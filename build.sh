#!/bin/zsh
# Builds build/Ejectus.app (Apple silicon + Intel).
set -euo pipefail
cd "${0:A:h}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Ejectus"

APP=build/Ejectus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ejectus"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.ejectus</string>
    <key>CFBundleName</key><string>Ejectus</string>
    <key>CFBundleExecutable</key><string>Ejectus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>2.4</string>
    <key>CFBundleVersion</key><string>BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Clean Junk Files</string></dict>
            <key>NSMessage</key><string>cleanJunk</string>
            <key>NSPortName</key><string>Ejectus</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.volume</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Unique build number every build, so each installed build is identifiable.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"

# Spotlight helper: a standalone copy of the binary plus its installer (see install-helper.sh).
cp "$BIN" "$APP/Contents/Resources/EjectusHelper"
cp install-helper.sh "$APP/Contents/Resources/install-helper.sh"

# Sign with a stable local certificate if one exists, so macOS keeps Full Disk Access and the
# helper approval across updates. Otherwise fall back to ad-hoc (approvals reset each build).
IDENTITY="Ejectus Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --identifier local.ejectus.privhelper "$APP/Contents/Resources/EjectusHelper"
    codesign --force --sign "$IDENTITY" --identifier local.ejectus "$APP"
else
    echo "note: no \"$IDENTITY\" certificate; signing ad-hoc"
    codesign --force --sign - --identifier local.ejectus.privhelper "$APP/Contents/Resources/EjectusHelper"
    codesign --force --sign - --identifier local.ejectus "$APP"
fi
echo "Built $APP"
