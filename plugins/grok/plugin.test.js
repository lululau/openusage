import fs from "node:fs"
import path from "node:path"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

const AUTH_PATH = "~/.grok/auth.json"
const SUBSCRIPTIONS_ENDPOINT = "https://grok.com/rest/subscriptions"
const BILLING_CREDITS_ENDPOINT = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
const TOKEN_ENDPOINT = "https://auth.x.ai/oauth2/token"
const GROK_USAGE_PAGE = "https://grok.com/?_s=usage"
const SEVEN_DAYS_MS = 7 * 24 * 3600 * 1000

const loadPlugin = () => {
  const code = fs.readFileSync(path.join(import.meta.dirname, "plugin.js"), "utf8")
  delete globalThis.__openusage_plugin
  new Function("globalThis", code)(globalThis)
  return globalThis.__openusage_plugin
}

function installAuth(ctx, entry, storeKey = "https://auth.x.ai::test-client") {
  const store = storeKey
    ? {
        [storeKey]: {
          key: "access-token",
          refresh_token: "refresh-token",
          expires_at: "2099-01-01T00:00:00.000Z",
          oidc_client_id: "test-client",
          ...entry,
        },
      }
    : {
        key: "access-token",
        refresh_token: "refresh-token",
        expires_at: "2099-01-01T00:00:00.000Z",
        ...entry,
      }
  ctx.host.fs.writeText(AUTH_PATH, JSON.stringify(store))
}

describe("grok plugin", () => {
  beforeEach(() => {
    delete globalThis.__openusage_plugin
  })

  it("throws authentication error when not logged in", () => {
    const ctx = makeCtx()
    ctx.host.http.request.mockImplementation(() => ({
      status: 401,
      bodyText: "",
    }))

    const plugin = loadPlugin()
    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("uses CLI billing credits for usage percent + weekly period end (matches Grok CLI TUI)", () => {
    const ctx = makeCtx()
    const nowMs = Date.parse("2026-07-28T12:35:00.000Z")
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    installAuth(ctx)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url) === BILLING_CREDITS_ENDPOINT) {
        expect(opts.headers.Authorization).toBe("Bearer access-token")
        return {
          status: 200,
          bodyText: JSON.stringify({
            config: {
              currentPeriod: {
                type: "USAGE_PERIOD_TYPE_WEEKLY",
                start: "2026-07-28T02:14:58.226666+00:00",
                end: "2026-08-04T02:14:58.226666+00:00",
              },
              creditUsagePercent: 1.0,
              productUsage: [{ product: "GrokBuild", usagePercent: 1.0 }],
              prepaidBalance: { val: 0 },
              onDemandCap: { val: 0 },
              onDemandUsed: { val: 0 },
              isUnifiedBillingUser: true,
              billingPeriodStart: "2026-07-28T02:14:58.226666+00:00",
              billingPeriodEnd: "2026-08-04T02:14:58.226666+00:00",
            },
          }),
        }
      }
      if (String(opts.url) === SUBSCRIPTIONS_ENDPOINT) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            subscriptions: [
              {
                tier: "SUBSCRIPTION_TIER_GROK_PRO",
                status: "SUBSCRIPTION_STATUS_ACTIVE",
                createTime: "2026-07-28T02:14:57.000Z",
              },
            ],
          }),
        }
      }
      throw new Error("unexpected url: " + opts.url)
    })

    const plugin = loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines).toHaveLength(1)
    const line = result.lines[0]
    expect(line.label).toBe("SuperGrok")
    // period.end from billing (same wall-clock as CLI "Weekly limit")
    expect(line.resetsAt).toBe("2026-08-04T02:14:58.226Z")
    expect(line.periodDurationMs).toBe(SEVEN_DAYS_MS)
    expect(line.used).toBe(1)
    expect(line.limit).toBe(100)
    expect(line.format).toEqual({ kind: "percent" })
  })

  it("uses subscription createTime from /rest/subscriptions when billing lacks period end", () => {
    const ctx = makeCtx()
    const nowMs = Date.parse("2026-07-28T12:35:00.000Z")
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    installAuth(ctx)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url) === BILLING_CREDITS_ENDPOINT) {
        return { status: 500, bodyText: "error" }
      }
      if (String(opts.url) === SUBSCRIPTIONS_ENDPOINT) {
        expect(opts.headers.Authorization).toBe("Bearer access-token")
        return {
          status: 200,
          bodyText: JSON.stringify({
            subscriptions: [
              {
                tier: "SUBSCRIPTION_TIER_GROK_PRO",
                status: "SUBSCRIPTION_STATUS_ACTIVE",
                createTime: "2026-07-28T02:14:57.000Z",
              },
            ],
          }),
        }
      }
      throw new Error("unexpected url: " + opts.url)
    })

    const plugin = loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines).toHaveLength(1)
    const line = result.lines[0]
    expect(line.label).toBe("SuperGrok")
    // createTime 02:14:57Z + 7 days = 2026-08-04T02:14:57.000Z (Aug 4 10:14 AM CST)
    expect(line.resetsAt).toBe("2026-08-04T02:14:57.000Z")
    expect(line.periodDurationMs).toBe(SEVEN_DAYS_MS)
    expect(line.used).toBe(0)
    expect(line.format).toEqual({ kind: "percent" })
  })

  it("does not use now+7d fake time when createTime is missing", () => {
    const ctx = makeCtx()
    const nowMs = Date.parse("2026-07-28T12:37:00.000Z")
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    installAuth(ctx)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url) === BILLING_CREDITS_ENDPOINT) {
        return { status: 500, bodyText: "error" }
      }
      if (String(opts.url) === SUBSCRIPTIONS_ENDPOINT) {
        return {
          status: 200,
          bodyText: JSON.stringify({ subscriptions: [{ status: "SUBSCRIPTION_STATUS_ACTIVE" }] }),
        }
      }
      if (String(opts.url) === GROK_USAGE_PAGE) {
        return { status: 200, bodyText: "<html></html>" }
      }
      throw new Error("unexpected url: " + opts.url)
    })

    const plugin = loadPlugin()
    const result = plugin.probe(ctx)
    const line = result.lines[0]
    expect(line.resetsAt).toBeUndefined()
    // Explicitly not "current time + 7 days"
    expect(line.resetsAt).not.toBe(new Date(nowMs + SEVEN_DAYS_MS).toISOString())
  })

  it("extracts createTime from RSC-escaped HTML fallback", () => {
    const ctx = makeCtx()
    const nowMs = Date.parse("2026-07-28T12:35:00.000Z")
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    installAuth(ctx)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url) === BILLING_CREDITS_ENDPOINT) {
        return { status: 500, bodyText: "error" }
      }
      if (String(opts.url) === SUBSCRIPTIONS_ENDPOINT) {
        return { status: 500, bodyText: "error" }
      }
      if (String(opts.url) === GROK_USAGE_PAGE) {
        // Real Grok SSR embeds fields as \"createTime\":\"...\"
        return {
          status: 200,
          bodyText: String.raw`<!DOCTYPE html><script>self.__next_f.push([1,"tier\":\"SUBSCRIPTION_TIER_GROK_PRO\",\"createTime\":\"2026-07-28T02:14:57.000Z\",\"modTime\":\"2026-07-28T02:15:02.000Z\""])</script>`,
        }
      }
      throw new Error("unexpected url: " + opts.url)
    })

    const plugin = loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].resetsAt).toBe("2026-08-04T02:14:57.000Z")
  })

  it("parses direct resets_at from subscription payload", () => {
    const ctx = makeCtx()
    installAuth(ctx)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url) === BILLING_CREDITS_ENDPOINT) {
        return { status: 500, bodyText: "error" }
      }
      if (String(opts.url) === SUBSCRIPTIONS_ENDPOINT) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            subscriptions: [
              {
                status: "SUBSCRIPTION_STATUS_ACTIVE",
                createTime: "2026-07-28T02:14:57.000Z",
                resets_at: "2026-08-04T10:14:00.000Z",
              },
            ],
          }),
        }
      }
      throw new Error("unexpected url: " + opts.url)
    })

    const plugin = loadPlugin()
    const result = plugin.probe(ctx)
    // direct resets_at wins over createTime roll-forward
    expect(result.lines[0].resetsAt).toBe("2026-08-04T10:14:00.000Z")
  })

  it("refreshes expired access token then fetches billing credits", () => {
    const ctx = makeCtx()
    const nowMs = Date.parse("2026-07-28T12:00:00.000Z")
    vi.spyOn(Date, "now").mockReturnValue(nowMs)
    installAuth(ctx, {
      key: "stale-token",
      expires_at: "2026-07-28T08:00:00.000Z",
    })

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url) === TOKEN_ENDPOINT) {
        expect(opts.method).toBe("POST")
        expect(String(opts.bodyText)).toContain("grant_type=refresh_token")
        return {
          status: 200,
          bodyText: JSON.stringify({
            access_token: "fresh-token",
            refresh_token: "new-refresh",
            expires_in: 21600,
          }),
        }
      }
      if (String(opts.url) === BILLING_CREDITS_ENDPOINT) {
        expect(opts.headers.Authorization).toBe("Bearer fresh-token")
        return {
          status: 200,
          bodyText: JSON.stringify({
            config: {
              currentPeriod: {
                type: "USAGE_PERIOD_TYPE_WEEKLY",
                start: "2026-07-28T02:14:58.000Z",
                end: "2026-08-04T02:14:58.000Z",
              },
              creditUsagePercent: 3.0,
              prepaidBalance: { val: 0 },
            },
          }),
        }
      }
      if (String(opts.url) === SUBSCRIPTIONS_ENDPOINT) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            subscriptions: [
              {
                status: "SUBSCRIPTION_STATUS_ACTIVE",
                createTime: "2026-07-28T02:14:57.000Z",
              },
            ],
          }),
        }
      }
      throw new Error("unexpected url: " + opts.url)
    })

    const plugin = loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].resetsAt).toBe("2026-08-04T02:14:58.000Z")
    expect(result.lines[0].used).toBe(3)
    expect(ctx.host.fs.writeText).toHaveBeenCalled()
  })

  it("uses GROK_API_KEY env when auth.json is missing", () => {
    const ctx = makeCtx()
    ctx.host.env.get = vi.fn((name) => (name === "GROK_API_KEY" ? "env-token" : null))

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url) === BILLING_CREDITS_ENDPOINT) {
        expect(opts.headers.Authorization).toBe("Bearer env-token")
        return {
          status: 200,
          bodyText: JSON.stringify({
            config: {
              currentPeriod: {
                end: "2026-08-04T02:14:58.000Z",
              },
              creditUsagePercent: 1.0,
            },
          }),
        }
      }
      if (String(opts.url) === SUBSCRIPTIONS_ENDPOINT) {
        return { status: 200, bodyText: JSON.stringify({ subscriptions: [] }) }
      }
      throw new Error("unexpected url: " + opts.url)
    })

    const nowMs = Date.parse("2026-07-28T12:00:00.000Z")
    vi.spyOn(Date, "now").mockReturnValue(nowMs)

    const plugin = loadPlugin()
    const result = plugin.probe(ctx)
    expect(result.lines[0].resetsAt).toBe("2026-08-04T02:14:58.000Z")
    expect(result.lines[0].used).toBe(1)
  })

  it("includes extra usage spent line when prepaid balance exists", () => {
    const ctx = makeCtx()
    installAuth(ctx)

    ctx.host.http.request.mockImplementation((opts) => {
      if (String(opts.url) === BILLING_CREDITS_ENDPOINT) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            config: {
              currentPeriod: { end: "2026-08-04T02:14:58.000Z" },
              creditUsagePercent: 50.0,
              prepaidBalance: { val: 12.5 },
            },
          }),
        }
      }
      if (String(opts.url) === SUBSCRIPTIONS_ENDPOINT) {
        return {
          status: 200,
          bodyText: JSON.stringify({
            subscriptions: [
              {
                status: "SUBSCRIPTION_STATUS_ACTIVE",
                createTime: "2026-07-28T02:14:57.000Z",
              },
            ],
          }),
        }
      }
      throw new Error("unexpected url: " + opts.url)
    })

    const plugin = loadPlugin()
    const result = plugin.probe(ctx)

    expect(result.lines).toHaveLength(2)
    expect(result.lines[0].used).toBe(50)
    expect(result.lines[1].label).toBe("Extra usage spent")
    expect(result.lines[1].value).toBe("$12.50")
  })
})
