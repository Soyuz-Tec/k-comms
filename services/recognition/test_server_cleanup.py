"""Actual OS-child cleanup regressions; synthetic children never recognize speech."""
import asyncio
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from fastapi import HTTPException, Request, UploadFile
from starlette.datastructures import Headers


class RecognitionCleanupTest(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = tempfile.TemporaryDirectory(prefix="recognition-test-model-")
        with patch.dict(os.environ, {"RECOGNITION_MODEL_DIR": cls.model.name,
                                     "RECOGNITION_BEARER_TOKEN": "synthetic-test-authorization-" * 2}):
            spec = importlib.util.spec_from_file_location("recognition_cleanup_server", Path(__file__).with_name("server.py"))
            cls.server = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.server)

    @classmethod
    def tearDownClass(cls):
        cls.model.cleanup()

    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="recognition-cleanup-test-")
        self.original_tempdir = tempfile.tempdir
        tempfile.tempdir = self.directory.name
        self.server.slot = asyncio.Semaphore(1)
        self.started, self.disconnected = asyncio.Event(), asyncio.Event()
        self.children = []
        self.original_popen = subprocess.Popen

    async def asyncTearDown(self):
        for process in self.children:
            if process.poll() is None:
                process.kill()
                process.wait()
        tempfile.tempdir = self.original_tempdir
        self.directory.cleanup()

    def spawn(self, args, **kwargs):
        process = self.original_popen([sys.executable, "-B", "-c", "import time; time.sleep(30)"], **kwargs)
        self.children.append(process)
        self.started.set()
        return process

    async def receive(self):
        await self.disconnected.wait()
        return {"type": "http.disconnect"}

    async def invoke(self, media=b"synthetic lifecycle input"):
        request = Request({"type": "http", "method": "POST", "path": "/v1/audio/transcriptions", "headers": []}, self.receive)
        upload = UploadFile(io.BytesIO(media), filename="source.mp4", headers=Headers({"content-type": "video/mp4"}))
        return await self.server.transcribe(request, upload, "tiny.en", "verbose_json", "en")

    async def assert_settled_and_reusable(self):
        self.assertFalse(self.server.slot.locked())
        self.assertEqual(list(Path(self.directory.name).iterdir()), [])
        self.assertTrue(all(process.poll() is not None for process in self.children))
        with self.assertRaises(HTTPException) as refusal:
            await self.invoke(b"")
        self.assertEqual(refusal.exception.status_code, 422)
        self.assertFalse(self.server.slot.locked())

    async def test_disconnect_kills_reaps_before_releasing_slot_and_media(self):
        with patch.object(self.server.subprocess, "Popen", side_effect=self.spawn):
            task = asyncio.create_task(self.invoke())
            await asyncio.wait_for(self.started.wait(), timeout=2)
            self.disconnected.set()
            with self.assertRaises(HTTPException) as refusal:
                await asyncio.wait_for(task, timeout=2)
            self.assertEqual(refusal.exception.status_code, 499)
            self.assertEqual(self.children[0].returncode, -9)
            await self.assert_settled_and_reusable()

    async def test_coroutine_cancellation_reaps_child_and_releases_slot(self):
        with patch.object(self.server.subprocess, "Popen", side_effect=self.spawn):
            task = asyncio.create_task(self.invoke())
            await asyncio.wait_for(self.started.wait(), timeout=2)
            task.cancel()
            with self.assertRaises(HTTPException) as refusal:
                await task
            self.assertEqual(refusal.exception.status_code, 504)
            await self.assert_settled_and_reusable()

    async def test_repeated_cancellation_cannot_interrupt_reaping_or_release_slot_early(self):
        def delayed_spawn(args, **kwargs):
            process = self.spawn(args, **kwargs)
            wait = process.wait
            def delayed_wait(*values, **options):
                result = wait(*values, **options)
                time.sleep(0.15)
                return result
            process.wait = delayed_wait
            return process
        with patch.object(self.server.subprocess, "Popen", side_effect=delayed_spawn):
            task = asyncio.create_task(self.invoke())
            await asyncio.wait_for(self.started.wait(), timeout=2)
            task.cancel()
            await asyncio.sleep(0.02)
            self.assertTrue(self.server.slot.locked())
            task.cancel()
            await asyncio.sleep(0.02)
            self.assertTrue(self.server.slot.locked())
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            await self.assert_settled_and_reusable()

    async def test_accelerated_deadline_path_uses_one_original_55_second_budget(self):
        wait = asyncio.wait
        async def accelerated_wait(tasks, *, timeout, return_when):
            self.assertGreater(timeout, 54)
            self.assertLessEqual(timeout, 55)
            return await wait(tasks, timeout=0.02, return_when=return_when)
        with patch.object(self.server.subprocess, "Popen", side_effect=self.spawn), patch.object(self.server.asyncio, "wait", side_effect=accelerated_wait):
            with self.assertRaises(HTTPException) as refusal:
                await self.invoke()
            self.assertEqual(refusal.exception.status_code, 504)
            await self.assert_settled_and_reusable()

    async def test_engine_failure_cannot_return_receipt_or_retain_media(self):
        def fail(args, **kwargs):
            process = self.original_popen([sys.executable, "-B", "-c", "raise SystemExit(2)"], **kwargs)
            self.children.append(process)
            return process
        with patch.object(self.server.subprocess, "Popen", side_effect=fail):
            with self.assertRaises(HTTPException) as refusal:
                await self.invoke()
            self.assertEqual(refusal.exception.status_code, 422)
            await self.assert_settled_and_reusable()

    async def test_completed_upload_disconnect_monitor_does_not_reuse_upload_timeout(self):
        messages = iter([{"type": "http.request", "body": b"complete", "more_body": False},
                         {"type": "http.disconnect"}])
        bounded_reads = 0
        wait_for = asyncio.wait_for
        async def bounded_read(awaitable, timeout):
            nonlocal bounded_reads
            bounded_reads += 1
            return await wait_for(awaitable, timeout)
        async def receive():
            return next(messages)
        async def send(message):
            pass
        async def app(scope, receive, send):
            self.assertEqual((await receive())["type"], "http.request")
            self.assertEqual((await receive())["type"], "http.disconnect")
        scope = {"type": "http", "method": "POST", "path": "/v1/audio/transcriptions",
                 "headers": [(b"authorization", ("Bearer " + self.server.TOKEN).encode())]}
        with patch.object(self.server.asyncio, "wait_for", side_effect=bounded_read):
            await self.server.LimitsAndAuthentication(app)(scope, receive, send)
        self.assertEqual(bounded_reads, 1)


if __name__ == "__main__":
    unittest.main()
