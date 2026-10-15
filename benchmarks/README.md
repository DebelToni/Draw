# Draw AI benchmark

Agent-operated, private, reproducible case captures and repeated real-Pi runs. Anton supplies a document, page and question; Xaj stages, captures, freezes, runs and reviews it. No live document is a writable fixture.

## Current decision

Questionnaire `df47ed29`, 2026-10-11:

- Baseline: exact **Sol 6.1, medium reasoning, fast mode** (`codex-pro/gpt-6.1-sol`, not the long variant).
- Anton will name other candidates later; no family/setting sweep is enabled now.
- Primary measurement: DGX request to approved rendered result. Native capture/upload/download/application will be measured separately for finalists, not inferred from the DGX clock.
- Quality: independent Sol **OK / not OK**, with a short reason and optional uncertainty. No fixed score, golden-answer requirement or automatic pass-all gate. Repeated observations describe latency and review variation.

## Data and isolation

Code is in `benchmarks/draw_ai/`; private data is gitignored under `data/ai-benchmark/{staging,cases,runs}` with owner-only access. Captures include the requested document's full readable context, current generated objects and exact SHA-addressed images/geometry. Cases pin provenance, page heads, task framing, byte inventories and isolated document/page identities. Native stroke identities remain intact for safe edits. Frozen bundles reject mutation, missing/extra files, symlinks and overwrites.

Each measured run has a new broker, workspace, exact Pi session and private tmux socket/configuration. It uses the production Notes manager, native-capture protocol, interactive Pi bridge and renderer with ordinary global Pi tools. The broker binds only a random loopback port, has a separate token and no source adapter. It neither publishes source nor sends a fabricated native application acknowledgement. Cleanup is bounded and restricted to the run's positively owned processes; uncertain cleanup blocks the CLI's next repetition. This is data/session isolation, not an OS tool sandbox or proof that provider caches are cold.

### Freeze a user-selected case

1. Inspect the selected document/page through read-only source metadata/images. If the intended handwriting is unsynced, request a manual Sync; never silently benchmark an older page.
2. `stage` downloads a revision-checked current document through GET-only private loopback routes. It retains current native heads/generated assets, remaps organization/document/page IDs and records provenance separately from the native index.
3. Copy the staged `DrawBenchmarkInput` into the simulator test runner's **Documents**, regenerate the Xcode project, and run `DrawTests/AIBenchmarkCaptureTests`. This optional test reads a temporary copied Store, does not migrate ink/history, and writes `DrawBenchmarkExports/<case>/context.json` plus extensionless `assets/SHA`.
4. Retrieve the export to DGX and `import` it with the staging record. The importer binds source attribution to the captured identities, heads and generated objects.

The human question is a reviewer guide, not an extra hint to the candidate. Default candidate framing is the production AI-button prompt interpreting the paper. Use `--request-prompt` only for an explicitly agreed text-request case; that override is recorded and cannot be silently mixed with paper-first cases.

```bash
.venv/bin/python -m benchmarks.draw_ai init
.venv/bin/python -m benchmarks.draw_ai stage CASE DOC_UUID --page 3
# Native capture and retrieval are Xaj-operated, not steps for Anton.
.venv/bin/python -m benchmarks.draw_ai import CASE CAPTURE_DIRECTORY \
  --question 'The question being tested' \
  --provenance data/ai-benchmark/staging/CASE/stagingOriginalprovenance.json
.venv/bin/python -m benchmarks.draw_ai run CASE --repeats 3 --review
.venv/bin/python -m benchmarks.draw_ai report
```

### Timing and review

Input assets are preloaded, and the fresh worker is registered/idle before the primary clock starts. `requestToReadySeconds` begins before broker request creation/validation and ends at successful approval. It includes worker delivery, model/tool iterations and rendering; it excludes worker startup, capture/network transfer, native application, post-ready settlement and judging. Startup, settlement, tool-stage timing and observer overhead are recorded separately without subtracting overhead from the primary result.

`run.json` retains failures, deadlines, cleanup outcomes, requested settings and every observed assistant generation. The installed fast extension is hashed; its baseline invocation forces medium reasoning and priority service. Session metadata verifies the model and reasoning, but the harness does not claim independent observation of the provider's wire payload or actual priority scheduling. CLI `environment.json` pins relevant harness/broker/renderer/font/guidance bytes. Global Pi tools/settings and remote provider behavior remain variable; record changes when comparing later runs.

A neutral blind dossier contains the human question, captured pages, exact latest rendered previews, generated text/math and ink/object edit evidence. It excludes candidate labels, timings and transcripts. The CLI judge is fresh **Sol 6.1 high**, without `--fast`, with a session-local force-model lock; review time is outside the benchmark score. Alternatively Xaj can inspect the dossier and record a manual Sol verdict. Invalid/missing review evidence is **unknown**, never automatically OK. Blindness is prompt/data isolation, not enforced filesystem access control.

Reports group observations by case digest and profile, showing sample counts, median/min/max ready latency and OK/not-OK/unknown counts. Settings-invalid runs remain visible but are excluded from representative latency. Small samples get no p95 claim or automatic winner/pruning decision.

## Validation

```bash
.venv/bin/python -m unittest discover -s benchmarks/tests -q
```

84 tests pass, covering frozen inventories/provenance, GET-only source staging, production-broker replay, timing boundaries, complete model evidence, lost-launch recovery, owned cleanup, neutral review dossiers and aggregation. A fabricated arithmetic case exercised the real interactive Sol baseline, renderer and independent high-reasoning reviewer: approved output, OK verdict, no invalid settings, owned worker stopped and listener closed. It is a pipeline smoke test, not a result for Anton's notes or a meaningful model comparison. Evidence is under `~/tmp/draw-benchmark-smoke-c9f3ec27c13c47ee9761c556ab4cae72/`.

The native capture bridge compiles; its optional export test was skipped because no user-selected fixture is staged yet. The first real case will verify native export/provenance integration. No physical app update, production service restart, source write or new permanent service is part of this setup.
