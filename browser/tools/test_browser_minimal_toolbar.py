#!/usr/bin/env python3
"""Qualify the compact toolbar in an isolated, signed native browser fixture."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--probe', type=Path, help='Precompiled minimal_toolbar_probe.swift')
    parser.add_argument('--dark', action='store_true')
    parser.add_argument('--high-contrast', action='store_true')
    parser.add_argument('--loopback-host', action='store_true', help='Use a trustworthy .localhost origin for visual comparison')
    args = parser.parse_args()
    app, output = args.app.resolve(), args.output.resolve()
    manifest = json.loads((app.parent / 'winmux-package-manifest.json').read_text())
    assert manifest['verified'] and manifest['app'] == str(app)
    assert '0029-minimal-compact-toolbar.patch' in manifest['build']['patches_sha256']
    output.mkdir(parents=True, exist_ok=False)
    probe = args.probe.resolve() if args.probe else output / 'input-probe'
    if not args.probe:
        subprocess.run(['swiftc', '-module-cache-path', str(output / 'module-cache'),
                        str(ROOT / 'browser/tools/minimal_toolbar_probe.swift'), '-o', str(probe)], check=True)
    previous_pid = subprocess.check_output([str(probe), '--frontmost-pid'], text=True).strip()
    assert previous_pid.isdecimal() and int(previous_pid) > 0

    class Page(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == '/download':
                body = b'Minimal toolbar download fixture\n'
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Disposition', 'attachment; filename="toolbar-fixture.txt"')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            body = b'<!doctype html><title>Minimal toolbar fixture</title><h1>Toolbar fixture</h1><p>Native input and compact browser controls.</p>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    hostname = 'docs.localhost' if args.loopback_host else 'docs.toolbar.test'
    fixture_url = f'http://{hostname}:{server.server_port}/a/deep/path?query=fixture#anchor'
    extension = output / 'extension'
    extension.mkdir()
    (extension / 'manifest.json').write_text(json.dumps({
        'manifest_version': 3, 'name': 'Toolbar fixture', 'version': '1.0',
        'action': {'default_popup': 'popup.html'},
    }))
    (extension / 'popup.html').write_text('<!doctype html><title>Toolbar fixture</title><p>Native extension popup</p>')
    downloads = output / 'downloads'
    downloads.mkdir()
    profile = output / 'profile/Default'
    profile.mkdir(parents=True)
    (profile / 'Preferences').write_text(json.dumps({'download': {
        'default_directory': str(downloads), 'prompt_for_download': False,
    }}))
    service = 'com.jameslyons.winmux.browser.alpha.workspace.test.' + str(uuid.uuid4())
    report_file = output / 'helper.json'
    plist = output / 'helper.plist'
    plist.write_bytes(plistlib.dumps({
        'Label': service, 'ProgramArguments': [str(app / manifest['helper_relative_path']), service, str(report_file)],
        'MachServices': {service: True}, 'RunAtLoad': True, 'ProcessType': 'Interactive',
        'EnvironmentVariables': {'WINMUX_TEST_VIDEO_FULLSCREEN': '1', 'WINMUX_TEST_PROFILE_URL': fixture_url},
        'StandardOutPath': str(output / 'helper.log'), 'StandardErrorPath': str(output / 'helper.log'),
    }))
    command = [str(app / 'Contents/MacOS/Chromium'), '--user-data-dir=' + str(output / 'profile'),
               '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
               '--host-resolver-rules=MAP *.toolbar.test 127.0.0.1, MAP *.localhost 127.0.0.1, MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
               '--force-renderer-accessibility', '--winmux-sidebar-preview', '--winmux-test-service=' + service,
               '--winmux-bridge-report=' + str(output / 'bridge.json'), '--load-extension=' + str(extension), 'about:blank']
    if args.dark:
        command.append('--force-dark-mode')
    if args.high_contrast:
        command.append('--force-high-contrast')
    result = {'passed': False, 'dark': args.dark, 'high_contrast': args.high_contrast, 'loopback_host': args.loopback_host,
              'patch_sha256': manifest['build']['patches_sha256']['0029-minimal-compact-toolbar.patch'], 'layouts': []}
    browser = None
    bootstrapped = False
    sequence = 0

    def report():
        try:
            return json.loads(report_file.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def wait(predicate, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if browser and browser.poll() is not None:
                raise RuntimeError('Fixture browser exited')
            if predicate():
                return
            time.sleep(.05)
        raise TimeoutError('Fixture condition timed out')

    def control(action):
        nonlocal sequence
        previous = output / 'fullscreen-command.json'
        if previous.exists():
            sequence = max(sequence, json.loads(previous.read_text())['sequence'])
        sequence += 1
        temp = output / 'fullscreen-command.tmp'
        temp.write_text(json.dumps({'sequence': sequence, 'action': action}))
        temp.replace(output / 'fullscreen-command.json')
        wait(lambda: report().get('outcomes', {}).get('video_command') == f'{sequence}:issued')

    def capture(name):
        time.sleep(.8)
        hosts = [h for h in report().get('hosts', []) if h['visible']]
        assert hosts
        result['layouts'].append({'name': name, 'hosts': hosts})
        for host in hosts:
            subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(host['native_window_id']),
                            str(output / (name + '-' + str(host['native_window_id']) + '.png'))], check=True)

    try:
        subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(plist)], check=True)
        bootstrapped = True
        with (output / 'browser.log').open('w') as log:
            browser = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        wait(lambda: report().get('outcomes', {}).get('video_fullscreen') == 'ready', timeout=45)
        seed = report()['outcomes']['video_surface']

        def host():
            return next((h for h in report().get('hosts', []) if h['surface_id'] == seed), {})

        control('split')
        wait(lambda: len(report().get('hosts', [])) == 2 and all(h['managed'] and h['visible'] for h in report()['hosts']))
        capture('split')
        control('stack')
        wait(lambda: host().get('managed') and host().get('visible'))
        capture('stack')
        control('focus')
        with (output / 'input.log').open('w') as log:
            subprocess.run([str(probe), str(browser.pid), str(output / 'input'), fixture_url, previous_pid],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        result['input'] = json.loads((output / 'input/input-result.json').read_text())
        control('standalone')
        control('fullscreen')
        wait(lambda: host().get('fullscreen'))
        time.sleep(.8)
        control('fullscreen')
        wait(lambda: host().get('managed') and not host().get('fullscreen'))
        control('standalone')
        capture('fullscreen-restored')
        control('release')
        wait(lambda: not host().get('managed', True))
        capture('released')
        control('standalone')
        wait(lambda: host().get('managed'))
        capture('readopted')
        result['passed'] = True
    except Exception as error:
        result['error'] = str(error)
        raise
    finally:
        if browser and browser.poll() is None:
            browser.terminate()
            try:
                browser.wait(timeout=15)
            except subprocess.TimeoutExpired:
                browser.kill()
                browser.wait(timeout=10)
        if browser:
            result['browser_exit_code'] = browser.returncode
        if bootstrapped:
            clean = subprocess.run(['launchctl', 'bootout', f'gui/{os.getuid()}/{service}'], capture_output=True)
            result['test_service_removed'] = clean.returncode == 0
        server.shutdown()
        server.server_close()
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
