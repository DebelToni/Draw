"""Current-only maintenance and publication use temporary databases exclusively."""
import base64
import copy
import json
from pathlib import Path
import sqlite3
import tempfile
import zlib
import threading
import unittest
from unittest.mock import patch
from uuid import uuid4

import backup
from backup import export, restore_package, restore_scenes
from portable import RENDERER_VERSION
from server import (Conflict, Database, canonical, current_projection,
                    validate, validate_current_only)
from test_images import images, png
import test_incremental
from test_incremental import scene, sha
from test_server import package


def history_package():
    p = package()
    book = p["notebooks"][0]
    fid = str(uuid4()).upper()
    p["folders"] = [{"id": fid, "name": "School"}, {"id": str(uuid4()).upper(), "name": "Empty"}]
    book["folderID"] = fid
    root = copy.deepcopy(book["pages"][0])
    book["pages"] = []
    for index in range(65):
        page = copy.deepcopy(root)
        page["id"] = str(uuid4()).upper()
        ancestor, head, redo = [str(uuid4()).upper() for _ in range(3)]
        page.update(background=index % 4, starred=bool(index % 2), head=head, preferredRoot=ancestor,
                    nodes=[{"id": ancestor, "children": [head], "preferredChild": head},
                           {"id": head, "parent": ancestor, "children": [redo], "preferredChild": redo},
                           {"id": redo, "parent": head, "children": []}])
        if index % 11 == 0:
            page.pop("head")  # Blank is authoritative even with retained redo history.
        (book["pages"] if index < 61 else book["deleted"]).append(page)
    book["currentPage"] = book["pages"][3]["id"]
    p["blobs"] = {f'{book["id"]}/{page["id"]}/{node["id"]}':
                  base64.b64encode(f'native {index}/{i}'.encode()).decode()
                  for index, page in enumerate(book["pages"] + book["deleted"])
                  for i, node in enumerate(page["nodes"])}
    validate(p)
    return p


class CurrentOnlyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state.sqlite3"
        self.db = Database(self.path)

    def tearDown(self):
        self.temp.cleanup()

    def snapshot(self):
        with self.db.connect() as db:
            return {table: sorted(db.execute(f"SELECT * FROM {table}").fetchall())
                    for table in ("revisions", "objects", "images", "scenes", "staged_objects")}

    def seed(self, p, raw=False, previews=True):
        """Model an existing legacy store, never pass history through upload APIs."""
        old = package()
        old["blobs"] = {k: base64.b64encode(b"old source only").decode() for k in old["blobs"]}
        with self.db.connect() as db:
            db.execute("INSERT INTO revisions(revision,digest,package) VALUES(5,?,?)",
                       (sha(canonical(old)), self.db.pack(db, old)))
            db.execute("INSERT INTO revisions(revision,digest,package) VALUES(7,?,?)",
                       (sha(canonical(p)), canonical(p) if raw else self.db.pack(db, p)))
            old_key = next(iter(images(old)))
            db.execute("INSERT INTO images VALUES(5,?,?,?)",
                       (old_key, canonical(next(iter(images(old).values())) | {"png": "unused"}),
                        self.db.put_object(db, b"old PNG only")))
            db.execute("INSERT INTO scenes VALUES(5,?,?)", (old_key, self.db.put_object(db, b"old scene only")))
            if previews:
                preview = images(p)
                keys = list(preview)
                for key in keys[:61]:
                    metadata = {k: v for k, v in preview[key].items() if k != "png"}
                    metadata.update(rendererVersion=RENDERER_VERSION, tagStrokeCounts={"question": 1}, extra="keep exactly")
                    db.execute("INSERT INTO images VALUES(7,?,?,?)", (key, canonical(metadata), self.db.put_object(db, png())))
                book = p["notebooks"][0]
                for page in book["pages"] + book["deleted"]:
                    key = f'{book["id"]}/{page["id"]}'
                    data = json.dumps(scene(page), indent=3).encode()
                    db.execute("INSERT INTO scenes VALUES(7,?,?)", (key, self.db.put_object(db, data)))
            self.db.put_object(db, b"unreferenced old CAS")
        self.db.upload_object(sha(b"unfinished upload"), b"unfinished upload")

    def assert_live_objects_only(self, revision):
        refs = set(self.db.manifest_state()["manifest"]["blobs"].values())
        refs.update(self.db.scene_refs(revision).values())
        with self.db.connect() as db:
            refs.update(row[0] for row in db.execute("SELECT digest FROM images WHERE revision=?", (revision,)))
            self.assertEqual({row[0] for row in db.execute("SELECT digest FROM objects")}, refs)
            self.assertEqual(db.execute("SELECT revision FROM revisions").fetchall(), [(revision,)])
            self.assertEqual(db.execute("SELECT count(*) FROM staged_objects").fetchone()[0], 0)

    def test_explicit_migration_preserves_native_heads_folders_and_exact_61_65_refs(self):
        p = history_package()
        self.seed(p)
        before = self.snapshot()
        native = current_projection(p)
        metadata = self.db.image_metadata(7)
        scenes = self.db.scene_refs(7)
        scene_bytes = {key: self.db.object(digest) for key, digest in scenes.items()}
        old_digests = {row[0] for row in before["objects"]}
        self.assertEqual(self.db.migrate_current_only(), 8)
        self.assertEqual(self.db.latest(), {"revision": 8, "package": native})
        validate_current_only(native)
        recovered = self.db.latest()["package"]
        self.assertEqual(recovered["folders"], p["folders"])
        for original_book, recovered_book in zip(p["notebooks"], recovered["notebooks"]):
            self.assertEqual({k: v for k, v in recovered_book.items() if k not in ("pages", "deleted")},
                             {k: v for k, v in original_book.items() if k not in ("pages", "deleted")})
            for original_page, recovered_page in zip(original_book["pages"] + original_book["deleted"],
                                                     recovered_book["pages"] + recovered_book["deleted"]):
                self.assertEqual({k: v for k, v in recovered_page.items() if k not in ("nodes", "preferredRoot")},
                                 {k: v for k, v in original_page.items() if k not in ("nodes", "preferredRoot")})
                head = original_page.get("head")
                if head is not None:
                    key = f'{original_book["id"]}/{original_page["id"]}/{head}'
                    self.assertEqual(base64.b64decode(recovered["blobs"][key]), base64.b64decode(p["blobs"][key]))
                else:
                    self.assertEqual(recovered_page["nodes"], [])
        self.assertEqual(self.db.image_metadata(8), metadata)
        self.assertEqual(len(metadata), 61)
        for key in metadata:
            self.assertEqual(self.db.image(8, key), png())
        self.assertEqual(self.db.scene_refs(8), scenes)
        self.assertEqual(len(scenes), 65)
        self.assertEqual({key: self.db.object(digest) for key, digest in scenes.items()}, scene_bytes)
        self.assertEqual(self.db.image_metadata(7), {})
        self.assertEqual(self.db.scene_refs(7), {})
        with self.assertRaises(LookupError):
            self.db.latest(7)
        self.assert_live_objects_only(8)
        remaining = {row[0] for row in self.snapshot()["objects"]}
        for digest in old_digests - remaining:
            with self.assertRaises(LookupError):
                self.db.object(digest)
        migrated = self.snapshot()
        self.assertEqual(self.db.migrate_current_only(), 8)
        self.assertEqual(self.snapshot(), migrated)
        root = Path(self.temp.name) / "backup"
        self.assertTrue(export(self.db, root))
        self.assertEqual(restore_package(root), native)
        self.assertEqual(restore_scenes(root), scene_bytes)
        manifest = json.loads((root / "manifest.json").read_bytes())
        self.assertEqual(set(manifest["images"]), set(metadata))
        self.assertEqual(set(manifest["scenes"]), set(scenes))

    def test_migrated_cache_reused_only_missing_latest_pages_render(self):
        p = history_package()
        self.seed(p)
        self.db.migrate_current_only()
        metadata = self.db.image_metadata(8)
        manifest = self.db.manifest_state()["manifest"]
        scenes = self.db.scene_refs(8)
        with test_incremental.renderer() as module:
            with patch.object(module, "render_page", wraps=module.render_page) as render:
                self.assertEqual(self.db.commit_manifest(8, manifest, scenes), 8)
                self.assertEqual(render.call_count, 4)
                self.assertEqual(self.db.commit_manifest(0, manifest, scenes), 8)
                self.assertEqual(render.call_count, 4)
        refreshed = self.db.image_metadata(8)
        self.assertEqual(len(refreshed), 65)
        self.assertEqual({key: refreshed[key] for key in metadata}, metadata)
        self.assert_live_objects_only(8)

    def test_constructor_does_not_convert_or_prune_legacy_recovery(self):
        p = history_package()
        self.seed(p, raw=True)
        before = self.snapshot()
        reopened = Database(self.path)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(reopened.latest(7)["package"], p)
        self.assertEqual(reopened.latest(5)["revision"], 5)
        self.assertEqual(reopened.migrate_current_only(), 8)
        self.assertEqual(reopened.latest()["package"], current_projection(p))
        self.assert_live_objects_only(8)

    def test_blank_head_ignores_unusable_unused_history_and_blob(self):
        for raw in (False, True):
            with self.subTest(raw=raw):
                p = package()
                page = p["notebooks"][0]["pages"][0]
                page.pop("head")
                page["preferredRoot"] = "invalid unused root"
                self.seed(p, raw=raw, previews=False)
                with self.db.connect() as db:
                    if raw:
                        damaged = copy.deepcopy(p)
                        damaged["blobs"] = {key: "not base64" for key in p["blobs"]}
                        db.execute("UPDATE revisions SET package=? WHERE revision=7", (canonical(damaged),))
                    else:
                        db.execute("UPDATE objects SET data=? WHERE digest=?", (b"not compressed", sha(base64.b64decode(next(iter(p["blobs"].values()))))))
                self.assertEqual(self.db.migrate_current_only(), 8)
                self.assertEqual(self.db.latest()["package"]["blobs"], {})
                self.assertEqual(self.db.latest()["package"]["notebooks"][0]["pages"][0]["nodes"], [])
                self.assert_live_objects_only(8)
                with self.db.connect() as db:
                    for table in ("revisions", "objects", "images", "scenes", "staged_objects"):
                        db.execute(f"DELETE FROM {table}")

    def test_invalid_current_heads_and_missing_current_bytes_fail_before_mutation(self):
        p = history_package()
        self.seed(p)
        with self.db.connect() as db:
            stored = db.execute("SELECT package FROM revisions WHERE revision=7").fetchone()[0]
        for mutation in ("unknown", "duplicate", "missing", "corrupt"):
            with self.subTest(mutation=mutation):
                with self.db.connect() as db:
                    db.execute("UPDATE revisions SET package=? WHERE revision=7", (stored,))
                    manifest = self.db.source_manifest(stored)
                    page = manifest["notebooks"][0]["pages"][1]
                    key = f'{manifest["notebooks"][0]["id"]}/{page["id"]}/{page["head"]}'
                    if mutation == "unknown":
                        page["head"] = str(uuid4()).upper()
                    elif mutation == "duplicate":
                        page["nodes"].append(copy.deepcopy(page["nodes"][1]))
                    else:
                        manifest["blobs"][key] = "0" * 64
                        if mutation == "corrupt":
                            db.execute("INSERT INTO objects VALUES(?,?)", ("0" * 64, b"bad"))
                    packed = {"package": {k: v for k, v in manifest.items() if k != "blobs"}, "blobs": manifest["blobs"]}
                    db.execute("UPDATE revisions SET package=? WHERE revision=7", (Database.MAGIC + zlib.compress(canonical(packed)),))
                before = self.snapshot()
                with patch.object(self.db, "pack", side_effect=AssertionError("must not publish")):
                    with self.assertRaises((ValueError, LookupError)):
                        self.db.migrate_current_only()
                self.assertEqual(self.snapshot(), before)

    def test_migration_publication_and_gc_failures_rollback(self):
        self.seed(history_package())
        before = self.snapshot()
        for table, action in (("scenes", "INSERT"), ("revisions", "DELETE"), ("objects", "DELETE")):
            with self.subTest(table=table):
                with self.db.connect() as db:
                    db.execute(f"CREATE TRIGGER fail BEFORE {action} ON {table} BEGIN SELECT RAISE(ABORT, 'fail'); END")
                with self.assertRaises(sqlite3.Error):
                    self.db.migrate_current_only()
                self.assertEqual(self.snapshot(), before)
                with self.db.connect() as db:
                    db.execute("DROP TRIGGER fail")

    def test_migration_discards_mismatched_latest_previews_without_using_old_cache(self):
        p = package()
        self.seed(p)
        key = next(iter(images(p)))
        wrong_head = str(uuid4()).upper()
        with self.db.connect() as db:
            metadata = self.db.image_metadata(7, db=db)[key] | {"head": wrong_head}
            db.execute("UPDATE images SET metadata=? WHERE revision=7", (canonical(metadata),))
            scene_digest = self.db.put_object(db, canonical({"head": wrong_head}))
            db.execute("UPDATE scenes SET digest=? WHERE revision=7", (scene_digest,))
        self.assertEqual(self.db.migrate_current_only(), 8)
        self.assertEqual(self.db.latest()["package"]["blobs"], p["blobs"])
        self.assertEqual(self.db.image_metadata(8), {})
        self.assertEqual(self.db.scene_refs(8), {})
        self.assert_live_objects_only(8)

    def test_migration_current_source_retains_counter_and_empty_database_gc(self):
        p = package()
        p["notebooks"][0]["pages"][0]["preferredRoot"] = p["notebooks"][0]["pages"][0]["head"]
        self.seed(p, raw=True, previews=False)
        self.assertEqual(self.db.migrate_current_only(), 7)
        self.assert_live_objects_only(7)
        other = Database(Path(self.temp.name) / "empty.sqlite3")
        other.upload_object(sha(b"staged"), b"staged")
        self.assertEqual(other.migrate_current_only(), 0)
        with self.assertRaises(LookupError):
            other.object(sha(b"staged"))
        self.assertEqual(other.commit(0, package()), 1)

    def test_historical_uploads_rejected_before_object_read_or_publication(self):
        p = history_package()
        validate(p)  # Recovery validation deliberately remains history-capable.
        before = self.snapshot()
        with patch.object(self.db, "put_object", side_effect=AssertionError("must not publish")):
            with self.assertRaises(ValueError):
                self.db.commit(0, p)
        manifest = p | {"blobs": {key: "0" * 64 for key in p["blobs"]}}
        with patch.object(self.db, "object", side_effect=AssertionError("must not read")):
            with self.assertRaises(ValueError):
                self.db.commit_manifest(0, manifest, {})
        self.assertEqual(self.snapshot(), before)
        blank = package()
        blank["notebooks"][0]["pages"][0].pop("head")
        with self.assertRaises(ValueError):
            self.db.commit(0, blank)

    def test_unchanged_commit_gc_protects_pending_upload_then_prunes_superseded_native(self):
        p = package()
        self.db.commit(0, p)
        pending = b"new pending native"
        digest = self.db.upload_object(sha(pending), pending)
        with self.db.connect() as db:
            orphan = self.db.put_object(db, b"obsolete unreferenced object")
        self.assertEqual(self.db.commit(0, p), 1)
        self.assertEqual(self.db.object(digest), pending)
        with self.assertRaises(LookupError):
            self.db.object(orphan)
        changed = copy.deepcopy(p)
        key = next(iter(changed["blobs"]))
        changed["blobs"][key] = base64.b64encode(pending).decode()
        with self.assertRaises(Conflict):
            self.db.commit(0, changed)
        self.assertEqual(self.db.object(digest), pending)
        self.assertEqual(self.db.commit(1, changed), 2)
        self.assert_live_objects_only(2)
        with self.assertRaises(LookupError):
            self.db.object(sha(base64.b64decode(p["blobs"][key])))
        changed["notebooks"][0]["name"] = "third"
        self.assertEqual(self.db.commit(2, changed), 3)
        self.assert_live_objects_only(3)

    def test_upload_in_progress_survives_other_successful_writer(self):
        p = package()
        self.db.commit(0, p)
        ready, resume = threading.Event(), threading.Event()
        pending = b"concurrent upload native"
        errors = []
        def uploader():
            try:
                self.db.upload_object(sha(pending), pending)
                ready.set()
                resume.wait(5)
                changed = copy.deepcopy(p)
                changed["blobs"] = {key: base64.b64encode(pending).decode() for key in p["blobs"]}
                self.db.commit(1, changed)
            except Exception as error:
                errors.append(error)
        thread = threading.Thread(target=uploader)
        thread.start()
        try:
            self.assertTrue(ready.wait(5))
            changed = copy.deepcopy(p)
            changed["notebooks"][0]["name"] = "other writer"
            self.db.commit(1, changed)
        finally:
            resume.set()
            thread.join()
        self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], Conflict)
        self.assertEqual(self.db.object(sha(pending)), pending)

    def test_expired_staging_only_deletes_noncurrent_native_png_scene_objects(self):
        p = package()
        source = base64.b64decode(next(iter(p["blobs"].values())))
        source_digest = self.db.upload_object(sha(source), source)
        page = p["notebooks"][0]["pages"][0]
        key = next(iter(images(p)))
        scene_data = canonical(scene(page))
        scene_digest = self.db.upload_object(sha(scene_data), scene_data)
        manifest = p | {"blobs": {key: source_digest for key in p["blobs"]}}
        with test_incremental.renderer():
            self.db.commit_manifest(0, manifest, {key: scene_digest})
        current = {source_digest: source, scene_digest: scene_data,
                   sha(self.db.image(1, key)): self.db.image(1, key)}
        # Referenced objects may have old staging markers from duplicate uploads.
        for digest, data in current.items():
            self.db.upload_object(digest, data)
        old = self.db.upload_object(sha(b"expired pending"), b"expired pending")
        with self.db.connect() as db:
            db.execute("UPDATE staged_objects SET uploaded=CAST(strftime('%s','now') AS INTEGER)-90000")
        boundary = self.db.upload_object(sha(b"24h pending"), b"24h pending")
        recent = self.db.upload_object(sha(b"23h pending"), b"23h pending")
        with self.db.connect() as db:
            db.execute("UPDATE staged_objects SET uploaded=CAST(strftime('%s','now') AS INTEGER)-86400 WHERE digest=?", (boundary,))
            db.execute("UPDATE staged_objects SET uploaded=CAST(strftime('%s','now') AS INTEGER)-82800 WHERE digest=?", (recent,))
        before = self.snapshot()
        self.assertEqual(self.db.discard_expired_staging(), 2)
        after = self.snapshot()
        for table in ("revisions", "images", "scenes"):
            self.assertEqual(after[table], before[table])
        for digest, data in current.items():
            self.assertEqual(self.db.object(digest), data)
        for digest in (old, boundary):
            with self.assertRaises(LookupError):
                self.db.object(digest)
        self.assertEqual(self.db.object(recent), b"23h pending")
        self.assertEqual([row[0] for row in after["staged_objects"]], [recent])
        self.assertEqual(self.db.discard_expired_staging(), 0)

    def test_repeated_upload_refreshes_staging_timestamp(self):
        data = b"repeated pending upload"
        digest = self.db.upload_object(sha(data), data)
        with self.db.connect() as db:
            db.execute("UPDATE staged_objects SET uploaded=CAST(strftime('%s','now') AS INTEGER)-90000")
            old = db.execute("SELECT uploaded FROM staged_objects WHERE digest=?", (digest,)).fetchone()[0]
        self.db.upload_object(digest, data)
        with self.db.connect() as db:
            refreshed = db.execute("SELECT uploaded FROM staged_objects WHERE digest=?", (digest,)).fetchone()[0]
        self.assertGreater(refreshed, old)
        self.assertEqual(self.db.discard_expired_staging(), 0)
        self.assertEqual(self.db.object(digest), data)

    def test_commit_gc_expires_old_staging_but_failed_commit_preserves_recent(self):
        p = package()
        self.db.commit(0, p, images(p))
        old = self.db.upload_object(sha(b"old pending"), b"old pending")
        with self.db.connect() as db:
            db.execute("UPDATE staged_objects SET uploaded=CAST(strftime('%s','now') AS INTEGER)-90000")
        recent = self.db.upload_object(sha(b"recent pending"), b"recent pending")
        before = self.snapshot()
        with self.db.connect() as db:
            db.execute("CREATE TRIGGER fail_gc BEFORE DELETE ON objects BEGIN SELECT RAISE(ABORT, 'failed gc'); END")
        with self.assertRaises(sqlite3.Error):
            self.db.commit(0, p)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.db.object(recent), b"recent pending")
        with self.db.connect() as db:
            db.execute("DROP TRIGGER fail_gc")
        self.assertEqual(self.db.commit(0, p), 1)
        with self.assertRaises(LookupError):
            self.db.object(old)
        self.assertEqual(self.db.object(recent), b"recent pending")
        self.assertEqual(self.db.latest(), {"revision": 1, "package": p})
        self.assertEqual(self.db.image(1, next(iter(images(p)))), png())

    def test_staging_housekeeping_failure_rolls_back_objects_and_markers(self):
        data = b"expired upload"
        digest = self.db.upload_object(sha(data), data)
        with self.db.connect() as db:
            db.execute("UPDATE staged_objects SET uploaded=CAST(strftime('%s','now') AS INTEGER)-90000")
            db.execute("CREATE TRIGGER fail_staging BEFORE DELETE ON staged_objects BEGIN SELECT RAISE(ABORT, 'fail'); END")
        before = self.snapshot()
        with self.assertRaises(sqlite3.Error):
            self.db.discard_expired_staging()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.db.object(digest), data)

    def test_staging_housekeeping_never_migrates_legacy_history_or_prunes_old_refs(self):
        p = history_package()
        self.seed(p)
        with self.db.connect() as db:
            # Even expired markers on old published states must not invoke an
            # implicit native-history migration before verified recovery.
            db.execute("INSERT OR REPLACE INTO staged_objects(digest,uploaded) "
                       "SELECT digest,CAST(strftime('%s','now') AS INTEGER)-90000 FROM objects")
        before = self.snapshot()
        self.assertEqual(self.db.discard_expired_staging(), 2)
        after = self.snapshot()
        for table in ("revisions", "images", "scenes"):
            self.assertEqual(after[table], before[table])
        self.assertEqual(self.db.latest(7)["package"], p)
        self.assertEqual(self.db.latest(5)["revision"], 5)
        with self.assertRaises(ValueError):
            export(self.db, Path(self.temp.name) / "not-migrated")

    def test_old_staging_schema_adds_timestamp_without_pruning_on_startup(self):
        data = b"existing untimestamped upload"
        self.db.upload_object(sha(data), data)
        with self.db.connect() as db:
            db.execute("DROP TABLE staged_objects")
            db.execute("CREATE TABLE staged_objects(digest TEXT PRIMARY KEY)")
            db.execute("INSERT INTO staged_objects VALUES(?)", (sha(data),))
        before = self.snapshot()
        reopened = Database(self.path)
        after = self.snapshot()
        for table in ("revisions", "objects", "images", "scenes"):
            self.assertEqual(after[table], before[table])
        self.assertEqual(len(after["staged_objects"][0]), 2)
        self.assertGreater(after["staged_objects"][0][1], 0)
        self.assertEqual(reopened.discard_expired_staging(), 0)
        self.assertEqual(reopened.object(sha(data)), data)
        Database(self.path)
        self.assertEqual(self.snapshot(), after)

    def test_backup_job_expires_staging_before_separate_read_snapshot(self):
        p = package()
        self.db.commit(0, p, images(p))
        data = b"old backup housekeeping upload"
        digest = self.db.upload_object(sha(data), data)
        with self.db.connect() as db:
            db.execute("UPDATE staged_objects SET uploaded=CAST(strftime('%s','now') AS INTEGER)-90000")
        root = Path(self.temp.name) / "backup-job"
        (root / ".git").mkdir(parents=True)
        def checked_export(database, output):
            with self.assertRaises(LookupError):
                database.object(digest)
            return export(database, output)
        with patch("backup.Database", return_value=self.db), patch("backup.publish_current") as publishing, \
                patch("backup.export", side_effect=checked_export) as exporting, \
                patch.object(self.db, "migrate_current_only", side_effect=AssertionError("migration must remain explicit")), \
                patch("sys.argv", ["backup.py"]), patch("builtins.print"), \
                patch.dict("os.environ", {"DRAW_SYNC_BACKUP_REPO": str(root), "DRAW_SYNC_STATE": self.temp.name}):
            backup.main()
        exporting.assert_called_once_with(self.db, root)
        publishing.assert_called_once_with(root)
        self.assertEqual(restore_package(root), p)

    def test_backup_requires_migration_and_removes_obsolete_files_even_unchanged(self):
        p = history_package()
        self.seed(p)
        root = Path(self.temp.name) / "backup"
        with self.assertRaises(ValueError):
            export(self.db, root)
        self.assertFalse(root.exists())
        # Legacy backups still provide recovery without the new upload guard.
        root.mkdir()
        objects = root / "objects"
        objects.mkdir()
        refs = {}
        for key, encoded in p["blobs"].items():
            data = base64.b64decode(encoded)
            relative = "objects/" + sha(data) + ".pkdraw"
            (root / relative).write_bytes(data)
            refs[key] = relative
        (root / "manifest.json").write_bytes(canonical({"package": {k: v for k, v in p.items() if k != "blobs"}, "blobs": refs}))
        self.assertEqual(restore_package(root), p)
        self.db.migrate_current_only()
        self.assertTrue(export(self.db, root))
        self.assertEqual(restore_package(root), current_projection(p))
        manifest = json.loads((root / "manifest.json").read_bytes())
        retained = set(manifest["blobs"].values()) | {v["file"] for v in manifest["images"].values()} | set(manifest["scenes"].values())
        self.assertEqual({"objects/" + f.name for f in objects.iterdir()}, retained)
        self.assertFalse(export(self.db, root))
        obsolete = objects / "unreferenced.pkdraw"
        obsolete.write_bytes(b"old working tree")
        self.assertTrue(export(self.db, root))
        self.assertFalse(obsolete.exists())
        self.assertFalse(export(self.db, root))

    def test_backup_failure_does_not_remove_last_published_recovery(self):
        p = package()
        self.db.commit(0, p, images(p))
        root = Path(self.temp.name) / "backup"
        export(self.db, root)
        original = (root / "manifest.json").read_bytes()
        p["blobs"] = {key: base64.b64encode(b"changed native").decode() for key in p["blobs"]}
        self.db.commit(1, p, images(p))
        with patch("backup.write_object", side_effect=OSError("write failure")):
            with self.assertRaises(OSError):
                export(self.db, root)
        self.assertEqual((root / "manifest.json").read_bytes(), original)
        self.assertNotEqual(restore_package(root), p)
        self.assertTrue(export(self.db, root))
        self.assertEqual(restore_package(root), p)


class CurrentOnlyHTTPTests(unittest.TestCase):
    setUp = test_incremental.IncrementalHTTPTests.setUp
    tearDown = test_incremental.IncrementalHTTPTests.tearDown
    request = test_incremental.IncrementalHTTPTests.request
    def test_history_rejected_and_old_revision_native_scene_png_unavailable(self):
        historical = history_package()
        self.assertEqual(self.request("/v1/state", {"baseRevision": 0, "package": historical})[0], 400)
        manifest = historical | {"blobs": {key: "0" * 64 for key in historical["blobs"]}}
        self.assertEqual(self.request("/v2/state", {"baseRevision": 0, "manifest": manifest, "scenes": {}})[0], 400)
        self.assertEqual(self.server.database.latest()["revision"], 0)
        p = package()
        book = p["notebooks"][0]
        page = book["pages"][0]
        key = f'{book["id"]}/{page["id"]}'
        source = base64.b64decode(next(iter(p["blobs"].values())))
        portable = canonical(scene(page))
        for data in (source, portable):
            self.assertEqual(self.request("/v2/objects/" + sha(data), data)[0], 200)
        manifest = p | {"blobs": {k: sha(source) for k in p["blobs"]}}
        self.assertEqual(self.request("/v2/state", {"baseRevision": 0, "manifest": manifest, "scenes": {key: sha(portable)}})[0], 200)
        old_png_digest = sha(self.server.database.image(1, key))
        p["blobs"] = {k: base64.b64encode(b"replacement source").decode() for k in p["blobs"]}
        self.assertEqual(self.request("/v1/state", {"baseRevision": 1, "package": p})[0], 200)
        for digest in (sha(source), sha(portable), old_png_digest):
            self.assertEqual(self.request("/v2/objects/" + digest)[0], 404)
        self.assertEqual(self.request(f'/v1/documents/{book["id"]}?revision=1')[0], 404)
        self.assertEqual(self.request(f'/v1/documents/{book["id"]}/pages/{page["id"]}.png?revision=1')[0], 404)


if __name__ == "__main__":
    unittest.main()
