#!/usr/bin/env bash
# Build the macOS WidgetKit extension (.appex) via XcodeGen + xcodebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS_DIR="$ROOT/macos"
DERIVED="$MACOS_DIR/build/DerivedData"
OUT_DIR="$MACOS_DIR/build"

cd "$MACOS_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen required (brew install xcodegen)" >&2
  exit 1
fi

# Avoid broken XCODE_XCCONFIG_FILE pointing at a directory (common agent/env pollution).
if [[ -n "${XCODE_XCCONFIG_FILE:-}" && ! -f "${XCODE_XCCONFIG_FILE}" ]]; then
  echo "warn: unsetting invalid XCODE_XCCONFIG_FILE=$XCODE_XCCONFIG_FILE"
  unset XCODE_XCCONFIG_FILE
fi

xcodegen generate --spec project.yml

SIGN_ARGS=(
  CODE_SIGN_STYLE=Automatic
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development}"
)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "Using DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
  SIGN_ARGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

set +e
xcodebuild \
  -project OpenUsageWidget.xcodeproj \
  -scheme OpenUsageWidgetExtension \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  -allowProvisioningUpdates \
  ONLY_ACTIVE_ARCH=YES \
  BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
  "${SIGN_ARGS[@]}" \
  build
STATUS=$?
set -e

# Local fallback: ad-hoc sign (App Group / Widget install may not work until properly signed).
if [[ $STATUS -ne 0 ]]; then
  echo "warn: automatic signing failed (exit $STATUS); retrying ad-hoc (CODE_SIGN_IDENTITY=-)"
  xcodebuild \
    -project OpenUsageWidget.xcodeproj \
    -scheme OpenUsageWidgetExtension \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    ONLY_ACTIVE_ARCH=YES \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    build
fi

APPEX="$(find "$DERIVED/Build/Products" -type d -name 'OpenUsageWidgetExtension.appex' | head -n 1)"
if [[ -z "$APPEX" || ! -d "$APPEX" ]]; then
  echo "error: OpenUsageWidgetExtension.appex not found under $DERIVED" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/OpenUsageWidgetExtension.appex"
cp -R "$APPEX" "$OUT_DIR/OpenUsageWidgetExtension.appex"

echo "✓ Widget built: $OUT_DIR/OpenUsageWidgetExtension.appex"
