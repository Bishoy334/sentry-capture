#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Sentry Capture"
BIN_NAME="SentryCapture"
APP_DIR="/Applications/${APP_NAME}.app"

OPT="-O"
RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast) OPT="-Onone"; shift ;;
        --run) RUN=true; shift ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

echo "Building ${APP_NAME}..."

swiftc \
    -framework Cocoa -framework ScreenCaptureKit -framework AVFoundation \
    -framework CoreMedia -framework CoreImage -framework Vision \
    -framework Carbon -framework SwiftUI -framework ServiceManagement \
    -framework UniformTypeIdentifiers -framework Accelerate \
    ${OPT} -o "${SCRIPT_DIR}/${BIN_NAME}" \
    "${SCRIPT_DIR}"/src/*.swift \
    "${SCRIPT_DIR}"/src/Annotator/*.swift

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${SCRIPT_DIR}/${BIN_NAME}" "${APP_DIR}/Contents/MacOS/${BIN_NAME}"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Contents/Info.plist"
rm "${SCRIPT_DIR}/${BIN_NAME}"

# TCC ties the Screen Recording grant to the code signature — ad-hoc signing
# changes identity every rebuild and silently kills the grant. Prefer a real
# Apple Development identity, then the self-signed "Sentry Capture Dev" cert.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/{print $2; exit}')
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Sentry Capture Dev/{print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "${APP_DIR}"

echo "Built: ${APP_DIR}"
if $RUN; then
    pkill -x "${BIN_NAME}" 2>/dev/null || true
    sleep 0.3
    open "${APP_DIR}"
fi
