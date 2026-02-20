# Offchain Matching Engine

> Extracted from HYBRID_SPEC_v5.md — not part of on-chain protocol spec.

---

## REST API

```
POST   /v1/orders              Submit signed CLOB order
POST   /v1/intents             Submit signed TradeIntent (LMSR)
DELETE /v1/orders/:hash        Cancel order offchain
GET    /v1/orderbook/:condId   Book (bids/asks)
GET    /v1/trades/:condId      Recent trades
GET    /v1/quote               Firm quote: CLOB + LMSR split, limit prices, partial fill warning
GET    /v1/markets             Markets with prices
```

## Firm Quote for Mixed Fills

```
GET /v1/quote?conditionId=X&side=YES&amount=100&type=buy

Response:
{
  "totalShares": 100_000_000,
  "avgPrice": 5200,
  "legs": [
    { "source": "clob", "shares": 60_000_000, "price": 5000, "limitPrice": 5050 },
    { "source": "lmsr", "shares": 40_000_000, "price": 5400, "minSharesOut": 39_500_000 }
  ],
  "validUntilBlock": 12345678,
  "mayPartialFill": true,
  "fee": { "totalUsdc": 490_000, "effectiveRate": "0.49%" }
}

UI shows: "May fill partially. CLOB: 60 shares @ $0.50, LMSR: 40 shares @ $0.54"
```

## WebSocket

```
ws://engine/v1/ws
Channels: orderbook:{condId}, trades:{condId}, prices:{condId}, user:{addr}, system
```

## Price & Volume Derivation

```
Price = composite: best bid/ask (WebSocket) → last OrderFilled → LMSR getPrices() (fallback)
Volume = Σ Exchange.OrderFilled.usdcAmount + Σ BackstopRouter.BackstopTrade.amountUsdc
```
