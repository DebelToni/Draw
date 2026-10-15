import asyncio
import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path
from notes_service.manager import Manager
from notes_service.tests.fixtures import Renderer, Source, context, uid

HAS_AIOHTTP = importlib.util.find_spec("aiohttp") is not None
if HAS_AIOHTTP:
    from aiohttp.test_utils import TestClient, TestServer
    from notes_service.api import create_app


@unittest.skipUnless(HAS_AIOHTTP, "Parent must provide pinned aiohttp environment")
class APITests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.source = Source()
        self.m = Manager(self.root/"state", Renderer(), self.source, workspace=self.root/"workspace")
        self.client = TestClient(TestServer(create_app(self.m, "fixture-private-token", spawn_workers=False)))
        await self.client.start_server()
        self.headers = {"Authorization": "Bearer fixture-private-token"}
        self.cid, self.doc, self.rid = uid(), uid(), uid()
        self.m.register_client({"clientID": self.cid})
        self.ctx, self.digest = context(self.m, self.doc)
        self.page = self.ctx["focusPageID"]

    async def asyncTearDown(self):
        await self.client.close()
        self.m.close()
        self.tmp.cleanup()

    async def test_health_auth_structured(self):
        response = await self.client.get("/health")
        self.assertEqual(response.status, 401)
        self.assertEqual((await response.json())["error"]["code"], "unauthorized")
        response = await self.client.get("/health", headers=self.headers)
        self.assertEqual(await response.json(), {"ok": True, "protocol": 1})

    async def test_health_reads_requests_without_writes_source_or_model_calls(self):
        sql = []
        self.m.store.db.set_trace_callback(sql.append)
        before = self.m.store.db.total_changes
        source_calls = list(self.source.calls)
        try:
            response = await self.client.get("/health", headers=self.headers)
            self.assertEqual(response.status, 200)
            self.assertEqual(await response.json(), {"ok": True, "protocol": 1})
            self.assertEqual(sql, ["SELECT id FROM requests LIMIT 1"])
            self.assertEqual(self.m.store.db.total_changes, before)
            self.assertEqual(self.source.calls, source_calls)
            self.assertEqual(self.m.renderer.calls, 0)
        finally:
            self.m.store.db.set_trace_callback(None)

    async def test_health_unreadable_sqlite_cannot_report_ok(self):
        self.m.store.db.close()
        response = await self.client.get("/health", headers=self.headers)
        self.assertEqual(response.status, 500)
        self.assertEqual(await response.json(), {"error": {"code": "internal_error", "message": "Manager operation failed"}})
        self.assertEqual(self.m.renderer.calls, 0)

    async def test_receipt_optional_pin_fields_omit_missing_and_null_values(self):
        base = {"requestID": self.rid, "documentID": self.doc, "status": "awaiting_sync"}
        self.assertEqual(self.m.receipt(base), base)
        self.assertEqual(self.m.receipt({**base, "focusPageID": None, "contextSHA256": None}), base)
        fields = {"focusPageID": self.page, "contextSHA256": self.digest}
        self.assertEqual(self.m.receipt({**base, **fields, "prompt": "not exposed", "clientID": self.cid}), {**base, **fields})

    async def test_requested_b_focus_and_pinned_context_are_visible_in_bearer_receipts(self):
        ws = await self.channel(uid()) # Visible A is not requested B.
        try:
            response = await self.client.post("/v1/documents/"+self.doc+"/terminal-requests",
                json={"requestID": self.rid, "prompt": "Write", "focusPageID": self.page}, headers=self.headers)
            self.assertEqual(response.status, 200)
            initial = await response.json()
            self.assertEqual(initial["documentID"], self.doc)
            self.assertEqual(initial["focusPageID"], self.page)
            self.assertNotIn("contextSHA256", initial)
            self.assertEqual(await ws.receive_json(timeout=2), {"kind": "sync_document", "requestID": self.rid,
                "documentID": self.doc, "focusPageID": self.page})
            response = await self.client.post("/v1/requests/"+self.rid+"/sync-started", json={"clientID": self.cid}, headers=self.headers)
            started = await response.json()
            self.assertEqual(started["status"], "synchronizing")
            self.assertEqual(started["focusPageID"], self.page)
            self.assertNotIn("contextSHA256", started)
            sid = uid()
            self.source.receipts[sid] = {**self.source.state, "syncID": sid, "documentID": self.doc}
            response = await self.client.post("/v1/requests/"+self.rid+"/sync-ready",
                json={"clientID": self.cid, "syncID": sid, "contextSHA256": self.digest}, headers=self.headers)
            self.assertEqual(response.status, 200)
            queued = await response.json()
            self.assertEqual(queued["status"], "queued")
            self.assertEqual(queued["documentID"], self.doc)
            self.assertEqual(queued["focusPageID"], self.page)
            self.assertEqual(queued["contextSHA256"], self.digest)
            response = await self.client.get("/v1/requests/"+self.rid, headers=self.headers)
            self.assertEqual(await response.json(), queued)
            self.assertEqual(self.m.renderer.calls, 0)
        finally:
            await ws.close()

    async def test_cas_exact_bytes_integrity_missing(self):
        value = b'{ "exact": true }'
        sha = hashlib.sha256(value).hexdigest()
        response = await self.client.put("/v1/assets/"+sha, data=value, headers=self.headers)
        self.assertEqual(response.status, 200)
        response = await self.client.get("/v1/assets/"+sha, headers=self.headers)
        self.assertEqual(await response.read(), value)
        response = await self.client.put("/v1/assets/"+sha, data=b"changed", headers=self.headers)
        self.assertEqual(response.status, 422)
        response = await self.client.post("/v1/assets/missing", json={"digests": [sha, "0"*64]}, headers=self.headers)
        self.assertEqual(await response.json(), {"missing": ["0"*64]})

    async def test_invalid_json_not_internal_error_or_secret(self):
        response = await self.client.post("/v1/requests", data=b'{"requestID":NaN}', headers=self.headers)
        self.assertEqual(response.status, 422)
        self.assertNotIn("fixture-private-token", await response.text())
        response = await self.client.post("/v1/requests", json=[], headers=self.headers)
        self.assertEqual(response.status, 422)

    async def test_reject_url_token_even_with_bearer(self):
        response = await self.client.get("/health?token=private", headers=self.headers)
        self.assertEqual(response.status, 401)

    async def channel(self, current):
        ws = await self.client.ws_connect("/v1/clients/"+self.cid+"/channel", headers=self.headers)
        await ws.send_json({"kind": "open", "documentID": current})
        for _ in range(100):
            if self.cid in self.m.channels:
                break
            await asyncio.sleep(.001)
        self.assertIn(self.cid, self.m.channels)
        return ws

    async def test_websocket_home_requested_doc_ack(self):
        ws = await self.channel(None)
        response = await self.client.post("/v1/documents/"+self.doc+"/terminal-requests", json={"requestID": self.rid, "prompt": "Write"}, headers=self.headers)
        self.assertEqual(response.status, 200)
        pushed = await ws.receive_json(timeout=2)
        self.assertEqual(pushed, {"kind": "sync_document", "requestID": self.rid, "documentID": self.doc})
        sid = uid()
        self.source.receipts[sid] = {**self.source.state, "syncID": sid, "documentID": self.doc}
        response = await self.client.post("/v1/requests/"+self.rid+"/sync-ready", json={"clientID": self.cid, "syncID": sid, "contextSHA256": self.digest}, headers=self.headers)
        self.assertEqual((await response.json())["status"], "queued")
        await ws.close()

    async def test_expired_reopen_sends_no_sync_until_explicit_wait_consent(self):
        now = [1000.0]; self.m.clock = lambda: now[0]
        ws = await self.channel(None)
        await self.client.post("/v1/documents/"+self.doc+"/terminal-requests", json={"requestID":self.rid,"prompt":"Write","focusPageID":self.page}, headers=self.headers)
        await ws.receive_json(timeout=2)
        await ws.close(); await asyncio.sleep(0)
        now[0] += 10
        ws = await self.channel(None)
        with self.assertRaises(asyncio.TimeoutError): await ws.receive_json(timeout=0.05)
        response = await self.client.post("/v1/requests/"+self.rid+"/sync-started", json={"clientID":self.cid}, headers=self.headers)
        self.assertEqual(response.status, 409)
        response = await self.client.get("/v1/requests/"+self.rid, headers=self.headers)
        self.assertEqual((await response.json())["status"], "needs_stale_choice")
        response = await self.client.post("/v1/requests/"+self.rid+"/stale-choice", json={"choice":"wait"}, headers=self.headers)
        self.assertEqual(response.status, 200)
        self.assertEqual((await ws.receive_json(timeout=2))["focusPageID"], self.page)
        await ws.close(); await asyncio.sleep(0)
        now[0] += 7200
        ws = await self.channel(uid()) # Visible A is irrelevant: requested B/focus is retained.
        command = await ws.receive_json(timeout=2)
        self.assertEqual(command["documentID"], self.doc)
        self.assertEqual(command["focusPageID"], self.page)
        await ws.close()

    async def test_nested_undo_payload_rejected_before_cas_publication(self):
        data = b'{"metadata":{"extra":[{"undoHistory":{"drawing":"opaque"}}]}}'
        digest = hashlib.sha256(data).hexdigest()
        response = await self.client.put("/v1/assets/"+digest, data=data, headers=self.headers)
        self.assertEqual(response.status, 422)
        self.assertEqual((await response.json())["error"]["code"], "native_archive_forbidden")
        self.assertFalse(self.m.store.path(digest).exists())

    async def test_sync_started_ack_before_busy_native_sync_waits_past_ten_seconds(self):
        now = [1000.0]
        self.m.clock = lambda: now[0]
        ws = await self.channel(None)
        response = await self.client.post("/v1/documents/"+self.doc+"/terminal-requests", json={"requestID": self.rid, "prompt": "Write"}, headers=self.headers)
        self.assertEqual(response.status, 200)
        await ws.receive_json(timeout=2)
        response = await self.client.post("/v1/requests/"+self.rid+"/sync-started", json={"clientID": self.cid}, headers=self.headers)
        self.assertEqual((await response.json())["status"], "synchronizing")
        now[0] += 45 # Native flush/Sync/capture still busy, rather than no foreground response.
        response = await self.client.get("/v1/requests/"+self.rid, headers=self.headers)
        self.assertEqual((await response.json())["status"], "synchronizing")
        response = await self.client.post("/v1/requests/"+self.rid+"/stale-choice", json={"choice": "use_synced"}, headers=self.headers)
        self.assertEqual(response.status, 409)
        self.assertEqual((await response.json())["error"]["code"], "sync_in_progress")
        sid = uid()
        self.source.receipts[sid] = {**self.source.state, "syncID": sid, "documentID": self.doc}
        response = await self.client.post("/v1/requests/"+self.rid+"/sync-ready", json={"clientID": self.cid, "syncID": sid, "contextSHA256": self.digest}, headers=self.headers)
        self.assertEqual((await response.json())["status"], "queued")
        await ws.close()

    async def test_notes_cas_rejects_native_archive_and_source_manifest(self):
        for data in (b"bplist00native-undo-archive", b'{"notebooks":[],"blobs":{}}'):
            digest = hashlib.sha256(data).hexdigest()
            response = await self.client.put("/v1/assets/"+digest, data=data, headers=self.headers)
            self.assertEqual(response.status, 422)
            self.assertFalse(self.m.store.path(digest).exists())

    async def test_websocket_another_doc_still_routes_requested_doc(self):
        ws = await self.channel(uid())
        response = await self.client.post("/v1/documents/"+self.doc+"/terminal-requests", json={"requestID": self.rid, "prompt": "Write"}, headers=self.headers)
        self.assertEqual(response.status, 200)
        pushed = await ws.receive_json(timeout=2)
        self.assertEqual(pushed["documentID"], self.doc)
        await ws.close()

    async def test_background_closes_bridge_no_http_foreground_poll(self):
        ws = await self.channel(self.doc)
        await ws.close()
        for _ in range(100):
            if not self.m.channels:
                break
            await asyncio.sleep(.001)
        self.assertEqual(self.m.channels, {})
        response = await self.client.get("/v1/clients/"+self.cid+"/sync-requests?documentID="+self.doc, headers=self.headers)
        self.assertEqual(response.status, 404)

    async def test_settlement_event_failure_reconciles_over_authenticated_heartbeat(self):
        from unittest.mock import patch
        from notes_service.storage import Problem
        await self.m.create_request({"requestID":self.rid,"documentID":self.doc,"focusPageID":self.page,
            "contextSHA256":self.digest,"origin":"app","clientID":self.cid})
        worker = self.m.worker_registry.get(self.doc)
        worker = self.m.worker_registry.register({"documentID":self.doc,"sessionID":worker["sessionID"],
            "spawnNonce":worker["spawnNonce"],"sessionFile":str(self.root/"session.jsonl"),"cwd":worker["cwd"],
            "busy":False,"pending":False,"inputObserved":True})
        activity = {"busy":False,"pending":False,"inputObserved":True,"activeRequestID":None}
        delivery = self.m.lease_request(self.doc,worker["lease"],activity)["request"]
        marker = {"event":"agent_settled","eventID":uid(),"requestID":self.rid,"deliveryID":delivery["deliveryID"]}
        headers = {**self.headers,"X-Draw-Document":self.doc,"X-Draw-Lease":worker["lease"]}
        real_event = self.m.worker_event
        async def drop_event_post(doc,lease,body):
            if "settlement" not in body.get("activity",{}):
                raise Problem("transport_unavailable","Fixture event route unavailable",503)
            return await real_event(doc,lease,body)
        with patch.object(self.m,"worker_event",side_effect=drop_event_post):
            response = await self.client.post("/v1/workers/"+self.doc+"/event",json={**marker,"activity":activity},headers=headers)
            self.assertEqual(response.status,503)
            self.assertEqual(self.m.store.request(self.rid)["status"],"running")
            response = await self.client.post("/v1/workers/"+self.doc+"/heartbeat",json={**activity,"settlement":marker},headers=headers)
            self.assertEqual(response.status,200)
            self.assertEqual((await response.json())["settlementID"],marker["eventID"])
        response = await self.client.get("/v1/requests/"+self.rid,headers=self.headers)
        self.assertEqual((await response.json())["status"],"failed")
        self.assertEqual(self.m.renderer.calls,0)

    async def test_worker_tools_require_exact_lease(self):
        value = {"requestID": self.rid, "documentID": self.doc, "focusPageID": self.ctx["focusPageID"], "contextSHA256": self.digest, "origin": "app", "clientID": self.cid}
        response = await self.client.post("/v1/requests", json=value, headers=self.headers)
        self.assertEqual(response.status, 200)
        response = await self.client.post("/v1/requests/"+self.rid+"/read", json={"view": "overview"}, headers={**self.headers, "X-Draw-Document": self.doc, "X-Draw-Lease": "unknown"})
        self.assertEqual(response.status, 409)
        self.assertEqual((await response.json())["error"]["code"], "bridge_lease")

    async def test_registration_idempotent_no_restored_replay(self):
        other = uid()
        for _ in range(2):
            response = await self.client.post("/v1/clients/register", json={"clientID": other}, headers=self.headers)
            self.assertEqual(response.status, 200)
        response = await self.client.get("/v1/documents/"+self.doc+"/ready?clientID="+other, headers=self.headers)
        self.assertEqual(await response.json(), {"requests": []})


if __name__ == "__main__":
    unittest.main()
