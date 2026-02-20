# LMSR AMM Specification

> This document describes the evolution of the AMM from the current CPMM (v1) to LMSR (v2).

---

## 0. Current Problem (CPMM v1) — Critical Analysis

### 0.1 Problem Description

With low initial liquidity ($10-50), CPMM produces extreme slippage:
- User invests $60 into a market with $10 liquidity
- Receives ~15 shares due to price impact
- Even when winning, receives only $15 (a $45 loss)

### 0.2 Architectural Contradictions in the Current Market.sol

**Problem 1: Creator receives shares on both sides**

```solidity
// In initialize():
yesSharesTotal = seedUsdc;
noSharesTotal = seedUsdc;
yesShares[creator] = seedUsdc;
noShares[creator] = seedUsdc;
```

Consequences:
1. `winningSharesTotal` always includes the creator's large initial issuance
2. `payoutPerShare = usdcPool / winningSharesTotal` will be approximately 0.5-1.0 even without traders
3. A trader buying a rare outcome shares the pool with the massive initial issuance, resulting in low returns

**Example:**
```
seed = $100
yesSharesTotal = 100 (creator's)
Trader buys 10 YES shares for $60

On YES resolution:
- winningSharesTotal = 110 (100 creator + 10 trader)
- usdcPool = 100 + 60 - fees ≈ $157
- payoutPerShare = 157 / 110 ≈ $1.43

Trader receives: 10 * 1.43 = $14.30 (invested $60, loss of $45.70!)
```

**Problem 2: Mixing CPMM pricing with pari-mutuel settlement**

CPMM:
- Price is determined by reserves: `priceYes = noReserve / (yes + no)`
- Shares are "purchased" at marginal price

Pari-mutuel:
- `payoutPerShare = usdcPool / winningSharesTotal`
- All winners split the total pool

These models are incompatible:
- CPMM implies: "1 share = $1 on win"
- Pari-mutuel says: "1 share = usdcPool/totalShares"

### 0.3 Why CPMM Cannot Solve the "Invested 60 → Received 15" Problem

This is a **mathematical property** of constant-product AMMs with small seeds:
- With seed = $10 and a $60 purchase, the price impact is extreme
- CPMM protects the **pool**, not the user
- No amount of maxPriceImpact or maxTradeAmount tuning will fully solve this

### 0.4 Possible Fixes for MVP (Without Migrating to LMSR)

**Option A: Virtual Liquidity (recommended)**

```solidity
// DO NOT mint shares to creator
function initialize(uint256 seedUsdc) external onlyFactory {
    yesReserve = seedUsdc;    // virtual reserves for pricing
    noReserve = seedUsdc;
    k = seedUsdc * seedUsdc;

    // DO NOT create shares — this is virtual liquidity only
    yesSharesTotal = 0;       // start at 0
    noSharesTotal = 0;

    usdcPool = seedUsdc;      // real collateral
    creatorSeedDeposit = seedUsdc;  // separate tracking for refund

    initialized = true;
}
```

Creator receives the seed back at resolution (minus AMM losses).

**Option B: Fixed Payout (Polymarket-style)**

```solidity
// Each share pays EXACTLY $1 on win
payoutPerShare = 1e6;  // fixed at $1

// On resolution, verify:
require(usdcPool >= winningSharesTotal, "insufficient collateral");
```

However, this requires a different AMM model (order book or LMSR).

**Option C: Increase the Minimum Seed**

A brute-force solution — require seed >= $500-1000 so that slippage remains acceptable.

---

## 1. Solution: LMSR (Phase 2)

### 1.1 Why LMSR

LMSR solves both problems:
1. **Bounded loss** — the creator knows the maximum loss upfront: `max_loss = b * ln(2)`
2. **Shares = probability** — each share pays exactly $1 on win (no pari-mutuel mixing)
3. **Predictable slippage** — logarithmic, not exponential

### 1.2 LMSR Mathematics

**Cost Function:**
```
C(q_yes, q_no) = b * ln(e^(q_yes/b) + e^(q_no/b))
```

Where:
- `q_yes` — quantity of YES shares sold
- `q_no` — quantity of NO shares sold
- `b` — liquidity parameter
- `C` — total cost of all shares sold

**Purchase Cost:**
```
cost = C(q_yes + delta, q_no) - C(q_yes, q_no)
```

**Price (Probability) via Sigmoid:**
```
P(yes) = 1 / (1 + e^(-(q_yes - q_no)/b))
P(no) = 1 - P(yes)
```

### 1.3 LMSR vs CPMM Comparison

| Property | CPMM (current) | LMSR |
|----------|----------------|------|
| Slippage | Exponential | Logarithmic |
| Max loss for LP | Unbounded | Bounded: `b * ln(2)` |
| Payout per share | Variable (pari-mutuel) | Fixed $1 |
| Predictability | Low | High |
| Price always 0-100% | No (asymptotic) | Yes |

### 1.4 The `b` Parameter (Liquidity)

`b` controls the market "depth":
- **Small b** ($10-50) — high price sensitivity
- **Large b** ($1000+) — stable price, requires large trades to move

**Maximum market maker loss:**
```
max_loss = b * ln(2) ≈ 0.693 * b
```

Example: `b = $100` → max loss ≈ $69.3

---

## 2. Economic Model

### 2.1 Who Bears the Max Loss?

The **market creator** acts as the market maker:
- Deposits `seedUsdc` when creating the market
- This deposit covers the potential LMSR loss

**Minimum deposit:**
```
seedUsdc >= b * ln(2) ≈ 0.693 * b
```

> **Important:** NOT `seedUsdc >= b` (that would overestimate the requirement by 44%)

### 2.2 Primary Economic Invariant (via baseCost)

```
vaultBalance(market) >= C(qYes, qNo) - baseCost
```

Where:
- `vaultBalance(market)` = `IVault(vault).balanceOf(market)` — the market's balance in the Vault ledger
- `C(qYes, qNo)` — current LMSR cost
- `baseCost` = `C(qYes0, qNo0)` — cost at initialization (with initial bias)

**Why baseCost instead of C(0,0)?**

With initial bias (starting price != 50%), the initial `qYes0` and `qNo0` are non-zero.
- `C(0, 0) = b * ln(2)` — this is only the special case for 50/50
- `baseCost = C(qYes0, qNo0)` — universal baseline for any initial price

### 2.3 Collateralization

Unlike CPMM/pari-mutuel, LMSR guarantees:
- Each YES share pays exactly $1 if YES wins
- Each NO share pays exactly $1 if NO wins

**Invariant:**
```
vaultBalance(market) >= max(yesSharesTotal, noSharesTotal)
```

### 2.4 Max Loss Scenario

```
Start: qYes = 0, qNo = 0, price = 50%
b = $100, seed = $70 (covers max_loss of $69.3)

Traders buy YES en masse:
- qYes increases, price → 99%
- Creator receives their USDC into the pool

Market resolves as YES:
- All YES shares pay $1
- Creator covers the difference from the seed

Result for creator:
- Maximum loss = $69.3 (if everyone bought YES)
- Seed covered the loss
```

---

## 3. Vault Integration

### 3.1 Architecture (per VAULT.md)

```
The Market NEVER holds ERC20 USDC directly.
All balances are maintained in the Vault ledger.
```

**Key principle:**
- `IVault(vault).balanceOf(market)` — the sole source of truth for balance
- The Market may cache this value but must periodically assert equality

### 3.2 Terminology

| Term | Description |
|------|-------------|
| `vaultBalance(market)` | `IVault(vault).balanceOf(market)` — balance in the Vault ledger |
| `creatorFeesAcc` | Accumulated creator fees (portion of vaultBalance) |
| `protocolFeesAcc` | Accumulated protocol fees (portion of vaultBalance) |
| `effectivePool` | `vaultBalance - creatorFeesAcc - protocolFeesAcc` — available for payouts |

### 3.3 Vault Accounting Invariant

```
vaultBalance(market) == effectivePool + creatorFeesAcc + protocolFeesAcc
```

**Fee accounting:**
- Fees accumulate in `creatorFeesAcc` / `protocolFeesAcc`
- Fees remain on the market ledger until explicitly withdrawn (withdrawFees)
- On sell: `grossOut` is paid to the user; fees remain

### 3.4 Dust Handling

Due to floor division in buy/sell/redeem, minor discrepancies are possible:

```solidity
uint256 constant DUST_BOUND_PER_TRADE = 2;  // 2 units = $0.000002 per trade
```

Final invariant accounting for dust:
```
abs(vaultBalance(market) - (effectivePool + fees)) <= DUST_BOUND_PER_TRADE * tradeCount
```

An explicit `dustAcc` counter may also be maintained for precise auditing.

---

## 4. Fixed-Point Math Standard

### 4.1 Unified Standard: SD59x18 for All Math

**Principle:** All LMSR computations (exp, ln, sigmoid) are performed in SD59x18 (signed, 18 decimals).

**Conversions:**
```
USDC (6 dec) → SD59x18 (18 dec): value * 1e12
SD59x18 (18 dec) → USDC (6 dec): value / 1e12
```

### 4.2 Storage vs Computation

| Variable | Storage Type | Computation Type | Notes |
|----------|--------------|------------------|-------|
| `b` | `int256` (SD59x18) | SD59x18 | Stored as 1e18, not in USDC decimals |
| `qYes`, `qNo` | `int256` (SD59x18) | SD59x18 | Signed, may be < 0 |
| `baseCost` | `uint256` (USDC 6 dec) | — | Result of _calcCost, already in USDC |
| `yesShares`, `noShares` | `uint256` (6 dec) | — | 1 share = 1e6 |
| `amountUsdc` | `uint256` (6 dec) | SD59x18 after *1e12 | Input/output in USDC |

### 4.3 Constants

```solidity
// SD59x18 constants
int256 public constant UNIT = 1e18;                    // 1.0 in SD59x18
int256 public constant LN2 = 693147180559945309;       // ln(2) * 1e18
int256 public constant USDC_TO_SD59x18 = 1e12;         // conversion 6 dec → 18 dec

// Limits (in SD59x18)
int256 public constant MIN_B = 10 * UNIT;              // $10 (in 1e18)
int256 public constant MAX_B = 10_000 * UNIT;          // $10,000 (in 1e18)
int256 public constant SIGMOID_CLAMP = 20;             // clamp when |qDiff/b| > 20

// USDC constants
uint256 public constant MIN_TRADE_USDC = 10_000;       // $0.01
uint256 public constant PAYOUT_PER_SHARE = 1_000_000;  // $1
uint256 public constant BPS = 10_000;
```

### 4.4 MAX_Q_DELTA Derivation

`MAX_Q_DELTA` protects against overflow in exp/ln.

**Derivation:**
- Sigmoid is clamped when `|qYes - qNo| / b > SIGMOID_CLAMP`
- With `SIGMOID_CLAMP = 20` and `MAX_B = 10_000 * 1e18`:
- `MAX_Q_DELTA = SIGMOID_CLAMP * MAX_B = 20 * 10_000 * 1e18 = 2e23`

```solidity
int256 public constant MAX_Q_DELTA = 2e23;  // = SIGMOID_CLAMP * MAX_B
```

---

## 5. MarketLMSR.sol Contract

### 5.1 State Variables

```solidity
// LMSR parameters (all in SD59x18)
int256 public b;              // Liquidity parameter (SD59x18, e.g. 100e18 = $100)
int256 public qYes;           // YES shares sold (SD59x18, signed)
int256 public qNo;            // NO shares sold (SD59x18, signed)
uint256 public baseCost;      // C(qYes0, qNo0) at initialize (USDC 6 dec)

// Fee accumulators (USDC 6 dec)
uint256 public creatorFeesAcc;
uint256 public protocolFeesAcc;

// User positions (6 decimals, 1 share = 1e6)
mapping(address => uint256) public yesShares;
mapping(address => uint256) public noShares;
uint256 public yesSharesTotal;
uint256 public noSharesTotal;

// Resolution
uint256 public payoutPerShare;
uint256 public winningSharesTotal;
```

### 5.2 Initialization (with Initial Bias)

```solidity
function initialize(
    int256 _b,                    // SD59x18: e.g. 100e18 = $100
    uint256 seedUsdc,             // USDC 6 dec
    uint256 initialPriceYesBps    // 100 = 1%, 5000 = 50%, 9900 = 99%
) external onlyFactory {
    require(_b >= MIN_B && _b <= MAX_B, "invalid b");
    require(initialPriceYesBps >= 100 && initialPriceYesBps <= 9900, "invalid price");

    b = _b;

    // Calculate initial q values for the given price
    // P(yes) = 1 / (1 + e^(-(qYes - qNo)/b))
    // Solve: qDiff = -b * ln(1/P - 1)
    (qYes, qNo) = _calcInitialQ(initialPriceYesBps);

    // baseCost = C(qYes0, qNo0) — baseline for the invariant
    baseCost = _calcCost(qYes, qNo);

    // Minimum seed must cover max_loss = b * ln(2)
    // b is in SD59x18, LN2 is in SD59x18, result is in SD59x18, converted to USDC
    uint256 maxLossUsdc = uint256((b * LN2) / UNIT) / USDC_TO_SD59x18;
    require(seedUsdc >= maxLossUsdc, "seed must cover max loss");

    // Vault has already transferred the seed via pullForNewMarket
    // vaultBalance(this) == seedUsdc

    // No shares minted to creator — virtual liquidity only
    yesSharesTotal = 0;
    noSharesTotal = 0;

    initialized = true;
}
```

### 5.3 Buy (Analytical Solution)

```solidity
function buyYes(uint256 amountUsdc, uint256 minSharesOut)
    external onlyOpen returns (uint256 sharesOut)
{
    require(amountUsdc >= MIN_TRADE_USDC, "trade too small");

    // Fee
    uint256 fee = (amountUsdc * totalFeeBps) / BPS;
    uint256 net = amountUsdc - fee;

    // Analytical solution for sharesOut
    sharesOut = _calcSharesOut(net, true); // true = YES side

    require(sharesOut >= minSharesOut, "slippage");

    // Convert shares to SD59x18 for q update
    int256 deltaQ = int256(sharesOut) * USDC_TO_SD59x18;
    int256 newQYes = qYes + deltaQ;

    // Overflow check
    require(_abs(newQYes - qNo) <= MAX_Q_DELTA, "q delta overflow");

    // Update state
    qYes = newQYes;

    // Vault: debit from user
    IVault(vault).spendFromUser(msg.sender, amountUsdc, LedgerTransferReason.Buy);
    _accumulateFees(fee);

    // Mint shares
    yesShares[msg.sender] += sharesOut;
    yesSharesTotal += sharesOut;

    // Collateralization invariant
    uint256 vaultBal = IVault(vault).balanceOf(address(this));
    assert(vaultBal - creatorFeesAcc - protocolFeesAcc >= yesSharesTotal);

    emit Trade(...);
}
```

### 5.4 Sell

```solidity
function sellYes(uint256 shares, uint256 minAmountOut)
    external onlyOpen returns (uint256 amountOut)
{
    require(shares > 0 && yesShares[msg.sender] >= shares, "invalid shares");

    // Convert shares to SD59x18
    int256 deltaQ = int256(shares) * USDC_TO_SD59x18;
    int256 newQYes = qYes - deltaQ;

    // Calculate payout via LMSR
    uint256 currentCost = _calcCost(qYes, qNo);
    uint256 newCost = _calcCost(newQYes, qNo);
    uint256 grossOut = currentCost - newCost;

    // Fee
    uint256 fee = (grossOut * totalFeeBps) / BPS;
    amountOut = grossOut - fee;

    require(amountOut >= minAmountOut, "slippage");

    // Liquidity check: grossOut must be available
    uint256 vaultBal = IVault(vault).balanceOf(address(this));
    uint256 effectivePool = vaultBal - creatorFeesAcc - protocolFeesAcc;
    require(effectivePool >= grossOut, "insufficient liquidity");

    // Update state
    qYes = newQYes;
    _accumulateFees(fee);

    // Burn shares
    yesShares[msg.sender] -= shares;
    yesSharesTotal -= shares;

    // Pay user (amountOut; fees remain on the market ledger)
    IVault(vault).payToUser(msg.sender, amountOut, LedgerTransferReason.Sell);

    emit Trade(...);
}
```

### 5.5 Resolve & Redeem (Fixed Payout)

```solidity
function resolveMarket(Outcome _outcome) external onlyAdmin {
    // ... validation ...

    // In LMSR, each share pays EXACTLY $1
    payoutPerShare = PAYOUT_PER_SHARE;  // 1e6 = $1

    if (_outcome == Outcome.Yes) {
        winningSharesTotal = yesSharesTotal;
    } else if (_outcome == Outcome.No) {
        winningSharesTotal = noSharesTotal;
    } else {
        // Invalid: proportional refund
        winningSharesTotal = yesSharesTotal + noSharesTotal;
        uint256 vaultBal = IVault(vault).balanceOf(address(this));
        uint256 effectivePool = vaultBal - creatorFeesAcc - protocolFeesAcc;
        payoutPerShare = winningSharesTotal > 0
            ? effectivePool * 1e6 / winningSharesTotal
            : 0;
    }

    // Collateralization check
    uint256 vaultBal = IVault(vault).balanceOf(address(this));
    uint256 effectivePool = vaultBal - creatorFeesAcc - protocolFeesAcc;
    require(effectivePool >= winningSharesTotal * payoutPerShare / 1e6, "undercollateralized");

    status = MarketStatus.Resolved;
    outcome = _outcome;
}

function redeem() external returns (uint256 payout) {
    require(status == MarketStatus.Resolved, "not resolved");

    uint256 claimShares = (outcome == Outcome.Yes)
        ? yesShares[msg.sender]
        : (outcome == Outcome.No)
            ? noShares[msg.sender]
            : yesShares[msg.sender] + noShares[msg.sender];

    require(claimShares > 0, "nothing to redeem");

    payout = claimShares * payoutPerShare / 1e6;

    yesShares[msg.sender] = 0;
    noShares[msg.sender] = 0;

    IVault(vault).payToUser(msg.sender, payout, LedgerTransferReason.Redeem);

    emit Redeemed(msg.sender, claimShares, payout);
}
```

### 5.6 Price Calculation (Sigmoid)

```solidity
function getPrices() external view returns (uint256 priceYesBps, uint256 priceNoBps) {
    // P(yes) = 1 / (1 + e^(-(qYes - qNo)/b))

    int256 diff = qYes - qNo;  // SD59x18

    // Clamp to protect exp() from overflow — NOT part of the economics
    // When |diff/b| > SIGMOID_CLAMP, sigmoid ≈ 0 or 1
    if (diff > b * SIGMOID_CLAMP) {
        priceYesBps = 9999;
    } else if (diff < -b * SIGMOID_CLAMP) {
        priceYesBps = 1;
    } else {
        priceYesBps = _sigmoid(diff, b);
    }

    priceNoBps = BPS - priceYesBps;
}
```

### 5.7 Math Helpers (Log-Sum-Exp Trick) — Safe Implementation

```solidity
import { SD59x18, sd, exp, ln, UNIT, ZERO } from "@prb/math/SD59x18.sol";

/**
 * Log-Sum-Exp trick to prevent overflow:
 * C = b * (m + ln(e^(a-m) + e^(c-m)))
 * where m = max(qYes/b, qNo/b)
 *
 * ALL computations are in signed SD59x18.
 * The result is converted to USDC (uint256, 6 dec) only at the end.
 */
function _calcCost(int256 _qYes, int256 _qNo) internal view returns (uint256) {
    // All operations in SD59x18
    SD59x18 bSD = sd(b);
    SD59x18 a = sd(_qYes).div(bSD);   // qYes / b
    SD59x18 c = sd(_qNo).div(bSD);    // qNo / b

    // m = max(a, c) — for numerical stability
    SD59x18 m = a.gt(c) ? a : c;

    // e^(a-m) + e^(c-m)
    SD59x18 expAM = exp(a.sub(m));
    SD59x18 expCM = exp(c.sub(m));
    SD59x18 sumExp = expAM.add(expCM);

    // ln(sum)
    SD59x18 lnSum = ln(sumExp);

    // result = b * (m + ln(sum)) — still SD59x18 (signed)
    SD59x18 result = bSD.mul(m.add(lnSum));

    // Convert SD59x18 → USDC 6 decimals
    // result.unwrap() returns int256 in 1e18
    // Divide by 1e12 to obtain 6 decimals
    int256 rawResult = result.unwrap();

    // result is always >= 0 for valid q (LMSR cost function property)
    // Safety check nonetheless
    require(rawResult >= 0, "negative cost");

    return uint256(rawResult) / uint256(USDC_TO_SD59x18);
}

/**
 * Sigmoid for price calculation
 * P(yes) = 1 / (1 + e^(-diff/b))
 * Returns: priceYesBps (1-9999)
 */
function _sigmoid(int256 diff, int256 _b) internal pure returns (uint256) {
    SD59x18 x = sd(diff).div(sd(_b));    // diff / b
    SD59x18 negX = ZERO.sub(x);          // -x
    SD59x18 expNegX = exp(negX);         // e^(-x)
    SD59x18 denom = UNIT.add(expNegX);   // 1 + e^(-x)
    SD59x18 prob = UNIT.div(denom);      // 1 / (1 + e^(-x))

    // Convert to BPS (0-10000)
    // prob.unwrap() is in 1e18, we want BPS
    uint256 probBps = uint256(prob.unwrap()) * BPS / uint256(UNIT);

    // Clamp to 1-9999 (never exactly 0 or 100%)
    if (probBps == 0) return 1;
    if (probBps >= BPS) return 9999;
    return probBps;
}
```

---

## 6. Factory Integration (per factory.md)

### 6.1 Create Market with pullForNewMarket

```solidity
function createMarket(
    // ... existing params ...
    LiquidityTier liquidityTier,
    uint256 initialPriceYesBps
) external returns (address market) {
    (int256 bValue, uint256 minSeed) = getLiquidityParams(liquidityTier);

    require(initialPriceYesBps >= 100 && initialPriceYesBps <= 9900, "invalid price");

    // 1. Deploy market contract
    market = address(new MarketLMSR(config));

    // 2. Whitelist market in Vault (if required)
    IVault(vault).whitelistMarket(market);

    // 3. Pull seed from creator to market via Vault
    // pullForNewMarket = spendFromUser(creator) + credit to market ledger
    IVault(vault).pullForNewMarket(msg.sender, market, minSeed);

    // 4. Initialize market with LMSR params
    MarketLMSR(market).initialize(bValue, minSeed, initialPriceYesBps);

    emit MarketCreated(market, msg.sender, bValue, initialPriceYesBps);
}
```

### 6.2 Liquidity Tiers

```solidity
enum LiquidityTier { Low, Medium, High }

function getLiquidityParams(LiquidityTier tier)
    public pure returns (int256 bValue, uint256 minSeedUsdc)
{
    // bValue in SD59x18 (1e18 = $1)
    // minSeedUsdc in USDC 6 decimals

    if (tier == LiquidityTier.Low) {
        bValue = 50 * UNIT;           // $50 in SD59x18
        minSeedUsdc = 35_000_000;     // $35 (≈ 0.693 * 50)
    } else if (tier == LiquidityTier.Medium) {
        bValue = 200 * UNIT;          // $200
        minSeedUsdc = 139_000_000;    // $139
    } else {
        bValue = 1000 * UNIT;         // $1000
        minSeedUsdc = 693_000_000;    // $693
    }
}
```

---

## 7. Events (with Clear Semantics)

```solidity
event Trade(
    address indexed trader,
    Side side,           // Yes or No
    bool isBuy,          // true = buy, false = sell
    uint256 amountUsdc,  // buy: USDC spent; sell: USDC received (after fees)
    uint256 shares,      // buy: shares received; sell: shares burned
    uint256 fee,         // fee charged (in USDC)
    uint256 priceYesBps, // price after trade
    int256 qYesAfter,    // qYes after trade (SD59x18, for indexing)
    int256 qNoAfter      // qNo after trade (SD59x18)
);
```

**Semantics for indexing:**
- `isBuy=true`: `amountUsdc` = USDC spent (gross), `shares` = received
- `isBuy=false`: `shares` = sold, `amountUsdc` = USDC received (net, after fee)
- `fee` is always in USDC, already deducted from / added to `amountUsdc`

---

## 8. Status and Lifecycle

```solidity
enum MarketStatus {
    Open,      // Trading allowed
    Resolved   // Trading stopped, redemption allowed
}
// Paused removed from MVP — not implemented
```

**Lifecycle:**
```
[Factory creates] → Open → [admin resolves] → Resolved
                         → [timeout] → markAsInvalid() → Resolved(Invalid)
```

---

## 9. Gas Optimization

### 9.1 PRBMath Costs

- `exp()` ≈ 2000-3000 gas
- `ln()` ≈ 2000-3000 gas
- Full `_calcCost()` ≈ 8000-12000 gas

### 9.2 Optimizations

1. **Cache currentCost** — store after each trade:
   ```solidity
   uint256 public cachedCost;  // updated after every buy/sell
   ```

2. **Log-Sum-Exp trick** — mandatory, prevents overflow

3. **Approximations for getPrices()** — a lookup table can be used for sigmoid

### 9.3 Expected Gas

| Operation | CPMM | LMSR |
|-----------|------|------|
| buyYes    | ~80k | ~120k |
| sellYes   | ~85k | ~125k |
| getPrices | ~5k  | ~15k |

---

## 10. Testing

### 10.1 Unit Tests

- [ ] `testInitialize_validParams`
- [ ] `testInitialize_seedTooSmall` — revert
- [ ] `testInitialize_withBias` — correct initial price via baseCost
- [ ] `testBuyYes_sharesEqualsOneDollar` — payout = $1 per share
- [ ] `testSellYes_refundCorrect` — fees stay on market
- [ ] `testMaxLoss` — creator loss does not exceed `b * ln(2)`
- [ ] `testResolve_fixedPayout` — each share pays exactly $1
- [ ] `testCollateralization_alwaysSufficient`
- [ ] `testVaultBalance_matchesInvariant`

### 10.2 Invariant Tests

- `vaultBalance(market) >= C(qYes, qNo) - baseCost` always holds
- `vaultBalance(market) >= max(yesSharesTotal, noSharesTotal)` (collateralization)
- `vaultBalance(market) == effectivePool + creatorFeesAcc + protocolFeesAcc` (accounting)
- `priceYes + priceNo == 10000 bps`
- `abs(qYes - qNo) <= MAX_Q_DELTA`

### 10.3 Fuzz Tests

- Arbitrary sequences of buy/sell operations
- Extreme values of b (MIN_B to MAX_B)
- Random initial prices (100 to 9900 bps)
- Edge cases with overflow/underflow in SD59x18

---

## 11. Migration Strategy

1. **Deploy MarketLMSR.sol** — new contract
2. **Update Factory** — creates LMSR markets
3. **Old CPMM markets** — continue operating until resolution
4. **Frontend** — detects type by presence of the `b` field

### 11.1 Interface Compatibility

```solidity
interface IMarket {
    // Common to both CPMM and LMSR
    function buyYes(uint256 amountUsdc, uint256 minSharesOut) external returns (uint256);
    function sellYes(uint256 shares, uint256 minAmountOut) external returns (uint256);
    function getPrices() external view returns (uint256 priceYesBps, uint256 priceNoBps);
    function redeem() external returns (uint256);
}
```

---

## 12. Open Questions

1. **Math library** — PRBMath SD59x18 *(resolved)*
2. **Payout model** — Fixed $1 per share, not pari-mutuel *(resolved)*
3. **Creator shares** — No initial shares; virtual liquidity only *(resolved)*
4. **Fixed-point standard** — All math in SD59x18 (1e18) *(resolved)*
5. **Vault integration** — vaultBalance via IVault.balanceOf() *(resolved)*
6. **Adding liquidity post-creation?** — v1: no, v2: under consideration
7. **Oracle for initial price?** — v1: creator sets manually

---

## 13. References

- [LMSR Original Paper (Hanson)](https://mason.gmu.edu/~rhanson/mktscore.pdf)
- [Gnosis Conditional Tokens](https://docs.gnosis.io/conditionaltokens/)
- [PRBMath Library](https://github.com/PaulRBerg/prb-math)
- [Log-Sum-Exp Trick](https://en.wikipedia.org/wiki/LogSumExp)
- [Polymarket Docs](https://docs.polymarket.com/)
