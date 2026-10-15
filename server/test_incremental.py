"""Incremental protocol tests use only temporary databases and loopback servers."""
import base64
import copy
from contextlib import contextmanager
import gzip
import hashlib
import importlib
import json
from pathlib import Path
import sqlite3
import socket
import struct
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
from uuid import uuid4
import zlib

import server
from server import Database, Conflict, RenderFailure, canonical, make_server
from backup import export, restore_package, restore_scenes
from test_server import package


def sha(data):
    return hashlib.sha256(data).hexdigest()


def scene(page, width=32):
    value = {"format": 1, "width": width, "height": 36, "strokes": []}
    if page.get("head") is not None:
        value["head"] = page["head"]
    return value


def stroke(ink="com.apple.ink.pen"):
    points = [[x, 12, index * 0.1, 2, 2, 1, 1, 0, 1.57, 1, 0, 0]
              for index, x in enumerate((8, 12, 16))]
    return {"inkType": ink, "color": [0, 0, 0, 1], "transform": [1, 0, 0, 1, 0, 0],
            "randomSeed": 1, "creationDate": 0, "points": points, "samples": points}


def fallback_render(value):
    """Only used while the parent's module is absent, scoped to each new test."""
    if value.get("format") != 1 or not isinstance(value.get("strokes"), list):
        raise ValueError("Invalid test scene")
    width, height = int(value["width"] * 2), int(value["height"] * 2)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
           chunk(b"IDAT", zlib.compress((b"\0" + b"\xff" * width * 3) * height)) + chunk(b"IEND", b""))
    return {"head": value.get("head"), "width": width, "height": height, "strokeCount": len(value["strokes"]),
            "inkTypes": sorted({s["inkType"] for s in value["strokes"]}), "tagStrokeCounts": {}, "rendererVersion": sys.modules["portable"].RENDERER_VERSION}, png


@contextmanager
def renderer():
    try:
        module = importlib.import_module("portable")
    except ModuleNotFoundError as error:
        if error.name != "portable":
            raise
        module = types.ModuleType("portable")
        module.RENDERER_VERSION = 2
        module.render_page = fallback_render
        with patch.dict(sys.modules, {"portable": module}):
            yield module
    else:
        yield module


class IncrementalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "sync.sqlite3"
        self.db = Database(self.path)
        self.render_context = renderer()
        self.renderer = self.render_context.__enter__()
        self.p = package()
        self.manifest, self.scenes = self.upload(self.p)

    def tearDown(self):
        self.render_context.__exit__(None, None, None)
        self.temp.cleanup()

    def upload(self, p, width=32):
        manifest = copy.deepcopy(p)
        manifest["blobs"] = {}
        for key, encoded in p["blobs"].items():
            data = base64.b64decode(encoded)
            manifest["blobs"][key] = self.db.upload_object(sha(data), data)
        scenes = {}
        for b in p["notebooks"]:
            for page in b["pages"] + b["deleted"]:
                # Noncanonical whitespace intentionally tests exact scene bytes.
                data = json.dumps(scene(page, width), indent=2).encode()
                scenes[f'{b["id"]}/{page["id"]}'] = self.db.upload_object(sha(data), data)
        return manifest, scenes

    def commit(self, base=0, manifest=None, scenes=None):
        return self.db.commit_manifest(base, manifest if manifest is not None else self.manifest,
                                       scenes if scenes is not None else self.scenes)

    def counts(self):
        with self.db.connect() as db:
            return tuple(db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
                         for table in ("revisions", "images", "scenes", "objects"))

    def test_empty_state_and_upload_does_not_publish(self):
        self.assertEqual(self.db.manifest_state(), {"revision": 0, "manifest": None})
        self.assertEqual(self.db.latest(), {"revision": 0, "package": None})
        self.assertEqual(self.db.missing_objects(list(self.scenes.values())), [])
        self.assertEqual(self.db.missing_objects(["0" * 64, "0" * 64]), ["0" * 64])
        for digests in (["A" * 64], ["bad"], "bad", [None]):
            with self.assertRaises(ValueError):
                self.db.missing_objects(digests)

    def test_roundtrip_exact_legacy_digest_and_restart(self):
        self.assertEqual(self.commit(), 1)
        reopened = Database(self.path)
        self.assertEqual(reopened.manifest_state(), {"revision": 1, "manifest": self.manifest})
        self.assertEqual(reopened.latest(), {"revision": 1, "package": self.p})
        self.assertEqual(reopened.scene_refs(1), self.scenes)
        with self.db.connect() as db:
            self.assertEqual(db.execute("SELECT digest FROM revisions").fetchone()[0], sha(canonical(self.p)))
        key, digest = next(iter(self.scenes.items()))
        self.assertEqual(sha(reopened.object(digest)), digest)
        self.assertEqual(reopened.image_metadata(1)[key]["rendererVersion"], self.renderer.RENDERER_VERSION)
        self.assertTrue(reopened.image(1, key).startswith(b"\x89PNG"))

    def test_retries_metadata_only_and_legacy_baselines_reuse_renders(self):
        with patch.object(self.renderer, "render_page", wraps=self.renderer.render_page) as render:
            self.commit()
            before = self.counts()
            self.assertEqual(self.commit(), 1)
            self.manifest["notebooks"][0]["name"] = "Renamed"
            self.assertEqual(self.commit(1), 2)
            self.assertEqual(render.call_count, 1)
            self.assertEqual(self.counts()[3], before[3])
            self.assertEqual(self.db.image_metadata(1), {})
            self.assertTrue(self.db.image_metadata(2))
            # v1 digest and baseline remain usable after a v2 write.
            legacy = copy.deepcopy(self.p)
            legacy["notebooks"][0]["name"] = "Renamed"
            self.assertEqual(self.db.commit(0, legacy), 2)
            with self.assertRaises(LookupError):
                self.db.latest(1)

    def test_changed_objects_send_only_new_digests(self):
        self.commit()
        p = copy.deepcopy(self.p)
        key = next(iter(p["blobs"]))
        p["blobs"][key] = base64.b64encode(b"new native archive").decode()
        manifest, scenes = self.upload(p, width=40)
        old = list(self.manifest["blobs"].values()) + list(self.scenes.values())
        self.assertEqual(self.db.missing_objects(old), [])
        with patch.object(self.renderer, "render_page", wraps=self.renderer.render_page) as render:
            self.assertEqual(self.commit(1, manifest, scenes), 2)
            self.assertEqual(render.call_count, 1)
        self.assertEqual(self.db.latest()["package"], p)
        self.assertEqual(self.db.scene_refs(1), {})
        for digest in old:
            with self.assertRaises(LookupError):
                self.db.object(digest)

    def test_nonempty_real_scene_records_and_metadata(self):
        page = self.p["notebooks"][0]["pages"][0]
        value = scene(page) | {"strokes": [stroke(), stroke("com.apple.ink.marker")]}
        data = canonical(value)
        digest = self.db.upload_object(sha(data), data)
        key = next(iter(self.scenes))
        self.assertEqual(self.commit(scenes={key: digest}), 1)
        metadata = self.db.image_metadata(1)[key]
        self.assertEqual(metadata["strokeCount"], 2)
        self.assertEqual(set(metadata["inkTypes"]), {"com.apple.ink.pen", "com.apple.ink.marker"})
        self.assertEqual(self.db.object(digest), data)

    def test_renderer_version_change_rerenders(self):
        self.commit()
        original = self.renderer.render_page
        next_version = self.renderer.RENDERER_VERSION + 1
        def updated(value):
            metadata, png = original(value)
            return metadata | {"rendererVersion": next_version}, png
        with patch.object(self.renderer, "RENDERER_VERSION", next_version), patch.object(self.renderer, "render_page", side_effect=updated) as render:
            self.assertEqual(self.commit(), 1)
            self.assertEqual(render.call_count, 1)
            self.assertEqual(next(iter(self.db.image_metadata(1).values()))["rendererVersion"], next_version)

    def test_version_one_cache_refresh_aliases_teal_without_source_or_png_change(self):
        key = next(iter(self.scenes))
        missed = stroke()
        missed["color"] = [23 / 255, 127 / 255, 113 / 255, 1]
        data = canonical(scene(self.p["notebooks"][0]["pages"][0]) | {"strokes": [missed]})
        scenes = {key: self.db.upload_object(sha(data), data)}
        self.commit(scenes=scenes)
        png = self.db.image(1, key)
        with self.db.connect() as db:
            source = db.execute("SELECT revision,digest,package FROM revisions").fetchall()
            old_metadata = self.db.image_metadata(1, db=db)[key] | {"rendererVersion": 1, "tagStrokeCounts": {}}
            db.execute("UPDATE images SET metadata=? WHERE revision=1 AND page=?", (canonical(old_metadata), key))
        with patch.object(self.renderer, "render_page", wraps=self.renderer.render_page) as render:
            self.assertEqual(self.commit(scenes=scenes), 1)
            self.assertEqual(self.commit(scenes=scenes), 1)
            self.assertEqual(render.call_count, 1)
        metadata = self.db.image_metadata(1)[key]
        self.assertEqual(metadata["rendererVersion"], self.renderer.RENDERER_VERSION)
        self.assertEqual(metadata["tagStrokeCounts"], {"question": 1})
        self.assertEqual(self.db.image(1, key), png)
        self.assertEqual(self.db.scene_refs(1), scenes)
        self.assertEqual(self.db.object(sha(data)), data)
        with self.db.connect() as db:
            self.assertEqual(db.execute("SELECT revision,digest,package FROM revisions").fetchall(), source)

    def test_all_active_deleted_and_empty_pages_required(self):
        p = copy.deepcopy(self.p)
        b = p["notebooks"][0]
        b["deleted"].append({"id": str(uuid4()).upper(), "background": 0, "starred": False, "nodes": []})
        manifest, scenes = self.upload(p)
        missing = dict(scenes)
        del missing[next(reversed(missing))]
        for bad in (missing, scenes | {"extra": next(iter(scenes.values()))}):
            with self.assertRaises(ValueError):
                self.commit(0, manifest, bad)
            self.assertEqual(self.counts()[:3], (0, 0, 0))
        self.assertEqual(self.commit(0, manifest, scenes), 1)
        self.assertEqual(set(self.db.image_metadata(1)), set(scenes))

    def test_missing_objects_bad_heads_invalid_scenes_never_publish(self):
        self.commit()
        original = self.counts()
        missing_manifest = copy.deepcopy(self.manifest)
        missing_manifest["blobs"][next(iter(missing_manifest["blobs"]))] = "0" * 64
        with self.assertRaises(ValueError):
            self.commit(1, missing_manifest)
        with self.assertRaises(ValueError):
            self.commit(1, scenes={next(iter(self.scenes)): "0" * 64})
        page = self.p["notebooks"][0]["pages"][0]
        for value in (scene(page) | {"head": str(uuid4()).upper()}, scene(page) | {"format": 99}, []):
            data = canonical(value)
            self.db.upload_object(sha(data), data)
            with self.assertRaises((ValueError, RenderFailure)):
                self.commit(1, scenes={next(iter(self.scenes)): sha(data)})
            self.assertEqual(self.counts()[:3], original[:3])
            self.assertEqual(self.db.latest()["package"], self.p)
            self.assertEqual(self.db.scene_refs(1), self.scenes)

    def test_render_and_sql_failures_rollback_every_publication(self):
        self.commit()
        p = copy.deepcopy(self.p)
        p["notebooks"][0]["name"] = "Changed"
        manifest, scenes = self.upload(p, width=42)
        original = self.counts()
        metadata = self.db.image_metadata(1)
        with patch.object(self.renderer, "render_page", side_effect=RuntimeError("failed")):
            with self.assertRaises(RenderFailure):
                self.commit(1, manifest, scenes)
        self.assertEqual(self.counts(), original)
        with self.db.connect() as db:
            db.execute("CREATE TRIGGER fail_scene BEFORE INSERT ON scenes BEGIN SELECT RAISE(ABORT, 'failure'); END")
        with self.assertRaises(sqlite3.Error):
            self.commit(1, manifest, scenes)
        self.assertEqual(self.counts(), original)
        self.assertEqual(self.db.image_metadata(1), metadata)
        self.assertEqual(self.db.scene_refs(1), self.scenes)

    def test_final_gc_failure_rolls_back_source_and_same_source_scene_refresh(self):
        self.commit()
        original_metadata = self.db.image_metadata(1)
        original_png = self.db.image(1, next(iter(self.scenes)))
        for source_changed in (False, True):
            with self.subTest(source_changed=source_changed):
                p = copy.deepcopy(self.p)
                if source_changed:
                    p["blobs"] = {key: base64.b64encode(b"replacement native").decode() for key in p["blobs"]}
                manifest, scenes = self.upload(p, width=44)
                original = self.counts()
                with self.db.connect() as db:
                    db.execute("CREATE TRIGGER fail_gc BEFORE DELETE ON objects BEGIN SELECT RAISE(ABORT, 'gc failure'); END")
                with self.assertRaises(sqlite3.Error):
                    self.commit(1, manifest, scenes)
                self.assertEqual(self.counts(), original)
                self.assertEqual(self.db.latest(), {"revision": 1, "package": self.p})
                self.assertEqual(self.db.image_metadata(1), original_metadata)
                self.assertEqual(self.db.image(1, next(iter(self.scenes))), original_png)
                self.assertEqual(self.db.scene_refs(1), self.scenes)
                for digest in scenes.values():
                    self.db.object(digest)
                with self.db.connect() as db:
                    db.execute("DROP TRIGGER fail_gc")

    def test_conflicts_before_render_and_concurrent_reconciliation(self):
        self.commit()
        divergent = copy.deepcopy(self.manifest)
        divergent["notebooks"][0]["name"] = "Divergent"
        with patch.object(self.renderer, "render_page", side_effect=AssertionError("should not render")):
            with self.assertRaises(Conflict):
                self.commit(0, divergent)
        outcomes = []
        def writer(name):
            manifest = copy.deepcopy(self.manifest)
            manifest["notebooks"][0]["name"] = name
            try:
                outcomes.append(self.commit(1, manifest))
            except Conflict:
                outcomes.append("conflict")
        threads = [threading.Thread(target=writer, args=(str(n),)) for n in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertCountEqual(outcomes, [2, "conflict"])

    def test_scene_divergence_with_same_source_requires_current_base(self):
        self.commit()
        _, scenes = self.upload(self.p, width=40)
        with self.assertRaises(Conflict):
            self.commit(0, scenes=scenes)
        self.assertEqual(self.db.scene_refs(1), self.scenes)
        self.assertEqual(self.commit(1, scenes=scenes), 1)
        self.assertEqual(self.commit(0, scenes=scenes), 1)
        self.assertEqual(self.db.latest()["package"], self.p)

    def test_legacy_revision_can_gain_scenes_without_digest_change(self):
        self.db.commit(0, self.p)
        with self.db.connect() as db:
            original = db.execute("SELECT revision,digest FROM revisions").fetchall()
        self.assertEqual(self.commit(), 1)
        with self.db.connect() as db:
            self.assertEqual(db.execute("SELECT revision,digest FROM revisions").fetchall(), original)
        self.assertEqual(self.db.scene_refs(1), self.scenes)

    def test_real_scene_numeric_and_mask_rejections_are_atomic(self):
        if self.renderer.render_page is fallback_render:
            self.skipTest("Requires real renderer validation")
        self.commit()
        key = next(iter(self.scenes))
        original_metadata = self.db.image_metadata(1)
        original_png = self.db.image(1, key)
        value = scene(self.p["notebooks"][0]["pages"][0]) | {"strokes": [stroke("com.apple.ink.marker")]}
        invalid = []
        for field, replacement in (("format", True), ("width", 0), ("height", 4097)):
            invalid.append(value | {field: replacement})
        for index, replacement in ((0, 1_000_001), (3, -1), (4, 8193), (5, -0.01), (5, 2.01)):
            bad = copy.deepcopy(value)
            bad["strokes"][0]["samples"][0][index] = replacement
            invalid.append(bad)
        for commands, even_odd in (([[1.5, 0, 0]], False), ([[True, 0, 0]], False),
                                   ([[0, 0]], False), ([[0, 1_000_001, 0]], False),
                                   ([[0, 0, 0]], 1)):
            bad = copy.deepcopy(value)
            bad["strokes"][0]["mask"] = {"commands": commands, "evenOdd": even_odd}
            invalid.append(bad)
        for bad in invalid:
            with self.subTest(scene=bad):
                data = canonical(bad)
                self.db.upload_object(sha(data), data)
                before = self.counts()
                with self.assertRaises((ValueError, RenderFailure)):
                    self.commit(1, scenes={key: sha(data)})
                self.assertEqual(self.counts(), before)
                self.assertEqual(self.db.scene_refs(1), self.scenes)
                self.assertEqual(self.db.image_metadata(1), original_metadata)
                self.assertEqual(self.db.image(1, key), original_png)

    def test_brush_opacity_two_is_valid_scene_and_retry_is_cached(self):
        value = scene(self.p["notebooks"][0]["pages"][0]) | {"strokes": [stroke("com.apple.ink.marker")]}
        for field in ("points", "samples"):
            for point in value["strokes"][0][field]:
                point[5] = 2
        data = canonical(value)
        self.db.upload_object(sha(data), data)
        key = next(iter(self.scenes))
        with patch.object(self.renderer, "render_page", wraps=self.renderer.render_page) as render:
            self.assertEqual(self.commit(scenes={key: sha(data)}), 1)
            self.assertEqual(self.commit(scenes={key: sha(data)}), 1)
            self.assertEqual(render.call_count, 1)
        self.assertEqual(self.db.object(sha(data)), data)

    def test_later_page_render_failure_rolls_back_earlier_png_objects(self):
        if self.renderer.render_page is fallback_render:
            self.skipTest("Requires real renderer validation")
        p = copy.deepcopy(self.p)
        b = p["notebooks"][0]
        b["deleted"].append({"id": str(uuid4()).upper(), "background": 0, "starred": False, "nodes": []})
        manifest, scenes = self.upload(p)
        self.commit(0, manifest, scenes)
        metadata = self.db.image_metadata(1)
        changed = dict(scenes)
        for page, width in ((b["pages"][0], 41), (b["deleted"][0], 0)):
            data = canonical(scene(page, width))
            self.db.upload_object(sha(data), data)
            changed[f'{b["id"]}/{page["id"]}'] = sha(data)
        before = self.counts()
        with patch.object(self.renderer, "render_page", wraps=self.renderer.render_page) as render:
            with self.assertRaises(RenderFailure):
                self.commit(1, manifest, changed)
            self.assertEqual(render.call_count, 2)
        self.assertEqual(self.counts(), before)
        self.assertEqual(self.db.scene_refs(1), scenes)
        self.assertEqual(self.db.image_metadata(1), metadata)

    def test_audit_backup_reads_one_coherent_scene_image_snapshot(self):
        # A same-source refresh legally updates scenes/images at the same revision.
        # Interleave it after metadata is read but before PNGs/scene refs are read.
        self.commit()
        _, refreshed = self.upload(self.p, width=40)
        original_reader = self.db.image_metadata
        def concurrent_refresh(revision, db=None):
            self.assertIsNotNone(db)
            metadata = original_reader(revision, db=db)
            self.commit(1, scenes=refreshed)
            return metadata
        root = Path(self.temp.name) / "racing-backup"
        with patch.object(self.db, "image_metadata", side_effect=concurrent_refresh):
            export(self.db, root)
        manifest = json.loads((root / "manifest.json").read_bytes())
        self.assertEqual(self.db.scene_refs(1), refreshed)
        self.assertEqual({key: Path(relative).stem for key, relative in manifest["scenes"].items()}, self.scenes)
        self.assertEqual(restore_package(root), self.p)
        for preview in manifest["images"].values():
            png = (root / preview["file"]).read_bytes()
            self.assertEqual(struct.unpack(">II", png[16:24]), (preview["width"], preview["height"]))

    def test_audit_v1_image_write_cannot_claim_portable_cache_provenance(self):
        self.commit()
        key = next(iter(self.scenes))
        expected = self.db.image(1, key)
        # Legacy backup restore can copy rendererVersion into a v1 image record.
        # V1 validates the PNG/head, but does not bind it to the retained scene.
        from test_images import images
        legacy = images(self.p)
        legacy[key]["rendererVersion"] = self.renderer.RENDERER_VERSION
        with self.db.connect() as db:
            source_revisions = db.execute("SELECT revision,digest,package FROM revisions").fetchall()
        self.db.commit(0, self.p, legacy)
        self.assertNotIn("rendererVersion", self.db.image_metadata(1)[key])
        self.assertEqual(self.db.scene_refs(1), self.scenes)
        with patch.object(self.renderer, "render_page", wraps=self.renderer.render_page) as render:
            self.commit()
            self.assertEqual(render.call_count, 1)
            self.commit()
            self.assertEqual(render.call_count, 1)
        self.assertEqual(self.db.image(1, key), expected)
        with self.db.connect() as db:
            self.assertEqual(db.execute("SELECT revision,digest,package FROM revisions").fetchall(), source_revisions)

    def test_object_integrity_and_nonempty_upload(self):
        for data in (b"", b"wrong"):
            with self.assertRaises(ValueError):
                self.db.upload_object("0" * 64, data)
        digest = next(iter(self.scenes.values()))
        with self.db.connect() as db:
            db.execute("UPDATE objects SET data=? WHERE digest=?", (zlib.compress(b"tampered"), digest))
        with self.assertRaises(ValueError):
            self.db.object(digest)
        with self.assertRaises(ValueError):
            self.commit()
        self.assertEqual(self.counts()[:3], (0, 0, 0))

    def test_portable_backup_old_restore_and_scene_restore(self):
        key = next(iter(self.scenes))
        missed, question = stroke("com.apple.ink.marker"), stroke()
        missed["color"] = [23 / 255, 127 / 255, 113 / 255, 1]
        question["color"] = [175 / 255, 82 / 255, 222 / 255, 1]
        data = canonical(scene(self.p["notebooks"][0]["pages"][0]) | {"strokes": [missed, question]})
        self.scenes = {key: self.db.upload_object(sha(data), data)}
        self.commit()
        root = Path(self.temp.name) / "backup"
        self.assertTrue(export(self.db, root))
        self.assertFalse(export(self.db, root))
        self.assertEqual(restore_package(root), self.p)
        records = restore_scenes(root)
        self.assertEqual({key: sha(data) for key, data in records.items()}, self.scenes)
        manifest = json.loads((root / "manifest.json").read_bytes())
        self.assertEqual(manifest["images"][key]["tagStrokeCounts"], {"question": 2})
        self.assertEqual(manifest["images"][key]["rendererVersion"], self.renderer.RENDERER_VERSION)
        self.assertEqual((root / manifest["images"][key]["file"]).read_bytes(), self.db.image(1, key))
        for key, relative in manifest["scenes"].items():
            self.assertEqual(relative, "objects/" + self.scenes[key] + ".json")
        new_db = Database(Path(self.temp.name) / "restored.sqlite3")
        for digest in self.manifest["blobs"].values():
            new_db.upload_object(digest, self.db.object(digest))
        for data in records.values():
            new_db.upload_object(sha(data), data)
        new_db.commit_manifest(0, self.manifest, self.scenes)
        self.assertEqual(new_db.latest(), self.db.latest())
        self.assertEqual(new_db.image_metadata(1), self.db.image_metadata(1))
        self.assertEqual(new_db.image(1, key), self.db.image(1, key))
        # Superseded scene files are removed from the working tree.
        self.p["notebooks"][0]["name"] = "v1"
        self.db.commit(1, self.p)
        export(self.db, root)
        self.assertEqual(restore_scenes(root), {})
        for relative in manifest["scenes"].values():
            self.assertFalse((root / relative).exists())
        (root / "manifest.json").write_bytes(canonical(manifest))
        (root / next(iter(manifest["scenes"].values()))).write_bytes(b"bad")
        with self.assertRaises(ValueError):
            restore_scenes(root)

    def test_legacy_constructor_reads_without_migration(self):
        path = Path(self.temp.name) / "legacy.sqlite3"
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE revisions (revision INTEGER PRIMARY KEY, digest TEXT NOT NULL, package BLOB NOT NULL, created TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
            db.execute("INSERT INTO revisions(revision,digest,package) VALUES(7,?,?)", (sha(canonical(self.p)), canonical(self.p)))
        db = Database(path)
        self.assertEqual(db.latest(), {"revision": 7, "package": self.p})
        self.assertEqual(db.manifest_state()["manifest"], self.manifest)
        self.assertEqual(db.scene_refs(7), {})
        with db.connect() as connection:
            self.assertEqual(connection.execute("SELECT revision,digest FROM revisions").fetchone(), (7, sha(canonical(self.p))))


class IncrementalHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.server = make_server(Path(self.temp.name) / "http.sqlite3", "test-token", 0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.context = renderer()
        self.renderer = self.context.__enter__()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.context.__exit__(None, None, None)
        self.temp.cleanup()

    def request(self, path, body=None, token="test-token", **headers):
        if isinstance(body, dict):
            body = canonical(body)
        req = urllib.request.Request(f"http://127.0.0.1:{self.server.server_port}" + path,
            data=body, headers={"Authorization": "Bearer " + token} | headers)
        try:
            response = urllib.request.urlopen(req)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.code, response.read(), response.headers

    def test_all_v2_routes_authenticated(self):
        for path, body in (("/v2/state", None), ("/v2/state", {}), ("/v2/objects/" + "0" * 64, None),
                           ("/v2/objects/" + "0" * 64, b"x"), ("/v2/objects/missing", {"digests": []})):
            self.assertEqual(self.request(path, body, token="bad")[0], 401)

    def test_binary_gzip_upload_get_missing_and_v1_v2_state(self):
        p = package()
        manifest = copy.deepcopy(p)
        manifest["blobs"] = {}
        data = base64.b64decode(next(iter(p["blobs"].values())))
        digest = sha(data)
        self.assertEqual(json.loads(self.request("/v2/objects/missing", {"digests": [digest]})[1]), {"missing": [digest]})
        status, body, _ = self.request("/draw-sync/v2/objects/" + digest, gzip.compress(data), **{"Content-Encoding": "gzip"})
        self.assertEqual((status, json.loads(body)), (200, {"digest": digest}))
        self.assertEqual(self.request("/v2/objects/" + digest)[1], data)
        status, body, headers = self.request("/v2/objects/" + digest, **{"Accept-Encoding": "gzip"})
        self.assertEqual((status, headers["Content-Encoding"], gzip.decompress(body)), (200, "gzip", data))
        self.assertEqual(json.loads(self.request("/v2/objects/missing", {"digests": [digest]})[1]), {"missing": []})
        manifest["blobs"] = {key: digest for key in p["blobs"]}
        b = p["notebooks"][0]
        missed, question = stroke("com.apple.ink.marker"), stroke()
        missed["color"] = [23 / 255, 127 / 255, 113 / 255, 1]
        question["color"] = [175 / 255, 82 / 255, 222 / 255, 1]
        portable = json.dumps(scene(b["pages"][0]) | {"strokes": [missed, question]}, indent=2).encode()
        self.assertEqual(self.request("/v2/objects/" + sha(portable), portable)[0], 200)
        scenes = {f'{b["id"]}/{b["pages"][0]["id"]}': sha(portable)}
        upload = {"baseRevision": 0, "manifest": manifest, "scenes": scenes}
        self.assertEqual(self.request("/v2/state", gzip.compress(canonical(upload)), **{"Content-Encoding": "gzip"})[0], 200)
        self.assertEqual(json.loads(self.request("/v2/state")[1]), {"revision": 1, "manifest": manifest})
        self.assertEqual(self.request("/v2/objects/" + sha(portable))[1], portable)
        status, body, _ = self.request("/v1/documents/" + b["id"] + "?revision=1")
        self.assertEqual(status, 200)
        agent_page = json.loads(body)["pages"][0]
        self.assertEqual(agent_page["tags"], ["question"])
        self.assertEqual(agent_page["image"]["tagStrokeCounts"], {"question": 2})
        self.assertEqual(agent_page["image"]["rendererVersion"], self.renderer.RENDERER_VERSION)
        self.assertEqual(self.request(agent_page["png"])[0], 200)
        status, body, headers = self.request("/v1/state", **{"Accept-Encoding": "gzip"})
        self.assertEqual(headers["Content-Encoding"], "gzip")
        self.assertEqual(json.loads(gzip.decompress(body)), {"revision": 1, "package": p})
        self.assertNotIn("Content-Encoding", self.request("/v1/state", **{"Accept-Encoding": "gzip;q=0, *;q=1"})[2])
        self.assertEqual(self.request("/v1/state", gzip.compress(canonical({"baseRevision": 0, "package": p})), **{"Content-Encoding": "gzip"})[0], 200)
        self.assertEqual(self.request("/v2/state", upload | {"images": {}})[0], 400)
        manifest["notebooks"][0]["name"] = "Divergent"
        self.assertEqual(self.request("/v2/state", upload)[0], 409)

    def test_truncated_http_body_and_ambiguous_headers(self):
        data = b"native"
        path = "/v2/objects/" + sha(data)
        for headers, body in (("Content-Length: 7\r\n", data),
                              ("Content-Length: 6\r\nContent-Length: 6\r\n", data),
                              ("Content-Length: 6\r\nContent-Encoding: identity\r\nContent-Encoding: gzip\r\n", data),
                              ("Transfer-Encoding: chunked\r\n", b"0\r\n\r\n")):
            with socket.create_connection(("127.0.0.1", self.server.server_port), timeout=5) as connection:
                connection.sendall((f"POST {path} HTTP/1.0\r\nAuthorization: Bearer test-token\r\n" +
                                    headers + "\r\n").encode() + body)
                connection.shutdown(socket.SHUT_WR)
                response = connection.makefile("rb").read()
            self.assertTrue(response.startswith(b"HTTP/1.0 400"), response)
        self.assertEqual(self.server.database.missing_objects([sha(data)]), [sha(data)])

    def test_gzip_magic_is_preserved_in_original_cas_object(self):
        # Consumers must distinguish transport gzip from already-decoded gzip
        # archive bytes. Digest verification disambiguates the object response.
        data = gzip.compress(b"native archive-like content", mtime=0)
        digest = sha(data)
        path = "/v2/objects/" + digest
        self.assertEqual(self.request(path, gzip.compress(data), **{"Content-Encoding": "gzip"})[0], 200)
        status, wire, headers = self.request(path, **{"Accept-Encoding": "gzip"})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Encoding"], "gzip")
        decoded_transport = gzip.decompress(wire)
        self.assertEqual(decoded_transport, data)
        self.assertEqual(sha(decoded_transport), digest)
        # Models Swift's extra decode if URLSession retains the gzip header.
        self.assertNotEqual(sha(gzip.decompress(decoded_transport)), digest)

    def test_bad_gzip_encoding_checksums_and_limits(self):
        data = b"object bytes"
        path = "/v2/objects/" + sha(data)
        for body, encoding in ((gzip.compress(data)[:-1], "gzip"), (b"garbage", "gzip"),
                               (gzip.compress(data) + b"x", "gzip"),
                               (gzip.compress(data) * 2, "gzip"), (data, "br"), (data, "gzip, identity")):
            self.assertEqual(self.request(path, body, **{"Content-Encoding": encoding})[0], 400)
        self.assertEqual(self.request(path, b"wrong")[0], 400)
        self.assertEqual(self.request("/v2/objects/" + sha(b""), gzip.compress(b""), **{"Content-Encoding": "gzip"})[0], 400)
        with patch.object(server, "MAX_OBJECT_BYTES", 64):
            self.assertEqual(self.request(path, b"x" * 65)[0], 413)
            self.assertEqual(self.request(path, gzip.compress(b"x" * 65), **{"Content-Encoding": "gzip"})[0], 413)
        with patch.object(server, "MAX_METADATA_BYTES", 64):
            self.assertEqual(self.request("/v2/objects/missing", b" " * 65)[0], 413)
            self.assertEqual(self.request("/v2/state", gzip.compress(b" " * 65), **{"Content-Encoding": "gzip"})[0], 413)
        self.assertEqual(self.request("/v2/objects/" + "A" * 64, data)[0], 400)
        self.assertEqual(self.request("/v2/objects/" + "0" * 64)[0], 404)
        self.assertEqual(self.request("/v2/state", b'{"baseRevision":NaN}')[0], 400)
        self.assertEqual(self.request("/v2/state", b'\xff')[0], 400)
        self.assertEqual(self.server.database.manifest_state(), {"revision": 0, "manifest": None})


if __name__ == "__main__":
    unittest.main()
