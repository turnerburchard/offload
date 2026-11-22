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
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate with: swift scripts/make-icon.swift
cp Resources/EmptyCatalog.lrcat "$APP/Contents/Resources/EmptyCatalog.lrcat"   # empty Lightroom Classic catalog, copied for each import
# Local builds remember where their source is, for "Ask Claude". Release (CI) builds never embed a path.
SOURCE_KEY=""
[[ -z "${GITHUB_ACTIONS:-}" ]] && SOURCE_KEY="
  <key>OffloadSourcePath</key><string>$PWD</string>"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SD Offload</string>
  <key>CFBundleDisplayName</key><string>SD Offload</string>
  <key>CFBundleIdentifier</key><string>io.github.turnerburchard.offload</string>
  <key>CFBundleExecutable</key><string>Offload</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>OffloadUpdateRepo</key><string>$REPO</string>$SOURCE_KEY
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>Reads SD cards and copies photos to your backup drives.</string>
</dict></plist>
PLIST
# Signing: $OFFLOAD_SIGN_IDENTITY = SHA-1 hash of a code-signing identity (a self-signed cert is fine, but
# codesign can't find an untrusted cert by name, so pass the hash). A stable certificate keeps macOS from
# re-asking for removable-volume access after updates, and lets the updater pin updates to that certificate.
# Locally, if ~/.config/offload-signing/{offload-signing.p12,p12-password.txt} exist, sign with that cert via a
# TEMPORARY keychain (same as CI); the user's keychain search list is always restored. Otherwise ad-hoc.
EXPECTED_LEAF=84cf117dee32c5c07c1d6ca4a0a32bb22fde4d1e
SIGN_ID=${OFFLOAD_SIGN_IDENTITY:-}
P12="$HOME/.config/offload-signing/offload-signing.p12"
P12PW="$HOME/.config/offload-signing/p12-password.txt"
if [[ -z "$SIGN_ID" && -z "${GITHUB_ACTIONS:-}" && -f "$P12" && -f "$P12PW" ]]; then
  TMPK="${TMPDIR:-/tmp}/offload-build-$$.keychain-db"
  KPW=$(uuidgen)
  SAVED=("${(@f)$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')}")
  restore_keychains() {
    security list-keychains -d user -s "${SAVED[@]}"
    security delete-keychain "$TMPK" 2>/dev/null || true
  }
  trap restore_keychains EXIT
  if security create-keychain -p "$KPW" "$TMPK" \
     && security unlock-keychain -p "$KPW" "$TMPK" \
     && security import "$P12" -k "$TMPK" -P "$(cat "$P12PW")" -T /usr/bin/codesign >/dev/null \
     && security set-key-partition-list -S apple-tool:,apple: -s -k "$KPW" "$TMPK" >/dev/null \
     && security list-keychains -d user -s "$TMPK" "${SAVED[@]}"; then
    SIGN_ID=$(security find-identity -p codesigning "$TMPK" | awk '/[0-9A-F]{40}/ {print $2; exit}')
  fi
  [[ -z "$SIGN_ID" ]] && echo "Couldn't use the local signing certificate; signing ad-hoc instead." >&2
fi
if [[ -n "$SIGN_ID" ]] && codesign --force --sign "$SIGN_ID" "$APP" 2>/dev/null; then
  DR=$(codesign -d -r- "$APP" 2>&1 | grep designated)
  echo "$DR"
  [[ "$DR" == *"certificate leaf = H\"$EXPECTED_LEAF\""* ]] || echo "Warning: signed with an unexpected certificate (installed copies won't accept it as an update)." >&2
else
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc"
fi
echo "Built $PWD/$APP (version $VERSION, build $BUILD_NUMBER, updates from $REPO)"
