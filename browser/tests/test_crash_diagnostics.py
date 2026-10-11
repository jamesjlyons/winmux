"""Portable collector parsing, bounds, and data-minimization regressions."""
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

COLLECTOR = Path(__file__).resolve().parents[1] / 'tools/collect_browser_diagnostics.pl'


def fixture():
    data = bytearray(32 + 4 * 12)
    data[:4] = b'MDMP'
    struct.pack_into('<III', data, 4, 0xA793, 4, 32)
    struct.pack_into('<I', data, 20, 1791586800)
    streams = []

    def alloc(value):
        offset = len(data)
        data.extend(value)
        return offset

    def string(value, wide=False):
        encoded = value.encode('utf-16le' if wide else 'utf-8')
        return alloc(struct.pack('<I', len(encoded)) + encoded)

    annotations = [('pid', '1234'), ('ptype', 'renderer'), ('ver', '153.0.8010.53'),
                   ('url', 'https://private.invalid/secret-token'),
                   ('fatal_log', 'PRIVATE_FATAL_CONTENT')]
    entries = [(string(k), string(v)) for k, v in annotations]
    dictionary = alloc(struct.pack('<I', len(entries)) + b''.join(struct.pack('<II', *x) for x in entries))
    info = bytearray(52)
    struct.pack_into('<I', info, 0, 1)
    struct.pack_into('<II', info, 36, 4 + len(entries) * 8, dictionary)
    streams.append((0x43500001, len(info), alloc(info)))

    name = string('/Users/private-user/Chromium Framework', wide=True)
    cv = alloc(b'RSDS' + bytes(range(16)) + struct.pack('<I', 0))
    module = bytearray(108)
    struct.pack_into('<QI', module, 0, 0x100000000, 0x10000)
    struct.pack_into('<I', module, 20, name)
    struct.pack_into('<II', module, 76, 24, cv)
    modules = alloc(struct.pack('<I', 1) + module)
    streams.append((4, 112, modules))

    stack = bytearray(128)
    struct.pack_into('<QQ', stack, 0, 0x200000010, 0x100000300)
    struct.pack_into('<QQ', stack, 16, 0, 0x100000400)
    stack[32:64] = b'PRIVATE_STACK_CONTENT'.ljust(32, b'!')
    stack_offset = alloc(stack)
    context = bytearray(272)
    struct.pack_into('<I', context, 0, 0x00400007)
    struct.pack_into('<QQQQ', context, 240, 0x200000000, 0x100000200, 0x200000000, 0x100000100)
    context_offset = alloc(context)
    thread = bytearray(48)
    struct.pack_into('<I', thread, 0, 42)
    struct.pack_into('<QIIII', thread, 24, 0x200000000, len(stack), stack_offset, len(context), context_offset)
    threads = alloc(struct.pack('<I', 1) + thread)
    streams.append((3, 52, threads))
    exception = bytearray(168)
    struct.pack_into('<I', exception, 0, 42)
    struct.pack_into('<II', exception, 8, 6, 1)
    struct.pack_into('<I', exception, 32, 2)
    struct.pack_into('<QQ', exception, 40, 6, 1)
    struct.pack_into('<II', exception, 160, len(context), context_offset)
    streams.append((6, 168, alloc(exception)))
    for i, entry in enumerate(streams):
        struct.pack_into('<III', data, 32 + 12 * i, *entry)
    return data, dict(stack=stack_offset, context=context_offset)


class CrashDiagnosticsTest(unittest.TestCase):
    def summarize(self, data, expected_success=True):
        with tempfile.TemporaryDirectory(prefix='winmux-dump-parser-') as tmp:
            path = Path(tmp) / 'fixture.dmp'
            path.write_bytes(data)
            result = subprocess.run(['/usr/bin/perl', str(COLLECTOR), '--summarize', str(path)],
                                    capture_output=True, text=True, timeout=5)
        if expected_success:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            return json.loads(result.stdout), result.stdout
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        return result

    def test_crash_identity_and_frame_offsets_without_private_contents(self):
        data, _ = fixture()
        report, raw = self.summarize(data)
        self.assertEqual(report['annotations'], {'pid': '1234', 'ptype': 'renderer', 'ver': '153.0.8010.53'})
        self.assertEqual(report['exception']['thread_id'], 42)
        self.assertEqual(report['exception']['parameters'], ['0x6', '0x1'])
        self.assertEqual([f['image_offset'] for f in report['arm64_frames']], ['0x100', '0x200', '0x300', '0x400'])
        for secret in ('private.invalid', 'secret-token', 'PRIVATE_', 'private-user', '/Users/'):
            self.assertNotIn(secret, raw)

    def test_rejects_truncated_dump(self):
        data, _ = fixture()
        self.summarize(data[:-100], expected_success=False)

    def test_rejects_unbounded_stream_count(self):
        data, _ = fixture()
        struct.pack_into('<I', data, 8, 0xFFFFFFFF)
        self.summarize(data, expected_success=False)

    def test_cyclic_frame_pointer_stops(self):
        data, positions = fixture()
        struct.pack_into('<Q', data, positions['stack'], 0x200000000)
        report, _ = self.summarize(data)
        self.assertEqual(len(report['arm64_frames']), 3)

    def test_does_not_guess_unknown_context_layout(self):
        data, positions = fixture()
        struct.pack_into('<I', data, positions['context'], 0x00100007)
        report, _ = self.summarize(data)
        self.assertNotIn('arm64_frames', report)
        self.assertEqual(report['exception']['code'], '0x6')

    def test_unknown_code_pointer_does_not_emit_memory_address(self):
        data, positions = fixture()
        struct.pack_into('<Q', data, positions['context'] + 264, 0x123456789)
        report, raw = self.summarize(data)
        self.assertEqual(report['arm64_frames'][0], {'unmapped': True, 'origin': 'pc'})
        self.assertNotIn('123456789', raw)


if __name__ == '__main__':
    unittest.main()
