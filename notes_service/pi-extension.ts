/** Draw project bridge. Inherits the full global Pi loadout; no SDK/RPC worker. */
import { truncateHead, withFileMutationQueue, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { waitForFreshness } from "./freshness.ts";
import { ModelContext, UUID, box } from "./model-context.ts";

const ID = Type.String({ pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$" });
const SHA = Type.String({ pattern: "^[0-9a-f]{64}$" });
const Ref = Type.String({ maxLength: 256, description: "Captured pN/oN/sN handle, legacy UUID, or generated new:label (typed per request)" });
const Frame = Type.Object({ x: Type.Number(), y: Type.Number(), width: Type.Number({ minimum: 0 }), height: Type.Number({ minimum: 0 }) }, { additionalProperties: false });
const Position = Type.Union([Frame, Type.Tuple([Type.Number(), Type.Number(), Type.Number({ minimum: 0 }), Type.Number({ minimum: 0 })])]);
const Style = Type.Object({ fontSize: Type.Optional(Type.Number({ exclusiveMinimum: 0 })), color: Type.Optional(Type.String({ pattern: "^#[0-9A-Fa-f]{6}$" })), lineWidth: Type.Optional(Type.Number({ exclusiveMinimum: 0 })) }, { additionalProperties: false });
const ObjectSpec = Type.Object({ id: Ref, kind: Type.Union(["text", "latex", "mermaid", "arrow", "circle", "highlight"].map(v => Type.Literal(v))), source: Type.String({ maxLength: 65536 }), frame: Position, style: Type.Optional(Style) }, { additionalProperties: false });
const ObjectEdit = Type.Union([
  Type.Object({ op: Type.Literal("add"), object: ObjectSpec }, { additionalProperties: false }),
  Type.Object({ op: Type.Literal("replace"), objectID: Ref, expectedRevision: Type.Optional(Type.Integer({ minimum: 1 })), object: ObjectSpec }, { additionalProperties: false }),
  Type.Object({ op: Type.Literal("remove"), objectID: Ref, expectedRevision: Type.Optional(Type.Integer({ minimum: 1 })) }, { additionalProperties: false }),
]);
const StrokeEdit = Type.Union([
  Type.Object({ id: Ref, fingerprint: Type.Optional(SHA), op: Type.Union(["keep", "remove", "recolor"].map(v => Type.Literal(v))), color: Type.Optional(Type.String({ pattern: "^#[0-9A-Fa-f]{6}$" })) }, { additionalProperties: false }),
  Type.Object({ id: Ref, fingerprint: Type.Optional(SHA), op: Type.Literal("move"), dx: Type.Number(), dy: Type.Number() }, { additionalProperties: false }),
]);
const Targets = Type.Array(Ref, { minItems: 1, maxItems: 10000, description: "Page-local captured sN/oN handles, or existing pending AI add new:label; legacy captured identities accepted" });
const Insert = Type.Object({ pageID: Ref, afterPageID: Ref, background: Type.Integer({ minimum: 0, maximum: 3 }), width: Type.Number(), height: Type.Number() }, { additionalProperties: false });
const Edit = Type.Object({ pageID: Ref, objectEdits: Type.Optional(Type.Array(ObjectEdit, { maxItems: 128 })), strokeEdits: Type.Optional(Type.Array(StrokeEdit)) }, { additionalProperties: false });

type Descriptor = { documentID: string; sessionID: string; managerURL: string; tokenFile: string; spawnNonce: string };
type SettlementMarker = { eventID: string; event: "agent_settled"; requestID: string; deliveryID?: string; recovered?: boolean };
type RequestMarker = { requestID: string; deliveryID?: string; continued: boolean; approved?: boolean; outputMode?: string };

export default function drawExtension(pi: ExtensionAPI) {
  let descriptor: Descriptor | undefined;
  let token = "", lease = "", companion = false;
  let context: ExtensionContext | undefined;
  let active: RequestMarker | undefined;
  let pendingSettlement: SettlementMarker | undefined;
  let staleRequest: string | undefined;
  let stalePrompt: string | undefined;
  let busy = false, stopped = true, inPoll = false, humanActivity = false;
  let timer: ReturnType<typeof setInterval> | undefined;
  let removeInput: (() => void) | undefined;
  let generation = 0;
  let network = new AbortController();
  let model: ModelContext | undefined;
  let captureLoad: Promise<ModelContext> | undefined, versionLoad: Promise<number> | undefined;
  let pin: { contextSHA256: string; focusPageID: string } | undefined;
  const convenienceResults = new Map<string, { args: string; result: any }>();
  let eventTail: Promise<any> = Promise.resolve();

  const persist = () => { if (active) pi.appendEntry("draw-request", { ...active }); };
  async function api(path: string, data?: unknown, signal?: AbortSignal, method?: string): Promise<any> {
    if (!descriptor || stopped) throw new Error("Draw bridge is unavailable");
    const headers: Record<string,string> = { Authorization: `Bearer ${token}`, "X-Draw-Document": descriptor.documentID };
    if (lease) headers["X-Draw-Lease"] = lease;
    if (data !== undefined) headers["Content-Type"] = "application/json";
    const signals = [network.signal, AbortSignal.timeout(60000)];
    if (signal) signals.push(signal);
    let response: Response;
    try {
      response = await fetch(descriptor.managerURL + path, { method: method ?? (data === undefined ? "GET" : "POST"), headers, body: data === undefined ? undefined : JSON.stringify(data), signal: AbortSignal.any(signals), redirect: "error" });
    } catch { throw new Error("Draw manager request unavailable"); }
    const value = await response.json();
    if (!response.ok) {
      const error = new Error(`Draw ${value.error?.code ?? "request_failed"}: ${value.error?.message ?? "request failed"}`);
      (error as any).code = value.error?.code;
      throw error;
    }
    return value;
  }
  function activityBody(ctx: ExtensionContext, gateSettlement = true) {
    const result = { busy: busy || !ctx.isIdle(), pending: ctx.hasPendingMessages() || (gateSettlement && !!pendingSettlement), inputObserved: ctx.mode === "tui" && !!removeInput, humanActivity, activeRequestID: active?.requestID ?? null, contextUsage: ctx.getContextUsage() ?? null };
    humanActivity = false;
    return result;
  }
  async function register(ctx: ExtensionContext) {
    if (!descriptor) return;
    if (ctx.sessionManager.getSessionId() !== descriptor.sessionID || resolve(ctx.cwd) !== resolve(ctx.sessionManager.getCwd())) throw new Error("Draw exact session identity changed; recovery required");
    const response = await api("/v1/workers/register", { documentID: descriptor.documentID, sessionID: ctx.sessionManager.getSessionId(), sessionFile: ctx.sessionManager.getSessionFile(), cwd: ctx.cwd, spawnNonce: descriptor.spawnNonce, ...activityBody(ctx) });
    lease = response.lease;
    companion = response.companion;
  }
  function event(kind: string, rid = active?.requestID) {
    // Lifecycle reports stay ordered even while Pi executes sibling tools.
    eventTail = eventTail.catch(() => {}).then(async () => {
      if (!descriptor || stopped || !lease) return;
      await api(`/v1/workers/${descriptor.documentID}/event`, { event: kind, requestID: rid, ...(kind === "agent_settled" && context ? { activity: activityBody(context, false) } : {}) });
    });
    return eventTail;
  }
  function queueSettlement(marker: RequestMarker, recovered = false) {
    if (pendingSettlement) throw new Error("Draw settlement awaiting acknowledgement");
    const value: SettlementMarker = { eventID: randomUUID().toUpperCase(), event: "agent_settled", requestID: marker.requestID,
      ...(marker.deliveryID ? { deliveryID: marker.deliveryID } : {}), ...(recovered ? { recovered: true } : {}) };
    pi.appendEntry("draw-lifecycle-pending", value); // Persist before the first network await.
    pendingSettlement = value;
    active = undefined; // End page-writing authority; outbox still blocks delivery.
  }
  function acknowledgeSettlement(marker: SettlementMarker, response: any, epoch: number) {
    if (epoch !== generation || pendingSettlement?.eventID !== marker.eventID) return;
    if (response?.ok !== true || response.settlementID !== marker.eventID) throw new Error("Draw settlement not acknowledged");
    pi.appendEntry("draw-lifecycle-ack", { eventID: marker.eventID });
    pi.appendEntry("draw-settled", { requestID: marker.requestID, eventID: marker.eventID });
    pendingSettlement = undefined;
  }
  function flushSettlement(ctx: ExtensionContext) {
    eventTail = eventTail.catch(() => {}).then(async () => {
      if (!pendingSettlement || stopped || !descriptor || !lease) return;
      const marker = pendingSettlement, epoch = generation;
      const response = await api(`/v1/workers/${descriptor.documentID}/event`,
        { ...marker, activity: activityBody(ctx, false) }, AbortSignal.timeout(5000));
      acknowledgeSettlement(marker, response, epoch);
    });
    return eventTail;
  }
  function requireSettlementAck() {
    if (pendingSettlement) throw new Error("Draw settlement awaiting acknowledgement; no new page-writing delivery");
  }
  function scopeGuard() {
    const marker = active, epoch = generation, worker = descriptor, workerLease = lease;
    return () => {
      if (stopped || generation !== epoch || descriptor !== worker || lease !== workerLease || active !== marker || pendingSettlement) throw new Error("Draw request scope changed; discard this response");
    };
  }
  async function activateLocal(r: any, prompt: string, checkScope: () => void) {
    checkScope();
    active = { requestID: r.requestID, ...(r.deliveryID ? { deliveryID: r.deliveryID } : {}), continued: false, outputMode: r.outputMode ?? (companion ? "companion" : "page_only") };
    model = undefined; captureLoad = undefined; versionLoad = undefined; convenienceResults.clear();
    pin = { contextSHA256: r.contextSHA256, focusPageID: r.focusPageID };
    persist(); // Durable authority before any file/network await; never replay on recovery.
    const checkActive = scopeGuard();
    const path = join(context!.cwd, "current-request.json");
    const metadata = { requestID: r.requestID, documentID: descriptor!.documentID, sessionID: descriptor!.sessionID,
      deliveryID: r.deliveryID, focusPageID: r.focusPageID, contextSHA256: r.contextSHA256, prompt, outputMode: active.outputMode };
    await withFileMutationQueue(path, async () => {
      checkActive();
      await writeFile(path, JSON.stringify(metadata), { mode: 0o600 });
    });
    checkActive();
  }
  async function poll(ctx: ExtensionContext) {
    if (inPoll || stopped || !descriptor) return;
    inPoll = true;
    const epoch = generation;
    try {
      await eventTail.catch(() => {});
      if (!lease) await register(ctx);
      await flushSettlement(ctx).catch(() => {});
      // Heartbeats share lifecycle ordering: an older idle snapshot cannot arrive after a new agent_start.
      const heartbeatTask = eventTail = eventTail.catch(() => {}).then(async () => {
        const marker = pendingSettlement;
        const heartbeat = await api(`/v1/workers/${descriptor!.documentID}/heartbeat`,
          { ...activityBody(ctx), ...(marker ? { settlement: marker } : {}) });
        if (marker) acknowledgeSettlement(marker, heartbeat, epoch);
        return heartbeat;
      });
      const heartbeat = await heartbeatTask;
      await eventTail.catch(() => {});
      companion = heartbeat.companion;
      if (heartbeat.shutdown && !busy && ctx.isIdle() && !ctx.hasPendingMessages() && !active && !pendingSettlement) {
        ctx.shutdown();
        return;
      }
      if (busy || !ctx.isIdle() || ctx.hasPendingMessages() || active || pendingSettlement) return;
      const checkScope = scopeGuard();
      const response = await api(`/v1/workers/${descriptor.documentID}/poll`, activityBody(ctx));
      checkScope();
      const r = response.request;
      if (!r) return;
      // No user injection unless still idle. A lease made uncertain by a race is never redelivered automatically.
      if (!ctx.isIdle() || ctx.hasPendingMessages() || busy) throw new Error("Draw worker became busy during delivery; explicit reconciliation required");
      await activateLocal(r, r.prompt, checkScope);
      if (!ctx.isIdle() || ctx.hasPendingMessages() || busy) throw new Error("Draw worker became busy during delivery; explicit reconciliation required");
      busy = true;
      pi.sendUserMessage(r.prompt);
    } catch (error: any) {
      if (error.code === "bridge_lease") lease = "";
      if (!stopped) ctx.ui.setStatus("draw", "Draw bridge unavailable; no automatic request replay");
    } finally { inPoll = false; }
  }

  pi.on("session_start", async (_event, ctx) => {
    generation++;
    network = new AbortController();
    stopped = false;
    context = ctx;
    busy = !ctx.isIdle();
    try {
      descriptor = JSON.parse(await readFile(join(ctx.cwd, "document.json"), "utf8"));
      if (!descriptor || descriptor.sessionID !== ctx.sessionManager.getSessionId()) throw new Error("Draw worker session does not match document registry");
      const origin = new URL(descriptor.managerURL);
      if (origin.protocol !== "http:" || origin.hostname !== "127.0.0.1" || origin.username || origin.password || origin.pathname !== "/") throw new Error("Draw manager must be loopback HTTP");
      token = (await readFile(descriptor.tokenFile, "utf8")).trim();
      active = undefined;
      pendingSettlement = undefined;
      for (const entry of ctx.sessionManager.getBranch()) {
        if (entry.type === "custom" && entry.customType === "draw-request") active = entry.data as RequestMarker;
        if (entry.type === "custom" && entry.customType === "draw-settled") active = undefined;
        if (entry.type === "custom" && entry.customType === "draw-lifecycle-pending") {
          pendingSettlement = entry.data as SettlementMarker;
          if (active?.requestID === pendingSettlement.requestID) active = undefined;
        }
        if (entry.type === "custom" && entry.customType === "draw-lifecycle-ack" && (entry.data as any)?.eventID === pendingSettlement?.eventID) pendingSettlement = undefined;
      }
      if (ctx.mode === "tui") removeInput = ctx.ui.onTerminalInput(() => { humanActivity = true; });
      await register(ctx);
      if (pendingSettlement) ctx.ui.notify(`Draw request ${pendingSettlement.requestID}: retrying durable settlement only. No automatic replay.`, "info");
      if (active) {
        // Resume can report existing authority but must not send the old prompt again.
        const status = await api(`/v1/requests/${active.requestID}`);
        ctx.ui.notify(`Draw request ${active.requestID}: ${status.status}. No automatic replay.`, "info");
        queueSettlement(active, true);
      }
      timer = setInterval(() => { void poll(ctx); }, 1000);
      timer.unref();
      await poll(ctx);
    } catch {
      stopped = true;
      network.abort();
      removeInput?.(); removeInput = undefined;
      ctx.ui.notify("Draw bridge identity or manager unavailable; page-writing tools disabled. Reload after explicit recovery.", "error");
    }
  });
  pi.on("session_shutdown", async () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    removeInput?.(); removeInput = undefined;
    if (context) await flushSettlement(context).catch(() => {});
    await event("shutdown", active?.requestID ?? pendingSettlement?.requestID).catch(() => {});
    stopped = true; generation++; network.abort(); lease = "";
  });
  pi.on("session_before_switch", () => descriptor ? { cancel: true } : undefined);
  pi.on("session_before_fork", () => descriptor ? { cancel: true } : undefined);
  pi.on("input", async (e, ctx) => {
    if (e.source !== "extension") {
      humanActivity = true;
      await event("human").catch(() => {});
      if (staleRequest && /^(use (the )?synced( version)?|wait|cancel)[.!]?$/i.test(e.text.trim())) {
        requireSettlementAck();
        const text = e.text.trim().toLowerCase();
        const choice = text.startsWith("use") ? "use_synced" : text.startsWith("wait") ? "wait" : "cancel";
        const rid = staleRequest;
        const checkScope = scopeGuard();
        const result = await api(`/v1/requests/${rid}/stale-choice`, { choice });
        checkScope();
        if (result.status === "queued") {
          const activated = await api(`/v1/requests/${rid}/activate`, {});
          await activateLocal(activated, stalePrompt!, checkScope);
          staleRequest = undefined; stalePrompt = undefined;
        }
        return { action: "continue" };
      }
    }
  });
  pi.on("before_agent_start", (e) => {
    if (!descriptor || stopped) return;
    e.systemPromptOptions.promptGuidelines.push(`Draw current state: page-writing authority ${active && !pendingSettlement ? "active" : "inactive"}; outputMode=${active?.outputMode ?? (companion ? "companion" : "page_only")}${pendingSettlement ? "; settlement acknowledgement pending" : ""}.`);
  });
  pi.on("agent_start", async () => { busy = true; await event("agent_start").catch(() => {}); });
  pi.on("agent_before_settle", async (e) => {
    if (!active || active.approved || active.continued || e.outcome !== "completed" || e.continue || !e.context.canContinue || stopped) return;
    const checkScope = scopeGuard();
    let status;
    try { status = await api(`/v1/requests/${active.requestID}`); checkScope(); } catch { return; }
    if (status.status !== "running") return;
    active.continued = true; persist();
    return { continue: true, entries: [{ type: "custom_message", customType: "draw-page-reminder", display: false, content: "This request has no approved page output. Finish it now." }] };
  });
  pi.on("agent_settled", async (_event, ctx) => {
    busy = false;
    if (active) queueSettlement(active);
    if (pendingSettlement) await flushSettlement(ctx).catch(() => {});
    else await event("agent_settled").catch(() => {});
  });

  async function privateFile(name: string, data: string | Uint8Array, checkScope = scopeGuard()) {
    const path = join(context!.cwd, name);
    await withFileMutationQueue(path, async () => { checkScope(); await writeFile(path, data, { mode: 0o600 }); });
    checkScope();
  }
  async function assetBytes(sha: string, limit: number, signal?: AbortSignal) {
    if (!descriptor || !/^[0-9a-f]{64}$/.test(sha)) throw new Error("Draw asset SHA unavailable");
    const response = await fetch(`${descriptor.managerURL}/v1/assets/${sha}`, { headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.any([network.signal, signal ?? network.signal, AbortSignal.timeout(30000)]), redirect: "error" });
    if (!response.ok || !response.body) throw new Error("Draw asset download failed");
    const chunks: Uint8Array[] = []; let size = 0;
    const reader = response.body.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        size += value.length;
        if (size > limit) throw new Error("Draw asset exceeds transfer limit");
        chunks.push(value);
      }
    } catch (e) { await reader.cancel().catch(() => {}); throw e; }
    finally { reader.releaseLock(); }
    const data = Buffer.concat(chunks);
    if (createHash("sha256").update(data).digest("hex") !== sha) throw new Error("Draw asset integrity failed");
    return data;
  }
  function captured(signal?: AbortSignal): Promise<ModelContext> {
    if (!active || !pin) throw new Error("Draw has no active captured request");
    if (!captureLoad) {
      const marker = active, binding = pin, checkScope = scopeGuard();
      captureLoad = (async () => {
        const bytes = await assetBytes(binding.contextSHA256, 4*1024*1024, signal);
        checkScope();
        const value = new ModelContext(marker.requestID, JSON.parse(bytes.toString("utf8")), descriptor!.documentID, binding.focusPageID);
        await privateFile("current-context.json", bytes, checkScope);
        checkScope(); model = value; return value;
      })(); // One exact hashed GET per request, including a failed capture (fail closed).
    }
    return captureLoad;
  }
  function verifyRead(value: any, m: ModelContext) {
    if (value.contextSHA256 !== pin?.contextSHA256 || value.context?.documentID !== descriptor?.documentID || value.context?.focusPageID !== pin?.focusPageID) throw new Error("Draw staleRequest: read does not match active capture");
    m.observeVersion(value.draftVersion);
  }
  async function version(m: ModelContext, signal?: AbortSignal) {
    if (m.draftVersion !== undefined) return m.draftVersion;
    if (!versionLoad) {
      const checkScope = scopeGuard();
      versionLoad = (async () => {
        const value = await api(`/v1/requests/${m.requestID}/read`, { view: "overview" }, signal);
        checkScope(); verifyRead(value, m); return m.draftVersion!;
      })();
    }
    return versionLoad;
  }
  async function toolResult(value: any, signal?: AbortSignal, compact?: any, previewModel?: ModelContext) {
    const checkScope = scopeGuard(), deliveryModel = model;
    await privateFile("draw-last-result.json", JSON.stringify(value), checkScope);
    const modelJSON = JSON.stringify(compact ?? model?.compact(value) ?? value);
    const truncated = truncateHead(modelJSON, { maxBytes: 50000, maxLines: 2000 });
    const content: any[] = [{ type: "text", text: truncated.content + (truncated.truncated ? "\nTruncated; full response: draw-last-result.json" : "") }];
    try { for (const image of value.images ?? value.previews ?? []) {
      const data = await assetBytes(image.sha256, 128*1024*1024, signal);
      checkScope();
      if (!data.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])) || data.length < 33 || data.toString("ascii",12,16) !== "IHDR") throw new Error("Draw preview is not a PNG");
      if (previewModel) {
        const page = previewModel.pages.get(image.pageID) ?? previewModel.draft?.insertPages.find((p: any) => p.pageID === image.pageID);
        if (!page || data.readUInt32BE(16) !== Math.round(page.width*2) || data.readUInt32BE(20) !== Math.round(page.height*2)) throw new Error("Draw preview must match affected page at 2x");
      }
      content.push({ type: "image", data: data.toString("base64"), mimeType: "image/png" });
    }
    } catch (e) { if (model === deliveryModel && deliveryModel) deliveryModel.delivered = undefined; throw e; }
    return { content, details: value, structuredContent: JSON.parse(modelJSON) };
  }
  function proxy(name: string, description: string, parameters: any, endpoint: string) {
    pi.registerTool({ name, label: name, description, parameters, executionMode: endpoint === "draft" ? "parallel" : "sequential", outputSchema: Type.Any(),
      async execute(callID, params: any, signal) {
        if (!descriptor || stopped) throw new Error("Draw bridge unavailable");
        requireSettlementAck();
        if (!active) throw new Error("Draw has no active page-writing request");
        const { requestID: explicitID, ...input } = params;
        const convenience = ["mark", "move", "remove"].includes(endpoint), mutation = endpoint === "draft" || convenience;
        if (explicitID !== undefined && explicitID !== active.requestID) throw new Error("Draw requestID does not match the active request");
        const checkScope = scopeGuard(), m = await captured(signal); checkScope();
        // Capture CAS before joining the mutation queue; concurrent complete drafts cannot overwrite siblings.
        const expected = endpoint === "draft" ? input.expectedDraftVersion ?? await version(m, signal) : undefined;
        checkScope();
        return withFileMutationQueue(join(context!.cwd, "current-bridge.json"), async () => {
          checkScope();
          let body = input;
          if (convenience) {
            const cached = convenienceResults.get(`${endpoint}:${callID}`);
            if (cached) {
              if (cached.args !== JSON.stringify(input)) throw new Error(`Draw ${endpoint} tool call ID reused with different arguments`);
              return cached.result;
            }
            await version(m, signal); checkScope(); body = endpoint === "mark" ? m.mark(input, callID) : m.edit(input, endpoint as "move" | "remove");
          } else if (endpoint === "read") body = { ...input, ...(input.view !== "overview" && { pageID: m.page(input.pageID) }), ...(input.rect && { rect: box(input.rect) }) };
          else if (endpoint === "draft") {
            if (m.draftVersion !== undefined && expected !== m.draftVersion) throw new Error("Draw draft_conflict: draft version changed; read and rebuild complete draft");
            body = m.resolveDraft({ ...input, expectedDraftVersion: expected });
          } else if (endpoint === "render") {
            const latest = await version(m, signal);
            body = { ...input, draftVersion: input.draftVersion ?? latest };
          }
          else if (endpoint === "approve") body = m.approval(input);
          checkScope();
          if (mutation || endpoint === "render") m.delivered = undefined;
          let value;
          try { value = await api(`/v1/requests/${m.requestID}/${convenience ? "draft" : endpoint}`, body, signal); }
          catch (e) {
            if (mutation) { m.draft = undefined; m.draftVersion = undefined; versionLoad = undefined; }
            throw e;
          }
          checkScope();
          if (endpoint === "read") verifyRead(value, m);
          if (mutation) {
            m.observeVersion(value.draftVersion); m.draft = { insertPages: body.insertPages ?? [], pageEdits: body.pageEdits ?? [] };
            await privateFile("current-draft.json", JSON.stringify({ requestID: m.requestID, ...m.draft, draftVersion: m.draftVersion }), checkScope);
          }
          if (endpoint === "render") {
            const expectedPages = new Set([...(m.draft?.pageEdits ?? []).map((p: any) => p.pageID), ...(m.draft?.insertPages ?? []).map((p: any) => p.pageID)]);
            const actualPages = value.previews?.map((p: any) => p.pageID) ?? [];
            if (value.draftVersion !== m.draftVersion || !UUID.test(value.renderID) || !actualPages.length || new Set(actualPages).size !== actualPages.length || (m.draft && (actualPages.length !== expectedPages.size || actualPages.some((id: string) => !expectedPages.has(id))))) throw new Error("Draw render response does not cover exact current draft");
          }
          const renderHandle = endpoint === "render" ? `r${m.renders+1}` : undefined;
          const result = await toolResult(value, signal, m.compact(value, renderHandle), endpoint === "render" ? m : undefined);
          checkScope();
          if (endpoint === "render") {
            m.renders++; m.delivered = { handle: renderHandle!, value };
            await privateFile("current-render.json", JSON.stringify({ requestID: m.requestID, ...m.delivered }), checkScope);
          }
          // This file is private machine evidence, not a prompt or recovery authority.
          checkScope(); await writeFile(join(context!.cwd, "current-bridge.json"), JSON.stringify(m.evidence()), { mode: 0o600 }); checkScope();
          if (convenience) {
            convenienceResults.set(`${endpoint}:${callID}`, { args: JSON.stringify(input), result });
            if (convenienceResults.size > 128) convenienceResults.delete(convenienceResults.keys().next().value!);
          }
          if (endpoint === "approve") { active!.approved = true; persist(); }
          return result;
        }).catch(e => { if (endpoint === "render") m.delivered = undefined; throw e; });
      },
    });
  }
  proxy("draw_read", "Read pinned native images and compact geometry. Overview omits stroke bodies; page lists purple question targets; crop lists all intersecting colors. pageID=pN (default focus). Stroke sN uses original captured index+1, object oN is page-local; handles are current-request only. Frame/rect arrays=[x,y,w,h] in page points, crop retains page origin. Optional stroke row color/questionInk use strokeDefaults. Full private JSON: current-context.json and draw-last-result.json, available to normal code/read tools.", Type.Object({ requestID: Type.Optional(ID), view: Type.Union(["overview", "page", "crop"].map(v => Type.Literal(v))), pageID: Type.Optional(Ref), rect: Type.Optional(Position) }, { additionalProperties: false }), "read");
  proxy("draw_draft", "Replace complete draft with CAS. expectedDraftVersion defaults to observed latest; conflicts require rebuilding, never blind retries. Use pN/sN/oN; new pages/objects use stable new:label instead of UUID. Captured fingerprint/revision autofill, explicit legacy mismatches fail. Objects accept frame=[x,y,w,h] points. Full private current-draft.json.", Type.Object({ requestID: Type.Optional(ID), expectedDraftVersion: Type.Optional(Type.Integer({ minimum: 0 })), insertPages: Type.Optional(Type.Array(Insert, { maxItems: 32 })), pageEdits: Type.Optional(Type.Array(Edit)) }, { additionalProperties: false }), "draft");
  proxy("draw_render", "Render current draft (version defaults to latest); three attempts including failures. Returns rN and every verified actual 2x PNG for inspection. Full private current-render.json.", Type.Object({ requestID: Type.Optional(ID), draftVersion: Type.Optional(Type.Integer({ minimum: 1 })), renderID: Type.Optional(ID) }, { additionalProperties: false }), "render");
  proxy("draw_approve", "Explicitly publish AFTER inspecting every latest delivered preview. Defaults to latest rN; optional render:rN or exact legacy renderID/version/hashes must match. Draft changes or failed delivery prohibit stale approval. Never automatic.", Type.Object({ requestID: Type.Optional(ID), render: Type.Optional(Type.String({ pattern: "^r[1-9][0-9]*$" })), draftVersion: Type.Optional(Type.Integer({ minimum: 1 })), renderID: Type.Optional(ID), inspectedPreviewSHA256s: Type.Optional(Type.Array(SHA)) }, { additionalProperties: false }), "approve");
  proxy("draw_mark", "Append cyan highlight (20% opacity) or circle to CURRENT complete draft, preserving all edits with latest CAS. pageID defaults to focus, frame=[x,y,w,h] page points; optional id=new:label or captured oN replaces that object. Stable per-call generated ID. Still requires render, inspect, approve.", Type.Object({ requestID: Type.Optional(ID), pageID: Type.Optional(Ref), kind: Type.Union([Type.Literal("highlight"), Type.Literal("circle")]), frame: Position, id: Type.Optional(Ref) }, { additionalProperties: false }), "mark");

  proxy("draw_move", "Move current-task ink/AI work aside without a confirmation dialog. Preserve the CURRENT complete draft with CAS; targets are page-local captured sN/oN, or pending AI add new:label. pageID defaults to focus; dx/dy are finite deltas in original page points (right/down positive). Repeated moves merge; incompatible stroke edits fail. Source changes remain staged until render, inspect, explicit approve; hint-first assistance stays unchanged.", Type.Object({ requestID: Type.Optional(ID), pageID: Type.Optional(Ref), targets: Targets, dx: Type.Number(), dy: Type.Number() }, { additionalProperties: false }), "move");
  proxy("draw_remove", "Remove current-task ink/AI elements without a confirmation dialog. Preserve the CURRENT complete draft with CAS; targets are page-local captured sN/oN, or pending AI add new:label. pageID defaults to focus. Captured guards resolve internally; no other-document authority. Source changes remain staged until render, inspect, explicit approve; no implicit solving or approval.", Type.Object({ requestID: Type.Optional(ID), pageID: Type.Optional(Ref), targets: Targets }, { additionalProperties: false }), "remove");

  async function setCompanion(enabled: boolean) {
    if (!descriptor) throw new Error("Draw bridge unavailable");
    await api(`/v1/documents/${descriptor.documentID}/companion`, { enabled }, undefined, "PUT");
    companion = enabled;
    context?.ui.notify(enabled ? "Companion mode on until explicitly disabled." : "Page-only mode restored.", "info");
    return { enabled };
  }
  pi.registerTool({ name: "draw_companion", label: "Draw companion", description: "Announce and persist companion mode when Anton explicitly wants to watch/converse alongside Draw. Remains enabled until explicitly off. Page-only is default.", parameters: Type.Object({ enabled: Type.Boolean() }, { additionalProperties: false }), async execute(_id, p) { return toolResult(await setCompanion(p.enabled)); } });
  pi.registerCommand("companion", { description: "Sticky Draw companion mode: /companion on|off", handler: async (args, ctx) => {
    if (args.trim() !== "on" && args.trim() !== "off") { ctx.ui.notify(`Companion ${companion ? "on" : "off"}. Usage: /companion on|off`, "info"); return; }
    await setCompanion(args.trim() === "on");
  } });
  pi.registerTool({ name: "draw_terminal_request", label: "Draw terminal request", description: "Create a fresh page-writing request for this document via live Sync. Supply the current user task as prompt. Returns Sync status or required human stale choice; waits up to 10s for response or 300s after Sync acknowledgement.", parameters: Type.Object({ requestID: Type.Optional(ID), prompt: Type.String({ minLength: 1, maxLength: 65536 }), focusPageID: Type.Optional(ID) }, { additionalProperties: false }), async execute(_id, p, signal) {
    if (!descriptor) throw new Error("Draw bridge unavailable");
    requireSettlementAck();
    const { requestID = randomUUID().toUpperCase(), ...body } = p;
    const checkScope = scopeGuard();
    let value = await api(`/v1/documents/${descriptor.documentID}/terminal-requests`, { requestID, ...body }, signal);
    checkScope();
    value = await waitForFreshness(value, async () => {
      checkScope();
      const status = await api(`/v1/requests/${requestID}`, undefined, signal);
      checkScope();
      return status;
    }, signal ?? network.signal);
    checkScope();
    if (value.status === "synchronizing") value.instruction = "Foreground Draw is actively synchronizing. Do not fall back to stale notes; the manager owns the bounded Sync deadline.";
    if (value.status === "queued" || value.status === "running") {
      value = await api(`/v1/requests/${requestID}/activate`, {}, signal);
      await activateLocal(value, body.prompt, checkScope);
    }
    else if (value.status === "needs_stale_choice" || value.status === "awaiting_sync") { staleRequest = requestID; stalePrompt = body.prompt; value.requiredHumanChoice = "use synced / wait / cancel"; }
    const checkResultScope = scopeGuard();
    const result = await toolResult(value, signal, Object.fromEntries(["status", "instruction", "requiredHumanChoice", "lastSyncedAt"].filter(k => value[k] !== undefined).map(k => [k, value[k]])));
    checkResultScope();
    return result;
  } });
  pi.registerCommand("draw-stale", { description: "Explicit stale choice: /draw-stale REQUEST_UUID use_synced|wait|cancel", handler: async (args, ctx) => {
    requireSettlementAck();
    const [rid, choice] = args.trim().split(/\s+/);
    if (!rid || !["use_synced", "wait", "cancel"].includes(choice)) { ctx.ui.notify("Usage: /draw-stale REQUEST_UUID use_synced|wait|cancel", "warning"); return; }
    const result = await api(`/v1/requests/${rid}/stale-choice`, { choice });
    if (result.status === "queued") { staleRequest = undefined; await poll(ctx); }
    ctx.ui.notify(`Draw request ${rid}: ${result.status}`, "info");
  } });
}
