/**
 * Tests for LMSR Math utilities
 *
 * Critical tests for:
 * - Price calculations (sigmoid)
 * - Cost function (Log-Sum-Exp)
 * - Buy/sell simulations
 * - Polymarket-style guarantee (sharesOut >= net)
 * - Slippage calculations
 */

import { describe, it, expect } from "vitest";
import {
  // Constants
  BPS,
  ONE_USDC,
  UNIT,
  LN2,
  LIQUIDITY_TIERS,
  MIN_TRADE_USDC,

  // Types
  LmsrState,
  LiquidityTier,

  // Core math
  mulDivDown,
  abs,
  absDiff,
  expApprox,
  lnApprox,

  // Price calculations
  lmsrPriceYesBps,
  lmsrPriceNoBps,

  // Cost function
  lmsrCostUsdc,

  // Buy/sell simulations
  simulateLmsrBuyYes,
  simulateLmsrBuyNo,
  simulateLmsrSellYes,
  simulateLmsrSellNo,

  // Validation
  canLmsrBuy,
  canLmsrSell,
  minOutWithSlippage,

  // Formatting
  formatUsdc,
  parseUsdc,
  formatBps,

  // Initial price
  calcInitialQ,
  calcMaxLossUsdc,
  calcBFromSeed,
  getTierWithAdjustedSeed,
} from "./lmsrMath";

// ============================================================
// Test Utilities
// ============================================================

function createDefaultState(overrides?: Partial<LmsrState>): LmsrState {
  return {
    b: 200n * UNIT, // Medium tier
    qYes: 0n,
    qNo: 0n,
    feeBps: 200n, // 2%
    yesSharesTotal: 0n,
    noSharesTotal: 0n,
    ...overrides,
  };
}

// ============================================================
// Core Math Utilities
// ============================================================

describe("Core Math Utilities", () => {
  describe("mulDivDown", () => {
    it("should perform floor division correctly", () => {
      expect(mulDivDown(10n, 3n, 2n)).toBe(15n); // 10 * 3 / 2 = 15
      expect(mulDivDown(100n, 1n, 3n)).toBe(33n); // Floor(100/3) = 33
    });

    it("should throw on division by zero", () => {
      expect(() => mulDivDown(10n, 3n, 0n)).toThrow("Division by zero");
    });
  });

  describe("abs", () => {
    it("should return absolute value", () => {
      expect(abs(-10n)).toBe(10n);
      expect(abs(10n)).toBe(10n);
      expect(abs(0n)).toBe(0n);
    });
  });

  describe("absDiff", () => {
    it("should return absolute difference", () => {
      expect(absDiff(10n, 3n)).toBe(7n);
      expect(absDiff(3n, 10n)).toBe(7n);
      expect(absDiff(5n, 5n)).toBe(0n);
    });
  });

  describe("expApprox", () => {
    it("should approximate exp(0) = 1", () => {
      const result = expApprox(0n);
      expect(result).toBe(UNIT); // 1e18
    });

    it("should approximate exp(1) ≈ 2.718", () => {
      const result = expApprox(UNIT);
      // e ≈ 2.71828..., so result should be ~2.71e18
      const expected = 2718281828n * 10n ** 9n; // 2.718 * 1e18
      const tolerance = UNIT / 100n; // 1% tolerance
      expect(abs(result - expected)).toBeLessThan(tolerance);
    });

    it("should clamp at large positive values", () => {
      const result = expApprox(30n * UNIT);
      expect(result).toBe(485165195n * UNIT); // Clamped to e^20
    });

    it("should return ~0 for large negative values", () => {
      const result = expApprox(-30n * UNIT);
      expect(result).toBe(0n);
    });
  });

  describe("lnApprox", () => {
    it("should approximate ln(1) = 0", () => {
      const result = lnApprox(UNIT);
      expect(abs(result)).toBeLessThan(UNIT / 1000n); // Close to 0
    });

    it("should approximate ln(e) ≈ 1", () => {
      const e = 2718281828459045235n;
      const result = lnApprox(e);
      const tolerance = UNIT / 100n; // 1%
      expect(abs(result - UNIT)).toBeLessThan(tolerance);
    });

    it("should throw for non-positive input", () => {
      expect(() => lnApprox(0n)).toThrow("ln of non-positive number");
      expect(() => lnApprox(-1n)).toThrow("ln of non-positive number");
    });
  });
});

// ============================================================
// Price Calculations
// ============================================================

describe("Price Calculations", () => {
  describe("lmsrPriceYesBps", () => {
    it("should return 50% (5000 bps) when qYes == qNo", () => {
      const b = 200n * UNIT;
      const price = lmsrPriceYesBps(b, 0n, 0n);
      expect(price).toBe(5000n);
    });

    it("should return higher price when qYes > qNo", () => {
      const b = 200n * UNIT;
      const price = lmsrPriceYesBps(b, 100n * UNIT, 0n);
      expect(price).toBeGreaterThan(5000n);
    });

    it("should return lower price when qYes < qNo", () => {
      const b = 200n * UNIT;
      const price = lmsrPriceYesBps(b, 0n, 100n * UNIT);
      expect(price).toBeLessThan(5000n);
    });

    it("should clamp at extreme values (never 0 or 10000)", () => {
      const b = 200n * UNIT;
      // Very high qYes
      const highPrice = lmsrPriceYesBps(b, 5000n * UNIT, 0n);
      expect(highPrice).toBeLessThanOrEqual(9999n);
      expect(highPrice).toBeGreaterThan(9900n);

      // Very high qNo
      const lowPrice = lmsrPriceYesBps(b, 0n, 5000n * UNIT);
      expect(lowPrice).toBeGreaterThanOrEqual(1n);
      expect(lowPrice).toBeLessThan(100n);
    });

    it("should return 5000 when b is 0", () => {
      const price = lmsrPriceYesBps(0n, 100n, 50n);
      expect(price).toBe(5000n);
    });
  });

  describe("lmsrPriceNoBps", () => {
    it("should equal 10000 - priceYes", () => {
      const b = 200n * UNIT;
      const priceYes = lmsrPriceYesBps(b, 50n * UNIT, 30n * UNIT);
      const priceNo = lmsrPriceNoBps(b, 50n * UNIT, 30n * UNIT);
      expect(priceYes + priceNo).toBe(10000n);
    });
  });
});

// ============================================================
// Cost Function
// ============================================================

describe("Cost Function", () => {
  describe("lmsrCostUsdc", () => {
    it("should return 0 when b is 0", () => {
      const cost = lmsrCostUsdc(0n, 100n, 50n);
      expect(cost).toBe(0n);
    });

    it("should return b * ln(2) when qYes == qNo == 0", () => {
      const b = 200n * UNIT;
      const cost = lmsrCostUsdc(b, 0n, 0n);
      // C(0, 0) = b * ln(e^0 + e^0) = b * ln(2)
      const expectedCost = calcMaxLossUsdc(b);
      // Use larger tolerance as approximations may differ
      const tolerance = 15n * ONE_USDC; // $15 tolerance (due to Taylor series approximation)
      expect(abs(cost - expectedCost)).toBeLessThan(tolerance);
    });

    it("should increase when shares are bought", () => {
      const b = 200n * UNIT;
      const costBefore = lmsrCostUsdc(b, 0n, 0n);
      const costAfter = lmsrCostUsdc(b, 10n * UNIT, 0n);
      expect(costAfter).toBeGreaterThan(costBefore);
    });

    it("should be symmetric for qYes and qNo", () => {
      const b = 200n * UNIT;
      const cost1 = lmsrCostUsdc(b, 50n * UNIT, 30n * UNIT);
      const cost2 = lmsrCostUsdc(b, 30n * UNIT, 50n * UNIT);
      expect(cost1).toBe(cost2);
    });
  });
});

// ============================================================
// Buy Simulations
// ============================================================

describe("Buy Simulations", () => {
  describe("simulateLmsrBuyYes", () => {
    it("should return positive shares for valid input", () => {
      const state = createDefaultState();
      const result = simulateLmsrBuyYes(state, 10n * ONE_USDC);

      expect(result.sharesOut).toBeGreaterThan(0n);
      expect(result.fee).toBeGreaterThan(0n);
      expect(result.netUsdc).toBe(10n * ONE_USDC - result.fee);
    });

    it("should deduct 2% fee correctly", () => {
      const state = createDefaultState({ feeBps: 200n });
      const result = simulateLmsrBuyYes(state, 100n * ONE_USDC);

      expect(result.fee).toBe(2n * ONE_USDC); // 2% of 100
      expect(result.netUsdc).toBe(98n * ONE_USDC);
    });

    it("should increase YES price after buying YES", () => {
      const state = createDefaultState();
      const priceBefore = lmsrPriceYesBps(state.b, state.qYes, state.qNo);
      const result = simulateLmsrBuyYes(state, 50n * ONE_USDC);

      expect(result.newPriceYesBps).toBeGreaterThan(priceBefore);
    });

    it("should pass Polymarket-style guarantee: sharesOut >= netUsdc", () => {
      const state = createDefaultState();
      const result = simulateLmsrBuyYes(state, 10n * ONE_USDC);

      // This is the critical invariant: you can never pay more than $1 per share
      // So if you win, you get at least $1 payout per share
      expect(result.sharesOut).toBeGreaterThanOrEqual(result.netUsdc);
    });

    it("should return avgPricePerShare <= $1", () => {
      const state = createDefaultState();
      const result = simulateLmsrBuyYes(state, 10n * ONE_USDC);

      // avgPricePerShare = netUsdc * ONE_USDC / sharesOut
      // Should be <= ONE_USDC ($1)
      expect(result.avgPricePerShare).toBeLessThanOrEqual(ONE_USDC);
    });
  });

  describe("simulateLmsrBuyNo", () => {
    it("should decrease YES price after buying NO", () => {
      const state = createDefaultState();
      const priceBefore = lmsrPriceYesBps(state.b, state.qYes, state.qNo);
      const result = simulateLmsrBuyNo(state, 50n * ONE_USDC);

      expect(result.newPriceYesBps).toBeLessThan(priceBefore);
    });

    it("should update qNo correctly", () => {
      const state = createDefaultState();
      const result = simulateLmsrBuyNo(state, 10n * ONE_USDC);

      expect(result.newQNo).toBeGreaterThan(state.qNo);
      expect(result.newQYes).toBe(state.qYes);
    });
  });
});

// ============================================================
// Sell Simulations
// ============================================================

describe("Sell Simulations", () => {
  describe("simulateLmsrSellYes", () => {
    it("should return positive amountOut for valid shares", () => {
      // First buy some shares
      const state = createDefaultState({ qYes: 50n * UNIT });
      const result = simulateLmsrSellYes(state, 10n * ONE_USDC);

      expect(result.amountOutGross).toBeGreaterThan(0n);
      expect(result.amountOutNet).toBeGreaterThan(0n);
      expect(result.amountOutNet).toBeLessThan(result.amountOutGross);
    });

    it("should decrease YES price after selling YES", () => {
      const state = createDefaultState({ qYes: 50n * UNIT });
      const priceBefore = lmsrPriceYesBps(state.b, state.qYes, state.qNo);
      const result = simulateLmsrSellYes(state, 10n * ONE_USDC);

      expect(result.newPriceYesBps).toBeLessThan(priceBefore);
    });
  });

  describe("simulateLmsrSellNo", () => {
    it("should increase YES price after selling NO", () => {
      const state = createDefaultState({ qNo: 50n * UNIT });
      const priceBefore = lmsrPriceYesBps(state.b, state.qYes, state.qNo);
      const result = simulateLmsrSellNo(state, 10n * ONE_USDC);

      expect(result.newPriceYesBps).toBeGreaterThan(priceBefore);
    });
  });
});

// ============================================================
// Validation
// ============================================================

describe("Validation", () => {
  describe("canLmsrBuy", () => {
    it("should return valid for normal trades", () => {
      const state = createDefaultState();
      const simulation = simulateLmsrBuyYes(state, 10n * ONE_USDC);
      const result = canLmsrBuy(simulation);

      expect(result.valid).toBe(true);
    });

    it("should return invalid if sharesOut is 0", () => {
      const simulation = {
        sharesOut: 0n,
        fee: 0n,
        netUsdc: ONE_USDC,
        newQYes: 0n,
        newQNo: 0n,
        newPriceYesBps: 5000n,
        priceImpactBps: 0n,
        avgPricePerShare: 0n,
      };
      const result = canLmsrBuy(simulation);

      expect(result.valid).toBe(false);
      expect(result.reason).toContain("zero shares");
    });

    it("should return invalid if sharesOut < netUsdc (price > $1)", () => {
      const simulation = {
        sharesOut: 500_000n, // $0.50
        fee: 20_000n,
        netUsdc: 1_000_000n, // $1.00
        newQYes: 0n,
        newQNo: 0n,
        newPriceYesBps: 5000n,
        priceImpactBps: 0n,
        avgPricePerShare: 2_000_000n,
      };
      const result = canLmsrBuy(simulation);

      expect(result.valid).toBe(false);
      expect(result.reason).toContain("lose money");
    });
  });

  describe("canLmsrSell", () => {
    it("should return valid for normal sells", () => {
      const state = createDefaultState({ qYes: 50n * UNIT });
      const simulation = simulateLmsrSellYes(state, 10n * ONE_USDC);
      const result = canLmsrSell(simulation);

      expect(result.valid).toBe(true);
    });

    it("should return invalid for trades below minimum", () => {
      const simulation = {
        amountOutGross: MIN_TRADE_USDC - 1n,
        amountOutNet: MIN_TRADE_USDC - 2n,
        fee: 1n,
        newQYes: 0n,
        newQNo: 0n,
        newPriceYesBps: 5000n,
        priceImpactBps: 0n,
      };
      const result = canLmsrSell(simulation);

      expect(result.valid).toBe(false);
      expect(result.reason).toContain("too small");
    });
  });

  describe("minOutWithSlippage", () => {
    it("should reduce output by slippage percentage", () => {
      const expected = 100n * ONE_USDC;
      const result = minOutWithSlippage(expected, 100n); // 1% slippage

      expect(result).toBe(99n * ONE_USDC);
    });

    it("should return 0 for 100% slippage", () => {
      const expected = 100n * ONE_USDC;
      const result = minOutWithSlippage(expected, BPS);

      expect(result).toBe(0n);
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

    it("should handle negative numbers", () => {
      expect(formatUsdc(-1_000_000n)).toBe("-1.00");
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
    });

    it("should truncate extra decimals", () => {
      expect(parseUsdc("1.1234567890")).toBe(1_123_456n);
    });

    it("should handle empty/invalid", () => {
      expect(parseUsdc("")).toBe(0n);
      expect(parseUsdc(".")).toBe(0n);
    });
  });

  describe("formatBps", () => {
    it("should convert bps to percentage", () => {
      expect(formatBps(5000n)).toBe("50.00%");
      expect(formatBps(100n)).toBe("1.00%");
      expect(formatBps(9999n)).toBe("99.99%");
    });
  });
});

// ============================================================
// Liquidity Tiers
// ============================================================

describe("Liquidity Tiers", () => {
  describe("LIQUIDITY_TIERS", () => {
    it("should have all tiers defined", () => {
      expect(LIQUIDITY_TIERS.low).toBeDefined();
      expect(LIQUIDITY_TIERS.medium).toBeDefined();
      expect(LIQUIDITY_TIERS.high).toBeDefined();
    });

    it("should have correct seed amounts", () => {
      expect(LIQUIDITY_TIERS.low.seedUsdc).toBe(35n * ONE_USDC);
      expect(LIQUIDITY_TIERS.medium.seedUsdc).toBe(139n * ONE_USDC);
      expect(LIQUIDITY_TIERS.high.seedUsdc).toBe(693n * ONE_USDC);
    });
  });

  describe("calcMaxLossUsdc", () => {
    it("should calculate max loss = b * ln(2)", () => {
      // Low tier: b = 50, maxLoss ≈ 50 * 0.693 = 34.65
      const maxLossLow = calcMaxLossUsdc(LIQUIDITY_TIERS.low.b);
      expect(maxLossLow).toBeGreaterThan(34n * ONE_USDC);
      expect(maxLossLow).toBeLessThan(36n * ONE_USDC);

      // Medium tier: b = 200, maxLoss ≈ 200 * 0.693 = 138.6
      const maxLossMedium = calcMaxLossUsdc(LIQUIDITY_TIERS.medium.b);
      expect(maxLossMedium).toBeGreaterThan(137n * ONE_USDC);
      expect(maxLossMedium).toBeLessThan(140n * ONE_USDC);
    });
  });

  describe("calcBFromSeed", () => {
    it("should invert calcMaxLossUsdc", () => {
      const seedUsdc = 100n * ONE_USDC;
      const b = calcBFromSeed(seedUsdc);
      const maxLoss = calcMaxLossUsdc(b);

      // maxLoss should be approximately seedUsdc
      const tolerance = ONE_USDC; // $1
      expect(abs(maxLoss - seedUsdc)).toBeLessThan(tolerance);
    });
  });
});

// ============================================================
// Initial Price
// ============================================================

describe("Initial Price", () => {
  describe("calcInitialQ", () => {
    it("should calculate qYes, qNo for 50/50 price", () => {
      const b = 200n * UNIT;
      const { qYes, qNo } = calcInitialQ(b, 5000n);

      // At 50/50, qYes should equal qNo (both ~0)
      expect(abs(qYes - qNo)).toBeLessThan(UNIT);
    });

    it("should calculate higher qYes for >50% initial price", () => {
      const b = 200n * UNIT;
      const { qYes, qNo } = calcInitialQ(b, 7000n); // 70%

      expect(qYes).toBeGreaterThan(qNo);
    });

    it("should throw for invalid prices", () => {
      const b = 200n * UNIT;
      expect(() => calcInitialQ(b, 0n)).toThrow();
      expect(() => calcInitialQ(b, 10000n)).toThrow();
    });
  });

  describe("getTierWithAdjustedSeed", () => {
    it("should return base seed for 50/50 price", () => {
      const result = getTierWithAdjustedSeed("medium", 5000n);

      expect(result.adjustedSeedUsdc).toBe(LIQUIDITY_TIERS.medium.seedUsdc);
    });

    it("should require more seed for biased initial price", () => {
      const result5050 = getTierWithAdjustedSeed("medium", 5000n);
      const result8020 = getTierWithAdjustedSeed("medium", 8000n);

      expect(result8020.adjustedSeedUsdc).toBeGreaterThan(
        result5050.adjustedSeedUsdc
      );
    });
  });
});

// ============================================================
// Integration Tests
// ============================================================

describe("Integration Tests", () => {
  it("should maintain price consistency through buy-sell cycle", () => {
    const state = createDefaultState();
    const buyAmount = 10n * ONE_USDC;

    // Buy YES
    const buyResult = simulateLmsrBuyYes(state, buyAmount);

    // Update state
    const stateAfterBuy = {
      ...state,
      qYes: buyResult.newQYes,
      qNo: buyResult.newQNo,
    };

    // Sell the same shares back
    const sellResult = simulateLmsrSellYes(stateAfterBuy, buyResult.sharesOut);

    // Price should return close to original
    const originalPrice = lmsrPriceYesBps(state.b, state.qYes, state.qNo);
    const priceTolerance = 10n; // Allow 0.1% tolerance

    expect(abs(sellResult.newPriceYesBps - originalPrice)).toBeLessThan(
      priceTolerance
    );
  });

  it("should handle large trades without overflow", () => {
    const state = createDefaultState();
    const largeAmount = 1000n * ONE_USDC; // $1000

    const result = simulateLmsrBuyYes(state, largeAmount);

    expect(result.sharesOut).toBeGreaterThan(0n);
    expect(result.newPriceYesBps).toBeGreaterThan(5000n);
    expect(result.newPriceYesBps).toBeLessThanOrEqual(9999n);
  });

  it("should maintain YES + NO = 100%", () => {
    const state = createDefaultState();
    const amounts = [1n, 10n, 100n, 1000n].map((x) => x * ONE_USDC);

    for (const amount of amounts) {
      const result = simulateLmsrBuyYes(state, amount);
      const priceYes = result.newPriceYesBps;
      const priceNo = lmsrPriceNoBps(state.b, result.newQYes, result.newQNo);

      expect(priceYes + priceNo).toBe(10000n);
    }
  });
});
