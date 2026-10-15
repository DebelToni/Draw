import asyncio
import copy
import hashlib
import tempfile
import unittest
from pathlib import Path
from notes_service.manager import Manager
from notes_service.storage import Problem, encoded, utc
from notes_service import validation as check
from notes_service.tests.fixtures import Source, Renderer, context, draft, uid, image


class AuditTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.now = 1000.0
        self.renderer, self.source = Renderer(), Source()
        self.m = Manager(self.root/"state", self.renderer, self.source, clock=lambda: self.now)
        self.doc, self.page, self.rid, self.cid = uid(), uid(), uid(), uid()
        self.m.register_client({"clientID": self.cid})
        self.ctx, self.digest = context(self.m, self.doc, self.page)
        self.body = {"requestID": self.rid, "documentID": self.doc, "focusPageID": self.page,
                     "contextSHA256": self.digest, "origin": "app", "clientID": self.cid}
        self.sent = []

    async def asyncTearDown(self):
        self.m.close(); self.temp.cleanup()

    async def sender(self, value):
        self.sent.append(value)

    async def terminal(self):
        await self.m.open_channel(self.cid, self.sender)
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write", "focusPageID": self.page})
        self.sent.clear()

    async def start(self):
        await self.m.create_request(self.body)
        worker = self.m.worker_registry.get(self.doc)
        registered = self.m.worker_registry.register({"documentID": self.doc, "sessionID": worker["sessionID"],
            "spawnNonce": worker["spawnNonce"], "sessionFile": str(self.root/"fixture.jsonl"),
            "cwd": worker["cwd"], "busy": False, "pending": False, "inputObserved": True})
        self.lease = registered["lease"]
        self.m.lease_request(self.doc, self.lease, {"busy": False, "pending": False, "inputObserved": True})

    async def approved(self, inspect=False):
        await self.start()
        await self.m.draft(self.rid, draft(self.page), self.doc, self.lease)
        rendered = await self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease)
        if inspect:
            value = await self.m.read(self.rid, {"view": "crop", "pageID": self.page, "rect": {"x":0,"y":0,"width":4,"height":4}}, self.doc, self.lease)
            self.inspected = value["images"][0]["sha256"]
        await self.m.approve(self.rid, {"draftVersion": 1, "renderID": rendered["renderID"],
            "inspectedPreviewSHA256s": [p["sha256"] for p in rendered["previews"]]}, self.doc, self.lease)
        return self.m.store.request(self.rid)

    async def apply(self, request):
        receipt = {"requestID": self.rid, "resultSHA256": request["resultSHA256"], "appliedAt": utc(),
                   "skippedObjectTargets": [], "skippedStrokeTargets": []}
        body = {"clientID": self.cid, "receipt": receipt}
        await self.m.applied(self.rid, body)
        return body

    async def test_bound_expired_reconnect_is_inert_even_without_status_poll(self):
        await self.terminal()
        self.m.channels.clear()
        self.now += 10
        await self.m.open_channel(self.cid, self.sender)
        self.assertEqual(self.sent, [])
        self.assertEqual(self.m.store.request(self.rid)["status"], "needs_stale_choice")
        with self.assertRaises(Problem):
            await self.m.sync_started(self.rid, {"clientID": self.cid})
        sid = uid(); self.source.receipts[sid] = {**self.source.state, "syncID": sid, "documentID": self.doc}
        with self.assertRaises(Problem):
            await self.m.sync_ready(self.rid, {"clientID": self.cid, "syncID": sid, "contextSHA256": self.digest})
        self.assertNotIn(("receipt", sid), self.source.calls)
        self.assertEqual(self.m.store.requests(self.doc, {"queued", "running"}), [])

    async def test_unexpired_reconnect_carries_requested_focus(self):
        await self.terminal()
        self.m.channels.clear(); self.now += 9.999
        await self.m.open_channel(self.cid, self.sender)
        self.assertEqual(self.sent, [{"kind": "sync_document", "requestID": self.rid, "documentID": self.doc, "focusPageID": self.page}])

    async def test_explicit_wait_survives_hours_until_open_then_has_bounded_sync(self):
        await self.terminal()
        self.m.channels.clear(); self.now += 10
        await self.m.stale_choice(self.rid, {"choice": "wait"})
        self.now += 7200
        await self.m.maintenance()
        self.assertEqual(self.m.store.request(self.rid)["status"], "awaiting_sync")
        await self.m.open_channel(self.cid, self.sender)
        self.assertEqual(len(self.sent), 1)
        await self.m.sync_started(self.rid, {"clientID": self.cid})
        self.now += 300
        await self.m.terminal_status(self.m.store.request(self.rid))
        self.m.channels.clear(); self.sent.clear()
        await self.m.open_channel(self.cid, self.sender)
        self.assertEqual(self.sent, [])
        self.assertEqual(self.m.store.request(self.rid)["status"], "needs_stale_choice")

    async def test_active_sync_reconnect_does_not_duplicate_sync_upload(self):
        await self.terminal()
        await self.m.sync_started(self.rid, {"clientID": self.cid})
        self.m.channels.clear(); self.now += 25
        await self.m.open_channel(self.cid, self.sender)
        self.assertEqual(self.sent, [])
        self.assertEqual(self.m.store.request(self.rid)["status"], "synchronizing")

    async def test_wait_consent_survives_failed_channel_send_and_reconnect(self):
        await self.terminal(); self.now += 10
        async def closed(value): raise ConnectionError("Closed foreground channel")
        self.m.channels[self.cid] = closed
        self.assertEqual((await self.m.stale_choice(self.rid, {"choice":"wait"}))["status"], "awaiting_sync")
        self.assertNotIn(self.cid, self.m.channels)
        self.now += 7200
        await self.m.open_channel(self.cid, self.sender)
        self.assertEqual(len(self.sent), 1)

    async def test_explicit_wait_cancel_revokes_reconnect_consent(self):
        await self.terminal()
        self.m.channels.clear(); self.now += 10
        await self.m.stale_choice(self.rid, {"choice": "wait"})
        await self.m.stale_choice(self.rid, {"choice": "cancel"})
        await self.m.open_channel(self.cid, self.sender)
        self.assertEqual(self.sent, [])

    async def test_cas_nested_native_undo_payload_rejected_before_write(self):
        for payload in ({"metadata": [{"undoHistory": {"nodes": []}}]}, {"data": {"nativeArchive": "opaque"}},
                        {"extra": {"native_snapshots": ["opaque"]}}):
            data = encoded(payload); digest = hashlib.sha256(data).hexdigest()
            with self.assertRaises(Problem): self.m.store.put_asset(digest, data)
            self.assertFalse(self.m.store.path(digest).exists())
        self.m.store.put_bytes(encoded({"metadata": {"subject": "history", "source": "normal user notes", "archive": {"title": "Reference papers"}}}))

    async def test_portable_flat_controls_allowed_unknown_nested_fields_rejected(self):
        stroke = {"inkType": "com.apple.ink.pen", "color": [0,0,0,1], "transform": [1,0,0,1,0,0],
                  "randomSeed": 0, "creationDate": 0, "points": [], "samples": [],
                  "mask": {"evenOdd": False, "commands": []}}
        scene = {"format": 1, "head": None, "width": 32, "height": 32, "strokes": [stroke]}
        self.m.store.put_bytes(encoded(scene))
        for bad in ({**scene, "extra": {"archive": []}}, {**scene, "strokes": [{**stroke, "extra": {"data": "opaque"}}]},
                    {**scene, "strokes": [{**stroke, "points": [{"geometry": []}]}]}):
            data = encoded(bad); digest = hashlib.sha256(data).hexdigest()
            with self.assertRaises(Problem): self.m.store.put_asset(digest, data)
            self.assertFalse(self.m.store.path(digest).exists())

    async def test_applied_capture_and_derived_images_released_output_and_receipt_retained(self):
        r = await self.approved(inspect=True)
        captured = set(r["contextAssets"]) | {self.inspected}
        output = r["resultSHA256"]
        body = await self.apply(r)
        retired = self.m.store.request(self.rid)
        self.assertTrue(retired["contextRetired"])
        self.assertTrue(all(self.m.store.path(d).exists() for d in captured)) # Upload lease survives publication/retirement.
        self.now += 3600
        self.m.collect_artifacts()
        self.assertTrue(all(not self.m.store.path(d).exists() for d in captured-set(retired["outputAssets"])))
        self.assertTrue(self.m.store.path(output).exists())
        self.assertEqual(retired["appliedReceipt"], body["receipt"])
        with self.assertRaises(Problem):
            await self.m.read(self.rid, {"view":"overview"}, self.doc, self.lease)
        self.assertEqual((await self.m.applied(self.rid, body))["status"], "applied")

    async def test_exact_approval_retry_after_applied_capture_gc(self):
        r = await self.approved(); await self.apply(r)
        body = {"draftVersion":1,"renderID":r["render"]["renderID"],"inspectedPreviewSHA256s":sorted(r["render"]["previewSHA256s"].values())}
        self.assertEqual((await self.m.approve(self.rid, body, self.doc, self.lease))["status"], "applied")
        body["inspectedPreviewSHA256s"] = ["f"*64]
        with self.assertRaises(Problem): await self.m.approve(self.rid, body, self.doc, self.lease)

    async def test_failed_context_and_read_artifacts_released(self):
        await self.start()
        value = await self.m.read(self.rid, {"view":"overview"}, self.doc, self.lease)
        roots = set(self.m.store.request(self.rid)["contextAssets"]) | {v["sha256"] for v in value["images"]}
        await self.m.worker_event(self.doc, self.lease, {"event":"agent_settled", "requestID":self.rid})
        self.assertEqual(self.m.store.request(self.rid)["status"], "failed")
        self.assertTrue(all(self.m.store.path(d).exists() for d in roots))
        self.now += 3600
        self.m.collect_artifacts()
        self.assertTrue(all(not self.m.store.path(d).exists() for d in roots))

    async def test_ready_and_interrupted_pin_survives_staging_expiry(self):
        r = await self.approved()
        self.now += 7200
        self.m.collect_artifacts()
        self.assertTrue(all(self.m.store.path(d).exists() for d in r["contextAssets"]+r["renderAssets"]))
        r["status"] = "interrupted"; self.m.store.save_request(r)
        self.m.collect_artifacts()
        self.assertTrue(self.m.store.path(self.digest).exists())

    async def test_shared_active_context_survives_completed_request_gc(self):
        r = await self.approved()
        doc2, page2 = uid(), uid()
        ctx2, digest2 = context(self.m, doc2, page2)
        await self.m.create_request({**self.body, "requestID":uid(), "documentID":doc2, "focusPageID":page2, "contextSHA256":digest2})
        await self.apply(r)
        self.now += 3600
        self.m.collect_artifacts()
        self.assertFalse(self.m.store.path(self.digest).exists())
        self.assertTrue(self.m.store.path(digest2).exists())
        self.assertTrue(self.m.store.path(ctx2["pages"][0]["portableSHA256"]).exists())

    async def test_abandoned_uploads_expire_after_one_hour_but_published_context_stays(self):
        unused = self.m.store.put_bytes(encoded({"metadata":"unpublished"}))
        await self.start()
        self.now += 3599; self.m.collect_artifacts()
        self.assertTrue(self.m.store.path(unused).exists())
        self.now += 1; self.m.collect_artifacts()
        self.assertFalse(self.m.store.path(unused).exists())
        self.assertTrue(self.m.store.path(self.digest).exists())

    async def test_shared_upload_staging_survives_other_request_pin_and_retirement(self):
        r = await self.approved()
        shared = self.digest
        self.now += 100
        self.m.store.stage([shared]) # B's missing-object handshake starts an independent upload lease.
        deadline = self.now+3600
        self.m.store.pin([shared]) # A publishing/pinning the same bytes must not consume B's lease.
        await self.apply(r)
        self.assertNotIn("contextAssets", self.m.store.request(self.rid))
        self.now = deadline-1
        self.m.collect_artifacts()
        self.assertTrue(self.m.store.path(shared).exists())
        self.assertEqual(self.m.store.db.execute("SELECT staged_until FROM artifacts WHERE sha=?",(shared,)).fetchone()[0], deadline)
        self.now = deadline
        self.m.collect_artifacts()
        self.assertFalse(self.m.store.path(shared).exists())

    async def test_unsynced_output_not_released_by_overlapping_or_wrong_source(self):
        r = await self.approved(); await self.apply(r)
        output = self.m.store.request(self.rid)["outputAssets"]
        self.source.state = {**self.source.state, "lastSyncedAt": utc(), "manifest": {"notebooks":[{"id":self.doc,"pages":[]}]}}
        await self.m.confirm_outputs(); self.m.collect_artifacts()
        self.assertTrue(all(self.m.store.path(d).exists() for d in output))

    async def test_current_source_confirmation_releases_output_without_reopening_receipt(self):
        r = await self.approved(); objects = r["render"]["response"]["objects"]
        body = await self.apply(r)
        output = self.m.store.request(self.rid)["outputAssets"]
        head = uid()
        self.source.state = {**self.source.state, "lastSyncedAt":utc(), "manifest":{"notebooks":[{"id":self.doc,
            "pages":[{"id":self.page,"head":head,"nodes":[{"id":head,"objects":objects}]}]}]}}
        await self.m.confirm_outputs(); self.m.collect_artifacts()
        self.now += 3600
        self.m.collect_artifacts()
        self.assertTrue(all(not self.m.store.path(d).exists() for d in output))
        self.assertEqual((await self.m.applied(self.rid, body))["status"], "applied")
        self.assertEqual(self.m.store.request(self.rid)["appliedReceipt"], body["receipt"])
        with self.assertRaises(Problem): self.m.result(self.rid, self.cid)

    async def test_later_confirmed_replacement_releases_superseded_unsynced_output(self):
        r = await self.approved(); old = r["render"]["response"]["objects"][0]
        await self.apply(r)
        newer = copy.deepcopy(old)
        newer["revision"] += 1; newer["source"] = "Later answer"
        newer["frame"]["x"] = 7.0; newer["provenance"]["requestID"] = uid()
        digest = self.m.store.put_bytes(encoded({"newOutput":True}))
        self.m.store.pin([digest])
        later = {"requestID":newer["provenance"]["requestID"], "documentID":self.doc, "status":"applied", "origin":"app",
                 "contextRetired":True, "outputAssets":[digest], "outputObjects":[newer],
                 "objectTransitions":[{"id":old["id"],"before":self.m.object_digest(old),"after":self.m.object_digest(newer)}],
                 "appliedReceipt":{"appliedAt":utc(),"skippedObjectTargets":[]}}
        self.m.store.save_request(later)
        source_object = copy.deepcopy(newer); source_object["frame"]["x"] = 7 # Swift's equivalent integral JSON spelling.
        head = uid()
        self.source.state = {**self.source.state,"lastSyncedAt":utc(),"manifest":{"notebooks":[{"id":self.doc,
            "pages":[{"head":head,"nodes":[{"id":head,"objects":[source_object]}]}]}]}}
        await self.m.confirm_outputs(); self.m.collect_artifacts()
        self.assertTrue(self.m.store.request(self.rid)["outputRetired"])
        self.now += 3600
        self.m.collect_artifacts()
        self.assertFalse(self.m.store.path(r["resultSHA256"]).exists())

    async def test_unbound_explicit_wait_binds_only_when_foreground_opens(self):
        await self.m.terminal_request(self.doc, {"requestID":self.rid,"prompt":"Write"})
        self.now += 10
        await self.m.stale_choice(self.rid, {"choice":"wait"})
        self.now += 7200
        await self.m.open_channel(self.cid, self.sender)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.m.store.request(self.rid)["clientID"], self.cid)

    async def test_expired_explicit_claim_does_not_resume_on_reopen(self):
        await self.m.ensure_worker(self.doc)
        result = self.m.store.put_bytes(encoded({"approved":True}))
        self.m.store.save_request({"requestID":self.rid,"documentID":self.doc,"origin":"terminal","clientID":None,
                                  "status":"ready","created":self.now,"resultSHA256":result})
        await self.m.open_channel(self.cid, self.sender)
        await self.m.claim(self.rid, {"clientID":self.cid})
        self.m.channels.clear(); self.sent.clear(); self.now += 10
        await self.m.open_channel(self.cid, self.sender)
        self.assertEqual(self.sent, [])
        with self.assertRaises(Problem): await self.m.sync_started(self.rid, {"clientID":self.cid})
        await self.m.claim(self.rid, {"clientID":self.cid})
        self.assertEqual(len(self.sent), 1)
        self.assertEqual((await self.m.sync_started(self.rid, {"clientID":self.cid}))["status"], "ready")

    async def test_broken_retained_pin_stops_gc_before_any_deletion(self):
        await self.start()
        orphan = self.m.store.put_bytes(encoded({"orphan":True})); self.m.store.pin([orphan])
        self.m.store.path(self.digest).unlink()
        with self.assertRaises(Problem): self.m.collect_artifacts()
        self.assertTrue(self.m.store.path(orphan).exists())

    async def captured_object(self):
        oid = uid(); data = self.m.store.put_bytes(image(4,4))
        obj = {"id":oid,"revision":1,"kind":"text","source":"Old","frame":{"x":3,"y":5,"width":2,"height":2},
               "style":{"fontSize":14,"color":"#000000","lineWidth":1},
               "asset":{"sha256":data,"pixelWidth":4,"pixelHeight":4,"scale":2},
               "provenance":{"requestID":uid(),"contextSHA256":"a"*64,"rendererSignature":"old-render"}}
        page = self.ctx["pages"][0]; page["objects"] = [obj]
        page["portableSHA256"] = self.m.store.put_bytes(encoded({"format":1,"head":None,"width":32,"height":32,"background":0,"objects":[obj],"strokes":[]}))
        self.digest = self.m.store.put_bytes(encoded(self.ctx)); self.body["contextSHA256"] = self.digest
        return obj

    async def test_position_only_circle_reuses_and_pins_captured_png_after_application(self):
        from notes_service.renderer import Renderer as NativeRenderer
        old = await self.captured_object()
        old.update(kind="circle", source='{"cx":50,"cy":50,"rx":35,"ry":35}')
        page = self.ctx["pages"][0]
        page["portableSHA256"] = self.m.store.put_bytes(encoded({"format": 1, "head": None,
            "width": 32, "height": 32, "background": 0, "objects": [old], "strokes": []}))
        self.digest = self.m.store.put_bytes(encoded(self.ctx)); self.body["contextSHA256"] = self.digest
        self.m.renderer = NativeRenderer(self.m.store.read_asset)
        await self.start()
        supplied = {key: copy.deepcopy(old[key]) for key in ("id", "kind", "source", "style", "frame")}
        supplied["frame"].update(x=-0.26, y=7.24)
        value = {"expectedDraftVersion": 0, "pageEdits": [{"pageID": self.page, "objectEdits": [
            {"op": "replace", "objectID": old["id"], "expectedRevision": 1, "object": supplied}]}]}
        await self.m.draft(self.rid, value, self.doc, self.lease)
        rendered = await self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease)
        moved = rendered["objects"][0]
        self.assertEqual(moved["asset"], old["asset"])
        self.assertEqual(moved["frame"], {**old["frame"], "x": -0.5, "y": 7.0})
        self.assertEqual(moved["revision"], 2)
        self.assertEqual(moved["provenance"]["requestID"], self.rid)
        await self.m.approve(self.rid, {"draftVersion": 1, "renderID": rendered["renderID"],
            "inspectedPreviewSHA256s": [p["sha256"] for p in rendered["previews"]]}, self.doc, self.lease)
        r = self.m.store.request(self.rid)
        await self.apply(r)
        retired = self.m.store.request(self.rid)
        self.assertIn(old["asset"]["sha256"], retired["outputAssets"])
        self.assertEqual(retired["outputObjects"], [moved])
        self.assertEqual(retired["objectTransitions"], [{"id": old["id"], "before": self.m.object_digest(old),
                                                       "after": self.m.object_digest(moved)}])
        self.now += 3600
        self.m.collect_artifacts()
        self.assertTrue(self.m.store.path(old["asset"]["sha256"]).exists())
        self.assertTrue(self.m.store.path(r["resultSHA256"]).exists())

    async def test_renderer_expected_object_matches_full_capture_and_rejects_branch_collision(self):
        old = await self.captured_object()
        await self.start()
        value = draft(self.page)
        value["pageEdits"][0]["objectEdits"][0].update(op="replace", objectID=old["id"], expectedRevision=1)
        value["pageEdits"][0]["objectEdits"][0]["object"]["id"] = old["id"]
        await self.m.draft(self.rid, value, self.doc, self.lease)
        r = self.m.store.request(self.rid)
        output = await self.renderer.render(self.ctx, r["draft"], self.rid, self.digest)
        for digest, data in output["assets"].items(): self.m.store.put_asset(digest, data)
        self.m.validate_rendered(r, output)
        for field in ("frame", "provenance", "asset"):
            bad = copy.deepcopy(output)
            if field == "frame": bad["pageEdits"][0]["objectEdits"][0]["expectedObject"][field]["x"] += 1
            elif field == "asset": bad["pageEdits"][0]["objectEdits"][0]["expectedObject"][field]["sha256"] = "b"*64
            else: bad["pageEdits"][0]["objectEdits"][0]["expectedObject"][field]["requestID"] = uid()
            with self.assertRaises(Problem): self.m.validate_rendered(r, bad)
        bad = copy.deepcopy(output); bad["pageEdits"][0]["objectEdits"][0].pop("expectedObject")
        with self.assertRaises(Problem): self.m.validate_rendered(r, bad)

    async def test_model_cannot_supply_expected_object_precondition(self):
        old = await self.captured_object()
        value = draft(self.page)
        op = value["pageEdits"][0]["objectEdits"][0]
        op.update(op="replace", objectID=old["id"], expectedRevision=1, expectedObject=old)
        op["object"]["id"] = old["id"]
        with self.assertRaises(Problem): check.draft(value, self.ctx)
