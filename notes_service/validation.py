"""Validate request boundaries before any worker can see a context."""
import io
import math
import re
from datetime import datetime
from PIL import Image
from .storage import MAX_ASSET, decoded, require, sha, uuid
from server.ai_models import KINDS, validate_asset, validate_object, validate_highlight_source


def no_native_history(value, depth=0):
    require(depth <= 64, "metadata_limit", "JSON nesting exceeds limit", 413)
    forbidden = {"blobs", "notebooks", "undohistory", "undograph", "historynodes", "nativearchive", "nativearchives",
                 "nativesnapshots", "nativedrawing", "pkdrawing", "pkdraw", "undostack", "redostack"}
    if isinstance(value, dict):
        for key, child in value.items():
            require(re.sub(r"[^a-z0-9]", "", key.lower()) not in forbidden,
                    "native_archive_forbidden", "Notes artifacts cannot contain native archives or Undo history")
            no_native_history(child, depth+1)
    elif isinstance(value, list):
        for child in value:
            no_native_history(child, depth+1)


def portable_scene(value):
    require(isinstance(value, dict) and set(value) <= {"format", "head", "width", "height", "background", "objects", "strokes"},
            "invalid_scene", "Portable scenes contain current public fields only")
    strokes = value.get("strokes")
    require(isinstance(strokes, list), "invalid_scene", "Expected current strokes")
    allowed = {"id", "pathID", "renderGroupID", "inkType", "color", "transform", "randomSeed", "creationDate",
               "grainOffset", "points", "samples", "mask"}
    for stroke in strokes:
        require(isinstance(stroke, dict) and set(stroke) <= allowed, "invalid_scene", "Unsupported portable stroke fields")
        if stroke.get("mask") is not None:
            require(isinstance(stroke["mask"], dict) and set(stroke["mask"]) == {"evenOdd", "commands"},
                    "invalid_scene", "Unsupported portable mask fields")
    from server.portable import validate_page
    try:
        validate_page(value)
    except (ValueError, KeyError, TypeError):
        require(False, "invalid_scene", "Invalid bounded current portable scene")
    return value


def artifact(data):
    if data.startswith(b"\x89PNG"):
        png(data)
        return
    value = decoded(data, limit=MAX_ASSET)
    require(isinstance(value, dict), "invalid_asset", "Notes CAS accepts PNG or JSON objects only")
    no_native_history(value)
    if "strokes" in value or {"head", "width", "height"} <= set(value):
        portable_scene(value)


MAX_NAME_BYTES = 1024
MAX_FOLDER_PATH_BYTES = 65536


def readable_label(text, limit):
    require(isinstance(text, str) and text.strip() and len(text.encode()) <= limit and
            not any(ord(c) < 32 or ord(c) == 127 for c in text),
            "invalid_label", "Document/folder labels must be bounded readable strings")


def labels(value):
    # folderName carries a full logical path in both native and stale captures.
    for key, limit in (("documentName", MAX_NAME_BYTES), ("folderName", MAX_FOLDER_PATH_BYTES)):
        if value.get(key) is not None:
            readable_label(value[key], limit)
    if value.get("folderID") is not None:
        uuid(value["folderID"])
    require("sourceManifestSHA256" not in value, "native_archive_forbidden",
            "Notes context cannot reference native source archives; use capture metadata and image/portable assets")


def folder_paths(folders, nested=True):
    """Validate a complete folder forest (or document ancestor chain), without flattening it."""
    require(isinstance(folders, list), "invalid_folders", "Expected folder metadata")
    graph = {}
    for folder in folders:
        require(isinstance(folder, dict), "invalid_folders", "Expected folder metadata")
        fid = uuid(folder.get("id"))
        require(fid not in graph, "invalid_folders", "Duplicate folder ID")
        require(folder.get("name") is not None, "invalid_folders", "Missing folder name")
        readable_label(folder["name"], MAX_NAME_BYTES)
        parent = folder.get("parentID")
        if parent is not None:
            uuid(parent)
            require(nested, "invalid_folders", "Legacy source folders must be flat")
        graph[fid] = folder
    paths = {}
    for fid in graph:
        chain, seen, current = [], set(), fid
        while current is not None and current not in paths:
            require(current in graph, "invalid_folders", "Missing folder ancestor")
            require(current not in seen, "invalid_folders", "Folder cycle")
            seen.add(current)
            chain.append(current)
            current = graph[current].get("parentID")
        prefix = paths.get(current, "")
        for child in reversed(chain):
            prefix = prefix + " / " + graph[child]["name"] if prefix else graph[child]["name"]
            readable_label(prefix, MAX_FOLDER_PATH_BYTES)
            paths[child] = prefix
    return paths


def timestamp(value):
    try:
        require(isinstance(value, str) and value.endswith("Z"), "invalid_timestamp", "Expected UTC timestamp")
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        require(False, "invalid_timestamp", "Expected UTC timestamp")


def number(value, positive=False):
    require(type(value) in (int, float) and math.isfinite(value) and
            (not positive or value > 0), "invalid_number", "Invalid finite geometry")
    return value


def integer(value, minimum=0):
    require(type(value) is int and value >= minimum, "invalid_integer", "Invalid integer")
    return value


def frame(value):
    require(isinstance(value, dict) and set(value) == {"x", "y", "width", "height"},
            "invalid_frame", "Expected page-point frame")
    for key, v in value.items():
        number(v)
        if key in ("width", "height"):
            require(v >= 0, "invalid_frame", "Negative dimensions")


def color(value):
    require(isinstance(value, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", value),
            "invalid_color", "Expected #RRGGBB")


def png(data):
    try:
        with Image.open(io.BytesIO(data)) as image:
            require(image.format == "PNG", "invalid_png", "Expected PNG")
            w, h = image.size
            require(0 < w <= 8192 and 0 < h <= 8192 and w*h <= 32_000_000,
                    "pixel_limit", "PNG exceeds image limits", 413)
            require(getattr(image, "n_frames", 1) == 1, "invalid_png", "Animated PNG not supported")
            image.verify()
            return w, h
    except (OSError, ValueError, Image.DecompressionBombError):
        require(False, "invalid_png", "Invalid PNG")


def descriptor(value, read_asset):
    require(isinstance(value, dict) and value.get("scale") == 2,
            "invalid_asset", "Expected 2 pixels per point asset")
    dims = integer(value.get("pixelWidth"), 1), integer(value.get("pixelHeight"), 1)
    data = read_asset(sha(value.get("sha256")))
    require(png(data) == dims, "invalid_asset", "Asset dimensions mismatch")
    try:
        validate_asset(data, value)
    except ValueError:
        require(False, "invalid_asset", "Asset must be verified bounded sRGB RGBA8 PNG")


def canonical_stroke_edits(edits):
    # Draft deltas may be fractional; only these resolved grid values are approved.
    return [{**op, **({key: round(op[key]*2)/2 for key in ("dx", "dy")} if op["op"] == "move" else {})}
            for op in edits]


def object_translation(value, captured):
    return (isinstance(value, dict) and isinstance(value.get("frame"), dict) and
            all(value.get(key) == captured[key] for key in ("id", "kind", "source", "style")) and
            all(type(value["style"].get(key)) in (int, float) for key in ("fontSize", "lineWidth")) and
            all(value["frame"].get(key) == captured["frame"][key] for key in ("width", "height")))


def object_spec(obj, read_asset=None, captured_translation=False):
    require(isinstance(obj, dict), "invalid_object", "Expected object")
    uuid(obj.get("id"))
    require(isinstance(obj.get("kind"), str) and obj["kind"] in KINDS,
            "invalid_kind", "Unsupported object kind")
    require(isinstance(obj.get("source"), str) and len(obj["source"].encode()) <= 65536,
            "source_limit", "Object source exceeds 64 KiB")
    if obj["kind"] == "highlight" and read_asset is None and not captured_translation:
        try:
            validate_highlight_source(obj["source"])
        except ValueError:
            require(False, "invalid_object", "Highlight requires rectangle JSON with exactly opacity 0.2")
    frame(obj.get("frame"))
    style = obj.get("style", {})
    require(isinstance(style, dict) and set(style) <= {"fontSize", "lineWidth", "color"},
            "invalid_style", "Unsupported style")
    number(style.get("fontSize", 18), True)
    number(style.get("lineWidth", 1), True)
    color(style.get("color", "#00B8D9" if obj["kind"] == "highlight" else "#000000"))
    if read_asset:
        try:
            validate_object(obj)
        except ValueError:
            require(False, "invalid_object", "Resolved object structure/frame/asset mismatch")
        integer(obj.get("revision"), 1)
        descriptor(obj.get("asset"), read_asset)
        provenance = obj.get("provenance", {})
        uuid(provenance.get("requestID"))
        sha(provenance.get("contextSHA256"))
        require(isinstance(provenance.get("rendererSignature"), str), "invalid_provenance", "Missing renderer signature")


def context(value, read_asset, document_id, focus=None):
    require(isinstance(value, dict) and type(value.get("format")) is int and value["format"] == 1,
            "invalid_context", "Unsupported context format")
    require(uuid(value.get("documentID")) == document_id, "context_document", "Context belongs to another document")
    captured_focus = uuid(value.get("focusPageID"))
    require(focus is None or captured_focus == focus, "context_focus", "Context focus does not match request")
    require(value.get("orientation") in ("portrait", "landscape"), "invalid_orientation", "Invalid document orientation")
    require(isinstance(value.get("rendererSignature"), str), "invalid_context", "Missing capture signature")
    timestamp(value.get("capturedAt"))
    labels(value)
    if value.get("documentDigest") is not None:
        sha(value["documentDigest"])
    require(set(value) <= {"format", "documentID", "focusPageID", "capturedAt", "rendererSignature", "orientation", "pages",
                           "documentName", "folderName", "folderID", "nativeLayerUnavailable", "documentDigest", "lastSyncedAt", "previewLabel"},
            "invalid_context", "Unsupported context metadata")
    pages = value.get("pages")
    require(isinstance(pages, list) and 0 < len(pages) <= 512, "invalid_context", "Expected live document pages")
    seen, object_ids = set(), set()
    stale = value.get("nativeLayerUnavailable") is True
    for page in pages:
        require(isinstance(page, dict) and set(page) <= {"pageID", "head", "background", "width", "height", "objects", "paperSHA256", "inkSHA256", "compositeSHA256", "portableSHA256", "strokeTargets"}, "invalid_page", "Expected current captured page fields")
        pid = uuid(page.get("pageID"))
        require(pid not in seen, "invalid_context", "Duplicate page ID")
        seen.add(pid)
        if page.get("head") is not None:
            uuid(page["head"])
        require(type(page.get("background")) is int and 0 <= page["background"] <= 3,
                "invalid_paper", "Unsupported paper")
        w, h = number(page.get("width"), True), number(page.get("height"), True)
        require(w <= 4096 and h <= 4096 and w*h*4 <= 32_000_000,
                "pixel_limit", "Page geometry exceeds limits", 413)
        for layer in (("composite",) if stale else ("paper", "ink", "composite")):
            require(png(read_asset(sha(page.get(layer+"SHA256")))) == (round(w*2), round(h*2)),
                    "context_dimensions", "Captured layer dimensions do not match geometry")
        portable = portable_scene(decoded(read_asset(sha(page.get("portableSHA256"))), limit=MAX_ASSET))
        require(isinstance(portable, dict) and type(portable.get("format")) is int and portable["format"] == 1,
                "invalid_scene", "Unsupported portable scene")
        require(portable.get("head") == page.get("head") and portable.get("width") == w and portable.get("height") == h,
                "context_scene", "Portable scene does not match captured page")
        require("background" not in portable or portable["background"] == page["background"],
                "context_scene", "Portable paper does not match capture")
        require(portable.get("objects", []) == page.get("objects"), "context_scene", "Portable objects do not match capture")
        objects = page.get("objects")
        require(isinstance(objects, list) and len(objects) <= 128, "invalid_objects", "Expected object list")
        for obj in objects:
            object_spec(obj, read_asset)
            require(obj["id"] not in object_ids, "invalid_objects", "Duplicate captured object ID")
            object_ids.add(obj["id"])
        targets = page.get("strokeTargets")
        require(isinstance(targets, list) and len(targets) <= 100000, "invalid_targets", "Expected stroke targets")
        ids = set()
        for target in targets:
            require(isinstance(target, dict) and isinstance(target.get("id"), str) and
                    0 < len(target["id"]) <= 256 and target["id"] not in ids,
                    "invalid_targets", "Invalid or duplicate target identity")
            require(set(target) <= {"id", "fingerprint", "index", "asset", "frame"}, "invalid_targets", "Unsupported native target metadata")
            ids.add(target["id"])
            sha(target.get("fingerprint"))
            integer(target.get("index"))
            if "asset" in target:
                # Captures use {asset: AIAsset, frame: AIFrame}.
                descriptor(target["asset"], read_asset)
                frame(target.get("frame"))
    require(captured_focus in seen, "context_focus", "Focus page is not live")
    return value


def draft(value, ctx):
    no_native_history(value)
    inserts, edits = value.get("insertPages", []), value.get("pageEdits", [])
    require(isinstance(inserts, list) and len(inserts) <= 32 and isinstance(edits, list) and len(edits) <= 512,
            "draft_limit", "Draft exceeds page limits")
    pages = {p["pageID"]: p for p in ctx["pages"]}
    object_ids = {o["id"] for p in pages.values() for o in p["objects"]}
    new_ids, edited_pages, count = set(), set(), 0
    for page in inserts:
        require(isinstance(page, dict) and set(page) == {"pageID", "afterPageID", "background", "width", "height"}, "invalid_insert", "Expected current insertion metadata")
        pid, after = uuid(page.get("pageID")), uuid(page.get("afterPageID"))
        require(pid not in pages and after in pages, "invalid_insert", "Insertion identity/order invalid")
        require(type(page.get("background")) is int and 0 <= page["background"] <= 3, "invalid_paper", "Unsupported paper")
        w, h = number(page.get("width"), True), number(page.get("height"), True)
        base = (1024, 1361) if ctx["orientation"] == "portrait" else (1361, 1024)
        require((w, h) == base, "invalid_insert", "Inserted page must match document orientation")
        pages[pid] = {**page, "objects": [], "strokeTargets": []}
    for edit in edits:
        require(isinstance(edit, dict) and set(edit) <= {"pageID", "objectEdits", "strokeEdits"}, "invalid_edit", "Unsupported page edit fields")
        pid = uuid(edit.get("pageID"))
        require(pid in pages and pid not in edited_pages, "invalid_edit", "Invalid/duplicate destination page")
        edited_pages.add(pid)
        objects = {o["id"]: o for o in pages[pid]["objects"]}
        targets = {t["id"]: t for t in pages[pid]["strokeTargets"]}
        oe, se = edit.get("objectEdits", []), edit.get("strokeEdits", [])
        require(isinstance(oe, list) and isinstance(se, list), "invalid_edit", "Expected operation arrays")
        changed_objects, changed_strokes = set(), set()
        for operation in oe:
            require(isinstance(operation, dict) and operation.get("op") in ("add", "replace", "remove"), "invalid_operation", "Unsupported object operation")
            op = operation["op"]
            fields = {"op", "object"} if op == "add" else {"op", "objectID", "expectedRevision"} | ({"object"} if op == "replace" else set())
            require(set(operation) == fields, "invalid_operation", "Draft cannot supply renderer-resolved expectedObject or unknown operation fields")
            require(not ctx.get("nativeLayerUnavailable") or op == "add", "native_layer_unavailable", "Flattened stale preview supports additions only")
            oid = operation.get("objectID") if op != "add" else operation.get("object", {}).get("id")
            uuid(oid)
            require(oid not in changed_objects, "invalid_edit", "Duplicate object edit")
            changed_objects.add(oid)
            if op != "add":
                require(oid in objects and integer(operation.get("expectedRevision"), 1) == objects[oid]["revision"], "invalid_target", "Object target is not captured revision")
            if op != "remove":
                obj = operation.get("object")
                object_spec(obj, captured_translation=op == "replace" and object_translation(obj, objects[oid]))
                require(set(obj) <= {"id", "kind", "source", "frame", "style"}, "invalid_object", "Draft cannot supply resolved assets/provenance")
                require(obj["id"] == oid, "invalid_object", "Replacement must preserve object ID")
                if op == "add":
                    require(oid not in object_ids and oid not in new_ids, "invalid_object", "Add requires fresh unique ID")
                    new_ids.add(oid)
                count += 1
        for operation in se:
            require(isinstance(operation, dict) and operation.get("op") in ("keep", "remove", "recolor", "move"), "invalid_operation", "Unsupported stroke operation")
            extras = {"color"} if operation["op"] == "recolor" else {"dx", "dy"} if operation["op"] == "move" else set()
            require(set(operation) == {"id", "fingerprint", "op"} | extras, "invalid_operation", "Unexpected or missing stroke operation fields")
            if operation["op"] == "move":
                require(ctx.get("rendererSignature") == "native-capture-v2", "recapture_required",
                        "Native move requires full-stroke capture; recapture the page with the updated app")
                require(all(abs(number(operation[key])) <= 4096 for key in ("dx", "dy")),
                        "invalid_operation", "Stroke translation exceeds bounds")
            tid = operation.get("id")
            require(tid in targets and tid not in changed_strokes and operation.get("fingerprint") == targets[tid]["fingerprint"], "invalid_target", "Stroke target must match captured identity/fingerprint")
            changed_strokes.add(tid)
            if operation["op"] != "keep":
                require(not ctx.get("nativeLayerUnavailable") and "asset" in targets[tid], "native_layer_unavailable", "Ink edit requires captured native per-stroke asset")
            if operation["op"] == "recolor":
                color(operation.get("color"))
    require(count <= 128, "object_limit", "At most 128 generated objects")
    require(any(e.get("objectEdits") or any(op["op"] != "keep" for op in e.get("strokeEdits", [])) for e in edits),
            "page_output_missing", "Result requires a write operation")
    return {"insertPages": inserts, "pageEdits": edits}
