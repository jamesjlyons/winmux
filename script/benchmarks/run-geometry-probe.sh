#!/bin/bash
# Requires a running WinMux Dev with Accessibility permission and an unlocked session.
# Opens one temporary window, perturbs its frame 12 times, then closes it.
set -euo pipefail
benchmark_dir="$(cd "$(dirname "$0")" && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/winmux-geometry.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
probe_app="$probe_dir/WinMuxGeometryProbe.app"
mkdir -p "$probe_app/Contents/MacOS"
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.winmux.geometry-probe</string><key>CFBundleExecutable</key><string>probe</string><key>CFBundleName</key><string>WinMux Geometry Probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc "$benchmark_dir/geometry-probe.swift" -o "$probe_app/Contents/MacOS/probe"
"$probe_app/Contents/MacOS/probe"
