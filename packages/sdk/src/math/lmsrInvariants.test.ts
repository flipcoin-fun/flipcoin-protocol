/**
 * LMSR invariant & property-based tests
 *
 * These tests verify critical protocol invariants that must hold
 * for any combination of parameters. Failures here indicate
 * potential loss-of-funds bugs.
 *
 * Invariants tested:
 * 1. Polymarket guarantee: sharesOut >= netUsdc (share price <= $1)
 * 2. Price sum: priceYes + priceNo == 10000 bps (always)
 * 3. Price monotonicity: buying YES increases YES price
 * 4. Cost function symmetry: C(a,b) == C(b,a)
 * 5. Buy-sell round-trip: price returns to ~original
 * 6. Liquidity tier seed covers max loss
 * 7. calcInitialQ round-trip: calcInitialQ → lmsrPriceYesBps ≈ input
 * 8. calcBFromSeed ↔ calcMaxLossUsdc inversion
 */

import { describe, it, expect } from "vitest";
import {
  // Constants
  BPS,
  ONE_USDC,
  UNIT,
  LIQUIDITY_TIERS,

  // Types
  LmsrState,
  LiquidityTier,

  // Core math
  abs,
  absDiff,

  // Price
  lmsrPriceYesBps,
  lmsrPriceNoBps,

  // Cost
  lmsrCostUsdc,

  // Simulations
  simulateLmsrBuyYes,
  simulateLmsrBuyNo,
  simulateLmsrSellYes,
  simulateLmsrSellNo,

  // Validation
  canLmsrBuy,

  // Initial price
  calcInitialQ,
  calcMaxLossUsdc,
  calcBFromSeed,
  getTierWithAdjustedSeed,
} from "./lmsrMath";

// ============================================================
// Helpers
// ============================================================

function createState(
  tier: LiquidityTier,
  initialPriceBps: bigint = 5000n,
  feeBps: bigint = 200n
): LmsrState {
  const { b } = LIQUIDITY_TIERS[tier];
  const { qYes, qNo } = calcInitialQ(b, initialPriceBps);
  return {
    b,
    qYes,
    qNo,
    feeBps,
    yesSharesTotal: 0n,
    noSharesTotal: 0n,
  };
}

// Pseudo-random amounts for property testing
const TEST_AMOUNTS = [
  10_000n, // 0.01 USDC (minimum)
  100_000n, // 0.10 USDC
  1_000_000n, // 1 USDC
  5_000_000n, // 5 USDC
  10_000_000n, // 10 USDC
  50_000_000n, // 50 USDC
  100_000_000n, // 100 USDC
  500_000_000n, // 500 USDC
];

const TEST_PRICES: bigint[] = [
  1000n, // 10%
  2000n, // 20%
  3000n, // 30%
  5000n, // 50%
  7000n, // 70%
  8000n, // 80%
  9000n, // 90%
];

const TIERS: LiquidityTier[] = ["low", "medium", "high"];

// ============================================================
// 1. Polymarket Guarantee (sharesOut >= netUsdc)
// ============================================================

describe("Polymarket Guarantee: sharesOut >= netUsdc", () => {
  for (const tier of TIERS) {
    describe(`${tier} tier`, () => {
      for (const price of TEST_PRICES) {
        for (const amount of TEST_AMOUNTS) {
          // Skip very large amounts for low tier (would be unreasonable)
          if (tier === "low" && amount > 100_000_000n) continue;

          it(`buyYes: ${tier} @ ${price}bps, $${Number(amount) / 1e6}`, () => {
            const state = createState(tier, price);
            const result = simulateLmsrBuyYes(state, amount);

            if (result.sharesOut > 0n) {
              expect(result.sharesOut).toBeGreaterThanOrEqual(result.netUsdc);
            }
          });

          it(`buyNo: ${tier} @ ${price}bps, $${Number(amount) / 1e6}`, () => {
            const state = createState(tier, price);
            const result = simulateLmsrBuyNo(state, amount);

            if (result.sharesOut > 0n) {
              expect(result.sharesOut).toBeGreaterThanOrEqual(result.netUsdc);
            }
          });
        }
      }
    });
  }
});

// ============================================================
// 2. Price Sum Invariant: YES + NO == 10000 bps
// ============================================================

describe("Price Sum Invariant: YES + NO == 10000", () => {
  it("should hold at initial state for all tiers and prices", () => {
    for (const tier of TIERS) {
      for (const price of TEST_PRICES) {
        const state = createState(tier, price);
        const pYes = lmsrPriceYesBps(state.b, state.qYes, state.qNo);
        const pNo = lmsrPriceNoBps(state.b, state.qYes, state.qNo);

        expect(pYes + pNo).toBe(10_000n);
      }
    }
  });

  it("should hold after trades", () => {
    for (const tier of TIERS) {
      const state = createState(tier);
      for (const amount of [1_000_000n, 10_000_000n, 50_000_000n]) {
        const result = simulateLmsrBuyYes(state, amount);
        const pYes = lmsrPriceYesBps(
          state.b,
          result.newQYes,
          result.newQNo
        );
        const pNo = lmsrPriceNoBps(state.b, result.newQYes, result.newQNo);

        expect(pYes + pNo).toBe(10_000n);
      }
    }
  });
});

// ============================================================
// 3. Price Monotonicity
// ============================================================

describe("Price Monotonicity", () => {
  it("buying YES should increase YES price", () => {
    for (const tier of TIERS) {
      const state = createState(tier);
      const priceBefore = lmsrPriceYesBps(state.b, state.qYes, state.qNo);

      for (const amount of TEST_AMOUNTS) {
        if (tier === "low" && amount > 100_000_000n) continue;
        const result = simulateLmsrBuyYes(state, amount);
        if (result.sharesOut > 0n) {
          expect(result.newPriceYesBps).toBeGreaterThanOrEqual(priceBefore);
        }
      }
    }
  });

  it("buying NO should decrease YES price", () => {
    for (const tier of TIERS) {
      const state = createState(tier);
      const priceBefore = lmsrPriceYesBps(state.b, state.qYes, state.qNo);

      for (const amount of TEST_AMOUNTS) {
        if (tier === "low" && amount > 100_000_000n) continue;
        const result = simulateLmsrBuyNo(state, amount);
        if (result.sharesOut > 0n) {
          expect(result.newPriceYesBps).toBeLessThanOrEqual(priceBefore);
        }
      }
    }
  });
});

// ============================================================
// 4. Cost Function Symmetry
// ============================================================

describe("Cost Function Symmetry: C(qYes, qNo) == C(qNo, qYes)", () => {
  it("should be symmetric for various q values", () => {
    const b = LIQUIDITY_TIERS.medium.b;
    const qValues = [
      0n,
      10n * UNIT,
      50n * UNIT,
      100n * UNIT,
      200n * UNIT,
    ];

    for (const qA of qValues) {
      for (const qB of qValues) {
        const cost1 = lmsrCostUsdc(b, qA, qB);
        const cost2 = lmsrCostUsdc(b, qB, qA);
        expect(cost1).toBe(cost2);
      }
    }
  });
});

// ============================================================
// 5. Buy-Sell Round-Trip
// ============================================================

describe("Buy-Sell Round-Trip", () => {
  it("price should return close to original after buy + sell same shares", () => {
    for (const tier of TIERS) {
      const state = createState(tier);
      const originalPrice = lmsrPriceYesBps(
        state.b,
        state.qYes,
        state.qNo
      );

      for (const amount of [1_000_000n, 10_000_000n]) {
        const buyResult = simulateLmsrBuyYes(state, amount);
        if (buyResult.sharesOut === 0n) continue;

        const stateAfterBuy: LmsrState = {
          ...state,
          qYes: buyResult.newQYes,
          qNo: buyResult.newQNo,
        };

        const sellResult = simulateLmsrSellYes(
          stateAfterBuy,
          buyResult.sharesOut
        );
        const priceAfterRoundTrip = sellResult.newPriceYesBps;

        // Price should be within 1% of original (fees cause small drift)
        const tolerance = 100n; // 1%
        expect(absDiff(priceAfterRoundTrip, originalPrice)).toBeLessThan(
          tolerance
        );
      }
    }
  });

  it("NO round-trip should also preserve price", () => {
    const state = createState("medium");
    const originalPrice = lmsrPriceYesBps(state.b, state.qYes, state.qNo);

    const buyResult = simulateLmsrBuyNo(state, 10_000_000n);
    const stateAfterBuy: LmsrState = {
      ...state,
      qYes: buyResult.newQYes,
      qNo: buyResult.newQNo,
    };

    const sellResult = simulateLmsrSellNo(
      stateAfterBuy,
      buyResult.sharesOut
    );

    const tolerance = 100n;
    expect(absDiff(sellResult.newPriceYesBps, originalPrice)).toBeLessThan(
      tolerance
    );
  });
});

// ============================================================
// 6. Liquidity Tier Seed Covers Max Loss
// ============================================================

describe("Liquidity Tier Seed >= Max Loss", () => {
  for (const tier of TIERS) {
    it(`${tier} tier: seedUsdc >= b * ln(2)`, () => {
      const params = LIQUIDITY_TIERS[tier];
      const maxLoss = calcMaxLossUsdc(params.b);

      // Seed must cover max loss (with small tolerance for rounding)
      const tolerance = ONE_USDC; // $1
      expect(params.seedUsdc + tolerance).toBeGreaterThanOrEqual(maxLoss);
    });
  }
});

// ============================================================
// 7. calcInitialQ Round-Trip
// ============================================================

describe("calcInitialQ Round-Trip", () => {
  it("calcInitialQ → lmsrPriceYesBps should return ~input price", () => {
    for (const tier of TIERS) {
      const b = LIQUIDITY_TIERS[tier].b;

      for (const targetPrice of TEST_PRICES) {
        const { qYes, qNo } = calcInitialQ(b, targetPrice);
        const actualPrice = lmsrPriceYesBps(b, qYes, qNo);

        // Allow 2% tolerance (Taylor approximation + floor division)
        const tolerance = 200n; // 2% in bps
        expect(
          absDiff(actualPrice, targetPrice)
        ).toBeLessThan(tolerance);
      }
    }
  });

  it("50/50 should produce qYes ≈ qNo ≈ 0", () => {
    for (const tier of TIERS) {
      const b = LIQUIDITY_TIERS[tier].b;
      const { qYes, qNo } = calcInitialQ(b, 5000n);

      // At 50/50, both q values should be very close to 0
      expect(abs(qYes)).toBeLessThan(UNIT);
      expect(abs(qNo)).toBeLessThan(UNIT);
    }
  });
});

// ============================================================
// 8. calcBFromSeed ↔ calcMaxLossUsdc Inversion
// ============================================================

describe("calcBFromSeed ↔ calcMaxLossUsdc inversion", () => {
  it("calcMaxLossUsdc(calcBFromSeed(seed)) ≈ seed", () => {
    const seeds = [
      10_000_000n, // $10
      35_000_000n, // $35
      100_000_000n, // $100
      139_000_000n, // $139
      500_000_000n, // $500
      693_000_000n, // $693
      1_000_000_000n, // $1000
    ];

    for (const seed of seeds) {
      const b = calcBFromSeed(seed);
      const maxLoss = calcMaxLossUsdc(b);

      const tolerance = ONE_USDC; // $1
      expect(absDiff(maxLoss, seed)).toBeLessThan(tolerance);
    }
  });
});

// ============================================================
// 9. Sequential Trades Accumulation
// ============================================================

describe("Sequential Trades", () => {
  it("price should increase with each consecutive YES buy", () => {
    let state = createState("medium");
    let lastPrice = lmsrPriceYesBps(state.b, state.qYes, state.qNo);

    for (let i = 0; i < 5; i++) {
      const result = simulateLmsrBuyYes(state, 10_000_000n);
      expect(result.newPriceYesBps).toBeGreaterThan(lastPrice);

      lastPrice = result.newPriceYesBps;
      state = {
        ...state,
        qYes: result.newQYes,
        qNo: result.newQNo,
      };
    }
  });

  it("Polymarket guarantee should hold after multiple trades", () => {
    let state = createState("high");

    // 10 sequential YES buys
    for (let i = 0; i < 10; i++) {
      const result = simulateLmsrBuyYes(state, 20_000_000n);
      if (result.sharesOut > 0n) {
        expect(result.sharesOut).toBeGreaterThanOrEqual(result.netUsdc);
      }

      state = {
        ...state,
        qYes: result.newQYes,
        qNo: result.newQNo,
      };
    }

    // Then 5 NO buys
    for (let i = 0; i < 5; i++) {
      const result = simulateLmsrBuyNo(state, 15_000_000n);
      if (result.sharesOut > 0n) {
        expect(result.sharesOut).toBeGreaterThanOrEqual(result.netUsdc);
      }

      state = {
        ...state,
        qYes: result.newQYes,
        qNo: result.newQNo,
      };
    }
  });
});

// ============================================================
// 10. canLmsrBuy validation consistency
// ============================================================

describe("canLmsrBuy consistency", () => {
  it("should return valid=true for all normal trades across tiers", () => {
    for (const tier of TIERS) {
      const state = createState(tier);

      for (const amount of [1_000_000n, 5_000_000n, 10_000_000n]) {
        const sim = simulateLmsrBuyYes(state, amount);
        const result = canLmsrBuy(sim);
        expect(result.valid).toBe(true);
      }
    }
  });
});

// ============================================================
// 11. getTierWithAdjustedSeed
// ============================================================

describe("getTierWithAdjustedSeed", () => {
  it("should return base seed at 50/50", () => {
    for (const tier of TIERS) {
      const result = getTierWithAdjustedSeed(tier, 5000n);
      expect(result.adjustedSeedUsdc).toBe(LIQUIDITY_TIERS[tier].seedUsdc);
    }
  });

  it("should return higher seed at extreme prices", () => {
    for (const tier of TIERS) {
      const at50 = getTierWithAdjustedSeed(tier, 5000n);
      const at80 = getTierWithAdjustedSeed(tier, 8000n);
      const at90 = getTierWithAdjustedSeed(tier, 9000n);

      expect(at80.adjustedSeedUsdc).toBeGreaterThanOrEqual(
        at50.adjustedSeedUsdc
      );
      expect(at90.adjustedSeedUsdc).toBeGreaterThanOrEqual(
        at80.adjustedSeedUsdc
      );
    }
  });

  it("should be symmetric: 20% and 80% need same additional seed", () => {
    for (const tier of TIERS) {
      const at20 = getTierWithAdjustedSeed(tier, 2000n);
      const at80 = getTierWithAdjustedSeed(tier, 8000n);

      // Due to cost function symmetry, the additional seed should be similar
      const tolerance = 2n * ONE_USDC; // $2
      expect(
        absDiff(at20.adjustedSeedUsdc, at80.adjustedSeedUsdc)
      ).toBeLessThan(tolerance);
    }
  });
});
