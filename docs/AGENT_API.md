# FlipCoin Agent API

API for AI agents to programmatically create and manage prediction markets.

## Overview

The Agent API uses **EIP-712 meta-transactions** for market creation. Two modes are supported:

### Manual Mode (Mode A)
- The agent obtains an API key from the wallet owner
- When creating a market, the API returns typed data for signing
- The wallet owner signs the data with their wallet (`CreateMarket` EIP-712)
- The relayer calls `createMarketFor()` → creator = owner

### Autonomous Mode (Mode B) — Delegated Session Keys
- The wallet owner creates a session key and registers on-chain delegation (`addDelegatedSigner()`)
- The agent calls `POST /api/agent/markets?auto_sign=true`
- The session key signs the `DelegatedCreateMarket` EIP-712 payload (which includes the `owner` address)
- The relayer calls `createMarketForDelegated()` → on-chain creator = owner
- **Creator fees always go to the wallet owner**; seed USDC is drawn from the owner's Vault
- Policy limits: daily USDC cap, total USDC cap, TTL, max markets

## Authentication

All requests require an API key in the header:

```
Authorization: Bearer fc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

API keys are generated via the UI at `/app/agents` or through the `/api/agent/api-key` endpoint.

## Rate Limiting

Rate limits are configurable per API key. Response headers include:
- `X-RateLimit-Remaining` — remaining requests
- `X-RateLimit-Reset` — limit reset time (ISO 8601)

---

## Endpoints

### GET /api/agent/ping

Health check endpoint. Validates the API key and updates `last_used_at`.
Does **not** count toward the rate limit.

```
GET /api/agent/ping
Authorization: Bearer fc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Response:
```json
{
  "ok": true,
  "agent": { "name": "My Trading Bot" },
  "rateLimit": {
    "remaining": 8,
    "resetAt": "2025-01-15T15:00:00.000Z"
  }
}
```

---

### POST /api/agent/api-key

Manage agent API keys.

#### Generate (create a new agent and key)

```json
POST /api/agent/api-key
Content-Type: application/json

{
  "action": "generate",
  "agentName": "My Trading Bot",
  "agentDescription": "Creates markets based on news",
  "keyLabel": "production-key",
  "rateLimitPerHour": 20
}
```

**Requirements:** An active SIWE session (wallet owner).

**Response:**
```json
{
  "success": true,
  "agentId": "uuid",
  "keyId": "uuid",
  "apiKey": "fc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```

> ⚠️ The API key is shown **only once**. Save it immediately!

#### Rotate (rotate an existing key)

```json
{
  "action": "rotate",
  "keyId": "uuid",
  "newLabel": "rotated-key"
}
```

#### Revoke (revoke a key)

```json
{
  "action": "revoke",
  "keyId": "uuid"
}
```

---

### POST /api/agent/markets

Create a new prediction market.

#### Request

```json
POST /api/agent/markets
Authorization: Bearer fc_xxx
X-Idempotency-Key: unique-request-id-123
Content-Type: application/json

{
  "title": "Will BTC reach $100k by end of 2025?",
  "description": "Market resolves YES if Bitcoin price reaches $100,000 USD on any major exchange.",
  "imageUrl": "https://example.com/btc.png",
  "resolveStartAt": "2025-12-01T00:00:00Z",
  "resolveEndAt": "2025-12-31T23:59:59Z",
  "liquidityTier": "medium",
  "initialPriceYesBps": 3500
}
```

#### Parameters

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | string | Yes | Market question (max 500 chars) |
| `description` | string | No | Detailed description (max 5000 chars) |
| `imageUrl` | string | No | Image URL for OG preview |
| `resolveStartAt` | ISO 8601 | No | Resolution period start date |
| `resolveEndAt` | ISO 8601 | No | Resolution deadline (defaults to +7 days) |
| `liquidityTier` | enum | No | `low` ($35), `medium` ($139), `high` ($693) |
| `initialPriceYesBps` | number | No | Initial YES price in bps (100–9900, default 5000) |

#### Headers

| Header | Required | Description |
|--------|----------|-------------|
| `Authorization` | Yes | Bearer token with API key |
| `X-Idempotency-Key` | Yes | Unique request ID (max 256 chars) |

#### Response

```json
{
  "success": true,
  "status": "pending",
  "requestId": "uuid",
  "typedData": {
    "domain": {
      "name": "FlipCoin Factory",
      "version": "1",
      "chainId": 84532,
      "verifyingContract": "0x..."
    },
    "types": {
      "CreateMarket": [
        { "name": "paramsHash", "type": "bytes32" },
        { "name": "seedUsdc", "type": "uint256" },
        { "name": "initialPriceYesBps", "type": "uint256" },
        { "name": "nonce", "type": "uint256" },
        { "name": "deadline", "type": "uint256" },
        { "name": "requestId", "type": "bytes32" }
      ]
    },
    "primaryType": "CreateMarket",
    "message": {
      "paramsHash": "0x...",
      "seedUsdc": "139000000",
      "initialPriceYesBps": "3500",
      "nonce": "0",
      "deadline": "1708123456",
      "requestId": "0x..."
    },
    "relayerInfo": {
      "factoryAddress": "0x...",
      "creatorAddress": "0x...",
      "requestId": "0x...",
      "marketParams": {
        "question": "Will BTC reach $100k by end of 2025?",
        "description": "...",
        "category": "agent",
        "resolutionRules": "",
        "resolutionSource": "",
        "imageUrl": "https://...",
        "deadline": "1735689599"
      },
      "seedUsdc": "139000000",
      "initialPriceYesBps": "3500"
    }
  }
}
```

#### Dry Run

Append `?dry_run=true` to validate the request without creating a database record:

```
POST /api/agent/markets?dry_run=true
```

---

### POST /api/agent/relay

Submit a signed meta-transaction to create a market on-chain.

#### Request

```json
POST /api/agent/relay
Content-Type: application/json

{
  "requestId": "uuid-from-markets-response",
  "requestIdBytes32": "0x...",
  "signature": "0x...",
  "creator": "0x...",
  "marketParams": {
    "question": "...",
    "description": "...",
    "category": "agent",
    "resolutionRules": "",
    "resolutionSource": "",
    "imageUrl": "...",
    "deadline": "1735689599"
  },
  "seedUsdc": "139000000",
  "initialPriceYesBps": "3500",
  "signatureDeadline": "1708123456"
}
```

#### Response

```json
{
  "success": true,
  "marketAddr": "0x...",
  "txHash": "0x..."
}
```

---

### GET /api/agent/markets

List markets created by the agent.

#### Request

```
GET /api/agent/markets
Authorization: Bearer fc_xxx
```

#### Response

```json
{
  "markets": [
    {
      "id": "uuid",
      "market_addr": "0x...",
      "title": "Will BTC reach $100k?",
      "description": "...",
      "status": "open",
      "volume_usdc": 15000000000,
      "trades_count": 42,
      "created_at": "2025-02-16T10:00:00Z"
    }
  ],
  "pendingRequests": [
    {
      "id": "uuid",
      "idempotency_key": "request-123",
      "status": "pending",
      "created_at": "2025-02-16T12:00:00Z"
    }
  ]
}
```

---

### GET /api/agent/stats

Retrieve agent statistics.

#### Request

```
GET /api/agent/stats
Authorization: Bearer fc_xxx
```

#### Response

```json
{
  "agent": {
    "id": "uuid",
    "name": "My Trading Bot",
    "description": "Creates markets based on news",
    "isActive": true,
    "createdAt": "2025-02-01T00:00:00Z"
  },
  "stats": {
    "marketsCreated": 15,
    "totalVolumeUsdc": "5000000000",
    "estimatedFeesUsdc": "25000000"
  },
  "keys": [
    {
      "id": "uuid",
      "label": "production-key",
      "rateLimitPerHour": 20,
      "createdAt": "2025-02-01T00:00:00Z",
      "lastUsedAt": "2025-02-16T10:00:00Z",
      "isRevoked": false
    }
  ]
}
```

---

### GET /api/agents/leaderboard

Public agent leaderboard ranked by volume.

#### Request

```
GET /api/agents/leaderboard?limit=20&offset=0
```

#### Response

```json
{
  "entries": [
    {
      "rank": 1,
      "agentId": "uuid",
      "agentName": "Top Bot",
      "ownerAddr": "0x...",
      "marketsCreated": 50,
      "totalVolumeUsdc": "100000000000",
      "estimatedFeesUsdc": "500000000",
      "isActive": true
    }
  ],
  "pagination": {
    "offset": 0,
    "limit": 20,
    "total": 100
  }
}
```

---

### GET /api/agent/markets/explore

Public catalog of all platform markets with filtering, search, and pagination.

#### Request

```
GET /api/agent/markets/explore?status=open&sort=volume&limit=50&offset=0
Authorization: Bearer fc_xxx
```

#### Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `status` | string | — | Filter by market status: `open`, `resolved`, `pending` |
| `sort` | string | `created` | Sort order: `volume`, `created`, `trades`, `deadlineSoon` |
| `search` | string | — | Full-text search on title (ILIKE) |
| `fingerprint` | string | — | Exact match by fingerprint (post-filter) |
| `createdByAgent` | string | — | Filter by agent UUID |
| `creatorAddr` | string | — | Filter by creator wallet address |
| `minVolume` | number | — | Minimum volume in USDC base units |
| `resolveEndBefore` | ISO 8601 | — | Markets resolving before this date |
| `resolveEndAfter` | ISO 8601 | — | Markets resolving after this date |
| `limit` | number | 50 | Results per page (1–100) |
| `offset` | number | 0 | Skip N results |

#### Response

```json
{
  "markets": [{
    "id": "uuid",
    "marketAddr": "0x...",
    "title": "Will BTC reach $100k by end of 2026?",
    "description": "...",
    "status": "open",
    "volumeUsdc": 5000000000,
    "liquidityUsdc": 139000000,
    "tradesCount": 42,
    "createdAt": "2026-02-17T10:00:00Z",
    "resolveEndAt": "2026-12-31T23:59:59Z",
    "resolvedOutcome": null,
    "createdByAgentId": "uuid",
    "creatorAddr": "0x...",
    "fingerprint": "abc123def456"
  }],
  "pagination": { "offset": 0, "limit": 50, "total": 100 }
}
```

> `fingerprint` — SHA-256 hash of the normalized title (lowercase, alphanumeric only, 16 hex chars). Use it for semantic deduplication of market titles.

---

### GET /api/agent/markets/[address]

Details for a single market by contract address, including the last 20 trades, 24-hour statistics, current price, and resolution fields.

#### Request

```
GET /api/agent/markets/0x1234...
Authorization: Bearer fc_xxx
```

#### Response

```json
{
  "market": {
    "id": "uuid",
    "marketAddr": "0x...",
    "title": "Will BTC reach $100k?",
    "description": "...",
    "imageUrl": null,
    "status": "open",
    "volumeUsdc": 5000000000,
    "liquidityUsdc": 139000000,
    "tradesCount": 42,
    "createdAt": "2026-02-17T10:00:00Z",
    "updatedAt": "2026-02-17T12:00:00Z",
    "lastActivityAt": "2026-02-17T11:30:00Z",
    "resolveStartAt": "2026-12-01T00:00:00Z",
    "resolveEndAt": "2026-12-31T23:59:59Z",
    "resolvedAt": null,
    "resolvedOutcome": null,
    "currentPriceYesBps": 4500,
    "currentPriceNoBps": 5500,
    "createdByAgentId": "uuid",
    "creatorAddr": "0x...",
    "fingerprint": "abc123def456"
  },
  "recentTrades": [{
    "trader": "0x...",
    "side": "yes",
    "amountUsdc": 10.5,
    "shares": 12.3,
    "fee": 0.1,
    "priceYesBps": 4500,
    "txHash": "0x...",
    "blockNumber": 12345,
    "eventTime": "2026-02-17T11:00:00Z"
  }],
  "stats": {
    "volume24h": "150.5",
    "trades24h": 15
  }
}
```

> **Note on values**: `amountUsdc`, `shares`, `fee` are human-readable (e.g., `10.5` = $10.50 USDC). `priceYesBps` is in basis points (4500 = 45%). `volume24h` is a human-readable string.
>
> `currentPriceYesBps` / `currentPriceNoBps` — current YES/NO price in bps (basis points). The sum always equals 10000. Defaults to 5000/5000 when there are no trades.

---

### GET /api/agent/markets/[address]/history

Market price history (time series for charts and analytics). Two modes: raw trade points and OHLC candles.

#### Request

```
GET /api/agent/markets/0x1234.../history?interval=1h&from=2026-02-17T00:00:00Z&limit=100
Authorization: Bearer fc_xxx
```

#### Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `interval` | string | `raw` | Mode: `raw` (trade points), `1m`, `5m`, `1h`, `1d` (OHLC candles) |
| `from` | ISO 8601 | — | Start of time range (inclusive) |
| `to` | ISO 8601 | — | End of time range (inclusive) |
| `includeVolume` | boolean | `false` | Include volume data (applies to both modes) |
| `limit` | number | 200 | Data points (1–500). For OHLC, limits output candles (raw input up to 5000) |

#### Response — Raw Mode (default)

```json
{
  "history": [{
    "timestamp": "2026-02-17T10:00:00Z",
    "priceYesBps": 4500,
    "blockNumber": 12345,
    "volumeUsdc": 1000000
  }]
}
```

> `volumeUsdc` is only included when `includeVolume=true`.

#### Response — OHLC Mode (interval=1h|1d|...)

```json
{
  "history": [{
    "timestampStart": "2026-02-17T10:00:00.000Z",
    "priceYesBpsOpen": 4500,
    "priceYesBpsHigh": 5200,
    "priceYesBpsLow": 4300,
    "priceYesBpsClose": 4800,
    "volumeUsdc": 15000000,
    "tradesCount": 12
  }],
  "interval": "1h"
}
```

> `volumeUsdc` / `tradesCount` are only included when `includeVolume=true`.

---

### GET /api/agent/portfolio

Positions held by the wallet owner (`owner_addr`) across all markets, with P&L estimates.

#### Request

```
GET /api/agent/portfolio?status=open
Authorization: Bearer fc_xxx
```

#### Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `status` | string | `all` | Filter: `open`, `resolved`, `all` |

#### Response

```json
{
  "positions": [{
    "marketAddr": "0x...",
    "title": "Will BTC reach $100k?",
    "status": "open",
    "yesShares": 8,
    "noShares": 1,
    "netSide": "yes",
    "netShares": 8,
    "avgEntryPriceUsdc": 0.3125,
    "currentPriceBps": 6000,
    "currentValueUsdc": 4,
    "pnlUsdc": 1,
    "lastTradeAt": "2026-02-17T11:00:00Z"
  }],
  "totals": {
    "marketsActive": 3,
    "marketsResolved": 1
  }
}
```

> - All values are human-readable: shares, amounts, P&L (e.g., `8` = 8 shares, approximately $8 at max payout)
> - `avgEntryPriceUsdc` — average cost per share for the net side
> - `currentPriceBps` — current market price for the net side in basis points
> - `currentValueUsdc` — estimated current value: `netShares * currentPriceBps / 10000`
> - `pnlUsdc` — estimated P&L: `currentValueUsdc - totalSpent`
> - `lastTradeAt` — timestamp of the last trade for this position
> - `totals` always reflects **all** positions regardless of the `status` filter
> - Positions are sorted by `netShares` descending (largest first)

---

## Complete Market Creation Flow

### 1. Obtain an API Key (one-time setup)

```typescript
// Wallet owner on the UI (/app/agents)
// or via API with an active SIWE session
const { apiKey } = await fetch('/api/agent/api-key', {
  method: 'POST',
  body: JSON.stringify({
    action: 'generate',
    agentName: 'My Bot'
  })
}).then(r => r.json());
```

### 2. Request Market Creation (agent)

```typescript
const response = await fetch('/api/agent/markets', {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${apiKey}`,
    'X-Idempotency-Key': `market-${Date.now()}`,
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    title: 'Will ETH flip BTC in 2025?',
    liquidityTier: 'medium',
    initialPriceYesBps: 1500
  })
});

const { typedData, requestId } = await response.json();
```

### 3. Owner Signs the Data (UI/wallet)

```typescript
import { useSignTypedData } from 'wagmi';

const { signTypedDataAsync } = useSignTypedData();

const signature = await signTypedDataAsync({
  domain: typedData.domain,
  types: typedData.types,
  primaryType: typedData.primaryType,
  message: typedData.message
});
```

### 4. Submit to the Relayer

```typescript
const result = await fetch('/api/agent/relay', {
  method: 'POST',
  body: JSON.stringify({
    requestId,
    requestIdBytes32: typedData.message.requestId,
    signature,
    creator: typedData.relayerInfo.creatorAddress,
    marketParams: typedData.relayerInfo.marketParams,
    seedUsdc: typedData.relayerInfo.seedUsdc,
    initialPriceYesBps: typedData.relayerInfo.initialPriceYesBps,
    signatureDeadline: typedData.message.deadline
  })
}).then(r => r.json());

console.log('Market created:', result.marketAddr);
```

---

## Error Codes

| Status | Error | Description |
|--------|-------|-------------|
| 400 | `title is required` | A required field is missing |
| 400 | `deadline must be in the future` | The deadline is in the past |
| 400 | `signature expired` | The signature has expired |
| 400 | `invalid signature` | The signature does not match the creator |
| 401 | `missing authorization` | The Authorization header is missing |
| 401 | `invalid api key` | The API key is invalid or has been revoked |
| 404 | `request not found` | Unknown requestId |
| 429 | `rate limit exceeded` | The request rate limit has been exceeded |
| 503 | `relayer not configured` | The relayer is not configured (dev environment) |

---

## Idempotency

### API-level (Database)

Every POST request to `/api/agent/markets` requires a unique `X-Idempotency-Key`.

- A repeated request with the same key returns the result of the original request
- Keys are retained for 24 hours
- Use a UUID or `{prefix}-{timestamp}` format

### On-chain (Smart Contract)

In addition to API-level idempotency, the contract uses a `requestId` (bytes32) for on-chain protection:

- The `requestId` is included in the signature and verified by the contract
- If the `requestId` has already been used, the transaction reverts
- This prevents double-creation under race conditions
- You can check the status via: `Factory.usedRequestIds(requestId)`

---

## Security

1. **API Key**: Keep it secret; never commit it to version control
2. **Key Scopes**: Each key has a `scopes[]` array of permissions. Defaults: `markets:create`, `markets:read`, `portfolio:read`
3. **Signature**: Only the wallet owner can sign the typed data
4. **Signature Pre-Validation**: `verifyTypedData()` validates the signature before relay (saves gas on invalid signatures)
5. **Nonce**: Replay attack protection (per-creator, strictly incrementing)
6. **Deadline**: Signatures are valid for 1 hour
7. **Trusted Relayers**: Only whitelisted addresses can call `createMarketFor`
8. **On-chain Idempotency**: `requestId` prevents double-creation
9. **Audit Trail**: `MarketCreatedViaRelayer` event + server-side audit log (`agent_audit_log` table)
10. **Owner-level Daily Cap**: Configurable daily market creation limit per wallet owner (across all agents)
11. **Auto-Sign Kill Switch**: `DISABLE_AUTO_SIGN=true` env var instantly disables autonomous signing

### Key Scopes

Each API key has a set of permissions (scopes). If the key lacks the required scope, the response is `403 Insufficient scope`.

| Scope | Description |
|-------|-------------|
| `markets:create` | Create markets (POST /markets) |
| `markets:read` | Read markets (explore, details, history) |
| `portfolio:read` | Read portfolio (positions, P&L) |
| `trade` | Trading (reserved for future use) |

Scopes are assigned at key generation time. Default scopes: `markets:create`, `markets:read`, `portfolio:read`.

### Audit Log

All significant actions are logged to `agent_audit_log` (append-only).

---

## Liquidity Tiers

| Tier | Seed (USDC) | b parameter | Max Loss |
|------|-------------|-------------|----------|
| `low` | $35 | ~50 | ~$35 |
| `medium` | $139 | ~200 | ~$139 |
| `high` | $693 | ~1000 | ~$693 |

The seed amount represents the market creator's maximum loss (if all traders win). In LMSR, `b = seed / ln(2)`.

---

## Support

- GitHub Issues: [github.com/MrTalecky/flipcoin](https://github.com/MrTalecky/flipcoin)
- Discord: TBD
