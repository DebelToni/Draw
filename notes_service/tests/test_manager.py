import asyncio
import copy
import hashlib
import tempfile
import unittest
from pathlib import Path
from notes_service.manager import Manager
from notes_service.storage import Problem, decoded, encoded
from notes_service.tests.fixtures import Source, Renderer, context, draft, uid, image


class ManagerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.now = 1000.0
        self.renderer = Renderer()
        self.source = Source()
        self.m = Manager(self.root/"state", self.renderer, self.source, workspace=self.root/"workspace", clock=lambda: self.now)
        self.doc, self.cid, self.rid = uid(), uid(), uid()
        self.m.register_client({"clientID": self.cid})
        self.ctx, self.digest = context(self.m, self.doc)
        self.page = self.ctx["focusPageID"]
        self.body = {"requestID": self.rid, "documentID": self.doc, "focusPageID": self.page,
                     "contextSHA256": self.digest, "origin": "app", "clientID": self.cid}
        self.lease = None

    async def asyncTearDown(self):
        self.m.close()
        self.temp.cleanup()

    def assertProblem(self, code):
        test = self
        class Error:
            def __enter__(self):
                self.check = test.assertRaises(Problem)
                return self.check.__enter__()
            def __exit__(self, *args):
                self.check.__exit__(*args)
                test.assertEqual(self.check.exception.code, code)
                return True
        return Error()

    async def running(self):
        await self.m.create_request(self.body)
        w = self.m.worker_registry.get(self.doc)
        w = self.m.worker_registry.register({"documentID": self.doc, "sessionID": w["sessionID"],
            "sessionFile": str(self.root/"session.jsonl"), "cwd": w["cwd"], "spawnNonce": w["spawnNonce"],
            "busy": False, "pending": False, "inputObserved": True})
        self.lease = w["lease"]
        self.m.lease_request(self.doc, self.lease, {"busy": False, "pending": False, "inputObserved": True})

    async def test_standing_guidance_is_context_only_for_app_and_terminal_prompts(self):
        await self.running()
        for origin, prompt in (("app", None), ("terminal", "Answer this question on the page. ")):
            with self.subTest(origin=origin):
                r = self.m.store.request(self.rid)
                r.update(status="queued", origin=origin)
                if prompt is None:
                    r.pop("prompt", None)
                else:
                    r["prompt"] = prompt
                self.m.store.save_request(r)
                delivered = self.m.lease_request(self.doc, self.lease,
                    {"busy": False, "pending": False, "inputObserved": True})["request"]["prompt"]
                self.assertEqual(delivered, prompt or self.m.app_prompt(r))
                for standing in ("font", "Times", "recolor", "#007AFF", "SHA256", "requestID"):
                    self.assertNotIn(standing, delivered)
        agents = (Path(self.m.worker_registry.get(self.doc)["cwd"]).parent.parent / "AGENTS.md").read_text()
        self.assertIn("defaulting to 18 page points", agents)
        self.assertIn("Do not shrink body text or formulas below 18 points", agents)
        self.assertIn("explicitly requested learning document", agents)
        self.assertIn("a one-pixel gap to either border is acceptable", agents)
        self.assertIn("recolor the WHOLE question", agents)
        self.assertIn("not just the final symbol", agents)
        self.assertIn("every captured stroke that belongs to it", agents)
        self.assertIn("Preserve surrounding working", agents)
        self.assertIn("light Blue `#007AFF`", agents)
        self.assertIn("Page tools infer the active request", agents)
        self.assertIn("Reserve at least one-third", agents)
        self.assertIn("AFTER EACH exercise", agents)
        self.assertIn("FIRST important mistake", agents)
        self.assertIn("without an approval dialog", agents)
        self.assertIn("#00B8D9", agents)
        self.assertIn("do not include answers", agents)
        self.assertIn("current-request.json", agents)

    def settlement(self, **changes):
        r = self.m.store.request(self.rid)
        return {"event": "agent_settled", "eventID": uid(), "requestID": self.rid,
                "deliveryID": r.get("deliveryID"),
                "activity": {"busy": False, "pending": False, "inputObserved": True, "activeRequestID": None}, **changes}

    async def test_healthy_idle_heartbeat_reconciles_exact_pending_settlement_without_inference(self):
        await self.running()
        activity = {"busy": False, "pending": False, "inputObserved": True, "activeRequestID": None}
        self.m.worker_registry.heartbeat(self.doc, self.lease, activity)
        await self.m.maintenance()
        self.assertEqual(self.m.store.request(self.rid)["status"], "running")
        marker = self.settlement(); marker.pop("activity")
        result = await self.m.worker_heartbeat(self.doc, self.lease, {**activity, "settlement": marker})
        self.assertEqual(result["settlementID"], marker["eventID"])
        self.assertEqual(self.m.store.request(self.rid)["status"], "failed")
        self.assertTrue(self.m.store.request(self.rid)["contextRetired"])
        self.m.document_free(self.doc)
        self.assertEqual(self.renderer.calls, 0)

    async def test_settlement_lost_ack_retry_does_not_mark_new_turn_idle(self):
        await self.running()
        marker = self.settlement()
        ack = await self.m.worker_event(self.doc, self.lease, marker)
        # A different delivered request or current human turn must survive both POST and heartbeat retries.
        new_id = uid()
        busy = {"busy": True, "pending": True, "inputObserved": True, "activeRequestID": new_id}
        self.m.worker_registry.heartbeat(self.doc, self.lease, busy)
        before = self.m.worker_registry.get(self.doc)
        self.assertEqual(await self.m.worker_event(self.doc, self.lease, marker), ack)
        self.assertEqual(self.m.worker_registry.get(self.doc), before)
        result = await self.m.worker_heartbeat(self.doc, self.lease, {**marker["activity"], "settlement": {k:v for k,v in marker.items() if k != "activity"}})
        self.assertEqual(result["settlementID"], marker["eventID"])
        self.assertEqual(self.m.worker_registry.get(self.doc), before)
        human_busy = {**busy, "activeRequestID": None}
        self.m.worker_registry.heartbeat(self.doc, self.lease, human_busy)
        human = self.m.worker_registry.get(self.doc)
        await self.m.worker_heartbeat(self.doc, self.lease, {**marker["activity"], "settlement": {k:v for k,v in marker.items() if k != "activity"}})
        self.assertEqual(self.m.worker_registry.get(self.doc), human)
        self.m.worker_registry.heartbeat(self.doc, self.lease, busy)
        before = self.m.worker_registry.get(self.doc)
        # Even an unacknowledged old event must not touch a different current delivery's flags.
        another = {**marker, "eventID": uid()}
        await self.m.worker_event(self.doc, self.lease, another)
        self.assertEqual(self.m.worker_registry.get(self.doc), before)

    async def test_critical_settlement_identity_collision_and_wrong_delivery_fail_before_activity(self):
        await self.running()
        marker = self.settlement()
        before = self.m.worker_registry.get(self.doc)
        with self.assertProblem("worker_identity"):
            await self.m.worker_event(self.doc, self.lease, {**marker, "deliveryID": uid()})
        self.assertEqual(self.m.store.request(self.rid)["status"], "running")
        self.assertEqual(self.m.worker_registry.get(self.doc), before)
        await self.m.worker_event(self.doc, self.lease, marker)
        with self.assertProblem("event_collision"):
            await self.m.worker_event(self.doc, self.lease, {**marker, "recovered": True})

    async def test_recovered_settlement_interrupts_and_keeps_retry_pin(self):
        await self.running()
        marker = self.settlement(recovered=True)
        await self.m.worker_event(self.doc, self.lease, marker)
        r = self.m.store.request(self.rid)
        self.assertEqual(r["status"], "interrupted")
        self.assertEqual(r["error"]["code"], "delivery_uncertain")
        self.assertNotIn("contextRetired", r)
        self.assertEqual(self.m.context(r), self.ctx)
        self.assertEqual(self.renderer.calls, 0)

    async def rendered(self):
        await self.running()
        await self.m.draft(self.rid, draft(self.page), self.doc, self.lease)
        return await self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease)

    async def approved(self):
        render = await self.rendered()
        body = {"draftVersion": 1, "renderID": render["renderID"],
                "inspectedPreviewSHA256s": [p["sha256"] for p in render["previews"]]}
        return await self.m.approve(self.rid, body, self.doc, self.lease), render, body

    async def edit_only_running(self, op):
        from notes_service.renderer import Renderer as NativeRenderer
        layer = self.m.store.put_bytes(image(4, 4, (175, 82, 222, 73)))
        self.ctx["rendererSignature"] = "native-capture-v2"
        page = self.ctx["pages"][0]
        page["strokeTargets"] = [{"id": "native", "fingerprint": "0"*64, "index": 0,
            "frame": {"x": 3, "y": 5, "width": 2, "height": 2},
            "asset": {"sha256": layer, "pixelWidth": 4, "pixelHeight": 4, "scale": 2}}]
        old = {"id": uid(), "revision": 1, "kind": "text", "source": "Old",
               "frame": {"x": 3, "y": 5, "width": 2, "height": 2},
               "style": {"fontSize": 18, "color": "#000000", "lineWidth": 1},
               "asset": {"sha256": layer, "pixelWidth": 4, "pixelHeight": 4, "scale": 2},
               "provenance": {"requestID": uid(), "contextSHA256": "a"*64, "rendererSignature": "old-render"}}
        if op == "object-remove":
            page["objects"] = [old]
        page["portableSHA256"] = self.m.store.put_bytes(encoded({"format": 1, "head": None,
            "width": 32, "height": 32, "background": 0, "objects": page["objects"], "strokes": []}))
        self.digest = self.m.store.put_bytes(encoded(self.ctx))
        self.body["contextSHA256"] = self.digest
        self.m.renderer = NativeRenderer(self.m.store.read_asset)
        await self.running()
        stroke = {"id": "native", "fingerprint": "0"*64, "op": op}
        if op == "move": stroke.update(dx=-2.5, dy=7)
        if op == "recolor": stroke["color"] = "#007AFF"
        value = {"expectedDraftVersion": 0, "pageEdits": [{"pageID": self.page,
            "objectEdits": [{"op": "remove", "objectID": old["id"], "expectedRevision": 1}] if op == "object-remove" else [],
            "strokeEdits": [] if op == "object-remove" else [stroke]}]}
        await self.m.draft(self.rid, value, self.doc, self.lease)
        return value

    async def assert_edit_only_approval(self, op):
        value = await self.edit_only_running(op)
        rendered = await self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease)
        self.assertEqual(rendered["objects"], [])
        body = {"draftVersion": 1, "renderID": rendered["renderID"], "inspectedPreviewSHA256s": []}
        with self.assertProblem("preview_integrity"):
            await self.m.approve(self.rid, body, self.doc, self.lease)
        body["inspectedPreviewSHA256s"] = [p["sha256"] for p in rendered["previews"]]
        receipt = await self.m.approve(self.rid, body, self.doc, self.lease)
        result = self.m.result(self.rid, self.cid)
        self.assertEqual(receipt["resultSHA256"], hashlib.sha256(result).hexdigest())
        frozen = decoded(result)
        self.assertEqual(frozen["pageEdits"][0]["strokeEdits"], value["pageEdits"][0]["strokeEdits"])
        await self.m.applied(self.rid, {"clientID": self.cid, "receipt": {"requestID": self.rid,
            "resultSHA256": receipt["resultSHA256"], "appliedAt": "2026-10-09T00:00:00Z",
            "skippedStrokeTargets": [], "skippedObjectTargets": []}})
        self.assertEqual(self.m.get_request(self.rid)["status"], "applied")

    async def test_native_move_only_approval(self): await self.assert_edit_only_approval("move")
    async def test_native_remove_only_approval(self): await self.assert_edit_only_approval("remove")
    async def test_native_recolor_only_approval(self): await self.assert_edit_only_approval("recolor")
    async def test_object_remove_only_approval(self): await self.assert_edit_only_approval("object-remove")

    async def test_v1_move_draft_requires_recapture_without_version_or_attempt_change(self):
        value = await self.edit_only_running("move")
        legacy = copy.deepcopy(self.ctx)
        legacy["rendererSignature"] = "native-capture-v1"
        digest = self.m.store.put_bytes(encoded(legacy))
        r = self.m.store.request(self.rid)
        r["contextSHA256"] = digest
        self.m.store.save_request(r)
        value["expectedDraftVersion"] = 1
        with self.assertProblem("recapture_required"):
            await self.m.draft(self.rid, value, self.doc, self.lease)
        r = self.m.store.request(self.rid)
        self.assertEqual(r["draftVersion"], 1)
        self.assertEqual(r["attempts"], 0)
        self.assertEqual(r["status"], "running")

    async def test_move_only_preserves_cas_latest_preview_binding_and_three_attempt_budget(self):
        value = await self.edit_only_running("move")
        first = await self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease)
        with self.assertProblem("draft_conflict"):
            await self.m.draft(self.rid, value, self.doc, self.lease)
        value["expectedDraftVersion"] = 1
        value["pageEdits"][0]["strokeEdits"][0]["dx"] = 12
        await self.m.draft(self.rid, value, self.doc, self.lease)
        with self.assertProblem("approval_conflict"):
            await self.m.approve(self.rid, {"draftVersion": 1, "renderID": first["renderID"],
                "inspectedPreviewSHA256s": [p["sha256"] for p in first["previews"]]}, self.doc, self.lease)
        second = await self.m.render(self.rid, {"draftVersion": 2}, self.doc, self.lease)
        latest = await self.m.render(self.rid, {"draftVersion": 2}, self.doc, self.lease)
        with self.assertProblem("approval_conflict"):
            await self.m.approve(self.rid, {"draftVersion": 2, "renderID": second["renderID"],
                "inspectedPreviewSHA256s": [p["sha256"] for p in second["previews"]]}, self.doc, self.lease)
        with self.assertProblem("render_budget"):
            await self.m.render(self.rid, {"draftVersion": 2}, self.doc, self.lease)
        await self.m.approve(self.rid, {"draftVersion": 2, "renderID": latest["renderID"],
            "inspectedPreviewSHA256s": [p["sha256"] for p in latest["previews"]]}, self.doc, self.lease)

    async def test_move_resolved_tuple_is_exactly_bound(self):
        await self.edit_only_running("move")
        r = self.m.store.request(self.rid)
        out = self.m.renderer.render(self.ctx, r["draft"], self.rid, self.digest)
        self.m.validate_rendered(r, out)
        for key, v in [("dy", 7.24), ("dx", 12), ("color", "#007AFF"), ("unexpected", 0)]:
            bad = copy.deepcopy(out)
            bad["pageEdits"][0]["strokeEdits"][0][key] = v
            with self.assertProblem("renderer_invalid"):
                self.m.validate_rendered(r, bad)

    async def test_fractional_move_approval_binds_only_canonical_deltas(self):
        value = await self.edit_only_running("move")
        value["expectedDraftVersion"] = 1
        value["pageEdits"][0]["strokeEdits"][0].update(dx=0.24, dy=0.26)
        await self.m.draft(self.rid, value, self.doc, self.lease)
        r = self.m.store.request(self.rid)
        out = self.m.renderer.render(self.ctx, r["draft"], self.rid, self.digest)
        self.m.validate_rendered(r, out)
        op = out["pageEdits"][0]["strokeEdits"][0]
        self.assertEqual((op["dx"], op["dy"]), (0, 0.5))
        for key, v in [("dx", 0.24), ("dy", 0.26), ("fingerprint", "1"*64), ("color", "#007AFF")]:
            bad = copy.deepcopy(out); bad["pageEdits"][0]["strokeEdits"][0][key] = v
            with self.assertProblem("renderer_invalid"): self.m.validate_rendered(r, bad)
        rendered = await self.m.render(self.rid, {"draftVersion": 2}, self.doc, self.lease)
        receipt = await self.m.approve(self.rid, {"draftVersion": 2, "renderID": rendered["renderID"],
            "inspectedPreviewSHA256s": [p["sha256"] for p in rendered["previews"]]}, self.doc, self.lease)
        frozen = decoded(self.m.result(self.rid, self.cid))
        self.assertEqual(frozen["pageEdits"][0]["strokeEdits"][0], op)
        self.assertEqual(receipt["resultSHA256"], hashlib.sha256(self.m.result(self.rid, self.cid)).hexdigest())
        self.assertEqual(self.m.store.request(self.rid)["draft"]["pageEdits"][0]["strokeEdits"][0]["dx"], 0.24)

    async def test_empty_and_keep_only_drafts_do_not_advance_version(self):
        await self.edit_only_running("move")
        for operations in ([], [{"id": "native", "fingerprint": "0"*64, "op": "keep"}]):
            with self.assertProblem("page_output_missing"):
                await self.m.draft(self.rid, {"expectedDraftVersion": 1, "pageEdits": [{
                    "pageID": self.page, "objectEdits": [], "strokeEdits": operations}]}, self.doc, self.lease)
            self.assertEqual(self.m.store.request(self.rid)["draftVersion"], 1)

    async def test_idempotence_and_collision(self):
        first = await self.m.create_request(self.body)
        self.assertEqual(first, await self.m.create_request(self.body))
        changed = {**self.body, "focusPageID": uid()}
        with self.assertProblem("request_collision"):
            await self.m.create_request(changed)

    async def test_document_serialization(self):
        await self.m.create_request(self.body)
        with self.assertProblem("document_busy"):
            await self.m.create_request({**self.body, "requestID": uid()})

    async def test_concurrent_document_requests_only_one(self):
        results = await asyncio.gather(self.m.create_request(self.body), self.m.create_request({**self.body, "requestID": uid()}), return_exceptions=True)
        self.assertEqual(sum(isinstance(r, Problem) for r in results), 1)

    async def test_context_document_mismatch(self):
        with self.assertProblem("context_document"):
            await self.m.create_request({**self.body, "documentID": uid()})
        self.assertEqual(self.m.store.requests(), [])

    async def test_missing_context_asset_atomic(self):
        self.m.store.path(self.ctx["pages"][0]["inkSHA256"]).unlink()
        with self.assertProblem("missing_asset"):
            await self.m.create_request(self.body)
        self.assertEqual(self.m.store.requests(), [])
        self.assertEqual(self.m.store.records("worker"), [])

    async def test_native_geometry_checked(self):
        self.ctx["pages"][0]["width"] = 99
        self.body["contextSHA256"] = self.m.store.put_bytes(encoded(self.ctx))
        with self.assertProblem("context_dimensions"):
            await self.m.create_request(self.body)

    async def test_unregistered_install_rejected(self):
        with self.assertProblem("client_unregistered"):
            await self.m.create_request({**self.body, "clientID": uid()})

    async def test_app_cannot_claim_stale_capture(self):
        self.ctx["nativeLayerUnavailable"] = True
        self.body["contextSHA256"] = self.m.store.put_bytes(encoded(self.ctx))
        with self.assertProblem("invalid_context"):
            await self.m.create_request(self.body)

    async def test_draft_cas_with_parallel_tools(self):
        await self.running()
        ops = draft(self.page)
        results = await asyncio.gather(self.m.draft(self.rid, ops, self.doc, self.lease), self.m.draft(self.rid, ops, self.doc, self.lease), return_exceptions=True)
        self.assertEqual(sum(isinstance(r, Problem) for r in results), 1)
        self.assertEqual(self.m.store.request(self.rid)["draftVersion"], 1)

    async def test_generated_identity_fixed_across_retry(self):
        await self.running()
        await self.m.draft(self.rid, draft(self.page), self.doc, self.lease)
        changed = {**draft(self.page), "expectedDraftVersion": 1}
        with self.assertProblem("generated_identity"):
            await self.m.draft(self.rid, changed, self.doc, self.lease)

    async def test_draft_invalidates_old_render(self):
        rendered = await self.rendered()
        r = self.m.store.request(self.rid)
        body = {"expectedDraftVersion": 1, "pageEdits": r["draft"]["pageEdits"]}
        await self.m.draft(self.rid, body, self.doc, self.lease)
        with self.assertProblem("approval_conflict"):
            await self.m.approve(self.rid, {"draftVersion": 1, "renderID": rendered["renderID"], "inspectedPreviewSHA256s": [p["sha256"] for p in rendered["previews"]]}, self.doc, self.lease)

    async def test_three_failures_consume_budget(self):
        await self.running()
        await self.m.draft(self.rid, draft(self.page), self.doc, self.lease)
        self.renderer.fail = True
        for _ in range(3):
            with self.assertProblem("render_failed"):
                await self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease)
        with self.assertProblem("render_budget"):
            await self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease)
        self.assertEqual(self.renderer.calls, 3)

    async def test_idempotent_render_id(self):
        await self.running()
        await self.m.draft(self.rid, draft(self.page), self.doc, self.lease)
        body = {"draftVersion": 1, "renderID": uid()}
        first = await self.m.render(self.rid, body, self.doc, self.lease)
        self.assertEqual(first, await self.m.render(self.rid, body, self.doc, self.lease))
        self.assertEqual(self.renderer.calls, 1)

    async def test_missing_preview_cannot_publish(self):
        self.renderer.bad_preview = True
        await self.running()
        await self.m.draft(self.rid, draft(self.page), self.doc, self.lease)
        with self.assertProblem("preview_integrity"):
            await self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease)
        self.assertNotIn("resultSHA256", self.m.get_request(self.rid))

    async def test_renderer_provenance_verified(self):
        self.renderer.bad_provenance = True
        await self.running()
        await self.m.draft(self.rid, draft(self.page), self.doc, self.lease)
        with self.assertProblem("renderer_invalid"):
            await self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease)

    async def test_exact_preview_hash_required(self):
        render = await self.rendered()
        with self.assertProblem("preview_integrity"):
            await self.m.approve(self.rid, {"draftVersion": 1, "renderID": render["renderID"], "inspectedPreviewSHA256s": ["0"*64]}, self.doc, self.lease)
        self.assertEqual(self.m.ready(self.doc, self.cid), {"requests": []})

    async def test_approved_exact_bytes_and_ready_client_binding(self):
        receipt, render, approve = await self.approved()
        result = self.m.result(self.rid, self.cid)
        self.assertEqual(hashlib.sha256(result).hexdigest(), receipt["resultSHA256"])
        self.assertEqual(decoded(result)["previewSHA256s"], {p["pageID"]: p["sha256"] for p in render["previews"]})
        other = uid()
        self.m.register_client({"clientID": other})
        self.assertEqual(self.m.ready(self.doc, other), {"requests": []})
        with self.assertProblem("client_binding"):
            self.m.result(self.rid, other)
        self.assertEqual(receipt, await self.m.approve(self.rid, approve, self.doc, self.lease))

    async def test_application_receipt_survives_undo_retry(self):
        receipt, _, _ = await self.approved()
        body = {"clientID": self.cid, "receipt": {"requestID": self.rid, "resultSHA256": receipt["resultSHA256"], "appliedAt": "2026-10-08T00:00:00Z", "skippedStrokeTargets": [], "skippedObjectTargets": []}}
        first = await self.m.applied(self.rid, body)
        self.assertEqual(first, await self.m.applied(self.rid, body))
        self.assertEqual(self.m.ready(self.doc, self.cid), {"requests": []})
        with self.assertProblem("receipt_collision"):
            await self.m.applied(self.rid, {**body, "receipt": {**body["receipt"], "skippedObjectTargets": [uid()]}})

    async def test_no_result_before_approval(self):
        await self.rendered()
        with self.assertProblem("not_ready"):
            self.m.result(self.rid, self.cid)

    async def test_cross_document_tools_rejected(self):
        await self.running()
        other = uid()
        worker = self.m.worker_registry.reserve(other)
        worker = self.m.worker_registry.register({"documentID": other, "sessionID": worker["sessionID"], "sessionFile": str(self.root/"other.jsonl"), "cwd": worker["cwd"], "spawnNonce": worker["spawnNonce"]})
        with self.assertProblem("document_scope"):
            await self.m.read(self.rid, {"view": "overview"}, other, worker["lease"])

    async def test_crop_real_image_and_pinned_metadata(self):
        await self.running()
        value = await self.m.read(self.rid, {"view": "crop", "pageID": self.page, "rect": {"x": 1, "y": 2, "width": 4, "height": 5}}, self.doc, self.lease)
        from notes_service.validation import png
        self.assertEqual(png(self.m.store.read_asset(value["images"][0]["sha256"])), (8,10))
        self.assertEqual(value["contextSHA256"], self.digest)

    async def test_restart_marks_running_uncertain_never_replays(self):
        await self.running()
        self.m.close()
        self.m = Manager(self.root/"state", self.renderer, self.source, workspace=self.root/"workspace", clock=lambda: self.now)
        self.assertEqual(self.m.get_request(self.rid)["status"], "interrupted")
        self.assertEqual(self.m.store.requests(self.doc, {"queued"}), [])
        self.assertIsNone(self.m.worker_registry.get(self.doc)["lease"])

    async def test_lease_loss_is_interrupted(self):
        await self.running()
        self.now += 31
        await self.m.maintenance()
        self.assertEqual(self.m.get_request(self.rid)["status"], "interrupted")

    async def test_settlement_without_page_output_fails(self):
        await self.running()
        await self.m.worker_event(self.doc, self.lease, {"event": "agent_settled", "requestID": self.rid})
        self.assertEqual(self.m.get_request(self.rid)["error"]["code"], "page_output_missing")

    async def test_companion_durable_app_mode(self):
        self.m.companion(self.doc, True)
        await self.m.create_request(self.body)
        self.assertEqual(self.m.store.request(self.rid)["outputMode"], "companion")
        self.m.close()
        self.m = Manager(self.root/"state", self.renderer, self.source, workspace=self.root/"workspace")
        self.assertTrue(self.m.companion(self.doc)["enabled"])

    async def test_terminal_bridge_home_or_another_document(self):
        sent = []
        async def sender(value): sent.append(value)
        await self.m.open_channel(self.cid, sender)
        body = {"requestID": self.rid, "prompt": "Answer on this note", "focusPageID": self.page}
        receipt = await self.m.terminal_request(self.doc, body)
        self.assertEqual(receipt["status"], "awaiting_sync")
        self.assertEqual(sent, [{"kind": "sync_document", "documentID": self.doc, "requestID": self.rid, "focusPageID": self.page}])
        self.assertEqual(self.m.store.request(self.rid)["clientID"], self.cid)
        sid = uid()
        self.source.receipts[sid] = {**self.source.state, "documentID": self.doc, "syncID": sid}
        ack = {"clientID": self.cid, "syncID": sid, "contextSHA256": self.digest}
        receipt = await self.m.sync_ready(self.rid, ack)
        self.assertEqual(receipt["status"], "queued")
        self.assertEqual(receipt, await self.m.sync_ready(self.rid, ack))

    async def test_sync_ready_rejects_wrong_document_receipt(self):
        async def sender(value): pass
        await self.m.open_channel(self.cid, sender)
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"})
        sid = uid()
        self.source.receipts[sid] = {**self.source.state, "documentID": uid(), "syncID": sid}
        with self.assertProblem("sync_document"):
            await self.m.sync_ready(self.rid, {"clientID": self.cid, "syncID": sid, "contextSHA256": self.digest})
        self.assertEqual(self.m.get_request(self.rid)["status"], "awaiting_sync")

    async def test_sync_ready_rejects_other_client(self):
        async def sender(value): pass
        await self.m.open_channel(self.cid, sender)
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"})
        other = uid(); self.m.register_client({"clientID": other})
        with self.assertProblem("client_binding"):
            await self.m.sync_ready(self.rid, {"clientID": other, "syncID": uid(), "contextSHA256": self.digest})

    async def test_timeout_requires_explicit_choice_no_stale_read(self):
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"})
        self.now += 10
        receipt = await self.m.terminal_status(self.m.store.request(self.rid))
        self.assertEqual(receipt["status"], "needs_stale_choice")
        self.assertEqual(receipt["lastSyncedAt"], self.source.state["lastSyncedAt"])
        self.assertFalse(any(name == "stale" for name, _ in self.source.calls))
        self.source.context = {**self.ctx, "nativeLayerUnavailable": True}
        receipt = await self.m.stale_choice(self.rid, {"choice": "use_synced"})
        self.assertEqual(receipt["status"], "queued")
        self.assertTrue(self.m.context(self.m.store.request(self.rid))["nativeLayerUnavailable"])
        self.assertIsNone(self.m.store.request(self.rid)["clientID"])

    async def test_reconnect_only_sync_intent_same_client(self):
        sent = []
        async def sender(v): sent.append(v)
        await self.m.open_channel(self.cid, sender)
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"})
        self.m.channels.clear()
        other = uid(); self.m.register_client({"clientID": other})
        await self.m.open_channel(other, sender)
        self.assertEqual(len(sent), 1)
        self.m.channels.clear()
        await self.m.open_channel(self.cid, sender)
        self.assertEqual(len(sent), 2)
        self.assertEqual(self.m.get_request(self.rid)["status"], "awaiting_sync")

    async def test_unsynced_native_labels_do_not_query_missing_source(self):
        async def missing(doc):
            raise Problem("sync_unavailable", "Unsynced document absent", 409)
        self.source.labels = missing
        folder_id = uid()
        self.ctx.update(documentName="Local unsynced note", folderName="Calculus", folderID=folder_id)
        self.body["contextSHA256"] = self.m.store.put_bytes(encoded(self.ctx))
        await self.m.create_request(self.body)
        worker = self.m.worker_registry.get(self.doc)
        self.assertEqual(worker["label"], "Calculus / Local unsynced note")
        self.assertEqual(worker["folderID"], folder_id)
        self.assertEqual(self.source.calls, [])

    async def test_partial_optional_capture_labels_do_not_require_source(self):
        async def missing(doc):
            raise Problem("sync_unavailable", "Unsynced document absent", 409)
        self.source.labels = missing
        fid = uid()
        self.ctx.update(folderID=fid, folderName="Math")
        self.body["contextSHA256"] = self.m.store.put_bytes(encoded(self.ctx))
        await self.m.create_request(self.body)
        worker = self.m.worker_registry.get(self.doc)
        self.assertEqual(worker["folderID"], fid)
        self.assertEqual(worker["folderName"], "Math")
        self.assertEqual(worker["noteName"], "Untitled-"+self.doc[:8])
        self.assertEqual(self.source.calls, [])

    async def test_invalid_context_label_values_rejected_before_reservation(self):
        for values in ({"documentName": []}, {"documentName": "bad\nname"}, {"folderName": ""},
                       {"documentName": "x"*1025}, {"folderID": "invalid"}):
            ctx = {**self.ctx, **values}
            body = {**self.body, "contextSHA256": self.m.store.put_bytes(encoded(ctx))}
            with self.assertRaises(Problem):
                await self.m.create_request(body)
        self.assertEqual(self.m.store.records("worker"), [])

    async def test_new_unsynced_terminal_document_can_attempt_live_sync(self):
        await self.m.ensure_worker(self.doc, {"documentName": "New local note"})
        async def missing(doc):
            raise Problem("sync_unavailable", "No first publication", 409)
        self.source.document_state = missing
        async def sender(value): pass
        await self.m.open_channel(self.cid, sender)
        receipt = await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"})
        self.assertEqual(receipt["status"], "awaiting_sync")
        self.assertIsNone(receipt["lastSyncedAt"])
        self.assertEqual((await self.m.sync_started(self.rid, {"clientID": self.cid}))["status"], "synchronizing")

    async def test_parallel_terminal_source_lookups_cannot_reserve_two_writers(self):
        await self.m.ensure_worker(self.doc, {"documentName": "Note"})
        arrived = asyncio.Event(); release = asyncio.Event()
        async def delayed(doc):
            arrived.set(); await release.wait(); return self.source.state
        self.source.document_state = delayed
        first = asyncio.create_task(self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"}))
        await arrived.wait()
        second = asyncio.create_task(self.m.terminal_request(self.doc, {"requestID": uid(), "prompt": "Write more"}))
        await asyncio.sleep(0)
        release.set()
        result = await asyncio.gather(first, second, return_exceptions=True)
        self.assertEqual(sum(isinstance(value, dict) for value in result), 1)
        self.assertEqual([value.code for value in result if isinstance(value, Problem)], ["document_busy"])
        self.assertEqual(len(self.m.store.requests(self.doc)), 1)

    async def test_context_native_source_manifest_forbidden(self):
        self.ctx["sourceManifestSHA256"] = "a"*64
        self.body["contextSHA256"] = self.m.store.put_bytes(encoded(self.ctx))
        with self.assertProblem("native_archive_forbidden"):
            await self.m.create_request(self.body)
        self.assertEqual(self.m.store.requests(), [])

    async def terminal_syncing(self):
        async def sender(value): pass
        await self.m.open_channel(self.cid, sender)
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write", "focusPageID": self.page})
        return await self.m.sync_started(self.rid, {"clientID": self.cid})

    async def test_ack_extends_sync_window_past_ten_seconds_while_native_busy(self):
        started = await self.terminal_syncing()
        self.assertEqual(started["status"], "synchronizing")
        self.now += 35
        await self.m.maintenance()
        self.assertEqual((await self.m.terminal_status(self.m.store.request(self.rid)))["status"], "synchronizing")
        with self.assertProblem("sync_in_progress"):
            await self.m.stale_choice(self.rid, {"choice": "use_synced"})
        self.assertFalse(any(name == "stale" for name, _ in self.source.calls))
        sid = uid()
        self.source.receipts[sid] = {**self.source.state, "documentID": self.doc, "syncID": sid}
        receipt = await self.m.sync_ready(self.rid, {"clientID": self.cid, "syncID": sid, "contextSHA256": self.digest})
        self.assertEqual(receipt["status"], "queued")

    async def test_sync_ack_idempotent_deadline_max_three_hundred_seconds(self):
        started = await self.terminal_syncing()
        deadline = self.m.store.request(self.rid)["syncDeadline"]
        self.now += 299
        self.assertEqual((await self.m.sync_started(self.rid, {"clientID": self.cid}))["syncDeadlineAt"], started["syncDeadlineAt"])
        self.assertEqual(self.m.store.request(self.rid)["syncDeadline"], deadline)
        self.assertEqual((await self.m.terminal_status(self.m.store.request(self.rid)))["status"], "synchronizing")
        self.now += 1
        self.assertEqual((await self.m.terminal_status(self.m.store.request(self.rid)))["status"], "needs_stale_choice")
        self.assertEqual((await self.m.sync_started(self.rid, {"clientID": self.cid}))["status"], "needs_stale_choice")

    async def test_ack_requires_associated_foreground_client(self):
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"})
        with self.assertProblem("client_binding"):
            await self.m.sync_started(self.rid, {"clientID": self.cid})
        async def sender(value): pass
        await self.m.open_channel(self.cid, sender)
        other = uid(); self.m.register_client({"clientID": other})
        with self.assertProblem("client_binding"):
            await self.m.sync_started(self.rid, {"clientID": other})
        self.m.channels.clear()
        with self.assertProblem("foreground_required"):
            await self.m.sync_started(self.rid, {"clientID": self.cid})

    async def test_sync_a_receipt_context_remain_pinned_after_new_writing_b(self):
        await self.terminal_syncing()
        sid = uid()
        receipt_a = {**self.source.state, "documentID": self.doc, "syncID": sid}
        self.source.receipts[sid] = receipt_a
        self.source.state = {**self.source.state, "documentDigest": "b"*64, "revision": 2}
        ctx_b = {**self.ctx, "documentName": "New writing B"}
        digest_b = self.m.store.put_bytes(encoded(ctx_b))
        self.now += 20
        await self.m.sync_ready(self.rid, {"clientID": self.cid, "syncID": sid, "contextSHA256": self.digest})
        r = self.m.store.request(self.rid)
        self.assertEqual(r["contextSHA256"], self.digest)
        self.assertNotEqual(r["contextSHA256"], digest_b)
        self.assertEqual(r["syncReceipt"], receipt_a)
        self.assertEqual(r["sourcePin"], {k: receipt_a[k] for k in ("documentID", "documentDigest", "syncID", "revision")})
        self.assertEqual(self.source.calls, [("state", self.doc), ("receipt", sid)])

    async def test_ack_restart_preserves_syncing_deadline_without_inference(self):
        await self.terminal_syncing()
        deadline = self.m.store.request(self.rid)["syncDeadline"]
        self.m.close()
        self.now += 30
        self.m = Manager(self.root/"state", self.renderer, self.source, workspace=self.root/"workspace", clock=lambda: self.now)
        self.assertEqual(self.m.store.request(self.rid)["syncDeadline"], deadline)
        self.assertEqual((await self.m.terminal_status(self.m.store.request(self.rid)))["status"], "synchronizing")
        self.assertEqual(self.m.store.requests(self.doc, {"queued", "running"}), [])

    async def test_unbound_terminal_ready_requires_explicit_claim_sync(self):
        self.source.context = {**self.ctx, "nativeLayerUnavailable": True}
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"})
        await self.m.stale_choice(self.rid, {"choice": "use_synced"})
        r = self.m.store.request(self.rid)
        result = self.m.store.put_bytes(encoded({"approved": "fixture"}))
        r.update(status="ready", resultSHA256=result)
        self.m.store.save_request(r)
        self.assertEqual(self.m.ready(self.doc, self.cid), {"requests": []})
        sent = []
        async def sender(v): sent.append(v)
        await self.m.open_channel(self.cid, sender)
        self.assertEqual(sent, [])
        await self.m.claim(self.rid, {"clientID": self.cid})
        self.assertEqual(sent[0]["documentID"], self.doc)
        self.assertEqual(self.m.ready(self.doc, self.cid), {"requests": []})
        sid = uid()
        self.source.receipts[sid] = {**self.source.state, "documentID": self.doc, "syncID": sid}
        await self.m.sync_ready(self.rid, {"clientID": self.cid, "syncID": sid, "contextSHA256": self.digest})
        self.assertEqual(self.m.ready(self.doc, self.cid)["requests"][0]["resultSHA256"], result)
        self.assertEqual(self.m.store.request(self.rid)["contextSHA256"], r["contextSHA256"])

    async def test_current_unbound_intent_binds_newly_opened_foreground(self):
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"})
        sent = []
        async def sender(v): sent.append(v)
        await self.m.open_channel(self.cid, sender)
        self.assertEqual(self.m.store.request(self.rid)["clientID"], self.cid)
        self.assertEqual(sent[0]["requestID"], self.rid)

    async def test_expired_unbound_intent_never_replays_on_new_install(self):
        await self.m.terminal_request(self.doc, {"requestID": self.rid, "prompt": "Write"})
        self.now += 20
        sent = []
        async def sender(v): sent.append(v)
        await self.m.open_channel(self.cid, sender)
        self.assertEqual(sent, [])
        self.assertIsNone(self.m.store.request(self.rid)["clientID"])

    async def test_render_lock_serializes_draft_mutation(self):
        await self.running()
        ops = draft(self.page)
        await self.m.draft(self.rid, ops, self.doc, self.lease)
        self.renderer.started, self.renderer.release = asyncio.Event(), asyncio.Event()
        rendering = asyncio.create_task(self.m.render(self.rid, {"draftVersion": 1}, self.doc, self.lease))
        await self.renderer.started.wait()
        mutation = asyncio.create_task(self.m.draft(self.rid, {**ops, "expectedDraftVersion": 1}, self.doc, self.lease))
        await asyncio.sleep(0)
        self.assertFalse(mutation.done())
        self.renderer.release.set()
        await rendering; await mutation
        self.assertNotIn("render", self.m.store.request(self.rid))


if __name__ == "__main__":
    unittest.main()
