#!/bin/bash
# Opens two temporary windows, alternates native focus 16 times, then closes both.
set -euo pipefail
benchmark_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$benchmark_dir/../.." && pwd)"
cli="${WINMUX_BENCHMARK_CLI:-$repo_dir/.build/release/winmux}"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/winmux-focus.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
probe_app="$probe_dir/WinMuxFocusProbe.app"
mkdir -p "$probe_app/Contents/MacOS"
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.winmux.focus-probe</string><key>CFBundleExecutable</key><string>probe</string><key>CFBundleName</key><string>WinMux Focus Probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc -O "$benchmark_dir/focus-probe.swift" -o "$probe_app/Contents/MacOS/probe"
"$probe_app/Contents/MacOS/probe" "$cli" "${1:-unlabelled}"
