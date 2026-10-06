# 1Password desktop-link investigation

The user tested source commit `260981fe` and confirmed the trial was approved
in 1Password. The extension's integration toggle is on, but its status reads
“Connection problem”. That status alone does not distinguish a missing host,
a disconnected desktop process, or browser-verification failure.

The earlier patch fixed discovery of the installed native-host registration.
Its isolated extension test verifies discovery and rejection of an unauthorized
extension; it does not validate the real 1Password handshake or Touch ID.

Further inspection found a distribution-certificate requirement in the installed
1Password 8.12.38 BrowserSupport executable. Applying that requirement with
`codesign --verify --strict -R` to the uploaded trial returns status 3:
`code failed to satisfy specified code requirement(s)`. The same check passes
against the installed 1Password application. The trial still passes its own
normal strict signature verification. This is evidence of a certificate-class
mismatch, not a damaged ZIP. It is not a capture of the failing Mac's handshake.

The trial uses an Apple Development certificate. The build machine has two
valid Apple Development identities and no valid Developer ID Application
identity. Developer ID is Apple's distribution-signing option for a Mac app
outside the App Store; obtaining one requires an eligible developer-program
membership and the appropriate account role. See
[Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

## Prepared packaging path

After a Developer ID Application certificate and its matching private key are
available in the build Mac's keychain, select its exact fingerprint and team:

```sh
export BROWSER_SIGNING_IDENTITY='<Developer ID Application certificate SHA-1>'
export BROWSER_SIGNING_TEAM='<certificate team identifier>'
python3 browser/tools/package_alpha.py --root /path/to/existing/engine \
  --output /path/to/new/package --views-trial --developer-id
```

The new flag rejects an unavailable or development identity before staging,
requires secure timestamps for the browser and embedded components, and checks
the Apple Developer ID certificate extensions in the final browser, workspace
helper, and blocker signatures. Chromium's per-process entitlements remain in
use. The manifest records the signing mode, certificate verification, and the
fact that desktop linking has not yet been verified. The default development
packaging path remains available for local UI work.

This command does not notarize. Notarization, stapling, a fresh ZIP, and an
end-to-end 1Password check remain release steps after obtaining the identity.
Do not describe certificate checks or native-host discovery as an integration
pass. Use the supported Add Browser flow for the final installed package, then
check extension lock/unlock, Touch ID, and a browser restart.

No vault contents, approved-browser entries, certificate trust settings, or
existing app installations were changed during this investigation.
