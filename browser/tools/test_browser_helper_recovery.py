#!/usr/bin/env python3
"""Kill only a UUID fixture helper; require automatic identity recovery.

Fresh headless profile, observe-only helper, no native-management ownership.
This covers transport and inventory recovery, not restoration of native layout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time
import uuid

from measure_helper import Sampler
from test_browser_layout_watchdog import BROWSER_ID, stop_process


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    manifest_path = app.parent / 'winmux-package-manifest.json'
    manifest = read_json(manifest_path)
    executable = app / 'Contents/MacOS/Chromium'
    helper = app / manifest['helper_relative_path']
    assert manifest['verified'] is True
    for binary, key in [(executable, 'browser_executable_sha256'), (helper, 'helper_sha256')]:
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == manifest[key]
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    service = BROWSER_ID + '.workspace.test.' + str(uuid.uuid4())
    target = f'gui/{os.getuid()}/{service}'
    report, bridge = output / 'helper.json', output / 'bridge.json'
    agent = output / 'helper.plist'
    # Exercise the packaged launch policy, including launchd's restart throttle.
    # Inventing a faster fixture policy would hide a production recovery delay.
    production_agent = plistlib.loads((app / 'Contents/Library/LaunchAgents' /
        (BROWSER_ID + '.workspace.plist')).read_bytes())
    launch_policy = {key: production_agent[key] for key in ('ProcessType', 'ThrottleInterval')
                     if key in production_agent}
    agent.write_bytes(plistlib.dumps({'Label': service, 'ProgramArguments': [str(helper), service, str(report)],
        'MachServices': {service: True}, 'RunAtLoad': True,
        **launch_policy,
        'EnvironmentVariables': {'WINMUX_TEST_OBSERVE_ONLY': '1'},
        'StandardOutPath': str(output / 'helper.log'), 'StandardErrorPath': str(output / 'helper.log')}))
    result = {'passed': False, 'scope': 'isolated_helper_process_failure_and_inventory_recovery',
              'package_manifest_sha256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
              'packaged_launch_policy': launch_policy,
              'limits': ['Observe-only helper; native layout recovery is tested separately',
                         'A UUID launchd service is relaunched on XPC demand; no enrolled service is modified']}
    browser = None

    def wait(predicate, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if browser and browser.poll() is not None:
                raise RuntimeError('Browser exited during helper recovery')
            value = predicate()
            if value:
                return value
            time.sleep(.05)
        raise TimeoutError('Helper recovery condition timed out')

    def helper_pid():
        text = subprocess.check_output(['launchctl', 'print', target], text=True)
        match = re.search(r'^\s*pid = (\d+)', text, re.MULTILINE)
        return int(match[1]) if match else None

    def identities():
        return sorted(host['surface_id'] for host in read_json(report).get('hosts', []))

    try:
        subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(agent)], check=True, timeout=10)
        command = [str(executable), '--headless=new', '--no-first-run', '--no-default-browser-check',
            '--user-data-dir=' + str(output / 'profile'), '--enable-logging=stderr',
            '--winmux-test-service=' + service, '--winmux-bridge-report=' + str(bridge), 'about:blank']
        with (output / 'browser.log').open('x') as log:
            browser = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        wait(lambda: read_json(bridge).get('state') == 'authenticated' and identities())
        old_pid = wait(helper_pid)
        old_identity = Sampler(old_pid, helper).read()
        initial_browser = Sampler(browser.pid, executable).read()
        initial_ids = identities()
        initial_report_mtime = report.stat().st_mtime_ns
        initial_connections = read_json(bridge)['authenticated_connections']
        result.update(browser_pid=browser.pid, old_helper_pid=old_pid, initial_surfaces=initial_ids)
        start = time.monotonic()
        subprocess.run(['launchctl', 'kill', 'SIGKILL', target], check=True, timeout=10)
        # XPC reconnect demand owns relaunch. A second kickstart -k races that
        # launch and can block even after the browser has reauthenticated.
        new_pid = wait(lambda: (pid if (pid := helper_pid()) and pid != old_pid else None))
        wait(lambda: read_json(bridge).get('state') == 'authenticated'
             and read_json(bridge).get('authenticated_connections', 0) > initial_connections
             and report.stat().st_mtime_ns > initial_report_mtime
             and identities() == initial_ids)
        result['recovery_seconds'] = time.monotonic() - start
        new_identity = Sampler(new_pid, helper).read()
        assert new_identity['process_start_ticks'] != old_identity['process_start_ticks']
        # Outlast both connection-negotiation watchdog windows after recovery.
        for _ in range(180):
            time.sleep(.1)
            assert browser.poll() is None and identities() == initial_ids
            assert read_json(bridge).get('state') == 'authenticated'
        assert Sampler(browser.pid, executable).read()['process_start_ticks'] == initial_browser['process_start_ticks']
        result.update(functional_passed=True, new_helper_pid=new_pid, browser_identity_preserved=True,
                      surfaces_preserved=True, automatic_service_relaunch=True,
                      stable_seconds=18, recovered_bridge=read_json(bridge))
        result['within_recovery_budget'] = result['recovery_seconds'] <= 10
        result['passed'] = result['within_recovery_budget']
        if not result['within_recovery_budget']:
            result['error'] = 'Helper recovery exceeded ten-second budget'
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
    finally:
        result['browser_cleanup'] = stop_process(browser)
        result['test_service_removed'] = subprocess.run(['launchctl', 'bootout', target],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
        if not result['browser_cleanup'] or not result['test_service_removed']:
            result['passed'] = False
        log_path = output / 'browser.log'
        if log_path.exists() and re.search(r'FATAL:|CHECK failed|DCHECK failed|Received signal', log_path.read_text(errors='replace')):
            result.update(passed=False, error='Unexpected fatal error in browser process tree')
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
