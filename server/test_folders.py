import copy
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.request
import urllib.error
from uuid import uuid4

from server import Database, make_server
from test_server import package
from backup import export, restore_package


class FolderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "sync.db"
        self.db = Database(self.path)

    def tearDown(self):
        self.temp.cleanup()

    def test_folder_registry_membership_and_latest_revision_roundtrip(self):
        original = package()
        self.db.commit(0, original)
        p = copy.deepcopy(original)
        fid = str(uuid4()).upper()
        p["folders"] = [{"id": fid, "name": "Math"}, {"id": str(uuid4()).upper(), "name": "Empty"}]
        p["notebooks"][0]["folderID"] = fid
        self.db.commit(1, p)
        self.assertEqual(Database(self.path).latest()["package"], p)
        with self.assertRaises(LookupError):
            self.db.latest(1)
        self.assertEqual(p["blobs"], original["blobs"])
        backup = Path(self.temp.name) / "backup"
        export(self.db, backup)
        self.assertEqual(restore_package(backup), p)

    def test_invalid_folders_never_replace_library(self):
        original = package()
        self.db.commit(0, original)
        fid = str(uuid4()).upper()
        for folders, membership in [([], fid), ([{"id": fid, "name": " "}], None),
                ([{"id": fid, "name": "A"}, {"id": fid, "name": "B"}], None), ("bad", None)]:
            p = copy.deepcopy(original)
            p["folders"] = folders
            p["notebooks"][0]["folderID"] = membership
            with self.assertRaises(ValueError):
                self.db.commit(1, p)
        self.assertEqual(self.db.latest()["package"], original)

    def test_authenticated_revision_pinned_folder_api(self):
        original = package()
        self.db.commit(0, original)
        p = copy.deepcopy(original)
        fid, empty = str(uuid4()).upper(), str(uuid4()).upper()
        p["folders"] = [{"id": fid, "name": "School"}, {"id": empty, "name": "Empty"}]
        p["notebooks"][0]["folderID"] = fid
        self.db.commit(1, p)
        server = make_server(self.path, "test-token", port=0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def get(path, token="test-token"):
            request = urllib.request.Request(f"http://127.0.0.1:{server.server_port}" + path,
                headers={"Authorization": "Bearer " + token})
            try:
                with urllib.request.urlopen(request) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)
        try:
            self.assertEqual(get("/v1/folders", "bad")[0], 401)
            listing = get("/draw-sync/v1/folders")[1]
            self.assertEqual(listing["revision"], 2)
            self.assertEqual([f["documentCount"] for f in listing["folders"]], [1, 0])
            group = get("/v1/folders/" + fid)[1]
            self.assertEqual(group["documents"][0]["folderID"], fid)
            self.assertEqual(group["documents"][0]["id"], p["notebooks"][0]["id"])
            self.assertEqual(get("/v1/folders/" + empty)[1]["documents"], [])
            self.assertEqual(get("/v1/folders?revision=1")[0], 404)
            self.assertEqual(get("/v1/folders/" + fid + "?revision=1")[0], 404)
            self.assertEqual(get("/v1/folders/" + str(uuid4()).upper())[0], 404)
            self.assertEqual(get("/v1/folders/bad")[0], 400)
            documents = get("/v1/documents")[1]
            self.assertEqual(documents["folders"], listing["folders"])
            self.assertEqual(documents["documents"][0]["folderID"], fid)
            self.assertEqual(get("/v1/documents?revision=1")[0], 404)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
