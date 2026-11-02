#!/bin/zsh
# Screenshot/testing build: identical app plus env hooks compiled in with -DPIXORA_UI_TESTING
# (PIXORA_TEST_SETUP / PIXORA_TEST_UNLOCK / PIXORA_TEST_CLEANUP drive Private Space for screenshots).
# The normal build (scripts/build_app.sh) never contains these hooks.
set -euo pipefail
cd "$(dirname "$0")/.."
mv build/Pixora.app build/.Pixora-keep 2>/dev/null || true
PIXORA_BUILD_PATH=.build-uitest PIXORA_SWIFT_FLAGS="-Xswiftc -DPIXORA_UI_TESTING" ./scripts/build_app.sh >/dev/null
rm -rf build/PixoraUITest.app
mv build/Pixora.app build/PixoraUITest.app
mv build/.Pixora-keep build/Pixora.app 2>/dev/null || true
echo "✓ built build/PixoraUITest.app (testing hooks enabled)"
