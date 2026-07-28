# Grok

Tracks Grok weekly SuperGrok / GrokBuild usage (same pool as the Grok CLI TUI).

## Data sources

1. **Grok CLI OAuth** (`~/.grok/auth.json`) — preferred  
   Access token + refresh token from `grok login`.
2. **Environment variables** — `GROK_API_KEY` or `XAI_API_KEY` (Bearer token).
3. **HTML scrape fallback** — `https://grok.com/?_s=usage` (RSC-escaped `createTime`).

> OpenUsage `host.http` does **not** inject browser cookies. Use CLI OAuth.

## API endpoints

| Endpoint | Purpose |
| --- | --- |
| `POST https://auth.x.ai/oauth2/token` | Refresh access token |
| `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` | **Primary** — weekly usage % + period window (same as Grok CLI) |
| `GET https://grok.com/rest/subscriptions` | Fallback — subscription `createTime` for reset |
| `GET https://grok.com/?_s=usage` | HTML fallback |

### Billing credits response (authoritative for usage)

```json
{
  "config": {
    "currentPeriod": {
      "type": "USAGE_PERIOD_TYPE_WEEKLY",
      "start": "2026-07-28T02:14:58.226666+00:00",
      "end": "2026-08-04T02:14:58.226666+00:00"
    },
    "creditUsagePercent": 1.0,
    "productUsage": [{ "product": "GrokBuild", "usagePercent": 1.0 }],
    "prepaidBalance": { "val": 0 },
    "isUnifiedBillingUser": true
  }
}
```

## Mapping

| OpenUsage field | Source |
| --- | --- |
| SuperGrok `used` | `config.creditUsagePercent` (0–100) → percent progress |
| SuperGrok `resetsAt` | `config.currentPeriod.end` (preferred); else `createTime` rolled by 7 days |
| SuperGrok `periodDurationMs` | `604_800_000` (7-day weekly window) |
| Extra usage spent | `config.prepaidBalance.val` when > 0 |

### Why usage was stuck at 100% left

Previously the plugin only read `/rest/subscriptions` (no usage fields) and defaulted `used_fraction` to `0` → UI showed **100% left**.  

Grok CLI reads `cli-chat-proxy…/billing?format=credits` → `creditUsagePercent` (e.g. `1` = 1% used → **99% left**).

## Auth errors

- Missing credentials → `Not logged in. Sign in via Grok CLI (~/.grok/auth.json) or set GROK_API_KEY.`
- Expired session → `Grok session expired. Run Grok CLI login again.`
