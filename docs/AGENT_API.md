# FlipCoin Agent API

API for AI agents to programmatically create and manage prediction markets.

For the on-chain Factory contract specification, see [HYBRID_SPEC_v5.md](HYBRID_SPEC_v5.md) §9.
For delegation and spend limits, see [HYBRID_SPEC_v5.md](HYBRID_SPEC_v5.md) §5.

## Overview

The Agent API uses **EIP-712 meta-transactions** for market creation. Two modes are supported:

### Manual Mode (Mode A)
- The agent obtains an API key from the wallet owner
- When creating a market, the API returns typed data for signing
- The wallet owner signs the data with their wallet (`CreateMarket` EIP-712)
- The relayer calls `createMarketFor()` → creator = owner

### Autonomous Mode (Mode B) — Delegated Session Keys
- The wallet owner creates a session key and registers on-chain delegation via `DelegationRegistry`
- The agent calls `POST /api/agent/markets?auto_sign=true`
- The session key signs the `DelegatedCreateMarket` EIP-712 payload (which includes the `owner` address in the signed data — preventing fee redirection)
- The relayer calls `createMarketForDelegated()` → on-chain creator = owner
- **Creator fees always go to the wallet owner**; seed USDC is drawn from the owner's Vault balance
- Policy limits enforced on-chain by DelegationRegistry (see §Delegation Policy)

> **Owner Liability**: The wallet owner bears full financial responsibility for all markets
> created via delegated session keys. Seed USDC is drawn from their Vault balance,
> and the owner must ensure adequate delegation policy limits.

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

## EIP-712 Typed Data

### CreateMarket (Mode A — owner signs directly)

```solidity
bytes32 constant CREATE_MARKET_TYPEHASH = keccak256(
    "CreateMarket(bytes32 paramsHash,uint256 seedUsdc,uint256 initialPriceYesBps,"
    "uint256 nonce,uint256 deadline,bytes32 requestId)"
);
```

Domain: `{ name: "FlipCoinFactory", version: "1", chainId, verifyingContract: factoryAddress }`

### DelegatedCreateMarket (Mode B — session key signs on behalf of owner)

```solidity
bytes32 constant DELEGATED_CREATE_TYPEHASH = keccak256(
    "DelegatedCreateMarket(bytes32 paramsHash,uint256 seedUsdc,uint256 initialPriceYesBps,"
    "uint256 nonce,uint256 deadline,bytes32 requestId,address owner)"
);
```

Same domain as Mode A (same Factory contract).

**Key difference**: `DelegatedCreateMarket` includes `owner` in the signed data.
This prevents a compromised session key from redirecting creator fees to a different address.
The two typehashes are structurally different, so a `CreateMarket` signature cannot be
replayed in the `DelegatedCreateMarket` context (and vice versa).

### Nonce Model

```
Factory.nonces: mapping(address => uint256)  // per-signer, strictly incrementing
```

**Mode A**: `nonces[creator]` — the owner's nonce, incremented on each `createMarketFor` call.
**Mode B**: `nonces[signer]` — the session key's nonce, incremented on each `createMarketForDelegated` call.

Each signer has an independent nonce counter. This means:
- Multiple session keys can operate concurrently without nonce conflicts
- Manual Mode A operations (owner signing) use a separate nonce from Mode B (session key signing)
- An owner's nonce and their session key's nonce are independent

### requestId (Idempotency)

```
API:      X-Idempotency-Key = uuid string (retained 24h)
On-chain: requestId = keccak256(abi.encodePacked(uuid)) → bytes32
```

Both layers use the same logical ID. The API stores the uuid string; the contract
stores `keccak256(uuid)` as `bytes32` in `Factory.usedRequestIds`. If the requestId
has already been used on-chain, the transaction reverts.

---

## Delegation Policy (Mode B)

On-chain enforcement via **DelegationRegistry** (see HYBRID_SPEC §5):

```
DelegationRegistry.delegations[owner][signer] = {
    active:              bool
    scope:               address(factory) or address(0) for all
    tokenScope:          0 (any market) — conditionId not known at creation time
    maxNotionalPerDay:   uint256 (USDC 6 dec) — max seed spend per rolling 24h
    maxMarketsPerDay:    uint256 — max market creations per rolling 24h
    spentToday:          uint256 — tracked by recordSpend()
    marketsCreatedToday: uint256 — tracked by recordMarketCreation()
    dayStart:            uint64 — rolling 24h window start
    expiresAt:           uint64 — delegation TTL (0 = no expiry)
}
```

**On-chain guarantees:**
- `maxNotionalPerDay`: caps total seed USDC the session key can spend per rolling 24h
- `maxMarketsPerDay`: caps number of markets created per rolling 24h
- `expiresAt`: delegation automatically becomes invalid after TTL
- `scope = factory`: restricts the key to market creation only (cannot trade or sign orders)

**Not enforced on-chain** (application-level policy):
- Allowed liquidity tiers (Low/Medium/High)
- Initial price range (min/max `initialPriceYesBps`)
- Maximum seed per individual market

The relayer validates application-level policies before submitting the transaction.

### Relayer Verification Steps

The relayer is NOT a simple proxy. Before submitting any transaction, it performs:

1. **`verifyTypedData()`** — validates the EIP-712 signature matches the claimed signer
2. **Nonce check** — verifies `nonce == Factory.nonces[signer]` (prevents stale signatures)
3. **requestId uniqueness** — checks `!Factory.usedRequestIds[requestId]`
4. **Delegation check** — verifies `DelegationRegistry.isAuthorized(owner, signer, factory, bytes32(0))`
5. **Policy validation** — checks application-level limits (allowed tiers, price range)
6. **Expiration check** — verifies `block.timestamp <= deadline`
7. **Balance check** — verifies owner has sufficient Vault balance for seed

If any check fails, the relayer returns an error without spending gas.

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

> The API key is shown **only once**. Save it immediately!

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
      "name": "FlipCoinFactory",
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

> For Mode B (`auto_sign=true`), the response uses `primaryType: "DelegatedCreateMarket"`
> with an additional `owner` field in the types and message.

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
>
> **Important**: `currentValueUsdc` and `pnlUsdc` are estimates based on the LMSR marginal price.
> Actual exit value depends on trade size and available liquidity. These values are NOT guaranteed
> redemption amounts.

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
| 403 | `insufficient scope` | The API key lacks the required scope |
| 404 | `request not found` | Unknown requestId |
| 429 | `rate limit exceeded` | The request rate limit has been exceeded |
| 503 | `relayer not configured` | The relayer is not configured (dev environment) |

---

## Security

### Authentication & Authorization

1. **API Key**: Keep it secret; never commit it to version control
2. **Key Scopes**: Each key has a `scopes[]` array of permissions (see below)
3. **Signature**: Only the wallet owner (Mode A) or delegated signer (Mode B) can sign
4. **Signature Pre-Validation**: `verifyTypedData()` validates before relay (saves gas on invalid signatures)
5. **Nonce**: Per-signer, strictly incrementing (prevents replay)
6. **Deadline**: Signatures are valid for 1 hour
7. **Trusted Relayers**: Only whitelisted addresses can call `createMarketFor` / `createMarketForDelegated`
8. **On-chain Idempotency**: `requestId` prevents double-creation
9. **Audit Trail**: `MarketCreatedViaRelayer` event + `agent_audit_log` table (append-only)
10. **Auto-Sign Kill Switch**: `DISABLE_AUTO_SIGN=true` env var instantly disables autonomous signing

### Key Scopes

| Scope | Description |
|-------|-------------|
| `markets:create` | Create markets (POST /markets) |
| `markets:read` | Read markets (explore, details, history) |
| `portfolio:read` | Read portfolio (positions, P&L) |
| `trade` | Trading (reserved for future use) |

Scopes are assigned at key generation time. Default scopes: `markets:create`, `markets:read`, `portfolio:read`.

### Threat Model

| Threat | Mitigation |
|--------|-----------|
| **Compromised API key** | API key grants request creation only, not signing. Attacker cannot create markets without a valid EIP-712 signature. Revoke immediately via `/api/agent/api-key` (action: revoke). |
| **Compromised session key** | On-chain limits (maxNotionalPerDay, maxMarketsPerDay, expiresAt) bound the damage. Owner revokes delegation via `DelegationRegistry.revokeDelegation()`. Kill switch `DISABLE_AUTO_SIGN=true` halts all autonomous signing. |
| **Malicious relayer** | Relayer can only submit pre-signed transactions — cannot forge signatures, alter parameters, or redirect fees. On-chain signature verification is the trust anchor. |
| **Signature replay** | Per-signer nonce (strictly incrementing) + requestId uniqueness + 1h deadline + DOMAIN_SEPARATOR (chainId + contract address) |
| **Cross-mode replay** | `CreateMarket` and `DelegatedCreateMarket` have different typehashes — signatures are not interchangeable |
| **Nonce race condition** | Per-signer (not per-owner) nonces prevent Mode A / Mode B conflicts. Multiple session keys operate independently. |
| **Fee redirection (Mode B)** | `DelegatedCreateMarket` includes `owner` in signed data. Creator fees are immutably set to `owner` by Factory. |

---

## Liquidity Tiers

| Tier | b (SD59x18) | Seed (USDC) | Max Loss |
|------|-------------|-------------|----------|
| `low` | 50 * 1e18 | $35 | $34.66 |
| `medium` | 200 * 1e18 | $139 | $138.63 |
| `high` | 1000 * 1e18 | $693 | $693.15 |

`b` is the LMSR liquidity parameter (fixed per tier). Seed = `ceil(b * ln(2))`.
See [LMSR_SPEC.md](LMSR_SPEC.md) §1.5 and §8 for the mathematical foundation.

---

## Gas Estimates

| Operation | Estimated Gas | Notes |
|-----------|--------------|-------|
| `createMarketFor` (Mode A) | ~250k | EIP-1167 clone + init + register |
| `createMarketForDelegated` (Mode B) | ~280k | Same + delegation check + recordSpend |

Gas is paid by the relayer. The protocol does not currently reimburse relayer gas from fees.

---

## Support

- GitHub Issues: [github.com/flipcoin-fun/flipcoin-protocol](https://github.com/flipcoin-fun/flipcoin-protocol)
- Discord: TBD
