"""Exercise production native-tab detection against off-screen synthetic windows."""
import argparse
import json
from pathlib import Path
import selectors
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
source = Path(__file__).resolve().parent
repo = source.parents[1]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
(output / 'main.swift').write_text((source / 'probe.swift').read_text())
subprocess.run(['swiftc', str(repo / 'Sources/AppBundle/tree/NativeTabRegistry.swift'),
                str(repo / 'Sources/AppBundle/tree/NativeTabAccessibility.swift'),
                str(output / 'main.swift'), '-o', str(output / 'probe')], check=True, timeout=60)
subprocess.run(['swiftc', str(source / 'fixture.swift'), '-o', str(output / 'fixture')], check=True, timeout=60)
fixture = subprocess.Popen([str(output / 'fixture')], stdout=subprocess.PIPE, text=True)
try:
    with selectors.DefaultSelector() as selector:
        selector.register(fixture.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=10):
            raise RuntimeError('Fixture did not start')
    first = fixture.stdout.readline()
    pid = json.loads(first)['pid']
    assert pid == fixture.pid
    with (output / 'observations.jsonl').open('w') as stream:
        subprocess.run([str(output / 'probe'), str(pid)], stdout=stream, check=True, timeout=25)
    remaining = fixture.communicate(timeout=5)[0]
    assert fixture.returncode == 0
    (output / 'fixture.jsonl').write_text(first + remaining)
finally:
    if fixture.poll() is None:
        fixture.terminate()
        fixture.wait(timeout=5)

stages = [json.loads(line) for line in (first + remaining).splitlines()]
samples = [json.loads(line) for line in (output / 'observations.jsonl').read_text().splitlines()]
assert [stage['step'] for stage in stages] == list(range(8))
assert len(samples) == 31
identities = {}
checked = set()
for index, stage in enumerate(stages):
    start = stage['time'] + 0.3
    end = stages[index + 1]['time'] - 0.3 if index + 1 < len(stages) else float('inf')
    expected = sorted({window['selected'] for window in stage['windows'] if window['visible']})
    for sample in samples:
        if not start <= sample['time'] <= end:
            continue
        checked.add(index)
        assert sample['logical'] == expected, (index, expected, sample)
        for slot in [0, 3]:
            # First group survives until step 5; second until step 7.
            if (slot == 0 and index >= 5) or (slot == 3 and index >= 7):
                continue
            # At step 4, window 0 detaches; the group remains on window 1.
            selected = stage['windows'][1 if slot == 0 and index == 4 else slot]['selected']
            group = next(g for g in sample['groups'] if g['selected'] == selected)
            if slot in identities:
                assert group['identity'] == identities[slot], (index, slot, sample)
            else:
                identities[slot] = group['identity']
            expected_count = len(stage['windows'][1 if slot == 0 and index == 4 else slot]['tabs'])
            assert group['count'] == max(expected_count, 1), (index, sample)
assert checked == set(range(8)), checked
assert len(set(identities.values())) == 2
report = {'passed': True, 'samples': len(samples), 'stages': len(checked),
          'production_detector': True, 'stable_group_identity': True,
          'identical_titles_remain_separate': True, 'create_switch_close_detach': True,
          'desktop_rearranged': False, 'full_window_manager_exercised': False}
(output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
