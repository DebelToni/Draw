# Draw note-worker contract

Approved direction from Anton, 2026-10-08. Implemented by the separate [assistance broker](notes_service/README.md), including inactivity management and interactive project workers. Real Pi startup, unlisted naming, graceful shutdown and exact-ID/file resumption after directory relocation were verified in isolated fixtures. Production workers are spawned on demand, not pre-started for every note. [ai-assistance.md](ai-assistance.md) owns the drawing/result protocol.

## Process and session identity

Draw's DGX manager spawns interactive Pi workers in the tmux session named exactly `Draw-notes`. Every worker is launched with `pi --unlisted --fast`; `--fast` requests OpenAI/Codex priority service with medium reasoning for this invocation. `--unlisted` identifies an agent-owned worker to Anton's tooling, not a temporary/unpersisted conversation. It must not appear as a newly spawned human chat. Workers inherit the ordinary global Pi configuration and instructions; Draw adds its project instructions and integration tools rather than constructing an empty replacement environment. The installed `~/.pi/agent/extensions/tmux-title/index.ts` registers `--unlisted`; it is a custom tooling flag, not an upstream CLI mode.

Each document worker owns a tmux window named `<Draw folder> / <note name>`, for example `dis / 1-intro` or `Home / Scratch`. Unlisted status must not remove this readable window label: it suppresses human-chat status tooling, not the literal tmux name. The manager supplies the same label as Pi's session name (`--name` on spawn/resume), so the existing title extension preserves it instead of reverting to the cwd basename. Folder/document rename or movement updates the label without changing Pi session identity; duplicate labels get a stable UUID-derived suffix. No global title-extension change is needed for this behavior.

The manager durably records document UUID → exact Pi session ID/file, working directory and owned tmux window/pane. One document always resumes its original session, including after idle shutdown, server restart, rename or folder movement. A duplicate document has a different UUID and receives a different session. Do not select a conversation by title, cwd recency, `--continue`, or a partial ID; missing/corrupt mapping is an explicit recovery problem, not permission to start a replacement conversation silently.

Pi sessions are grouped by cwd, so directory moves must preserve the stored session locator and be tested for accidental forks/replacement. Exact-session resume and same-file/ID directory relocation have been verified against the installed custom Pi; retain that regression coverage when upgrading it. Do not assume the generic CLI's cross-project resume behavior meets this contract. Conversation persistence is separate from the app's local two-Sync undo queue and current-only Draw-data backup.

Requests for one document are serialized and keyed by stable request ID. The manager waits for idle/settled state before delivering the next request; it does not inject a new question into an unrelated active turn. Manager/API request state, assets and receipts are durable independently of terminal output. Do not treat ANSI screen scraping as proof that a request or result committed. The project extension implements the structured bridge, including durable settlement acknowledgment/recovery; switching to invisible SDK/RPC workers without agreement would violate the chosen interface.

## Workspace hierarchy

The managed project root is `~/projects/Draw/notes-workspace/`. It is a runtime workspace, excluded from source Git, not a second Draw checkout. Its shared instructions override inherited development-role assumptions for note work without replacing normal global Pi resources.

```text
~/projects/Draw/notes-workspace/
  AGENTS.md
  <Draw-app-folder-name>/
    <document-name>/                 # worker cwd
      document.json                 # UUID and request/context locators
```

A document directory's parent represents its full logical folder path in the Draw app, encoded as one filesystem component even when app folders are nested. Two levels up is the note project root containing the shared `AGENTS.md`. Home documents get a reserved Home directory so the depth and meaning stay identical. The generated root instructions explicitly explain these relationships and how to retrieve current pages. They hold standing behavior, typography, placement and safety guidance in structured sections. Request messages carry only the current task; no repeated rules or UUID/hash headers. Page tools infer the active request ID (an explicit matching ID remains supported), and terminal-request IDs are generated when omitted. `current-request.json` exposes machine metadata if needed but grants no authority. Existing Pi compaction handles the conversation; no extra compaction machinery or project skill is needed. Update the shared file and reload verified idle workers when standing guidance changes.

Folder and document names are human-readable labels, not identity keys. Sanitize separators/control characters and disambiguate duplicate or colliding names with stable UUID-derived suffixes. Retain the UUID registry through renames/moves, and never let a display name escape the project root or select another session. Empty app folders remain represented. Workspace organization must not change editable ink IDs or native snapshot paths.

Global Pi resources remain global. Shared note behavior belongs at the project root; optional folder/document context can add subject-specific material without copying the global prompt into every directory. Full normal Pi tools are wanted, including files, wiki, memories, web search and other agents. Do not impose a document-only filesystem sandbox or stripped tool allowlist. Existing global authority rules still apply. Draw mutation tools target the current document unless another document is explicitly requested.

## Idle shutdown

The DGX manager closes only its owned inactive worker process/pane after **24 hours of continuous inactivity**, measured from the last request completion or human interaction. This deliberately favors continuity over reclaiming idle Node-process memory sooner. An active model turn, tool/render call, pending request or recent human interaction means the worker is not idle. A slow provider response must not trigger shutdown; completion restarts the inactivity interval.

Graceful shutdown preserves the session and acknowledged request state before releasing the pane. It never kills the whole `Draw-notes` tmux session, another document's active worker or a human-attached process without accounting for that activity. Resumption starts Pi in the document workspace with the same exact session. Idle shutdown does not prune conversation history or silently retry failed app requests.

## Shared standing context

The authoritative standing instructions are [notes_service/AGENTS.template.md](notes_service/AGENTS.template.md), copied to the shared workspace root and loaded into system context. Keep behavior there rather than repeating another prompt draft in this document. It covers practice without answer keys, reserved work space, intent-sensitive hints, first-error feedback, agent-only cyan markings, guarded task-local movement/removal, compact handles, freshness and exact preview inspection.

The canonical tool/diagnostic-file contract is [notes_service/README.md](notes_service/README.md). The model receives current-task messages and semantic images/geometry; the bridge resolves pinned UUIDs, fingerprints, revisions and approval evidence internally. Existing Pi compaction handles conversation history. Updating the shared instructions and reloading verified idle workers preserves their exact sessions.

## Documentation and retrieval

[server/README.md](server/README.md) is the maintained entry point for private endpoint/authentication, document/folder lookup, page and span downloads, tag filtering, revision behavior and operations. Keep it synchronized with actual server/client behavior whenever these interfaces change. Generated note instructions link to its absolute installed location or expose an equivalent manager-owned reference, rather than embedding a stale second API manual.

Current synced previews and future Ask snapshots are different sources. The existing read-only API cannot see unsynced iPad ink, start a note worker or apply an answer. Future worker requests must carry a pinned context snapshot and separate request/result protocol. For a terminal-origin request, ask active Draw to Sync the requested document first, reusing unchanged objects and leaving unrelated documents alone. If the app cannot respond, state its last document-Sync time and ask whether to proceed with that version or open the app and Sync; do not silently continue with stale context. The foreground reverse-request bridge is implemented over an authenticated WebSocket and document Sync receipts, not paired-device file access. The Mac's native device-copy tools remain separate recovery/build tooling.

## Implementation acceptance

- Every worker lives in `Draw-notes`, uses `--unlisted`, and has a readable folder/note window title throughout startup, tool activity, completion and resumption.
- Idle boundary tests retain a worker before 24 hours and close it only after that interval, with busy/pending/human-activity guards intact.
- Fresh spawn, inactivity shutdown, server restart, rename/move and duplicate-name tests preserve exact document session identity.
- Human interaction and busy turns prevent idle shutdown; no unrelated pane/process is terminated.
- Missing identity mapping or failed receipt recovery does not create a duplicate session/request/result.
- Global/project/folder instruction discovery is verified from the actual worker cwd, including Home and renamed folders.
- Answers are fast and task-focused, page-only by default, with explicit companion mode rather than Learn-style questioning. Handwritten follow-ups and terminal requests use the same document session/result protocol.
- Existing page retrieval remains documented and read-only; no AI deployment is implied by these design files.
