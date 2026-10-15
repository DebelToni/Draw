"""Private frozen captures for data/ai-benchmark/cases (runs live separately).

import_case returns the runner's {manifest, context, assets} triplet; the directory
is also accepted by runner.load_case. Assets are exact bytes, stored as assets/SHA.
Only document/page IDs change. Native stroke IDs/fingerprints, heads, object IDs
and historical object provenance remain untouched, including in portable JSON.

The inventory covers every payload file. case.json is the manifest itself, so it
cannot contain its own checksum. Read-only owner permissions prevent accidental
editing, not a malicious owner rewriting the manifest. No live retrieval or calls.
"""
from __future__ import annotations

import ctypes
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
from uuid import uuid4

from notes_service import validation
from server.ai_models import validate_objects
from notes_service.storage import MAX_ASSET, MAX_METADATA, Problem, decoded, encoded, require, sha, utc, uuid


_STAGE_FIELDS = {"originalDocumentID", "originalFocusPageID", "revision", "documentDigest",
                 "lastSyncedAt", "pageHeads", "identityMapping", "sceneReferences",
                 "sourceManifestSHA256", "currentObjects"}

_ASSET_NAME = re.compile(r"([0-9a-f]{64})(?:\.(?:png|json))?")


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _safe_path(path):
    """Reject symlinks in every existing component, without resolving them away."""
    path = Path(os.path.abspath(path))
    for part in (*reversed(path.parents), path):
        require(not part.is_symlink(), "case_path", "Symlink paths are forbidden")
    return path


def _read(path, limit):
    _safe_path(path)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        raise Problem("case_file", "Missing or unsafe case file") from None
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode), "case_file", "Expected a regular file")
        require(before.st_size <= limit, "case_limit", "Case file exceeds production limit", 413)
        data = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
        current = path.lstat()
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(len(data) <= limit and identity(before) == identity(after) == identity(current),
                "case_mutation", "Case file changed during capture")
        return data


def _entries(root, manifest=False):
    _safe_path(root)
    require(root.is_dir(), "case_structure", "Expected a capture/case directory")
    expected = {"context.json", "assets"} | ({"case.json"} if manifest else set())
    require({p.name for p in root.iterdir()} == expected,
            "case_inventory", "Unexpected or missing capture/case entries")
    assets = _safe_path(root / "assets")
    require(assets.is_dir(), "case_structure", "Expected an assets directory")
    return sorted(assets.iterdir())


def _assets(paths, raw=False):
    result = {}
    for path in paths:
        match = _ASSET_NAME.fullmatch(path.name)
        require(match is not None and (not raw or path.name == match[1]),
                "case_assets", "Expected SHA-named assets")
        digest = match[1]
        require(digest not in result, "case_assets", "Duplicate asset identity")
        data = _read(path, MAX_ASSET)
        require(_digest(data) == digest, "case_asset_integrity", "Asset checksum mismatch")
        validation.artifact(data)  # Same admission checks as the production CAS.
        result[digest] = data
    return result


def _validate_context(ctx, assets):
    validation.no_native_history(ctx)
    used = set()

    def read_asset(digest):
        sha(digest)
        require(digest in assets, "missing_asset", "Referenced case asset is missing")
        used.add(digest)
        return assets[digest]

    validation.context(ctx, read_asset, ctx.get("documentID"))
    # Stale production captures only require composite. Validate any supplied
    # optional native layers too, rather than silently retaining unchecked refs.
    for page in ctx["pages"]:
        for field in ("paperSHA256", "inkSHA256"):
            if field in page:
                require(validation.png(read_asset(page[field])) ==
                        (round(page["width"] * 2), round(page["height"] * 2)),
                        "context_dimensions", "Optional layer dimensions mismatch")
    require(used == set(assets), "case_inventory", "Unreferenced assets are forbidden")


def _validate_provenance(provenance, document_id, focus_id, captured_pages):
    """Bind stage_document's metadata to native capture identities and current state.

    Generic metadata (e.g. {"fixture": True}) makes no staged-source attribution.
    Stage fields are all-or-nothing. Extra metadata, including no-migration tags,
    is preserved but never relaxes head/object equality. Source digests are safe
    here, outside the production context, and cannot authenticate a source alone.
    """
    if not (_STAGE_FIELDS & set(provenance)):
        return
    require(_STAGE_FIELDS <= set(provenance), "case_provenance", "Incomplete staging provenance")
    original = uuid(provenance["originalDocumentID"])
    focus = uuid(provenance["originalFocusPageID"])
    validation.integer(provenance["revision"])
    sha(provenance["documentDigest"])
    sha(provenance["sourceManifestSHA256"])
    if provenance["lastSyncedAt"] is not None:
        validation.timestamp(provenance["lastSyncedAt"])
    mapping = provenance["identityMapping"]
    require(isinstance(mapping, dict) and set(mapping) == {"documentID", "pageIDs", "folderIDs"},
            "case_provenance", "Invalid staging identity mapping")
    document, pages, folders = (mapping[k] for k in ("documentID", "pageIDs", "folderIDs"))
    require(document == {"original": original, "isolated": document_id} and
            isinstance(pages, dict) and isinstance(folders, dict),
            "case_provenance", "Capture belongs to another staged document")
    originals = [original, *pages, *folders]
    isolated = [document_id, *pages.values(), *folders.values()]
    for identity in originals + isolated:
        uuid(identity)
    require(len(set(originals)) == len(originals) and len(set(isolated)) == len(isolated) and
            not (set(originals) & set(isolated)) and pages.get(focus) == focus_id and
            set(captured_pages) <= set(pages.values()),
            "case_provenance", "Staging identities or capture focus/pages differ")
    heads, objects, scenes = (provenance[k] for k in ("pageHeads", "currentObjects", "sceneReferences"))
    require(isinstance(heads, dict) and set(heads) == set(pages) and isinstance(objects, dict) and
            isinstance(scenes, dict) and set(scenes) == {original + "/" + pid for pid in pages},
            "case_provenance", "Incomplete staging page state")
    for head in heads.values():
        if head is not None:
            uuid(head)
    for digest in scenes.values():
        sha(digest)
    require(set(objects) == {pid for pid, head in heads.items() if head is not None},
            "case_provenance", "Staging objects must describe current heads")
    object_ids = set()
    for current in objects.values():
        try:
            validate_objects(current)
        except (ValueError, TypeError, KeyError, AttributeError):
            raise Problem("case_provenance", "Invalid staging current objects") from None
        for obj in current:
            require(obj["id"] not in object_ids, "case_provenance", "Duplicate staging object identity")
            object_ids.add(obj["id"])
    for original_page, captured_id in pages.items():
        if captured_id in captured_pages:
            captured = captured_pages[captured_id]
            require(captured.get("head") == heads[original_page] and
                    captured["objects"] == objects.get(original_page, []),
                    "case_provenance", "Capture head/objects differ from staged source")


def _text(value, name):
    require(isinstance(value, str) and value.strip() and len(value.encode()) <= 65536,
            "case_metadata", name + " must be a nonempty bounded string")


def _inventory(context_bytes, assets):
    return {name: {"sha256": _digest(data), "size": len(data)} for name, data in
            [("context.json", context_bytes), *[("assets/" + h, data) for h, data in sorted(assets.items())]]}


def _rename_new(source, destination):
    """DGX/Linux atomic publication without replacing even an empty directory."""
    rename = ctypes.CDLL(None, use_errno=True).renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1):  # RENAME_NOREPLACE
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def import_case(source_capture_dir, dest_case_dir, question: str, provenance: dict,
                request_prompt: str | None = None):
    """Validate and atomically freeze one capture, never overwrite an existing case.

    question is review-only. None keeps Manager.app_prompt exactly; an explicit
    request_prompt is a disclosed benchmark override. provenance is caller-owned
    source metadata, copied verbatim, never inferred from an environment/config.
    Staged provenance must bind to this capture; generic fixture metadata supplies
    no staged-source attribution.
    """
    _text(question, "question")
    require(isinstance(provenance, dict), "case_metadata", "Expected source provenance")
    provenance = decoded(encoded(provenance))
    validation.no_native_history(provenance)
    if request_prompt is not None:
        _text(request_prompt, "request_prompt")
    source, destination = _safe_path(source_capture_dir), _safe_path(dest_case_dir)
    require(not destination.is_relative_to(source) and not source.is_relative_to(destination),
            "case_path", "Capture and frozen case directories must be separate")
    if destination.exists():
        raise FileExistsError(str(destination))
    paths = _entries(source)
    original_bytes = _read(source / "context.json", MAX_METADATA)
    ctx = decoded(original_bytes)
    require(isinstance(ctx, dict), "case_structure", "Expected a context object")
    assets = _assets(paths)
    _validate_context(ctx, assets)
    _validate_provenance(provenance, ctx["documentID"], ctx["focusPageID"],
                         {p["pageID"]: p for p in ctx["pages"]})
    require(_entries(source) == paths and _assets(paths) == assets and
            _read(source / "context.json", MAX_METADATA) == original_bytes,
            "case_mutation", "Capture changed during import")

    original_doc, original_focus = ctx["documentID"], ctx["focusPageID"]
    source_metadata = {"contextSHA256": _digest(original_bytes), "documentID": original_doc,
                       "focusPageID": original_focus, "capturedAt": ctx["capturedAt"],
                       "pageHeads": {p["pageID"]: p.get("head") for p in ctx["pages"]}}
    page_ids = {p["pageID"]: str(uuid4()).upper() for p in ctx["pages"]}
    ctx["documentID"] = str(uuid4()).upper()
    ctx["focusPageID"] = page_ids[original_focus]
    for page in ctx["pages"]:
        page["pageID"] = page_ids[page["pageID"]]
    _validate_context(ctx, assets)
    context_bytes = encoded(ctx)
    manifest = {"format": 1, "kind": "draw-ai-benchmark-case", "caseID": str(uuid4()).upper(),
                "createdAt": utc(), "question": question, "questionPurpose": "review_only",
                "requestPrompt": request_prompt,
                "promptMode": "production_app_prompt" if request_prompt is None else "explicit_test_query",
                "provenance": provenance, "source": source_metadata,
                "identityMapping": {"documentID": {"original": original_doc, "isolated": ctx["documentID"]},
                                    "pageIDs": page_ids},
                "contextSHA256": _digest(context_bytes), "files": _inventory(context_bytes, assets)}
    manifest_bytes = encoded(manifest)
    decoded(manifest_bytes)  # Bound the complete manifest, not only provenance.
    missing, parent = [], destination.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    for parent in reversed(missing):
        parent.mkdir(mode=0o700)
    _safe_path(destination.parent)
    stage = Path(tempfile.mkdtemp(prefix=".case-", dir=destination.parent))
    try:
        (stage / "assets").mkdir(mode=0o700)
        for name, data in [("case.json", manifest_bytes), ("context.json", context_bytes),
                           *[("assets/" + h, data) for h, data in assets.items()]]:
            path = stage / name
            with path.open("xb") as stream:
                os.chmod(path, 0o400)
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        result = verify_case(stage)
        for directory in (stage / "assets", stage):
            os.chmod(directory, 0o500)
        _rename_new(stage, destination)
        return result
    finally:
        if stage.exists():
            # Only our unpublished temporary directory is ever made writable.
            os.chmod(stage, 0o700)
            os.chmod(stage / "assets", 0o700)
            shutil.rmtree(stage)


def verify_case(case_dir):
    """Verify the complete frozen bundle and return the runner's in-memory triplet."""
    root = _safe_path(case_dir)
    paths = _entries(root, manifest=True)
    manifest = decoded(_read(root / "case.json", MAX_METADATA))
    context_bytes = _read(root / "context.json", MAX_METADATA)
    ctx = decoded(context_bytes)
    require(isinstance(manifest, dict) and isinstance(ctx, dict), "case_structure", "Expected JSON objects")
    require(manifest.get("format") == 1 and manifest.get("kind") == "draw-ai-benchmark-case",
            "case_manifest", "Unsupported case manifest")
    validation.no_native_history(manifest)
    uuid(manifest.get("caseID"))
    validation.timestamp(manifest.get("createdAt"))
    _text(manifest.get("question"), "question")
    prompt = manifest.get("requestPrompt")
    if prompt is not None:
        _text(prompt, "requestPrompt")
    require(manifest.get("questionPurpose") == "review_only" and
            manifest.get("promptMode") == ("production_app_prompt" if prompt is None else "explicit_test_query") and
            isinstance(manifest.get("provenance"), dict), "case_manifest", "Invalid review/prompt metadata")
    assets = _assets(paths, raw=True)
    require(manifest.get("files") == _inventory(context_bytes, assets) and
            manifest.get("contextSHA256") == _digest(context_bytes),
            "case_integrity", "Case inventory or context checksum differs")
    _validate_context(ctx, assets)
    source, mapping = manifest.get("source"), manifest.get("identityMapping")
    require(isinstance(source, dict) and isinstance(mapping, dict), "case_manifest", "Missing source identity")
    sha(source.get("contextSHA256"))
    uuid(source.get("documentID"))
    uuid(source.get("focusPageID"))
    require(source.get("capturedAt") == ctx["capturedAt"] and
            source["documentID"] != ctx["documentID"] and
            mapping.get("documentID") == {"original": source["documentID"], "isolated": ctx["documentID"]},
            "case_identity", "Document identity must be isolated from the capture")
    pages, heads = mapping.get("pageIDs"), source.get("pageHeads")
    require(isinstance(pages, dict) and isinstance(heads, dict) and set(pages) == set(heads),
            "case_identity", "Missing page identity mapping")
    for pid in pages:
        uuid(pid)
        uuid(pages[pid])
    require(len(set(pages.values())) == len(pages) and not (set(pages) & set(pages.values())) and
            pages.get(source["focusPageID"]) == ctx["focusPageID"] and
            {pages[p]: h for p, h in heads.items()} == {p["pageID"]: p.get("head") for p in ctx["pages"]},
            "case_identity", "Page identity/head mapping differs")
    reverse = {isolated: original for original, isolated in pages.items()}
    _validate_provenance(manifest["provenance"], source["documentID"], source["focusPageID"],
                         {reverse[p["pageID"]]: p for p in ctx["pages"]})
    return {"manifest": manifest, "context": ctx, "assets": assets}


def list_cases(cases_dir):
    """Sorted verified case paths; unpublished .case-* stages are never listed."""
    root = _safe_path(cases_dir)
    if not root.exists():
        return []
    require(root.is_dir(), "case_structure", "Expected a private case corpus directory")
    cases = []
    for path in sorted(root.iterdir()):
        if path.name.startswith(".case-"):
            continue
        verify_case(path)
        cases.append(path)
    return cases
