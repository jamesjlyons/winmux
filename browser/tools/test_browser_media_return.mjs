#!/usr/bin/env node
// Bounded renderer/media lifecycle check. Explicit lifecycle transitions do not
// qualify WinMux's automatic deadlines or an authenticated Twitter session.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import {spawn, execFileSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';

const args = process.argv.slice(2);
if (![6, 7].includes(args.length) || args[0] !== '--app' || args[2] !== '--chromium-source' || args[4] !== '--output' ||
    (args.length === 7 && args[6] !== '--headed')) {
  throw new Error('Usage: node test_browser_media_return.mjs --app APP --chromium-source SOURCE --output NEW_DIRECTORY [--headed]');
}
const headed = args[6] === '--headed';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const app = fs.realpathSync(args[1]);
const source = fs.realpathSync(args[3]);
const output = path.resolve(args[5]);
const sha256 = data => crypto.createHash('sha256').update(data).digest('hex');
const bytes = fs.readFileSync(path.join(path.dirname(app), 'winmux-package-manifest.json'));
const manifest = JSON.parse(bytes);
const executable = path.join(app, 'Contents/MacOS/Chromium');
if (!manifest.verified || sha256(fs.readFileSync(executable)) !== manifest.browser_executable_sha256) {
  throw new Error('Verified package manifest does not match browser');
}
execFileSync('codesign', ['--verify', '--deep', '--strict', app]);
const revision = JSON.parse(fs.readFileSync(path.join(root, 'browser/chromium/pins.json'))).chromium.revision;
if (execFileSync('git', ['rev-parse', 'HEAD'], {cwd: source, encoding: 'utf8'}).trim() !== revision) {
  throw new Error('Media source is not the pinned Chromium revision');
}
const payloads = new Map();
for (const name of ['bear-1280x720.mp4', 'bear-1280x720-av_frag.mp4', 'bear-vp9-opus.webm']) {
  const data = fs.readFileSync(path.join(source, 'media/test/data', name));
  const pinned = execFileSync('git', ['show', `HEAD:media/test/data/${name}`], {cwd: source, maxBuffer: 20 * 1024 * 1024});
  if (!data.equals(pinned)) throw new Error('Modified media fixture: ' + name);
  payloads.set('/' + name, data);
}
payloads.set('/', fs.readFileSync(path.join(root, 'browser/tests/fixtures/media_background_return.html')));
fs.mkdirSync(output, {recursive: false, mode: 0o700});
// Chromium gates chrome://discards behind an opt-in preference. Enable it only
// in the new diagnostic profile, before the browser opens that profile.
fs.mkdirSync(path.join(output, 'profile'), {mode: 0o700});
fs.writeFileSync(path.join(output, 'profile/Local State'), JSON.stringify({internal_only_uis_enabled: true}), {mode: 0o600});
const report = {passed: false, scope: `isolated_${headed ? 'headed' : 'headless'}_media_background_freeze_discard_return`,
  package_manifest_sha256: sha256(bytes), fixture_chromium_revision: revision,
  fixture_sha256: Object.fromEntries([...payloads].map(([name, data]) => [name, sha256(data)])),
  cases: [], limits: ['Pinned local clips and a fresh profile; no authenticated Twitter, extensions, or user data.',
    `${headed ? 'Native browser window' : 'Headless browser'} with explicit freeze/discard; no managed workspace, automatic aging, or compositor qualification.`,
    'Short bounded transitions; long-duration testing remains deferred.']};
const journal = (event, data = {}) => fs.appendFileSync(path.join(output, 'journal.jsonl'), JSON.stringify({ms: performance.now(), event, ...data}) + '\n');
const server = http.createServer((req, res) => {
  const name = new URL(req.url, 'http://localhost').pathname;
  const data = payloads.get(name);
  if (!data) {res.writeHead(404); res.end(); return;}
  res.writeHead(200, {'Content-Type': name === '/' ? 'text/html' : name.endsWith('.webm') ? 'video/webm' : 'video/mp4',
    'Content-Length': data.length, 'Cache-Control': 'no-store'});
  res.end(data);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}/`;
let child, ws, exitStatus, next = 0;
const pending = new Map(), crashes = [];
function healthy() {
  if (exitStatus) throw new Error('Unexpected browser exit: ' + JSON.stringify(exitStatus));
  if (crashes.length) throw new Error('Unexpected renderer crash: ' + JSON.stringify(crashes));
  const log = fs.readFileSync(path.join(output, 'browser.log'), 'utf8');
  if (/FATAL:|CHECK failed|DCHECK failed|Received signal/.test(log)) throw new Error('Fatal error in browser process tree; see browser.log');
}
async function until(predicate, seconds = 15) {
  const end = Date.now() + seconds * 1000;
  while (Date.now() < end) {healthy(); const value = await predicate(); if (value) return value; await delay(100);}
  throw new Error(`Condition timed out after ${seconds}s`);
}
function call(method, params = {}, sessionId, timeout = 10000) {
  const id = ++next;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {pending.delete(id); reject(new Error(method + ' timed out'));}, timeout);
    pending.set(id, {resolve, reject, timer});
    ws.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
  });
}
async function evaluate(session, expression) {
  const result = await call('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true}, session);
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result?.value;
}
async function play(session) {
  await until(async () => await evaluate(session, '!document.hidden'));
  await until(async () => {
    const ready = await evaluate(session, 'window.fixture && ({ready:fixture.ready,errors:fixture.errors})');
    if (ready?.errors.length) throw new Error('Media load error: ' + JSON.stringify(ready.errors));
    return ready?.ready;
  });
  const before = await evaluate(session, 'resumePlayback()');
  return until(async () => {
    const value = await evaluate(session, 'snapshot()');
    if (value.errors.length || value.mediaError) throw new Error('Media failed after return: ' + JSON.stringify(value));
    return !value.paused && value.frames > before.frames + 2 ? value : null;
  });
}
const log = fs.openSync(path.join(output, 'browser.log'), 'wx', 0o600);
try {
  child = spawn(executable, [`--user-data-dir=${path.join(output, 'profile')}`, ...(headed ? [] : ['--headless=new']),
    '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1', '--no-first-run',
    '--no-default-browser-check', '--disable-background-networking', '--enable-logging=stderr',
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
    `--winmux-test-service=com.jameslyons.winmux.browser.alpha.workspace.test.${crypto.randomUUID()}`, 'about:blank'],
    {stdio: ['ignore', log, log]});
  child.on('error', error => {exitStatus = {spawn_error: String(error)};});
  child.on('exit', (code, signal) => {exitStatus = {code, signal}; journal('browser_exit', exitStatus);});
  report.browser_pid = child.pid;
  const active = path.join(output, 'profile/DevToolsActivePort');
  await until(() => fs.existsSync(active));
  const [port, suffix] = fs.readFileSync(active, 'utf8').trim().split('\n');
  ws = new WebSocket(`ws://127.0.0.1:${port}${suffix}`);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('CDP connect timeout')), 5000);
    ws.addEventListener('open', () => {clearTimeout(timer); resolve();}, {once: true});
    ws.addEventListener('error', () => {clearTimeout(timer); reject(new Error('CDP connection failed'));}, {once: true});
  });
  ws.addEventListener('message', event => {
    const data = JSON.parse(event.data);
    if (data.id) {
      const item = pending.get(data.id);
      if (item) {clearTimeout(item.timer); pending.delete(data.id); data.error ? item.reject(new Error(JSON.stringify(data.error))) : item.resolve(data.result);}
    } else if (/crash/i.test(data.method)) {crashes.push(data); journal('crash', data);}
  });
  ws.addEventListener('close', () => {
    for (const item of pending.values()) {clearTimeout(item.timer); item.reject(new Error('CDP disconnected'));}
    pending.clear();
  });
  await call('Target.setDiscoverTargets', {discover: true});
  const diagnostic = await call('Target.createTarget', {url: 'chrome://discards/'});
  const diagnosticSession = (await call('Target.attachToTarget', {targetId: diagnostic.targetId, flatten: true})).sessionId;
  await until(async () => await evaluate(diagnosticSession, 'document.readyState === "complete"'));
  await evaluate(diagnosticSession, 'import("/discards.js").then(m => { window.provider = m.getOrCreateDetailsProvider(); return true; })');
  for (const kind of ['mp4', 'mse', 'webm']) {
    console.log('Testing background media return: ' + kind);
    const url = base + '?kind=' + kind;
    let target = (await call('Target.createTarget', {url})).targetId;
    let session = (await call('Target.attachToTarget', {targetId: target, flatten: true})).sessionId;
    await call('Page.bringToFront', {}, session);
    const initial = await play(session);
    const record = {kind, passed: false, initial, transitions: []};
    report.cases.push(record);
    if (headed) {
      const {windowId} = await call('Browser.getWindowForTarget', {targetId: target});
      record.native_window = {windowId, ...(await call('Browser.getWindowBounds', {windowId}))};
      if (record.native_window.bounds.windowState === 'minimized') throw new Error('Media window is minimized');
    }
    await call('Target.activateTarget', {targetId: diagnostic.targetId});
    await until(async () => await evaluate(session, 'document.hidden'));
    await delay(10000);
    await call('Page.bringToFront', {}, session);
    record.transitions.push({kind: 'background_return', hidden_ms: 10000, after: await play(session)});
    for (let cycle = 0; cycle < 2; cycle++) {
      await call('Target.activateTarget', {targetId: diagnostic.targetId});
      await until(async () => await evaluate(session, 'document.hidden'));
      await call('Page.setWebLifecycleState', {state: 'frozen'}, session);
      journal('frozen', {kind, cycle});
      await delay(5000);
      healthy();
      await call('Page.setWebLifecycleState', {state: 'active'}, session);
      await call('Page.bringToFront', {}, session);
      const after = await play(session);
      const frozen = after.events.findLast(event => event.type === 'freeze');
      const resumed = after.events.findLast(event => event.type === 'resume');
      if (!frozen || !resumed || resumed.beats !== frozen.beats || after.token !== initial.token || after.discarded) {
        throw new Error('Freeze/resume lifecycle evidence is invalid: ' + JSON.stringify(after));
      }
      record.transitions.push({kind: 'freeze_return', cycle, frozen_ms: 5000, after});
    }
    // Pause and detach DevTools before a real WebContents discard. Query only
    // this fixture URL and require the discarded state before returning.
    await evaluate(session, 'document.querySelector("video").pause()');
    await call('Target.activateTarget', {targetId: diagnostic.targetId});
    await until(async () => await evaluate(session, 'document.hidden'));
    await call('Target.detachFromTarget', {sessionId: session});
    const rowExpression = `(await provider.getTabDiscardsInfo()).infos.find(row => row.tabUrl === ${JSON.stringify(url)})`;
    const row = await evaluate(diagnosticSession, `(async () => ${rowExpression})()`);
    if (!row) throw new Error('Fixture is missing from discard inventory');
    record.discard_before = row;
    await evaluate(diagnosticSession, `provider.discardById(${row.id}, 0).then(() => true)`);
    const discarded = await until(async () => {
      const value = await evaluate(diagnosticSession, `(async () => ${rowExpression})()`);
      return value?.state === 5 ? value : null;
    });
    const targets = (await call('Target.getTargets')).targetInfos.filter(row => row.type === 'page' && row.url === url);
    if (targets.length !== 1) throw new Error('Discard lost or duplicated the logical fixture tab');
    target = targets[0].targetId;
    await call('Target.activateTarget', {targetId: target});
    session = (await call('Target.attachToTarget', {targetId: target, flatten: true})).sessionId;
    await call('Page.bringToFront', {}, session);
    const after = await play(session);
    if (!after.discarded || after.token !== initial.token) throw new Error('Discard return did not preserve logical tab state');
    record.transitions.push({kind: 'discard_return', discarded, after});
    healthy();
    record.passed = true;
    journal('codec_complete', {kind});
    await call('Target.closeTarget', {targetId: target});
    fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(report, null, 2) + '\n');
  }
  report.passed = report.cases.length === 3 && report.cases.every(item => item.passed);
} catch (error) {report.error = String(error); journal('failure', {error: report.error});}
finally {
  if (child && !exitStatus) {
    try {await call('Browser.close');} catch {}
    for (let i = 0; i < 50 && !exitStatus; i++) await delay(100);
    if (!exitStatus) child.kill('SIGTERM');
    for (let i = 0; i < 50 && !exitStatus; i++) await delay(100);
    if (!exitStatus) {child.kill('SIGKILL'); await new Promise(resolve => child.once('exit', resolve));}
  }
  ws?.close(); fs.closeSync(log); server.closeAllConnections(); server.close();
  report.exit_after_cleanup = exitStatus;
  report.crashes = crashes;
  if (crashes.length || /FATAL:|CHECK failed|DCHECK failed|Received signal/.test(fs.readFileSync(path.join(output, 'browser.log'), 'utf8'))) {
    report.passed = false;
    report.error ||= 'Unexpected fatal error in browser process tree';
  }
  fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(report, null, 2) + '\n');
}
console.log(JSON.stringify({passed: report.passed, error: report.error, codecs: report.cases.map(row => ({kind: row.kind, passed: row.passed, transitions: row.transitions.length}))}));
process.exitCode = report.passed ? 0 : 1;
