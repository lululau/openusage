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
          // No multi-ring labels match → fall back to primary Requests
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
    expect(cursor.rings).toBeUndefined()

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

  it("builds 3 concentric percent rings for Cursor Total / Auto / API", () => {
    const snap = buildWidgetSnapshot({
      displayMode: "used",
      pluginsMeta: [
        {
          id: "cursor",
          name: "Cursor",
          iconUrl: "data:image/svg+xml;base64,cur",
          primaryCandidates: ["Credits", "Total usage", "Requests"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["cursor"], disabled: [] },
      pluginStates: {
        cursor: {
          data: {
            providerId: "cursor",
            displayName: "Cursor",
            iconUrl: "data:image/svg+xml;base64,cur",
            lines: [
              {
                type: "progress",
                label: "Credits",
                used: 5,
                limit: 20,
                format: { kind: "dollars" },
              },
              {
                type: "progress",
                label: "Total usage",
                used: 42,
                limit: 100,
                format: { kind: "percent" },
              },
              {
                type: "progress",
                label: "Auto usage",
                used: 12,
                limit: 100,
                format: { kind: "percent" },
              },
              {
                type: "progress",
                label: "API usage",
                used: 70,
                limit: 100,
                format: { kind: "percent" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })

    const cursor = snap.items[0]!
    expect(cursor.label).toBe("Total usage")
    expect(cursor.percentText).toBe("42%")
    expect(cursor.fraction).toBeCloseTo(0.42)
    expect(cursor.rings).toHaveLength(3)
    expect(cursor.rings!.map((r) => r.label)).toEqual([
      "Total usage",
      "Auto usage",
      "API usage",
    ])
    expect(cursor.rings!.map((r) => r.percentText)).toEqual(["42%", "12%", "70%"])
    // Fallback palette when lines have no color
    expect(cursor.rings![0]!.ringColor).toBe("#4CD964")
    expect(cursor.rings![1]!.ringColor).toBe("#5AC8FA")
    expect(cursor.rings![2]!.ringColor).toBe("#FF9F0A")
  })

  it("builds 2 concentric 5h rings for Antigravity Session + Claude, with weekly alternate", () => {
    const snap = buildWidgetSnapshot({
      displayMode: "left",
      pluginsMeta: [
        {
          id: "antigravity",
          name: "Antigravity",
          iconUrl: "",
          primaryCandidates: ["Session"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["antigravity"], disabled: [] },
      pluginStates: {
        antigravity: {
          data: {
            providerId: "antigravity",
            displayName: "Antigravity",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Session",
                used: 0,
                limit: 100,
                format: { kind: "percent" },
              },
              {
                type: "progress",
                label: "Weekly",
                used: 9,
                limit: 100,
                format: { kind: "percent" },
              },
              {
                type: "progress",
                label: "Claude",
                used: 10,
                limit: 100,
                format: { kind: "percent" },
              },
              {
                type: "progress",
                label: "Claude Weekly",
                used: 0,
                limit: 100,
                format: { kind: "percent" },
              },
            ],
          },
          loading: false,
          error: null,
        },
      },
    })

    const item = snap.items[0]!
    // Default face = 5h (Session outer, Claude inner)
    expect(item.label).toBe("Session")
    expect(item.percentText).toBe("100%")
    expect(item.rings).toHaveLength(2)
    expect(item.rings!.map((r) => r.label)).toEqual(["Session", "Claude"])
    expect(item.rings!.map((r) => r.percentText)).toEqual(["100%", "90%"])
    // Weekly alternate for widget tap toggle
    expect(item.weeklyRings).toHaveLength(2)
    expect(item.weeklyRings!.map((r) => r.label)).toEqual(["Weekly", "Claude Weekly"])
    expect(item.weeklyRings!.map((r) => r.percentText)).toEqual(["91%", "100%"])
  })

  it("omits missing Cursor multi-ring metrics and still prefers Total over Credits", () => {
    const snap = buildWidgetSnapshot({
      displayMode: "used",
      pluginsMeta: [
        {
          id: "cursor",
          name: "Cursor",
          iconUrl: "",
          primaryCandidates: ["Credits", "Total usage"],
          lines: [],
        },
      ],
      pluginSettings: { order: ["cursor"], disabled: [] },
      pluginStates: {
        cursor: {
          data: {
            providerId: "cursor",
            displayName: "Cursor",
            iconUrl: "",
            lines: [
              {
                type: "progress",
                label: "Credits",
                used: 1,
                limit: 10,
                format: { kind: "dollars" },
              },
              {
                type: "progress",
                label: "Total usage",
                used: 15,
                limit: 100,
                format: { kind: "percent" },
              },
              // Auto / API absent
            ],
          },
          loading: false,
          error: null,
        },
      },
    })

    const cursor = snap.items[0]!
    expect(cursor.rings).toHaveLength(1)
    expect(cursor.rings![0]!.label).toBe("Total usage")
    expect(cursor.percentText).toBe("15%")
  })
})
