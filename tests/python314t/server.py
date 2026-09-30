import json
import os
import sys
import sysconfig
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


FREE_THREADED_BUILD = sysconfig.get_config_var("Py_GIL_DISABLED") == 1
GIL_ENABLED = sys._is_gil_enabled()
EXPECTED_GIL = os.getenv("EXPECTED_GIL")
DEFAULT_ITERATIONS = int(os.getenv("CPU_WORK_ITERATIONS", "250000"))


if not FREE_THREADED_BUILD:
    raise RuntimeError("benchmark requires a CPython free-threaded build")

if EXPECTED_GIL is not None:
    expected = EXPECTED_GIL == "1"
    if GIL_ENABLED != expected:
        raise RuntimeError(
            f"PYTHON_GIL validation failed: expected gil_enabled={expected}, actual={GIL_ENABLED}"
        )


def cpu_work(iterations: int) -> int:
    # Pure-Python integer work: native extensions would blur the GIL A/B test.
    value = 0x12345678
    for i in range(iterations):
        value = ((value ^ i) * 1664525 + 1013904223) & 0xFFFFFFFF
        value ^= value >> 13
    return value


class Handler(BaseHTTPRequestHandler):
    server_version = "python314t-benchmark/1.0"

    def send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.send_json(200, {
                "status": "ok",
                "python": sys.version.split()[0],
                "free_threaded_build": FREE_THREADED_BUILD,
                "gil_enabled": GIL_ENABLED,
                "thread": threading.get_ident(),
            })
            return

        if parsed.path == "/cpu":
            query = parse_qs(parsed.query)
            iterations = int(query.get("iterations", [DEFAULT_ITERATIONS])[0])
            iterations = max(1, min(iterations, 5_000_000))
            started = time.perf_counter()
            result = cpu_work(iterations)
            elapsed_ms = (time.perf_counter() - started) * 1000
            self.send_json(200, {
                "status": "ok",
                "iterations": iterations,
                "result": result,
                "duration_ms": round(elapsed_ms, 3),
                "gil_enabled": GIL_ENABLED,
                "thread": threading.get_ident(),
            })
            return

        self.send_json(404, {"status": "not_found"})

    def log_message(self, format: str, *args) -> None:
        return


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print(json.dumps({
        "python": sys.version,
        "free_threaded_build": FREE_THREADED_BUILD,
        "gil_enabled": GIL_ENABLED,
        "cpu_count": os.cpu_count(),
    }), flush=True)
    Server(("0.0.0.0", 8080), Handler).serve_forever()
