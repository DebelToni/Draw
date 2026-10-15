# Draw manual sync

This is the maintained server/agent-access reference. Update route shapes, CLI examples, metadata meaning and retrieval limitations here alongside implementation changes; do not leave workers dependent on session-memory descriptions. The note-worker lifecycle is [notes-agents.md](../notes-agents.md); the separate assistance API and foreground bridge are described in [notes_service/README.md](../notes_service/README.md). Deployment evidence belongs in the current build record, not this interface reference.

Private origin: `https://draw.example.invalid/draw-sync`. Current app Sync uses `/v2/state` plus content-addressed objects; legacy `/v1/state` remains available.

The user service `draw-sync.service` listens on **127.0.0.1:18874**. Tailscale Serve adds only `/draw-sync` to the existing private HTTPS listener. No Funnel, public ingress, automatic mobile sync, persistent connection or periodic polling.

## Protocol and recovery

Bearer-authenticated v2 GET returns `{revision, manifest}` with snapshot SHA references, not archive bodies. The client reuses matching local archives and downloads only missing objects. Upload asks `/v2/objects/missing`, sends only missing gzip-compressed native archives/portable scenes, then commits `{baseRevision, manifest, scenes}`. V2 uploads contain no PNGs. The server renders changed scene PNGs before one SQLite `BEGIN IMMEDIATE`, `synchronous=FULL` publication of source/image/scene references. It retains only the latest source revision and its current page objects. Revision numbers remain monotonic. Conflicts return 409; identical retries are safe. Exact wire fields, limits, fidelity and measurements: [portable-sync.md](../portable-sync.md).

Legacy v1 GET returns `{revision, package}`; POST accepts `{baseRevision, package, images?}`. Its package contains only live/deleted current heads as base64 and optional client PNGs. Format 2 adds referenced immutable AI PNG assets and current object specifications. Format 3 is required for nested folders, with the same optional AI content; readers limited to formats 1/2 must reject it rather than silently flattening the tree. Legacy v1 POST accepts nested format 3 only without AI objects; AI sources require verified v2 scenes. Both v1 and v2 reject historical nodes before publishing. Current Sync uses v2.

The client permits upload only when its remembered server copy is unchanged, or when initializing an empty server. It downloads when only the server changed, or into an empty fresh installation. Divergent copies stop with an explicit conflict, without automatic merging. Local imports validate every drawing and immutable snapshot collision before writes, write snapshots first, then atomically replace the index while retaining compatible device-local branches. Cleanup uses UUID-relative keys, validates retained snapshots and inventories all references before deleting obsolete files. Local history policy is [local-undo.md](../local-undo.md).

Success means a confirmed server commit or a fully committed local import. Offline/VPN-off, authentication, size and conflict errors show **Sync unsuccessful**, never a false success. A timed-out upload may have reached the server; retry is safe. Both machines being on the same LAN is not sufficient: this URL is private Tailscale HTTPS. Do not disable certificate validation to work around connectivity failures.

V2 metadata is bounded to **4 MiB**, each compressed/decoded object to **128 MiB**; legacy uploads retain their 128 MiB whole-body limit. DGX stores a compressed current manifest and SHA-addressed current native/scene/PNG objects. PNGs are derived and revision-bound; refreshing images for unchanged notes does not create another note revision. Cache reuse requires the same exact scene digest and renderer version; v1 client PNGs cannot claim server-rendered provenance. Confirmed commits transactionally discard superseded revisions and unreferenced objects. In-flight objects survive failed commits, expire after 24 hours, and are cleaned by commit/backup housekeeping without deleting current references. Local whole-page snapshot costs remain between successful Syncs.

## Document Sync and generated assets

[AI_SYNC.md](AI_SYNC.md) is the exact new route/field reference. `/v2/documents/DOC_UUID/state` reads or publishes a single document, preserving unrelated server documents and empty folders. A POST carries a stable `syncID` and an opaque `baseDocumentDigest`; missing baselines cannot overwrite existing documents. `/v2/sync-receipts/SYNC_UUID` recovers an exact committed receipt after response loss. Freshness is `lastSyncedAt`, including unchanged successful confirmations, not the source revision's creation time.

Current generated objects live in the current head's optional `objects`; source/manifest format 2 (flat folders) or 3 (nested folders) references exact PNG assets through the existing CAS. Assets/specifications/native current heads/composites survive backup restoration; old undo and obsolete assets do not. Scene composites place native ink over generated objects. The client keeps per-document and folder reconciliation authority, so partial Sync cannot bless unrelated stale copies.

## State and credentials

- DGX state: `~/.local/state/draw-sync/{token,sync.sqlite3}` (owner-only).
- Unit source: `server/draw-sync.service`; installed in `~/.config/systemd/user/`.
- Mac build credential: `~/.config/draw-build/Sync.xcconfig`, containing `DRAW_SYNC_TOKEN`. Never commit it or paste build settings into chat/log reports. Xcode embeds it via `Draw/Info.plist`; this is a private-device credential, not an unextractable secret.
- DGX retains the same private build config under the service state directory. Rotate both configs, restart the service and rebuild the app to revoke a credential.
- A pre-update iPad container backup and the signed build are retained under `~/.local/state/draw-sync/` on DGX. App uninstall destroys local unsynced data; refresh signing by installing over the existing app.

The independent copy is now [private current-state data backup](https://github.com/your-account/Draw-data). The `draw-backup.timer` checks local DGX state every five minutes; it pushes only new/unpushed changes. `draw-backup.service` exports a metadata manifest, immutable `.pkdraw` snapshots, exact portable `.json` scenes and current `.png` images through one consistent SQLite read snapshot into `~/.local/state/draw-sync/backup-repo`. Each published backup is one parentless current-state commit; every successful update replaces the previous root using an exact remote-OID lease. Unchanged content is reused, and current active/deleted pages are included. Credentials, live databases and signed apps are excluded. A failed GitHub push retries on later runs; **Synced with DGX** confirms the DGX transaction, not a GitHub push. Do not run a second writer or a manual unconditional force-push. The backup job refuses unexpected refs and remote changes, and prunes local unreachable Git objects only after verifying publication.

`python server/backup.py --restore-package PATH_TO_BACKUP --output PRIVATE_OUTPUT.json` reconstructs a checksummed native sync package without altering the app/server. `restore_scenes(PATH_TO_BACKUP)` restores optional portable scene records; old backups without scenes remain compatible. Unsynced iPad edits are not in this backup. Repository access exposes current notes. GitHub is provisional; physical garbage collection may lag a rewrite, and formerly reachable commit URLs may remain accessible. No old version is reachable from published branches.

Maintenance migration uses explicit `Database.migrate_current_only()` followed by offline VACUUM, after verified current-only recovery. It never runs automatically in the constructor. Do not preserve undo-bearing recovery databases; before app installation verify current native files and retrieve current-only recovery to DGX. Use SQLite's online backup API when a database recovery copy is necessary, not a live file copy that ignores WAL.

## Agent API

Every endpoint uses the same bearer authentication and private Tailscale origin. No OCR, semantic classification or LaTeX generation runs here. Metadata comes from stored page properties and counts derived from portable strokes, or legacy iPad image metadata.

- `GET /v1/documents`: latest revision, document IDs/names/dates/orientation, live/deleted page counts, each document's `folderID` (null for Home), full `folderPath` and root-first `folderPathIDs`, and folder summaries.
- `GET /v1/folders`: revision and complete folder list (`id`, `name`, `parentID`, `documentCount`, `fullPath`, `pathIDs`), including empty folders. `parentID` is null for root folders, `documentCount` counts direct documents, `fullPath` joins root-first names with `/`, and `pathIDs` is the root-first UUID chain including the folder. Names can contain `/` or repeat; navigate by IDs, not by the display path.
- `GET /v1/folders/FOLDER_UUID`: folder summary, root-first `ancestors` (excluding itself), direct `children` summaries, and direct `documents`. All ancestry/path fields come from the selected revision. Existing document/page URLs and IDs do not change.
- `GET /v1/documents/BOOK_UUID`: ordered pages and Deleted pages, paper type, stars, head, history count, tags, image dimensions, stroke count and native ink types. `png` links pin the revision so a later sync does not mix pages from different libraries.
- `GET /v1/documents/BOOK_UUID/pages/PAGE_UUID.png?revision=N`: raw PNG, including Deleted pages by ID.
- `GET /v1/documents/BOOK_UUID/pages.zip?start=2&end=5&revision=N`: PNGs for an inclusive **1-based document-order** span; no Deleted pages mixed into that range. Omit `start/end` for the entire live document.

Folders are organization metadata, with no separate drawing directories or ownership rules. Sources optionally include `folders: [{id,name,parentID?}]`; notebooks optionally include `folderID`. Missing or null `parentID` means root, without adding default fields to legacy flat sources or their digests. Any non-null parent requires source format 3. Folder IDs must be unique, parents must exist, and the graph must be acyclic before publication; input order need not be parent-first. Moving a folder preserves its descendants and IDs. App deletion reparents only direct documents and child folders to the deleted folder's containing parent (or Home), preserving descendant trees; publish that validated replacement graph through whole-library Sync. Document-only Sync carries exactly its folder and all ancestors, with no children or unrelated folders, omitting `folders` when the ancestor closure is empty; differing existing ancestor metadata conflicts rather than implicitly renaming or moving shared folders. It preserves unrelated documents, empty folders and their ancestry. Whole-library backup and restoration retain the graph, source format and readable PNGs. The iPad atomically stores `{notebooks,folders,localHistory}`; its reader accepts the older wrapper and original array. Optional notebook `orientation` is `portrait` or `landscape`, defaulting to portrait when absent. Device-only retention metadata never enters Sync. Do not install older builds that misunderstand the retention policy. The agent API remains read-only; changes are made in the app and published by manual Sync.

Append `?revision=N` to pin the current revision; superseded revisions now return 404 rather than mixing page versions. Missing images return an explicit 404 asking for an updated-app Sync. Linux does not decode private PencilKit archives. During manual Home Sync, the updated iPad exports public controls and native interpolation samples; DGX renders readable 2× PNGs on ruled white paper. Original paper settings remain metadata. Native archives remain editable recovery data; procedural marker previews are approximate. Existing cached iPad PNGs remain until updated-app Sync. These PNGs are excluded from note digests and do not change history. No OCR dependency is needed.

Generated scenes also support agent-only cyan `highlight` objects: immutable 20%-opacity RGBA rectangles beneath native ink. Their source, descriptors and PNGs survive current-only Sync/backup like other AI objects; they do not alter ink colors or add a human palette entry. Native movement uses the assistance protocol's full-stroke capture, not a server rewrite of archives. See [AI_SYNC.md](AI_SYNC.md) and [../notes_service/README.md](../notes_service/README.md).

Fixed purple **Question** (`#AF52DE`) now means any question, missing/unfinished material or item to revisit. The old teal Missed palette entry is removed by the app upgrade and recolored to purple. Renderer version 3 treats remaining legacy teal as `question` too, without mutating stored native archives. Matching uses a half-channel-step tolerance, for pen and marker. New `tagStrokeCounts` emits `question` only; legacy `missed` counts remain readable. Positive counts cannot exceed `strokeCount`; `{}` means inspected with none, absent/null means legacy or unknown. Page-level `tags` lists available keys, is `[]` for none, or `null` for unknown. Renderer version 3 refreshes older metadata through ordinary confirmed Sync without changing source revisions merely for tags. Counts and tags become available after manual **Sync**, remain in the private backup, and can be refreshed without a new source revision.

Agent helper (downloads to `~/tmp/draw/BOOK_UUID/REVISION/` by default):

```bash
.venv/bin/python server/client.py                       # list documents and folders
.venv/bin/python server/client.py --folders
.venv/bin/python server/client.py --folder FOLDER_UUID --revision N  # direct docs, children and ancestry
.venv/bin/python server/client.py BOOK_UUID             # list pages and metadata
.venv/bin/python server/client.py BOOK_UUID --page PAGE_UUID
.venv/bin/python server/client.py BOOK_UUID --span 2:5
```

Filter tagged pages from document metadata (use `"missed"` in place of `"question"` for fill-ins):

```bash
.venv/bin/python server/client.py DOC_ID | jq '.pages[] | select((.tags // []) | index("question")) | {id, number, tags}'
```

On DGX it reads the owner-only token file. Other trusted clients can use `DRAW_SYNC_TOKEN` and optionally `DRAW_SYNC_URL`; never put bearer secrets in query strings or pasted commands. Pass `--dest` to choose a different private output directory, then the Pi agent can read the resulting PNG files directly.

## Browser viewer

The private deployment also has an X launcher/page viewer (not included in this repository). It lists the synced folder/note library and scrolls ordered cached PNGs, loading nearby pages on demand; Deleted is collapsed separately. Refresh retrieves the latest synced metadata. This uses only DGX's read-only API, keeps the bearer server-side, and does not contact the iPad/Mac, run inference or change source. Images bind the selected source revision; a concurrent Sync retiring it yields an explicit refreshable error, not mixed versions. Viewer code/runtime belong to `~/jarvis/src/jarvis/x/`; health is `~/uptime/draw_page_viewer.py`. Its data/fidelity limits are the same as the API below.

## Reader workflow and limits

1. List documents/folders, select the document UUID, then fetch its metadata. Match IDs, not titles or page numbers that may change.
2. Inspect `pages` in document order and `deleted` separately. The positive `question`/`missed` tag counts identify native colors; they do not encode question text, locations, answers or whether a question has been resolved. `tags: null` is unknown legacy metadata, not an unmarked page.
3. Retrieve individual pages by UUID or an inclusive active-page span. The helper fetches document metadata and pins subsequent downloads to that revision; optional `--revision N` also pins the initial metadata/folder lookup. Read the downloaded PNGs directly, zoom/crop when needed, and never invent page content from metadata alone.
4. If a concurrent Sync supersedes that revision, retry metadata and the whole affected read rather than mixing revisions. Already downloaded files remain usable as that captured snapshot; the server does not retain an old revision for later re-fetching.

From a document workspace outside the source checkout, use the absolute helper:

```bash
/home/xaj/projects/Draw/.venv/bin/python /home/xaj/projects/Draw/server/client.py
/home/xaj/projects/Draw/.venv/bin/python /home/xaj/projects/Draw/server/client.py DOC_UUID --page PAGE_UUID
/home/xaj/projects/Draw/.venv/bin/python /home/xaj/projects/Draw/server/client.py DOC_UUID --span 1:3 --dest "$HOME/tmp/draw-read"
```

These are read-only server operations. Downloads default to the revision-specific path documented above; keep distinct destinations when explicitly overriding it. The helper loads the private local bearer token, so agents do not need to print, paste or embed it in commands. HTTP callers use the `revision` query parameter; the CLI exposes the same pin as `--revision N`. Home documents use `folderPath: ""` and `folderPathIDs: []`.

Legacy synced PNGs use ruled white paper and retain original paper as metadata. New scenes with explicit `background` composite the actual paper and generated objects; native captured assistance images remain distinct from procedural server previews. They are not exact app screenshots or necessarily the same size as a future Ask snapshot. Unsynced iPad strokes are unavailable through this API. This read-only Sync CLI does not run OCR, start Pi, apply AI drafts or edit drawings. Those request/draft operations belong to the separate [assistance broker](../notes_service/README.md), with actual native captured context and explicit foreground document Sync. Standalone agents can still retrieve and inspect marked pages here, but must not assume the last manual Sync includes newer iPad ink.

## Operation

Renderer dependencies are pinned in `server/requirements.txt` and use the host's Cairo library. Install into the existing project environment with `uv pip install --python .venv/bin/python -r server/requirements.txt`, without replacing it.

Run server tests: `.venv/bin/python -m unittest discover -s server -v`.

Service status/restart: `systemctl --user status draw-sync` / `systemctl --user restart draw-sync`.

Disable only this service with `systemctl --user disable --now draw-sync`. Remove only this Serve route with `tailscale serve --https=443 --set-path /draw-sync off`; do not reset Serve or disable all HTTPS routes. Preserve the state directory for recovery.

Build the iPad app with `-xcconfig "$HOME/.config/draw-build/Sync.xcconfig"`. Signed builds over SSH may lack access to the Mac's GUI-login keychain even when local Xcode works. The verified workaround stages the already-built app and Xcode-produced entitlements in Mac `/private/tmp`, then runs `/usr/bin/codesign` as a one-shot GUI LaunchAgent with the existing identity. It does not unlock keychains, change key ACLs or bypass prompts. Verify with `codesign --verify --deep --strict`, install with `devicectl`, then remove the one-shot agent. Token-bearing signed artifacts are private, never public downloads.

Weekly Personal Team renewal is agent-operated: rebuild/renew/install over the app, retaining the same developer certificate while valid. Developer trust is normally a one-time iPad action for that signer, not a weekly checklist; successful installation alone does not prove the OS permits launching. Check the signing certificate belongs to the renewed provisioning profile. If iPadOS requests trust, use Settings → General → VPN & Device Management → Developer App, and approve Trust/Allow & Restart as offered. Do not delete Draw to troubleshoot trust. No unattended renewal schedule has been enabled. If automatic provisioning keeps a nearly expired cached profile, first retain a verified private copy, then refresh only that exact UUID's Xcode cache entry and retry `-allowProvisioningUpdates`. The build may still fail at SSH Keychain signing while successfully embedding a renewed profile. Verify its new expiry, paired device and existing signer membership before the unsigned-build/GUI-sign path; preserve the recovery profile and restore the old cache entry if required. Do not remove developer certificates, unrelated profiles or the app.
