#!/usr/bin/env bash
# Builds "build/Quick Chat.app" from the SwiftPM executable and codesigns it.
#
# Environment overrides:
#   BUNDLE_ID          CFBundleIdentifier            (default: dev.shuaibird.quickchat)
#   VERSION            CFBundleShortVersionString    (default: latest git tag minus "v", else 0.0.0-dev)
#   BUILD_NUMBER       CFBundleVersion               (default: git commit count, else 1)
#   UNIVERSAL=1        build arm64 + x86_64 instead of the host architecture only
#   CODESIGN_IDENTITY  signing identity; "-" forces ad-hoc
#                      (default: first "Apple Development" identity, else ad-hoc)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Quick Chat"
EXECUTABLE="QuickChat" # SwiftPM product name
BUNDLE_ID="${BUNDLE_ID:-dev.shuaibird.quickchat}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
VERSION="${VERSION#v}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/${APP_NAME}.app"

SWIFT_FLAGS="-c release"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  SWIFT_FLAGS="${SWIFT_FLAGS} --arch arm64 --arch x86_64"
fi

echo "==> swift build ${SWIFT_FLAGS}"
swift build ${SWIFT_FLAGS}
BIN_DIR="$(swift build ${SWIFT_FLAGS} --show-bin-path)"

echo "==> Assembling ${APP} (${BUNDLE_ID} ${VERSION} (${BUILD_NUMBER}))"
rm -rf "${APP}" "build/Quick Chat for ChatGPT.app" # also drop the bundle built under the old name
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${EXECUTABLE}" "${APP}/Contents/MacOS/${EXECUTABLE}"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns" # regenerate with scripts/make-icon.sh

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>${APP_NAME} uses the microphone for ChatGPT voice input.</string>
  <key>NSCameraUsageDescription</key><string>${APP_NAME} uses the camera when you take a photo or share video in ChatGPT.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>${APP_NAME} saves files you download from ChatGPT to your Downloads folder.</string>
</dict>
</plist>
PLIST
plutil -lint -s "${APP}/Contents/Info.plist"

# Signing: a stable Apple Development identity keeps privacy grants (microphone, camera) across rebuilds;
# ad-hoc ("-") works everywhere but macOS sees every rebuild as a new app.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "${IDENTITY}" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
IDENTITY="${IDENTITY:--}"

# A secure timestamp needs the network and is only required for Developer ID (notarization).
TIMESTAMP="--timestamp=none"
case "${IDENTITY}" in "Developer ID Application"*) TIMESTAMP="--timestamp" ;; esac

echo "==> codesign (identity: ${IDENTITY})"
codesign --force --options runtime ${TIMESTAMP} \
  --entitlements scripts/QuickChat.entitlements --sign "${IDENTITY}" "${APP}"
codesign --verify --strict --verbose=1 "${APP}"
echo "==> Built ${APP}"
