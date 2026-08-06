#!/usr/bin/env bash
# Embed OpenUsageWidgetExtension.appex into a built OpenUsage.app and re-sign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPEX_SRC="${1:-$ROOT/macos/build/OpenUsageWidgetExtension.appex}"
APP_PATH="${2:-}"

if [[ -z "$APP_PATH" ]]; then
  # Prefer release bundle from tauri build.
  CANDIDATES=(
    "$ROOT/src-tauri/target/release/bundle/macos/OpenUsage.app"
    "$ROOT/src-tauri/target/debug/bundle/macos/OpenUsage.app"
  )
  for c in "${CANDIDATES[@]}"; do
    if [[ -d "$c" ]]; then
      APP_PATH="$c"
      break
    fi
  done
fi

if [[ ! -d "$APPEX_SRC" ]]; then
  echo "error: widget appex not found: $APPEX_SRC" >&2
  echo "Run: bun run widget:build" >&2
  exit 1
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "error: OpenUsage.app not found. Build the app first (bun tauri build)." >&2
  exit 1
fi

PLUGINS="$APP_PATH/Contents/PlugIns"
mkdir -p "$PLUGINS"
rm -rf "$PLUGINS/OpenUsageWidgetExtension.appex"
cp -R "$APPEX_SRC" "$PLUGINS/OpenUsageWidgetExtension.appex"

# Re-sign appex then host app so the embedded extension is trusted.
# Prefer SHA-1 hash over CN: keychain often has multiple certs with the same name
# (revoked/expired duplicates → codesign "ambiguous").
pick_codesign_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$CODESIGN_IDENTITY"
    return
  fi
  # "valid identities only" still lists some CSSMERR_*; skip those lines, take hash ($2).
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ && !/CSSMERR/ { print $2; exit }'
}

IDENTITY="$(pick_codesign_identity || true)"

if [[ -z "$IDENTITY" ]]; then
  echo "warn: no codesign identity; copied appex without signing" >&2
  echo "✓ Embedded (unsigned): $PLUGINS/OpenUsageWidgetExtension.appex"
  exit 0
fi

ENTITLEMENTS_APP="$ROOT/src-tauri/Entitlements.plist"
ENTITLEMENTS_WIDGET="$ROOT/macos/OpenUsageWidget/OpenUsageWidget.entitlements"

echo "codesign identity: $IDENTITY"

# Sign appex first (nested code), then host — do not put App Groups on the host
# unless a matching provisioning profile is embedded (otherwise PlugInKit hides the widget).
codesign --force --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS_WIDGET" \
  --options runtime \
  "$PLUGINS/OpenUsageWidgetExtension.appex"

codesign --force --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS_APP" \
  --options runtime \
  "$APP_PATH"

# Re-register so Notification Center / desktop widget gallery can see the extension.
if command -v pluginkit >/dev/null 2>&1; then
  pluginkit -a "$PLUGINS/OpenUsageWidgetExtension.appex" >/dev/null 2>&1 || true
  pluginkit -e use -i com.sunstory.openusage.widget >/dev/null 2>&1 || true
fi
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
  "$lsregister" -f "$APP_PATH" >/dev/null 2>&1 || true
fi

echo "✓ Embedded + signed with: $IDENTITY"
echo "  $PLUGINS/OpenUsageWidgetExtension.appex"
echo
echo "Install tip: copy THIS app to /Applications AFTER embed (not the pre-embed build):"
echo "  rm -rf /Applications/OpenUsage.app && cp -R \"$APP_PATH\" /Applications/"
echo "  open /Applications/OpenUsage.app"
echo "Then: desktop right-click → Edit Widgets → search OpenUsage"
