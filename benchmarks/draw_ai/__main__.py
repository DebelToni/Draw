"""Agent-operated Draw benchmark. Private data stays in data/ai-benchmark."""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import platform
import re
from uuid import uuid4

from .capture import DEFAULT_ENDPOINT, DEFAULT_TOKEN_FILE, stage_document
from .cases import import_case, list_cases, verify_case
from .report import summary
from .review import judge
from .runner import BASELINE, run_case

PROJECT = Path(__file__).resolve().parents[2]
DATA = PROJECT / "data/ai-benchmark"


def case_name(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", value):
        raise argparse.ArgumentTypeError("Use a single safe case name")
    return value


def print_json(value):
    print(json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2))


def environment():
    # Pin executable guidance/rendering as well as harness code. No environment
    # variables, credentials, mutable live-note state or unrelated files enter it.
    paths = list((PROJECT / "benchmarks/draw_ai").glob("*.py"))
    paths += list((PROJECT / "notes_service").glob("*.py"))
    paths += [PROJECT / "notes_service/pi-extension.ts", PROJECT / "notes_service/AGENTS.template.md",
              PROJECT / "notes_service/rendering/render.mjs", PROJECT / "notes_service/rendering/package-lock.json"]
    paths += list((PROJECT / "notes_service/rendering/fonts").glob("*.ttf"))
    return {"python": platform.python_version(), "machine": platform.machine(),
            "platform": platform.platform(), "providerCacheConditions": "unknown",
            "files": {str(p.relative_to(PROJECT)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted(paths)}}


async def execute(args):
    for name in ("cases", "runs", "staging"):
        (DATA / name).mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.command == "init":
        print_json({"data": str(DATA), "baseline": BASELINE,
                    "cases": len(list_cases(DATA / "cases")), "nativeApplication": "finalist checks later"})
    elif args.command == "list":
        print_json([{"case": p.name, "question": verify_case(p)["manifest"]["question"]}
                    for p in list_cases(DATA / "cases")])
    elif args.command == "stage":
        page = int(args.page) if args.page.isdecimal() else args.page
        value = await stage_document(DEFAULT_ENDPOINT, DEFAULT_TOKEN_FILE, args.document, page,
                                     DATA / "staging" / args.case)
        print_json({k: value[k] for k in ("inputDirectory", "provenancePath", "target")})
    elif args.command == "import":
        provenance = json.loads(args.provenance.read_bytes()) if args.provenance else {"source": "supplied_capture"}
        if "caseProvenance" in provenance:
            provenance = provenance["caseProvenance"]
        value = import_case(args.capture, DATA / "cases" / args.case, args.question, provenance,
                            request_prompt=args.request_prompt)
        print_json({"case": args.case, "contextSHA256": value["manifest"]["contextSHA256"]})
    elif args.command == "run":
        case = DATA / "cases" / args.case
        verify_case(case)
        for _ in range(args.repeats):
            destination = DATA / "runs" / uuid4().hex
            snapshot = environment()
            record = await run_case(case, destination, timeout=args.timeout)
            (destination / "environment.json").write_text(json.dumps(snapshot, indent=2))
            if args.review and record["status"] == "ready":
                await judge(case, destination, destination / "judge")
                record = json.loads((destination / "run.json").read_bytes())
            print_json({"run": str(destination), "status": record["status"],
                        "timings": record["timings"], "quality": record["quality"],
                        "cleanup": record["cleanup"]})
            if record["cleanup"]["status"] == "blocked":
                raise RuntimeError("Owned worker cleanup is uncertain; inspect before another run")
    elif args.command == "review":
        print_json(await judge(DATA / "cases" / args.case, args.run, args.run / ("judge-" + uuid4().hex)))
    elif args.command == "report":
        runs = args.runs or sorted((DATA / "runs").glob("*/run.json"))
        print_json(summary(runs, list_cases(DATA / "cases")))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init")
    commands.add_parser("list")
    stage = commands.add_parser("stage", help="GET-only frozen current-source copy for native capture")
    stage.add_argument("case", type=case_name)
    stage.add_argument("document")
    stage.add_argument("--page", required=True)
    add = commands.add_parser("import", help="Freeze a native context/assets export")
    add.add_argument("case", type=case_name)
    add.add_argument("capture", type=Path)
    add.add_argument("--question", required=True, help="Human task description for the reviewer, not the candidate")
    add.add_argument("--provenance", type=Path)
    add.add_argument("--request-prompt", help="Explicit task override; otherwise preserve the AI-button prompt")
    run = commands.add_parser("run")
    run.add_argument("case", type=case_name)
    run.add_argument("--repeats", type=int, default=3)
    run.add_argument("--timeout", type=float, default=600)
    run.add_argument("--review", action="store_true")
    review = commands.add_parser("review")
    review.add_argument("case", type=case_name)
    review.add_argument("run", type=Path)
    report = commands.add_parser("report")
    report.add_argument("runs", type=Path, nargs="*")
    args = parser.parse_args()
    if args.command == "run" and not 1 <= args.repeats <= 100:
        parser.error("repeats must be between 1 and 100")
    asyncio.run(execute(args))


if __name__ == "__main__":
    main()
