import base64
import io
import json
from pathlib import Path
import sqlite3
import struct
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import zipfile
import zlib
from uuid import uuid4
from server import Database, make_server, canonical
from backup import export, restore_package
from test_server import package


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\xff\xff\xff")) + chunk(b"IEND", b"")


def images(p):
    return {f'{b["id"]}/{page["id"]}': {"head": page.get("head"), "width": 1, "height": 1,
        "strokeCount": 1, "inkTypes": ["com.apple.ink.pen"], "png": base64.b64encode(png()).decode()}
        for b in p["notebooks"] for page in b["pages"] + b["deleted"]}


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state.sqlite3"
        self.db = Database(self.path)

    def tearDown(self):
        self.temp.cleanup()

    def test_compact_revisions_reuse_objects_and_keep_exact_data(self):
        p = package()
        self.db.commit(0, p, images(p))
        p["notebooks"][0]["name"] = "Changed metadata only"
        self.db.commit(1, p, images(p))
        with self.db.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM objects").fetchone()[0], 2)
            self.assertTrue(db.execute("SELECT package FROM revisions LIMIT 1").fetchone()[0].startswith(Database.MAGIC))
        self.assertEqual(self.db.latest()["package"], p)
        with self.assertRaises(LookupError):
            self.db.latest(1)
        self.assertEqual(Database(self.path).latest()["package"], p)

    def test_legacy_database_migrates_without_changing_revision_or_digest(self):
        legacy = Path(self.temp.name) / "legacy.sqlite3"
        p = package()
        with sqlite3.connect(legacy) as db:
            db.execute("CREATE TABLE revisions (revision INTEGER PRIMARY KEY, digest TEXT NOT NULL, package BLOB NOT NULL, created TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
            db.execute("INSERT INTO revisions(revision,digest,package) VALUES(1,'original-digest',?)", (canonical(p),))
        restored = Database(legacy)
        self.assertEqual(restored.latest(), {"revision": 1, "package": p})
        with restored.connect() as db:
            self.assertEqual(db.execute("SELECT digest FROM revisions").fetchone()[0], "original-digest")

    def test_bad_images_cannot_commit_notes(self):
        p = package()
        self.db.commit(0, p, images(p))
        for field, value in [("head", str(uuid4()).upper()), ("width", 2), ("png", "bad"), ("strokeCount", -1)]:
            preview = images(p)
            preview[next(iter(preview))][field] = value
            with self.assertRaises((ValueError, KeyError)):
                self.db.commit(1, p, preview)
        self.assertEqual(self.db.latest()["revision"], 1)
        with self.assertRaises(ValueError):
            self.db.commit(1, p, {})

    def test_invalid_tag_counts_cannot_commit_notes_or_replace_images(self):
        p = package()
        preview = images(p)
        key = next(iter(preview))
        preview[key]["tagStrokeCounts"] = {"question": 1}
        self.db.commit(0, p, preview)
        original_metadata = self.db.image_metadata(1)
        for counts in [[], ["question"], "question", 1, True,
                       {"question": 0}, {"question": -1}, {"question": 2},
                       {"question": 1.0}, {"question": True}, {"question": False},
                       {"question": "1"}, {"question": None}, {"question": []},
                       {"unknown": 1}, {"Question": 1}, {"question": 1, "unknown": 1}]:
            for changed_source in (False, True):
                with self.subTest(counts=counts, changed_source=changed_source):
                    p["notebooks"][0]["name"] = "Changed" if changed_source else "Test"
                    bad = images(p)
                    bad[key]["tagStrokeCounts"] = counts
                    with self.assertRaises(ValueError):
                        self.db.commit(1, p, bad)
                    self.assertEqual(self.db.latest()["revision"], 1)
                    self.assertEqual(self.db.latest()["package"]["notebooks"][0]["name"], "Test")
                    self.assertEqual(self.db.image_metadata(1), original_metadata)

    def test_legacy_null_empty_and_positive_tag_metadata_retained_exactly(self):
        p = package()
        for counts in ("absent", None, {}, {"question": 1}, {"question": 3}):
            with self.subTest(counts=counts):
                preview = images(p)
                key = next(iter(preview))
                preview[key]["strokeCount"] = 3 if counts else 0
                if counts != "absent":
                    preview[key]["tagStrokeCounts"] = counts
                self.assertEqual(self.db.commit(0, p, preview), 1)
                self.assertEqual(self.db.image_metadata(1)[key],
                                 {k: v for k, v in preview[key].items() if k != "png"})

    def test_tag_backup_roundtrip_and_recolor_clears_without_source_revision(self):
        p = package()
        preview = images(p)
        key = next(iter(preview))
        preview[key]["tagStrokeCounts"] = {"question": 1}
        self.db.commit(0, p, preview)
        root = Path(self.temp.name) / "tag-backup"
        self.assertTrue(export(self.db, root))
        manifest = json.loads((root / "manifest.json").read_bytes())
        self.assertEqual(manifest["images"][key]["tagStrokeCounts"], {"question": 1})
        restored_images = {k: {field: value for field, value in image.items() if field not in ("file", "paper")} |
                          {"png": base64.b64encode((root / image["file"]).read_bytes()).decode()}
                          for k, image in manifest["images"].items()}
        restored = Database(Path(self.temp.name) / "restored.sqlite3")
        restored.commit(0, restore_package(root), restored_images)
        self.assertEqual(restored.image_metadata(1), self.db.image_metadata(1))
        with self.db.connect() as db:
            source_digest = db.execute("SELECT digest FROM revisions").fetchone()[0]
        # Simulate recoloring via refreshed image metadata, with unchanged source.
        preview[key]["tagStrokeCounts"] = {}
        self.assertEqual(self.db.commit(0, p, preview), 1)
        self.assertEqual(self.db.latest(), {"revision": 1, "package": p})
        self.assertEqual(self.db.image_metadata(1)[key]["tagStrokeCounts"], {})
        with self.db.connect() as db:
            self.assertEqual(db.execute("SELECT revision,digest FROM revisions").fetchall(), [(1, source_digest)])
        self.assertTrue(export(self.db, root))
        self.assertEqual(json.loads((root / "manifest.json").read_bytes())["images"][key]["tagStrokeCounts"], {})
        self.assertFalse(export(self.db, root))

    def test_retry_can_add_images_without_new_note_revision(self):
        p = package()
        self.db.commit(0, p)
        self.assertFalse(self.db.image_metadata(1))
        self.assertEqual(self.db.commit(0, p, images(p)), 1)
        self.assertEqual(self.db.image(1, next(iter(images(p)))), png())

    def test_backup_is_reconstructable_includes_png_and_reuses_objects(self):
        p = package()
        self.db.commit(0, p, images(p))
        root = Path(self.temp.name) / "backup"
        self.assertTrue(export(self.db, root))
        self.assertFalse(export(self.db, root))
        self.assertEqual(restore_package(root), p)
        manifest = json.loads((root / "manifest.json").read_bytes())
        image = next(iter(manifest["images"].values()))
        self.assertEqual((root / image["file"]).read_bytes(), png())
        p["notebooks"][0]["name"] = "Renamed"
        self.db.commit(1, p, images(p))
        export(self.db, root)
        self.assertEqual(len(list((root / "objects").iterdir())), 2)
        self.assertEqual(restore_package(root), p)
        snapshot = next((root / "objects").glob("*.pkdraw"))
        snapshot.write_bytes(b"bad")
        with self.assertRaises(ValueError):
            restore_package(root)

    def test_http_documents_png_spans_auth_and_revision_pinning(self):
        p = package()
        b = p["notebooks"][0]
        for _ in range(3):
            b["pages"].append({"id": str(uuid4()).upper(), "background": 0, "starred": False, "nodes": []})
        b["deleted"].append({"id": str(uuid4()).upper(), "background": 0, "starred": False, "nodes": []})
        preview = images(p)
        preview[f'{b["id"]}/{b["pages"][0]["id"]}']["tagStrokeCounts"] = {"question": 1}
        preview[f'{b["id"]}/{b["pages"][1]["id"]}']["tagStrokeCounts"] = {}
        preview[f'{b["id"]}/{b["pages"][2]["id"]}']["tagStrokeCounts"] = None
        preview[f'{b["id"]}/{b["deleted"][0]["id"]}']["tagStrokeCounts"] = {"question": 1}
        self.db.commit(0, p, preview)
        server = make_server(self.path, "test-token", 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        origin = f"http://127.0.0.1:{server.server_port}"
        def get(path, token="test-token"):
            req = urllib.request.Request(origin + path, headers={"Authorization": "Bearer " + token})
            try:
                with urllib.request.urlopen(req) as r: return r.status, r.read(), r.headers["Content-Type"]
            except urllib.error.HTTPError as e: return e.code, e.read(), e.headers["Content-Type"]
        try:
            self.assertEqual(get("/draw-sync/v1/documents", "bad")[0], 401)
            listing = json.loads(get("/draw-sync/v1/documents")[1])
            self.assertEqual(listing["documents"][0]["pageCount"], 4)
            base = "/v1/documents/" + b["id"]
            metadata = json.loads(get(base)[1])
            self.assertEqual([page["tags"] for page in metadata["pages"]], [["question"], [], None, None])
            self.assertEqual(metadata["deleted"][0]["tags"], ["question"])
            self.assertEqual(metadata["pages"][0]["image"]["tagStrokeCounts"], {"question": 1})
            self.assertNotIn("tagStrokeCounts", metadata["pages"][3]["image"])
            self.assertEqual(metadata["pages"][0]["historyCount"], 1)
            self.assertEqual(metadata["pages"][0]["imagePaper"], "lines")
            self.assertEqual(get(metadata["pages"][0]["png"])[1:], (png(), "image/png"))
            result = get(base + "/pages.zip?start=1&end=2")
            with zipfile.ZipFile(io.BytesIO(result[1])) as archive:
                self.assertEqual(len(archive.namelist()), 2)
                self.assertEqual(archive.read(archive.namelist()[0]), png())
            self.assertEqual(get(base + "/pages.zip?start=0&end=2")[0], 400)
            b["name"] = "New revision without cached image"
            self.db.commit(1, p)
            self.assertEqual(get(metadata["pages"][0]["png"])[0], 404)
            self.assertEqual(get(base + "?revision=1")[0], 404)
            latest = json.loads(get(base)[1])
            self.assertEqual(latest["revision"], 2)
            self.assertTrue(all(page["tags"] is None for page in latest["pages"] + latest["deleted"]))
            self.assertTrue(all(page["image"] is None for page in latest["pages"] + latest["deleted"]))
            self.assertEqual(get(base + f'/pages/{b["pages"][0]["id"]}.png')[0], 404)
            self.assertEqual(self.db.commit(2, p, preview), 2)
            preview[f'{b["id"]}/{b["pages"][0]["id"]}']["tagStrokeCounts"] = {}
            self.assertEqual(self.db.commit(2, p, preview), 2)
            self.assertEqual(json.loads(get(base)[1])["pages"][0]["tags"], [])
            self.assertEqual(get(base + "?revision=1")[0], 404)
            self.assertEqual(get(base + "?revision=99")[0], 404)
            self.assertEqual(get("/v1/documents/bad")[0], 400)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
