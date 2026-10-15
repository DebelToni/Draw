import copy
import hashlib
import io
from uuid import uuid4
from PIL import Image
from notes_service.storage import encoded, utc


def uid():
    return str(uuid4()).upper()


def image(w=64, h=64, color=(255,255,255,255)):
    stream = io.BytesIO()
    Image.new("RGBA", (w,h), color).save(stream, format="PNG")
    return stream.getvalue()


def context(manager, doc, page=None):
    page = page or uid()
    store = manager.store
    paper = store.put_bytes(image())
    ink = store.put_bytes(image(color=(0,0,0,0)))
    portable = store.put_bytes(encoded({"format": 1, "head": None, "width": 32, "height": 32, "background": 0, "objects": [], "strokes": []}))
    value = {"format": 1, "documentID": doc, "focusPageID": page, "capturedAt": utc(),
             "rendererSignature": "native-capture-v1", "orientation": "portrait",
             "pages": [{"pageID": page, "head": None, "background": 0, "width": 32, "height": 32,
                        "objects": [], "paperSHA256": paper, "inkSHA256": ink,
                        "compositeSHA256": paper, "portableSHA256": portable, "strokeTargets": []}]}
    return value, store.put_bytes(encoded(value))


def draft(page, oid=None):
    return {"expectedDraftVersion": 0, "pageEdits": [{"pageID": page, "objectEdits": [{"op": "add", "object": {
        "id": oid or uid(), "kind": "text", "source": "Answer", "frame": {"x": 0, "y": 0, "width": 16, "height": 8},
        "style": {"fontSize": 14, "color": "#000000", "lineWidth": 1}}}]}]}


class Renderer:
    def __init__(self):
        self.calls = 0
        self.fail = False
        self.bad_preview = False
        self.bad_provenance = False
        self.started = None
        self.release = None

    async def render(self, ctx, draft, rid, digest):
        self.calls += 1
        if self.started:
            self.started.set()
            await self.release.wait()
        if self.fail:
            raise ValueError("sensitive content must not escape")
        edits = copy.deepcopy(draft["pageEdits"])
        objects, assets = [], {}
        data = image(4,4,(0,0,0,255))
        asset_sha = hashlib.sha256(data).hexdigest()
        for edit in edits:
            for op in edit.get("objectEdits", []):
                if op["op"] != "add":
                    op["expectedObject"] = copy.deepcopy(next(o for p in ctx["pages"] for o in p["objects"] if o["id"] == op["objectID"]))
                if op["op"] == "remove":
                    continue
                obj = op["object"]
                obj["frame"]["width"] = obj["frame"]["height"] = 2
                obj["revision"] = 1 if op["op"] == "add" else op["expectedRevision"]+1
                obj["asset"] = {"sha256": asset_sha, "pixelWidth": 4, "pixelHeight": 4, "scale": 2}
                obj["provenance"] = {"requestID": uid() if self.bad_provenance else rid, "contextSHA256": digest, "rendererSignature": "fixture-render-v1"}
                objects.append(obj)
                assets[asset_sha] = data
        pages = {e["pageID"] for e in edits} | {p["pageID"] for p in draft["insertPages"]}
        previews = {pid: image() for pid in pages}
        if self.bad_preview:
            previews = {}
        return {"pageEdits": edits, "insertPages": copy.deepcopy(draft["insertPages"]),
                "objects": objects, "assets": assets, "previews": previews, "rendererSignature": "fixture-render-v1"}


class Source:
    def __init__(self):
        self.receipts = {}
        self.state = {"revision": 1, "documentDigest": "a"*64, "lastSyncedAt": utc()}
        self.context = None
        self.calls = []

    async def labels(self, doc):
        return "Home", "Note-"+doc[:8]

    async def document_state(self, doc):
        self.calls.append(("state", doc))
        return self.state

    async def sync_receipt(self, sid):
        self.calls.append(("receipt", sid))
        return self.receipts[sid]

    async def stale_context(self, doc, focus, store):
        self.calls.append(("stale", doc))
        return copy.deepcopy(self.context)
