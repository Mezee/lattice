#!/bin/zsh
# Builds Lattice.app. Usage: ./build.sh [--zip]
set -e
cd "$(dirname "$0")"
VERSION="0.1.4"
APP="${APP_DIR:-$HOME/Applications}/Lattice.app"
# Compile first, so a failed build never removes an installed app.
swiftc -O -target arm64-apple-macos26.0 main.swift -o .build-arm64
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -target x86_64-apple-macos26.0 main.swift -o .build-x86 2>/dev/null && lipo -create .build-arm64 .build-x86 -output "$APP/Contents/MacOS/Lattice" || cp .build-arm64 "$APP/Contents/MacOS/Lattice"
rm -f .build-arm64 .build-x86
mkdir -p "$APP/Contents/Resources"
cp assets/Lattice.icns assets/menubar-*.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Lattice</string>
<key>CFBundleIdentifier</key><string>io.github.mezee.lattice</string>
<key>CFBundleExecutable</key><string>Lattice</string>
<key>CFBundleIconFile</key><string>Lattice</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
# A fixed designated requirement lets the Accessibility permission survive rebuilds.
codesign --force --sign - -r="designated => identifier \"io.github.mezee.lattice\"" "$APP"
echo "Built $APP"
if [[ "$1" == "--zip" ]]; then
  ditto -c -k --keepParent "$APP" "Lattice-$VERSION.zip"
  echo "Wrote Lattice-$VERSION.zip"
fi
