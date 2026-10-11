#!/usr/bin/env node
// Bounded fault-injection checks against a signed, disposable browser profile.
// Requires Node 22+ (built-in WebSocket). All browser control is local CDP.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import crypto from 'node:crypto';
import {spawn, execFileSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {fileURLToPath} from 'node:url';

const args = process.argv.slice(2);
const names = ['renderer-crash','renderer-hang','gpu-crash','network-lifecycle-pressure','browser-crash','public-sites','popup-lifecycle','profiler-deopt','accessibility-churn'];
if (![4, 6].includes(args.length) || args[0] !== '--app' || args[2] !== '--output' ||
    (args.length === 6 && (args[4] !== '--case' || !names.includes(args[5])))) {
  throw new Error('Usage: node test_browser_failure_capture.mjs --app APP --output NEW_DIRECTORY [--case NAME]');
}
const app = fs.realpathSync(args[1]);
const output = path.resolve(args[3]);
const manifestPath = path.join(path.dirname(app), 'winmux-package-manifest.json');
const manifestBytes = fs.readFileSync(manifestPath);
const manifest = JSON.parse(manifestBytes);
const executable = path.join(app, 'Contents/MacOS/Chromium');
const hash = data => crypto.createHash('sha256').update(data).digest('hex');
if (!manifest.verified || hash(fs.readFileSync(executable)) !== manifest.browser_executable_sha256) {
  throw new Error('Browser does not match verified package manifest');
}
execFileSync('codesign', ['--verify', '--deep', '--strict', app]);
fs.mkdirSync(output, {recursive: false, mode: 0o700});
const database = path.join(os.homedir(), 'Library/Application Support/WinMux Browser Alpha/Crashpad');
const listDumps = () => ['pending', 'completed'].flatMap(folder => {
  const directory = path.join(database, folder);
  return fs.existsSync(directory) ? fs.readdirSync(directory).filter(n => n.endsWith('.dmp')).map(n => path.join(directory, n)) : [];
});

// Read only the process identity annotations; never dump arbitrary memory or URLs.
function dumpIdentity(filename) {
  const b = fs.readFileSync(filename), a = {};
  const u = o => b.readUInt32LE(o);
  const string = o => { const n = u(o); if (n > 65536 || o+4+n > b.length) throw new Error('Invalid annotation'); return b.toString('utf8', o+4, o+4+n); };
  if (b.toString('ascii', 0, 4) !== 'MDMP') throw new Error('Invalid dump');
  const take = (k, v) => { if (['pid', 'ptype', 'ver'].includes(k)) a[k] = v; };
  const dictionary = o => { if (!o) return; const n=u(o); if (n>10000) throw new Error('Invalid dictionary'); for(let i=0;i<n;i++) take(string(u(o+4+i*8)), string(u(o+8+i*8))); };
  for (let i=0; i<u(8); i++) {
    const directory=u(12)+i*12;
    if (u(directory) !== 0x43500001) continue;
    const o=u(directory+8); dictionary(u(o+40)); const m=u(o+48);
    if (!m) continue;
    for(let j=0;j<u(m);j++) {
      const n=u(m+12+j*12); dictionary(u(n+16)); const z=u(n+24);
      if(z) for(let k=0;k<u(z);k++) {const q=z+4+k*12;take(string(u(q)),string(u(q+8)));}
    }
  }
  return {...a, generated_epoch_seconds:u(20)};
}

class CDP {
  constructor(ws, journal) {
    this.ws=ws; this.journal=journal; this.next=0; this.pending=new Map(); this.events=[];
    ws.addEventListener('message', event => {
      const data=JSON.parse(event.data);
      if(data.id) { const p=this.pending.get(data.id); if(p) {clearTimeout(p.timer);this.pending.delete(data.id);data.error?p.reject(new Error(JSON.stringify(data.error))):p.resolve(data.result);} }
      else {this.events.push(data); if(this.events.length>2000)this.events.shift(); if(/crash|detach/i.test(data.method))journal('protocol_event',data);}
    });
    ws.addEventListener('close', () => {for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(new Error('CDP disconnected'));}this.pending.clear();});
  }
  static async connect(url, journal) {
    const ws=new WebSocket(url);
    await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{ws.close();reject(new Error('CDP connection timed out'));},5000);ws.addEventListener('open',()=>{clearTimeout(timer);resolve();},{once:true});ws.addEventListener('error',()=>{clearTimeout(timer);reject(new Error('CDP connection failed'));},{once:true});});
    return new CDP(ws,journal);
  }
  call(method, params={}, sessionId, timeout=5000) {
    const id=++this.next;
    return new Promise((resolve,reject)=>{const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error(method+' timed out'));},timeout);this.pending.set(id,{resolve,reject,timer});this.ws.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  }
}
async function until(predicate, seconds=15) {
  const end=Date.now()+seconds*1000;
  while(Date.now()<end){const value=await predicate();if(value)return value;await delay(100);}
  throw new Error('Condition timed out after '+seconds+' seconds');
}
const timers=new Set();
const html='<!doctype html><title>Isolated stability fixture</title><input id="draft" value="retained draft"><canvas id="canvas"></canvas><script>window.beats=0;setInterval(()=>window.beats++,100);</script>';
const server=http.createServer((req,res)=>{
  if(req.url==='/slow'){const t=setTimeout(()=>{timers.delete(t);if(!res.destroyed){res.writeHead(200,{'Content-Type':'text/html'});res.end(html);}},8000);timers.add(t);res.on('close',()=>{clearTimeout(t);timers.delete(t);});return;}
  res.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});res.end(html);
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const base='http://127.0.0.1:'+server.address().port;
const result={passed:false,scope:'isolated_injected_failure_capture_and_bounded_recovery',package_manifest_sha256:hash(manifestBytes),cases:[],limits:[
  'Deliberate failures in synthetic profiles; not incidents in daily browsing.',
  'Headless CDP recovery is not native window or compositor qualification.',
  'Memory notifications simulate browser pressure; they do not establish OS pressure/discard cadence.',
  'Local crash dumps retained without upload.']};
if(args[5]==='popup-lifecycle'){
  result.scope='isolated_visible_popup_lifecycle';
  result.limits=['Fresh local profile and an unlocked native console with input permission',
    'Closed-popup visibility and real address-field input; no intentional crashes',
    'Bounded resize/focus and open/close cycles; not long-duration qualification'];
}
try {
  // Native popup input needs an unlocked console and runs only when selected.
  for(const name of (args.length === 6 ? [args[5]] : names.filter(n=>n!=='popup-lifecycle'))) {
    const directory=path.join(output,name);fs.mkdirSync(directory,{mode:0o700});
    const journal=(action,details={})=>fs.appendFileSync(path.join(directory,'journal.jsonl'),JSON.stringify({monotonic_ms:performance.now(),action,...details})+'\n');
    const record={name,passed:false,expected_failure:/crash|hang/.test(name)};result.cases.push(record);
    const before=new Set(listDumps()); const started=Date.now();
    const log=fs.openSync(path.join(directory,'browser.log'),'wx',0o600);
    const command=[`--user-data-dir=${path.join(directory,'profile')}`,...(name==='popup-lifecycle'?[]:['--headless=new']),...(name==='profiler-deopt'?['--js-flags=--allow-natives-syntax']:[]),...(name==='accessibility-churn'?['--force-renderer-accessibility']:[]),'--remote-debugging-port=0','--remote-debugging-address=127.0.0.1',
      '--no-first-run','--no-default-browser-check','--enable-logging=stderr',
      `--winmux-test-service=com.jameslyons.winmux.browser.alpha.workspace.test.${crypto.randomUUID()}`,'about:blank'];
    let child,cdp;let exitStatus=null;
    console.log('Starting '+name);
    try {
      child=spawn(executable,command,{stdio:['ignore',log,log]});
      child.on('error',error=>{record.spawn_error=String(error);});
      child.on('exit',(code,signal)=>{exitStatus={code,signal};journal('browser_exit',exitStatus);});
      record.browser_pid=child.pid;journal('browser_started',{pid:child.pid});
      const active=path.join(directory,'profile/DevToolsActivePort');
      await until(()=>{if(exitStatus||record.spawn_error)throw new Error('Browser failed during startup');return fs.existsSync(active);});
      const [port,suffix]=fs.readFileSync(active,'utf8').trim().split('\n');
      cdp=await CDP.connect(`ws://127.0.0.1:${port}${suffix}`,journal);
      await cdp.call('Target.setDiscoverTargets',{discover:true});
      const target=await cdp.call('Target.createTarget',{url:base});
      const {sessionId}=await cdp.call('Target.attachToTarget',{targetId:target.targetId,flatten:true});
      const evaluate=async(expression,timeout=5000)=>{const r=await cdp.call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},sessionId,timeout);if(r.exceptionDetails)throw new Error('Page evaluation failed');return r.result?.value;};
      await until(async()=>await evaluate('document.readyState === "complete" && typeof beats === "number"'));
      record.processes_before=(await cdp.call('SystemInfo.getProcessInfo')).processInfo;
      journal('before_injection',{processes:record.processes_before});
      if(name==='browser-crash') {
        journal('inject_browser_crash');
        const expected=cdp.call('Browser.crash').catch(e=>String(e));
        await until(()=>exitStatus,10);await expected;
        if(exitStatus.code===0&&!exitStatus.signal)throw new Error('Injected crash exited normally');
        record.exit=exitStatus;
      } else if(name==='renderer-crash') {
        journal('inject_renderer_crash',{target_id:target.targetId});
        const expected=cdp.call('Page.crash',{},sessionId).catch(e=>String(e));
        await until(()=>cdp.events.some(e=>e.method==='Target.targetCrashed'&&e.params.targetId===target.targetId));await expected;
        record.browser_survived=(await cdp.call('Browser.getVersion')).product;
        const fresh=await cdp.call('Target.createTarget',{url:base+'/recovered'});
        const attached=await cdp.call('Target.attachToTarget',{targetId:fresh.targetId,flatten:true});
        await until(async()=>{const v=await cdp.call('Runtime.evaluate',{expression:'typeof beats === "number"',returnByValue:true},attached.sessionId);return v.result.value;});
        record.new_page_responsive=true;
      } else if(name==='renderer-hang') {
        await cdp.call('Profiler.enable',{},sessionId);
        await cdp.call('Profiler.start',{},sessionId);
        journal('inject_renderer_hang');
        const t=performance.now();const blocked=cdp.call('Runtime.evaluate',{expression:'while(true){}'},sessionId,2500).catch(e=>String(e));
        await delay(300);record.browser_survived=(await cdp.call('Browser.getVersion')).product;
        const detection=await blocked;if(!String(detection).includes('timed out'))throw new Error('Hang was not detected');
        record.detection_ms=performance.now()-t;journal('hang_detected',{elapsed_ms:record.detection_ms});
        const after=(await cdp.call('SystemInfo.getProcessInfo')).processInfo;
        const renderers=after.filter(p=>p.type==='renderer').map(p=>({...p,cpu_delta:p.cpuTime-(record.processes_before.find(q=>q.id===p.id)?.cpuTime??p.cpuTime)})).sort((a,b)=>b.cpu_delta-a.cpu_delta);
        const renderer=renderers[0];
        if(!renderer || renderer.cpu_delta<1)throw new Error('Could not identify the injected busy renderer');
        record.sampled_renderer=renderer;
        try{execFileSync('/usr/bin/sample',[String(renderer.id),'1','10','-file',path.join(directory,'renderer-sample.txt')],{timeout:45000,stdio:'ignore'});record.thread_sample_captured=fs.statSync(path.join(directory,'renderer-sample.txt')).size>0;}catch(e){record.thread_sample_error=String(e);}
        await cdp.call('Runtime.terminateExecution',{},sessionId);
        const {profile}=await cdp.call('Profiler.stop',{},sessionId);
        fs.writeFileSync(path.join(directory,'renderer-cpu-profile.json'),JSON.stringify(profile));
        record.javascript_cpu_profile_captured=Boolean(profile.samples?.length && profile.nodes?.length);
        if(await evaluate('6*7')!==42)throw new Error('Renderer did not recover');
        record.renderer_recovered=true;
        if(!record.thread_sample_captured && !record.javascript_cpu_profile_captured)throw new Error('Hang recovered but both native and JavaScript stack samples are missing');
      } else if(name==='accessibility-churn') {
        await cdp.call('Accessibility.enable',{},sessionId);
        record.cycles=0;
        for(let cycle=0;cycle<120;cycle++) {
          await evaluate(`new Promise(resolve => {
            document.body.innerHTML = '<div role="dialog" aria-modal="true" aria-labelledby="label"><h1 id="label">Cycle ${cycle}</h1><div id="owner" aria-owns="row"></div><div id="other"><button id="row">Item ${cycle}</button></div><input id="edit"></div>';
            const row=document.querySelector('#row');
            row.setAttribute('aria-hidden','true');
            document.querySelector('${cycle%2?'#owner':'#other'}').append(row);
            row.removeAttribute('aria-hidden');
            document.querySelector('${cycle%2?'#row':'#edit'}').focus();
            requestAnimationFrame(()=>resolve(true));
          })`);
          const tree=await cdp.call('Accessibility.getFullAXTree',{},sessionId);
          if(!tree.nodes.some(node=>node.role?.value==='heading'&&node.name?.value===`Cycle ${cycle}`)) {
            throw new Error('Accessibility tree failed to update after DOM/ARIA/focus changes');
          }
          record.cycles++;
        }
      } else if(name==='profiler-deopt') {
        await cdp.call('Profiler.enable',{},sessionId);
        await cdp.call('Profiler.start',{},sessionId);
        record.deoptimization=await evaluate(`(() => {
          function inner(x) { return x + 1; }
          function outer(x) { return inner(x); }
          %PrepareFunctionForOptimization(outer);
          for (let i=0;i<100;i++) outer(i);
          %OptimizeFunctionOnNextCall(outer);
          outer(1);
          const optimized = %GetOptimizationStatus(outer);
          const result = outer('changed');
          return {optimized,result,after:%GetOptimizationStatus(outer)};
        })()`);
        // OptimizationStatus::kOptimized in the pinned V8 revision is bit 3.
        if(!(record.deoptimization.optimized & 8) || (record.deoptimization.after & 8) || record.deoptimization.result!=='changed1') {
          throw new Error('Forced optimization/deoptimization workload did not execute');
        }
        const {profile}=await cdp.call('Profiler.stop',{},sessionId);
        record.profile_nodes=profile.nodes.length;
        if(await evaluate('6*7')!==42)throw new Error('Renderer failed after profiled deoptimization');
      } else if(name==='gpu-crash') {
        const old=record.processes_before.filter(p=>p.type.toLowerCase()==='gpu').map(p=>p.id);
        if(!old.length)throw new Error('No GPU process to test');
        journal('inject_gpu_crash',{old_gpu_pids:old});await cdp.call('Browser.crashGpuProcess');
        await evaluate('document.querySelector("canvas").getContext("webgl") !== null');
        record.replacement_gpu=await until(async()=>{const all=(await cdp.call('SystemInfo.getProcessInfo')).processInfo;return all.find(p=>p.type.toLowerCase()==='gpu'&&!old.includes(p.id));});
        if(await evaluate('6*7')!==42)throw new Error('Page did not survive GPU failure');
      } else if(name==='popup-lifecycle') {
        record.scope='visible_preloaded_popup_lifecycle_and_native_toolbar_input';
        // Inspect only the fresh browser's preloaded internal popup pages. The
        // main fixture remains selected; attaching does not activate a popup.
        const popupSessions=new Map();
        const observePopups=async()=>{
          const {targetInfos}=await cdp.call('Target.getTargets',{filter:[{}]});
          const popups=targetInfos.filter(t=>t.url.startsWith('chrome://omnibox-popup.'));
          if(!popups.length)throw new Error('No preloaded omnibox popup was observed');
          const states=[];
          for(const popup of popups){
            if(!popupSessions.has(popup.targetId)){
              const attached=await cdp.call('Target.attachToTarget',{targetId:popup.targetId,flatten:true});
              popupSessions.set(popup.targetId,attached.sessionId);
            }
            const value=await cdp.call('Runtime.evaluate',{
              expression:'({hidden:document.hidden,visibility:document.visibilityState,focused:document.hasFocus(),width:innerWidth,height:innerHeight})',
              returnByValue:true
            },popupSessions.get(popup.targetId));
            states.push({target_id:popup.targetId,...value.result.value});
          }
          record.last_popup_states=states;
          return states;
        };
        await cdp.call('Page.bringToFront',{},sessionId);
        await delay(1000);
        const {windowId}=await cdp.call('Browser.getWindowForTarget',{targetId:target.targetId});
        record.popup_observations=[];
        for(let i=0;i<80;i++){
          await cdp.call('Browser.setWindowBounds',{windowId,bounds:{width:900+(i%2)*100,height:700}});
          await cdp.call('Page.bringToFront',{},sessionId);
          await delay(30);
          if(i%10===0||i===79){
            const states=await observePopups();
            record.popup_observations.push({iteration:i,states});
            journal('closed_popup_visibility',{iteration:i,states});
            if(states.some(s=>!s.hidden||s.focused))throw new Error('A closed omnibox popup is visible or focused');
          }
        }
        record.resize_focus_cycles=80;
        const probeApp=path.join(directory,'Popup Input Probe.app');
        const probe=path.join(probeApp,'Contents/MacOS/popup-input-probe');
        fs.mkdirSync(path.dirname(probe),{recursive:true});
        fs.writeFileSync(path.join(probeApp,'Contents/Info.plist'),`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.jameslyons.winmux.browser.alpha.workspace</string>
<key>CFBundleExecutable</key><string>popup-input-probe</string>
<key>CFBundleName</key><string>Popup Input Probe</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/>
</dict></plist>`);
        execFileSync('swiftc',['-O','-module-cache-path',path.join(directory,'module-cache'),
          fileURLToPath(new URL('./popup_input_probe.swift',import.meta.url)),'-o',probe],{timeout:120000});
        execFileSync('codesign',['--force','--sign',manifest.identity_sha1,
          '--identifier','com.jameslyons.winmux.browser.alpha.workspace','--options','runtime','--timestamp=none',probeApp]);
        const press=command=>{
          const reply=execFileSync(probe,[String(child.pid)],{input:command+'\n',encoding:'utf8',timeout:5000});
          if(reply.trim()!=='posted')throw new Error('Scoped toolbar input was not posted');
        };
        record.open_close_cycles=0;
        for(let i=0;i<5;i++){
          record.phase='open_autocomplete';
          press('address');await delay(200);press(i%2?'query-b':'query');await delay(200);
          const focus=JSON.parse(execFileSync(probe,[String(child.pid)],{input:'snapshot\n',encoding:'utf8',timeout:5000}));
          journal('autocomplete_input',{cycle:i,focus});
          if(focus.AXRole!=='AXTextField'||focus.AXValue!==(i%2?'b':'a'))throw new Error('Native autocomplete query was not delivered');
          await until(async()=>(await observePopups()).some(s=>!s.hidden),5);
          record.phase='close_autocomplete';
          press('close');
          await until(async()=>(await observePopups()).every(s=>s.hidden),5);
          record.open_close_cycles++;
        }
        record.browser_survived=(await cdp.call('Browser.getVersion')).product;
        if(await evaluate('6*7')!==42)throw new Error('Main page stopped responding');
      } else if(name==='public-sites') {
        record.sites=[];
        for(const [label,url] of [['Twitter/X','https://x.com/explore'],['YouTube','https://www.youtube.com/']]) {
          journal('public_site_navigation',{site:label});
          const navigation=await cdp.call('Page.navigate',{url},sessionId,20000);
          await delay(3000);
          const samples=[];
          for(let i=0;i<3;i++) {
            samples.push(await evaluate('JSON.parse(JSON.stringify({ready:document.readyState,videoCount:document.querySelectorAll("video").length,playingCount:[...document.querySelectorAll("video")].filter(v=>!v.paused&&v.currentTime>0).length,loginPrompt:/sign in|log in|something went wrong/i.test(document.body?.innerText??""),errorPage:location.protocol==="chrome-error:"}))'));
            await evaluate('window.scrollBy(0,800)');await delay(300);
          }
          record.sites.push({site:label,navigation_error:navigation.errorText??null,samples,coverage:'logged-out navigation and scripted scrolling only; authenticated video feed not covered'});
        }
        record.authenticated_video_feed_covered=false;
        record.blocked=record.sites.some(site=>site.navigation_error||site.samples.some(sample=>sample.errorPage));
        if(record.blocked)record.blocked_reason='At least one public site failed to load; survival of its error page does not pass site coverage';
      } else {
        await cdp.call('Network.enable',{},sessionId);
        await cdp.call('Network.emulateNetworkConditions',{offline:true,latency:0,downloadThroughput:-1,uploadThroughput:-1},sessionId);
        const offline=await cdp.call('Page.navigate',{url:base+'/offline'},sessionId);if(!offline.errorText)throw new Error('Offline navigation did not fail');
        record.offline_error=offline.errorText;
        await cdp.call('Network.emulateNetworkConditions',{offline:false,latency:0,downloadThroughput:-1,uploadThroughput:-1},sessionId);
        await cdp.call('Page.navigate',{url:base+'/online'},sessionId);await until(async()=>await evaluate('typeof beats === "number"'));
        await cdp.call('Page.setWebLifecycleState',{state:'frozen'},sessionId);await delay(300);
        await cdp.call('Page.setWebLifecycleState',{state:'active'},sessionId);
        if(await evaluate('document.querySelector("#draft").value')!=='retained draft')throw new Error('Draft lost across freeze');
        record.explicit_freeze_thaw=true;
        for(let i=0;i<3;i++){journal('simulate_pressure',{cycle:i});await cdp.call('Memory.simulatePressureNotification',{level:'moderate'});await delay(250);await cdp.call('Memory.simulatePressureNotification',{level:'critical'});await delay(250);if(await evaluate('6*7')!==42)throw new Error('Input failed after pressure');}
        record.pressure_notification_cycles=3;
        const navigation=cdp.call('Page.navigate',{url:base+'/slow'},sessionId).catch(e=>String(e));await delay(500);await cdp.call('Page.stopLoading',{},sessionId);await navigation;
        await cdp.call('Page.navigate',{url:base+'/recovered'},sessionId);await until(async()=>await evaluate('typeof beats === "number"'));
        record.network_recovered=true;
      }
      if(name!=='browser-crash'&&exitStatus)throw new Error('Unexpected browser exit');
      if(['browser-crash','renderer-crash'].includes(name)) {
        const pids=new Set([String(child.pid),...record.processes_before.map(p=>String(p.id))]);
        record.dumps=await until(()=>{const matches=[];for(const filename of listDumps()){if(before.has(filename))continue;try{const info=dumpIdentity(filename);if(pids.has(info.pid)&&info.generated_epoch_seconds>=Math.floor(started/1000)-1){fs.copyFileSync(filename,path.join(directory,path.basename(filename)));fs.chmodSync(path.join(directory,path.basename(filename)),0o600);matches.push({file:path.basename(filename),...info});}}catch{}}return matches.length?matches:null;},15);
      }
      record.passed=!record.blocked;
    } catch(error){record.error=String(error);journal('failure',{error:record.error});}
    finally {
      if(child&&!exitStatus){try{await cdp?.call('Browser.close');}catch{}try{await until(()=>exitStatus,5);}catch{child.kill('SIGTERM');try{await until(()=>exitStatus,5);}catch{child.kill('SIGKILL');await until(()=>exitStatus,5);}}}
      cdp?.ws.close();fs.closeSync(log);record.exit_after_cleanup=exitStatus;record.seconds=(Date.now()-started)/1000;
      if(['popup-lifecycle','profiler-deopt','accessibility-churn'].includes(name) && /FATAL:|Check failed|CHECK failed|DCHECK failed|Received signal/.test(fs.readFileSync(path.join(directory,'browser.log'),'utf8'))){
        record.passed=false;record.error='Unexpected fatal error in browser process tree';
      }
      fs.writeFileSync(path.join(directory,'result.json'),JSON.stringify(record,null,2)+'\n');
      fs.writeFileSync(path.join(output,'result.json'),JSON.stringify(result,null,2)+'\n');
      console.log(name+': '+(record.passed?'passed':record.blocked?'blocked':record.error));
    }
  }
  result.passed=result.cases.every(c=>c.passed);
} finally {
  for(const timer of timers)clearTimeout(timer);server.closeAllConnections();server.close();
  fs.writeFileSync(path.join(output,'result.json'),JSON.stringify(result,null,2)+'\n');
}
process.exitCode=result.passed?0:result.cases.every(c=>c.passed||c.blocked)?2:1;
