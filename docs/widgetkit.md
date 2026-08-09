# macOS WidgetKit (OpenUsage rings)

## What it is

Native **WidgetKit** extension that shows enabled providers as circular gauges (battery-widget style):

- Center: plugin icon  
- Below ring: **one** value line — `%` for percent metrics, remaining/used amount for `count` / `dollars`  
- **Concentric multi-rings** when the snapshot includes `rings[]` (outer → inner):
  - **Cursor**: Total usage · Auto usage · API usage (all percent when present)
  - **Antigravity**: Gemini Flash · Claude  
- Other plugins: single ring from tray primary metric  

Data path: main Tauri app probes plugins → frontend builds snapshot → Rust writes App Group JSON + SVG icons → `WidgetCenter.reloadAllTimelines()`.

## Bundle IDs

| Component | ID |
|-----------|-----|
| App | `com.sunstory.openusage` |
| Widget extension | `com.sunstory.openusage.widget` |
| App Group | `group.com.sunstory.openusage` |

## Snapshot file

Primary path (sideload-safe Application Support):

```
~/Library/Application Support/com.sunstory.openusage/widget/usage-snapshot.json
~/Library/Application Support/com.sunstory.openusage/widget/icons/<pluginId>.svg
```

Optional mirror (real App Groups only):

```
~/Library/Group Containers/group.com.sunstory.openusage/usage-snapshot.json
```

> **Do not rely on Group Containers for sandboxed widgets without a provisioned App Group** — macOS returns “you don’t have permission” even with absolute-path temporary exceptions.

Schema (camelCase):

```json
{
  "version": 1,
  "updatedAt": "2026-08-06T00:00:00.000Z",
  "displayMode": "left",
  "items": [
    {
      "id": "cursor",
      "name": "Cursor",
      "iconFile": "icons/cursor.svg",
      "fraction": 0.58,
      "percentText": "58%",
      "ringColor": "#4CD964",
      "label": "Total usage",
      "rings": [
        { "label": "Total usage", "fraction": 0.58, "percentText": "58%", "ringColor": "#4CD964" },
        { "label": "Auto usage", "fraction": 0.30, "percentText": "30%", "ringColor": "#5AC8FA" },
        { "label": "API usage", "fraction": 0.72, "percentText": "72%", "ringColor": "#FF9F0A" }
      ]
    }
  ]
}
```

- `rings` optional; outer → inner. Widget falls back to top-level `fraction` when missing/single.  
- Primary under-ring text is the first multi-ring layer (Cursor → Total usage; Antigravity → Gemini Flash).

## Build & install (order matters)

```bash
# widget:build — unsigned compile (no DEVELOPMENT_TEAM needed)
# widget:embed — defaults to ad-hoc re-sign (local launch). Do NOT use Apple
#   Development here if you hit launchd error 163 / “malware” quarantine.

bun run widget:build
bun tauri build
bun run widget:embed

# ONLY AFTER embed — copy the release bundle (not a mid-build copy):
rm -rf /Applications/OpenUsage.app
cp -R src-tauri/target/release/bundle/macos/OpenUsage.app /Applications/
xattr -cr /Applications/OpenUsage.app
open /Applications/OpenUsage.app

# Optional:
#   WIDGET_CODE_SIGN=auto DEVELOPMENT_TEAM=… bun run widget:build
#   CODESIGN_IDENTITY=<sha1> bun run widget:embed   # real cert (may fail Gatekeeper)
```

Then: **desktop right-click → Edit Widgets** (or Notification Center → Edit) → search **OpenUsage**.

`scripts/build-release.sh` runs widget build/embed when `xcodegen` is available.

Requirements: Xcode, `xcodegen` (`brew install xcodegen`), Apple Development cert for embed re-sign.

### Why the widget might not appear

| Mistake | Symptom |
|--------|---------|
| Copied to `/Applications` **before** `widget:embed` | No `Contents/PlugIns/*.appex` → zero widgets |
| Host signed with `com.apple.security.application-groups` **without** a matching provisioning profile | `codesign --verify` OK, but `pluginkit` never lists the extension |
| Searching gallery before opening the installed app once | LaunchServices not registered |

**Host entitlements:** keep `src-tauri/Entitlements.plist` free of App Groups for local/dev signing. Main app writes snapshot under `~/Library/Group Containers/group.com.sunstory.openusage/`.

**Widget entitlements (local sideload):**

| Entitlement | Why |
|-------------|-----|
| `app-sandbox` = true | **Required** for PlugInKit / “Edit Widgets” to list the extension. Without it, widget vanishes from search. |
| `application-groups` | Preferred shared container when profile includes the group |
| `temporary-exception.files.absolute-path.read-only` → `/Users/` | Free-team profiles omit App Groups. Sandbox **container home** makes home-relative paths wrong; absolute `/Users/` lets widget read real `~/Library/Group Containers/...` snapshot |

For MAS: register App Group on both App IDs, drop the temporary-exception, keep sandbox.

### Tap widget to re-read disk (no remote probe)

- Whole-card `Button` + `ReloadOpenUsageWidgetIntent` (`AppIntents`)
- Intent calls `WidgetCenter.reloadTimelines` only — **does not** open the main app or hit remote usage APIs
- Fresh usage numbers still come from the main app’s normal auto-update / manual refresh writing the snapshot file

### Empty widget: “Open OpenUsage to refresh usage”

This string means **snapshot load returned 0 items**, not “app never opened”.

| Check | Command / meaning |
|-------|-------------------|
| Snapshot exists? | `cat ~/Library/Group\ Containers/group.com.sunstory.openusage/usage-snapshot.json` — should list 4 `items` |
| New binary installed? | That empty message only exists in post-17:20 builds; if you see it, `/Applications` **is** the new UI |
| Real cause (local) | Sandboxed widget + profile without App Groups → cannot read JSON |

Fix: rebuild widget (sandbox off for dev), `widget:embed`, re-copy to `/Applications`, open app once, **remove and re-add** the widget (or wait for timeline reload).

## Add widget on macOS

1. Install signed OpenUsage.app  
2. Open **Notification Center** or desktop → **Edit Widgets**  
3. Search **OpenUsage** → add Small / Medium / Large  

## Dev notes

- `tauri dev` writes snapshots when the command works, but WidgetKit only loads extensions from installed/signed app bundles.  
- Without App Group entitlement/signing, container URL may be nil; Rust falls back to `~/Library/Group Containers/group.com.sunstory.openusage/` for debugging.  
- Primary metric selection matches tray: `primaryCandidates` / plugin order / enabled list.
