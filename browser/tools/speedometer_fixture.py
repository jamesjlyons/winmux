#!/usr/bin/env python3
"""Serve pinned Speedometer 3.1 assets and export results without UI polling.

The benchmark sources and default timing/iteration settings are unchanged. A
module wrapper exports its existing completion callback and records page focus,
visibility and viewport. Use a separate native environment recording as well.
This is a development baseline, not full-workload performance qualification.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import secrets
import threading
import time
from urllib.parse import unquote, urlsplit


SCRIPT = r'''
import "/resources/main.mjs";
const client = globalThis.benchmarkClient;
const events = [];
const state = () => ({wall_ms: Date.now(), monotonic_ms: performance.now(),
  focused: document.hasFocus(), visibility: document.visibilityState,
  width: innerWidth, height: innerHeight, device_pixel_ratio: devicePixelRatio});
for (const name of ["focus", "blur", "visibilitychange", "resize"])
  window.addEventListener(name, () => events.push({event: name, ...state()}));
let start;
const originalStart = client.willStartFirstIteration;
client.willStartFirstIteration = function(...args) {
  start = state();
  events.length = 0;
  return originalStart.apply(this, args);
};
const originalEnd = client.didFinishLastIteration;
client.didFinishLastIteration = function(metrics) {
  const end = state();
  originalEnd.call(this, metrics);
  fetch(ENDPOINT, {method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({start, end, events, user_agent: navigator.userAgent,
      time_origin_ms: performance.timeOrigin, metrics})})
    .then(r => { if (!r.ok) throw new Error(`export ${r.status}`); })
    .catch(e => { document.title = `RESULT EXPORT FAILED: ${e.message}`; });
};
// Preparation time permits the operator to verify the selected window, then
// start the native observer before the benchmark. No polling occurs in the run.
window.addEventListener("DOMContentLoaded", () => {
  setTimeout(() => {
    if (document.hasFocus() && document.visibilityState === "visible") client.start();
    else document.title = "NOT RUN: Speedometer page must be focused";
  }, 20000);
});
'''


def asset_manifest(root):
    """Content-address all assets, including compiled framework applications."""
    digest = hashlib.sha256()
    count = 0
    for path in sorted(root.rglob("*")):
        if path.is_file():
            if path.is_symlink():
                raise ValueError("Benchmark assets must not be symlinks")
            relative = path.relative_to(root).as_posix()
            file_hash = hashlib.sha256(path.read_bytes()).hexdigest()
            digest.update(f"{relative}\0{file_hash}\n".encode())
            count += 1
    return {"files": count, "tree_sha256": digest.hexdigest()}


def page_conditions(result):
    problems = []
    start, end = result["start"], result["end"]
    if end["monotonic_ms"] <= start["monotonic_ms"]:
        problems.append("Non-positive benchmark interval")
    states = [start, *result["events"], end]
    for item in states:
        if item["visibility"] != "visible" or not item["focused"]:
            problems.append("Page was hidden or unfocused")
        if item["width"] < 850 or item["height"] < 650:
            problems.append("Viewport smaller than Speedometer requirements")
        if any(item[k] != start[k] for k in ("width", "height", "device_pixel_ratio")):
            problems.append("Viewport changed during benchmark")
    return sorted(set(problems))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", nargs="+", required=True)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    root = args.assets.resolve(strict=True)
    entry = (root / "index.html").read_text()
    source_tag = '<script src="resources/main.mjs" type="module"></script>'
    if entry.count(source_tag) != 1 or "Speedometer 3.1" not in entry:
        parser.error("Expected the pinned Speedometer 3.1 entry point")
    if any(not re.fullmatch(r"[a-z0-9-]{1,60}", run) for run in args.runs) or len(set(args.runs)) != len(args.runs):
        parser.error("Run names must be unique lowercase identifiers")
    args.output.mkdir(parents=True, exist_ok=False)
    provenance = {"scope": "local_speedometer_3_1_engine_baseline",
                  "assets": asset_manifest(root), "fixture_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  "iteration_count": 10, "benchmark_timing_modified": False,
                  "benchmark_qualified": False}
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    token = secrets.token_hex(16)
    prefix = "/__winmux/" + token + "/"
    lock = threading.Lock()

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(root), **kw)

        def log_message(self, *_):
            pass

        def reply(self, code, body=b"", content_type="text/plain"):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlsplit(self.path).path
            for run in args.runs:
                base = prefix + run
                if path == base:
                    page = entry.replace("<head>", '<head><base href="/">', 1).replace(
                        source_tag, f'<script src="{base}/driver.mjs" type="module"></script>')
                    self.reply(200, page.encode(), "text/html")
                    return
                if path == base + "/driver.mjs":
                    script = SCRIPT.replace("ENDPOINT", json.dumps(base + "/result"))
                    self.reply(200, script.encode(), "text/javascript")
                    return
            candidate = (root / unquote(path).lstrip("/")).resolve()
            contained = candidate == root or root in candidate.parents
            servable = candidate.is_file() or (candidate.is_dir() and (candidate / "index.html").is_file())
            if not contained or not servable:
                self.reply(404)
                return
            super().do_GET()

        def do_POST(self):
            paths = {prefix + run + "/result": run for run in args.runs}
            run = paths.get(self.path)
            origin = f"http://127.0.0.1:{self.server.server_port}"
            if run is None or self.headers.get("Origin") != origin:
                self.reply(403)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 8 * 1024 * 1024:
                    raise ValueError("Invalid report size")
                result = json.loads(self.rfile.read(length))
                problems = page_conditions(result)
                metrics = result["metrics"]
                if not isinstance(metrics, dict) or "Score" not in metrics:
                    raise ValueError("No benchmark Score")
            except (ValueError, TypeError, KeyError):
                self.reply(400)
                return
            report = {**provenance, "run": run, "received_utc": datetime.now(timezone.utc).isoformat(),
                      "received_monotonic_ns": time.monotonic_ns(),
                      "page_condition_problems": problems, "result": result}
            with lock:
                try:
                    with (args.output / (run + ".json")).open("x") as stream:
                        json.dump(report, stream, indent=2, allow_nan=False)
                        stream.write("\n")
                except FileExistsError:
                    self.reply(409)
                    return
            print(json.dumps({"completed": run, "score": metrics["Score"], "page_condition_problems": problems}), flush=True)
            self.reply(201, b"recorded")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    urls = {run: f"http://127.0.0.1:{server.server_port}{prefix}{run}" for run in args.runs}
    (args.output / "urls.json").write_text(json.dumps(urls, indent=2) + "\n")
    print(json.dumps(urls), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
