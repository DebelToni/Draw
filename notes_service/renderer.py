"""Controlled Draw V1 rendering. No caller state is mutated and no assets are published.

The caller owns draft versions, render attempt accounting, persistence and approval.
"""
from __future__ import annotations

import copy
from datetime import datetime
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

from PIL import Image, ImageCms, ImageDraw, UnidentifiedImageError
from server.ai_models import KINDS, validate_highlight_source
from .validation import canonical_stroke_edits, object_translation

SIGNATURE = "draw-ai-render-v1"
SCALE = 2
MAX_PIXELS = 32_000_000  # Stricter than the 64 MP decompression safety ceiling.
MAX_DIMENSION = 8192
MAX_BYTES = 128 * 1024 * 1024  # Encoded bytes per PNG; also the wire transfer limit.
MAX_DECODED_BYTES = 4 * 1024 * 1024 * 1024  # Cumulative RGBA decoding work per render.
MAX_SOURCE = 64 * 1024
MAX_OBJECTS = 128
PASS_SECONDS = 30
MAX_BROWSER_RSS = 1024 * 1024 * 1024
ROOT = Path(__file__).parent / "rendering"
SHA = re.compile(r"[0-9a-f]{64}\Z")
COLOR = re.compile(r"#[0-9A-Fa-f]{6}\Z")


class RendererError(ValueError):
    def __init__(self, code: str, message: str):
        self.code, self.message = code, message
        super().__init__(message)

    def as_dict(self):
        return {"error": {"code": self.code, "message": self.message}}


def fail(message, code="invalid_render"):
    raise RendererError(code, message)


def fields(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        fail("Invalid renderer fields")
    return value


def number(value, minimum=0, maximum=4096):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not minimum <= value <= maximum:
        fail("Invalid finite numeric bounds")
    return value


def integer(value, minimum=0, maximum=MAX_OBJECTS):
    if type(value) is not int or not minimum <= value <= maximum:
        fail("Invalid integer bounds")
    return value


def identity(value):
    if not isinstance(value, str):
        fail("Invalid UUID")
    try:
        canonical = str(uuid.UUID(value)).upper()
    except (ValueError, AttributeError):
        fail("Invalid UUID")
    if canonical != value:
        fail("UUID must use canonical uppercase spelling")
    return value


def digest(value):
    if not isinstance(value, str) or not SHA.fullmatch(value):
        fail("Invalid SHA256")
    return value


def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z", value):
        fail("Expected RFC3339 UTC timestamp")
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail("Invalid UTC timestamp")


def color(value):
    if not isinstance(value, str) or not COLOR.fullmatch(value):
        fail("Invalid RGB color")
    return value.upper()


def frame(value, page=None, native=False):
    fields(value, ("x", "y", "width", "height"))
    result = {key: number(value[key], -4096 if native and key in {"x", "y"} else 0) for key in value}
    if result["width"] <= 0 or result["height"] <= 0:
        fail("Frame dimensions must be positive")
    dimensions(result["width"], result["height"])
    if page and (result["x"] + result["width"] > page["width"] or result["y"] + result["height"] > page["height"]):
        fail("Frame exceeds page bounds")
    return result


def dimensions(width, height):
    number(width, 0.5)
    number(height, 0.5)
    w, h = round(width * SCALE), round(height * SCALE)
    if w > MAX_DIMENSION or h > MAX_DIMENSION or w * h > MAX_PIXELS:
        fail("PNG exceeds pixel limits", "render_limit")
    return w, h


def png(image):
    out = io.BytesIO()
    image.save(out, format="PNG")
    return out.getvalue()


def source_check(kind, source):
    if not isinstance(source, str):
        fail("Source must be a string")
    try:
        size = len(source.encode("utf-8"))
    except UnicodeEncodeError:
        fail("Invalid Unicode source")
    if size > MAX_SOURCE:
        fail("Object source exceeds 64 KiB", "render_limit")
    if not source.strip() or "\x00" in source:
        fail("Empty or invalid object source")
    if kind in {"latex", "mermaid"}:
        # No URLs, HTML or code/file references, including encoded HTML syntax.
        if re.search(r"(?:https?|ftp|file|data|javascript|vbscript)\s*:|www\.|<\s*/?\s*[a-zA-Z!][^>]*>|&(?:#|lt;|gt;)", source, re.I):
            fail("External resources or markup are forbidden")
    if kind == "latex" and re.search(r"\\(?:href|url|includegraphics|html\w*|class|style|cssId|require|input|include|def|gdef|edef|xdef|let|futurelet|newcommand|renewcommand|providecommand)\b", source, re.I):
        fail("Unsafe TeX command")
    if kind == "mermaid":
        if re.search(r"%%\s*\{|^\s*---|\b(?:click|callback|href|javascript|link|image|icon)\b|^\s*(?:style|classDef|linkStyle)\b|@import|url\s*\(", source, re.I | re.M):
            fail("Unsafe Mermaid directive or resource")


def draft_object(value, page):
    fields(value, ("id", "kind", "source", "frame"), ("style",))
    identity(value["id"])
    kind = value["kind"]
    if not isinstance(kind, str) or kind not in KINDS:
        fail("Unsupported object kind")
    source_check(kind, value["source"])
    box = frame(value["frame"], page)
    # Placement is snapped once to the fixed 2x asset grid, before tight cropping.
    box["x"] = round(box["x"] * SCALE) / SCALE
    box["y"] = round(box["y"] * SCALE) / SCALE
    box["width"] = math.floor(box["width"] * SCALE) / SCALE
    box["height"] = math.floor(box["height"] * SCALE) / SCALE
    frame(box, page)
    style = fields(value.get("style", {}), (), ("fontSize", "color", "lineWidth"))
    style = {"fontSize": number(style.get("fontSize", 18), 1, 128),
             "color": color(style.get("color", "#00B8D9" if kind == "highlight" else "#000000")),
             "lineWidth": number(style.get("lineWidth", 1), 0.1, 32)}
    result = {"id": value["id"], "kind": kind, "source": value["source"], "frame": box, "style": style}
    if kind == "highlight":
        try:
            result["geometry"] = validate_highlight_source(value["source"])
        except ValueError:
            fail("Highlight requires rectangle JSON with exactly opacity 0.2")
    if kind in {"arrow", "circle"}:
        try:
            geometry = json.loads(value["source"])
        except (ValueError, RecursionError):
            fail("Invalid shape JSON")
        margin = style["lineWidth"] / 2
        if kind == "circle":
            fields(geometry, ("cx", "cy", "rx", "ry"))
            for key in geometry:
                number(geometry[key])
            if geometry["rx"] <= 0 or geometry["ry"] <= 0:
                fail("Circle radii must be positive")
            for center, radius, bound in [("cx", "rx", box["width"]), ("cy", "ry", box["height"])]:
                if geometry[center] - geometry[radius] < margin or geometry[center] + geometry[radius] > bound - margin:
                    fail("Circle exceeds placement box")
        else:
            fields(geometry, ("from", "to"))
            for key in geometry:
                if not isinstance(geometry[key], list) or len(geometry[key]) != 2:
                    fail("Arrow endpoints must be coordinate pairs")
                for coordinate, bound in zip(geometry[key], (box["width"], box["height"])):
                    number(coordinate, margin, bound - margin)
            x, y = geometry["from"]
            tx, ty = geometry["to"]
            if x == tx and y == ty:
                fail("Arrow must have nonzero length")
            angle, size = math.atan2(ty-y, tx-x), max(5, style["lineWidth"]*4)
            for theta in (angle-.45, angle+.45):
                number(tx-size*math.cos(theta), margin, box["width"]-margin)
                number(ty-size*math.sin(theta), margin, box["height"]-margin)
        result["geometry"] = geometry
    return result


class Renderer:
    def __init__(self, read_asset):
        """read_asset(sha256: str) -> bytes, synchronous, immutable root CAS reader."""
        if not callable(read_asset):
            raise TypeError("read_asset must be callable")
        self.read_asset = read_asset

    def render(self, context, draft, requestID, contextSHA256):
        try:
            for value in (context, draft):
                if len(json.dumps(value, allow_nan=False).encode("utf-8")) > 4 * 1024 * 1024:
                    fail("Renderer metadata exceeds 4 MiB", "render_limit")
            return self._render(context, draft, requestID, contextSHA256)
        except RendererError:
            raise
        except (TypeError, KeyError, ValueError, OverflowError, RecursionError, UnicodeError):
            fail("Malformed renderer input")
        except OSError:
            fail("Renderer resource unavailable", "renderer_unavailable")

    def _render(self, context, draft, requestID, contextSHA256):
        started = time.monotonic()
        identity(requestID)
        digest(contextSHA256)
        # All pass state is local, so a Renderer can be shared by concurrent requests.
        decoded = 0

        def check_time():
            if time.monotonic() - started >= PASS_SECONDS:
                fail("Renderer exceeded 30 seconds", "render_timeout")

        def load(sha, expected=None, native=False, require_alpha=False, retain=False):
            nonlocal decoded
            check_time()
            digest(sha)
            try:
                data = self.read_asset(sha)
            except Exception:
                fail("Required captured PNG is unavailable", "missing_asset")
            if not isinstance(data, bytes) or len(data) > MAX_BYTES or hashlib.sha256(data).hexdigest() != sha:
                fail("Asset bytes do not match SHA256", "invalid_asset")
            layer = decode(data, expected, native, require_alpha)
            if retain:
                assets[sha] = data
            return layer

        def decode(data, expected=None, native=False, require_alpha=False):
            nonlocal decoded
            if len(data) > MAX_BYTES:
                fail("PNG bytes exceed transfer limit", "render_limit")
            try:
                with Image.open(io.BytesIO(data)) as image:
                    w, h = image.size
                    if image.format != "PNG" or getattr(image, "n_frames", 1) != 1:
                        fail("Asset must be a single PNG", "invalid_asset")
                    if w <= 0 or h <= 0 or w > MAX_DIMENSION or h > MAX_DIMENSION or w*h > MAX_PIXELS:
                        fail("PNG exceeds pixel limits", "render_limit")
                    if expected and image.size != expected:
                        fail("PNG dimensions do not match frame", "invalid_asset")
                    decoded += w*h*4
                    if decoded > MAX_DECODED_BYTES:
                        fail("Decoded PNG work exceeds 4 GiB", "render_limit")
                    # Native opaque UIKit PNGs may be RGB and include a color profile.
                    # Generated object assets must remain unprofiled sRGB RGBA.
                    if not native and (image.mode != "RGBA" or "icc_profile" in image.info):
                        fail("Object PNG must be unprofiled sRGB RGBA", "invalid_asset")
                    if require_alpha and image.mode != "RGBA":
                        fail("Native ink PNG requires an alpha channel", "invalid_asset")
                    if image.mode not in {"RGB", "RGBA"}:
                        fail("Native PNG must use RGB or RGBA", "invalid_asset")
                    with Image.open(io.BytesIO(data)) as verified:
                        verified.verify()
                    converted = image.convert("RGBA")
                    if native and image.info.get("icc_profile"):
                        try:
                            profile = ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
                            converted = ImageCms.profileToProfile(converted, profile,
                                ImageCms.createProfile("sRGB"), outputMode="RGBA")
                        except (OSError, ValueError, ImageCms.PyCMSError):
                            fail("Native PNG has an invalid color profile", "invalid_asset")
                    return converted
            except (UnidentifiedImageError, OSError, Image.DecompressionBombError, Image.DecompressionBombWarning):
                fail("Malformed or oversized PNG", "invalid_asset")

        fields(context, ("format", "documentID", "focusPageID", "capturedAt", "rendererSignature", "orientation", "pages"),
               ("documentName", "folderName", "folderID", "sourceManifestSHA256", "nativeLayerUnavailable",
                "lastSyncedAt", "documentDigest", "previewLabel"))
        if type(context["format"]) is not int or context["format"] != 1:
            fail("Unsupported context format")
        timestamp(context["capturedAt"])
        for key in ("documentName", "folderName"):
            if context.get(key) is not None:
                value = context[key]
                if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > 1024 or re.search(r"[\x00-\x1f\x7f]", value):
                    fail("Invalid context display name")
        if context.get("folderID") is not None:
            identity(context["folderID"])
        if context.get("sourceManifestSHA256") is not None:
            digest(context["sourceManifestSHA256"])
        stale = context["rendererSignature"] == "server-synced-preview-v1"
        if stale:
            if context.get("nativeLayerUnavailable") is not True or context.get("previewLabel") != "stale/native-layer-unavailable":
                fail("Server preview must disclose unavailable native layers", "native_layer_unavailable")
            digest(context.get("documentDigest"))
            timestamp(context.get("lastSyncedAt"))
        elif (context["rendererSignature"] not in {"native-capture-v1", "native-capture-v2"} or
              ("nativeLayerUnavailable" in context and context["nativeLayerUnavailable"] is not False) or
              any(key in context for key in ("lastSyncedAt", "documentDigest", "previewLabel"))):
            fail("Unsupported or inconsistent capture disclosure", "native_layer_unavailable")
        identity(context["documentID"])
        identity(context["focusPageID"])
        if context["orientation"] not in {"portrait", "landscape"}:
            fail("Invalid document orientation")
        if not isinstance(context["pages"], list) or not 1 <= len(context["pages"]) <= 512:
            fail("Invalid captured pages")
        pages, old_ids = {}, set()
        for page in context["pages"]:
            fields(page, ("pageID", "head", "background", "width", "height", "objects", "paperSHA256", "inkSHA256", "compositeSHA256", "portableSHA256", "strokeTargets"))
            page_id = identity(page["pageID"])
            if page_id in pages:
                fail("Duplicate captured page ID")
            if page["head"] is not None:
                identity(page["head"])
            integer(page["background"], 0, 3)
            dimensions(page["width"], page["height"])
            for key in ("paperSHA256", "inkSHA256", "compositeSHA256", "portableSHA256"):
                digest(page[key])
            if not isinstance(page["objects"], list) or not isinstance(page["strokeTargets"], list):
                fail("Invalid captured objects or strokes")
            for obj in page["objects"]:
                fields(obj, ("id", "revision", "kind", "source", "frame", "style", "asset", "provenance"))
                oid = identity(obj["id"])
                if oid in old_ids:
                    fail("Duplicate captured object ID")
                old_ids.add(oid)
                integer(obj["revision"], 1, 2**31-1)
                frame(obj["frame"], page, native=True)
                if obj["kind"] not in KINDS:
                    fail("Invalid captured object kind")
                self._descriptor(obj["asset"], obj["frame"])
            pages[page_id] = page
        if context["focusPageID"] not in pages:
            fail("Focus page is not captured")

        fields(draft, (), ("insertPages", "pageEdits", "draftVersion"))
        if "draftVersion" in draft:
            integer(draft["draftVersion"], 1, 2**31-1)
        inserted = copy.deepcopy(draft.get("insertPages", []))
        edits = copy.deepcopy(draft.get("pageEdits", []))
        if not isinstance(inserted, list) or not isinstance(edits, list) or len(inserted) > 32 or len(edits) > 512:
            fail("Invalid draft page limits", "render_limit")
        new_ids = set()
        for page in inserted:
            fields(page, ("pageID", "afterPageID", "background", "width", "height"))
            page_id, after = identity(page["pageID"]), identity(page["afterPageID"])
            if page_id in pages or after not in pages:
                fail("Invalid page insertion identity or order")
            integer(page["background"], 0, 3)
            base = (1024, 1361) if context["orientation"] == "portrait" else (1361, 1024)
            if (page["width"], page["height"]) != base:
                fail("New page must match document orientation geometry")
            dimensions(page["width"], page["height"])
            pages[page_id] = {**page, "objects": [], "strokeTargets": []}
            new_ids.add(page_id)

        tasks, bindings, seen_pages, added_ids = [], [], set(), set()
        operation_count = 0
        reused_assets = set()
        for edit in edits:
            fields(edit, ("pageID",), ("objectEdits", "strokeEdits"))
            page_id = identity(edit["pageID"])
            if page_id not in pages or page_id in seen_pages:
                fail("Invalid or duplicate edited page")
            seen_pages.add(page_id)
            page = pages[page_id]
            captured = {obj["id"]: obj for obj in page["objects"]}
            object_edits, stroke_edits = edit.setdefault("objectEdits", []), edit.setdefault("strokeEdits", [])
            if not isinstance(object_edits, list) or not isinstance(stroke_edits, list):
                fail("Invalid edit arrays")
            if stale and (stroke_edits or any(not isinstance(op, dict) or op.get("op") != "add" for op in object_edits)):
                fail("Flattened stale preview supports additions only; native edits are unavailable", "native_layer_unavailable")
            operation_count += len(object_edits)
            if operation_count > MAX_OBJECTS or len(stroke_edits) > 10000:
                fail("Too many edits", "render_limit")
            seen_targets = set()
            for op in object_edits:
                if not isinstance(op, dict):
                    fail("Invalid object edit")
                kind = op.get("op")
                value = None
                if kind == "add":
                    fields(op, ("op", "object"))
                    value = draft_object(op["object"], page)
                    oid = value["id"]
                    if oid in old_ids or oid in added_ids:
                        fail("Add must use a fresh unique object UUID")
                    added_ids.add(oid)
                    revision = 1
                elif kind in {"replace", "remove"}:
                    fields(op, ("op", "objectID", "expectedRevision"), ("object",) if kind == "replace" else ())
                    oid = identity(op["objectID"])
                    expected = integer(op["expectedRevision"], 1, 2**31-2)
                    if oid not in captured or captured[oid]["revision"] != expected:
                        fail("Object target is outside captured ID/revision scope")
                    # Revisions can collide after Undo branches; bind the full captured state.
                    op["expectedObject"] = copy.deepcopy(captured[oid])
                    if kind == "replace":
                        if "object" not in op:
                            fail("Missing replacement object")
                        supplied = fields(op["object"], ("id", "kind", "source", "frame"), ("style",))
                        if supplied["id"] != oid:
                            fail("Replacement must retain captured object ID")
                        revision = expected + 1
                        if object_translation(supplied, captured[oid]):
                            # The source belongs to the original placement box, not
                            # its tight crop. Position-only edits reuse proven pixels.
                            box = frame(supplied["frame"], page, native=True)
                            moved = copy.deepcopy(captured[oid])
                            moved["frame"].update(x=round(box["x"]*SCALE)/SCALE, y=round(box["y"]*SCALE)/SCALE)
                            frame(moved["frame"], page, native=True)
                            moved.update(revision=revision, provenance={"requestID": requestID,
                                "contextSHA256": contextSHA256, "rendererSignature": SIGNATURE})
                            op["object"] = moved
                            reused_assets.add(moved["asset"]["sha256"])
                        else:
                            value = draft_object(supplied, page)
                else:
                    fail("Unsupported object operation")
                if oid in seen_targets:
                    fail("Duplicate object operation target")
                seen_targets.add(oid)
                if value is not None:
                    tasks.append(value)
                    bindings.append((op, revision))
            self._stroke_edits(page, stroke_edits)
            if any(op["op"] == "move" for op in stroke_edits) and context["rendererSignature"] != "native-capture-v2":
                fail("Native move requires full-stroke capture; recapture the page with the updated app", "recapture_required")
            edit["strokeEdits"] = canonical_stroke_edits(stroke_edits)
        if not any(edit["objectEdits"] or any(op["op"] != "keep" for op in edit["strokeEdits"]) for edit in edits):
            fail("Result requires a write operation")
        if new_ids - seen_pages:
            fail("Inserted pages require visible edits")

        assets = {}
        temporary = Path.home() / "tmp"
        temporary.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="draw-render-", dir=temporary) as temp:
            folder = Path(temp)
            (folder / "tasks.json").write_text(json.dumps(tasks, allow_nan=False), encoding="utf-8")
            if tasks:
                self._browser(folder, PASS_SECONDS - (time.monotonic() - started))
            for index, (task, (op, revision)) in enumerate(zip(tasks, bindings)):
                check_time()
                image = decode((folder / f"{index}.png").read_bytes())
                crop = image.getchannel("A").getbbox()
                if crop is None:
                    fail("Object has no visible pixels")
                image = image.crop(crop)
                data = png(image)
                sha = hashlib.sha256(data).hexdigest()
                assets[sha] = data
                resolved = {"x": task["frame"]["x"] + crop[0]/SCALE,
                            "y": task["frame"]["y"] + crop[1]/SCALE,
                            "width": image.width/SCALE, "height": image.height/SCALE}
                obj = {key: task[key] for key in ("id", "kind", "source", "style")}
                obj.update(revision=revision, frame=resolved,
                           asset={"sha256": sha, "pixelWidth": image.width, "pixelHeight": image.height, "scale": SCALE},
                           provenance={"requestID": requestID, "contextSHA256": contextSHA256, "rendererSignature": SIGNATURE})
                op["object"] = obj

        previews = {}
        for edit in edits:
            check_time()
            page = pages[edit["pageID"]]
            size = dimensions(page["width"], page["height"])
            if page["pageID"] in new_ids:
                base = self._paper(page)
            else:
                base = load(page["compositeSHA256"] if stale else page["paperSHA256"], size, native=True)
            # Stale composites already contain their captured objects and source ink.
            scene = [] if stale else list(page["objects"])
            for op in edit["objectEdits"]:
                if op["op"] == "add":
                    scene.append(op["object"])
                else:
                    index = next(i for i, obj in enumerate(scene) if obj["id"] == op["objectID"])
                    if op["op"] == "remove":
                        scene.pop(index)
                    else:
                        scene[index] = op["object"]
            for obj in scene:
                box, asset = obj["frame"], obj["asset"]
                expected = self._descriptor(asset, box)
                layer = decode(assets[asset["sha256"]], expected) if asset["sha256"] in assets else load(asset["sha256"], expected, retain=asset["sha256"] in reused_assets)
                base.alpha_composite(layer, (round(box["x"]*SCALE), round(box["y"]*SCALE)))
            stroke_edits = edit["strokeEdits"]
            modified = any(op["op"] != "keep" and (op["op"] != "move" or op["dx"] != 0 or op["dy"] != 0)
                           for op in stroke_edits)
            if page["pageID"] not in new_ids and not stale:
                if not modified:
                    base.alpha_composite(load(page["inkSHA256"], size, native=True, require_alpha=True))
                else:
                    by_id = {op["id"]: op for op in stroke_edits}
                    for stroke in sorted(page["strokeTargets"], key=lambda item: item["index"]):
                        op = by_id.get(stroke["id"], {"op": "keep"})
                        # Even removed strokes must have a complete valid capture.
                        if "frame" not in stroke or "asset" not in stroke:
                            fail("Stroke edits require every ordered native stroke PNG/frame", "missing_asset")
                        box = frame(stroke["frame"], native=True)
                        expected = self._descriptor(stroke["asset"], box)
                        layer = load(stroke["asset"]["sha256"], expected, native=True, require_alpha=True)
                        if op["op"] == "remove":
                            continue
                        if op["op"] == "recolor":
                            alpha = layer.getchannel("A")
                            layer = Image.new("RGBA", layer.size, op["color"])
                            layer.putalpha(alpha)
                        dx, dy = (op["dx"], op["dy"]) if op["op"] == "move" else (0, 0)
                        base.alpha_composite(layer, (round((box["x"]+dx)*SCALE), round((box["y"]+dy)*SCALE)))
            previews[page["pageID"]] = png(base)
        check_time()
        objects = [op["object"] for edit in edits for op in edit["objectEdits"] if op["op"] != "remove"]
        return {"pageEdits": edits, "insertPages": inserted, "objects": objects,
                "assets": assets, "previews": previews, "rendererSignature": SIGNATURE}

    @staticmethod
    def _descriptor(asset, box):
        fields(asset, ("sha256", "pixelWidth", "pixelHeight", "scale"))
        digest(asset["sha256"])
        if isinstance(asset["scale"], bool) or asset["scale"] != SCALE:
            fail("Asset scale must be exactly 2")
        w = integer(asset["pixelWidth"], 1, MAX_DIMENSION)
        h = integer(asset["pixelHeight"], 1, MAX_DIMENSION)
        if w*h > MAX_PIXELS or (w, h) != dimensions(box["width"], box["height"]):
            fail("Asset descriptor does not match frame")
        return w, h

    @staticmethod
    def _stroke_edits(page, edits):
        targets, indices = {}, set()
        for stroke in page["strokeTargets"]:
            fields(stroke, ("id", "fingerprint", "index"), ("asset", "frame"))
            if not isinstance(stroke["id"], str) or not stroke["id"] or len(stroke["id"]) > 256:
                fail("Invalid stroke identity")
            digest(stroke["fingerprint"])
            index = integer(stroke["index"], 0, 1000000)
            if stroke["id"] in targets or index in indices:
                fail("Ambiguous captured stroke identity/order")
            targets[stroke["id"]] = stroke
            indices.add(index)
        seen = set()
        for op in edits:
            if not isinstance(op, dict):
                fail("Invalid stroke operation")
            extras = ("color",) if op.get("op") == "recolor" else ("dx", "dy") if op.get("op") == "move" else ()
            fields(op, ("id", "fingerprint", "op", *extras))
            if not isinstance(op["id"], str) or op["id"] not in targets or op["id"] in seen:
                fail("Stroke edit is outside unique captured scope")
            digest(op["fingerprint"])
            if op["fingerprint"] != targets[op["id"]]["fingerprint"]:
                fail("Stroke fingerprint does not match capture")
            if op["op"] not in {"keep", "remove", "recolor", "move"}:
                fail("Unsupported stroke operation")
            if op["op"] == "recolor":
                color(op["color"])  # Preserve the exact caller operation for approval binding.
            elif op["op"] == "move":
                number(op["dx"], -4096, 4096)
                number(op["dy"], -4096, 4096)
            seen.add(op["id"])

    @staticmethod
    def _browser(folder, timeout):
        node = shutil.which("node")
        if not node or not (ROOT / "bundle/libraries.js").is_file():
            fail("Install pinned renderer npm dependencies and build bundle", "renderer_unavailable")
        if timeout <= 0:
            fail("Renderer exceeded 30 seconds", "render_timeout")
        process = subprocess.Popen([node, "--max-old-space-size=256", str(ROOT / "render.mjs"), str(folder)],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    fail("Renderer exceeded 30 seconds", "render_timeout")
                if Renderer._owned_rss(process.pid) > MAX_BROWSER_RSS:
                    fail("Owned browser exceeded 1 GiB memory limit", "render_limit")
                time.sleep(0.05)
            status = folder / "done.json"
            if process.returncode or not status.is_file() or json.loads(status.read_text()) != {"ok": True}:
                fail("Controlled browser render failed or placement box is too small", "render_failed")
        except subprocess.TimeoutExpired:
            fail("Renderer exceeded 30 seconds", "render_timeout")
        finally:
            # This new process group contains only this call's Node/Chromium children.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if process.poll() is None:
                try:
                    process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

    @staticmethod
    def _owned_rss(root_pid):
        """Linux RSS sum for this pass's descendants, never another browser."""
        pending, seen, total = [root_pid], set(), 0
        while pending:
            pid = pending.pop()
            if pid in seen:
                continue
            seen.add(pid)
            try:
                status = Path(f"/proc/{pid}/status").read_text()
                total += next((int(line.split()[1])*1024 for line in status.splitlines()
                               if line.startswith("VmRSS:")), 0)
                children = Path(f"/proc/{pid}/task/{pid}/children").read_text()
                pending.extend(int(child) for child in children.split())
            except (OSError, ValueError):
                continue  # A child may close between the proc reads.
        return total

    @staticmethod
    def _paper(page):
        """PaperView geometry: 36 pt spacing, 1.5 pt dots, 0.5 pt rules."""
        image = Image.new("RGBA", dimensions(page["width"], page["height"]), "white")
        draw = ImageDraw.Draw(image)
        pattern = page["background"]
        if pattern == 1:
            for x in range(72, image.width, 72):
                for y in range(72, image.height, 72):
                    draw.ellipse((x, y, x+2, y+2), fill=(199, 199, 199, 255))
        elif pattern in {2, 3}:
            for y in range(72, image.height, 72):
                draw.line((0, y, image.width, y), fill=(224, 224, 224, 255), width=1)
            if pattern == 3:
                for x in range(72, image.width, 72):
                    draw.line((x, 0, x, image.height), fill=(224, 224, 224, 255), width=1)
        return image
