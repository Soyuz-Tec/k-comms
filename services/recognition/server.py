"""Authenticated fixed-origin Whisper-compatible post-recording HTTP service."""
import asyncio
import hmac
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from protocol import MAX_MEDIA_BYTES, MAX_RESPONSE_BYTES

TOKEN = os.environ.get("RECOGNITION_BEARER_TOKEN", "")
MODEL_DIR = os.environ.get("RECOGNITION_MODEL_DIR", "")
if not re.fullmatch(r"[^\s\x00-\x1f\x7f]{32,4096}", TOKEN) or not Path(MODEL_DIR).is_dir():
    raise RuntimeError("provision a protected bearer secret and pinned local model")
# Offline environment is inherited by the hard-deadline inference child.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
slot = asyncio.Semaphore(1)
api = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


class LimitsAndAuthentication:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = dict(scope["headers"])
        credential = headers.get(b"authorization", b"")
        authorization_count = sum(name == b"authorization" for name, _ in scope["headers"])
        if (authorization_count != 1 or scope["path"] != "/v1/audio/transcriptions" or scope["method"] != "POST" or
                not hmac.compare_digest(credential, ("Bearer " + TOKEN).encode())):
            await send({"type": "http.response.start", "status": 403, "headers": [(b"cache-control", b"no-store")]})
            return await send({"type": "http.response.body", "body": b""})
        used = 0
        upload_finished = False
        upload_deadline = asyncio.get_running_loop().time() + 30

        async def bounded_receive():
            nonlocal used, upload_finished
            if upload_finished:
                return await receive()
            remaining = upload_deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise HTTPException(408, "upload deadline exceeded")
            try:
                message = await asyncio.wait_for(receive(), timeout=min(10, remaining))
            except TimeoutError:
                raise HTTPException(408, "upload deadline exceeded") from None
            used += len(message.get("body", b""))
            if used > MAX_MEDIA_BYTES + 65_536:
                raise HTTPException(413, "upload exceeds approved bound")
            if message["type"] == "http.request" and not message.get("more_body", False):
                upload_finished = True
            return message
        await self.app(scope, bounded_receive, send)


@api.post("/v1/audio/transcriptions")
async def transcribe(request: Request, file: UploadFile = File(...), model: str = Form(...),
                     response_format: str = Form(...), language: str | None = Form(None)):
    if (model != "tiny.en" or response_format != "verbose_json" or
            language not in (None, "en") or
            file.content_type != "video/mp4"):
        await file.close()
        raise HTTPException(422, "unsupported recognition format; pinned model is English only")
    # Reject concurrent work; do not retain a queued upload indefinitely.
    if slot.locked():
        await file.close()
        raise HTTPException(429, "recognition capacity occupied")
    async with slot:
        with tempfile.TemporaryDirectory(prefix="kcomms-recognition-") as directory:
            source, output = Path(directory) / "source.mp4", Path(directory) / "result.json"
            count = 0
            try:
                with source.open("wb") as stream:
                    while block := await file.read(65_536):
                        count += len(block)
                        if count > MAX_MEDIA_BYTES:
                            raise HTTPException(413, "recording exceeds approved size")
                        stream.write(block)
                if count == 0:
                    raise HTTPException(422, "empty recording")
                operation_id = str(uuid.uuid4())
                args = [sys.executable, str(Path(__file__).with_name("engine.py")),
                        str(source), str(output), language or "", operation_id]
                deadline = asyncio.get_running_loop().time() + 55
                process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                waiter = asyncio.create_task(asyncio.to_thread(process.wait))

                async def watch_disconnect():
                    while not await request.is_disconnected():
                        await asyncio.sleep(0.05)

                monitor = asyncio.create_task(watch_disconnect())
                try:
                    completed, _ = await asyncio.wait(
                        (waiter, monitor), timeout=max(0, deadline - asyncio.get_running_loop().time()),
                        return_when=asyncio.FIRST_COMPLETED)
                    if not completed:
                        raise HTTPException(504, "recognition deadline exceeded")
                    if monitor in completed:
                        await monitor
                        raise HTTPException(499, "recognition request disconnected")
                    await waiter
                except asyncio.CancelledError:
                    raise HTTPException(504, "recognition request cancelled") from None
                finally:
                    if process.poll() is None:
                        try:
                            process.kill()
                        except ProcessLookupError:
                            pass
                    monitor.cancel()

                    async def join_tasks():
                        await asyncio.gather(waiter, monitor, return_exceptions=True)

                    cleanup = asyncio.create_task(join_tasks())
                    cancelled = False
                    while not cleanup.done():
                        try:
                            await asyncio.shield(cleanup)
                        except asyncio.CancelledError:
                            cancelled = True
                    cleanup.result()
                    if cancelled:
                        raise asyncio.CancelledError
                if process.returncode != 0 or not output.exists() or output.stat().st_size > MAX_RESPONSE_BYTES:
                    raise HTTPException(422, "recognition could not complete within approved bounds")
                return json.loads(output.read_text(encoding="utf-8"))
            finally:
                await file.close()


app = LimitsAndAuthentication(api)
