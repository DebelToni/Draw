# Local undo and current-only Sync

Approved 2026-10-07. Undo is device-local, per page, with retained branches inside a rolling two-window queue. Native `.pkdraw` files remain the editable source; document/page/current snapshot IDs, drawing coordinates and folders are unchanged.

## Queue

A successful manual Sync discards undo preceding the previous successful Sync, keeps changes since that previous Sync plus the entry states needed to undo them, and starts a fresh window. Two successful Syncs without intervening edits leave current states only. Failed or interrupted Sync never rotates the queue; a committed upload whose receipt was lost is reconciled on retry. A nonblank retained floor cannot Undo to an invented blank page. Branch navigation stays within retained states.

The index stores device-only `localHistory` atomically. Snapshots are deleted only after that index is durable, and after readable retained files plus a complete inventory are verified. Identity comparisons use book/page/node UUIDs, not absolute paths: iOS `/var/mobile` and `/private/var/mobile` are aliases. Missing current files block cleanup. Failed cleanup can leave harmless unreferenced files, retried later.

The one-time upgrade clears pre-existing undo, including deleted-page history, after checking current heads. It is not repeated after ordinary relaunches. Historical indexes and archives retained outside the app were explicitly removed after independently verifying current-only recovery.

## Remote state

`Store.exportCurrentPackage()` exports one normalized root node per nonblank current head; nil heads export no nodes. `exportPackage()` remains a local test/recovery inspection API and must never feed shipping Sync. Baseline digests describe current content, independent of device history pruning. Same-page downloads reuse retained local nodes or attach a new remote head; a changed nil head safely resets that page to blank.

The server rejects historical nodes through both upload routes, holds one latest source revision, and atomically removes obsolete scene/image/native references. Uncommitted CAS uploads have a 24-hour expiry, preserving current references. Agent URLs remain revision-pinned, but obsolete revisions are unavailable.

Draw-data publishes one parentless current-state commit with an exact remote lease. Local Git garbage collection follows verified publication; failed pushes preserve recovery objects. GitHub's reported disk size and unreachable commit availability can lag its physical garbage collection. This is recovery of the last Sync, not version history.

## Orientation

Home Settings explicitly selects Portrait or Landscape. Native orientation is locked to the selected mode, not driven by device motion. Every document has an orientation icon, new documents inherit the selected mode, and only matching documents open. Existing documents default to portrait. No document conversion or ink rotation is performed. Both modes retain the 3×3 overview, all tools and toolbar edges. Portrait base coordinates are 1024×1361 points; landscape uses 1361×1024, extended when existing ink exceeds that extent. Portable export uses each document's mode, independent of the current Home orientation.

## Pinned baseline repair

An operator-created `sync-baseline-repair.json` can pin an exact previous baseline, current local source digest and target remote revision/digest. It is consulted only during manual Sync. Mismatches stop without replacing source; stale/already-applied receipts do not override newer authority. This is not a general conflict bypass or remote-command interface.

Local whole-page undo snapshots can grow between confirmed Syncs. The queue bounds history age in successful-Sync windows, not a fixed storage quota.
