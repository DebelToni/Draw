"""Standalone normal-user manager. Launching this module is an explicit service action."""
import argparse
import os
from pathlib import Path
from aiohttp import ClientSession, ClientTimeout, web
from .api import create_app
from .manager import Manager
from .renderer import Renderer
from .source import SyncSource


def main():
    parser = argparse.ArgumentParser(description="Draw notes manager (separate from Sync sandbox)")
    parser.add_argument("--state", type=Path, default=Path.home()/".local/state/draw-sync/notes")
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parent.parent/"notes-workspace")
    parser.add_argument("--token-file", type=Path, default=Path.home()/".local/state/draw-sync/token")
    parser.add_argument("--port", type=int, default=18881)
    parser.add_argument("--sync-url", default="http://127.0.0.1:18874")
    parser.add_argument("--no-workers", action="store_true", help="Fixture/API mode, never spawn Pi or tmux")
    args = parser.parse_args()
    os.umask(0o077)
    token = args.token_file.read_text().strip()
    manager = Manager(args.state, renderer=None, workspace=args.workspace, token_file=args.token_file,
                      url=f"http://127.0.0.1:{args.port}")
    manager.renderer = Renderer(manager.store.read_asset)
    app = create_app(manager, token, spawn_workers=not args.no_workers)

    async def source_lifecycle(app):
        async with ClientSession(timeout=ClientTimeout(total=30), trust_env=False) as http:
            manager.source = SyncSource(http, token, args.sync_url)
            yield
        manager.close()
    app.cleanup_ctx.insert(0, source_lifecycle)
    # No HTTP access logs containing request IDs, filenames, credentials or source text.
    web.run_app(app, host="127.0.0.1", port=args.port, access_log=None, print=None)


if __name__ == "__main__":
    main()
