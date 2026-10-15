"""Latest-only Git publication against local, disposable bare remotes."""
import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import backup
from backup import export, git, publish_current, restore_package
from server import Database, canonical
from test_incremental import renderer, scene, sha
from test_server import package


class BackupGitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "Draw-data"
        self.remote = Path(self.temp.name) / "remote.git"
        self.root.mkdir()
        self.environment = patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"})
        self.environment.start()
        git(self.root, "init", "--initial-branch=main")
        git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.identity(self.root)
        git(self.root, "remote", "add", "origin", str(self.remote))
        self.db = Database(Path(self.temp.name) / "sync.sqlite3")
        self.p = package()
        self.render_context = renderer()
        self.render_context.__enter__()

    def tearDown(self):
        self.render_context.__exit__(None, None, None)
        self.environment.stop()
        self.temp.cleanup()

    def identity(self, root):
        git(root, "config", "user.name", "Temporary Draw test")
        git(root, "config", "user.email", "draw-test@example.invalid")

    def next_backup(self, number):
        p = copy.deepcopy(self.p)
        native = f"current native archive {number}".encode()
        p["blobs"] = {key: base64.b64encode(native).decode() for key in p["blobs"]}
        source_digest = self.db.upload_object(sha(native), native)
        portable = canonical(scene(p["notebooks"][0]["pages"][0], width=30 + number))
        scene_digest = self.db.upload_object(sha(portable), portable)
        manifest = p | {"blobs": {key: source_digest for key in p["blobs"]}}
        key = next(iter(self.db.image_metadata(self.db.latest()["revision"])), None)
        if key is None:
            book = p["notebooks"][0]
            key = f'{book["id"]}/{book["pages"][0]["id"]}'
        self.db.commit_manifest(self.db.latest()["revision"], manifest, {key: scene_digest})
        self.assertTrue(export(self.db, self.root))
        data = json.loads((self.root / "manifest.json").read_bytes())
        paths = list(data["blobs"].values()) + list(data["scenes"].values()) + [v["file"] for v in data["images"].values()]
        return p, {git(self.root, "hash-object", path) for path in paths}

    def reachable_objects(self, root):
        return {line.split()[0] for line in git(root, "rev-list", "--objects", "--all").splitlines()}

    def assert_current_only(self, head, old_objects=(), documentation=()):
        self.assertEqual(git(self.root, "rev-parse", "HEAD"), head)
        self.assertEqual(git(self.remote, "rev-parse", "main"), head)
        self.assertEqual(git(self.root, "rev-list", "--count", "--all"), "1")
        self.assertEqual(git(self.remote, "rev-list", "--count", "--all"), "1")
        self.assertEqual(git(self.root, "rev-list", "--parents", "-n", "1", head), head)
        for root in (self.root, self.remote):
            self.assertFalse(set(old_objects) & self.reachable_objects(root))
        for oid in old_objects:
            with self.assertRaises(subprocess.CalledProcessError):
                git(self.root, "cat-file", "-e", oid)
        self.assertEqual(git(self.root, "reflog", "show", "--all"), "")
        self.assertEqual(git(self.root, "status", "--porcelain"), "")
        manifest = json.loads((self.root / "manifest.json").read_bytes())
        paths = set(manifest["blobs"].values()) | set(manifest.get("scenes", {}).values()) | {v["file"] for v in manifest["images"].values()}
        self.assertEqual({"objects/" + f.name for f in (self.root / "objects").iterdir()}, paths)
        self.assertEqual(set(git(self.root, "ls-tree", "-r", "--name-only", "HEAD").splitlines()), paths | {"manifest.json"} | set(documentation))

    def advance_remote(self):
        other = Path(self.temp.name) / "other-writer"
        git(self.root, "clone", str(self.remote), str(other))
        self.identity(other)
        (other / "unexpected.txt").write_text("external writer")
        git(other, "add", "unexpected.txt")
        git(other, "commit", "-m", "External change")
        git(other, "push", "origin", "main")
        return git(other, "rev-parse", "HEAD")

    def test_two_backups_have_one_commit_without_previous_native_scene_or_png_reachability(self):
        _, old_objects = self.next_backup(1)
        first = publish_current(self.root)
        p, _ = self.next_backup(2)
        with patch("backup.git", wraps=git) as commands:
            second = publish_current(self.root)
        self.assertNotEqual(first, second)
        pushes = [call.args for call in commands.call_args_list if "push" in call.args]
        self.assertEqual(len(pushes), 1)
        self.assertIn("--force-with-lease=refs/heads/main:" + first, pushes[0])
        self.assertNotIn("--force", pushes[0])
        self.assert_current_only(second, old_objects | {first})
        self.assertEqual(restore_package(self.root), p)
        self.assertFalse(export(self.db, self.root))
        with patch("backup.git", wraps=git) as commands:
            self.assertEqual(publish_current(self.root), second)
        self.assertFalse(any("commit-tree" in call.args or "push" in call.args for call in commands.call_args_list))

    def test_explicit_helper_rewrites_unchanged_cumulative_history(self):
        _, old_objects = self.next_backup(1)
        git(self.root, "add", "manifest.json", "objects")
        git(self.root, "commit", "-m", "Legacy backup 1")
        first = git(self.root, "rev-parse", "HEAD")
        git(self.root, "push", "origin", "main")
        p, _ = self.next_backup(2)
        git(self.root, "add", "--all", "manifest.json", "objects")
        git(self.root, "commit", "-m", "Legacy backup 2")
        second = git(self.root, "rev-parse", "HEAD")
        git(self.root, "push", "origin", "main")
        self.assertEqual(git(self.remote, "rev-list", "--count", "main"), "2")
        self.assertFalse(export(self.db, self.root))
        current = publish_current(self.root)
        self.assert_current_only(current, old_objects | {first, second})
        self.assertEqual(restore_package(self.root), p)

    def test_push_failure_retains_recovery_objects_and_unchanged_retry_publishes_same_head(self):
        _, old_objects = self.next_backup(1)
        previous = publish_current(self.root)
        p, _ = self.next_backup(2)
        def failing_push(root, *args):
            if "push" in args:
                raise subprocess.CalledProcessError(1, args, b"simulated failed push")
            return git(root, *args)
        with patch("backup.git", side_effect=failing_push) as commands:
            with self.assertRaises(subprocess.CalledProcessError):
                publish_current(self.root)
        pending = git(self.root, "rev-parse", "HEAD")
        self.assertNotEqual(pending, previous)
        self.assertEqual(git(self.root, "rev-parse", "origin/main"), previous)
        self.assertEqual(git(self.remote, "rev-parse", "main"), previous)
        self.assertFalse(any("gc" in call.args or "expire" in call.args for call in commands.call_args_list))
        for oid in old_objects | {previous}:
            git(self.root, "cat-file", "-e", oid)
        self.assertFalse(export(self.db, self.root))
        with patch("backup.git", wraps=git) as commands:
            self.assertEqual(publish_current(self.root), pending)
        self.assertFalse(any("commit-tree" in call.args for call in commands.call_args_list))
        self.assert_current_only(pending, old_objects | {previous})
        self.assertEqual(restore_package(self.root), p)

    def test_stale_origin_main_refuses_external_remote_change_before_updating_head(self):
        _, old_objects = self.next_backup(1)
        previous = publish_current(self.root)
        self.next_backup(2)
        foreign = self.advance_remote()
        with patch("backup.git", wraps=git) as commands:
            with self.assertRaisesRegex(ValueError, "differs from origin/main"):
                publish_current(self.root)
        self.assertEqual(git(self.root, "rev-parse", "HEAD"), previous)
        self.assertEqual(git(self.root, "rev-parse", "origin/main"), previous)
        self.assertEqual(git(self.remote, "rev-parse", "main"), foreign)
        self.assertFalse(any("commit-tree" in call.args or "update-ref" in call.args or "push" in call.args or "gc" in call.args
                             for call in commands.call_args_list))
        for oid in old_objects:
            git(self.root, "cat-file", "-e", oid)

    def test_exact_lease_rejects_remote_race_after_oid_capture(self):
        _, old_objects = self.next_backup(1)
        previous = publish_current(self.root)
        self.next_backup(2)
        foreign = []
        def racing_push(root, *args):
            if "push" in args:
                foreign.append(self.advance_remote())
                self.assertIn("--force-with-lease=refs/heads/main:" + previous, args)
            return git(root, *args)
        with patch("backup.git", side_effect=racing_push) as commands:
            with self.assertRaises(subprocess.CalledProcessError):
                publish_current(self.root)
        self.assertEqual(len(foreign), 1)
        self.assertEqual(git(self.remote, "rev-parse", "main"), foreign[0])
        self.assertEqual(git(self.root, "rev-parse", "origin/main"), previous)
        self.assertFalse(any("gc" in call.args or "expire" in call.args for call in commands.call_args_list))
        for oid in old_objects | {previous}:
            git(self.root, "cat-file", "-e", oid)

    def test_failed_post_push_verification_does_not_prune_local_recovery(self):
        _, old_objects = self.next_backup(1)
        previous = publish_current(self.root)
        self.next_backup(2)
        reads = []
        def failed_verification(root, *args):
            if "ls-remote" in args:
                reads.append(1)
                if len(reads) == 2:
                    raise subprocess.CalledProcessError(1, args, b"failed verification")
            return git(root, *args)
        with patch("backup.git", side_effect=failed_verification) as commands:
            with self.assertRaises(subprocess.CalledProcessError):
                publish_current(self.root)
        pending = git(self.root, "rev-parse", "HEAD")
        self.assertEqual(git(self.remote, "rev-parse", "main"), pending)
        self.assertFalse(any("gc" in call.args or "expire" in call.args for call in commands.call_args_list))
        for oid in old_objects | {previous}:
            git(self.root, "cat-file", "-e", oid)
        self.assertEqual(publish_current(self.root), pending)
        self.assert_current_only(pending, old_objects | {previous})

    def test_unexpected_local_or_remote_refs_are_rejected(self):
        self.next_backup(1)
        previous = publish_current(self.root)
        self.next_backup(2)
        for target, ref in ((self.root, "refs/heads/other"), (self.root, "refs/tags/keep-old"),
                            (self.remote, "refs/heads/other"), (self.remote, "refs/tags/keep-old")):
            with self.subTest(target=target, ref=ref):
                git(target, "update-ref", ref, previous)
                with self.assertRaises(ValueError):
                    publish_current(self.root)
                self.assertEqual(git(self.root, "rev-parse", "HEAD"), previous)
                self.assertEqual(git(self.remote, "rev-parse", "main"), previous)
                git(target, "update-ref", "-d", ref)

    def test_empty_library_publishes_without_objects_and_clears_previous_library(self):
        empty = {"format": 1, "notebooks": [], "blobs": {}}
        self.db.commit(0, empty)
        self.assertTrue(export(self.db, self.root))
        first = publish_current(self.root)
        self.assert_current_only(first)
        _, old_objects = self.next_backup(1)
        second = publish_current(self.root)
        self.db.commit(self.db.latest()["revision"], empty)
        self.assertTrue(export(self.db, self.root))
        current = publish_current(self.root)
        self.assert_current_only(current, old_objects | {first, second})
        self.assertEqual(restore_package(self.root), empty)

    def test_checksum_failure_cannot_publish_or_change_head(self):
        self.next_backup(1)
        previous = publish_current(self.root)
        manifest = json.loads((self.root / "manifest.json").read_bytes())
        files = (next(iter(manifest["blobs"].values())), next(iter(manifest["scenes"].values())),
                 next(iter(manifest["images"].values()))["file"])
        for relative in files:
            with self.subTest(relative=relative):
                file = self.root / relative
                data = file.read_bytes()
                file.write_bytes(b"bad checksum")
                try:
                    with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                        publish_current(self.root)
                    self.assertEqual(git(self.root, "rev-parse", "HEAD"), previous)
                    self.assertEqual(git(self.remote, "rev-parse", "main"), previous)
                finally:
                    file.write_bytes(data)

    def test_tracked_backup_documentation_survives_parentless_rewrites(self):
        _, old_objects = self.next_backup(1)
        docs = {"README.md": b"# Draw-data\nCurrent portable backup.\n",
                ".gitignore": b"# Temporary export files\n*.tmp\n"}
        for name, data in docs.items():
            (self.root / name).write_bytes(data)
        git(self.root, "add", "manifest.json", "objects", "README.md", ".gitignore")
        git(self.root, "commit", "-m", "Legacy backup with documentation")
        first = git(self.root, "rev-parse", "HEAD")
        git(self.root, "push", "origin", "main")
        doc_objects = {name: git(self.root, "rev-parse", "HEAD:" + name) for name in docs}
        self.next_backup(2)
        git(self.root, "add", "--all", "manifest.json", "objects")
        git(self.root, "commit", "-m", "Second legacy backup")
        second = git(self.root, "rev-parse", "HEAD")
        git(self.root, "push", "origin", "main")
        current = publish_current(self.root)
        self.assert_current_only(current, old_objects | {first, second}, docs)
        self.next_backup(3)
        # Ordinary subsequent roots also preserve documentation from the index.
        current = publish_current(self.root)
        self.assert_current_only(current, documentation=docs)
        for name, data in docs.items():
            self.assertEqual((self.root / name).read_bytes(), data)
            self.assertEqual(git(self.root, "rev-parse", "HEAD:" + name), doc_objects[name])
            self.assertEqual(git(self.remote, "rev-parse", "main:" + name), doc_objects[name])
        for extra in ("source.py", "README.txt", ".gitignore.bak", "objects/unreferenced.pkdraw"):
            with self.subTest(extra=extra):
                (self.root / extra).write_text("unexpected content")
                git(self.root, "add", extra)
                with self.assertRaisesRegex(ValueError, "unexpected tracked files"):
                    publish_current(self.root)
                self.assertEqual(git(self.root, "rev-parse", "HEAD"), current)
                self.assertEqual(git(self.remote, "rev-parse", "main"), current)
                git(self.root, "rm", "-f", extra)

    def test_code_checkout_or_extra_backup_objects_cannot_be_orphaned(self):
        self.next_backup(1)
        previous = publish_current(self.root)
        for extra in ("source.py", "objects/unreferenced.pkdraw"):
            with self.subTest(extra=extra):
                (self.root / extra).write_text("unexpected content")
                git(self.root, "add", extra)
                with self.assertRaisesRegex(ValueError, "unexpected tracked files"):
                    publish_current(self.root)
                self.assertEqual(git(self.root, "rev-parse", "HEAD"), previous)
                self.assertEqual(git(self.remote, "rev-parse", "main"), previous)
                git(self.root, "rm", "-f", extra)


if __name__ == "__main__":
    unittest.main()
