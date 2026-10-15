import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { mkdtemp, writeFile, readFile, stat, rm } from "node:fs/promises";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { randomUUID, createHash } from "node:crypto";

const packagePath = process.env.DRAW_PI_PACKAGE ?? "/home/xaj/.local/share/pi-codex-ultra/releases/fd81f791cde9ae95cb740b2ab039f02f00e4e127/node_modules/@earendil-works/pi-coding-agent";
const require = createRequire(import.meta.url);
const { createJiti } = require(join(packagePath, "node_modules/jiti/lib/jiti.cjs"));
const jiti = createJiti(import.meta.url, { moduleCache: false, fsCache: false, alias: {
  "typebox": join(packagePath, "node_modules/typebox/build/index.mjs"),
  "@earendil-works/pi-coding-agent": fileURLToPath(new URL("./extension_host.mjs", import.meta.url)),
} });
const { Check } = await import(join(packagePath, "node_modules/typebox/build/value/index.mjs"));
const extension = await jiti.import(fileURLToPath(new URL("../pi-extension.ts", import.meta.url)), { default: true });
const id = () => randomUUID().toUpperCase();

async function fixture(options = {}) {
  const cwd = await mkdtemp("/home/xaj/tmp/draw-extension-unit-");
  const documentID = id(), sessionID = randomUUID(), requestID = id();
  await writeFile(join(cwd, "token"), "unit-fixture-secret", { mode: 0o600 });
  await writeFile(join(cwd, "document.json"), JSON.stringify({ documentID, sessionID, managerURL: "http://127.0.0.1:18881", tokenFile: join(cwd, "token"), spawnNonce: randomUUID() }));
  const handlers = new Map(), tools = new Map(), commands = new Map(), entries = [], sent = [], calls = [], notifications = [];
  let status = "running", idle = options.idle ?? true, polled = false, terminalID;
  let companion = options.companion ?? false;
  const focusPageID = id(), prompt = "Read captured notes";
  const capture = { format: 1, documentID, focusPageID, orientation: "portrait", rendererSignature: "native-capture-v1", pages: [
    { pageID: focusPageID, width: 8, height: 10, background: 0, objects: [
      { id: id(), revision: 3, kind: "text", source: 'Glyph.JSON meta masks are literal source, not routing', frame: { x: 0, y: 0, width: 4, height: 2 }, style: { fontSize: 18 } }
    ], strokeTargets: [{ id: id(), fingerprint: "b".repeat(64), index: 4, frame: { x: 1, y: 2, width: 3, height: 4 } }] },
    { pageID: id(), width: 8, height: 10, background: 0, objects: [], strokeTargets: [] }
  ] };
  options.captureTransform?.(capture);
  const captureBytes = Buffer.from(JSON.stringify(capture));
  const contextSHA256 = createHash("sha256").update(captureBytes).digest("hex");
  let draftVersion = 0, draft = { insertPages: [], pageEdits: [] }, lastRender;

  let settlementDrops = options.settlementDrops ?? 0, heartbeatAck = options.heartbeatAck ?? true;
  let tickCallback;
  const lifecycle = new Map(), deliveryID = id();
  const image = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAABAAAAAUCAYAAACEYr13AAAAH0lEQVR4nGP8////fwYKABMlmkcNGDVg1IBRAwaXAQCdigQkzW5rvAAAAABJRU5ErkJggg==", "base64"), sha = createHash("sha256").update(image).digest("hex");
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    assert.equal(init.headers.Authorization, "Bearer unit-fixture-secret");
    calls.push({ url, body: init.body ? JSON.parse(init.body) : undefined });
    let value = { ok: true };
    if (url.endsWith("/register")) value = { lease: "unit-lease", companion };
    else if (url.endsWith("/heartbeat")) {
      value = { ok: true, companion, shutdown: false };
      const settlement = calls.at(-1).body?.settlement;
      if (settlement && heartbeatAck) {
        if (!lifecycle.has(settlement.eventID)) { lifecycle.set(settlement.eventID, settlement); if (status === "running") status = settlement.recovered ? "interrupted" : "failed"; }
        value.settlementID = settlement.eventID;
      }
    } else if (url.endsWith("/event") && calls.at(-1).body?.eventID) {
      const marker = calls.at(-1).body;
      assert.ok(entries.some(e => e.type === "draw-lifecycle-pending" && e.data.eventID === marker.eventID));
      if (settlementDrops-- > 0) throw new Error("Dropped settlement POST only");
      if (!lifecycle.has(marker.eventID)) { lifecycle.set(marker.eventID, marker); if (status === "running") status = marker.recovered ? "interrupted" : "failed"; }
      value = { ok: true, settlementID: marker.eventID };
    }
    else if (url.endsWith("/poll")) {
      value = { request: !polled && options.delivery ? { requestID, deliveryID, documentID, focusPageID, contextSHA256, outputMode: options.outputMode ?? "page_only", prompt,
        token: "not-for-metadata", managerURL: "not-for-metadata", contextAssets: ["not-for-metadata"] } : null };
      polled = true;
    } else if (url.endsWith("/terminal-requests")) {
      terminalID = calls.at(-1).body.requestID;
      value = { requestID: terminalID, documentID, status: options.terminalStatus ?? "needs_stale_choice", lastSyncedAt: "2026-10-08T00:00:00Z" };
    }
    else if (url.endsWith("/stale-choice")) value = { requestID: terminalID, documentID, status: "queued" };
    else if (url.endsWith("/activate")) value = { requestID: url.split("/").at(-2), documentID, focusPageID, contextSHA256, status: "running" };
    else if (url.endsWith("/companion")) companion = calls.at(-1).body.enabled;
    else if (url.endsWith("/approve")) { status = "ready"; value = { requestID, documentID, status }; }
    else if (url.endsWith("/draft")) {
      const body = calls.at(-1).body;
      if (body.expectedDraftVersion !== draftVersion) return new Response(JSON.stringify({ error: { code: "draft_conflict", message: "version changed" } }), { status: 409 });
      draft = { insertPages: body.insertPages ?? [], pageEdits: body.pageEdits ?? [] }; value = { draftVersion: ++draftVersion };
    }
    else if (url.endsWith("/render")) {
      const body = calls.at(-1).body;
      const pageIDs = [...new Set([...draft.pageEdits, ...draft.insertPages].map(p => p.pageID))];
      lastRender = { renderID: body.renderID ?? id(), draftVersion, attempt: 1, objects: [], previews: pageIDs.map(pageID => ({ pageID, sha256: sha })) };
      value = { ...lastRender, ...options.renderResponse };
    }
    else if (url.endsWith("/read")) {
      const body = calls.at(-1).body;
      value = { contextSHA256, metadataScope: { kind: body.view }, context: { ...capture, pages: body.view === "overview" ? capture.pages.map(({objects, strokeTargets, ...p}) => p) : capture.pages.filter(p => p.pageID === body.pageID) },
        draftVersion, outputMode:"page_only", ...options.readMetadata, images: [{ pageID: focusPageID, sha256: sha, path: "/fixture/image" }] };
    }
    else if (url.includes("/v1/assets/")) { await options.beforeResponse?.(url); return new Response(url.endsWith(contextSHA256) ? (options.captureBytes ?? captureBytes) : (options.assets?.[url.split("/").at(-1)] ?? options.imageBytes ?? image)); }
    else if (url.endsWith(`/requests/${requestID}`)) value = { requestID, documentID, status };
    await options.beforeResponse?.(url);
    return new Response(JSON.stringify(value), { headers: { "Content-Type": "application/json" } });
  };
  const pi = { on(name, callback) { handlers.set(name, callback); }, registerTool(tool) { tools.set(tool.name, tool); }, registerCommand(name, command) { commands.set(name, command); }, appendEntry(type, data) { entries.push({ type, data }); }, sendUserMessage(text) {
    const metadata = JSON.parse(readFileSync(join(cwd, "current-request.json"), "utf8"));
    assert.equal(metadata.requestID, requestID); // Lookup is ready before model prompt injection.
    assert.ok(entries.some(e => e.type === "draw-request" && e.data.requestID === requestID));
    sent.push(text);
  } };
  const ctx = { cwd, mode: "tui", isIdle: () => idle, hasPendingMessages: () => false,
    getContextUsage: () => ({ tokens: 32 }), shutdown() {},
    sessionManager: { getSessionId: () => options.wrongIdentity ? randomUUID() : sessionID, getSessionFile: () => join(cwd, "session.jsonl"), getCwd: () => cwd,
      getBranch: () => options.restored ? [{ type: "custom", customType: "draw-request", data: { requestID, deliveryID, continued: true } }, ...entries.map(e => ({ type: "custom", customType: e.type, data: e.data }))] : entries.map(e => ({ type: "custom", customType: e.type, data: e.data })) },
    ui: { notify(text) { notifications.push(text); }, setStatus() {}, onTerminalInput(callback) { return () => {}; } },
  };
  extension(pi);
  return { options, cwd, handlers, tools, commands, entries, sent, calls, notifications, requestID, documentID, sessionID, deliveryID, focusPageID, prompt, contextSHA256, capture, image, sha, ctx,
    setIdle(value) { idle = value; }, setStatus(value) { status = value; }, getStatus() { return status; },
    setHeartbeatAck(value) { heartbeatAck = value; },
    async tick() { tickCallback(); for (let i=0;i<20;i++) await new Promise(resolve => setImmediate(resolve)); },
    async reload() { await handlers.get("session_shutdown")({ reason: "reload" }, ctx); extension(pi); await this.start(); },
    async start() {
      const original = globalThis.setInterval;
      globalThis.setInterval = (callback) => { tickCallback = callback; return original(callback, 60000); };
      try { await handlers.get("session_start")({ reason: "startup" }, ctx); } finally { globalThis.setInterval = original; }
    },
    async stop() { await handlers.get("session_shutdown")({ reason: "quit" }, ctx); globalThis.fetch = originalFetch; await rm(cwd, { recursive: true }); },
  };
}

async function draftAndRender(f) {
  await f.tools.get("draw_draft").execute("draft", { pageEdits: [{ pageID: "p1", objectEdits: [{ op: "add", object: { id: "new:answer", kind: "text", source: "answer", frame: [0,0,4,4] } }] }] });
  return f.tools.get("draw_render").execute("render", {});
}

test("factory registers full draft tools but no resources before session_start", async () => {
  const f = await fixture();
  try {
    assert.equal(f.calls.length, 0);
    assert.deepEqual([...f.tools.keys()].sort(), ["draw_approve", "draw_companion", "draw_draft", "draw_mark", "draw_move", "draw_read", "draw_remove", "draw_render", "draw_terminal_request"]);
    assert.equal(f.handlers.has("agent_end"), false);
    assert.ok(f.handlers.has("agent_settled"));
  } finally { await f.stop(); }
});

test("idle leased request records authority and injects only the task once", async () => {
  const f = await fixture({ delivery: true });
  try {
    await f.start();
    assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0], f.prompt);
    assert.doesNotMatch(f.sent[0], /requestID|documentID|focusPageID|contextSHA256|outputMode|quizzes|Times|recolor/);
    const metadata = JSON.parse(await readFile(join(f.cwd, "current-request.json"), "utf8"));
    assert.deepEqual(metadata, { requestID: f.requestID, documentID: f.documentID, sessionID: f.sessionID,
      deliveryID: f.deliveryID, focusPageID: f.focusPageID, contextSHA256: f.contextSHA256, prompt: f.prompt, outputMode: "page_only" });
    assert.equal((await stat(join(f.cwd, "current-request.json"))).mode & 0o777, 0o600);
    assert.equal(f.entries[0].type, "draw-request");
    assert.deepEqual(f.handlers.get("session_before_switch")({}), { cancel: true });
  } finally { await f.stop(); }
});

test("before_settle continuation is bounded once and suppressed after exact approval", async () => {
  const f = await fixture({ delivery: true });
  try {
    await f.start();
    const event = { outcome: "completed", context: { canContinue: true } };
    const continuation = await f.handlers.get("agent_before_settle")(event, f.ctx);
    assert.equal(continuation.continue, true);
    assert.equal(continuation.entries[0].content, "This request has no approved page output. Finish it now.");
    assert.equal(await f.handlers.get("agent_before_settle")(event, f.ctx), undefined);
    await draftAndRender(f);
    await f.tools.get("draw_approve").execute("tool", {}, undefined);
    assert.equal(await f.handlers.get("agent_before_settle")(event, f.ctx), undefined);
    await f.handlers.get("agent_settled")({}, f.ctx);
    assert.equal(f.entries.at(-1).type, "draw-settled");
    assert.equal(f.calls.filter(c => c.body?.event === "agent_settled").length, 1);
  } finally { await f.stop(); }
});

test("actual image bytes in tool content, checksum bound", async () => {
  const f = await fixture({ delivery: true });
  try {
    await f.start();
    const result = await f.tools.get("draw_read").execute("tool", { requestID: f.requestID, view: "overview" }, undefined);
    assert.equal(result.content[1].type, "image");
    assert.equal(result.content[1].data, f.image.toString("base64"));
    assert.equal(result.content[1].mimeType, "image/png");
  } finally { await f.stop(); }
});

test("busy worker cannot poll-deliver into unrelated human turn", async () => {
  const f = await fixture({ delivery: true, idle: false });
  try { await f.start(); assert.equal(f.sent.length, 0); assert.equal(f.calls.filter(c => c.url.endsWith("/poll")).length, 0); }
  finally { await f.stop(); }
});

test("session ID reset disables tools and never registers replacement", async () => {
  const f = await fixture({ wrongIdentity: true });
  try {
    await f.start();
    assert.equal(f.calls.length, 0);
    await assert.rejects(() => f.tools.get("draw_read").execute("t", { requestID: f.requestID, view: "overview" }), /unavailable/);
    assert.ok(f.notifications.some(n => n.includes("identity")));
  } finally { await f.stop(); }
});

test("restored in-flight marker reports authority but never replays old prompt", async () => {
  const f = await fixture({ restored: true });
  try { f.setStatus("interrupted"); await f.start(); assert.equal(f.sent.length, 0); assert.ok(f.notifications.some(n => n.includes("No automatic replay"))); }
  finally { await f.stop(); }
});

test("natural companion tool and slash command durably announce toggles", async () => {
  const f = await fixture();
  try {
    await f.start();
    await f.tools.get("draw_companion").execute("t", { enabled: true });
    await f.commands.get("companion").handler("off", f.ctx);
    assert.deepEqual(f.calls.filter(c => c.url.endsWith("/companion")).map(c => c.body.enabled), [true, false]);
    assert.ok(f.notifications.includes("Companion mode on until explicitly disabled."));
  } finally { await f.stop(); }
});

test("explicit natural stale choice activates same request, no silent fallback", async () => {
  const f = await fixture();
  try {
    await f.start();
    const result = await f.tools.get("draw_terminal_request").execute("t", { requestID: f.requestID, prompt: "Write answer" });
    assert.equal(result.details.status, "needs_stale_choice");
    assert.equal(f.calls.filter(c => c.url.endsWith("/stale-choice")).length, 0);
    const transform = await f.handlers.get("input")({ source: "interactive", text: "use synced" }, f.ctx);
    assert.deepEqual(transform, { action: "continue" });
    const metadata = JSON.parse(await readFile(join(f.cwd, "current-request.json"), "utf8"));
    assert.equal(metadata.prompt, "Write answer");
    assert.equal(metadata.requestID, f.requestID);
    assert.equal(f.calls.find(c => c.url.endsWith("/stale-choice")).body.choice, "use_synced");
    assert.equal(f.calls.filter(c => c.url.endsWith("/activate")).length, 1);
    assert.equal(f.entries.at(-1).data.requestID, f.requestID);
  } finally { await f.stop(); }
});


test("before_agent_start adds only dynamic state without intercepting conversation", async () => {
  const f = await fixture();
  try {
    await f.start();
    const e = { systemPromptOptions: { promptGuidelines: [] } };
    f.handlers.get("before_agent_start")(e, f.ctx);
    assert.deepEqual(e.systemPromptOptions.promptGuidelines, ["Draw current state: page-writing authority inactive; outputMode=page_only."]);
    assert.equal(f.sent.length, 0);
  } finally { await f.stop(); }
});





test("dropped settlement POST recovers through healthy heartbeat before any new delivery", async () => {
  const f = await fixture({ delivery: true, settlementDrops: 100 });
  try {
    await f.start();
    await f.handlers.get("agent_settled")({}, f.ctx);
    assert.equal(f.getStatus(), "running");
    assert.equal(f.entries.at(-1).type, "draw-lifecycle-pending");
    const pending = f.entries.at(-1).data;
    assert.ok(pending.deliveryID);
    await assert.rejects(() => f.tools.get("draw_terminal_request").execute("t", { requestID: id(), prompt: "New" }), /settlement awaiting/);
    const start = f.calls.length;
    await f.tick();
    assert.equal(f.getStatus(), "failed");
    assert.equal(f.entries.at(-1).type, "draw-settled");
    assert.equal(f.entries.at(-1).data.eventID, pending.eventID);
    const calls = f.calls.slice(start);
    assert.ok(calls[0].url.endsWith("/event"));
    assert.ok(calls[1].url.endsWith("/heartbeat"));
    assert.equal(calls[1].body.settlement.eventID, pending.eventID);
    assert.ok(calls[2].url.endsWith("/poll"));
    assert.equal(f.sent.length, 1);
  } finally { await f.stop(); }
});

test("pending settlement survives reload with no inference replay and blocks polling until ACK", async () => {
  const f = await fixture({ delivery: true, settlementDrops: 100, heartbeatAck: false });
  try {
    await f.start();
    await f.handlers.get("agent_settled")({}, f.ctx);
    const pending = f.entries.at(-1).data;
    await f.tick();
    const polls = f.calls.filter(c => c.url.endsWith("/poll")).length;
    await f.reload();
    assert.equal(f.calls.filter(c => c.url.endsWith("/poll")).length, polls);
    assert.equal(f.sent.length, 1);
    assert.equal(f.entries.filter(e => e.type === "draw-lifecycle-pending").length, 1);
    f.setHeartbeatAck(true);
    await f.tick();
    assert.equal(f.getStatus(), "failed");
    assert.equal(f.entries.at(-1).data.eventID, pending.eventID);
    assert.equal(f.sent.length, 1);
  } finally { await f.stop(); }
});

test("late old settlement retry carries current human busy state instead of marking it idle", async () => {
  const f = await fixture({ delivery: true, settlementDrops: 100 });
  try {
    await f.start();
    await f.handlers.get("agent_settled")({}, f.ctx);
    f.setIdle(false);
    await f.handlers.get("agent_start")({}, f.ctx);
    const polls = f.calls.filter(c => c.url.endsWith("/poll")).length;
    await f.tick();
    const retried = f.calls.filter(c => c.body?.eventID).at(-1);
    assert.equal(retried.body.activity.busy, true);
    const heartbeat = f.calls.filter(c => c.url.endsWith("/heartbeat")).at(-1);
    assert.equal(heartbeat.body.busy, true);
    assert.equal(f.calls.filter(c => c.url.endsWith("/poll")).length, polls);
    assert.equal(f.getStatus(), "failed");
    assert.equal(f.sent.length, 1);
  } finally { await f.stop(); }
});


const pageCalls = () => [
  ["draw_read", "read", { view: "overview" }],
  ["draw_draft", "draft", { expectedDraftVersion: 0, insertPages: [], pageEdits: [] }],
  ["draw_render", "render", { draftVersion: 1, renderID: id() }],
  ["draw_approve", "approve", { draftVersion: 1, renderID: id(), inspectedPreviewSHA256s: ["b".repeat(64)] }],
  ["draw_move", "draft", { targets: ["s5"], dx: 1, dy: 2 }],
  ["draw_remove", "draft", { targets: ["s5"] }],
];
function systemState(f) {
  const e = { systemPromptOptions: { promptGuidelines: [] } };
  f.handlers.get("before_agent_start")(e, f.ctx);
  return e.systemPromptOptions.promptGuidelines;
}

test("page tools bind omitted IDs and matching explicit legacy fields", async () => {
  const f = await fixture({ delivery: true });
  try {
    await f.start();
    await f.tools.get("draw_read").execute("t1", { requestID: f.requestID, view: "page" });
    await draftAndRender(f);
    const rendered = JSON.parse(await readFile(join(f.cwd, "current-render.json"), "utf8")).value;
    const params = { requestID: f.requestID, renderID: rendered.renderID, draftVersion: rendered.draftVersion, inspectedPreviewSHA256s: [f.sha] };
    assert.equal(Check(f.tools.get("draw_approve").parameters, params), true);
    await f.tools.get("draw_approve").execute("approve", params);
    assert.deepEqual(f.calls.findLast(c => c.url.endsWith("/approve")).body, { renderID: rendered.renderID, draftVersion: rendered.draftVersion, inspectedPreviewSHA256s: [f.sha] });
  } finally { await f.stop(); }
});

test("every page tool rejects explicit mismatches before any broker call", async () => {
  const f = await fixture({ delivery: true });
  try {
    await f.start();
    const count = f.calls.length;
    for (const [name, , body] of pageCalls()) {
      await assert.rejects(() => f.tools.get(name).execute("t", { ...body, requestID: id() }), /does not match/);
    }
    assert.equal(f.calls.length, count);
  } finally { await f.stop(); }
});

test("every page tool rejects both omitted and explicit IDs without active authority", async () => {
  const f = await fixture();
  try {
    await f.start();
    const count = f.calls.length;
    for (const [name, , body] of pageCalls()) {
      for (const params of [body, { ...body, requestID: f.requestID }]) {
        await assert.rejects(() => f.tools.get(name).execute("t", params), /no active/);
      }
    }
    assert.equal(f.calls.length, count);
  } finally { await f.stop(); }
});

test("terminal autogenerated UUID activates durably with code-readable task metadata", async () => {
  const f = await fixture({ terminalStatus: "queued" });
  try {
    await f.start();
    const tool = f.tools.get("draw_terminal_request");
    assert.equal(Check(tool.parameters, {}), false);
    assert.equal(Check(tool.parameters, { prompt: "" }), false);
    assert.equal(Check(tool.parameters, { prompt: "Solve the marked integral", focusPageID: f.focusPageID }), true);
    const result = await tool.execute("t", { prompt: "Solve the marked integral", focusPageID: f.focusPageID });
    const created = f.calls.find(c => c.url.endsWith("/terminal-requests"));
    const rid = created.body.requestID;
    assert.match(rid, /^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/);
    assert.equal(created.body.prompt, "Solve the marked integral");
    assert.ok(f.calls.some(c => c.url.endsWith(`/requests/${rid}/activate`)));
    assert.equal(result.details.requestID, rid);
    assert.equal(result.details.contextSHA256, f.contextSHA256);
    assert.equal(JSON.parse(result.content[0].text).contextSHA256, undefined);
    assert.equal(f.entries.at(-1).type, "draw-request");
    assert.equal(f.entries.at(-1).data.requestID, rid);
    const metadata = JSON.parse(await readFile(join(f.cwd, "current-request.json"), "utf8"));
    assert.deepEqual(metadata, { requestID: rid, documentID: f.documentID, sessionID: f.sessionID,
      focusPageID: f.focusPageID, contextSHA256: f.contextSHA256, prompt: "Solve the marked integral", outputMode: "page_only" });
    assert.equal(f.sent.length, 0);
    await f.tools.get("draw_read").execute("t", { view: "overview" });
    assert.ok(f.calls.some(c => c.url.endsWith(`/requests/${rid}/read`)));
    await f.handlers.get("agent_settled")({}, f.ctx);
    assert.equal(f.entries.at(-1).data.requestID, rid);
    await f.reload();
    assert.equal(f.sent.length, 0);
    assert.deepEqual(systemState(f), ["Draw current state: page-writing authority inactive; outputMode=page_only."]);
  } finally { await f.stop(); }
});

test("active output mode is dynamic state only, with no UUID, hash or standing rules", async () => {
  const f = await fixture({ delivery: true, outputMode: "companion" });
  try {
    await f.start();
    assert.deepEqual(systemState(f), ["Draw current state: page-writing authority active; outputMode=companion."]);
    await f.handlers.get("agent_settled")({}, f.ctx);
    assert.deepEqual(systemState(f), ["Draw current state: page-writing authority inactive; outputMode=page_only."]);
    await f.tools.get("draw_companion").execute("t", { enabled: true });
    assert.deepEqual(systemState(f), ["Draw current state: page-writing authority inactive; outputMode=companion."]);
  } finally { await f.stop(); }
});

test("restored authority is settled, not exposed as active policy during pending outbox", async () => {
  const f = await fixture({ restored: true, settlementDrops: 100, heartbeatAck: false });
  try {
    await f.start();
    assert.deepEqual(systemState(f), ["Draw current state: page-writing authority inactive; outputMode=page_only; settlement acknowledgement pending."]);
    const count = f.calls.length;
    for (const [name, , body] of pageCalls()) {
      await assert.rejects(() => f.tools.get(name).execute("t", body), /settlement awaiting/);
    }
    assert.equal(f.calls.length, count);
    assert.equal(f.sent.length, 0);
    assert.equal(f.entries.at(-1).data.requestID, f.requestID);
    assert.equal(f.entries.at(-1).data.deliveryID, f.deliveryID);
    assert.equal(f.entries.at(-1).data.recovered, true);
  } finally { await f.stop(); }
});



for (const phase of ["approve", "read", "assets"]) {
  test(`scope change during ${phase} await rejects the old response without approving newer authority`, async () => {
    let release, arrived;
    const reached = new Promise(resolve => { arrived = resolve; });
    const blocked = new Promise(resolve => { release = resolve; });
    const f = await fixture({ delivery: true, terminalStatus: "queued", beforeResponse: async url => {
      if (phase === "assets" ? (url.includes("/v1/assets/") && !url.endsWith(f.contextSHA256)) : url.endsWith(`/${phase}`)) {
        arrived(); await blocked;
      }
    } });
    try {
      await f.start();
      if (phase === "approve") await draftAndRender(f);
      const [name, body] = phase === "approve" ? ["draw_approve", {}] : ["draw_read", { view: "overview" }];
      const old = f.tools.get(name).execute("t", body);
      const rejected = assert.rejects(old, /scope changed/);
      await reached;
      const newer = id();
      await f.tools.get("draw_terminal_request").execute("t", { requestID: newer, prompt: "New task" });
      release();
      await rejected;
      assert.equal(f.entries.at(-1).data.requestID, newer);
      assert.equal(f.entries.at(-1).data.approved, undefined);
    } finally { release(); await f.stop(); }
  });
}

test("shutdown epoch invalidates an outstanding tool response", async () => {
  let release, arrived;
  const reached = new Promise(resolve => { arrived = resolve; });
  const blocked = new Promise(resolve => { release = resolve; });
  const f = await fixture({ delivery: true, beforeResponse: async url => {
    if (url.endsWith("/draft")) { arrived(); await blocked; }
  } });
  try {
    await f.start();
    const old = f.tools.get("draw_draft").execute("t", { expectedDraftVersion: 0 });
    const rejected = assert.rejects(old, /scope changed/);
    await reached;
    await f.handlers.get("session_shutdown")({}, f.ctx);
    release();
    await rejected;
  } finally { release(); await f.stop(); }
});


test("hashed full capture loads once, remains private, and drives compact schema", async () => {
  const f = await fixture({ delivery: true });
  try {
    await f.start();
    for (const body of [{view:"page"}, {view:"crop",pageID:"p1",rect:[0,0,4,4]}]) {
      assert.equal(Check(f.tools.get("draw_read").parameters, body), true);
      const result = await f.tools.get("draw_read").execute("read", body);
      const text = result.content[0].text;
      assert.doesNotMatch(text, /fingerprint|revision|sha256|head|provenance|fullContext|[0-9A-F]{8}-/);
      assert.deepEqual(result.structuredContent, JSON.parse(text));
      assert.equal(JSON.parse(text).pages[0].objects[0].source, f.capture.pages[0].objects[0].source);
      assert.equal(result.details.contextSHA256, f.contextSHA256);
      assert.equal(result.content[1].data, f.image.toString("base64"));
      assert.deepEqual(JSON.parse(text).pages[0].strokes[0].slice(0,5), ["s5",1,2,3,4]);
    }
    assert.equal(f.calls.filter(c => c.url.endsWith(f.contextSHA256)).length, 1);
    const bytes = await readFile(join(f.cwd,"current-context.json"));
    assert.equal(createHash("sha256").update(bytes).digest("hex"),f.contextSHA256);
    assert.equal((await stat(join(f.cwd,"current-context.json"))).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(bytes),f.capture);
  } finally { await f.stop(); }
});

for (const [label, options, pattern] of [
  ["exact-byte SHA", {captureBytes: Buffer.from("{}")} , /integrity/],
  ["4MiB streamed limit", {captureBytes: Buffer.alloc(4*1024*1024+1)}, /transfer limit/],
  ["document binding", {captureTransform: c => { c.documentID = id(); }}, /document\/focus/],
  ["focus binding", {captureTransform: c => { c.focusPageID = c.pages[1].pageID; }}, /document\/focus/],
]) test(`capture rejects ${label} before edit and never refetches uncertain pin`, async () => {
  const f = await fixture({ delivery: true, ...options });
  try {
    await f.start();
    for (let n=0;n<2;n++) await assert.rejects(() => f.tools.get("draw_draft").execute("draft",{}),pattern);
    assert.equal(f.calls.filter(c => c.url.endsWith(f.contextSHA256)).length,1);
    assert.equal(f.calls.some(c => c.url.endsWith("/draft")),false);
  } finally { await f.stop(); }
});

test("handle edits restore exact native identities and reject explicit wrong guards", async () => {
  const f = await fixture({ delivery: true });
  try {
    await f.start();
    const tool = f.tools.get("draw_draft");
    const body = { pageEdits: [{pageID:"p1",strokeEdits:[{id:"s5",op:"remove"}],objectEdits:[{op:"remove",objectID:"o1"}]}] };
    assert.equal(Check(tool.parameters,body),true);
    await tool.execute("draft",body);
    const sent = f.calls.findLast(c => c.url.endsWith("/draft")).body;
    assert.equal(sent.expectedDraftVersion,0);
    assert.deepEqual(sent.pageEdits[0].strokeEdits[0],{id:f.capture.pages[0].strokeTargets[0].id,op:"remove",fingerprint:"b".repeat(64)});
    assert.deepEqual(sent.pageEdits[0].objectEdits[0],{op:"remove",objectID:f.capture.pages[0].objects[0].id,expectedRevision:3});
    for (const edit of [
      {pageID:"p1",strokeEdits:[{id:"s5",op:"remove",fingerprint:"c".repeat(64)}]},
      {pageID:"p1",objectEdits:[{op:"remove",objectID:"o1",expectedRevision:2}]},
      {pageID:"p2",strokeEdits:[{id:"s5",op:"remove"}]},
      {pageID:"p2",objectEdits:[{op:"remove",objectID:"o1"}]},
      {pageID:"p500",strokeEdits:[]},
    ]) await assert.rejects(() => tool.execute("bad",{pageEdits:[edit]}),/invalid_handle/);
    assert.equal(f.calls.filter(c => c.url.endsWith("/draft")).length,1);
  } finally { await f.stop(); }
});

test("omitted CAS on concurrent complete drafts conflicts rather than overwriting sibling", async () => {
  const f = await fixture({delivery:true});
  try {
    await f.start();
    const tool = f.tools.get("draw_draft");
    assert.equal(tool.executionMode,"parallel");
    const results = await Promise.allSettled([tool.execute("one",{}),tool.execute("two",{})]);
    assert.equal(results.filter(r=>r.status==="fulfilled").length,1);
    assert.match(results.find(r=>r.status==="rejected").reason.message,/draft_conflict/);
    assert.equal(f.calls.filter(c=>c.url.endsWith("/draft")).length,1);
  } finally { await f.stop(); }
});

test("new labels retain typed canonical IDs over draft retries and accept legacy UUID inserts", async () => {
  const f = await fixture({delivery:true});
  try {
    await f.start();
    const body = {insertPages:[{pageID:"new:answer",afterPageID:"p1",background:0,width:8,height:10}],pageEdits:[{pageID:"new:answer",objectEdits:[{op:"add",object:{id:"new:answer",kind:"text",source:"literal Glyph.JSON",frame:[0,0,4,4]}}]}]};
    const tool = f.tools.get("draw_draft");
    assert.equal(Check(tool.parameters,body),true);
    await tool.execute("one",body); await tool.execute("two",body);
    const drafts = f.calls.filter(c=>c.url.endsWith("/draft")).map(c=>c.body);
    assert.deepEqual(drafts[0].insertPages,drafts[1].insertPages);
    assert.deepEqual(drafts[0].pageEdits,drafts[1].pageEdits);
    assert.notEqual(drafts[0].insertPages[0].pageID,drafts[0].pageEdits[0].objectEdits[0].object.id);
    const pageID = id(), oid = id();
    const legacy = {insertPages:[{pageID,afterPageID:f.focusPageID,background:0,width:8,height:10}],pageEdits:[{pageID,objectEdits:[{op:"add",object:{id:oid,kind:"text",source:"legacy",frame:{x:0,y:0,width:4,height:4}}}]}]};
    await tool.execute("legacy",legacy);
    assert.equal(f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].pageID,pageID);
    const evidence = JSON.parse(await readFile(join(f.cwd,"current-bridge.json"),"utf8"));
    assert.equal(evidence.requestID,f.requestID);
    assert.ok(evidence.labels["object:new:answer"]);
  } finally { await f.stop(); }
});

test("mark appends with CAS, preserves writes, defaults focus, and is idempotent per call ID", async () => {
  const f = await fixture({delivery:true});
  try {
    await f.start(); await draftAndRender(f);
    const tool = f.tools.get("draw_mark");
    const params = {kind:"highlight",frame:[1,1,4,4]};
    assert.equal(Check(tool.parameters,params),true);
    const r1 = await tool.execute("mark-call",params);
    const r2 = await tool.execute("mark-call",params);
    assert.deepEqual(r1,r2);
    const sent = f.calls.filter(c=>c.url.endsWith("/draft"));
    assert.equal(sent.length,2);
    assert.equal(sent[1].body.expectedDraftVersion,1);
    assert.equal(sent[1].body.pageEdits[0].objectEdits.length,2);
    const highlight = sent[1].body.pageEdits[0].objectEdits[1].object;
    assert.equal(highlight.kind,"highlight");assert.equal(highlight.source,'{"opacity":0.2}');
    assert.deepEqual(highlight.style,{color:"#00B8D9",lineWidth:1,fontSize:18});
    await assert.rejects(()=>tool.execute("mark-call",{...params,frame:[0,0,4,4]}),/reused/);
    await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/delivered/);
    await tool.execute("circle",{kind:"circle",frame:[1,1,4.2,5.3],id:"new:circle"});
    const circle=f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].objectEdits.at(-1).object;
    assert.deepEqual(circle.frame,{x:1,y:1,width:4,height:5});
    assert.deepEqual(JSON.parse(circle.source),{cx:2,cy:2.5,rx:1.5,ry:2});
    await assert.rejects(()=>tool.execute("small",{kind:"circle",frame:[0,0,1.1,2]}),/too small/);
    await tool.execute("replace",{kind:"circle",frame:[0,0,3,3],id:"o1"});
    const replace=f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].objectEdits.at(-1);
    assert.equal(replace.op,"replace"); assert.equal(replace.expectedRevision,3);
    assert.equal(replace.object.id,f.capture.pages[0].objects[0].id);
  } finally { await f.stop(); }
});

test("approval defaults exact delivered render only and optional legacy claims cannot disagree", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();
    const approve=f.tools.get("draw_approve");
    await assert.rejects(()=>approve.execute("approve",{}),/delivered/);
    const rendered=await draftAndRender(f);
    assert.equal(JSON.parse(rendered.content[0].text).render,"r1");
    for (const params of [{render:"r2"},{renderID:id()},{draftVersion:2},{inspectedPreviewSHA256s:["c".repeat(64)]},{inspectedPreviewSHA256s:[f.sha,f.sha]}]) await assert.rejects(()=>approve.execute("bad",params),/does not match|hashes/);
    assert.equal(f.calls.some(c=>c.url.endsWith("/approve")),false);
    await approve.execute("approve",{render:"r1"});
    const body=f.calls.findLast(c=>c.url.endsWith("/approve")).body;
    assert.deepEqual(body,{draftVersion:1,renderID:rendered.details.renderID,inspectedPreviewSHA256s:[f.sha]});
    assert.equal(f.entries.at(-1).data.approved,true);
    await f.reload();
    await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/no active/);
  } finally { await f.stop(); }
});

test("failed delivery clears prior approval and cannot fall back to previous inspected render", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();await draftAndRender(f);
    f.options.imageBytes=Buffer.from("broken PNG delivery");
    await assert.rejects(()=>f.tools.get("draw_render").execute("render",{}),/integrity/);
    await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/delivered/);
    assert.equal(f.calls.some(c=>c.url.endsWith("/approve")),false);
  } finally { await f.stop(); }
});

test("failed read image delivery also clears previous render approval", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();await draftAndRender(f);f.options.imageBytes=Buffer.from("bad");
    await assert.rejects(()=>f.tools.get("draw_read").execute("read",{view:"page"}),/integrity/);
    await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/delivered/);
  } finally { await f.stop(); }
});

test("render rejects missing pages, duplicate pages and wrong draft version", async () => {
  for (const patch of [{previews:[]},{draftVersion:999}]) {
    const f=await fixture({delivery:true,renderResponse:patch});
    try {
      await f.start();await assert.rejects(()=>draftAndRender(f),/exact current draft/);
      await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/delivered/);
    } finally { await f.stop(); }
  }
});

test("new request clears render/labels and legacy stale requestID fails before broker", async () => {
  const f=await fixture({delivery:true,terminalStatus:"queued"});
  try {
    await f.start();await draftAndRender(f);
    const oldDraft=JSON.parse(await readFile(join(f.cwd,"current-draft.json"),"utf8"));
    const newID=id();await f.tools.get("draw_terminal_request").execute("new",{requestID:newID,prompt:"new task"});
    await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/delivered/);
    await assert.rejects(()=>f.tools.get("draw_draft").execute("old",{requestID:f.requestID}),/does not match/);
    await f.tools.get("draw_draft").execute("new-draft",{pageEdits:[{pageID:"p1",objectEdits:[{op:"add",object:{id:"new:answer",kind:"text",source:"new",frame:[0,0,4,4]}}]}]});
    const newDraft=JSON.parse(await readFile(join(f.cwd,"current-draft.json"),"utf8"));
    assert.notEqual(oldDraft.pageEdits[0].objectEdits[0].object.id,newDraft.pageEdits[0].objectEdits[0].object.id);
  } finally { await f.stop(); }
});


test("multi-page rendering approves only after all exact PNGs were delivered", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();
    await f.tools.get("draw_draft").execute("draft",{pageEdits:["p1","p2"].map((pageID,n)=>({pageID,objectEdits:[{op:"add",object:{id:`new:answer${n}`,kind:"text",source:"answer",frame:[0,0,4,4]}}]}))});
    const rendered=await f.tools.get("draw_render").execute("render",{});
    assert.equal(rendered.content.filter(c=>c.type==="image").length,2);
    assert.ok(rendered.content.filter(c=>c.type==="image").every(c=>createHash("sha256").update(Buffer.from(c.data,"base64")).digest("hex")===f.sha));
    await f.tools.get("draw_approve").execute("approve",{});
    assert.deepEqual(f.calls.findLast(c=>c.url.endsWith("/approve")).body.inspectedPreviewSHA256s,[f.sha]);
  } finally { await f.stop(); }
});

test("partial image set download failure never creates approval authority", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();
    await f.tools.get("draw_draft").execute("draft",{pageEdits:["p1","p2"].map(pageID=>({pageID}))});
    const corrupt="c".repeat(64);
    f.options.renderResponse={previews:[{pageID:f.focusPageID,sha256:f.sha},{pageID:f.capture.pages[1].pageID,sha256:corrupt}]};
    await assert.rejects(()=>f.tools.get("draw_render").execute("render",{}),/integrity/);
    await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/delivered/);
    assert.equal(f.calls.some(c=>c.url.endsWith("/approve")),false);
  } finally { await f.stop(); }
});

test("valid SHA cannot bypass actual 2x PNG geometry or PNG format validation", async () => {
  for (const kind of ["dimensions","format"]) {
    const f=await fixture({delivery:true});
    try {
      await f.start();await draftAndRender(f);
      const bytes=Buffer.from(f.image);
      // Exact hashed bytes but an invalid native-preview header, supplied only by this fixture.
      if (kind==="dimensions") bytes.writeUInt32BE(3,16);else bytes[0]=0;
      const hash=createHash("sha256").update(bytes).digest("hex");
      f.options.assets={[hash]:bytes};f.options.renderResponse={previews:[{pageID:f.focusPageID,sha256:hash}]};
      await assert.rejects(()=>f.tools.get("draw_render").execute("render",{}),kind==="dimensions"?/2x/:/not a PNG/);
      await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/delivered/);
    } finally { await f.stop(); }
  }
});

test("read metadata must match active captured pin and document", async () => {
  for (const patch of [ {contextSHA256:"c".repeat(64)}, {context:{documentID:id(),focusPageID:id(),pages:[]}} ]) {
    const f=await fixture({delivery:true,readMetadata:patch});
    try {await f.start();await assert.rejects(()=>f.tools.get("draw_read").execute("read",{view:"overview"}),/staleRequest/);}
    finally {await f.stop();}
  }
});

test("observed remote CAS change fails closed and never auto-retries replacement", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();await draftAndRender(f);
    // Represent a broker state whose version advanced after the bridge's last observation.
    f.options.readMetadata={draftVersion:9};
    await f.tools.get("draw_read").execute("read",{view:"overview"});
    await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/delivered/);
    await assert.rejects(()=>f.tools.get("draw_mark").execute("mark",{kind:"circle",frame:[0,0,3,3]}),/unknown/);
    const start=f.calls.filter(c=>c.url.endsWith("/draft")).length;
    await assert.rejects(()=>f.tools.get("draw_draft").execute("draft",{}),/draft_conflict/);
    assert.equal(f.calls.filter(c=>c.url.endsWith("/draft")).length,start+1);
  } finally {await f.stop();}
});


test("discoverable move/remove schemas preserve draft and bind captured native guards", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();await draftAndRender(f);
    const move=f.tools.get("draw_move"), remove=f.tools.get("draw_remove");
    assert.equal(Check(move.parameters,{targets:["s5","o1"],dx:1,dy:2}),true);
    for (const args of [{targets:[],dx:1,dy:2},{targets:["s5"],dx:1},{targets:["s5"],dx:1,dy:2,color:"#000000"}]) assert.equal(Check(move.parameters,args),false);
    assert.equal(Check(remove.parameters,{targets:["o1"]}),true);
    assert.equal(Check(remove.parameters,{targets:["o1"],dx:1}),false);
    await move.execute("move",{targets:["s5","o1"],dx:1,dy:2});
    const body=f.calls.findLast(c=>c.url.endsWith("/draft")).body;
    assert.equal(body.expectedDraftVersion,1);assert.equal(body.pageEdits[0].objectEdits.length,2);
    assert.equal(body.pageEdits[0].objectEdits[0].object.source,"answer");
    assert.deepEqual(body.pageEdits[0].strokeEdits,[{op:"move",id:f.capture.pages[0].strokeTargets[0].id,fingerprint:"b".repeat(64),dx:1,dy:2}]);
    const replaced=body.pageEdits[0].objectEdits[1], original=f.capture.pages[0].objects[0];
    assert.equal(replaced.op,"replace");assert.equal(replaced.expectedRevision,original.revision);
    assert.deepEqual(replaced.object,{id:original.id,kind:original.kind,source:original.source,style:original.style,frame:{...original.frame,x:1,y:2}});
    await assert.rejects(()=>f.tools.get("draw_approve").execute("approve",{}),/delivered/);
    await remove.execute("remove",{targets:["s5","o1"]});
    const removed=f.calls.findLast(c=>c.url.endsWith("/draft")).body;
    assert.equal(removed.expectedDraftVersion,2);assert.equal(removed.pageEdits[0].objectEdits.length,2);
    assert.deepEqual(removed.pageEdits[0].objectEdits[1],{op:"remove",objectID:original.id,expectedRevision:original.revision});
    assert.deepEqual(removed.pageEdits[0].strokeEdits,[{op:"remove",id:f.capture.pages[0].strokeTargets[0].id,fingerprint:"b".repeat(64)}]);
    assert.equal(f.calls.some(c=>c.url.endsWith("/approve")),false);
    assert.equal(f.sent.length,1);
    assert.equal(JSON.parse(await readFile(join(f.cwd,"current-context.json"),"utf8")).pages[0].objects[0].frame.x,0);
  } finally {await f.stop();}
});

test("repeat moves merge into one operation; exact tool call retry cannot move twice", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();const move=f.tools.get("draw_move");
    const args={targets:["s5","o1"],dx:1.5,dy:-0.5};
    const first=await move.execute("one",args);assert.deepEqual(await move.execute("one",args),first);
    assert.equal(f.calls.filter(c=>c.url.endsWith("/draft")).length,1);
    await assert.rejects(()=>move.execute("one",{...args,dx:3}),/reused/);
    await move.execute("two",args);
    const body=f.calls.findLast(c=>c.url.endsWith("/draft")).body;
    assert.equal(body.pageEdits[0].objectEdits.length,1);assert.equal(body.pageEdits[0].strokeEdits.length,1);
    assert.deepEqual([body.pageEdits[0].strokeEdits[0].dx,body.pageEdits[0].strokeEdits[0].dy],[3,-1]);
    assert.deepEqual([body.pageEdits[0].objectEdits[0].object.frame.x,body.pageEdits[0].objectEdits[0].object.frame.y],[3,-1]);
  } finally {await f.stop();}
});

test("pending labelled mark can move or disappear without invented captured replace/remove", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();
    await f.tools.get("draw_mark").execute("mark",{kind:"circle",frame:[0,0,3,3],id:"new:circle"});
    await f.tools.get("draw_move").execute("move",{targets:["new:circle"],dx:2,dy:1});
    const pending=f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].objectEdits[0];
    assert.equal(pending.op,"add");assert.deepEqual(pending.object.frame,{x:2,y:1,width:3,height:3});assert.equal(pending.expectedRevision,undefined);
    await f.tools.get("draw_remove").execute("remove",{targets:["new:circle"]});
    assert.deepEqual(f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].objectEdits,[]);
    await assert.rejects(()=>f.tools.get("draw_move").execute("absent",{targets:["new:circle"],dx:1,dy:1}),/invalid_handle/);
  } finally {await f.stop();}
});

test("move/remove reject wrong page, duplicate targets, nonfinite deltas and unknown draft before mutation", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();const move=f.tools.get("draw_move"),remove=f.tools.get("draw_remove");
    for (const targets of [["s5"],["o1"],[f.capture.pages[0].objects[0].id]]) {
      await assert.rejects(()=>move.execute("wrong",{pageID:"p2",targets,dx:1,dy:1}),/invalid_handle/);
      await assert.rejects(()=>remove.execute("wrong",{pageID:"p2",targets}),/invalid_handle/);
    }
    for (const value of [NaN,Infinity,-Infinity]) await assert.rejects(()=>move.execute("nonfinite",{targets:["s5"],dx:value,dy:1}),/finite/);
    await assert.rejects(()=>remove.execute("dupe",{targets:["o1",f.capture.pages[0].objects[0].id]}),/duplicate/);
    assert.equal(f.calls.some(c=>c.url.endsWith("/draft")),false);
    f.options.readMetadata={draftVersion:5};await f.tools.get("draw_read").execute("read",{view:"overview"});
    await assert.rejects(()=>remove.execute("unknown",{targets:["s5"]}),/unknown/);
  } finally {await f.stop();}
});

test("raw draw_draft move requires both deltas, forbids color, resolves internal fingerprint", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();const draft=f.tools.get("draw_draft");
    const body=stroke=>({pageEdits:[{pageID:"p1",strokeEdits:[stroke]}]});
    const stroke={id:"s5",op:"move",dx:1,dy:-2};
    assert.equal(Check(draft.parameters,body(stroke)),true);
    for (const invalid of [{id:"s5",op:"move",dx:1},{...stroke,color:"#000000"},{id:"s5",op:"remove",dx:1,dy:2}]) {
      assert.equal(Check(draft.parameters,body(invalid)),false);
      await assert.rejects(()=>draft.execute("invalid",body(invalid)),/dx\/dy|no color/);
    }
    await assert.rejects(()=>draft.execute("fingerprint",body({...stroke,fingerprint:"c".repeat(64)})),/fingerprint/);
    await draft.execute("valid",body(stroke));
    assert.deepEqual(f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].strokeEdits[0],{...stroke,id:f.capture.pages[0].strokeTargets[0].id,fingerprint:"b".repeat(64)});
  } finally {await f.stop();}
});

test("move/render/approve uses exact delivered preview and remove invalidates inspection", async () => {
  const f=await fixture({delivery:true});
  try {
    await f.start();await f.tools.get("draw_move").execute("move",{targets:["s5"],dx:1,dy:0});
    const rendered=await f.tools.get("draw_render").execute("render",{});
    assert.equal(rendered.content[1].data,f.image.toString("base64"));
    await f.tools.get("draw_remove").execute("remove",{targets:["s5"]});
    await assert.rejects(()=>f.tools.get("draw_approve").execute("old",{render:"r1"}),/delivered/);
    const next=await f.tools.get("draw_render").execute("render2",{});
    await f.tools.get("draw_approve").execute("approve",{render:"r2"});
    assert.equal(f.calls.findLast(c=>c.url.endsWith("/approve")).body.renderID,next.details.renderID);
  } finally {await f.stop();}
});

for (const name of ["draw_move","draw_remove"]) test(`${name} cannot persist an old response into new request authority`,async()=>{
  let release,arrived;const reached=new Promise(r=>{arrived=r;});const blocked=new Promise(r=>{release=r;});
  const f=await fixture({delivery:true,terminalStatus:"queued",beforeResponse:async url=>{if(url.endsWith("/draft")){arrived();await blocked;}}});
  try {
    await f.start();const old=f.tools.get(name).execute("edit",{targets:["s5"],...(name==="draw_move"?{dx:1,dy:0}:{})});
    const rejected=assert.rejects(old,/scope changed/);await reached;
    const newID=id();await f.tools.get("draw_terminal_request").execute("new",{requestID:newID,prompt:"new"});release();await rejected;
    assert.equal(f.entries.at(-1).data.requestID,newID);assert.equal(f.entries.at(-1).data.approved,undefined);
  } finally {release();await f.stop();}
});


test("default mark cannot overwrite explicit new:mark1 question, with durable stable allocation",async()=>{
  const f=await fixture({delivery:true});
  try {
    await f.start();
    await f.tools.get("draw_draft").execute("question",{pageEdits:[{pageID:"p1",objectEdits:[{op:"add",object:{id:"new:mark1",kind:"text",source:"Keep this problem",frame:[0,0,4,4]}}]}]});
    const original=f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].objectEdits[0];
    const mark=f.tools.get("draw_mark"),args={kind:"highlight",frame:[1,1,3,3]};
    const result=await mark.execute("automatic",args);assert.deepEqual(await mark.execute("automatic",args),result);
    const draft=JSON.parse(await readFile(join(f.cwd,"current-draft.json"),"utf8"));
    assert.equal(draft.pageEdits[0].objectEdits.length,2);assert.deepEqual(draft.pageEdits[0].objectEdits[0],original);
    const evidence=JSON.parse(await readFile(join(f.cwd,"current-bridge.json"),"utf8"));
    assert.equal(evidence.markCalls.automatic,"new:mark2");assert.equal(evidence.labels["object:new:mark1"],original.object.id);
    await mark.execute("intentional",{...args,id:"new:mark1"});
    const updated=f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].objectEdits;
    assert.equal(updated.length,2);assert.equal(updated[0].object.id,original.object.id);assert.equal(updated[0].object.kind,"highlight");
  }finally{await f.stop();}
});

test("legacy render object fallback never rebinds explicit new:legacy2 to another pending object",async()=>{
  const f=await fixture({delivery:true});
  try {
    await f.start();const legacyID=id();
    const specs=[{id:"new:legacy2",kind:"text",source:"original problem",frame:[0,0,3,3]}, {id:legacyID,kind:"text",source:"legacy answer",frame:[4,0,3,3]}];
    await f.tools.get("draw_draft").execute("draft",{pageEdits:[{pageID:"p1",objectEdits:specs.map(object=>({op:"add",object}))}]});
    const canonical=f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].objectEdits.map(op=>op.object);
    f.options.renderResponse={objects:canonical};
    const rendered=await f.tools.get("draw_render").execute("render",{}),model=JSON.parse(rendered.content[0].text);
    const legacyHandle=model.objects.find(o=>o.source==="legacy answer").id;
    assert.notEqual(legacyHandle,"new:legacy2");assert.equal(model.objects.find(o=>o.source==="original problem").id,"new:legacy2");
    await f.tools.get("draw_move").execute("move",{targets:["new:legacy2",legacyHandle],dx:0,dy:2});
    const moved=f.calls.findLast(c=>c.url.endsWith("/draft")).body.pageEdits[0].objectEdits.map(op=>op.object);
    assert.equal(moved[0].id,canonical[0].id);assert.equal(moved[0].source,"original problem");
    assert.equal(moved[1].id,legacyID);assert.equal(moved[1].source,"legacy answer");
    const evidence=JSON.parse(await readFile(join(f.cwd,"current-bridge.json"),"utf8"));
    assert.equal(evidence.labels["object:new:legacy2"],canonical[0].id);assert.equal(evidence.labels[`object:${legacyHandle}`],legacyID);
  }finally{await f.stop();}
});

test("legacy render page fallback preserves explicit label through chained retry",async()=>{
  const f=await fixture({delivery:true});
  try {
    await f.start();const legacyID=id(),insert=(pageID,afterPageID)=>({pageID,afterPageID,background:0,width:8,height:10});
    await f.tools.get("draw_draft").execute("draft",{insertPages:[insert("new:legacy2","p1"),insert(legacyID,"new:legacy2")],pageEdits:[{pageID:"new:legacy2"},{pageID:legacyID}]});
    const initial=f.calls.findLast(c=>c.url.endsWith("/draft")).body;
    const rendered=await f.tools.get("draw_render").execute("render",{}),pages=JSON.parse(rendered.content[0].text).previews.map(p=>p.page);
    assert.equal(pages[0],"new:legacy2");assert.notEqual(pages[1],"new:legacy2");
    await f.tools.get("draw_draft").execute("retry",{insertPages:[insert(pages[0],"p1"),insert(pages[1],pages[0])],pageEdits:pages.map(pageID=>({pageID}))});
    assert.deepEqual(f.calls.findLast(c=>c.url.endsWith("/draft")).body.insertPages,initial.insertPages);
    const evidence=JSON.parse(await readFile(join(f.cwd,"current-bridge.json"),"utf8"));
    assert.equal(evidence.labels["page:new:legacy2"],initial.insertPages[0].pageID);assert.equal(evidence.labels[`page:${pages[1]}`],legacyID);
  }finally{await f.stop();}
});

test("same-draft legacy UUID insertion chain succeeds, self/future chains fail before broker",async()=>{
  const f=await fixture({delivery:true});
  try {
    await f.start();const refs=[id(),id(),id()],page=(pageID,afterPageID)=>({pageID,afterPageID,background:0,width:8,height:10});
    const body={insertPages:refs.map((pageID,n)=>page(pageID,n?refs[n-1]:"p1")),pageEdits:refs.map(pageID=>({pageID}))};
    const draft=f.tools.get("draw_draft");await draft.execute("chain",body);await draft.execute("retry",body);
    assert.deepEqual(f.calls.findLast(c=>c.url.endsWith("/draft")).body.insertPages.map(p=>p.afterPageID),[f.focusPageID,refs[0],refs[1]]);
    const count=f.calls.filter(c=>c.url.endsWith("/draft")).length;
    for(const insertPages of [[page(refs[0],refs[0])],[page(refs[0],refs[1]),page(refs[1],"p1")]])await assert.rejects(()=>draft.execute("bad",{insertPages}),/invalid_handle/);
    assert.equal(f.calls.filter(c=>c.url.endsWith("/draft")).length,count);
  }finally{await f.stop();}
});

test("pending label/UUID duplicates and old-request aliases cannot modify current scene",async()=>{
  const f=await fixture({delivery:true,terminalStatus:"queued"});
  try {
    await f.start();await f.tools.get("draw_mark").execute("mark",{kind:"circle",frame:[1,1,3,3],id:"new:legacy2"});
    const before=await readFile(join(f.cwd,"current-draft.json"),"utf8"),oid=JSON.parse(before).pageEdits[0].objectEdits[0].object.id;
    const count=f.calls.filter(c=>c.url.endsWith("/draft")).length;
    await assert.rejects(()=>f.tools.get("draw_move").execute("duplicate",{targets:["new:legacy2",oid],dx:1,dy:0}),/duplicate/);
    assert.equal(await readFile(join(f.cwd,"current-draft.json"),"utf8"),before);assert.equal(f.calls.filter(c=>c.url.endsWith("/draft")).length,count);
    const rid=id();await f.tools.get("draw_terminal_request").execute("new",{requestID:rid,prompt:"New task"});
    const calls=f.calls.length;
    await assert.rejects(()=>f.tools.get("draw_move").execute("old",{requestID:f.requestID,targets:["new:legacy2"],dx:1,dy:0}),/does not match/);
    assert.equal(f.calls.length,calls);
    await f.tools.get("draw_draft").execute("empty",{});
    const current=await readFile(join(f.cwd,"current-draft.json"),"utf8");
    for(const target of ["new:legacy2",oid])await assert.rejects(()=>f.tools.get("draw_remove").execute("stale",{targets:[target]}),/invalid_handle/);
    assert.equal(await readFile(join(f.cwd,"current-draft.json"),"utf8"),current);
  }finally{await f.stop();}
});
