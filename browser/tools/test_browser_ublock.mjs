#!/usr/bin/env node
// Full uBlock component qualification in fresh, isolated profiles. Node 22+.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { randomUUID, createHash } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, i, all) => {
  if (i % 2 === 0) pairs.push([value.replace(/^--/, ''), all[i + 1]]);
  return pairs;
}, []));
assert(args.app && args.output, 'Use --app <staged app> --output <new directory>');
args.app = fs.realpathSync(args.app);
const manifestBytes = fs.readFileSync(path.join(path.dirname(args.app), 'winmux-package-manifest.json'));
const manifest = JSON.parse(manifestBytes);
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
assert(manifest.verified, 'A verified signed package is required');
assert.equal(sha256(fs.readFileSync(path.join(args.app, 'Contents/MacOS/Chromium'))), manifest.browser_executable_sha256);
execFileSync('codesign', ['--verify', '--deep', '--strict', args.app]);
const output = path.resolve(args.output);
fs.mkdirSync(output, { recursive: false });
const profile = path.join(output, 'profile');
fs.mkdirSync(path.join(profile, 'Default'), { recursive: true });
fs.writeFileSync(path.join(profile, 'Default/Preferences'), JSON.stringify({
  winmux: { blocking_disabled_sites: ['https://legacy.winmux.test'] },
}));
const consent = allowed => fs.writeFileSync(path.join(profile, 'winmux-services.json'), JSON.stringify({
  version: 1, security_updates: false, extension_updates: false, filter_updates: allowed,
}));
consent(false);
let requests = [];
const server = http.createServer((req, res) => {
  requests.push({ host: req.headers.host, url: req.url });
  if (req.url === '/ad.js') {
    res.writeHead(200, { 'Content-Type': 'application/javascript' });
    res.end('window.winmuxAdRequestLoaded = true;');
  } else if (req.url === '/filters.txt') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('[Adblock Plus 2.0]\n! WinMux consent fixture\n||fixture-ad.invalid^\n');
  } else {
    res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
    res.end(`<!doctype html><title>WinMux uBlock fixture</title>
      <script>window.winmuxAdEnabled = true;</script>
      <script src="http://ads.winmux.test:${server.address().port}/ad.js"></script>
      <div class="ad-slot">Advert</div><div class="sponsor">WinMux ad</div>
      <p id="content">Normal page content</p>`);
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const pageURL = `http://fixture.winmux.test:${server.address().port}/`;
const filterURL = `http://updates.winmux.test:${server.address().port}/filters.txt`;
const report = { passed: false, package_manifest_sha256: sha256(manifestBytes), cases: [], requests, exceptions: [] };
let child, socket, log, commandId = 0;
const pending = new Map();
async function until(predicate, seconds = 30) {
  const end = Date.now() + seconds * 1000;
  while (Date.now() < end) {
    if (child?.signalCode || (child?.exitCode !== null && child?.exitCode !== undefined)) {
      throw new Error('Browser exited: ' + (child.signalCode || child.exitCode));
    }
    const value = await predicate();
    if (value) return value;
    await delay(100);
  }
  throw new Error('Fixture condition timed out');
}
function call(method, params = {}, sessionId) {
  const id = ++commandId;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(method + ' timed out')); }, 15000);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
}
async function evaluate(session, expression) {
  const result = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, replMode: true }, session);
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function start(label) {
  fs.rmSync(path.join(profile, 'DevToolsActivePort'), { force: true });
  log = fs.openSync(path.join(output, label + '.log'), 'w');
  child = spawn(path.join(args.app, 'Contents/MacOS/Chromium'), [
    `--user-data-dir=${profile}`, '--headless=new', '--no-first-run', '--no-default-browser-check',
    '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
    '--enable-logging=stderr',
    `--winmux-test-service=com.jameslyons.winmux.browser.alpha.workspace.test.${randomUUID()}`,
    '--host-resolver-rules=MAP *.winmux.test 127.0.0.1, MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
    'about:blank',
  ], { stdio: ['ignore', log, log] });
  const port = await until(() => {
    try { const lines = fs.readFileSync(path.join(profile, 'DevToolsActivePort'), 'utf8').trim().split('\n'); return lines.length === 2 ? lines : null; }
    catch { return null; }
  });
  socket = new WebSocket(`ws://127.0.0.1:${port[0]}${port[1]}`);
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.exceptionThrown') report.exceptions.push(message.params.exceptionDetails);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id); clearTimeout(waiter.timer);
    if (message.error) waiter.reject(new Error(JSON.stringify(message.error))); else waiter.resolve(message.result);
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  const background = await until(async () => (await call('Target.getTargets')).targetInfos.find(
    t => t.type === 'background_page' && t.url === 'chrome-extension://blockjmkbacgjkknlgpkjjiijinjdanf/background.html'));
  const { sessionId } = await call('Target.attachToTarget', { targetId: background.targetId, flatten: true });
  await call('Runtime.enable', {}, sessionId);
  // A background target can appear before start.js initializes vAPI. Importing
  // background.js that early evaluates its dependencies in the wrong order.
  await until(() => evaluate(sessionId, 'typeof globalThis.winmuxBlockingReady === "function"'));
  await evaluate(sessionId, `globalThis.testUBlock = (await import('./js/background.js')).default; true`);
  await evaluate(sessionId, 'await testUBlock.isReadyPromise; true');
  await until(() => evaluate(sessionId, 'testUBlock.readyToFilter && typeof globalThis.winmuxBlockingReady === "function"'));
  await until(() => evaluate(sessionId, 'await (async() => (await vAPI.storage.get("winmuxMigrationV1")).winmuxMigrationV1 === true)()'));
  return sessionId;
}
async function stop() {
  if (socket?.readyState === WebSocket.OPEN) await call('Browser.close').catch(() => {});
  if (child && child.exitCode === null && !child.signalCode) {
    await Promise.race([new Promise(resolve => child.once('exit', resolve)), delay(10000)]);
    if (child.exitCode === null && !child.signalCode) { child.kill('SIGTERM'); await delay(1000); }
    if (child.exitCode === null && !child.signalCode) child.kill('SIGKILL');
  }
  socket?.close(); socket = null;
  if (log !== undefined) { fs.closeSync(log); log = undefined; }
  child = null;
}

try {
  let background = await start('offline');
  const defaults = await evaluate(background, `({version:chrome.runtime.getManifest().version,
    lists:testUBlock.selectedFilterLists, consent:winmuxFilterUpdatesAllowed,
    migration:testUBlock.getNetFilteringSwitch('https://child.legacy.winmux.test/path') === false &&
      testUBlock.getNetFilteringSwitch('http://legacy.winmux.test/path') === true})`);
  assert.equal(defaults.version, '1.75.0');
  assert.equal(defaults.consent, false);
  assert.equal(defaults.migration, true);
  assert(defaults.lists.includes('ublock-filters') && defaults.lists.includes('helium-annoyances'));
  report.cases.push({ name: 'offline defaults and schemeful exception migration', result: defaults });
  const denied = await evaluate(background, `await (async()=>{try{await (await import('./js/assets.js')).default.fetch(${JSON.stringify(filterURL)});return null;}catch(details){return {url:details.url,content:details.content,error:details.error,description:String(details)};}})()`);
  assert.equal(denied?.url, filterURL, JSON.stringify(denied));
  assert.equal(denied.content, '');
  assert.match(denied.error, /Filter updates are disabled/);
  const deniedList = await evaluate(background, `await (await import('./js/assets.js')).default.fetchFilterList(${JSON.stringify(filterURL)})`);
  assert.equal(deniedList.content, '');
  assert(!requests.some(r => r.url === '/filters.txt'));
  report.cases.push({ name: 'filter downloads denied without consent', passed: true });
  const filters = '||ads.winmux.test^$script\nfixture.winmux.test##.ad-slot\nfixture.winmux.test##.sponsor:has-text(WinMux ad)\nfixture.winmux.test##+js(set-constant, winmuxAdEnabled, false)\n';
  await evaluate(background, `await testUBlock.appendUserFilters(${JSON.stringify(filters)}); await testUBlock.loadFilterLists(); true`);
  const target = await call('Target.createTarget', { url: pageURL });
  const page = (await call('Target.attachToTarget', { targetId: target.targetId, flatten: true })).sessionId;
  const inspect = `(()=>({ready:!!document.querySelector('#content'), adLoaded:window.winmuxAdRequestLoaded === true,
    scriptlet:window.winmuxAdEnabled === false,
    hidden:document.querySelector('.ad-slot') && getComputedStyle(document.querySelector('.ad-slot')).display === 'none',
    procedural:!document.querySelector('.sponsor') || getComputedStyle(document.querySelector('.sponsor')).display === 'none'}))()`;
  const filtered = await until(async () => { const x = await evaluate(page, inspect); return x.ready && x.scriptlet && x.hidden && x.procedural ? x : null; });
  assert.equal(filtered.adLoaded, false);
  assert(!requests.some(r => r.url === '/ad.js'));
  report.cases.push({ name: 'network blocking, cosmetics, procedural rules, and scriptlets', result: filtered });
  await evaluate(background, `testUBlock.toggleNetFilteringSwitch(${JSON.stringify(pageURL)}, '', false);
    await vAPI.storage.set({netWhitelist:testUBlock.arrayFromWhitelist(testUBlock.netWhitelist)}); true`);
  await call('Page.reload', {}, page);
  const unfiltered = await until(async () => { const x = await evaluate(page, inspect); return x.ready && x.adLoaded && !x.scriptlet && !x.hidden && !x.procedural ? x : null; });
  report.cases.push({ name: 'site exception disables all filtering', result: unfiltered });
  await stop();
  consent(true);
  background = await start('updates-enabled');
  assert.equal(await evaluate(background, `testUBlock.getNetFilteringSwitch(${JSON.stringify(pageURL)})`), false);
  assert.equal(await evaluate(background, 'winmuxFilterUpdatesAllowed'), true);
  const fetched = await evaluate(background, `await (await import('./js/assets.js')).default.fetch(${JSON.stringify(filterURL)}).then(x => typeof x.content === 'string' && x.content.includes('WinMux consent fixture'))`);
  assert(fetched); assert(requests.some(r => r.url === '/filters.txt'));
  report.cases.push({ name: 'persisted exceptions and consented filter downloads', passed: true });
  report.passed = true;
} catch (error) {
  report.error = error.stack;
  process.exitCode = 1;
} finally {
  await stop();
  server.close();
  fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ passed: report.passed, cases: report.cases.length, error: report.error, output }));
}
