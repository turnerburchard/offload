#!/bin/zsh
# Builds the SwiftPM package and wraps the binary into a double-clickable Offload.app.
# Usage: ./build.sh [debug|release]   (default release)
set -euo pipefail
cd "${0:A:h}"
CONFIG=${1:-release}
# Single source of truth for the version. In CI a v* tag must match it.
VERSION=$(tr -d ' \n' < VERSION)
if [[ "${GITHUB_REF_TYPE:-}" == tag && "${GITHUB_REF_NAME:-}" != "v$VERSION" ]]; then
  echo "Tag ${GITHUB_REF_NAME} doesn't match VERSION ($VERSION)" >&2; exit 1
fi
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
# GitHub repo the updater checks (forks get their own automatically in Actions).
REPO=${OFFLOAD_REPO:-${GITHUB_REPOSITORY:-turnerburchard/offload}}
# Keep SwiftPM/clang caches inside this folder.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
SPM=(--cache-path .build/spm-cache --config-path .build/spm-config --security-path .build/spm-security -c "$CONFIG")
swift build "${SPM[@]}"
BIN="$(swift build "${SPM[@]}" --show-bin-path)"

APP=Offload.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Offload" "$APP/Contents/MacOS/Offload"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SD Offload</string>
  <key>CFBundleDisplayName</key><string>SD Offload</string>
  <key>CFBundleIdentifier</key><string>io.github.turnerburchard.offload</string>
  <key>CFBundleExecutable</key><string>Offload</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>OffloadUpdateRepo</key><string>$REPO</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>Reads SD cards and copies photos to your backup drives.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"   # ad-hoc signature so Gatekeeper/TCC treat it as one stable app
echo "Built $PWD/$APP (version $VERSION, build $BUILD_NUMBER, updates from $REPO)"
