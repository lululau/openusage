import { useEffect, useRef } from "react"
import { invoke } from "@tauri-apps/api/core"
import type { PluginMeta } from "@/lib/plugin-types"
import type { DisplayMode, PluginSettings } from "@/lib/settings"
import { buildWidgetSnapshot } from "@/lib/widget-snapshot"
import type { PluginState } from "@/hooks/app/types"

const WIDGET_SNAPSHOT_DEBOUNCE_MS = 600

type UseWidgetSnapshotArgs = {
  pluginsMeta: PluginMeta[]
  pluginSettings: PluginSettings | null
  pluginStates: Record<string, PluginState>
  displayMode: DisplayMode
}

/**
 * Debounced push of usage snapshot to the macOS WidgetKit extension
 * via App Group shared container (Rust command).
 */
export function useWidgetSnapshot({
  pluginsMeta,
  pluginSettings,
  pluginStates,
  displayMode,
}: UseWidgetSnapshotArgs) {
  const timerRef = useRef<number | null>(null)
  const latestRef = useRef({ pluginsMeta, pluginSettings, pluginStates, displayMode })
  latestRef.current = { pluginsMeta, pluginSettings, pluginStates, displayMode }

  useEffect(() => {
    if (timerRef.current != null) {
      window.clearTimeout(timerRef.current)
    }

    timerRef.current = window.setTimeout(() => {
      timerRef.current = null
      const { pluginsMeta: meta, pluginSettings: settings, pluginStates: states, displayMode: mode } =
        latestRef.current

      // Only macOS host implements the command; ignore failures on other platforms / unsigned dev.
      if (!settings) return

      const snapshot = buildWidgetSnapshot({
        pluginsMeta: meta,
        pluginSettings: settings,
        pluginStates: states,
        displayMode: mode,
      })

      void invoke("write_widget_snapshot", { snapshot }).catch((err) => {
        console.debug("write_widget_snapshot skipped/failed:", err)
      })
    }, WIDGET_SNAPSHOT_DEBOUNCE_MS)

    return () => {
      if (timerRef.current != null) {
        window.clearTimeout(timerRef.current)
        timerRef.current = null
      }
    }
  }, [pluginsMeta, pluginSettings, pluginStates, displayMode])
}
