import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from notes_service.storage import Store, Problem, encoded
from notes_service.workerregistry import WorkerRegistry, IDLE_SECONDS, safe_name
from notes_service.tests.fixtures import uid


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store = Store(self.root/"state")
        self.now = 1000.0
        self.registry = WorkerRegistry(self.store, self.root/"workspace", "http://127.0.0.1:18881", self.root/"token", clock=lambda: self.now)
        self.doc = uid()
        self.w = self.registry.reserve(self.doc, "math", "Limits")

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def register(self, **changes):
        body = {"documentID": self.doc, "sessionID": self.w["sessionID"], "sessionFile": str(self.root/"session.jsonl"),
                "cwd": self.w["cwd"], "spawnNonce": self.w["spawnNonce"], "busy": False, "pending": False, "inputObserved": True}
        self.w = self.registry.register({**body, **changes})
        return self.w

    def persisted(self):
        self.register()
        path = Path(self.w["sessionFile"])
        header = {"type": "session", "version": 3, "id": self.w["sessionID"], "cwd": self.w["cwd"], "timestamp": "2026-10-08T00:00:00Z"}
        body = encoded({"type": "custom", "customType": "sentinel", "data": {"value": 42}})+b"\n"
        path.write_bytes(encoded(header)+b"\n"+body)
        self.registry.activity(self.doc, self.w["lease"], "shutdown")
        self.w = self.registry.get(self.doc)
        return body

    def idle(self):
        self.register()
        self.now += IDLE_SECONDS
        self.w["heartbeat"] = self.now
        return self.w

    def test_idempotent_reservation_exact_session(self):
        self.assertEqual(self.registry.reserve(self.doc, "other", "name"), self.w)
        self.assertTrue((Path(self.w["cwd"])/"document.json").is_file())
        self.assertTrue((self.root/"workspace/AGENTS.md").is_file())
        self.assertEqual(Path(self.w["cwd"]).parents[1], self.root/"workspace")

    def test_duplicate_label_disambiguated(self):
        other_doc = uid()
        other = self.registry.reserve(other_doc, "math", "Limits")
        self.assertIn(other_doc[:8], other["label"])
        self.assertNotEqual(other["sessionID"], self.w["sessionID"])
        self.assertEqual(other["noteName"], "Limits")

    def test_duplicate_folder_names_have_distinct_uuid_paths(self):
        first_id, second_id = uid(), uid()
        first = self.registry.reserve(uid(), "Math", "Limits", first_id)
        second = self.registry.reserve(uid(), "Math", "Limits", second_id)
        same_folder = self.registry.reserve(uid(), "Math", "Limits", first_id)
        self.assertNotEqual(Path(first["cwd"]).parent, Path(second["cwd"]).parent)
        self.assertEqual(Path(first["cwd"]).parent, Path(same_folder["cwd"]).parent)
        self.assertEqual(first["folderID"], first_id)
        self.assertEqual(second["folderID"], second_id)
        self.assertIn(second_id[:8], second["label"])
        self.assertNotEqual(first["sessionID"], second["sessionID"])

    def test_nested_logical_labels_use_one_safe_folder_directory(self):
        first_id, second_id = uid(), uid()
        first = self.registry.reserve(uid(), "Semester / Math", "Limits", first_id)
        second = self.registry.reserve(uid(), "Semester / Math", "Limits", second_id)
        self.assertEqual(first["folderName"], "Semester / Math")
        self.assertEqual(first["label"], "Semester / Math / Limits")
        self.assertEqual(Path(first["cwd"]).parent.name, "Semester _ Math")
        self.assertEqual(Path(first["cwd"]).parents[1], self.registry.workspace)
        self.assertEqual(self.store.record("folder", first_id)["name"], "Semester / Math")
        self.assertNotEqual(Path(first["cwd"]).parent, Path(second["cwd"]).parent)
        self.assertIn(second_id[:8], second["label"])

    def test_logical_rename_with_same_safe_path_refreshes_label_without_session_change(self):
        rest = self.persisted()
        fid = uid()
        with patch.object(self.registry, "pane_owned", return_value=False):
            before = self.registry.relocate(self.doc, "Semester / Math", "Limits", fid)
            moved = self.registry.relocate(self.doc, "Semester _ Math", "Limits", fid)
        self.assertEqual(moved["cwd"], before["cwd"])
        self.assertEqual(moved["label"], "Semester _ Math / Limits")
        self.assertEqual(moved["sessionID"], before["sessionID"])
        self.assertEqual(moved["sessionFile"], before["sessionFile"])
        self.assertEqual(Path(moved["sessionFile"]).read_bytes().split(b"\n", 1)[1], rest)

    def test_named_home_folder_cannot_claim_unfiled_home(self):
        folder_id = uid()
        filed = self.registry.reserve(uid(), "Home", "Filed", folder_id)
        unfiled = self.registry.reserve(uid(), "Home", "Scratch")
        self.assertEqual(Path(unfiled["cwd"]).parent.name, "Home")
        self.assertIn(folder_id[:8], Path(filed["cwd"]).parent.name)

    def test_relocation_preserves_folder_uuid_and_exact_session(self):
        self.persisted()
        new_folder = uid()
        with patch.object(self.registry, "pane_owned", return_value=False):
            moved = self.registry.relocate(self.doc, "Analysis", "Limits", new_folder)
        self.assertEqual(moved["folderID"], new_folder)
        self.assertEqual(moved["sessionID"], self.w["sessionID"])
        self.assertEqual(moved["sessionFile"], self.w["sessionFile"])
        self.assertEqual(json.loads((Path(moved["cwd"])/"document.json").read_text())["folderID"], new_folder)

    def test_header_relocation_refuses_still_existing_unowned_pane(self):
        self.persisted()
        self.w.update(paneID="%fixture", shutdownAcknowledged=True)
        self.registry.save(self.w)
        original = Path(self.w["sessionFile"]).read_bytes()
        import subprocess
        result = subprocess.CompletedProcess([], 0, "%fixture", "")
        with patch.object(self.registry, "pane_owned", return_value=False), patch("notes_service.workerregistry.subprocess.run", return_value=result), self.assertRaises(Problem):
            self.registry.relocate(self.doc, "New", "Moved")
        self.assertEqual(Path(self.w["sessionFile"]).read_bytes(), original)
        self.assertTrue(Path(self.w["cwd"]).exists())

    def test_missing_pane_exit_zero_empty_format_allows_exact_session_relocation(self):
        rest = self.persisted()
        self.w.update(paneID="%426", windowID="@fixture", shutdownAcknowledged=True)
        self.registry.save(self.w)
        old = self.w["cwd"]
        import subprocess
        def display(args, **kwargs):
            self.assertEqual(args[1:5], ["display-message", "-p", "-t", "%426"])
            return subprocess.CompletedProcess(args, 0, "\n" if args[-1] == "#{pane_id}" else "||||\n", "")
        with patch("notes_service.workerregistry.subprocess.run", side_effect=display):
            moved = self.registry.relocate(self.doc, "New", "Moved")
        self.assertEqual(moved["sessionID"], self.w["sessionID"])
        self.assertEqual(moved["sessionFile"], self.w["sessionFile"])
        first, body = Path(moved["sessionFile"]).read_bytes().split(b"\n", 1)
        self.assertEqual(json.loads(first)["cwd"], moved["cwd"])
        self.assertEqual(body, rest)
        self.assertFalse(Path(old).exists())

    def test_missing_pane_probe_unknown_output_or_failure_remains_uncertain(self):
        self.persisted()
        self.w.update(paneID="%426", shutdownAcknowledged=True)
        self.registry.save(self.w)
        original = Path(self.w["sessionFile"]).read_bytes()
        import subprocess
        for code, stdout, stderr in ((0, "%other", ""), (0, "||||", ""), (1, "", "permission denied")):
            with self.subTest(code=code, stdout=stdout), patch.object(self.registry, "pane_owned", return_value=False), patch(
                    "notes_service.workerregistry.subprocess.run", return_value=subprocess.CompletedProcess([], code, stdout, stderr)):
                with self.assertRaises(Problem) as error:
                    self.registry.relocate(self.doc, "New", "Moved")
                self.assertEqual(error.exception.code, "worker_uncertain")
                self.assertEqual(Path(self.w["sessionFile"]).read_bytes(), original)
                self.assertTrue(Path(self.w["cwd"]).exists())

    def test_path_sanitization_and_home_depth(self):
        self.assertEqual(safe_name("../../a\n"), "_.._a_")
        worker = self.registry.reserve(uid(), "..", "../../outside")
        self.assertTrue(Path(worker["cwd"]).is_relative_to(self.root/"workspace"))
        home = self.registry.reserve(uid(), "Home", "Scratch")
        self.assertEqual(Path(home["cwd"]).parents[1], self.root/"workspace")

    def test_command_full_global_tools_and_unlisted(self):
        args = self.registry.command(self.w)
        self.assertIn("--unlisted", args)
        self.assertIn("--fast", args)
        self.assertIn("--name", args)
        self.assertIn("--session-id", args)
        for stripped in ("--no-tools", "--tools", "--no-extensions", "--mode", "--continue", "--no-context-files"):
            self.assertNotIn(stripped, args)

    def test_wrong_session_reset_and_cwd_refused(self):
        for changes in ({"sessionID": uid()}, {"cwd": str(self.root)}, {"spawnNonce": "bad"}):
            with self.assertRaises(Problem) as error:
                self.register(**changes)
            self.assertEqual(error.exception.code, "worker_identity")

    def test_duplicate_live_bridge_cannot_take_session_lease(self):
        self.register()
        first = self.w["lease"]
        with self.assertRaises(Problem) as error:
            self.register()
        self.assertEqual(error.exception.code, "worker_bridge_busy")
        self.assertEqual(self.registry.get(self.doc)["lease"], first)

    def test_exact_file_cannot_be_replaced(self):
        self.register()
        with self.assertRaises(Problem) as error:
            self.register(sessionFile=str(self.root/"different.jsonl"))
        self.assertEqual(error.exception.code, "worker_identity")

    def test_session_header_id_mismatch_refused(self):
        path = self.root/"session.jsonl"
        path.write_bytes(encoded({"type": "session", "version": 3, "id": uid(), "cwd": self.w["cwd"]})+b"\n")
        with self.assertRaises(Problem) as error:
            self.register()
        self.assertEqual(error.exception.code, "worker_identity")

    def test_missing_persisted_locator_is_explicit_not_new(self):
        self.register()
        with self.assertRaises(Problem) as error:
            self.registry.command(self.w)
        self.assertEqual(error.exception.code, "worker_session_missing")

    def test_idle_boundary_24h(self):
        worker = self.idle()
        self.now -= .01
        worker["heartbeat"] = self.now
        self.assertFalse(self.registry.idle_allowed(worker, tmux_activity_known=True))
        self.now += .01
        worker["heartbeat"] = self.now
        self.assertTrue(self.registry.idle_allowed(worker, tmux_activity_known=True))

    def test_idle_requires_complete_recent_activity(self):
        original = self.idle()
        for field, value in (("busy", True), ("pending", True), ("inputObserved", False),
                             ("activeRequestID", uid()), ("heartbeat", self.now-31), ("lease", None)):
            worker = {**original, field: value}
            self.assertFalse(self.registry.idle_allowed(worker, tmux_activity_known=True), field)
        self.assertFalse(self.registry.idle_allowed(original, pending_requests=True, tmux_activity_known=True))
        self.assertFalse(self.registry.idle_allowed(original, tmux_activity_known=False))

    def test_raw_human_input_restarts_inactivity(self):
        self.idle()
        self.registry.heartbeat(self.doc, self.w["lease"], {"busy": False, "pending": False, "inputObserved": True, "humanActivity": True})
        worker = self.registry.get(self.doc)
        self.assertEqual(worker["lastActivity"], self.now)
        self.assertFalse(self.registry.idle_allowed(worker, tmux_activity_known=True))

    def test_agent_end_not_supported_settled_authority(self):
        self.register()
        self.registry.activity(self.doc, self.w["lease"], "agent_start")
        with self.assertRaises(Problem):
            self.registry.activity(self.doc, self.w["lease"], "agent_end")
        self.assertTrue(self.registry.get(self.doc)["busy"])
        self.registry.activity(self.doc, self.w["lease"], "agent_settled")
        self.assertFalse(self.registry.get(self.doc)["busy"])

    def test_shutdown_requests_only_owned_pane(self):
        worker = self.idle()
        self.registry.save(worker)
        with patch.object(self.registry, "pane_owned", return_value=False):
            self.assertFalse(self.registry.request_idle_shutdown(self.doc))
        with patch.object(self.registry, "pane_owned", return_value=True):
            self.assertTrue(self.registry.request_idle_shutdown(self.doc))
        self.assertTrue(self.registry.get(self.doc)["shutdownRequested"])

    def test_resume_absolute_file_no_continue(self):
        self.persisted()
        args = self.registry.command(self.w)
        self.assertEqual(args[args.index("--session")+1], self.w["sessionFile"])
        self.assertIn("--fast", args)
        self.assertNotIn("--session-id", args)

    def test_rename_preserves_exact_session_and_bytes(self):
        rest = self.persisted()
        old = self.w["cwd"]
        with patch.object(self.registry, "pane_owned", return_value=False):
            moved = self.registry.relocate(self.doc, "analysis", "Continuity")
        self.assertEqual(moved["sessionID"], self.w["sessionID"])
        self.assertEqual(moved["sessionFile"], self.w["sessionFile"])
        self.assertFalse(Path(old).exists())
        data = Path(moved["sessionFile"]).read_bytes()
        first, body = data.split(b"\n",1)
        self.assertEqual(body, rest)
        self.assertEqual(json.loads(first)["cwd"], moved["cwd"])
        self.assertEqual(moved["label"], "analysis / Continuity")
        self.registry.command(moved)

    def test_rename_busy_live_and_pending_guards(self):
        self.register()
        with self.assertRaises(Problem):
            self.registry.relocate(self.doc, "analysis", "New")
        self.registry.activity(self.doc, self.w["lease"], "shutdown")
        with patch.object(self.registry, "pane_owned", return_value=True), self.assertRaises(Problem):
            self.registry.relocate(self.doc, "analysis", "New")

    def test_crash_journal_finishes_move_without_fork(self):
        rest = self.persisted()
        destination = self.root/"workspace/New/Restored"
        worker = self.registry.get(self.doc)
        worker["relocation"] = {"from": worker["cwd"], "to": str(destination)}
        self.registry.save(worker)
        with patch.object(self.registry, "pane_owned", return_value=False):
            self.registry.finish_relocation(worker)
        self.assertEqual(worker["sessionID"], self.w["sessionID"])
        self.assertEqual(Path(worker["sessionFile"]).read_bytes().split(b"\n",1)[1], rest)
        self.assertNotIn("relocation", self.registry.get(self.doc))


if __name__ == "__main__":
    unittest.main()
