"""Export immutable Draw data to a private Git repository; never copy live SQLite."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
from server import Database, canonical, validate_current_only, validate, validate_folder_graph
from ai_models import validate_source_assets, validate_asset


def write_object(file, data):
    if file.exists():
        if file.read_bytes() != data:
            raise ValueError("Backup object checksum mismatch")
        return
    temporary = file.with_suffix(file.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(file)


def export(database, root):
    # Scene/image refreshes may reuse a source revision. Pin every read, not
    # just the revision number, to one WAL snapshot while writers keep syncing.
    with database.connect() as db:
        db.execute("BEGIN")
        state = database.latest(db=db)
        if state["package"] is None:
            return False
        validate_current_only(state["package"])
        validate(state["package"])
        root = Path(root)
        objects = root / "objects"
        objects.mkdir(parents=True, exist_ok=True)
        package = state["package"]
        refs = {}
        for key, encoded in package["blobs"].items():
            data = base64.b64decode(encoded)
            name = hashlib.sha256(data).hexdigest() + ".pkdraw"
            file = objects / name
            write_object(file, data)
            refs[key] = "objects/" + name
        assets = {}
        for digest, encoded in package.get("assets", {}).items():
            name = digest + ".png"
            write_object(objects / name, base64.b64decode(encoded, validate=True))
            assets[digest] = "objects/" + name
        previews = {}
        for key, metadata in database.image_metadata(state["revision"], db=db).items():
            png = database.image(state["revision"], key, db=db)
            name = hashlib.sha256(png).hexdigest() + ".png"
            file = objects / name
            write_object(file, png)
            previews[key] = metadata | {"file": "objects/" + name, "paper": ["blank", "dots", "lines", "grid"][metadata.get("background", 2)]}
        manifest = {"backupFormat": 1, "revision": state["revision"],
                    "package": {k: v for k, v in package.items() if k not in ("blobs", "assets")},
                    "blobs": refs, "images": previews}
        if "assets" in package:
            manifest["assets"] = assets
        scenes = {}
        for key, digest in database.scene_refs(state["revision"], db=db).items():
            name = digest + ".json"
            write_object(objects / name, database.object(digest, db=db))
            scenes[key] = "objects/" + name
        if scenes:
            manifest["scenes"] = scenes
        data = canonical(manifest) + b"\n"
        target = root / "manifest.json"
        changed = not target.exists() or target.read_bytes() != data
        if changed:
            temporary = root / "manifest.json.tmp"
            temporary.write_bytes(data)
            temporary.replace(target)
        # Publish the manifest before removing superseded working-tree files.
        # Git publication subsequently replaces history with a parentless root.
        retained = set(refs.values()) | {p["file"] for p in previews.values()} | set(scenes.values()) | set(assets.values())
        for file in objects.iterdir():
            if file.is_file() and "objects/" + file.name not in retained:
                file.unlink()
                changed = True
        return changed


def restore_package(root):
    root = Path(root)
    manifest = json.loads((root / "manifest.json").read_bytes())
    package = manifest["package"]
    blobs = {}
    for key, relative in manifest["blobs"].items():
        path = Path(relative)
        if path.parent != Path("objects") or path.suffix != ".pkdraw":
            raise ValueError("Invalid backup path")
        data = (root / path).read_bytes()
        if hashlib.sha256(data).hexdigest() != path.stem:
            raise ValueError("Backup checksum mismatch")
        blobs[key] = base64.b64encode(data).decode()
    package["blobs"] = blobs
    if "assets" in manifest:
        package["assets"] = {}
        for digest, relative in manifest["assets"].items():
            path = Path(relative)
            if path.parent != Path("objects") or path.name != digest + ".png":
                raise ValueError("Invalid asset backup path")
            data = (root / path).read_bytes()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError("Backup asset checksum mismatch")
            package["assets"][digest] = base64.b64encode(data).decode()
        for digest, descriptor in validate_source_assets(package).items():
            validate_asset(base64.b64decode(package["assets"][digest], validate=True), descriptor)
    validate_folder_graph(package)
    return package


def restore_scenes(root):
    """Read optional exact portable records; old backups return an empty map."""
    root = Path(root)
    manifest = json.loads((root / "manifest.json").read_bytes())
    scenes = {}
    for key, relative in manifest.get("scenes", {}).items():
        path = Path(relative)
        if path.parent != Path("objects") or path.suffix != ".json":
            raise ValueError("Invalid scene backup path")
        data = (root / path).read_bytes()
        if hashlib.sha256(data).hexdigest() != path.stem:
            raise ValueError("Backup checksum mismatch")
        scenes[key] = data
    return scenes


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.STDOUT).decode().strip()


def remote_main(root):
    refs = [line.split() for line in git(root, "ls-remote", "--refs", "origin").splitlines()]
    if any(len(row) != 2 or row[1] != "refs/heads/main" for row in refs) or len(refs) > 1:
        raise ValueError("Backup remote must contain only main, without tags or other refs")
    return refs[0][0] if refs else None


def publish_current(root):
    """Publish a Draw-data root commit; return its OID. Requires one writer.

    Previous remote refs/objects survive failure. Local pruning happens only
    after remote main is verified. Hosting-provider physical GC is separate;
    this guarantees one reachable commit, not immediate remote byte erasure.
    """
    root = Path(root)
    manifest = json.loads((root / "manifest.json").read_bytes())
    package = restore_package(root)
    validate_current_only(package)
    validate(package)
    restore_scenes(root)
    files = {"manifest.json"} | set(manifest["blobs"].values()) | set(manifest.get("scenes", {}).values()) | set(manifest.get("assets", {}).values())
    for image in manifest["images"].values():
        path = Path(image["file"])
        if path.parent != Path("objects") or path.suffix != ".png":
            raise ValueError("Invalid image backup path")
        if hashlib.sha256((root / path).read_bytes()).hexdigest() != path.stem:
            raise ValueError("Backup checksum mismatch")
        files.add(image["file"])
    if git(root, "symbolic-ref", "HEAD") != "refs/heads/main":
        raise ValueError("Backup checkout must be on main")
    refs = dict(line.split() for line in git(root, "for-each-ref", "--format=%(refname) %(objectname)").splitlines())
    if set(refs) - {"refs/heads/main", "refs/remotes/origin/main", "refs/remotes/origin/HEAD"}:
        raise ValueError("Backup checkout has unexpected refs")
    if "refs/remotes/origin/HEAD" in refs and git(root, "symbolic-ref", "refs/remotes/origin/HEAD") != "refs/remotes/origin/main":
        raise ValueError("Unexpected origin HEAD")
    expected = remote_main(root)
    if expected != refs.get("refs/remotes/origin/main"):
        raise ValueError("Remote main differs from origin/main; explicit recovery required")
    # Refuse code checkouts and unrelated staged files; preserve exactly the
    # optional tracked backup documentation alongside current data.
    git(root, "add", "--all", "--", "manifest.json", "objects")
    tracked = set(git(root, "ls-files").splitlines())
    if tracked - {"README.md", ".gitignore"} != files:
        raise ValueError("Backup checkout contains unexpected tracked files")
    tree = git(root, "write-tree")
    head = refs.get("refs/heads/main")
    if (head is None or git(root, "rev-parse", head + "^{tree}") != tree or
            len(git(root, "rev-list", "--parents", "-n", "1", head).split()) != 1):
        # No -p: ordinary publication replaces history, including one-time
        # cleanup of a previously cumulative backup with an unchanged tree.
        new_head = git(root, "commit-tree", tree, "-m", "Back up current Draw library")
        git(root, "update-ref", "-m", "Publish current Draw backup", "refs/heads/main", new_head, head or "")
        head = new_head
    if head != expected:
        git(root, "-c", "gc.auto=0", "push", "--force-with-lease=refs/heads/main:" + (expected or ""),
            "origin", head + ":refs/heads/main")
    # A successful push with a failed verification retains recovery objects.
    # Equal refs also allow retrying cleanup after a previously interrupted job.
    if remote_main(root) != head:
        raise ValueError("Published backup could not be verified")
    git(root, "update-ref", "refs/remotes/origin/main", head)
    git(root, "reflog", "expire", "--expire=all", "--expire-unreachable=all", "--all")
    git(root, "gc", "--prune=now")
    return head


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--restore-package", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.restore_package:
        if args.output is None:
            parser.error("--output is required (avoid printing personal notes)")
        args.output.write_bytes(canonical(restore_package(args.restore_package)))
        return
    os.umask(0o077)
    root = Path(os.environ["DRAW_SYNC_BACKUP_REPO"])
    if not (root / ".git").exists():
        raise SystemExit("Backup checkout missing")
    database = Database(Path(os.environ["DRAW_SYNC_STATE"]) / "sync.sqlite3")
    database.discard_expired_staging()
    export(database, root)
    # Includes retries of a failed publication even when export is unchanged.
    publish_current(root)
    print("Draw GitHub backup up to date")


if __name__ == "__main__":
    main()
