import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from notes_service import __main__ as entry
from notes_service.manager import Manager
from notes_service.tests.fixtures import uid


class StartupPortTests(unittest.TestCase):
    def test_cli_default_and_scratch_override_bind_generated_descriptor_to_actual_port(self):
        for flags, port in (([], 18881), (["--port", "48281"], 48281)):
            with self.subTest(port=port), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                token = root/"token"
                token.write_text("fixture-private-token")
                managers = []
                def make_manager(*args, **kwargs):
                    manager = Manager(*args, **kwargs)
                    managers.append(manager)
                    return manager
                args = ["notes_service", "--state", str(root/"state"), "--workspace", str(root/"workspace"),
                        "--token-file", str(token), "--no-workers", *flags]
                try:
                    with patch("sys.argv", args), patch.object(entry, "Manager", side_effect=make_manager), patch.object(
                            entry, "Renderer", return_value=object()), patch.object(entry.os, "umask"), patch.object(entry.web, "run_app") as run:
                        entry.main()
                    self.assertEqual(len(managers), 1)
                    self.assertEqual(run.call_args.kwargs["host"], "127.0.0.1")
                    self.assertEqual(run.call_args.kwargs["port"], port)
                    self.assertIsNone(run.call_args.kwargs["access_log"])
                    manager = managers[0]
                    worker = manager.worker_registry.reserve(uid(), "Fixture", "Port")
                    descriptor = json.loads((Path(worker["cwd"])/"document.json").read_text())
                    self.assertEqual(descriptor["managerURL"], f"http://127.0.0.1:{port}")
                    self.assertEqual(descriptor["tokenFile"], str(token))
                    self.assertNotIn("fixture-private-token", json.dumps(descriptor))
                    self.assertIsNone(manager.source) # Cleanup context not entered; no HTTP/model/tmux launch.
                finally:
                    for manager in managers:
                        manager.close()

    def test_manager_default_url_and_service_template_use_draw_port(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manager = Manager(root/"state", renderer=None, workspace=root/"workspace")
            try:
                worker = manager.worker_registry.reserve(uid(), "Fixture", "Default")
                descriptor = json.loads((Path(worker["cwd"])/"document.json").read_text())
                self.assertEqual(descriptor["managerURL"], "http://127.0.0.1:18881")
            finally:
                manager.close()
        service = Path(entry.__file__).with_name("draw-notes.service").read_text()
        self.assertIn("ExecStart=%h/projects/Draw/.venv/bin/python -m notes_service --port 18881\n", service)
