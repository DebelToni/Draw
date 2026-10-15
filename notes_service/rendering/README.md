# Draw AI controlled renderer

## API handoff

```python
from notes_service.renderer import Renderer, RendererError
renderer = Renderer(read_asset)  # sync immutable SHA256 -> exact bytes callback
rendered = renderer.render(context, draft, requestID, contextSHA256)
```

The synchronous call returns `pageEdits`, `insertPages`, `objects`, `assets` (SHA256 → PNG bytes), `previews` (page UUID → PNG bytes), and `rendererSignature: "draw-ai-render-v1"`. Use a manager executor/thread so rendering does not block its event loop. Inputs are not mutated. State is per call; a Renderer can be shared. `RendererError.code`, `.message`, and `.as_dict()` provide source-free structured errors. The manager owns draft CAS, exact-byte context hash validation, persistence, all three-call accounting (including failures), approval, and result serialization.

Draft is `{draftVersion?, insertPages?, pageEdits?}` with frozen operation names. Draft object fields are `{id,kind,source,frame,style?}` only. Defaults: black, 14 point font, 1 point lines. Replacements retain ID and increment the captured revision. All UUIDs use uppercase canonical spelling. Dimensions and RGB colors are checked before invoking Chromium. Every affected page gets a preview. At least one visible generated answer is required; removal-only drafts fail. Inserted pages use the document's base portrait 1024×1361 or landscape 1361×1024 geometry and PaperView's 0 blank, 1 dots, 2 lines, 3 grid pattern, spaced 36 points.

Resolved result operations have a stricter shape than drafts:

- add: `{op,object}`, with no `expectedObject`.
- replace: `{op,objectID,expectedRevision,expectedObject,object}`.
- remove: `{op,objectID,expectedRevision,expectedObject}`.

`expectedObject` is a deep copy of the complete captured AIObject, preserving ID, revision, kind, source, frame, style, asset descriptor and provenance without normalization. Models cannot supply it in drafts. The manager must require exact captured metadata equality, reject unknown result-operation fields and bind this guard into approved result bytes. The native applier compares the latest full AIObject metadata before replacing/removing, so divergent Undo branches with the same ID/revision are skipped. The guard is metadata only: no old target PNG fetch, result asset reference or native source archive is required solely to compare it. Preview rendering loads only current visible layers and newly generated assets.

Assets are unprofiled sRGB RGBA PNG at exactly 2 pixels/point. Placement snaps once to the half-point grid. The returned frame already includes the alpha-tight crop offset. Native RGB/RGBA layers with valid embedded profiles are color-managed to sRGB, preserving alpha. Native captures need actual full-page paper and transparent ink layers. Composite order is paper → amended AI objects → native ink. Unchanged stroke previews use the full native ink layer. Any remove/recolor/move reconstructs every stroke in captured index order and requires complete `{id,fingerprint,index,frame,asset}` captures, including removed strokes. Recolor replaces RGB and preserves alpha footprint. Move uses complete native-capture-v2 stroke tiles, snaps dx/dy once to the half-point grid in the approved result, and shifts those pixels without clipping source geometry. V1 moves fail closed and require recapture. Position-only object replacements reuse exact captured PNGs and dimensions rather than re-typesetting tight-cropped text or shape sources. Explicit edit-only requests still require complete previews and exact approval. Native grouped-marker blending may differ from ordered individual PNG composition; this is not universal hardware pixel identity.

## Context metadata contract

The strict top-level schema permits optional `documentName`, `folderName`, `folderID` and `sourceManifestSHA256`. Omitted/null means absent. Present names are nonempty readable strings, at most 1024 UTF-8 bytes with no ASCII control characters. Present folder IDs are canonical uppercase UUIDs; manifest references are lowercase SHA256. These are inert metadata: no file/path interpretation, source-archive fetch or editable-source publication, and they do not replace the exact-byte `contextSHA256` provenance binding. The manager owns worker display-label sanitization and any stricter upstream source-reference policy.

There are two accepted context modes:

- `native-capture-v2`: separate native paper/ink layers plus full-stroke tiles, permitting safe previewed moves even when source geometry extends off-page. Allocation preflight preserves the existing axis/pixel/aggregate limits.
- `native-capture-v1`: legacy separate native paper/ink layers; remove/recolor remain compatible, while moves require fresh v2 capture. `nativeLayerUnavailable` is omitted or explicitly false. Stale disclosure fields are forbidden.
- `server-synced-preview-v1`: requires `nativeLayerUnavailable:true`, `previewLabel:"stale/native-layer-unavailable"`, lowercase `documentDigest`, and RFC3339 UTC `lastSyncedAt`. The manager's source adapter normally sets `paperSHA256 == compositeSHA256` to a pinned flattened server PNG and supplies empty ink. Renderer always uses `compositeSHA256` as the authoritative base, paints only newly added objects, and never redraws captured objects or ink. Replacement, removal and every nonempty `strokeEdits` array (including keep) fail with `native_layer_unavailable` before Chromium starts. New inserted pages still use ordinary declared paper geometry. All normal object-source/security/pixel limits apply.

Stale rendering is available only after the manager's explicit `use_synced` choice. Its read/render response preserves the disclosure and warns `stale/native-layer-unavailable; synced server preview`. Old legacy server images can contain reconstructed ruled paper rather than actual native paper/ink; these additions-only previews do not claim native-layer or hardware pixel equivalence. Final results remain bound to the disclosed pinned context, with the normal `draw-ai-render-v1` object-renderer signature. This signature does not claim a native capture.

TeX uses KaTeX with `trust:false`, strict errors and expansion/size bounds. Multiline math uses standard environments, e.g. `\begin{aligned} a &= b+c \\ c &= \frac{1}{2} \end{aligned}`. Write prose and math as separate objects for proofs. Text is literal `textContent`, including Cyrillic and newlines. Prose, KaTeX text spans and Mermaid labels use pinned Liberation Serif (Times-compatible, including Cyrillic), with regular/bold/italic/bolditalic faces. Necessary mathematical glyph fonts remain KaTeX's serif math faces. The KaTeX outer size is 1em, matching the declared font size rather than its stock 1.21em inflation; scripts still scale normally. Worker guidance and omitted-style defaults use 18-point body/formulas/remarks, with compact headings and no arbitrary wide page gutters; a one-pixel border gap is acceptable when content remains visible/readable. Existing immutable PNGs keep their appearance until explicitly re-rendered. Mermaid uses strict security, non-HTML labels and monochrome styling, not model-supplied themes, callbacks or directives. SVG output is checked for active elements/resources before capture. Diagram geometry is intrinsic, not shrunk to unreadably fit a placement box.

## Verified checks

`test_renderer.py` covers real owned Chromium rendering of all six kinds, Cyrillic, multiline math, alpha-tight crops, frame/provenance, exact stacking, scoped replacement/removal, native RGB/ICC capture, ordered alpha-preserving stroke edits, portrait/landscape paper geometry, source injection/limits, malformed finite inputs, missing/corrupt/oversized PNGs, runtime/memory cleanup, the manager's frozen resolved-output validator, optional label/manifest metadata validation, stale additions-only composition and disclosure rejection, and real renderer integration through `SyncSource` pinning, manager explicit stale confirmation, new-page rendering, warning and exact preview approval (synthetic transport, no HTTP service). Guard regressions additionally verify exact full metadata/type preservation, deep-copy isolation, same-revision divergent branch discrimination, draft guard injection rejection, add guard omission, and no old target PNG dependency. The manager integration regression requires rejection of missing/forged/extra result guards and unknown operation fields; this is an integration gate for the manager owner, not a renderer-side validator implementation. No live service, Mac data, app install or physical-device test was used.

## Dependencies and installation

Python dependency: Pillow (already in the project `.venv`). No Python Playwright, cairocffi or service installation is required. Node dependencies and the lockfile live here: KaTeX 0.19.0, Mermaid 12.1.0 (verified npm latest stable during implementation), Playwright 1.64.0, esbuild 0.28.2. Checked-in Liberation Serif 2.1.5 font bytes and license are in `fonts/`; KaTeX fonts come from the exact locked package.

```sh
cd /home/xaj/projects/Draw/notes_service/rendering
npm ci --ignore-scripts --no-audit --no-fund
npm run bundle
# If the pinned browser is missing, install without pruning other agents' cache:
PLAYWRIGHT_SKIP_BROWSER_GC=1 npx playwright install chromium
cd /home/xaj/projects/Draw
.venv/bin/python -m unittest notes_service.tests.test_renderer -v
```

Each pass owns a new process group and one Playwright Chromium browser, closed in `finally`. Only that group is terminated on errors. Browser page requests are blocked except exact allowlisted local bytes fulfilled in memory, including pinned fonts; there is no HTTP server or online browser request. CSP, service-worker blocking, WebSocket blocking and disabled background networking reinforce the boundary. Runtime is 30 seconds/pass; Node and Chromium V8 heaps are 256 MiB each and the owned process tree has a polled 1 GiB summed-RSS ceiling. Limits are 64 KiB/source, 128 object operations, 4 MiB metadata, 8192 pixels/axis, 32 million pixels/PNG, 128 MiB encoded bytes per PNG and unchanged wire-transfer bounds. Cumulative RGBA decoding work per render is capped at 4 GiB, including repeated decodes; this is not an RSS measurement. The larger work budget supports multi-page workbooks without shrinking typography, while the separate browser RSS/pixel/runtime limits remain in force. Temporary private render inputs and screenshots live only in `~/tmp/draw-render-*` and are removed on return. No private source is written to stdout/stderr.
