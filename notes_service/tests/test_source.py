import copy
import hashlib
import tempfile
import unittest
from pathlib import Path
from notes_service.source import SyncSource
from notes_service import validation as check
from notes_service.storage import Store, Problem, encoded, utc
from notes_service.tests.fixtures import uid, image


class Response:
    def __init__(self, data, status=200):
        self.data, self.status, self.content = data, status, self
    async def __aenter__(self): return self
    async def __aexit__(self, *args): pass
    async def iter_chunked(self, size):
        for start in range(0, len(self.data), size):
            yield self.data[start:start+size]


class HTTP:
    def __init__(self, mapping):
        self.mapping, self.calls, self.count = mapping, [], {}
    def get(self, url, headers, allow_redirects):
        self.calls.append((url, headers, allow_redirects))
        path = url.removeprefix("http://127.0.0.1:18874")
        self.count[path] = self.count.get(path, 0)+1
        value = self.mapping[path]
        if callable(value): value = value(self.count[path])
        if isinstance(value, Response): return value
        return Response(value if isinstance(value, bytes) else encoded(value))


class SourceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name)/"state")
        self.doc, self.page = uid(), uid()
        self.scene = encoded({"format": 1, "head": None, "width": 32, "height": 32, "background": 0, "objects": [], "strokes": []})
        self.digest = hashlib.sha256(self.scene).hexdigest()
        self.state = {"revision": 4, "documentDigest": "e"*64, "lastSyncedAt": utc(), "manifest": {
            "format": 1, "notebooks": [{"id": self.doc, "name": "Fixture", "pages": [{"id": self.page, "head": None, "nodes": []}], "deleted": []}], "blobs": {}}}
        self.refs = {"revision": 4, "scenes": {self.doc+"/"+self.page: self.digest}}
        self.state_path = "/v2/documents/"+self.doc+"/state"
        self.refs_path = "/v2/documents/"+self.doc+"/scenes"
        self.http = HTTP({self.state_path: self.state, self.refs_path: self.refs,
                          "/v2/objects/"+self.digest: self.scene,
                          "/v1/documents/"+self.doc+"/pages/"+self.page+".png?revision=4": image()})
        self.source = SyncSource(self.http, "never-print-this")

    async def asyncTearDown(self):
        self.store.close(); self.temp.cleanup()

    async def test_stale_pin_labels_and_exact_server_digest(self):
        ctx = await self.source.stale_context(self.doc, self.page, self.store)
        self.assertTrue(ctx["nativeLayerUnavailable"])
        self.assertEqual(ctx["documentDigest"], "e"*64)
        self.assertEqual(ctx["rendererSignature"], "server-synced-preview-v1")
        self.assertEqual(ctx["pages"][0]["paperSHA256"], ctx["pages"][0]["compositeSHA256"])
        self.assertEqual(self.store.read_asset(ctx["pages"][0]["portableSHA256"]), self.scene)
        self.assertTrue(all(c[1] == {"Authorization": "Bearer never-print-this"} and c[2] is False for c in self.http.calls))
        self.assertTrue(all("never-print-this" not in c[0] for c in self.http.calls))

    async def test_historical_highlight_from_source_survives_stale_and_native_validators(self):
        for source_format in (2, 3):
            with self.subTest(format=source_format):
                data = image(8, 4, (0, 184, 217, 51))
                digest, head = hashlib.sha256(data).hexdigest(), uid()
                obj = {"id": uid(), "revision": 1, "kind": "highlight", "source": '{"opacity":0.2}',
                       "frame": {"x": 2, "y": -1, "width": 4, "height": 2},
                       "style": {"fontSize": 14, "color": "#00B8D9", "lineWidth": 1},
                       "asset": {"sha256": digest, "pixelWidth": 8, "pixelHeight": 4, "scale": 2},
                       "provenance": {"requestID": uid(), "contextSHA256": "a"*64,
                                      "rendererSignature": "draw-ai-render-v1"}}
                scene = encoded({"format": 1, "head": head, "width": 32, "height": 32,
                                 "background": 0, "objects": [obj], "strokes": []})
                scene_sha = hashlib.sha256(scene).hexdigest()
                manifest = self.state["manifest"]
                manifest.update(format=source_format, assets={digest: digest})
                manifest["notebooks"][0]["pages"][0].update(head=head, nodes=[{"id": head, "objects": [obj]}])
                self.refs["scenes"][self.doc+"/"+self.page] = scene_sha
                self.http.mapping["/v2/objects/"+scene_sha] = scene
                self.http.mapping["/v2/objects/"+digest] = data
                before = copy.deepcopy(manifest)
                ctx = await self.source.stale_context(self.doc, self.page, self.store)
                self.assertEqual(ctx["pages"][0]["objects"], [obj])
                self.assertEqual(self.store.read_asset(digest), data)
                check.context(ctx, self.store.read_asset, self.doc, self.page)
                native = {key: value for key, value in ctx.items() if key not in
                          ("nativeLayerUnavailable", "previewLabel", "documentDigest", "lastSyncedAt")}
                native["rendererSignature"] = "native-capture-v1"
                check.context(native, self.store.read_asset, self.doc, self.page)
                self.assertEqual(manifest, before)
                bad = copy.deepcopy(ctx)
                bad["pages"][0]["objects"][0]["kind"] = "future-highlight"
                with self.assertRaises(Problem):
                    check.context(bad, self.store.read_asset, self.doc, self.page)

    async def test_same_revision_scene_refresh_stops_pin(self):
        self.http.mapping[self.refs_path] = lambda count: self.refs if count == 1 else {"revision": 4, "scenes": {self.doc+"/"+self.page: "0"*64}}
        with self.assertRaises(Problem) as e:
            await self.source.stale_context(self.doc, self.page, self.store)
        self.assertEqual(e.exception.code, "sync_changed")

    async def test_source_revision_race_stops_pin(self):
        self.http.mapping[self.state_path] = lambda count: self.state if count == 1 else {**self.state, "revision": 5}
        with self.assertRaises(Problem) as e:
            await self.source.stale_context(self.doc, self.page, self.store)
        self.assertEqual(e.exception.code, "sync_changed")

    async def test_absent_or_never_confirmed_source_cannot_be_used(self):
        self.http.mapping[self.state_path] = {**self.state, "lastSyncedAt": None}
        with self.assertRaises(Problem) as e:
            await self.source.stale_context(self.doc, self.page, self.store)
        self.assertEqual(e.exception.code, "synced_context_unavailable")

    async def test_loopback_only_no_credential_redirect(self):
        with self.assertRaises(Problem):
            SyncSource(self.http, "secret", "https://example.com")
        self.http.mapping[self.state_path] = Response(b"redirect", 302)
        with self.assertRaises(Problem) as e:
            await self.source.document_state(self.doc)
        self.assertEqual(e.exception.code, "sync_unavailable")
        self.assertNotIn("never-print-this", str(e.exception))

    async def test_worker_labels_preserve_folder_uuid_not_duplicate_name(self):
        first, second = uid(), uid()
        self.state["manifest"]["folders"] = [{"id": first, "name": "Math"}, {"id": second, "name": "Math"}]
        self.state["manifest"]["notebooks"][0]["folderID"] = second
        self.assertEqual(await self.source.worker_labels(self.doc), {"documentName": "Fixture", "folderName": "Math", "folderID": second, "documentDigest": self.state["documentDigest"], "lastSyncedAt": self.state["lastSyncedAt"]})

    async def test_format_three_full_ancestor_labels_and_stale_metadata(self):
        root, leaf = uid(), uid()
        manifest = self.state["manifest"]
        manifest.update(format=3, folders=[{"id": leaf, "name": "Math", "parentID": root},
                                           {"id": root, "name": "Semester", "parentID": None}])
        manifest["notebooks"][0]["folderID"] = leaf
        self.assertEqual(await self.source.labels(self.doc), ("Semester / Math", "Fixture"))
        labels = await self.source.worker_labels(self.doc)
        self.assertEqual(labels["folderID"], leaf)
        ctx = await self.source.stale_context(self.doc, self.page, self.store)
        self.assertEqual((ctx["folderName"], ctx["folderID"]), ("Semester / Math", leaf))
        self.assertEqual(manifest["folders"][0]["parentID"], root)
        self.assertNotIn("sourceManifestSHA256", ctx)

    async def test_long_logical_path_survives_source_and_native_context_validation(self):
        folders, parent, names = [], None, []
        for index in range(11):
            fid, name = uid(), str(index).zfill(2)+"x"*94
            folders.append({"id": fid, "name": name, "parentID": parent})
            parent = fid
            names.append(name)
        manifest = self.state["manifest"]
        manifest.update(format=3, folders=folders)
        manifest["notebooks"][0]["folderID"] = parent
        full_path = " / ".join(names)
        self.assertGreater(len(full_path.encode()), 1024)
        self.assertEqual(await self.source.labels(self.doc), (full_path, "Fixture"))
        ctx = await self.source.stale_context(self.doc, self.page, self.store)
        self.assertEqual(ctx["folderName"], full_path)
        self.assertEqual(ctx["folderID"], parent)
        check.context(ctx, self.store.read_asset, self.doc, self.page)
        native = {key: value for key, value in ctx.items() if key not in ("nativeLayerUnavailable", "previewLabel")}
        check.context(native, self.store.read_asset, self.doc, self.page)

    async def test_full_path_byte_bound_is_distinct_from_individual_name_bound(self):
        exact = "é"*32768
        check.labels({"folderName": exact, "documentName": "é"*512})
        for labels in ({"folderName": exact+"é"}, {"documentName": "é"*513}):
            with self.subTest(labels=list(labels)), self.assertRaises(Problem):
                check.labels(labels)
        fid = uid()
        with self.assertRaises(Problem):
            check.folder_paths([{"id": fid, "name": "é"*513}])
        folders, parent = [], None
        for index in range(64):
            fid = uid()
            folders.append({"id": fid, "name": "x"*1024, "parentID": parent})
            parent = fid
        with self.assertRaises(Problem):
            check.folder_paths(folders)  # Individually valid names, but a path over 64 KiB.

    async def test_legacy_flat_formats_keep_existing_labels(self):
        fid = uid()
        for format in (1, 2):
            self.state["manifest"].update(format=format, folders=[{"id": fid, "name": "Math"}])
            self.state["manifest"]["notebooks"][0]["folderID"] = fid
            self.assertEqual(await self.source.labels(self.doc), ("Math", "Fixture"))

    async def test_invalid_folder_graph_rejected_before_stale_asset_reads(self):
        root, leaf = uid(), uid()
        manifest = self.state["manifest"]
        manifest.update(format=3)
        manifest["notebooks"][0]["folderID"] = leaf
        cases = ([{"id": leaf, "name": "Math", "parentID": root}],
                 [{"id": leaf, "name": "Math", "parentID": leaf}],
                 [{"id": leaf, "name": "Math", "parentID": root},
                  {"id": root, "name": "Semester", "parentID": leaf}],
                 [{"id": leaf, "name": "Math"}, {"id": leaf, "name": "Duplicate"}],
                 [{"id": leaf, "name": "Math", "parentID": "invalid"}],
                 [{"id": root, "name": "Semester"}],
                 [{"id": leaf, "name": "Bad\nname"}])
        for folders in cases:
            with self.subTest(folders=folders):
                manifest["folders"] = folders
                self.http.calls.clear()
                with self.assertRaises(Problem):
                    await self.source.worker_labels(self.doc)
                with self.assertRaises(Problem):
                    await self.source.stale_context(self.doc, self.page, self.store)
                self.assertTrue(all(call[0].endswith("/state") for call in self.http.calls))

    async def test_folder_listing_preserves_nested_empty_folder_graph(self):
        root, empty = uid(), uid()
        folders = [{"id": root, "name": "Semester", "documentCount": 0},
                   {"id": empty, "name": "Empty", "parentID": root, "documentCount": 0}]
        self.http.mapping["/v1/folders"] = {"revision": 4, "folders": folders}
        self.assertEqual(await self.source.folders(), folders)

    async def test_unpublished_source_cannot_overwrite_native_labels(self):
        self.http.mapping[self.state_path] = {**self.state, "manifest": None}
        with self.assertRaises(Problem) as error:
            await self.source.worker_labels(self.doc)
        self.assertEqual(error.exception.code, "document_not_synced")

    async def test_stale_capture_never_fetches_or_stores_native_blobs(self):
        raw = b"bplist00native-current-snapshot"
        digest = hashlib.sha256(raw).hexdigest()
        self.state["manifest"]["blobs"] = {self.doc+"/"+self.page+"/"+uid(): digest}
        self.http.mapping["/v2/objects/"+digest] = raw
        await self.source.stale_context(self.doc, self.page, self.store)
        self.assertFalse(self.store.path(digest).exists())
        self.assertNotIn("/v2/objects/"+digest, self.http.count)

    async def test_labels_are_not_identity_keys(self):
        self.assertEqual(await self.source.labels(self.doc), ("Home", "Fixture"))
        self.state["manifest"]["notebooks"][0]["id"] = uid()
        with self.assertRaises(Problem) as e:
            await self.source.labels(self.doc)
        self.assertEqual(e.exception.code, "sync_document")


if __name__ == "__main__":
    unittest.main()
