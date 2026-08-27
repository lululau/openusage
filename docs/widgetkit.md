# macOS WidgetKit (OpenUsage rings)

## What it is

A native **WidgetKit** extension that shows enabled providers as circular gauges (battery-widget style):

- Center: provider icon
- Below the ring: **one** value line — `%` for percent metrics, remaining/used amount for `count` / `dollars`
- **Concentric multi-rings** where configured (outer → inner):
  - **Cursor**: Total usage · Auto usage · API usage
  - **Antigravity**: Session + Claude (default 5h face); tap toggles to Weekly + Claude Weekly
- Every other provider: single ring from its menu-bar pinned metric (matching the tray), falling back to its first bounded metric

Sizes: Small shows 2 cards, Medium 4, Large 8.

## Data flow

The app writes a snapshot file after every data change and asks WidgetKit to reload:

1. Providers refresh into `WidgetDataStore` (the same rendered snapshots every surface reads).
2. `WidgetSnapshotBuilder` maps enabled providers, in dashboard order, onto ring cards.
3. `WidgetSnapshotWriter` copies each provider's SVG icon, writes the JSON below, mirrors it into Group Containers when an App Group exists, and calls `WidgetCenter.reloadAllTimelines()`.
4. The extension reads the snapshot from disk when its timeline rebuilds; tapping the widget only toggles Antigravity's 5h/weekly face and re-reads the file — it never probes remote APIs.

Files involved:

| Piece | Path |
|---|---|
| Host builder | `Sources/OpenUsage/Services/WidgetSnapshotBuilder.swift` |
| Host writer | `Sources/OpenUsage/Services/WidgetSnapshotWriter.swift` |
| Extension | `macos/OpenUsageWidget/*.swift` |
| Extension project | `macos/project.yml` (XcodeGen) |
| Build / embed | `script/build-widget.sh`, `script/embed-widget.sh` |

## Bundle IDs

| Component | ID |
|-----------|-----|
| App | `com.robinebers.openusage` |
| Widget extension | `com.robinebers.openusage.widget` |
| App Group | `group.com.robinebers.openusage` |

## Snapshot file

Primary path (sideload-safe Application Support):

```
~/Library/Application Support/com.robinebers.openusage/widget/usage-snapshot.json
~/Library/Application Support/com.robinebers.openusage/widget/icons/<providerId>.svg
```

Optional mirror (real App Groups only):

```
~/Library/Group Containers/group.com.robinebers.openusage/usage-snapshot.json
```

> Do not rely on Group Containers for sandboxed widgets without a provisioned App Group — macOS returns "you don't have permission" even with absolute-path temporary exceptions.

Schema (camelCase):

```json
{
  "version": 1,
  "updatedAt": "2026-08-06T00:00:00.000Z",
  "displayMode": "remaining",
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

- `rings` optional, outer → inner; the widget falls back to top-level `fraction` when missing or single.
- With multi-rings, the value under the card comes from the outermost layer (Cursor → Total usage; Antigravity → Session / Weekly depending on the tapped period).
- A provider with no bounded data yet renders as a card with "—" rather than disappearing.

## Build & install

```bash
# widget:build — unsigned compile (no DEVELOPMENT_TEAM needed)
script/build-widget.sh

# Build the host app DMG — release.sh builds + embeds + signs the extension
# automatically when xcodegen is installed (skips with a warning otherwise;
# set WIDGET_REQUIRED=1 to make that a hard error).
script/release.sh

# Local dev: embed the .appex into an existing dist/OpenUsage.app and ad-hoc sign
CODESIGN_IDENTITY=- script/embed-widget.sh

rm -rf /Applications/OpenUsage.app
cp -R dist/OpenUsage.app /Applications/
xattr -cr /Applications/OpenUsage.app
open /Applications/OpenUsage.app
```

Requirements: Xcode, `xcodegen` (`brew install xcodegen`). For distribution releases the Developer ID identity signs the extension (hardened runtime), same as Sparkle and the CLI.

Then: desktop right-click → **Edit Widgets** → search **OpenUsage**.

### Signing notes

| Entitlement (widget) | Why |
|-------------|-----|
| `app-sandbox` = true | Required for PlugInKit to list the extension in "Edit Widgets". |
| `application-groups` | Preferred shared container when a profile includes the group. |
| `temporary-exception.files.absolute-path.read-only` → `/Users/` | Free/dev profiles omit App Groups, and sandboxed extensions get a *container* home so home-relative paths miss the real snapshot. Absolute `/Users/` read access lets the widget read the host-written file. Use real App Groups only (drop the exception) for a Mac App Store build. |

### Why the widget might not appear

| Mistake | Symptom |
|--------|---------|
| App copied to `/Applications` before `embed-widget.sh` ran | No `Contents/PlugIns/*.appex` → zero widgets |
| Searching the gallery before opening the installed app once | LaunchServices not registered yet |
| Snapshot load returns 0 items | Widget reads "Open OpenUsage to refresh usage"; check the JSON paths above exist |

Removing and re-adding the widget after an update forces a fresh timeline.
