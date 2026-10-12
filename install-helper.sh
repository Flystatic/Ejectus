#!/bin/sh
# Installs Ejectus's Spotlight helper as a classic launchd daemon. Run as root (the app asks for
# the admin password). The helper is a standalone signed copy, so app updates don't affect it.
set -e
LABEL=local.ejectus.privhelper
SRC="$(dirname "$0")/EjectusHelper"
DST=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

launchctl bootout system/$LABEL 2>/dev/null || true
mkdir -p /Library/PrivilegedHelperTools
cp "$SRC" "$DST"
chown root:wheel "$DST"
chmod 755 "$DST"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DST</string><string>--helper</string></array>
    <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
