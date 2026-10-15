# AI source and document Sync API

Implementation reference, not deployment approval. Routes use the existing Bearer authentication and optionally `/draw-sync` prefix. UUIDs are uppercase; SHA256 values are lowercase hashes of exact decoded bytes. Source, scene and PNG uploads use the existing `/v2/objects` CAS routes.

## Document bridge

`GET /v2/documents/{documentID}/state`:

```json
{"revision":1,"manifest":{},"documentDigest":"sha256","lastSyncedAt":"UTC"}
```

The manifest contains only the requested notebook, its current live/deleted heads, native archive references, its required folder's full ancestor closure and referenced AI PNG assets, excluding child/unrelated folders. Ancestor records retain library order for legacy digest compatibility; the graph, not array ordering, defines the chain. An empty ancestor closure omits `folders`, including for Home documents alongside nested empty folders, preserving the legacy single-document digest shape. A nested document subset uses source format 3; a flat subset uses the original format 1/2 even when unrelated library folders are nested. An absent document returns null for manifest, digest and timestamp. The digest is opaque server authority over the canonical single-document wire manifest. Preserve it; do not reproduce it from Swift serialization. Existing normalized `preferredRoot` omission/presence and explicit empty object arrays are preserved. Readable historical sources are projected to heads for this bridge, without publishing a migration.

`POST /v2/documents/{documentID}/state`:

```json
{"syncID":"UUID","baseDocumentDigest":null,"manifest":{},"scenes":{"BOOK/PAGE":"sha256"}}
```

`baseDocumentDigest` is required, including explicit null when creating a document whose UUID does not exist remotely. Require exactly that notebook, all live/deleted page scenes and exactly its required folder ancestry/asset metadata. Folder IDs must be unique, every parent must be included, and the chain must be acyclic; missing ancestors, duplicate IDs, children and unrelated folders are rejected. A missing baseline never authorizes overwriting an existing UUID. Under one immediate transaction, recheck the digest, merge with the latest whole library, preserve unrelated native/scene/image/asset references and empty folders, then publish source, composites, GC, timestamp and receipt. Conflicting existing folder/ancestor metadata (including name or parent) returns 409 instead of renaming or moving shared folders. Missing and null root `parentID` are semantically equivalent when checking this conflict; source encodings otherwise remain untouched. Whole-library folder changes also change affected document digests, invalidating stale baselines. This route cannot delete documents.

Response and durable `GET /v2/sync-receipts/{syncID}` result:

```json
{"revision":1,"documentDigest":"sha256","lastSyncedAt":"UTC","syncID":"UUID","documentID":"UUID"}
```

The additive `documentID` binds terminal bridge receipts to their document. Same ID and canonical request returns the original receipt, even after later publications or asset GC. Reusing an ID for different content or another route conflicts. Unchanged successful confirmation refreshes `lastSyncedAt` without increasing the source revision; receipt replay does not refresh it. Failed operations update neither timestamp nor receipt.

`GET /v2/documents/{documentID}/scenes` returns `{revision, scenes}` with document-only `BOOK/PAGE → SHA256` references. Scene bytes remain retrievable through CAS. These current-only reads are individually snapshot-coherent; callers pin/recheck revision and digest while collecting multiple artifacts because later publication may prune old CAS objects.

New routes return `{error:{code,message}}`: 401 authentication, 404 unknown receipt/route, 409 conflict, 413 body limit, 422 invalid source/scene/assets, 503 storage/renderer failure. Legacy routes retain their existing error shapes.

## Home confirmation

`POST /v2/state` additionally accepts optional `syncID`. Without it the response remains `{revision}`. With it the durable receipt is `{revision,syncID,lastSyncedAt,documents}`, where `documents` maps confirmed notebook UUIDs to opaque document digests. Every notebook in this complete, validated Home publication is confirmed. Document-only publications stamp just their target. `/v1/documents` metadata summaries expose `lastSyncedAt`; unknown legacy freshness is null rather than a revision creation date.

The server does not solve local baseline reconciliation. A Home client must merge against fetched remote state before CAS publication, preserve remote-only documents, and rotate Undo only after confirmation. Local package digests and opaque server document digests are separate authorities.

## Source and rendering

- Any nested folder (`parentID` non-null) requires source format 3. Flat sources use the original format 1 without AI, or format 2 with AI; existing flat wire bytes/digests never acquire parent defaults. Formats 1/2 reject nested records, and older readers limited to 1/2 reject format 3. Package `assets` maps SHA256 to base64 raw PNG; wire manifest `assets` maps each SHA256 to itself. With AI in format 2/3, keys must exactly equal current live/deleted references. Nested-only format 3 omits `assets` (an explicit empty map is also accepted and preserved in backup), and never downgrades to format 2 merely because the tree is nested. Format 3 can remain readable after a tree becomes flat; generated flat projections use format 1/2.
- Folder records add optional uppercase UUID `parentID`, absent/null for root. Unique IDs, known parent references and cycle-free ancestry are validated before source object reads/publication. Document merges preserve all existing folders, including empty branches, and add only missing ancestor records; complete folder moves/deletions are whole-library publications. The app reparents deleted folders' direct documents and child folders to their containing parent, preserving deeper descendants and all retained IDs.
- `HistoryNode.objects` is optional. Missing and explicit empty arrays both mean no objects, but retain their distinct source encodings. Objects use the frozen AIObject fields, source kinds, descriptors and provenance; no old Undo graph is accepted remotely. The supported kinds include `highlight`: an ordinary immutable transparent PNG with cyan default and source geometry `{\"opacity\":0.2}`. It needs an updated native reader, not a new source format or human pen-palette entry.
- All referenced assets are hash-checked, dimension-checked, structurally validated and fully decoded before publication, including cached scenes. PNGs are noninterlaced RGBA8, at 2 pixels/point, at most 8192 pixels/side and 32,000,000 pixels. Transfer limits remain 128 MiB/object and 4 MiB/request metadata. ICC color overrides and animated PNGs are rejected.
- Portable v1 scenes optionally contain `background` (0 blank, 1 dots, 2 lines, 3 grid) and ordered `objects`. Objects must equal the current source head; explicit background must equal page metadata. Cairo composites paper, immutable object PNGs, then portable native ink. Absent background retains the existing ruled-white rendering byte-for-byte. This renderer approximates native brushes; it does not claim native pixel identity.
- Renderer version 3 emits only `question`, classifying exact old teal and purple as that tag without recoloring pixels. Legacy `missed` image metadata remains readable/restorable; version-3 generated metadata rejects it. Existing source/scene hashes are not rewritten just to refresh tags.
- Current-only GC protects source native archives, AI assets, scenes and composites, plus unexpired staged uploads. Receipts survive source pruning. Backup exports object specifications, native archives, exact scenes, asset PNGs and current composites through one database snapshot; restoration reconstructs the original format 1/2/3 and validates the folder graph. Git publication remains a single parentless root against its existing lease. AI apply/Undo receipts are not source backup data.

## Python integration

`server.ai_models` exports `validate_object`, `validate_objects`, `validate_frame`, `validate_asset_descriptor`, `validate_asset`, `validate_png`, `current_objects`, `referenced_assets`, and `validate_source_assets`. Validation raises `ValueError`; no rendering/worker side effects. `validate_asset(data, descriptor)` returns verified bytes; `validate_png(data, width=None, height=None, rgba=True)` returns pixel dimensions.

`server.portable.render_page(scene, assets=None)` takes SHA256 → raw PNG bytes and returns metadata plus composite PNG. The notes renderer remains a separate component; captured stroke targets `{id,fingerprint,index,frame,asset}` and native-layer preview edits belong there, not to Sync source revisions.

`server.client.ManagerClient(origin, token)` supplies read-only `document_state`, `document_scene_refs` (alias `docScenerefs`), `object_bytes` (alias `objectBytes`), `document_metadata`, and `sync_receipt`. Object reads verify exact SHA256 and bound transport decompression. These helpers never create note workers.

## Isolated verification

```sh
.venv/bin/python -m unittest discover -s server -q
```

All fixtures use temporary databases, generated images, loopback servers and local disposable Git remotes. No production or Mac commands are needed.
