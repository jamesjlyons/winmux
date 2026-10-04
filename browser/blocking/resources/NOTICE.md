# Bundled blocking resources

`easylist.txt.gz` and `easyprivacy.txt.gz` are unmodified snapshots by
**The EasyList authors (https://easylist.to/)**, retrieved 2026-09-19. Original
headers and authorship are preserved inside each file. `manifest.json` records
the source URLs, list version, and SHA-256 of the uncompressed contents.

The authors offer GPL-3.0-or-later or CC-BY-SA-3.0-or-later. These snapshots are
distributed under the permitted CC-BY-SA-4.0 option; its full text is in
`licenses/CC-BY-SA-4.0.txt`. License source:
https://easylist.to/pages/licence.html. Compression changes no list content.
Any distributed modified lists must retain attribution and their license.

The filtering engine is Brave's **adblock-rust 0.13.3**, licensed MPL-2.0:
https://github.com/brave/adblock-rust. Its license is included in
`licenses/MPL-2.0.txt`. Exact dependencies and registry checksums are in
`../Cargo.lock`. The engine source is available from crates.io for the exact
version. The alpha packaging step must include engine/dependency notices and
the corresponding source offer before distribution; that step is not yet built.

The only v1 replacement resource is an empty JavaScript response named
`empty.js`, authored for this project and covered by the repository MIT license.
There is no remotely supplied executable resource or scriptlet. Procedural
cosmetics and additional scriptlets remain pending renderer integration.
