"""Render bounded public PencilKit stroke records, without Apple frameworks."""
from io import BytesIO
import math
from uuid import UUID

import cairocffi as cairo
from PIL import Image, ImageFilter

try:
    from .ai_models import validate_objects, validate_asset, MAX_PIXELS
except ImportError:
    from ai_models import validate_objects, validate_asset, MAX_PIXELS

RENDERER_VERSION = 3
MAX_GEOMETRY = 262_144
MAX_STROKES = 10_000
SUPPORTED_INKS = {"com.apple.ink.pen", "com.apple.ink.monoline", "com.apple.ink.marker"}


def number(value, limit=1e12):
    if type(value) not in (int, float) or not math.isfinite(value) or abs(value) > limit:
        raise ValueError("Invalid portable number")
    return value


def array(value, count, limit=1e12):
    if not isinstance(value, list) or len(value) != count:
        raise ValueError("Invalid portable array")
    return [number(x, limit) for x in value]


def optional_uuid(value):
    if value is not None and (not isinstance(value, str) or str(UUID(value)).upper() != value):
        raise ValueError("Invalid portable UUID")


def validate_page(scene):
    if not isinstance(scene, dict) or type(scene.get("format")) is not int or scene["format"] != 1:
        raise ValueError("Unsupported portable format")
    optional_uuid(scene.get("head"))
    width, height = number(scene["width"]), number(scene["height"])
    if not 0 < width <= 4096 or not 0 < height <= 4096:
        raise ValueError("Invalid portable page extent")
    if math.ceil(width * 2) * math.ceil(height * 2) > MAX_PIXELS:
        raise ValueError("Portable page pixel limit")
    if "background" in scene and (type(scene["background"]) is not int or scene["background"] not in range(4)):
        raise ValueError("Invalid portable background")
    if "objects" in scene:
        validate_objects(scene["objects"])
    strokes = scene["strokes"]
    if not isinstance(strokes, list) or len(strokes) > MAX_STROKES:
        raise ValueError("Too many portable strokes")
    geometry = 0
    for stroke in strokes:
        if not isinstance(stroke, dict) or stroke.get("inkType") not in SUPPORTED_INKS:
            raise ValueError("Unsupported portable ink")
        for field in ("id", "pathID", "renderGroupID"):
            optional_uuid(stroke.get(field))
        color = array(stroke["color"], 4)
        if any(not 0 <= x <= 1 for x in color):
            raise ValueError("Invalid portable color")
        array(stroke["transform"], 6, 1e6)
        if type(stroke["randomSeed"]) is not int or not 0 <= stroke["randomSeed"] <= 0xffffffff:
            raise ValueError("Invalid portable seed")
        number(stroke["creationDate"])
        if stroke.get("grainOffset") is not None:
            array(stroke["grainOffset"], 2, 1e6)
        for field in ("points", "samples"):
            values = stroke[field]
            if not isinstance(values, list):
                raise ValueError("Invalid portable points")
            geometry += len(values)
            if geometry > MAX_GEOMETRY:
                raise ValueError("Too much portable geometry")
            for point in values:
                p = array(point, 12)
                if (abs(p[0]) > 1e6 or abs(p[1]) > 1e6 or p[2] < 0 or not 0 <= p[3] <= 8192
                        or not 0 <= p[4] <= 8192 or not 0 <= p[5] <= 2 or p[6] < 0
                        or p[9] < 0 or not 0 <= p[10] <= 1):
                    raise ValueError("Invalid portable footprint")
        if stroke["points"] and not stroke["samples"]:
            raise ValueError("Missing portable samples")
        mask = stroke.get("mask")
        if mask is not None:
            if not isinstance(mask, dict) or type(mask.get("evenOdd")) is not bool or not isinstance(mask.get("commands"), list):
                raise ValueError("Invalid portable mask")
            geometry += len(mask["commands"])
            if geometry > MAX_GEOMETRY:
                raise ValueError("Too much portable geometry")
            for command in mask["commands"]:
                if not isinstance(command, list) or not command or type(command[0]) not in (int, float):
                    raise ValueError("Invalid mask command")
                if command[0] not in (0, 1, 2, 3, 4):
                    raise ValueError("Invalid mask opcode")
                array(command, (3, 3, 5, 7, 1)[int(command[0])], 1e6)
    return width, height, strokes


def simplify(points, tolerance=0.025):
    """Bound simplification work; keeping the original curve is always safe."""
    if len(points) < 3:
        return points
    keep = {0, len(points) - 1}
    stack, work = [(0, len(points) - 1)], 0
    while stack:
        first, last = stack.pop()
        work += last - first
        if work > 1_000_000:
            return points
        a, b = points[first], points[last]
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = dx * dx + dy * dy
        largest, index = tolerance * tolerance, None
        for i in range(first + 1, last):
            p = points[i]
            t = max(0, min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length)) if length else 0
            distance = (p[0] - a[0] - t * dx) ** 2 + (p[1] - a[1] - t * dy) ** 2
            if distance > largest:
                largest, index = distance, i
        if index is not None:
            keep.add(index)
            stack.extend(((first, index), (index, last)))
    return [points[i] for i in sorted(keep)]


def append_mask(context, mask):
    context.new_path()
    for c in mask["commands"]:
        if c[0] == 0:
            context.move_to(*c[1:])
        elif c[0] == 1:
            context.line_to(*c[1:])
        elif c[0] == 2:
            x, y = context.get_current_point()
            cx, cy, tx, ty = c[1:]
            context.curve_to(x + 2 * (cx - x) / 3, y + 2 * (cy - y) / 3,
                             tx + 2 * (cx - tx) / 3, ty + 2 * (cy - ty) / 3, tx, ty)
        elif c[0] == 3:
            context.curve_to(*c[1:])
        else:
            context.close_path()
    context.set_fill_rule(cairo.FILL_RULE_EVEN_ODD if mask["evenOdd"] else cairo.FILL_RULE_WINDING)
    context.clip()
    context.set_fill_rule(cairo.FILL_RULE_WINDING)


def ellipse(context, point):
    if point[3] <= 0 or point[4] <= 0:
        return
    context.new_sub_path()
    context.save()
    context.translate(point[0], point[1])
    context.rotate(point[7])
    context.scale(point[3] / 2, point[4] / 2)
    context.arc(0, 0, 1, 0, 2 * math.pi)
    context.restore()
    context.close_path()


def footprint(context, points):
    constant = max(p[3] for p in points) - min(p[3] for p in points) < 0.001 and all(abs(p[3] - p[4]) < 0.001 for p in points)
    if constant and len(points) > 1:
        curve = simplify(points)
        context.move_to(*curve[0][:2])
        for p in curve[1:]:
            context.line_to(*p[:2])
        context.set_line_width(points[0][3])
        context.set_line_cap(cairo.LINE_CAP_ROUND)
        context.set_line_join(cairo.LINE_JOIN_ROUND)
        context.stroke()
        return
    if len(points) > 1:
        left, right = [], []
        for i, p in enumerate(points):
            before, after = points[max(0, i - 1)], points[min(len(points) - 1, i + 1)]
            dx, dy = after[0] - before[0], after[1] - before[1]
            length = math.hypot(dx, dy)
            nx, ny = (-dy / length, dx / length) if length else (0, 1)
            rx, ry, angle = p[3] / 2, p[4] / 2, p[7]
            c, s = math.cos(angle), math.sin(angle)
            xx, yy, cross = rx * rx * c * c + ry * ry * s * s, rx * rx * s * s + ry * ry * c * c, (rx * rx - ry * ry) * c * s
            vx, vy = xx * nx + cross * ny, cross * nx + yy * ny
            support = math.sqrt(max(0, nx * vx + ny * vy))
            ox, oy = (vx / support, vy / support) if support else (0, 0)
            left.append((p[0] + ox, p[1] + oy))
            right.append((p[0] - ox, p[1] - oy))
        polygon = list(reversed(left + list(reversed(right))))
        context.move_to(*polygon[0])
        for p in polygon[1:]:
            context.line_to(*p)
        context.close_path()
    ellipse(context, points[0])
    if len(points) > 1:
        ellipse(context, points[-1])
    context.fill()


def marker_layer(stroke, pixels):
    """Procedural chisel footprint; native grain is deliberately not fabricated."""
    source = stroke["samples"]
    # Calibrated to fresh-identity native size/opacity sweeps on iOS 27.
    points = [p[:3] + [1.2 * p[3], 0.46 * p[4]] + p[5:] for p in source]
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, *pixels)
    context = cairo.Context(surface)
    context.scale(2, 2)
    context.transform(cairo.Matrix(*stroke["transform"]))
    context.set_source_rgba(1, 1, 1, 1)
    footprint(context, points)
    buffer = BytesIO()
    surface.write_to_png(buffer)
    image = Image.open(BytesIO(buffer.getvalue())).convert("RGBA")
    mean_width = sum(p[3] for p in source) / len(source)
    opacity = sum(p[5] for p in source) / len(source)
    alpha = (1 - math.exp(-1.35 * mean_width ** 0.4 * opacity)) * stroke["color"][3]
    channel = image.getchannel("A").filter(ImageFilter.GaussianBlur(mean_width * 0.055 * 2))
    channel = channel.point([round(i * alpha) for i in range(256)])
    colored = Image.new("RGBA", pixels, tuple(round(c * 255) for c in stroke["color"][:3]) + (0,))
    colored.putalpha(channel)
    buffer = BytesIO()
    colored.save(buffer, format="PNG")
    return cairo.ImageSurface.create_from_png(BytesIO(buffer.getvalue()))


def draw_paper(context, width, height, background):
    context.set_source_rgb(1, 1, 1)
    context.paint()
    if background == 0:
        return
    if background == 1:
        context.set_source_rgb(0.78, 0.78, 0.78)
        for x in range(36, math.floor(width) + 1, 36):
            for y in range(36, math.floor(height) + 1, 36):
                context.arc(x + 0.75, y + 0.75, 0.75, 0, 2 * math.pi)
                context.fill()
        return
    context.set_source_rgb(0.88, 0.88, 0.88)
    context.set_line_width(0.5)
    for y in range(36, math.floor(height) + 1, 36):
        context.move_to(0, y)
        context.line_to(width, y)
    if background == 3:
        for x in range(36, math.floor(width) + 1, 36):
            context.move_to(x, 0)
            context.line_to(x, height)
    context.stroke()


def render_page(scene, assets=None):
    width, height, strokes = validate_page(scene)
    pixels = (math.ceil(width * 2), math.ceil(height * 2))
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, *pixels)
    context = cairo.Context(surface)
    context.scale(2, 2)
    draw_paper(context, width, height, scene.get("background", 2))
    for obj in scene.get("objects", []):
        asset = obj["asset"]
        if assets is None or asset["sha256"] not in assets:
            raise ValueError("Missing object PNG")
        data = validate_asset(assets[asset["sha256"]], asset)
        layer = cairo.ImageSurface.create_from_png(BytesIO(data))
        frame = obj["frame"]
        context.save()
        context.translate(frame["x"], frame["y"])
        context.rectangle(0, 0, frame["width"], frame["height"])
        context.clip()
        context.scale(0.5, 0.5)
        context.set_source_surface(layer)
        context.paint()
        context.restore()
    for stroke in strokes:
        source = stroke["samples"]
        if not source or stroke["color"][3] == 0:
            continue
        context.save()
        context.transform(cairo.Matrix(*stroke["transform"]))
        if stroke.get("mask") is not None:
            append_mask(context, stroke["mask"])
        if stroke["inkType"] == "com.apple.ink.marker":
            layer = marker_layer(stroke, pixels)
            context.identity_matrix()
            context.set_source_surface(layer)
            context.paint()
        else:
            # Native pen size is a half-diameter plus a 2pt kernel offset.
            points = [p[:3] + [max(0, 2 * (p[3] - 2)), max(0, 2 * (p[4] - 2))] + p[5:] for p in source]
            if any(p[3] > 0 and p[4] > 0 for p in points):
                opacities = [p[5] for p in points]
                color = stroke["color"]
                if max(opacities) - min(opacities) <= 0.01 or points[0][:2] == points[-1][:2]:
                    context.set_source_rgba(*color[:3], min(1, sum(opacities) / len(points) * color[3]))
                else:
                    gradient = cairo.LinearGradient(*points[0][:2], *points[-1][:2])
                    distances = [0]
                    for a, b in zip(points, points[1:]):
                        distances.append(distances[-1] + math.hypot(a[0] - b[0], a[1] - b[1]))
                    stride = max(1, len(points) // 128)
                    for i in sorted(set(range(0, len(points), stride)) | {len(points) - 1}):
                        gradient.add_color_stop_rgba(distances[i] / distances[-1], *color[:3], min(1, points[i][5] * color[3]))
                    context.set_source(gradient)
                footprint(context, points)
        context.restore()
    buffer = BytesIO()
    surface.write_to_png(buffer)
    tag_counts = {}
    colors = ((175 / 255, 82 / 255, 222 / 255, 1), (23 / 255, 127 / 255, 113 / 255, 1))
    count = sum(any(all(abs(actual - expected) < 0.5 / 255 for actual, expected in zip(s["color"], color)) for color in colors) for s in strokes)
    if count:
        tag_counts["question"] = count
    metadata = {"head": scene.get("head"), "width": pixels[0], "height": pixels[1],
                "strokeCount": len(strokes), "inkTypes": sorted({s["inkType"] for s in strokes}),
                "tagStrokeCounts": tag_counts, "rendererVersion": RENDERER_VERSION}
    if "background" in scene:
        metadata["background"] = scene["background"]
    return metadata, buffer.getvalue()
