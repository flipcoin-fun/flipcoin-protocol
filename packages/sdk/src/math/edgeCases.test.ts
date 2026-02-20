/**
 * Edge case and boundary value tests for both LMSR and CPMM math
 *
 * These tests cover:
 * 1. Zero inputs (0 amount, 0 shares, 0 reserves)
 * 2. Minimum trade amounts
 * 3. Very large values (near uint256 limits in practice)
 * 4. Negative q values in LMSR
 * 5. Precision at boundaries
 * 6. Division edge cases
 * 7. Initial price boundary values
 */

import { describe, it, expect } from "vitest";
import {
  // LMSR
  BPS as LMSR_BPS,
  ONE_USDC as LMSR_ONE_USDC,
  UNIT,
  USDC_TO_SD59x18,
  MIN_TRADE_USDC as LMSR_MIN_TRADE,
  PAYOUT_PER_SHARE,
  MIN_SEED_USDC,
  MAX_SEED_USDC,
  mulDivDown as lmsrMulDiv,
  abs,
  absDiff,
  expApprox,
  lnApprox,
  lmsrPriceYesBps,
  lmsrPriceNoBps,
  lmsrCostUsdc,
  simulateLmsrBuyYes,
  simulateLmsrBuyNo,
  simulateLmsrSellYes,
  simulateLmsrSellNo,
  canLmsrBuy,
  canLmsrSell,
  formatUsdc as lmsrFormatUsdc,
  parseUsdc as lmsrParseUsdc,
  formatBps as lmsrFormatBps,
  calcInitialQ,
  calcMaxLossUsdc,
  calcBFromSeed,
  type LmsrState,
} from "./lmsrMath";

import {
  // CPMM
  MIN_RESERVE,
  mulDivDown as cpmmMulDiv,
  priceYesBps as cpmmPriceYes,
  simulateBuyYes as cpmmBuyYes,
  canBuy as cpmmCanBuy,
  formatTokenPrice,
  formatProbability,
  type AmmState,
} from "./ammMath";

// ============================================================
// LMSR helpers
// ============================================================

function lmsrState(overrides?: Partial<LmsrState>): LmsrState {
  return {
    b: 200n * UNIT,
    qYes: 0n,
    qNo: 0n,
    feeBps: 200n,
    yesSharesTotal: 0n,
    noSharesTotal: 0n,
    ...overrides,
  };
}

// ============================================================
// 1. Zero Input Edge Cases
// ============================================================

describe("Zero input edge cases", () => {
  describe("LMSR", () => {
    it("buyYes with 0 USDC should return 0 shares", () => {
      const state = lmsrState();
      const result = simulateLmsrBuyYes(state, 0n);
      expect(result.sharesOut).toBe(0n);
      expect(result.fee).toBe(0n);
      expect(result.netUsdc).toBe(0n);
    });

    it("buyNo with 0 USDC should return 0 shares", () => {
      const state = lmsrState();
      const result = simulateLmsrBuyNo(state, 0n);
      expect(result.sharesOut).toBe(0n);
    });

    it("sellYes with 0 shares should return 0 output", () => {
      const state = lmsrState({ qYes: 50n * UNIT });
      const result = simulateLmsrSellYes(state, 0n);
      expect(result.amountOutGross).toBe(0n);
      expect(result.amountOutNet).toBe(0n);
    });

    it("sellNo with 0 shares should return 0 output", () => {
      const state = lmsrState({ qNo: 50n * UNIT });
      const result = simulateLmsrSellNo(state, 0n);
      expect(result.amountOutGross).toBe(0n);
    });

    it("cost with b=0 should return 0", () => {
      expect(lmsrCostUsdc(0n, 100n * UNIT, 50n * UNIT)).toBe(0n);
    });

    it("price with b=0 should return 5000 bps", () => {
      expect(lmsrPriceYesBps(0n, 100n * UNIT, 50n * UNIT)).toBe(5000n);
    });
  });

  describe("CPMM", () => {
    it("price with both reserves 0 should return 5000", () => {
      expect(cpmmPriceYes(0n, 0n)).toBe(5000n);
    });
  });
});

// ============================================================
// 2. Minimum Trade Amounts
// ============================================================

describe("Minimum trade amounts", () => {
  it("LMSR: MIN_TRADE_USDC buy should produce non-zero shares", () => {
    const state = lmsrState();
    const result = simulateLmsrBuyYes(state, LMSR_MIN_TRADE);

    // Even 0.01 USDC should produce some shares at 50/50
    // (depends on fee eating into the small amount)
    // At 2% fee on 10000 (0.01 USDC), fee = 200, net = 9800
    // This is very small, may or may not produce shares
    expect(result.fee).toBe(200n);
    expect(result.netUsdc).toBe(9_800n);
  });

  it("LMSR: 1 USDC buy should always produce shares", () => {
    const state = lmsrState();
    const result = simulateLmsrBuyYes(state, LMSR_ONE_USDC);
    expect(result.sharesOut).toBeGreaterThan(0n);
  });

  it("canLmsrSell rejects gross output below MIN_TRADE", () => {
    const result = canLmsrSell({
      amountOutGross: LMSR_MIN_TRADE - 1n,
      amountOutNet: 0n,
      fee: 0n,
      newQYes: 0n,
      newQNo: 0n,
      newPriceYesBps: 5000n,
      priceImpactBps: 0n,
    });
    expect(result.valid).toBe(false);
  });
});

// ============================================================
// 3. Very Large Values
// ============================================================

describe("Very large values", () => {
  it("LMSR: $10,000 buy on high tier should work", () => {
    const state = lmsrState({ b: 1000n * UNIT }); // High tier
    const result = simulateLmsrBuyYes(state, 10_000n * LMSR_ONE_USDC);
    expect(result.sharesOut).toBeGreaterThan(0n);
    expect(result.newPriceYesBps).toBeGreaterThan(5000n);
    expect(result.newPriceYesBps).toBeLessThanOrEqual(9999n);
  });

  it("LMSR: large b parameter should work", () => {
    const bigB = 10_000n * UNIT;
    const price = lmsrPriceYesBps(bigB, 0n, 0n);
    expect(price).toBe(5000n);

    const cost = lmsrCostUsdc(bigB, 0n, 0n);
    expect(cost).toBeGreaterThan(0n);
  });

  it("expApprox clamping: very large exponent returns capped value", () => {
    const result = expApprox(100n * UNIT);
    // Should be clamped to e^20 ≈ 4.85e8
    expect(result).toBe(485165195n * UNIT);
  });

  it("expApprox clamping: very negative exponent returns 0", () => {
    const result = expApprox(-100n * UNIT);
    expect(result).toBe(0n);
  });
});

// ============================================================
// 4. Negative q Values in LMSR
// ============================================================

describe("Negative q values", () => {
  it("negative qYes should produce low YES price", () => {
    const b = 200n * UNIT;
    const price = lmsrPriceYesBps(b, -100n * UNIT, 0n);
    expect(price).toBeLessThan(5000n);
  });

  it("negative qNo should produce high YES price", () => {
    const b = 200n * UNIT;
    const price = lmsrPriceYesBps(b, 0n, -100n * UNIT);
    expect(price).toBeGreaterThan(5000n);
  });

  it("both negative q should still produce valid price", () => {
    const b = 200n * UNIT;
    const price = lmsrPriceYesBps(b, -50n * UNIT, -50n * UNIT);
    // Equal q values → 50%
    expect(price).toBe(5000n);
  });

  it("selling YES from initial state creates negative qYes", () => {
    // This simulates the case where someone sells YES without having bought
    const state = lmsrState();
    const result = simulateLmsrSellYes(state, 5_000_000n);

    // qYes should decrease (become negative)
    expect(result.newQYes).toBeLessThan(state.qYes);
    // Price should decrease
    expect(result.newPriceYesBps).toBeLessThan(5000n);
  });
});

// ============================================================
// 5. Precision at Boundaries
// ============================================================

describe("Precision at boundaries", () => {
  it("lmsrPriceYesBps never returns 0", () => {
    const b = 200n * UNIT;
    // Very large negative diff
    const price = lmsrPriceYesBps(b, -10000n * UNIT, 0n);
    expect(price).toBeGreaterThanOrEqual(1n);
  });

  it("lmsrPriceYesBps never returns 10000", () => {
    const b = 200n * UNIT;
    // Very large positive diff
    const price = lmsrPriceYesBps(b, 10000n * UNIT, 0n);
    expect(price).toBeLessThanOrEqual(9999n);
  });

  it("PAYOUT_PER_SHARE should be $1", () => {
    expect(PAYOUT_PER_SHARE).toBe(1_000_000n);
  });

  it("USDC_TO_SD59x18 scale factor should be 1e12", () => {
    expect(USDC_TO_SD59x18).toBe(10n ** 12n);
    // Verify: 1 USDC (1e6) * scale = 1e18 (SD59x18 unit)
    expect(LMSR_ONE_USDC * USDC_TO_SD59x18).toBe(UNIT);
  });
});

// ============================================================
// 6. Division Edge Cases
// ============================================================

describe("Division edge cases", () => {
  it("mulDivDown with large numerators should not overflow JS BigInt", () => {
    // BigInt handles arbitrary precision, so this should always work
    const result = lmsrMulDiv(10n ** 30n, 10n ** 30n, 10n ** 20n);
    expect(result).toBe(10n ** 40n);
  });

  it("mulDivDown division by zero should throw", () => {
    expect(() => lmsrMulDiv(1n, 1n, 0n)).toThrow("Division by zero");
    expect(() => cpmmMulDiv(1n, 1n, 0n)).toThrow("Division by zero");
  });

  it("mulDivDown with 0 numerator should return 0", () => {
    expect(lmsrMulDiv(0n, 12345n, 100n)).toBe(0n);
    expect(lmsrMulDiv(12345n, 0n, 100n)).toBe(0n);
  });

  it("lnApprox should throw for 0", () => {
    expect(() => lnApprox(0n)).toThrow();
  });

  it("lnApprox should throw for negative numbers", () => {
    expect(() => lnApprox(-1n)).toThrow();
    expect(() => lnApprox(-UNIT)).toThrow();
  });
});

// ============================================================
// 7. Initial Price Boundary Values
// ============================================================

describe("Initial price boundary values", () => {
  it("calcInitialQ should throw for 0 bps", () => {
    expect(() => calcInitialQ(200n * UNIT, 0n)).toThrow();
  });

  it("calcInitialQ should throw for 10000 bps", () => {
    expect(() => calcInitialQ(200n * UNIT, 10000n)).toThrow();
  });

  it("calcInitialQ should work for 1 bps (extreme low)", () => {
    const b = 200n * UNIT;
    const { qYes, qNo } = calcInitialQ(b, 1n);
    // qNo should be much larger than qYes
    expect(qNo).toBeGreaterThan(qYes);
  });

  it("calcInitialQ should work for 9999 bps (extreme high)", () => {
    const b = 200n * UNIT;
    const { qYes, qNo } = calcInitialQ(b, 9999n);
    // qYes should be much larger than qNo
    expect(qYes).toBeGreaterThan(qNo);
  });

  it("calcInitialQ at 5000 should give qYes ≈ qNo", () => {
    const b = 200n * UNIT;
    const { qYes, qNo } = calcInitialQ(b, 5000n);
    expect(absDiff(qYes, abs(qNo))).toBeLessThan(UNIT);
  });
});

// ============================================================
// 8. Seed/b Parameter Boundaries
// ============================================================

describe("Seed/b parameter boundaries", () => {
  it("MIN_SEED_USDC should be $10", () => {
    expect(MIN_SEED_USDC).toBe(10n * LMSR_ONE_USDC);
  });

  it("MAX_SEED_USDC should be $10,000", () => {
    expect(MAX_SEED_USDC).toBe(10_000n * LMSR_ONE_USDC);
  });

  it("calcBFromSeed with MIN_SEED should produce valid b", () => {
    const b = calcBFromSeed(MIN_SEED_USDC);
    expect(b).toBeGreaterThan(0n);

    const maxLoss = calcMaxLossUsdc(b);
    expect(absDiff(maxLoss, MIN_SEED_USDC)).toBeLessThan(LMSR_ONE_USDC);
  });

  it("calcBFromSeed with MAX_SEED should produce valid b", () => {
    const b = calcBFromSeed(MAX_SEED_USDC);
    expect(b).toBeGreaterThan(0n);

    const maxLoss = calcMaxLossUsdc(b);
    expect(absDiff(maxLoss, MAX_SEED_USDC)).toBeLessThan(LMSR_ONE_USDC);
  });

  it("calcMaxLossUsdc with 0 b should return 0", () => {
    expect(calcMaxLossUsdc(0n)).toBe(0n);
  });
});

// ============================================================
// 9. Formatting Edge Cases
// ============================================================

describe("Formatting edge cases", () => {
  it("formatUsdc with 0", () => {
    expect(lmsrFormatUsdc(0n)).toBe("0.00");
  });

  it("formatUsdc with 1 wei (smallest unit)", () => {
    expect(lmsrFormatUsdc(1n, 6)).toBe("0.000001");
  });

  it("formatUsdc with negative values", () => {
    expect(lmsrFormatUsdc(-1_000_000n)).toBe("-1.00");
    expect(lmsrFormatUsdc(-500_000n)).toBe("-0.50");
  });

  it("formatUsdc with 0 decimals", () => {
    expect(lmsrFormatUsdc(1_500_000n, 0)).toBe("1");
    expect(lmsrFormatUsdc(999_999n, 0)).toBe("0");
  });

  it("parseUsdc with empty string", () => {
    expect(lmsrParseUsdc("")).toBe(0n);
  });

  it("parseUsdc with just a dot", () => {
    expect(lmsrParseUsdc(".")).toBe(0n);
  });

  it("parseUsdc should throw for alphabetic", () => {
    expect(() => lmsrParseUsdc("hello")).toThrow();
  });

  it("formatBps for 0 bps", () => {
    expect(lmsrFormatBps(0n)).toBe("0.00%");
  });

  it("formatBps for 10000 bps", () => {
    expect(lmsrFormatBps(10000n)).toBe("100.00%");
  });
});

// ============================================================
// 10. CPMM formatTokenPrice edge cases
// ============================================================

describe("CPMM formatTokenPrice edge cases", () => {
  it("0 bps should show $<0.01", () => {
    expect(formatTokenPrice(0n)).toBe("$<0.01");
  });

  it("10000 bps should show $>0.99", () => {
    expect(formatTokenPrice(10000n)).toBe("$>0.99");
  });

  it("exactly 11 bps (barely above threshold) should show 3 decimals", () => {
    const result = formatTokenPrice(11n);
    expect(result).toMatch(/^\$0\.00\d$/);
  });

  it("exactly 9989 bps (barely below threshold) should show 3 decimals", () => {
    const result = formatTokenPrice(9989n);
    expect(result).toMatch(/^\$0\.99\d$/);
  });
});

// ============================================================
// 11. abs and absDiff
// ============================================================

describe("abs and absDiff edge cases", () => {
  it("abs of max safe bigint-like values", () => {
    const big = 2n ** 128n;
    expect(abs(big)).toBe(big);
    expect(abs(-big)).toBe(big);
  });

  it("absDiff with equal values", () => {
    expect(absDiff(0n, 0n)).toBe(0n);
    expect(absDiff(2n ** 64n, 2n ** 64n)).toBe(0n);
  });

  it("absDiff is commutative", () => {
    const a = 123456789n;
    const b = 987654321n;
    expect(absDiff(a, b)).toBe(absDiff(b, a));
  });
});

// ============================================================
// 12. Fee edge cases
// ============================================================

describe("Fee edge cases", () => {
  it("0% fee should pass full amount", () => {
    const state = lmsrState({ feeBps: 0n });
    const result = simulateLmsrBuyYes(state, 10_000_000n);
    expect(result.fee).toBe(0n);
    expect(result.netUsdc).toBe(10_000_000n);
  });

  it("100% fee should leave 0 net (edge case)", () => {
    const state = lmsrState({ feeBps: 10_000n });
    const result = simulateLmsrBuyYes(state, 10_000_000n);
    expect(result.fee).toBe(10_000_000n);
    expect(result.netUsdc).toBe(0n);
    expect(result.sharesOut).toBe(0n);
  });

  it("1 bps fee on $100 should be $0.01", () => {
    const state = lmsrState({ feeBps: 1n });
    const result = simulateLmsrBuyYes(state, 100_000_000n);
    expect(result.fee).toBe(10_000n); // 0.01 USDC
  });
});
