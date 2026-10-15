"""Read-only authenticated loopback Sync adapter. Opaque document digest authority."""
import io
from urllib.parse import urlsplit
from PIL import Image
from . import validation as check
from .storage import Problem, MAX_ASSET, decoded, require, sha, utc, uuid


class SyncSource:
    def __init__(self, http, token, base="http://127.0.0.1:18874"):
        url = urlsplit(base)
        require(url.scheme == "http" and url.hostname == "127.0.0.1" and not url.username and
                not url.password and not url.query and not url.fragment,
                "invalid_source", "Sync source must be authenticated loopback HTTP")
        self.http, self.token, self.base = http, token, base.rstrip("/")

    async def get(self, path, raw=False):
        try:
            async with self.http.get(self.base+path, headers={"Authorization": "Bearer "+self.token}, allow_redirects=False) as response:
                require(response.status == 200, "sync_unavailable", "Read-only Sync request failed", 409)
                data = bytearray()
                async for chunk in response.content.iter_chunked(65536):
                    require(len(data)+len(chunk) <= MAX_ASSET, "asset_limit", "Sync artifact exceeds limit", 413)
                    data.extend(chunk)
                return bytes(data) if raw else decoded(data)
        except Problem:
            raise
        except Exception:
            raise Problem("sync_unavailable", "Read-only Sync request unavailable", 409) from None

    async def document_state(self, doc):
        return await self.get("/v2/documents/"+uuid(doc)+"/state")

    async def sync_receipt(self, sid):
        return await self.get("/v2/sync-receipts/"+uuid(sid))

    async def folders(self):
        folders = (await self.get("/v1/folders")).get("folders", [])
        check.folder_paths(folders)
        return folders

    @staticmethod
    def manifest_labels(manifest, doc):
        require(isinstance(manifest, dict) and type(manifest.get("format")) is int and
                manifest["format"] in (1, 2, 3), "sync_document", "Unsupported source format", 409)
        books = manifest.get("notebooks", [])
        require(isinstance(books, list) and len(books) == 1 and isinstance(books[0], dict) and
                books[0].get("id") == doc, "sync_document", "Unexpected single-document source", 409)
        book = books[0]
        folders = manifest.get("folders")
        paths = check.folder_paths([] if folders is None else folders, nested=manifest["format"] == 3)
        fid = book.get("folderID")
        if fid is not None:
            uuid(fid)
            require(fid in paths, "invalid_folders", "Document folder missing from source graph", 409)
        labels = {"folderName": paths[fid] if fid is not None else "Home",
                  "documentName": book.get("name", "Untitled"), "folderID": fid}
        check.labels(labels)
        return book, labels

    async def worker_labels(self, doc):
        state = await self.document_state(doc)
        manifest = state.get("manifest")
        require(manifest is not None, "document_not_synced", "Keep native captured labels until this document is first synced", 409)
        _, labels = self.manifest_labels(manifest, doc)
        return {**labels,
                "documentDigest": state.get("documentDigest"), "lastSyncedAt": state.get("lastSyncedAt")}

    async def labels(self, doc):
        value = await self.worker_labels(doc)
        return value["folderName"], value["documentName"]

    async def stale_context(self, doc, focus, store):
        state = await self.document_state(doc)
        manifest = state.get("manifest")
        require(manifest is not None and state.get("lastSyncedAt") is not None, "synced_context_unavailable", "Document has no confirmed Sync snapshot", 409)
        document_digest = sha(state.get("documentDigest"))
        book, labels = self.manifest_labels(manifest, doc)
        refs = await self.get("/v2/documents/"+uuid(doc)+"/scenes")
        require(refs.get("revision") == state["revision"], "sync_changed", "Sync changed while pinning context; retry explicit choice", 409)
        for digest in manifest.get("assets", {}).values():
            store.put_asset(digest, await self.get("/v2/objects/"+sha(digest), raw=True))
        pages = []
        for page in book["pages"]:
            pid = uuid(page["id"])
            scene_digest = refs["scenes"].get(doc+"/"+pid)
            require(scene_digest is not None, "synced_context_unavailable", "Portable scene missing; open Draw and Sync", 409)
            scene_data = await self.get("/v2/objects/"+sha(scene_digest), raw=True)
            store.put_asset(scene_digest, scene_data)
            scene = decoded(scene_data, limit=MAX_ASSET)
            png = await self.get("/v1/documents/"+doc+"/pages/"+pid+".png?revision="+str(state["revision"]), raw=True)
            composite = store.put_bytes(png)
            with Image.open(io.BytesIO(png)) as image:
                w, h = image.size
            blank = io.BytesIO()
            Image.new("RGBA", (w,h)).save(blank, format="PNG")
            empty = store.put_bytes(blank.getvalue())
            pages.append({"pageID": pid, "head": page.get("head"), "background": scene.get("background", 2),
                          "width": w/2, "height": h/2, "objects": scene.get("objects", []),
                          "paperSHA256": composite, "inkSHA256": empty, "compositeSHA256": composite,
                          "portableSHA256": scene_digest, "strokeTargets": []})
        require(pages, "synced_context_unavailable", "Synced document has no live pages", 409)
        # Final digest/revision check proves metadata and scene/image reads share one publication.
        latest = await self.document_state(doc)
        latest_refs = await self.get("/v2/documents/"+uuid(doc)+"/scenes")
        require(latest_refs == refs, "sync_changed", "Portable scenes changed while capturing stale context; retry explicit choice", 409)
        require(latest["revision"] == state["revision"] and latest["documentDigest"] == document_digest,
                "sync_changed", "Sync changed while capturing stale context; retry explicit choice", 409)
        return {"format": 1, "documentID": doc, "focusPageID": focus or pages[0]["pageID"],
                "capturedAt": utc(), "rendererSignature": "server-synced-preview-v1",
                "orientation": book.get("orientation", "portrait"), "pages": pages,
                "nativeLayerUnavailable": True, "previewLabel": "stale/native-layer-unavailable",
                "documentDigest": document_digest, "lastSyncedAt": state["lastSyncedAt"],
                **labels}
