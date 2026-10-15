"""Read-only source staging; native XCTest exports importer-ready context/assets.

await stage_document(DEFAULT_ENDPOINT, protected_token_file, document_uuid,
                     page_1_based_or_uuid, NEW_case_directory)
Only an explicit call retrieves notes. Copy DrawBenchmarkInput to the test runner's
Documents, run AIBenchmarkCaptureTests, then import DrawBenchmarkExports/<caseID>.
Keep stagingOriginalprovenance.json alongside staging, outside the native Store.
Pass the returned caseProvenance to import_case, not the native-bearing manifest.
No source publication, Notes CAS access, worker launch, or app installation.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from uuid import UUID, uuid4

import aiohttp
from benchmarks.draw_ai.cases import _read, _rename_new, _safe_path
from server.server import (MAX_METADATA_BYTES, MAX_OBJECT_BYTES, canonical,
                           decode_body, object_digest, parse_json, validate,
                           validate_current_only, validate_folder_graph)
from server.ai_models import validate_source_assets

DEFAULT_ENDPOINT = "http://127.0.0.1:18874"
DEFAULT_TOKEN_FILE = Path.home() / ".local/state/draw-sync/token"


def _uuid(value):
    return str(UUID(value)).upper()


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _token(path):
    path = _safe_path(path)
    info = path.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Bearer file must be owner-only")
    token = _read(path, 4096).decode().strip()
    if not token or any(c.isspace() for c in token):
        raise ValueError("Invalid bearer file")
    return token


class _MissingObject(Exception):
    pass


async def _get(session, endpoint, path, limit):
    async with session.get(endpoint + path, allow_redirects=False) as response:
        if response.status == 404 and path.startswith("/v2/objects/"):
            raise _MissingObject()
        if response.status != 200:
            # Never include URLs, bearer values or response bodies in errors.
            raise ValueError(f"Source GET failed: HTTP {response.status}")
        body = bytearray()
        async for chunk in response.content.iter_chunked(65536):
            body.extend(chunk)
            if len(body) > limit:
                raise ValueError("Source response exceeds size limit")
        # Disable aiohttp auto decoding; decode exactly once, by HTTP header,
        # never by archive magic. Both encoded and decoded bodies are bounded.
        return decode_body(bytes(body), response.headers.get("Content-Encoding", "").lower(), limit)


async def _state(session, endpoint, document):
    state = parse_json(await _get(session, endpoint,
        f"/v2/documents/{document}/state", MAX_METADATA_BYTES))
    if not isinstance(state, dict) or state.get("manifest") is None:
        raise ValueError("Source document does not exist")
    if type(state.get("revision")) is not int or state["revision"] < 0:
        raise ValueError("Invalid source revision")
    object_digest(state.get("documentDigest"))
    manifest = state["manifest"]
    validate_current_only(manifest)
    validate_source_assets(manifest, wire=True)
    if len(manifest["notebooks"]) != 1 or manifest["notebooks"][0]["id"] != document:
        raise ValueError("Expected exactly the requested document")
    for sha in (*manifest["blobs"].values(), *manifest.get("assets", {}).values()):
        object_digest(sha)
    folders = validate_folder_graph(manifest)
    closure, folder = set(), manifest["notebooks"][0].get("folderID")
    while folder is not None:
        closure.add(folder)
        folder = folders[folder].get("parentID")
    if closure != set(folders):
        raise ValueError("Source contains unrelated folders")
    return state


def _same_source(original, current):
    if any(original[k] != current[k] for k in ("revision", "documentDigest", "manifest")):
        raise ValueError("Source revision changed; select and stage again")


def _library(manifest, mapping):
    """Dictionary copy preserves Swift reference-date numbers and object provenance."""
    original = manifest["notebooks"][0]
    old_pages = {p["id"] for p in original["pages"] + original["deleted"]}
    old_folders = {f["id"] for f in manifest.get("folders") or []}
    if (mapping["documentID"]["original"] != original["id"] or
            set(mapping["pageIDs"]) != old_pages or set(mapping["folderIDs"]) != old_folders):
        raise ValueError("Incomplete staging identity mapping")
    new_ids = [mapping["documentID"]["isolated"], *mapping["pageIDs"].values(), *mapping["folderIDs"].values()]
    if (any(_uuid(v) != v for v in new_ids) or len(set(new_ids)) != len(new_ids) or
            set(new_ids) & {original["id"], *old_pages, *old_folders}):
        raise ValueError("Staging identities must be unique and isolated")
    book = copy.deepcopy(original)
    book["id"] = mapping["documentID"]["isolated"]
    book["name"] = "Test " + book["name"]
    if book.get("currentPage") is not None:
        book["currentPage"] = mapping["pageIDs"][book["currentPage"]]
    if book.get("folderID") is not None:
        book["folderID"] = mapping["folderIDs"][book["folderID"]]
    for page in book["pages"] + book["deleted"]:
        page["id"] = mapping["pageIDs"][page["id"]]
        head = page.get("head")
        page["nodes"] = [copy.deepcopy(next(n for n in page["nodes"] if n["id"] == head))] if head else []
        for node in page["nodes"]:
            node["children"] = []
            node.pop("parent", None)
            node.pop("preferredChild", None)
        page["preferredRoot"] = head
    folders = copy.deepcopy(manifest.get("folders") or [])
    for folder in folders:
        folder["id"] = mapping["folderIDs"][folder["id"]]
        folder["name"] = "Test " + folder["name"]
        if folder.get("parentID") is not None:
            folder["parentID"] = mapping["folderIDs"][folder["parentID"]]
    # No localHistory means Store's constructor cannot prune snapshots, and
    # migrateLegacyHistory:false prevents the teal/history migration entirely.
    return {"notebooks": [book], "folders": folders, "historySchemaVersion": 2}


def verify_staging(directory):
    """Verify every staged byte and the isolated index before native transfer."""
    root = _safe_path(directory)
    if {p.name for p in root.iterdir()} != {"DrawBenchmarkInput", "stagingOriginalprovenance.json"}:
        raise ValueError("Unexpected staging entries")
    provenance = parse_json(_read(root / "stagingOriginalprovenance.json", MAX_METADATA_BYTES))
    native = root / "DrawBenchmarkInput"
    actual, directories = {}, set()
    _safe_path(native)
    for file in native.rglob("*"):
        _safe_path(file)
        if file.is_file():
            data = _read(file, MAX_OBJECT_BYTES)
            actual[file.relative_to(native).as_posix()] = {"sha256": _digest(data), "size": len(data)}
        elif file.is_dir():
            directories.add(file.relative_to(native).as_posix())
        else:
            raise ValueError("Unexpected staged file")
    expected_directories = {"assets"}
    for name in provenance["files"]:
        expected_directories.update(str(p) for p in Path(name).parents if str(p) != ".")
    if actual != provenance["files"] or directories != expected_directories:
        raise ValueError("Staging inventory checksum mismatch")
    library = parse_json(_read(native / "notebooks.json", MAX_METADATA_BYTES))
    if library != _library(provenance["manifest"], provenance["identityMapping"]):
        raise ValueError("Staging identity or source metadata differs")
    manifest, mapping, target = provenance["manifest"], provenance["identityMapping"], provenance["target"]
    if (parse_json(_read(native / "targets.json", MAX_METADATA_BYTES)) != [target] or
            target["documentID"] != mapping["documentID"]["isolated"] or
            target["focusPageID"] != mapping["pageIDs"][provenance["originalFocusPageID"]] or
            target["identityMapping"] != mapping):
        raise ValueError("Staging target differs")
    for key, sha in manifest["blobs"].items():
        _, pid, head = key.split("/")
        name = f'{mapping["documentID"]["isolated"]}/{mapping["pageIDs"][pid]}/{head}.pkdraw'
        if actual[name]["sha256"] != sha:
            raise ValueError("Staged snapshot differs from pinned source SHA")
    for sha in manifest.get("assets", {}):
        if actual["assets/" + sha + ".png"]["sha256"] != sha:
            raise ValueError("Staged asset differs from pinned source SHA")
    return provenance


async def stage_document(endpoint, token_file, document_id, page: int | str, destination):
    """Freeze one current source document, fail closed on a concurrent revision.

    destination is a NEW case directory, normally the gitignored
    data/ai-benchmark/staging/<case-id>. Integers select 1-based live page order;
    strings select a live page UUID. Deleted heads are copied, never focus targets.
    Returns inputDirectory, provenancePath, target and frozen provenance.
    """
    endpoint = endpoint.rstrip("/")
    if endpoint != DEFAULT_ENDPOINT:
        raise ValueError("Only the fixed private loopback source endpoint is allowed")
    document = _uuid(document_id)
    destination = _safe_path(destination)
    if destination.exists():
        raise FileExistsError(str(destination))
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", destination.name) is None:
        raise ValueError("Case ID must be a safe single path component")
    token = _token(token_file)  # Credential is read only inside the explicit call.
    async with aiohttp.ClientSession(trust_env=False, auto_decompress=False,
            timeout=aiohttp.ClientTimeout(total=90), headers={
                "Authorization": "Bearer " + token, "Accept-Encoding": "gzip"}) as session:
        state = await _state(session, endpoint, document)
        manifest = state["manifest"]
        book = manifest["notebooks"][0]
        live = book["pages"]
        if type(page) is int:
            if not 1 <= page <= len(live):
                raise ValueError("Focus page number outside live document")
            focus = live[page - 1]["id"]
        else:
            focus = _uuid(page)
            if focus not in {p["id"] for p in live}:
                raise ValueError("Focus page is not a live page of this document")
        scene_state = parse_json(await _get(session, endpoint,
            f"/v2/documents/{document}/scenes", MAX_METADATA_BYTES))
        scene_refs = scene_state["scenes"]
        if scene_state["revision"] != state["revision"]:
            raise ValueError("Source revision changed; select and stage again")
        if set(scene_refs) != {document + "/" + p["id"] for p in live + book["deleted"]}:
            raise ValueError("Source scene inventory differs")
        for sha in scene_refs.values():
            object_digest(sha)
        objects = {}
        digests = set(manifest["blobs"].values()) | set(manifest.get("assets", {}).values()) | set(scene_refs.values())
        for attempt in range(3):
            try:
                for sha in sorted(digests - objects.keys()):
                    data = await _get(session, endpoint, "/v2/objects/" + sha, MAX_OBJECT_BYTES)
                    if _digest(data) != sha:
                        raise ValueError("Source object checksum mismatch")
                    objects[sha] = data
                break
            except _MissingObject:
                _same_source(state, await _state(session, endpoint, document))
                if attempt == 2:
                    raise ValueError("Pinned source object disappeared") from None
        _same_source(state, await _state(session, endpoint, document))

    # Full existing source admission validates metadata/PNG assets, never writes.
    package = copy.deepcopy(manifest)
    package["blobs"] = {k: base64.b64encode(objects[h]).decode() for k, h in manifest["blobs"].items()}
    if "assets" in manifest:
        package["assets"] = {k: base64.b64encode(objects[h]).decode() for k, h in manifest["assets"].items()}
    validate(package)
    original_ids = {document, *[p["id"] for p in live + book["deleted"]],
                    *[f["id"] for f in manifest.get("folders") or []]}
    generated = set(original_ids)
    def fresh():
        value = str(uuid4()).upper()
        while value in generated:
            value = str(uuid4()).upper()
        generated.add(value)
        return value
    mapping = {"documentID": {"original": document, "isolated": fresh()},
               "pageIDs": {p["id"]: fresh() for p in live + book["deleted"]},
               "folderIDs": {f["id"]: fresh() for f in manifest.get("folders") or []}}
    target = {"caseID": destination.name, "documentID": mapping["documentID"]["isolated"],
              "focusPageID": mapping["pageIDs"][focus], "identityMapping": mapping}
    payloads = {"notebooks.json": canonical(_library(manifest, mapping)), "targets.json": canonical([target])}
    for key, sha in manifest["blobs"].items():
        _, pid, head = key.split("/")
        payloads[f'{mapping["documentID"]["isolated"]}/{mapping["pageIDs"][pid]}/{head}.pkdraw'] = objects[sha]
    for sha in manifest.get("assets", {}):
        payloads["assets/" + sha + ".png"] = objects[sha]
    provenance = {"format": 1, "kind": "draw-ai-benchmark-staging", "originalDocumentID": document,
                  "originalFocusPageID": focus, "revision": state["revision"],
                  "documentDigest": state["documentDigest"], "lastSyncedAt": state.get("lastSyncedAt"),
                  "manifest": manifest, "sceneReferences": scene_refs,
                  "objectChecksums": {h: {"sha256": h, "size": len(objects[h])} for h in sorted(objects)},
                  "pageHeads": {p["id"]: p.get("head") for p in live + book["deleted"]},
                  "identityMapping": mapping, "target": target,
                  "files": {k: {"sha256": _digest(v), "size": len(v)} for k, v in payloads.items()}}
    # Importer provenance must not carry native source/Undo-bearing field names.
    # The full exact wire manifest remains only in the separate staging record.
    case_provenance = {k: copy.deepcopy(provenance[k]) for k in (
        "originalDocumentID", "originalFocusPageID", "revision", "documentDigest", "lastSyncedAt",
        "pageHeads", "identityMapping", "sceneReferences")}
    case_provenance["sourceManifestSHA256"] = _digest(canonical(manifest))
    case_provenance["currentObjects"] = {p["id"]: copy.deepcopy(p["nodes"][0].get("objects", []))
                                         for p in live + book["deleted"] if p["nodes"]}
    provenance["caseProvenance"] = case_provenance
    provenance_bytes = canonical(provenance)
    if max(len(provenance_bytes), len(payloads["notebooks.json"])) > MAX_METADATA_BYTES:
        raise ValueError("Staging metadata exceeds size limit")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _safe_path(destination.parent)
    temporary = Path(tempfile.mkdtemp(prefix=".staging-", dir=destination.parent))
    try:
        native = temporary / "DrawBenchmarkInput"
        native.mkdir(mode=0o700)
        # Blank/no-AI documents still have the conventional assets directory.
        (native / "assets").mkdir(mode=0o700)
        for name, data in payloads.items():
            file = native / name
            file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with file.open("xb") as stream:
                os.chmod(file, 0o600)
                stream.write(data)
        (temporary / "stagingOriginalprovenance.json").write_bytes(provenance_bytes)
        os.chmod(temporary / "stagingOriginalprovenance.json", 0o600)
        verify_staging(temporary)
        _rename_new(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return {"inputDirectory": str(destination / "DrawBenchmarkInput"),
            "provenancePath": str(destination / "stagingOriginalprovenance.json"),
            "target": target, "provenance": provenance, "caseProvenance": case_provenance}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("document", type=_uuid)
    parser.add_argument("--page", required=True, help="1-based live page number or page UUID")
    parser.add_argument("--destination", type=Path, required=True, help="New staging case directory")
    parser.add_argument("--token-file", type=Path, default=DEFAULT_TOKEN_FILE)
    args = parser.parse_args()
    page = int(args.page) if args.page.isdecimal() else args.page
    result = asyncio.run(stage_document(DEFAULT_ENDPOINT, args.token_file, args.document, page, args.destination))
    print(json.dumps({k: v for k, v in result.items() if k not in ("provenance", "caseProvenance")}, indent=2))


if __name__ == "__main__":
    main()
