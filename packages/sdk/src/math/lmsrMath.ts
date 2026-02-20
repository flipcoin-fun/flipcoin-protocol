/**
 * LMSR Math utilities for frontend
 *
 * All calculations use bigint (matching Solidity) with floor division.
 * Uses JavaScript's BigInt for 18-decimal fixed-point math (SD59x18 equivalent).
 *
 * Based on MarketLMSR.sol implementation:
 * - Cost function: C(qYes, qNo) = b * ln(e^(qYes/b) + e^(qNo/b))
 * - Price sigmoid: P(yes) = 1 / (1 + e^(-(qYes - qNo)/b))
 * - Fixed payout: each winning share pays exactly $1
 *
 * ============================================================
 * LMSR DESIGN PRINCIPLES
 * ============================================================
 *
 * 1. FIXED PAYOUT MODEL
 *    - Each winning share pays exactly $1 at resolution
 *    - No pari-mutuel pooling — predictable payouts
 *    - Collateralization: vaultBalance >= max(yesSharesTotal, noSharesTotal)
 *
 * 2. BOUNDED MAX LOSS FOR CREATOR
 *    - Max loss = b * ln(2) ≈ 0.693 * b
 *    - Creator's seed covers this potential loss
 *    - Known upfront, unlike CPMM
 *
 * 3. LOGARITHMIC SLIPPAGE
 *    - More gradual price impact than CPMM
 *    - Better for low-liquidity markets
 *
 * 4. PRICE VIA SIGMOID
 *    - Always in (0, 1), never exactly 0 or 1
 *    - Clamp at extreme values to prevent overflow
 *
 * ============================================================
 */

// ============================================================
// Constants
// ============================================================

export const BPS = 10_000n;
export const USDC_DECIMALS = 6;
export const ONE_USDC = 10n ** BigInt(USDC_DECIMALS);
export const MIN_TRADE_USDC = 10_000n; // 0.01 USDC
export const DEFAULT_FEE_BPS = 200n; // 2%
export const PAYOUT_PER_SHARE = 1_000_000n; // $1 per winning share

// SD59x18 constants (18 decimals)
export const UNIT = 10n ** 18n;
export const LN2 = 693147180559945309n; // ln(2) * 1e18
export const USDC_TO_SD59x18 = 10n ** 12n; // Convert 6 dec to 18 dec
export const SIGMOID_CLAMP = 20n; // Max |diff/b| for overflow protection

// ============================================================
// Types
// ============================================================

export interface LmsrState {
  b: bigint; // Liquidity parameter (SD59x18)
  qYes: bigint; // Cumulative YES shares sold (SD59x18)
  qNo: bigint; // Cumulative NO shares sold (SD59x18)
  feeBps: bigint;
  yesSharesTotal: bigint; // 6 decimals
  noSharesTotal: bigint; // 6 decimals
}

export interface LmsrBuySimulation {
  sharesOut: bigint;
  fee: bigint;
  netUsdc: bigint;
  newQYes: bigint;
  newQNo: bigint;
  newPriceYesBps: bigint;
  priceImpactBps: bigint;
  avgPricePerShare: bigint; // In USDC (6 dec)
}

export interface LmsrSellSimulation {
  amountOutGross: bigint;
  amountOutNet: bigint;
  fee: bigint;
  newQYes: bigint;
  newQNo: bigint;
  newPriceYesBps: bigint;
  priceImpactBps: bigint;
}

export type LiquidityTier = "low" | "medium" | "high";

export interface TierParams {
  b: bigint;
  seedUsdc: bigint;
  label: string;
  description: string;
}

// ============================================================
// Liquidity Tiers
// ============================================================

export const LIQUIDITY_TIERS: Record<LiquidityTier, TierParams> = {
  low: {
    b: 50n * UNIT,
    seedUsdc: 35n * ONE_USDC,
    label: "Low",
    description: "$35 seed, max loss $35",
  },
  medium: {
    b: 200n * UNIT,
    seedUsdc: 139n * ONE_USDC,
    label: "Medium",
    description: "$139 seed, max loss $139",
  },
  high: {
    b: 1000n * UNIT,
    seedUsdc: 693n * ONE_USDC,
    label: "High",
    description: "$693 seed, max loss $693",
  },
};

// ============================================================
// Core Math Utilities
// ============================================================

/**
 * Floor division (matches Solidity default)
 */
export function mulDivDown(a: bigint, b: bigint, c: bigint): bigint {
  if (c === 0n) throw new Error("Division by zero");
  return (a * b) / c;
}

/**
 * Absolute value
 */
export function abs(x: bigint): bigint {
  return x < 0n ? -x : x;
}

/**
 * Absolute difference
 */
export function absDiff(a: bigint, b: bigint): bigint {
  return a > b ? a - b : b - a;
}

/**
 * Approximate exp(x) for SD59x18 using Taylor series
 * Only accurate for small |x| (< 20 * UNIT)
 *
 * exp(x) ≈ 1 + x + x²/2! + x³/3! + x⁴/4! + ...
 */
export function expApprox(x: bigint): bigint {
  // Clamp to prevent overflow
  if (x > 20n * UNIT) return 485165195n * UNIT; // e^20 ≈ 4.85e8
  if (x < -20n * UNIT) return 0n;

  // Taylor series: 1 + x + x²/2 + x³/6 + x⁴/24 + x⁵/120 + x⁶/720
  let result = UNIT; // 1
  let term = UNIT;

  for (let i = 1n; i <= 12n; i++) {
    term = (term * x) / (i * UNIT);
    result += term;
    // Early exit if term is negligible
    if (abs(term) < 1n) break;
  }

  return result > 0n ? result : 1n;
}

/**
 * Approximate ln(x) for SD59x18 using Newton-Raphson
 * x should be positive and in SD59x18 format
 */
export function lnApprox(x: bigint): bigint {
  if (x <= 0n) throw new Error("ln of non-positive number");

  // For very small x, return a large negative number
  if (x < UNIT / 1000n) return -7n * UNIT; // ≈ ln(0.001)

  // For x close to 1, use Taylor series around 1
  // ln(1 + y) ≈ y - y²/2 + y³/3 - y⁴/4
  const y = x - UNIT;
  if (abs(y) < UNIT / 2n) {
    let result = y;
    let yPow = y;
    for (let i = 2n; i <= 8n; i++) {
      yPow = (yPow * y) / UNIT;
      if (i % 2n === 0n) {
        result -= yPow / i;
      } else {
        result += yPow / i;
      }
    }
    return result;
  }

  // For larger x, use the fact that ln(x) = ln(x/e^k) + k
  // Find k such that x / e^k is close to 1
  let k = 0n;
  let xNorm = x;

  // Normalize x to be close to 1
  const E = 2718281828459045235n; // e * 1e18
  while (xNorm > 2n * UNIT) {
    xNorm = (xNorm * UNIT) / E;
    k += UNIT;
  }
  while (xNorm < UNIT / 2n) {
    xNorm = (xNorm * E) / UNIT;
    k -= UNIT;
  }

  // Now use Taylor series for ln(xNorm)
  const yNorm = xNorm - UNIT;
  let result = yNorm;
  let yPow = yNorm;
  for (let i = 2n; i <= 8n; i++) {
    yPow = (yPow * yNorm) / UNIT;
    if (i % 2n === 0n) {
      result -= yPow / i;
    } else {
      result += yPow / i;
    }
  }

  return result + k;
}

// ============================================================
// LMSR Price Calculations
// ============================================================

/**
 * Calculate YES price using sigmoid function
 * P(yes) = 1 / (1 + e^(-(qYes - qNo)/b))
 *
 * @returns Price in basis points (0-10000)
 */
export function lmsrPriceYesBps(b: bigint, qYes: bigint, qNo: bigint): bigint {
  if (b === 0n) return 5000n;

  const diff = qYes - qNo;

  // Clamp for overflow protection
  if (diff > b * SIGMOID_CLAMP) return 9999n;
  if (diff < -b * SIGMOID_CLAMP) return 1n;

  // P = 1 / (1 + e^(-diff/b))
  // = e^(diff/b) / (1 + e^(diff/b))
  const exponent = (diff * UNIT) / b;
  const expVal = expApprox(exponent);

  // P = expVal / (1 + expVal) in BPS
  const numerator = expVal * BPS;
  const denominator = UNIT + expVal;

  if (denominator === 0n) return 5000n;

  const result = numerator / denominator;

  // Clamp to valid range
  if (result < 1n) return 1n;
  if (result > 9999n) return 9999n;

  return result;
}

/**
 * Calculate NO price in basis points
 */
export function lmsrPriceNoBps(b: bigint, qYes: bigint, qNo: bigint): bigint {
  return BPS - lmsrPriceYesBps(b, qYes, qNo);
}

// ============================================================
// LMSR Cost Function
// ============================================================

/**
 * Calculate LMSR cost function using Log-Sum-Exp trick
 * C(qYes, qNo) = b * ln(e^(qYes/b) + e^(qNo/b))
 *
 * Using LSE trick for numerical stability:
 * C = b * (m + ln(e^(a-m) + e^(c-m)))
 * where m = max(qYes/b, qNo/b)
 *
 * @returns Cost in USDC (6 decimals)
 */
export function lmsrCostUsdc(b: bigint, qYes: bigint, qNo: bigint): bigint {
  if (b === 0n) return 0n;

  const a = (qYes * UNIT) / b;
  const c = (qNo * UNIT) / b;

  // m = max(a, c)
  const m = a > c ? a : c;

  // e^(a-m) + e^(c-m)
  const expAMinusM = expApprox(a - m);
  const expCMinusM = expApprox(c - m);
  const sumExp = expAMinusM + expCMinusM;

  // ln(sumExp)
  const lnSum = lnApprox(sumExp);

  // C = b * (m + ln(sumExp))
  const costSd = (b * (m + lnSum)) / UNIT;

  // Convert to USDC (6 decimals)
  const costUsdc = costSd / USDC_TO_SD59x18;

  return costUsdc > 0n ? costUsdc : 0n;
}

// ============================================================
// Buy Simulations
// ============================================================

/**
 * Calculate shares out for a given USDC input using binary search
 * Similar to MarketLMSR._calcSharesOut
 *
 * For LMSR, at price P the effective cost per share is approximately P * $1.
 * At 50% price, you get ~2 shares per $1 spent (before fees).
 * At 10% price, you could get ~10 shares per $1 spent.
 *
 * Upper bound should be: netUsdc / minPrice, but we use a generous multiplier.
 */
function calcSharesOut(
  b: bigint,
  qYes: bigint,
  qNo: bigint,
  netUsdc: bigint,
  isYes: boolean
): bigint {
  if (b === 0n || netUsdc === 0n) return 0n;

  // Initial cost
  const costBefore = lmsrCostUsdc(b, qYes, qNo);
  const targetCost = costBefore + netUsdc;

  // Binary search for shares
  // Upper bound must match contract: costUsdc * 200 (handles prices as low as 0.5%)
  // At price P, shares ≈ netUsdc / P, so at 0.5% → 200x multiplier
  let lo = 0n;
  let hi = netUsdc * 200n;
  let bestShares = 0n;

  for (let i = 0; i < 128; i++) {
    const mid = (lo + hi) / 2n;
    if (mid === lo) break;

    const deltaQ = mid * USDC_TO_SD59x18;
    let newQYes = qYes;
    let newQNo = qNo;

    if (isYes) {
      newQYes = qYes + deltaQ;
    } else {
      newQNo = qNo + deltaQ;
    }

    const newCost = lmsrCostUsdc(b, newQYes, newQNo);

    if (newCost <= targetCost) {
      bestShares = mid;
      lo = mid;
    } else {
      hi = mid;
    }
  }

  return bestShares;
}

/**
 * Simulate buying YES shares
 */
export function simulateLmsrBuyYes(
  state: LmsrState,
  amountUsdc: bigint
): LmsrBuySimulation {
  const { b, qYes, qNo, feeBps } = state;

  // Calculate fee
  const fee = mulDivDown(amountUsdc, feeBps, BPS);
  const netUsdc = amountUsdc - fee;

  // Calculate shares out
  const sharesOut = calcSharesOut(b, qYes, qNo, netUsdc, true);

  // New state
  const deltaQ = sharesOut * USDC_TO_SD59x18;
  const newQYes = qYes + deltaQ;
  const newQNo = qNo;

  // Price calculations
  const priceBefore = lmsrPriceYesBps(b, qYes, qNo);
  const newPriceYesBps = lmsrPriceYesBps(b, newQYes, newQNo);
  const priceImpactBps = absDiff(newPriceYesBps, priceBefore);

  // Average price per share
  const avgPricePerShare =
    sharesOut > 0n ? mulDivDown(netUsdc, ONE_USDC, sharesOut) : 0n;

  return {
    sharesOut,
    fee,
    netUsdc,
    newQYes,
    newQNo,
    newPriceYesBps,
    priceImpactBps,
    avgPricePerShare,
  };
}

/**
 * Simulate buying NO shares
 */
export function simulateLmsrBuyNo(
  state: LmsrState,
  amountUsdc: bigint
): LmsrBuySimulation {
  const { b, qYes, qNo, feeBps } = state;

  // Calculate fee
  const fee = mulDivDown(amountUsdc, feeBps, BPS);
  const netUsdc = amountUsdc - fee;

  // Calculate shares out
  const sharesOut = calcSharesOut(b, qYes, qNo, netUsdc, false);

  // New state
  const deltaQ = sharesOut * USDC_TO_SD59x18;
  const newQYes = qYes;
  const newQNo = qNo + deltaQ;

  // Price calculations
  const priceBefore = lmsrPriceYesBps(b, qYes, qNo);
  const newPriceYesBps = lmsrPriceYesBps(b, newQYes, newQNo);
  const priceImpactBps = absDiff(newPriceYesBps, priceBefore);

  // Average price per share (for NO, use NO price)
  const avgPricePerShare =
    sharesOut > 0n ? mulDivDown(netUsdc, ONE_USDC, sharesOut) : 0n;

  return {
    sharesOut,
    fee,
    netUsdc,
    newQYes,
    newQNo,
    newPriceYesBps,
    priceImpactBps,
    avgPricePerShare,
  };
}

// ============================================================
// Sell Simulations
// ============================================================

/**
 * Simulate selling YES shares
 */
export function simulateLmsrSellYes(
  state: LmsrState,
  shares: bigint
): LmsrSellSimulation {
  const { b, qYes, qNo, feeBps } = state;

  // Cost before
  const costBefore = lmsrCostUsdc(b, qYes, qNo);

  // New state after selling
  const deltaQ = shares * USDC_TO_SD59x18;
  const newQYes = qYes - deltaQ;
  const newQNo = qNo;

  // Cost after
  const costAfter = lmsrCostUsdc(b, newQYes, newQNo);

  // Gross output = reduction in cost
  const amountOutGross = costBefore - costAfter;

  // Calculate fee
  const fee = mulDivDown(amountOutGross, feeBps, BPS);
  const amountOutNet = amountOutGross - fee;

  // Price calculations
  const priceBefore = lmsrPriceYesBps(b, qYes, qNo);
  const newPriceYesBps = lmsrPriceYesBps(b, newQYes, newQNo);
  const priceImpactBps = absDiff(newPriceYesBps, priceBefore);

  return {
    amountOutGross,
    amountOutNet,
    fee,
    newQYes,
    newQNo,
    newPriceYesBps,
    priceImpactBps,
  };
}

/**
 * Simulate selling NO shares
 */
export function simulateLmsrSellNo(
  state: LmsrState,
  shares: bigint
): LmsrSellSimulation {
  const { b, qYes, qNo, feeBps } = state;

  // Cost before
  const costBefore = lmsrCostUsdc(b, qYes, qNo);

  // New state after selling
  const deltaQ = shares * USDC_TO_SD59x18;
  const newQYes = qYes;
  const newQNo = qNo - deltaQ;

  // Cost after
  const costAfter = lmsrCostUsdc(b, newQYes, newQNo);

  // Gross output = reduction in cost
  const amountOutGross = costBefore - costAfter;

  // Calculate fee
  const fee = mulDivDown(amountOutGross, feeBps, BPS);
  const amountOutNet = amountOutGross - fee;

  // Price calculations
  const priceBefore = lmsrPriceYesBps(b, qYes, qNo);
  const newPriceYesBps = lmsrPriceYesBps(b, newQYes, newQNo);
  const priceImpactBps = absDiff(newPriceYesBps, priceBefore);

  return {
    amountOutGross,
    amountOutNet,
    fee,
    newQYes,
    newQNo,
    newPriceYesBps,
    priceImpactBps,
  };
}

// ============================================================
// Slippage Helpers
// ============================================================

/**
 * Calculate minimum output with slippage tolerance
 */
export function minOutWithSlippage(
  expectedOut: bigint,
  slippageBps: bigint
): bigint {
  if (slippageBps >= BPS) return 0n;
  return mulDivDown(expectedOut, BPS - slippageBps, BPS);
}

// ============================================================
// Validation Helpers
// ============================================================

/**
 * Check if a buy would succeed
 * Includes Polymarket-style guarantee: shares >= net (price per share <= $1)
 */
export function canLmsrBuy(simulation: LmsrBuySimulation): {
  valid: boolean;
  reason?: string;
} {
  if (simulation.sharesOut <= 0n) {
    return { valid: false, reason: "Would receive zero shares" };
  }
  // Polymarket-style guarantee: payout (shares) >= cost (net)
  // This ensures price per share <= $1, so winning is always profitable
  if (simulation.sharesOut < simulation.netUsdc) {
    return {
      valid: false,
      reason: "Price too high - would lose money even if you win",
    };
  }
  return { valid: true };
}

/**
 * Check if a sell would succeed
 */
export function canLmsrSell(
  simulation: LmsrSellSimulation,
  minTrade: bigint = MIN_TRADE_USDC
): { valid: boolean; reason?: string } {
  if (simulation.amountOutGross < minTrade) {
    return { valid: false, reason: "Trade too small" };
  }
  if (simulation.amountOutNet <= 0n) {
    return { valid: false, reason: "Would receive nothing after fees" };
  }
  return { valid: true };
}

// ============================================================
// Formatting Helpers
// ============================================================

/**
 * Format bigint USDC amount to human-readable string
 */
export function formatUsdc(amount: bigint, decimals: number = 2): string {
  const whole = amount / ONE_USDC;
  const frac = abs(amount) % ONE_USDC;
  const fracStr = frac.toString().padStart(USDC_DECIMALS, "0");
  const sign = amount < 0n ? "-" : "";
  if (decimals <= 0) return `${sign}${abs(whole)}`;
  return `${sign}${abs(whole)}.${fracStr.slice(0, decimals)}`;
}

/**
 * Parse human-readable USDC string to bigint
 */
export function parseUsdc(value: string): bigint {
  const trimmed = value.trim();
  if (!trimmed || trimmed === ".") return 0n;

  const [wholePart, fracPart = ""] = trimmed.split(".");

  if (!/^\d*$/.test(wholePart) || !/^\d*$/.test(fracPart)) {
    throw new Error("Invalid USDC amount");
  }

  const paddedFrac = fracPart.slice(0, USDC_DECIMALS).padEnd(USDC_DECIMALS, "0");

  const wholeValue = wholePart ? BigInt(wholePart) * ONE_USDC : 0n;
  const fracValue = paddedFrac ? BigInt(paddedFrac) : 0n;

  return wholeValue + fracValue;
}

/**
 * Format basis points to percentage string
 */
export function formatBps(bps: bigint, decimals: number = 2): string {
  const pct = Number(bps) / 100;
  return `${pct.toFixed(decimals)}%`;
}

// ============================================================
// Initial Price Calculation
// ============================================================

/**
 * Calculate initial qYes and qNo for a given initial price
 * Inverts the sigmoid formula: P = 1 / (1 + e^(-(qYes-qNo)/b))
 *
 * Solving for qDiff = qYes - qNo:
 * qDiff = b * ln(P / (1-P))
 *
 * We set qYes = qDiff/2, qNo = -qDiff/2
 */
export function calcInitialQ(
  b: bigint,
  priceYesBps: bigint
): { qYes: bigint; qNo: bigint } {
  if (priceYesBps <= 0n || priceYesBps >= BPS) {
    throw new Error("Invalid initial price");
  }

  // P = priceYesBps / 10000
  const pNum = priceYesBps;
  const pDen = BPS;

  // ratio = P / (1-P) = pNum / (pDen - pNum)
  const ratioNum = pNum * UNIT;
  const ratioDen = pDen - pNum;

  if (ratioDen <= 0n) {
    throw new Error("Invalid ratio denominator");
  }

  const ratio = ratioNum / ratioDen;

  // qDiff = b * ln(ratio)
  const lnRatio = lnApprox(ratio);
  const qDiff = (b * lnRatio) / UNIT;

  // Split evenly
  const qYes = qDiff / 2n;
  const qNo = -qDiff / 2n;

  return { qYes, qNo };
}

/**
 * Calculate max loss (seed requirement) for a given b value
 * Max loss = b * ln(2)
 */
export function calcMaxLossUsdc(b: bigint): bigint {
  const maxLossSd = (b * LN2) / UNIT;
  return maxLossSd / USDC_TO_SD59x18;
}

/**
 * Calculate b parameter from desired seed amount
 * b = seed / ln(2) ≈ seed / 0.693
 *
 * @param seedUsdc Seed amount in USDC (6 decimals)
 * @returns b parameter in SD59x18 format
 */
export function calcBFromSeed(seedUsdc: bigint): bigint {
  // b = seedUsdc * USDC_TO_SD59x18 / LN2 * UNIT
  // Simplified: b = seedUsdc * 1e12 * 1e18 / LN2
  return (seedUsdc * USDC_TO_SD59x18 * UNIT) / LN2;
}

/**
 * Minimum seed for LMSR markets (10 USDC)
 */
export const MIN_SEED_USDC = 10n * ONE_USDC;

/**
 * Maximum seed for LMSR markets (10,000 USDC)
 */
export const MAX_SEED_USDC = 10_000n * ONE_USDC;

/**
 * Get tier parameters and calculate adjusted seed for initial price
 * Initial price affects baseCost, which may require more seed
 */
export function getTierWithAdjustedSeed(
  tier: LiquidityTier,
  initialPriceYesBps: bigint
): TierParams & { adjustedSeedUsdc: bigint; baseCost: bigint } {
  const params = LIQUIDITY_TIERS[tier];
  const { qYes, qNo } = calcInitialQ(params.b, initialPriceYesBps);
  const baseCost = lmsrCostUsdc(params.b, qYes, qNo);
  const maxLoss = calcMaxLossUsdc(params.b);

  // Adjusted seed must cover both baseCost increase and max potential loss
  // For 50/50, baseCost = b * ln(2), so no additional seed needed
  // For biased prices, baseCost > b * ln(2), need more seed
  const baseCostAt5050 = calcMaxLossUsdc(params.b);
  const additionalSeed = baseCost > baseCostAt5050 ? baseCost - baseCostAt5050 : 0n;
  const adjustedSeedUsdc = params.seedUsdc + additionalSeed;

  return {
    ...params,
    adjustedSeedUsdc,
    baseCost,
  };
}
