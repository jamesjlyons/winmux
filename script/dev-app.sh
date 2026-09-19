#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_name='WinMux Dev.app'
build_app="$repo_dir/.local/dev-build/$app_name"
install_app="${DEV_INSTALL_DIR:-/Applications}/$app_name"
signing_identity="${DEV_SIGNING_IDENTITY:-Apple Development}"
# Direct packaging keeps the historical Debug default. `make dev-build` selects
# the optimized Release configuration, still compiled with -DDEBUG for Dev identity.
build_configuration="${DEV_BUILD_CONFIGURATION:-debug}"
case "$build_configuration" in
    debug|release) ;;
    *) echo 'DEV_BUILD_CONFIGURATION must be debug or release.' >&2; exit 2 ;;
esac
binary_dir="$repo_dir/.build/$build_configuration"

verify_signature() {
    codesign --verify --deep --strict "$1"
    codesign -dv --verbose=4 "$1" 2>&1 | rg '^Authority=Apple Development:' >/dev/null
    codesign -dr - "$1" 2>&1 | rg 'identifier "com.zimengxiong.winmux.debug"' >/dev/null
}

case "${1:-build}" in
    build)
        if ! security find-identity -v -p codesigning | rg '"Apple Development:' >/dev/null; then
            echo 'An Apple Development signing identity is required. No ad-hoc fallback is used.' >&2
            exit 1
        fi
        mkdir -p "$(dirname "$build_app")"
        staging_dir="$(mktemp -d "$repo_dir/.local/dev-build/staging.XXXXXX")"
        trap 'rm -rf "$staging_dir"' EXIT
        staged_app="$staging_dir/$app_name"
        mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
        cp "$binary_dir/WinMuxApp" "$staged_app/Contents/MacOS/WinMuxApp"
        ditto "$binary_dir/Sparkle.framework" "$staged_app/Contents/MacOS/Sparkle.framework"
        for bundle in "$binary_dir"/*.bundle; do
            [ ! -d "$bundle" ] || ditto "$bundle" "$staged_app/Contents/Resources/$(basename "$bundle")"
        done
        python3 - "$staged_app/Contents/Info.plist" "${VERSION:-0.0.0}" "$build_configuration" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleExecutable='WinMuxApp', CFBundleIdentifier='com.zimengxiong.winmux.debug',
                      CFBundleName='WinMux Dev', CFBundleDisplayName='WinMux Dev', CFBundlePackageType='APPL',
                      CFBundleVersion=sys.argv[2], CFBundleShortVersionString=sys.argv[2],
                      LSUIElement=True, LSMinimumSystemVersion='13.0', NSHighResolutionCapable=True,
                      WinMuxBuildConfiguration=sys.argv[3]), f)
PY
        # Sign the app as a complete bundle; preserve valid vendor signatures on nested frameworks.
        codesign --force --sign "$signing_identity" --entitlements "$repo_dir/resources/WinMux.entitlements" "$staged_app"
        verify_signature "$staged_app"
        rm -rf "$build_app"
        mv "$staged_app" "$build_app"
        echo "Signed development app: $build_app"
        ;;
    install)
        verify_signature "$build_app"
        if pgrep -f '[/]WinMux Dev.app/Contents/MacOS/WinMuxApp' >/dev/null; then
            echo 'Quit WinMux Dev before installing so its session is saved and its running bundle stays intact.' >&2
            exit 1
        fi
        mkdir -p "$(dirname "$install_app")"
        install_staging="$(mktemp -d "$(dirname "$install_app")/.winmux-dev-install.XXXXXX")"
        trap 'rm -rf "$install_staging"' EXIT
        ditto "$build_app" "$install_staging/$app_name"
        verify_signature "$install_staging/$app_name"
        if [ -d "$install_app" ]; then
            old_requirement="$(codesign -dr - "$install_app" 2>&1 | sed -n 's/^designated => //p')"
            if [ -n "$old_requirement" ] && ! codesign --verify --test-requirement "=$old_requirement" "$install_staging/$app_name"; then
                echo 'The signing identity changed. Keep the existing app and explicitly migrate its permissions before replacing it.' >&2
                exit 1
            fi
            mv "$install_app" "$install_staging/previous.app"
        fi
        if ! mv "$install_staging/$app_name" "$install_app"; then
            [ ! -d "$install_staging/previous.app" ] || mv "$install_staging/previous.app" "$install_app"
            exit 1
        fi
        echo "Installed: $install_app"
        ;;
    run)
        verify_signature "$install_app"
        if pgrep -f '[/]WinMux Dev.app/Contents/MacOS/WinMuxApp' >/dev/null; then
            echo 'WinMux Dev is already running. Quit it before starting another instance.' >&2
            exit 1
        fi
        if [ -n "${WINMUX_CONFIG_PATH:-}" ]; then
            exec "$install_app/Contents/MacOS/WinMuxApp" --config-path "$WINMUX_CONFIG_PATH" "${@:2}"
        fi
        exec "$install_app/Contents/MacOS/WinMuxApp" "${@:2}"
        ;;
    *) echo 'Usage: dev-app.sh build|install|run' >&2; exit 2 ;;
esac
