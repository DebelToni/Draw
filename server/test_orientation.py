"""Notebook orientation is additive metadata, never a source rewrite default."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from uuid import uuid4

from backup import export, restore_package
from server import Database, canonical, current_projection, validate
from test_current_only import history_package
import test_incremental
from test_incremental import renderer, scene, sha
from test_server import package


class OrientationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = Database(Path(self.temp.name) / "state.sqlite3")

    def tearDown(self):
        self.temp.cleanup()

    def snapshot(self):
        with self.db.connect() as db:
            return {table: sorted(db.execute(f"SELECT * FROM {table}").fetchall())
                    for table in ("revisions", "objects", "images", "scenes", "staged_objects")}

    def test_allowed_orientation_backup_roundtrip_never_inserts_source_default(self):
        for value in ("absent", None, "portrait", "landscape"):
            with self.subTest(value=value):
                p = package()
                if value != "absent":
                    p["notebooks"][0]["orientation"] = value
                before = copy.deepcopy(p)
                validate(p)
                self.db.commit(self.db.latest()["revision"], p)
                root = Path(self.temp.name) / "backup"
                export(self.db, root)
                self.assertEqual(restore_package(root), before)
                self.assertEqual(self.db.latest()["package"], before)
                self.assertEqual(p, before)

    def test_invalid_orientation_rejected_atomically_in_v1_v2_and_scene_dims_unchanged(self):
        p = package()
        p["notebooks"][0]["orientation"] = "landscape"
        with self.db.connect() as db:
            packed = self.db.pack(db, p)
        manifest = self.db.source_manifest(packed)
        book = p["notebooks"][0]
        key = f'{book["id"]}/{book["pages"][0]["id"]}'
        portable = canonical(scene(book["pages"][0], width=80) | {"height": 20})
        scene_digest = self.db.upload_object(sha(portable), portable)
        scenes = {key: scene_digest}
        with renderer():
            self.db.commit_manifest(0, manifest, scenes)
            metadata = self.db.image_metadata(1)[key]
            self.assertEqual((metadata["width"], metadata["height"]), (160, 40))
            before = self.snapshot()
            for value in ("", "Landscape", "square", 0, False, [], {}, ["portrait"]):
                with self.subTest(value=value):
                    bad = copy.deepcopy(p)
                    bad["notebooks"][0]["orientation"] = value
                    with self.assertRaises(ValueError):
                        self.db.commit(1, bad)
                    bad_manifest = copy.deepcopy(manifest)
                    bad_manifest["notebooks"][0]["orientation"] = value
                    with self.assertRaises(ValueError):
                        self.db.commit_manifest(1, bad_manifest, scenes)
                    self.assertEqual(self.snapshot(), before)

    def test_current_only_migration_preserves_orientation_and_rejects_invalid_atomically(self):
        for value in ("absent", None, "portrait", "landscape", "invalid"):
            with self.subTest(value=value):
                p = history_package()
                if value != "absent":
                    p["notebooks"][0]["orientation"] = value
                with self.db.connect() as db:
                    for table in ("revisions", "objects", "images", "scenes", "staged_objects"):
                        db.execute(f"DELETE FROM {table}")
                    db.execute("INSERT INTO revisions(revision,digest,package) VALUES(7,?,?)",
                               (sha(canonical(p)), self.db.pack(db, p)))
                before = self.snapshot()
                if value == "invalid":
                    with self.assertRaises(ValueError):
                        self.db.migrate_current_only()
                    self.assertEqual(self.snapshot(), before)
                else:
                    self.assertEqual(self.db.migrate_current_only(), 8)
                    projected = self.db.latest()["package"]
                    self.assertEqual(projected, current_projection(p))
                    self.assertEqual({k: v for k, v in projected["notebooks"][0].items() if k not in ("pages", "deleted")},
                                     {k: v for k, v in p["notebooks"][0].items() if k not in ("pages", "deleted")})
                    root = Path(self.temp.name) / "migrated-backup"
                    export(self.db, root)
                    self.assertEqual(restore_package(root), projected)


class OrientationHTTPTests(unittest.TestCase):
    setUp = test_incremental.IncrementalHTTPTests.setUp
    tearDown = test_incremental.IncrementalHTTPTests.tearDown
    request = test_incremental.IncrementalHTTPTests.request

    def test_document_and_folder_overviews_default_legacy_blank_to_portrait_without_source_rewrite(self):
        for revision, value in enumerate(("absent", None, "portrait", "landscape")):
            with self.subTest(value=value):
                p = package()
                book = p["notebooks"][0]
                if value != "absent":
                    book["orientation"] = value
                # Blank native legacy pages remain valid and still report orientation.
                book["pages"][0].pop("head")
                book["pages"][0]["nodes"] = []
                p["blobs"] = {}
                fid = str(uuid4()).upper()
                p["folders"] = [{"id": fid, "name": "School"}]
                book["folderID"] = fid
                self.assertEqual(self.request("/v1/state", {"baseRevision": revision, "package": p})[0], 200)
                expected = "landscape" if value == "landscape" else "portrait"
                for path, field in (("/v1/documents", "documents"),
                                    ("/v1/documents/" + book["id"], "document"),
                                    ("/v1/folders/" + fid, "documents")):
                    status, body, _ = self.request(path)
                    self.assertEqual(status, 200)
                    result = json.loads(body)[field]
                    document = result[0] if isinstance(result, list) else result
                    self.assertEqual(document["orientation"], expected)
                self.assertEqual(json.loads(self.request("/v1/state")[1])["package"], p)
                bad = copy.deepcopy(p)
                bad["notebooks"][0]["orientation"] = "sideways"
                self.assertEqual(self.request("/v1/state", {"baseRevision": revision + 1, "package": bad})[0], 400)
                self.assertEqual(json.loads(self.request("/v1/state")[1])["package"], p)


if __name__ == "__main__":
    unittest.main()
