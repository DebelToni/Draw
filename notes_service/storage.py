"""Private durable request authority and immutable exact-byte artifacts."""
import hashlib
import json
import os
import re
import sqlite3
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

MAX_METADATA = 4 * 1024 * 1024
MAX_ASSET = 128 * 1024 * 1024


class Problem(Exception):
    def __init__(self, code, message, status=422):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


def require(condition, code, message, status=422):
    if not condition:
        raise Problem(code, message, status)


def uuid(value):
    try:
        require(isinstance(value, str) and str(UUID(value)).upper() == value,
                "invalid_uuid", "Expected uppercase UUID")
    except (ValueError, AttributeError):
        raise Problem("invalid_uuid", "Expected uppercase UUID") from None
    return value


def sha(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value),
            "invalid_digest", "Expected lowercase SHA256")
    return value


def utc():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).encode()


def decoded(data, limit=MAX_METADATA):
    require(len(data) <= limit, "metadata_limit", "Metadata exceeds size limit", 413)
    def pairs(items):
        result = {}
        for k, v in items:
            require(k not in result, "invalid_json", "Duplicate JSON key")
            result[k] = v
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except RecursionError:
        raise Problem("metadata_limit", "JSON nesting exceeds limit", 413) from None
    except (ValueError, UnicodeDecodeError):
        raise Problem("invalid_json", "Invalid JSON") from None


def atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".stage-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Store:
    def __init__(self, root, clock=time.time):
        self.clock = clock
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        self.cas = self.root / "artifacts"
        self.cas.mkdir(exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.root / "notes.sqlite3")
        os.chmod(self.root / "notes.sqlite3", 0o600)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, doc TEXT NOT NULL, status TEXT NOT NULL, data BLOB NOT NULL)")
        self.db.execute("CREATE TABLE IF NOT EXISTS records (kind TEXT NOT NULL, id TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(kind,id))")
        self.db.execute("CREATE TABLE IF NOT EXISTS artifacts (sha TEXT PRIMARY KEY, staged_until REAL NOT NULL)")
        self.db.commit()

    def close(self):
        self.db.close()

    def path(self, digest):
        return self.cas / sha(digest)

    def read_asset(self, digest):
        try:
            data = self.path(digest).read_bytes()
        except FileNotFoundError:
            raise Problem("missing_asset", "Referenced artifact is missing", 422) from None
        require(hashlib.sha256(data).hexdigest() == digest, "asset_integrity", "Artifact checksum mismatch")
        return data

    def put_asset(self, digest, data):
        sha(digest)
        require(len(data) <= MAX_ASSET, "asset_limit", "Artifact exceeds 128 MiB", 413)
        require(hashlib.sha256(data).hexdigest() == digest, "asset_integrity", "Artifact checksum mismatch")
        from .validation import artifact
        artifact(data)
        path = self.path(digest)
        if path.exists():
            require(self.read_asset(digest) == data, "asset_collision", "Immutable artifact collision", 409)
        else:
            atomic(path, data)
        self.stage([digest])
        return digest

    def put_bytes(self, data):
        return self.put_asset(hashlib.sha256(data).hexdigest(), data)

    def stage(self, digests):
        # Upload/missing handshake protects reused assets until request publication, at most one hour.
        for digest in digests:
            self.db.execute("INSERT INTO artifacts VALUES(?,?) ON CONFLICT(sha) DO UPDATE SET staged_until=excluded.staged_until",
                            (sha(digest), self.clock()+3600))
        self.db.commit()

    def pin(self, digests):
        # Live request roots and upload deadlines are independent; another upload may share this SHA.
        for digest in digests:
            self.db.execute("INSERT INTO artifacts VALUES(?,0) ON CONFLICT(sha) DO NOTHING", (sha(digest),))
        self.db.commit()

    def collect(self, live):
        live = set(live)
        staged = {row[0] for row in self.db.execute("SELECT sha FROM artifacts WHERE staged_until>?", (self.clock(),))}
        retained = live | staged
        inventory = list(self.cas.iterdir())
        for path in inventory:
            require(path.is_file() and not path.is_symlink(), "artifact_inventory", "Unsafe CAS inventory; collection stopped", 409)
            sha(path.name)
        # Complete inventory and readable verified retained roots precede deletion.
        for digest in retained:
            self.read_asset(digest)
        removed = []
        for path in inventory:
            if path.name not in retained:
                path.unlink()
                self.db.execute("DELETE FROM artifacts WHERE sha=?", (path.name,))
                removed.append(path.name)
        for (digest,) in self.db.execute("SELECT sha FROM artifacts").fetchall():
            if digest not in retained:
                self.db.execute("DELETE FROM artifacts WHERE sha=?", (digest,))
        self.db.commit()
        return removed

    def request(self, request_id):
        row = self.db.execute("SELECT data FROM requests WHERE id=?", (uuid(request_id),)).fetchone()
        require(row is not None, "not_found", "Request not found", 404)
        return json.loads(row[0])

    def requests(self, doc=None, statuses=None):
        rows = self.db.execute("SELECT data FROM requests" + (" WHERE doc=?" if doc else ""),
                               (doc,) if doc else ()).fetchall()
        return [r for row in rows if (r := json.loads(row[0])) and
                (statuses is None or r["status"] in statuses)]

    def save_request(self, r):
        self.db.execute("INSERT INTO requests VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status,data=excluded.data",
                        (r["requestID"], r["documentID"], r["status"], encoded(r)))
        self.db.commit()

    def record(self, kind, key, default=None):
        row = self.db.execute("SELECT data FROM records WHERE kind=? AND id=?", (kind, key)).fetchone()
        return json.loads(row[0]) if row else default

    def records(self, kind):
        return [json.loads(row[0]) for row in self.db.execute("SELECT data FROM records WHERE kind=?", (kind,))]

    def save_record(self, kind, key, data):
        self.db.execute("INSERT INTO records VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET data=excluded.data", (kind, key, encoded(data)))
        self.db.commit()
