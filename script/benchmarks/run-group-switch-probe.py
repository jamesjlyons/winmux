#!/usr/bin/env python3
"""Measure reversible group switching with WindowServer geometry, not content presentation.

Switches only the explicitly named existing groups and restores the original selected
surface. Records IDs and frames; never records window titles, URLs, or screenshots.
"""
import argparse, concurrent.futures, json, math, os, selectors, socket, struct, subprocess, time
from pathlib import Path
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--socket', required=True)
parser.add_argument('--browser-pid', required=True, type=int)
parser.add_argument('--groups', nargs='+', required=True)
parser.add_argument('--samples', type=int, default=30)
parser.add_argument('--output', type=Path, required=True, help='New evidence directory')
parser.add_argument('--capture-frames', action='store_true')
options = parser.parse_args()
if (options.samples < 1 or options.browser_pid < 1 or len(options.groups) < 2
    or len(set(options.groups)) != len(options.groups)):
 parser.error('Use a live browser PID, at least two distinct existing groups, and a positive sample count.')
root = options.output.absolute()
root.mkdir(parents=True, exist_ok=False)
endpoint = options.socket
browser_pid = options.browser_pid
subprocess.run(['swiftc', '-O', '-module-cache-path', str(root/'module-cache'),
                str(Path(__file__).with_name('group-window-observer.swift')), '-o', str(root/'window-observer')], check=True)

def request(args):
 with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
  s.settimeout(10);s.connect(endpoint)
  data=json.dumps(dict(args=args,stdin='',windowId=None,workspace=None)).encode()
  s.sendall(struct.pack('<I',len(data))+data)
  def receive(n):
   data=b''
   while len(data)<n:
    chunk=s.recv(n-len(data))
    if not chunk: raise RuntimeError('Unexpected EOF')
    data+=chunk
   return data
  result=json.loads(receive(struct.unpack('<I',receive(4))[0]))
  if result['exitCode']: raise RuntimeError(result['stderr'])
  return result['stdout']

surfaces=json.loads(request(['surface','list']))
original=next((x['id'] for x in surfaces if x['selected'] and x['available']),None)
if not original: raise RuntimeError('No available selected surface to restore; refusing to switch.')
existing={x['workspace'] for x in surfaces if x['available']}
if not set(options.groups).issubset(existing): raise RuntimeError('Choose only existing groups with available surfaces.')
unready=[dict(id=x['id'],workspace=x['workspace'],managed=x['browser'].get('managed'),
              layout_reply=x['browser'].get('layoutReply')) for x in surfaces
         if x['available'] and x['workspace'] in options.groups and x.get('browser') is not None
         and (x['browser'].get('managed') is not True or x['browser'].get('layoutReply') != 'issued')]
if unready:
 (root/'preflight-failure.json').write_text(json.dumps(dict(reason='Browser layout has not become managed and acknowledged',surfaces=unready),indent=2)+'\n')
 raise RuntimeError('Browser layouts are unmanaged or unacknowledged; refusing startup/no-op switching measurements.')
native_ids={x['nativeWindowID'] for x in surfaces if x.get('nativeWindowID') is not None}
observer=subprocess.Popen([str(root/'window-observer')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,bufsize=0)
observer_ready = selectors.DefaultSelector()
observer_ready.register(observer.stdout, selectors.EVENT_READ)
def snapshot():
 if observer.poll() is not None: raise RuntimeError('Window observer exited unexpectedly')
 observer.stdin.write(b'snapshot\n');observer.stdin.flush()
 deadline=time.perf_counter()+3;line=b''
 while not line.endswith(b'\n'):
  remaining=deadline-time.perf_counter()
  if remaining<=0 or not observer_ready.select(timeout=remaining):
   raise TimeoutError('Window observer did not answer within 3 seconds')
  chunk=os.read(observer.stdout.fileno(),65536)
  if not chunk: raise RuntimeError('Window observer closed its output unexpectedly')
  line+=chunk
 return {str(w['id']):w['bounds'] for w in json.loads(line)
         if w['onscreen'] and (w['pid']==browser_pid or w['id'] in native_ids)}

samples=[];expected={};drift=[];failure=None;restore_error=None;restoration_request_succeeded=False
try:
 for group in options.groups:
  request(['workspace',group]);time.sleep(.6)
  expected[group]=snapshot()
  if not expected[group]:
   raise RuntimeError(f'No measurable visible windows for group {group!r}; refusing empty-geometry timing')
  duplicates=[other for other, frame in expected.items() if other != group and frame == expected[group]]
  if duplicates:
   raise RuntimeError(f'Groups {duplicates + [group]!r} have identical visible geometry; switching is not established')
 with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
  for i in range(options.samples):
   group=options.groups[i % len(options.groups)]
   started=time.perf_counter()
   def switch():
    request(['workspace',group]);return (time.perf_counter()-started)*1000
   response=pool.submit(switch)
   ready=None;first_match=None;first_match_requested=None;ready_requested=None
   positions=[];frame_snapshot_requested=[]
   while time.perf_counter()-started<2:
    requested_ms=(time.perf_counter()-started)*1000
    current=snapshot()
    # A CG snapshot may block across the switch. Timestamp receipt, not request:
    # only now do we know this geometry was observed. This is an upper bound.
    elapsed=(time.perf_counter()-started)*1000
    positions.append((elapsed,current))
    frame_snapshot_requested.append(requested_ms)
    if current==expected[group]:
     if first_match is None:
      first_match=elapsed;first_match_requested=requested_ms
     ready=elapsed;ready_requested=requested_ms
     if response.done():break
    time.sleep(.005)
   reply_ms=response.result()
   time.sleep(.15)
   final=snapshot()
   if final!=expected[group]:drift.append(dict(index=i,group=group,expected=expected[group],actual=final))
   samples.append(dict(index=i,group=group,response_ms=reply_ms,first_matching_geometry_ms=first_match,
                       first_matching_snapshot_requested_ms=first_match_requested,
                       matching_geometry_ms=ready,matching_snapshot_requested_ms=ready_requested,
                       geometry_changes=sum(a[1]!=b[1] for a,b in zip(positions,positions[1:])),
                       frames=positions if options.capture_frames else [],
                       frame_snapshot_requested_ms=frame_snapshot_requested if options.capture_frames else []))
except (Exception, KeyboardInterrupt) as error:
 failure=f'{type(error).__name__}: {error}'
finally:
 # Restore first, but always reap the observer even if the application/socket
 # disappeared. Preserve partial measurements and cleanup errors in evidence.
 try:
  request(['surface','focus',original])
  restoration_request_succeeded=True
 except Exception as error:
  restore_error=f'{type(error).__name__}: {error}'
 finally:
  observer_ready.close()
  observer.terminate()
  try: observer.wait(timeout=3)
  except subprocess.TimeoutExpired:
   observer.kill();observer.wait(timeout=3)
missing_matches=[dict(index=s['index'],group=s['group']) for s in samples if s['first_matching_geometry_ms'] is None]
report=dict(samples=samples,frame_drift=drift,expected=expected,original_selection=original,
            measurement_method=dict(geometry_timestamp='snapshot_response_received',
                                    geometry_bound='upper_bound_on_first_observed_match',
                                    frames_format='[snapshot_response_ms, window_bounds]',
                                    frame_snapshot_requested_ms='Parallel request timestamps for optional frames'),
            missing_geometry_matches=missing_matches,requested_samples=options.samples,
            failure=failure,restoration_request_succeeded=restoration_request_succeeded,restoration_error=restore_error,
            limits=['Command response and WindowServer geometry visibility only; not rendered content or input readiness.',
                    'Sequential switches in existing groups; system load and active apps are uncontrolled.',
                    'Geometry timings are measured after each snapshot returns: conservative observation upper bounds including snapshot/polling overhead.',
                    'Snapshot-request timestamps are observation-interval starts, not measured switch completion.',
                    'Earlier probe reports used request timestamps; distinguish those observation lower endpoints from these upper endpoints when comparing.',
                    'Timing aggregates include matching samples only; missing_geometry_matches records every timeout.',
                    'Restoration records focus-command acceptance, not rendered content or actual input focus.'])
for field in ['response_ms','first_matching_geometry_ms']:
 values=sorted(s[field] for s in samples if s[field] is not None)
 report[field]=dict(median=values[len(values)//2] if values else None,p95=values[math.ceil(len(values)*.95)-1] if values else None,count=len(values))
(root/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ['response_ms','first_matching_geometry_ms']}))
print('frame drifts',len(drift),'missing geometry matches',len(missing_matches))
if failure: print('probe failed:',failure)
if restore_error: print('RESTORATION FAILED:',restore_error)
if failure or restore_error or missing_matches or drift: raise SystemExit(1)
