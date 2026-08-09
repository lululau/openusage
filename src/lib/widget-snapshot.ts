import type { PluginMeta, PluginOutput, ProgressFormat } from "@/lib/plugin-types"
import type { DisplayMode, PluginSettings } from "@/lib/settings"
import { DEFAULT_DISPLAY_MODE } from "@/lib/settings"
import { clamp01, formatCountNumber, formatFixedPrecisionNumber } from "@/lib/utils"

export const WIDGET_SNAPSHOT_VERSION = 1 as const
/** Medium banner shows 4; large can use up to 8. Keep snapshot at 8. */
export const WIDGET_MAX_ITEMS = 8
/** Medium / 横幅 widget visible slots. */
export const WIDGET_MEDIUM_VISIBLE = 4

/**
 * Concentric multi-ring metric labels per plugin (outer → inner).
 * Only progress lines that exist at probe time are included.
 */
export const WIDGET_MULTI_RING_LABELS: Readonly<Record<string, readonly string[]>> = {
  // Total (included) + Auto/Composer pool + API/$ pool
  cursor: ["Total usage", "Auto usage", "API usage"],
  // Antigravity first-party Gemini Flash + bundled Claude pool
  antigravity: ["Gemini Flash", "Claude"],
}

/** Fallback stroke colors when a metric has no `color` (outer → inner). */
export const WIDGET_MULTI_RING_COLORS = ["#4CD964", "#5AC8FA", "#FF9F0A"] as const

type PluginStateLike = {
  data: PluginOutput | null
  loading: boolean
  error: string | null
}

type ProgressLine = Extract<
  PluginOutput["lines"][number],
  { type: "progress"; label: string; used: number; limit: number; format: ProgressFormat }
>

/** One concentric ring layer (outer → inner in array order). */
export type WidgetRingLayer = {
  label: string
  /** 0..1 arc fill (respects displayMode left/used). */
  fraction: number
  /** Value text for this layer (usually "NN%"). */
  percentText: string
  ringColor?: string
}

function isProgressLine(line: PluginOutput["lines"][number]): line is ProgressLine {
  return line.type === "progress"
}

/** One provider card in the macOS WidgetKit layout. */
export type WidgetRingItem = {
  id: string
  name: string
  /** data:image/svg+xml;base64,... from plugin meta / probe */
  iconDataUrl: string
  /** 0..1 for primary/outer ring; omit when unknown */
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
  /** Primary metric label, e.g. "Total usage" */
  label?: string
  /**
   * Concentric rings (outer → inner). When present and length ≥ 2, the widget
   * draws multiple strokes. Single-layer / missing → use top-level fraction.
   */
  rings?: WidgetRingLayer[]
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

function progressLayer(
  line: ProgressLine,
  displayMode: DisplayMode,
  fallbackColor?: string
): WidgetRingLayer | null {
  if (!(line.limit > 0)) return null
  const shownAmount =
    displayMode === "used" ? line.used : Math.max(0, line.limit - line.used)
  const fraction = clamp01(shownAmount / line.limit)
  return {
    label: line.label,
    fraction,
    percentText: formatPrimaryText(line.format, shownAmount, fraction),
    ringColor: line.color || fallbackColor,
  }
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

function findProgressByLabel(data: PluginOutput | null, label: string): ProgressLine | null {
  if (!data) return null
  return (
    data.lines.find(
      (line): line is ProgressLine => isProgressLine(line) && line.label === label
    ) ?? null
  )
}

/** Collect configured multi-ring layers that exist in probe data. */
function buildMultiRings(
  pluginId: string,
  data: PluginOutput | null,
  displayMode: DisplayMode
): WidgetRingLayer[] {
  const labels = WIDGET_MULTI_RING_LABELS[pluginId]
  if (!labels?.length || !data) return []

  const rings: WidgetRingLayer[] = []
  for (let i = 0; i < labels.length; i++) {
    const label = labels[i]!
    const line = findProgressByLabel(data, label)
    if (!line) continue
    const layer = progressLayer(line, displayMode, WIDGET_MULTI_RING_COLORS[i])
    if (layer) rings.push(layer)
  }
  return rings
}

/**
 * Build WidgetKit snapshot items from the same primary-progress rules as the tray.
 * One value line under each ring: % for percent metrics, remaining count/$ for others.
 * Cursor / Antigravity may emit multiple concentric `rings` when those metrics exist.
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
    const multiRings = buildMultiRings(id, data, displayMode)
    const primary = pickPrimaryLine(meta, data)

    let fraction: number | undefined
    let percentText = "—"
    let label: string | undefined
    let ringColor: string | undefined
    let rings: WidgetRingLayer[] | undefined

    if (multiRings.length >= 1) {
      // Prefer multi-ring when any configured metric is present (Cursor Total / Auto / API).
      rings = multiRings
      const head = multiRings[0]!
      fraction = head.fraction
      percentText = head.percentText
      label = head.label
      ringColor = head.ringColor
    } else if (primary && primary.limit > 0) {
      const layer = progressLayer(primary, displayMode)
      if (layer) {
        fraction = layer.fraction
        percentText = layer.percentText
        label = layer.label
        // Prefer metric color only. Plugin brandColor is often pure black/white (logo).
        ringColor = primary.color
      }
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
      ...(rings && rings.length > 0 ? { rings } : {}),
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
