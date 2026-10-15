"""Authenticated aiohttp manager and foreground reverse WebSocket bridge."""
import asyncio
import hmac
from aiohttp import web, WSMsgType
from .storage import Problem, MAX_ASSET, MAX_METADATA, decoded, require, sha, uuid


@web.middleware
async def errors(request, handler):
    try:
        return await handler(request)
    except Problem as e:
        return web.json_response({"error": {"code": e.code, "message": e.message}}, status=e.status)
    except web.HTTPException as e:
        return web.json_response({"error": {"code": "http_error", "message": e.reason}}, status=e.status)
    except (KeyError, TypeError, ValueError, AttributeError):
        return web.json_response({"error": {"code": "invalid_structure", "message": "Invalid request structure"}}, status=422)
    except asyncio.CancelledError:
        raise
    except Exception:
        return web.json_response({"error": {"code": "internal_error", "message": "Manager operation failed"}}, status=500)


def create_app(manager, token, spawn_workers=False):
    require(isinstance(token, str) and token.strip() == token and bool(token), "invalid_auth", "Nonempty private Bearer required")

    @web.middleware
    async def auth(request, handler):
        supplied = request.headers.get("Authorization", "")
        require(hmac.compare_digest(supplied.encode(), ("Bearer "+token).encode()), "unauthorized", "Bearer authentication required", 401)
        require(not request.query.get("token") and not request.query.get("access_token"), "invalid_auth", "Credentials cannot be passed in URL", 401)
        return await handler(request)

    app = web.Application(middlewares=[errors, auth], client_max_size=MAX_ASSET)

    async def body(request, limit=MAX_METADATA, raw=False):
        require(request.headers.get("Content-Encoding", "identity") == "identity", "invalid_encoding", "Upload exact decoded raw bytes")
        if request.content_length is not None:
            require(request.content_length <= limit, "body_limit", "Request exceeds transfer limit", 413)
        data = bytearray()
        async for chunk in request.content.iter_chunked(65536):
            require(len(data)+len(chunk) <= limit, "body_limit", "Request exceeds transfer limit", 413)
            data.extend(chunk)
        return bytes(data) if raw else decoded(data)

    def worker_auth(request):
        doc = uuid(request.headers.get("X-Draw-Document"))
        lease = request.headers.get("X-Draw-Lease")
        manager.worker_registry.authenticate(doc, lease)
        return doc, lease

    async def health(request):
        manager.store.db.execute("SELECT id FROM requests LIMIT 1").fetchone()
        return web.json_response({"ok": True, "protocol": 1})

    async def missing(request):
        value = await body(request)
        digests = value.get("digests")
        require(isinstance(digests, list) and len(digests) <= 10000, "invalid_digests", "Expected bounded digest array")
        for digest in digests:
            sha(digest)
        manager.store.stage([d for d in dict.fromkeys(digests) if manager.store.path(d).is_file()])
        return web.json_response({"missing": [d for d in dict.fromkeys(digests) if not manager.store.path(d).is_file()]})

    async def asset(request):
        digest = sha(request.match_info["digest"])
        if request.method == "PUT":
            data = await body(request, MAX_ASSET, raw=True)
            manager.store.put_asset(digest, data)
            return web.json_response({"sha256": digest})
        data = manager.store.read_asset(digest)
        return web.Response(body=data, content_type="image/png" if data.startswith(b"\x89PNG") else "application/octet-stream")

    async def register_client(request):
        return web.json_response(manager.register_client(await body(request)))

    async def create_request(request):
        return web.json_response(await manager.create_request(await body(request)))

    async def request_status(request):
        rid = uuid(request.match_info["rid"])
        r = manager.store.request(rid)
        if r["origin"] == "terminal":
            await manager.terminal_status(r)
        return web.json_response(manager.get_request(rid, request.query.get("clientID")))

    async def ready(request):
        return web.json_response(manager.ready(request.match_info["doc"], request.query.get("clientID")))

    async def companion(request):
        doc = request.match_info["doc"]
        value = await body(request) if request.method == "PUT" else None
        if value is not None:
            require(set(value) == {"enabled"}, "invalid_companion", "Expected enabled boolean")
        # Worker proxy must be scoped, app/private callers may explicitly set any doc.
        if request.headers.get("X-Draw-Lease"):
            worker_doc, _ = worker_auth(request)
            require(doc == worker_doc, "document_scope", "Companion setting belongs to another document", 409)
        return web.json_response(manager.companion(doc, value["enabled"] if value else None))

    async def terminal(request):
        doc = uuid(request.match_info["doc"])
        if request.headers.get("X-Draw-Lease"):
            worker_doc, _ = worker_auth(request)
            require(doc == worker_doc, "document_scope", "Terminal writing belongs to another document", 409)
        return web.json_response(await manager.terminal_request(doc, await body(request)))

    async def mutate(request):
        rid, operation = request.match_info["rid"], request.match_info["operation"]
        value = await body(request)
        if operation in ("read", "draft", "render", "approve", "activate"):
            doc, lease = worker_auth(request)
            result = await getattr(manager, operation)(rid, value, doc, lease)
        elif operation in ("applied", "sync-started", "sync-ready", "stale-choice", "retry", "claim"):
            if operation in ("stale-choice", "retry") and request.headers.get("X-Draw-Lease"):
                doc, lease = worker_auth(request)
                require(manager.store.request(rid)["documentID"] == doc, "document_scope", "Request/document mismatch", 409)
            result = await getattr(manager, operation.replace("-", "_"))(rid, value)
        else:
            raise Problem("not_found", "Operation not found", 404)
        return web.json_response(result)

    async def result(request):
        return web.Response(body=manager.result(request.match_info["rid"], request.query.get("clientID")), content_type="application/json")

    async def channel(request):
        cid = uuid(request.match_info["cid"])
        manager.registered(cid)
        require(cid not in manager.channels, "channel_busy", "Installation already has foreground channel", 409)
        ws = web.WebSocketResponse(heartbeat=20, max_msg_size=MAX_METADATA)
        await ws.prepare(request)
        opened = False
        sender = ws.send_json
        try:
            async for message in ws:
                if message.type == WSMsgType.TEXT:
                    value = decoded(message.data.encode())
                    require(isinstance(value, dict) and set(value) == {"kind", "documentID"} and value["kind"] == "open", "invalid_channel", "Expected open foreground hello")
                    if value["documentID"] is not None:
                        uuid(value["documentID"])
                    # Home and a different current document are valid foreground states.
                    if not opened:
                        await manager.open_channel(cid, sender)
                        opened = True
                elif message.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                    break
        except Problem as e:
            await ws.send_json({"error": {"code": e.code, "message": e.message}})
            await ws.close(code=1008)
        finally:
            if manager.channels.get(cid) == sender:
                manager.channels.pop(cid, None)
        return ws

    async def worker_register(request):
        value = await body(request)
        worker = manager.worker_registry.register(value)
        return web.json_response({"documentID": worker["documentID"], "sessionID": worker["sessionID"],
                                  "lease": worker["lease"], "companion": manager.companion(worker["documentID"])["enabled"]})

    async def worker_operation(request):
        doc, lease = worker_auth(request)
        require(doc == request.match_info["doc"], "document_scope", "Worker route/document mismatch", 409)
        value = await body(request)
        op = request.match_info["operation"]
        if op == "poll":
            result = manager.lease_request(doc, lease, value)
        elif op == "heartbeat":
            result = await manager.worker_heartbeat(doc, lease, value)
        elif op == "event":
            result = await manager.worker_event(doc, lease, value)
        else:
            raise Problem("not_found", "Worker operation not found", 404)
        return web.json_response(result)

    app.router.add_get("/health", health)
    app.router.add_post("/v1/assets/missing", missing)
    app.router.add_route("PUT", "/v1/assets/{digest}", asset)
    app.router.add_get("/v1/assets/{digest}", asset)
    app.router.add_post("/v1/clients/register", register_client)
    app.router.add_get("/v1/clients/{cid}/channel", channel)
    app.router.add_post("/v1/requests", create_request)
    app.router.add_get("/v1/requests/{rid}", request_status)
    app.router.add_get("/v1/requests/{rid}/result", result)
    app.router.add_post("/v1/requests/{rid}/{operation}", mutate)
    app.router.add_get("/v1/documents/{doc}/ready", ready)
    app.router.add_route("PUT", "/v1/documents/{doc}/companion", companion)
    app.router.add_get("/v1/documents/{doc}/companion", companion)
    app.router.add_post("/v1/documents/{doc}/terminal-requests", terminal)
    app.router.add_post("/v1/workers/register", worker_register)
    app.router.add_post("/v1/workers/{doc}/{operation}", worker_operation)

    async def lifecycle(app):
        async def maintain():
            while True:
                await asyncio.sleep(5)
                try:
                    await manager.maintenance(spawn_workers)
                except Problem:
                    # Source temporarily unavailable. Keep sessions alive, never guess activity.
                    pass
                except Exception:
                    manager.store.save_record("service_error", "maintenance", {"code": "maintenance_failed"})
        task = asyncio.create_task(maintain())
        yield
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        for sender in list(manager.channels.values()):
            ws = getattr(sender, "__self__", None)
            if ws is not None:
                await ws.close(code=1001)
    app.cleanup_ctx.append(lifecycle)
    return app
