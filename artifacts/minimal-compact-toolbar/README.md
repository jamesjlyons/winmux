# Minimal compact browser toolbar

The integrated browser keeps its existing system material and 34-point row.
The resting address pill and action divider are removed. Hover adds a faint
rounded fill; editing retains Chromium's field, focus ring, suggestions, and
higher-contrast treatment. Navigation icons remain 16 points inside 26-point
button targets, with the native traffic lights centered in the same row.

Ordinary HTTP/HTTPS pages paint only their hostname, retaining subdomains and
non-default ports. Chromium's URL formatter handles internationalized names.
The underlying address, clipboard, accessibility text, and editing model remain
native. Focus reveals the complete editing address; Chromium's existing omission
of `http://` in its editing display is retained, and copying still includes the
scheme. Non-web URLs and unfinished input keep their normal presentation.

Empty compact-toolbar padding participates in native frame dragging. Controls
and the address field retain their own hit targets. Releasing management restores
Chromium's conventional presentation. The change introduces no bridge protocol,
settings, or persisted-data changes.

Implementation is in
[`0029-minimal-compact-toolbar.patch`](../../browser/chromium/patches/0029-minimal-compact-toolbar.patch).
The patch adds three Chromium omnibox regression tests covering hostname
formatting, focus/copy/draft behavior, navigation updates, and mouse selection.

## Native verification

The reusable fixture launches a signed package with temporary browser data,
a local page server, an extension, and a temporary helper service. It checks
native accessibility geometry, mouse and keyboard input, copied URLs, navigation,
extensions, downloads, non-web addresses, narrow/wide layouts, dragging, and
fullscreen/release/re-adoption. Screenshots and results are written to the chosen
output directory. Address suggestions were also visually verified in the full
editing screenshots for all three appearances. It restores the clipboard and removes its helper service.

```sh
python3 browser/tools/test_browser_minimal_toolbar.py \
  --app '/path/to/WinMux Browser Alpha.app' \
  --output .local/minimal-toolbar/check-light
```

Add `--dark` or `--high-contrast` for the other appearances. `--loopback-host`
uses a trustworthy `.localhost` fixture so the comparison can also show the
ordinary site-information icon. Ordinary HTTP fixtures retain the native
**Not Secure** indicator. macOS Accessibility and screen capture access are
required for the native fixture.

See [report.json](report.json) for recorded build and verification results.
The complete Chromium unit-test executable is not built in this workspace;
the new C++ regression tests are compile-checked, while interaction assertions
run against the signed browser through the native fixture.
