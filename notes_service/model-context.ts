/** Request-local translation only. Broker/native validators retain final authority. */
import { createHash } from "node:crypto";

export const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
export const boxArray = (f: any) => f && [f.x, f.y, f.width, f.height];
export function box(f: any) {
  const result = Array.isArray(f) ? { x: f[0], y: f[1], width: f[2], height: f[3] } : f;
  if (!result || (Array.isArray(f) && f.length !== 4) || ![result.x, result.y, result.width, result.height].every(Number.isFinite)) throw new Error("Draw frame requires [x,y,width,height] in page points");
  return result;
}
const fail = (message: string): never => { throw new Error(`Draw staleRequest/invalid_handle: ${message}`); };

export class ModelContext {
  readonly pages: Map<string, any>;
  readonly labels = new Map<string, string>();
  readonly markCalls = new Map<string, string>();
  draftVersion?: number;
  draft?: any;
  delivered?: { handle: string; value: any };
  renders = 0;
  marks = 0;

  constructor(readonly requestID: string, readonly capture: any, documentID: string, focusPageID: string) {
    if (capture.documentID !== documentID || capture.focusPageID !== focusPageID || !Array.isArray(capture.pages) || !capture.pages.length) fail("capture document/focus does not match active descriptor");
    this.pages = new Map(capture.pages.map((p: any) => [p.pageID, p]));
    if (!this.pages.has(focusPageID) || this.pages.size !== capture.pages.length) fail("invalid captured pages");
    for (const p of capture.pages) {
      if (!UUID.test(p.pageID) || new Set(p.strokeTargets.map((s: any) => s.index)).size !== p.strokeTargets.length) fail("ambiguous captured page/stroke order");
    }
  }
  generated(kind: "page" | "object", label: string) {
    if (!/^new:[A-Za-z0-9_.:-]{1,128}$/.test(label)) fail("use new:label for a generated identity");
    const key = `${kind}:${label}`;
    if (!this.labels.has(key)) {
      this.labels.set(key, this.generatedID(kind, label));
    }
    return this.labels.get(key)!;
  }
  private generatedID(kind: "page" | "object", label: string) {
    // Deterministic request + typed namespace, never the model's UUID allocation.
    const bytes = createHash("sha256").update(JSON.stringify([this.requestID, kind, label])).digest().subarray(0, 16);
    bytes[6] = (bytes[6] & 15) | 0x50; bytes[8] = (bytes[8] & 63) | 0x80;
    const hex = bytes.toString("hex").toUpperCase();
    return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
  }
  private legacyHandle(kind: "page" | "object", id: string) {
    let key = [...this.labels].find(([key, value]) => key.startsWith(`${kind}:`) && value === id)?.[0];
    if (!key) {
      let n = this.labels.size+1;
      while (this.labels.has(`${kind}:new:legacy${n}`)) n++;
      key = `${kind}:new:legacy${n}`; this.labels.set(key, id);
    }
    return key.slice(kind.length+1);
  }
  page(ref = this.capture.focusPageID, create = false, inserted: string[] = []): string {
    if (/^p[1-9][0-9]*$/.test(ref)) {
      const p = this.capture.pages[Number(ref.slice(1))-1];
      if (!p) fail(`unknown page ${ref} in current request`);
      return p.pageID;
    }
    if (ref.startsWith("new:")) {
      if (create) return this.generated("page", ref);
      const id = this.labels.get(`page:${ref}`);
      if (id) return id;
    }
    if (UUID.test(ref) && (create || this.pages.has(ref) || inserted.includes(ref) || this.draft?.insertPages.some((p: any) => p.pageID === ref))) return ref;
    return fail(`unknown page ${ref} in current request`);
  }
  pageHandle(id: string) {
    const n = this.capture.pages.findIndex((p: any) => p.pageID === id);
    if (n >= 0) return `p${n+1}`;
    return this.legacyHandle("page", id);
  }
  object(pageID: string, ref: string, create = false): string {
    const objects = this.pages.get(pageID)?.objects ?? [];
    if (/^o[1-9][0-9]*$/.test(ref)) {
      const obj = objects[Number(ref.slice(1))-1];
      if (obj) return obj.id;
    }
    if (create && ref.startsWith("new:")) return this.generated("object", ref);
    if (UUID.test(ref) && (create || objects.some((o: any) => o.id === ref))) return ref;
    return fail(`object ${ref} is not on ${this.pageHandle(pageID)} in current capture`);
  }
  stroke(pageID: string, ref: string) {
    const targets = this.pages.get(pageID)?.strokeTargets ?? [];
    const target = /^s[1-9][0-9]*$/.test(ref) ? targets.find((t: any) => t.index === Number(ref.slice(1))-1) : targets.find((t: any) => t.id === ref);
    if (!target) fail(`stroke ${ref} is not on ${this.pageHandle(pageID)} in current capture`);
    return target;
  }
  objectHandle(id: string, pageID?: string) {
    const pages = pageID ? [this.pages.get(pageID)] : this.capture.pages;
    for (const page of pages) {
      const n = page?.objects.findIndex((o: any) => o.id === id) ?? -1;
      if (n >= 0) return `o${n+1}`;
    }
    return this.legacyHandle("object", id);
  }
  resolveDraft(body: any) {
    const inserted: string[] = [];
    const inserts = (body.insertPages ?? []).map((p: any) => {
      const pageID = this.page(p.pageID, true), afterPageID = this.page(p.afterPageID, false, inserted);
      if (this.pages.has(pageID) || inserted.includes(pageID)) fail("inserted page must have a fresh unique identity");
      if (!this.pages.has(afterPageID) && !inserted.includes(afterPageID)) fail("insertions must follow a captured or earlier inserted page");
      inserted.push(pageID);
      return { ...p, pageID, afterPageID };
    });
    const edits = (body.pageEdits ?? []).map((e: any) => {
      const pageID = this.page(e.pageID, false, inserts.map((p: any) => p.pageID)), captured = this.pages.get(pageID);
      return { ...e, pageID,
        ...(e.objectEdits && { objectEdits: e.objectEdits.map((op: any) => {
          const objectID = op.op === "add" ? undefined : this.object(pageID, op.objectID);
          const obj = captured?.objects.find((o: any) => o.id === objectID);
          if (obj && op.expectedRevision !== undefined && op.expectedRevision !== obj.revision) fail("explicit expectedRevision does not match captured object");
          const object = op.object && { ...op.object, id: this.object(pageID, op.object.id, op.op === "add"), frame: box(op.object.frame) };
          return { ...op, ...(objectID && { objectID, expectedRevision: obj.revision }), ...(object && { object }) };
        }) }),
        ...(e.strokeEdits && { strokeEdits: e.strokeEdits.map((s: any) => {
          const target = this.stroke(pageID, s.id);
          if (s.op === "move" && (!Number.isFinite(s.dx) || !Number.isFinite(s.dy) || s.color !== undefined)) throw new Error("Draw stroke move requires finite dx/dy page-point deltas and no color");
          if (s.op !== "move" && (s.dx !== undefined || s.dy !== undefined)) throw new Error("Draw dx/dy are only valid for stroke move");
          if (s.fingerprint !== undefined && s.fingerprint !== target.fingerprint) fail("explicit fingerprint does not match captured stroke");
          return { ...s, id: target.id, fingerprint: target.fingerprint };
        }) }),
      };
    });
    return { expectedDraftVersion: body.expectedDraftVersion, insertPages: inserts, pageEdits: edits };
  }
  observeVersion(version: number) {
    if (!Number.isInteger(version) || version < 0) fail("broker draftVersion unavailable");
    if (version !== this.draftVersion) {
      this.delivered = undefined;
      this.draft = version === 0 ? { insertPages: [], pageEdits: [] } : undefined;
      this.draftVersion = version;
    }
  }
  compact(value: any, renderHandle?: string) {
    if (value.context) {
      const c = value.context, scope = value.metadataScope ?? {};
      return { view: scope.kind, coordinates: "page points; frame=[x,y,w,h]; crop keeps page origin", focus: this.pageHandle(this.capture.focusPageID),
        draftVersion: value.draftVersion, outputMode: value.outputMode, orientation: c.orientation,
        ...(c.nativeLayerUnavailable && { warning: "stale/native-layer-unavailable; additions only" }), ...(scope.rect && { rect: boxArray(scope.rect) }),
        strokeColumns: ["id", "x", "y", "w", "h", "color?", "questionInk?"],
        pages: c.pages.map((p: any) => ({ page: this.pageHandle(p.pageID), size: [p.width,p.height], background: p.background,
          counts: { objects: p.objectCount, strokes: p.strokeTargetCount, question: p.questionStrokeTargetCount, unlocated: p.unlocatedStrokeTargetCount },
          ...(p.strokeTargets && this.compactStrokes(p.strokeTargets)),
          ...(p.objects && { objects: p.objects.map((o: any) => this.compactObject(o, p.pageID)) }),
        })), images: (value.images ?? []).map((i: any) => i.pageIDs ? { pages: i.pageIDs.map((id: string) => this.pageHandle(id)) } : { page: this.pageHandle(i.pageID) }) };
    }
    if (value.previews) return { render: renderHandle ?? this.delivered?.handle, draftVersion: value.draftVersion, attempt: value.attempt,
      ...(value.warning && { warning: value.warning }), previews: value.previews.map((p: any) => ({ page: this.pageHandle(p.pageID) })),
      objects: value.objects.map((o: any) => {
        const pageID = this.draft?.pageEdits.find((p: any) => p.objectEdits?.some((op: any) => op.object?.id === o.id))?.pageID ?? this.capture.pages.find((p: any) => p.objects.some((old: any) => old.id === o.id))?.pageID;
        return { page: pageID && this.pageHandle(pageID), ...this.compactObject(o, pageID) };
      }) };
    // Receipts are useful without routing identities, opaque hashes or storage paths.
    return Object.fromEntries(["draftVersion", "status", "enabled", "instruction", "requiredHumanChoice", "error", "lastSyncedAt"].filter(k => value[k] !== undefined).map(k => [k,value[k]]));
  }
  compactStrokes(targets: any[]) {
    const color = targets[0]?.colorHex ?? null, questionInk = targets[0]?.questionInk ? 1 : 0;
    return { strokeDefaults: { color, questionInk }, strokes: targets.map(s => {
      const same = (s.colorHex ?? null) === color && (s.questionInk ? 1 : 0) === questionInk;
      return [`s${s.index+1}`, ...(boxArray(s.frame) ?? [null,null,null,null]), ...(same ? [] : [s.colorHex ?? null, s.questionInk ? 1 : 0])];
    }) };
  }
  compactObject(o: any, pageID?: string) {
    return { id: this.objectHandle(o.id, pageID), kind: o.kind, source: o.source, frame: boxArray(o.frame), style: o.style };
  }
  approval(params: any) {
    const render = this.delivered;
    if (!render || render.value.draftVersion !== this.draftVersion) throw new Error("Draw approval requires latest successfully delivered previews; call draw_render and inspect all images");
    const v = render.value, hashes = [...new Set(v.previews.map((p: any) => p.sha256))] as string[];
    if ((params.render !== undefined && params.render !== render.handle) || (params.renderID !== undefined && params.renderID !== v.renderID) || (params.draftVersion !== undefined && params.draftVersion !== v.draftVersion)) throw new Error("Draw approval does not match latest delivered render");
    if (params.inspectedPreviewSHA256s !== undefined && JSON.stringify([...params.inspectedPreviewSHA256s].sort()) !== JSON.stringify([...hashes].sort())) throw new Error("Draw approval preview hashes do not match exact delivered set");
    return { draftVersion: v.draftVersion, renderID: v.renderID, inspectedPreviewSHA256s: hashes };
  }
  mark(params: any, callID: string) {
    if (!this.draft) throw new Error("Draw current complete draft is unknown; write draw_draft before adding a mark");
    const pageID = this.page(params.pageID), requested = box(params.frame);
    // Match the renderer's fixed half-point grid before deriving shape bounds.
    const f = { x: Math.round(requested.x*2)/2, y: Math.round(requested.y*2)/2, width: Math.floor(requested.width*2)/2, height: Math.floor(requested.height*2)/2 };
    if (f.width <= 1 || f.height <= 1) throw new Error("Draw mark frame too small for a 1 point stroke");
    let label = params.id;
    if (!label) {
      if (!this.markCalls.has(callID)) {
        let n = this.marks, candidate: string, occupied: boolean;
        do {
          candidate = `new:mark${++n}`;
          const id = this.generatedID("object", candidate);
          occupied = this.labels.has(`object:${candidate}`) || this.draft.pageEdits.some((p: any) => p.objectEdits?.some((op: any) => op.op === "add" && op.object.id === id));
        } while (occupied);
        this.marks = n; this.markCalls.set(callID, candidate);
      }
      label = this.markCalls.get(callID);
    }
    const id = this.object(pageID, label, true), captured = this.pages.get(pageID)?.objects.find((o: any) => o.id === id);
    const object = { id, kind: params.kind, frame: f, style: { color: "#00B8D9", lineWidth: 1, fontSize: 18 },
      source: JSON.stringify(params.kind === "highlight" ? { opacity: 0.2 } : { cx: f.width/2, cy: f.height/2, rx: f.width/2-0.5, ry: f.height/2-0.5 }) };
    const draft = structuredClone(this.draft);
    let page = draft.pageEdits.find((e: any) => e.pageID === pageID);
    if (!page) { page = { pageID, objectEdits: [] }; draft.pageEdits.push(page); }
    page.objectEdits ??= [];
    const op = captured ? { op: "replace", objectID: id, expectedRevision: captured.revision, object } : { op: "add", object };
    const n = page.objectEdits.findIndex((o: any) => (o.objectID ?? o.object?.id) === id);
    if (n < 0) page.objectEdits.push(op); else page.objectEdits[n] = op;
    return { ...draft, expectedDraftVersion: this.draftVersion };
  }
  edit(params: any, operation: "move" | "remove") {
    if (!this.draft) throw new Error("Draw current complete draft is unknown; write draw_draft before editing targets");
    if (operation === "move" && (!Number.isFinite(params.dx) || !Number.isFinite(params.dy))) throw new Error("Draw move requires finite dx/dy page-point deltas");
    if (!Array.isArray(params.targets) || !params.targets.length) throw new Error("Draw edit requires target handles");
    const pageID = this.page(params.pageID), captured = this.pages.get(pageID);
    const draft = structuredClone(this.draft);
    let page = draft.pageEdits.find((e: any) => e.pageID === pageID);
    if (!page) { page = { pageID }; draft.pageEdits.push(page); }
    const seen = new Set<string>();
    for (const ref of params.targets) {
      const pendingID = this.labels.get(`object:${ref}`) ?? ref;
      const added = page.objectEdits?.find((op: any) => op.op === "add" && op.object.id === pendingID);
      const stroke = /^s[1-9][0-9]*$/.test(ref) || captured?.strokeTargets.some((s: any) => s.id === ref);
      const objectID = stroke || added ? undefined : this.object(pageID, ref);
      const target = stroke ? this.stroke(pageID, ref) : added?.object ?? captured?.objects.find((o: any) => o.id === objectID);
      if (!target) fail(`unknown edit target ${ref} on current page`);
      const key = `${stroke ? "stroke" : "object"}:${target.id}`;
      if (seen.has(key)) throw new Error("Draw duplicate edit target; name each captured element once");
      seen.add(key);
      if (stroke) {
        page.strokeEdits ??= [];
        const n = page.strokeEdits.findIndex((op: any) => op.id === target.id), prior = page.strokeEdits[n];
        if (operation === "move" && prior && !["keep", "move"].includes(prior.op)) throw new Error(`Draw cannot move a stroke with pending ${prior.op}; rebuild draw_draft explicitly`);
        const op: any = { id: target.id, fingerprint: target.fingerprint, op: operation };
        if (operation === "move") {
          op.dx = params.dx + (prior?.op === "move" ? prior.dx : 0); op.dy = params.dy + (prior?.op === "move" ? prior.dy : 0);
          if (!Number.isFinite(op.dx) || !Number.isFinite(op.dy)) throw new Error("Draw accumulated stroke move delta is not finite");
        }
        if (n < 0) page.strokeEdits.push(op); else page.strokeEdits[n] = op;
      } else {
        page.objectEdits ??= [];
        const n = page.objectEdits.findIndex((op: any) => (op.objectID ?? op.object?.id) === target.id), prior = page.objectEdits[n];
        if (operation === "move" && prior?.op === "remove") throw new Error("Draw cannot move an object pending removal; rebuild draw_draft explicitly");
        if (operation === "remove" && added) { page.objectEdits.splice(n, 1); continue; }
        const op: any = added ? prior : { op: operation === "move" ? "replace" : "remove", objectID: target.id, expectedRevision: target.revision };
        if (operation === "move") {
          const source = prior?.object ?? target;
          const { id, kind, source: text, style } = source;
          const frame = { ...source.frame, x: source.frame.x + params.dx, y: source.frame.y + params.dy };
          box(frame); // Includes overflow validation; assets/provenance/revision are renderer-owned.
          op.object = { id, kind, source: text, frame, ...(style && { style: structuredClone(style) }) };
        }
        if (n < 0) page.objectEdits.push(op); else page.objectEdits[n] = op;
      }
    }
    return { ...draft, expectedDraftVersion: this.draftVersion };
  }
  evidence() {
    return { requestID: this.requestID, labels: Object.fromEntries(this.labels), markCalls: Object.fromEntries(this.markCalls), draftVersion: this.draftVersion,
      ...(this.delivered && { delivered: { handle: this.delivered.handle, draftVersion: this.delivered.value.draftVersion, renderID: this.delivered.value.renderID, previews: this.delivered.value.previews } }) };
  }
}
