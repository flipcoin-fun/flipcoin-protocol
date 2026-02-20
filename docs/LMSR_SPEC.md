# LMSR AMM Specification

> Mathematical foundations and economic model for the LMSR (Logarithmic Market Scoring Rule)
> backstop AMM used in FlipCoin v2. For contract interfaces and integration details,
> see [HYBRID_SPEC_v5.md](HYBRID_SPEC_v5.md) §6–§8.

---

## 0. Motivation: Limitations of CPMM Under Low Seed

### 0.1 Problem

In FlipCoin v1, the CPMM (constant product market maker) produces extreme slippage with small
seed capital ($10–$50). A user investing $60 into a $10-seeded market receives ~15 shares;
even when winning, the payout is only $15 — a $45 loss.

This is a mathematical property of constant-product AMMs, not a bug:
with small reserves, price impact is extreme.

### 0.2 Root Causes (specific to FlipCoin v1 implementation)

**1. Creator receives shares on both sides at initialization**

```
yesSharesTotal = seedUsdc;   // creator's initial issuance
noSharesTotal = seedUsdc;
yesShares[creator] = seedUsdc;
noShares[creator] = seedUsdc;
```

The creator's large initial position dilutes all subsequent traders.
On resolution, `payoutPerShare = usdcPool / winningSharesTotal` is low
because `winningSharesTotal` includes the creator's shares.

**2. CPMM pricing mixed with pari-mutuel settlement**

CPMM implies "1 share ≈ $1 on win" (marginal pricing), but pari-mutuel
settlement computes `payoutPerShare = usdcPool / totalShares`. These models
are incompatible: the CPMM purchase price has no relation to the actual payout.

### 0.3 Why LMSR

LMSR solves both problems:
1. **Fixed payout**: each winning share pays exactly $1 (no pari-mutuel)
2. **Bounded loss**: the creator knows max loss upfront: `b * ln(2)`
3. **No initial token issuance**: seed funds the backstop, not the creator's position
4. **Logarithmic slippage**: predictable, not exponential

---

## 1. LMSR Mathematics

### 1.1 Cost Function

```
C(qYes, qNo) = b * ln(e^(qYes/b) + e^(qNo/b))
```

Where:
- `qYes`, `qNo` — cumulative shares sold per side (SD59x18, signed)
- `b` — liquidity parameter (SD59x18, controls market depth)
- `C` — total cost of all shares sold (in USDC after conversion)

### 1.2 Purchase Cost

```
cost(delta) = C(qYes + delta, qNo) - C(qYes, qNo)
```

To buy `delta` YES shares, the user pays `cost(delta)` USDC.

### 1.3 Price (Sigmoid)

```
P(yes) = 1 / (1 + e^(-(qYes - qNo) / b))
P(no)  = 1 - P(yes)
```

Price is always in (0, 1). In basis points: 1–9999.

### 1.4 Units Convention

```
┌──────────────────────────────────────────────────────────────────┐
│ USDC:     1 USDC = 1_000_000 (6 decimals)                        │
│ Shares:   1 share = 1_000_000 (6 decimals, $1 face value)        │
│ q values: SD59x18 = shares * SCALE_6_TO_18                       │
│           1 share (1e6) → deltaQ = 1e6 * 1e12 = 1e18 (1.0 SD)   │
│ b:        SD59x18 (e.g. 100e18 = $100 liquidity depth)           │
│ Price:    basis points, 1–9999 (5000 = $0.50)                    │
│                                                                    │
│ SCALE_6_TO_18 = 1e12  (converts 6-decimal values to 18-decimal)  │
│                                                                    │
│ Invariant: 1 winning share always redeems for exactly 1 USDC     │
│            (1_000_000 units → 1_000_000 units)                    │
└──────────────────────────────────────────────────────────────────┘
```

### 1.5 The `b` Parameter

`b` controls market depth:
- Small `b` ($10–$50): high price sensitivity, low max loss
- Large `b` ($1000+): stable price, requires large trades to move

Maximum market maker loss:
```
max_loss = b * ln(2) ≈ 0.693 * b
```

Example: `b = $100` → max loss ≈ $69.3

### 1.6 LMSR vs CPMM Comparison

| Property | CPMM (v1) | LMSR (v2) |
|----------|-----------|-----------|
| Slippage | Exponential | Logarithmic |
| Max loss for seed provider | Unbounded | Bounded: `b * ln(2)` |
| Payout per share | Variable (pari-mutuel) | Fixed $1 |
| Initial token issuance | Minted to creator | None |
| Price range | Asymptotic to 0/1 | Always (0, 1) strictly |

---

## 2. Economic Model

### 2.1 Seed as Backstop Collateral

The market creator deposits `seedUsdc` when creating the market.
This seed funds the LMSR backstop — it is real collateral locked in the Vault,
not "virtual liquidity."

No initial outcome tokens are minted to the creator. Token supply starts at 0.
The seed covers the worst-case LMSR loss.

**Minimum seed:**
```
seedUsdc >= b * ln(2) ≈ 0.693 * b
```

> **Note**: NOT `seedUsdc >= b` (that would overestimate the requirement by 44%).

### 2.2 Cost Invariant (via baseCost)

```
effectiveCollateral >= C(qYes, qNo) - baseCost
```

Where:
- `effectiveCollateral` = market's available USDC in Vault (excluding accumulated fees)
- `C(qYes, qNo)` = current LMSR cost
- `baseCost` = `C(qYes0, qNo0)` = cost at initialization (with initial price bias)

**Why baseCost instead of C(0, 0)?**

With initial price bias (starting price ≠ 50%), the initial `qYes0` and `qNo0` are non-zero.
`C(0, 0) = b * ln(2)` is only the special case for 50/50. `baseCost` is the universal
baseline for any initial price.

### 2.3 Collateralization (v2 Model)

In v2, shares are ERC-1155 tokens managed by ShareToken. Collateral is tracked
in the Vault via three separate buckets (see HYBRID_SPEC §8):

```
Vault.splitReserve   — USDC backing outstanding YES+NO token pairs
Vault.balances[addr] — per-address ledger balances
Vault.feePool        — accumulated protocol + creator fees
```

The global invariant:
```
USDC.balanceOf(vault) >= totalBalances + splitReserve + feePool
```

For the LMSR specifically, the cost invariant ensures that the market's
Vault balance plus splitReserve always covers the maximum payout liability.

**Pre-resolution**: `splitReserve` covers all minted token pairs at $1 per pair.
Since `yesSupply == noSupply` (split/merge invariant), max payout = max(yesSupply, noSupply) = yesSupply.

**Post-resolution**: winning tokens redeem via `ShareToken.redeemPositions()`.
Vault releases from `splitReserve` to the redeemer. See HYBRID_SPEC §3 and §10.

### 2.4 Max Loss Scenario

```
Start: qYes = 0, qNo = 0, price = 50%
b = $100, seed = $70 (covers max_loss of $69.3)

Traders buy YES en masse:
- qYes increases, price → 99%
- Each buy: user pays USDC → Vault → splitPosition mints YES+NO pair
- LMSR inventory accumulates NO tokens, sells YES to buyer

Market resolves as YES:
- All YES holders redeem $1 per share via ShareToken
- LMSR's NO inventory is worthless
- Creator's seed covered the LMSR loss

Result for creator:
- Maximum loss = $69.3 (if all capital flows to YES)
- Seed covered the loss
- After resolution: creator withdraws remaining seed + accumulated fees
```

---

## 3. v2 Integration: ERC-1155 Inventory Model

### 3.1 Architecture

In v2, MarketLMSR does **NOT** store user balances. The architecture is:

```
ShareToken (ERC-1155)  — stores all user token balances (YES/NO per conditionId)
VaultV2                — stores all USDC balances (per-address ledger + splitReserve + feePool)
MarketLMSR             — pure LMSR pricing engine + inventory holder
BackstopRouter         — entry point for all LMSR trades (signature verification, delegation)
```

MarketLMSR holds ERC-1155 tokens as **inventory** (the opposite side of each trade),
not as user balances.

### 3.2 Buy Flow

```
User wants to buy 100 YES shares for ~52 USDC:

1. BackstopRouter verifies intent/sender
2. Vault.transferBetween(buyer, market, 52)         — buyer pays USDC
3. fee = 52 * totalFeeBps / BPS                      — calculate fee
4. net = 52 - fee                                     — net USDC for LMSR
5. sharesOut = LMSR.calcSharesOut(net, YES)           — LMSR pricing
6. require(sharesOut >= net)                           — Polymarket guarantee: price ≤ $1
7. Vault.lockForSplit(market, net)                    — lock USDC in splitReserve
8. ShareToken.splitPosition(conditionId, market, sharesOut) — mint YES+NO to market
9. ShareToken.safeTransferFrom(market, buyer, yesTokenId, sharesOut)  — buyer gets YES
   — market keeps NO as inventory
10. Vault.accumulateFee(market, fee)                   — fee → feePool
11. qYes += sharesOut * SCALE_6_TO_18                  — update LMSR state
```

### 3.3 Sell Flow

```
User wants to sell 100 YES shares for ~48 USDC:

1. BackstopRouter calls ShareToken.safeTransferFrom(user, market, yesTokenId, 100)
   — requires user's one-time approval of BackstopRouter (see HYBRID_SPEC §7.1.1)
2. gross = LMSR cost difference (C_before - C_after)  — LMSR pricing
3. ShareToken.mergePositions(conditionId, market, 100) — burn 100 YES + 100 NO (market's inventory)
4. Vault.releaseFromMerge(market, 100)                 — release USDC from splitReserve → market balance
5. fee = gross * totalFeeBps / BPS                     — calculate fee
6. amountOut = gross - fee
7. Vault.transferBetween(market, seller, amountOut)    — seller receives USDC
8. Vault.accumulateFee(market, fee)                    — fee → feePool
9. qYes -= 100 * SCALE_6_TO_18                         — update LMSR state
```

### 3.4 Redeem (post-resolution)

Redemption is handled entirely by **ShareToken**, not MarketLMSR:

```
1. ShareToken.redeemPositions(conditionId)
   — checks status == Resolved
   — burns winning tokens (or both if Invalid)
   — calls Vault.releaseForRedeem(user, amount)
2. User receives USDC: winningShares * payoutPerShare / 1e6
   — payoutPerShare = 1_000_000 for Yes/No outcome ($1)
   — payoutPerShare = 500_000 for Invalid outcome ($0.50)
```

MarketLMSR has no `redeem()` function. After resolution, the creator
can call `withdrawSeedAndFees()` to reclaim remaining seed + accumulated fees.

### 3.5 Key Invariants

```
PRE-RESOLUTION:
  ShareToken.totalSupply(yesTokenId) == ShareToken.totalSupply(noTokenId)
  — guaranteed by split/merge always operating in pairs

  Vault.splitReserve covers all outstanding token pairs:
  splitReserve >= totalSupply(yesTokenId) * PAYOUT_PER_SHARE / 1e6

POST-RESOLUTION:
  Redemption releases splitReserve → user balances
  No new tokens can be minted (splitPosition requires status == Open)
```

---

## 4. Fixed-Point Math

### 4.1 Standard: SD59x18 for All LMSR Math

All LMSR computations (exp, ln, sigmoid) use PRBMath SD59x18 (signed, 18 decimals).

**Conversions:**
```
USDC/shares (6 dec) → SD59x18 (18 dec):  value * SCALE_6_TO_18
SD59x18 (18 dec) → USDC/shares (6 dec):  value / SCALE_6_TO_18
```

### 4.2 Storage vs Computation

| Variable | Storage Type | Scale | Notes |
|----------|-------------|-------|-------|
| `b` | `int256` (SD59x18) | 1e18 per $1 | e.g. 100e18 = $100 |
| `qYes`, `qNo` | `int256` (SD59x18) | 1e18 per share | Signed, may be < 0 |
| `baseCost` | `uint256` | USDC 6 dec | Result of calcCostUsdc |
| shares (in/out) | `uint256` | 6 dec | 1 share = 1e6 = $1 face |
| `amountUsdc` | `uint256` | 6 dec | Input/output in USDC |

### 4.3 Constants

```solidity
// Scale conversion
int256 constant SCALE_6_TO_18 = 1e12;    // converts 6-decimal → 18-decimal

// SD59x18 constants
int256 constant UNIT_INT = 1e18;          // 1.0 in SD59x18
int256 constant SIGMOID_CLAMP = 20;       // clamp when |qDiff/b| > 20

// Price / fee constants
uint256 constant BPS = 10_000;
uint256 constant MIN_TRADE_USDC = 10_000;       // $0.01
uint256 constant PAYOUT_PER_SHARE = 1_000_000;  // $1
```

> **Note on naming**: The onchain constant is `USDC_TO_SD59x18 = 1e12` in current deployed
> contracts. Semantically it is a scale factor from 6 to 18 decimals. In this spec we use
> the clearer name `SCALE_6_TO_18`. Both refer to the same value `1e12`.

### 4.4 maxLossUsdc Derivation

```solidity
// b is SD59x18, ln(2) is SD59x18:
// b * ln(2) → SD59x18 * SD59x18 = 1e36 scale
// Divide by UNIT_INT (1e18) → back to SD59x18 (1e18)
// Divide by SCALE_6_TO_18 (1e12) → USDC 6 decimals

int256 LN2 = 693147180559945309;  // ln(2) * 1e18

uint256 maxLossUsdc = uint256((b * LN2) / UNIT_INT) / uint256(SCALE_6_TO_18);
require(seedUsdc >= maxLossUsdc, "seed must cover max loss");
```

The intermediate `b * LN2` is safe from overflow for `b <= MAX_B` (10_000e18):
`10_000e18 * 693e15 ≈ 6.93e39`, well within int256 range (~5.7e76).

### 4.5 Log-Sum-Exp Trick (Overflow Protection)

The cost function uses the Log-Sum-Exp trick to prevent exp() overflow:

```
C = b * (m + ln(e^(a-m) + e^(c-m)))
where a = qYes/b, c = qNo/b, m = max(a, c)
```

Since `a - m ≤ 0` and `c - m ≤ 0`, both exp() inputs are non-positive,
guaranteeing no overflow. The implementation:

```solidity
function calcCostUsdc(int256 b, int256 _qYes, int256 _qNo)
    internal pure returns (uint256 cost)
{
    SD59x18 bSD = sd(b);
    SD59x18 a = sd(_qYes).div(bSD);
    SD59x18 c = sd(_qNo).div(bSD);
    SD59x18 m = a.gt(c) ? a : c;

    SD59x18 sumExp = exp(a.sub(m)).add(exp(c.sub(m)));
    SD59x18 result = bSD.mul(m.add(ln(sumExp)));

    int256 rawResult = result.unwrap();
    require(rawResult >= 0, "negative cost");
    cost = uint256(rawResult) / uint256(SCALE_6_TO_18);
}
```

### 4.6 Binary Search for sharesOut

`calcSharesOut` uses binary search (40 iterations) to find the number of shares
purchasable for a given USDC cost:

```
Given: costUsdc (net, after fees)
Find:  sharesOut such that C(q + delta) - C(q) ≈ costUsdc

Binary search over [0, costUsdc * 200]:
  mid = (low + high) / 2
  newCost = calcCostUsdc(q + mid * SCALE_6_TO_18)
  if newCost <= targetCost → low = mid
  else → high = mid

Result: sharesOut = low (conservative, never overspends)
```

40 iterations give ~1e12 precision (more than sufficient for 6-decimal values).

### 4.7 Sigmoid Price Calculation

```solidity
function sigmoid(int256 b, int256 diff) internal pure returns (uint256 priceYesBps) {
    // P(yes) = 1 / (1 + e^(-diff/b))
    SD59x18 x = sd(diff).div(sd(b));
    SD59x18 expNegX = exp(ZERO.sub(x));
    SD59x18 prob = UNIT.div(UNIT.add(expNegX));

    uint256 probBps = uint256(prob.unwrap()) * BPS / uint256(UNIT_INT);

    // Clamp to 1-9999 (never exactly 0% or 100%)
    if (probBps == 0) return 1;
    if (probBps >= BPS) return 9999;
    return probBps;
}
```

Sigmoid is clamped when `|qYes - qNo| / b > SIGMOID_CLAMP (20)` to avoid
unnecessary exp() computation at extreme prices.

---

## 5. Trade Event Semantics

```solidity
event Trade(
    address indexed trader,
    Side side,           // Yes or No
    bool isBuy,          // true = buy, false = sell
    uint256 amountUsdc,  // see note below
    uint256 shares,      // buy: shares received; sell: shares sold
    uint256 fee,         // fee charged (USDC, 6 dec)
    uint256 priceYesBps, // YES price after trade (1-9999)
    int256 qYesAfter,    // qYes after trade (SD59x18)
    int256 qNoAfter      // qNo after trade (SD59x18)
);
```

**`amountUsdc` asymmetry (current implementation):**
- `isBuy=true`: `amountUsdc` = gross USDC spent (includes fee)
- `isBuy=false`: `amountUsdc` = net USDC received (after fee deducted)

`fee` is always in USDC and always emitted separately.

For indexing, the volume calculation is:
```
buyVolume = amountUsdc                    (already gross)
sellVolume = amountUsdc + fee             (reconstruct gross from net + fee)
```

> **BackstopRouter normalization**: The `BackstopTrade` event in BackstopRouter
> always emits `amountUsdc` as the USDC figure and `shares` as the share figure,
> regardless of isBuy. See HYBRID_SPEC §7.4 step 9.

---

## 6. Polymarket-Style Price Guarantee

```
require(sharesOut >= net, "price exceeds $1");
```

This check ensures that the user always receives at least as many shares as the
net USDC spent (in 6-decimal units). Since 1 share redeems for exactly $1,
this guarantees the share price never exceeds $1.

Combined with the fixed $1 payout:
- Maximum loss on a winning bet = fee only
- No scenario where "invested $60, won, received $15"

---

## 7. Gas Profile

### 7.1 PRBMath Costs

- `exp()`: ~2,000–3,000 gas
- `ln()`: ~2,000–3,000 gas
- Full `calcCostUsdc()`: ~8,000–12,000 gas
- Binary search (40 iterations × calcCostUsdc): ~400,000–500,000 gas

### 7.2 Total Gas per Operation

| Operation | Estimated Gas | Notes |
|-----------|--------------|-------|
| buyYes/buyNo | ~500–600k | Includes binary search + split + transfer |
| sellYes/sellNo | ~200–300k | No binary search (direct cost diff) |
| getPrices | ~15k | Single sigmoid computation |
| quoteBuy | ~500k | Same binary search as buy (view) |
| quoteSell | ~20k | Two calcCostUsdc calls (view) |

### 7.3 Optimization: Cached Cost

The `baseCost` is stored once at initialization. Each buy/sell computes
the cost difference directly rather than maintaining a running `cachedCost`,
since the binary search in buy already calls `calcCostUsdc` for each iteration.

---

## 8. Liquidity Tiers

```
┌─────────────┬──────────────┬──────────────┬────────────┐
│ Tier        │ b (SD59x18)  │ Min Seed     │ Max Loss   │
├─────────────┼──────────────┼──────────────┼────────────┤
│ Low         │  50 * 1e18   │  $35         │  $34.66    │
│ Medium      │ 200 * 1e18   │ $139         │ $138.63    │
│ High        │ 1000 * 1e18  │ $693         │ $693.15    │
└─────────────┴──────────────┴──────────────┴────────────┘

Min seed formula: ceil(b * ln(2) / 1e18 / 1e12)
```

Tiers are enforced by Factory at market creation. See HYBRID_SPEC §9 for the
full market creation flow (EIP-1167 clone → initConfig → initialize).

---

## 9. Testing

### 9.1 TypeScript (SDK — `@flipcoin/sdk`)

LMSR math tests in `packages/sdk/src/math/lmsrMath.test.ts` (58 tests):
- Price calculations (sigmoid function)
- Cost function (Log-Sum-Exp)
- Buy/sell simulations
- Polymarket-style guarantee (`sharesOut >= netUsdc`)
- Slippage calculations, initial price calculations, liquidity tiers

### 9.2 Solidity (Foundry)

`test/MarketLMSRMath.t.sol` (34 tests):
- Sigmoid correctness across price range
- Buy/sell math: quoteBuy/quoteSell consistency
- Polymarket guarantee enforcement
- Edge cases: extreme b values, boundary prices

`test/BackstopRouterAdvanced.t.sol` (additional LMSR integration):
- Fee ceiling checks, delegation spend, gasless execution

`test/FuzzInvariants.t.sol` (7 fuzz tests, 256 runs each):
- Vault solvency invariant
- Token pair invariant (yesSupply == noSupply)
- Polymarket guarantee across random trades
- Full lifecycle fuzz (create → trade → resolve → redeem)

---

## 10. References

- [LMSR Original Paper (Hanson)](https://mason.gmu.edu/~rhanson/mktscore.pdf)
- [Gnosis Conditional Tokens](https://docs.gnosis.io/conditionaltokens/)
- [PRBMath Library](https://github.com/PaulRBerg/prb-math)
- [Log-Sum-Exp Trick](https://en.wikipedia.org/wiki/LogSumExp)
- [Polymarket Docs](https://docs.polymarket.com/)
- [HYBRID_SPEC_v5.md](HYBRID_SPEC_v5.md) — Full v2 contract specification
