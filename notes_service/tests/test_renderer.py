"""Real CPU Chromium tests. Fixtures are synthetic and never touch Draw data."""
import copy
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import time
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zlib

from PIL import Image, ImageCms, ImageDraw

from notes_service.renderer import ROOT, Renderer, RendererError, png


def uid():
    return str(uuid.uuid4()).upper()


def put(assets, image):
    data = png(image)
    sha = hashlib.sha256(data).hexdigest()
    assets[sha] = data
    return sha


def fixture(width=400, height=800):
    assets = {}
    page = {"pageID": uid(), "head": uid(), "background": 0,
            "width": width, "height": height, "objects": [], "strokeTargets": []}
    paper = Image.new("RGBA", (width*2, height*2), "white")
    # Actual capture uses deliberately non-default paper to detect fake ruled bases.
    paper.putpixel((2, 20), (100, 110, 120, 255))
    ink = Image.new("RGBA", paper.size)
    ImageDraw.Draw(ink).line((0, 0, width*2, height*2), fill=(175, 82, 222, 255), width=5)
    page.update(paperSHA256=put(assets, paper), inkSHA256=put(assets, ink),
                compositeSHA256="a"*64, portableSHA256="b"*64)
    context = {"format": 1, "documentID": uid(), "focusPageID": page["pageID"],
               "capturedAt": "2026-10-09T00:00:00Z", "rendererSignature": "native-capture-v1",
               "orientation": "portrait", "pages": [page]}
    return assets, context


def obj(kind="text", source="Hello", y=20, x=20, width=300, height=100):
    return {"id": uid(), "kind": kind, "source": source,
            "frame": {"x": x, "y": y, "width": width, "height": height}, "style": {}}


def draft(context, objects=None, strokes=None):
    return {"draftVersion": 1, "insertPages": [], "pageEdits": [
        {"pageID": context["focusPageID"], "objectEdits": [
            {"op": "add", "object": value} for value in (objects or [obj()])],
         "strokeEdits": strokes or []}]}


def image(data):
    return Image.open(io.BytesIO(data)).convert("RGBA")


class RendererTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assets, cls.context = fixture()
        cls.request = uid()
        cls.objects = [
            obj(source="Привет, свят!\nSecond line"),
            obj("latex", r"\begin{aligned} a &= b+c \\ c &= \frac{1}{2} \end{aligned}", y=100),
            obj("mermaid", "flowchart TD\n A[Start] --> B[Finish]", y=250, height=180),
            obj("circle", '{"cx":50,"cy":50,"rx":35,"ry":35}', y=450),
            obj("arrow", '{"from":[10,10],"to":[150,60]}', y=600),
        ]
        cls.original = draft(cls.context, cls.objects)
        cls.rendered = Renderer(cls.assets.__getitem__).render(cls.context, cls.original, cls.request, "c"*64)

    def setUp(self):
        self.a = copy.deepcopy(self.assets)
        self.c = copy.deepcopy(self.context)
        self.renderer = Renderer(self.a.__getitem__)

    def render(self, d=None):
        return self.renderer.render(self.c, d or draft(self.c), uid(), "c"*64)

    def error(self, d=None, code=None):
        with self.assertRaises(RendererError) as caught:
            self.render(d)
        if code:
            self.assertEqual(caught.exception.code, code)
        self.assertNotIn("Hello", caught.exception.message)
        self.assertEqual(caught.exception.as_dict()["error"]["code"], caught.exception.code)

    def test_all_five_real_owned_browser_kinds_and_tight_assets(self):
        self.assertEqual([o["kind"] for o in self.rendered["objects"]], [o["kind"] for o in self.objects])
        for supplied, resolved in zip(self.objects, self.rendered["objects"]):
            asset = resolved["asset"]
            data = self.rendered["assets"][asset["sha256"]]
            layer = image(data)
            self.assertEqual(hashlib.sha256(data).hexdigest(), asset["sha256"])
            self.assertEqual(layer.mode, "RGBA")
            self.assertEqual(layer.size, (asset["pixelWidth"], asset["pixelHeight"]))
            self.assertEqual(layer.getchannel("A").getbbox(), (0, 0, layer.width, layer.height))
            self.assertIn(0, layer.getchannel("A").getextrema())
            self.assertEqual((resolved["frame"]["width"]*2, resolved["frame"]["height"]*2), layer.size)
            self.assertGreaterEqual(resolved["frame"]["x"], supplied["frame"]["x"])
            self.assertGreaterEqual(resolved["frame"]["y"], supplied["frame"]["y"])
            self.assertEqual(resolved["style"], {"fontSize": 18, "lineWidth": 1, "color": "#000000"})
            self.assertEqual(resolved["provenance"], {"requestID": self.request, "contextSHA256": "c"*64,
                                                     "rendererSignature": "draw-ai-render-v1"})
            self.assertEqual(resolved["revision"], 1)
        self.assertEqual(self.original, draft(self.context, self.objects))
        self.assertTrue(all("expectedObject" not in op for e in self.rendered["pageEdits"] for op in e["objectEdits"]))

    def test_highlight_fills_intrinsic_frame_rgba8_cyan_at_exact_twenty_percent(self):
        from server.ai_models import validate_asset, validate_object
        objects = [obj("highlight", '{"opacity":0.2}', x=20, y=20, width=120, height=30),
                   obj("highlight", '{"opacity":0.2}', x=180, y=20, width=10.5, height=5.5),
                   obj("highlight", '{"opacity":0.2}', x=200, y=20, width=0.5, height=0.5)]
        objects[1]["style"] = {"fontSize": 14, "color": "#00b8d9"}
        before = copy.deepcopy(self.c)
        out = self.render(draft(self.c, objects))
        for supplied, resolved in zip(objects, out["objects"]):
            data = out["assets"][resolved["asset"]["sha256"]]
            validate_object(resolved)
            validate_asset(data, resolved["asset"])
            layer = image(data)
            self.assertEqual(resolved["frame"], supplied["frame"])
            self.assertEqual(layer.size, (supplied["frame"]["width"]*2, supplied["frame"]["height"]*2))
            self.assertEqual(layer.getchannel("A").getextrema(), (51, 51))
            self.assertEqual(sum(layer.getchannel("A").tobytes()) / (layer.width*layer.height), 51)
            for channel, expected in zip(layer.split()[:3], (0, 184, 217)):
                low, high = channel.getextrema()
                self.assertLessEqual(abs(low-expected), 2)
                self.assertLessEqual(abs(high-expected), 2)
            self.assertEqual(resolved["source"], '{"opacity":0.2}')
            self.assertEqual(resolved["style"], {"fontSize": supplied["style"].get("fontSize", 18),
                                                 "color": "#00B8D9", "lineWidth": 1})
        self.assertEqual(self.c, before)

    def test_highlight_preview_keeps_black_native_ink_and_raw_clip_unchanged(self):
        page = self.c["pages"][0]
        ink = Image.new("RGBA", (800, 1600))
        ImageDraw.Draw(ink).line((45, 50, 260, 60), fill=(0, 0, 0, 255), width=5)
        # Include partially covered pixels to verify the original native alpha, too.
        ink.putpixel((60, 62), (0, 0, 0, 127))
        page["inkSHA256"] = put(self.a, ink)
        raw_clip = self.a[page["inkSHA256"]]
        context_before, assets_before = copy.deepcopy(self.c), copy.deepcopy(self.a)
        out = self.render(draft(self.c, [obj("highlight", '{"opacity":0.2}', width=120, height=30)]))
        resolved = out["objects"][0]
        expected = image(self.a[page["paperSHA256"]])
        expected.alpha_composite(image(out["assets"][resolved["asset"]["sha256"]]), (40, 40))
        expected.alpha_composite(image(raw_clip))
        actual = image(out["previews"][page["pageID"]])
        self.assertEqual(actual.tobytes(), expected.tobytes())
        self.assertEqual(actual.getpixel((100, 53)), (0, 0, 0, 255))
        self.assertEqual(actual.getpixel((100, 90)), (204, 241, 247, 255))
        self.assertEqual(actual.getpixel((300, 90)), (255, 255, 255, 255))
        self.assertEqual(self.c, context_before)
        self.assertEqual(self.a, assets_before)
        self.assertEqual(self.a[page["inkSHA256"]], raw_clip)

    def test_highlight_draft_rejects_invalid_geometry_alpha_resources_and_style_before_browser(self):
        from notes_service import validation as check
        from notes_service.storage import Problem
        invalid = ["", "{}", "[]", "null", "0.2", "not JSON", '{"opacity":true}',
                   '{"opacity":"0.2"}', '{"opacity":NaN}', '{"opacity":Infinity}',
                   '{"opacity":0.2001}', '{"opacity":-0.2}', '{"opacity":0}', '{"opacity":1}',
                   '{"opacity":0.2,"opacity":0.2}', '{"opacity":0.2,"x":0}',
                   '{"opacity":0.2,"width":100}', '{"opacity":0.2,"shape":"circle"}',
                   '{"opacity":0.2,"fill":"url(https://example.invalid/a)"}',
                   '{"opacity":0.2,"svg":"<rect onload=alert(1)>"}',
                   '{"opacity":0.2,"source":"file:///private"}']
        with patch.object(Renderer, "_browser", side_effect=AssertionError("browser must not start")):
            for source in invalid:
                with self.subTest(source=source):
                    value = draft(self.c, [obj("highlight", source)])
                    self.error(value)
                    with self.assertRaises(Problem):
                        check.draft(value, self.c)
            for style in ({"color": "#00B8D933"}, {"opacity": 0.2}, {"color": "url(https://example.invalid)"}):
                value = obj("highlight", '{"opacity":0.2}')
                value["style"] = style
                self.error(draft(self.c, [value]))
                with self.assertRaises(Problem):
                    check.draft(draft(self.c, [value]), self.c)
            for delta in ({"width": 0}, {"height": -1}, {"x": float("nan")}, {"width": 500}):
                value = obj("highlight", '{"opacity":0.2}')
                value["frame"].update(delta)
                self.error(draft(self.c, [value]))
            for kind in ("rectangle", [], {}):
                self.error(draft(self.c, [obj(kind, '{"opacity":0.2}')]))
                with self.assertRaises(Problem):
                    check.draft(draft(self.c, [obj(kind, '{"opacity":0.2}')]), self.c)
        valid = draft(self.c, [obj("highlight", '{"opacity":0.2}')])
        check.draft(valid, self.c)

    def test_existing_highlight_scene_guard_and_asset_remain_exact(self):
        from notes_service.manager import Manager
        from notes_service.storage import encoded
        original = self.render(draft(self.c, [obj("highlight", '{"opacity":0.2}')]))
        old = original["objects"][0]
        self.c["pages"][0]["objects"] = [old]
        self.a.update(original["assets"])
        replacement = obj("highlight", '{"opacity":0.2}', x=30)
        replacement["id"] = old["id"]
        amended = {"pageEdits": [{"pageID": self.c["focusPageID"], "objectEdits": [
            {"op": "replace", "objectID": old["id"], "expectedRevision": 1, "object": replacement},
            {"op": "add", "object": obj(source="Still 18-point text", y=100)}]}]}
        with tempfile.TemporaryDirectory(prefix="draw-highlight-test-", dir=Path.home()/"tmp") as folder:
            manager = Manager(folder, None)
            try:
                context_sha = manager.store.put_bytes(encoded(self.c))
                request_id = uid()
                out = self.renderer.render(self.c, amended, request_id, context_sha)
                for sha, data in out["assets"].items():
                    manager.store.put_asset(sha, data)
                manager.validate_rendered({"draft": amended, "contextSHA256": context_sha, "requestID": request_id}, out)
                self.assertEqual(out["pageEdits"][0]["objectEdits"][0]["expectedObject"], old)
                self.assertEqual(out["objects"][0]["revision"], 2)
                self.assertEqual(out["objects"][1]["style"]["fontSize"], 18)
                self.assertEqual(self.c["pages"][0]["objects"], [old])
                self.assertEqual(self.a[old["asset"]["sha256"]], original["assets"][old["asset"]["sha256"]])
            finally:
                manager.close()

    def test_installed_serif_faces_and_declared_browser_sizes(self):
        # Instrument only this owned browser via a Node preload. CDP reports fonts
        # that actually painted glyphs, not merely a requested CSS family or regex.
        # Production wire output, done.json and Renderer remain unchanged.
        preload = r"""
import {chromium} from PLAYWRIGHT;
import {writeFile} from 'node:fs/promises';
import {join, basename} from 'node:path';
const launch = chromium.launch.bind(chromium);
chromium.launch = async (...args) => {
  const browser = await launch(...args);
  const newContext = browser.newContext.bind(browser);
  browser.newContext = async (...args) => {
    const context = await newContext(...args);
    const newPage = context.newPage.bind(context);
    context.newPage = async (...args) => {
      const page = await newPage(...args);
      const screenshot = page.screenshot.bind(page);
      page.screenshot = async options => {
        const cdp = await context.newCDPSession(page);
        try {
          await cdp.send('DOM.enable'); await cdp.send('CSS.enable');
          const {root} = await cdp.send('DOM.getDocument');
          const diagnostics = {};
          for (const selector of ['#content', '.katex', '.katex-html .text .mord',
            '.katex-html .mathnormal', '.katex-html .msupsub .mord', 'svg text tspan']) {
            const {nodeIds} = await cdp.send('DOM.querySelectorAll', {nodeId:root.nodeId, selector});
            const styles = await page.locator(selector).evaluateAll(nodes => nodes.map(node => {
              const css = getComputedStyle(node);
              return {text:node.textContent, children:node.childElementCount,
                size:parseFloat(css.fontSize), weight:css.fontWeight, style:css.fontStyle};
            }));
            for (let i=0; i<nodeIds.length; i++) {
              styles[i].fonts = (await cdp.send('CSS.getPlatformFontsForNode', {nodeId:nodeIds[i]})).fonts;
            }
            diagnostics[selector] = styles;
          }
          await writeFile(join(DIAGNOSTICS, basename(options.path)+'.json'), JSON.stringify(diagnostics));
        } finally {await cdp.detach();}
        return screenshot(options);
      };
      return page;
    };
    return context;
  };
  return browser;
};
"""
        formula = (r"\begin{aligned} \text{English Български} &= x^2 + \frac{1}{2} \\" "\n"
                   r"\textbf{Bold Удебелен} &= y \\" "\n"
                   r"\textit{Italic Курсив} &= z \\" "\n"
                   r"\textbf{\textit{Both Двете}} &= w \end{aligned}")
        # Each object gets ample bounds; no wrapping/scaling may mask a size change.
        objects = []
        for size in (14, 18):
            for kind, source in [("text", "English Български"), ("latex", formula),
                                 ("mermaid", "flowchart TD\n A[English] --> B[Български]")]:
                value = obj(kind, source, width=360, height=200)
                value["style"]["fontSize"] = size
                objects.append(value)
        with tempfile.TemporaryDirectory(prefix="draw-type-test-", dir=Path.home()/"tmp") as folder:
            folder = Path(folder)
            script = folder/"inspect.mjs"
            script.write_text(preload.replace("PLAYWRIGHT", json.dumps(
                (ROOT/"node_modules/playwright/index.mjs").as_uri())).replace(
                "DIAGNOSTICS", json.dumps(str(folder))), encoding="utf-8")
            popen = subprocess.Popen
            def instrument(command, **kwargs):
                return popen([command[0], "--import", str(script), *command[1:]], **kwargs)
            with patch("notes_service.renderer.subprocess.Popen", side_effect=instrument):
                rendered = self.render(draft(self.c, objects))
            for index, supplied in enumerate(objects):
                with self.subTest(kind=supplied["kind"], size=supplied["style"]["fontSize"]):
                    metrics = json.loads((folder/f'{index}.png.json').read_text())
                    size = supplied["style"]["fontSize"]
                    self.assertEqual(metrics["#content"][0]["size"], size)
                    if supplied["kind"] == "text":
                        prose = metrics["#content"]
                    elif supplied["kind"] == "mermaid":
                        prose = metrics["svg text tspan"]
                        self.assertTrue(any("English" in node["text"] for node in prose))
                        self.assertTrue(any("Български" in node["text"] for node in prose))
                    else:
                        self.assertEqual(metrics[".katex"][0]["size"], size)
                        prose = [node for node in metrics[".katex-html .text .mord"] if not node["children"]]
                        self.assertEqual({(node["weight"], node["style"]) for node in prose},
                                         {("400", "normal"), ("700", "normal"),
                                          ("400", "italic"), ("700", "italic")})
                        for weight, style in {("400", "normal"), ("700", "normal"),
                                              ("400", "italic"), ("700", "italic")}:
                            face = [node for node in prose if (node["weight"], node["style"]) == (weight, style)]
                            self.assertTrue(any(any("A" <= c <= "Z" or "a" <= c <= "z" for c in node["text"]) for node in face))
                            self.assertTrue(any(any("Ѐ" <= c <= "ӿ" for c in node["text"]) for node in face))
                        # Math remains KaTeX, with its original superscript hierarchy.
                        math = metrics[".katex-html .mathnormal"]
                        self.assertTrue(math)
                        for node in math:
                            self.assertEqual(node["size"], size)
                            self.assertTrue(all(font["familyName"].startswith("KaTeX_") for font in node["fonts"]))
                            self.assertTrue(node["fonts"])
                        scripts = metrics[".katex-html .msupsub .mord"]
                        self.assertTrue(scripts)
                        self.assertTrue(all(node["size"] < size for node in scripts))
                    self.assertTrue(prose)
                    for node in prose:
                        self.assertEqual(node["size"], size)
                        self.assertTrue(node["fonts"])
                        for font in node["fonts"]:
                            self.assertEqual(font["familyName"], "Liberation Serif")
                            self.assertTrue(font["isCustomFont"])
                            self.assertGreater(font["glyphCount"], 0)
                            if supplied["kind"] == "latex":
                                face = {("400", "normal"): "LiberationSerif", ("700", "normal"): "LiberationSerif-Bold",
                                        ("400", "italic"): "LiberationSerif-Italic", ("700", "italic"): "LiberationSerif-BoldItalic"}
                                self.assertEqual(font["postScriptName"], face[node["weight"], node["style"]])
                    resolved = rendered["objects"][index]
                    layer = image(rendered["assets"][resolved["asset"]["sha256"]])
                    self.assertEqual(layer.size, (resolved["frame"]["width"]*2, resolved["frame"]["height"]*2))
                    self.assertIn(0, layer.getchannel("A").getextrema())
                    for axis in ("width", "height"):
                        self.assertLessEqual(resolved["frame"][axis], supplied["frame"][axis])

    def test_serif_text_and_mermaid_do_not_shrink_to_fit(self):
        for kind, source in [("text", "English Български"),
                             ("mermaid", "flowchart TD\n A[English] --> B[Български]")]:
            with self.subTest(kind=kind):
                self.error(draft(self.c, [obj(kind, source, width=1, height=1)]), "render_failed")

    def test_native_ink_above_ai_actual_paper_and_preview_asset_placement(self):
        page = self.c["pages"][0]
        composed = image(self.rendered["previews"][page["pageID"]])
        expected = image(self.a[page["paperSHA256"]])
        for value in self.rendered["objects"]:
            layer = image(self.rendered["assets"][value["asset"]["sha256"]])
            expected.alpha_composite(layer, (round(value["frame"]["x"]*2), round(value["frame"]["y"]*2)))
        expected.alpha_composite(image(self.a[page["inkSHA256"]]))
        self.assertEqual(composed.tobytes(), expected.tobytes())
        self.assertEqual(composed.getpixel((80, 160)), (175, 82, 222, 255))
        self.assertEqual(composed.getpixel((2, 20)), (100, 110, 120, 255))

    def test_captured_object_replace_remove_preserve_z_order_and_revision(self):
        page = self.c["pages"][0]
        existing = copy.deepcopy(self.rendered["objects"][:3])
        page["objects"] = existing
        self.a.update(self.rendered["assets"])
        replacement = obj(source="Changed")
        replacement["id"] = existing[0]["id"]
        new = obj(source="New", y=500)
        d = {"pageEdits": [{"pageID": page["pageID"], "objectEdits": [
            {"op": "replace", "objectID": existing[0]["id"], "expectedRevision": 1, "object": replacement},
            {"op": "remove", "objectID": existing[1]["id"], "expectedRevision": 1},
            {"op": "add", "object": new}]}]}
        out = self.render(d)
        self.assertEqual(out["objects"][0]["id"], existing[0]["id"])
        self.assertEqual(out["objects"][0]["revision"], 2)
        expected = image(self.a[page["paperSHA256"]])
        for value in [out["objects"][0], existing[2], out["objects"][1]]:
            data = {**self.a, **out["assets"]}[value["asset"]["sha256"]]
            expected.alpha_composite(image(data), (round(value["frame"]["x"]*2), round(value["frame"]["y"]*2)))
        expected.alpha_composite(image(self.a[page["inkSHA256"]]))
        self.assertEqual(image(out["previews"][page["pageID"]]).tobytes(), expected.tobytes())
        self.assertEqual(page["objects"], existing)
        ops = out["pageEdits"][0]["objectEdits"]
        self.assertEqual(ops[0]["expectedObject"], existing[0])
        self.assertEqual(ops[1]["expectedObject"], existing[1])
        self.assertNotIn("expectedObject", ops[2])
        self.assertTrue(all("expectedObject" not in op for op in d["pageEdits"][0]["objectEdits"]))

    def stroke_fixture(self):
        page = self.c["pages"][0]
        targets = []
        for index, alpha in enumerate([100, 200, 255]):
            layer = Image.new("RGBA", (40, 40))
            ImageDraw.Draw(layer).ellipse((2, 2, 37, 37), fill=(175, 82, 222, alpha))
            sha = put(self.a, layer)
            targets.append({"id": f"stroke-{index}", "fingerprint": str(index)*64, "index": index,
                            "frame": {"x": 20+index*10, "y": 300, "width": 20, "height": 20},
                            "asset": {"sha256": sha, "pixelWidth": 40, "pixelHeight": 40, "scale": 2}})
        # Deliberately unsorted input; index defines native order.
        page["strokeTargets"] = targets[::-1]
        strokes = [{"id": "stroke-0", "fingerprint": "0"*64, "op": "recolor", "color": "#5ac8fa"},
                   {"id": "stroke-1", "fingerprint": "1"*64, "op": "remove"}]
        return targets, strokes

    def test_scoped_native_stroke_remove_recolor_preserves_alpha_and_order(self):
        targets, strokes = self.stroke_fixture()
        out = self.render(draft(self.c, strokes=strokes))
        page = self.c["pages"][0]
        expected = image(self.a[page["paperSHA256"]])
        for o in out["objects"]:
            expected.alpha_composite(image(out["assets"][o["asset"]["sha256"]]),
                                     (round(o["frame"]["x"]*2), round(o["frame"]["y"]*2)))
        layer = image(self.a[targets[0]["asset"]["sha256"]])
        tinted = Image.new("RGBA", layer.size, "#5AC8FA")
        tinted.putalpha(layer.getchannel("A"))
        expected.alpha_composite(tinted, (40, 600))
        expected.alpha_composite(image(self.a[targets[2]["asset"]["sha256"]]), (80, 600))
        actual = image(out["previews"][page["pageID"]])
        self.assertEqual(actual.tobytes(), expected.tobytes())
        self.assertEqual(actual.getpixel((50, 610)), (190, 233, 253, 255))
        self.assertEqual(out["pageEdits"][0]["strokeEdits"][0]["color"], "#5ac8fa")

    def test_position_only_replacements_reuse_all_six_captured_kind_assets_and_metadata(self):
        from notes_service import validation as check
        from notes_service.manager import Manager
        from notes_service.storage import Problem, encoded
        supplied = copy.deepcopy(self.objects) + [obj("highlight", '{"opacity":0.2}', x=20, y=730, width=100, height=20)]
        first = self.render(draft(self.c, supplied))
        captured = copy.deepcopy(first["objects"])
        self.c["pages"][0]["objects"] = captured
        self.a.update(first["assets"])
        edits = []
        for old in captured:
            moved = {key: copy.deepcopy(old[key]) for key in ("id", "kind", "source", "frame", "style")}
            moved["frame"].update(x=-10.26, y=old["frame"]["y"] + 0.26)
            edits.append({"op": "replace", "objectID": old["id"], "expectedRevision": old["revision"], "object": moved})
        value = {"pageEdits": [{"pageID": self.c["focusPageID"], "objectEdits": edits}]}
        before = copy.deepcopy((self.c, value, self.a))
        check.draft(value, self.c)
        with tempfile.TemporaryDirectory(prefix="draw-object-move-test-", dir=Path.home()/"tmp") as folder:
            manager = Manager(folder, None)
            try:
                for sha, data in self.a.items(): manager.store.put_asset(sha, data)
                context_sha = manager.store.put_bytes(encoded(self.c))
                request = uid()
                with patch.object(Renderer, "_browser", side_effect=AssertionError("position-only must not reflow")):
                    out = self.renderer.render(self.c, value, request, context_sha)
                r = {"draft": value, "contextSHA256": context_sha, "requestID": request}
                manager.validate_rendered(r, out)
                self.assertEqual([o["kind"] for o in out["objects"]], [o["kind"] for o in captured])
                expected_preview = image(self.a[self.c["pages"][0]["paperSHA256"]])
                for old, resolved, op in zip(captured, out["objects"], out["pageEdits"][0]["objectEdits"]):
                    self.assertEqual(op["expectedObject"], old)
                    for key in ("id", "kind", "source", "style", "asset"):
                        self.assertEqual(encoded(resolved[key]), encoded(old[key]))
                    self.assertEqual(resolved["revision"], old["revision"] + 1)
                    self.assertEqual(resolved["frame"], {**old["frame"], "x": -10.5, "y": old["frame"]["y"] + 0.5})
                    self.assertEqual(resolved["provenance"], {"requestID": request, "contextSHA256": context_sha,
                                                            "rendererSignature": "draw-ai-render-v1"})
                    sha = old["asset"]["sha256"]
                    self.assertEqual(out["assets"][sha], first["assets"][sha])
                    self.assertEqual(image(out["assets"][sha]).tobytes(), image(first["assets"][sha]).tobytes())
                    expected_preview.alpha_composite(image(out["assets"][sha]),
                        (round(resolved["frame"]["x"]*2), round(resolved["frame"]["y"]*2)))
                expected_preview.alpha_composite(image(self.a[self.c["pages"][0]["inkSHA256"]]))
                self.assertEqual(image(out["previews"][self.c["focusPageID"]]).tobytes(), expected_preview.tobytes())
                # All original expected guards, extents, styles and PNGs stay bound.
                for field in ("asset", "style", "frame", "expectedObject", "provenance"):
                    bad = copy.deepcopy(out)
                    op = bad["pageEdits"][0]["objectEdits"][0]
                    if field == "asset": op["object"][field] = captured[1][field]
                    elif field == "style": op["object"][field]["color"] = "#FF0000"
                    elif field == "frame": op["object"][field]["x"] += 0.5
                    elif field == "expectedObject": op[field]["source"] += " changed"
                    else: op["object"][field]["requestID"] = uid()
                    bad["objects"][0] = op["object"]
                    with self.assertRaises(Problem): manager.validate_rendered(r, bad)
            finally:
                manager.close()
        self.assertEqual((self.c, value, self.a), before)

    def test_position_only_does_not_bypass_new_content_style_extent_or_field_validation(self):
        old = copy.deepcopy(self.rendered["objects"][0])
        self.c["pages"][0]["objects"] = [old]
        self.a.update(self.rendered["assets"])
        supplied = {key: copy.deepcopy(old[key]) for key in ("id", "kind", "source", "frame", "style")}
        def value(object):
            return {"pageEdits": [{"pageID": self.c["focusPageID"], "objectEdits": [
                {"op": "replace", "objectID": old["id"], "expectedRevision": old["revision"], "object": object}]}]}
        for field, key, v in [("source", None, "Changed source"), ("kind", None, "latex"),
                              ("style", "fontSize", 18.01), ("style", "color", "#FF0000"),
                              ("frame", "width", old["frame"]["width"]+0.5),
                              ("frame", "height", old["frame"]["height"]+0.5)]:
            mutated = copy.deepcopy(supplied)
            if key is None: mutated[field] = v
            else: mutated[field][key] = v
            with patch.object(Renderer, "_browser", side_effect=AssertionError("normal rendering required")):
                with self.assertRaisesRegex(AssertionError, "normal rendering required"): self.render(value(mutated))
        for field in ("asset", "provenance", "revision"):
            malformed = copy.deepcopy(supplied)
            malformed[field] = old[field]
            with patch.object(Renderer, "_browser", side_effect=AssertionError("no browser")):
                self.error(value(malformed))
        for x in (500, -4096.1, True):
            malformed = copy.deepcopy(supplied); malformed["frame"]["x"] = x
            self.error(value(malformed))

    def test_position_only_move_preflights_captured_png_hash_and_dimensions(self):
        old = copy.deepcopy(self.rendered["objects"][0])
        self.c["pages"][0]["objects"] = [old]
        self.a.update(self.rendered["assets"])
        supplied = {key: copy.deepcopy(old[key]) for key in ("id", "kind", "source", "frame", "style")}
        supplied["frame"]["x"] = -old["frame"]["width"]
        value = {"pageEdits": [{"pageID": self.c["focusPageID"], "objectEdits": [
            {"op": "replace", "objectID": old["id"], "expectedRevision": 1, "object": supplied}]}]}
        with patch.object(Renderer, "_browser", side_effect=AssertionError("no browser")):
            del self.a[old["asset"]["sha256"]]
            self.error(value, "missing_asset")
            self.a[old["asset"]["sha256"]] = b"bad bytes"
            self.error(value, "invalid_asset")
            wrong = put(self.a, Image.new("RGBA", (1, 1), "black"))
            old["asset"]["sha256"] = wrong
            self.error(value, "invalid_asset")

    def test_keep_uses_full_native_ink_not_single_strokes(self):
        page = self.c["pages"][0]
        page["strokeTargets"] = [{"id": "s", "fingerprint": "0"*64, "index": 0}]
        out = self.render(draft(self.c, strokes=[{"id": "s", "fingerprint": "0"*64, "op": "keep"}]))
        actual = image(out["previews"][page["pageID"]])
        self.assertEqual(actual.getpixel((80, 160)), (175, 82, 222, 255))

    def test_missing_stroke_capture_fails_including_removed_stroke(self):
        targets, strokes = self.stroke_fixture()
        self.c["pages"][0]["strokeTargets"][1].pop("frame")
        self.error(draft(self.c, strokes=strokes), "missing_asset")

    def test_inserted_landscape_grid_and_continuation_geometry(self):
        self.c["orientation"] = "landscape"
        page_id = uid()
        d = draft(self.c)
        d["insertPages"] = [{"pageID": page_id, "afterPageID": self.c["focusPageID"],
                             "background": 3, "width": 1361, "height": 1024}]
        d["pageEdits"].append({"pageID": page_id, "objectEdits": [{"op": "add", "object": obj(source="Continued")} ]})
        out = self.render(d)
        self.assertEqual(set(out["previews"]), {page_id, self.c["focusPageID"]})
        paper = image(out["previews"][page_id])
        self.assertEqual(paper.size, (2722, 2048))
        self.assertEqual(paper.getpixel((72, 500)), (224, 224, 224, 255))
        self.assertEqual(paper.getpixel((500, 72)), (224, 224, 224, 255))
        self.assertEqual(paper.getpixel((500, 501)), (255, 255, 255, 255))

    def test_paper_types_native_geometry(self):
        for pattern in range(4):
            page = {"width": 100, "height": 100, "background": pattern}
            paper = Renderer._paper(page)
            self.assertEqual(paper.getpixel((70, 70)), (255, 255, 255, 255))
            self.assertEqual(paper.getpixel((73, 73)), (199, 199, 199, 255) if pattern == 1 else (255, 255, 255, 255))
            self.assertEqual(paper.getpixel((10, 72)), (224, 224, 224, 255) if pattern in {2, 3} else (255, 255, 255, 255))

    def test_injection_and_source_limits_rejected_before_browser(self):
        payloads = [
            ("latex", r"\href{https://evil.invalid}{x}"),
            ("latex", r"\htmlClass{foo}{x}"),
            ("latex", r"\def\a{\a}\a"),
            ("latex", '<script>alert(1)</script>'),
            ("mermaid", 'flowchart TD\n A --> B\n click A callback'),
            ("mermaid", '%%{init: {"securityLevel":"loose"}}%%\nflowchart TD\nA --> B'),
            ("mermaid", '---\nconfig:\n securityLevel: loose\n---\nflowchart TD\nA --> B'),
            ("mermaid", 'flowchart TD\n A["<img src=x onerror=alert(1)>"]'),
            ("mermaid", 'flowchart TD\n A["&#60;script&#62;"]'),
            ("mermaid", 'flowchart TD\n A --> B\n style A fill:red'),
            ("text", "x"*65537),
        ]
        with patch.object(Renderer, "_browser", side_effect=AssertionError("browser must not start")):
            for kind, source in payloads:
                with self.subTest(kind=kind, source=source[:30]):
                    self.error(draft(self.c, [obj(kind, source)]))

    def test_plain_text_html_is_literal_not_executable(self):
        out = self.render(draft(self.c, [obj(source='<script>throw Error("pwned")</script>')]))
        self.assertEqual(out["objects"][0]["source"], '<script>throw Error("pwned")</script>')

    def test_malformed_finite_bounds_unknown_fields_and_operations(self):
        cases = []
        for value in [float("nan"), float("inf"), -1, True, "100"]:
            o = obj(); o["frame"]["width"] = value; cases.append(draft(self.c, [o]))
        for o in [obj("unknown"), obj("circle", '{"cx":0,"cy":1,"rx":3,"ry":4}'),
                  obj("arrow", '{"from":[0,0],"to":[0,0]}'),
                  obj("text", ""), obj("circle", '{"cx":NaN,"cy":1,"rx":3,"ry":4}')]:
            cases.append(draft(self.c, [o]))
        o = obj(); o["provenance"] = {}; cases.append(draft(self.c, [o]))
        d = draft(self.c); d["pageEdits"][0]["objectEdits"][0]["op"] = "inject"; cases.append(d)
        o = obj(); o["style"] = {"color": "url(evil)"}; cases.append(draft(self.c, [o]))
        with patch.object(Renderer, "_browser", side_effect=AssertionError("browser must not start")):
            for d in cases:
                self.error(d)
            self.c["orientation"] = []
            self.error()

    def test_object_count_fresh_ids_and_captured_scope(self):
        with patch.object(Renderer, "_browser", side_effect=AssertionError("browser must not start")):
            self.error(draft(self.c, [obj() for _ in range(129)]), "render_limit")
            o = obj(); self.error(draft(self.c, [o, o]))
            d = draft(self.c); d["pageEdits"][0]["objectEdits"] = [{"op": "remove", "objectID": uid(), "expectedRevision": 1}]
            self.error(d)
            self.c["pages"][0]["objects"] = self.rendered["objects"][:1]
            captured = self.rendered["objects"][0]
            d["pageEdits"][0]["objectEdits"] = [{"op": "replace", "objectID": captured["id"], "expectedRevision": 3, "object": obj()}]
            self.error(d)

    def test_fingerprint_and_ambiguous_stroke_scope(self):
        _, strokes = self.stroke_fixture()
        with patch.object(Renderer, "_browser", side_effect=AssertionError("browser must not start")):
            strokes[0]["fingerprint"] = "9"*64
            self.error(draft(self.c, strokes=strokes))
            self.c["pages"][0]["strokeTargets"].append(self.c["pages"][0]["strokeTargets"][0])
            self.error(draft(self.c))

    def test_missing_hash_mismatch_dimension_and_png_limits(self):
        page = self.c["pages"][0]
        old = page["paperSHA256"]
        del self.a[old]
        self.error(code="missing_asset")
        self.a[old] = b"not a png"
        self.error(code="invalid_asset")
        page["paperSHA256"] = put(self.a, Image.new("RGBA", (10, 10)))
        self.error(code="invalid_asset")
        page["paperSHA256"] = put(self.a, Image.new("RGBA", (8193, 1)))
        self.error(code="render_limit")

    def test_large_decoded_workload_is_separate_from_encoded_transfer_limit(self):
        from notes_service.renderer import MAX_BYTES, MAX_DECODED_BYTES
        self.assertEqual(MAX_BYTES, 128 * 1024 * 1024)
        self.assertEqual(MAX_DECODED_BYTES, 4 * 1024 * 1024 * 1024)
        assets, context = fixture(width=1024, height=1361)
        pages = [copy.deepcopy(context["pages"][0]) for _ in range(4)]
        for page in pages:
            page["pageID"] = uid()
        context["pages"] = pages
        context["focusPageID"] = pages[0]["pageID"]
        edits = [{"pageID": page["pageID"], "objectEdits": [{"op": "add", "object": obj()}],
                  "strokeEdits": []} for page in pages]
        value = {"draftVersion": 1, "insertPages": [], "pageEdits": edits}
        # Four paper/ink pairs cost 170 MiB decoded even though each PNG is small.
        with patch("notes_service.renderer.MAX_DECODED_BYTES", 128 * 1024 * 1024):
            with self.assertRaises(RendererError) as caught:
                Renderer(assets.__getitem__).render(context, value, self.request, "c"*64)
            self.assertEqual(caught.exception.code, "render_limit")
        result = Renderer(assets.__getitem__).render(context, value, self.request, "c"*64)
        self.assertEqual(set(result["previews"]), {page["pageID"] for page in pages})
        self.assertTrue(all(len(data) < MAX_BYTES for data in result["previews"].values()))

    def test_encoded_png_limit_still_applies_with_large_decoded_budget(self):
        with patch("notes_service.renderer.MAX_BYTES", 8):
            self.error(code="render_limit")

    def test_oversized_header_is_rejected_without_decoding(self):
        def chunk(name, payload):
            return struct.pack(">I", len(payload)) + name + payload + struct.pack(">I", zlib.crc32(name+payload))
        data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8192, 8192, 8, 6, 0, 0, 0))
        data += chunk(b"IDAT", zlib.compress(b"\x00")) + chunk(b"IEND", b"")
        sha = hashlib.sha256(data).hexdigest()
        self.a[sha] = data
        self.c["pages"][0]["paperSHA256"] = sha
        self.error(code="render_limit")

    def test_real_parse_failure_too_small_box_and_timeout_cleanup(self):
        self.error(draft(self.c, [obj("mermaid", "totally invalid Mermaid input")]), "render_failed")
        self.error(draft(self.c, [obj("latex", r"\frac{1}{2}", width=1, height=1)]), "render_failed")
        start = time.monotonic()
        folders = []
        browser = Renderer._browser
        def owned(folder, timeout):
            folders.append(folder)
            return browser(folder, timeout)
        with patch.object(Renderer, "_browser", side_effect=owned), patch("notes_service.renderer.PASS_SECONDS", 0.01):
            self.error(code="render_timeout")
        self.assertLess(time.monotonic()-start, 3)
        self.assertTrue(folders)
        self.assertTrue(all(not folder.exists() for folder in folders))

    def test_native_opaque_rgb_and_icc_srgb_capture(self):
        page = self.c["pages"][0]
        original = image(self.a[page["paperSHA256"]])
        out = io.BytesIO()
        original.convert("RGB").save(out, format="PNG",
            icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
        data = out.getvalue()
        sha = hashlib.sha256(data).hexdigest()
        self.a[sha] = data
        page["paperSHA256"] = sha
        result = self.render()
        self.assertEqual(image(result["previews"][page["pageID"]]).getpixel((2,20)), (100,110,120,255))

    def test_real_output_passes_manager_frozen_validator(self):
        # Durable scratch CAS, but no HTTP service, worker or live source.
        from notes_service.manager import Manager
        from notes_service.storage import encoded
        with tempfile.TemporaryDirectory(prefix="draw-render-integration-", dir=Path.home()/"tmp") as folder:
            manager = Manager(folder, None)
            try:
                for sha, data in {**self.a, **self.rendered["assets"]}.items():
                    manager.store.put_asset(sha, data)
                context_sha = manager.store.put_bytes(encoded(self.c))
                rendered = copy.deepcopy(self.rendered)
                for value in rendered["objects"]:
                    value["provenance"]["contextSHA256"] = context_sha
                manager.validate_rendered({"draft": self.original, "contextSHA256": context_sha,
                                           "requestID": self.request}, rendered)
            finally:
                manager.close()

    def test_browser_memory_limit_is_structured_and_cleans_temp(self):
        with patch.object(Renderer, "_owned_rss", return_value=2*1024*1024*1024):
            self.error(code="render_limit")

    def test_native_ink_requires_alpha(self):
        self.c["pages"][0]["inkSHA256"] = put(self.a, Image.new("RGB", (800,1600), "white"))
        self.error(code="invalid_asset")

    def test_own_browser_process_group_is_closed(self):
        pids = []
        popen = subprocess.Popen
        def owned(*args, **kwargs):
            process = popen(*args, **kwargs)
            pids.append(process.pid)
            return process
        with patch("notes_service.renderer.subprocess.Popen", side_effect=owned):
            self.render()
        self.assertEqual(len(pids), 1)
        live = []
        for path in Path("/proc").iterdir():
            if not path.name.isdigit():
                continue
            try:
                stat = (path/"stat").read_text()
                fields = stat[stat.rfind(")")+2:].split()
                if int(fields[2]) == pids[0] and fields[0] != "Z":
                    live.append(path.name)
            except (OSError, IndexError, ValueError):
                pass
        self.assertEqual(live, [])

    def stale_fixture(self):
        from notes_service.storage import encoded
        page = self.c["pages"][0]
        old = copy.deepcopy(self.rendered["objects"][0])
        page["objects"] = [old]
        self.a.update(self.rendered["assets"])
        flat = image(self.a[page["paperSHA256"]])
        flat.alpha_composite(image(self.a[old["asset"]["sha256"]]),
                             (round(old["frame"]["x"]*2), round(old["frame"]["y"]*2)))
        flat.alpha_composite(image(self.a[page["inkSHA256"]]))
        # The legacy server renderer may encode an opaque RGB PNG.
        page["compositeSHA256"] = put(self.a, flat.convert("RGB"))
        page["paperSHA256"] = page["compositeSHA256"]
        page["inkSHA256"] = put(self.a, Image.new("RGBA", flat.size))
        scene = encoded({"format": 1, "head": page["head"], "width": page["width"],
                         "height": page["height"], "objects": [old], "strokes": []})
        page["portableSHA256"] = hashlib.sha256(scene).hexdigest()
        self.a[page["portableSHA256"]] = scene
        self.c.update(rendererSignature="server-synced-preview-v1", nativeLayerUnavailable=True,
                      lastSyncedAt="2026-10-09T00:00:00Z", documentDigest="e"*64,
                      previewLabel="stale/native-layer-unavailable")
        return flat

    def test_stale_additions_use_flat_composite_without_redrawing_objects_or_ink(self):
        flat = self.stale_fixture()
        page = self.c["pages"][0]
        # Deliberately different aliases prove the composite is authoritative.
        page["paperSHA256"] = put(self.a, Image.new("RGBA", flat.size, "green"))
        page["inkSHA256"] = put(self.a, Image.new("RGBA", flat.size, "red"))
        reads = []
        def read(sha):
            reads.append(sha)
            return self.a[sha]
        self.renderer = Renderer(read)
        before = copy.deepcopy(self.c)
        out = self.render(draft(self.c, [obj(source="Additional answer", y=700)]))
        expected = flat.copy()
        for value in out["objects"]:
            expected.alpha_composite(image(out["assets"][value["asset"]["sha256"]]),
                                     (round(value["frame"]["x"]*2), round(value["frame"]["y"]*2)))
        self.assertEqual(image(out["previews"][page["pageID"]]).tobytes(), expected.tobytes())
        self.assertEqual(reads, [page["compositeSHA256"]])
        self.assertEqual(len(out["objects"]), 1)
        self.assertEqual(self.c, before)
        self.assertEqual(out["rendererSignature"], "draw-ai-render-v1")

    def test_stale_rejects_replacement_removal_and_all_stroke_edits_before_browser(self):
        self.stale_fixture()
        page = self.c["pages"][0]
        old = page["objects"][0]
        page["strokeTargets"] = [{"id": "s", "fingerprint": "0"*64, "index": 0}]
        with patch.object(Renderer, "_browser", side_effect=AssertionError("browser must not start")):
            for operation in ("replace", "remove"):
                d = draft(self.c)
                op = {"op": operation, "objectID": old["id"], "expectedRevision": old["revision"]}
                if operation == "replace":
                    op["object"] = {key: old[key] for key in ("id", "kind", "source", "frame", "style")}
                d["pageEdits"][0]["objectEdits"].append(op)
                self.error(d, "native_layer_unavailable")
            for operation in ("keep", "remove", "recolor"):
                stroke = {"id": "s", "fingerprint": "0"*64, "op": operation}
                if operation == "recolor":
                    stroke["color"] = "#5AC8FA"
                self.error(draft(self.c, strokes=[stroke]), "native_layer_unavailable")

    def test_stale_disclosure_and_metadata_are_strict(self):
        self.stale_fixture()
        before = copy.deepcopy(self.c)
        cases = [("nativeLayerUnavailable", None), ("nativeLayerUnavailable", 1),
                 ("nativeLayerUnavailable", False), ("previewLabel", "native"),
                 ("documentDigest", "bad"), ("lastSyncedAt", "2026-02-30T00:00:00Z"),
                 ("lastSyncedAt", "2026-10-09T00:00:00+00:00"), ("unexpected", True),
                 ("rendererSignature", "native-capture-v1")]
        with patch.object(Renderer, "_browser", side_effect=AssertionError("browser must not start")):
            for key, value in cases:
                self.c = {**before, key: value}
                self.error()
            for key in ("nativeLayerUnavailable", "previewLabel", "lastSyncedAt", "documentDigest"):
                self.c = copy.deepcopy(before)
                self.c.pop(key)
                self.error()
            self.c = copy.deepcopy(before)
            self.error(draft(self.c, [obj("latex", r"\href{https://evil.invalid}{x}")]))

    def test_optional_native_label_and_source_metadata_accepts_without_mutation(self):
        self.c.update(documentName="Несинхронизирана бележка", folderName="Алгебра", folderID=uid(),
                      sourceManifestSHA256="f"*64)
        before = copy.deepcopy(self.c)
        out = self.render()
        self.assertEqual(self.c, before)
        self.assertEqual(set(out["previews"]), {self.c["focusPageID"]})
        self.assertEqual(out["objects"][0]["provenance"]["contextSHA256"], "c"*64)
        # Home and omitted optional manifest remain supported without extra asset reads.
        self.c.update(documentName=None, folderName=None, folderID=None, sourceManifestSHA256=None)
        out = self.render()
        self.assertEqual(out["rendererSignature"], "draw-ai-render-v1")

    def test_optional_native_metadata_types_and_unknown_fields_rejected(self):
        before = copy.deepcopy(self.c)
        cases = [("documentName", {}), ("documentName", ""), ("folderName", "x\x00y"),
                 ("folderName", "x"*1025), ("folderID", "bad"), ("folderID", True),
                 ("sourceManifestSHA256", "BAD"), ("sourceManifestSHA256", 1),
                 ("capturedAt", "not UTC"), ("unrecognized", "value")]
        with patch.object(Renderer, "_browser", side_effect=AssertionError("browser must not start")):
            for key, value in cases:
                self.c = {**before, key: value}
                self.error()

    def guarded_draft(self):
        page = self.c["pages"][0]
        existing = copy.deepcopy(self.rendered["objects"][:2])
        for old in existing:
            old["revision"] = 2
            old["frame"]["x"] += 0.25
            old["style"].update(fontSize=14.0, lineWidth=1.0, color="#ab52de")
            old["asset"]["scale"] = 2.0
            old["provenance"]["contextSHA256"] = "e"*64
        page["objects"] = existing
        replacement = obj(source="Replacement from captured branch")
        replacement["id"] = existing[0]["id"]
        d = {"pageEdits": [{"pageID": page["pageID"], "objectEdits": [
            {"op": "replace", "objectID": existing[0]["id"], "expectedRevision": 2, "object": replacement},
            {"op": "remove", "objectID": existing[1]["id"], "expectedRevision": 2},
            {"op": "add", "object": obj(source="Additional note", y=500)}]}]}
        return existing, d

    def test_full_expected_object_guard_preserves_metadata_types_and_deep_copies(self):
        from notes_service.storage import encoded
        existing, d = self.guarded_draft()
        before = copy.deepcopy(self.c)
        out = self.render(d)
        operations = out["pageEdits"][0]["objectEdits"]
        self.assertEqual(out["objects"][0]["revision"], 3)
        for index, operation in enumerate(operations[:2]):
            expected = operation["expectedObject"]
            self.assertEqual(encoded(expected), encoded(existing[index]))
            self.assertIsNot(expected, existing[index])
            for key in ("frame", "style", "asset", "provenance"):
                self.assertIsNot(expected[key], existing[index][key])
            self.assertIs(type(expected["style"]["fontSize"]), float)
            self.assertIs(type(expected["asset"]["scale"]), float)
            # Undo may create a different object with the same ID/revision.
            divergent = copy.deepcopy(existing[index])
            divergent["source"] = "A divergent revision 2 on another branch"
            self.assertEqual((expected["id"], expected["revision"]), (divergent["id"], divergent["revision"]))
            self.assertNotEqual(expected, divergent)
        self.assertNotIn("expectedObject", operations[2])
        self.assertEqual(self.c, before)
        self.assertTrue(all("expectedObject" not in op for op in d["pageEdits"][0]["objectEdits"]))
        operations[0]["expectedObject"]["frame"]["x"] += 10
        operations[0]["expectedObject"]["provenance"]["contextSHA256"] = "f"*64
        self.assertEqual(self.c, before)

    def test_expected_guard_does_not_require_old_target_png_download(self):
        existing, d = self.guarded_draft()
        # Replaced/removed targets are absent from the amended visible scene.
        self.assertTrue(all(old["asset"]["sha256"] not in self.a for old in existing))
        reads = []
        def read(sha):
            reads.append(sha)
            return self.a[sha]
        self.renderer = Renderer(read)
        out = self.render(d)
        self.assertTrue(all(old["asset"]["sha256"] not in reads for old in existing))
        self.assertTrue(all(old["asset"]["sha256"] not in out["assets"] for old in existing))
        self.assertEqual(out["pageEdits"][0]["objectEdits"][1]["expectedObject"], existing[1])

    def test_drafts_cannot_supply_expected_object_on_any_operation(self):
        existing, d = self.guarded_draft()
        with patch.object(Renderer, "_browser", side_effect=AssertionError("browser must not start")):
            for index in range(3):
                forged = copy.deepcopy(d)
                forged["pageEdits"][0]["objectEdits"][index]["expectedObject"] = existing[0]
                self.error(forged)

    def test_manager_expected_guard_validation_preserves_full_captured_metadata(self):
        from notes_service.manager import Manager
        from notes_service.storage import Problem, encoded
        existing, d = self.guarded_draft()
        with tempfile.TemporaryDirectory(prefix="draw-object-guard-integration-", dir=Path.home()/"tmp") as folder:
            manager = Manager(folder, None)
            try:
                context_sha = manager.store.put_bytes(encoded(self.c))
                request_id = uid()
                out = self.renderer.render(self.c, d, request_id, context_sha)
                for sha, data in out["assets"].items():
                    manager.store.put_asset(sha, data)
                r = {"draft": d, "contextSHA256": context_sha, "requestID": request_id}
                # No old target PNGs are in this CAS; metadata-only guards still validate.
                manager.validate_rendered(r, out)
                malformed = []
                for index in (0,1):
                    altered = copy.deepcopy(out)
                    altered["pageEdits"][0]["objectEdits"][index].pop("expectedObject")
                    malformed.append(altered)
                    for key, value in [("source", "Divergent revision 2"), ("kind", "circle")]:
                        altered = copy.deepcopy(out)
                        altered["pageEdits"][0]["objectEdits"][index]["expectedObject"][key] = value
                        malformed.append(altered)
                    altered = copy.deepcopy(out)
                    # Python == treats 2.0 == 2, but the capture's JSON type must be preserved.
                    altered["pageEdits"][0]["objectEdits"][index]["expectedObject"]["asset"]["scale"] = 2
                    malformed.append(altered)
                    altered = copy.deepcopy(out)
                    altered["pageEdits"][0]["objectEdits"][index]["expectedObject"]["provenance"]["requestID"] = uid()
                    malformed.append(altered)
                    altered = copy.deepcopy(out)
                    altered["pageEdits"][0]["objectEdits"][index]["unexpected"] = True
                    malformed.append(altered)
                altered = copy.deepcopy(out)
                altered["pageEdits"][0]["objectEdits"][2]["expectedObject"] = existing[0]
                malformed.append(altered)
                for case, altered in enumerate(malformed):
                    with self.subTest(case=case):
                        with self.assertRaises(Problem) as caught:
                            manager.validate_rendered(r, altered)
                        self.assertEqual(caught.exception.code, "renderer_invalid")
            finally:
                manager.close()

    def test_stale_native_layer_unavailable_is_explicit_failure(self):
        self.c["rendererSignature"] = "server-stale-v1"
        self.error()


class RendererEditOnlyTests(unittest.TestCase):
    def setUp(self):
        self.assets, self.ctx = fixture(100, 100)
        self.ctx["rendererSignature"] = "native-capture-v2"
        self.page = self.ctx["pages"][0]
        # Alpha varies within the tile; transparent holes must move without filling.
        self.tile = Image.new("RGBA", (12, 10))
        self.tile.putpixel((1, 2), (35, 85, 175, 73))
        self.tile.putpixel((6, 5), (175, 82, 222, 200))
        sha = put(self.assets, self.tile)
        self.target = {"id": "native", "fingerprint": "0"*64, "index": 0,
                       "frame": {"x": 10, "y": 20, "width": 6, "height": 5},
                       "asset": {"sha256": sha, "pixelWidth": 12, "pixelHeight": 10, "scale": 2}}
        self.page["strokeTargets"] = [self.target]
        ink = Image.new("RGBA", (200, 200))
        ink.alpha_composite(self.tile, (20, 40))
        self.page["inkSHA256"] = put(self.assets, ink)
        self.renderer = Renderer(self.assets.__getitem__)

    def edit(self, op="move", **extra):
        operation = {"id": "native", "fingerprint": "0"*64, "op": op, **extra}
        return {"pageEdits": [{"pageID": self.page["pageID"], "objectEdits": [], "strokeEdits": [operation]}]}

    def render(self, value):
        # Edit-only passes must not launch Chromium to render an empty task list.
        with patch.object(Renderer, "_browser", side_effect=AssertionError("unexpected browser")):
            return self.renderer.render(self.ctx, value, uid(), "c"*64)

    def test_move_preview_matches_translated_native_tile_and_alpha_oracle(self):
        for dx, dy in [(8.5, -12), (-13, -22), (4096, -4096), (0, 0)]:
            with self.subTest(dx=dx, dy=dy):
                value = self.edit(dx=dx, dy=dy)
                before = copy.deepcopy((self.ctx, value, self.assets))
                out = self.render(value)
                expected = image(self.assets[self.page["paperSHA256"]])
                expected.alpha_composite(self.tile, (round((10+dx)*2), round((20+dy)*2)))
                self.assertEqual(image(out["previews"][self.page["pageID"]]).tobytes(), expected.tobytes())
                self.assertEqual(out["pageEdits"], value["pageEdits"])
                self.assertEqual(out["objects"], [])
                self.assertEqual(out["assets"], {})
                self.assertEqual((self.ctx, value, self.assets), before)

    def test_fractional_deltas_are_snapped_once_and_output_binds_the_pixel_preview(self):
        from notes_service import validation as check
        for dx, dy in [(0.24, -0.24), (0.26, -0.26), (1.24, -1.26), (0.25, 0.75)]:
            value = self.edit(dx=dx, dy=dy)
            before = copy.deepcopy(value)
            out = self.render(value)
            op = out["pageEdits"][0]["strokeEdits"][0]
            expected_op = {**before["pageEdits"][0]["strokeEdits"][0], "dx": round(dx*2)/2, "dy": round(dy*2)/2}
            self.assertEqual(op, expected_op)
            self.assertEqual(out["pageEdits"][0]["strokeEdits"], check.canonical_stroke_edits(before["pageEdits"][0]["strokeEdits"]))
            expected = image(self.assets[self.page["paperSHA256"]])
            expected.alpha_composite(self.tile, (round((10+op["dx"])*2), round((20+op["dy"])*2)))
            self.assertEqual(image(out["previews"][self.page["pageID"]]).tobytes(), expected.tobytes())
            self.assertEqual(value, before)

    def test_fractional_zero_move_uses_authoritative_whole_ink(self):
        self.page["inkSHA256"] = put(self.assets, Image.new("RGBA", (200, 200), (10, 20, 30, 99)))
        out = self.render(self.edit(dx=0.24, dy=-0.24))
        self.assertEqual((out["pageEdits"][0]["strokeEdits"][0]["dx"], out["pageEdits"][0]["strokeEdits"][0]["dy"]), (0, 0))
        expected = image(self.assets[self.page["paperSHA256"]])
        expected.alpha_composite(image(self.assets[self.page["inkSHA256"]]))
        self.assertEqual(image(out["previews"][self.page["pageID"]]).tobytes(), expected.tobytes())

    def test_full_offpage_tile_can_move_into_view_without_clipping_the_tile(self):
        self.target["frame"].update(x=-5, y=-4)
        out = self.render(self.edit(dx=10, dy=10))
        expected = image(self.assets[self.page["paperSHA256"]])
        expected.alpha_composite(self.tile, (10, 12))
        self.assertEqual(image(out["previews"][self.page["pageID"]]).tobytes(), expected.tobytes())

    def test_v1_move_requires_recapture_but_legacy_remove_recolor_remain_valid(self):
        from notes_service import validation as check
        from notes_service.storage import Problem
        self.ctx["rendererSignature"] = "native-capture-v1"
        for delta in ({"dx": 10, "dy": 10}, {"dx": 0, "dy": 0}):
            value = self.edit(**delta)
            with self.assertRaises(RendererError) as error: self.render(value)
            self.assertEqual(error.exception.code, "recapture_required")
            with self.assertRaises(Problem) as error: check.draft(value, self.ctx)
            self.assertEqual(error.exception.code, "recapture_required")
        for op, extra in [("remove", {}), ("recolor", {"color": "#007AFF"})]:
            value = self.edit(op, **extra)
            check.draft(value, self.ctx)
            self.render(value)

    def test_v2_move_reveals_negative_y_part_that_old_page_crop_omitted(self):
        self.target["frame"].update(x=10, y=-4)
        self.target["asset"].update(pixelHeight=10)
        original = image(self.assets[self.page["paperSHA256"]])
        clipped = Image.new("RGBA", original.size)
        clipped.alpha_composite(self.tile, (20, -8))
        self.page["inkSHA256"] = put(self.assets, clipped)
        before = copy.deepcopy(self.ctx)
        out = self.render(self.edit(dx=0, dy=10))
        expected = original.copy()
        expected.alpha_composite(self.tile, (20, 12))
        actual = image(out["previews"][self.page["pageID"]])
        self.assertEqual(actual.tobytes(), expected.tobytes())
        self.assertNotEqual(actual.getpixel((21, 14)), original.getpixel((21, 14)))
        self.assertEqual(clipped.getchannel("A").getbbox(), None)
        self.assertEqual(self.ctx, before)

    def test_edit_only_remove_and_recolor_are_valid(self):
        for op, extra in [("remove", {}), ("recolor", {"color": "#007AFF"})]:
            out = self.render(self.edit(op, **extra))
            expected = image(self.assets[self.page["paperSHA256"]])
            if op == "recolor":
                tinted = Image.new("RGBA", self.tile.size, "#007AFF")
                tinted.putalpha(self.tile.getchannel("A"))
                expected.alpha_composite(tinted, (20, 40))
            self.assertEqual(image(out["previews"][self.page["pageID"]]).tobytes(), expected.tobytes())

    def test_object_remove_only_uses_authoritative_whole_ink_even_with_keep(self):
        # No download of the removed object's PNG is needed.
        old = {"id": uid(), "revision": 1, "kind": "text", "source": "Old",
               "frame": {"x": 1, "y": 1, "width": 2, "height": 2}, "style": {},
               "asset": {"sha256": "a"*64, "pixelWidth": 4, "pixelHeight": 4, "scale": 2},
               "provenance": {}}
        self.page["objects"] = [old]
        # Deliberately diverge the grouped whole layer from the individual tile.
        self.page["inkSHA256"] = put(self.assets, Image.new("RGBA", (200, 200), (10, 20, 30, 99)))
        value = self.edit("keep")
        value["pageEdits"][0]["objectEdits"] = [{"op": "remove", "objectID": old["id"], "expectedRevision": 1}]
        out = self.render(value)
        expected = image(self.assets[self.page["paperSHA256"]])
        expected.alpha_composite(image(self.assets[self.page["inkSHA256"]]))
        self.assertEqual(image(out["previews"][self.page["pageID"]]).tobytes(), expected.tobytes())
        self.assertEqual(out["pageEdits"][0]["objectEdits"][0]["expectedObject"], old)

    def test_strict_move_tuple_and_legacy_operation_fields_in_both_validators(self):
        from notes_service import validation as check
        from notes_service.storage import Problem
        invalid = []
        for key in ("dx", "dy"):
            for v in (None, True, "1", float("nan"), float("inf"), -4096.1, 4096.1):
                invalid.append(self.edit(dx=1, dy=2))
                invalid[-1]["pageEdits"][0]["strokeEdits"][0][key] = v
            missing = self.edit(dx=1, dy=2)
            missing["pageEdits"][0]["strokeEdits"][0].pop(key)
            invalid.append(missing)
        invalid.extend([self.edit(dx=1, dy=2, color="#007AFF"), self.edit(dx=1, dy=2, extra=0),
                        self.edit("keep", dx=0), self.edit("remove", color=None),
                        self.edit("recolor", color="#007AFF", dy=1), self.edit("recolor")])
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(RendererError): self.render(value)
                with self.assertRaises(Problem): check.draft(value, self.ctx)
        for op, extra in [("move", {"dx": -4096, "dy": 4096}), ("remove", {}), ("recolor", {"color": "#007AFF"})]:
            check.draft(self.edit(op, **extra), self.ctx)

    def test_empty_and_keep_only_fail_structural_minimum(self):
        from notes_service import validation as check
        from notes_service.storage import Problem
        for value in ({}, {"pageEdits": []}, self.edit("keep"),
                      {"pageEdits": [{"pageID": self.page["pageID"], "objectEdits": [], "strokeEdits": []}]}):
            with self.assertRaises(RendererError): self.render(value)
            with self.assertRaises(Problem): check.draft(value, self.ctx)


class RendererLongTextMoveTests(unittest.TestCase):
    def test_six_kib_multiline_captured_text_moves_without_reflow_or_asset_change(self):
        assets, ctx = fixture(1024, 2000)
        source = ("The original multiline sentence must retain its exact pixels and line breaks. " + "abcdefghij "*3 + "\n")*60
        self.assertGreater(len(source), 6000)
        renderer = Renderer(assets.__getitem__)
        first = renderer.render(ctx, draft(ctx, [obj(source=source, x=10, y=10, width=950, height=1850)]), uid(), "c"*64)
        old = first["objects"][0]
        assets.update(first["assets"])
        ctx["pages"][0]["objects"] = [old]
        moved = {key: copy.deepcopy(old[key]) for key in ("id", "kind", "source", "frame", "style")}
        moved["frame"].update(x=10.26, y=20.24)
        value = {"pageEdits": [{"pageID": ctx["focusPageID"], "objectEdits": [
            {"op": "replace", "objectID": old["id"], "expectedRevision": 1, "object": moved}]}]}
        with patch.object(Renderer, "_browser", side_effect=AssertionError("no 6 KiB text reflow")):
            out = renderer.render(ctx, value, uid(), "d"*64)
        resolved = out["objects"][0]
        self.assertEqual(resolved["source"], source)
        self.assertEqual(resolved["asset"], old["asset"])
        self.assertEqual(out["assets"][old["asset"]["sha256"]], first["assets"][old["asset"]["sha256"]])
        self.assertEqual(resolved["frame"], {**old["frame"], "x": 10.5, "y": 20.0})


class RendererManagerStaleConfirmTests(unittest.IsolatedAsyncioTestCase):
    async def test_explicit_stale_confirm_real_source_renderer_and_approval(self):
        from notes_service.manager import Manager
        from notes_service.source import SyncSource
        from notes_service.storage import encoded, decoded
        from notes_service.tests.test_source import HTTP

        with tempfile.TemporaryDirectory(prefix="draw-stale-render-integration-", dir=Path.home()/"tmp") as folder:
            root = Path(folder)
            assets, ctx = fixture()
            doc, page = ctx["documentID"], ctx["pages"][0]
            pid, rid = page["pageID"], uid()
            # A partially transparent old object makes accidental double painting visible.
            layer = Image.new("RGBA", (40,40), (30,90,160,100))
            old_sha = put(assets, layer)
            old = {"id": uid(), "revision": 1, "kind": "text", "source": "Existing",
                   "frame": {"x": 20, "y": 20, "width": 20, "height": 20},
                   "style": {"fontSize": 14, "color": "#000000", "lineWidth": 1},
                   "asset": {"sha256": old_sha, "pixelWidth": 40, "pixelHeight": 40, "scale": 2},
                   "provenance": {"requestID": uid(), "contextSHA256": "d"*64,
                                  "rendererSignature": "draw-ai-render-v1"}}
            flat = image(assets[page["paperSHA256"]])
            flat.alpha_composite(layer, (40,40))
            flat.alpha_composite(image(assets[page["inkSHA256"]]))
            # Legacy portable source intentionally has no actual-paper field.
            scene = encoded({"format": 1, "head": page["head"], "width": page["width"],
                             "height": page["height"], "objects": [old], "strokes": []})
            scene_sha = hashlib.sha256(scene).hexdigest()
            state = {"revision": 4, "documentDigest": "e"*64, "lastSyncedAt": "2026-10-09T00:00:00Z",
                     "manifest": {"format": 2, "notebooks": [{"id": doc, "name": "Fixture",
                        "orientation": "portrait", "pages": [{"id": pid, "head": page["head"], "nodes": []}]}],
                        "assets": {old_sha: old_sha}, "blobs": {}}}
            http = HTTP({"/v2/documents/"+doc+"/state": state,
                         "/v2/documents/"+doc+"/scenes": {"revision": 4, "scenes": {doc+"/"+pid: scene_sha}},
                         "/v2/objects/"+scene_sha: scene, "/v2/objects/"+old_sha: assets[old_sha],
                         "/v1/documents/"+doc+"/pages/"+pid+".png?revision=4": png(flat.convert("RGB"))})
            source = SyncSource(http, "synthetic-local-test-token")
            now = [1000.0]
            manager = Manager(root/"state", None, source, workspace=root/"workspace", clock=lambda: now[0])
            manager.renderer = Renderer(manager.store.read_asset)
            try:
                initial = await manager.terminal_request(doc, {"requestID": rid, "prompt": "Add a short answer", "focusPageID": pid})
                self.assertEqual(initial["status"], "awaiting_sync")
                self.assertNotIn("contextSHA256", manager.store.request(rid))
                now[0] += 11
                pending = await manager.terminal_status(manager.store.request(rid))
                self.assertEqual(pending["status"], "needs_stale_choice")
                confirmed = await manager.stale_choice(rid, {"choice": "use_synced"})
                self.assertEqual(confirmed["status"], "queued")
                pinned = manager.context(manager.store.request(rid))
                self.assertTrue(pinned["nativeLayerUnavailable"])
                self.assertEqual(pinned["rendererSignature"], "server-synced-preview-v1")
                self.assertEqual(pinned["previewLabel"], "stale/native-layer-unavailable")
                worker = manager.worker_registry.get(doc)
                worker = manager.worker_registry.register({"documentID": doc, "sessionID": worker["sessionID"],
                    "sessionFile": str(root/"session.jsonl"), "cwd": worker["cwd"], "spawnNonce": worker["spawnNonce"],
                    "busy": False, "pending": False, "inputObserved": True})
                lease = worker["lease"]
                d = draft(pinned, [obj(source="New answer", y=600)])
                added_page = uid()
                d["insertPages"] = [{"pageID": added_page, "afterPageID": pid, "background": 3, "width": 1024, "height": 1361}]
                d["pageEdits"].append({"pageID": added_page, "objectEdits": [{"op": "add", "object": obj(source="Continued")}]})
                await manager.draft(rid, {"expectedDraftVersion": 0, "pageEdits": d["pageEdits"], "insertPages": d["insertPages"]}, doc, lease)
                rendered = await manager.render(rid, {"draftVersion": 1}, doc, lease)
                self.assertEqual(rendered["warning"], "stale/native-layer-unavailable; synced server preview")
                self.assertEqual(len(rendered["objects"]), 2)
                previews = {p["pageID"]: p for p in rendered["previews"]}
                expected = flat.copy()
                added = rendered["objects"][0]
                expected.alpha_composite(image(manager.store.read_asset(added["asset"]["sha256"])),
                                         (round(added["frame"]["x"]*2), round(added["frame"]["y"]*2)))
                self.assertEqual(image(manager.store.read_asset(previews[pid]["sha256"])).tobytes(), expected.tobytes())
                new_paper = image(manager.store.read_asset(previews[added_page]["sha256"]))
                self.assertEqual(new_paper.size, (2048,2722))
                self.assertEqual(new_paper.getpixel((72,500)), (224,224,224,255))
                approved = await manager.approve(rid, {"draftVersion": 1, "renderID": rendered["renderID"],
                    "inspectedPreviewSHA256s": [p["sha256"] for p in rendered["previews"]]}, doc, lease)
                self.assertEqual(approved["status"], "ready")
                result = decoded(manager.store.read_asset(approved["resultSHA256"]))
                self.assertEqual(result["contextSHA256"], manager.store.request(rid)["contextSHA256"])
                self.assertEqual(result["rendererSignature"], "draw-ai-render-v1")
                self.assertTrue(all(op["op"] == "add" for e in result["pageEdits"] for op in e["objectEdits"]))
                self.assertTrue(all(not e["strokeEdits"] for e in result["pageEdits"]))
                self.assertEqual(manager.context(manager.store.request(rid)), pinned)
            finally:
                manager.close()


if __name__ == "__main__":
    unittest.main()
