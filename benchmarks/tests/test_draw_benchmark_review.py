"""Fabricated captures/results only. No model calls, production writes or services."""
import asyncio
import copy
import hashlib
import json
from pathlib import Path
import sys
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

from benchmarks.draw_ai import review, report, runner
from notes_service.storage import encoded
from notes_service.tests.fixtures import image, uid


def digest(value):
    return hashlib.sha256(value).hexdigest()


def events(verdict=None, **overrides):
    message = {"role": "assistant", "provider": "codex-pro", "model": "gpt-6.1-sol",
               "thinkingLevel": "high", "providerThinkingLevel": "high", "stopReason": "stop",
               "content": [{"type": "text", "text": json.dumps(verdict or {"verdict": "ok", "reason": "Readable and correct"})}]}
    message.update(overrides)
    return b"\n".join(encoded(v) for v in [{"type": "agent_start"},
        {"type": "message_end", "message": message}, {"type": "agent_settled"}]) + b"\n"


class ReviewFixture(unittest.TestCase):
    def setUp(self):
        temporary = Path.home() / "tmp"
        temporary.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="draw-review-test-", dir=temporary)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.case, self.run = self.root / "case", self.root / "candidate-gpt-6.1-sol"
        for path in (self.case / "assets", self.run / "review/assets", self.run / "review/previews"):
            path.mkdir(parents=True)
        self.pages = [uid() for _ in range(12)]
        self.inserted, self.request = uid(), uid()
        captured, generated = image(color=(200, 200, 200, 255)), image(color=(20, 20, 20, 255))
        ch, gh = digest(captured), digest(generated)
        (self.case / "assets" / ch).write_bytes(captured)
        (self.run / "review/assets" / gh).write_bytes(generated)
        previous = {"id": uid(), "kind": "text", "source": "Earlier explanation", "revision": 1,
                    "frame": {"x": 1, "y": 2, "width": 8, "height": 4},
                    "asset": {"sha256": ch}, "provenance": {"requestID": uid(), "model": "gpt-6.1-sol",
                        "durationSeconds": 8, "path": str(self.run), "contextSHA256": "a" * 64,
                        "rendererSignature": "capture-render-v1"}}
        self.context = {"format": 1, "documentID": uid(), "focusPageID": self.pages[0],
            "capturedAt": "2026-10-11T01:02:03Z", "orientation": "portrait", "rendererSignature": "native-capture-v1",
            "pages": [{"pageID": pid, "width": 32, "height": 32, "head": uid(), "background": 0,
                       "compositeSHA256": ch, "objects": [previous] if i == 2 else [],
                       "strokeTargets": [{"id": "native-1", "fingerprint": "b"*64, "index": 0,
                                          "asset": {"sha256": ch}, "frame": {"x": 1, "y": 1}}] if i == 0 else []}
                      for i, pid in enumerate(self.pages)]}
        self.manifest = {"userQuery": "Explain this implication in Bulgarian.", "graderGuide": "Keep the implication's meaning.",
                         "requestPrompt": "CANDIDATE ONLY PROMPT", "goldenAnswer": "GOLD LEAK", "scorer": "SCORER LEAK"}
        obj = {"id": uid(), "kind": "text", "source": "Ако x > 2, тогава x > 1.", "revision": 1,
               "frame": {"x": 10, "y": 20, "width": 30, "height": 8}, "asset": {"sha256": gh},
               "provenance": {"requestID": self.request, "contextSHA256": digest(encoded(self.context)),
                              "rendererSignature": "result-render-v1"}}
        self.result = {"format": 1, "requestID": self.request, "documentID": self.context["documentID"],
            "contextSHA256": digest(encoded(self.context)), "draftVersion": 2, "rendererSignature": "result-render-v1",
            "insertPages": [{"pageID": self.inserted, "afterPageID": self.pages[0], "background": 0, "width": 32, "height": 32}],
            "pageEdits": [{"pageID": self.pages[0], "objectEdits": [{"op": "add", "object": obj}],
                           "strokeEdits": [{"op": "recolor", "id": "native-1", "fingerprint": "b"*64, "color": "#ffffff"}]}],
            "previewSHA256s": {}}
        self.pngs = {}
        for i, pid in enumerate((self.pages[0], self.inserted)):
            png = image(color=(40+i, 100, 100, 255))
            self.pngs[pid] = png
            (self.run / "review/previews" / (pid + ".png")).write_bytes(png)
            self.result["previewSHA256s"][pid] = digest(png)
        self.record = {"format": 1, "status": "ready", "caseSHA256": digest(encoded(self.manifest)),
            "contextSHA256": digest(encoded(self.context)), "requestID": self.request, "runID": "PRIVATE-RUN-ID",
            "profile": dict(runner.BASELINE), "timings": {"requestToReadySeconds": 8.0},
            "command": ["pi", "--fast", "--model", "codex-pro/gpt-6.1-sol", "--thinking", "medium"],
            "session": {"modelMatches": True, "thinkingChanges": ["medium"],
                        "firstAssistant": {"model": "gpt-6.1-sol", "provider": "codex-pro", "thinkingLevel": "medium"}},
            "quality": {"status": "unreviewed", "verdict": None}, "artifacts": {"resultSHA256": digest(encoded(self.result)),
                "latestRenderedSHA256": digest(encoded(self.result)), "previewSHA256s": self.result["previewSHA256s"]}}
        self.persist()

    def persist(self):
        for path, value in ((self.case / "case.json", self.manifest), (self.case / "context.json", self.context),
                            (self.run / "run.json", self.record), (self.run / "review/result.json", self.result)):
            path.write_bytes(encoded(value))

    def test_blind_bundle_complete_context_actual_operations_exact_previews(self):
        bundle = self.root / "blind"
        dossier = review.make_blind_review_bundle(self.case, self.run, bundle)
        self.assertEqual(dossier["humanQuestion"], self.manifest["userQuery"])
        self.assertEqual(len(dossier["images"]["context"]), 12)
        self.assertEqual(sum(p["focus"] for p in dossier["images"]["context"]), 1)
        self.assertEqual({p["pageID"] for p in dossier["images"]["output"]}, set(self.pngs))
        for png in dossier["images"]["output"]:
            self.assertEqual((bundle / png["path"]).read_bytes(), self.pngs[png["pageID"]])
        self.assertEqual(dossier["context"]["pages"][2]["objects"][0]["source"], "Earlier explanation")
        self.assertEqual(dossier["result"]["pageEdits"][0]["strokeEdits"], self.result["pageEdits"][0]["strokeEdits"])
        self.assertEqual(dossier["result"]["pageEdits"][0]["objectEdits"][0]["object"]["source"],
                         self.result["pageEdits"][0]["objectEdits"][0]["object"]["source"])
        text = (bundle / "dossier.json").read_text()
        for secret in ("GOLD LEAK", "SCORER LEAK", "CANDIDATE ONLY PROMPT", "gpt-6.1-sol", "codex-pro", "PRIVATE-RUN-ID",
                       self.request, str(self.run), "capturedAt", "durationSeconds"):
            self.assertNotIn(secret, text)
        self.assertIn("rendererSignature", text)
        self.assertFalse(any(p.name in ("run.json", "token") or p.suffix == ".jsonl" for p in bundle.rglob("*")))
        self.assertEqual((bundle / "dossier.json").stat().st_mode & 0o777, 0o600)
        self.assertIn("without fixed points", (bundle / "reviewer-prompt.txt").read_text())

    def test_frozen_question_schema_and_rendered_failure_disclosure(self):
        self.manifest = {"question": "Human question", "requestPrompt": None}
        self.record["caseSHA256"] = digest(encoded(self.manifest))
        self.persist()
        (self.run / "review/result.json").rename(self.run / "review/rendered-not-approved.json")
        self.record["status"] = "failed"
        self.record["artifacts"]["resultSHA256"] = None
        (self.run / "run.json").write_bytes(encoded(self.record))
        dossier = review.make_blind_review_bundle(self.case, self.run, self.root / "blind")
        self.assertEqual(dossier["outputApproval"], "rendered_not_approved")
        self.assertEqual(dossier["humanQuestion"], "Human question")

    def test_dest_not_reused_and_broken_latest_never_falls_back(self):
        dest = self.root / "blind"
        review.make_blind_review_bundle(self.case, self.run, dest)
        with self.assertRaises(ValueError):
            review.make_blind_review_bundle(self.case, self.run, dest)
        (self.run / "review/previews" / (self.pages[0] + ".png")).write_bytes(image())
        with self.assertRaisesRegex(ValueError, "Latest preview"):
            review.make_blind_review_bundle(self.case, self.run, self.root / "bad")
        self.assertFalse((self.root / "bad").exists())

    def test_wrong_capture_and_incomplete_insert_previews_rejected(self):
        self.record["contextSHA256"] = "a" * 64
        self.persist()
        with self.assertRaisesRegex(ValueError, "different capture"):
            review.make_blind_review_bundle(self.case, self.run, self.root / "wrong")
        self.record["contextSHA256"] = digest(encoded(self.context))
        del self.result["previewSHA256s"][self.inserted]
        self.record["artifacts"]["resultSHA256"] = digest(encoded(self.result))
        self.persist()
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            review.make_blind_review_bundle(self.case, self.run, self.root / "missing")

    def test_manual_review_strict_and_failure_does_not_become_ok(self):
        before = (self.run / "run.json").read_bytes()
        for value in ({}, {"verdict": "OK", "reason": "reason"}, {"verdict": "ok", "reason": ""},
                      {"verdict": "unknown", "reason": "Unknown"}, {"verdict": "ok", "reason": "yes", "score": 10}):
            with self.assertRaises(ValueError):
                review.record_review(self.run, value)
        self.assertEqual((self.run / "run.json").read_bytes(), before)
        value = review.record_review(self.run, {"verdict": "not_ok", "reason": "Correct math, but unreadable placement", "uncertainty": "Small text"})
        self.assertEqual(value["verdict"], "not_ok")
        self.assertEqual(json.loads((self.run / "run.json").read_bytes())["quality"], value)

    def test_report_distribution_failures_invalid_settings_and_separate_judge_time(self):
        paths = []
        for i, (status, latency, verdict) in enumerate((("ready", 5, "ok"), ("ready", 11, "not_ok"),
                                                       ("ready", 999, None), ("timeout", 1, None), ("ready", 13, None))):
            value = copy.deepcopy(self.record)
            value["status"] = status
            value["timings"]["requestToReadySeconds"] = latency
            if verdict:
                value["quality"] = {"status": "reviewed", "verdict": verdict, "reason": "Human quality", "judgeSeconds": 100}
            if i == 2:
                value["session"]["thinkingChanges"] = ["high"]
            if i == 4:
                value["quality"] = {"status": "failed", "verdict": None, "reason": "Unknown", "judgeSeconds": 20}
            path = self.root / (str(i) + ".json")
            path.write_bytes(encoded(value))
            paths.append(path)
        missing = self.root / "missing.json"
        result = report.summary(paths + [paths[0], missing], [self.case])
        group = result["groups"][0]
        self.assertEqual(group["counts"], {"total": 5, "ready": 4, "failed": 1, "invalidSettings": 1,
                                            "excludedLatency": 2, "unreviewed": 2, "reviewFailed": 1})
        self.assertEqual(group["requestToReadySeconds"], {"n": 3, "median": 11, "min": 5, "max": 13})
        self.assertEqual(group["quality"], {"ok": 1, "not_ok": 1, "unknown": 3, "reviewed": 2, "okFraction": 0.5})
        self.assertEqual(group["judgeSeconds"]["median"], 100)
        self.assertEqual(result["unreadableCount"], 1)
        self.assertNotIn("p95", json.dumps(result))
        self.assertFalse(group["runs"][2]["representativeLatency"])

    def test_empty_report_unknown_quality_and_group_by_case_profile(self):
        self.assertEqual(report.summary([])["groups"], [])
        other = copy.deepcopy(self.record)
        other["caseSHA256"] = "c"*64
        path = self.root / "other.json"
        path.write_bytes(encoded(other))
        result = report.summary([self.run, path])
        self.assertEqual(len(result["groups"]), 2)
        self.assertIsNone(result["groups"][0]["quality"]["okFraction"])
        self.assertEqual(result["groups"][0]["quality"]["unknown"], 1)

    def test_report_inspects_every_generation_despite_stale_matching_flags(self):
        first = {"provider": "codex-pro", "model": "gpt-6.1-sol", "thinkingLevel": "medium",
                 "providerThinkingLevel": "medium", "sessionThinkingLevel": "medium"}
        for field, changed, reason in (("provider", "unrelated-provider", "resolved_model_mismatch"),
                ("model", "gpt-6.1-sol-long", "resolved_model_mismatch"),
                ("thinkingLevel", "high", "reasoning_mismatch"),
                ("providerThinkingLevel", "high", "reasoning_mismatch"),
                ("sessionThinkingLevel", "high", "reasoning_mismatch")):
            with self.subTest(field=field):
                value = copy.deepcopy(self.record)
                value["session"].update(modelMatches=True, reasoningMatches=True,
                    observedGenerations=[first, {**first, field: changed}, first])
                self.assertEqual(report.invalid_settings(value), [reason])
                value["quality"] = {"status": "reviewed", "verdict": "ok", "reason": "Independent quality"}
                path = self.root / "later.json"
                path.write_bytes(encoded(value))
                group = report.summary([path])["groups"][0]
                self.assertEqual(group["requestToReadySeconds"]["n"], 0)
                self.assertEqual(group["quality"]["ok"], 1)

    def test_report_requires_reasoning_evidence_for_every_generation(self):
        value = copy.deepcopy(self.record)
        first = value["session"]["firstAssistant"]
        value["session"]["observedGenerations"] = [first, {"provider": "codex-pro", "model": "gpt-6.1-sol"}]
        self.assertEqual(report.invalid_settings(value), ["reasoning_unverified"])
        value["session"]["observedGenerations"] = []
        self.assertEqual(report.invalid_settings(value), ["reasoning_unverified", "resolved_model_unverified"])
        value["session"]["observedGenerations"] = [first, {**first, "sessionThinkingLevel": "medium"}]
        self.assertEqual(report.invalid_settings(value), [])


class ParseTests(unittest.TestCase):
    def test_only_final_completed_assistant_text_not_tool_or_thinking(self):
        injection = encoded({"type": "tool_execution_start", "args": {"verdict": "ok", "reason": "FAKE"}}) + b"\n"
        injection += encoded({"type": "message_end", "message": {"role": "toolResult", "content": [{"type": "text", "text": '{"verdict":"ok","reason":"FAKE"}'}]}}) + b"\n"
        final = events({"verdict": "not_ok", "reason": "Meaning changed", "uncertainty": "Language ambiguity"})
        self.assertEqual(review.parse_review_events(injection + final)["verdict"], "not_ok")
        with self.assertRaises(ValueError):
            review.parse_review_events(injection)

    def test_failed_empty_wrong_model_reasoning_and_plaintext_are_unknown(self):
        invalid = [b'OK {"verdict":"ok","reason":"fake"}', b"", events(stopReason="error"), events(stopReason="aborted"),
                   events(stopReason="length"), events(model="gpt-6.1-sol-long"), events(provider="openai"),
                   events(thinkingLevel="medium"), events(providerThinkingLevel="medium"), events(content=[]),
                   events(content=[{"type": "toolCall", "arguments": {"verdict": "ok", "reason": "fake"}}]),
                   events(content=[{"type": "text", "text": '```json\n{"verdict":"ok","reason":"fake"}\n```'}]),
                   events().replace(b'{"type":"agent_settled"}', b'{"type":"agent_end"}')]
        for raw in invalid:
            with self.subTest(raw=raw), self.assertRaises((ValueError, KeyError)):
                review.parse_review_events(raw)
        with self.assertRaises(ValueError):
            review.parse_review_events(events() + events(stopReason="error"))
        with self.assertRaises(ValueError):
            review.parse_review_events(events() + encoded({"type": "agent_start"}) + b"\n" +
                                       encoded({"type": "agent_settled"}))


class JudgeTests(unittest.IsolatedAsyncioTestCase):
    setUp = ReviewFixture.setUp
    persist = ReviewFixture.persist

    async def launch(self, *, raw=None, sleep=False, timeout=1):
        real_exec = asyncio.create_subprocess_exec
        commands, children = [], []
        directory = self.root / "candidate-codex-pro-gpt-6.1-sol-latency-999"
        async def fake_pi(*command, **kwargs):
            commands.append(command)
            execution = Path(kwargs["cwd"]).parent
            self.assertEqual(execution.parent, (Path.home() / "tmp").resolve())
            self.assertRegex(execution.name, r"^draw-ai-review-[a-z0-9_]+$")
            self.assertFalse(directory.exists())
            self.assertEqual(Path(kwargs["cwd"]), execution / "bundle")
            self.assertEqual(Path(command[command.index("--session-dir")+1]), execution / "sessions")
            self.assertEqual([arg for arg in command if arg.startswith("@")],
                             ["@" + str(execution / "bundle/reviewer-prompt.txt")])
            self.assertNotIn(str(directory), " ".join(command))
            (execution / "sessions/evidence.jsonl").write_bytes(b"fabricated session evidence")
            code = "import time; time.sleep(20)" if sleep else "import sys; sys.stdout.buffer.write(" + repr(raw or events()) + ")"
            child = await real_exec(sys.executable, "-c", code, **kwargs)
            children.append(child)
            return child
        with patch.object(review.asyncio, "create_subprocess_exec", side_effect=fake_pi), \
                patch.object(review.os, "killpg", wraps=review.os.killpg) as killpg:
            result = await review.judge(self.case, self.run, directory, timeout=timeout)
        self.assertEqual(killpg.call_count, 1 if sleep else 0)
        self.assertEqual(Path(result["reviewDirectory"]), directory)
        self.assertEqual((directory / "sessions/evidence.jsonl").read_bytes(), b"fabricated session evidence")
        self.assertTrue((directory / "bundle/dossier.json").is_file())
        self.assertEqual(json.loads((directory / "invocation.json").read_bytes())["command"], list(commands[0]))
        self.assertIsNotNone(children[0].returncode)
        return result, commands[0], directory

    async def test_fabricated_child_smoke_normal_globals_exact_high_no_fast_one_attachment(self):
        result, command, directory = await self.launch()
        self.assertEqual(result["status"], "reviewed")
        self.assertEqual(command[command.index("--model")+1], "codex-pro/gpt-6.1-sol")
        self.assertEqual(command[command.index("--thinking")+1], "high")
        for flag in ("--fast", "--no-tools", "--no-extensions", "--no-context-files", "--continue", "--resume"):
            self.assertNotIn(flag, command)
        self.assertIn("--unlisted", command)
        self.assertIn("--print", command)
        self.assertEqual(command[command.index("--mode")+1], "json")
        self.assertEqual(sum(arg.startswith("@") for arg in command), 1)
        self.assertEqual(command.count("--force-model"), 1)
        self.assertLess(command.index("--force-model"), next(i for i, arg in enumerate(command) if arg.startswith("@")))
        self.assertFalse(Path(command[command.index("--session-dir")+1]).parent.exists())
        self.assertEqual((directory / "events.jsonl").stat().st_mode & 0o777, 0o600)
        self.assertNotIn("judgeSeconds", self.record["timings"])

    async def test_actual_installed_launcher_consumes_force_before_attachment(self):
        library = Path.home() / ".local/share/pi-codex-ultra/current/launcher/lib.mjs"
        if not library.is_file() or not shutil.which("node"):
            self.skipTest("Installed Ultra parser is unavailable")
        _, command, _ = await self.launch()
        script = """import { readFileSync } from 'node:fs';
const { parseUltraLauncherArgs } = await import(process.argv[1]);
console.log(JSON.stringify(parseUltraLauncherArgs(JSON.parse(readFileSync(0, 'utf8')))));"""
        parsed = subprocess.run(["node", "--input-type=module", "-e", script, library.as_uri()],
            input=json.dumps(command[1:]), capture_output=True, text=True, check=True, timeout=10)
        value = json.loads(parsed.stdout)
        self.assertIs(value["forceModel"], True)
        self.assertIs(value["explicitModel"], True)
        self.assertIs(value["explicitThinking"], True)
        self.assertNotIn("--force-model", value["piArgs"])
        self.assertNotIn("--fast", value["piArgs"])
        self.assertIn("codex-pro/gpt-6.1-sol", value["piArgs"])
        self.assertIn("high", value["piArgs"])
        for args in (list(command[1:]).copy(), ["--print", "literal prompt", "--force-model"]):
            if args[0] == "--force-model":
                args.remove("--force-model")
            unforced = subprocess.run(["node", "--input-type=module", "-e", script, library.as_uri()],
                input=json.dumps(args), capture_output=True, text=True, check=True, timeout=10)
            self.assertIs(json.loads(unforced.stdout)["forceModel"], False)

    async def test_unverified_cleanup_retains_execution_files_without_archiving_live_child(self):
        process = Mock(pid=123, returncode=None, wait=AsyncMock(side_effect=TimeoutError))
        destination = self.root / "live-child"
        with patch.object(review.asyncio, "create_subprocess_exec", return_value=process), \
                patch.object(review, "_group_fingerprint", return_value=None), \
                patch.object(review, "_cleanup_process", return_value=False), \
                patch.object(review.os, "killpg") as killpg:
            result = await review.judge(self.case, self.run, destination)
        execution = Path(result["reviewDirectory"])
        self.addCleanup(shutil.rmtree, execution)
        self.assertEqual(result["cleanupErrorCode"], "review_cleanup_unverified")
        self.assertEqual(result["errorCode"], "review_timeout")
        self.assertFalse(destination.exists())
        self.assertTrue((execution / "bundle/dossier.json").is_file())
        killpg.assert_not_called()

    async def test_no_destination_still_uses_neutral_execution_root(self):
        real_exec = asyncio.create_subprocess_exec
        async def fake_pi(*command, **kwargs):
            self.assertRegex(Path(kwargs["cwd"]).parent.name, r"^draw-ai-review-[a-z0-9_]+$")
            return await real_exec(sys.executable, "-c", "import sys; sys.stdout.buffer.write(" + repr(events()) + ")", **kwargs)
        with patch.object(review.asyncio, "create_subprocess_exec", side_effect=fake_pi):
            result = await review.judge(self.case, self.run)
        directory = Path(result["reviewDirectory"])
        self.addCleanup(shutil.rmtree, directory)
        self.assertEqual(directory.parent, (Path.home() / "tmp").resolve())
        self.assertTrue((directory / "events.jsonl").is_file())

    async def test_deadline_stops_only_owned_child_and_records_unknown(self):
        result, _, directory = await self.launch(sleep=True, timeout=0.05)
        self.assertEqual(result["status"], "failed")
        self.assertIsNone(result["verdict"])
        self.assertEqual(result["errorCode"], "review_timeout")
        self.assertTrue((directory / "events.jsonl").exists())
        self.assertEqual(json.loads((self.run / "run.json").read_bytes())["quality"], result)

    async def test_error_stop_does_not_record_ok(self):
        result, _, _ = await self.launch(raw=events(stopReason="error"))
        self.assertEqual(result["status"], "failed")
        self.assertIsNone(result["verdict"])

    async def test_cancellation_is_durable_and_re_raised(self):
        real_exec = asyncio.create_subprocess_exec
        children = []
        async def fake_pi(*command, **kwargs):
            child = await real_exec(sys.executable, "-c", "import time; time.sleep(20)", **kwargs)
            children.append(child)
            return child
        with patch.object(review.asyncio, "create_subprocess_exec", side_effect=fake_pi):
            task = asyncio.create_task(review.judge(self.case, self.run, self.root / "cancelled"))
            while not children:
                await asyncio.sleep(0.001)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertIsNotNone(children[0].returncode)
        quality = json.loads((self.run / "run.json").read_bytes())["quality"]
        self.assertEqual(quality["errorCode"], "review_cancelled")
        self.assertIsNone(quality["verdict"])


class CleanupTests(unittest.IsolatedAsyncioTestCase):
    async def test_returned_process_never_signals_group_even_with_old_fingerprint(self):
        process = Mock(pid=123, returncode=0)
        with patch.object(review.os, "killpg") as killpg, patch.object(review, "_group_fingerprint") as fingerprint:
            self.assertTrue(await review._cleanup_process(process, "start"))
        killpg.assert_not_called()
        fingerprint.assert_not_called()

    async def test_reused_or_unexpected_group_never_signalled_and_wait_is_bounded(self):
        for original, current in (("start", "new-start"), ("start", None), (None, None)):
            with self.subTest(original=original, current=current):
                process = Mock(pid=123, returncode=None, wait=AsyncMock())
                with patch.object(review.os, "killpg") as killpg, \
                        patch.object(review, "_group_fingerprint", return_value=current), \
                        patch.object(review.asyncio, "wait_for", side_effect=TimeoutError) as wait:
                    self.assertFalse(await review._cleanup_process(process, original))
                killpg.assert_not_called()
                self.assertEqual(wait.call_args.args[1], 5)
                # Mock wait_for never consumes its coroutine.
                wait.call_args.args[0].close()

    def test_fingerprint_requires_own_group_and_session(self):
        for group, session in ((123, 123), (456, 123), (123, 456)):
            fields = ["S", "1", str(group), str(session)] + ["0"] * 15 + ["987"]
            with patch.object(Path, "read_text", return_value="123 (name with spaces) " + " ".join(fields)):
                self.assertEqual(review._group_fingerprint(123), "987" if group == session == 123 else None)


if __name__ == "__main__":
    unittest.main()
