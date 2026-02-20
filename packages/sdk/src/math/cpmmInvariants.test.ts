/**
 * CPMM invariant & property-based tests
 *
 * Validates critical CPMM properties across parameter combinations:
 * 1. k-invariant: newYes * newNo <= k (floor division can only decrease)
 * 2. Price sum: priceYes + priceNo == 10000 bps
 * 3. Price monotonicity: buying YES increases YES price
 * 4. Reserve protection: MIN_RESERVE is never breached by validation
 * 5. Buy-sell round-trip: price returns to ~original
 * 6. Fee deduction correctness
 * 7. Extreme price behavior: small sharesOut is valid, not an error
 * 8. formatTokenPrice / formatProbability boundary correctness
 */

import { describe, it, expect } from "vitest";
import {
  BPS,
  ONE_USDC,
  MIN_RESERVE,
  MIN_TRADE_USDC,
  DEFAULT_FEE_BPS,
  type AmmState,
  mulDivDown,
  absDiff,
  minOutWithSlippage,
  priceYesBps,
  priceNoBps,
  calculatePriceImpact,
  simulateBuyYes,
  simulateBuyNo,
  simulateSellYes,
  simulateSellNo,
  canBuy,
  canSell,
  formatUsdc,
  parseUsdc,
  formatTokenPrice,
  formatProbability,
  getSafeProgressValue,
  isExtremePrice,
} from "./ammMath";

// ============================================================
// Helpers
// ============================================================

function createState(
  yesReserve: bigint = 100_000_000n,
  noReserve: bigint = 100_000_000n,
  feeBps: bigint = DEFAULT_FEE_BPS
): AmmState {
  return {
    yesReserve,
    noReserve,
    k: yesReserve * noReserve,
    feeBps,
  };
}

const TEST_AMOUNTS = [
  10_000n, // 0.01 USDC
  100_000n, // 0.10 USDC
  1_000_000n, // 1 USDC
  5_000_000n, // 5 USDC
  10_000_000n, // 10 USDC
  25_000_000n, // 25 USDC
  50_000_000n, // 50 USDC
];

// Various pool sizes
const POOL_CONFIGS: Array<{ yes: bigint; no: bigint; label: string }> = [
  { yes: 10_000_000n, no: 10_000_000n, label: "$10/$10 (small)" },
  { yes: 100_000_000n, no: 100_000_000n, label: "$100/$100 (medium)" },
  { yes: 1_000_000_000n, no: 1_000_000_000n, label: "$1000/$1000 (large)" },
  { yes: 50_000_000n, no: 150_000_000n, label: "$50/$150 (75% YES)" },
  { yes: 150_000_000n, no: 50_000_000n, label: "$150/$50 (25% YES)" },
  { yes: 10_000_000n, no: 190_000_000n, label: "$10/$190 (95% YES)" },
  { yes: 190_000_000n, no: 10_000_000n, label: "$190/$10 (5% YES)" },
];

// ============================================================
// 1. k-Invariant
// ============================================================

describe("k-Invariant: newYes * newNo <= k", () => {
  for (const pool of POOL_CONFIGS) {
    describe(pool.label, () => {
      for (const amount of TEST_AMOUNTS) {
        it(`buyYes $${Number(amount) / 1e6}`, () => {
          const state = createState(pool.yes, pool.no);
          const result = simulateBuyYes(state, amount);
          const newK = result.newYesReserve * result.newNoReserve;

          // Due to floor division, new k <= original k
          expect(newK).toBeLessThanOrEqual(state.k);
          // But should be very close (within 0.1%)
          if (state.k > 0n) {
            const diff = state.k - newK;
            const ratio = Number(diff) / Number(state.k);
            expect(ratio).toBeLessThan(0.001);
          }
        });

        it(`buyNo $${Number(amount) / 1e6}`, () => {
          const state = createState(pool.yes, pool.no);
          const result = simulateBuyNo(state, amount);
          const newK = result.newYesReserve * result.newNoReserve;

          expect(newK).toBeLessThanOrEqual(state.k);
        });
      }
    });
  }
});

// ============================================================
// 2. Price Sum Invariant
// ============================================================

describe("Price Sum: YES + NO == 10000 bps", () => {
  it("should hold for all pool configs", () => {
    for (const pool of POOL_CONFIGS) {
      const pYes = priceYesBps(pool.yes, pool.no);
      const pNo = priceNoBps(pool.yes, pool.no);
      expect(pYes + pNo).toBe(10_000n);
    }
  });

  it("should hold after buying YES", () => {
    for (const pool of POOL_CONFIGS) {
      const state = createState(pool.yes, pool.no);
      const result = simulateBuyYes(state, 5_000_000n);
      const pYes = priceYesBps(result.newYesReserve, result.newNoReserve);
      const pNo = priceNoBps(result.newYesReserve, result.newNoReserve);
      expect(pYes + pNo).toBe(10_000n);
    }
  });

  it("should hold after buying NO", () => {
    for (const pool of POOL_CONFIGS) {
      const state = createState(pool.yes, pool.no);
      const result = simulateBuyNo(state, 5_000_000n);
      const pYes = priceYesBps(result.newYesReserve, result.newNoReserve);
      const pNo = priceNoBps(result.newYesReserve, result.newNoReserve);
      expect(pYes + pNo).toBe(10_000n);
    }
  });
});

// ============================================================
// 3. Price Monotonicity
// ============================================================

describe("Price Monotonicity", () => {
  it("buying YES should always increase YES price", () => {
    for (const pool of POOL_CONFIGS) {
      const state = createState(pool.yes, pool.no);
      const priceBefore = priceYesBps(state.yesReserve, state.noReserve);

      for (const amount of TEST_AMOUNTS) {
        const result = simulateBuyYes(state, amount);
        expect(result.newPriceYesBps).toBeGreaterThanOrEqual(priceBefore);
      }
    }
  });

  it("buying NO should always decrease YES price", () => {
    for (const pool of POOL_CONFIGS) {
      const state = createState(pool.yes, pool.no);
      const priceBefore = priceYesBps(state.yesReserve, state.noReserve);

      for (const amount of TEST_AMOUNTS) {
        const result = simulateBuyNo(state, amount);
        expect(result.newPriceYesBps).toBeLessThanOrEqual(priceBefore);
      }
    }
  });

  it("selling YES should always decrease YES price", () => {
    const state = createState();
    const priceBefore = priceYesBps(state.yesReserve, state.noReserve);

    for (const shares of [1_000_000n, 5_000_000n, 10_000_000n]) {
      const result = simulateSellYes(state, shares);
      expect(result.newPriceYesBps).toBeLessThanOrEqual(priceBefore);
    }
  });

  it("selling NO should always increase YES price", () => {
    const state = createState();
    const priceBefore = priceYesBps(state.yesReserve, state.noReserve);

    for (const shares of [1_000_000n, 5_000_000n, 10_000_000n]) {
      const result = simulateSellNo(state, shares);
      expect(result.newPriceYesBps).toBeGreaterThanOrEqual(priceBefore);
    }
  });
});

// ============================================================
// 4. Reserve Protection Validation
// ============================================================

describe("Reserve Protection", () => {
  it("canBuy should reject when YES reserve drops below MIN_RESERVE", () => {
    const result = canBuy({
      sharesOut: 1_000_000n,
      fee: 0n,
      netUsdc: 1_000_000n,
      newYesReserve: MIN_RESERVE - 1n,
      newNoReserve: 200_000_000n,
      newPriceYesBps: 9900n,
      priceImpactBps: 100n,
    });
    expect(result.valid).toBe(false);
    expect(result.reason).toContain("YES reserve");
  });

  it("canBuy should reject when NO reserve drops below MIN_RESERVE", () => {
    const result = canBuy({
      sharesOut: 1_000_000n,
      fee: 0n,
      netUsdc: 1_000_000n,
      newYesReserve: 200_000_000n,
      newNoReserve: MIN_RESERVE - 1n,
      newPriceYesBps: 100n,
      priceImpactBps: 100n,
    });
    expect(result.valid).toBe(false);
    expect(result.reason).toContain("NO reserve");
  });

  it("canBuy should accept when reserves are exactly at MIN_RESERVE", () => {
    const result = canBuy({
      sharesOut: 1_000_000n,
      fee: 0n,
      netUsdc: 1_000_000n,
      newYesReserve: MIN_RESERVE,
      newNoReserve: MIN_RESERVE,
      newPriceYesBps: 5000n,
      priceImpactBps: 0n,
    });
    expect(result.valid).toBe(true);
  });

  it("canSell should reject when reserves drop below MIN_RESERVE", () => {
    const result = canSell({
      amountOutGross: 1_000_000n,
      amountOutNet: 980_000n,
      fee: 20_000n,
      newYesReserve: MIN_RESERVE - 1n,
      newNoReserve: 100_000_000n,
      newPriceYesBps: 5000n,
      priceImpactBps: 0n,
    });
    expect(result.valid).toBe(false);
  });

  it("canSell should reject trades below MIN_TRADE_USDC", () => {
    const result = canSell({
      amountOutGross: MIN_TRADE_USDC - 1n,
      amountOutNet: MIN_TRADE_USDC - 2n,
      fee: 1n,
      newYesReserve: 100_000_000n,
      newNoReserve: 100_000_000n,
      newPriceYesBps: 5000n,
      priceImpactBps: 0n,
    });
    expect(result.valid).toBe(false);
    expect(result.reason).toContain("too small");
  });
});

// ============================================================
// 5. Buy-Sell Round-Trip
// ============================================================

describe("Buy-Sell Round-Trip", () => {
  it("price should return close to original after buy + sell", () => {
    for (const pool of POOL_CONFIGS.slice(0, 3)) {
      // balanced pools only
      const state = createState(pool.yes, pool.no);
      const originalPrice = priceYesBps(state.yesReserve, state.noReserve);

      for (const amount of [1_000_000n, 5_000_000n, 10_000_000n]) {
        const buyResult = simulateBuyYes(state, amount);
        if (buyResult.sharesOut === 0n) continue;

        const stateAfterBuy = createState(
          buyResult.newYesReserve,
          buyResult.newNoReserve,
          state.feeBps
        );
        const sellResult = simulateSellYes(stateAfterBuy, buyResult.sharesOut);
        const finalPrice = priceYesBps(
          sellResult.newYesReserve,
          sellResult.newNoReserve
        );

        // Price should be within 5% of original (fees + floor division)
        const tolerance = 500n;
        expect(absDiff(finalPrice, originalPrice)).toBeLessThan(tolerance);
      }
    }
  });

  it("user always loses some value due to fees in round-trip", () => {
    const state = createState();
    const buyAmount = 10_000_000n;

    const buyResult = simulateBuyYes(state, buyAmount);
    const stateAfterBuy = createState(
      buyResult.newYesReserve,
      buyResult.newNoReserve,
      state.feeBps
    );
    const sellResult = simulateSellYes(stateAfterBuy, buyResult.sharesOut);

    // User should get back less than they put in (due to 2x fee)
    expect(sellResult.amountOutNet).toBeLessThan(buyAmount);
  });
});

// ============================================================
// 6. Fee Deduction Correctness
// ============================================================

describe("Fee Deduction", () => {
  it("fee should be exactly feeBps/10000 of input for buys", () => {
    const feeBps = 200n; // 2%
    const state = createState(100_000_000n, 100_000_000n, feeBps);

    for (const amount of TEST_AMOUNTS) {
      const result = simulateBuyYes(state, amount);
      const expectedFee = (amount * feeBps) / BPS;
      expect(result.fee).toBe(expectedFee);
      expect(result.netUsdc).toBe(amount - expectedFee);
    }
  });

  it("fee should be feeBps/10000 of gross output for sells", () => {
    const feeBps = 200n;
    const state = createState(100_000_000n, 100_000_000n, feeBps);

    const result = simulateSellYes(state, 5_000_000n);
    const expectedFee = (result.amountOutGross * feeBps) / BPS;
    expect(result.fee).toBe(expectedFee);
    expect(result.amountOutNet).toBe(result.amountOutGross - result.fee);
  });

  it("zero fee should pass through full amount", () => {
    const state = createState(100_000_000n, 100_000_000n, 0n);
    const result = simulateBuyYes(state, 10_000_000n);

    expect(result.fee).toBe(0n);
    expect(result.netUsdc).toBe(10_000_000n);
  });
});

// ============================================================
// 7. Extreme Price Behavior
// ============================================================

describe("Extreme Price Behavior", () => {
  it("should produce small but positive sharesOut at 95% YES price", () => {
    // Pool with YES at ~95%: noReserve >> yesReserve
    const state = createState(10_000_000n, 190_000_000n);
    const result = simulateBuyYes(state, 1_000_000n);

    // Small sharesOut is EXPECTED at extreme prices
    expect(result.sharesOut).toBeGreaterThan(0n);
    // Price should be high
    expect(result.newPriceYesBps).toBeGreaterThan(9000n);
  });

  it("buying the cheap side at extreme prices gives many shares", () => {
    // YES is at ~95%, so NO is cheap
    const state = createState(10_000_000n, 190_000_000n);
    const noResult = simulateBuyNo(state, 1_000_000n);

    // Buying cheap NO should give lots of shares
    expect(noResult.sharesOut).toBeGreaterThan(0n);
    // Price should move significantly
    expect(noResult.priceImpactBps).toBeGreaterThan(0n);
  });

  it("canBuy allows trades at extreme prices (no artificial restrictions)", () => {
    const state = createState(10_000_000n, 190_000_000n);
    const result = simulateBuyYes(state, 1_000_000n);
    const validation = canBuy(result);

    // Should be valid even though sharesOut is small
    if (
      result.newYesReserve >= MIN_RESERVE &&
      result.newNoReserve >= MIN_RESERVE &&
      result.sharesOut > 0n
    ) {
      expect(validation.valid).toBe(true);
    }
  });
});

// ============================================================
// 8. Sequential Trades
// ============================================================

describe("Sequential Trades", () => {
  it("10 consecutive YES buys should monotonically increase price", () => {
    let state = createState();
    let lastPrice = priceYesBps(state.yesReserve, state.noReserve);

    for (let i = 0; i < 10; i++) {
      const result = simulateBuyYes(state, 5_000_000n);
      expect(result.newPriceYesBps).toBeGreaterThan(lastPrice);

      lastPrice = result.newPriceYesBps;
      state = createState(
        result.newYesReserve,
        result.newNoReserve,
        state.feeBps
      );
    }
  });

  it("alternating YES/NO buys should keep price near center", () => {
    let state = createState();
    const amount = 5_000_000n;

    for (let i = 0; i < 5; i++) {
      const buyYes = simulateBuyYes(state, amount);
      state = createState(
        buyYes.newYesReserve,
        buyYes.newNoReserve,
        state.feeBps
      );

      const buyNo = simulateBuyNo(state, amount);
      state = createState(
        buyNo.newYesReserve,
        buyNo.newNoReserve,
        state.feeBps
      );
    }

    const finalPrice = priceYesBps(state.yesReserve, state.noReserve);
    // Should still be near 50% (within 15%)
    expect(finalPrice).toBeGreaterThan(3500n);
    expect(finalPrice).toBeLessThan(6500n);
  });
});

// ============================================================
// 9. formatTokenPrice Boundaries
// ============================================================

describe("formatTokenPrice boundaries", () => {
  it("should never return $0.00 (CPMM asymptote)", () => {
    for (let bps = 0n; bps <= 20n; bps++) {
      const result = formatTokenPrice(bps);
      expect(result).not.toBe("$0.00");
    }
  });

  it("should never return $1.00 (CPMM asymptote)", () => {
    for (let bps = 9980n; bps <= 10000n; bps++) {
      const result = formatTokenPrice(bps);
      expect(result).not.toBe("$1.00");
    }
  });

  it("should return $<0.01 for very low values", () => {
    expect(formatTokenPrice(0n)).toBe("$<0.01");
    expect(formatTokenPrice(5n)).toBe("$<0.01");
    expect(formatTokenPrice(10n)).toBe("$<0.01");
  });

  it("should return $>0.99 for very high values", () => {
    expect(formatTokenPrice(9990n)).toBe("$>0.99");
    expect(formatTokenPrice(9999n)).toBe("$>0.99");
    expect(formatTokenPrice(10000n)).toBe("$>0.99");
  });

  it("standard range should show 2 decimals", () => {
    expect(formatTokenPrice(5000n)).toBe("$0.50");
    expect(formatTokenPrice(2500n)).toBe("$0.25");
    expect(formatTokenPrice(7500n)).toBe("$0.75");
  });
});

// ============================================================
// 10. formatProbability Boundaries
// ============================================================

describe("formatProbability boundaries", () => {
  it("should never return 0%", () => {
    for (let bps = 0n; bps <= 20n; bps++) {
      const result = formatProbability(bps);
      expect(result).not.toBe("0%");
    }
  });

  it("should never return 100%", () => {
    for (let bps = 9980n; bps <= 10000n; bps++) {
      const result = formatProbability(bps);
      expect(result).not.toBe("100%");
    }
  });

  it("should return <1% for very low values", () => {
    expect(formatProbability(0n)).toBe("<1%");
    expect(formatProbability(10n)).toBe("<1%");
  });

  it("should return >99% for very high values", () => {
    expect(formatProbability(9990n)).toBe(">99%");
    expect(formatProbability(10000n)).toBe(">99%");
  });
});

// ============================================================
// 11. getSafeProgressValue
// ============================================================

describe("getSafeProgressValue clamping", () => {
  it("should never return 0 or 100", () => {
    expect(getSafeProgressValue(0n)).toBeGreaterThanOrEqual(1);
    expect(getSafeProgressValue(10000n)).toBeLessThanOrEqual(99);
  });

  it("should return correct values in normal range", () => {
    expect(getSafeProgressValue(5000n)).toBe(50);
    expect(getSafeProgressValue(2500n)).toBe(25);
    expect(getSafeProgressValue(7500n)).toBe(75);
  });
});

// ============================================================
// 12. isExtremePrice
// ============================================================

describe("isExtremePrice thresholds", () => {
  it("boundary at 500 bps (5%)", () => {
    expect(isExtremePrice(500n).isLow).toBe(false);
    expect(isExtremePrice(499n).isLow).toBe(true);
  });

  it("boundary at 9500 bps (95%)", () => {
    expect(isExtremePrice(9500n).isHigh).toBe(false);
    expect(isExtremePrice(9501n).isHigh).toBe(true);
  });

  it("mid-range is never extreme", () => {
    for (const bps of [2000n, 3000n, 5000n, 7000n, 8000n]) {
      const result = isExtremePrice(bps);
      expect(result.isExtreme).toBe(false);
    }
  });
});

// ============================================================
// 13. parseUsdc edge cases
// ============================================================

describe("parseUsdc edge cases", () => {
  it("should handle leading zeros", () => {
    expect(parseUsdc("001")).toBe(1_000_000n);
    expect(parseUsdc("00.50")).toBe(500_000n);
  });

  it("should handle no whole part", () => {
    expect(parseUsdc(".50")).toBe(500_000n);
    expect(parseUsdc(".001")).toBe(1_000n);
  });

  it("should handle max precision (6 decimals)", () => {
    expect(parseUsdc("0.000001")).toBe(1n);
    expect(parseUsdc("1.000001")).toBe(1_000_001n);
  });

  it("should handle whitespace", () => {
    expect(parseUsdc("  100  ")).toBe(100_000_000n);
    expect(parseUsdc(" 1.50 ")).toBe(1_500_000n);
  });

  it("should throw for non-numeric input", () => {
    expect(() => parseUsdc("abc")).toThrow();
    expect(() => parseUsdc("1.2a")).toThrow();
    expect(() => parseUsdc("$100")).toThrow();
  });
});

// ============================================================
// 14. formatUsdc ↔ parseUsdc round-trip
// ============================================================

describe("formatUsdc ↔ parseUsdc round-trip", () => {
  it("format → parse should return original (2 decimal places)", () => {
    const values = [
      0n,
      1_000_000n,
      10_500_000n,
      100_000_000n,
      999_990_000n,
    ];

    for (const v of values) {
      // Round to 2 decimals first (formatUsdc truncates)
      const rounded = (v / 10_000n) * 10_000n;
      const formatted = formatUsdc(rounded, 2);
      const parsed = parseUsdc(formatted);
      expect(parsed).toBe(rounded);
    }
  });

  it("format with 6 decimals → parse should preserve full precision", () => {
    const values = [1n, 123_456n, 1_234_567n, 999_999n];

    for (const v of values) {
      const formatted = formatUsdc(v, 6);
      const parsed = parseUsdc(formatted);
      expect(parsed).toBe(v);
    }
  });
});

// ============================================================
// 15. minOutWithSlippage
// ============================================================

describe("minOutWithSlippage properties", () => {
  it("0 slippage should return full amount", () => {
    expect(minOutWithSlippage(100_000_000n, 0n)).toBe(100_000_000n);
  });

  it("slippage > 100% should return 0", () => {
    expect(minOutWithSlippage(100_000_000n, 10_001n)).toBe(0n);
    expect(minOutWithSlippage(100_000_000n, 20_000n)).toBe(0n);
  });

  it("should be monotonically decreasing with slippage", () => {
    const base = 100_000_000n;
    let prev = base;

    for (const slippage of [50n, 100n, 200n, 500n, 1000n, 5000n]) {
      const result = minOutWithSlippage(base, slippage);
      expect(result).toBeLessThanOrEqual(prev);
      prev = result;
    }
  });
});

// ============================================================
// 16. calculatePriceImpact
// ============================================================

describe("calculatePriceImpact", () => {
  it("should return 0 for same price", () => {
    expect(calculatePriceImpact(5000n, 5000n)).toBe(0n);
  });

  it("should be symmetric", () => {
    expect(calculatePriceImpact(3000n, 7000n)).toBe(
      calculatePriceImpact(7000n, 3000n)
    );
  });

  it("larger trades should have larger impact", () => {
    const state = createState();
    const small = simulateBuyYes(state, 1_000_000n);
    const large = simulateBuyYes(state, 50_000_000n);

    expect(large.priceImpactBps).toBeGreaterThan(small.priceImpactBps);
  });
});
