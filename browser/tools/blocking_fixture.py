#!/usr/bin/env python3
"""Local-only browser integration fixture; traffic counts distinguish blocking from CORS errors.

Launch the alpha with --host-resolver-rules="MAP winmux.test 127.0.0.1, MAP
ad.doubleclick.net 127.0.0.1" and navigate to the URL printed by this server.
No request is sent to the real advertising domain. The pinned EasyList already
contains its network rule and the .ADBAR cosmetic selector; no test rules are
injected into the product.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
from threading import Lock
from urllib.parse import urlsplit


PAGE = r'''<!doctype html><meta charset="utf-8"><title>WinMux blocking integration</title>
<style>body{font:20px system-ui;max-width:800px;margin:50px auto}pre{white-space:pre-wrap}.ADBAR{padding:20px;background:#fcc}</style>
<h1>WinMux blocking integration</h1><p>Local test traffic with the bundled EasyList and EasyPrivacy.</p>
<div class="ADBAR" id="initial-ad">Cosmetic test: this ad placeholder should be hidden.</div>
<div id="content">Ordinary page content remains visible.</div><pre id="status">Running…</pre>
<script>
(async()=>{
 const result={};
 const ad='http://ad.doubleclick.net:PORT';
 const probe=async(url)=>{try{return (await fetch(url)).ok}catch{return false}};
 result.allowed_request=await probe('/allowed.txt');
 result.direct_request_blocked=!(await probe(ad+'/direct-ad.txt'));
 result.redirect_blocked=!(await probe('/redirect'));
 result.worker_request_blocked=await new Promise(resolve=>{
   const w=new Worker('/worker.js');
   const timer=setTimeout(()=>{w.terminate();resolve(false)},10000);
   w.onmessage=e=>{clearTimeout(timer);w.terminate();resolve(e.data===true)};
   w.onerror=()=>{clearTimeout(timer);w.terminate();resolve(false)};
 });
 for(let i=0;i<100;i++){
   if(getComputedStyle(document.getElementById('initial-ad')).display==='none')break;
   await new Promise(r=>setTimeout(r,50));
 }
 result.initial_cosmetic_hidden=getComputedStyle(document.getElementById('initial-ad')).display==='none';
 const later=document.createElement('div');later.className='ADBAR';later.textContent='Later matching ad';document.body.append(later);
 await new Promise(r=>requestAnimationFrame(r));
 result.later_matching_selector_hidden=getComputedStyle(later).display==='none';
 // Introduce a token absent from the initial document so this also exercises
 // the renderer's bounded mutation queries, not only an existing stylesheet.
 const dynamic=document.createElement('div');dynamic.className='ADBox';dynamic.textContent='New cosmetic token';document.body.append(dynamic);
 for(let i=0;i<100;i++){
   if(getComputedStyle(dynamic).display==='none')break;
   await new Promise(r=>setTimeout(r,50));
 }
 result.new_token_cosmetic_hidden=getComputedStyle(dynamic).display==='none';
 result.normal_content_visible=getComputedStyle(document.getElementById('content')).display!=='none';
 document.getElementById('status').textContent=JSON.stringify(result,null,2);
 await fetch('/report/TOKEN',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(result)});
})();
</script>'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    token = secrets.token_hex(16)
    counts = Counter()
    lock = Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *values):
            pass

        def reply(self, code, body=b"", content_type="text/plain", location=None):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "no-store")
            if location:
                self.send_header("Location", location)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlsplit(self.path).path
            with lock:
                counts[path] += 1
            port = self.server.server_port
            if path == "/":
                page = PAGE.replace("PORT", str(port)).replace("TOKEN", token)
                self.reply(200, page.encode(), "text/html")
            elif path == "/redirect":
                self.reply(302, location=f"http://ad.doubleclick.net:{port}/redirect-ad.txt")
            elif path == "/worker.js":
                body = f"fetch('http://ad.doubleclick.net:{port}/worker-ad.txt').then(()=>postMessage(false)).catch(()=>postMessage(true));"
                self.reply(200, body.encode(), "text/javascript")
            else:
                self.reply(200, b"fixture response")

        def do_POST(self):
            if self.path != "/report/" + token:
                self.reply(404)
                return
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 8192:
                self.reply(400)
                return
            result = json.loads(self.rfile.read(length))
            with lock:
                traffic = dict(counts)
            blocked_paths = ("/direct-ad.txt", "/redirect-ad.txt", "/worker-ad.txt")
            absent = all(traffic.get(path, 0) == 0 for path in blocked_paths)
            report = {"scope": "local_chromium_network_and_dynamic_cosmetic_integration",
                      "recorded_utc": datetime.now(timezone.utc).isoformat(),
                      "page_checks": result, "server_requests": traffic,
                      "blocked_targets_never_reached_server": absent,
                      "passed": bool(result) and all(v is True for v in result.values()) and absent,
                      "limits": ["No performance qualification, profile/site switches, replacements or WebSocket coverage"]}
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report), flush=True)
            self.reply(200, b"recorded")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"http://winmux.test:{server.server_port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
