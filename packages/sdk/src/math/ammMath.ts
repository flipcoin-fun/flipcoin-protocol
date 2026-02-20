/**
 * AMM Math utilities for dev playground
 *
 * All calculations use bigint (uint256 equivalent) with floor division
 * to match Solidity contract behavior exactly.
 *
 * Based on Market.sol CPMM implementation:
 * - k = yesReserve * noReserve (constant product)
 * - buying YES: add USDC to noReserve, remove from yesReserve
 * - buying NO: add USDC to yesReserve, remove from noReserve
 * - fees deducted before AMM calculation
 *
 * ============================================================
 * CPMM INVARIANTS & DESIGN PRINCIPLES
 * ============================================================
 *
 * 1. PRICE IS NEVER 0 OR 1 (asymptotic)
 *    - CPMM formula: price = oppositeReserve / (yesReserve + noReserve)
 *    - As one reserve approaches MIN_RESERVE, price approaches but never reaches 0 or 1
 *    - UI must reflect this: use "$<0.01" / "$>0.99", never "$0.00" / "$1.00"
 *
 * 2. EXTREME PRICING IS A VALID MARKET STATE
 *    - 99% or 1% probability is not an error, it reflects market consensus
 *    - Users can always trade regardless of current probability
 *    - No artificial restrictions on trading at extreme prices
 *
 * 3. BUYING AT EXTREME PRICES = BUYING PROBABILITY MOVEMENT
 *    - At 99% YES: buying YES moves price very little, buying NO has high leverage
 *    - Small sharesOut is expected behavior, not an error
 *    - Users are paying for probability movement, not just position size
 *
 * 4. SMALL sharesOut IS NOT AN ERROR
 *    - At extreme prices, user receives fewer shares per USDC
 *    - This correctly reflects the market's view of probability
 *    - Each share still pays $1 if that outcome wins
 *
 * 5. CPMM PROTECTS THE POOL, NOT THE USER
 *    - MIN_RESERVE ensures pool can't be fully drained
 *    - No other trading restrictions are imposed
 *    - User is responsible for understanding their trade
 *    - UI should INFORM, not RESTRICT
 *
 * ============================================================
 */

// ============================================================
// Constants
// ============================================================

export const BPS = 10_000n;
export const USDC_DECIMALS = 6;
export const ONE_USDC = 10n ** BigInt(USDC_DECIMALS);
export const MIN_RESERVE = 1_000n; // 0.001 USDC
export const MIN_TRADE_USDC = 10_000n; // 0.01 USDC
export const DEFAULT_FEE_BPS = 200n; // 2%

// ============================================================
// Types
// ============================================================

export interface AmmState {
  yesReserve: bigint;
  noReserve: bigint;
  k: bigint;
  feeBps: bigint;
}

export interface BuySimulation {
  sharesOut: bigint;
  fee: bigint;
  netUsdc: bigint;
  newYesReserve: bigint;
  newNoReserve: bigint;
  newPriceYesBps: bigint;
  priceImpactBps: bigint;
}

export interface SellSimulation {
  amountOutGross: bigint;
  amountOutNet: bigint;
  fee: bigint;
  newYesReserve: bigint;
  newNoReserve: bigint;
  newPriceYesBps: bigint;
  priceImpactBps: bigint;
}

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
 * Absolute difference
 */
export function absDiff(a: bigint, b: bigint): bigint {
  return a > b ? a - b : b - a;
}

/**
 * Calculate minimum output with slippage tolerance
 * @param expectedOut Expected output amount
 * @param slippageBps Slippage tolerance in basis points (e.g., 100 = 1%)
 */
export function minOutWithSlippage(expectedOut: bigint, slippageBps: bigint): bigint {
  if (slippageBps >= BPS) return 0n;
  return mulDivDown(expectedOut, BPS - slippageBps, BPS);
}

// ============================================================
// Price Calculations
// ============================================================

/**
 * Calculate YES price in basis points
 * Price = noReserve / (yesReserve + noReserve) * 10000
 */
export function priceYesBps(yesReserve: bigint, noReserve: bigint): bigint {
  const total = yesReserve + noReserve;
  if (total === 0n) return 5000n; // 50% default
  return mulDivDown(noReserve, BPS, total);
}

/**
 * Calculate NO price in basis points
 */
export function priceNoBps(yesReserve: bigint, noReserve: bigint): bigint {
  return BPS - priceYesBps(yesReserve, noReserve);
}

/**
 * Calculate price impact in basis points
 */
export function calculatePriceImpact(
  priceBefore: bigint,
  priceAfter: bigint
): bigint {
  return absDiff(priceAfter, priceBefore);
}

// ============================================================
// Buy Simulations
// ============================================================

/**
 * Simulate buying YES shares
 *
 * CPMM mechanics:
 * 1. Deduct fee from input
 * 2. Add net USDC to noReserve
 * 3. New yesReserve = k / newNoReserve
 * 4. sharesOut = oldYesReserve - newYesReserve
 */
export function simulateBuyYes(state: AmmState, amountUsdc: bigint): BuySimulation {
  const { yesReserve, noReserve, k, feeBps } = state;

  // Calculate fee
  const fee = mulDivDown(amountUsdc, feeBps, BPS);
  const netUsdc = amountUsdc - fee;

  // CPMM calculation
  const newNoReserve = noReserve + netUsdc;
  const newYesReserve = k / newNoReserve;
  const sharesOut = yesReserve - newYesReserve;

  // Price calculations
  const priceBefore = priceYesBps(yesReserve, noReserve);
  const newPriceYesBps = priceYesBps(newYesReserve, newNoReserve);
  const priceImpactBps = calculatePriceImpact(priceBefore, newPriceYesBps);

  return {
    sharesOut,
    fee,
    netUsdc,
    newYesReserve,
    newNoReserve,
    newPriceYesBps,
    priceImpactBps,
  };
}

/**
 * Simulate buying NO shares
 *
 * CPMM mechanics (inverse of buyYes):
 * 1. Deduct fee from input
 * 2. Add net USDC to yesReserve
 * 3. New noReserve = k / newYesReserve
 * 4. sharesOut = oldNoReserve - newNoReserve
 */
export function simulateBuyNo(state: AmmState, amountUsdc: bigint): BuySimulation {
  const { yesReserve, noReserve, k, feeBps } = state;

  // Calculate fee
  const fee = mulDivDown(amountUsdc, feeBps, BPS);
  const netUsdc = amountUsdc - fee;

  // CPMM calculation
  const newYesReserve = yesReserve + netUsdc;
  const newNoReserve = k / newYesReserve;
  const sharesOut = noReserve - newNoReserve;

  // Price calculations
  const priceBefore = priceYesBps(yesReserve, noReserve);
  const newPriceYesBps = priceYesBps(newYesReserve, newNoReserve);
  const priceImpactBps = calculatePriceImpact(priceBefore, newPriceYesBps);

  return {
    sharesOut,
    fee,
    netUsdc,
    newYesReserve,
    newNoReserve,
    newPriceYesBps,
    priceImpactBps,
  };
}

// ============================================================
// Sell Simulations
// ============================================================

/**
 * Simulate selling YES shares
 *
 * CPMM mechanics:
 * 1. Add shares to yesReserve
 * 2. New noReserve = k / newYesReserve
 * 3. grossOut = oldNoReserve - newNoReserve
 * 4. Deduct fee from grossOut
 */
export function simulateSellYes(state: AmmState, shares: bigint): SellSimulation {
  const { yesReserve, noReserve, k, feeBps } = state;

  // CPMM calculation
  const newYesReserve = yesReserve + shares;
  const newNoReserve = k / newYesReserve;
  const amountOutGross = noReserve - newNoReserve;

  // Calculate fee
  const fee = mulDivDown(amountOutGross, feeBps, BPS);
  const amountOutNet = amountOutGross - fee;

  // Price calculations
  const priceBefore = priceYesBps(yesReserve, noReserve);
  const newPriceYesBps = priceYesBps(newYesReserve, newNoReserve);
  const priceImpactBps = calculatePriceImpact(priceBefore, newPriceYesBps);

  return {
    amountOutGross,
    amountOutNet,
    fee,
    newYesReserve,
    newNoReserve,
    newPriceYesBps,
    priceImpactBps,
  };
}

/**
 * Simulate selling NO shares
 *
 * CPMM mechanics (inverse of sellYes):
 * 1. Add shares to noReserve
 * 2. New yesReserve = k / newNoReserve
 * 3. grossOut = oldYesReserve - newYesReserve
 * 4. Deduct fee from grossOut
 */
export function simulateSellNo(state: AmmState, shares: bigint): SellSimulation {
  const { yesReserve, noReserve, k, feeBps } = state;

  // CPMM calculation
  const newNoReserve = noReserve + shares;
  const newYesReserve = k / newNoReserve;
  const amountOutGross = yesReserve - newYesReserve;

  // Calculate fee
  const fee = mulDivDown(amountOutGross, feeBps, BPS);
  const amountOutNet = amountOutGross - fee;

  // Price calculations
  const priceBefore = priceYesBps(yesReserve, noReserve);
  const newPriceYesBps = priceYesBps(newYesReserve, newNoReserve);
  const priceImpactBps = calculatePriceImpact(priceBefore, newPriceYesBps);

  return {
    amountOutGross,
    amountOutNet,
    fee,
    newYesReserve,
    newNoReserve,
    newPriceYesBps,
    priceImpactBps,
  };
}

// ============================================================
// Validation Helpers
// ============================================================

/**
 * Check if a buy would succeed (reserves stay above MIN_RESERVE)
 *
 * NOTE: These checks only validate CONTRACT-level constraints.
 * Small sharesOut at extreme prices is VALID and EXPECTED behavior.
 * UI should NEVER block trades based on low sharesOut - it's the user's choice.
 */
export function canBuy(
  simulation: BuySimulation,
  minReserve: bigint = MIN_RESERVE
): { valid: boolean; reason?: string } {
  // Only check pool protection constraints (MIN_RESERVE)
  // Small sharesOut is valid - user is paying for probability movement
  if (simulation.newYesReserve < minReserve) {
    return { valid: false, reason: "YES reserve would drop below minimum" };
  }
  if (simulation.newNoReserve < minReserve) {
    return { valid: false, reason: "NO reserve would drop below minimum" };
  }
  // Note: sharesOut > 0 is only a sanity check, not a user protection
  if (simulation.sharesOut <= 0n) {
    return { valid: false, reason: "Would receive zero shares" };
  }
  return { valid: true };
}

/**
 * Check if a sell would succeed
 *
 * NOTE: These checks only validate CONTRACT-level constraints.
 * CPMM protects the pool, not the user.
 */
export function canSell(
  simulation: SellSimulation,
  minReserve: bigint = MIN_RESERVE,
  minTrade: bigint = MIN_TRADE_USDC
): { valid: boolean; reason?: string } {
  if (simulation.newYesReserve < minReserve) {
    return { valid: false, reason: "YES reserve would drop below minimum" };
  }
  if (simulation.newNoReserve < minReserve) {
    return { valid: false, reason: "NO reserve would drop below minimum" };
  }
  if (simulation.amountOutGross < minTrade) {
    return { valid: false, reason: "Trade too small" };
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
  const frac = amount % ONE_USDC;
  const fracStr = frac.toString().padStart(USDC_DECIMALS, "0");
  return `${whole}.${fracStr.slice(0, decimals)}`;
}

/**
 * Parse human-readable USDC string to bigint
 * Handles decimal input safely without floating point errors
 */
export function parseUsdc(value: string): bigint {
  const trimmed = value.trim();
  if (!trimmed || trimmed === ".") return 0n;

  const [wholePart, fracPart = ""] = trimmed.split(".");

  // Validate parts
  if (!/^\d*$/.test(wholePart) || !/^\d*$/.test(fracPart)) {
    throw new Error("Invalid USDC amount");
  }

  // Pad or truncate fractional part to USDC_DECIMALS
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
// Safe Price Formatting
// ============================================================

/**
 * Format token price from bps with safe bounds
 *
 * INVARIANT: Price is NEVER 0 or 1 (CPMM asymptote)
 * - Never returns "$0.00" or "$1.00" because these values are mathematically impossible
 * - Uses "$<0.01" and "$>0.99" for extreme prices
 * - This reflects the CPMM property, not a display hack
 *
 * @param bps - Price in basis points (0-10000)
 * @returns Formatted price string like "$0.50", "$<0.01", "$>0.99"
 */
export function formatTokenPrice(bps: bigint): string {
  // Extreme low: CPMM approaches but never reaches 0
  if (bps <= 10n) return "$<0.01";

  // Extreme high: CPMM approaches but never reaches 1
  if (bps >= 9990n) return "$>0.99";

  const price = Number(bps) / 10000;

  // Very low prices: show 3 decimals
  if (bps < 100n) return `$${price.toFixed(3)}`;

  // Very high prices: show 3 decimals
  if (bps > 9900n) return `$${price.toFixed(3)}`;

  // Standard range: 2 decimals
  return `$${price.toFixed(2)}`;
}

/**
 * Format probability from bps with safe bounds
 *
 * INVARIANT: Probability is NEVER 0% or 100% (CPMM asymptote)
 * - Never returns "0%" or "100%" because these values are mathematically impossible
 * - Uses "<1%" and ">99%" for extreme probabilities
 * - Extreme probabilities are VALID market states, not errors
 *
 * @param bps - Probability in basis points (0-10000)
 * @returns Formatted probability string like "50%", "<1%", ">99%"
 */
export function formatProbability(bps: bigint): string {
  // Extreme low: CPMM approaches but never reaches 0%
  if (bps <= 10n) return "<1%";

  // Extreme high: CPMM approaches but never reaches 100%
  if (bps >= 9990n) return ">99%";

  const pct = Number(bps) / 100;

  // Near extremes: show 1 decimal for precision
  if (bps < 500n) return `${pct.toFixed(1)}%`;
  if (bps > 9500n) return `${pct.toFixed(1)}%`;

  // Standard range: round to integer
  return `${Math.round(pct)}%`;
}

/**
 * Get safe progress bar value (never 0 or 100)
 * @param bps - Value in basis points
 * @returns Value between 1 and 99 for progress bar
 */
export function getSafeProgressValue(bps: bigint): number {
  const value = Number(bps) / 100;
  return Math.min(99, Math.max(1, value));
}

/**
 * Check if price is in extreme state (for showing INFORMATIONAL messages only)
 *
 * NOTE: Extreme pricing is a VALID market state, not an error.
 * This function is used to show helpful context to users, NOT to restrict trading.
 * Users can trade at any price level without restrictions.
 */
export function isExtremePrice(bps: bigint): { isExtreme: boolean; isHigh: boolean; isLow: boolean } {
  const isHigh = bps > 9500n;
  const isLow = bps < 500n;
  return {
    isExtreme: isHigh || isLow,
    isHigh,
    isLow,
  };
}
