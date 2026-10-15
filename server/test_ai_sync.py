"""AI/document Sync uses temporary databases, PNGs and loopback HTTP only."""
import base64
import copy
import hashlib
from io import BytesIO
import json
from pathlib import Path
import sqlite3
import struct
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
from uuid import uuid4
import zlib

from PIL import Image
from ai_models import validate_asset, validate_objects, validate_png
from backup import export, restore_package, restore_scenes
from client import ManagerClient
from portable import render_page
import portable
from server import Database, Conflict, canonical, make_server, validate
from test_server import package
from test_incremental import stroke


def uid():
    return str(uuid4()).upper()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def asset_png(color=(255, 0, 0, 255)):
    buffer = BytesIO()
    Image.new("RGBA", (4, 4), color).save(buffer, format="PNG")
    return buffer.getvalue()


def ai_object(data):
    return {"id": uid(), "revision": 1, "kind": "text", "source": "answer",
            "frame": {"x": 12, "y": 12, "width": 2, "height": 2},
            "style": {"fontSize": 14, "color": "#000000", "lineWidth": 1},
            "asset": {"sha256": sha(data), "pixelWidth": 4, "pixelHeight": 4, "scale": 2},
            "provenance": {"requestID": uid(), "contextSHA256": "0" * 64,
                           "rendererSignature": "draw-ai-render-v1"}}


class AISyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state.sqlite3"
        self.db = Database(self.path)

    def tearDown(self):
        self.temp.cleanup()

    def with_ai(self):
        p = package()
        data = asset_png()
        obj = ai_object(data)
        p["notebooks"][0]["pages"][0]["nodes"][0]["objects"] = [obj]
        p["format"] = 2
        p["assets"] = {sha(data): base64.b64encode(data).decode()}
        return p

    def upload(self, p):
        manifest = copy.deepcopy(p)
        for field in ("blobs", "assets"):
            if field in p:
                manifest[field] = {}
                for key, encoded in p[field].items():
                    data = base64.b64decode(encoded)
                    manifest[field][key] = self.db.upload_object(sha(data), data)
        scenes = {}
        for b in p["notebooks"]:
            for page in b["pages"] + b["deleted"]:
                objects = next((n.get("objects", []) for n in page["nodes"] if n["id"] == page.get("head")), [])
                value = {"format": 1, "head": page.get("head"), "width": 64, "height": 72,
                         "background": page["background"], "objects": objects, "strokes": []}
                data = canonical(value)
                scenes[f'{b["id"]}/{page["id"]}'] = self.db.upload_object(sha(data), data)
        return manifest, scenes

    def test_legacy_missing_and_explicit_empty_objects_keep_source_bytes(self):
        for explicit in (False, True):
            p = package()
            if explicit:
                p["notebooks"][0]["pages"][0]["nodes"][0]["objects"] = []
            before = canonical(p)
            m, scenes = self.upload(p)
            self.db.commit_manifest(self.db.latest()["revision"], m, scenes)
            self.assertEqual(canonical(self.db.latest()["package"]), before)
            with self.db.connect() as db:
                self.assertEqual(db.execute("SELECT digest FROM revisions").fetchone()[0], sha(before))
            self.assertNotIn("assets", self.db.manifest_state()["manifest"])

    def test_format_two_roundtrip_restore_assets_and_source_spec(self):
        p = self.with_ai()
        m, scenes = self.upload(p)
        self.assertEqual(self.db.commit_manifest(0, m, scenes), 1)
        self.assertEqual(Database(self.path).latest()["package"], p)
        self.assertEqual(self.db.manifest_state()["manifest"], m)
        root = Path(self.temp.name) / "backup"
        self.assertTrue(export(self.db, root))
        self.assertFalse(export(self.db, root))
        self.assertEqual(restore_package(root), p)
        self.assertEqual({key: sha(data) for key, data in restore_scenes(root).items()}, scenes)
        manifest = json.loads((root / "manifest.json").read_bytes())
        self.assertEqual(manifest["assets"], {digest: "objects/" + digest + ".png" for digest in p["assets"]})
        self.assertNotIn("assets", manifest["package"])
        restored = Database(Path(self.temp.name) / "restored.sqlite3")
        for digest in list(m["blobs"].values()) + list(m["assets"].values()) + list(scenes.values()):
            restored.upload_object(digest, self.db.object(digest))
        restored.commit_manifest(0, m, scenes)
        self.assertEqual(restored.latest(), self.db.latest())
        self.assertEqual(restored.image_metadata(1), self.db.image_metadata(1))
        for key in scenes:
            self.assertEqual(restored.image(1, key), self.db.image(1, key))

    def test_highlight_current_source_formats_roundtrip_backup_without_kind_format_change(self):
        for source_format in (2, 3):
            with self.subTest(format=source_format):
                p = self.with_ai()
                data = asset_png((0, 184, 217, 51))
                obj = ai_object(data)
                obj.update(kind="highlight", source='{"opacity":0.2}')
                obj["style"]["color"] = "#00B8D9"
                # Carry can leave a current object crossing the page's upper edge.
                obj["frame"]["y"] = -1
                p.update(format=source_format, assets={sha(data): base64.b64encode(data).decode()})
                p["notebooks"][0]["pages"][0]["nodes"][0]["objects"] = [obj]
                if source_format == 3:
                    root, leaf = uid(), uid()
                    p["folders"] = [{"id": root, "name": "Semester"},
                                    {"id": leaf, "name": "Math", "parentID": root}]
                    p["notebooks"][0]["folderID"] = leaf
                validate(p)
                before = canonical(p)
                manifest, scenes = self.upload(p)
                revision = self.db.latest()["revision"]
                self.db.commit_manifest(revision, manifest, scenes)
                self.assertEqual(canonical(Database(self.path).latest()["package"]), before)
                self.assertEqual(self.db.manifest_state()["manifest"], manifest)
                root = Path(self.temp.name) / ("highlight-backup-" + str(source_format))
                self.assertTrue(export(self.db, root))
                self.assertEqual(canonical(restore_package(root)), before)
                self.assertEqual({key: sha(value) for key, value in restore_scenes(root).items()}, scenes)
                self.assertEqual((root / "objects" / (sha(data) + ".png")).read_bytes(), data)
                self.assertEqual(obj["style"]["fontSize"], 14)
                self.assertEqual(p["format"], source_format)
                bad = copy.deepcopy(p)
                bad["notebooks"][0]["pages"][0]["nodes"][0]["objects"][0]["kind"] = "future-highlight"
                with self.assertRaises(ValueError):
                    validate(bad)
                if source_format == 3:
                    legacy = copy.deepcopy(p)
                    legacy["format"] = 2
                    with self.assertRaises(ValueError):
                        validate(legacy)

    def test_highlight_resolved_source_uses_existing_rgb_style_and_verified_asset_contract(self):
        data = asset_png((0, 184, 217, 51))
        obj = ai_object(data)
        obj.update(kind="highlight", source='{"opacity":0.2}')
        obj["style"]["color"] = "#00B8D9"
        validate_objects([obj])
        validate_asset(data, obj["asset"])
        # Source/native logical readers never reinterpret geometry or regenerate images.
        validate_objects([obj | {"source": "historical source metadata"}])
        for style in (obj["style"] | {"color": "#00B8D933"}, obj["style"] | {"opacity": 0.2}):
            with self.assertRaises(ValueError):
                validate_objects([obj | {"style": style}])
        with self.assertRaises(ValueError):
            validate_asset(asset_png((0, 184, 217, 255)), obj["asset"])

    def test_highlight_portable_scene_keeps_black_ink_above_transparent_asset(self):
        data = asset_png((0, 184, 217, 51))
        obj = ai_object(data)
        obj.update(kind="highlight", source='{"opacity":0.2}')
        obj["style"]["color"] = "#00B8D9"
        scene = {"format": 1, "width": 64, "height": 72, "strokes": [], "objects": [obj], "background": 0}
        _, preview = render_page(scene, {sha(data): data})
        self.assertEqual(Image.open(BytesIO(preview)).convert("RGB").getpixel((25, 25)), (204, 241, 247))
        scene["strokes"] = [stroke()]
        scene["strokes"][0]["samples"] = [[12, 13, 0, 4, 4, 1, 1, 0, 1, 1, 0, 0], [14, 13, 0, 4, 4, 1, 1, 0, 1, 1, 0, 0]]
        original_strokes = copy.deepcopy(scene["strokes"])
        _, preview = render_page(scene, {sha(data): data})
        self.assertEqual(Image.open(BytesIO(preview)).convert("RGB").getpixel((25, 25)), (0, 0, 0))
        self.assertEqual(scene["strokes"], original_strokes)

    def test_asset_backup_git_publish_retains_exactly_one_root(self):
        import os
        from backup import git, publish_current
        p = self.with_ai()
        m, scenes = self.upload(p)
        self.db.commit_manifest(0, m, scenes)
        root = Path(self.temp.name) / "git-backup"
        remote = Path(self.temp.name) / "bare.git"
        root.mkdir()
        with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}):
            git(root, "init", "--initial-branch=main")
            git(root, "init", "--bare", "--initial-branch=main", str(remote))
            git(root, "config", "user.name", "Scratch test")
            git(root, "config", "user.email", "scratch@example.invalid")
            git(root, "remote", "add", "origin", str(remote))
            export(self.db, root)
            first = publish_current(root)
            old_asset = "objects/" + next(iter(m["assets"])) + ".png"
            self.assertIn(old_asset, git(root, "ls-tree", "-r", "--name-only", first).splitlines())
            p["notebooks"][0]["pages"][0]["nodes"][0]["objects"] = []
            p.pop("assets")
            p["format"] = 1
            m, scenes = self.upload(p)
            self.db.commit_manifest(1, m, scenes)
            export(self.db, root)
            second = publish_current(root)
            self.assertNotEqual(first, second)
            for repo in (root, remote):
                self.assertEqual(git(repo, "rev-list", "--count", "--all"), "1")
                self.assertEqual(git(repo, "rev-list", "--parents", "-n", "1", second), second)
            self.assertNotIn(old_asset, git(root, "ls-tree", "-r", "--name-only", second).splitlines())
            self.assertEqual(restore_package(root), p)

    def test_document_normalized_root_spelling_and_legacy_current_projection(self):
        p = package()
        page = p["notebooks"][0]["pages"][0]
        page.pop("preferredRoot", None)
        p["folders"] = None
        m, scenes = self.upload(p)
        self.db.commit_manifest(0, m, scenes)
        bid = p["notebooks"][0]["id"]
        before = self.db.document_state(bid)
        self.assertNotIn("preferredRoot", before["manifest"]["notebooks"][0]["pages"][0])
        receipt = self.db.commit_document(bid, uid(), before["documentDigest"], before["manifest"], scenes)
        self.assertEqual(receipt["revision"], 1)
        self.assertEqual(self.db.latest()["package"], p)
        historical = copy.deepcopy(m)
        node = historical["notebooks"][0]["pages"][0]["nodes"][0]
        root = uid()
        node["parent"] = root
        historical["notebooks"][0]["pages"][0]["nodes"].insert(0, {"id": root, "children": [node["id"]]})
        historical["blobs"][bid + "/" + page["id"] + "/" + root] = "1" * 64
        projected = self.db.document_manifest(historical, bid)
        projected_page = projected["notebooks"][0]["pages"][0]
        self.assertEqual(projected_page["nodes"], [{"id": page["head"], "children": []}])
        self.assertEqual(set(projected["blobs"]), set(m["blobs"]))

    def test_format_and_asset_set_validation(self):
        p = self.with_ai()
        for mutate in (lambda q: q.update(format=1), lambda q: q.pop("assets"),
                       lambda q: q.update(assets={}), lambda q: q["assets"].update({"0" * 64: "eA=="})):
            q = copy.deepcopy(p)
            mutate(q)
            with self.assertRaises(ValueError):
                validate(q)
        for assets in ({}, {"0" * 64: "eA=="}):
            q = package() | {"format": 2, "assets": assets}
            with self.assertRaises(ValueError):
                validate(q)
        with self.assertRaises(ValueError):
            self.db.commit(0, p)

    def test_missing_corrupt_and_mismatched_assets_fail_before_publication(self):
        p = self.with_ai()
        m, scenes = self.upload(p)
        self.db.commit_manifest(0, m, scenes)
        before = self.db.latest()
        for mutate in (lambda q: q.update(assets={}), lambda q: q["assets"].update({next(iter(q["assets"])): "0" * 64}),
                       lambda q: q["notebooks"][0]["pages"][0]["nodes"][0]["objects"][0]["asset"].update(pixelWidth=5)):
            q = copy.deepcopy(m)
            mutate(q)
            with self.assertRaises(ValueError):
                self.db.commit_manifest(1, q, scenes)
            self.assertEqual(self.db.latest(), before)
        digest = next(iter(m["assets"]))
        with self.db.connect() as db:
            db.execute("DELETE FROM objects WHERE digest=?", (digest,))
        with self.assertRaises(ValueError):
            self.db.commit_manifest(1, m, scenes)
        self.assertEqual(self.db.manifest_state()["manifest"], m)
        self.assertEqual(self.db.scene_refs(1), scenes)

    def test_asset_png_structure_dimensions_crc_deflate_and_bounds(self):
        good = asset_png()
        validate_asset(good, ai_object(good)["asset"])
        def chunk(kind, payload):
            return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
        header = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 6, 0, 0, 0))
        for data in (good[:-1], good + b"x", good[:40] + b"x" + good[41:],
                     header + chunk(b"IDAT", b"invalid") + chunk(b"IEND", b""),
                     header + chunk(b"IDAT", zlib.compress(b"\0" * 1000)) + chunk(b"IEND", b""),
                     header + chunk(b"IDAT", zlib.compress(b"\5" * 68)) + chunk(b"IEND", b"")):
            with self.assertRaises(ValueError):
                validate_png(data)
        with self.assertRaises(ValueError):
            validate_png(good, 3, 4)
        descriptor = ai_object(good)["asset"] | {"pixelWidth": 8192, "pixelHeight": 8192}
        with self.assertRaises(ValueError):
            validate_asset(good, descriptor)

    def test_object_bounds_ids_nonfinite_and_revisions(self):
        obj = ai_object(asset_png())
        for field, value in (("revision", True), ("kind", "html"), ("source", "x" * 65537)):
            with self.assertRaises(ValueError):
                validate_objects([obj | {field: value}])
        for field, value in (("width", -1), ("height", float("nan")), ("x", float("inf"))):
            bad = copy.deepcopy(obj)
            bad["frame"][field] = value
            with self.assertRaises(ValueError):
                validate_objects([bad])
        with self.assertRaises(ValueError):
            validate_objects([obj, obj])

    def test_scene_objects_paper_and_deleted_head_assets_are_verified(self):
        p = self.with_ai()
        book = p["notebooks"][0]
        book["deleted"] = [book["pages"].pop()]
        book["pages"] = [{"id": uid(), "background": 0, "starred": False, "nodes": []}]
        book["currentPage"] = book["pages"][0]["id"]
        m, scenes = self.upload(p)
        key = next(k for k in scenes if k.endswith(book["deleted"][0]["id"]))
        for delta in ({"objects": []}, {"background": 3}):
            bad = json.loads(self.db.object(scenes[key])) | delta
            data = canonical(bad)
            digest = self.db.upload_object(sha(data), data)
            with self.assertRaises(ValueError):
                self.db.commit_manifest(0, m, scenes | {key: digest})
            self.assertEqual(self.db.latest()["revision"], 0)
        self.db.commit_manifest(0, m, scenes)
        self.assertEqual(self.db.latest()["package"], p)

    def test_paper_object_then_ink_layering_and_legacy_ruled(self):
        data = asset_png()
        obj = ai_object(data)
        scene = {"format": 1, "width": 64, "height": 72, "strokes": [], "objects": [obj], "background": 0}
        _, png = render_page(scene, {sha(data): data})
        image = Image.open(BytesIO(png)).convert("RGB")
        self.assertEqual(image.getpixel((25, 25)), (255, 0, 0))
        self.assertEqual(image.getpixel((20, 72)), (255, 255, 255))
        scene["strokes"] = [stroke()]
        scene["strokes"][0]["samples"] = [[12, 13, 0, 4, 4, 1, 1, 0, 1, 1, 0, 0], [14, 13, 0, 4, 4, 1, 1, 0, 1, 1, 0, 0]]
        _, png = render_page(scene, {sha(data): data})
        self.assertEqual(Image.open(BytesIO(png)).convert("RGB").getpixel((25, 25)), (0, 0, 0))
        for background in range(4):
            value = {"format": 1, "width": 64, "height": 72, "strokes": [], "background": background}
            metadata, png = render_page(value)
            self.assertEqual(metadata["background"], background)
            image = Image.open(BytesIO(png)).convert("RGB")
            if background in (2, 3):
                self.assertLess(image.getpixel((20, 72))[0], 255)
            if background == 1:
                self.assertLess(image.getpixel((73, 73))[0], 255)
            if background == 3:
                self.assertLess(image.getpixel((72, 20))[0], 255)
        legacy = {"format": 1, "width": 64, "height": 72, "strokes": []}
        self.assertEqual(render_page(legacy)[1], render_page(legacy | {"background": 2})[1])
        self.assertNotIn("background", render_page(legacy)[0])

    def test_document_unchanged_freshness_and_durable_idempotency(self):
        p = self.with_ai()
        m, scenes = self.upload(p)
        bid = p["notebooks"][0]["id"]
        first = self.db.commit_document(bid, uid(), None, m, scenes)
        state = self.db.document_state(bid)
        self.assertEqual(state["manifest"], m)
        self.assertEqual(state["documentDigest"], sha(canonical(m)))
        sync_id = uid()
        second = self.db.commit_document(bid, sync_id, first["documentDigest"], m, scenes)
        self.assertEqual(second["revision"], first["revision"])
        self.assertGreater(second["lastSyncedAt"], first["lastSyncedAt"])
        self.assertEqual(Database(self.path).sync_receipt(sync_id), second)
        changed = copy.deepcopy(m)
        changed["notebooks"][0]["name"] = "new"
        self.db.commit_document(bid, uid(), second["documentDigest"], changed, scenes)
        retry = self.db.commit_document(bid, sync_id, first["documentDigest"], m, scenes)
        self.assertEqual(retry, second)
        self.assertEqual(self.db.document_state(bid)["manifest"], changed)
        with self.assertRaises(Conflict):
            self.db.commit_document(bid, sync_id, first["documentDigest"], changed, scenes)

    def test_document_merge_preserves_unrelated_docs_assets_empty_folders_and_freshness(self):
        first = self.with_ai()
        second = package()
        folder = {"id": uid(), "name": "empty"}
        combined = copy.deepcopy(first)
        combined["notebooks"] += second["notebooks"]
        combined["blobs"].update(second["blobs"])
        combined["folders"] = [folder]
        m, scenes = self.upload(combined)
        self.db.commit_manifest(0, m, scenes)
        first_id, second_id = [b["id"] for b in combined["notebooks"]]
        before = self.db.document_state(first_id)
        metadata = self.db.image_metadata(1)
        second_m = self.db.document_state(second_id)["manifest"]
        base = self.db.document_state(second_id)["documentDigest"]
        # An unrelated latest server edit occurs after the second doc's baseline.
        first_m = copy.deepcopy(before["manifest"])
        first_m["notebooks"][0]["name"] = "remote-only edit"
        first_scenes = {key: value for key, value in scenes.items() if key.startswith(first_id)}
        self.db.commit_document(first_id, uid(), before["documentDigest"], first_m, first_scenes)
        remote = self.db.document_state(first_id)
        second_m["notebooks"][0]["name"] = "local second"
        with patch.object(portable, "render_page", side_effect=AssertionError("unchanged renders must be ref-copied")):
            receipt = self.db.commit_document(second_id, uid(), base, second_m,
                {key: value for key, value in scenes.items() if key.startswith(second_id)})
        latest = self.db.manifest_state()["manifest"]
        self.assertEqual(latest["notebooks"][0], first_m["notebooks"][0])
        self.assertEqual(latest["folders"], [folder])
        self.assertEqual(latest["assets"], m["assets"])
        self.assertEqual(self.db.document_state(first_id)["lastSyncedAt"], remote["lastSyncedAt"])
        self.assertEqual(self.db.image_metadata(receipt["revision"]), metadata)
        self.assertEqual(self.db.scene_refs(receipt["revision"]), scenes)

    def test_unrelated_legacy_missing_scene_preview_is_ref_copied(self):
        from test_images import images
        p = package()
        self.db.commit(0, p, images(p))
        first_id = p["notebooks"][0]["id"]
        original = self.db.image_metadata(1)
        new = package()
        m, scenes = self.upload(new)
        receipt = self.db.commit_document(new["notebooks"][0]["id"], uid(), None, m, scenes)
        latest = self.db.image_metadata(receipt["revision"])
        self.assertEqual({key: value for key, value in latest.items() if key.startswith(first_id)}, original)
        self.assertEqual(self.db.document_state(first_id)["manifest"]["notebooks"], p["notebooks"])

    def test_document_conflicts_missing_baseline_and_required_folder(self):
        p = package()
        folder = {"id": uid(), "name": "Math"}
        p["folders"] = [folder]
        bid = p["notebooks"][0]["id"]
        p["notebooks"][0]["folderID"] = folder["id"]
        m, scenes = self.upload(p)
        first = self.db.commit_document(bid, uid(), None, m, scenes)
        with self.assertRaises(Conflict):
            self.db.commit_document(bid, uid(), None, m, scenes)
        changed = copy.deepcopy(m)
        changed["folders"][0]["name"] = "unrelated rename"
        with self.assertRaises(Conflict):
            self.db.commit_document(bid, uid(), first["documentDigest"], changed, scenes)
        for delta in ({"folders": []}, {"notebooks": []}, {"folders": [folder, {"id": uid(), "name": "extra"}]}):
            with self.assertRaises(ValueError):
                self.db.commit_document(bid, uid(), first["documentDigest"], m | delta, scenes)
        self.assertEqual(self.db.document_state(bid)["lastSyncedAt"], first["lastSyncedAt"])
        self.assertEqual(self.db.manifest_state()["manifest"], m)

    def test_receipt_failure_rolls_back_source_scenes_images_and_freshness(self):
        p = package()
        m, scenes = self.upload(p)
        sync_id = uid()
        bid = p["notebooks"][0]["id"]
        with self.db.connect() as db:
            db.execute("CREATE TRIGGER fail_receipt BEFORE INSERT ON sync_receipts BEGIN SELECT RAISE(ABORT, 'failed'); END")
        with self.assertRaises(sqlite3.Error):
            self.db.commit_document(bid, sync_id, None, m, scenes)
        self.assertEqual(self.db.latest()["revision"], 0)
        self.assertIsNone(self.db.document_state(bid)["lastSyncedAt"])
        self.assertEqual(self.db.image_metadata(1), {})
        self.assertEqual(self.db.scene_refs(1), {})
        with self.assertRaises(LookupError):
            self.db.sync_receipt(sync_id)

    def test_home_optional_receipt_unchanged_confirmation_and_cross_route_id_conflict(self):
        p = package()
        m, scenes = self.upload(p)
        sync_id = uid()
        first = self.db.commit_manifest(0, m, scenes, sync_id)
        second = self.db.commit_manifest(1, m, scenes, uid())
        self.assertEqual(first["revision"], second["revision"])
        self.assertGreater(second["lastSyncedAt"], first["lastSyncedAt"])
        self.assertEqual(self.db.commit_manifest(0, m, scenes, sync_id), first)
        bid = p["notebooks"][0]["id"]
        self.assertEqual(first["documents"][bid], self.db.document_state(bid)["documentDigest"])
        with self.assertRaises(Conflict):
            self.db.commit_document(bid, sync_id, first["documents"][bid], m, scenes)

    def test_current_only_gc_drops_old_assets_but_not_receipts(self):
        p = self.with_ai()
        m, scenes = self.upload(p)
        bid = p["notebooks"][0]["id"]
        sync_id = uid()
        first = self.db.commit_document(bid, sync_id, None, m, scenes)
        old_asset = next(iter(m["assets"]))
        p["notebooks"][0]["pages"][0]["nodes"][0]["objects"] = []
        p["format"] = 1
        p.pop("assets")
        new_m, new_scenes = self.upload(p)
        self.db.commit_document(bid, uid(), first["documentDigest"], new_m, new_scenes)
        with self.assertRaises(LookupError):
            self.db.object(old_asset)
        self.assertEqual(self.db.sync_receipt(sync_id), first)
        self.assertEqual(self.db.commit_document(bid, sync_id, None, m, scenes), first)
        with self.db.connect() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM revisions").fetchone()[0], 1)

    def test_two_documents_concurrent_merge_and_same_document_conflict(self):
        docs = [package(), package()]
        uploads = [self.upload(p) for p in docs]
        results = []
        def publish(index):
            try:
                m, scenes = uploads[index]
                results.append(self.db.commit_document(docs[index]["notebooks"][0]["id"], uid(), None, m, scenes))
            except Exception as error:
                results.append(error)
        threads = [threading.Thread(target=publish, args=(i,)) for i in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertTrue(all(isinstance(result, dict) for result in results), results)
        self.assertEqual(len(self.db.latest()["package"]["notebooks"]), 2)
        self.assertEqual(self.db.latest()["revision"], 2)
        m, scenes = uploads[0]
        with self.assertRaises(Conflict):
            self.db.commit_document(docs[0]["notebooks"][0]["id"], uid(), None, m, scenes)


class AIDocumentHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.http = make_server(Path(self.temp.name) / "state.sqlite3", "fixture", 0)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f"http://127.0.0.1:{self.http.server_port}"
        self.client = ManagerClient(self.origin, "fixture")

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, path, body=None, token="fixture"):
        request = urllib.request.Request(self.origin + path, data=canonical(body) if body is not None else None,
                                         headers={"Authorization": "Bearer " + token})
        try:
            response = urllib.request.urlopen(request)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.code, json.loads(response.read())

    def test_exact_document_state_helpers_receipts_and_errors(self):
        bid = uid()
        absent = self.client.document_state(bid)
        self.assertEqual(absent, {"revision": 0, "manifest": None, "documentDigest": None, "lastSyncedAt": None})
        p = package()
        bid = p["notebooks"][0]["id"]
        page = p["notebooks"][0]["pages"][0]
        native = base64.b64decode(next(iter(p["blobs"].values())))
        self.http.database.upload_object(sha(native), native)
        m = p | {"blobs": {key: sha(native) for key in p["blobs"]}}
        data = canonical({"format": 1, "head": page["head"], "width": 32, "height": 36, "strokes": [], "background": 0})
        self.http.database.upload_object(sha(data), data)
        scenes = {bid + "/" + page["id"]: sha(data)}
        sync_id = uid()
        body = {"syncID": sync_id, "baseDocumentDigest": None, "manifest": m, "scenes": scenes}
        route = "/v2/documents/" + bid + "/state"
        code, receipt = self.request(route, body)
        self.assertEqual(code, 200)
        self.assertEqual(receipt["documentID"], bid)
        self.assertEqual(self.client.sync_receipt(sync_id), receipt)
        self.assertEqual(self.client.docScenerefs(bid), {"revision": 1, "scenes": scenes})
        self.assertEqual(self.client.objectBytes(sha(data)), data)
        self.assertEqual(self.client.document_metadata(bid)["document"]["lastSyncedAt"], receipt["lastSyncedAt"])
        self.assertEqual(self.client.document_metadata(bid)["pages"][0]["imagePaper"], "blank")
        self.assertEqual(self.client.document_state(bid)["manifest"], m)
        self.assertEqual(self.request(route, body), (200, receipt))
        for path, payload, token, expected in ((route, body, "bad", 401),
              (route, body | {"syncID": uid()}, "fixture", 409),
              (route, body | {"scenes": {}, "syncID": uid(), "baseDocumentDigest": receipt["documentDigest"]}, "fixture", 422),
              ("/v2/sync-receipts/" + uid(), None, "fixture", 404)):
            status, response = self.request(path, payload, token)
            self.assertEqual(status, expected)
            self.assertEqual(set(response["error"]), {"code", "message"})
    def test_invalid_portable_scene_is_422_without_receipt_or_stamp(self):
        p = package()
        bid = p["notebooks"][0]["id"]
        page = p["notebooks"][0]["pages"][0]
        native = base64.b64decode(next(iter(p["blobs"].values())))
        self.http.database.upload_object(sha(native), native)
        m = p | {"blobs": {key: sha(native) for key in p["blobs"]}}
        data = canonical({"format": 99, "head": page["head"], "width": 32, "height": 36, "strokes": []})
        self.http.database.upload_object(sha(data), data)
        body = {"syncID": uid(), "baseDocumentDigest": None, "manifest": m, "scenes": {bid + "/" + page["id"]: sha(data)}}
        status, response = self.request("/v2/documents/" + bid + "/state", body)
        self.assertEqual(status, 422)
        self.assertEqual(response["error"]["code"], "invalid_scene")
        self.assertIsNone(self.client.document_state(bid)["lastSyncedAt"])
        self.assertEqual(self.request("/v2/sync-receipts/" + body["syncID"])[0], 404)


if __name__ == "__main__":
    unittest.main()
