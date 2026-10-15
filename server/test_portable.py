from io import BytesIO
import unittest

from PIL import Image
from portable import render_page, validate_page, simplify, MAX_GEOMETRY, RENDERER_VERSION


def point(x, y, size=4, opacity=1):
    return [x, y, 0, size, size, opacity, 0.75, 0, 1.2, 1, 0, 0]


def stroke(size=4, color=None, ink="com.apple.ink.pen"):
    points = [point(10, 20, size), point(50, 20, size)]
    return {"inkType": ink, "color": color or [0, 0, 0, 1], "transform": [1, 0, 0, 1, 0, 0],
            "randomSeed": 123, "creationDate": 0, "points": points, "samples": points}


def page(strokes=None):
    return {"format": 1, "width": 64, "height": 72, "strokes": strokes or []}


def image(scene):
    metadata, data = render_page(scene)
    return metadata, Image.open(BytesIO(data)).convert("RGB")


class PortableRendererTests(unittest.TestCase):
    def test_empty_ruled_opaque_page(self):
        metadata, raster = image(page())
        self.assertEqual(raster.size, (128, 144))
        self.assertEqual(raster.getpixel((10, 10)), (255, 255, 255))
        self.assertLess(raster.getpixel((10, 72))[0], 255)
        self.assertEqual(metadata["rendererVersion"], RENDERER_VERSION)
        self.assertEqual(metadata["strokeCount"], 0)
        self.assertEqual(metadata["tagStrokeCounts"], {})

    def test_native_pen_kernel_sizes_cover_app_minimum_default_and_maximum(self):
        # Native tool diameters .5/4/12 map to archived point sizes 2.25/4/8.
        for size, diameter in [(2.25, 0.5), (4, 4), (8, 12)]:
            with self.subTest(size=size):
                _, raster = image(page([stroke(size)]))
                rows = [y for y in range(20, 60) if raster.getpixel((60, y))[0] < 200]
                self.assertGreater(len(rows), 0)
                self.assertLessEqual(abs(len(rows) - 2 * diameter), 1)

    def test_transform_applies_to_centerline_and_width(self):
        value = stroke()
        value["transform"] = [1, 0, 0, 1, 0, 20]
        _, raster = image(page([value]))
        self.assertEqual(raster.getpixel((60, 40)), (255, 255, 255))
        self.assertEqual(raster.getpixel((60, 80)), (0, 0, 0))

    def test_even_odd_clip_hole_and_winding_are_distinct(self):
        value = stroke(8)
        value["mask"] = {"evenOdd": True, "commands": [
            [0, 0, 0], [1, 64, 0], [1, 64, 60], [1, 0, 60], [4],
            [0, 25, 10], [1, 35, 10], [1, 35, 30], [1, 25, 30], [4]]}
        _, raster = image(page([value]))
        self.assertEqual(raster.getpixel((40, 40)), (0, 0, 0))
        self.assertEqual(raster.getpixel((60, 40)), (255, 255, 255))
        value["mask"]["evenOdd"] = False
        _, raster = image(page([value]))
        self.assertEqual(raster.getpixel((60, 40)), (0, 0, 0))

    def test_empty_mask_erases_visible_ink_without_fabricating_source(self):
        value = stroke()
        value["mask"] = {"evenOdd": False, "commands": []}
        metadata, raster = image(page([value]))
        self.assertEqual(raster.getpixel((60, 40)), (255, 255, 255))
        self.assertEqual(metadata["strokeCount"], 1)

    def test_quadratic_and_cubic_mask_commands(self):
        value = stroke()
        value["mask"] = {"evenOdd": False, "commands": [
            [0, 0, 0], [2, 30, 0, 64, 0], [3, 64, 20, 64, 40, 64, 60], [1, 0, 60], [4]]}
        _, raster = image(page([value]))
        self.assertEqual(raster.getpixel((60, 40)), (0, 0, 0))

    def test_stroke_order_and_question_tag(self):
        question = stroke(color=[175 / 255, 82 / 255, 222 / 255, 1])
        metadata, raster = image(page([stroke(), question]))
        self.assertEqual(raster.getpixel((60, 40)), (175, 82, 222))
        self.assertEqual(metadata["tagStrokeCounts"], {"question": 1})
        question["color"] = [0, 0.2, 0.8, 1]
        metadata, _ = image(page([question]))
        self.assertEqual(metadata["tagStrokeCounts"], {})

    def test_both_semantic_tags_count_pen_monoline_and_marker(self):
        strokes = [stroke()]
        for color in ([175 / 255, 82 / 255, 222 / 255, 1], [23 / 255, 127 / 255, 113 / 255, 1]):
            for ink in ("com.apple.ink.pen", "com.apple.ink.monoline", "com.apple.ink.marker"):
                strokes.append(stroke(color=color, ink=ink))
        metadata, _ = image(page(strokes))
        self.assertEqual(metadata["tagStrokeCounts"], {"question": 6})
        metadata, raster = image(page([stroke(color=[23 / 255, 127 / 255, 113 / 255, 1])]))
        self.assertEqual(metadata["tagStrokeCounts"], {"question": 1})
        self.assertEqual(raster.getpixel((60, 40)), (23, 127, 113))

    def test_semantic_tags_tolerate_native_rgba_rounding_only(self):
        for tag, color in (("question", [175 / 255, 82 / 255, 222 / 255, 1]),
                           ("question", [23 / 255, 127 / 255, 113 / 255, 1])):
            for ink in ("com.apple.ink.pen", "com.apple.ink.marker"):
                for channel in range(4):
                    for delta, expected in ((0.49 / 255, {tag: 1}), (0.51 / 255, {})):
                        with self.subTest(tag=tag, ink=ink, channel=channel, delta=delta):
                            native_color = color.copy()
                            native_color[channel] += delta if color[channel] < 1 else -delta
                            metadata, _ = image(page([stroke(color=native_color, ink=ink)]))
                            self.assertEqual(metadata["tagStrokeCounts"], expected)

    def test_marker_has_soft_edges_and_mask_does_not_leak_after_blur(self):
        value = stroke(20, color=[1, 1, 0, 1], ink="com.apple.ink.marker")
        for p in value["samples"]:
            p[5] = 0.5
        value["mask"] = {"evenOdd": False, "commands": [[0, 0, 0], [1, 32, 0], [1, 32, 60], [1, 0, 60], [4]]}
        metadata, raster = image(page([value]))
        self.assertLess(raster.getpixel((40, 40))[2], 100)
        self.assertEqual(raster.getpixel((90, 40)), (255, 255, 255))
        self.assertEqual(metadata["inkTypes"], ["com.apple.ink.marker"])

    def test_opacity_multiplier_two_is_valid(self):
        value = stroke()
        value["points"][0][5] = 2
        validate_page(page([value]))
        for bad in (-1, 2.01):
            value["points"][0][5] = bad
            with self.assertRaises(ValueError):
                validate_page(page([value]))

    def test_reject_invalid_geometry_color_and_domains(self):
        mutations = [lambda s: s.update(inkType="pencil"),
                     lambda s: s["color"].__setitem__(0, float("nan")),
                     lambda s: s["transform"].__setitem__(1, float("inf")),
                     lambda s: s["points"][0].__setitem__(3, -1),
                     lambda s: s["points"][0].__setitem__(2, -1),
                     lambda s: s["points"][0].__setitem__(6, -1),
                     lambda s: s["points"][0].__setitem__(9, -1),
                     lambda s: s["points"][0].__setitem__(10, 2),
                     lambda s: s.update(samples=[]),
                     lambda s: s.update(randomSeed=True)]
        for mutate in mutations:
            value = stroke()
            mutate(value)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                validate_page(page([value]))

    def test_geometry_budget_and_mask_opcode_validation(self):
        value = stroke()
        value["samples"] = [value["samples"][0]] * MAX_GEOMETRY
        with self.assertRaises(ValueError):
            validate_page(page([value]))
        for command in [[True, 0, 0], [1.5, 0, 0], [3, 0, 0]]:
            value = stroke()
            value["mask"] = {"evenOdd": True, "commands": [command]}
            with self.assertRaises(ValueError):
                validate_page(page([value]))

    def test_simplifier_work_budget_keeps_original_geometry(self):
        points = [point(i / 10, i % 2) for i in range(5000)]
        simplified = simplify(points)
        self.assertIs(simplified, points)


if __name__ == "__main__":
    unittest.main()
