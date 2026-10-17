# RetroDir

**Website:** https://retrodir.app/

A retro dual-panel file manager (inspired by the classic orthodox file managers) for macOS, written in Swift/AppKit with a text-mode look,
plus a built-in tabbed terminal in a bottom split (Cmd-T).

Build: `./build.sh` - needs only the Xcode Command Line Tools and produces `build/RetroDir.app`.
The terminal emulator is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), vendored in
`vendor/SwiftTerm` at tag v1.9.0 and compiled by the build script (SwiftPM is not used because the
Command Line Tools' PackageDescription library fails to link manifests on this machine).

Press F1 in the app for the full keyboard reference. On laptop keyboards use fn+F-keys or Cmd-1...Cmd-0.

## Disclaimer

RetroDir is an experimental, non-commercial project built with AI (Claude Code). Original code and artwork;
not affiliated with or endorsed by any other file manager or its owners. Provided as is, without warranty.
It can move and delete files, so keep backups.

## Licence

RetroDir is released under the [MIT licence](LICENSE), copyright (c) 2026 Ehsan Haque.
It includes [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT, see `vendor/SwiftTerm/LICENSE`);
the app bundle ships both licences in `Contents/Resources/LICENSES.txt` (Options > Licences in the app).

## Releasing

`./release.sh` builds a universal (Apple silicon + Intel) app, signs it with the Developer ID certificate in
the keychain, packages `build/RetroDir.dmg`, notarizes it with the `retrodir-notary` notarytool profile and
staples the ticket. Upload the DMG to a GitHub Release as `RetroDir.dmg` so the website's download link
(`releases/latest/download/RetroDir.dmg`) keeps working.

## Website

The site in `docs/` is served by GitHub Pages at https://retrodir.app/. After editing `docs/style.css`, run
`tools/bump_css.sh` so browsers pick up the new stylesheet. `tools/make_demo.sh` creates the placeholder
folder used for screenshots.
