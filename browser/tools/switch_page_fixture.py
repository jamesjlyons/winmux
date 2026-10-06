"""Loopback-only synthetic pages for live switching; no browser scripting API."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import secrets
import threading
import time

PAGE = r'''<!doctype html><meta charset="utf-8"><title>WinMux speed fixture</title>
<style>body{background:hsl(PAGEHUE 55% 22%);color:white;font:24px system-ui;padding:60px}</style>
<h1>Page PAGEID</h1><p id="status">Ready for a switch</p>
<script>
const page = PAGEID;
const state = () => ({page, visible: document.visibilityState === 'visible',
  focused: document.hasFocus(), discarded: document.wasDiscarded,
  width: innerWidth, height: innerHeight, pixel_ratio: devicePixelRatio,
  page_time_ms: performance.now()});
const report = (kind, extra = {}) => fetch('ENDPOINT', {method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({kind,...state(),...extra})});
let inputSequence = 0;
// Page zero exercises an independent Chromium freeze protection. It is not a
// form or an active page, and never releases the lock during this fixture.
if (page === 0) navigator.locks.request('winmux-speed-protection', () => {
  report('protected_lock');
  return new Promise(() => {});
});
function shown() {
  if (document.visibilityState !== 'visible') return;
  requestAnimationFrame(() => requestAnimationFrame(() => report('frame_callbacks')));
}
addEventListener('focus', () => {report('focus'); shown();});
document.addEventListener('visibilitychange', shown);
document.addEventListener('freeze', () => report('freeze'));
document.addEventListener('resume', () => report('resume'));
addEventListener('keydown', e => {
  if (e.code === 'F13' || e.key === 'F13' || e.code === 'PrintScreen')
    fetch('ENDPOINT', {method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({kind:'probe_key',code:e.code,key:e.key,trusted:e.isTrusted,...state()})});
  if (e.code !== 'F13' || !e.isTrusted) return;
  e.preventDefault();
  const input_sequence = ++inputSequence;
  document.getElementById('status').textContent = 'Keyboard input received';
  report('input', {input_sequence});
  requestAnimationFrame(() => requestAnimationFrame(() => report('input_frame_callbacks', {input_sequence})));
});
report('loaded'); shown();
</script>'''


class SwitchPages:
    def __init__(self, count):
        self.events = []
        self.condition = threading.Condition()
        self.token = secrets.token_hex(16)
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def reply(self, status, data=b"", content_type="text/plain"):
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Content-Type", content_type)
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                pages = {f"/{owner.token}/{i}": i for i in range(count)}
                if self.path not in pages:
                    self.reply(404)
                    return
                page = pages[self.path]
                data = PAGE.replace("PAGEHUE", str(page * 47 % 360)).replace("PAGEID", str(page))
                data = data.replace("ENDPOINT", f"/{owner.token}/event")
                self.reply(200, data.encode(), "text/html")

            def do_POST(self):
                received = time.perf_counter_ns()
                if self.path != f"/{owner.token}/event" or self.headers.get("Origin") != owner.origin:
                    self.reply(403)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= 4096:
                        raise ValueError("invalid length")
                    event = json.loads(self.rfile.read(length))
                    if type(event.get("page")) is not int or not 0 <= event["page"] < count:
                        raise ValueError("invalid fixture page")
                except (ValueError, TypeError):
                    self.reply(400)
                    return
                with owner.condition:
                    owner.events.append(dict(event, received_ns=received))
                    owner.condition.notify_all()
                self.reply(204)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.urls = [f"{self.origin}/{self.token}/{i}" for i in range(count)]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def wait(self, kind, since, *, page=None, input_sequence=None, timeout=5):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                match = next((e for e in self.events if e["received_ns"] >= since and e["kind"] == kind
                              and (page is None or e["page"] == page)
                              and (input_sequence is None or e.get("input_sequence") == input_sequence)), None)
                if match is not None:
                    return match
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"No {kind} acknowledgement from fixture page {page}")
                self.condition.wait(remaining)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
