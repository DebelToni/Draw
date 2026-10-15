"""Fabricated source GETs only, never production notes, app installs or workers."""
import copy
import gzip
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from benchmarks.draw_ai import capture
from notes_service.tests.fixtures import image, uid
from notes_service.validation import no_native_history
from server.server import canonical


def digest(data):
    return hashlib.sha256(data).hexdigest()


class FakeContent:
    def __init__(self, body):
        self.body = body

    async def iter_chunked(self, size):
        for start in range(0, len(self.body), size):
            yield self.body[start:start + size]


class FakeResponse:
    def __init__(self, body, status=200, compressed=True):
        self.status = status
        self.headers = {"Content-Encoding": "gzip"} if compressed else {}
        self.content = FakeContent(gzip.compress(body) if compressed else body)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass


class FakeSession:
    def __init__(self, owner, options):
        self.owner = owner
        self.options = options

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    def get(self, url, **options):
        self.owner.calls.append(("GET", url, options))
        path = url.removeprefix(capture.DEFAULT_ENDPOINT)
        if path.endswith("/state"):
            self.owner.state_reads += 1
            state = copy.deepcopy(self.owner.state)
            if self.owner.change_revision and self.owner.state_reads > 1:
                state["revision"] += 1
            return FakeResponse(canonical(state))
        if path.endswith("/scenes"):
            scenes = copy.deepcopy(self.owner.scenes)
            if self.owner.change_scene_revision:
                scenes["revision"] += 1
            return FakeResponse(canonical(scenes))
        if path.startswith("/v2/objects/"):
            sha = path.rsplit("/", 1)[1]
            if sha == self.owner.missing and self.owner.missing_count:
                self.owner.missing_count -= 1
                return FakeResponse(b"missing", status=404)
            if self.owner.redirect:
                return FakeResponse(b"", status=302)
            body = self.owner.objects[sha]
            if sha == self.owner.corrupt:
                body += b"tampered"
            return FakeResponse(body, compressed=self.owner.compressed)
        raise AssertionError("Unexpected route: " + path)


class CaptureTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temporary = Path.home() / "tmp"
        temporary.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="draw-stage-test-", dir=temporary)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.token = self.root / "token"
        self.token.write_text("fabricated-private-bearer\n")
        self.token.chmod(0o600)
        self.destination = self.root / "staging/example"
        self.doc, self.focus, self.deleted = uid(), uid(), uid()
        self.head, self.deleted_head, self.folder, self.parent = uid(), uid(), uid(), uid()
        self.objects = {}
        def asset(data):
            sha = digest(data)
            self.objects[sha] = data
            return sha
        self.png = asset(image(4, 4, (153, 0, 255, 255)))
        self.obj = {"id": uid(), "kind": "text", "source": "Preserved annotation", "revision": 3,
                    "frame": {"x": 4, "y": 5, "width": 2, "height": 2},
                    "style": {"fontSize": 14, "lineWidth": 1, "color": "#9900ff"},
                    "asset": {"sha256": self.png, "pixelWidth": 4, "pixelHeight": 4, "scale": 2},
                    "provenance": {"requestID": uid(), "contextSHA256": "b" * 64,
                                   "rendererSignature": "fixture-v1"}}
        def page(pid, head, objects):
            return {"id": pid, "head": head, "background": 0, "starred": False,
                    "nodes": [{"id": head, "parent": None, "children": [], "objects": objects}]}
        self.book = {"id": self.doc, "name": "Fabricated notes", "created": 42.25, "modified": 43.125,
                     "folderID": self.folder, "currentPage": self.focus, "orientation": "landscape",
                     "pages": [page(self.focus, self.head, [self.obj])],
                     "deleted": [page(self.deleted, self.deleted_head, [])]}
        # Starts with gzip magic but is NOT HTTP gzip. Do not sniff archive bytes.
        self.archive = b"\x1f\x8bexact fabricated native archive"
        manifest = {"format": 3, "notebooks": [self.book],
                    "folders": [{"id": self.folder, "name": "Leaf", "parentID": self.parent},
                                {"id": self.parent, "name": "Root"}],
                    "blobs": {f"{self.doc}/{self.focus}/{self.head}": asset(self.archive),
                              f"{self.doc}/{self.deleted}/{self.deleted_head}": asset(b"deleted archive")},
                    "assets": {self.png: self.png}}
        self.state = {"revision": 17, "documentDigest": digest(canonical(manifest)),
                      "lastSyncedAt": "2026-10-10T10:00:00Z", "manifest": manifest}
        self.scenes = {"revision": 17, "scenes": {f"{self.doc}/{pid}": asset(canonical({"format": 1, "head": h}))
                       for pid, h in [(self.focus, self.head), (self.deleted, self.deleted_head)]}}
        self.calls = []
        self.sessions = []
        self.state_reads = 0
        self.compressed = True
        self.change_revision = self.change_scene_revision = self.redirect = False
        self.corrupt = self.missing = None
        self.missing_count = 0
        def session(**options):
            result = FakeSession(self, options)
            self.sessions.append(result)
            return result
        self.patch = patch.object(capture.aiohttp, "ClientSession", side_effect=session)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    async def stage(self, page=1):
        return await capture.stage_document(capture.DEFAULT_ENDPOINT, self.token, self.doc, page, self.destination)

    async def test_current_only_native_copy_isolated_ids_exact_bytes_and_provenance(self):
        original = copy.deepcopy(self.state)
        result = await self.stage()
        provenance = capture.verify_staging(self.destination)
        native = Path(result["inputDirectory"])
        library = json.loads((native / "notebooks.json").read_bytes())
        book = library["notebooks"][0]
        mapping = provenance["identityMapping"]
        self.assertEqual(library["historySchemaVersion"], 2)
        self.assertNotIn("localHistory", library)
        self.assertNotIn("syncBaseline", library)
        self.assertEqual(book["name"], "Test " + self.book["name"])
        self.assertEqual(book["created"], 42.25)
        self.assertEqual(book["modified"], 43.125)
        self.assertEqual(book["orientation"], "landscape")
        self.assertEqual(book["currentPage"], result["target"]["focusPageID"])
        self.assertEqual(book["folderID"], mapping["folderIDs"][self.folder])
        folder = next(f for f in library["folders"] if f["id"] == book["folderID"])
        self.assertEqual(folder["parentID"], mapping["folderIDs"][self.parent])
        self.assertTrue(all(f["name"].startswith("Test ") for f in library["folders"]))
        old = {self.doc, self.focus, self.deleted, self.folder, self.parent}
        new = {book["id"], *mapping["pageIDs"].values(), *mapping["folderIDs"].values()}
        self.assertEqual(len(new), len(old))
        self.assertTrue(old.isdisjoint(new))
        for page in book["pages"] + book["deleted"]:
            self.assertEqual(len(page["nodes"]), 1)
            node = page["nodes"][0]
            self.assertEqual(node["id"], page["head"])
            self.assertEqual(node["children"], [])
            self.assertNotIn("parent", node)
            self.assertNotIn("preferredChild", node)
        self.assertEqual(book["pages"][0]["nodes"][0]["objects"], [self.obj])
        self.assertEqual((native / book["id"] / book["currentPage"] / (self.head + ".pkdraw")).read_bytes(), self.archive)
        self.assertEqual((native / "assets" / (self.png + ".png")).read_bytes(), self.objects[self.png])
        no_native_history(result["caseProvenance"])
        self.assertEqual(result["caseProvenance"]["currentObjects"][self.focus], [self.obj])
        self.assertEqual(result["caseProvenance"]["sourceManifestSHA256"], digest(canonical(original["manifest"])))
        self.assertEqual(provenance["manifest"], original["manifest"])
        self.assertEqual(provenance["revision"], 17)
        self.assertEqual(provenance["documentDigest"], original["documentDigest"])
        self.assertEqual(provenance["pageHeads"], {self.focus: self.head, self.deleted: self.deleted_head})
        self.assertEqual(provenance["sceneReferences"], self.scenes["scenes"])
        self.assertEqual(set(provenance["objectChecksums"]), set(self.objects))
        self.assertFalse((native / "stagingOriginalprovenance.json").exists())
        self.assertEqual(self.state, original)
        self.assertEqual({p.name for p in self.destination.iterdir()}, {"DrawBenchmarkInput", "stagingOriginalprovenance.json"})
        session = self.sessions[0]
        self.assertFalse(session.options["trust_env"])
        self.assertFalse(session.options["auto_decompress"])
        self.assertTrue(all(method == "GET" and not opts["allow_redirects"] for method, _, opts in self.calls))
        self.assertFalse(any("/v1/state" in url or "/v2/state" in url for _, url, _ in self.calls))
        exported = b"".join(f.read_bytes() for f in self.destination.rglob("*") if f.is_file())
        self.assertNotIn(b"fabricated-private-bearer", exported)
        self.assertNotIn(capture.DEFAULT_ENDPOINT.encode(), exported)

    async def test_uuid_focus_and_identity_http_body_not_magic(self):
        self.compressed = False
        await self.stage(self.focus.lower())
        capture.verify_staging(self.destination)

    async def test_flat_legacy_metadata_dates_and_blank_pages(self):
        manifest = self.state["manifest"]
        manifest["format"] = 1
        manifest.pop("folders")
        manifest.pop("assets")
        manifest["blobs"] = {}
        book = manifest["notebooks"][0]
        book.pop("folderID")
        book.pop("orientation")
        book["deleted"] = []
        book["pages"][0].update(head=None, nodes=[])
        self.scenes["scenes"].pop(f"{self.doc}/{self.deleted}")
        await self.stage()
        library = json.loads((self.destination / "DrawBenchmarkInput/notebooks.json").read_bytes())
        self.assertEqual(library["folders"], [])
        self.assertNotIn("orientation", library["notebooks"][0])
        self.assertEqual(library["notebooks"][0]["pages"][0]["nodes"], [])

    async def test_bad_focus_rejected_without_publication(self):
        for page in (0, 2, self.deleted, uid()):
            with self.subTest(page=page), self.assertRaises(ValueError):
                await self.stage(page)
        self.assertFalse(self.destination.exists())

    async def test_checksum_failure_no_partial_stage(self):
        self.corrupt = digest(self.archive)
        with self.assertRaisesRegex(ValueError, "checksum"):
            await self.stage()
        self.assertFalse(self.destination.exists())
        self.assertFalse(self.destination.parent.exists())

    async def test_revision_changes_fail_closed_even_after_objects_downloaded(self):
        self.change_revision = True
        with self.assertRaisesRegex(ValueError, "revision changed"):
            await self.stage()
        self.assertFalse(self.destination.exists())

    async def test_scene_revision_mismatch(self):
        self.change_scene_revision = True
        with self.assertRaisesRegex(ValueError, "revision changed"):
            await self.stage()
        self.assertFalse(any("/objects/" in url for _, url, _ in self.calls))

    async def test_gc_missing_retry_rechecks_same_source(self):
        self.missing = digest(self.archive)
        self.missing_count = 1
        await self.stage()
        self.assertEqual(self.state_reads, 3)
        self.assertEqual(sum(url.endswith(self.missing) for _, url, _ in self.calls), 2)

    async def test_gc_missing_never_switches_to_new_current_revision(self):
        self.missing = digest(self.archive)
        self.missing_count = 1
        self.change_revision = True
        with self.assertRaisesRegex(ValueError, "revision changed"):
            await self.stage()
        self.assertEqual(sum(url.endswith(self.missing) for _, url, _ in self.calls), 1)

    async def test_missing_object_retry_bounded(self):
        self.missing = digest(self.archive)
        self.missing_count = 99
        with self.assertRaisesRegex(ValueError, "disappeared"):
            await self.stage()
        self.assertEqual(sum(url.endswith(self.missing) for _, url, _ in self.calls), 3)
        self.assertFalse(self.destination.exists())

    async def test_redirect_rejected_without_following(self):
        self.redirect = True
        with self.assertRaisesRegex(ValueError, "HTTP 302"):
            await self.stage()
        self.assertTrue(all(not options["allow_redirects"] for _, _, options in self.calls))

    async def test_endpoint_token_and_destination_safety_before_http(self):
        for endpoint in ("https://public.invalid", "http://127.0.0.1:18881", "http://user@127.0.0.1:18874"):
            with self.assertRaisesRegex(ValueError, "loopback"):
                await capture.stage_document(endpoint, self.token, self.doc, 1, self.destination)
        self.token.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "owner-only"):
            await self.stage()
        self.token.chmod(0o600)
        self.destination.mkdir(parents=True)
        marker = self.destination / "existing"
        marker.write_bytes(b"keep")
        with self.assertRaises(FileExistsError):
            await self.stage()
        self.assertEqual(marker.read_bytes(), b"keep")
        self.assertEqual(self.calls, [])

    async def test_tampering_and_symlinks_rejected(self):
        await self.stage()
        native = self.destination / "DrawBenchmarkInput"
        file = native / "assets" / (self.png + ".png")
        file.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum"):
            capture.verify_staging(self.destination)
        file.unlink()
        file.symlink_to(self.token)
        with self.assertRaises(Exception):
            capture.verify_staging(self.destination)

    async def test_snapshot_tamper_detected_even_if_inventory_is_rehashed(self):
        result = await self.stage()
        target = result["target"]
        name = f'{target["documentID"]}/{target["focusPageID"]}/{self.head}.pkdraw'
        data = b"different native head"
        (self.destination / "DrawBenchmarkInput" / name).write_bytes(data)
        file = self.destination / "stagingOriginalprovenance.json"
        provenance = json.loads(file.read_bytes())
        provenance["files"][name] = {"sha256": digest(data), "size": len(data)}
        file.write_bytes(canonical(provenance))
        with self.assertRaisesRegex(ValueError, "pinned source SHA"):
            capture.verify_staging(self.destination)

    async def test_extra_empty_directory_is_not_accepted(self):
        await self.stage()
        (self.destination / "DrawBenchmarkInput/unexpected").mkdir()
        with self.assertRaisesRegex(ValueError, "checksum"):
            capture.verify_staging(self.destination)

    async def test_mapping_cannot_reuse_original_ids_even_with_new_inventory(self):
        await self.stage()
        file = self.destination / "stagingOriginalprovenance.json"
        provenance = json.loads(file.read_bytes())
        provenance["identityMapping"]["documentID"]["isolated"] = self.doc
        file.write_bytes(canonical(provenance))
        with self.assertRaisesRegex(ValueError, "isolated"):
            capture.verify_staging(self.destination)

    async def test_unrelated_folders_rejected(self):
        self.state["manifest"]["folders"].append({"id": uid(), "name": "Unrelated"})
        with self.assertRaisesRegex(ValueError, "unrelated"):
            await self.stage()
        self.assertFalse(any("/objects/" in url for _, url, _ in self.calls))

    def test_gzip_trailing_incomplete_and_overflow_rejected(self):
        for body in (gzip.compress(b"abc") + b"junk", gzip.compress(b"abc")[:-2]):
            with self.assertRaises(ValueError):
                capture.decode_body(body, "gzip", 100)
        with self.assertRaises(Exception):
            capture.decode_body(gzip.compress(b"x" * 10000), "gzip", 100)


if __name__ == "__main__":
    unittest.main()
