import copy
import hashlib
import tempfile
import unittest
from pathlib import Path
from notes_service.manager import Manager
from notes_service.storage import encoded
from notes_service.tests.fixtures import Source, Renderer, context, uid, image, draft


class ReadScopeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = Source()
        self.m = Manager(self.root/"state", Renderer(), self.source, workspace=self.root/"workspace")
        self.doc, self.cid, self.rid = uid(), uid(), uid()
        self.m.register_client({"clientID":self.cid})
        self.ctx, _ = context(self.m, self.doc)
        base = self.ctx["pages"][0]
        tiny = self.m.store.put_bytes(image(4,4))
        self.ctx["pages"] = []
        for page_index in range(13):
            page = copy.deepcopy(base); page["pageID"] = uid()
            strokes, targets = [], []
            for index in range(90):
                purple = index in (70, 89)
                rgba = [175/255,82/255,222/255,1] if purple else [0,0,0,1]
                strokes.append({"inkType":"com.apple.ink.pen","color":rgba,"transform":[1,0,0,1,0,0],
                                "randomSeed":0,"creationDate":0,"points":[],"samples":[]})
                targets.append({"id":f"p{page_index}-s{index}", "fingerprint":hashlib.sha256(f"{page_index}/{index}".encode()).hexdigest(),
                                "index":index,"frame":{"x":2 if index in (0,70) else 20,"y":2,"width":2,"height":2},
                                "asset":{"sha256":tiny,"pixelWidth":4,"pixelHeight":4,"scale":2}})
            scene = {"format":1,"head":None,"width":32,"height":32,"background":0,"objects":[],"strokes":strokes}
            page.update(portableSHA256=self.m.store.put_bytes(encoded(scene)), strokeTargets=targets)
            self.ctx["pages"].append(page)
        self.focus = self.ctx["pages"][9]["pageID"]
        self.ctx.update(focusPageID=self.focus, documentName="Local name")
        self.original = encoded(self.ctx)
        self.digest = self.m.store.put_bytes(self.original)
        await self.m.create_request({"requestID":self.rid,"documentID":self.doc,"focusPageID":self.focus,
                                    "contextSHA256":self.digest,"origin":"app","clientID":self.cid})
        worker = self.m.worker_registry.get(self.doc)
        worker = self.m.worker_registry.register({"documentID":self.doc,"sessionID":worker["sessionID"],"cwd":worker["cwd"],
            "sessionFile":str(self.root/"fixture.jsonl"),"spawnNonce":worker["spawnNonce"],"busy":False,"pending":False,"inputObserved":True})
        self.lease = worker["lease"]
        self.m.lease_request(self.doc,self.lease,{"busy":False,"pending":False,"inputObserved":True})

    async def asyncTearDown(self):
        self.m.close(); self.temp.cleanup()

    async def test_page_ten_has_scoped_question_ids_without_global_metadata(self):
        value = await self.m.read(self.rid,{"view":"page","pageID":self.focus},self.doc,self.lease)
        page = value["context"]["pages"][0]
        self.assertEqual(len(value["context"]["pages"]),1)
        self.assertEqual(page["pageID"],self.focus)
        self.assertEqual(page["pageNumber"],10)
        self.assertEqual([t["id"] for t in page["strokeTargets"]],["p9-s70","p9-s89"])
        self.assertEqual(page["strokeTargetCount"],90)
        self.assertEqual(page["returnedStrokeTargetCount"],2)
        self.assertTrue(all(t["colorHex"]=="#AF52DE" for t in page["strokeTargets"]))
        self.assertTrue(len(self.original)>100000)
        self.assertLess(len(encoded(value)),10000)
        self.assertTrue(value["metadataScope"]["contextIsSummary"])
        self.assertEqual(value["contextSHA256"],self.digest)
        self.assertEqual(Path(value["fullContextMetadata"]["path"]).read_bytes(),self.original)
        self.assertEqual(self.m.store.read_asset(self.digest),self.original)
        self.assertEqual(self.m.store.request(self.rid)["draftVersion"],0)

    async def test_scoped_read_does_not_replace_renderer_context_or_hash(self):
        await self.m.read(self.rid,{"view":"page","pageID":self.focus},self.doc,self.lease)
        original_render = self.m.renderer.render
        seen = []
        async def render(ctx,value,rid,digest):
            seen.append(digest)
            self.assertEqual(encoded(ctx),self.original)
            self.assertEqual(len(ctx["pages"]),13)
            self.assertEqual(len(ctx["pages"][9]["strokeTargets"]),90)
            return await original_render(ctx,value,rid,digest)
        self.m.renderer.render = render
        await self.m.draft(self.rid,draft(self.focus),self.doc,self.lease)
        await self.m.render(self.rid,{"draftVersion":1,"renderID":uid()},self.doc,self.lease)
        self.assertEqual(seen,[self.digest])

    async def test_crop_returns_nearby_normal_and_purple_original_coordinates(self):
        rect = {"x":1,"y":1,"width":6,"height":6}
        value = await self.m.read(self.rid,{"view":"crop","pageID":self.focus,"rect":rect},self.doc,self.lease)
        targets = value["context"]["pages"][0]["strokeTargets"]
        self.assertEqual([t["id"] for t in targets],["p9-s70","p9-s0"])
        self.assertEqual(targets[1]["color"],[0,0,0,1])
        self.assertEqual(targets[1]["fingerprint"],self.ctx["pages"][9]["strokeTargets"][0]["fingerprint"])
        self.assertEqual(targets[1]["frame"],{"x":2,"y":2,"width":2,"height":2})
        self.assertEqual(value["metadataScope"]["rect"],rect)
        self.assertEqual(value["metadataScope"]["strokeTargets"],"intersecting_crop_all_colors")

    async def test_overview_compact_page_summary_has_no_target_or_object_bodies(self):
        value = await self.m.read(self.rid,{"view":"overview"},self.doc,self.lease)
        self.assertEqual(len(value["context"]["pages"]),13)
        self.assertEqual(len(value["images"]),2)
        self.assertTrue(all("strokeTargets" not in p and "objects" not in p for p in value["context"]["pages"]))
        self.assertLess(len(encoded(value)),10000)

    async def test_page_and_crop_keep_complete_captured_object_list(self):
        page = copy.deepcopy(self.ctx["pages"][9])
        obj = {"id":uid(),"revision":1,"kind":"text","source":"Existing",
               "frame":{"x":20,"y":20,"width":2,"height":2},"style":{"fontSize":14,"color":"#000000","lineWidth":1},
               "asset":{"sha256":page["strokeTargets"][0]["asset"]["sha256"],"pixelWidth":4,"pixelHeight":4,"scale":2},
               "provenance":{"requestID":uid(),"contextSHA256":"a"*64,"rendererSignature":"fixture"}}
        page["objects"] = [obj]
        for view, rect in (("page",None),("crop",{"x":1,"y":1,"width":6,"height":6})):
            summary = self.m.read_metadata(self.ctx,[page],view,rect)
            self.assertEqual(summary["pages"][0]["objects"],[obj])

    async def test_palette_exactness_and_unlocated_crop_targets(self):
        page = copy.deepcopy(self.ctx["pages"][9])
        import struct
        float32 = lambda number: struct.unpack("f",struct.pack("f",number))[0]
        colors = [[float32(175/255),float32(82/255),float32(222/255),1],
                  [176/255,82/255,222/255,1],[175/255,82/255,222/255,0.5],[0,0,0,1]]
        scene = {"format":1,"head":None,"width":32,"height":32,"background":0,"objects":[],
                 "strokes":[{"inkType":"com.apple.ink.pen","color":color,"transform":[1,0,0,1,0,0],"randomSeed":0,"creationDate":0,"points":[],"samples":[]} for color in colors]}
        page["portableSHA256"] = self.m.store.put_bytes(encoded(scene))
        page["strokeTargets"] = copy.deepcopy(page["strokeTargets"][:4])
        for index,target in enumerate(page["strokeTargets"]): target["index"] = index
        page["strokeTargets"][3].pop("frame")
        result = self.m.read_metadata(self.ctx,[page],"page")["pages"][0]
        self.assertEqual([t["index"] for t in result["strokeTargets"]],[0])
        self.assertEqual(result["strokeTargets"][0]["color"],colors[0])
        crop = self.m.read_metadata(self.ctx,[page],"crop",{"x":0,"y":0,"width":32,"height":32})["pages"][0]
        self.assertEqual([t["index"] for t in crop["strokeTargets"]],[0,1,2])
        self.assertEqual(crop["unlocatedStrokeTargetCount"],1)

    async def test_full_page_crop_obtains_all_colors_and_edge_only_contact_is_excluded(self):
        value = await self.m.read(self.rid,{"view":"crop","pageID":self.focus,"rect":{"x":0,"y":0,"width":32,"height":32}},self.doc,self.lease)
        self.assertEqual(len(value["context"]["pages"][0]["strokeTargets"]),90)
        value = await self.m.read(self.rid,{"view":"crop","pageID":self.focus,"rect":{"x":0,"y":0,"width":2,"height":2}},self.doc,self.lease)
        self.assertEqual(value["context"]["pages"][0]["strokeTargets"],[])


class CapturedLabelTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name); self.doc,self.fid = uid(),uid()
        self.source = Source()
        self.remote = {"documentName":"Old note","folderName":"Old folder","folderID":self.fid,
                       "documentDigest":"a"*64,"lastSyncedAt":"2026-10-09T00:00:00Z"}
        async def labels(doc): return dict(self.remote)
        async def folders(): return [{"id":self.fid,"name":self.remote["folderName"]}]
        self.source.worker_labels,self.source.folders = labels,folders
        self.m = Manager(self.root/"state",Renderer(),self.source,workspace=self.root/"workspace")
        self.capture = {"documentName":"New note","folderName":"New folder","folderID":self.fid,"capturedAt":"2026-10-09T00:01:00Z"}
        await self.m.ensure_worker(self.doc,self.capture)

    async def asyncTearDown(self): self.m.close(); self.temp.cleanup()

    async def test_unsynced_capture_names_not_reverted_by_old_or_new_timestamp_old_names(self):
        before = self.m.worker_registry.get(self.doc)
        for timestamp,digest in (("2026-10-09T00:00:00Z","a"*64),("2026-10-09T00:02:00Z","b"*64)):
            self.remote.update(lastSyncedAt=timestamp,documentDigest=digest)
            await self.m.refresh_worker_labels()
            after = self.m.worker_registry.get(self.doc)
            self.assertEqual(after["cwd"],before["cwd"])
            self.assertEqual(after["label"],before["label"])
            self.assertNotIn("renamePending",after)
            self.assertEqual(self.m.worker_registry.folder_directory("New folder",self.fid),"New folder")

    async def test_names_confirm_then_require_changed_digest_and_fresh_document_sync(self):
        self.remote.update(documentName="New note",folderName="New folder")
        await self.m.refresh_worker_labels()
        self.assertIn("confirmedSource",self.m.worker_registry.get(self.doc)["capturedLabelProvenance"])
        self.remote.update(documentName="Remote rename",lastSyncedAt="2026-10-09T00:02:00Z")
        await self.m.refresh_worker_labels()
        self.assertNotIn("renamePending",self.m.worker_registry.get(self.doc)) # Same digest is not a changed source publication.
        self.remote.update(documentDigest="b"*64,lastSyncedAt="2026-10-09T00:00:30Z")
        await self.m.refresh_worker_labels()
        self.assertNotIn("renamePending",self.m.worker_registry.get(self.doc))
        self.remote.update(lastSyncedAt="2026-10-09T00:03:00Z")
        await self.m.refresh_worker_labels()
        worker = self.m.worker_registry.get(self.doc)
        self.assertEqual(worker["renamePending"]["name"],"Remote rename")
        self.assertNotIn("capturedLabelProvenance",worker)

    async def test_label_provenance_survives_restart(self):
        self.m.close()
        self.m = Manager(self.root/"state",Renderer(),self.source,workspace=self.root/"workspace")
        await self.m.refresh_worker_labels()
        self.assertEqual(self.m.worker_registry.get(self.doc)["noteName"],"New note")
        self.assertNotIn("renamePending",self.m.worker_registry.get(self.doc))

    async def test_new_native_labels_replace_pending_source_rename_without_session_reset(self):
        worker = self.m.worker_registry.get(self.doc)
        worker["renamePending"] = {"folder":"Old folder","name":"Old note","folderID":self.fid}
        self.m.worker_registry.save(worker)
        await self.m.ensure_worker(self.doc,self.capture)
        fresh = self.m.worker_registry.get(self.doc)
        self.assertNotIn("renamePending",fresh)
        self.assertEqual(fresh["sessionID"],worker["sessionID"])

    async def test_partial_native_name_preserves_known_folder_and_does_not_guard_invented_labels(self):
        await self.m.ensure_worker(self.doc,{"documentName":"Another name","capturedAt":"2026-10-09T00:04:00Z"})
        worker = self.m.worker_registry.get(self.doc)
        self.assertEqual(worker["renamePending"]["folderID"],self.fid)
        self.assertEqual(worker["renamePending"]["folder"],"New folder")
        self.assertEqual(worker["capturedLabelProvenance"]["fields"],["name"])
        self.remote.update(documentName="Another name")
        self.assertTrue(self.m.accept_source_labels(worker,self.remote))

    async def test_latest_native_folder_capture_wins_shared_folder_mirroring(self):
        other = uid()
        old = {"documentName":"Other","folderName":"Old folder","folderID":self.fid,"capturedAt":"2026-10-09T00:00:00Z"}
        manager = Manager(self.root/"other-state",Renderer(),self.source,workspace=self.root/"other-workspace")
        try:
            await manager.ensure_worker(other,old)
            await manager.ensure_worker(self.doc,self.capture)
            await manager.refresh_worker_labels()
            self.assertEqual(manager.store.record("folder",self.fid)["directory"],"New folder")
        finally:
            manager.close()
