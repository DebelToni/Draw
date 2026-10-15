"""Durable request state machine. Never mutates Draw source or parses terminal output."""
import asyncio
import hashlib
import inspect
import io
import time
from uuid import uuid4
from datetime import datetime, timezone
from PIL import Image, ImageDraw
from server.ai_models import current_objects
from . import validation as check
from .storage import MAX_ASSET, MAX_METADATA, Problem, Store, decoded, encoded, require, sha, utc, uuid
from .workerregistry import WorkerRegistry, HEARTBEAT_SECONDS, safe_name

ACTIVE = {"queued", "running", "awaiting_sync", "synchronizing", "needs_stale_choice"}


class Manager:
    def __init__(self, root, renderer, source=None, workspace=None, token_file=None,
                 url="http://127.0.0.1:18881", clock=time.time):
        self.store = Store(root, clock=clock)
        self.renderer, self.source, self.clock = renderer, source, clock
        self.locks = {}
        self.last_label_refresh = 0
        self.last_collection = 0
        self.channels = {}  # clientID -> authenticated foreground websocket sender
        self.worker_registry = WorkerRegistry(self.store, workspace or self.store.root / "workspace",
                                              url, token_file or self.store.root.parent / "token", clock=clock)
        # A restart never blindly redelivers uncertain work, including a lease not yet acknowledged.
        for r in self.store.requests(statuses={"running"}):
            r.update(status="interrupted", error={"code": "delivery_uncertain", "message": "Manager restarted; explicit retry/reconciliation required"}, updatedAt=utc())
            self.store.save_request(r)
        for worker in self.store.records("worker"):
            worker.update(lease=None, heartbeat=0)
            self.worker_registry.save(worker)

    def close(self):
        self.store.close()

    def lock(self, request_id):
        return self.locks.setdefault(uuid(request_id), asyncio.Lock())

    def receipt(self, r):
        keys = ("requestID", "documentID", "status", "resultSHA256", "error", "updatedAt", "lastSyncedAt", "syncStartedAt", "syncDeadlineAt")
        result = {k: r[k] for k in keys if k in r}
        result.update({k: r[k] for k in ("focusPageID", "contextSHA256") if r.get(k) is not None})
        return result

    def registered(self, client_id):
        uuid(client_id)
        require(self.store.record("client", client_id) is not None, "client_unregistered", "Register this installation first", 409)

    def register_client(self, body):
        cid = uuid(body.get("clientID"))
        self.store.save_record("client", cid, self.store.record("client", cid, {"clientID": cid, "registeredAt": utc()}))
        return {"clientID": cid}

    def companion(self, doc, enabled=None):
        uuid(doc)
        value = self.store.record("companion", doc, {"enabled": False})
        if enabled is not None:
            require(type(enabled) is bool, "invalid_companion", "enabled must be boolean")
            value = {"enabled": enabled}
            self.store.save_record("companion", doc, value)
        return value

    def context(self, r):
        require(not r.get("contextRetired"), "context_retired", "Completed capture has been released", 409)
        return decoded(self.store.read_asset(r["contextSHA256"]))

    def validate_context(self, digest, doc, focus=None, allow_stale=False):
        value = decoded(self.store.read_asset(sha(digest)))
        require(allow_stale or not value.get("nativeLayerUnavailable"), "invalid_context", "App requests require native capture")
        return check.context(value, self.store.read_asset, doc, focus)

    def pin_context(self, r, ctx):
        refs = {r["contextSHA256"]}
        for page in ctx["pages"]:
            refs.update(page[key] for key in ("paperSHA256", "inkSHA256", "compositeSHA256", "portableSHA256"))
            refs.update(obj["asset"]["sha256"] for obj in page["objects"])
            refs.update(target["asset"]["sha256"] for target in page["strokeTargets"] if "asset" in target)
        r["contextAssets"] = sorted(refs)
        self.store.pin(refs)

    @staticmethod
    def object_digest(obj):
        # Swift/Python may spell equal integral JSON numbers differently. This is a
        # causal metadata fingerprint, not an opaque source digest or asset hash.
        def normalize(value):
            if type(value) is float and value.is_integer():
                return int(value)
            if isinstance(value, dict):
                return {key: normalize(child) for key, child in value.items()}
            if isinstance(value, list):
                return [normalize(child) for child in value]
            return value
        return hashlib.sha256(encoded(normalize(obj))).hexdigest()

    def release_context(self, r):
        if r.get("contextRetired"):
            return
        if r["status"] == "applied" and not r.get("outputAssets"):
            result = decoded(self.store.read_asset(r["resultSHA256"]))
            objects = [op["object"] for page in result["pageEdits"] for op in page.get("objectEdits", []) if op["op"] != "remove"]
            r["outputObjects"] = objects
            r["objectTransitions"] = [
                {"id": op.get("objectID") or op["object"]["id"],
                 "before": self.object_digest(op["expectedObject"]) if op["op"] != "add" else None,
                 "after": self.object_digest(op["object"]) if op["op"] != "remove" else None}
                for page in result["pageEdits"] for op in page.get("objectEdits", [])]
            r["outputAssets"] = sorted({r["resultSHA256"]} | {obj["asset"]["sha256"] for obj in objects})
            self.store.pin(r["outputAssets"])
        # Keep receipts, request body hashes and approved unsynced output, not captured scenes/geometry.
        for key in ("contextAssets", "renderAssets", "readAssets", "draft", "render", "renders", "generatedIDs", "previousGeneratedIDs"):
            r.pop(key, None)
        r["contextRetired"] = True
        self.store.save_request(r)

    def collect_artifacts(self):
        live = set()
        for r in self.store.requests():
            if r["status"] in ("applied", "failed"):
                if not r.get("contextRetired"):
                    self.release_context(r)
                live.update(r.get("outputAssets", []))
            else:
                if r.get("contextSHA256") and "contextAssets" not in r:
                    self.pin_context(r, self.context(r))
                    self.store.save_request(r)
                for key in ("contextAssets", "renderAssets", "readAssets"):
                    live.update(r.get(key, []))
        return self.store.collect(live)

    async def confirm_outputs(self):
        if not self.source:
            return
        applied = self.store.requests(statuses={"applied"})
        for previous in applied:
            if not previous.get("outputAssets"):
                continue
            try:
                state = await self.source.document_state(previous["documentID"])
                books = (state.get("manifest") or {}).get("notebooks", [])
                require(len(books) == 1 and books[0]["id"] == previous["documentID"] and
                        check.timestamp(state.get("lastSyncedAt")) >= check.timestamp(previous["appliedReceipt"]["appliedAt"]),
                        "source_not_confirmed", "Output has not been confirmed in this document's source", 409)
                current = {obj["id"]: obj for page in books[0]["pages"]+books[0].get("deleted", []) for obj in current_objects(page)}
                # A Sync overlapping application or omitting these objects is not proof of publication.
                skipped = set(previous["appliedReceipt"]["skippedObjectTargets"])
                def confirmed(obj):
                    if current.get(obj["id"]) == obj or obj["id"] in skipped:
                        return True
                    # Later acknowledged replacements/removals can supersede an earlier unsynced output.
                    # Retain only hashes as causal tombstones, never old object geometry or asset bodies.
                    goal = self.object_digest(current[obj["id"]]) if obj["id"] in current else None
                    pending = [self.object_digest(obj)]
                    seen = set()
                    while pending:
                        before = pending.pop()
                        if before in seen:
                            continue
                        seen.add(before)
                        for later in applied:
                            if (later["documentID"] != previous["documentID"] or
                                obj["id"] in later["appliedReceipt"]["skippedObjectTargets"] or
                                not check.timestamp(previous["appliedReceipt"]["appliedAt"]) <= check.timestamp(later["appliedReceipt"]["appliedAt"]) <= check.timestamp(state["lastSyncedAt"])):
                                continue
                            for change in later.get("objectTransitions", []):
                                if change["id"] == obj["id"] and change["before"] == before:
                                    if change["after"] == goal:
                                        return True
                                    if change["after"] is not None:
                                        pending.append(change["after"])
                    return False
                require(all(confirmed(obj) for obj in previous.get("outputObjects", [])),
                        "source_not_confirmed", "Approved output is not yet represented by current source", 409)
            except Problem:
                continue
            async with self.lock(previous["requestID"]):
                r = self.store.request(previous["requestID"])
                r.update(outputAssets=[], outputObjects=[], outputRetired=True, sourceConfirmedAt=state["lastSyncedAt"])
                self.store.save_request(r)

    def document_free(self, doc):
        require(not self.store.requests(doc, ACTIVE), "document_busy", "Document has an active request", 409)
        worker = self.store.record("worker", doc)
        require(worker is None or not (worker.get("busy") or worker.get("pending")),
                "document_busy", "Document Pi worker is active", 409)

    async def source_labels(self, doc):
        if self.source and hasattr(self.source, "worker_labels"):
            return await self.source.worker_labels(doc)
        folder, name = await self.source.labels(doc) if self.source else ("Home", "Untitled")
        return {"folderName": folder, "documentName": name, "folderID": None}

    @staticmethod
    def label_target(labels):
        return {"folder": labels["folderName"], "name": safe_name(labels["documentName"]), "folderID": labels.get("folderID")}

    def accept_source_labels(self, worker, labels):
        guard = worker.get("capturedLabelProvenance")
        if not guard:
            return True
        proof = {"documentDigest": labels.get("documentDigest"), "lastSyncedAt": labels.get("lastSyncedAt")}
        target = self.label_target(labels)
        if all(target[field] == guard["labels"][field] for field in guard.get("fields", ("folder", "name", "folderID"))):
            # Only a source publication carrying the captured names can establish their baseline.
            if proof["documentDigest"] and proof["lastSyncedAt"]:
                sha(proof["documentDigest"])
                previous = guard.get("confirmedSource")
                if not previous or check.timestamp(proof["lastSyncedAt"]) >= check.timestamp(previous["lastSyncedAt"]):
                    guard["confirmedSource"] = proof
                    self.worker_registry.save(worker)
            return True
        baseline = guard.get("confirmedSource")
        if (baseline and proof["documentDigest"] and proof["lastSyncedAt"] and
                proof["documentDigest"] != baseline["documentDigest"] and
                check.timestamp(proof["lastSyncedAt"]) > max(check.timestamp(guard["capturedAt"]), check.timestamp(baseline["lastSyncedAt"]))):
            sha(proof["documentDigest"])
            worker.pop("capturedLabelProvenance", None)
            self.worker_registry.save(worker)
            return True
        return False

    async def ensure_worker(self, doc, ctx=None):
        existing = self.store.record("worker", doc)
        native_labels = ctx and any(ctx.get(key) is not None for key in ("documentName", "folderName", "folderID"))
        if native_labels:
            # Native capture identifies unsynced documents without requiring server publication.
            folder_known = ctx.get("folderName") is not None or "folderID" in ctx
            fid = ctx.get("folderID") if folder_known else existing.get("folderID") if existing else None
            if folder_known:
                folder = ctx.get("folderName") or ("Folder-"+fid[:8] if fid else "Home")
            else:
                folder = existing.get("folderName", "Home") if existing else "Home"
            labels = {"documentName": ctx.get("documentName") or (existing.get("noteName") if existing else "Untitled-"+doc[:8]),
                      "folderID": fid, "folderName": folder}
        elif existing:
            return
        else:
            labels = await self.source_labels(doc)
        check.labels(labels)
        folder, name, fid = labels["folderName"], labels["documentName"], labels.get("folderID")
        worker = existing or self.worker_registry.reserve(doc, folder, name, fid)
        target = self.label_target(labels)
        if existing and (existing.get("folderName"), existing.get("noteName"), existing.get("folderID")) != (target["folder"], target["name"], fid):
            worker["renamePending"] = target
        elif existing:
            # A newer native capture may undo a pending stale/source rename.
            worker.pop("renamePending", None)
        if native_labels:
            previous = worker.get("capturedLabelProvenance", {})
            fields = []
            if ctx.get("documentName") is not None:
                fields.append("name")
            if ctx.get("folderName") is not None:
                fields.append("folder")
            if "folderID" in ctx or ctx.get("folderName") == "Home":
                fields.append("folderID")
            guard = {"labels": target, "fields": fields, "capturedAt": ctx.get("capturedAt", utc())}
            if previous.get("labels") == target and previous.get("confirmedSource"):
                guard["confirmedSource"] = previous["confirmedSource"]
            worker["capturedLabelProvenance"] = guard
        self.worker_registry.save(worker)

    async def create_request(self, body):
        require(isinstance(body, dict) and set(body) == {"requestID", "documentID", "focusPageID", "contextSHA256", "origin", "clientID"}, "invalid_request", "Unexpected request fields")
        rid, doc, focus = uuid(body.get("requestID")), uuid(body.get("documentID")), uuid(body.get("focusPageID"))
        self.registered(body.get("clientID"))
        require(body.get("origin") == "app", "invalid_origin", "Use terminal freshness endpoint for terminal requests")
        async with self.lock(rid):
            existing = self.store.db.execute("SELECT data FROM requests WHERE id=?", (rid,)).fetchone()
            if existing:
                r = self.store.request(rid)
                require(r["body"] == body, "request_collision", "Request ID already used with different metadata", 409)
                return self.receipt(r)
            ctx = self.validate_context(body.get("contextSHA256"), doc, focus)
            await self.ensure_worker(doc, ctx)
            # No await between availability check and durable reservation.
            self.document_free(doc)
            r = {**body, "body": body, "status": "queued", "updatedAt": utc(),
                 "created": self.clock(), "draftVersion": 0, "attempts": 0,
                 "draft": {"draftVersion": 0, "insertPages": [], "pageEdits": []},
                 "outputMode": "companion" if self.companion(doc)["enabled"] else "page_only"}
            self.pin_context(r, ctx)
            self.store.save_request(r)
            return self.receipt(r)

    def get_request(self, rid, client_id=None):
        r = self.store.request(rid)
        if client_id is not None:
            self.registered(client_id)
            require(r.get("clientID") == client_id, "client_binding", "Request is bound to another installation", 409)
        return self.receipt(r)

    def ready(self, doc, client_id):
        uuid(doc)
        self.registered(client_id)
        return {"requests": [self.receipt(r) for r in self.store.requests(doc, {"ready"}) if r.get("clientID") == client_id]}

    async def applied(self, rid, body):
        async with self.lock(rid):
            r = self.store.request(rid)
            self.registered(body.get("clientID"))
            require(r.get("clientID") == body["clientID"], "client_binding", "Result belongs to another installation", 409)
            receipt = body.get("receipt")
            require(isinstance(receipt, dict) and receipt.get("requestID") == rid and
                    receipt.get("resultSHA256") == r.get("resultSHA256"),
                    "receipt_integrity", "Application receipt does not match approved result")
            require(set(receipt) == {"requestID", "resultSHA256", "appliedAt", "skippedStrokeTargets", "skippedObjectTargets"},
                    "invalid_receipt", "Incomplete application receipt")
            check.timestamp(receipt["appliedAt"])
            require(isinstance(receipt["skippedStrokeTargets"], list) and len(receipt["skippedStrokeTargets"]) <= 100000 and
                    all(isinstance(t, str) and 0 < len(t) <= 256 for t in receipt["skippedStrokeTargets"]),
                    "invalid_receipt", "Invalid skipped stroke identities")
            require(isinstance(receipt["skippedObjectTargets"], list) and len(receipt["skippedObjectTargets"]) <= 128,
                    "invalid_receipt", "Invalid skipped object identities")
            for target in receipt["skippedObjectTargets"]:
                uuid(target)
            if r["status"] == "applied":
                require(r.get("appliedReceipt") == receipt, "receipt_collision", "Different application receipt already recorded", 409)
            else:
                require(r["status"] == "ready", "not_ready", "Only approved results can be acknowledged", 409)
                r.update(status="applied", appliedReceipt=receipt, updatedAt=utc())
                self.store.save_request(r)
            self.release_context(r)
            self.collect_artifacts()
            return self.receipt(r)

    def result(self, rid, client_id):
        r = self.store.request(rid)
        self.registered(client_id)
        require(r.get("clientID") == client_id, "client_binding", "Result is bound to another installation", 409)
        require(r["status"] in ("ready", "applied"), "not_ready", "No approved result", 409)
        require(not r.get("outputRetired"), "result_retired", "Applied output is now confirmed in source; retain the application receipt", 409)
        return self.store.read_asset(r["resultSHA256"])

    async def terminal_request(self, doc, body):
        uuid(doc)
        require(isinstance(body, dict) and set(body) <= {"requestID", "prompt", "focusPageID"}, "invalid_request", "Unexpected terminal metadata")
        rid = uuid(body.get("requestID"))
        require(isinstance(body.get("prompt"), str) and 0 < len(body["prompt"].encode()) <= 65536, "invalid_prompt", "Terminal prompt must be 1..64 KiB")
        if body.get("focusPageID") is not None:
            uuid(body["focusPageID"])
        async with self.lock(rid):
            if self.store.db.execute("SELECT 1 FROM requests WHERE id=?", (rid,)).fetchone():
                r = self.store.request(rid)
                require(r["body"] == body and r["documentID"] == doc and r["origin"] == "terminal", "request_collision", "Request ID already used", 409)
                return self._terminal_status(r)
            await self.ensure_worker(doc)
            try:
                state = await self.source.document_state(doc) if self.source else {}
            except Problem:
                # New/unsynced documents still get a live foreground Sync attempt.
                # Unknown lastSyncedAt is never permission to read stale content.
                state = {}
            # No await between availability check and reservation, including terminal intents.
            require(not self.store.requests(doc, ACTIVE), "document_busy", "Document has an active request", 409)
            # Foreground means channel open, including Home and other documents.
            clients = list(self.channels)
            require(len(clients) <= 1, "client_ambiguous", "Multiple foreground clients; select an installation explicitly", 409)
            r = {"requestID": rid, "documentID": doc, "origin": "terminal", "body": body,
                 "prompt": body["prompt"], "focusPageID": body.get("focusPageID"),
                 "clientID": clients[0] if clients else None, "status": "awaiting_sync",
                 "lastSyncedAt": state.get("lastSyncedAt"), "created": self.clock(), "updatedAt": utc(),
                 "draftVersion": 0, "attempts": 0,
                 "draft": {"draftVersion": 0, "insertPages": [], "pageEdits": []},
                 "outputMode": "companion" if self.companion(doc)["enabled"] else "page_only"}
            self.store.save_request(r)
            await self.push_sync(r)
            return self.receipt(r)

    def _terminal_status(self, r):
        expired = (r["status"] == "awaiting_sync" and not r.get("waitUntilOpen") and self.clock()-r["created"] >= 10) or (
            r["status"] == "synchronizing" and self.clock() >= r["syncDeadline"])
        if expired:
            r.update(status="needs_stale_choice", updatedAt=utc())
            self.store.save_request(r)
        return self.receipt(r)

    async def terminal_status(self, r):
        async with self.lock(r["requestID"]):
            return self._terminal_status(self.store.request(r["requestID"]))

    async def sync_started(self, rid, body):
        async with self.lock(rid):
            require(isinstance(body, dict) and set(body) == {"clientID"}, "invalid_sync_ack", "Expected clientID acknowledgement")
            r = self.store.request(rid)
            cid = uuid(body.get("clientID"))
            self.registered(cid)
            require(r["origin"] == "terminal" and (r.get("clientID") == cid or r.get("claimClientID") == cid),
                    "client_binding", "Only the associated foreground installation may start Sync", 409)
            self._terminal_status(r)
            if r.get("claimClientID") == cid:
                require(self.clock() < (r["syncDeadline"] if r.get("syncStarted") else r["claimCreated"]+10),
                        "freshness_consent_required", "Expired claim requires an explicit new claim", 409)
            if r.get("syncStarted"):
                require(r["syncStarted"] == body, "receipt_collision", "Sync start acknowledgement differs", 409)
                return self._terminal_status(r)
            require(cid in self.channels, "foreground_required", "Sync-started requires an active foreground channel", 409)
            claiming = r["status"] == "ready" and r.get("claimClientID") == cid
            require(r["status"] == "awaiting_sync" or claiming,
                    "request_state", "Request is not awaiting Sync", 409)
            now = self.clock()
            r.update(syncStarted=body, syncStartedAt=datetime.fromtimestamp(now, timezone.utc).isoformat().replace("+00:00", "Z"),
                     syncDeadline=now+300, syncDeadlineAt=datetime.fromtimestamp(now+300, timezone.utc).isoformat().replace("+00:00", "Z"),
                     updatedAt=utc())
            if not claiming:
                r["status"] = "synchronizing"
                r.pop("waitUntilOpen", None)
            self.store.save_request(r)
            return self.receipt(r)

    async def push_sync(self, r):
        sender = self.channels.get(r.get("claimClientID") or r.get("clientID"))
        if sender:
            command = {"kind": "sync_document", "requestID": r["requestID"], "documentID": r["documentID"]}
            if r.get("focusPageID") is not None:
                command["focusPageID"] = r["focusPageID"]
            try:
                await sender(command)
            except (ConnectionError, RuntimeError):
                cid = r.get("claimClientID") or r.get("clientID")
                if self.channels.get(cid) == sender:
                    self.channels.pop(cid, None)

    async def open_channel(self, cid, sender):
        self.registered(cid)
        require(cid not in self.channels, "channel_busy", "Installation already has a foreground channel", 409)
        self.channels[cid] = sender
        # Opening Draw is not renewed permission for an abandoned terminal ask.
        for prior in self.store.requests():
            async with self.lock(prior["requestID"]):
                r = self.store.request(prior["requestID"])
                self._terminal_status(r)
                eligible = r["status"] == "awaiting_sync"
                if eligible and r.get("clientID") is None and len(self.channels) == 1:
                    r.update(clientID=cid, updatedAt=utc())
                    self.store.save_request(r)
                if eligible and r.get("clientID") == cid:
                    await self.push_sync(r)
                # A live claim was itself explicit consent, but is bounded too.
                elif r.get("claimClientID") == cid and self.clock()-r["claimCreated"] < 10:
                    await self.push_sync(r)

    async def sync_ready(self, rid, body):
        require(isinstance(body, dict) and set(body) == {"clientID", "syncID", "contextSHA256"}, "invalid_sync_ack", "Expected clientID, syncID and contextSHA256")
        async with self.lock(rid):
            r = self.store.request(rid)
            cid, sid = uuid(body.get("clientID")), uuid(body.get("syncID"))
            self.registered(cid)
            require(r["origin"] == "terminal" and (r.get("clientID") == cid or r.get("claimClientID") == cid),
                    "client_binding", "Only the associated foreground installation may acknowledge Sync", 409)
            if r.get("syncReady"):
                require(r["syncReady"] == body, "receipt_collision", "Sync acknowledgement already differs", 409)
                return self.receipt(r)
            self._terminal_status(r)
            if r.get("claimClientID") == cid:
                require(self.clock() < (r["syncDeadline"] if r.get("syncStarted") else r["claimCreated"]+10),
                        "freshness_consent_required", "Expired claim requires an explicit new claim", 409)
            require(r["status"] in ("awaiting_sync", "synchronizing") or (r["status"] == "ready" and r.get("claimClientID") == cid), "request_state", "Request is not awaiting Sync", 409)
            require(self.source is not None, "sync_unavailable", "Sync receipt verification unavailable", 409)
            receipt = await self.source.sync_receipt(sid)
            require(receipt.get("documentID") == r["documentID"] and receipt.get("syncID") == sid,
                    "sync_document", "Sync receipt belongs to another document", 409)
            sha(receipt.get("documentDigest"))
            require(check.timestamp(receipt.get("lastSyncedAt")) >= r.get("claimCreated", r["created"])-2,
                    "sync_not_fresh", "Sync confirmation predates this terminal intent; perform document Sync again", 409)
            ctx = self.validate_context(body.get("contextSHA256"), r["documentID"], r.get("focusPageID"))
            # Preserve the receipt's A identity even if source/native state advanced to B.
            # No fetch of latest source and no native archive copies into Notes CAS.
            source_pin = {k: receipt[k] for k in ("documentID", "documentDigest", "syncID", "revision")}
            if r.get("claimClientID") == cid:
                r.update(clientID=cid, syncReady=body, claimSyncReceipt=receipt, updatedAt=utc())
                r.pop("claimClientID", None)
                self.store.save_request(r)
                return self.receipt(r)
            r.update(contextSHA256=body["contextSHA256"], focusPageID=ctx["focusPageID"],
                     status="queued", syncReady=body, syncReceipt=receipt, sourcePin=source_pin,
                     lastSyncedAt=receipt.get("lastSyncedAt"), updatedAt=utc())
            self.pin_context(r, ctx)
            self.store.save_request(r)
            return self.receipt(r)

    async def claim(self, rid, body):
        async with self.lock(rid):
            r = self.store.request(rid)
            cid = uuid(body.get("clientID"))
            self.registered(cid)
            require(r["origin"] == "terminal" and r["status"] == "ready" and r.get("clientID") is None,
                    "client_binding", "Only unbound terminal results may be explicitly claimed", 409)
            require(cid in self.channels, "foreground_required", "Explicit claim requires a foreground channel", 409)
            require(r.get("claimClientID") in (None, cid), "client_binding", "Another installation is already claiming this result", 409)
            r.update(claimClientID=cid, claimCreated=self.clock(), updatedAt=utc())
            for key in ("syncStarted", "syncStartedAt", "syncDeadline", "syncDeadlineAt"):
                r.pop(key, None)
            self.store.save_request(r)
            await self.push_sync(r)
            return self.receipt(r)

    async def stale_choice(self, rid, body):
        async with self.lock(rid):
            r = self.store.request(rid)
            self._terminal_status(r)
            choice = body.get("choice")
            require(not (r["status"] == "synchronizing" and choice != "cancel"),
                    "sync_in_progress", "Foreground app is actively synchronizing; no stale fallback while its bounded Sync window is active", 409)
            require(r["origin"] == "terminal" and r["status"] in ("awaiting_sync", "synchronizing", "needs_stale_choice"), "request_state", "No pending stale choice", 409)
            require(choice in ("use_synced", "wait", "cancel"), "invalid_choice", "Unsupported stale choice")
            if choice == "cancel":
                r.update(status="failed", error={"code": "cancelled", "message": "Cancelled by user"})
            elif choice == "wait":
                r.update(status="awaiting_sync", created=self.clock(), waitUntilOpen=True, freshnessChoice="wait")
                for key in ("syncStarted", "syncStartedAt", "syncDeadline", "syncDeadlineAt"):
                    r.pop(key, None)
                clients = list(self.channels)
                if r.get("clientID") is None and len(clients) == 1:
                    r["clientID"] = clients[0]
                r["updatedAt"] = utc()
                self.store.save_request(r) # Consent survives a closing websocket or process crash.
                await self.push_sync(r)
            else:
                require(self.source is not None, "sync_unavailable", "Synced source unavailable", 409)
                ctx = await self.source.stale_context(r["documentID"], r.get("focusPageID"), self.store)
                require(ctx.get("nativeLayerUnavailable") is True, "invalid_context", "Stale context must disclose absent native layers")
                check.context(ctx, self.store.read_asset, r["documentID"], r.get("focusPageID"))
                digest = self.store.put_bytes(encoded(ctx))
                r.update(contextSHA256=digest, focusPageID=ctx["focusPageID"], status="queued", staleChoice="use_synced", lastSyncedAt=ctx.get("lastSyncedAt", r.get("lastSyncedAt")))
                self.pin_context(r, ctx)
            r["updatedAt"] = utc()
            self.store.save_request(r)
            if r["status"] == "failed":
                self.release_context(r)
                self.collect_artifacts()
            return self.receipt(r)

    def worker_request(self, rid, doc, lease):
        self.worker_registry.authenticate(doc, lease)
        r = self.store.request(rid)
        require(r["documentID"] == doc, "document_scope", "Tool request belongs to another document", 409)
        require(r["status"] in ("running", "queued"), "request_state", "Request is not writable", 409)
        if r["status"] == "queued":
            # Terminal-origin tool can join the current human turn without a second injected turn.
            require(r["origin"] == "terminal", "request_state", "App request requires worker delivery lease", 409)
            r.update(status="running", workerSessionID=self.worker_registry.get(doc)["sessionID"], updatedAt=utc())
            self.store.save_request(r)
        require(r.get("workerSessionID") == self.worker_registry.get(doc)["sessionID"], "worker_identity", "Request was delivered to another session", 409)
        return r

    def lease_request(self, doc, lease, body):
        worker = self.worker_registry.heartbeat(doc, lease, body)
        require(not worker["busy"] and not worker["pending"], "worker_busy", "Worker is not settled/idle", 409)
        if worker.get("shutdownRequested"):
            return {"shutdown": True}
        pending = self.store.requests(doc, {"queued"})
        if not pending:
            return {"request": None}
        r = min(pending, key=lambda r: r["created"])
        r.update(status="running", workerSessionID=worker["sessionID"], deliveryID=str(uuid4()).upper(), updatedAt=utc())
        self.store.save_request(r)
        worker.update(pending=True, activeRequestID=r["requestID"], lastActivity=self.clock())
        self.worker_registry.save(worker)
        return {"request": {**self.receipt(r), "contextSHA256": r["contextSHA256"],
                            "focusPageID": r["focusPageID"], "outputMode": r["outputMode"],
                            "deliveryID": r["deliveryID"], "prompt": r.get("prompt", self.app_prompt(r))}}

    def app_prompt(self, r):
        return "Help with the questions or unfinished material on the captured focus page."

    async def worker_heartbeat(self, doc, lease, body):
        settlement = body.get("settlement")
        result = None
        if settlement is not None:
            require(isinstance(settlement, dict) and settlement.get("event") == "agent_settled" and settlement.get("eventID") is not None,
                    "invalid_event", "Expected critical settlement marker")
            result = await self.worker_event(doc, lease, {**settlement, "activity": body})
        # The critical event applies fresh activity once. Its duplicate must never apply an old idle snapshot.
        worker = self.worker_registry.authenticate(doc, lease) if settlement else self.worker_registry.heartbeat(doc, lease, body)
        return {"ok": True, "shutdown": worker.get("shutdownRequested", False),
                "companion": self.companion(doc)["enabled"],
                **({"settlementID": result["settlementID"]} if result else {})}

    async def worker_event(self, doc, lease, body):
        worker = self.worker_registry.authenticate(doc, lease)
        event, rid = body.get("event"), body.get("requestID")
        event_id = body.get("eventID")
        if event_id is not None:
            uuid(event_id)
            require(event == "agent_settled" and rid is not None, "invalid_event", "Critical settlement requires a request")
            proof = {"eventID": event_id, "event": event, "documentID": doc, "requestID": uuid(rid),
                     "sessionID": worker["sessionID"], "deliveryID": body.get("deliveryID"), "recovered": body.get("recovered") is True}
            if proof["deliveryID"] is not None:
                uuid(proof["deliveryID"])
            async with self.lock(rid):
                worker = self.worker_registry.authenticate(doc, lease)
                previous = self.store.record("worker_settlement", event_id)
                if previous is not None:
                    require(previous == proof, "event_collision", "Settlement identity changed", 409)
                    # A lost ACK retry cannot change a newer turn's activity or delivery.
                    return {"ok": True, "settlementID": event_id}
                r = self.store.request(rid)
                require(r["documentID"] == doc, "document_scope", "Request/document mismatch", 409)
                require(r.get("workerSessionID") == worker["sessionID"] and r.get("deliveryID") == proof["deliveryID"],
                        "worker_identity", "Settlement must identify the exact delivered request", 409)
                activity = body.get("activity")
                require(isinstance(activity, dict) and isinstance(activity.get("busy"), bool) and isinstance(activity.get("pending"), bool),
                        "invalid_event", "Settlement requires current activity")
                if r["status"] == "running":
                    interrupted = proof["recovered"]
                    r.update(status="interrupted" if interrupted else "failed",
                             error={"code": "delivery_uncertain" if interrupted else "page_output_missing",
                                    "message": "Worker ended without approved page output"}, updatedAt=utc())
                    self.store.save_request(r)
                    if not interrupted:
                        self.release_context(r)
                if worker.get("activeRequestID") in (None, rid):
                    self.worker_registry.activity(doc, lease, "tool_end")
                    self.worker_registry.heartbeat(doc, lease, activity)
                self.store.save_record("worker_settlement", event_id, proof)
                if r["status"] == "failed":
                    self.collect_artifacts()
            return {"ok": True, "settlementID": event_id}
        if rid and event in ("agent_settled", "shutdown"):
            async with self.lock(rid):
                r = self.store.request(rid)
                require(r["documentID"] == doc, "document_scope", "Request/document mismatch", 409)
                self.worker_registry.activity(doc, lease, event)
                if r["status"] == "running":
                    r.update(status="failed" if event == "agent_settled" else "interrupted",
                             error={"code": "page_output_missing" if event == "agent_settled" else "delivery_uncertain",
                                    "message": "Worker ended without approved page output"}, updatedAt=utc())
                    self.store.save_request(r)
                    if r["status"] == "failed":
                        self.release_context(r)
                        self.collect_artifacts()
        elif event == "agent_settled" and isinstance(body.get("activity"), dict):
            self.worker_registry.activity(doc, lease, "tool_end")
            self.worker_registry.heartbeat(doc, lease, body["activity"])
        else:
            self.worker_registry.activity(doc, lease, event)
        return {"ok": True}

    async def activate(self, rid, body, doc, lease):
        async with self.lock(rid):
            return self.receipt(self.worker_request(rid, doc, lease))

    async def draft(self, rid, body, doc, lease):
        async with self.lock(rid):
            r = self.worker_request(rid, doc, lease)
            require(type(body.get("expectedDraftVersion")) is int and body["expectedDraftVersion"] == r["draftVersion"], "draft_conflict", "Draft version changed", 409)
            require(set(body) <= {"expectedDraftVersion", "insertPages", "pageEdits"}, "invalid_draft", "Unknown draft fields")
            value = check.draft(body, self.context(r))
            version = r["draftVersion"] + 1
            # Insertion/add IDs stay fixed across revisions/retries once first introduced.
            known = r.get("generatedIDs", {})
            current = {"pages": [p["pageID"] for p in value["insertPages"]],
                       "objects": [op["object"]["id"] for e in value["pageEdits"] for op in e.get("objectEdits", []) if op["op"] == "add"]}
            if known:
                previous = r.get("previousGeneratedIDs", known)
                for kind in ("pages", "objects"):
                    added = set(current[kind]) - set(known[kind])
                    require(not added or set(previous[kind]) <= set(current[kind]), "generated_identity", "Do not replace existing generated IDs across retries", 409)
            combined = {kind: sorted(set(known.get(kind, [])) | set(current[kind])) for kind in ("pages", "objects")}
            r.update(draftVersion=version, draft={**value, "draftVersion": version}, generatedIDs=combined, previousGeneratedIDs=current, updatedAt=utc())
            r.pop("render", None)
            self.store.save_request(r)
            return {"draftVersion": version}

    async def render(self, rid, body, doc, lease):
        async with self.lock(rid):
            r = self.worker_request(rid, doc, lease)
            version = body.get("draftVersion")
            require(type(version) is int and version == r["draftVersion"] and version > 0, "draft_conflict", "Render must use current draft version", 409)
            require(set(body) <= {"draftVersion", "renderID"}, "invalid_render", "Unknown render fields")
            render_id = uuid(body["renderID"]) if body.get("renderID") else str(uuid4()).upper()
            history = r.setdefault("renders", {})
            if render_id in history:
                require(history[render_id]["draftVersion"] == version, "render_collision", "Render ID already used for another draft", 409)
                require(history[render_id].get("response") is not None, "render_failed", "This render attempt failed; use a new render ID", 409)
                return history[render_id]["response"]
            require(r["attempts"] < 3, "render_budget", "Three render attempts exhausted", 409)
            r["attempts"] += 1
            history[render_id] = {"draftVersion": version, "attempt": r["attempts"]}
            self.store.save_request(r)  # failure/crash consumes budget before renderer starts
            try:
                ctx = self.context(r)
                method = self.renderer.render
                if inspect.iscoroutinefunction(method):
                    output = await method(ctx, r["draft"], rid, r["contextSHA256"])
                else:
                    output = await asyncio.to_thread(method, ctx, r["draft"], rid, r["contextSHA256"])
                    if inspect.isawaitable(output):
                        output = await output
                require(isinstance(output, dict), "renderer_invalid", "Renderer returned invalid result")
                for digest, data in output["assets"].items():
                    check.png(data)
                    self.store.put_asset(digest, data)
                    r["renderAssets"] = sorted(set(r.get("renderAssets", [])) | {digest})
                    self.store.pin([digest])
                previews = []
                for pid, data in output["previews"].items():
                    uuid(pid)
                    check.png(data)
                    digest = self.store.put_bytes(data)
                    r["renderAssets"] = sorted(set(r.get("renderAssets", [])) | {digest})
                    self.store.pin([digest])
                    previews.append({"pageID": pid, "sha256": digest, "path": str(self.store.path(digest))})
                expected = {e["pageID"] for e in r["draft"]["pageEdits"]} | {p["pageID"] for p in r["draft"]["insertPages"]}
                require(expected and {p["pageID"] for p in previews} == expected, "preview_integrity", "Renderer must return every affected page preview")
                require(output["insertPages"] == r["draft"]["insertPages"], "renderer_invalid", "Renderer changed insertion identities")
                # Resolved operation lists are checked against the captured draft identities.
                self.validate_rendered(r, output)
                hashes = {p["pageID"]: p["sha256"] for p in previews}
                result = {"format": 1, "requestID": rid, "documentID": doc,
                          "contextSHA256": r["contextSHA256"], "draftVersion": version,
                          "rendererSignature": output["rendererSignature"], "insertPages": output["insertPages"],
                          "pageEdits": output["pageEdits"], "previewSHA256s": hashes}
                result_bytes = encoded(result)
                require(len(result_bytes) <= MAX_METADATA, "metadata_limit", "Approved result exceeds 4 MiB", 413)
                digest = self.store.put_bytes(result_bytes)
                r["renderAssets"] = sorted(set(r.get("renderAssets", [])) | {digest})
                self.store.pin([digest])
                response = {"draftVersion": version, "renderID": render_id, "attempt": r["attempts"],
                            "previews": previews, "objects": output["objects"]}
                if ctx.get("nativeLayerUnavailable"):
                    response["warning"] = "stale/native-layer-unavailable; synced server preview"
                r["render"] = {"renderID": render_id, "draftVersion": version, "resultSHA256": digest,
                               "previewSHA256s": hashes, "response": response}
                history[render_id]["response"] = response
                r["updatedAt"] = utc()
                self.store.save_request(r)
                return response
            except Exception as error:
                # Do not log renderer exception text: it can contain user content, paths or tokens.
                history[render_id]["failed"] = True
                self.store.save_request(r)
                if isinstance(error, Problem):
                    raise
                raise Problem("render_failed", "Renderer could not safely complete this attempt") from None

    def validate_rendered(self, r, output):
        require(isinstance(output.get("rendererSignature"), str) and output["rendererSignature"], "renderer_invalid", "Missing renderer signature")
        requested, resolved = r["draft"]["pageEdits"], output["pageEdits"]
        require(len(requested) == len(resolved), "renderer_invalid", "Renderer changed page edits")
        has_write = False
        rendered_objects = []
        captured = {o["id"]: o for p in self.context(r)["pages"] for o in p["objects"]}
        for draft, edit in zip(requested, resolved):
            require(draft["pageID"] == edit["pageID"] and encoded(check.canonical_stroke_edits(draft.get("strokeEdits", []))) == encoded(edit.get("strokeEdits", [])), "renderer_invalid", "Renderer changed stroke/page targets")
            has_write |= any(op["op"] != "keep" for op in edit.get("strokeEdits", []))
            ops = edit.get("objectEdits", [])
            require(len(draft.get("objectEdits", [])) == len(ops), "renderer_invalid", "Renderer changed operations")
            for source, op in zip(draft.get("objectEdits", []), ops):
                require(isinstance(op, dict) and op.get("op") in ("add", "replace", "remove"),
                        "renderer_invalid", "Unsupported resolved object operation")
                fields = {"op", "object"} if op["op"] == "add" else {"op", "objectID", "expectedRevision", "expectedObject"} | ({"object"} if op["op"] == "replace" else set())
                require(set(op) == fields, "renderer_invalid", "Unexpected or missing resolved operation fields")
                require(source["op"] == op["op"] and source.get("objectID") == op.get("objectID") and source.get("expectedRevision") == op.get("expectedRevision"), "renderer_invalid", "Renderer changed target identity")
                if op["op"] != "add":
                    require(isinstance(op["expectedObject"], dict) and op["objectID"] in captured,
                            "renderer_invalid", "Expected object must identify a captured object")
                    try:
                        exact = encoded(op["expectedObject"]) == encoded(captured[op["objectID"]])
                    except (TypeError, ValueError):
                        exact = False
                    require(exact, "renderer_invalid", "Expected object must preserve the exact captured JSON metadata")
                has_write = True
                if op["op"] != "remove":
                    obj = op["object"]
                    check.object_spec(obj, self.store.read_asset)
                    require(all(obj[k] == source["object"][k] for k in ("id", "kind", "source")), "renderer_invalid", "Renderer changed object source/identity")
                    expected_revision = 1 if op["op"] == "add" else captured[obj["id"]]["revision"]+1
                    require(obj["revision"] == expected_revision and obj["provenance"] == {"requestID": r["requestID"], "contextSHA256": r["contextSHA256"], "rendererSignature": output["rendererSignature"]}, "renderer_invalid", "Renderer provenance/revision mismatch")
                    if op["op"] == "replace" and check.object_translation(source["object"], captured[obj["id"]]):
                        old = captured[obj["id"]]
                        expected = {**old, "revision": expected_revision, "provenance": obj["provenance"],
                            "frame": {**old["frame"], **{key: round(source["object"]["frame"][key]*2)/2 for key in ("x", "y")}}}
                        require(encoded(obj) == encoded(expected), "renderer_invalid", "Position-only replacement must preserve captured pixels and metadata")
                    require(obj["frame"]["width"] > 0 and obj["frame"]["height"] > 0, "page_output_missing", "Generated answer has no visible area")
                    rendered_objects.append(obj)
        require(has_write, "page_output_missing", "Result requires a write operation")
        require(output["objects"] == rendered_objects, "renderer_invalid", "Resolved object list mismatch")

    async def approve(self, rid, body, doc, lease):
        async with self.lock(rid):
            self.worker_registry.authenticate(doc, lease)
            r = self.store.request(rid)
            require(r["documentID"] == doc, "document_scope", "Request/document mismatch", 409)
            if r["status"] == "applied":
                approval = r.get("approval", {})
                hashes = body.get("inspectedPreviewSHA256s")
                require(body.get("draftVersion") == approval.get("draftVersion") and body.get("renderID") == approval.get("renderID") and
                        isinstance(hashes, list) and all(isinstance(h, str) for h in hashes) and
                        sorted(hashes) == approval.get("previewSHA256s"), "approval_conflict", "Approval does not match the retired approved output", 409)
                return self.receipt(r)
            render = r.get("render")
            require(render and body.get("draftVersion") == r["draftVersion"] == render["draftVersion"] and
                    body.get("renderID") == render["renderID"], "approval_conflict", "Approval must name latest successful rendered draft", 409)
            hashes = body.get("inspectedPreviewSHA256s")
            require(isinstance(hashes, list) and all(isinstance(s, str) for s in hashes) and
                    set(hashes) == set(render["previewSHA256s"].values()) and len(hashes) == len(set(hashes)),
                    "preview_integrity", "Inspect every exact rendered preview before approval", 409)
            require(r["status"] in ("running", "ready", "applied"), "request_state", "Request cannot be approved", 409)
            if r["status"] == "running":
                # Verify exact persisted bytes and every PNG again before publication.
                self.store.read_asset(render["resultSHA256"])
                for digest in render["previewSHA256s"].values():
                    self.store.read_asset(digest)
                r.update(status="ready", resultSHA256=render["resultSHA256"], updatedAt=utc(),
                         approval={"draftVersion": r["draftVersion"], "renderID": render["renderID"], "previewSHA256s": sorted(hashes)})
                self.store.save_request(r)
            return self.receipt(r)

    def read_metadata(self, ctx, pages, view, rect=None):
        summary = {key: value for key, value in ctx.items() if key != "pages"}
        page_numbers = {page["pageID"]: index+1 for index, page in enumerate(ctx["pages"])}
        scoped = []
        for page in pages:
            entry = {"pageID": page["pageID"], "head": page.get("head"),
                     "background": page["background"], "width": page["width"], "height": page["height"]}
            entry.update(pageNumber=page_numbers[page["pageID"]], objectCount=len(page["objects"]),
                         strokeTargetCount=len(page["strokeTargets"]))
            if view != "overview":
                scene = decoded(self.store.read_asset(page["portableSHA256"]), limit=MAX_ASSET)
                strokes = scene["strokes"]
                targets, question_count, unlocated = [], 0, 0
                for target in page["strokeTargets"]:
                    rgba = strokes[target["index"]]["color"] if target["index"] < len(strokes) else None
                    # Same exact 8-bit palette test as native QuestionInk.matches, including opacity.
                    question = rgba is not None and all(abs(component-wanted) < 0.5/255 for component, wanted in zip(rgba, (175/255, 82/255, 222/255, 1)))
                    question_count += int(question)
                    frame = target.get("frame")
                    unlocated += int(frame is None)
                    if view == "page" and not question:
                        continue
                    if view == "crop" and (frame is None or not (
                            frame["x"] < rect["x"]+rect["width"] and frame["x"]+frame["width"] > rect["x"] and
                            frame["y"] < rect["y"]+rect["height"] and frame["y"]+frame["height"] > rect["y"])):
                        continue
                    item = {key: target[key] for key in ("id", "fingerprint", "index")}
                    if frame is not None:
                        item["frame"] = frame
                    item.update(color=rgba, questionInk=question)
                    if rgba is not None:
                        item["colorHex"] = "#"+"".join(f"{round(component*255):02X}" for component in rgba[:3])
                    targets.append(item)
                targets.sort(key=lambda target: (not target["questionInk"], target["index"]))
                entry.update(questionStrokeTargetCount=question_count, unlocatedStrokeTargetCount=unlocated,
                             returnedStrokeTargetCount=len(targets), strokeTargets=targets, objects=page["objects"],
                             portableSHA256=page["portableSHA256"])
            scoped.append(entry)
        summary["pages"] = scoped
        return summary

    async def read(self, rid, body, doc, lease):
        async with self.lock(rid):
            r = self.worker_request(rid, doc, lease)
            ctx = self.context(r)
            view = body.get("view")
            require(view in ("overview", "page", "crop"), "invalid_view", "Unsupported read view")
            pages = ctx["pages"]
            if view != "overview":
                pid = uuid(body.get("pageID"))
                pages = [p for p in pages if p["pageID"] == pid]
                require(pages, "not_found", "Page is not captured", 404)
            rect = body.get("rect") if view == "crop" else None
            metadata = {"kind": view, "contextIsSummary": True,
                        "strokeTargets": "omitted" if view == "overview" else "question_ink_only" if view == "page" else "intersecting_crop_all_colors",
                        "coordinates": "original page points; crop coordinates are not a new origin"}
            if view != "overview":
                metadata["pageID"] = pages[0]["pageID"]
            if rect is not None:
                check.frame(rect)
                page = pages[0]
                require(rect["width"] > 0 and rect["height"] > 0 and rect["x"] >= 0 and rect["y"] >= 0 and rect["x"]+rect["width"] <= page["width"] and rect["y"]+rect["height"] <= page["height"], "invalid_crop", "Crop must lie within captured page")
                metadata["rect"] = rect
            reply = {"contextSHA256": r["contextSHA256"], "metadataScope": metadata,
                     "fullContextMetadata": {"sha256": r["contextSHA256"], "path": str(self.store.path(r["contextSHA256"]))},
                     "context": self.read_metadata(ctx, pages, view, rect),
                     "draftVersion": r["draftVersion"], "outputMode": r["outputMode"]}
            images = []
            if view == "overview":
                # Bounded actual-image contact sheets; detailed reading uses page/crop.
                for start in range(0, len(pages), 9):
                    group = pages[start:start+9]
                    columns = min(3, len(group))
                    sheet = Image.new("RGBA", (columns*256, ((len(group)+columns-1)//columns)*360), "white")
                    labels = ImageDraw.Draw(sheet)
                    for offset, page in enumerate(group):
                        with Image.open(io.BytesIO(self.store.read_asset(page["compositeSHA256"]))) as native:
                            thumbnail = native.convert("RGBA")
                            thumbnail.thumbnail((256, 336))
                            x, y = (offset%columns)*256, (offset//columns)*360
                            sheet.alpha_composite(thumbnail, (x,y+24))
                            labels.text((x+4,y+4), f'{start+offset+1} {page["pageID"][:8]}', fill="black")
                    data = io.BytesIO()
                    sheet.save(data, format="PNG")
                    digest = self.store.put_bytes(data.getvalue())
                    images.append({"pageIDs": [p["pageID"] for p in group], "sha256": digest, "path": str(self.store.path(digest))})
                r["readAssets"] = sorted(set(r.get("readAssets", [])) | {image["sha256"] for image in images})
                self.store.pin(r["readAssets"])
                self.store.save_request(r)
                return {**reply, "images": images}
            for page in pages:
                digest = page["compositeSHA256"]
                if view == "crop":
                    with Image.open(io.BytesIO(self.store.read_asset(digest))) as image:
                        cropped = image.crop(tuple(round(v*2) for v in (rect["x"], rect["y"], rect["x"]+rect["width"], rect["y"]+rect["height"])))
                        data = io.BytesIO()
                        cropped.save(data, format="PNG")
                        digest = self.store.put_bytes(data.getvalue())
                images.append({"pageID": page["pageID"], "sha256": digest, "path": str(self.store.path(digest))})
            r["readAssets"] = sorted(set(r.get("readAssets", [])) | {image["sha256"] for image in images})
            self.store.pin(r["readAssets"])
            self.store.save_request(r)
            return {**reply, "images": images}

    async def retry(self, rid, body):
        async with self.lock(rid):
            r = self.store.request(rid)
            require(body == {"choice": "resume"}, "explicit_retry", "Explicit resume choice required")
            require(r["status"] == "interrupted", "request_state", "Only interrupted requests can be resumed", 409)
            self.worker_registry.get(r["documentID"])
            require(not self.store.requests(r["documentID"], ACTIVE), "document_busy", "Document is busy", 409)
            r.update(status="queued", updatedAt=utc())
            r.pop("error", None)
            self.store.save_request(r)
            return self.receipt(r)

    async def refresh_worker_labels(self):
        if not self.source:
            return
        if hasattr(self.source, "folders"):
            protected = {}
            for worker in self.store.records("worker"):
                guard = worker.get("capturedLabelProvenance")
                fid = guard["labels"].get("folderID") if guard else None
                if fid and "folder" in guard.get("fields", ("folder", "name", "folderID")) and (fid not in protected or check.timestamp(guard["capturedAt"]) > check.timestamp(protected[fid]["capturedAt"])):
                    protected[fid] = guard
            folders = await self.source.folders()
            paths = check.folder_paths(folders)
            for folder in folders:
                label = paths[folder["id"]]
                if folder["id"] in protected and label != protected[folder["id"]]["labels"]["folder"]:
                    continue
                name = self.worker_registry.folder_directory(label, uuid(folder["id"]))
                (self.worker_registry.workspace / name).mkdir(parents=True, exist_ok=True, mode=0o700)
        for worker in self.store.records("worker"):
            doc = worker["documentID"]
            try:
                labels = await self.source_labels(doc)
                check.labels(labels)
                worker = self.worker_registry.get(doc)
                if not self.accept_source_labels(worker, labels):
                    continue
                target = self.label_target(labels)
                if worker.get("folderName") == target["folder"] and worker.get("noteName") == target["name"] and worker.get("folderID") == target["folderID"]:
                    # Accepted source labels may revert a deferred rename while still busy.
                    if worker.pop("renamePending", None) is not None:
                        self.worker_registry.save(worker)
                    continue
                # Label/cwd movement is deferred through the extension's graceful shutdown,
                # not by killing a pane or reopening a different/most-recent conversation.
                worker["renamePending"] = target
                self.worker_registry.save(worker)
            except Problem:
                continue

    async def maintenance(self, spawn_workers=False):
        if self.clock()-self.last_collection >= 60:
            self.last_collection = self.clock()
            self.collect_artifacts()
            await self.confirm_outputs()
            self.collect_artifacts()
        for r in self.store.requests(statuses={"awaiting_sync", "synchronizing"}):
            await self.terminal_status(r)
        if spawn_workers:
            for worker in self.store.records("worker"):
                if worker.get("relocation"):
                    try:
                        self.worker_registry.finish_relocation(worker)
                    except Problem as error:
                        self.store.save_record("worker_error", worker["documentID"], {"code": error.code, "message": error.message})
        if spawn_workers and self.clock()-self.last_label_refresh >= 60:
            self.last_label_refresh = self.clock()
            await self.refresh_worker_labels()
        for r in self.store.requests(statuses={"running"}):
            worker = self.worker_registry.get(r["documentID"])
            if worker.get("lease") is None or self.clock()-worker["heartbeat"] > HEARTBEAT_SECONDS:
                async with self.lock(r["requestID"]):
                    current = self.store.request(r["requestID"])
                    if current["status"] == "running":
                        current.update(status="interrupted", error={"code": "delivery_uncertain", "message": "Worker bridge lease lost; reconcile before explicit retry"}, updatedAt=utc())
                        self.store.save_request(current)
        for worker in self.store.records("worker"):
            doc = worker["documentID"]
            pending = bool(self.store.requests(doc, ACTIVE))
            if spawn_workers and worker.get("renamePending") and not pending:
                target = worker["renamePending"]
                if self.worker_registry.pane_owned(worker):
                    if (worker.get("lease") and self.clock()-worker["heartbeat"] <= HEARTBEAT_SECONDS and
                            not worker["busy"] and not worker["pending"] and worker.get("inputObserved")):
                        worker["shutdownRequested"] = True
                        self.worker_registry.save(worker)
                elif worker.get("lease") is None and not worker["busy"] and not worker["pending"]:
                    try:
                        moved = self.worker_registry.relocate(doc, target["folder"], target["name"], target.get("folderID"))
                        moved.pop("renamePending", None)
                        self.worker_registry.save(moved)
                    except Problem as error:
                        self.store.save_record("worker_error", doc, {"code": error.code, "message": error.message})
                continue
            if spawn_workers and self.store.requests(doc, {"queued"}):
                try:
                    self.worker_registry.spawn(doc)
                except Problem as e:
                    self.store.save_record("worker_error", doc, {"code": e.code, "message": e.message})
            if spawn_workers:
                self.worker_registry.request_idle_shutdown(doc, pending)
