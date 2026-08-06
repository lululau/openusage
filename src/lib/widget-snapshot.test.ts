import { describe, expect, it } from "vitest"
import { buildWidgetSnapshot } from "@/lib/widget-snapshot"

describe("buildWidgetSnapshot", () => {
  it("returns empty items when settings missing", () => {
    const snap = buildWidgetSnapshot({
      pluginsMeta: [],
      pluginSettings: null,
      pluginStates: {},
      now: new Date("2026-08-06T00:00:00.000Z"),
    })
    expect(snap.items).toEqual([])
    expect(snap.version).toBe(1)
  })

  it("uses % for percent metrics; count amount as primary (no detail line)", () => {
    const snap = buildWidgetSnapshot({
      displayMode: "left",
      pluginsMeta: [
        {
          id: "cursor",
          name: "Cursor",
          iconUrl: "data:image/svg+xml;base64,abc",
          primaryCandidates: ["Requests"],
          lines: [],
        },
        {
          id: "claude",
          name: "Claude",
          iconUrl: "data:image/svg+xml;base64,def",
          primaryCandidates: ["Session"],
          lines: [],
          brandColor: "#d97757",
        },
      ],
      pluginSettings: { order: ["cursor", "claude"], disabled: [] },
      pluginStates: {
        cursor: {
          data: {
            providerId: "cursor",
            displayName: "Cursor",
            iconUrl: "data:image/svg+xml;base64,abc",
            lines: [
              {
                type: "progress",
                label: "Requests",
                used: 500,
                limit: 1000,
                format: { kind: "count", suffix: "requests" },
              },
            ],
          },
          loading: false,
          error: null,
        },
        claude: {
          data: {
            providerId: "claude",
            displayName: "Claude",
            iconUrl: "data:image/svg+xml;base64,def",
            lines: [
              {
                type: "progress",
                label: "Session",
                used: 25,
                limit: 100,
                format: { kind: "percent" },
                color: "#22c55e",
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
      now: new Date("2026-08-06T00:00:00.000Z"),
    })

    expect(snap.items).toHaveLength(2)

    const cursor = snap.items[0]!
    expect(cursor.id).toBe("cursor")
    expect(cursor.fraction).toBe(0.5)
    // Remaining count in the primary slot (not "50%" + detail)
    expect(cursor.percentText).toBe("500")
    expect(cursor.detailText).toBeUndefined()
    expect(cursor.label).toBe("Requests")

    const claude = snap.items[1]!
    expect(claude.percentText).toBe("75%")
    expect(claude.detailText).toBeUndefined()
    expect(claude.ringColor).toBe("#22c55e")
  })

  it("formats dollars as primary text and respects used displayMode", () => {
    const snap = buildWidgetSnapshot({
      displayMode: "used",
      pluginsMeta: [
        {
          id: "a",
          name: "A",
          iconUrl: "",
          primaryCandidates: ["Credits"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["a"], disabled: [] },
      pluginStates: {
        a: {
          data: {
            providerId: "a",
            displayName: "A",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Credits",
                used: 12.5,
                limit: 100,
                format: { kind: "dollars" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })

    expect(snap.items[0]!.fraction).toBeCloseTo(0.125)
    expect(snap.items[0]!.percentText).toBe("$12.50")
    expect(snap.items[0]!.detailText).toBeUndefined()
  })

  it("skips disabled and limits to maxItems", () => {
    const ids = ["a", "b", "c", "d"]
    const snap = buildWidgetSnapshot({
      maxItems: 2,
      pluginsMeta: ids.map((id) => ({
        id,
        name: id,
        iconUrl: "",
        primaryCandidates: ["Usage"],
        lines: [],
      })),
      pluginSettings: { order: ids, disabled: ["b"] },
      pluginStates: {},
    })
    expect(snap.items.map((i) => i.id)).toEqual(["a", "c"])
  })
})
