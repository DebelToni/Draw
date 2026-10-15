"""Nested-folder contracts use temporary state and loopback HTTP only."""
import copy
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

from backup import export, restore_package
import client
from server import (Conflict, Database, canonical, current_projection, make_server,
                    validate, validate_current_only, validate_folder_graph)
import test_ai_sync
from test_ai_sync import sha, uid
from test_server import package


class NestedFolderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state.sqlite3"
        self.db = Database(self.path)
        self.root = {"id": uid(), "name": "School"}
        self.child = {"id": uid(), "name": "Math", "parentID": self.root["id"]}
        self.leaf = {"id": uid(), "name": "Notes", "parentID": self.child["id"]}
        self.empty = {"id": uid(), "name": "Empty", "parentID": self.root["id"]}
        self.p = package() | {"format": 3, "folders": [self.leaf, self.empty, self.root, self.child]}
        self.bid = self.p["notebooks"][0]["id"]
        self.p["notebooks"][0]["folderID"] = self.leaf["id"]

    def tearDown(self):
        self.temp.cleanup()

    def upload(self, p):
        return test_ai_sync.AISyncTests.upload(self, p)

    def publish(self, p=None):
        manifest, scenes = self.upload(p or self.p)
        self.db.commit_manifest(self.db.latest()["revision"], manifest, scenes)
        return manifest, scenes

    def snapshot(self):
        with self.db.connect() as db:
            return {t: db.execute("SELECT * FROM " + t).fetchall() for t in
                    ("revisions", "images", "scenes", "objects", "document_sync", "sync_receipts")}

    def test_format_three_roundtrip_projection_and_nested_only_merge(self):
        self.publish()
        self.assertEqual(Database(self.path).latest()["package"], self.p)
        self.assertEqual(current_projection(self.p)["format"], 3)
        state = self.db.document_state(self.bid)
        self.assertEqual(state["manifest"]["format"], 3)
        self.assertNotIn("assets", state["manifest"])
        scenes = self.db.document_scene_refs(self.bid)["scenes"]
        self.db.commit_document(self.bid, uid(), state["documentDigest"], state["manifest"], scenes)
        self.assertEqual(self.db.latest()["package"]["format"], 3)
        self.assertNotIn("assets", self.db.latest()["package"])

    def test_old_formats_cannot_carry_nested_graph(self):
        for fmt in (1, 2):
            p = copy.deepcopy(self.p)
            p["format"] = fmt
            for validator in (validate, validate_current_only):
                with self.assertRaisesRegex(ValueError, "format 3"):
                    validator(p)
        self.assertGreater(self.p["format"], 2)  # Older source readers reject the format gate.

    def test_flat_formats_and_document_digests_remain_exact(self):
        for with_ai in (False, True):
            for root_parent in ("absent", None):
                p = test_ai_sync.AISyncTests.with_ai(self) if with_ai else package()
                root = copy.deepcopy(self.root)
                if root_parent is None:
                    root["parentID"] = None
                p["folders"] = [root]
                p["notebooks"][0]["folderID"] = root["id"]
                encoded = canonical(p)
                manifest, _ = self.publish(p)
                state = self.db.document_state(p["notebooks"][0]["id"])
                self.assertEqual(state["manifest"], manifest)
                self.assertEqual(state["documentDigest"], sha(canonical(manifest)))
                self.assertEqual(canonical(self.db.latest()["package"]), encoded)
                with self.db.connect() as db:
                    self.assertEqual(db.execute("SELECT digest FROM revisions").fetchone()[0], sha(encoded))
                self.assertEqual(p["format"], 2 if with_ai else 1)
                self.assertEqual("parentID" in self.db.latest()["package"]["folders"][0], root_parent is None)

    def test_invalid_graph_rejected_before_any_object_read_or_publication(self):
        manifest, scenes = self.publish()
        baseline = self.snapshot()
        cases = []
        for parent in (self.leaf["id"], uid(), "bad", 42):
            bad = copy.deepcopy(manifest)
            bad["folders"][0]["parentID"] = parent
            cases.append(bad)
        bad = copy.deepcopy(manifest)
        bad["folders"][2]["parentID"] = self.leaf["id"]
        cases.append(bad)
        cases.append(manifest | {"folders": manifest["folders"] + [self.root]})
        cases.append(manifest | {"folders": [f for f in manifest["folders"] if f["id"] != self.root["id"]]})
        for bad in cases:
            with self.subTest(folders=bad["folders"]):
                with patch.object(self.db, "object", side_effect=AssertionError("Read before graph validation")):
                    with self.assertRaises(ValueError):
                        self.db.commit_manifest(1, bad, scenes)
                    with self.assertRaises(ValueError):
                        self.db.commit(1, bad)
                self.assertEqual(self.snapshot(), baseline)

    def test_deep_graph_validates_without_recursion_or_parent_first_order(self):
        folders = []
        parent = None
        for _ in range(1500):
            f = {"id": uid(), "name": "N", "parentID": parent}
            folders.append(f)
            parent = f["id"]
        p = {"format": 3, "notebooks": [], "folders": list(reversed(folders))}
        self.assertEqual(len(validate_folder_graph(p)), len(folders))
        p["folders"][-1]["parentID"] = parent
        with self.assertRaises(ValueError):
            validate_folder_graph(p)

    def test_document_manifest_exact_ancestor_closure_and_flat_root_subset(self):
        manifest, _ = self.publish()
        state = self.db.document_state(self.bid)
        self.assertEqual(state["manifest"]["folders"], [self.leaf, self.root, self.child])
        root_book = copy.deepcopy(manifest["notebooks"][0])
        root_book["folderID"] = self.root["id"]
        subset = self.db.document_manifest(manifest | {"notebooks": [root_book]}, self.bid)
        self.assertEqual(subset["folders"], [self.root])
        self.assertEqual(subset["format"], 1)
        root_book.pop("folderID")
        subset = self.db.document_manifest(manifest | {"notebooks": [root_book]}, self.bid)
        self.assertNotIn("folders", subset)
        self.assertEqual(subset["format"], 1)

    def test_home_receipt_unfiled_document_omits_empty_folder_closure(self):
        for folders in ([self.root], [self.root, self.child, self.empty]):
            with self.subTest(folders=folders):
                p = package() | {"format": 3 if len(folders) > 1 else 1, "folders": folders}
                bid = p["notebooks"][0]["id"]
                manifest, scenes = self.upload(p)
                sync_id = uid()
                receipt = self.db.commit_manifest(self.db.latest()["revision"], manifest, scenes, sync_id)
                expected = {key: value for key, value in manifest.items() if key != "folders"}
                expected["format"] = 1
                state = self.db.document_state(bid)
                self.assertEqual(state["manifest"], expected)
                self.assertEqual(receipt["documents"][bid], sha(canonical(expected)))
                self.assertEqual(receipt["documents"][bid], state["documentDigest"])
                self.assertEqual(self.db.sync_receipt(sync_id), receipt)
                self.assertEqual(self.db.manifest_state()["manifest"], manifest)

    def test_document_requires_exact_validated_ancestry_and_no_extra_children(self):
        _, scenes = self.publish()
        state = self.db.document_state(self.bid)
        baseline = self.snapshot()
        manifest = state["manifest"]
        cases = [manifest | {"folders": [self.leaf]},
                 manifest | {"folders": manifest["folders"] + [self.empty]},
                 manifest | {"folders": manifest["folders"] + [self.root]},
                 manifest | {"folders": [{"id": uid(), "name": "Other"}] + manifest["folders"]}]
        for bad in cases:
            with self.assertRaises(ValueError):
                self.db.commit_document(self.bid, uid(), state["documentDigest"], bad, scenes)
            self.assertEqual(self.snapshot(), baseline)

    def test_document_cannot_rename_or_move_existing_ancestors(self):
        _, scenes = self.publish()
        state = self.db.document_state(self.bid)
        baseline = self.snapshot()
        for fid in (self.leaf["id"], self.child["id"], self.root["id"]):
            bad = copy.deepcopy(state["manifest"])
            next(f for f in bad["folders"] if f["id"] == fid)["name"] = "Renamed"
            with self.assertRaises(Conflict):
                self.db.commit_document(self.bid, uid(), state["documentDigest"], bad, scenes)
        bad = copy.deepcopy(state["manifest"])
        next(f for f in bad["folders"] if f["id"] == self.child["id"])["parentID"] = None
        bad["folders"] = [f for f in bad["folders"] if f["id"] != self.root["id"]]
        with self.assertRaises(Conflict):
            self.db.commit_document(self.bid, uid(), state["documentDigest"], bad, scenes)
        self.assertEqual(self.snapshot(), baseline)

    def test_remote_ancestor_change_invalidates_document_baseline(self):
        _, scenes = self.publish()
        state = self.db.document_state(self.bid)
        p = copy.deepcopy(self.p)
        next(f for f in p["folders"] if f["id"] == self.root["id"])["name"] = "New name"
        self.publish(p)
        self.assertNotEqual(self.db.document_state(self.bid)["documentDigest"], state["documentDigest"])
        with self.assertRaises(Conflict):
            self.db.commit_document(self.bid, uid(), state["documentDigest"], state["manifest"], scenes)

    def test_document_merge_preserves_unrelated_docs_empty_tree_and_ancestry(self):
        combined = copy.deepcopy(self.p)
        other = package()
        combined["notebooks"] += other["notebooks"]
        combined["blobs"].update(other["blobs"])
        self.publish(combined)
        state = self.db.document_state(self.bid)
        manifest = copy.deepcopy(state["manifest"])
        manifest["notebooks"][0]["name"] = "Updated note"
        self.db.commit_document(self.bid, uid(), state["documentDigest"], manifest,
                                self.db.document_scene_refs(self.bid)["scenes"])
        latest = self.db.latest()["package"]
        self.assertEqual(latest["folders"], combined["folders"])
        self.assertEqual(latest["notebooks"][1], other["notebooks"][0])
        self.assertEqual(latest["blobs"], combined["blobs"])
        # A Home document's flat subset must not downgrade the remaining tree.
        bid = other["notebooks"][0]["id"]
        state = self.db.document_state(bid)
        self.assertEqual(state["manifest"]["format"], 1)
        self.db.commit_document(bid, uid(), state["documentDigest"], state["manifest"],
                                self.db.document_scene_refs(bid)["scenes"])
        self.assertEqual(self.db.latest()["package"]["format"], 3)

    def test_document_can_add_new_ancestry_without_pruning_existing_folders(self):
        self.publish()
        p = package() | {"format": 3, "folders": [copy.deepcopy(self.root), {"id": uid(), "name": "New", "parentID": self.root["id"]}]}
        p["notebooks"][0]["folderID"] = p["folders"][1]["id"]
        manifest, scenes = self.upload(p)
        self.db.commit_document(p["notebooks"][0]["id"], uid(), None, manifest, scenes)
        folders = self.db.latest()["package"]["folders"]
        self.assertEqual(folders, self.p["folders"] + [p["folders"][1]])

    def test_nested_ai_roundtrip_merge_projection_and_backup(self):
        p = test_ai_sync.AISyncTests.with_ai(self)
        p.update({"format": 3, "folders": self.p["folders"]})
        bid = p["notebooks"][0]["id"]
        p["notebooks"][0]["folderID"] = self.leaf["id"]
        self.publish(p)
        state = self.db.document_state(bid)
        self.assertEqual(state["manifest"]["format"], 3)
        self.assertEqual(current_projection(p)["format"], 3)
        self.db.commit_document(bid, uid(), state["documentDigest"], state["manifest"],
                                self.db.document_scene_refs(bid)["scenes"])
        self.assertEqual(self.db.latest()["package"], p)
        root = Path(self.temp.name) / "backup"
        export(self.db, root)
        self.assertEqual(restore_package(root), p)
        with self.assertRaisesRegex(ValueError, "v2"):
            self.db.commit(self.db.latest()["revision"], p)

    def test_nested_no_ai_assets_optional_but_no_unreferenced_assets(self):
        validate(self.p)
        validate(self.p | {"assets": {}})
        self.publish(self.p | {"assets": {}})
        root = Path(self.temp.name) / "backup"
        export(self.db, root)
        self.assertEqual(restore_package(root), self.p | {"assets": {}})
        for assets in (None, [], {"0" * 64: "eA=="}):
            with self.assertRaises(ValueError):
                validate(self.p | {"assets": assets})

    def test_whole_library_move_and_delete_reparent_without_changing_ids_or_pngs(self):
        p = copy.deepcopy(self.p)
        descendant = {"id": uid(), "name": "Deep", "parentID": self.leaf["id"]}
        p["folders"].append(descendant)
        # A document directly inside the deleted child moves to its parent.
        p["notebooks"][0]["folderID"] = self.child["id"]
        _, scenes = self.publish(p)
        key = next(iter(scenes))
        png = self.db.image(1, key)
        changed = copy.deepcopy(p)
        changed["folders"] = [f for f in changed["folders"] if f["id"] != self.child["id"]]
        next(f for f in changed["folders"] if f["id"] == self.leaf["id"])["parentID"] = self.root["id"]
        changed["notebooks"][0]["folderID"] = self.root["id"]
        self.publish(changed)
        self.assertEqual(self.db.latest()["package"], changed)
        self.assertEqual(changed["blobs"], p["blobs"])
        self.assertEqual(next(f for f in changed["folders"] if f["id"] == descendant["id"]), descendant)
        self.assertEqual(self.db.image(2, key), png)
        root = Path(self.temp.name) / "backup"
        export(self.db, root)
        self.assertEqual(restore_package(root), changed)
        backup = json.loads((root / "manifest.json").read_bytes())
        self.assertEqual((root / backup["images"][key]["file"]).read_bytes(), png)
        # A whole-library folder move retains the subtree.
        moved = copy.deepcopy(changed)
        next(f for f in moved["folders"] if f["id"] == self.root["id"])["parentID"] = self.empty["id"]
        with self.assertRaises(ValueError):  # Empty was inside root, so this move cycles.
            self.publish(moved)
        self.assertEqual(self.db.latest()["package"], changed)
        backup["package"]["folders"][0]["parentID"] = uid()
        (root / "manifest.json").write_bytes(canonical(backup))
        with self.assertRaises(ValueError):
            restore_package(root)

    def test_whole_library_existing_folder_move_preserves_descendant_tree(self):
        self.publish()
        p = copy.deepcopy(self.p)
        destination = {"id": uid(), "name": "Destination"}
        p["folders"].append(destination)
        next(f for f in p["folders"] if f["id"] == self.child["id"])["parentID"] = destination["id"]
        self.publish(p)
        latest = self.db.latest()["package"]
        self.assertEqual(latest, p)
        self.assertEqual(latest["blobs"], self.p["blobs"])
        self.assertEqual(next(f for f in latest["folders"] if f["id"] == self.leaf["id"]), self.leaf)
        state = self.db.document_state(self.bid)
        self.assertEqual({f["id"] for f in state["manifest"]["folders"]},
                         {destination["id"], self.child["id"], self.leaf["id"]})

    def test_revision_pinned_navigation_and_cli(self):
        self.publish()
        server = make_server(self.path, "test-token", port=0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def get(path):
            request = urllib.request.Request(f"http://127.0.0.1:{server.server_port}" + path,
                                             headers={"Authorization": "Bearer test-token"})
            with urllib.request.urlopen(request) as response:
                return json.load(response)
        try:
            group = get("/v1/folders/" + self.leaf["id"] + "?revision=1")
            self.assertEqual(group["folder"]["parentID"], self.child["id"])
            self.assertEqual(group["folder"]["fullPath"], "School/Math/Notes")
            self.assertEqual(group["folder"]["pathIDs"], [self.root["id"], self.child["id"], self.leaf["id"]])
            self.assertEqual([f["id"] for f in group["ancestors"]], [self.root["id"], self.child["id"]])
            self.assertEqual(group["children"], [])
            self.assertEqual(group["documents"][0]["folderPath"], "School/Math/Notes")
            root = get("/v1/folders/" + self.root["id"])
            self.assertEqual(root["folder"]["parentID"], None)
            self.assertEqual({f["id"] for f in root["children"]}, {self.child["id"], self.empty["id"]})
            self.assertEqual(root["documents"], [])
            listing = get("/v1/documents?revision=1")
            self.assertEqual(listing["documents"][0]["folderPathIDs"], group["folder"]["pathIDs"])
            p = copy.deepcopy(self.p)
            next(f for f in p["folders"] if f["id"] == self.root["id"])["name"] = "Updated"
            self.publish(p)
            with self.assertRaises(urllib.error.HTTPError) as error:
                get("/v1/folders/" + self.leaf["id"] + "?revision=1")
            self.assertEqual(error.exception.code, 404)
            self.assertEqual(get("/v1/folders/" + self.leaf["id"])["folder"]["fullPath"], "Updated/Math/Notes")
            with patch.dict("os.environ", {"DRAW_SYNC_TOKEN": "test-token", "DRAW_SYNC_URL": f"http://127.0.0.1:{server.server_port}"}), patch("sys.argv", ["client.py", "--folder", self.leaf["id"], "--revision", "2"]), patch("builtins.print") as output:
                client.main()
            self.assertEqual(json.loads(output.call_args.args[0])["revision"], 2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
