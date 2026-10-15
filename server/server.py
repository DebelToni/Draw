"""Manual Draw sync. Tailnet HTTPS terminates at Tailscale Serve; bind loopback only."""
import base64
from contextlib import contextmanager
import hashlib
import gzip
import hmac
import json
import os
import re
from pathlib import Path
import sqlite3
import struct
import zlib
import io
import zipfile
from urllib.parse import urlsplit, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import UUID
from datetime import datetime, timezone
try:
    from .ai_models import current_objects, validate_objects, validate_source_assets, validate_asset
except ImportError:
    from ai_models import current_objects, validate_objects, validate_source_assets, validate_asset

MAX_BYTES = 128 * 1024 * 1024
MAX_OBJECT_BYTES = 128 * 1024 * 1024
MAX_METADATA_BYTES = 4 * 1024 * 1024


def object_digest(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("Invalid object digest")
    return value


def decode_body(data, encoding, limit):
    if encoding == "gzip":
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            decoded = decoder.decompress(data, limit + 1)
        except zlib.error as error:
            raise ValueError("Invalid gzip body") from error
        if len(decoded) > limit or decoder.unconsumed_tail:
            raise BodyTooLarge()
        if not decoder.eof or decoder.unused_data:
            raise ValueError("Incomplete or trailing gzip data")
        return decoded
    if encoding not in ("", "identity"):
        raise ValueError("Unsupported content encoding")
    return data


def parse_json(data):
    def invalid_constant(value):
        raise ValueError("Non-finite JSON number")
    return json.loads(data.decode("utf-8"), parse_constant=invalid_constant)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def uuid(value):
    if not isinstance(value, str) or str(UUID(value)).upper() != value:
        raise ValueError("Invalid UUID")
    return value


def validate_folder_graph(package):
    """Validate a forest without adding defaults to legacy source metadata."""
    folders = package.get("folders")
    if folders is None:
        folders = []
    if not isinstance(folders, list):
        raise ValueError("Invalid folders")
    by_id = {}
    for folder in folders:
        if not isinstance(folder, dict):
            raise ValueError("Invalid folder")
        fid = uuid(folder.get("id"))
        if fid in by_id or not isinstance(folder.get("name"), str) or not folder["name"].strip():
            raise ValueError("Invalid folder")
        if folder.get("parentID") is not None:
            uuid(folder["parentID"])
            if package.get("format") != 3:
                raise ValueError("Nested folders require source format 3")
        by_id[fid] = folder
    complete = set()
    for fid in by_id:
        chain = set()
        while fid is not None and fid not in complete:
            if fid not in by_id:
                raise ValueError("Unknown parent folder")
            if fid in chain:
                raise ValueError("Folder cycle")
            chain.add(fid)
            fid = by_id[fid].get("parentID")
        complete.update(chain)
    for book in package["notebooks"]:
        if book.get("folderID") is not None and book["folderID"] not in by_id:
            raise ValueError("Unknown folder")
    return by_id


def folder_chain(folders, fid):
    """Root-first ancestry from an already validated folder graph."""
    chain = []
    while fid is not None:
        chain.append(folders[fid])
        fid = folders[fid].get("parentID")
    return list(reversed(chain))


def source_format(package, has_assets):
    if any(f.get("parentID") is not None for f in package.get("folders") or []):
        return 3
    return 2 if has_assets else 1


def validate(package):
    if not isinstance(package, dict) or type(package.get("format")) is not int or package.get("format") not in (1, 2, 3):
        raise ValueError("Unsupported package")
    books, blobs = package["notebooks"], package["blobs"]
    if not isinstance(books, list) or not isinstance(blobs, dict):
        raise ValueError("Invalid package")
    folder_ids = validate_folder_graph(package)
    expected, book_ids = set(), set()
    for book in books:
        bid = uuid(book["id"])
        if bid in book_ids or not isinstance(book["name"], str) or not book["pages"]:
            raise ValueError("Invalid notebook")
        if book.get("orientation") not in (None, "portrait", "landscape"):
            raise ValueError("Invalid notebook orientation")
        book_ids.add(bid)
        if book.get("folderID") is not None and book["folderID"] not in folder_ids:
            raise ValueError("Unknown folder")
        for date in (book["created"], book["modified"]):
            if type(date) not in (int, float):
                raise ValueError("Invalid date")
        page_ids = set()
        for page in book["pages"] + book["deleted"]:
            pid = uuid(page["id"])
            if pid in page_ids or page["background"] not in range(4) or type(page["starred"]) is not bool:
                raise ValueError("Invalid page")
            page_ids.add(pid)
            seen = set()
            nodes = {uuid(n["id"]): n for n in page["nodes"]}
            if len(nodes) != len(page["nodes"]) or (page.get("head") is not None and page["head"] not in nodes):
                raise ValueError("Invalid history")
            root = page.get("preferredRoot")
            if root is not None and (root not in nodes or nodes[root].get("parent") is not None):
                raise ValueError("Invalid preferred root")
            for nid, node in nodes.items():
                if "objects" in node:
                    validate_objects(node["objects"])
                parent = node.get("parent")
                if parent is not None and parent not in seen:
                    raise ValueError("History must be parent-first")
                children = node["children"]
                if len(set(children)) != len(children) or any(c not in nodes or nodes[c].get("parent") != nid for c in children):
                    raise ValueError("Invalid children")
                if parent is not None and nid not in nodes[parent]["children"]:
                    raise ValueError("Missing child")
                if node.get("preferredChild") is not None and node["preferredChild"] not in children:
                    raise ValueError("Invalid redo target")
                seen.add(nid)
                key = f"{bid}/{pid}/{nid}"
                if not base64.b64decode(blobs[key], validate=True):
                    raise ValueError("Empty drawing")
                expected.add(key)
        current = book.get("currentPage")
        if current is not None and current not in {p["id"] for p in book["pages"]}:
            raise ValueError("Invalid current page")
    if set(blobs) != expected:
        raise ValueError("Unreferenced or missing snapshots")
    refs = validate_source_assets(package)
    for digest, asset in refs.items():
        validate_asset(base64.b64decode(package["assets"][digest], validate=True), asset)


def validate_current_only(package):
    """Check wire shape before reading/publishing any source objects."""
    if not isinstance(package, dict) or type(package.get("format")) is not int or package.get("format") not in (1, 2, 3):
        raise ValueError("Unsupported package")
    validate_folder_graph(package)
    expected = set()
    for book in package["notebooks"]:
        for page in book["pages"] + book["deleted"]:
            head, nodes = page.get("head"), page["nodes"]
            if not isinstance(nodes, list):
                raise ValueError("Invalid current nodes")
            if head is None:
                if nodes or page.get("preferredRoot") is not None:
                    raise ValueError("Blank page must not retain history")
                continue
            if (len(nodes) != 1 or nodes[0]["id"] != head or
                    nodes[0].get("parent") is not None or nodes[0]["children"] != [] or
                    nodes[0].get("preferredChild") is not None or
                    page.get("preferredRoot") not in (None, head)):
                raise ValueError("Only the normalized current head is accepted")
            expected.add(f'{book["id"]}/{page["id"]}/{head}')
    if set(package["blobs"]) != expected:
        raise ValueError("Unreferenced or missing current snapshots")
    validate_source_assets(package)


def current_projection(package):
    """Project recovery metadata without needing any unused historical bytes."""
    projected = parse_json(canonical(package))
    refs = {}
    for book in projected["notebooks"]:
        for page in book["pages"] + book["deleted"]:
            head = page.get("head")
            if head is None:
                page["nodes"] = []
                page.pop("preferredRoot", None)
                continue
            uuid(head)
            if sum(node["id"] == head for node in page["nodes"]) != 1:
                raise ValueError("Invalid current head")
            objects = next(n for n in page["nodes"] if n["id"] == head).get("objects")
            page["nodes"] = [{"id": head, "children": []}]
            if objects is not None:
                page["nodes"][0]["objects"] = objects
            page["preferredRoot"] = head
            key = f'{book["id"]}/{page["id"]}/{head}'
            refs[key] = projected["blobs"][key]
    projected["blobs"] = refs
    asset_refs = {o["asset"]["sha256"] for b in projected["notebooks"] for p in b["pages"] + b["deleted"] for o in current_objects(p)}
    if asset_refs:
        projected["assets"] = {sha: projected["assets"][sha] for sha in asset_refs}
    else:
        projected.pop("assets", None)
    projected["format"] = source_format(projected, bool(asset_refs))
    validate_current_only(projected)
    return projected


class Database:
    MAGIC = b"DRAW2\0"

    def __init__(self, path):
        self.path = path
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("BEGIN IMMEDIATE")
            db.execute("CREATE TABLE IF NOT EXISTS revisions (revision INTEGER PRIMARY KEY, digest TEXT NOT NULL, package BLOB NOT NULL, created TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
            db.execute("CREATE TABLE IF NOT EXISTS document_sync (document TEXT PRIMARY KEY, synced TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS sync_receipts (sync_id TEXT PRIMARY KEY, body_digest TEXT NOT NULL, receipt BLOB NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS objects (digest TEXT PRIMARY KEY, data BLOB NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS images (revision INTEGER NOT NULL, page TEXT NOT NULL, metadata BLOB NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(revision,page))")
            db.execute("CREATE TABLE IF NOT EXISTS scenes (revision INTEGER NOT NULL, page TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(revision,page))")
            db.execute("CREATE INDEX IF NOT EXISTS scenes_by_page_digest ON scenes(page,digest)")
            # Pending uploads survive failed/concurrent commits for 24 hours.
            db.execute("CREATE TABLE IF NOT EXISTS staged_objects (digest TEXT PRIMARY KEY, uploaded INTEGER NOT NULL DEFAULT 0)")
            if "uploaded" not in {row[1] for row in db.execute("PRAGMA table_info(staged_objects)")}:
                db.execute("ALTER TABLE staged_objects ADD COLUMN uploaded INTEGER NOT NULL DEFAULT 0")
                db.execute("UPDATE staged_objects SET uploaded=CAST(strftime('%s','now') AS INTEGER)")

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=20)
        try:
            db.execute("PRAGMA synchronous=FULL")
            with db:
                yield db
        finally:
            db.close()

    def put_object(self, db, data):
        digest = hashlib.sha256(data).hexdigest()
        if db.execute("SELECT 1 FROM objects WHERE digest=?", (digest,)).fetchone() is None:
            db.execute("INSERT OR IGNORE INTO objects VALUES(?,?)", (digest, zlib.compress(data)))
        return digest

    def pack(self, db, package):
        refs = {key: self.put_object(db, base64.b64decode(data)) for key, data in package["blobs"].items()}
        manifest = {"package": {k: v for k, v in package.items() if k not in ("blobs", "assets")}, "blobs": refs}
        if "assets" in package:
            manifest["assets"] = {key: self.put_object(db, base64.b64decode(data, validate=True)) for key, data in package["assets"].items()}
        return self.MAGIC + zlib.compress(canonical(manifest))

    def unpack(self, db, data, include_blobs=True):
        if not bytes(data).startswith(self.MAGIC):
            package = parse_json(bytes(data))
            if not include_blobs:
                package.pop("blobs")
            return package
        manifest = json.loads(zlib.decompress(bytes(data)[len(self.MAGIC):]))
        package = manifest["package"]
        if include_blobs:
            package["blobs"] = {key: base64.b64encode(self.object(digest, db)).decode()
                                for key, digest in manifest["blobs"].items()}
            if "assets" in manifest:
                package["assets"] = {key: base64.b64encode(self.object(digest, db)).decode() for key, digest in manifest["assets"].items()}
        return package

    def latest(self, revision=None, include_blobs=True, db=None):
        if db is None:
            with self.connect() as connection:
                return self.latest(revision, include_blobs, connection)
        if revision is None:
            row = db.execute("SELECT revision,package FROM revisions ORDER BY revision DESC LIMIT 1").fetchone()
        else:
            row = db.execute("SELECT revision,package FROM revisions WHERE revision=?", (revision,)).fetchone()
        if row:
            return {"revision": row[0], "package": self.unpack(db, row[1], include_blobs)}
        if revision is not None:
            raise LookupError("Revision not found")
        return {"revision": 0, "package": None}

    def object(self, digest, db=None):
        object_digest(digest)
        if db is None:
            with self.connect() as connection:
                return self.object(digest, connection)
        row = db.execute("SELECT data FROM objects WHERE digest=?", (digest,)).fetchone()
        if row is None:
            raise LookupError("Object not found")
        try:
            decoder = zlib.decompressobj()
            data = decoder.decompress(row[0], MAX_OBJECT_BYTES + 1)
        except zlib.error as error:
            raise ValueError("Corrupt stored object") from error
        if (not data or len(data) > MAX_OBJECT_BYTES or not decoder.eof or
                decoder.unused_data or decoder.unconsumed_tail or hashlib.sha256(data).hexdigest() != digest):
            raise ValueError("Corrupt stored object")
        return data

    def upload_object(self, digest, data):
        object_digest(digest)
        if not data or len(data) > MAX_OBJECT_BYTES or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("Invalid object body or checksum")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("INSERT INTO staged_objects(digest,uploaded) VALUES(?,CAST(strftime('%s','now') AS INTEGER)) "
                       "ON CONFLICT(digest) DO UPDATE SET uploaded=excluded.uploaded", (digest,))
            self.put_object(db, data)
        return digest

    def missing_objects(self, digests):
        if not isinstance(digests, list):
            raise ValueError("Invalid digests")
        with self.connect() as db:
            return [digest for digest in dict.fromkeys(object_digest(d) for d in digests)
                    if db.execute("SELECT 1 FROM objects WHERE digest=?", (digest,)).fetchone() is None]

    def manifest_state(self):
        with self.connect() as db:
            row = db.execute("SELECT revision,package FROM revisions ORDER BY revision DESC LIMIT 1").fetchone()
            if row is None:
                return {"revision": 0, "manifest": None}
            return {"revision": row[0], "manifest": self.source_manifest(row[1])}

    def source_manifest(self, data):
        if bytes(data).startswith(self.MAGIC):
            packed = parse_json(zlib.decompress(bytes(data)[len(self.MAGIC):]))
            result = packed["package"] | {"blobs": packed["blobs"]}
            if "assets" in packed:
                result["assets"] = packed["assets"]
            return result
        package = parse_json(bytes(data))
        result = package | {"blobs": {key: hashlib.sha256(base64.b64decode(value, validate=True)).hexdigest()
                                     for key, value in package["blobs"].items()}}
        if "assets" in package:
            result["assets"] = {key: hashlib.sha256(base64.b64decode(value, validate=True)).hexdigest() for key, value in package["assets"].items()}
        return result

    def retain_object_refs(self, db):
        # All stored revisions are protected during staging-only housekeeping.
        # Commit GC first prunes superseded revisions, leaving just current refs.
        refs = set()
        for (data,) in db.execute("SELECT package FROM revisions"):
            manifest = self.source_manifest(data)
            refs.update(manifest["blobs"].values())
            refs.update(manifest.get("assets", {}).values())
        refs.update(r[0] for r in db.execute("SELECT digest FROM images UNION SELECT digest FROM scenes"))
        db.execute("CREATE TEMP TABLE retained_objects (digest TEXT PRIMARY KEY)")
        db.executemany("INSERT INTO retained_objects VALUES(?)", ((digest,) for digest in refs))

    def discard_expired_staging(self):
        """Discard uncommitted uploads after 24h, without migrating source history."""
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            cutoff = db.execute("SELECT CAST(strftime('%s','now') AS INTEGER)-86400").fetchone()[0]
            if db.execute("SELECT 1 FROM staged_objects WHERE uploaded <= ? LIMIT 1", (cutoff,)).fetchone() is None:
                return 0
            self.retain_object_refs(db)
            removed = db.execute("DELETE FROM objects WHERE digest IN "
                                 "(SELECT digest FROM staged_objects WHERE uploaded <= ?) "
                                 "AND digest NOT IN (SELECT digest FROM retained_objects)", (cutoff,)).rowcount
            db.execute("DELETE FROM staged_objects WHERE uploaded <= ?", (cutoff,))
            db.execute("DROP TABLE retained_objects")
        return removed

    def prune_current(self, db, revision, preserve_staging=True):
        """Run only inside the transaction that confirms the latest publication."""
        db.execute("DELETE FROM images WHERE revision != ?", (revision,))
        db.execute("DELETE FROM scenes WHERE revision != ?", (revision,))
        db.execute("DELETE FROM revisions WHERE revision != ?", (revision,))
        self.retain_object_refs(db)
        if preserve_staging:
            db.execute("DELETE FROM staged_objects WHERE digest IN (SELECT digest FROM retained_objects) "
                       "OR uploaded <= CAST(strftime('%s','now') AS INTEGER)-86400")
        else:
            db.execute("DELETE FROM staged_objects")
        db.execute("DELETE FROM objects WHERE digest NOT IN (SELECT digest FROM retained_objects) "
                   "AND digest NOT IN (SELECT digest FROM staged_objects)")
        db.execute("DROP TABLE retained_objects")

    def migrate_current_only(self):
        """Explicit offline maintenance, after verified recovery. Does not VACUUM.

        Keeps the latest revision number unless the source projection changes,
        then publishes N+1. Pending staging is discarded during maintenance.
        """
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT revision,package FROM revisions ORDER BY revision DESC LIMIT 1").fetchone()
            if row is None:
                self.prune_current(db, 0, preserve_staging=False)
                return 0
            previous, stored = row
            if bytes(stored).startswith(self.MAGIC):
                original = self.source_manifest(stored)
                projected = current_projection(original)
                package = projected | {"blobs": {key: base64.b64encode(self.object(digest, db)).decode()
                                                 for key, digest in projected["blobs"].items()}}
            else:
                original = parse_json(bytes(stored))
                package = current_projection(original)
                projected = package
            if "assets" in projected and bytes(stored).startswith(self.MAGIC):
                package["assets"] = {key: base64.b64encode(self.object(digest, db)).decode() for key, digest in projected["assets"].items()}
            validate(package)
            pages = {f'{b["id"]}/{p["id"]}': p for b in package["notebooks"] for p in b["pages"] + b["deleted"]}
            previews, scenes = [], []
            for key, metadata, digest in db.execute("SELECT page,metadata,digest FROM images WHERE revision=?", (previous,)):
                if key in pages and parse_json(metadata).get("head") == pages[key].get("head"):
                    png = self.object(digest, db)
                    validate_images({"notebooks": [{"id": key.split("/")[0], "pages": [pages[key]], "deleted": []}]},
                                    {key: parse_json(metadata) | {"png": base64.b64encode(png).decode()}})
                    previews.append((key, metadata, digest))
            for key, digest in db.execute("SELECT page,digest FROM scenes WHERE revision=?", (previous,)):
                if key in pages:
                    scene = parse_json(self.object(digest, db))
                    if isinstance(scene, dict) and scene.get("head") == pages[key].get("head"):
                        scenes.append((key, digest))
            revision = previous + (canonical(projected) != canonical(original))
            digest = hashlib.sha256(canonical(package)).hexdigest()
            packed = self.pack(db, package)
            if revision != previous:
                db.execute("INSERT INTO revisions(revision,digest,package) VALUES(?,?,?)", (revision, digest, packed))
            else:
                db.execute("UPDATE revisions SET digest=?,package=? WHERE revision=?", (digest, packed, revision))
            db.execute("DELETE FROM images WHERE revision=?", (revision,))
            db.execute("DELETE FROM scenes WHERE revision=?", (revision,))
            db.executemany("INSERT INTO images VALUES(?,?,?,?)", ((revision, *preview) for preview in previews))
            db.executemany("INSERT INTO scenes VALUES(?,?,?)", ((revision, *scene) for scene in scenes))
            self.prune_current(db, revision, preserve_staging=False)
        return revision

    def scene_refs(self, revision, db=None):
        if db is None:
            with self.connect() as connection:
                return self.scene_refs(revision, connection)
        return dict(db.execute("SELECT page,digest FROM scenes WHERE revision=?", (revision,)))

    def _manifest_state(self, db):
        row = db.execute("SELECT revision,package FROM revisions ORDER BY revision DESC LIMIT 1").fetchone()
        return {"revision": row[0], "manifest": self.source_manifest(row[1])} if row else {"revision": 0, "manifest": None}

    def document_manifest(self, manifest, document):
        if manifest is None:
            return None
        book = next((b for b in manifest["notebooks"] if b["id"] == document), None)
        if book is None:
            return None
        folders = validate_folder_graph(manifest)
        required_folders = {f["id"] for f in folder_chain(folders, book.get("folderID"))}
        result = {"format": 1, "notebooks": [book], "blobs": {
            key: digest for key, digest in manifest["blobs"].items() if key.split("/")[0] == document}}
        if required_folders:
            result["folders"] = [f for f in manifest["folders"] or [] if f["id"] in required_folders]
        assets = {o["asset"]["sha256"] for p in book["pages"] + book["deleted"] for o in current_objects(p)}
        if assets:
            result["assets"] = {key: manifest["assets"][key] for key in assets}
        result["format"] = source_format(result, bool(assets))
        # Old readable revisions may contain history; never expose it through
        # the document bridge. Preserve already-normalized root field spelling.
        if any((p.get("head") is None and p["nodes"]) or len(p["nodes"]) > 1 or
               any(n["id"] != p.get("head") or n.get("parent") is not None or n["children"] for n in p["nodes"])
               for p in book["pages"] + book["deleted"]):
            result = current_projection(result)
        return result

    def document_state(self, document, db=None):
        uuid(document)
        if db is None:
            with self.connect() as connection:
                connection.execute("BEGIN")
                return self.document_state(document, connection)
        state = self._manifest_state(db)
        manifest = self.document_manifest(state["manifest"], document)
        row = db.execute("SELECT synced FROM document_sync WHERE document=?", (document,)).fetchone()
        return {"revision": state["revision"], "manifest": manifest,
                "documentDigest": hashlib.sha256(canonical(manifest)).hexdigest() if manifest else None,
                "lastSyncedAt": row[0] if manifest and row else None}

    def document_scene_refs(self, document):
        with self.connect() as db:
            db.execute("BEGIN")
            state = self.document_state(document, db)
            if state["manifest"] is None:
                raise LookupError("Document not found")
            return {"revision": state["revision"], "scenes": {
                key: digest for key, digest in self.scene_refs(state["revision"], db).items()
                if key.split("/")[0] == document}}

    def sync_receipt(self, sync_id, db=None, body_digest=None):
        uuid(sync_id)
        if db is None:
            with self.connect() as connection:
                return self.sync_receipt(sync_id, connection, body_digest)
        row = db.execute("SELECT body_digest,receipt FROM sync_receipts WHERE sync_id=?", (sync_id,)).fetchone()
        if row is None:
            if body_digest is None:
                raise LookupError("Sync receipt not found")
            return None
        if body_digest is not None and not hmac.compare_digest(row[0], body_digest):
            raise Conflict()
        return parse_json(row[1])

    def _stamp_documents(self, db, documents):
        stamp = datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
        db.executemany("INSERT INTO document_sync VALUES(?,?) ON CONFLICT(document) DO UPDATE SET synced=excluded.synced",
                       ((document, stamp) for document in documents))
        return stamp

    def _store_receipt(self, db, sync_id, body_digest, receipt):
        db.execute("INSERT INTO sync_receipts VALUES(?,?,?)", (sync_id, body_digest, canonical(receipt)))

    def commit_manifest(self, base, manifest, scenes, sync_id=None):
        if type(base) is not int or base < 0:
            raise ValueError("Invalid revision")
        body_digest = hashlib.sha256(canonical({"baseRevision": base, "manifest": manifest, "scenes": scenes})).hexdigest()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if sync_id is not None:
                receipt = self.sync_receipt(sync_id, db, body_digest)
                if receipt is not None:
                    return receipt
            revision = self._commit_manifest(db, base, manifest, scenes)
            documents = [b["id"] for b in manifest["notebooks"]]
            stamp = self._stamp_documents(db, documents)
            if sync_id is None:
                return revision
            receipt = {"revision": revision, "syncID": sync_id, "lastSyncedAt": stamp,
                       "documents": {document: self.document_state(document, db)["documentDigest"] for document in documents}}
            self._store_receipt(db, sync_id, body_digest, receipt)
            return receipt

    def commit_document(self, document, sync_id, base_digest, manifest, scenes):
        uuid(document)
        uuid(sync_id)
        if base_digest is not None:
            object_digest(base_digest)
        body_digest = hashlib.sha256(canonical({"documentID": document, "baseDocumentDigest": base_digest,
                                                "manifest": manifest, "scenes": scenes})).hexdigest()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            receipt = self.sync_receipt(sync_id, db, body_digest)
            if receipt is not None:
                return receipt
            current = self.document_state(document, db)
            if current["documentDigest"] != base_digest:
                raise Conflict()
            if not isinstance(manifest, dict) or len(manifest["notebooks"]) != 1 or manifest["notebooks"][0]["id"] != document:
                raise ValueError("Require exactly the requested document")
            validate_current_only(manifest)
            validate_source_assets(manifest, wire=True)
            book = manifest["notebooks"][0]
            folder_registry = validate_folder_graph(manifest)
            required_folders = {f["id"] for f in folder_chain(folder_registry, book.get("folderID"))}
            folders = manifest.get("folders") or []
            if set(folder_registry) != required_folders:
                raise ValueError("Require exactly document folder ancestry")
            required_pages = {f'{document}/{p["id"]}' for p in book["pages"] + book["deleted"]}
            if not isinstance(scenes, dict) or set(scenes) != required_pages:
                raise ValueError("Require all requested document scenes")
            latest = self._manifest_state(db)
            merged = latest["manifest"] or {"format": 1, "notebooks": [], "blobs": {}}
            # Merge refs into the latest server state, never an offline library.
            merged = parse_json(canonical(merged))
            found = any(b["id"] == document for b in merged["notebooks"])
            merged["notebooks"] = [book if b["id"] == document else b for b in merged["notebooks"]]
            if not found:
                merged["notebooks"].append(book)
            merged["blobs"] = {key: digest for key, digest in merged["blobs"].items() if key.split("/")[0] != document} | manifest["blobs"]
            existing_folders = {f["id"]: f for f in merged.get("folders") or []}
            for folder in folders:
                existing = existing_folders.get(folder["id"])
                if existing is not None and (
                        existing.get("parentID") != folder.get("parentID") or
                        {k: v for k, v in existing.items() if k != "parentID"} !=
                        {k: v for k, v in folder.items() if k != "parentID"}):
                    raise Conflict()
                existing_folders.setdefault(folder["id"], folder)
            if any(folder["id"] not in {f["id"] for f in merged.get("folders") or []} for folder in folders):
                merged["folders"] = list(existing_folders.values())
            refs = {o["asset"]["sha256"] for b in merged["notebooks"] for p in b["pages"] + b["deleted"] for o in current_objects(p)}
            if refs:
                assets = merged.get("assets", {}) | manifest.get("assets", {})
                merged["assets"] = {key: assets[key] for key in refs}
            else:
                merged.pop("assets", None)
            merged["format"] = source_format(merged, bool(refs))
            preserved = {f'{b["id"]}/{p["id"]}' for b in merged["notebooks"] if b["id"] != document for p in b["pages"] + b["deleted"]}
            merged_scenes = {key: digest for key, digest in self.scene_refs(latest["revision"], db).items() if key in preserved} | scenes
            revision = self._commit_manifest(db, latest["revision"], merged, merged_scenes, preserved)
            stamp = self._stamp_documents(db, [document])
            receipt = {"revision": revision, "documentDigest": self.document_state(document, db)["documentDigest"],
                       "lastSyncedAt": stamp, "syncID": sync_id, "documentID": document}
            self._store_receipt(db, sync_id, body_digest, receipt)
            return receipt

    def _commit_manifest(self, db, base, manifest, scenes, preserved_pages=()):
        if not isinstance(manifest, dict) or not isinstance(manifest.get("blobs"), dict):
            raise ValueError("Invalid manifest")
        validate_current_only(manifest)
        validate_source_assets(manifest, wire=True)
        if not isinstance(scenes, dict):
            raise ValueError("Invalid scenes")
        # Lazy import keeps legacy serving independent of the portable renderer.
        try:
            from .portable import render_page, RENDERER_VERSION
        except ImportError:
            from portable import render_page, RENDERER_VERSION
        try:
            package = manifest | {"blobs": {key: base64.b64encode(self.object(digest, db)).decode()
                                           for key, digest in manifest["blobs"].items()}}
        except LookupError as error:
            raise ValueError("Missing source object") from error
        if "assets" in manifest:
            try:
                package["assets"] = {key: base64.b64encode(self.object(digest, db)).decode() for key, digest in manifest["assets"].items()}
            except LookupError as error:
                raise ValueError("Missing asset object") from error
        validate(package)
        pages = {f'{b["id"]}/{p["id"]}': p for b in package["notebooks"] for p in b["pages"] + b["deleted"]}
        if set(scenes) - set(pages) or set(pages) - set(scenes) - set(preserved_pages):
            raise ValueError("Missing or unreferenced page scenes")
        for digest in scenes.values():
            object_digest(digest)
        digest = hashlib.sha256(canonical(package)).hexdigest()
        row = db.execute("SELECT revision,digest FROM revisions ORDER BY revision DESC LIMIT 1").fetchone()
        revision = row[0] if row else 0
        same = row and hmac.compare_digest(row[1], digest)
        prior_scenes = dict(db.execute("SELECT page,digest FROM scenes WHERE revision=?", (revision,)))
        if base != revision and (not same or (prior_scenes and prior_scenes != scenes)):
            raise Conflict()
        previews = {key: (metadata, image_digest) for key, metadata, image_digest in
                    db.execute("SELECT page,metadata,digest FROM images WHERE revision=?", (revision,)) if key in preserved_pages}
        for key, scene_digest in scenes.items():
            if key in preserved_pages:
                continue
            try:
                scene = parse_json(self.object(scene_digest, db))
            except LookupError as error:
                raise ValueError("Missing scene object") from error
            if not isinstance(scene, dict) or scene.get("head") != pages[key].get("head"):
                raise ValueError("Scene does not match page head")
            if scene.get("objects", []) != current_objects(pages[key]):
                raise ValueError("Scene objects do not match current head")
            if "background" in scene and scene["background"] != pages[key]["background"]:
                raise ValueError("Scene paper does not match page")
            cached = db.execute("SELECT images.metadata,images.digest FROM scenes JOIN images "
                                "ON scenes.revision=images.revision AND scenes.page=images.page "
                                "WHERE scenes.revision=? AND scenes.page=? AND scenes.digest=?",
                                (revision, key, scene_digest))
            match = next(((metadata, image_digest) for metadata, image_digest in cached
                          if json.loads(metadata).get("rendererVersion") == RENDERER_VERSION
                          and json.loads(metadata).get("head") == pages[key].get("head")), None)
            if match is not None:
                previews[key] = match
                continue
            try:
                if current_objects(pages[key]):
                    metadata, png = render_page(scene, {o["asset"]["sha256"]: self.object(o["asset"]["sha256"], db) for o in current_objects(pages[key])})
                else:
                    metadata, png = render_page(scene)
            except Exception as error:
                raise RenderFailure() from error
            # Reuse existing image checks without changing the legacy metadata contract.
            checked = validate_images({"notebooks": [{"id": key.split("/")[0], "pages": [pages[key]], "deleted": []}]},
                                      {key: metadata | {"png": base64.b64encode(png).decode()}})
            metadata, png = checked[key]
            if len(png) > MAX_OBJECT_BYTES:
                raise ValueError("Rendered PNG exceeds object size limit")
            if metadata.get("rendererVersion") != RENDERER_VERSION:
                raise ValueError("Invalid renderer version")
            previews[key] = (canonical(metadata), self.put_object(db, png))
        if not same:
            revision += 1
            db.execute("INSERT INTO revisions(revision,digest,package) VALUES(?,?,?)", (revision, digest, self.pack(db, package)))
        for key, (metadata, image_digest) in previews.items():
            db.execute("INSERT OR REPLACE INTO images VALUES(?,?,?,?)", (revision, key, metadata, image_digest))
        for key, scene_digest in scenes.items():
            db.execute("INSERT OR REPLACE INTO scenes VALUES(?,?,?)", (revision, key, scene_digest))
        self.prune_current(db, revision)
        return revision

    def commit(self, base, package, images=None):
        validate_current_only(package)
        if package.get("format") == 2 or any(current_objects(p) for b in package["notebooks"] for p in b["pages"] + b["deleted"]):
            raise ValueError("AI objects require verified portable scenes via v2")
        validate(package)
        previews = validate_images(package, images) if images is not None else None
        digest = hashlib.sha256(canonical(package)).hexdigest()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT revision,digest FROM revisions ORDER BY revision DESC LIMIT 1").fetchone()
            revision = row[0] if row else 0
            same = row and hmac.compare_digest(row[1], digest)
            if not same:
                if base != revision:
                    raise Conflict()
                revision += 1
                db.execute("INSERT INTO revisions(revision,digest,package) VALUES(?,?,?)", (revision, digest, self.pack(db, package)))
            # Images and notes become visible together. Identical retries may
            # supply missing cached images without creating a new note revision.
            if previews is not None:
                for key, (metadata, png) in previews.items():
                    # A v1 PNG is not verified against retained portable scenes.
                    # Only server renders may claim portable cache provenance.
                    metadata.pop("rendererVersion", None)
                    image_digest = self.put_object(db, png)
                    db.execute("INSERT OR REPLACE INTO images VALUES(?,?,?,?)", (revision, key, canonical(metadata), image_digest))
            self.prune_current(db, revision)
            self._stamp_documents(db, [b["id"] for b in package["notebooks"]])
        return revision

    def image_metadata(self, revision, db=None):
        if db is None:
            with self.connect() as connection:
                return self.image_metadata(revision, connection)
        return {key: json.loads(data) for key, data in db.execute("SELECT page,metadata FROM images WHERE revision=?", (revision,))}

    def image(self, revision, key, db=None):
        if db is None:
            with self.connect() as connection:
                return self.image(revision, key, connection)
        row = db.execute("SELECT digest FROM images WHERE revision=? AND page=?", (revision, key)).fetchone()
        if not row:
            raise LookupError("No image for this revision; Sync from the updated iPad app")
        return self.object(row[0], db)


def validate_images(package, images):
    expected = {f'{b["id"]}/{p["id"]}': p for b in package["notebooks"] for p in b["pages"] + b["deleted"]}
    if not isinstance(images, dict) or set(images) != set(expected):
        raise ValueError("Missing or unreferenced page images")
    result = {}
    for key, image in images.items():
        page = expected[key]
        if image.get("head") != page.get("head"):
            raise ValueError("Image does not match page head")
        for field in ("width", "height"):
            if type(image[field]) is not int or not 0 < image[field] <= 8192:
                raise ValueError("Invalid image dimensions")
        if type(image["strokeCount"]) is not int or image["strokeCount"] < 0 or not isinstance(image["inkTypes"], list) or not all(isinstance(i, str) for i in image["inkTypes"]):
            raise ValueError("Invalid ink metadata")
        tags = image.get("tagStrokeCounts")
        known_tags = ("question",) if type(image.get("rendererVersion")) is int and image["rendererVersion"] >= 3 else ("question", "missed")
        if tags is not None and (not isinstance(tags, dict) or any(
                tag not in known_tags or type(count) is not int or not 0 < count <= image["strokeCount"]
                for tag, count in tags.items())):
            raise ValueError("Invalid tag stroke counts")
        png = base64.b64decode(image["png"], validate=True)
        if len(png) < 33 or png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR" or struct.unpack(">II", png[16:24]) != (image["width"], image["height"]):
            raise ValueError("Invalid PNG header")
        offset, saw_data, ended = 8, False, False
        while offset < len(png):
            if offset + 12 > len(png):
                raise ValueError("Truncated PNG")
            length = struct.unpack(">I", png[offset:offset + 4])[0]
            end = offset + 12 + length
            if end > len(png):
                raise ValueError("Truncated PNG chunk")
            kind = png[offset + 4:offset + 8]
            payload = png[offset + 4:end - 4]
            if zlib.crc32(payload) != struct.unpack(">I", png[end - 4:end])[0]:
                raise ValueError("PNG checksum mismatch")
            saw_data |= kind == b"IDAT"
            if kind == b"IEND":
                ended = length == 0 and end == len(png)
                break
            offset = end
        if not ended or not saw_data:
            raise ValueError("Incomplete PNG")
        result[key] = ({k: v for k, v in image.items() if k != "png"}, png)
    return result


class Conflict(Exception):
    pass


class BodyTooLarge(Exception):
    pass


class RenderFailure(Exception):
    pass


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Do not log credentials, document payloads or URL query strings.
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def reply(self, status, data):
        self.reply_bytes(status, canonical(data), "application/json")

    def reply_bytes(self, status, body, content_type):
        # Honor an explicit gzip refusal even when a wildcard is present.
        accepted = {}
        for item in self.headers.get("Accept-Encoding", "").split(","):
            parts = item.strip().lower().split(";")
            try:
                quality = float(parts[1].strip().removeprefix("q=")) if len(parts) == 2 else 1.0
            except ValueError:
                quality = 0.0
            accepted[parts[0]] = quality
        compressed = accepted.get("gzip", accepted.get("*", 0)) > 0
        if compressed:
            body = gzip.compress(body, mtime=0)
        self.send_response(status)
        self.send_header("Vary", "Accept-Encoding")
        if compressed:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def error(self, status, code, message):
        self.reply(status, {"error": {"code": code, "message": message}})

    def document_route(self):
        path = urlsplit(self.path).path.removeprefix("/draw-sync")
        return path.startswith("/v2/documents/") or path.startswith("/v2/sync-receipts/")

    def authorized(self):
        if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + self.server.token):
            if self.document_route():
                self.error(401, "unauthorized", "Unauthorized")
            else:
                self.reply(401, {"error": "Unauthorized"})
            return False
        return True

    def route(self):
        url = urlsplit(self.path)
        return url.path.removeprefix("/draw-sync"), parse_qs(url.query, strict_parsing=True)

    def do_GET(self):
        if not self.authorized():
            return
        try:
            path, query = self.route()
            parts = path.strip("/").split("/")
            if parts[:2] == ["v2", "documents"] and len(parts) == 4:
                if query:
                    raise ValueError("Document state is current-only")
                document = uuid(parts[2])
                if parts[3] == "state":
                    self.reply(200, self.server.database.document_state(document))
                    return
                if parts[3] == "scenes":
                    self.reply(200, self.server.database.document_scene_refs(document))
                    return
            if parts[:2] == ["v2", "sync-receipts"] and len(parts) == 3:
                if query:
                    raise ValueError("Invalid receipt query")
                self.reply(200, self.server.database.sync_receipt(parts[2]))
                return
            if path == "/v2/state":
                self.reply(200, self.server.database.manifest_state())
                return
            if path.startswith("/v2/objects/"):
                digest = object_digest(path.removeprefix("/v2/objects/"))
                self.reply_bytes(200, self.server.database.object(digest), "application/octet-stream")
                return
            if path == "/v1/state":
                self.reply(200, self.server.database.latest())
                return
            parts = path.strip("/").split("/")
            if parts[:2] not in (["v1", "documents"], ["v1", "folders"]):
                raise LookupError("Not found")
            revision = int(query["revision"][0]) if "revision" in query else None
            state = self.server.database.latest(revision, include_blobs=False)
            revision = state["revision"]
            books = state["package"]["notebooks"] if state["package"] else []
            images = self.server.database.image_metadata(revision)
            registry = validate_folder_graph(state["package"]) if state["package"] else {}
            def path_fields(fid):
                chain = folder_chain(registry, fid)
                return {"pathIDs": [f["id"] for f in chain], "fullPath": "/".join(f["name"] for f in chain)}
            def summary(book):
                ancestry = path_fields(book.get("folderID"))
                return {k: book[k] for k in ("id", "name", "created", "modified")} | {"pageCount": len(book["pages"]), "deletedPageCount": len(book["deleted"]), "folderID": book.get("folderID"), "folderPath": ancestry["fullPath"], "folderPathIDs": ancestry["pathIDs"], "orientation": book.get("orientation") or "portrait", "lastSyncedAt": self.server.database.document_state(book["id"])["lastSyncedAt"]}
            folders = [f | {"parentID": f.get("parentID"), "documentCount": sum(b.get("folderID") == f["id"] for b in books)} | path_fields(f["id"]) for f in registry.values()]
            if parts[:2] == ["v1", "folders"]:
                if len(parts) == 2:
                    self.reply(200, {"revision": revision, "folders": folders})
                    return
                if len(parts) == 3:
                    fid = uuid(parts[2])
                    folder = next((f for f in folders if f["id"] == fid), None)
                    if folder is None:
                        raise LookupError("Folder not found")
                    self.reply(200, {"revision": revision, "folder": folder,
                        "ancestors": [next(f for f in folders if f["id"] == ancestor) for ancestor in folder["pathIDs"][:-1]],
                        "children": [f for f in folders if f["parentID"] == fid],
                        "documents": [summary(b) for b in books if b.get("folderID") == fid]})
                    return
                raise LookupError("Not found")
            def page_info(book, page, number, deleted=False):
                key = f'{book["id"]}/{page["id"]}'
                image = images.get(key)
                return {"id": page["id"], "number": number, "deleted": deleted,
                        "paper": ["blank", "dots", "lines", "grid"][page["background"]],
                        "starred": page["starred"], "head": page.get("head"), "historyCount": len(page["nodes"]),
                        "tags": list(image["tagStrokeCounts"]) if image and image.get("tagStrokeCounts") is not None else None,
                        "image": image, "imagePaper": ["blank", "dots", "lines", "grid"][image.get("background", 2)] if image else None,
                        "png": f'/draw-sync/v1/documents/{book["id"]}/pages/{page["id"]}.png?revision={revision}' if image else None}
            if len(parts) == 2:
                self.reply(200, {"revision": revision, "documents": [summary(b) for b in books], "folders": folders})
                return
            bid = uuid(parts[2])
            book = next((b for b in books if b["id"] == bid), None)
            if book is None:
                raise LookupError("Document not found")
            if len(parts) == 3:
                self.reply(200, {"revision": revision, "document": summary(book),
                    "pages": [page_info(book, p, i + 1) for i, p in enumerate(book["pages"])],
                    "deleted": [page_info(book, p, i + 1, True) for i, p in enumerate(book["deleted"])]})
                return
            if len(parts) == 5 and parts[3] == "pages" and parts[4].endswith(".png"):
                pid = uuid(parts[4][:-4])
                if not any(p["id"] == pid for p in book["pages"] + book["deleted"]):
                    raise LookupError("Page not found")
                self.reply_bytes(200, self.server.database.image(revision, f"{bid}/{pid}"), "image/png")
                return
            if len(parts) == 4 and parts[3] == "pages.zip":
                start = int(query.get("start", ["1"])[0])
                end = int(query.get("end", [str(len(book["pages"]))])[0])
                if not 1 <= start <= end <= len(book["pages"]):
                    raise ValueError("Invalid inclusive 1-based page span")
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED) as archive:
                    for number in range(start, end + 1):
                        page = book["pages"][number - 1]
                        archive.writestr(f'{number:04}-{page["id"]}.png', self.server.database.image(revision, f'{bid}/{page["id"]}'))
                self.reply_bytes(200, buffer.getvalue(), "application/zip")
                return
            raise LookupError("Not found")
        except LookupError as error:
            if self.document_route():
                self.error(404, "not_found", str(error))
            else:
                self.reply(404, {"error": str(error)})
        except (ValueError, TypeError, KeyError):
            if self.document_route():
                self.error(422, "invalid_request", "Invalid request")
            else:
                self.reply(400, {"error": "Invalid request"})
        except sqlite3.Error:
            if self.document_route():
                self.error(503, "storage_unavailable", "Storage unavailable")
            else:
                self.reply(503, {"error": "Storage unavailable"})

    def request_body(self, limit):
        if self.headers.get("Transfer-Encoding") is not None:
            raise ValueError("Unsupported transfer encoding")
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) != 1 or re.fullmatch(r"[0-9]+", lengths[0]) is None:
            raise ValueError("Missing or duplicate body length")
        length = int(lengths[0])
        if length <= 0:
            raise ValueError("Empty body")
        if length > limit:
            raise BodyTooLarge()
        data = self.rfile.read(length)
        if len(data) != length:
            raise ValueError("Incomplete body")
        encodings = self.headers.get_all("Content-Encoding", [])
        if len(encodings) > 1:
            raise ValueError("Duplicate content encoding")
        encoding = encodings[0].strip().lower() if encodings else ""
        return decode_body(data, encoding, limit)

    def do_POST(self):
        if not self.authorized():
            return
        try:
            path, query = self.route()
            if query:
                raise LookupError("Not found")
            parts = path.strip("/").split("/")
            if parts[:2] == ["v2", "documents"] and len(parts) == 4 and parts[3] == "state":
                request = parse_json(self.request_body(MAX_METADATA_BYTES))
                if set(request) != {"syncID", "baseDocumentDigest", "manifest", "scenes"}:
                    raise ValueError("Invalid document request fields")
                receipt = self.server.database.commit_document(uuid(parts[2]), request["syncID"],
                    request["baseDocumentDigest"], request["manifest"], request["scenes"])
                self.reply(200, receipt)
                return
            if path == "/v2/objects/missing":
                request = parse_json(self.request_body(MAX_METADATA_BYTES))
                self.reply(200, {"missing": self.server.database.missing_objects(request["digests"])})
                return
            if path.startswith("/v2/objects/"):
                digest = object_digest(path.removeprefix("/v2/objects/"))
                self.server.database.upload_object(digest, self.request_body(MAX_OBJECT_BYTES))
                self.reply(200, {"digest": digest})
                return
            if path not in ("/v1/state", "/v2/state"):
                raise LookupError("Not found")
            request = parse_json(self.request_body(MAX_BYTES if path == "/v1/state" else MAX_METADATA_BYTES))
            if type(request["baseRevision"]) is not int or request["baseRevision"] < 0:
                raise ValueError("Invalid revision")
            if path == "/v2/state":
                if set(request) - {"baseRevision", "manifest", "scenes", "syncID"}:
                    raise ValueError("Invalid commit fields")
                if "images" in request:
                    raise ValueError("Client images are not accepted in v2")
                revision = self.server.database.commit_manifest(request["baseRevision"], request["manifest"], request["scenes"], request.get("syncID"))
            else:
                revision = self.server.database.commit(request["baseRevision"], request["package"], request.get("images"))
            self.reply(200, revision if isinstance(revision, dict) else {"revision": revision})
        except Conflict:
            if self.document_route():
                self.error(409, "conflict", "Conflict: neither copy was overwritten")
            else:
                self.reply(409, {"error": "Conflict: neither copy was overwritten"})
        except BodyTooLarge:
            if self.document_route():
                self.error(413, "limit", "Body exceeds size limit")
            else:
                self.reply(413, {"error": "Body exceeds size limit"})
        except LookupError:
            if self.document_route():
                self.error(404, "not_found", "Not found")
            else:
                self.reply(404, {"error": "Not found"})
        except (ValueError, KeyError, TypeError, AttributeError, RecursionError, TimeoutError):
            if self.document_route():
                self.error(422, "invalid_package", "Invalid sync package")
            else:
                self.reply(400, {"error": "Invalid sync package"})
        except RenderFailure as error:
            if self.document_route():
                if isinstance(error.__cause__, (ValueError, KeyError, TypeError)):
                    self.error(422, "invalid_scene", "Invalid portable scene")
                else:
                    self.error(503, "renderer_unavailable", "Renderer unavailable")
            else:
                self.reply(503, {"error": "Storage or renderer unavailable"})
        except (sqlite3.Error, ImportError):
            if self.document_route():
                self.error(503, "unavailable", "Storage or renderer unavailable")
            else:
                self.reply(503, {"error": "Storage or renderer unavailable"})


def make_server(path, token, port=18874):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.database = Database(path)
    server.token = token
    return server


if __name__ == "__main__":
    os.umask(0o077)
    state = Path(os.environ["DRAW_SYNC_STATE"])
    state.mkdir(parents=True, exist_ok=True)
    token = (state / "token").read_text().strip()
    if len(token) < 32:
        raise SystemExit("Missing sync token")
    make_server(state / "sync.sqlite3", token).serve_forever()
