# Security Review #2 — FlipCoin v2 Smart Contracts

**Date:** 2026-02-28
**Reviewer:** Claude Opus 4.6 (independent security review)
**Scope:** All v2 Solidity contracts in `contracts/v2/` (9 files, ~3,500 LOC)
**Prior audit:** `docs/SECURITY_AUDIT_CONTRACTS.md` (Review #1, 2026-02-27, 18 findings — all fixed)

**Methodology:** Independent line-by-line review focusing on:
- Economic invariant violations (price, collateralization, fund flows)
- Operator trust model boundaries and abuse vectors
- Cross-contract state consistency
- Settlement logic correctness (COMPLEMENTARY, MINT, MERGE)
- EIP-712 signature security and replay protection
- Comparison with industry standard (Polymarket CTFExchange)

**Contracts reviewed (9):**

| Contract | LOC | Description |
|----------|-----|-------------|
| `Exchange.sol` | 741 | CLOB settlement (3 match types: COMPLEMENTARY, MINT, MERGE) |
| `BackstopRouter.sol` | 409 | LMSR entry point (gasless + direct trades, EIP-712) |
| `MarketLMSR.sol` | 462 | LMSR AMM (ERC-1155 inventory, EIP-1167 clone) |
| `ShareToken.sol` | 591 | ERC-1155 conditional tokens + resolution lifecycle |
| `VaultV2.sol` | 432 | USDC custody (4-pool model) |
| `FactoryV2.sol` | 628 | Market creation (3 modes + Agent API) |
| `DelegationRegistry.sol` | 258 | Delegation + daily USDC spend limits |
| `libraries/LMSRMath.sol` | 181 | PRBMath SD59x18 LMSR calculations |
| `interfaces/Types.sol` | 189 | Shared type definitions |

---

## Summary

| Severity | Count | Fixed | Description |
|----------|-------|-------|-------------|
| :yellow_circle: Medium | 2 | 2 | Economic logic issues in Exchange settlement |
| :blue_circle: Informational | 3 | — | Design notes, no direct exploit |
| **Total** | **5** | **2** | |

All 18 findings from Review #1 were verified as correctly fixed.
Both Medium findings from Review #2 fixed with 5 regression tests in `AuditFixes.t.sol`.

---

## :yellow_circle: MEDIUM

### R2-1. Exchange._settleComplementary — No Seller Price Protection — FIXED

- **Contract:** `Exchange.sol` lines 482-507
- **Confidence:** 9/10
- **Category:** Economic logic / operator trust boundary
- **Status:** :white_check_mark: **Fixed** — Added `PriceBelowSellerMinimum` error and `_getPriceSell(seller)` validation in `_settleComplementary`. 3 regression tests added.

**Description:**

In COMPLEMENTARY settlement, the execution price is derived exclusively from the **buyer's** (taker's) order via `_getPriceBuy(buyer)`. The seller's (maker's) minimum acceptable price — encoded in their signed order as `takerAmount / makerAmount` — is **never validated**.

```solidity
function _settleComplementary(
    Order calldata buyer,   // = takerOrder
    Order calldata seller,  // = makerOrder
    ...
) internal {
    uint256 priceBps = _getPriceBuy(buyer);  // ONLY buyer's price
    // ... no check against seller's minimum price ...
    uint256 usdcAmount = fillAmount * priceBps / BPS;
    vault.transferBetween(buyer.maker, seller.maker, usdcAmount);
    shareToken.safeTransferFrom(seller.maker, buyer.maker, buyer.tokenId, fillAmount, "");
}
```

The fill capacity check (`ordersFilled[makerHash] + fillAmount <= _getOrderShares(makerOrder)`) only bounds the **number of shares** the seller provides, not the **price per share**. `_getOrderShares` returns `max(makerAmount, takerAmount)` = shares count. No per-share USDC minimum is enforced.

**Exploit scenario:**

1. Seller signs order: sell 1 YES share for min $0.70 (`makerAmount=1_000_000`, `takerAmount=700_000`)
2. Buyer signs order: buy 1 YES share at $0.50 (`makerAmount=500_000`, `takerAmount=1_000_000`)
3. Compromised operator matches with `fillAmount=1_000_000`
4. Execution price = `_getPriceBuy(buyer) = 500_000 * 10_000 / 1_000_000 = 5000 bps` ($0.50)
5. Seller receives $0.50 instead of their signed minimum of $0.70
6. Buyer profits $0.20 per share at seller's expense

In a legitimate CLOB, matching only occurs when buyer's bid >= seller's ask. The operator is expected to enforce this off-chain, but the contract provides **no on-chain guarantee**.

**Comparison with Polymarket CTFExchange:**

Polymarket computes each party's USDC settlement from **their own** order's `makerAmount/takerAmount` ratio:
```solidity
// Polymarket: each maker's payment computed from their own terms
takingAmount = making * order.takerAmount / order.makerAmount;
```
Any surplus (when buyer pays more than seller asks) is reconciled. This gives **implicit on-chain price protection** to both parties.

FlipCoin uses a single price (buyer's) for the entire settlement, leaving sellers unprotected.

**Impact:** A compromised or malicious operator can systematically underpay sellers on COMPLEMENTARY matches. The seller signed explicit price terms that the contract ignores.

**Recommended fix:**

```solidity
function _settleComplementary(...) internal {
    uint256 priceBps = _getPriceBuy(buyer);
    if (priceBps == 0 || priceBps >= BPS) revert InvalidPrice();

    // R2-1: Validate seller's minimum price is satisfied
    uint256 sellerMinPriceBps = _getPriceSell(seller);
    if (priceBps < sellerMinPriceBps) revert PriceBelowSellerMinimum();

    uint256 usdcAmount = fillAmount * priceBps / BPS;
    // ... rest unchanged
}
```

Alternatively, follow Polymarket's pattern: compute USDC from the seller's ratio and verify the buyer can afford it.

---

### R2-2. Exchange._settleMerge — Surplus USDC Stranded (No Recovery) — FIXED

- **Contract:** `Exchange.sol` lines 547-582
- **Confidence:** 8/10
- **Category:** Economic logic / permanent fund lock
- **Status:** :white_check_mark: **Fixed** — Option A implemented: surplus routed to `protocolFeesAccumulated` via `vault.accumulateFee()`. 2 regression tests added.

**Description:**

In MERGE settlement, `vault.releaseFromMerge(address(this), fillAmount)` credits `fillAmount` USDC to the Exchange's vault balance. Then sellers are paid and fees collected, totaling `usdc1 + usdc2` where:

```
usdc1 = fillAmount * price1 / BPS
usdc2 = fillAmount * price2 / BPS
```

When `price1 + price2 < BPS`, a surplus of `fillAmount - usdc1 - usdc2` USDC remains in `vault.balances[exchange]`. This is the mirror image of C-1 (MINT undercollateralization, fixed in Review #1).

**Two sub-issues:**

1. **Intentional under-BPS MERGEs:** The off-chain matcher allows `price1 + price2 <= 10000` (including strict inequality). Example: YES seller at 3000 bps + NO seller at 5000 bps = 8000 bps. On a 10 USDC fill, 2 USDC is stranded per operation.

2. **Rounding dust:** Even with `price1 + price2 = BPS`, integer truncation causes `usdc1 + usdc2 < fillAmount` by 1-2 micro-units per operation. Over thousands of MERGE operations, dust accumulates.

**The Exchange contract has no function to recover its own vault balance.**

All Exchange admin functions (`withdrawProtocolFees`, `withdrawCreatorFees`) operate on `feePool`, not on `vault.balances[exchange]`. There is no `rescueBalance()` or equivalent. VaultV2 also has no sweep mechanism.

**Impact:** USDC permanently locked in `vault.balances[exchange]`. Not a solvency risk (totalBalances invariant is maintained), but permanent fund loss.

**Recommended fix (two options):**

Option A — Route surplus to fee pool:
```solidity
// In _settleMerge, after paying sellers and collecting fees:
uint256 surplus = fillAmount - usdc1 - usdc2;
if (surplus > 0) vault.accumulateFee(address(this), surplus);
```

Option B — Add admin recovery function:
```solidity
function rescueExchangeBalance(address to, uint256 amount) external onlyAdmin {
    vault.transferBetween(address(this), to, amount);
}
```

---

## :blue_circle: INFORMATIONAL

### I-1. LMSR Sell Inventory Limitation from Cross-Venue Shares

- **Contract:** `MarketLMSR.sol` lines 381-423
- **Category:** Design limitation

The LMSR sell flow (`_sell`) requires the MarketLMSR clone to hold both YES and NO tokens for merge. The LMSR's inventory comes exclusively from its own minting history (buys through BackstopRouter). Shares acquired via the Exchange (CLOB) are not reflected in LMSR inventory.

If a user acquires YES shares via CLOB and attempts to sell through the LMSR, the merge may fail because the MarketLMSR lacks sufficient NO tokens in its ERC-1155 balance.

This is an inherent design limitation of hybrid CLOB+LMSR systems, not a bug. Users who acquired shares via CLOB should sell via CLOB or redeem at resolution. However, this reduces the LMSR's effectiveness as a universal "backstop" for all share holders.

---

### I-2. MarketLMSR._buy — lockForSplit/splitPosition Amount Asymmetry

- **Contract:** `MarketLMSR.sol` lines 349-352
- **Category:** Design note

Each buy trade locks `net` USDC in splitReserve but mints `sharesOut >= net` token pairs (Polymarket guarantee enforces `sharesOut >= net`). This creates a per-trade deficit where splitReserve < total outstanding share pairs after buys.

The LMSR cost function and seed liquidity provide global solvency. Fuzz tests in `FuzzInvariants.t.sol` validate the vault solvency invariant across 256 randomized lifecycles. No solvency violation was observed.

This is by design — the seed USDC covers the deficit, and the LMSR's mathematical properties guarantee overall collateralization.

---

### I-3. Exchange.matchOrders — Micro-Fill Fee Rounding to Zero

- **Contract:** `Exchange.sol` line 611
- **Category:** Design note

The fee formula `totalFeeBps * min(price, BPS-price) * fillAmount / BPS / BPS` rounds to 0 for sufficiently small `fillAmount`. With `totalFeeBps=150` and `min(price, BPS-price)=5000`, fills with `fillAmount <= 133` (0.0133 cents) produce zero fee.

In theory, splitting large trades into millions of micro-fills could evade fees. In practice, gas costs of millions of on-chain transactions far exceed saved fees. Additionally, the operator controls `fillAmount` and would not submit micro-fills in normal operation.

---

## Verified Secure (No Issues Found)

The following areas were specifically examined in this review and found to be correctly implemented:

| Area | Verdict | Notes |
|------|---------|-------|
| **EIP-712 domain separation** | :white_check_mark: Secure | Exchange, BackstopRouter, Factory use separate domain names and version "1" |
| **Nonce management** | :white_check_mark: Secure | Sequential per-signer nonces in all three contracts; `bumpNonce` for bulk cancel |
| **Reentrancy protection** | :white_check_mark: Secure | `nonReentrant` on all external state-changing functions; CEI pattern in BackstopRouter |
| **MINT collateralization (C-1 fix)** | :white_check_mark: Verified | `price1 + price2 >= BPS` enforced in `_settleMint` |
| **Price range validation (H-1/H-2 fix)** | :white_check_mark: Verified | `priceBps != 0 && priceBps < BPS` in all settlement paths |
| **Zero-address checks in initConfig (H-3 fix)** | :white_check_mark: Verified | All 4 critical addresses validated in MarketLMSR |
| **BackstopRouter fee ceiling (H-4 fix)** | :white_check_mark: Verified | `maxFeeBps` parameter in `executeTrade()` |
| **BackstopRouter pause (M-5 fix)** | :white_check_mark: Verified | `whenNotPaused` on both trade functions |
| **Resolution timelock** | :white_check_mark: Secure | 24h dispute period, shareholder-only dispute, correct lifecycle |
| **VaultV2 4-pool accounting** | :white_check_mark: Secure | `totalBalances`, `splitReserve`, `feePool` correctly maintained |
| **ERC-1155 compliance** | :white_check_mark: Secure | ShareToken extends ERC1155Supply, correct receiver interfaces |
| **PRBMath SD59x18 usage** | :white_check_mark: Secure | Proper scaling, Log-Sum-Exp trick prevents overflow |
| **Binary search convergence (M-3 fix)** | :white_check_mark: Verified | Post-check reverts if `sharesOut == 0 && costUsdc > 0` |
| **Sell underflow guard (M-4 fix)** | :white_check_mark: Verified | `if (newCost >= currentCost) return 0` |
| **Creator fee cap (L-5 fix)** | :white_check_mark: Verified | Capped at 500 bps (5%) |
| **DelegationRegistry spend limits** | :white_check_mark: Secure | Rolling 24h window, scope validation, expiry check |
| **Factory deadline validation (L-3 fix)** | :white_check_mark: Verified | `require(params.deadline > uint64(block.timestamp))` |
| **EIP-1271 smart contract wallets** | :white_check_mark: Secure | Correct staticcall + magic value validation |
| **Order cancellation (digest-based)** | :white_check_mark: Secure | Uses domain-separated hash consistently |
| **MERGE buy-side price validation** | :white_check_mark: Secure | `_getPriceSell` used for both sellers with individual prices |
| **MINT buy-side symmetry** | :white_check_mark: Secure | Each buyer pays their own price; `_getPriceBuy` per order |
| **Access control consistency** | :white_check_mark: Secure | `onlyAdmin`, `onlyOperator`, `onlyFactory`, `onlySettlement` |
| **Event emission completeness** | :white_check_mark: Secure | All state changes emit events with correct parameters |

---

## Architecture Assessment

### Operator Trust Model

The Exchange uses a trusted operator model (`onlyOperator` modifier). The operator:
- Submits `matchOrders` transactions (cannot be called by users)
- Chooses `matchType` and `fillAmount` for each match
- Determines which orders to match and when

This is standard for prediction market CLOBs (Polymarket uses the same model). The key risks are:
1. **Key compromise** — a stolen operator key can abuse matching logic (R2-1)
2. **Censorship** — operator can selectively delay/ignore orders
3. **Front-running** — operator sees all orders before matching

Mitigation M-1 (multi-sig, from Review #1) addresses key compromise at the admin level. Operator key rotation should also be considered.

### Settlement Flow Summary

| Match Type | Price Source | Validation | Status |
|------------|-------------|------------|--------|
| COMPLEMENTARY | Buyer only | Price range (0, BPS) + seller min price | :white_check_mark: Secure (R2-1 fix) |
| MINT | Both buyers individually | Price range + `p1+p2 >= BPS` | :white_check_mark: Secure (C-1 fix) |
| MERGE | Both sellers individually | Price range + surplus recovery | :white_check_mark: Secure (R2-2 fix) |

---

## Recommendations

1. ~~**R2-1 fix (Priority: HIGH)**~~ :white_check_mark: **FIXED** — Seller price validation added in `_settleComplementary`. `PriceBelowSellerMinimum` error + `_getPriceSell(seller)` check.

2. ~~**R2-2 fix (Priority: MEDIUM)**~~ :white_check_mark: **FIXED** — MERGE surplus routed to `protocolFeesAccumulated` via `vault.accumulateFee()`.

3. **Off-chain matcher hardening:** Update `src/services/orderbook/matcher.ts` to enforce `buyer_price >= seller_ask` for COMPLEMENTARY matches and `price1 + price2 == BPS` for MERGE matches as defense-in-depth.

4. **Operator key rotation:** Implement a mechanism for regular operator key rotation, separate from admin key management.

5. **External human audit:** Both reviews were automated (Claude Opus 4.6). A professional human audit firm (Trail of Bits, OpenZeppelin, Spearbit) is recommended before mainnet deployment with real funds.

---

## Test Coverage

All 455 tests pass across 18 suites (including 5 new regression tests for R2-1 and R2-2):

| Finding | Test | Status |
|---------|------|--------|
| R2-1 | `test_R2_1_complementary_priceBelowSellerAsk_reverts` | :white_check_mark: Pass |
| R2-1 | `test_R2_1_complementary_priceAtSellerAsk_succeeds` | :white_check_mark: Pass |
| R2-1 | `test_R2_1_complementary_priceAboveSellerAsk_succeeds` | :white_check_mark: Pass |
| R2-2 | `test_R2_2_merge_surplusToProtocolFees` | :white_check_mark: Pass |
| R2-2 | `test_R2_2_merge_noPriceSumEqual` | :white_check_mark: Pass |

---

*Review #2 complete. 2 actionable findings (Medium) — both fixed. 3 informational notes, 22 verified-secure areas. All 18 Review #1 fixes confirmed.*
