(function () {
  const STATE_DB =
    "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
  const KEYCHAIN_ACCESS_TOKEN_SERVICE = "cursor-access-token"
  const KEYCHAIN_REFRESH_TOKEN_SERVICE = "cursor-refresh-token"
  const REFRESH_URL = "https://api2.cursor.sh/oauth/token"
  const REST_USAGE_URL = "https://cursor.com/api/usage"
  const CLIENT_ID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
  const REFRESH_BUFFER_MS = 5 * 60 * 1000
  const LOGIN_HINT = "Sign in via Cursor app or run `agent login`."

  function readStateValue(ctx, key) {
    try {
      const sql =
        "SELECT value FROM ItemTable WHERE key = '" + key + "' LIMIT 1;"
      const json = ctx.host.sqlite.query(STATE_DB, sql)
      const rows = ctx.util.tryParseJson(json)
      if (!Array.isArray(rows)) {
        throw new Error("sqlite returned invalid json")
      }
      if (rows.length > 0 && rows[0].value) {
        return rows[0].value
      }
    } catch (e) {
      ctx.host.log.warn("sqlite read failed for " + key + ": " + String(e))
    }
    return null
  }

  function writeStateValue(ctx, key, value) {
    try {
      const escaped = String(value).replace(/'/g, "''")
      const sql =
        "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('" +
        key +
        "', '" +
        escaped +
        "');"
      ctx.host.sqlite.exec(STATE_DB, sql)
      return true
    } catch (e) {
      ctx.host.log.warn("sqlite write failed for " + key + ": " + String(e))
      return false
    }
  }

  function readKeychainValue(ctx, service) {
    if (!ctx.host.keychain || typeof ctx.host.keychain.readGenericPassword !== "function") {
      return null
    }
    try {
      const value = ctx.host.keychain.readGenericPassword(service)
      if (typeof value !== "string") return null
      const trimmed = value.trim()
      return trimmed || null
    } catch (e) {
      ctx.host.log.info("keychain read failed for " + service + ": " + String(e))
      return null
    }
  }

  function writeKeychainValue(ctx, service, value) {
    if (!ctx.host.keychain || typeof ctx.host.keychain.writeGenericPassword !== "function") {
      ctx.host.log.warn("keychain write unsupported")
      return false
    }
    try {
      ctx.host.keychain.writeGenericPassword(service, String(value))
      return true
    } catch (e) {
      ctx.host.log.warn("keychain write failed for " + service + ": " + String(e))
      return false
    }
  }

  function loadAuthState(ctx) {
    const sqliteAccessToken = readStateValue(ctx, "cursorAuth/accessToken")
    const sqliteRefreshToken = readStateValue(ctx, "cursorAuth/refreshToken")
    if (sqliteAccessToken || sqliteRefreshToken) {
      return {
        accessToken: sqliteAccessToken,
        refreshToken: sqliteRefreshToken,
        source: "sqlite",
      }
    }

    const keychainAccessToken = readKeychainValue(ctx, KEYCHAIN_ACCESS_TOKEN_SERVICE)
    const keychainRefreshToken = readKeychainValue(ctx, KEYCHAIN_REFRESH_TOKEN_SERVICE)
    if (keychainAccessToken || keychainRefreshToken) {
      return {
        accessToken: keychainAccessToken,
        refreshToken: keychainRefreshToken,
        source: "keychain",
      }
    }

    return {
      accessToken: null,
      refreshToken: null,
      source: null,
    }
  }

  function persistAccessToken(ctx, source, accessToken) {
    if (source === "keychain") {
      return writeKeychainValue(ctx, KEYCHAIN_ACCESS_TOKEN_SERVICE, accessToken)
    }
    return writeStateValue(ctx, "cursorAuth/accessToken", accessToken)
  }

  function getTokenExpiration(ctx, token) {
    const payload = ctx.jwt.decodePayload(token)
    if (!payload || typeof payload.exp !== "number") return null
    return payload.exp * 1000
  }

  function needsRefresh(ctx, accessToken, nowMs) {
    if (!accessToken) return true
    const expiresAt = getTokenExpiration(ctx, accessToken)
    return ctx.util.needsRefreshByExpiry({
      nowMs,
      expiresAtMs: expiresAt,
      bufferMs: REFRESH_BUFFER_MS,
    })
  }

  function refreshToken(ctx, refreshTokenValue, source) {
    if (!refreshTokenValue) {
      ctx.host.log.warn("refresh skipped: no refresh token")
      return null
    }

    ctx.host.log.info("attempting token refresh")
    try {
      const resp = ctx.util.request({
        method: "POST",
        url: REFRESH_URL,
        headers: { "Content-Type": "application/json" },
        bodyText: JSON.stringify({
          grant_type: "refresh_token",
          client_id: CLIENT_ID,
          refresh_token: refreshTokenValue,
        }),
        timeoutMs: 15000,
      })

      if (resp.status === 400 || resp.status === 401) {
        let errorInfo = null
        errorInfo = ctx.util.tryParseJson(resp.bodyText)
        const shouldLogout = errorInfo && errorInfo.shouldLogout === true
        ctx.host.log.error("refresh failed: status=" + resp.status + " shouldLogout=" + shouldLogout)
        if (shouldLogout) {
          throw "Session expired. " + LOGIN_HINT
        }
        throw "Token expired. " + LOGIN_HINT
      }

      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("refresh returned unexpected status: " + resp.status)
        return null
      }

      const body = ctx.util.tryParseJson(resp.bodyText)
      if (!body) {
        ctx.host.log.warn("refresh response not valid JSON")
        return null
      }

      if (body.shouldLogout === true) {
        ctx.host.log.error("refresh response indicates shouldLogout=true")
        throw "Session expired. " + LOGIN_HINT
      }

      const newAccessToken = body.access_token
      if (!newAccessToken) {
        ctx.host.log.warn("refresh response missing access_token")
        return null
      }

      persistAccessToken(ctx, source, newAccessToken)
      ctx.host.log.info("refresh succeeded, token persisted")
      return newAccessToken
    } catch (e) {
      if (typeof e === "string") throw e
      ctx.host.log.error("refresh exception: " + String(e))
      return null
    }
  }

  function buildSessionToken(ctx, accessToken) {
    var payload = ctx.jwt.decodePayload(accessToken)
    if (!payload || !payload.sub) return null
    var parts = String(payload.sub).split("|")
    var userId = parts.length > 1 ? parts[1] : parts[0]
    if (!userId) return null
    return { userId: userId, sessionToken: userId + "%3A%3A" + accessToken }
  }

  function fetchRequestBasedUsage(ctx, accessToken) {
    var session = buildSessionToken(ctx, accessToken)
    if (!session) {
      ctx.host.log.warn("request-based: cannot build session token")
      return null
    }
    try {
      var resp = ctx.util.request({
        method: "GET",
        url: REST_USAGE_URL + "?user=" + encodeURIComponent(session.userId),
        headers: {
          Cookie: "WorkosCursorSessionToken=" + session.sessionToken,
        },
        timeoutMs: 10000,
      })
      if (resp.status < 200 || resp.status >= 300) {
        ctx.host.log.warn("request-based usage returned status=" + resp.status)
        return null
      }
      return ctx.util.tryParseJson(resp.bodyText)
    } catch (e) {
      ctx.host.log.warn("request-based usage fetch failed: " + String(e))
      return null
    }
  }

  function probe(ctx) {
    const authState = loadAuthState(ctx)
    let accessToken = authState.accessToken
    const refreshTokenValue = authState.refreshToken
    const authSource = authState.source

    if (!accessToken && !refreshTokenValue) {
      ctx.host.log.error("probe failed: no access or refresh token in sqlite/keychain")
      throw "Not logged in. " + LOGIN_HINT
    }

    ctx.host.log.info("tokens loaded from " + authSource + ": accessToken=" + (accessToken ? "yes" : "no") + " refreshToken=" + (refreshTokenValue ? "yes" : "no"))

    const nowMs = Date.now()

    if (needsRefresh(ctx, accessToken, nowMs)) {
      ctx.host.log.info("token needs refresh (expired or expiring soon)")
      let refreshed = null
      try {
        refreshed = refreshToken(ctx, refreshTokenValue, authSource)
      } catch (e) {
        ctx.host.log.warn("refresh failed but have access token, will try: " + String(e))
        if (!accessToken) throw e
      }
      if (refreshed) {
        accessToken = refreshed
      } else if (!accessToken) {
        ctx.host.log.error("refresh failed and no access token available")
        throw "Not logged in. " + LOGIN_HINT
      }
    }

    const usage = fetchRequestBasedUsage(ctx, accessToken)
    if (!usage) {
      throw "Cursor usage data unavailable. Try again later."
    }

    const gpt4 = usage["gpt-4"]
    if (!gpt4 || typeof gpt4.maxRequestUsage !== "number") {
      throw "Usage data format invalid."
    }

    const totalRequests = gpt4.numRequestsTotal || gpt4.numRequests || 0
    const limit = gpt4.maxRequestUsage
    const remaining = Math.max(0, limit - totalRequests)

    let billingPeriodMs = 30 * 24 * 60 * 60 * 1000
    let cycleStart = null
    let cycleEndMs = null

    if (usage.startOfMonth) {
      cycleStart = ctx.util.parseDateMs(usage.startOfMonth)
      if (cycleStart) {
        cycleEndMs = cycleStart + billingPeriodMs
      }
    }

    const lines = []
    lines.push(ctx.line.progress({
      label: "Requests",
      used: totalRequests,
      limit: limit,
      format: { kind: "count", suffix: "requests" },
      resetsAt: ctx.util.toIso(cycleEndMs),
      periodDurationMs: billingPeriodMs,
    }))

    return { plan: null, lines: lines }
  }

  globalThis.__openusage_plugin = { id: "cursor", probe }
})()
