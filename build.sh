#!/bin/zsh
# Builds RetroDir.app with the Swift command line tools (no Xcode / SwiftPM needed).
# SwiftTerm (MIT, vendored at vendor/SwiftTerm, tag v1.9.0) is compiled once into a static library.
set -e
cd "$(dirname "$0")"
ARCH=$(uname -m)
TARGET=$ARCH-apple-macos13.0
APP=build/RetroDir.app
ST=vendor/SwiftTerm/Sources/SwiftTerm
mkdir -p build/mod

if [ ! -d "$ST" ]; then
  git clone -q --depth 1 --branch v1.9.0 https://github.com/migueldeicaza/SwiftTerm vendor/SwiftTerm
fi

LIB=build/libSwiftTerm.a
if [ ! -f "$LIB" ] || [ -n "$(find $ST -name '*.swift' -newer $LIB)" ]; then
  echo "Compiling SwiftTerm..."
  swiftc -O -swift-version 5 -target $TARGET -parse-as-library -module-name SwiftTerm \
    -emit-library -static -emit-module -emit-module-path build/mod/SwiftTerm.swiftmodule -o $LIB \
    $ST/*.swift $ST/Apple/*.swift $ST/Mac/*.swift
fi

echo "Compiling RetroDir..."
swiftc -O -swift-version 5 -target $TARGET -I build/mod -L build -lSwiftTerm \
  -framework AppKit -framework Quartz -framework Metal -framework MetalKit -framework CoreText \
  Sources/RetroDir/*.swift -o build/RetroDir

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/RetroDir "$APP/Contents/MacOS/RetroDir"
cp Info.plist "$APP/Contents/Info.plist"
{
  echo "RetroDir is an experimental, non-commercial project built with AI (Claude Code)."
  echo "Original code and artwork; not affiliated with or endorsed by any other file manager or its owners."
  echo "Provided as is, without warranty. It can move and delete files, so keep backups."
  echo
  echo "# RetroDir"
  echo
  cat LICENSE
  echo
  echo "RetroDir includes the following third-party software."
  echo
  echo "# SwiftTerm v1.9.0 - https://github.com/migueldeicaza/SwiftTerm"
  echo
  cat vendor/SwiftTerm/LICENSE
} > "$APP/Contents/Resources/LICENSES.txt"
ICNS=build/AppIcon.icns
if [ ! -f $ICNS ] || [ icon/AppIcon-source.png -nt $ICNS ] || [ tools/make_icon.swift -nt $ICNS ]; then
  echo "Rendering icon..."
  rm -rf build/AppIcon.iconset
  swift tools/make_icon.swift icon/AppIcon-source.png build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o $ICNS
fi
cp $ICNS "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
