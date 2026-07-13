#!/bin/bash
# Builds ReclaimKit/reclaim-cli/ReclaimApp in release mode, assembles Reclaim.app, signs it,
# and installs + (re)launches it from /Applications. Same shape as gokulmc/membar's build.sh
# (see docs/IMPLEMENTATION.md, "build.sh contract").
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Reclaim"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_DIR="/Applications"
SIGN_IDENTITY="ReclaimLocalSign"

echo "==> Building release binaries"
swift build -c release

echo "==> Assembling app bundle"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Library/LaunchAgents"

cp "${BUILD_DIR}/ReclaimApp" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${BUILD_DIR}/reclaim-cli" "${APP_BUNDLE}/Contents/MacOS/reclaim-cli"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
else
    echo "    warning: Resources/AppIcon.icns not found — run 'swift scripts/render-icon.swift' to generate it."
fi

echo "==> Installing weekly LaunchAgent plist (M4 scheduling, off by default)"
# The plist ships as a template with a placeholder for the CLI path, since the LaunchAgent
# runs the bundled reclaim-cli directly (no PATH lookup) — substitute in the path it will
# actually live at once installed.
CLI_INSTALLED_PATH="${INSTALL_DIR}/${APP_BUNDLE}/Contents/MacOS/reclaim-cli"
sed "s#__RECLAIM_CLI_PATH__#${CLI_INSTALLED_PATH}#" \
    "Resources/com.gokul.reclaim.agent.plist" \
    > "${APP_BUNDLE}/Contents/Library/LaunchAgents/com.gokul.reclaim.agent.plist"

if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    echo "==> Code signing (${SIGN_IDENTITY})"
    SIGN_ARG="${SIGN_IDENTITY}"
else
    echo "==> Code signing (ad-hoc — ${SIGN_IDENTITY} not found in keychain)"
    echo "    Tip: run ./setup-signing.sh once so macOS doesn't reset your"
    echo "    grants on every rebuild."
    SIGN_ARG="-"
fi

# Sign the CLI binary on its own first (it's a peer executable under Contents/MacOS, not a
# nested bundle/framework, so the app's own --deep sign below won't reach it), then sign the
# app bundle as a whole.
codesign --force --sign "${SIGN_ARG}" "${APP_BUNDLE}/Contents/MacOS/reclaim-cli"
codesign --force --deep --sign "${SIGN_ARG}" "${APP_BUNDLE}"

echo "==> Installing to ${INSTALL_DIR}"
if [ -d "${INSTALL_DIR}/${APP_BUNDLE}" ]; then
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    sleep 1
    rm -rf "${INSTALL_DIR}/${APP_BUNDLE}"
fi
cp -R "${APP_BUNDLE}" "${INSTALL_DIR}/"

echo "==> Launching"
open "${INSTALL_DIR}/${APP_BUNDLE}"

echo "Done. Look for the drive icon + free-space text in the menu bar."
