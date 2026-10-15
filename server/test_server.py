import base64
import copy
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.request
import urllib.error
from uuid import uuid4
from server import Database, Conflict, make_server


def package():
    bid, pid, nid = [str(uuid4()).upper() for _ in range(3)]
    return {"format": 1, "notebooks": [{"id": bid, "name": "Test", "created": 0, "modified": 1,
        "pages": [{"id": pid, "background": 0, "starred": False, "head": nid,
            "nodes": [{"id": nid, "children": []}]}], "deleted": [], "currentPage": pid}],
        "blobs": {f"{bid}/{pid}/{nid}": base64.b64encode(b"opaque PencilKit bytes").decode()}}


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "sync.db"
        self.db = Database(self.path)

    def tearDown(self):
        self.temp.cleanup()

    def test_roundtrip_and_restart(self):
        p = package()
        self.assertEqual(self.db.commit(0, p), 1)
        self.assertEqual(Database(self.path).latest(), {"revision": 1, "package": p})

    def test_retry_after_lost_response_is_idempotent(self):
        p = package()
        self.db.commit(0, p)
        self.assertEqual(self.db.commit(0, p), 1)

    def test_conflict_does_not_overwrite(self):
        p = package()
        self.db.commit(0, p)
        with self.assertRaises(Conflict):
            self.db.commit(0, package())
        self.assertEqual(self.db.latest()["package"], p)

    def test_bad_package_does_not_overwrite(self):
        p = package()
        self.db.commit(0, p)
        bad = copy.deepcopy(p)
        bad["blobs"] = {}
        with self.assertRaises(ValueError):
            self.db.commit(1, bad)
        self.assertEqual(self.db.latest()["package"], p)

    def test_missed_validation_preserves_legacy_metadata_and_rejects_invalid_counts(self):
        from test_images import images
        p = package()
        key = next(iter(images(p)))
        for counts in ("absent", None, {}, {"missed": 1}, {"question": 1, "missed": 2}):
            with self.subTest(counts=counts):
                preview = images(p)
                preview[key]["strokeCount"] = 3
                if counts != "absent":
                    preview[key]["tagStrokeCounts"] = counts
                self.assertEqual(self.db.commit(0, p, preview), 1)
                self.assertEqual(self.db.image_metadata(1)[key],
                                 {k: v for k, v in preview[key].items() if k != "png"})
        original = self.db.image_metadata(1)
        original_png = self.db.image(1, key)
        bad_counts = [[], "missed", 1, True, {"unknown": 1}, {"Missed": 1},
                      {"question": 1, "missed": 1, "unknown": 1}]
        bad_counts += [{"missed": count} for count in (0, -1, 4, 1.0, True, False, "1", None, [])]
        for counts in bad_counts:
            for changed_source in (False, True):
                with self.subTest(counts=counts, changed_source=changed_source):
                    bad = copy.deepcopy(p)
                    if changed_source:
                        bad["notebooks"][0]["name"] = "Changed"
                    preview = images(bad)
                    preview[key]["strokeCount"] = 3
                    preview[key]["tagStrokeCounts"] = counts
                    with self.assertRaises(ValueError):
                        self.db.commit(1, bad, preview)
                    self.assertEqual(self.db.latest(), {"revision": 1, "package": p})
                    self.assertEqual(self.db.image_metadata(1), original)
                    self.assertEqual(self.db.image(1, key), original_png)

    def test_preferred_root_is_optional_but_must_reference_a_root(self):
        p = package()
        self.db.commit(0, p)
        page = p["notebooks"][0]["pages"][0]
        page["preferredRoot"] = page["nodes"][0]["id"]
        self.assertEqual(self.db.commit(1, p), 2)
        bad = copy.deepcopy(p)
        bad["notebooks"][0]["pages"][0]["preferredRoot"] = str(uuid4()).upper()
        with self.assertRaises(ValueError):
            self.db.commit(2, bad)
        self.assertEqual(self.db.latest()["package"], p)

    def test_failed_transaction_preserves_committed_revision(self):
        import sqlite3
        p = package()
        self.db.commit(0, p)
        with self.db.connect() as db:
            db.execute("CREATE TRIGGER fail_write BEFORE INSERT ON revisions BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END")
        with self.assertRaises(sqlite3.Error):
            self.db.commit(1, package())
        self.assertEqual(Database(self.path).latest(), {"revision": 1, "package": p})

    def test_only_latest_revision_retained(self):
        self.db.commit(0, package())
        self.db.commit(1, package())
        with self.db.connect() as db:
            self.assertEqual(db.execute("SELECT revision FROM revisions").fetchall(), [(2,)])
        with self.assertRaises(LookupError):
            self.db.latest(1)

    def test_concurrent_writers_only_one_wins(self):
        outcomes = []
        def writer():
            try: outcomes.append(self.db.commit(0, package()))
            except Conflict: outcomes.append("conflict")
        threads = [threading.Thread(target=writer) for _ in range(2)]
        for thread in threads: thread.start()
        for thread in threads: thread.join()
        self.assertCountEqual(outcomes, [1, "conflict"])

    def test_http_auth_validation_and_conflicts(self):
        server = make_server(self.path, "test-token", 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/v1/state"
        def request(data=None, token="test-token"):
            req = urllib.request.Request(url, data=json.dumps(data).encode() if data else None,
                headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req) as response: return response.status, json.load(response)
            except urllib.error.HTTPError as error: return error.code, json.load(error)
        try:
            self.assertEqual(request(token="bad")[0], 401)
            self.assertEqual(request()[1], {"revision": 0, "package": None})
            self.assertEqual(request({"baseRevision": 0, "package": package()})[0], 200)
            self.assertEqual(request({"baseRevision": 0, "package": package()})[0], 409)
            self.assertEqual(request({"baseRevision": 1, "package": {}})[0], 400)
            self.assertEqual(request()[1]["revision"], 1)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
