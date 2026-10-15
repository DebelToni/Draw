"""No live Pi, production brokers or native application in these tests."""
import asyncio
import hashlib
import json
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from aiohttp import ClientSession
from benchmarks.draw_ai import cases, runner
from notes_service.storage import Store, Problem, encoded
from notes_service.tests.fixtures import Renderer, context, draft, uid


class FixtureWorker(runner.BenchmarkWorkerRegistry):
    instances = []
    mode = "ready"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.present, self.calls, self.task = False, [], None
        self.__class__.instances.append(self)

    def capture_processes(self):
        pass

    def processes_alive(self):
        return []

    def pane_state(self, worker):
        return "owned" if self.present else "absent"

    def run(self, *args):
        self.calls.append(args)
        if args[0] == "kill-pane" or args[-1] == "C-m":
            self.present = False
            if self.task and not self.task.done():
                self.task.cancel()
        return ""

    def spawn(self, doc):
        worker = self.get(doc)
        self.command_used = self.command(worker)
        self.launch_attempted = True
        worker.update(spawned=True, paneID="%fixture", windowID="@fixture")
        self.save(worker)
        self.present = True
        self.task = asyncio.create_task(self.bridge(doc))
        return worker

    async def bridge(self, doc):
        if self.mode == "startup_timeout":
            await asyncio.sleep(10)
            return
        worker = self.get(doc)
        path = self.run_root / "sessions" / (worker["sessionID"] + ".jsonl")
        path.write_bytes(encoded({"type": "session", "version": 3, "id": worker["sessionID"],
                                 "cwd": worker["cwd"]}) + b"\n")
        token = Path(self.token_file).read_text()
        async with ClientSession(headers={"Authorization": "Bearer " + token}) as client:
            async def post(route, body, worker_headers=None):
                async with client.post(self.manager_url + route, json=body, headers=worker_headers) as response:
                    value = await response.json()
                    if response.status != 200:
                        raise AssertionError(value)
                    return value
            activity = {"busy": False, "pending": False, "inputObserved": True, "activeRequestID": None}
            registered = await post("/v1/workers/register", {"documentID": doc, "sessionID": worker["sessionID"],
                "sessionFile": str(path), "cwd": worker["cwd"], "spawnNonce": worker["spawnNonce"], **activity})
            headers = {"X-Draw-Document": doc, "X-Draw-Lease": registered["lease"]}
            await post(f"/v1/workers/{doc}/heartbeat", activity, headers)
            while True:
                polled = await post(f"/v1/workers/{doc}/poll", activity, headers)
                if polled.get("request"):
                    break
                await asyncio.sleep(0.001)
            request = polled["request"]
            self.prompt = request["prompt"]
            rid = request["requestID"]
            await post(f"/v1/workers/{doc}/event", {"event": "agent_start", "requestID": rid}, headers)
            if self.mode == "request_timeout":
                await asyncio.sleep(10)
                return
            model = "gpt-6.1-sol-long" if self.mode == "wrong_model" else runner.BASELINE["model"]
            with path.open("ab") as stream:
                stream.write(encoded({"type": "thinking_level_change", "thinkingLevel": "medium"}) + b"\n")
                stream.write(encoded({"type": "message", "message": {"role": "assistant", "provider": "codex-pro",
                    "model": model, "content": [{"text": "secret raw transcript, not for review"}]}}) + b"\n")
                if self.mode in ("late_model", "late_thinking"):
                    stream.write(encoded({"type": "message", "message": {"role": "assistant",
                        "provider": "codex-other" if self.mode == "late_model" else "codex-pro",
                        "model": model, "thinkingLevel": "medium",
                        "providerThinkingLevel": "high" if self.mode == "late_thinking" else "medium"}}) + b"\n")
            if self.mode != "no_output":
                await post(f"/v1/requests/{rid}/read", {"view": "page", "pageID": request["focusPageID"]}, headers)
                await post(f"/v1/requests/{rid}/draft", draft(request["focusPageID"]), headers)
                rendered = await post(f"/v1/requests/{rid}/render", {"draftVersion": 1}, headers)
                if self.mode != "render_no_approve":
                    await post(f"/v1/requests/{rid}/approve", {"draftVersion": 1, "renderID": rendered["renderID"],
                        "inspectedPreviewSHA256s": [p["sha256"] for p in rendered["previews"]]}, headers)
            await asyncio.sleep(0.08)  # Approval is intentionally earlier than settlement.
            await post(f"/v1/workers/{doc}/event", {"eventID": uid(), "event": "agent_settled", "requestID": rid,
                "deliveryID": request["deliveryID"], "activity": activity}, headers)


class RunnerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        temporary = Path.home() / "tmp"
        temporary.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="draw-runner-test-", dir=temporary)
        self.root = Path(self.tmp.name)
        FixtureWorker.mode, FixtureWorker.instances = "ready", []
        manager = runner.Manager(self.root / "fixture", Renderer(), source=None)
        ctx, _ = context(manager, uid())
        assets = {path.name: path.read_bytes() for path in manager.store.cas.iterdir()
                  if path.name != hashlib.sha256(encoded(ctx)).hexdigest()}
        manager.close()
        # Synthetic native layers, but the case itself goes through the real freezer/verifier.
        capture = self.root / "capture"
        (capture / "assets").mkdir(parents=True)
        (capture / "context.json").write_bytes(encoded(ctx))
        for digest, data in assets.items():
            (capture / "assets" / digest).write_bytes(data)
        self.case = cases.import_case(capture, self.root / "frozen", "Fixture question", {"kind": "synthetic_unit_fixture"})
        self.patches = [patch.object(runner, "BenchmarkWorkerRegistry", FixtureWorker),
                        patch.object(runner, "Renderer", lambda _: Renderer()),
                        patch.object(runner, "preflight", AsyncMock(return_value={"availableCatalog": True}))]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    async def asyncTearDown(self):
        for registry in FixtureWorker.instances:
            if registry.task:
                if not registry.task.done():
                    registry.task.cancel()
                await asyncio.gather(registry.task, return_exceptions=True)
        self.tmp.cleanup()

    async def run_case(self, name="run", **kwargs):
        return await runner.run_case(self.case, self.root / name, timeout=1, startup_timeout=1,
                                    settlement_timeout=1, cleanup_timeout=0.03, **kwargs)

    def listener_closed(self, record):
        host, port = record["brokerURL"].removeprefix("http://").split(":")
        self.assertEqual(host, "127.0.0.1")
        self.assertNotEqual(int(port), 18881)
        with socket.socket() as probe:
            probe.settimeout(0.1)
            self.assertNotEqual(probe.connect_ex((host, int(port))), 0)
        self.assertTrue(record["listenerClosed"])

    async def test_real_broker_fixture_ready_export_and_timing(self):
        record = await self.run_case()
        self.assertEqual(record["status"], "ready", record)
        self.assertEqual(record["cleanup"]["status"], "stopped")
        self.assertTrue(record["cleanup"]["parkSent"])
        timing = record["timings"]
        self.assertLess(timing["requestToReadySeconds"], timing["requestToSettledSeconds"])
        self.assertGreater(timing["readyToSettledSeconds"], 0.06)
        self.assertEqual([s["stage"] for s in timing["stages"]], ["read", "draft", "render", "approve"])
        self.assertTrue(all(s["ok"] and s["durationSeconds"] >= 0 for s in timing["stages"]))
        self.assertTrue(record["session"]["modelMatches"])
        self.assertTrue(record["session"]["reasoningMatches"])
        self.assertEqual(len(record["session"]["observedGenerations"]), 1)
        self.assertEqual(timing["observers"][0]["stage"], "render_observer")
        self.assertEqual(timing["observerOverheadSeconds"], timing["observers"][0]["durationSeconds"])
        self.assertTrue(timing["observerOverheadIncludedInPrimary"])
        self.assertLessEqual(timing["observers"][0]["endSeconds"], timing["requestToReadySeconds"])
        self.assertFalse(record["session"]["wirePayloadObserved"])
        review = self.root / "run/review"
        data = (review / "result.json").read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), record["artifacts"]["resultSHA256"])
        self.assertTrue(list((review / "assets").iterdir()))
        self.assertEqual(len(list((review / "previews").iterdir())), 1)
        self.assertEqual(record, json.loads((self.root / "run/run.json").read_text()))
        token = (self.root / "run/token").read_text()
        self.assertNotIn(token, encoded(record).decode())
        self.assertFalse(any(path.name in ("token", "document.json", "notes.sqlite3") or path.suffix == ".jsonl"
                             for path in review.rglob("*")))
        self.assertEqual((self.root / "run").stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / "run/token").stat().st_mode & 0o777, 0o600)
        self.assertEqual(record["providerCacheConditions"], "unknown")
        self.assertFalse(record["nativeApplication"])
        self.assertEqual(record["quality"]["status"], "unreviewed")
        store = Store(self.root / "run/state")
        self.assertEqual(store.request(record["requestID"])["status"], "ready")
        self.assertNotIn("appliedReceipt", store.request(record["requestID"]))
        store.close()
        self.listener_closed(record)

    async def test_fresh_store_sessions_tokens_and_production_prompt(self):
        first = await self.run_case("first")
        second = await self.run_case("second")
        self.assertNotEqual(first["session"]["sessionID"], second["session"]["sessionID"])
        self.assertNotEqual(first["requestID"], second["requestID"])
        self.assertNotEqual((self.root / "first/token").read_bytes(), (self.root / "second/token").read_bytes())
        self.assertEqual(first["contextSHA256"], second["contextSHA256"])
        for registry in FixtureWorker.instances:
            self.assertEqual(registry.prompt, "Help with the questions or unfinished material on the captured focus page.")
            command = registry.command_used
            self.assertIn("--fast", command)
            self.assertEqual(command[command.index("--model")+1], "codex-pro/gpt-6.1-sol")
            self.assertEqual(command[command.index("--thinking")+1], "medium")
            self.assertEqual(command[command.index("--session-dir")+1], str(registry.run_root / "sessions"))
            for option in ("--no-tools", "--tools", "--no-extensions", "--mode", "--no-context-files", "--continue"):
                self.assertNotIn(option, command)
        self.assertFalse(first["promptOverride"])
        self.listener_closed(first)
        self.listener_closed(second)

    async def test_explicit_query_disclosed(self):
        self.case["manifest"]["requestPrompt"] = "Fixture question. "
        self.case["manifest"]["promptMode"] = "explicit_test_query"
        record = await self.run_case()
        self.assertTrue(record["promptOverride"])
        self.assertEqual(record["promptMode"], "explicit_test_query")
        self.assertTrue(FixtureWorker.instances[-1].prompt.startswith("Fixture question. "))

    async def test_missing_output_kept_as_failure(self):
        FixtureWorker.mode = "no_output"
        record = await self.run_case()
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["errorCode"], "page_output_missing")
        self.assertNotIn("requestToReadySeconds", record["timings"])
        self.listener_closed(record)

    async def test_failed_settlement_keeps_last_real_render_bytes(self):
        FixtureWorker.mode = "render_no_approve"
        record = await self.run_case()
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["errorCode"], "page_output_missing")
        data = (self.root / "run/review/rendered-not-approved.json").read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), record["artifacts"]["latestRenderedSHA256"])
        self.assertIsNone(record["artifacts"]["resultSHA256"])
        self.assertTrue(list((self.root / "run/review/previews").iterdir()))
        self.assertFalse((self.root / "run/review/result.json").exists())

    async def test_model_alias_is_not_accepted_as_baseline(self):
        FixtureWorker.mode = "wrong_model"
        record = await self.run_case()
        self.assertEqual(record["status"], "profile_mismatch")
        self.assertTrue((self.root / "run/review/result.json").is_file())

    async def test_later_generations_cannot_silently_change_profile(self):
        for mode in ("late_model", "late_thinking"):
            FixtureWorker.mode = mode
            record = await self.run_case(mode)
            self.assertEqual(record["status"], "profile_mismatch", record)
            self.assertEqual(len(record["session"]["observedGenerations"]), 2)
            self.assertEqual(record["session"]["firstAssistant"]["provider"], "codex-pro")
            self.assertFalse(record["session"]["modelMatches"] if mode == "late_model" else
                             record["session"]["reasoningMatches"])

    async def test_timeouts_are_durable_and_only_stop_owned_worker(self):
        for mode in ("startup_timeout", "request_timeout"):
            FixtureWorker.mode = mode
            record = await runner.run_case(self.case, self.root / mode, timeout=0.04,
                startup_timeout=0.04, settlement_timeout=0.03, cleanup_timeout=0.02)
            self.assertEqual(record["status"], "timeout", record)
            self.assertEqual(record["errorCode"], mode)
            self.assertTrue(record["cleanup"]["forced"])
            self.assertFalse(record["cleanup"]["parkSent"])
            self.assertTrue(record["cleanup"]["shutdownRequested"])
            self.assertTrue((self.root / mode / "run.json").is_file())
            self.listener_closed(record)

    async def test_uncertain_cleanup_is_blocked_and_preserved(self):
        with patch.object(FixtureWorker, "pane_state", return_value="uncertain"):
            record = await self.run_case()
        self.assertEqual(record["cleanup"]["status"], "blocked")
        self.assertEqual(record["cleanup"]["code"], "ownership_uncertain")
        self.assertFalse(FixtureWorker.instances[-1].calls)
        self.assertTrue((self.root / "run/sessions").is_dir())
        self.listener_closed(record)

    async def test_invalid_assets_and_profiles_fail_without_listener_or_worker(self):
        self.case["assets"]["a"*64] = b"wrong"
        record = await self.run_case("bad_asset")
        self.assertEqual(record["errorCode"], "case_asset_integrity")
        record = await self.run_case("bad_profile", profile={**runner.BASELINE, "model": "gpt-6.1-sol-long"})
        self.assertEqual(record["errorCode"], "benchmark_profile")
        self.assertFalse(FixtureWorker.instances)

    async def test_existing_run_is_never_reused(self):
        await self.run_case()
        before = (self.root / "run/run.json").read_bytes()
        with self.assertRaises(FileExistsError):
            await self.run_case()
        self.assertEqual((self.root / "run/run.json").read_bytes(), before)

    def test_directory_and_triplet_use_full_frozen_verifier(self):
        self.assertEqual(runner.load_case(self.root / "frozen"), runner.load_case(self.case))
        with patch.object(cases, "verify_case", wraps=cases.verify_case) as verify:
            runner.load_case(self.root / "frozen")
            verify.assert_called_once_with(self.root / "frozen")
        bad = {**self.case, "manifest": {**self.case["manifest"], "contextSHA256": "a"*64}}
        with self.assertRaises(Problem) as error:
            runner.load_case(bad)
        self.assertEqual(error.exception.code, "case_integrity")
        bad = {**self.case, "manifest": {**self.case["manifest"], "identityMapping": {}}}
        with self.assertRaises(Problem) as error:
            runner.load_case(bad)
        self.assertEqual(error.exception.code, "case_identity")
        (self.root / "capture/context.json").write_bytes(b"{}")
        with self.assertRaises(Problem):
            runner.load_case(self.root / "capture")  # A raw/synthetic directory is never a frozen case.

    def test_case_directory_handoff_and_exact_assets(self):
        case_dir = self.root / "case"
        (case_dir / "assets").mkdir(parents=True)
        (case_dir / "case.json").write_bytes(encoded(self.case["manifest"]))
        (case_dir / "context.json").write_bytes(encoded(self.case["context"]))
        for digest, data in self.case["assets"].items():
            (case_dir / "assets" / digest).write_bytes(data)
        manifest, ctx, assets = runner.load_case(case_dir)
        self.assertEqual((manifest, ctx, assets), (self.case["manifest"], self.case["context"], self.case["assets"]))


class ProductionRegistryTests(unittest.TestCase):
    def test_spawn_uses_only_private_tmux_socket_group_and_exact_profile(self):
        with tempfile.TemporaryDirectory(dir=Path.home() / "tmp") as temp:
            root = Path(temp)
            store = Store(root / "state")
            registry = runner.BenchmarkWorkerRegistry(store, root / "workspace", "http://127.0.0.1:1234",
                                                       root / "token", run_root=root, profile=runner.BASELINE)
            worker = registry.reserve(uid())
            calls = []
            def tmux(args, **kwargs):
                calls.append(args)
                self.assertEqual(args[:5], ["tmux", "-f", "/dev/null", "-S", str(root / "tmux.sock")])
                self.assertNotIn("Draw-notes", args)
                op = args[5]
                if op == "new-session":
                    self.assertEqual(args[args.index("-s")+1], registry.group)
                    self.assertTrue(any("--model codex-pro/gpt-6.1-sol" in arg for arg in args))
                    output = "@1 %1"
                elif op == "display-message":
                    output = "123" if args[-1] == "#{pane_pid}" else "|".join(
                        [registry.group, "@1", registry.owner, worker["documentID"], "123"])
                else:
                    output = ""
                return subprocess.CompletedProcess(args, 0, output, "")
            with patch.object(runner.subprocess, "run", side_effect=tmux), patch.object(runner, "_tree", return_value={123: "owned"}):
                registry.spawn(worker["documentID"])
                self.assertTrue(registry.pane_owned(registry.get(worker["documentID"])))
            self.assertTrue(calls)
            with self.assertRaises(Problem) as error:
                registry.register({"sessionFile": str(root / "outside.jsonl")})
            self.assertEqual(error.exception.code, "session_escape")
            store.close()

    def test_lost_spawn_reply_recovers_only_tagged_private_server(self):
        with tempfile.TemporaryDirectory(dir=Path.home() / "tmp") as temp:
            root = Path(temp)
            store = Store(root / "state")
            registry = runner.BenchmarkWorkerRegistry(store, root / "workspace", "http://127.0.0.1:1234",
                root / "token", run_root=root, profile=runner.BASELINE)
            worker = registry.reserve(uid())
            stopped, calls = False, []
            def tmux(args, **kwargs):
                nonlocal stopped
                calls.append(args)
                self.assertEqual(args[:5], ["tmux", "-f", "/dev/null", "-S", str(registry.socket)])
                self.assertNotIn("Draw-notes", args)
                op = args[5]
                if op == "new-session":
                    self.assertIn("@draw_benchmark_source_pid", args)
                    raise subprocess.TimeoutExpired(args, 10)  # Server created; stdout was lost.
                if op == "list-panes":
                    output = "\t".join(["789", registry.group, "@1", "%1", "123", worker["cwd"],
                        registry.owner, str(runner.os.getpid()), "", "", "."])
                elif op == "kill-server":
                    stopped, output = True, ""
                else:
                    output = ""
                return subprocess.CompletedProcess(args, 0, output, "")
            def proc(pid):
                return ("server", "S") if pid == 789 else None if stopped else ("owned", "S")
            from types import SimpleNamespace
            manager = SimpleNamespace(worker_registry=registry, settled_at=None)
            with patch.object(runner.subprocess, "run", side_effect=tmux), patch.object(runner, "_proc", side_effect=proc), patch.object(
                    runner, "_tree", return_value={123: "owned"}):
                with self.assertRaises(subprocess.TimeoutExpired):
                    registry.spawn(worker["documentID"])
                self.assertIsNone(registry.get(worker["documentID"])["paneID"])
                report = asyncio.run(runner.cleanup_worker(manager, worker["documentID"], 0.01))
            self.assertTrue(report["launchAttempted"])
            self.assertTrue(report["launchUncertain"])
            self.assertTrue(report["privateServerStopped"])
            self.assertEqual(report["recoveredPanes"], ["%1"])
            self.assertEqual(report["status"], "stopped")
            self.assertTrue(any(args[5] == "kill-server" for args in calls))
            store.close()

    def test_lost_spawn_without_ownership_evidence_is_blocked(self):
        with tempfile.TemporaryDirectory(dir=Path.home() / "tmp") as temp:
            root = Path(temp)
            store = Store(root / "state")
            registry = runner.BenchmarkWorkerRegistry(store, root / "workspace", "http://127.0.0.1:1234",
                root / "token", run_root=root, profile=runner.BASELINE)
            worker = registry.reserve(uid())
            registry.launch_attempted = registry.launch_uncertain = True
            from types import SimpleNamespace
            manager = SimpleNamespace(worker_registry=registry)
            with patch.object(registry, "recover_launch", side_effect=Problem("benchmark_server_owner", "unknown")), patch.object(registry, "run") as tmux:
                report = asyncio.run(runner.cleanup_worker(manager, worker["documentID"], 0.01))
            self.assertEqual(report["status"], "blocked")
            self.assertTrue(report["launchUncertain"])
            tmux.assert_not_called()
            store.close()


class PreflightTests(unittest.IsolatedAsyncioTestCase):
    async def test_exact_authenticated_catalog_row_and_fast_forcer(self):
        with tempfile.TemporaryDirectory(dir=Path.home() / "tmp") as temp:
            path = Path(temp) / "extensions/cli-fast/index.ts"
            path.parent.mkdir(parents=True)
            path.write_bytes(b'reasoning: { ...reasoning, effort: "medium" }\nservice_tier: "priority"')
            with patch.dict(runner.os.environ, {"PI_CODING_AGENT_DIR": temp}), patch.object(runner, "_probe", AsyncMock(
                    side_effect=[(0, "codex-pro gpt-6.1-sol 256K 128K yes yes"), (0, "--fast")])):
                evidence = await runner.preflight(runner.BASELINE, temp)
            self.assertEqual(evidence["authentication"], "resolved_by_pi_getAvailable")
            self.assertFalse(evidence["fastForcer"]["wirePayloadObserved"])
            with patch.object(runner, "_probe", AsyncMock(return_value=(0, "codex-pro gpt-6.1-sol-long 1M"))):
                with self.assertRaises(Problem) as error:
                    await runner.preflight(runner.BASELINE, temp)
            self.assertEqual(error.exception.code, "baseline_unavailable")


class RenderObserverTests(unittest.IsolatedAsyncioTestCase):
    async def test_observer_retains_only_refs_without_reading_asset_bytes(self):
        with tempfile.TemporaryDirectory(dir=Path.home() / "tmp") as temp:
            manager = runner.TimedManager(Path(temp) / "state", None)
            manager.started = runner.time.perf_counter()
            page, result_hash, asset, preview = uid(), "a"*64, "b"*64, "c"*64
            response = {"objects": [{"asset": {"sha256": asset}}],
                        "previews": [{"pageID": page, "sha256": preview}]}
            with patch.object(manager, "_stage", AsyncMock(return_value=response)), patch.object(
                    manager.store, "request", return_value={"render": {"resultSHA256": result_hash}}), patch.object(
                    manager.store, "read_asset", side_effect=AssertionError("pre-ready byte read")) as read:
                await manager.render(uid(), {}, uid(), "fixture_lease")
                read.assert_not_called()
            self.assertEqual(manager.latest_render, {"resultSHA256": result_hash, "assets": [asset],
                                                     "previews": {page: preview}})
            self.assertTrue(manager.observer_events[0]["ok"])
            manager.close()


class ProcessIdentityTests(unittest.TestCase):
    def test_signals_only_verified_owned_pid_fingerprints(self):
        registry = object.__new__(runner.BenchmarkWorkerRegistry)
        registry.processes = {101: "old", 102: "owned", 103: "zombie"}
        values = {101: ("reused", "S"), 102: ("owned", "S"), 103: ("zombie", "Z")}
        with patch.object(runner, "_proc", side_effect=lambda pid: values.get(pid)), patch.object(runner.os, "kill") as kill:
            registry.signal_owned(signal.SIGTERM)
        kill.assert_called_once_with(102, signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
