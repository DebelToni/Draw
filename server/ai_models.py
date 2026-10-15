"""Shared source-backed AI object/PNG validation. No worker or rendering side effects."""
import hashlib
import io
import json
import math
import re
import struct
from uuid import UUID
import zlib

MAX_ASSET_BYTES = 128 * 1024 * 1024
MAX_PIXELS = 32_000_000
MAX_OBJECTS = 128
KINDS = {"text", "latex", "mermaid", "arrow", "circle", "highlight"}


def validate_highlight_source(source):
    """Generation-only geometry check; resolved source objects trust verified PNGs."""
    def unique_fields(pairs):
        value = dict(pairs)
        if len(value) != len(pairs):
            raise ValueError("Duplicate highlight fields")
        return value

    try:
        geometry = json.loads(source, object_pairs_hook=unique_fields)
    except (TypeError, ValueError, RecursionError) as error:
        raise ValueError("Invalid highlight JSON") from error
    if (not isinstance(geometry, dict) or set(geometry) != {"opacity"} or
            type(geometry["opacity"]) not in (int, float) or geometry["opacity"] != 0.2):
        raise ValueError("Highlight requires exactly opacity 0.2")
    return geometry


def digest(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("Invalid SHA256")
    return value


def identifier(value):
    if not isinstance(value, str) or str(UUID(value)).upper() != value:
        raise ValueError("Invalid UUID")
    return value


def number(value):
    if type(value) not in (int, float) or not math.isfinite(value) or abs(value) > 1e6:
        raise ValueError("Invalid AI number")
    return value


def validate_frame(frame):
    if not isinstance(frame, dict) or set(frame) != {"x", "y", "width", "height"}:
        raise ValueError("Invalid AI frame")
    for field in frame:
        number(frame[field])
    if frame["width"] <= 0 or frame["height"] <= 0:
        raise ValueError("Invalid AI frame extent")
    return frame


def validate_asset_descriptor(asset):
    if not isinstance(asset, dict) or set(asset) != {"sha256", "pixelWidth", "pixelHeight", "scale"}:
        raise ValueError("Invalid AI asset")
    digest(asset["sha256"])
    for field in ("pixelWidth", "pixelHeight"):
        if type(asset[field]) is not int or not 0 < asset[field] <= 8192:
            raise ValueError("Invalid asset dimensions")
    if asset["pixelWidth"] * asset["pixelHeight"] > MAX_PIXELS or type(asset["scale"]) not in (int, float) or asset["scale"] != 2:
        raise ValueError("Invalid asset scale or area")
    return asset


def validate_object(obj):
    fields = {"id", "revision", "kind", "source", "frame", "style", "asset", "provenance"}
    if not isinstance(obj, dict) or set(obj) != fields:
        raise ValueError("Invalid AI object")
    identifier(obj["id"])
    if type(obj["revision"]) is not int or obj["revision"] < 1 or obj["kind"] not in KINDS:
        raise ValueError("Invalid AI object kind/revision")
    if not isinstance(obj["source"], str) or len(obj["source"].encode("utf-8")) > 65536:
        raise ValueError("Invalid AI source")
    validate_frame(obj["frame"])
    style = obj["style"]
    if not isinstance(style, dict) or set(style) != {"fontSize", "color", "lineWidth"}:
        raise ValueError("Invalid AI style")
    if number(style["fontSize"]) <= 0 or number(style["lineWidth"]) < 0 or not isinstance(style["color"], str) or re.fullmatch(r"#[0-9a-fA-F]{6}", style["color"]) is None:
        raise ValueError("Invalid AI style values")
    asset = validate_asset_descriptor(obj["asset"])
    if abs(obj["frame"]["width"] * 2 - asset["pixelWidth"]) > 0.001 or abs(obj["frame"]["height"] * 2 - asset["pixelHeight"]) > 0.001:
        raise ValueError("Frame does not match asset")
    provenance = obj["provenance"]
    if not isinstance(provenance, dict) or set(provenance) != {"requestID", "contextSHA256", "rendererSignature"}:
        raise ValueError("Invalid AI provenance")
    identifier(provenance["requestID"])
    digest(provenance["contextSHA256"])
    if not isinstance(provenance["rendererSignature"], str) or not 0 < len(provenance["rendererSignature"]) <= 256:
        raise ValueError("Invalid renderer signature")
    return obj


def validate_objects(objects):
    if not isinstance(objects, list) or len(objects) > MAX_OBJECTS:
        raise ValueError("Invalid AI objects")
    ids = set()
    for obj in objects:
        validate_object(obj)
        if obj["id"] in ids:
            raise ValueError("Duplicate AI object")
        ids.add(obj["id"])
    return objects


def validate_png(data, width=None, height=None, rgba=True):
    """Check structure, CRCs and bounded full decoding, not just a PNG header."""
    if not isinstance(data, bytes) or not 33 <= len(data) <= MAX_ASSET_BYTES or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Invalid PNG")
    offset, kinds, idat, ended = 8, [], [], False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("Truncated PNG")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("Truncated PNG chunk")
        kind, payload = data[offset + 4:offset + 8], data[offset + 8:end - 4]
        if re.fullmatch(b"[A-Za-z]{4}", kind) is None or not kind[2:3].isupper():
            raise ValueError("Invalid PNG chunk type")
        if rgba and kind == b"iCCP":
            raise ValueError("Asset ICC color overrides unsupported; use sRGB")
        if kind == b"sRGB" and (kind in kinds or length != 1 or payload[0] > 3 or b"IDAT" in kinds):
            raise ValueError("Invalid PNG sRGB chunk")
        if kind == b"PLTE" and (kind in kinds or b"IDAT" in kinds or not 0 < length <= 768 or length % 3):
            raise ValueError("Invalid PNG palette")
        if zlib.crc32(kind + payload) != struct.unpack(">I", data[end - 4:end])[0]:
            raise ValueError("PNG checksum mismatch")
        if not kinds and kind != b"IHDR" or kind == b"IHDR" and (kinds or length != 13):
            raise ValueError("Invalid PNG header order")
        if kind == b"IHDR":
            w, h, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if not 0 < w <= 8192 or not 0 < h <= 8192 or w * h > MAX_PIXELS or compression or filtering or interlace not in (0, 1):
                raise ValueError("Invalid PNG dimensions/encoding")
            if width is not None and w != width or height is not None and h != height:
                raise ValueError("PNG dimensions mismatch")
            if rgba and (depth != 8 or color != 6 or interlace):
                raise ValueError("Asset must be noninterlaced RGBA8 PNG")
        elif kind == b"IDAT":
            if b"IDAT" in kinds and kinds[-1] != b"IDAT":
                raise ValueError("Nonconsecutive PNG data")
            idat.append(payload)
        elif kind == b"IEND":
            if length or not idat or end != len(data):
                raise ValueError("Invalid PNG end")
            ended = True
        elif kind[:1].isupper() and kind != b"PLTE":
            raise ValueError("Unknown critical PNG chunk")
        if kind in (b"acTL", b"fcTL", b"fdAT"):
            raise ValueError("Animated PNG unsupported")
        kinds.append(kind)
        offset = end
    if not ended:
        raise ValueError("Incomplete PNG")
    # RGBA8 has exactly one filter byte + four bytes/pixel per scanline.
    if rgba:
        decoder = zlib.decompressobj()
        try:
            raw = decoder.decompress(b"".join(idat), (w * 4 + 1) * h + 1)
        except zlib.error as error:
            raise ValueError("Invalid PNG data") from error
        if len(raw) != (w * 4 + 1) * h or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or any(raw[i] > 4 for i in range(0, len(raw), w * 4 + 1)):
            raise ValueError("Invalid PNG scanlines")
    from PIL import Image
    try:
        with Image.open(io.BytesIO(data)) as image:
            image.load()
            if image.format != "PNG" or image.size != (w, h) or rgba and image.mode != "RGBA":
                raise ValueError("Invalid decoded PNG")
    except (OSError, SyntaxError) as error:
        raise ValueError("Invalid PNG data") from error
    return w, h


def validate_asset(data, asset):
    validate_asset_descriptor(asset)
    if hashlib.sha256(data).hexdigest() != asset["sha256"]:
        raise ValueError("Asset checksum mismatch")
    validate_png(data, asset["pixelWidth"], asset["pixelHeight"])
    return data


def current_objects(page):
    head = page.get("head")
    node = next((n for n in page["nodes"] if n["id"] == head), None)
    return (node.get("objects") or []) if node else []


def referenced_assets(package):
    refs, ids = {}, set()
    for book in package["notebooks"]:
        for page in book["pages"] + book["deleted"]:
            for obj in validate_objects(current_objects(page)):
                if obj["id"] in ids:
                    raise ValueError("Duplicate library object ID")
                ids.add(obj["id"])
                asset = obj["asset"]
                previous = refs.setdefault(asset["sha256"], asset)
                if previous != asset:
                    raise ValueError("Conflicting asset descriptors")
    return refs


def validate_source_assets(package, wire=False):
    refs = referenced_assets(package)
    assets = package.get("assets")
    if refs:
        if package.get("format") not in (2, 3) or not isinstance(assets, dict) or set(assets) != set(refs):
            raise ValueError("Missing or unreferenced assets")
        if wire and any(key != value for key, value in assets.items()):
            raise ValueError("Invalid asset references")
    elif package.get("format") == 3:
        if "assets" in package and assets != {}:
            raise ValueError("Unreferenced assets")
    elif package.get("format") != 1 or "assets" in package:
        raise ValueError("Empty source must use legacy format")
    return refs
