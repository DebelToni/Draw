"""Descriptive benchmark counts, not hard quality gates or model selection.

python -m benchmarks.draw_ai.report RUN_DIR [RUN_DIR ...] --cases CASE_DIR ...
No settings sweep, p95 from tiny samples, automatic pruning or judge time folded
into the primary request-to-ready latency. All failures remain in the counts.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
from statistics import median

from benchmarks.draw_ai.review import validate_verdict


def _number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def _stats(values):
    return {"n": len(values), "median": median(values) if values else None,
            "min": min(values) if values else None, "max": max(values) if values else None}


def invalid_settings(run):
    """Check declared vs observed profile, never silently repair a bad run."""
    reasons = []
    if run.get("status") == "profile_mismatch" or run.get("errorCode") in ("benchmark_profile", "resolved_model_mismatch"):
        reasons.append("profile_mismatch")
    profile = run.get("profile", {})
    if not isinstance(profile, dict) or any(k not in profile for k in ("provider", "model", "thinking", "fast")):
        return reasons + ["profile_missing"]
    if (any(not isinstance(profile[k], str) or not profile[k] for k in ("provider", "model", "thinking"))
            or type(profile["fast"]) is not bool):
        return reasons + ["profile_invalid"]
    session = run.get("session", {})
    if run.get("status") == "ready" and session.get("modelMatches") is not True:
        reasons.append("resolved_model_unverified")
    assistant = session.get("firstAssistant") or {}
    generations = session.get("observedGenerations")
    # Older run records expose only firstAssistant. Never let that fallback mask
    # per-generation metadata in a current runner record.
    observed = generations if generations is not None else ([assistant] if assistant else [])
    if any(g.get("provider") != profile["provider"] or g.get("model") != profile["model"] for g in observed):
        reasons.append("resolved_model_mismatch")
    per_generation = [[g[k] for k in ("thinkingLevel", "providerThinkingLevel", "sessionThinkingLevel")
                       if g.get(k) is not None] for g in observed]
    levels = session.get("thinkingChanges", []) + [level for row in per_generation for level in row]
    if any(level != profile["thinking"] for level in levels):
        reasons.append("reasoning_mismatch")
    if run.get("status") == "ready" and generations is not None:
        if not observed:
            reasons.append("resolved_model_unverified")
        if not per_generation or not all(per_generation):
            reasons.append("reasoning_unverified")
    command = run.get("command")
    if command:
        def option(name):
            return command[command.index(name) + 1] if name in command and command.index(name) + 1 < len(command) else None
        if (option("--model") != profile["provider"] + "/" + profile["model"]
                or option("--thinking") != profile["thinking"] or ("--fast" in command) != profile["fast"]):
            reasons.append("command_profile_mismatch")
    elif run.get("status") == "ready":
        reasons.append("command_unverified")
    if run.get("status") == "ready" and not levels:
        reasons.append("reasoning_unverified")
    return sorted(set(reasons))


def summary(run_paths, case_paths=()):
    """Group explicit run directories/run.json files by profile and case digest.

    Quality fractions use reviewed samples only; unknown is separately visible.
    Invalid settings exclude latency, not observations. Judge time is separate.
    Optional frozen cases label digests without exposing private provenance.
    """
    cases = {}
    for path in case_paths:
        path = Path(path)
        manifest_path = path / "case.json" if path.is_dir() else path
        manifest = json.loads(manifest_path.read_bytes())
        data = json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()
        cases[hashlib.sha256(data).hexdigest()] = str(manifest_path.parent)
    groups, unreadable, seen = {}, [], set()
    for path in run_paths:
        path = Path(path)
        path = path / "run.json" if path.is_dir() else path
        identity = path.resolve()
        if identity in seen:
            continue
        seen.add(identity)
        try:
            run = json.loads(path.read_bytes())
            if not isinstance(run, dict):
                raise ValueError("Invalid run")
            if any(not isinstance(run.get(k, {}), dict) for k in ("profile", "session", "timings", "quality")):
                raise ValueError("Invalid run fields")
            profile, digest = run.get("profile", {}), run.get("caseSHA256")
            settings = invalid_settings(run)
            key = (json.dumps(profile, sort_keys=True), digest)
            group = groups.setdefault(key, {"profile": profile, "caseSHA256": digest, "caseDirectory": cases.get(digest),
                "runs": [], "counts": Counter(), "quality": Counter({"ok": 0, "not_ok": 0, "unknown": 0}),
                "latency": [], "judgeLatency": []})
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            unreadable.append({"path": str(path), "error": "unreadable_or_invalid_run"})
            continue
        counts = group["counts"]
        counts["total"] += 1
        ready = run.get("status") == "ready"
        counts["ready" if ready else "failed"] += 1
        counts["invalidSettings"] += bool(settings)
        timing = run.get("timings", {}).get("requestToReadySeconds")
        representative = ready and not settings and _number(timing)
        counts["excludedLatency"] += not representative
        if representative:
            group["latency"].append(timing)
        quality = run.get("quality") or {}
        verdict = "unknown"
        if quality.get("status") == "reviewed":
            try:
                verdict = validate_verdict({k: quality[k] for k in ("verdict", "reason", "uncertainty") if k in quality})["verdict"]
            except ValueError:
                counts["reviewFailed"] += 1
        elif quality.get("status") == "failed":
            counts["reviewFailed"] += 1
        else:
            counts["unreviewed"] += 1
        group["quality"][verdict] += 1
        if _number(quality.get("judgeSeconds")):
            group["judgeLatency"].append(quality["judgeSeconds"])
        group["runs"].append({"path": str(path), "status": run.get("status"), "errorCode": run.get("errorCode"),
                              "invalidSettings": settings, "representativeLatency": representative, "quality": verdict})
    result = []
    for group in groups.values():
        for name in ("total", "ready", "failed", "invalidSettings", "excludedLatency", "unreviewed", "reviewFailed"):
            group["counts"].setdefault(name, 0)
        q = group["quality"]
        reviewed = q["ok"] + q["not_ok"]
        group["quality"] = {**q, "reviewed": reviewed, "okFraction": q["ok"] / reviewed if reviewed else None}
        group["requestToReadySeconds"] = _stats(group.pop("latency"))
        group["judgeSeconds"] = _stats(group.pop("judgeLatency"))
        result.append(group)
    return {"groups": result, "unreadableRuns": unreadable, "unreadableCount": len(unreadable),
            "interpretation": "Sampled OK fractions describe quality distributions, not hard pruning. "
                              "Latency uses ready runs with valid settings only; judge latency is separate."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--cases", nargs="*", type=Path, default=[])
    args = parser.parse_args()
    print(json.dumps(summary(args.runs, args.cases), ensure_ascii=False, allow_nan=False, indent=2))


if __name__ == "__main__":
    main()
