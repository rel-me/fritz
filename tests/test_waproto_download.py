"""Exercise verified descriptor caching through real HTTP and competing processes."""
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/prepare-waproto.py"
spec = importlib.util.spec_from_file_location("waproto_download", SCRIPT)
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)


class DescriptorDownloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fritz descriptor ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.payload = b"pinned descriptor fixture" * 100
        self.sha = hashlib.sha256(self.payload).hexdigest()

    def server(self, payload, *, gate=False, declared_size=None):
        started, release = threading.Event(), threading.Event()
        if not gate:
            release.set()
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_response(200)
                self.send_header("Content-Length", str(declared_size or len(payload)))
                self.end_headers()
                middle = len(payload) // 2
                try:
                    self.wfile.write(payload[:middle])
                    self.wfile.flush()
                    started.set()
                    release.wait(10)
                    self.wfile.write(payload[middle:])
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.addCleanup(release.set)
        return server, f"http://127.0.0.1:{server.server_port}/descriptor", requests, started, release

    def destination(self):
        return self.root / "downloads/waproto" / f"{self.sha}.desc"

    def test_verified_download_is_reused_offline_without_touching_its_timestamp(self):
        server, url, requests, _started, _release = self.server(self.payload)
        path = download.prepare(self.root, url, self.sha)
        self.assertEqual(path.read_bytes(), self.payload)
        timestamp = path.stat().st_mtime_ns
        server.shutdown()
        server.server_close()
        self.assertEqual(download.prepare(self.root, url, self.sha), path)
        self.assertEqual(path.stat().st_mtime_ns, timestamp)
        self.assertEqual(len(requests), 1)

    def test_bad_or_truncated_download_is_not_published(self):
        for body in (b"wrong bytes", self.payload[:50]):
            with self.subTest(size=len(body)):
                _server, url, _requests, _started, _release = self.server(
                    body, declared_size=len(self.payload))
                with self.assertRaises((ValueError, OSError, http.client.HTTPException)):
                    download.prepare(self.root, url, self.sha)
                self.assertFalse(self.destination().exists())
                self.assertEqual(list(self.root.rglob("*.partial")), [])

    def test_corrupt_cached_input_fails_without_silent_replacement(self):
        _server, url, requests, _started, _release = self.server(self.payload)
        path = self.destination()
        path.parent.mkdir(parents=True)
        path.write_bytes(b"corrupt cache")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            download.prepare(self.root, url, self.sha)
        self.assertEqual(path.read_bytes(), b"corrupt cache")
        self.assertEqual(requests, [])

    def test_oversized_response_is_bounded_even_with_a_matching_checksum(self):
        payload = b"x" * (download.MAX_BYTES + 1)
        sha = hashlib.sha256(payload).hexdigest()
        _server, url, _requests, _started, _release = self.server(payload)
        with self.assertRaisesRegex(ValueError, "download limit"):
            download.prepare(self.root, url, sha)
        self.assertFalse((self.root / "downloads/waproto" / f"{sha}.desc").exists())
        self.assertEqual(list(self.root.rglob("*.partial")), [])

    def test_competing_processes_download_once_and_publish_atomically(self):
        _server, url, requests, started, release = self.server(self.payload, gate=True)
        worker = self.root / "worker.py"
        worker.write_text(
            "import importlib.util, pathlib, sys\n"
            "spec=importlib.util.spec_from_file_location('download',sys.argv[1])\n"
            "module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)\n"
            "pathlib.Path(sys.argv[5]).touch()\n"
            "print(module.prepare(pathlib.Path(sys.argv[2]),sys.argv[3],sys.argv[4]))\n")
        processes = []
        try:
            for index in range(2):
                marker = self.root / f"started-{index}"
                processes.append(subprocess.Popen([sys.executable, str(worker), str(SCRIPT),
                    str(self.root), url, self.sha, str(marker)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE))
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists(), "download worker never started")
                if index == 0:
                    self.assertTrue(started.wait(5), "first HTTP request never started")
            with self.assertRaises(subprocess.TimeoutExpired):
                processes[1].communicate(timeout=0.3)
            self.assertFalse(self.destination().exists(), "partial input became visible")
            release.set()
            for process in processes:
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, (stdout + stderr).decode())
            self.assertEqual(len(requests), 1)
            self.assertEqual(self.destination().read_bytes(), self.payload)
        finally:
            release.set()
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                process.communicate(timeout=10)


if __name__ == "__main__":
    unittest.main()
