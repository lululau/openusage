#!/usr/bin/env bash
# Build the macOS WidgetKit extension (.appex) via XcodeGen + xcodebuild.
#
# Default: compile with CODE_SIGNING_ALLOWED=NO (no DEVELOPMENT_TEAM / Xcode
# account required). `bun run widget:embed` re-signs the .appex into the host
# app with a local Apple Development identity.
#
# Optional automatic signing (needs Xcode signed-in to the team):
#   DEVELOPMENT_TEAM=XXXXXXXXXX WIDGET_CODE_SIGN=auto bun run widget:build
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

# First non-revoked Apple Development identity hash (for logging / auto team).
pick_dev_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ && !/CSSMERR/ { print $2; exit }'
}

# Team ID = OU field of the leaf cert (e.g. 9ZSG4N8477). Not the (XXXXXXXX) in CN.
detect_development_team() {
  local hash pem
  hash="$(pick_dev_identity || true)"
  [[ -n "$hash" ]] || return 1
  pem="$(
    security find-certificate -a -Z -p 2>/dev/null | awk -v h="$hash" '
      BEGIN { th = toupper(h); gsub(/:/, "", th) }
      /SHA-1 hash:/ {
        cur = toupper($3)
        gsub(/:/, "", cur)
        grab = (cur == th)
      }
      grab { print }
      /END CERTIFICATE/ && grab { exit }
    '
  )"
  [[ -n "$pem" ]] || return 1
  # subject=... OU=TEAMID, ...
  printf '%s\n' "$pem" \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU=\([^,/=]*\).*/\1/p' \
    | head -n 1
}

build_unsigned() {
  echo "Building widget (CODE_SIGNING_ALLOWED=NO) — embed will re-sign later"
  xcodebuild \
    -project OpenUsageWidget.xcodeproj \
    -scheme OpenUsageWidgetExtension \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    build
}

build_auto_signed() {
  local team="$1"
  echo "Building widget with automatic signing (DEVELOPMENT_TEAM=$team)"
  xcodebuild \
    -project OpenUsageWidget.xcodeproj \
    -scheme OpenUsageWidgetExtension \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' \
    -allowProvisioningUpdates \
    ONLY_ACTIVE_ARCH=YES \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development}" \
    DEVELOPMENT_TEAM="$team" \
    build
}

MODE="${WIDGET_CODE_SIGN:-unsigned}"

if [[ "$MODE" == "auto" ]]; then
  TEAM="${DEVELOPMENT_TEAM:-}"
  if [[ -z "$TEAM" ]]; then
    TEAM="$(detect_development_team || true)"
    if [[ -n "$TEAM" ]]; then
      echo "Detected DEVELOPMENT_TEAM=$TEAM from Apple Development certificate"
    fi
  fi
  if [[ -z "$TEAM" ]]; then
    echo "warn: WIDGET_CODE_SIGN=auto but no DEVELOPMENT_TEAM; falling back to unsigned" >&2
    build_unsigned
  else
    set +e
    build_auto_signed "$TEAM"
    STATUS=$?
    set -e
    if [[ $STATUS -ne 0 ]]; then
      echo "warn: automatic signing failed (exit $STATUS); falling back to unsigned" >&2
      echo "hint: Xcode → Settings → Accounts must include team $TEAM, or use default unsigned build" >&2
      build_unsigned
    fi
  fi
else
  # Default path: no Xcode team / provisioning profile required.
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "note: DEVELOPMENT_TEAM is set but ignored (WIDGET_CODE_SIGN=unsigned)."
    echo "      Use WIDGET_CODE_SIGN=auto to enable automatic signing."
  fi
  build_unsigned
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
echo "  Next: bun tauri build && bun run widget:embed"
