# Draw notes assistance

The assistance broker is separate from the editable source Sync server. It listens on **127.0.0.1:18881**, privately served at `/draw-ai` on the existing tailnet origin, with the same owner-only Bearer token. Port 18876 belongs to the Google browser CDP and must not be changed.

Source/page lookup, current-only storage and ordinary Sync are documented in [server/README.md](../server/README.md); document receipts and format-2 assets are in [AI_SYNC.md](../server/AI_SYNC.md). Worker behavior and workspace identity are in [notes-agents.md](../notes-agents.md). Rendering/security details are in [rendering/README.md](rendering/README.md).

## Processes and state

- `draw-notes.service` runs this broker with normal user HOME and Pi/tmux access, outside the Sync service's restrictive filesystem sandbox.
- Private request SQLite/CAS: `~/.local/state/draw-sync/notes/`.
- Generated note project: `~/projects/Draw/notes-workspace/`, excluded from source Git.
- Interactive workers: tmux `Draw-notes`; windows `<folder> / <note>`; `pi --unlisted --fast --name ...` with normal global tools/configuration. `--fast` requests OpenAI/Codex priority service with medium reasoning on new/resumed workers; it does not change global settings.
- App folder parent links derive full logical paths for labels; the physical workspace remains root / encoded-full-folder-path / document, so shared instructions stay two levels up. Source format 3 and ancestor-only document manifests preserve the hierarchy. Ancestor renames/moves use existing deferred, exact-session relocation rules.
- Exact document UUID → Pi session ID/file is durable. Idle shutdown happens after 24 hours, only with fresh proven-idle activity. Missing/corrupt identity is an explicit recovery error.

Standing Draw instructions live in the structured shared workspace `AGENTS.md`, loaded into system context. The broker delivers only the current task, and the extension adds current authority/output-mode state to system context without embedding routing hashes in the user message. Page tools infer the active request ID; omitted terminal IDs are generated internally. `current-request.json` is diagnostic metadata only. Model-facing outputs now omit routing hashes, repeated provenance and native color floats. Pinned handles resolve against verified capture bytes: `pN` is captured page order, `sN` is ORIGINAL stroke index+1 (not filtered-list order), `oN` is page-local object order, and `new:label` names a stable generated identity. Frames accept `[x,y,width,height]` page points. Fingerprints, revisions, complete object guards and exact preview hashes are supplied internally; canonical broker/native validation is unchanged. Reload verified idle workers after shared-context or extension changes, preserving their exact sessions.

The broker is not a second writer of Draw source. Approved results apply on the client; source reaches the data server through confirmed Sync. Do not reset source baselines or treat a terminal preview as already applied.

## App requests

1. Register an installation UUID using `POST /v1/clients/register`.
2. Capture actual paper, transparent native ink, current generated objects and stable ink targets. Captures pin immutable source before detached rendering; writing can continue. Current-head caches are bounded and never serve an old head as current.
3. Ask `/v1/assets/missing`, PUT only missing exact bytes to `/v1/assets/{SHA}`, and submit `/v1/requests` with request/document/focus/context/client IDs. Asset uploads have bounded concurrency; JSON/source and PNG limits are validated before publication.
4. While this explicit request is active and the app is foreground, inspect its status. A different active request for that document returns 409. There is no idle inference or automatic retry.
5. Download the approved result by SHA and verify exact bytes/assets. Wait for Pencil contact to end, preserve later/untargeted ink, and atomically apply all page changes plus the durable request receipt.
6. Acknowledge `/v1/requests/{ID}/applied`. Lost acknowledgments retry the receipt, not application; Undo does not make a result eligible again.

On opening a document, `/v1/documents/{ID}/ready?clientID=UUID` performs one check for existing results. No chat or result-navigation panel is created. The AI button disables while busy. Ordinary errors leave notes intact.

Label metadata keeps document names and individual source folder names within 1,024 UTF-8 bytes. `folderName` is the full logical ancestor path, bounded at 65,536 UTF-8 bytes for source labels and both native/stale contexts, without truncating folder names or replacing UUID identity. The complete context still has a 4 MiB metadata limit. Managed workspace directory components remain independently sanitized and capped at 96 characters, with UUID collision suffixes.

## Terminal requests and foreground channel

The foreground app opens an authenticated WebSocket at `/v1/clients/{clientID}/channel`, sending `{kind:"open",documentID:UUID|null}`. Its lifetime is separate from bounded ordinary HTTP transfers. Background/inactive state closes the socket; there is no idle HTTP polling or background note upload.

A worker's `draw_terminal_request` creates a durable terminal intent. If Draw is foreground, the broker pushes `{kind:"sync_document",requestID,documentID,focusPageID?}`. Home and another visible document are valid. Draw acknowledges `sync-started`, performs requested-document-only Sync, captures the exact confirmed package rather than subsequent live ink, then sends `sync-ready` with the receipt/context IDs. This does not navigate the iPad.

Without a responding app, the worker reports the document's real last-Sync timestamp and asks for explicit use-synced, wait or cancel. Unanswered expired asks stay inert on reconnect. Explicit wait consent persists until the app opens or the user cancels. Acknowledged Sync gets a bounded 300-second interval instead of the initial 10-second availability wait.

Explicit use-synced context is labelled `stale/native-layer-unavailable`. Its flattened cached image supports additions only, not source-ink edits or replacement/removal of earlier objects. No native archives are uploaded to this broker. Captured public geometry/image artifacts are retired after confirmed application or permanent failure, with active/interrupted/ready pins and upload staging protected. Approved output assets remain until source confirmation makes their retirement safe.

## Pi tools

The project extension uses ordinary interactive Pi, not a hidden SDK/RPC replacement. It registers:

- `draw_read`: focused page/crop images and indexed target/color metadata; overview is a compact document summary/contact sheet. The original pinned context digest remains the authority.
- `draw_draft`: replaces the COMPLETE draft, including generated objects/pages and explicit ink edits. Version defaults to the latest observed broker state; stale sibling mutations fail CAS rather than overwrite or silently retry.
- `draw_mark`: adds/upserts a cyan circle or 20%-opacity highlight by frame, preserving other draft operations.
- `draw_move`: moves captured stroke/object handles by dx/dy in page points; right/down are positive. Whole strokes are guarded; pure object translations reuse captured PNGs.
- `draw_remove`: removes selected captured strokes or objects, or drops a pending generated add, preserving unrelated draft edits.
- `draw_render`: immutable object assets and actual composite previews. Three complete attempts total, including failures.
- `draw_approve`: explicit approval after inspecting every affected preview. The bridge binds the latest successfully delivered full image set and supplies its hashes; model arguments may use `render:"rN"` or omit it for the current delivered render. Draft changes, failed/incomplete image delivery and reload uncertainty invalidate that authority.
- `draw_terminal_request`: explicit fresh-state negotiation for terminal page writing.
- `draw_companion`, `/companion on|off`: sticky companion mode, otherwise useful output goes on the page.

The model may edit relevant handwriting, but only captured unchanged stroke identities/fingerprints are applied. Changed/missing/ambiguous targets are skipped rather than resurrected or treated as a whole-page review gate. Object edits include the complete captured descriptor, preventing revision-number collisions after Undo. Renderer approval hashes bind assets/layout; they do not prove mathematical correctness.

Manager authority is durable request state plus authenticated worker leases and `agent_settled`, not ANSI terminal scraping. A renderer failure, lost worker lease or unsupported session relocation must not silently replay inference or create a replacement Pi ID. Human input and busy turns inhibit shutdown.

## Private diagnostic context

Full canonical data is stored in owner-only worker files: `current-context.json`, `current-draft.json`, `current-render.json`, `current-bridge.json`, and `draw-last-result.json`, alongside `current-request.json`. Bind every file to its current request/version before code uses it. These are diagnostics/cache, not recovery or mutation authority. The model sees compact content/geometry plus actual PNG images; tool `details` retain original metadata for tooling. Stable short labels and convenience-call IDs do not replace lease, context, CAS or native target checks.

Native-capture-v2 supplies full-stroke tiles, including hidden off-page portions, under preflight bounds. Older captures continue supporting legacy edits but must be refreshed before moving handwriting. Requested edit-only moves/removals can finish without adding an unnecessary answer block; ordinary assistance still supplies meaningful page feedback. Standing practice and marking policy is in shared AGENTS, not repeated in each request.

## Installation and diagnostics

```bash
uv pip install --python .venv/bin/python -r notes_service/requirements.txt
cd notes_service/rendering
npm ci --ignore-scripts --no-audit --no-fund
npm run bundle
PLAYWRIGHT_SKIP_BROWSER_GC=1 npx playwright install chromium
```

Install the unit template only as part of an authorized rollout, preserve unrelated Serve routes, and verify authenticated `/health`. It performs a read-only SQLite check and never launches a worker or calls a model. The response-based monitor is `~/uptime/draw_notes_assistance.py`.

```bash
systemctl --user status draw-notes.service
journalctl --user -u draw-notes.service --since '10 minutes ago' --no-pager
tmux list-windows -t Draw-notes
```

Never paste token bytes or use credentials in query strings. Test suites run against temporary stores/loopback fixtures and copied notes, never as liveness probes. Mac/iPad recovery and signed apps remain private. Do not uninstall Draw to update it.
