#!/bin/zsh
# Builds build/Pixora.app: release binary + compiled face models + Info.plist + icon, signed with the local
# identity from scripts/make_signing_identity.sh (ad hoc if that isn't available).
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Pixora.app
BUILD_PATH="${PIXORA_BUILD_PATH:-.build}"
swift build -c release --product Pixora --build-path "$BUILD_PATH" ${=PIXORA_SWIFT_FLAGS:-}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_PATH/release/Pixora" "$APP/Contents/MacOS/Pixora"

# Face models: SCRFD detector + ArcFace recogniser (preferred); FaceNet only if ArcFace is missing.
bundled=0
for m in SCRFD10G ArcFaceR50; do
  if [[ -d Models/$m.mlpackage ]]; then
    xcrun coremlcompiler compile Models/$m.mlpackage "$APP/Contents/Resources/" >/dev/null; echo "✓ bundled $m.mlmodelc"; bundled=1
  fi
done
if [[ ! -d Models/ArcFaceR50.mlpackage && -d Models/FaceNet512.mlpackage ]]; then
  xcrun coremlcompiler compile Models/FaceNet512.mlpackage "$APP/Contents/Resources/" >/dev/null; echo "✓ bundled FaceNet512.mlmodelc"; bundled=1
fi
if [[ $bundled == 0 ]]; then
  echo "! No face models in Models/ — the app will run in Basic mode. See README to create them."
fi

# App icon
ICONSET=build/Pixora.iconset; rm -rf $ICONSET; mkdir -p $ICONSET
swift scripts/make_icon.swift build/icon_1024.png
for sz in 16 32 128 256 512; do
  sips -z $sz $sz build/icon_1024.png --out $ICONSET/icon_${sz}x${sz}.png >/dev/null
  sips -z $((sz*2)) $((sz*2)) build/icon_1024.png --out $ICONSET/icon_${sz}x${sz}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"

VERSION="${PIXORA_VERSION:-1.3.0}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Pixora</string>
  <key>CFBundleDisplayName</key><string>Pixora</string>
  <key>CFBundleIdentifier</key><string>local.pixora.Pixora</string>
  <key>CFBundleExecutable</key><string>Pixora</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Made by Mithin Sagar · mithinsagarofficial@gmail.com · MIT License (bundled face models: non-commercial use)</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Pixora reads photos on memory cards to find the people in them. It never changes or deletes them.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Pixora reads photos on network drives to find the people in them. It never changes or deletes them.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Pixora reads photos you choose in this folder, and copies photos here only when you export to it.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Pixora reads photos you choose in this folder, and copies photos here only when you export to it.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Pixora reads photos you choose in this folder, and copies photos here only when you export to it.</string>
  <key>NSContactsUsageDescription</key><string>Pixora links a person to their contact card only when you choose “Link to Contact”, so you can send them their photos.</string>
  <key>NSPicturesFolderUsageDescription</key><string>Pixora reads photos you choose in this folder, and copies photos here only when you export to it.</string>
</dict></plist>
PLIST

# Sign with the stable local identity (scripts/make_signing_identity.sh) so macOS treats each rebuild as the
# same app and doesn't ask for the keychain password again. Falls back to ad-hoc if it can't be created.
KC="$PWD/.signing/pixora-signing.keychain-db"
[[ -f "$KC" ]] || ./scripts/make_signing_identity.sh >/dev/null 2>&1 || true
if [[ -f "$KC" ]] && security unlock-keychain -p "$(cat .signing/keychain-password)" "$KC" 2>/dev/null; then
  codesign --force --deep --keychain "$KC" --sign "Pixora Local Signing" "$APP"
else
  echo "! signing ad hoc: macOS may ask for the keychain password after each rebuild"
  codesign --force --deep --sign - "$APP"
fi
echo "✓ built $APP"
