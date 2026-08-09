#!/usr/bin/env bash
# Embed OpenUsageWidgetExtension.appex into a built OpenUsage.app and re-sign.
#
# Default identity: ad-hoc (`-`).
# On several machines Apple Development + hardened runtime fails at launch with:
#   RBSRequestErrorDomain Code=5 / NSPOSIXErrorDomain Code=163
# (AMFI / Gatekeeper rejects the signature; often CSSMERR_TP_CERT_REVOKED or
#  untrusted Development cert for non-Xcode launches). Ad-hoc launches fine
# for local /Applications sideload. Use Developer ID + notarize for distribution.
#
# Override:
#   CODESIGN_IDENTITY=-              # ad-hoc (default)
#   CODESIGN_IDENTITY=<sha1 hash>    # specific cert
#   CODESIGN_IDENTITY="Apple Development"  # by name (fragile if duplicates)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPEX_SRC="${1:-$ROOT/macos/build/OpenUsageWidgetExtension.appex}"
APP_PATH="${2:-}"

if [[ -z "$APP_PATH" ]]; then
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

# True if leaf cert for identity hash passes security verify-cert (codeSign).
identity_cert_ok() {
  local hash="$1" pem
  [[ "$hash" == "-" || "$hash" == "adhoc" ]] && return 0
  # Only check hex hashes; names can't be OCSP-checked easily.
  [[ "$hash" =~ ^[0-9A-Fa-f]{40}$ ]] || return 0
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
  printf '%s\n' "$pem" | security verify-cert -p codeSign 2>/dev/null
}

pick_codesign_identity() {
  # Explicit override wins (including "-"/adhoc).
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$CODESIGN_IDENTITY"
    return
  fi
  # Default: ad-hoc — reliable local launch (error 163 workaround).
  printf '%s\n' "-"
}

IDENTITY="$(pick_codesign_identity)"
# Normalize aliases
if [[ "$IDENTITY" == "adhoc" || "$IDENTITY" == "ad-hoc" ]]; then
  IDENTITY="-"
fi

if [[ "$IDENTITY" != "-" ]]; then
  if ! identity_cert_ok "$IDENTITY"; then
    echo "warn: identity $IDENTITY fails certificate verify (revoked/untrusted); falling back to ad-hoc (-)" >&2
    IDENTITY="-"
  fi
fi

ENTITLEMENTS_APP="$ROOT/src-tauri/Entitlements.plist"
ENTITLEMENTS_WIDGET="$ROOT/macos/OpenUsageWidget/OpenUsageWidget.entitlements"

echo "codesign identity: $IDENTITY"

if [[ "$IDENTITY" == "-" ]]; then
  # Ad-hoc: do NOT use --options runtime (can still launch; matches local sideload).
  codesign --force --sign - \
    --entitlements "$ENTITLEMENTS_WIDGET" \
    "$PLUGINS/OpenUsageWidgetExtension.appex"

  codesign --force --sign - \
    --entitlements "$ENTITLEMENTS_APP" \
    "$APP_PATH"
else
  # Real identity: nested first, then host; hardened runtime for distribution-like builds.
  codesign --force --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS_WIDGET" \
    --options runtime \
    "$PLUGINS/OpenUsageWidgetExtension.appex"

  codesign --force --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS_APP" \
    --options runtime \
    "$APP_PATH"
fi

# Deep verify (fail the script if broken).
if ! codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
  echo "error: codesign --verify failed for $APP_PATH" >&2
  codesign --verify --deep --strict --verbose=4 "$APP_PATH" 2>&1 || true
  exit 1
fi

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
if [[ "$IDENTITY" == "-" ]]; then
  echo "  (ad-hoc: OK for local /Applications; not for distribution/notarize)"
fi
echo
echo "Install tip: copy THIS app to /Applications AFTER embed:"
echo "  rm -rf /Applications/OpenUsage.app"
echo "  cp -R \"$APP_PATH\" /Applications/"
echo "  xattr -cr /Applications/OpenUsage.app"
echo "  open /Applications/OpenUsage.app"
echo "Then: desktop right-click → Edit Widgets → search OpenUsage"
