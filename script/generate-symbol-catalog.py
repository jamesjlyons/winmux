#!/usr/bin/env python3
"""Generate the offline name/keyword catalog from Apple's public SF Symbols app."""
import argparse
import json
import pathlib
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=pathlib.Path, help="Path to the latest official SF Symbols.app")
parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1] / "Sources/AppBundle/Resources/sf-symbols.json")
args = parser.parse_args()
contents = args.app / "Contents"
metadata = contents / "Resources/Metadata"

def read_plist(path):
    return plistlib.loads(path.read_bytes())

info = read_plist(contents / "Info.plist")
availability = read_plist(metadata / "name_availability.plist")
search = read_plist(metadata / "symbol_search.plist")
symbols = []
for name, release in sorted(availability["symbols"].items()):
    mac_version = availability["year_to_release"][release].get("macOS")
    if mac_version is None:
        continue
    symbols.append(dict(name=name, keywords=sorted(set(search.get(name, []))), macOS=mac_version))
assert len(symbols) > 5000, "Unexpectedly incomplete SF Symbols metadata"
catalog = dict(version=info["CFBundleShortVersionString"], source="https://developer.apple.com/sf-symbols/", symbols=symbols)
args.output.parent.mkdir(parents=True, exist_ok=True)
# One entry per line keeps catalog updates reviewable without expanding every field.
header = json.dumps({k: v for k, v in catalog.items() if k != "symbols"}, ensure_ascii=False)[:-1]
text = header + ', "symbols": [\n' + ',\n'.join(json.dumps(s, ensure_ascii=False, sort_keys=True) for s in symbols) + '\n]}\n'
args.output.write_text(text)
print(f"Generated {len(symbols)} symbols from SF Symbols {catalog['version']} → {args.output}")
