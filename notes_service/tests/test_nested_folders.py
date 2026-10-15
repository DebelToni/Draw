"""Nested source labels never change the two-level workspace or exact Pi identity."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from notes_service.manager import Manager
from notes_service.source import SyncSource
from notes_service.storage import Problem, encoded
from notes_service.tests.fixtures import Renderer, uid
from notes_service.tests.test_source import HTTP


class NestedFolderTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.now = 1000.0
        self.semester, self.math, self.empty, self.other = uid(), uid(), uid(), uid()
        self.folders = [{"id": self.math, "name": "Math", "parentID": self.semester},
                        {"id": self.semester, "name": "Semester", "parentID": None},
                        {"id": self.empty, "name": "Empty", "parentID": self.math},
                        {"id": self.other, "name": "Other"}]
        self.http = HTTP({"/v1/folders": {"folders": self.folders}})
        self.source = SyncSource(self.http, "fixture-token")
        self.m = Manager(self.root/"state", Renderer(), self.source, workspace=self.root/"workspace",
                         clock=lambda: self.now)
        self.docs, self.states = [], []
        for name in ("Limits", "Continuity"):
            doc = uid()
            state = {"documentDigest": "a"*64, "lastSyncedAt": "2026-10-09T00:00:00Z",
                     "manifest": {"format": 3, "folders": self.folders,
                                  "notebooks": [{"id": doc, "name": name, "folderID": self.math}]}}
            self.http.mapping["/v2/documents/"+doc+"/state"] = state
            self.docs.append(doc)
            self.states.append(state)
            await self.m.ensure_worker(doc, {"documentName": name, "folderID": self.math,
                                            "folderName": "Semester / Math",
                                            "capturedAt": "2026-10-09T00:00:00Z"})
        self.before, self.rest = {}, b'{"type":"custom","data":"sentinel"}\n'
        for doc in self.docs:
            worker = self.m.worker_registry.get(doc)
            path = self.root/(doc+".jsonl")
            path.write_bytes(encoded({"type": "session", "version": 3, "id": worker["sessionID"],
                                      "cwd": worker["cwd"]})+b"\n"+self.rest)
            worker["sessionFile"] = str(path)
            self.m.worker_registry.save(worker)
            self.before[doc] = worker
        await self.m.refresh_worker_labels()  # Establish the captured-name source baseline.

    async def asyncTearDown(self):
        self.m.close()
        self.temp.cleanup()

    def publish(self):
        for state in self.states:
            state.update(documentDigest="b"*64, lastSyncedAt="2026-10-09T00:02:00Z")

    async def test_empty_nested_folders_mirror_as_single_display_directory(self):
        record = self.m.store.record("folder", self.empty)
        self.assertEqual(record["folderID"], self.empty)
        self.assertEqual(record["name"], "Semester / Math / Empty")
        directory = self.m.worker_registry.workspace/record["directory"]
        self.assertTrue(directory.is_dir())
        self.assertEqual(directory.parent, self.m.worker_registry.workspace)
        self.assertEqual(list(directory.iterdir()), [])
        self.assertEqual(await self.source.folders(), self.folders)

    async def test_ancestor_move_refreshes_all_descendants_and_defers_exact_relocation(self):
        # Move the root under another folder and rename it, leaving leaf membership unchanged.
        self.folders[1].update(name="New semester", parentID=self.other)
        self.publish()
        await self.m.refresh_worker_labels()
        expected = "Other / New semester / Math"
        registry = self.m.worker_registry
        for doc in self.docs:
            worker = registry.get(doc)
            self.assertEqual(worker["renamePending"]["folder"], expected)
            self.assertEqual(worker["renamePending"]["folderID"], self.math)
            self.assertEqual(worker["cwd"], self.before[doc]["cwd"])
            self.assertEqual(worker["sessionID"], self.before[doc]["sessionID"])
        self.assertEqual(self.m.store.record("folder", self.empty)["name"], expected+" / Empty")
        live = self.docs[0]
        worker = registry.get(live)
        worker.update(lease="fixture-lease", heartbeat=self.now, inputObserved=True)
        registry.save(worker)
        # These tests may exercise maintenance but must never issue live worker commands.
        with patch.object(registry, "pane_owned", side_effect=lambda w: w["documentID"] == live), patch(
                "notes_service.workerregistry.subprocess.run") as process:
            await self.m.maintenance(spawn_workers=True)
            process.assert_not_called()
        self.assertTrue(registry.get(live)["shutdownRequested"])
        self.assertEqual(registry.get(live)["cwd"], self.before[live]["cwd"])
        registry.activity(live, "fixture-lease", "shutdown")
        with patch.object(registry, "pane_owned", return_value=False), patch(
                "notes_service.workerregistry.subprocess.run") as process:
            await self.m.maintenance(spawn_workers=True)
            process.assert_not_called()
        for doc in self.docs:
            moved = registry.get(doc)
            before = self.before[doc]
            self.assertEqual(moved["folderID"], self.math)
            self.assertEqual(moved["folderName"], expected)
            self.assertEqual(moved["label"], expected+" / "+before["noteName"])
            self.assertEqual(moved["sessionID"], before["sessionID"])
            self.assertEqual(moved["sessionFile"], before["sessionFile"])
            self.assertEqual(Path(moved["cwd"]).parents[1], registry.workspace)
            self.assertNotEqual(moved["cwd"], before["cwd"])
            self.assertNotIn("renamePending", moved)
            first, rest = Path(moved["sessionFile"]).read_bytes().split(b"\n", 1)
            self.assertEqual(rest, self.rest)
            self.assertEqual(json.loads(first)["cwd"], moved["cwd"])
            command = registry.command(moved)
            self.assertIn("--fast", command)
            self.assertEqual(command[command.index("--session")+1], before["sessionFile"])

    async def test_source_revert_while_busy_clears_pending_without_relocation(self):
        registry = self.m.worker_registry
        for doc in self.docs:
            worker = registry.get(doc)
            worker.update(busy=True, pending=True)
            registry.save(worker)
        self.folders[1]["name"] = "Renamed"
        self.publish()
        await self.m.refresh_worker_labels()
        with patch.object(registry, "pane_owned", return_value=False), patch(
                "notes_service.workerregistry.subprocess.run") as process:
            await self.m.maintenance(spawn_workers=True)
            process.assert_not_called()
        for doc in self.docs:
            self.assertEqual(registry.get(doc)["renamePending"]["folder"], "Renamed / Math")

        self.folders[1]["name"] = "Semester"
        for state in self.states:
            state.update(documentDigest="c"*64, lastSyncedAt="2026-10-09T00:04:00Z")
        await self.m.refresh_worker_labels()
        for doc in self.docs:
            worker = registry.get(doc)
            self.assertNotIn("renamePending", worker)
            worker.update(busy=False, pending=False)
            registry.save(worker)
        with patch.object(registry, "pane_owned", return_value=False), patch(
                "notes_service.workerregistry.subprocess.run") as process:
            await self.m.maintenance(spawn_workers=True)
            process.assert_not_called()
        for doc in self.docs:
            worker, before = registry.get(doc), self.before[doc]
            for key in ("sessionID", "sessionFile", "cwd", "folderDirectory", "folderID", "label"):
                self.assertEqual(worker[key], before[key])
            self.assertNotIn("relocation", worker)
            self.assertFalse(worker["shutdownRequested"])
            self.assertEqual(json.loads(Path(worker["sessionFile"]).read_bytes().split(b"\n", 1)[0])["cwd"], before["cwd"])
            self.assertEqual(Path(worker["sessionFile"]).read_bytes().split(b"\n", 1)[1], self.rest)

    async def test_old_source_current_labels_do_not_clear_newer_native_pending(self):
        doc = self.docs[0]
        native = {"folderName": "Renamed / Math", "folderID": self.math,
                  "capturedAt": "2026-10-09T00:03:00Z"}
        await self.m.ensure_worker(doc, native)
        await self.m.refresh_worker_labels()  # Source still has the current, older worker labels.
        worker = self.m.worker_registry.get(doc)
        self.assertEqual(worker["renamePending"]["folder"], native["folderName"])
        self.assertEqual(worker["capturedLabelProvenance"]["fields"], ["folder", "folderID"])

        # Even a confirmed native baseline must not permit an older source revert.
        self.folders[1]["name"] = "Renamed"
        self.publish()
        await self.m.refresh_worker_labels()
        guard = self.m.worker_registry.get(doc)["capturedLabelProvenance"]
        self.assertIn("confirmedSource", guard)
        self.folders[1]["name"] = "Semester"
        self.states[0].update(documentDigest="c"*64, lastSyncedAt="2026-10-09T00:02:30Z")
        await self.m.refresh_worker_labels()
        worker = self.m.worker_registry.get(doc)
        self.assertEqual(worker["renamePending"]["folder"], native["folderName"])
        self.assertEqual(worker["capturedLabelProvenance"], guard)
        self.assertEqual(worker["cwd"], self.before[doc]["cwd"])
        self.assertEqual(worker["sessionID"], self.before[doc]["sessionID"])

    async def test_long_branch_keeps_source_and_unrelated_worker_refresh_healthy(self):
        parent, names = None, []
        for index in range(11):
            fid, name = uid(), str(index).zfill(2)+"x"*94
            self.folders.append({"id": fid, "name": name, "parentID": parent})
            parent = fid
            names.append(name)
        full_path = " / ".join(names)
        self.assertGreater(len(full_path.encode()), 1024)
        long_doc = uid()
        self.http.mapping["/v2/documents/"+long_doc+"/state"] = {
            "documentDigest": "d"*64, "lastSyncedAt": "2026-10-09T00:04:00Z",
            "manifest": {"format": 3, "folders": self.folders,
                         "notebooks": [{"id": long_doc, "name": "Deep note", "folderID": parent}]}}
        await self.m.ensure_worker(long_doc)
        long_before = self.m.worker_registry.get(long_doc)
        self.folders[1]["name"] = "Renamed"
        self.publish()
        self.assertEqual(await self.source.folders(), self.folders)
        self.assertEqual((await self.source.worker_labels(long_doc))["folderName"], full_path)
        await self.m.refresh_worker_labels()
        self.assertEqual(self.m.store.record("folder", parent)["name"], full_path)
        directory = self.m.store.record("folder", parent)["directory"]
        self.assertLessEqual(len(directory), 105)
        self.assertEqual(Path(long_before["cwd"]).parents[1], self.m.worker_registry.workspace)
        for doc in self.docs:
            self.assertEqual(self.m.worker_registry.get(doc)["renamePending"]["folder"], "Renamed / Math")
        long_after = self.m.worker_registry.get(long_doc)
        self.assertEqual(long_after["folderName"], full_path)
        self.assertEqual(long_after["sessionID"], long_before["sessionID"])
        self.assertNotIn("renamePending", long_after)

    async def test_invalid_listing_does_not_publish_partial_folder_labels(self):
        before = self.m.store.record("folder", self.math)
        self.folders[1]["parentID"] = self.math
        with self.assertRaises(Problem):
            await self.m.refresh_worker_labels()
        self.assertEqual(self.m.store.record("folder", self.math), before)
        for doc in self.docs:
            self.assertNotIn("renamePending", self.m.worker_registry.get(doc))

    async def test_nested_capture_replaces_pending_label_without_new_session(self):
        doc = self.docs[0]
        self.folders[1]["name"] = "Renamed"
        self.publish()
        await self.m.refresh_worker_labels()
        self.assertIn("renamePending", self.m.worker_registry.get(doc))
        await self.m.ensure_worker(doc, {"folderName": "Semester / Math", "folderID": self.math,
                                        "capturedAt": "2026-10-09T00:03:00Z"})
        worker = self.m.worker_registry.get(doc)
        self.assertNotIn("renamePending", worker)
        self.assertEqual(worker["sessionID"], self.before[doc]["sessionID"])
        self.assertEqual(worker["sessionFile"], self.before[doc]["sessionFile"])


if __name__ == "__main__":
    unittest.main()
