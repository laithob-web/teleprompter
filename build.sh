#!/bin/bash
# Builds Teleprompter.app without Xcode — SwiftPM plus a hand-assembled bundle.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Teleprompter"
BUNDLE_ID="com.laith.teleprompter"
BUILD_DIR=".build/${CONFIG}"
APP="build/${APP_NAME}.app"

echo "==> Compiling (${CONFIG})"
swift build -c "${CONFIG}"

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Ad-hoc sign with a FIXED identifier. macOS keys TCC permission grants to the
# bundle identity, so pinning it here is what stops the mic and audio-capture
# prompts from reappearing after every rebuild.
echo "==> Signing (ad-hoc, identifier ${BUNDLE_ID})"
codesign --force --sign - \
  --identifier "${BUNDLE_ID}" \
  --entitlements Resources/Teleprompter.entitlements \
  --options runtime \
  "${APP}" 2>&1 | sed 's/^/    /'

codesign --verify --verbose=1 "${APP}" 2>&1 | sed 's/^/    /'

echo
echo "Built ${APP}"
echo "Run with:  open ${APP}"
echo "Look for the text icon in your menu bar — there is no Dock icon by design."
