import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { randomUUID, createHash } from "node:crypto";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
const packagePath = process.env.DRAW_PI_PACKAGE ?? "/home/xaj/.local/share/pi-codex-ultra/releases/fd81f791cde9ae95cb740b2ab039f02f00e4e127/node_modules/@earendil-works/pi-coding-agent";
const { createJiti } = createRequire(import.meta.url)(join(packagePath,"node_modules/jiti/lib/jiti.cjs"));
const jiti = createJiti(import.meta.url,{moduleCache:false,fsCache:false});
const { ModelContext } = await jiti.import(fileURLToPath(new URL("../model-context.ts",import.meta.url)));
const id=()=>randomUUID().toUpperCase(), sha=s=>createHash("sha256").update(s).digest("hex");

function fixture() {
  const doc=id(), pages=Array.from({length:10},()=>({pageID:id(),width:1024,height:1361,background:0,head:id(),objects:[],strokeTargets:[]}));
  const page=pages[5], focus=page.pageID;
  page.strokeTargets=Array.from({length:294},(_,index)=>({id:id(),fingerprint:sha(String(index)),index,frame:{x:132+index/2,y:1111,width:4+index/2,height:35},asset:{sha256:sha("native stroke"),pixelWidth:8,pixelHeight:70,scale:2}}));
  const sources=["Literal Glyph.JSON meta masks", JSON.stringify({kind:"Glyph.JSON",meta:{masks:[{evenOdd:true,commands:[["move",1,2],["line",3,4]]}]}}),"Exact LaTeX \\frac{a}{b} and source UUID "+id(),"practice source text ".repeat(55)];
  page.objects=sources.map((source,index)=>({id:id(),revision:index+1,kind:index===2?"latex":"text",source,frame:{x:25,y:116+index*100,width:323,height:16.5},style:{color:"#000000",fontSize:18,lineWidth:1},asset:{sha256:sha("original AI bytes "+index),pixelWidth:646,pixelHeight:33,scale:2},provenance:{contextSHA256:sha("old context"),rendererSignature:"draw-ai-render-v1",requestID:id()}}));
  const capture={format:1,documentID:doc,focusPageID:focus,orientation:"portrait",capturedAt:"2026-10-12T00:00:00Z",rendererSignature:"native-capture-v1",pages};
  const m=new ModelContext(id(),capture,doc,focus);
  const scoped={...page,objectCount:4,strokeTargetCount:294,questionStrokeTargetCount:44,unlocatedStrokeTargetCount:0,returnedStrokeTargetCount:44,
    strokeTargets:page.strokeTargets.slice(250).map(({asset,...t})=>({...t,color:[0.686274528503418,0.32156863808631897,0.8705881834030151,1],colorHex:"#AF52DE",questionInk:true})),portableSHA256:sha("portable")};
  const response={contextSHA256:sha(JSON.stringify(capture)),fullContextMetadata:{sha256:sha(JSON.stringify(capture)),path:"/private/full-context"},metadataScope:{kind:"page",contextIsSummary:true,strokeTargets:"question_ink_only"},context:{...capture,pages:[scoped]},draftVersion:0,outputMode:"page_only",images:[{pageID:focus,sha256:sha("exact native PNG"),path:"/private/png"}]};
  return {m,capture,page,response};
}

test("44 strokes + 4 AI sources compact below 7k chars without geometry/source loss",()=>{
  const {m,capture,page,response}=fixture(), before=JSON.stringify(capture), raw=JSON.stringify(response), compact=m.compact(response), text=JSON.stringify(compact);
  assert.ok(text.length<7000,`${text.length} chars`);assert.ok(text.length<raw.length*0.35,`${text.length}/${raw.length}`);
  assert.equal(compact.pages[0].page,"p6");assert.equal(compact.focus,"p6");
  assert.equal(compact.pages[0].strokes[0][0],"s251");
  for (const [n,target] of response.context.pages[0].strokeTargets.entries()) assert.deepEqual(compact.pages[0].strokes[n].slice(1,5),[target.frame.x,target.frame.y,target.frame.width,target.frame.height]);
  for (const [n,o] of page.objects.entries()) {
    assert.equal(compact.pages[0].objects[n].id,`o${n+1}`);assert.equal(compact.pages[0].objects[n].source,o.source);
    assert.deepEqual(compact.pages[0].objects[n].frame,[o.frame.x,o.frame.y,o.frame.width,o.frame.height]);
    assert.deepEqual(compact.pages[0].objects[n].style,o.style);
  }
  assert.doesNotMatch(text,/fingerprint|provenance|contextSHA256|portableSHA256|pixelWidth|head|color":\[/);
  assert.equal(JSON.stringify(capture),before); assert.equal(response.images[0].sha256,sha("exact native PNG"));
});

test("page/crop filtering order cannot renumber original stroke indices or page-local object handles",()=>{
  const {m,response,page}=fixture();
  const cropped=structuredClone(response);cropped.metadataScope={kind:"crop",rect:{x:1,y:2,width:3,height:4}};
  cropped.context.pages[0].strokeTargets=[response.context.pages[0].strokeTargets[20],{...page.strokeTargets[0],colorHex:"#0033CC",questionInk:false}];
  assert.deepEqual(m.compact(cropped).pages[0].strokes.map(t=>t[0]),["s271","s1"]);
  assert.deepEqual(m.compact(cropped).rect,[1,2,3,4]);
  assert.deepEqual(m.compact(cropped).pages[0].objects,m.compact(response).pages[0].objects);
  const resolved=m.resolveDraft({expectedDraftVersion:0,pageEdits:[{pageID:"p6",strokeEdits:[{id:"s271",op:"remove"},{id:"s1",op:"keep"}]}]});
  assert.equal(resolved.pageEdits[0].strokeEdits[0].id,page.strokeTargets[270].id);
  assert.equal(resolved.pageEdits[0].strokeEdits[0].fingerprint,page.strokeTargets[270].fingerprint);
  assert.equal(resolved.pageEdits[0].strokeEdits[1].id,page.strokeTargets[0].id);
});

test("literal nested source JSON masks and UUID-looking text are never scrubbed",()=>{
  const {m,page}=fixture(), original=JSON.stringify(m.capture);
  const body={pageEdits:[{pageID:"p6",objectEdits:[{op:"replace",objectID:"o2",object:{id:"o2",kind:"text",source:page.objects[1].source,frame:[0,0,20,30]}}]}]};
  const resolved=m.resolveDraft(body).pageEdits[0].objectEdits[0];
  assert.equal(resolved.expectedRevision,2);assert.equal(resolved.object.id,page.objects[1].id);
  assert.equal(resolved.object.source,page.objects[1].source);assert.equal(JSON.stringify(m.capture),original);
  assert.equal(body.pageEdits[0].objectEdits[0].object.id,"o2");
});

test("generated identity map is stable, typed, and request-specific with prototype-safe labels",()=>{
  const {m,capture}=fixture(), other=new ModelContext(id(),capture,capture.documentID,capture.focusPageID);
  const page=m.generated("page","new:__proto__"), object=m.generated("object","new:__proto__");
  assert.notEqual(page,object);assert.equal(page,m.generated("page","new:__proto__"));assert.notEqual(page,other.generated("page","new:__proto__"));
  const recreated=new ModelContext(m.requestID,capture,capture.documentID,capture.focusPageID);
  assert.equal(object,recreated.generated("object","new:__proto__"));
  for (const bad of ["new:","new:has space","new:"+"a".repeat(129)]) assert.throws(()=>m.generated("object",bad),/new:label/);
});

test("legacy new UUIDs retain compatibility through labelled insert edits",()=>{
  const {m}=fixture(), pageID=id(), oid=id();
  const resolved=m.resolveDraft({insertPages:[{pageID,afterPageID:"p1",background:0,width:1024,height:1361}],pageEdits:[{pageID,objectEdits:[{op:"add",object:{id:oid,kind:"text",source:"legacy",frame:[1,2,3,4]}}]}]});
  assert.equal(resolved.pageEdits[0].pageID,pageID);assert.equal(resolved.pageEdits[0].objectEdits[0].object.id,oid);
  const label=m.objectHandle(oid);assert.match(label,/^new:/);assert.equal(m.object(pageID,label,true),oid);
});

test("mark copies full draft, uses valid 1-point inset circle, and preserves source capture",()=>{
  const {m}=fixture();m.observeVersion(0);
  const first=m.mark({kind:"circle",frame:[1,2,3.4,4.7]},"call1");
  const object=first.pageEdits[0].objectEdits[0].object,g=JSON.parse(object.source);
  assert.equal(g.cx-g.rx,0.5);assert.equal(g.cy-g.ry,0.5);assert.equal(g.cx+g.rx,object.frame.width-0.5);assert.equal(g.cy+g.ry,object.frame.height-0.5);
  assert.deepEqual(m.draft,{insertPages:[],pageEdits:[]});
  const again=m.mark({kind:"circle",frame:[1,2,3.4,4.7]},"call1");assert.equal(again.pageEdits[0].objectEdits[0].object.id,object.id);
  assert.throws(()=>m.mark({kind:"circle",frame:[0,0,1,2]},"small"),/too small/);
});

test("render compact output qualifies page-local objects and approval guards exact set",()=>{
  const {m,page}=fixture();m.observeVersion(1);m.draft={insertPages:[],pageEdits:[{pageID:page.pageID,objectEdits:[{op:"replace",object:page.objects[0]}]}]};
  const value={renderID:id(),draftVersion:1,attempt:1,objects:[page.objects[0]],previews:[{pageID:page.pageID,sha256:sha("one")}]};
  m.delivered={handle:"r1",value};
  assert.equal(m.compact(value).objects[0].page,"p6");assert.equal(m.compact(value).objects[0].id,"o1");
  assert.equal(m.approval({render:"r1"}).renderID,value.renderID);
  m.observeVersion(2);assert.throws(()=>m.approval({}),/delivered/);
});


test("compact draft input removes guard boilerplate while resolving the identical canonical operations",()=>{
  const {m,page}=fixture();
  const input={pageEdits:[{pageID:"p6",strokeEdits:page.strokeTargets.slice(250).map(t=>({id:`s${t.index+1}`,op:"remove"})),objectEdits:[{op:"remove",objectID:"o1"}]}]};
  const canonical={expectedDraftVersion:0,insertPages:[],pageEdits:[{pageID:page.pageID,strokeEdits:page.strokeTargets.slice(250).map(t=>({id:t.id,fingerprint:t.fingerprint,op:"remove"})),objectEdits:[{op:"remove",objectID:page.objects[0].id,expectedRevision:1}]}]};
  const compactSize=JSON.stringify(input).length,rawSize=JSON.stringify(canonical).length;
  assert.ok(compactSize<rawSize*0.3,`${compactSize}/${rawSize}`);assert.ok(compactSize<2000);
  assert.deepEqual(m.resolveDraft({...input,expectedDraftVersion:0}),canonical);
});


test("move canonical AI replacement retains only source spec and captured revision guard",()=>{
  const {m,page}=fixture();m.observeVersion(0);const original=JSON.stringify(m.capture);
  const d=m.edit({targets:["o2","s271"],dx:30,dy:-20},"move"),o=d.pageEdits[0].objectEdits[0];
  assert.equal(o.expectedRevision,2);assert.equal(o.objectID,page.objects[1].id);assert.equal(o.object.id,o.objectID);
  assert.deepEqual(o.object.frame,{...page.objects[1].frame,x:55,y:196});
  assert.equal(o.object.source,page.objects[1].source);assert.deepEqual(o.object.style,page.objects[1].style);
  for(const field of ["asset","provenance","revision"])assert.equal(o.object[field],undefined);
  assert.equal(d.pageEdits[0].strokeEdits[0].fingerprint,page.strokeTargets[270].fingerprint);
  assert.equal(JSON.stringify(m.capture),original);assert.deepEqual(m.draft,{insertPages:[],pageEdits:[]});
});

test("convenience merging keeps replacement source edits, unrelated pages/strokes and pending adds",()=>{
  const {m,page}=fixture();m.observeVersion(0);
  m.draft=m.resolveDraft({pageEdits:[{pageID:"p6",objectEdits:[{op:"replace",objectID:"o1",object:{id:"o1",kind:"text",source:"changed",frame:[10,20,30,40],style:{fontSize:22}}}],strokeEdits:[{id:"s1",op:"recolor",color:"#00B8D9"}]},{pageID:"p1",objectEdits:[]}],insertPages:[]});
  const prior=JSON.stringify(m.draft),d=m.edit({targets:["o1","s271"],dx:2,dy:3},"move");
  assert.equal(d.pageEdits[0].objectEdits.length,1);assert.equal(d.pageEdits[0].objectEdits[0].object.source,"changed");
  assert.deepEqual(d.pageEdits[0].objectEdits[0].object.frame,{x:12,y:23,width:30,height:40});
  assert.deepEqual(d.pageEdits[0].strokeEdits[0],m.draft.pageEdits[0].strokeEdits[0]);assert.deepEqual(d.pageEdits[1],m.draft.pageEdits[1]);
  assert.equal(JSON.stringify(m.draft),prior);
  assert.throws(()=>m.edit({targets:["s1"],dx:2,dy:3},"move"),/pending recolor/);
  const removed=m.edit({targets:["s1","o1"]},"remove");
  assert.equal(removed.pageEdits[0].strokeEdits[0].op,"remove");assert.equal(removed.pageEdits[0].strokeEdits[0].color,undefined);
  assert.deepEqual(removed.pageEdits[0].objectEdits[0],{op:"remove",objectID:page.objects[0].id,expectedRevision:1});
  m.draft=removed;assert.throws(()=>m.edit({targets:["o1"],dx:1,dy:1},"move"),/pending removal/);
  assert.throws(()=>m.edit({targets:["s1"],dx:1,dy:1},"move"),/pending remove/);
});

test("mixed-target duplicate/conflict failures are atomic and move deltas cannot overflow",()=>{
  const {m,page}=fixture();m.observeVersion(0);
  for(const targets of [["o1",page.objects[0].id],["s1",page.strokeTargets[0].id],["o1","o999"]])assert.throws(()=>m.edit({targets,dx:1,dy:1},"move"),/duplicate|invalid_handle/);
  assert.deepEqual(m.draft,{insertPages:[],pageEdits:[]});
  m.draft=m.edit({targets:["s1"],dx:Number.MAX_VALUE,dy:1},"move");
  assert.throws(()=>m.edit({targets:["s1"],dx:Number.MAX_VALUE,dy:1},"move"),/not finite/);
});

test("pending add edits are page-bound and retain add identity without captured revision",()=>{
  const {m}=fixture();m.observeVersion(0);m.draft=m.mark({kind:"circle",frame:[10,20,30,40],id:"new:circle"},"mark");
  const original=m.draft.pageEdits[0].objectEdits[0], moved=m.edit({targets:["new:circle"],dx:2,dy:3},"move");
  assert.equal(moved.pageEdits[0].objectEdits[0].op,"add");assert.equal(moved.pageEdits[0].objectEdits[0].object.id,original.object.id);
  assert.throws(()=>m.edit({pageID:"p1",targets:["new:circle"]},"remove"),/invalid_handle/);
  assert.throws(()=>m.edit({targets:["new:unknown"]},"remove"),/invalid_handle/);
  assert.equal(m.edit({targets:["new:circle"]},"remove").pageEdits[0].objectEdits.length,0);
});


test("automatic mark skips explicit question label and preserves its pending add",()=>{
  const {m}=fixture();m.observeVersion(0);
  m.draft=m.resolveDraft({pageEdits:[{pageID:"p6",objectEdits:[{op:"add",object:{id:"new:mark1",kind:"text",source:"Question: do not overwrite",frame:[1,2,3,4]}}]}]});
  const original=structuredClone(m.draft.pageEdits[0].objectEdits[0]);
  const marked=m.mark({kind:"highlight",frame:[10,20,30,40]},"automatic");
  assert.equal(marked.pageEdits[0].objectEdits.length,2);
  assert.deepEqual(marked.pageEdits[0].objectEdits[0],original);
  assert.equal(m.markCalls.get("automatic"),"new:mark2");assert.equal(m.marks,2);
  assert.notEqual(marked.pageEdits[0].objectEdits[1].object.id,original.object.id);
  assert.equal(m.mark({kind:"circle",frame:[10,20,30,40]},"automatic").pageEdits[0].objectEdits[1].object.id,marked.pageEdits[0].objectEdits[1].object.id);
  const explicit=m.mark({kind:"circle",frame:[10,20,30,40],id:"new:mark1"},"intentional");
  assert.equal(explicit.pageEdits[0].objectEdits.length,1);assert.equal(explicit.pageEdits[0].objectEdits[0].object.id,original.object.id);
});

test("automatic mark avoids pending legacy add with candidate ID even without label map",()=>{
  const {m,capture}=fixture();m.observeVersion(0);
  const sameRequest=new ModelContext(m.requestID,capture,capture.documentID,capture.focusPageID);
  const occupiedID=sameRequest.generated("object","new:mark1");
  m.draft=m.resolveDraft({pageEdits:[{pageID:"p1",objectEdits:[{op:"add",object:{id:occupiedID,kind:"text",source:"Other-page question",frame:[1,2,3,4]}}]}]});
  assert.equal(m.labels.size,0);
  const marked=m.mark({kind:"circle",frame:[10,20,30,40]},"automatic");
  assert.equal(m.markCalls.get("automatic"),"new:mark2");
  assert.notEqual(marked.pageEdits[1].objectEdits[0].object.id,occupiedID);
  assert.deepEqual(marked.pageEdits[0],m.draft.pageEdits[0]);
});

for(const kind of ["object","page"])test(`${kind} fallback aliases cannot overwrite explicit new:legacy2`,()=>{
  const {m}=fixture();const originalID=m.generated(kind,"new:legacy2"), legacyID=id();
  const handle=kind==="object"?m.objectHandle(legacyID):m.pageHandle(legacyID);
  assert.notEqual(handle,"new:legacy2");assert.equal(m.labels.get(`${kind}:new:legacy2`),originalID);
  assert.equal(m.labels.get(`${kind}:${handle}`),legacyID);
  assert.equal(kind==="object"?m.objectHandle(legacyID):m.pageHandle(legacyID),handle);
  assert.equal(kind==="object"?m.objectHandle(originalID):m.pageHandle(originalID),"new:legacy2");
  assert.equal(m.generated(kind,"new:legacy2"),originalID);
  // Growing both namespaces cannot change any previously bound identity.
  const saved=new Map(m.labels);m.generated(kind,"new:legacy4");
  for(let n=0;n<5;n++){m.pageHandle(id());m.objectHandle(id());}
  for(const [key,value]of saved)assert.equal(m.labels.get(key),value);
});

test("ordered insertion chains resolve earlier UUIDs and labels equivalently on retries",()=>{
  const {m,capture}=fixture();
  const labels=["new:A","new:B","new:C"],ids=labels.map(label=>m.generated("page",label));
  const input=refs=>({expectedDraftVersion:0,insertPages:refs.map((pageID,n)=>({pageID,afterPageID:n?refs[n-1]:"p1",background:0,width:1024,height:1361})),pageEdits:refs.map(pageID=>({pageID}))});
  const legacy=new ModelContext(m.requestID,capture,capture.documentID,capture.focusPageID);
  const byID=legacy.resolveDraft(input(ids)),byLabel=m.resolveDraft(input(labels));
  assert.deepEqual(byID,byLabel);
  assert.deepEqual(byID.insertPages.map(p=>p.afterPageID),[capture.pages[0].pageID,ids[0],ids[1]]);
  legacy.draft=byID;m.draft=byLabel;
  assert.deepEqual(legacy.resolveDraft(input(ids)),byID);assert.deepEqual(m.resolveDraft(input(labels)),byLabel);
});

test("insertion references cannot use future/self pages from cached previous draft or labels",()=>{
  const {m}=fixture();
  const a=m.generated("page","new:A"),b=m.generated("page","new:B");
  m.draft={insertPages:[{pageID:a},{pageID:b}],pageEdits:[]};
  const page=(pageID,afterPageID)=>({pageID,afterPageID,background:0,width:1024,height:1361});
  for(const refs of [[a,b],["new:A","new:B"]]){
    assert.throws(()=>m.resolveDraft({insertPages:[page(refs[0],refs[1]),page(refs[1],"p1")]}),/invalid_handle/);
    assert.throws(()=>m.resolveDraft({insertPages:[page(refs[0],refs[0])]}),/invalid_handle/);
    assert.throws(()=>m.resolveDraft({insertPages:[page(refs[0],"p1"),page(refs[0],refs[0])]}),/invalid_handle/);
  }
});

test("fractional stroke deltas remain staged intent; renderer owns one half-point snap",()=>{
  const {m,page}=fixture();m.observeVersion(0);
  const input={pageEdits:[{pageID:"p6",strokeEdits:[{id:"s271",op:"move",dx:0.24,dy:-0.24}]}]},before=JSON.stringify(input);
  const draft=m.resolveDraft(input);assert.deepEqual([draft.pageEdits[0].strokeEdits[0].dx,draft.pageEdits[0].strokeEdits[0].dy],[0.24,-0.24]);
  assert.equal(draft.pageEdits[0].strokeEdits[0].fingerprint,page.strokeTargets[270].fingerprint);
  m.draft=draft;const merged=m.edit({targets:["s271"],dx:0.24,dy:-0.24},"move");
  assert.deepEqual([merged.pageEdits[0].strokeEdits[0].dx,merged.pageEdits[0].strokeEdits[0].dy],[0.48,-0.48]);
  assert.equal(JSON.stringify(input),before);
});
