"""Reproduce native macOS tab identity transitions using only synthetic windows."""
import argparse
import json
from pathlib import Path
import selectors
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True, help="New result directory")
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
source = Path(__file__).resolve().parent
for name in ["native-tabs-fixture", "native-tabs-cache-probe"]:
    subprocess.run(["swiftc", str(source / (name + ".swift")), "-o", str(output / name)], check=True, timeout=60)

fixture = subprocess.Popen([str(output / "native-tabs-fixture")], stdout=subprocess.PIPE, text=True)
try:
    with selectors.DefaultSelector() as selector:
        selector.register(fixture.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=10):
            raise RuntimeError("Fixture did not start")
    first = fixture.stdout.readline()
    pid = json.loads(first)["pid"]
    if pid != fixture.pid:
        raise RuntimeError("Unexpected fixture PID")
    observation = output / "native-tabs-cache-observation.jsonl"
    with observation.open("w") as stream:
        subprocess.run([str(output / "native-tabs-cache-probe"), str(pid)], stdout=stream, check=True, timeout=25)
    remaining = fixture.communicate(timeout=10)[0]
    if fixture.returncode != 0:
        raise RuntimeError("Fixture failed")
    (output / "native-tabs-fixture-observation.jsonl").write_text(first + remaining)
finally:
    if fixture.poll() is None:
        fixture.terminate()
        fixture.wait(timeout=5)

stages = [json.loads(line) for line in (first + remaining).splitlines()]
samples = [json.loads(line) for line in observation.read_text().splitlines()]
ids = [window["id"] for window in stages[0]["windows"]]
assert len(ids) == 3 and len(set(ids)) == 3
assert [stage["step"] for stage in stages] == list(range(5))
assert len(samples) == 14
for sample in samples:
    assert len(sample["windows"]) == 3
    assert all(window["currentID"] == window["originalID"] for window in sample["windows"])
    assert next(window for window in sample["windows"] if window["originalID"] == ids[2])["enumerated"]

group_owners = {}
inactive = set()
for sample in samples:
    for window in sample["windows"]:
        if not window["enumerated"]:
            inactive.add(window["originalID"])
        for group in window["tabgroups"]:
            if len(group["tabs"]) == 2:
                group_owners.setdefault(group["identity"], set()).add(window["originalID"])
assert inactive == set(ids[:2])
assert any(owners == set(ids[:2]) for owners in group_owners.values())
assert all(window["enumerated"] for window in samples[-1]["windows"])
report = {"passed": True, "samples": len(samples), "native_tab_switch_preserved_cached_ids": True,
          "selected_tab_changes_enumerated_window": True, "group_identity_observed_across_switch": True,
          "detach_restores_both_entries": True, "unrelated_window_preserved": True,
          "fixture_exited": fixture.returncode == 0, "production_window_manager_exercised": False}
(output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
