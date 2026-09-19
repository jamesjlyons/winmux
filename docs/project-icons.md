# Space icons

Open a space's menu (including a right-click on its sidebar indicator) and choose **Choose Icon…**. Search by SF Symbol name or keyword, then click a symbol or use the arrow keys and Return. **Use Default** restores its colored dot. Escape and clicking outside dismiss the picker without changing the icon.

Icons use the space's color. The default dot is the `circle.fill` SF Symbol. The switcher uses evenly spaced icons and shows selection by brightness, with no background or checkmark. Their stable project ID keeps the assignment intact when spaces are renamed or reordered. Deleting a space removes its icon setting.

```toml
[workspace-sidebar.project-icons]
"default" = "house"
"project-5" = "music.note"
```

Omitting a key restores the default dot. A symbol unavailable on the running macOS version also displays a dot, while retaining the saved name for a newer system. Icon changes are written before updating the sidebar; write failures show the existing Sidebar Error message.

## Offline catalog

`Sources/AppBundle/Resources/sf-symbols.json` contains public names, keywords, and macOS availability from Apple's SF Symbols 27.0 metadata. It includes 9,524 names and localized variants. No symbol artwork or fonts are bundled; AppKit renders system symbols, and the picker filters unsupported names. Exact-name lookup also supports newer OS symbols between catalog refreshes.

Download the latest official app from [Apple](https://developer.apple.com/sf-symbols/), then run:

```sh
python3 script/generate-symbol-catalog.py '/Applications/SF Symbols.app'
```

The generator accepts an extracted app as well as an installed app and writes deterministic output. End users do not need the SF Symbols app or an internet connection. Refresh the version/count expectations in the catalog test when updating it.

## Validation

`WorkspaceSidebarProjectIconTest` covers configuration, persistence failures, restart loading, project lifecycle, two-monitor selection, catalog/search, and native menu color rendering. Render compact and expanded icon fixtures with:

```sh
swift run winmux-marketing-renderer --project-icon-proof /tmp/winmux-project-icons-proof
```

This renders 28-, 120-, and 240-point sidebars with default dots and assigned symbols across solid, Liquid Glass, and menu-bar styles in light and dark appearances.
