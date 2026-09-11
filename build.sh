#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
VERSION="$(cat VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid VERSION" >&2
    exit 1
fi
APP="$PWD/build/轻缓存.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/zsh ./build-icon.sh
/bin/cp Assets/AppIcon.icns Assets/BrandIcon.png "$APP/Contents/Resources/"
/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 Sources/BrowserActivity.swift Sources/BrowserLauncher.swift -o "$APP/Contents/Resources/BrowserLauncher"
/usr/bin/clang -O2 -mmacosx-version-min=14.0 -c Sources/NativeProbe.c -o build/NativeProbe.o
/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 Sources/Core.swift Sources/NativeProbe.swift build/NativeProbe.o Sources/BrowserActivity.swift Sources/BrowserReaper.swift Sources/App.swift -o "$APP/Contents/MacOS/MacCacheCare" -framework SwiftUI -framework AppKit -framework CoreGraphics
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.chris.MacCacheCare</string>
<key>CFBundleName</key><string>轻缓存</string>
<key>CFBundleDisplayName</key><string>轻缓存</string>
<key>CFBundleExecutable</key><string>MacCacheCare</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP"
echo "$APP"
