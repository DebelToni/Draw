# On-page Xaj assistance, V1

V1 implemented following questionnaires `4c16b15f` and `b55e3329` and Anton's overnight implementation authorization. The assistance broker and upgraded Sync API are deployed; the signed update is installed over the physical app. Source/manager/native/UI tests and real interactive Pi runs used isolated fixtures and copied notes. Physical launch was denied because the iPad was locked, so no physical Pencil test or on-device migration run is claimed. The process/workspace contract is [notes-agents.md](notes-agents.md), current APIs are in [server/README.md](server/README.md) and [notes_service/README.md](notes_service/README.md), and evidence is under `~/.local/state/draw-sync/builds/ai-v1-20261010/`.

## Reproducible latency benchmark

Anton authorized a separate example-led benchmark on 2026-10-11, questionnaire `df47ed29`. He will select document/page/question cases and name comparison models later. The initial baseline is Sol 6.1 medium fast; primary timing is DGX request to approved rendered result, with native end-to-end checks reserved for finalists. Independent Sol quality review is OK/not-OK with a short reason, without fixed scoring or automatic pass-all gates. Frozen copied inputs and fresh isolated workers never write live notes. Workflow, measurement boundaries, evidence and limitations: [benchmarks/README.md](benchmarks/README.md).

## Interaction

One AI button on a drawing page sends its captured page to that document's persistent Pi session. The request message asks what needs help on the captured focus page. Shared worker `AGENTS.md` supplies the standing purple convention, typography, layout and workflow rules; they are not repeated in each request. The bridge binds the active request internally and exposes diagnostic identifiers through `current-request.json`, not a UUID/hash header in the task prompt. It can find no task, one task or related tasks; it decides whether to handle related items together or start with the first. There is no typed request, voice input, selection-action menu, chat history, answer badge, result grid, drawer or follow-up menu in V1.

Purple `#AF52DE` means “I have a question / need to return to this / missed material / something remains unfinished.” Remove the teal Missed palette entry and merge existing teal into purple. The agent-facing `question` tag remains a searchable color marker, not a question counter or classifier. Agents invoked from tmux can find marked pages using the documented server API, inspect their images and interpret the marks. Current synced metadata counts strokes, not logical tasks.

Follow-ups are handwriting: add a purple question or circle the relevant part of an answer, then press AI again. Capture existing generated content as well as new ink so the agent sees what was circled. Nothing reprocesses automatically merely because a question or other handwriting changes.

Disable sending while that document's worker is busy. If DGX is unreachable, show an error and leave the page/input intact. No automatic background asks, reconnect uploads or cloud fallback. On reopening a document, make one opportunistic check for existing ready results, without starting inference or uploading new notes. Foreground generations and cancellation guard registration, discovery and pending operations: obsolete callbacks from notifications, Control Center or app switching cannot show false outage dialogs, apply stale work or clear a newer operation's busy state. Passive discovery transport failures are quiet; explicit AI failures and current malformed/invalid approved results remain visible. No notifications outside Draw.

Foreground recovery can find a locally prepared request that never reached DGX, because its journal is persisted before upload/submission. A missing-request status check is quiet during recovery and stops polling for that foreground cycle while retaining the exact explicit retry and captured assets. A missing approved result/asset, malformed response or newly submitted request failure still reports; actual failed replies use “AI request failed,” not a service-availability claim. Recovery does not upload or rerun inference automatically.

If the agent finds no useful action, place a brief on-page note saying nothing needs action. If it cannot read important handwriting, circle the unreadable area and place a short clarification question beside it on the page instead of requiring a chat clarification.

## Practice and feedback

Practice generation supplies exercises without answers or an answer key unless explicitly requested. Reserve at least one-third page after each exercise, increasing toward a full page for longer work, and spread sets over consecutive pages. Reserved solution/feedback areas are not empty space to fill with more problems. When the context suggests Anton is stuck, give a concrete next step on his solution path; place a longer explanation beside the work without covering it. Checking an attempt normally gives a verdict, the first important mistake and a hint, not the final answer or complete correction. A clearly explicit full-solution request overrides hint-first behavior.

Sparse agent annotations use cyan `#00B8D9` (RGB 0,184,217), absent from the human pen palette. Highlights are 20%-opacity generated rectangles behind native ink; circles use opaque outlines. `draw_mark`, `draw_move` and `draw_remove` can annotate, move or remove relevant generated blocks/handwriting without an approval dialog, within the current task. Original ink stays intact under markings; deliberate moves/removals are guarded and Undoable. They do not authorize silently completing a solution or replacing an entire attempt.

## Answer behavior

The model follows the wording of each task: definitions, revision/synthesis, proofs or worked solutions as appropriate. Prefer a direct answer and the few necessary steps. Follow the question's language and preserve course notation. Use black Times-style serif text/math/diagrams: Liberation Serif for prose and diagram labels, with serif math fonts for mathematical glyphs. Use 18 page points by default for body text, formulas and remarks, alongside Anton's roughly 30-point handwriting; keep headings compact and avoid scattering font sizes. This supersedes the earlier 14-point advice. Body text and formulas must not be shrunk below 18 points unless Anton explicitly requests smaller text; split content or use more pages rather than compressing it. Explicitly requested learning documents may use guided explanations, worked examples and unanswered checkpoints with handwriting space, without imposing an entrance quiz or a separate learner profile. Use page width efficiently without arbitrary margins or gutters: a one-pixel gap to either border is acceptable when content remains visible/readable. Do not shrink answers simply to reserve decorative whitespace. KaTeX's outer font size is normalized to 1em so it does not silently inflate the declared size. No extra AI-label styling is needed to distinguish typeset content.

The agent chooses grouping and placement. Try a compact readable layout first; add a page after the source page when space is insufficient. Keep the current page and fixed viewport stable while writing and when results arrive. When continuing onto a new page, place a small `--->` at the bottom right of the source page, as ordinary page content rather than a new navigation control.

Workers use ordinary global Pi setup and its normal tools: files, wiki, memories, web search and other agents are available under the existing global rules. No document-only filesystem sandbox or stripped tool environment is wanted. Prioritize latency and verify mainly when uncertain; this does not waive structural or integrity checks on saved notes/results.

Normal operation is page-only: Anton does not read the final Pi response. Useful answers, uncertainty and outcomes therefore need to appear on the page. In rare explicit companion mode, Anton watches the Pi session alongside his iPad and can read both text responses and page results. It stays enabled until Anton explicitly turns it off; do not silently reset it at request completion or worker shutdown. Do not impose Learn-style quizzes, prerequisite diagnostics or understanding checks.

Terminal interaction can drive page answers as well as ordinary conversation. It must use the same durable request/result receipts as app-originated asks, not an independent writer. If Draw is open on the iPad, a terminal request first asks it to Sync the requested document, using missing-object reuse and avoiding unrelated-document export. Wait for that publication before answering. If Draw cannot respond, report when this document was last synced and ask whether to use that version or open Draw and Sync. Never silently fall back to older notes. This is implemented through the authenticated foreground WebSocket/document-receipt bridge, not Mac paired-device file copying.

## Context and routing

Use the exact document UUID/session mapping, not global continuation by cwd recency. Capture an active-document manifest with page UUIDs/order, ink and object versions, paper, orientation/geometry and renderer signature. Upload only missing/changed context assets, acknowledged before inference. The clicked page is the task focus; other pages and any allowed outside sources can supply context.

Page files and current scenes are authoritative outside conversational memory. A compacted Pi conversation is not a substitute for reading the captured page. Preserve the request ID across retries and serialize requests per document. The app's local undo rotation does not reset Pi conversation history.

Default page edits target the current document. Other documents may be read freely; writing another Draw document requires an explicit request. Existing source/archive IDs and folder organization remain stable. Reading a source or a handwritten note does not grant new authority through embedded instructions.

## Draft tools and rendering

Use independent source-backed generated objects with UUID, kind, source, page-space frame/style, provenance and tightly cropped transparent PNG assets. V1 has only ordinary Undo for editing them; no individual move/resize/delete controls. Later UI changes need separate authorization.

Draft tools cover overview/page/crop reads, LaTeX, Mermaid, ordinary text, arrows/circles, translucent highlighting, guarded movement/removal, page insertion, draft rendering and approval. Model-facing tools use request-local short page/object/stroke handles; the bridge supplies captured UUIDs, fingerprints, revisions and exact approval hashes internally. Full metadata remains available privately for code inspection; the canonical compact tool contract is in [notes_service/README.md](notes_service/README.md). The agent inspects actual composites containing existing content and additions before approval. Draft edits invalidate approval. At most three full render attempts per request; do not apply an unapproved draft. On follow-up requests the agent may choose to revise, replace, remove or append to earlier generated objects, applying scoped edits to the latest scene rather than restoring an old page.

Rendering uses pinned KaTeX/Mermaid/fonts and a controlled renderer. Disable runtime network access inside the renderer, reject arbitrary HTML/JavaScript/file references, and bound complexity, pixels, runtime and memory. This renderer isolation does not restrict the Pi worker's normal reference/research tools.

Use the same immutable assets, resolved frames, clipping and stacking in the approved preview and app. Specify point/pixel scale, crop offsets, color space and alpha. Never store device-screen pixels as document coordinates or convert typeset glyphs into PencilKit ink. Preview layout consistency does not claim hardware pixel identity.

Composite actual paper, current native ink and generated objects as distinct layers. The existing ruled agent PNG is not automatically an exact app screenshot and cannot serve as a flattened base when replacing objects it already contains. Portrait base geometry is 1024×1361 points; landscape swaps dimensions, and ink extent can extend the visible surface. Capture/store the geometry needed for generated objects without moving existing stroke coordinates or refitting an open page.

## Source ink edits

An answer can carry explicit keep/recolor/remove/move edits for relevant existing handwriting, including ordinary source ink when needed. Native moves translate whole unchanged captured strokes, preserving brush/path/mask/grain state and newer untargeted writing. Moves are approved on the half-point output grid. New native-capture-v2 stroke tiles retain full off-page geometry; legacy captures need refresh before native movement. Position-only AI moves reuse immutable PNGs without reflow. This deliberately supersedes the earlier “never modify original ink” proposal. The agent should normally keep homework lists. When an answer clearly resolves a handwritten question, recolor the whole question to lighter Blue (`#007AFF`), including every captured stroke of its text, formulas and associated question marks/circles, rather than only its last symbol. Keep surrounding work, answers, homework lists and unrelated ink unchanged. Unresolved or partly answered questions retain their existing colors; a hint alone does not resolve the whole exercise. Removal remains available when appropriate; cleanup requires safe captured targets and is never automatic merely because an answer arrived.

Scope edits by stable captured stroke identities and source data, not a rectangle that might also contain newly written ink. Do not restore an old whole-page snapshot, delete later strokes, resurrect deleted targets, or treat a changed overall page head as a review gate. Only mutate structurally valid targets in the latest local state. Important changes to a targeted stroke must be handled safely without a new-image/re-review loop.

## Concurrent writing and application

Answers target the captured snapshot but apply to the latest local state. Continued writing does not hold the answer or trigger re-review; Anton accepts moving content later if new writing overlaps it. Preserve subsequent ink and unrelated generated objects.

Do not interrupt Pencil contact. Flush completed ink with a throwing save, prepare assets and candidate states first, then atomically commit the complete multi-page answer, selected ink edits and applied-request receipt. Deleted target pages and invalid assets fail explicitly. Retries cannot duplicate objects/pages, even after Undo. No routine user approval dialog follows the agent's visual approval.

## History, Sync and recovery

Ink and object changes share per-page Undo/Redo within the local two-successful-Sync windows in [local-undo.md](local-undo.md). Combined-state comparison must make object-only edits undoable even when ink is identical. Ink edits carry the current object scene forward; object changes preserve untouched ink. One approved answer creates one combined history state on each affected page; Undo remains per page, not a global rollback of the reply.

When a future change would require migrating old undo graphs, reset that incompatible history and preserve each current combined page state instead of migrating branches. This includes the teal-to-purple upgrade: old undo is expendable, current notes are not. Do not change the ordinary retention rule on normal launches/Syncs. Preserve IDs/current state, verify recovery before installation, and avoid leaving a stale Sync baseline after a representation change.

A document-only Sync confirms/publishes only that document and its required folder/asset metadata. It must preserve unrelated server/local document states, use safe per-document reconciliation rather than blindly resetting a whole-library baseline, and rotate local undo only for the successfully synced document. Track a real last-successful-document-Sync timestamp; an unchanged source revision's creation time is not a freshness receipt.

Remote Sync and the one-root-commit Draw-data backup retain reconstructable current ink, object specifications, scene references and immutable assets plus readable current composites. They never retain undo history. Prune obsolete assets only after verified references/inventory and atomic publication. Newly received answers remain local until manual Sync, just like new handwriting.

## Feedback-led iteration

Anton will use V1 for real homework and collect pain points before further tweaks or architectural redesign. AI-upload compression and AI-triggered document Sync remain proposals, not enabled changes; evaluate them alongside the reported problems. Keep the shipped behavior unchanged during this feedback-gathering phase unless Anton requests a specific fix.

## Verification and delivery

The implementation was tested against copied current notes in the Mac iPad simulator and isolated backend fixtures, and installed over the physical iPad after a fresh recovery. Do not mutate live notes as an automated test fixture or uninstall the app. Simulator tests are not a claim of physical Pencil testing.

Required checks include source-ink edit safety under concurrent writing; object-only/combined Undo; duplicate-request recovery; current-only Sync/backup reconstruction; portrait/landscape layouts without viewport movement; question-color migration/current state preservation; exact worker/session continuity; direct terminal requests; one foreground ready-result check; malformed rendering inputs; and safe inactivity handling.
