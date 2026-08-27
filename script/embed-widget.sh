#!/usr/bin/env bash
# Embed OpenUsageWidgetExtension.appex into a built OpenUsage.app and re-sign.
#
#   script/embed-widget.sh [APP_PATH]
#
# APP_PATH defaults to dist/OpenUsage.app (script/release.sh output).
#
# Signing identity via CODESIGN_IDENTITY:
#   "-" (default)  ad-hoc — reliable for local /Applications sideload. Apple
#                  Development + hardened runtime often fails at launch with
#                  RBSRequestErrorDomain Code=5 / NSPOSIXErrorDomain Code=163
#                  (AMFI rejects the revoked/untrusted dev cert outside Xcode).
#   <sha1|name>    real identity (Developer ID for distribution): nested appex
#                  first, then host, both with hardened runtime + timestamp.
#
# SKIP_HOST_RESIGN=1 leaves the host bundle untouched (used by release.sh, which
# signs the app itself with its iCloud entitlements right after embedding).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPEX_SRC="${WIDGET_APPEX:-$ROOT/macos/build/OpenUsageWidgetExtension.appex}"
APP_PATH="${1:-}"

if [[ -z "$APP_PATH" ]]; then
  if [[ -d "$ROOT/dist/OpenUsage.app" ]]; then
    APP_PATH="$ROOT/dist/OpenUsage.app"
  else
    echo "error: no app bundle given and $ROOT/dist/OpenUsage.app not found." >&2
    echo "Build it first: script/release.sh (or pass the .app path as \$1)." >&2
    exit 1
  fi
fi

if [[ ! -d "$APPEX_SRC" ]]; then
  echo "error: widget appex not found: $APPEX_SRC" >&2
  echo "Run: script/build-widget.sh" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: OpenUsage.app not found: $APP_PATH" >&2
  exit 1
fi

PLUGINS="$APP_PATH/Contents/PlugIns"
mkdir -p "$PLUGINS"
rm -rf "$PLUGINS/OpenUsageWidgetExtension.appex"
cp -R "$APPEX_SRC" "$PLUGINS/OpenUsageWidgetExtension.appex"

ENTITLEMENTS_WIDGET="$ROOT/macos/OpenUsageWidget/OpenUsageWidget.entitlements"
IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "adhoc" || "$IDENTITY" == "ad-hoc" ]]; then
  IDENTITY="-"
fi

echo "codesign identity: $IDENTITY"

sign_options=(--force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS_WIDGET")
if [[ "$IDENTITY" != "-" ]]; then
  sign_options+=(--options runtime --timestamp)
fi
codesign "${sign_options[@]}" \
  "$PLUGINS/OpenUsageWidgetExtension.appex"

if [[ "${SKIP_HOST_RESIGN:-0}" != "1" ]]; then
  host_options=(--force --sign "$IDENTITY")
  if [[ "$IDENTITY" != "-" ]]; then
    host_options+=(--options runtime --timestamp)
  fi
  codesign "${host_options[@]}" "$APP_PATH"
fi

# Deep verify (fail the script if broken) — only on the standalone path where we also re-signed the
# host. With SKIP_HOST_RESIGN=1 (release.sh), the host has not been signed yet; its own signing pass
# runs --verify --deep --strict right after we exit.
if [[ "${SKIP_HOST_RESIGN:-0}" != "1" ]]; then
  if ! codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    echo "error: codesign --verify failed for $APP_PATH" >&2
    codesign --verify --deep --strict --verbose=4 "$APP_PATH" 2>&1 || true
    exit 1
  fi
fi

if command -v pluginkit >/dev/null 2>&1; then
  pluginkit -a "$PLUGINS/OpenUsageWidgetExtension.appex" >/dev/null 2>&1 || true
  pluginkit -e use -i com.robinebers.openusage.widget >/dev/null 2>&1 || true
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
echo "Install tip (local dev): copy THIS app to /Applications AFTER embed:"
echo "  rm -rf /Applications/OpenUsage.app"
echo "  cp -R \"$APP_PATH\" /Applications/"
echo "  xattr -cr /Applications/OpenUsage.app"
echo "  open /Applications/OpenUsage.app"
echo "Then: desktop right-click → Edit Widgets → search OpenUsage"
