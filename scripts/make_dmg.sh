#!/bin/zsh
# Packages build/Pixora.app into build/Pixora-<version>.dmg: the app, an Applications shortcut to drag it onto,
# the licence files and a short "read me first" about opening an app that isn't notarised.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/Pixora.app ]] || ./scripts/build_app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Pixora.app/Contents/Info.plist)
STAGE=build/dmg-stage
DMG=build/Pixora-$VERSION.dmg
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R build/Pixora.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$STAGE/Third-party notices.md"
cat > "$STAGE/Read Me First.txt" <<TXT
Pixora $VERSION, made by Mithin Sagar (mithinsagarofficial@gmail.com)

1. Drag Pixora onto the Applications folder.
2. Open Pixora from Applications. macOS will say it can't check it for malicious software, because the app
   isn't notarised by Apple. Open System Settings → Privacy & Security, scroll down and click "Open Anyway"
   next to the Pixora message, then confirm. You only need to do this once.

Pixora runs entirely on your Mac: no account, no internet, and nothing is uploaded.
It never changes, moves or deletes your original photos.

Source code: MIT License (LICENSE.txt). The bundled face models are InsightFace's, for non-commercial use only
(see "Third-party notices.md"), so Pixora as distributed is for personal, non-commercial use.
TXT
hdiutil create -volname "Pixora $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null && echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
