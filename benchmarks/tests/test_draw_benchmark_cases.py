"""Fabricated captures only: no live notes, model calls, or native archives."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from benchmarks.draw_ai import cases, runner
from notes_service.storage import Problem, decoded, encoded
from notes_service.tests.fixtures import image, uid


def digest(data):
    return hashlib.sha256(data).hexdigest()


class CaseTests(unittest.TestCase):
    def setUp(self):
        temporary = Path.home() / "tmp"
        temporary.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="draw-cases-test-", dir=temporary)
        self.root = Path(self.tmp.name)
        self.source = self.root / "capture"
        (self.source / "assets").mkdir(parents=True)
        self.destination = self.root / "private/cases/example"
        self.question = "Human-only expected answer for later review"
        self.assets = {}

        def asset(data):
            h = digest(data)
            self.assets[h] = data
            return h

        self.stroke_id = uid()
        self.obj = {"id": uid(), "kind": "text", "source": "Existing purple annotation", "revision": 3,
                    "frame": {"x": 4, "y": 5, "width": 2, "height": 2},
                    "style": {"fontSize": 14, "lineWidth": 1, "color": "#9900ff"},
                    "asset": {"sha256": asset(image(4, 4, (153, 0, 255, 255))),
                              "pixelWidth": 4, "pixelHeight": 4, "scale": 2},
                    "provenance": {"requestID": uid(), "contextSHA256": "b" * 64,
                                   "rendererSignature": "fixture-v1"}}
        paper = asset(image())
        ink = asset(image(color=(0, 0, 0, 0)))
        pages = []
        for index in range(2):
            head, page_id = uid(), uid()
            objects = [copy.deepcopy(self.obj)] if index == 0 else []
            strokes = [{"id": self.stroke_id, "pathID": uid(), "renderGroupID": uid(),
                        "inkType": "com.apple.ink.pen", "color": [0, 0, 0, 1],
                        "transform": [1, 0, 0, 1, 0, 0], "randomSeed": 12,
                        "creationDate": 42, "points": [], "samples": []}] if index == 0 else []
            portable = {"format": 1, "head": head, "width": 32, "height": 32,
                        "background": 0, "objects": objects, "strokes": strokes}
            pages.append({"pageID": page_id, "head": head, "background": 0, "width": 32, "height": 32,
                          "objects": objects, "paperSHA256": paper, "inkSHA256": ink,
                          "compositeSHA256": paper, "portableSHA256": asset(encoded(portable)),
                          "strokeTargets": [{"id": self.stroke_id, "fingerprint": "c" * 64, "index": 0,
                                             "asset": copy.deepcopy(self.obj["asset"]),
                                             "frame": copy.deepcopy(self.obj["frame"])}] if index == 0 else []})
        self.ctx = {"format": 1, "documentID": uid(), "focusPageID": pages[0]["pageID"],
                    "capturedAt": "2026-10-10T10:00:00.000Z", "rendererSignature": "native-capture-fixture",
                    "orientation": "portrait", "documentName": "Fabricated Note", "folderName": "Test / Folder",
                    "folderID": uid(), "documentDigest": "d" * 64, "pages": pages}
        self.provenance = {"fixture": True}  # Generic metadata claims no staged source.
        self.write_capture()

    def tearDown(self):
        # Frozen cases are deliberately read-only; only test-owned temp dirs change.
        for root, directories, _ in os.walk(self.root):
            os.chmod(root, 0o700)
            for directory in directories:
                path = Path(root) / directory
                if not path.is_symlink():
                    os.chmod(path, 0o700)
        self.tmp.cleanup()

    def write_capture(self):
        (self.source / "context.json").write_text(json.dumps(self.ctx, indent=2))
        for path in (self.source / "assets").iterdir():
            path.unlink()
        for h, data in self.assets.items():
            suffix = ".png" if data.startswith(b"\x89PNG") else ".json"
            (self.source / "assets" / (h + suffix)).write_bytes(data)

    def import_case(self, **kwargs):
        return cases.import_case(self.source, self.destination, self.question, self.provenance, **kwargs)

    def assert_rejected(self, code=None):
        with self.assertRaises(Problem) as failure:
            self.import_case()
        if code:
            self.assertEqual(failure.exception.code, code)
        self.assertFalse(self.destination.exists())
        if self.destination.parent.exists():
            self.assertFalse(list(self.destination.parent.glob(".case-*")))

    def replace_asset(self, field, data):
        page = self.ctx["pages"][0]
        old = page[field]
        new = digest(data)
        # Some image layers share their exact CAS identity.
        for p in self.ctx["pages"]:
            for key in ("paperSHA256", "inkSHA256", "compositeSHA256", "portableSHA256"):
                if p[key] == old:
                    p[key] = new
        self.assets.pop(old)
        self.assets[new] = data
        self.write_capture()

    def staged_provenance(self):
        """Fabricated stage_document output with live, deleted and headless pages."""
        original = uid()
        page_ids = {uid(): p["pageID"] for p in self.ctx["pages"]}
        heads = {pid: p["head"] for pid, p in zip(page_ids, self.ctx["pages"])}
        objects = {pid: copy.deepcopy(p["objects"]) for pid, p in zip(page_ids, self.ctx["pages"])}
        deleted, blank = uid(), uid()
        page_ids.update({deleted: uid(), blank: uid()})
        heads.update({deleted: uid(), blank: None})
        objects[deleted] = []
        self.ctx["documentName"] = "Test Fabricated Note"
        self.ctx["folderName"] = "Test Root / Test Folder"
        self.write_capture()
        return {"originalDocumentID": original, "originalFocusPageID": next(iter(page_ids)),
                "revision": 17, "documentDigest": "d" * 64, "lastSyncedAt": None,
                "identityMapping": {"documentID": {"original": original, "isolated": self.ctx["documentID"]},
                                    "pageIDs": page_ids, "folderIDs": {uid(): self.ctx["folderID"]}},
                "pageHeads": heads, "currentObjects": objects,
                "sceneReferences": {original + "/" + pid: "e" * 64 for pid in page_ids},
                "sourceManifestSHA256": "f" * 64, "nativeCaptureNoHistoryMigration": True}

    def test_staged_provenance_binds_live_subset_and_preserves_metadata(self):
        self.provenance = self.staged_provenance()
        self.provenance.update({"NoNativeHistory": True, "NoNativeMigration": False,
                                "Name_Test": "review tag", "tags": ["Sequence", "Head"],
                                "rootMetadata": {"label": "Test Root", "empty": True}})
        before = copy.deepcopy(self.provenance)
        result = self.import_case()
        self.assertEqual(result["manifest"]["provenance"], before)
        self.assertEqual(len(result["context"]["pages"]), 2)
        self.assertEqual(len(before["identityMapping"]["pageIDs"]), 4)
        for key in ("documentName", "folderName", "folderID", "documentDigest"):
            self.assertEqual(result["context"][key], self.ctx[key])
        # The source SHA is safe in provenance, never injected into native context.
        self.assertNotIn("sourceManifestSHA256", result["context"])
        self.assertEqual(cases.verify_case(self.destination), result)
        triplet = copy.deepcopy(result)
        with patch.object(cases, "import_case", side_effect=AssertionError("No recursive admission")):
            self.assertEqual(runner.load_case(triplet),
                             (result["manifest"], result["context"], result["assets"]))
        self.assertEqual(triplet, result)

    def test_other_native_capture_cannot_borrow_staged_provenance(self):
        self.provenance = self.staged_provenance()
        original_ctx = copy.deepcopy(self.ctx)
        for field in ("documentID", "focusPageID", "pageID"):
            with self.subTest(field=field):
                self.ctx = copy.deepcopy(original_ctx)
                if field == "documentID":
                    self.ctx[field] = uid()
                elif field == "focusPageID":
                    self.ctx[field] = self.ctx["pages"][1]["pageID"]
                else:
                    self.ctx["pages"][1][field] = uid()
                self.write_capture()
                self.assert_rejected("case_provenance")

    def test_staging_tags_never_waive_current_head_or_object_equality(self):
        original = self.staged_provenance()
        focus = original["originalFocusPageID"]
        for flag in (True, False):
            for field in ("pageHeads", "currentObjects"):
                with self.subTest(flag=flag, field=field):
                    self.provenance = copy.deepcopy(original)
                    self.provenance["nativeCaptureNoHistoryMigration"] = flag
                    if field == "pageHeads":
                        self.provenance[field][focus] = uid()
                    else:
                        self.provenance[field][focus][0]["style"]["color"] = "#00aaaa"
                    self.assert_rejected("case_provenance")

    def test_partial_staging_provenance_fails_closed(self):
        original = self.staged_provenance()
        for field in cases._STAGE_FIELDS:
            with self.subTest(field=field, mode="only"):
                self.provenance = {field: original[field]}
                self.assert_rejected("case_provenance")
            with self.subTest(field=field, mode="missing"):
                self.provenance = copy.deepcopy(original)
                del self.provenance[field]
                self.assert_rejected("case_provenance")

    def test_staging_maps_state_types_and_all_object_identities_are_validated(self):
        original = self.staged_provenance()
        focus, other, deleted, blank = original["identityMapping"]["pageIDs"]
        folder = next(iter(original["identityMapping"]["folderIDs"]))
        mutations = [
            lambda p: p.update(revision=True),
            lambda p: p.update(sourceManifestSHA256="bad"),
            lambda p: p.update(documentDigest="bad"),
            lambda p: p.update(lastSyncedAt="bad"),
            lambda p: p.update(originalDocumentID=uid()),
            lambda p: p.update(originalFocusPageID=uid()),
            lambda p: p["identityMapping"].pop("folderIDs"),
            lambda p: p["identityMapping"].update(pageIDs=[]),
            lambda p: p["identityMapping"]["pageIDs"].update({other: p["identityMapping"]["pageIDs"][focus]}),
            lambda p: p["identityMapping"]["pageIDs"].update({deleted: focus}),
            lambda p: p["identityMapping"]["pageIDs"].update({blank: "bad"}),
            lambda p: p["identityMapping"]["folderIDs"].update({folder: self.ctx["documentID"]}),
            lambda p: p["identityMapping"]["folderIDs"].update({focus: uid()}),
            lambda p: p["pageHeads"].pop(deleted),
            lambda p: p["pageHeads"].update({blank: "bad"}),
            lambda p: p["sceneReferences"].pop(p["originalDocumentID"] + "/" + deleted),
            lambda p: p["sceneReferences"].update({p["originalDocumentID"] + "/" + deleted: "bad"}),
            lambda p: p["currentObjects"].pop(deleted),
            lambda p: p["currentObjects"].update({blank: []}),
            lambda p: p["currentObjects"].update({deleted: {}}),
            lambda p: p["currentObjects"].update({deleted: [{"id": uid()}]}),
            lambda p: p["currentObjects"].update({deleted: [copy.deepcopy(self.obj)]}),
            lambda p: p["currentObjects"][focus].append(copy.deepcopy(self.obj)),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                self.provenance = copy.deepcopy(original)
                mutate(self.provenance)
                self.assert_rejected()

    def test_staging_head_and_objects_must_match_the_same_page(self):
        self.provenance = self.staged_provenance()
        focus, other, *_ = self.provenance["identityMapping"]["pageIDs"]
        for field in ("pageHeads", "currentObjects"):
            with self.subTest(field=field):
                state = self.provenance[field]
                state[focus], state[other] = state[other], state[focus]
                self.assert_rejected("case_provenance")
                state[focus], state[other] = state[other], state[focus]

    def test_verify_and_dictionary_runner_reject_spoofed_staging_attribution(self):
        self.provenance = self.staged_provenance()
        result = self.import_case()
        original = copy.deepcopy(result["manifest"]["provenance"])
        path = self.destination / "case.json"
        os.chmod(path, 0o600)
        for field in ("documentID", "focusPageID", "pageHeads", "currentObjects", "partial"):
            with self.subTest(field=field):
                spoof = copy.deepcopy(result)
                provenance = spoof["manifest"]["provenance"] = copy.deepcopy(original)
                focus = provenance["originalFocusPageID"]
                if field == "documentID":
                    provenance["identityMapping"][field]["isolated"] = uid()
                elif field == "focusPageID":
                    provenance["originalFocusPageID"] = uid()
                elif field == "pageHeads":
                    provenance[field][focus] = uid()
                elif field == "currentObjects":
                    provenance[field][focus][0]["source"] = "Changed ink annotation"
                else:
                    provenance.pop("identityMapping")
                path.write_bytes(encoded(spoof["manifest"]))
                with self.assertRaises(Problem) as failure:
                    cases.verify_case(self.destination)
                self.assertEqual(failure.exception.code, "case_provenance")
                before = copy.deepcopy(spoof)
                with patch.object(cases, "import_case", side_effect=AssertionError("No recursive admission")):
                    with self.assertRaises(Problem) as failure:
                        runner.load_case(spoof)
                self.assertEqual(failure.exception.code, "case_provenance")
                self.assertEqual(spoof, before)

    def test_exact_private_bundle_whole_document_remap_and_runner_contract(self):
        before = {str(p.relative_to(self.source)): p.read_bytes()
                  for p in self.source.rglob("*") if p.is_file()}
        result = self.import_case()
        manifest, ctx, assets = runner.load_case(self.destination)
        self.assertEqual(result, {"manifest": manifest, "context": ctx, "assets": assets})
        self.assertEqual(result, cases.verify_case(self.destination))
        self.assertEqual(runner.load_case(result), (manifest, ctx, assets))
        self.assertEqual(assets, self.assets)
        self.assertEqual(manifest["provenance"], self.provenance)
        self.assertEqual(manifest["source"]["contextSHA256"], digest(before["context.json"]))
        self.assertEqual(manifest["contextSHA256"], digest((self.destination / "context.json").read_bytes()))
        self.assertEqual(manifest["question"], self.question)
        self.assertIsNone(manifest["requestPrompt"])
        self.assertEqual(manifest["promptMode"], "production_app_prompt")
        self.assertEqual(manifest["questionPurpose"], "review_only")
        self.assertNotIn(self.question, encoded(ctx).decode())
        self.assertNotEqual(ctx["documentID"], self.ctx["documentID"])
        self.assertEqual(len(ctx["pages"]), 2)  # Never crop the native whole-document capture.
        mapping = manifest["identityMapping"]["pageIDs"]
        self.assertFalse(set(mapping) & set(mapping.values()))
        restored = copy.deepcopy(ctx)
        restored["documentID"] = self.ctx["documentID"]
        restored["focusPageID"] = self.ctx["focusPageID"]
        for page, original in zip(restored["pages"], self.ctx["pages"]):
            self.assertEqual(mapping[original["pageID"]], page["pageID"])
            page["pageID"] = original["pageID"]
        self.assertEqual(restored, self.ctx)  # Guards objects, heads, stroke IDs, fingerprints and provenance.
        self.assertEqual(ctx["pages"][0]["strokeTargets"][0]["id"], self.stroke_id)
        portable = decoded(assets[ctx["pages"][0]["portableSHA256"]])
        self.assertEqual(portable["strokes"][0]["id"], self.stroke_id)
        self.assertEqual(portable["objects"][0], self.obj)
        self.assertEqual(before, {str(p.relative_to(self.source)): p.read_bytes()
                                  for p in self.source.rglob("*") if p.is_file()})
        expected = {"context.json"} | {"assets/" + h for h in self.assets}
        self.assertEqual(set(manifest["files"]), expected)
        self.assertEqual({str(p.relative_to(self.destination)) for p in self.destination.rglob("*") if p.is_file()},
                         expected | {"case.json"})
        for name, record in manifest["files"].items():
            data = (self.destination / name).read_bytes()
            self.assertEqual(record, {"sha256": digest(data), "size": len(data)})
        for directory in (self.destination, self.destination / "assets"):
            self.assertEqual(directory.stat().st_mode & 0o777, 0o500)
        for path in self.destination.rglob("*"):
            if path.is_file():
                self.assertEqual(path.stat().st_mode & 0o777, 0o400)
        for parent in (self.root / "private", self.destination.parent):
            self.assertEqual(parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(cases.list_cases(self.destination.parent), [self.destination])

    def test_raw_sha_capture_and_explicit_override(self):
        for path in (self.source / "assets").iterdir():
            path.rename(path.with_suffix(""))
        result = self.import_case(request_prompt="Disclosed test-only query")
        self.assertEqual(result["manifest"]["requestPrompt"], "Disclosed test-only query")
        self.assertEqual(result["manifest"]["promptMode"], "explicit_test_query")
        self.assertEqual(result["assets"], self.assets)

    def test_existing_case_and_empty_directory_are_never_overwritten(self):
        self.import_case()
        before = (self.destination / "case.json").read_bytes()
        with self.assertRaises(FileExistsError):
            self.import_case()
        self.assertEqual(before, (self.destination / "case.json").read_bytes())
        empty = self.root / "empty"
        empty.mkdir()
        with self.assertRaises(FileExistsError):
            cases.import_case(self.source, empty, self.question, self.provenance)
        self.assertFalse(list(empty.iterdir()))

    def test_atomic_publish_race_never_replaces_empty_destination(self):
        rename = cases._rename_new
        def race(stage, destination):
            self.assertTrue((stage / "case.json").is_file())
            destination.mkdir()
            rename(stage, destination)
        with patch.object(cases, "_rename_new", side_effect=race):
            with self.assertRaises(FileExistsError):
                self.import_case()
        self.assertFalse(list(self.destination.iterdir()))
        self.assertFalse(list(self.destination.parent.glob(".case-*")))

    def test_publish_failure_cleans_only_unpublished_stage(self):
        with patch.object(cases, "_rename_new", side_effect=OSError("fixture publication failure")):
            with self.assertRaises(OSError):
                self.import_case()
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.destination.parent.glob(".case-*")))
        self.assertTrue((self.source / "context.json").is_file())

    def test_missing_asset_and_hash_tamper(self):
        path = next((self.source / "assets").iterdir())
        data = path.read_bytes()
        path.unlink()
        self.assert_rejected("missing_asset")
        path.write_bytes(data + b"tamper")
        self.assert_rejected("case_asset_integrity")

    def test_png_decode_and_dimensions_use_production_checks(self):
        self.replace_asset("paperSHA256", b"\x89PNG invalid PNG bytes")
        self.assert_rejected("invalid_png")
        self.replace_asset("paperSHA256", image(10, 10))
        self.assert_rejected("context_dimensions")

    def test_portable_scene_and_resolved_object_equality_are_checked(self):
        portable = decoded(self.assets[self.ctx["pages"][0]["portableSHA256"]])
        portable["objects"][0]["source"] = "Mismatch with captured resolved object"
        self.replace_asset("portableSHA256", encoded(portable))
        self.assert_rejected("context_scene")
        portable["strokes"][0]["opaqueNativeArchive"] = "invalid portable field"
        self.replace_asset("portableSHA256", encoded(portable))
        self.assert_rejected("invalid_scene")

    def test_native_history_is_forbidden_in_context_assets_and_provenance(self):
        self.ctx["undo_graph"] = {}
        self.write_capture()
        self.assert_rejected("native_archive_forbidden")
        self.ctx.pop("undo_graph")
        archive = encoded({"nested": {"PKDrawing": "never accepted"}})
        self.assets[digest(archive)] = archive
        self.write_capture()
        self.assert_rejected("native_archive_forbidden")
        self.assets.pop(digest(archive))
        self.write_capture()
        self.provenance["nativeSnapshots"] = []
        self.assert_rejected("native_archive_forbidden")

    def test_unreferenced_assets_unknown_names_duplicates_and_extra_entries(self):
        extra = image(2, 2)
        self.assets[digest(extra)] = extra
        self.write_capture()
        self.assert_rejected("case_inventory")
        self.assets.pop(digest(extra))
        self.write_capture()
        h, data = next(iter(self.assets.items()))
        path = self.source / "assets/not-a-sha.png"
        path.write_bytes(data)
        self.assert_rejected("case_assets")
        path.unlink()
        (self.source / "assets" / h).write_bytes(data)
        self.assert_rejected("case_assets")
        (self.source / "assets" / h).unlink()
        (self.source / "Undo.sqlite3").write_bytes(b"must not enter corpus")
        self.assert_rejected("case_inventory")

    def test_symlinks_are_rejected_for_files_roots_and_destination_ancestors(self):
        path = next((self.source / "assets").iterdir())
        external = self.root / "external"
        external.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(external)
        self.assert_rejected("case_path")
        path.unlink()
        self.write_capture()
        linked_source = self.root / "source-link"
        linked_source.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(Problem) as failure:
            cases.import_case(linked_source, self.destination, self.question, self.provenance)
        self.assertEqual(failure.exception.code, "case_path")
        (self.root / "private").symlink_to(self.root, target_is_directory=True)
        self.assert_rejected("case_path")

    def test_traversal_references_and_metadata_directory_symlinks_are_rejected(self):
        self.ctx["pages"][0]["portableSHA256"] = "../../outside.json"
        self.write_capture()
        self.assert_rejected("invalid_digest")
        self.ctx["pages"][0]["portableSHA256"] = next(
            h for h, data in self.assets.items()
            if not data.startswith(b"\x89PNG") and decoded(data)["objects"])
        self.write_capture()
        context_path = self.source / "context.json"
        external = self.root / "external-context.json"
        context_path.rename(external)
        context_path.symlink_to(external)
        self.assert_rejected("case_path")
        context_path.unlink()
        external.rename(context_path)
        assets = self.source / "assets"
        external_assets = self.root / "external-assets"
        assets.rename(external_assets)
        assets.symlink_to(external_assets, target_is_directory=True)
        self.assert_rejected("case_path")

    def test_stale_optional_native_layers_are_still_verified(self):
        self.ctx["nativeLayerUnavailable"] = True
        self.ctx["pages"][0]["inkSHA256"] = "f" * 64
        self.write_capture()
        self.assert_rejected("missing_asset")

    def test_source_and_destination_may_not_overlap(self):
        with self.assertRaises(Problem) as failure:
            cases.import_case(self.source, self.source / "case", self.question, self.provenance)
        self.assertEqual(failure.exception.code, "case_path")

    def test_context_and_asset_mutation_during_import_are_rejected(self):
        validate = cases._validate_context
        def mutate_context(ctx, assets):
            validate(ctx, assets)
            (self.source / "context.json").write_bytes(encoded(self.ctx))
        with patch.object(cases, "_validate_context", side_effect=mutate_context):
            self.assert_rejected("case_mutation")
        self.write_capture()
        def mutate_asset(ctx, assets):
            validate(ctx, assets)
            path = next((self.source / "assets").iterdir())
            path.write_bytes(path.read_bytes() + b"changed")
        with patch.object(cases, "_validate_context", side_effect=mutate_asset):
            self.assert_rejected("case_asset_integrity")

    def test_verify_rejects_tampered_context_assets_inventory_and_unknown_files(self):
        result = self.import_case()
        context_path = self.destination / "context.json"
        original = context_path.read_bytes()
        os.chmod(context_path, 0o600)
        context_path.write_bytes(original + b" ")
        with self.assertRaises(Problem) as failure:
            cases.verify_case(self.destination)
        self.assertEqual(failure.exception.code, "case_integrity")
        context_path.write_bytes(original)
        asset_path = self.destination / "assets" / next(iter(result["assets"]))
        os.chmod(asset_path, 0o600)
        asset_path.write_bytes(b"tampered")
        with self.assertRaises(Problem) as failure:
            cases.verify_case(self.destination)
        self.assertEqual(failure.exception.code, "case_asset_integrity")
        asset_path.write_bytes(result["assets"][asset_path.name])
        manifest_path = self.destination / "case.json"
        os.chmod(manifest_path, 0o600)
        manifest = copy.deepcopy(result["manifest"])
        manifest["files"]["../escape"] = {"sha256": "a" * 64, "size": 1}
        manifest_path.write_bytes(encoded(manifest))
        with self.assertRaises(Problem) as failure:
            cases.verify_case(self.destination)
        self.assertEqual(failure.exception.code, "case_integrity")
        manifest_path.write_bytes(encoded(result["manifest"]))
        os.chmod(self.destination, 0o700)
        (self.destination / "untracked").write_bytes(b"unexpected")
        with self.assertRaises(Problem) as failure:
            cases.verify_case(self.destination)
        self.assertEqual(failure.exception.code, "case_inventory")

    def test_invalid_review_metadata_and_invalid_context_are_not_published(self):
        for kwargs in ({"question": ""}, {"provenance": []}, {"request_prompt": ""},
                       {"request_prompt": 3}, {"question": "x" * 65537}):
            arguments = {"question": self.question, "provenance": self.provenance, **kwargs}
            with self.assertRaises(Problem):
                cases.import_case(self.source, self.destination, **arguments)
        self.ctx["orientation"] = "automatic"
        self.write_capture()
        self.assert_rejected("invalid_orientation")

    def test_identity_mapping_cannot_be_reverted_to_source_ids(self):
        result = self.import_case()
        manifest_path = self.destination / "case.json"
        os.chmod(manifest_path, 0o600)
        result["manifest"]["identityMapping"]["documentID"]["isolated"] = self.ctx["documentID"]
        manifest_path.write_bytes(encoded(result["manifest"]))
        with self.assertRaises(Problem) as failure:
            cases.verify_case(self.destination)
        self.assertEqual(failure.exception.code, "case_identity")

    def test_list_missing_corpus_and_ignore_unpublished_stages(self):
        self.assertEqual(cases.list_cases(self.destination.parent), [])
        self.import_case()
        (self.destination.parent / ".case-incomplete").mkdir()
        self.assertEqual(cases.list_cases(self.destination.parent), [self.destination])


if __name__ == "__main__":
    unittest.main()
