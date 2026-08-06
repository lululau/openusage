import type { PluginMeta, PluginOutput, ProgressFormat } from "@/lib/plugin-types"
import type { DisplayMode, PluginSettings } from "@/lib/settings"
import { DEFAULT_DISPLAY_MODE } from "@/lib/settings"
import { clamp01, formatCountNumber, formatFixedPrecisionNumber } from "@/lib/utils"

export const WIDGET_SNAPSHOT_VERSION = 1 as const
/** Medium banner shows 4; large can use up to 8. Keep snapshot at 8. */
export const WIDGET_MAX_ITEMS = 8
/** Medium / 横幅 widget visible slots. */
export const WIDGET_MEDIUM_VISIBLE = 4

type PluginStateLike = {
  data: PluginOutput | null
  loading: boolean
  error: string | null
}

type ProgressLine = Extract<
  PluginOutput["lines"][number],
  { type: "progress"; label: string; used: number; limit: number; format: ProgressFormat }
>

function isProgressLine(line: PluginOutput["lines"][number]): line is ProgressLine {
  return line.type === "progress"
}

/** One ring in the macOS WidgetKit card. */
export type WidgetRingItem = {
  id: string
  name: string
  /** data:image/svg+xml;base64,... from plugin meta / probe */
  iconDataUrl: string
  /** 0..1 for ring arc; omit when unknown */
  fraction?: number
  /**
   * Single value under the ring (battery-widget style — one line only):
   * - percent metrics → "74%"
   * - count metrics → remaining/used amount ("499")
   * - dollars → "$12.50"
   */
  percentText: string
  /** @deprecated unused in widget UI; kept optional for older snapshots */
  detailText?: string
  /** Optional ring stroke (CSS/hex). Widget falls back to system green. */
  ringColor?: string
  /** Primary metric label, e.g. "Requests" */
  label?: string
}

export type WidgetSnapshot = {
  version: typeof WIDGET_SNAPSHOT_VERSION
  updatedAt: string
  displayMode: DisplayMode
  items: WidgetRingItem[]
}

/** Primary label under the ring — percent, or absolute remaining/used for count/dollars. */
function formatPrimaryText(format: ProgressFormat, shownAmount: number, fraction: number): string {
  if (format.kind === "count") {
    return formatCountNumber(shownAmount)
  }
  if (format.kind === "dollars") {
    return `$${formatFixedPrecisionNumber(shownAmount)}`
  }
  return `${Math.round(fraction * 100)}%`
}

function pickPrimaryLine(
  meta: PluginMeta,
  data: PluginOutput | null
): ProgressLine | null {
  if (!data || !meta.primaryCandidates?.length) return null
  const primaryLabel = meta.primaryCandidates.find((label) =>
    data.lines.some((line) => isProgressLine(line) && line.label === label)
  )
  if (!primaryLabel) return null
  return (
    data.lines.find(
      (line): line is ProgressLine => isProgressLine(line) && line.label === primaryLabel
    ) ?? null
  )
}

/**
 * Build WidgetKit snapshot items from the same primary-progress rules as the tray.
 * One value line under each ring: % for percent metrics, remaining count/$ for others.
 */
export function buildWidgetSnapshot(args: {
  pluginsMeta: PluginMeta[]
  pluginSettings: PluginSettings | null
  pluginStates: Record<string, PluginStateLike | undefined>
  displayMode?: DisplayMode
  maxItems?: number
  now?: Date
}): WidgetSnapshot {
  const {
    pluginsMeta,
    pluginSettings,
    pluginStates,
    displayMode = DEFAULT_DISPLAY_MODE,
    maxItems = WIDGET_MAX_ITEMS,
    now = new Date(),
  } = args

  const items: WidgetRingItem[] = []
  if (!pluginSettings) {
    return {
      version: WIDGET_SNAPSHOT_VERSION,
      updatedAt: now.toISOString(),
      displayMode,
      items,
    }
  }

  const metaById = new Map(pluginsMeta.map((p) => [p.id, p]))
  const disabled = new Set(pluginSettings.disabled)

  for (const id of pluginSettings.order) {
    if (disabled.has(id)) continue
    const meta = metaById.get(id)
    if (!meta) continue
    if (!meta.primaryCandidates || meta.primaryCandidates.length === 0) continue

    const state = pluginStates[id]
    const data = state?.data ?? null
    const primary = pickPrimaryLine(meta, data)

    let fraction: number | undefined
    let percentText = "—"
    let label: string | undefined
    let ringColor: string | undefined

    if (primary && primary.limit > 0) {
      const shownAmount =
        displayMode === "used" ? primary.used : Math.max(0, primary.limit - primary.used)
      fraction = clamp01(shownAmount / primary.limit)
      percentText = formatPrimaryText(primary.format, shownAmount, fraction)
      label = primary.label
      // Prefer metric color only. Plugin brandColor is often pure black/white (logo),
      // which reads poorly as a ring stroke on both light and dark widgets.
      ringColor = primary.color
    }

    const iconDataUrl = data?.iconUrl || meta.iconUrl || ""

    items.push({
      id,
      name: meta.name,
      iconDataUrl,
      fraction,
      percentText,
      label,
      ringColor,
    })

    if (items.length >= maxItems) break
  }

  return {
    version: WIDGET_SNAPSHOT_VERSION,
    updatedAt: now.toISOString(),
    displayMode,
    items,
  }
}
