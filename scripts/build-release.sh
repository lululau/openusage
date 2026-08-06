#!/bin/bash
set -e

cd "$(dirname "$0")/.."

# Load .env (handles values with spaces)
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

# Read key contents from file path
if [ -f "$TAURI_SIGNING_PRIVATE_KEY" ]; then
  export TAURI_SIGNING_PRIVATE_KEY="$(cat "$TAURI_SIGNING_PRIVATE_KEY")"
fi

# Clean previous bundle
rm -rf src-tauri/target/release/bundle

# Build WidgetKit extension (optional if xcodegen/Xcode unavailable)
if command -v xcodegen >/dev/null 2>&1; then
  echo "Building WidgetKit extension…"
  bun run widget:build || echo "warn: widget build failed; continuing without widget"
else
  echo "warn: xcodegen not found; skipping WidgetKit extension"
fi

# Build
bun tauri build "$@"

# Embed widget into .app and re-sign when present
if [[ -d macos/build/OpenUsageWidgetExtension.appex ]]; then
  echo "Embedding WidgetKit extension…"
  bun run widget:embed || echo "warn: widget embed failed"
fi

echo ""
echo "✓ Build complete! Output:"
ls -la src-tauri/target/release/bundle/dmg/*.dmg 2>/dev/null || ls -la src-tauri/target/release/bundle/macos/*.app
