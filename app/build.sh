#!/bin/bash
# Baut "Save.TV Downloader.app" aus main.swift + ../savetv_dl.py + icon.png
# Voraussetzung: Xcode Command Line Tools  (xcode-select --install)
set -e
cd "$(dirname "$0")"

command -v swiftc >/dev/null 2>&1 || { echo "swiftc fehlt. Bitte einmal ausführen:  xcode-select --install"; exit 1; }
[[ -f ../savetv_dl.py ]] || { echo "../savetv_dl.py nicht gefunden"; exit 1; }

APP="Save.TV Downloader.app"
pkill -x SaveTVDownloader 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Kompiliere … (beim ersten Mal kann das 1–2 Minuten dauern)"
swiftc -O -framework AppKit -framework UserNotifications main.swift -o "$APP/Contents/MacOS/SaveTVDownloader"

cp ../savetv_dl.py "$APP/Contents/Resources/savetv_dl.py"

# App-Icon (.icns) aus icon.png erzeugen
if [[ -f icon.png ]]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
    for s in 16 32 64 128 256 512; do
        sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        d=$((s*2)); sips -z $d $d icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" && echo "Icon erzeugt."
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Save.TV Downloader</string>
    <key>CFBundleDisplayName</key>     <string>Save.TV Downloader</string>
    <key>CFBundleIdentifier</key>      <string>de.savetv-dl.app</string>
    <key>CFBundleVersion</key>         <string>4.2</string>
    <key>CFBundleShortVersionString</key> <string>4.2</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>SaveTVDownloader</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key> <string>Privates Werkzeug – nur für den eigenen Save.TV-Account</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Wird für Mitteilungen und das Anmeldeobjekt benötigt.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
touch "$APP"   # Finder: Icon-Cache auffrischen

echo
echo "Fertig: $(pwd)/$APP"
echo "Starten:   open \"$APP\""
echo "Optional:  nach /Applications kopieren"
