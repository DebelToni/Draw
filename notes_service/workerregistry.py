"""Exact interactive Pi identity, owned tmux panes and conservative idle guards."""
import json
import hashlib
import os
import re
import shlex
import subprocess
import time
from pathlib import Path
from uuid import uuid4
from .storage import Problem, atomic, encoded, require, uuid

IDLE_SECONDS = 24 * 3600
HEARTBEAT_SECONDS = 30


def safe_name(value):
    value = re.sub(r"[/\\\x00-\x1f\x7f]", "_", str(value)).strip(" .")[:96]
    return value if value and value not in (".", "..") else "Untitled"


class WorkerRegistry:
    def __init__(self, store, workspace, manager_url, token_file, pi="pi", tmux="tmux", clock=time.time):
        self.store, self.clock = store, clock
        self.workspace = Path(workspace).resolve()
        self.manager_url, self.token_file = manager_url, str(Path(token_file).resolve())
        self.pi, self.tmux = pi, tmux
        self.owner = store.record("owner", "tmux")
        if self.owner is None:
            self.owner = str(uuid4())
            store.save_record("owner", "tmux", self.owner)
        # No filesystem or process changes to workspace until explicit reservation/spawn.

    def get(self, doc):
        worker = self.store.record("worker", uuid(doc))
        require(worker is not None, "worker_mapping_missing", "Document has no reserved worker", 409)
        return worker

    def save(self, worker):
        self.store.save_record("worker", worker["documentID"], worker)

    def folder_directory(self, folder, folder_id=None):
        if folder_id is not None:
            uuid(folder_id)
        key = folder_id or ("home" if folder == "Home" else "legacy:"+safe_name(folder))
        record = self.store.record("folder", key)
        if record and record["name"] == folder:
            return record["directory"]
        directory = safe_name(folder)
        occupied = {r["directory"]: r["key"] for r in self.store.records("folder")}
        # Home is always reserved for unfiled documents, regardless of reservation order.
        collision = (directory == "Home" and key != "home") or occupied.get(directory, key) != key
        path = self.workspace / directory
        if path.exists() and not (record and record["directory"] == directory) and directory not in occupied:
            collision = True
        if collision:
            suffix = folder_id[:8] if folder_id else hashlib.sha256(key.encode()).hexdigest()[:8].upper()
            directory += "-" + suffix
        require(occupied.get(directory, key) == key, "workspace_collision", "Folder label collision needs explicit recovery", 409)
        require((self.workspace/directory).resolve().is_relative_to(self.workspace) and not (self.workspace/directory).is_symlink(),
                "workspace_escape", "Folder path escapes managed root", 409)
        self.store.save_record("folder", key, {"key": key, "folderID": folder_id, "name": folder, "directory": directory})
        return directory

    @staticmethod
    def worker_label(folder, directory, name):
        # Display the logical path, retaining any filesystem collision suffix.
        return folder + directory[len(safe_name(folder)):] + " / " + name

    def reserve(self, doc, folder="Home", name="Untitled", folder_id=None):
        uuid(doc)
        existing = self.store.record("worker", doc)
        if existing:
            return existing
        name = safe_name(name)
        original_name = name
        folder_directory = self.folder_directory(folder, folder_id)
        path = self.workspace / folder_directory / name
        require(path.resolve().is_relative_to(self.workspace) and not path.parent.is_symlink(),
                "workspace_escape", "Workspace path escapes managed root", 409)
        occupied = {w["cwd"] for w in self.store.records("worker")}
        if str(path) in occupied or path.exists():
            name += "-" + doc[:8]
            path = self.workspace / folder_directory / name
        require(not path.exists(), "workspace_collision", "Document workspace already exists", 409)
        self.workspace.mkdir(parents=True, exist_ok=True, mode=0o700)
        template = Path(__file__).with_name("AGENTS.template.md").read_bytes()
        agents = self.workspace / "AGENTS.md"
        if not agents.exists():
            atomic(agents, template)
        path.mkdir(parents=True, mode=0o700)
        worker = {"documentID": doc, "sessionID": str(uuid4()), "sessionFile": None,
                  "cwd": str(path), "label": self.worker_label(folder, folder_directory, name),
                  "folderID": folder_id, "folderDirectory": folder_directory, "folderName": folder, "noteName": original_name, "spawnNonce": str(uuid4()), "paneID": None, "windowID": None,
                  "busy": False, "pending": False, "heartbeat": 0,
                  "lastActivity": self.clock(), "inputObserved": False,
                  "lease": None, "shutdownRequested": False, "spawned": False}
        self.save(worker)
        self.write_descriptor(worker)
        return worker

    def write_descriptor(self, worker):
        atomic(Path(worker["cwd"]) / "document.json", encoded({
            "documentID": worker["documentID"], "sessionID": worker["sessionID"],
            "managerURL": self.manager_url, "tokenFile": self.token_file,
            "spawnNonce": worker["spawnNonce"], "folderID": worker.get("folderID")}))

    def register(self, body):
        worker = self.get(body.get("documentID"))
        require(body.get("sessionID") == worker["sessionID"] and
                body.get("spawnNonce") == worker["spawnNonce"] and
                str(Path(body.get("cwd", "")).resolve()) == worker["cwd"],
                "worker_identity", "Worker document/session/cwd mapping mismatch", 409)
        file = body.get("sessionFile")
        require(isinstance(file, str) and Path(file).is_absolute() and file.endswith(".jsonl"),
                "worker_identity", "Exact persistent Pi session file required", 409)
        file = str(Path(file).resolve())
        if worker["sessionFile"]:
            require(file == worker["sessionFile"], "worker_identity", "Session locator cannot be replaced", 409)
        require(worker.get("lease") is None or self.clock()-worker["heartbeat"] > HEARTBEAT_SECONDS,
                "worker_bridge_busy", "Another live bridge already owns this exact session", 409)
        worker["sessionFile"] = file
        if Path(file).exists():
            self.verify_header(worker)
        worker.update(lease=str(uuid4()), heartbeat=self.clock(), shutdownRequested=False, shutdownAcknowledged=False,
                      busy=body.get("busy") is not False, pending=body.get("pending") is not False,
                      inputObserved=body.get("inputObserved") is True)
        self.save(worker)
        return worker

    def authenticate(self, doc, lease):
        worker = self.get(doc)
        require(lease is not None and lease == worker.get("lease"), "bridge_lease", "Worker lease expired; register exact session", 409)
        return worker

    def heartbeat(self, doc, lease, body):
        worker = self.authenticate(doc, lease)
        now = self.clock()
        if body.get("humanActivity") is True or body.get("busy") is True or body.get("pending") is True:
            worker["lastActivity"] = now
            worker["shutdownRequested"] = False
        # Require explicit complete activity information; uncertainty inhibits shutdown.
        worker.update(heartbeat=now, busy=body.get("busy") is not False,
                      pending=body.get("pending") is not False,
                      inputObserved=body.get("inputObserved") is True,
                      contextUsage=body.get("contextUsage"), activeRequestID=body.get("activeRequestID"))
        self.save(worker)
        return worker

    def activity(self, doc, lease, event):
        worker = self.authenticate(doc, lease)
        worker["lastActivity"] = worker["heartbeat"] = self.clock()
        worker["shutdownRequested"] = False
        if event == "agent_start":
            worker["busy"] = True
        elif event == "agent_settled":
            worker["busy"] = False
            worker["pending"] = False
            worker["activeRequestID"] = None
        elif event == "shutdown":
            worker["shutdownAcknowledged"] = True
            worker["lease"] = None
            worker["heartbeat"] = 0
        elif event not in ("human", "tool_start", "tool_end"):
            raise Problem("invalid_event", "Unsupported worker event")
        self.save(worker)
        return worker

    def idle_allowed(self, worker, pending_requests=False, tmux_activity_known=False):
        now = self.clock()
        return (now - worker["lastActivity"] >= IDLE_SECONDS and
                0 <= now - worker["heartbeat"] <= HEARTBEAT_SECONDS and
                worker.get("lease") is not None and worker.get("busy") is False and
                worker.get("pending") is False and worker.get("inputObserved") is True and
                worker.get("activeRequestID") is None and not pending_requests and
                tmux_activity_known and not worker.get("relocation") and not worker.get("renamePending"))

    def command(self, worker):
        args = [self.pi, "--unlisted", "--fast", "--name", worker["label"],
                "--extension", str(Path(__file__).with_name("pi-extension.ts").resolve())]
        if worker["sessionFile"]:
            path = Path(worker["sessionFile"])
            require(path.is_file(), "worker_session_missing", "Stored Pi session file is missing; explicit recovery required", 409)
            self.verify_header(worker)
            args += ["--session", str(path)]
        else:
            require(not worker["spawned"], "worker_session_missing", "Spawned worker did not register a session; recovery required", 409)
            args += ["--session-id", worker["sessionID"]]
        return args

    def verify_header(self, worker):
        try:
            with open(worker["sessionFile"], "rb") as f:
                header = json.loads(f.readline(1024*1024))
        except (OSError, ValueError):
            raise Problem("worker_session_missing", "Stored session is unreadable", 409) from None
        require(header.get("type") == "session" and header.get("id") == worker["sessionID"] and
                header.get("cwd") == worker["cwd"], "worker_identity", "Stored Pi header does not match registry", 409)
        return header

    def run(self, *args):
        result = subprocess.run([self.tmux, *args], capture_output=True, text=True, timeout=10)
        require(result.returncode == 0, "tmux_unavailable", "Owned tmux operation failed", 409)
        return result.stdout.strip()

    def pane_owned(self, worker):
        if not worker.get("paneID"):
            return False
        try:
            value = self.run("display-message", "-p", "-t", worker["paneID"],
                             "#{session_name}|#{window_id}|#{@draw_owner}|#{@draw_document}")
            return value == "|".join(("Draw-notes", worker["windowID"], self.owner, worker["documentID"]))
        except Problem:
            return False

    def spawn(self, doc):
        worker = self.get(doc)
        if self.pane_owned(worker):
            return worker
        require(worker.get("paneID") is None or worker.get("lease") is None or
                self.clock()-worker["heartbeat"] > HEARTBEAT_SECONDS,
                "worker_uncertain", "Worker pane identity is uncertain", 409)
        command = self.command(worker)
        shell = "exec " + shlex.join(command)
        has = subprocess.run([self.tmux, "has-session", "-t", "Draw-notes"], capture_output=True).returncode == 0
        operation = "new-window" if has else "new-session"
        args = [operation, "-d", "-P", "-F", "#{window_id} #{pane_id}"]
        args += ["-t", "Draw-notes:"] if has else ["-s", "Draw-notes"]
        args += ["-n", worker["label"], "-c", worker["cwd"], shell]
        window, pane = self.run(*args).split()
        worker.update(windowID=window, paneID=pane, spawned=True, heartbeat=0, lease=None, shutdownAcknowledged=False)
        self.save(worker)
        self.run("set-option", "-w", "-t", window, "automatic-rename", "off")
        self.run("set-option", "-w", "-t", window, "@draw_owner", self.owner)
        self.run("set-option", "-w", "-t", window, "@draw_document", doc)
        return worker

    def request_idle_shutdown(self, doc, pending_requests=False):
        worker = self.get(doc)
        # The extension observes all raw terminal input; ownership still must be proven.
        if self.idle_allowed(worker, pending_requests, self.pane_owned(worker)):
            worker["shutdownRequested"] = True
            self.save(worker)
            return True
        return False

    def require_stopped(self, worker):
        require(worker.get("lease") is None and not self.pane_owned(worker),
                "worker_busy", "Cannot relocate a live session", 409)
        if worker.get("paneID"):
            require(worker.get("shutdownAcknowledged") is True,
                    "worker_uncertain", "Relocation requires acknowledged graceful shutdown", 409)
            result = subprocess.run([self.tmux, "display-message", "-p", "-t", worker["paneID"], "#{pane_id}"],
                                    capture_output=True, text=True, timeout=10)
            pane = result.stdout.strip()
            require(pane != worker["paneID"], "worker_busy", "Stored pane still exists, even if ownership changed", 409)
            # tmux can succeed with an empty pane_id when an exact target has disappeared.
            absent = result.returncode == 0 and not pane
            absent = absent or (result.returncode != 0 and not pane and any(
                message in result.stderr.lower() for message in ("can't find pane", "no server running", "no such file or directory")))
            require(absent, "worker_uncertain", "Unable to prove stored pane has exited", 409)

    def relocate(self, doc, folder, name, folder_id=None):
        worker = self.get(doc)
        self.require_stopped(worker)
        require(not worker["busy"] and
                not worker["pending"] and not self.store.requests(doc, {"queued", "running", "awaiting_sync", "synchronizing", "needs_stale_choice"}),
                "worker_busy", "Relocation requires graceful worker shutdown and settled requests", 409)
        folder_directory = self.folder_directory(folder, folder_id)
        destination = self.workspace / folder_directory / safe_name(name)
        require(destination.resolve().is_relative_to(self.workspace) and not destination.parent.is_symlink(),
                "workspace_escape", "Relocation path escapes managed root", 409)
        if destination == Path(worker["cwd"]):
            worker.update(folderID=folder_id, folderName=folder, noteName=safe_name(name), folderDirectory=folder_directory,
                          label=self.worker_label(folder, folder_directory, destination.name))
            self.save(worker)
            self.write_descriptor(worker)
            return worker
        if any(w["cwd"] == str(destination) and w["documentID"] != doc for w in self.store.records("worker")) or destination.exists():
            destination = destination.with_name(destination.name + "-" + doc[:8])
        require(not destination.exists(), "workspace_collision", "Relocation destination exists", 409)
        header = self.verify_header(worker) if worker["sessionFile"] else None
        worker["relocation"] = {"from": worker["cwd"], "to": str(destination), "folderName": folder, "noteName": safe_name(name), "folderID": folder_id, "folderDirectory": folder_directory}
        self.save(worker)
        self.finish_relocation(worker, header)
        return worker

    def finish_relocation(self, worker, header=None):
        # Durable journal can be finished after any crash, but never while Pi is live.
        move = worker["relocation"]
        self.require_stopped(worker)
        old, new = Path(move["from"]), Path(move["to"])
        require(old.exists() != new.exists(), "relocation_uncertain", "Workspace relocation needs explicit recovery", 409)
        session_data = None
        if worker["sessionFile"]:
            path = Path(worker["sessionFile"])
            session_data = path.read_bytes()
            first, rest = session_data.split(b"\n", 1)
            current = json.loads(first)
            require(current.get("type") == "session" and current.get("id") == worker["sessionID"] and current.get("cwd") in (move["from"], move["to"]),
                    "worker_identity", "Relocation session identity mismatch", 409)
            require(current.get("version") == 3, "worker_session_version", "Unsupported session format for cwd relocation", 409)
        if old.exists():
            new.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.rename(old, new)
        if session_data is not None:
            require(path.read_bytes() == session_data, "worker_uncertain", "Session changed during stopped-worker relocation", 409)
            current["cwd"] = str(new)
            atomic(path, encoded(current) + b"\n" + rest)
        worker.update(cwd=str(new), label=self.worker_label(move.get("folderName", new.parent.name), new.parent.name, new.name), paneID=None, windowID=None,
                      folderName=move.get("folderName", new.parent.name), noteName=move.get("noteName", new.name),
                      folderID=move.get("folderID", worker.get("folderID")), folderDirectory=move.get("folderDirectory", new.parent.name))
        worker.pop("relocation", None)
        self.write_descriptor(worker)
        self.save(worker)
