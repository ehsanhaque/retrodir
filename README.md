# RetroDir

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
