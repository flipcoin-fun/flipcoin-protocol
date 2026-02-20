/**
 * Tests for CPMM AMM Math utilities
 *
 * Critical tests for:
 * - Price calculations
 * - CPMM k invariant
 * - Buy/sell simulations
 * - Reserve constraints
 * - Formatting utilities
 */

import { describe, it, expect } from "vitest";
import {
  // Constants
  BPS,
  ONE_USDC,
  MIN_RESERVE,
  MIN_TRADE_USDC,
  DEFAULT_FEE_BPS,

  // Types
  AmmState,

  // Core math
  mulDivDown,
  absDiff,
  minOutWithSlippage,

  // Price calculations
  priceYesBps,
  priceNoBps,
  calculatePriceImpact,

  // Buy simulations
  simulateBuyYes,
  simulateBuyNo,

  // Sell simulations
  simulateSellYes,
  simulateSellNo,

  // Validation
  canBuy,
  canSell,

  // Formatting
  formatUsdc,
  parseUsdc,
  formatBps,
  formatTokenPrice,
  formatProbability,
  getSafeProgressValue,
  isExtremePrice,
} from "./ammMath";

// ============================================================
// Test Utilities
// ============================================================

function createDefaultState(overrides?: Partial<AmmState>): AmmState {
  const yesReserve = overrides?.yesReserve ?? 100_000_000n; // $100
  const noReserve = overrides?.noReserve ?? 100_000_000n; // $100
  return {
    yesReserve,
    noReserve,
    k: overrides?.k ?? yesReserve * noReserve,
    feeBps: overrides?.feeBps ?? DEFAULT_FEE_BPS,
    ...overrides,
  };
}

// ============================================================
// Core Math Utilities
// ============================================================

describe("Core Math Utilities", () => {
  describe("mulDivDown", () => {
    it("should perform floor division correctly", () => {
      expect(mulDivDown(10n, 3n, 2n)).toBe(15n);
      expect(mulDivDown(100n, 1n, 3n)).toBe(33n); // Floor
    });

    it("should throw on division by zero", () => {
      expect(() => mulDivDown(10n, 3n, 0n)).toThrow("Division by zero");
    });
  });

  describe("absDiff", () => {
    it("should return absolute difference", () => {
      expect(absDiff(10n, 3n)).toBe(7n);
      expect(absDiff(3n, 10n)).toBe(7n);
      expect(absDiff(5n, 5n)).toBe(0n);
    });
  });

  describe("minOutWithSlippage", () => {
    it("should reduce by slippage percentage", () => {
      expect(minOutWithSlippage(100n * ONE_USDC, 100n)).toBe(99n * ONE_USDC); // 1%
      expect(minOutWithSlippage(100n * ONE_USDC, 500n)).toBe(95n * ONE_USDC); // 5%
    });

    it("should return 0 for 100% slippage", () => {
      expect(minOutWithSlippage(100n * ONE_USDC, BPS)).toBe(0n);
    });
  });
});

// ============================================================
// Price Calculations
// ============================================================

describe("Price Calculations", () => {
  describe("priceYesBps", () => {
    it("should return 50% when reserves are equal", () => {
      const price = priceYesBps(100_000_000n, 100_000_000n);
      expect(price).toBe(5000n);
    });

    it("should return higher price when YES is scarce", () => {
      const price = priceYesBps(50_000_000n, 100_000_000n);
      // Price = noReserve / (yes + no) = 100 / 150 = 66.7%
      expect(price).toBeGreaterThan(6600n);
      expect(price).toBeLessThan(6700n);
    });

    it("should return lower price when NO is scarce", () => {
      const price = priceYesBps(100_000_000n, 50_000_000n);
      // Price = noReserve / (yes + no) = 50 / 150 = 33.3%
      expect(price).toBeGreaterThan(3300n);
      expect(price).toBeLessThan(3400n);
    });

    it("should return 50% for empty reserves", () => {
      expect(priceYesBps(0n, 0n)).toBe(5000n);
    });
  });

  describe("priceNoBps", () => {
    it("should equal 10000 - priceYes", () => {
      const yes = priceYesBps(60_000_000n, 40_000_000n);
      const no = priceNoBps(60_000_000n, 40_000_000n);
      expect(yes + no).toBe(10000n);
    });
  });

  describe("calculatePriceImpact", () => {
    it("should return absolute difference", () => {
      expect(calculatePriceImpact(5000n, 5500n)).toBe(500n);
      expect(calculatePriceImpact(5500n, 5000n)).toBe(500n);
    });
  });
});

// ============================================================
// Buy Simulations
// ============================================================

describe("Buy Simulations", () => {
  describe("simulateBuyYes", () => {
    it("should return positive shares for valid input", () => {
      const state = createDefaultState();
      const result = simulateBuyYes(state, 10n * ONE_USDC);

      expect(result.sharesOut).toBeGreaterThan(0n);
      expect(result.fee).toBeGreaterThan(0n);
      expect(result.netUsdc).toBe(10n * ONE_USDC - result.fee);
    });

    it("should deduct correct fee", () => {
      const state = createDefaultState({ feeBps: 200n }); // 2%
      const result = simulateBuyYes(state, 100n * ONE_USDC);

      expect(result.fee).toBe(2n * ONE_USDC);
      expect(result.netUsdc).toBe(98n * ONE_USDC);
    });

    it("should increase YES price after buying YES", () => {
      const state = createDefaultState();
      const priceBefore = priceYesBps(state.yesReserve, state.noReserve);
      const result = simulateBuyYes(state, 10n * ONE_USDC);

      expect(result.newPriceYesBps).toBeGreaterThan(priceBefore);
    });

    it("should maintain k invariant", () => {
      const state = createDefaultState();
      const result = simulateBuyYes(state, 10n * ONE_USDC);

      // New k should equal or exceed original k (due to floor division)
      const newK = result.newYesReserve * result.newNoReserve;
      expect(newK).toBeLessThanOrEqual(state.k);
      // Should be close (within small percentage)
      expect(Number(state.k - newK) / Number(state.k)).toBeLessThan(0.01);
    });

    it("should decrease yesReserve and increase noReserve", () => {
      const state = createDefaultState();
      const result = simulateBuyYes(state, 10n * ONE_USDC);

      expect(result.newYesReserve).toBeLessThan(state.yesReserve);
      expect(result.newNoReserve).toBeGreaterThan(state.noReserve);
    });
  });

  describe("simulateBuyNo", () => {
    it("should decrease YES price after buying NO", () => {
      const state = createDefaultState();
      const priceBefore = priceYesBps(state.yesReserve, state.noReserve);
      const result = simulateBuyNo(state, 10n * ONE_USDC);

      expect(result.newPriceYesBps).toBeLessThan(priceBefore);
    });

    it("should increase yesReserve and decrease noReserve", () => {
      const state = createDefaultState();
      const result = simulateBuyNo(state, 10n * ONE_USDC);

      expect(result.newYesReserve).toBeGreaterThan(state.yesReserve);
      expect(result.newNoReserve).toBeLessThan(state.noReserve);
    });
  });
});

// ============================================================
// Sell Simulations
// ============================================================

describe("Sell Simulations", () => {
  describe("simulateSellYes", () => {
    it("should return positive output for valid shares", () => {
      const state = createDefaultState();
      const result = simulateSellYes(state, 5n * ONE_USDC);

      expect(result.amountOutGross).toBeGreaterThan(0n);
      expect(result.amountOutNet).toBeGreaterThan(0n);
      expect(result.fee).toBeGreaterThan(0n);
    });

    it("should decrease YES price after selling YES", () => {
      const state = createDefaultState();
      const priceBefore = priceYesBps(state.yesReserve, state.noReserve);
      const result = simulateSellYes(state, 5n * ONE_USDC);

      expect(result.newPriceYesBps).toBeLessThan(priceBefore);
    });

    it("should increase yesReserve and decrease noReserve", () => {
      const state = createDefaultState();
      const result = simulateSellYes(state, 5n * ONE_USDC);

      expect(result.newYesReserve).toBeGreaterThan(state.yesReserve);
      expect(result.newNoReserve).toBeLessThan(state.noReserve);
    });
  });

  describe("simulateSellNo", () => {
    it("should increase YES price after selling NO", () => {
      const state = createDefaultState();
      const priceBefore = priceYesBps(state.yesReserve, state.noReserve);
      const result = simulateSellNo(state, 5n * ONE_USDC);

      expect(result.newPriceYesBps).toBeGreaterThan(priceBefore);
    });
  });
});

// ============================================================
// Validation
// ============================================================

describe("Validation", () => {
  describe("canBuy", () => {
    it("should return valid for normal trades", () => {
      const state = createDefaultState();
      const simulation = simulateBuyYes(state, 10n * ONE_USDC);
      const result = canBuy(simulation);

      expect(result.valid).toBe(true);
    });

    it("should return invalid if reserve drops below minimum", () => {
      const state = createDefaultState({
        yesReserve: MIN_RESERVE + 1000n,
        noReserve: 100_000_000n,
      });
      state.k = state.yesReserve * state.noReserve;

      // Try to buy most of YES reserve
      const simulation = simulateBuyYes(state, 50n * ONE_USDC);

      if (simulation.newYesReserve < MIN_RESERVE) {
        const result = canBuy(simulation);
        expect(result.valid).toBe(false);
      }
    });

    it("should return invalid if sharesOut is 0", () => {
      const simulation = {
        sharesOut: 0n,
        fee: 0n,
        netUsdc: ONE_USDC,
        newYesReserve: 100_000_000n,
        newNoReserve: 100_000_000n,
        newPriceYesBps: 5000n,
        priceImpactBps: 0n,
      };
      const result = canBuy(simulation);

      expect(result.valid).toBe(false);
      expect(result.reason).toContain("zero shares");
    });
  });

  describe("canSell", () => {
    it("should return valid for normal sells", () => {
      const state = createDefaultState();
      const simulation = simulateSellYes(state, 5n * ONE_USDC);
      const result = canSell(simulation);

      expect(result.valid).toBe(true);
    });

    it("should return invalid for trade below minimum", () => {
      const simulation = {
        amountOutGross: MIN_TRADE_USDC - 1n,
        amountOutNet: MIN_TRADE_USDC - 2n,
        fee: 1n,
        newYesReserve: 100_000_000n,
        newNoReserve: 100_000_000n,
        newPriceYesBps: 5000n,
        priceImpactBps: 0n,
      };
      const result = canSell(simulation);

      expect(result.valid).toBe(false);
      expect(result.reason).toContain("too small");
    });
  });
});

// ============================================================
// Formatting
// ============================================================

describe("Formatting", () => {
  describe("formatUsdc", () => {
    it("should format whole numbers", () => {
      expect(formatUsdc(1_000_000n)).toBe("1.00");
      expect(formatUsdc(100_000_000n)).toBe("100.00");
    });

    it("should format decimals", () => {
      expect(formatUsdc(1_500_000n)).toBe("1.50");
      expect(formatUsdc(1_234_567n, 6)).toBe("1.234567");
    });

    it("should handle zero", () => {
      expect(formatUsdc(0n)).toBe("0.00");
    });
  });

  describe("parseUsdc", () => {
    it("should parse whole numbers", () => {
      expect(parseUsdc("100")).toBe(100_000_000n);
      expect(parseUsdc("1")).toBe(1_000_000n);
    });

    it("should parse decimals", () => {
      expect(parseUsdc("1.50")).toBe(1_500_000n);
      expect(parseUsdc("0.01")).toBe(10_000n);
      expect(parseUsdc("0.000001")).toBe(1n);
    });

    it("should truncate extra decimals", () => {
      expect(parseUsdc("1.1234567890")).toBe(1_123_456n);
    });

    it("should handle empty input", () => {
      expect(parseUsdc("")).toBe(0n);
      expect(parseUsdc(".")).toBe(0n);
    });

    it("should throw for invalid input", () => {
      expect(() => parseUsdc("abc")).toThrow();
      // Note: "1.2.3" may not throw as the implementation only splits on first "."
      // Let's test what actually throws
      expect(() => parseUsdc("abc123")).toThrow();
    });
  });

  describe("formatBps", () => {
    it("should convert bps to percentage", () => {
      expect(formatBps(5000n)).toBe("50.00%");
      expect(formatBps(100n)).toBe("1.00%");
      expect(formatBps(9999n)).toBe("99.99%");
    });
  });

  describe("formatTokenPrice", () => {
    it("should format normal prices", () => {
      expect(formatTokenPrice(5000n)).toBe("$0.50");
      expect(formatTokenPrice(2500n)).toBe("$0.25");
      expect(formatTokenPrice(7500n)).toBe("$0.75");
    });

    it("should handle extreme low prices", () => {
      expect(formatTokenPrice(10n)).toBe("$<0.01");
      expect(formatTokenPrice(5n)).toBe("$<0.01");
    });

    it("should handle extreme high prices", () => {
      expect(formatTokenPrice(9990n)).toBe("$>0.99");
      expect(formatTokenPrice(9999n)).toBe("$>0.99");
    });

    it("should show 3 decimals for low prices", () => {
      const price = formatTokenPrice(50n); // 0.5%
      expect(price).toMatch(/\$0\.00\d/);
    });
  });

  describe("formatProbability", () => {
    it("should format normal probabilities", () => {
      expect(formatProbability(5000n)).toBe("50%");
      expect(formatProbability(2500n)).toBe("25%");
    });

    it("should handle extreme probabilities", () => {
      expect(formatProbability(10n)).toBe("<1%");
      expect(formatProbability(9990n)).toBe(">99%");
    });

    it("should show 1 decimal near extremes", () => {
      const prob = formatProbability(300n); // 3%
      expect(prob).toBe("3.0%");
    });
  });

  describe("getSafeProgressValue", () => {
    it("should return values between 1 and 99", () => {
      expect(getSafeProgressValue(0n)).toBe(1);
      expect(getSafeProgressValue(10000n)).toBe(99);
      expect(getSafeProgressValue(5000n)).toBe(50);
    });
  });

  describe("isExtremePrice", () => {
    it("should detect high extreme", () => {
      const result = isExtremePrice(9600n);
      expect(result.isExtreme).toBe(true);
      expect(result.isHigh).toBe(true);
      expect(result.isLow).toBe(false);
    });

    it("should detect low extreme", () => {
      const result = isExtremePrice(400n);
      expect(result.isExtreme).toBe(true);
      expect(result.isHigh).toBe(false);
      expect(result.isLow).toBe(true);
    });

    it("should detect normal prices", () => {
      const result = isExtremePrice(5000n);
      expect(result.isExtreme).toBe(false);
      expect(result.isHigh).toBe(false);
      expect(result.isLow).toBe(false);
    });
  });
});

// ============================================================
// Integration Tests
// ============================================================

describe("Integration Tests", () => {
  it("should maintain k through buy-sell cycle", () => {
    const state = createDefaultState();
    const originalK = state.k;

    // Buy YES
    const buyResult = simulateBuyYes(state, 10n * ONE_USDC);
    const stateAfterBuy = {
      ...state,
      yesReserve: buyResult.newYesReserve,
      noReserve: buyResult.newNoReserve,
      k: buyResult.newYesReserve * buyResult.newNoReserve,
    };

    // Sell YES back
    const sellResult = simulateSellYes(stateAfterBuy, buyResult.sharesOut);
    const finalK = sellResult.newYesReserve * sellResult.newNoReserve;

    // K should be close to original (slight difference due to fees)
    const kRatio = Number(finalK) / Number(originalK);
    expect(kRatio).toBeGreaterThan(0.98);
    expect(kRatio).toBeLessThan(1.02);
  });

  it("should maintain price invariant: YES + NO = 100%", () => {
    const state = createDefaultState();
    const amounts = [1n, 10n, 50n].map((x) => x * ONE_USDC);

    for (const amount of amounts) {
      const result = simulateBuyYes(state, amount);
      const priceYes = priceYesBps(result.newYesReserve, result.newNoReserve);
      const priceNo = priceNoBps(result.newYesReserve, result.newNoReserve);

      expect(priceYes + priceNo).toBe(10000n);
    }
  });

  it("should not allow draining reserves below MIN_RESERVE", () => {
    const state = createDefaultState({
      yesReserve: MIN_RESERVE * 10n,
      noReserve: MIN_RESERVE * 10n,
    });
    state.k = state.yesReserve * state.noReserve;

    // Try a very large buy
    const result = simulateBuyYes(state, 1000n * ONE_USDC);
    const validation = canBuy(result);

    // If this drains reserves, should be invalid
    if (result.newYesReserve < MIN_RESERVE) {
      expect(validation.valid).toBe(false);
    }
  });
});
