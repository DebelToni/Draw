"""Isolated DGX request-to-approved-result benchmark using the production broker.

Handoff: await run_case(case_dir_or_dict, NEW_run_dir, timeout=600).
A dict has manifest, context (loaded dict), assets ({sha256: exact bytes}). A directory
has case.json (manifest), context.json, assets/<sha256>, verified by cases.verify_case.
Dict triplets are materialized privately and passed through the same verifier.
manifest.requestPrompt=None uses Manager.app_prompt unchanged; an explicit string
is a disclosed test-only override. Context IDs are already frozen/remapped by cases.

run.json is the durable, secret-free measurement. review/ contains canonical result
bytes, output assets and latest previews only. state/, workspace/, token and sessions/
are PRIVATE, never review exports. No applied acknowledgement or native-app claim.
Isolation is broker/state/session isolation, NOT a sandbox of normal global Pi tools.
Render-observer overhead is recorded separately but never subtracted from primary latency.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import signal
import socket
import subprocess
import tempfile
import time
from uuid import uuid4

from aiohttp import web
from . import cases
from notes_service.api import create_app
from notes_service.manager import Manager
from notes_service.renderer import Renderer
from notes_service.storage import Problem, atomic, decoded, encoded, require, sha
from notes_service.workerregistry import HEARTBEAT_SECONDS, WorkerRegistry

BASELINE = {"name": "sol-6.1-medium-fast", "provider": "codex-pro",
            "model": "gpt-6.1-sol", "thinking": "medium", "fast": True}
POLL_SECONDS = 0.05


def load_case(case):
    """Verify frozen files, including inventory, context digest and isolated IDs."""
    if not isinstance(case, dict):
        verified = cases.verify_case(case)
    else:
        # import_case returns a triplet. Use exactly the file verifier, not a weaker
        # in-memory admission path; synthetic unit inputs must also be frozen.
        temporary = Path.home() / "tmp"
        temporary.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="draw-case-verify-", dir=temporary) as temp:
            root = Path(temp)
            (root / "assets").mkdir(mode=0o700)
            atomic(root / "case.json", encoded(case["manifest"]))
            atomic(root / "context.json", encoded(case["context"]))
            for digest, data in case["assets"].items():
                sha(digest)
                require(isinstance(data, bytes), "case_structure", "Expected exact asset bytes")
                atomic(root / "assets" / digest, data)
            verified = cases.verify_case(root)
    return verified["manifest"], verified["context"], verified["assets"]


async def _probe(args, cwd):
    process = await asyncio.create_subprocess_exec(*args, cwd=cwd, stdout=asyncio.subprocess.PIPE,
                                                   stderr=asyncio.subprocess.PIPE, start_new_session=True)
    try:
        stdout, _ = await asyncio.wait_for(process.communicate(), 60)
        return process.returncode, stdout.decode(errors="replace")
    finally:
        if process.returncode is None:
            os.killpg(process.pid, signal.SIGKILL)  # New process group belongs only to this probe.
            await process.wait()


async def preflight(profile, cwd):
    """Pi --list-models uses getAvailable, including resolved provider authentication.

    No credential printing, auth-file copying, or API latency/cold-cache assertion.
    Stock `pi auth check` cannot resolve the installed custom codex-pro provider.
    """
    code, output = await _probe(["pi", "--list-models", profile["model"]], cwd)
    rows = [re.sub(r"\x1b\[[0-9;]*m", "", line).split() for line in output.splitlines()]
    require(code == 0 and any(row[:2] == [profile["provider"], profile["model"]] for row in rows),
            "baseline_unavailable", "Exact baseline absent from authenticated available catalog")
    code, help_text = await _probe(["pi", "--help"], cwd)
    require(code == 0 and "--fast" in help_text, "fast_unavailable", "CLI fast extension not loaded")
    path = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent")) / "extensions/cli-fast/index.ts"
    require(path.is_file(), "fast_unverified", "Installed CLI fast forcer is missing")
    source = path.read_bytes()
    require(b'reasoning: { ...reasoning, effort: "medium" }' in source and
            b'service_tier: "priority"' in source, "fast_unverified", "Installed CLI fast forcer differs")
    return {"availableCatalog": True, "authentication": "resolved_by_pi_getAvailable",
            "liveAPIProbe": False, "stockAuthCheck": "custom_provider_unsupported",
            "fastForcer": {"path": str(path), "sha256": hashlib.sha256(source).hexdigest(),
                           "wirePayloadObserved": False}}


class TimedManager(Manager):
    """Observe stage boundaries without replacing any production state transition."""
    def __init__(self, *args, request_prompt=None, **kwargs):
        super().__init__(*args, **kwargs)
        self.request_prompt = request_prompt
        self.started = None
        self.events = []
        self.ready_at = None
        self.settled_at = None
        self.heartbeats = set()
        self.latest_render = None
        self.observer_events = []

    def app_prompt(self, request):
        return super().app_prompt(request) if self.request_prompt is None else self.request_prompt

    async def create_request(self, body):
        self.started = time.perf_counter()  # Before creation, validation and worker delivery.
        return await super().create_request(body)

    async def _stage(self, name, method, *args):
        start, ok = time.perf_counter(), False
        try:
            result = await method(*args)
            ok = True
            if name == "approve" and result.get("status") == "ready" and self.ready_at is None:
                self.ready_at = time.perf_counter()
            return result
        finally:
            end = time.perf_counter()
            self.events.append({"stage": name, "startSeconds": start-self.started,
                                "endSeconds": end-self.started, "durationSeconds": end-start, "ok": ok})

    async def read(self, *args):
        return await self._stage("read", super().read, *args)

    async def draft(self, *args):
        return await self._stage("draft", super().draft, *args)

    def collect_artifacts(self):
        if self.latest_render is not None:
            self.store.stage([self.latest_render["resultSHA256"], *self.latest_render["assets"],
                              *self.latest_render["previews"].values()])
        return super().collect_artifacts()

    async def render(self, *args):
        result = await self._stage("render", super().render, *args)
        start, ok = time.perf_counter(), False
        try:
            # Retain refs in this isolated Store until export, even after failed
            # settlement. Large result/assets/previews are read only after timing.
            request = self.store.request(args[0])
            self.latest_render = {"resultSHA256": request["render"]["resultSHA256"],
                "assets": sorted({obj["asset"]["sha256"] for obj in result["objects"]}),
                "previews": {p["pageID"]: p["sha256"] for p in result["previews"]}}
            self.store.stage([self.latest_render["resultSHA256"], *self.latest_render["assets"],
                              *self.latest_render["previews"].values()])
            ok = True
        finally:
            end = time.perf_counter()
            self.observer_events.append({"stage": "render_observer", "startSeconds": start-self.started,
                "endSeconds": end-self.started, "durationSeconds": end-start, "ok": ok})
        return result

    async def approve(self, *args):
        return await self._stage("approve", super().approve, *args)

    async def worker_heartbeat(self, doc, lease, body):
        result = await super().worker_heartbeat(doc, lease, body)
        self.heartbeats.add(doc)  # Only successful authenticated heartbeats count.
        return result

    async def worker_event(self, doc, lease, body):
        result = await super().worker_event(doc, lease, body)
        if (body.get("event") == "agent_settled" and body.get("requestID") and
                body.get("eventID") and self.started is not None and self.settled_at is None):
            self.settled_at = time.perf_counter()
        return result


def _proc(pid):
    """Linux PID fingerprint, protecting against reuse during bounded owned cleanup."""
    try:
        tail = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return (tail[19], tail[0])  # starttime, state
    except (OSError, IndexError):
        return None


def _tree(pid):
    result, pending = {}, [pid]
    while pending:
        current = pending.pop()
        if current in result:
            continue
        identity = _proc(current)
        if identity is None:
            continue
        result[current] = identity[0]
        try:
            pending.extend(int(p) for p in Path(f"/proc/{current}/task/{current}/children").read_text().split())
        except OSError:
            pass
    return result


class BenchmarkWorkerRegistry(WorkerRegistry):
    """Production reservation/bridge/command, private tmux socket and owned pane."""
    def __init__(self, *args, run_root, profile, **kwargs):
        super().__init__(*args, **kwargs)
        self.run_root, self.profile = Path(run_root), profile
        self.socket = self.run_root / "tmux.sock"
        self.group = "Draw-bench-" + self.owner[:8]
        self.command_used = None
        self.processes = {}
        self.root_pid = None
        self.launch_attempted = self.launch_uncertain = False
        self.server_identity = None

    def register(self, body):
        path = body.get("sessionFile")
        require(isinstance(path, str) and Path(path).resolve().is_relative_to(self.run_root / "sessions"),
                "session_escape", "Worker session must stay inside this run's private sessions")
        return super().register(body)

    def command(self, worker):
        return super().command(worker) + ["--model", self.profile["provider"] + "/" + self.profile["model"],
                                         "--thinking", "medium", "--session-dir", str(self.run_root / "sessions"),
                                         "--force-model"]  # No shared provider-sync/recovery side effects.

    def tmux_args(self, *args):
        return [self.tmux, "-f", "/dev/null", "-S", str(self.socket), *args]

    def run(self, *args):
        result = subprocess.run(self.tmux_args(*args), capture_output=True,
                                text=True, timeout=10)
        require(result.returncode == 0, "benchmark_tmux", "Private owned tmux operation failed")
        return result.stdout.strip()

    def pane_state(self, worker):
        if not worker.get("paneID"):
            return "absent"
        result = subprocess.run(self.tmux_args("display-message", "-p", "-t",
                                 worker["paneID"], "#{session_name}|#{window_id}|#{@draw_owner}|#{@draw_document}|#{pane_pid}"),
                                capture_output=True, text=True, timeout=10)
        value = result.stdout.strip()
        prefix = "|".join((self.group, worker["windowID"], self.owner, worker["documentID"])) + "|"
        if result.returncode == 0 and value.startswith(prefix) and value[len(prefix):].isdigit():
            return "owned"
        # No terminal content or generic failure is treated as absence/ownership.
        if not value and (result.returncode == 0 or any(message in result.stderr.lower() for message in
                ("can't find pane", "no server running", "no such file or directory"))):
            return "absent"
        if value == "||||":  # tmux exact absent target may emit empty format fields.
            return "absent"
        return "uncertain"

    def pane_owned(self, worker):
        return self.pane_state(worker) == "owned"

    def spawn(self, doc):
        worker = self.get(doc)
        require(not worker["spawned"], "benchmark_fresh_session", "Benchmark cannot resume/replay")
        self.command_used = self.command(worker)
        require(not self.socket.exists() and not self.socket.is_symlink(),
                "benchmark_socket_reused", "Private launch socket must never be reused")
        self.launch_attempted = True  # Set BEFORE an operation that may lose its reply.
        try:
            window, pane = self.run("new-session", "-d", "-P", "-F", "#{window_id} #{pane_id}",
                "-s", self.group, "-n", worker["label"], "-c", worker["cwd"],
                "exec " + shlex.join(self.command_used),
                ";", "set-option", "-g", "@draw_benchmark_owner", self.owner,
                ";", "set-option", "-g", "@draw_benchmark_source_pid", str(os.getpid())).split()
            worker.update(windowID=window, paneID=pane, spawned=True)
            self.save(worker)
            self.run("set-option", "-w", "-t", window, "automatic-rename", "off")
            self.run("set-option", "-w", "-t", window, "@draw_owner", self.owner)
            self.run("set-option", "-w", "-t", window, "@draw_document", doc)
            require(self.pane_owned(worker), "benchmark_owner", "Pane ownership not proven")
            self.root_pid = int(self.run("display-message", "-p", "-t", pane, "#{pane_pid}"))
            self.processes = _tree(self.root_pid)
            require(self.root_pid in self.processes, "benchmark_process", "Owned process root not proven")
            return worker
        except BaseException:
            self.launch_uncertain = True
            raise

    def recover_launch(self, worker):
        """Recover a lost new-session reply only from this fresh private server's tags."""
        fields = ("pid", "session_name", "window_id", "pane_id", "pane_pid", "pane_current_path",
                  "@draw_benchmark_owner", "@draw_benchmark_source_pid", "@draw_owner", "@draw_document")
        rows = [line.split("\t") for line in self.run("list-panes", "-a", "-F",
                "\t".join("#{"+field+"}" for field in fields)+"\t.").splitlines()]
        require(rows and all(len(r) == len(fields)+1 and r[-1] == "." and r[1] == self.group and r[5] == worker["cwd"] and
                r[6:8] == [self.owner, str(os.getpid())] and r[8] in ("", self.owner) and
                r[9] in ("", worker["documentID"]) for r in rows),
                "benchmark_server_owner", "Private server ownership is uncertain")
        server = int(rows[0][0])
        identity = _proc(server)
        require(identity is not None and all(r[0] == str(server) for r in rows) and
                self.server_identity in (None, (server, identity[0])),
                "benchmark_server_owner", "Private server PID identity changed")
        self.server_identity = (server, identity[0])
        for row in rows:
            self.processes.update(_tree(int(row[4])))
        worker.update(windowID=rows[0][2], paneID=rows[0][3], spawned=True)
        self.save(worker)
        return [r[3] for r in rows]

    def capture_processes(self):
        if self.root_pid is not None:
            current = _proc(self.root_pid)
            if current and current[0] == self.processes.get(self.root_pid):
                self.processes.update(_tree(self.root_pid))

    def processes_alive(self):
        return [pid for pid, identity in self.processes.items()
                if (current := _proc(pid)) and current[0] == identity and current[1] != "Z"]

    def signal_owned(self, sig):
        # Children before parent. No name-based process lookup or shared process group.
        for pid in reversed(list(self.processes)):
            current = _proc(pid)
            if current and current[0] == self.processes[pid] and current[1] != "Z":
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass


def idle(manager, doc):
    worker = manager.worker_registry.get(doc)
    return (doc in manager.heartbeats and worker.get("lease") is not None and
            0 <= manager.clock()-worker["heartbeat"] <= HEARTBEAT_SECONDS and
            worker.get("busy") is False and worker.get("pending") is False and
            worker.get("inputObserved") is True and worker.get("activeRequestID") is None)


async def wait_until(predicate, seconds, code):
    deadline = time.perf_counter() + seconds
    while not predicate():
        if time.perf_counter() >= deadline:
            raise Problem(code, "Bounded benchmark wait expired")
        await asyncio.sleep(POLL_SECONDS)


async def cleanup_worker(manager, doc, seconds):
    registry = manager.worker_registry
    worker = registry.store.record("worker", doc)
    report = {"status": "not_started", "forced": False, "shutdownRequested": False, "parkSent": False,
              "launchAttempted": registry.launch_attempted, "launchUncertain": registry.launch_uncertain}
    if registry.launch_uncertain:
        try:
            report["recoveredPanes"] = registry.recover_launch(worker)
            registry.recover_launch(worker)  # Recheck exact server fingerprint before killing it.
            registry.run("kill-server")  # tmux_args ALWAYS targets only this owned private socket.
            report.update(forced=True, privateServerStopped=True)
        except Exception:
            return {**report, "status": "blocked", "code": "launch_cleanup_uncertain"}
    if not worker or not worker.get("paneID"):
        return {**report, "status": "blocked", "code": "launch_cleanup_uncertain"} if registry.launch_attempted else report
    registry.capture_processes()
    state = registry.pane_state(worker)
    if state == "uncertain":
        return {**report, "status": "blocked", "code": "ownership_uncertain"}
    if state == "owned":
        # Timeout may still be busy. Request shutdown; never send /park into a model turn.
        worker["shutdownRequested"] = True
        registry.save(worker)
        report["shutdownRequested"] = True
        if manager.settled_at is not None and idle(manager, doc):
            registry.run("send-keys", "-t", worker["paneID"], "-l", "/park")
            registry.run("send-keys", "-t", worker["paneID"], "C-m")
            report["parkSent"] = True
        deadline = time.perf_counter() + seconds
        while time.perf_counter() < deadline:
            registry.capture_processes()
            state = registry.pane_state(worker)
            if state != "owned":
                break
            await asyncio.sleep(POLL_SECONDS)
        if state == "uncertain":
            return {**report, "status": "blocked", "code": "ownership_uncertain"}
        if state == "owned":
            registry.capture_processes()
            # Recheck exact socket/session/window/owner/document immediately before stopping.
            if not registry.pane_owned(worker):
                return {**report, "status": "blocked", "code": "ownership_uncertain"}
            registry.run("kill-pane", "-t", worker["paneID"])
            report["forced"] = True
    if registry.processes_alive():
        report["forced"] = True
        registry.signal_owned(signal.SIGTERM)
        await asyncio.sleep(min(seconds, 0.5))
        registry.signal_owned(signal.SIGKILL)
        try:
            await wait_until(lambda: not registry.processes_alive(), seconds, "owned_processes_remain")
        except Problem:
            return {**report, "status": "blocked", "code": "owned_processes_remain"}
    state = registry.pane_state(worker)
    report["status"] = "stopped" if state == "absent" else "blocked"
    if report["status"] == "blocked":
        report["code"] = "pane_exit_uncertain"
    return report


def session_evidence(registry, doc, profile):
    worker = registry.get(doc)
    path = worker.get("sessionFile")
    evidence = {"sessionID": worker["sessionID"], "sessionFile": path,
                "firstAssistant": None, "thinkingChanges": [], "observedGenerations": [],
                "modelMatches": False, "reasoningMatches": False, "wirePayloadObserved": False}
    if not path:
        return evidence
    require(Path(path).resolve().is_relative_to(registry.run_root / "sessions"),
            "session_escape", "Worker session escaped the isolated session directory")
    registry.verify_header(worker)
    thinking = None
    with open(path) as stream:
        for line in stream:
            entry = json.loads(line)
            if entry.get("type") == "thinking_level_change":
                thinking = entry.get("thinkingLevel")
                evidence["thinkingChanges"].append(thinking)
            message = entry.get("message", {})
            if entry.get("type") == "message" and message.get("role") == "assistant":
                observed = {key: message[key] for key in
                    ("provider", "model", "thinkingLevel", "providerThinkingLevel") if key in message}
                if evidence["firstAssistant"] is None:
                    evidence["firstAssistant"] = dict(observed)
                observed["sessionThinkingLevel"] = thinking
                evidence["observedGenerations"].append(observed)
    generations = evidence["observedGenerations"]
    evidence["modelMatches"] = bool(generations) and all(g.get("provider") == profile["provider"] and
        g.get("model") == profile["model"] for g in generations)
    levels = [[g[k] for k in ("thinkingLevel", "providerThinkingLevel", "sessionThinkingLevel")
               if g.get(k) is not None] for g in generations]
    evidence["reasoningEvidenceComplete"] = bool(levels) and all(levels)
    evidence["reasoningMatches"] = bool(evidence["reasoningEvidenceComplete"]) and all(
        level == profile["thinking"] for row in levels for level in row)
    evidence["reasoningConsistent"] = False if any(level != profile["thinking"] for row in levels for level in row) else (
        True if evidence["reasoningEvidenceComplete"] else None)
    return evidence


def export_result(manager, rid, client, root):
    request = manager.store.request(rid)
    review = root / "review"
    snapshot = manager.latest_render
    if request["status"] == "ready":
        data = manager.result(rid, client)  # The real broker's canonical exact-byte result.
        require(snapshot is not None and snapshot["resultSHA256"] == hashlib.sha256(data).hexdigest(),
                "benchmark_result_integrity", "Approved result differs from latest canonical render")
        atomic(review / "result.json", data)
    elif snapshot is not None:
        data = manager.store.read_asset(snapshot["resultSHA256"])
        atomic(review / "rendered-not-approved.json", data)
    else:
        return {"resultSHA256": None, "previewSHA256s": {}, "reviewDirectory": None}
    value = decoded(data)
    for digest in snapshot["assets"]:
        atomic(review / "assets" / digest, manager.store.read_asset(digest))
    for page, digest in snapshot["previews"].items():
        atomic(review / "previews" / (page + ".png"), manager.store.read_asset(digest))
    return {"resultSHA256": request.get("resultSHA256"),
            "latestRenderedSHA256": hashlib.sha256(data).hexdigest(),
            "previewSHA256s": value["previewSHA256s"], "reviewDirectory": str(review)}


async def run_case(case_dir, run_dir, profile=None, *, timeout=600, startup_timeout=300,
                   settlement_timeout=60, cleanup_timeout=10):
    """One fresh interactive worker/store, bounded waits, no production source access.

    profile is None or the exact BASELINE dict; no alternate-model fallback. run_dir
    MUST NOT exist. Returns the same secret-free dict durably written to run.json.
    Ready latency excludes startup and settlement. Quality is left for separate Sol
    OK/notOK review, not scored by this runner. Paths are retained on every failure.
    """
    require(all(isinstance(n, (int, float)) and 0 < n <= 3600 for n in
                (timeout, startup_timeout, settlement_timeout, cleanup_timeout)),
            "benchmark_deadline", "Deadlines must be positive and bounded to one hour")
    root = Path(run_dir).absolute()
    root.mkdir(parents=True, mode=0o700, exist_ok=False)
    root = root.resolve()
    record = {"format": 1, "status": "starting", "runDirectory": str(root),
              "profile": dict(BASELINE), "providerCacheConditions": "unknown",
              "nativeApplication": False, "quality": {"status": "unreviewed", "verdict": None},
              "timings": {}, "cleanup": {"status": "not_started"}}
    atomic(root / "run.json", encoded(record))
    manager = runner = sock = observer = None
    startup_start = None
    doc = rid = client = None
    cancelled = False
    try:
        selected = dict(BASELINE if profile is None else profile)
        require(selected == BASELINE, "benchmark_profile", "Only exact Sol 6.1 medium fast baseline is assigned")
        manifest, context, assets = load_case(case_dir)
        record["caseSHA256"] = hashlib.sha256(encoded(manifest)).hexdigest()
        record["promptOverride"] = manifest.get("requestPrompt") is not None
        record["promptMode"] = "explicit_test_query" if record["promptOverride"] else "production_app_prompt"
        doc = context["documentID"]
        rid, client = str(uuid4()).upper(), str(uuid4()).upper()
        record.update(documentID=doc, focusPageID=context["focusPageID"], requestID=rid, clientID=client)
        (root / "sessions").mkdir(mode=0o700)
        token = secrets.token_urlsafe(48)
        atomic(root / "token", token.encode())
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind(("127.0.0.1", 0))  # Bind once; never reserve/reopen a guessed free port.
        sock.setblocking(False)
        url = f"http://127.0.0.1:{sock.getsockname()[1]}"
        record["brokerURL"] = url
        manager = TimedManager(root / "state", None, source=None, workspace=root / "workspace",
                               token_file=root / "token", url=url, request_prompt=manifest.get("requestPrompt"))
        manager.renderer = Renderer(manager.store.read_asset)
        manager.worker_registry = BenchmarkWorkerRegistry(manager.store, root / "workspace", url,
            root / "token", run_root=root, profile=selected)
        for digest, data in assets.items():
            manager.store.put_asset(digest, data)
        context_sha = manager.store.put_bytes(encoded(context))
        record["contextSHA256"] = context_sha
        manager.validate_context(context_sha, doc, context["focusPageID"])
        manager.register_client({"clientID": client})
        await manager.ensure_worker(doc, context)
        runner = web.AppRunner(create_app(manager, token, spawn_workers=False), shutdown_timeout=cleanup_timeout)
        await runner.setup()
        await web.SockSite(runner, sock).start()
        record["preflight"] = await preflight(selected, root)
        startup_start = time.perf_counter()
        manager.worker_registry.spawn(doc)  # Store SQLite belongs to this event-loop thread.
        async def observe_owned_tree():
            while True:
                manager.worker_registry.capture_processes()
                await asyncio.sleep(POLL_SECONDS)
        observer = asyncio.create_task(observe_owned_tree())
        record["command"] = manager.worker_registry.command_used
        await wait_until(lambda: idle(manager, doc), max(0, startup_timeout-(time.perf_counter()-startup_start)),
                         "startup_timeout")
        record["timings"]["workerStartupSeconds"] = time.perf_counter()-startup_start
        record["status"] = "running"
        atomic(root / "run.json", encoded(record))
        body = {"requestID": rid, "documentID": doc, "focusPageID": context["focusPageID"],
                "contextSHA256": context_sha, "origin": "app", "clientID": client}
        await asyncio.wait_for(manager.create_request(body), timeout)
        await wait_until(lambda: manager.store.request(rid)["status"] not in ("queued", "running"),
                         max(0, timeout-(time.perf_counter()-manager.started)), "request_timeout")
        request = manager.store.request(rid)
        record["status"] = request["status"]
        if request.get("error"):
            record["errorCode"] = request["error"]["code"]
        if manager.ready_at is not None:
            record["timings"]["requestToReadySeconds"] = manager.ready_at-manager.started
        # A ready result remains ready even if the separate cleanup/settlement wait fails.
        try:
            await wait_until(lambda: manager.settled_at is not None and idle(manager, doc),
                             settlement_timeout, "settlement_timeout")
        except Problem as error:
            record["settlementErrorCode"] = error.code
        record["session"] = session_evidence(manager.worker_registry, doc, selected)
        if record["status"] == "ready" and not (record["session"]["modelMatches"] and record["session"]["reasoningMatches"]):
            record.update(status="profile_mismatch", errorCode="resolved_profile_mismatch")
    except asyncio.CancelledError:
        cancelled = True
        record.update(status="cancelled", errorCode="runner_cancelled")
    except Exception as error:
        record.update(status="timeout" if isinstance(error, (TimeoutError, Problem)) and
                      (isinstance(error, TimeoutError) or error.code.endswith("timeout")) else "failed",
                      errorCode=error.code if isinstance(error, Problem) else
                      "request_timeout" if isinstance(error, TimeoutError) else "runner_error")
        # Raw exception strings can contain prompts, tool output and credentials.
    finally:
        if observer is not None:
            observer.cancel()
            try:
                await observer
            except asyncio.CancelledError:
                pass
        if startup_start is not None and "workerStartupSeconds" not in record["timings"]:
            record["timings"]["workerStartupAttemptSeconds"] = time.perf_counter()-startup_start
        if manager is not None:
            registry = manager.worker_registry
            record["command"] = getattr(registry, "command_used", None)
            record.update(launchAttempted=getattr(registry, "launch_attempted", False),
                          launchUncertain=getattr(registry, "launch_uncertain", False))
            record["timings"]["stages"] = manager.events
            record["timings"]["observers"] = manager.observer_events
            record["timings"]["observerOverheadSeconds"] = sum(e["durationSeconds"] for e in manager.observer_events)
            record["timings"]["observerOverheadIncludedInPrimary"] = True
            if manager.ready_at is not None:
                record["timings"]["requestToReadySeconds"] = manager.ready_at-manager.started
            if manager.started is not None:
                record["timings"]["observedRequestSeconds"] = time.perf_counter()-manager.started
            if manager.settled_at is not None:
                record["timings"]["requestToSettledSeconds"] = manager.settled_at-manager.started
                if manager.ready_at is not None:
                    record["timings"]["readyToSettledSeconds"] = manager.settled_at-manager.ready_at
            if rid is not None and manager.store.requests():
                try:
                    record["artifacts"] = export_result(manager, rid, client, root)
                except Exception:
                    record["artifactErrorCode"] = "artifact_export_failed"
            if doc is not None:
                try:
                    record["cleanup"] = await cleanup_worker(manager, doc, cleanup_timeout)
                except Exception:
                    record["cleanup"] = {"status": "blocked", "code": "cleanup_error"}
                try:
                    record["session"] = session_evidence(registry, doc, record["profile"])
                except Exception:
                    record["sessionEvidenceErrorCode"] = "session_evidence_unavailable"
        try:
            if runner is not None:
                await asyncio.wait_for(runner.cleanup(), cleanup_timeout+1)
        except Exception:
            record["brokerCleanupErrorCode"] = "broker_cleanup_failed"
        finally:
            if sock is not None:
                sock.close()
            record["listenerClosed"] = True
            if manager is not None:
                manager.close()
            # All raw sessions/descriptors/store/leases remain private, never copied to review/.
            for path in root.rglob("*"):
                if path.is_file() and not path.is_symlink():
                    path.chmod(0o600)
            atomic(root / "run.json", encoded(record))
    if cancelled:
        raise asyncio.CancelledError
    return record
