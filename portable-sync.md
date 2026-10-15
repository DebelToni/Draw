# Portable page rendering and incremental Sync

Approved scope: portable stroke export/import, DGX-generated agent PNGs and compressed incremental transfer. PencilKit remains the on-device renderer. Native `.pkdraw` archives and existing IDs/directories remain authoritative. Local history retention was subsequently changed to the two-window policy in [local-undo.md](local-undo.md); network packages and backups contain current heads only. No AI implementation or background mobile Sync.

## Portable page v1

UTF-8 JSON, emitted with Swift sorted keys and without escaped slashes. SHA-256 identifies the exact JSON bytes; the server must not reserialize before verifying that digest.

Page fields: `format: 1`, optional `head` UUID, logical `width`, logical `height`, `strokes` in drawing order. Width/height include current ink extent and are bounded to 4096 logical points. Agent output remains 2× ink on ruled white paper, with 36 pt spacing, independent of the app's actual paper setting.

Stroke fields:

- Optional `id` and `pathID` UUIDs (public on iOS 27).
- `inkType` native string and `color: [r,g,b,a]` resolved sRGB components.
- `transform: [a,b,c,d,tx,ty]`, `randomSeed`, optional `renderGroupID`, optional `grainOffset: [x,y]`.
- `creationDate` seconds since Unix epoch.
- `points`: original control points for reconstruction.
- `samples`: native interpolated points for portable rendering; no need to reverse-engineer Apple's private spline representation.
- Optional `mask: {commands, evenOdd}`. Commands are `[0,x,y]` move, `[1,x,y]` line, `[2,cx,cy,x,y]` quadratic, `[3,c1x,c1y,c2x,c2y,x,y]` cubic, `[4]` close. Mask coordinates are preserved, not flattened.

Each point/sample is `[x,y,timeOffset,width,height,opacity,force,azimuth,altitude,secondaryScale,threshold,lateralJitter]`. Point opacity is a **0–2 brush multiplier**, not compositing alpha; color alpha and the 0–1 threshold are independent. Time, force and secondary scale are nonnegative. Version-available properties are guarded. The original controls, not the sampled curve, reconstruct `PKStrokePath`. Empty pages are valid. Portable reconstruction does not replace the recovery archives.

DGX uses direct Cairo for affine transforms, even-odd/winding clipping, stroke order and variable elliptical footprints. Current app pen/monoline and marker ink are supported; unknown ink fails explicitly instead of silently disappearing. Renderer version 2 adds `missed` metadata for exact muddy-teal RGBA `(23/255,127/255,113/255,1)` alongside purple `question`. It changes no geometry; the version bump prevents reusing pre-tag metadata. Fresh-identity iOS 27 native sweeps established pen diameter `max(0, 2 * (pointSize - 2))`; tool widths 0.5/4/12 pt produce archived sizes 2.25/4/8.

Marker rendering is a calibrated procedural chisel/soft-edge approximation. Native grain, render-group overlap rules and anisotropic transformed blur are not replicated. Pen opacity variation uses a linear-gradient approximation; threshold, secondary scale and lateral jitter are retained for native reconstruction but not fully modeled in DGX previews. Editable native ink is unaffected. Pixel identity across renderers is not promised.

Independent native archive decodes and repeated Store exports must produce exact scene bytes/digests. JSON controls remain exact; native reconstruction can re-quantize mask coordinates by 0.01 pt and force by 0.001. Tests allow those differences only in the relevant post-native fields, with unchanged raster checks.

## Incremental protocol v2

Same bearer authentication and private origin. Legacy v1 remains readable and writable. Source package format and source digests do not change; reconciliation and existing baselines remain compatible.

- `GET /v2/state` → `{revision, manifest}`; `manifest` is null when empty, otherwise the existing source package with `blobs` mapping snapshot keys to lowercase SHA-256 hex digests instead of base64 bytes. No drawing bodies are returned.
- `POST /v2/objects/missing` with `{digests: [...]}` → `{missing: [...]}`.
- `GET /v2/objects/SHA256` → original object bytes, gzip response when accepted.
- `POST /v2/objects/SHA256` → raw object bytes, optionally `Content-Encoding: gzip`; verify SHA-256 and nonempty/bounded decoded body before storing. Receipt `{digest}`. Objects may be native archives or portable JSON; uploading an object does not publish a revision.
- `POST /v2/state` with `{baseRevision, manifest, scenes: {BOOK/PAGE: SHA256}}` → `{revision}`. Require exact all-page scene keys, matching page heads and valid portable data. Resolve source blobs and scenes from verified stored objects. Render affected page PNGs before the note/image/scene transaction publishes. Reuse unchanged scene renders, retain every source revision and stop divergent writes.

Both requests and responses can use gzip. Bound compressed and decoded bodies; reject unsupported encodings and malformed/truncated streams. Metadata is limited to 4 MiB; each object's compressed and decoded body is limited to 128 MiB rather than imposing a whole-library wire limit. URLSession may retain a gzip header after automatic decoding, so object SHA identity is checked before attempting secondary gzip decompression.

The client reuses locally held snapshot bytes by hash on download, uploads only server-missing objects and never includes PNGs in a v2 upload. The server stores portable scene references alongside derived images and includes their exact JSON bytes in private data backups. Backup export reads source, scene and image objects through one SQLite snapshot. A v1-uploaded PNG cannot claim portable renderer-cache provenance. Failed renders, missing objects or conflicts must leave the published library and image cache unchanged. Transient uploads survive failure with a 24-hour expiry. Confirmed publication removes obsolete current-state objects and revisions, protecting current references.

## Validation and deployment gates

- Control-point/color/transform/mask/seed round-trip tests and native image comparisons.
- Real synced page comparisons and synthetic minimum/maximum pen widths, marker overlaps, masks and transformed strokes.
- Empty/retry/conflict/corrupt-object/gzip/legacy/baseline/backup tests.
- Repeated unchanged Sync transfers no native object bodies; a changed drawing sends only new archive/scene objects.
- Online SQLite recovery copy before additive production schema changes, no pruning or source replacement. Retrieve Mac build and validation outputs to DGX. Install only over the existing app when reachable.

## Measured scope (2026-10-06)

Revision 6 has 1,271 native history archives already in DGX CAS. The v2 state response is 484,863 bytes decoded and 131,061 bytes gzip, compared with the legacy 101,553,918-byte full-history JSON. Gzipping legacy reduces it to 60,299,666 bytes, but that large route still loses its connection from the Mac; the shipping client no longer uses it.

Ten current intro pages were exported and rendered against actual cached iPad PNGs. Mean channel error ranges 0.113–0.371 on a 0–255 scale. Bidirectional ink-mask coverage is 100% within two physical pixels at 2× scale, using a minimum-channel threshold below 180 to exclude gray ruling. This is geometry evidence for those pen pages, not universal brush fidelity.

Their portable scenes total 54,176,499 bytes raw and 10,652,506 bytes gzip. Portable JSON is not intrinsically smaller than native archives or PNGs. Savings come from object reuse: unchanged Sync sends no archive/scene bodies; an edit sends new native snapshots and the changed page's whole scene, not all history. Local whole-page snapshot growth and Home-Sync encoding costs remain.

The additive `scenes` table already existed with zero rows when rollout inspection ran, after the ordinary backup timer had loaded the updated checkout. A verified online SQLite recovery copy preceded the explicit server restart. All six source revisions/digests and 177 existing image references were unchanged; no production scenes were populated. DGX previews appear after manual Sync from the updated app. Private build evidence is under `~/.local/state/draw-sync/builds/portable-20261006/`. The update was subsequently installed over the existing app with renewed provisioning, after recovering all 2,832 local snapshots to DGX. The unsynced index and referenced snapshot sizes were preserved exactly. Recovery is `~/.local/state/draw-sync/device-recovery/portable-install-20261006/`; no automatic Sync was performed.

Earlier AI planning remains separate and unimplemented.
