"""Read Draw metadata or download synced PNGs for a Pi agent (stdlib only)."""
import argparse
import hashlib
import re
import json
import os
from pathlib import Path
import urllib.request
import zipfile
import io
from uuid import UUID


class ManagerClient:
    """Read-only Sync retrieval for the notes manager; never creates workers."""
    def __init__(self, origin, token):
        self.origin = origin.rstrip("/")
        self.token = token

    def get(self, path):
        request = urllib.request.Request(self.origin + path, headers={
            "Authorization": "Bearer " + self.token, "Accept-Encoding": "gzip"})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read(128 * 1024 * 1024 + 1)
            if len(data) > 128 * 1024 * 1024:
                raise ValueError("Sync response too large")
            if response.headers.get("Content-Encoding") == "gzip":
                import zlib
                decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
                data = decoder.decompress(data, 128 * 1024 * 1024 + 1)
                if len(data) > 128 * 1024 * 1024 or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
                    raise ValueError("Invalid compressed Sync response")
            return data

    def document_state(self, document):
        return json.loads(self.get("/v2/documents/" + str(UUID(document)).upper() + "/state"))

    def document_scene_refs(self, document):
        return json.loads(self.get("/v2/documents/" + str(UUID(document)).upper() + "/scenes"))

    def object_bytes(self, digest):
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise ValueError("Invalid object SHA256")
        data = self.get("/v2/objects/" + digest)
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("Sync object checksum mismatch")
        return data

    def document_metadata(self, document):
        return json.loads(self.get("/v1/documents/" + str(UUID(document)).upper()))

    def sync_receipt(self, sync_id):
        return json.loads(self.get("/v2/sync-receipts/" + str(UUID(sync_id)).upper()))

    # Contract spellings for direct manager integrations.
    docScenerefs = document_scene_refs
    objectBytes = object_bytes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("document", nargs="?", type=lambda v: str(UUID(v)).upper())
    parser.add_argument("--page", type=lambda v: str(UUID(v)).upper())
    parser.add_argument("--span", help="Inclusive document order, e.g. 2:5")
    parser.add_argument("--dest", type=Path)
    folders = parser.add_mutually_exclusive_group()
    folders.add_argument("--folders", action="store_true")
    folders.add_argument("--folder", type=lambda v: str(UUID(v)).upper())
    parser.add_argument("--revision", type=int, help="Pin metadata and folder ancestry to the current revision")
    args = parser.parse_args()
    if (args.folders or args.folder) and (args.document or args.page or args.span):
        parser.error("Choose folders or document/page metadata")
    if args.page and args.span:
        parser.error("Choose --page or --span")
    if (args.page or args.span) and not args.document:
        parser.error("A document ID is required")
    origin = os.environ.get("DRAW_SYNC_URL", "https://draw.example.invalid/draw-sync").rstrip("/")
    token = os.environ.get("DRAW_SYNC_TOKEN")
    if token is None:
        token = (Path.home() / ".local/state/draw-sync/token").read_text().strip()
    def get(path):
        request = urllib.request.Request(origin + path, headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    base = ("/v1/folders" + ("/" + args.folder if args.folder else "")) if args.folders or args.folder else "/v1/documents" + ("/" + args.document if args.document else "")
    if args.revision is not None and args.revision < 0:
        parser.error("Revision must be nonnegative")
    metadata = json.loads(get(base + (f"?revision={args.revision}" if args.revision is not None else "")))
    if not args.page and not args.span:
        print(json.dumps(metadata, indent=2))
        return
    revision = metadata["revision"]
    dest = args.dest or Path.home() / "tmp/draw" / args.document / str(revision)
    dest.mkdir(parents=True, exist_ok=True)
    if args.page:
        image = get(base + f"/pages/{args.page}.png?revision={revision}")
        file = dest / (args.page + ".png")
        file.write_bytes(image)
        print(file.resolve())
    else:
        start, end = map(int, args.span.split(":"))
        data = get(base + f"/pages.zip?start={start}&end={end}&revision={revision}")
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for name in archive.namelist():
                if Path(name).name != name or not name.endswith(".png"):
                    raise ValueError("Unsafe image archive path")
            for name in archive.namelist():
                file = dest / name
                file.write_bytes(archive.read(name))
                print(file.resolve())


if __name__ == "__main__":
    main()
