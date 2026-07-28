(function () {
  const AUTH_PATH = "~/.grok/auth.json"
  const SUBSCRIPTIONS_ENDPOINT = "https://grok.com/rest/subscriptions"
  // Grok CLI billing endpoint (same weekly SuperGrok/GrokBuild pool the TUI shows)
  const BILLING_CREDITS_ENDPOINT = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
  const TOKEN_ENDPOINT = "https://auth.x.ai/oauth2/token"
  const GROK_USAGE_PAGE = "https://grok.com/?_s=usage"
  const SEVEN_DAYS_MS = 7 * 24 * 3600 * 1000
  const REFRESH_BUFFER_MS = 5 * 60 * 1000
  const DEFAULT_OIDC_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"

  function parseNumber(value) {
    if (value === null || value === undefined) return null
    // Unwrap protobuf-style wrappers: { val: 12.5 }
    if (typeof value === "object" && value !== null && "val" in value) {
      return parseNumber(value.val)
    }
    const n = Number(value)
    return Number.isFinite(n) ? n : null
  }

  function parseExpiryMs(value) {
    if (value === null || value === undefined) return null
    if (typeof value === "number" && Number.isFinite(value)) {
      return Math.abs(value) < 1e12 ? value * 1000 : value
    }
    if (typeof value === "string") {
      const trimmed = value.trim()
      if (!trimmed) return null
      if (/^-?\d+(\.\d+)?$/.test(trimmed)) {
        const n = Number(trimmed)
        if (!Number.isFinite(n)) return null
        return Math.abs(n) < 1e12 ? n * 1000 : n
      }
      const ms = Date.parse(trimmed)
      return Number.isFinite(ms) ? ms : null
    }
    return null
  }

  function matchQuotedField(html, field) {
    if (typeof html !== "string" || !field) return null
    // Next.js RSC payloads often escape quotes: \"createTime\":\"2026-07-28T02:14:57.000Z\"
    const escaped = html.match(new RegExp('\\\\"' + field + '\\\\":\\\\"([^\\\\"]+)\\\\"'))
    if (escaped && escaped[1]) return escaped[1]
    const plain = html.match(new RegExp('"' + field + '"\\s*:\\s*"([^"]+)"'))
    if (plain && plain[1]) return plain[1]
    return null
  }

  function extractFieldsFromHtml(html) {
    if (typeof html !== "string") return null
    const obj = {}

    const createTime =
      matchQuotedField(html, "createTime") || matchQuotedField(html, "create_time")
    if (createTime) obj.createTime = createTime

    const resetsAt =
      matchQuotedField(html, "resets_at") ||
      matchQuotedField(html, "resetsAt") ||
      matchQuotedField(html, "reset_time") ||
      matchQuotedField(html, "resetTime")
    if (resetsAt) obj.resets_at = resetsAt

    const usedMatch =
      html.match(/\\"used_fraction\\":\s*([0-9.]+)/) ||
      html.match(/\\"usedFraction\\":\s*([0-9.]+)/) ||
      html.match(/"used_fraction"\s*:\s*([0-9.]+)/) ||
      html.match(/"usedFraction"\s*:\s*([0-9.]+)/)
    if (usedMatch && usedMatch[1]) obj.used_fraction = Number(usedMatch[1])

    return Object.keys(obj).length > 0 ? obj : null
  }

  function nextSevenDayResetIso(ctx, windowStart, nowMs) {
    const startMs = Date.parse(windowStart)
    if (!Number.isFinite(startMs)) return null
    let nextMs = startMs
    while (nextMs <= nowMs) {
      nextMs += SEVEN_DAYS_MS
    }
    return ctx.util.toIso(nextMs)
  }

  function parseResetTimestamp(ctx, data, nowMs) {
    if (data && typeof data === "object") {
      const directReset =
        data.resets_at ||
        data.resetsAt ||
        data.reset_time ||
        data.resetTime ||
        data.window_reset_time ||
        data.windowResetTime ||
        data.next_reset_time ||
        data.nextResetTime
      if (directReset) {
        const iso = ctx.util.toIso(directReset)
        if (iso) return iso
      }

      const seconds = parseNumber(
        data.resets_in_seconds ||
          data.resetsInSeconds ||
          data.remaining_seconds ||
          data.remainingSeconds ||
          data.ttl_seconds ||
          data.ttlSeconds
      )
      if (seconds !== null && seconds > 0) {
        return ctx.util.toIso(nowMs + Math.round(seconds * 1000))
      }

      const windowStart =
        data.window_start_time ||
        data.windowStartTime ||
        data.period_start ||
        data.periodStart ||
        data.createTime ||
        data.create_time ||
        data.createdAt ||
        data.created_at ||
        (data.subscription && (data.subscription.createTime || data.subscription.create_time))
      if (windowStart) {
        const rolled = nextSevenDayResetIso(ctx, windowStart, nowMs)
        if (rolled) return rolled
      }
    }

    // No invent-now+7d fallback: that produces "correct date, current clock time"
    // when the subscription started today. Prefer omitting resetsAt over a fake time.
    return null
  }

  function parseUsedFraction(data) {
    if (!data || typeof data !== "object") return 0.0

    // Grok CLI billing: creditUsagePercent / productUsage[].usagePercent are 0–100
    const creditPct = parseNumber(data.creditUsagePercent || data.credit_usage_percent)
    if (creditPct !== null) {
      return Math.min(1.0, Math.max(0.0, creditPct / 100.0))
    }
    if (Array.isArray(data.productUsage)) {
      for (let i = 0; i < data.productUsage.length; i += 1) {
        const p = data.productUsage[i]
        if (!p || typeof p !== "object") continue
        const product = String(p.product || "")
        // Prefer GrokBuild / SuperGrok weekly pool when present
        if (product === "GrokBuild" || /super.?grok/i.test(product) || product === "Grok") {
          const pct = parseNumber(p.usagePercent || p.usage_percent)
          if (pct !== null) return Math.min(1.0, Math.max(0.0, pct / 100.0))
        }
      }
      // Fall back to first product with a percent
      for (let i = 0; i < data.productUsage.length; i += 1) {
        const pct = parseNumber(data.productUsage[i] && (data.productUsage[i].usagePercent || data.productUsage[i].usage_percent))
        if (pct !== null) return Math.min(1.0, Math.max(0.0, pct / 100.0))
      }
    }

    if (parseNumber(data.used_fraction) !== null) {
      return Math.min(1.0, Math.max(0.0, parseNumber(data.used_fraction)))
    }
    if (parseNumber(data.used_percentage) !== null) {
      return Math.min(1.0, Math.max(0.0, parseNumber(data.used_percentage) / 100.0))
    }

    const used = parseNumber(data.used_queries || data.used_credits || data.used || data.query_count)
    const limit = parseNumber(data.total_queries || data.total_credits || data.limit || data.query_limit)
    if (used !== null && limit !== null && limit > 0) {
      return Math.min(1.0, Math.max(0.0, used / limit))
    }

    const remaining = parseNumber(data.remaining_queries || data.remaining_credits || data.remaining)
    if (remaining !== null && limit !== null && limit > 0) {
      return Math.min(1.0, Math.max(0.0, (limit - remaining) / limit))
    }

    return 0.0
  }

  function pickAuthEntry(store) {
    if (!store || typeof store !== "object") return null
    // ~/.grok/auth.json is a map of provider keys -> credential objects
    const keys = Object.keys(store)
    for (let i = 0; i < keys.length; i += 1) {
      const entry = store[keys[i]]
      if (!entry || typeof entry !== "object") continue
      const access = entry.key || entry.access_token || entry.accessToken
      const refresh = entry.refresh_token || entry.refreshToken
      if ((typeof access === "string" && access) || (typeof refresh === "string" && refresh)) {
        return { storeKey: keys[i], entry: entry }
      }
    }
    // Flat credentials shape
    const access = store.key || store.access_token || store.accessToken
    const refresh = store.refresh_token || store.refreshToken
    if ((typeof access === "string" && access) || (typeof refresh === "string" && refresh)) {
      return { storeKey: null, entry: store }
    }
    return null
  }

  function loadAuthStore(ctx) {
    if (!ctx.host.fs.exists(AUTH_PATH)) return null
    try {
      const parsed = ctx.util.tryParseJson(ctx.host.fs.readText(AUTH_PATH))
      if (!parsed || typeof parsed !== "object") return null
      return parsed
    } catch (e) {
      ctx.host.log.warn("grok auth read failed: " + String(e))
      return null
    }
  }

  function saveAuthStore(ctx, store) {
    try {
      ctx.host.fs.writeText(AUTH_PATH, JSON.stringify(store, null, 2))
    } catch (e) {
      ctx.host.log.warn("grok auth write failed: " + String(e))
    }
  }

  function accessTokenFromEntry(entry) {
    if (!entry || typeof entry !== "object") return null
    const token = entry.key || entry.access_token || entry.accessToken
    return typeof token === "string" && token ? token : null
  }

  function refreshTokenFromEntry(entry) {
    if (!entry || typeof entry !== "object") return null
    const token = entry.refresh_token || entry.refreshToken
    return typeof token === "string" && token ? token : null
  }

  function clientIdFromEntry(entry) {
    if (!entry || typeof entry !== "object") return DEFAULT_OIDC_CLIENT_ID
    const id = entry.oidc_client_id || entry.oidcClientId || entry.client_id || entry.clientId
    return typeof id === "string" && id ? id : DEFAULT_OIDC_CLIENT_ID
  }

  function needsRefresh(entry, nowMs) {
    if (!accessTokenFromEntry(entry)) return true
    const expiresMs = parseExpiryMs(entry.expires_at || entry.expiresAt || entry.expiry)
    if (expiresMs === null) return false
    return nowMs + REFRESH_BUFFER_MS >= expiresMs
  }

  function refreshAccessToken(ctx, entry) {
    const refreshToken = refreshTokenFromEntry(entry)
    if (!refreshToken) return null

    let resp
    try {
      resp = ctx.util.request({
        method: "POST",
        url: TOKEN_ENDPOINT,
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          Accept: "application/json",
          "User-Agent": "OpenUsage",
        },
        bodyText:
          "grant_type=refresh_token" +
          "&refresh_token=" +
          encodeURIComponent(refreshToken) +
          "&client_id=" +
          encodeURIComponent(clientIdFromEntry(entry)),
        timeoutMs: 15000,
      })
    } catch (e) {
      ctx.host.log.warn("grok token refresh failed: " + String(e))
      return null
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      throw "Grok session expired. Run Grok CLI login again."
    }
    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.warn("grok token refresh status: " + String(resp.status))
      return null
    }

    const body = ctx.util.tryParseJson(resp.bodyText)
    if (!body || typeof body.access_token !== "string" || !body.access_token) {
      ctx.host.log.warn("grok token refresh missing access_token")
      return null
    }

    entry.key = body.access_token
    entry.access_token = body.access_token
    if (typeof body.refresh_token === "string" && body.refresh_token) {
      entry.refresh_token = body.refresh_token
    }
    if (typeof body.expires_in === "number" && Number.isFinite(body.expires_in)) {
      entry.expires_at = new Date(Date.now() + body.expires_in * 1000).toISOString()
    }
    return body.access_token
  }

  function resolveAccessToken(ctx) {
    const envToken =
      (ctx.host.env.get && (ctx.host.env.get("GROK_API_KEY") || ctx.host.env.get("XAI_API_KEY"))) || null
    if (typeof envToken === "string" && envToken.trim()) {
      return { token: envToken.trim(), persist: null }
    }

    const store = loadAuthStore(ctx)
    if (!store) return null
    const picked = pickAuthEntry(store)
    if (!picked) return null

    const nowMs = Date.now()
    let token = accessTokenFromEntry(picked.entry)
    if (needsRefresh(picked.entry, nowMs)) {
      const refreshed = refreshAccessToken(ctx, picked.entry)
      if (refreshed) {
        token = refreshed
        if (picked.storeKey) store[picked.storeKey] = picked.entry
        saveAuthStore(ctx, store)
      }
    }

    if (!token) return null
    return { token: token, persist: { store: store, storeKey: picked.storeKey, entry: picked.entry } }
  }

  function authHeaders(token) {
    return {
      Authorization: "Bearer " + token,
      Accept: "application/json",
      "User-Agent": "OpenUsage",
    }
  }

  function requestJson(ctx, token, url) {
    let resp
    try {
      resp = ctx.util.request({
        method: "GET",
        url: url,
        headers: authHeaders(token),
        timeoutMs: 10000,
      })
    } catch (e) {
      ctx.host.log.warn("grok request failed (" + url + "): " + String(e))
      return null
    }

    if (ctx.util.isAuthStatus(resp.status)) {
      return { isAuthError: true }
    }
    if (resp.status < 200 || resp.status >= 300) {
      ctx.host.log.warn("grok request status " + String(resp.status) + " (" + url + ")")
      return null
    }

    const parsed = ctx.util.tryParseJson(resp.bodyText)
    if (!parsed || typeof parsed !== "object") {
      // SPA HTML shell or empty body
      return null
    }
    return { data: parsed }
  }

  function mapBillingConfig(parsed) {
    if (!parsed || typeof parsed !== "object") return null
    const config = parsed.config && typeof parsed.config === "object" ? parsed.config : parsed
    if (!config || typeof config !== "object") return null

    const period = config.currentPeriod || config.current_period || null
    const periodEnd =
      (period && (period.end || period.ends_at || period.endsAt)) ||
      config.billingPeriodEnd ||
      config.billing_period_end ||
      null
    const periodStart =
      (period && (period.start || period.starts_at || period.startsAt)) ||
      config.billingPeriodStart ||
      config.billing_period_start ||
      null

    return {
      creditUsagePercent: parseNumber(config.creditUsagePercent || config.credit_usage_percent),
      productUsage: Array.isArray(config.productUsage)
        ? config.productUsage
        : Array.isArray(config.product_usage)
          ? config.product_usage
          : null,
      // Prefer explicit period end from billing (matches Grok CLI "Weekly limit" reset)
      resets_at: periodEnd,
      createTime: periodStart,
      extra_credits: parseNumber(
        config.prepaidBalance || config.prepaid_balance || config.additional_credits || config.extra_credits
      ),
      onDemandUsed: parseNumber(config.onDemandUsed || config.on_demand_used),
      onDemandCap: parseNumber(config.onDemandCap || config.on_demand_cap),
      billingConfig: config,
    }
  }

  function fetchBillingCredits(ctx, token) {
    const result = requestJson(ctx, token, BILLING_CREDITS_ENDPOINT)
    if (!result) return null
    if (result.isAuthError) return result
    const mapped = mapBillingConfig(result.data)
    if (!mapped) return null
    return { data: mapped }
  }

  function fetchSubscriptions(ctx, token) {
    const result = requestJson(ctx, token, SUBSCRIPTIONS_ENDPOINT)
    if (!result) return null
    if (result.isAuthError) return result

    const parsed = result.data
    const list = Array.isArray(parsed.subscriptions) ? parsed.subscriptions : null
    if (!list || list.length === 0) return { data: {} }

    // Prefer active SuperGrok / Pro subscription when multiple exist
    let chosen = list[0]
    for (let i = 0; i < list.length; i += 1) {
      const sub = list[i]
      if (!sub || typeof sub !== "object") continue
      const status = String(sub.status || "")
      if (status.indexOf("ACTIVE") !== -1) {
        chosen = sub
        break
      }
    }

    return {
      data: {
        createTime: chosen.createTime || chosen.create_time || null,
        resets_at: chosen.resets_at || chosen.resetsAt || chosen.reset_time || chosen.resetTime || null,
        used_fraction: parseNumber(chosen.used_fraction || chosen.usedFraction),
        extra_credits: parseNumber(
          chosen.extra_credits || chosen.prepaid_balance || chosen.additional_credits
        ),
        subscription: chosen,
        subscriptions: list,
      },
    }
  }

  function fetchPageCreateTime(ctx, token) {
    try {
      const headers = {
        Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "User-Agent": "OpenUsage",
      }
      if (token) headers.Authorization = "Bearer " + token

      const pageResp = ctx.util.request({
        method: "GET",
        url: GROK_USAGE_PAGE,
        headers: headers,
        timeoutMs: 10000,
      })

      if (ctx.util.isAuthStatus(pageResp.status)) {
        return { isAuthError: true }
      }

      if (pageResp.status >= 200 && pageResp.status < 300) {
        const extracted = extractFieldsFromHtml(pageResp.bodyText)
        if (extracted) return { data: extracted }
      }
    } catch (e) {
      ctx.host.log.warn("grok page request failed: " + String(e))
    }
    return null
  }

  function withTokenRetry(ctx, auth, fetchFn) {
    let result = fetchFn(ctx, auth.token)
    if (result && result.isAuthError && auth.persist && auth.persist.entry) {
      const refreshed = refreshAccessToken(ctx, auth.persist.entry)
      if (refreshed) {
        if (auth.persist.storeKey) auth.persist.store[auth.persist.storeKey] = auth.persist.entry
        saveAuthStore(ctx, auth.persist.store)
        auth.token = refreshed
        result = fetchFn(ctx, refreshed)
      }
    }
    return result
  }

  function fetchCreditsData(ctx) {
    const auth = resolveAccessToken(ctx)
    if (!auth || !auth.token) {
      // No CLI credentials — still try page scrape (works only if host injects cookies)
      const pageOnly = fetchPageCreateTime(ctx, null)
      if (pageOnly && pageOnly.data) return pageOnly
      return { isAuthError: true }
    }

    // 1) Primary: CLI billing credits (usage % + weekly period end) — same source as Grok CLI TUI
    const billing = withTokenRetry(ctx, auth, fetchBillingCredits)
    if (billing && billing.isAuthError) {
      return { isAuthError: true }
    }

    // 2) Secondary: subscriptions createTime (reset fallback)
    const sub = withTokenRetry(ctx, auth, fetchSubscriptions)
    if (sub && sub.isAuthError && !(billing && billing.data)) {
      return { isAuthError: true }
    }

    let data = {}
    if (sub && sub.data) data = Object.assign(data, sub.data)
    if (billing && billing.data) {
      // Billing wins for usage + period end (authoritative for weekly limit)
      data = Object.assign(data, billing.data)
    }

    if (
      data.createTime ||
      data.resets_at ||
      (data.creditUsagePercent !== null && data.creditUsagePercent !== undefined)
    ) {
      return { data: data }
    }

    // 3) HTML fallback
    const page = fetchPageCreateTime(ctx, auth.token)
    if (page && page.isAuthError) return { isAuthError: true }
    if (page && page.data) {
      return { data: Object.assign(data, page.data) }
    }

    if (Object.keys(data).length > 0) return { data: data }
    return null
  }

  function probe(ctx) {
    const result = fetchCreditsData(ctx)
    if (result && result.isAuthError) {
      throw "Not logged in. Sign in via Grok CLI (`~/.grok/auth.json`) or set GROK_API_KEY."
    }

    const data = (result && result.data) || {}
    const nowMs = Date.now()
    const resetsAt = parseResetTimestamp(ctx, data, nowMs)
    const usedFraction = parseUsedFraction(data)
    const usedPercent = Math.round(usedFraction * 100)

    const progressOpts = {
      label: "SuperGrok",
      used: usedPercent,
      limit: 100,
      format: { kind: "percent" },
      periodDurationMs: SEVEN_DAYS_MS,
    }
    if (resetsAt) progressOpts.resetsAt = resetsAt

    const lines = [ctx.line.progress(progressOpts)]

    const extraBalance = parseNumber(
      data.extra_credits || data.prepaid_balance || data.additional_credits
    )
    if (extraBalance !== null && extraBalance > 0) {
      lines.push(
        ctx.line.text({
          label: "Extra usage spent",
          value: "$" + extraBalance.toFixed(2),
        })
      )
    }

    return { lines: lines }
  }

  globalThis.__openusage_plugin = { id: "grok", probe: probe }
})()
