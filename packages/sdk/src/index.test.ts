/**
 * Tests for SDK public API surface
 *
 * Validates:
 * - Namespaced exports (lmsr, cpmm) don't collide
 * - All expected functions are accessible via namespaces
 * - Re-exported types and ABIs are present
 * - No accidental breaking changes to the public API
 */

import { describe, it, expect } from "vitest";
import * as sdk from "./index";

// ============================================================
// Namespace structure
// ============================================================

describe("SDK namespace exports", () => {
  it("should export lmsr namespace", () => {
    expect(sdk.lmsr).toBeDefined();
    expect(typeof sdk.lmsr).toBe("object");
  });

  it("should export cpmm namespace", () => {
    expect(sdk.cpmm).toBeDefined();
    expect(typeof sdk.cpmm).toBe("object");
  });

  it("lmsr and cpmm should be separate objects", () => {
    expect(sdk.lmsr).not.toBe(sdk.cpmm);
  });
});

// ============================================================
// LMSR namespace contents
// ============================================================

describe("lmsr namespace", () => {
  it("should export constants", () => {
    expect(sdk.lmsr.BPS).toBe(10_000n);
    expect(sdk.lmsr.ONE_USDC).toBe(1_000_000n);
    expect(sdk.lmsr.UNIT).toBe(10n ** 18n);
    expect(sdk.lmsr.LN2).toBeDefined();
    expect(sdk.lmsr.USDC_TO_SD59x18).toBe(10n ** 12n);
    expect(sdk.lmsr.PAYOUT_PER_SHARE).toBe(1_000_000n);
    expect(sdk.lmsr.MIN_SEED_USDC).toBeDefined();
    expect(sdk.lmsr.MAX_SEED_USDC).toBeDefined();
  });

  it("should export core math functions", () => {
    expect(typeof sdk.lmsr.mulDivDown).toBe("function");
    expect(typeof sdk.lmsr.abs).toBe("function");
    expect(typeof sdk.lmsr.absDiff).toBe("function");
    expect(typeof sdk.lmsr.expApprox).toBe("function");
    expect(typeof sdk.lmsr.lnApprox).toBe("function");
  });

  it("should export price functions", () => {
    expect(typeof sdk.lmsr.lmsrPriceYesBps).toBe("function");
    expect(typeof sdk.lmsr.lmsrPriceNoBps).toBe("function");
  });

  it("should export cost function", () => {
    expect(typeof sdk.lmsr.lmsrCostUsdc).toBe("function");
  });

  it("should export simulation functions", () => {
    expect(typeof sdk.lmsr.simulateLmsrBuyYes).toBe("function");
    expect(typeof sdk.lmsr.simulateLmsrBuyNo).toBe("function");
    expect(typeof sdk.lmsr.simulateLmsrSellYes).toBe("function");
    expect(typeof sdk.lmsr.simulateLmsrSellNo).toBe("function");
  });

  it("should export validation functions", () => {
    expect(typeof sdk.lmsr.canLmsrBuy).toBe("function");
    expect(typeof sdk.lmsr.canLmsrSell).toBe("function");
    expect(typeof sdk.lmsr.minOutWithSlippage).toBe("function");
  });

  it("should export formatting functions", () => {
    expect(typeof sdk.lmsr.formatUsdc).toBe("function");
    expect(typeof sdk.lmsr.parseUsdc).toBe("function");
    expect(typeof sdk.lmsr.formatBps).toBe("function");
  });

  it("should export initial price functions", () => {
    expect(typeof sdk.lmsr.calcInitialQ).toBe("function");
    expect(typeof sdk.lmsr.calcMaxLossUsdc).toBe("function");
    expect(typeof sdk.lmsr.calcBFromSeed).toBe("function");
    expect(typeof sdk.lmsr.getTierWithAdjustedSeed).toBe("function");
  });

  it("should export liquidity tiers", () => {
    expect(sdk.lmsr.LIQUIDITY_TIERS).toBeDefined();
    expect(sdk.lmsr.LIQUIDITY_TIERS.low).toBeDefined();
    expect(sdk.lmsr.LIQUIDITY_TIERS.medium).toBeDefined();
    expect(sdk.lmsr.LIQUIDITY_TIERS.high).toBeDefined();
  });
});

// ============================================================
// CPMM namespace contents
// ============================================================

describe("cpmm namespace", () => {
  it("should export constants", () => {
    expect(sdk.cpmm.BPS).toBe(10_000n);
    expect(sdk.cpmm.ONE_USDC).toBe(1_000_000n);
    expect(sdk.cpmm.MIN_RESERVE).toBeDefined();
    expect(sdk.cpmm.MIN_TRADE_USDC).toBeDefined();
    expect(sdk.cpmm.DEFAULT_FEE_BPS).toBeDefined();
  });

  it("should export core math functions", () => {
    expect(typeof sdk.cpmm.mulDivDown).toBe("function");
    expect(typeof sdk.cpmm.absDiff).toBe("function");
    expect(typeof sdk.cpmm.minOutWithSlippage).toBe("function");
  });

  it("should export price functions", () => {
    expect(typeof sdk.cpmm.priceYesBps).toBe("function");
    expect(typeof sdk.cpmm.priceNoBps).toBe("function");
    expect(typeof sdk.cpmm.calculatePriceImpact).toBe("function");
  });

  it("should export simulation functions", () => {
    expect(typeof sdk.cpmm.simulateBuyYes).toBe("function");
    expect(typeof sdk.cpmm.simulateBuyNo).toBe("function");
    expect(typeof sdk.cpmm.simulateSellYes).toBe("function");
    expect(typeof sdk.cpmm.simulateSellNo).toBe("function");
  });

  it("should export validation functions", () => {
    expect(typeof sdk.cpmm.canBuy).toBe("function");
    expect(typeof sdk.cpmm.canSell).toBe("function");
  });

  it("should export formatting functions", () => {
    expect(typeof sdk.cpmm.formatUsdc).toBe("function");
    expect(typeof sdk.cpmm.parseUsdc).toBe("function");
    expect(typeof sdk.cpmm.formatBps).toBe("function");
    expect(typeof sdk.cpmm.formatTokenPrice).toBe("function");
    expect(typeof sdk.cpmm.formatProbability).toBe("function");
    expect(typeof sdk.cpmm.getSafeProgressValue).toBe("function");
    expect(typeof sdk.cpmm.isExtremePrice).toBe("function");
  });
});

// ============================================================
// Namespace isolation (no naming conflicts)
// ============================================================

describe("Namespace isolation", () => {
  it("lmsr.BPS and cpmm.BPS should be equal but independent", () => {
    expect(sdk.lmsr.BPS).toBe(sdk.cpmm.BPS);
    // They're the same value but accessed through different namespaces
    expect(sdk.lmsr.BPS).toBe(10_000n);
    expect(sdk.cpmm.BPS).toBe(10_000n);
  });

  it("lmsr.formatUsdc and cpmm.formatUsdc should both work independently", () => {
    const lmsrResult = sdk.lmsr.formatUsdc(1_000_000n);
    const cpmmResult = sdk.cpmm.formatUsdc(1_000_000n);
    expect(lmsrResult).toBe("1.00");
    expect(cpmmResult).toBe("1.00");
  });

  it("lmsr.parseUsdc and cpmm.parseUsdc should both work independently", () => {
    const lmsrResult = sdk.lmsr.parseUsdc("100");
    const cpmmResult = sdk.cpmm.parseUsdc("100");
    expect(lmsrResult).toBe(100_000_000n);
    expect(cpmmResult).toBe(100_000_000n);
  });
});

// ============================================================
// EIP-712 types re-export
// ============================================================

describe("EIP-712 re-exports", () => {
  it("should export Side enum", () => {
    expect(sdk.Side).toBeDefined();
    expect(sdk.Side.YES).toBe(0);
    expect(sdk.Side.NO).toBe(1);
  });

  it("should export SignatureType enum", () => {
    expect(sdk.SignatureType).toBeDefined();
    expect(sdk.SignatureType.EOA).toBe(0);
  });

  it("should export MatchType enum", () => {
    expect(sdk.MatchType).toBeDefined();
    expect(sdk.MatchType.COMPLEMENTARY).toBe(0);
    expect(sdk.MatchType.MINT).toBe(1);
    expect(sdk.MatchType.MERGE).toBe(2);
  });

  it("should export ResolutionStatus enum", () => {
    expect(sdk.ResolutionStatus).toBeDefined();
    expect(sdk.ResolutionStatus.Open).toBe(0);
    expect(sdk.ResolutionStatus.Pending).toBe(1);
    expect(sdk.ResolutionStatus.Resolved).toBe(2);
  });

  it("should export OutcomeV2 enum", () => {
    expect(sdk.OutcomeV2).toBeDefined();
    expect(sdk.OutcomeV2.None).toBe(0);
    expect(sdk.OutcomeV2.Yes).toBe(1);
    expect(sdk.OutcomeV2.No).toBe(2);
    expect(sdk.OutcomeV2.Invalid).toBe(3);
  });

  it("should export typed data builder functions", () => {
    expect(typeof sdk.getTradeIntentTypedData).toBe("function");
    expect(typeof sdk.getOrderTypedData).toBe("function");
    expect(typeof sdk.getBackstopRouterDomain).toBe("function");
    expect(typeof sdk.getExchangeDomain).toBe("function");
  });
});

// ============================================================
// Deployment re-exports
// ============================================================

describe("Deployment re-exports", () => {
  it("should export deployment lookup functions", () => {
    expect(typeof sdk.getDeployments).toBe("function");
    expect(typeof sdk.getDeploymentsV2).toBe("function");
  });

  it("should export chain support utilities", () => {
    expect(typeof sdk.isSupportedChain).toBe("function");
    expect(sdk.SUPPORTED_CHAIN_IDS).toBeDefined();
  });

  it("should export deployment constants", () => {
    expect(sdk.deploymentsBaseSepolia).toBeDefined();
    expect(sdk.deploymentsBaseSepoliaV2).toBeDefined();
    expect(sdk.deploymentsBaseMainnet).toBeDefined();
    expect(sdk.deploymentsBaseMainnetV2).toBeDefined();
  });
});

// ============================================================
// ABI re-exports
// ============================================================

describe("ABI re-exports", () => {
  it("should export v1 ABIs", () => {
    expect(sdk.MockUSDCAbi).toBeDefined();
    expect(sdk.VaultAbi).toBeDefined();
    expect(sdk.FactoryAbi).toBeDefined();
    expect(sdk.MarketAbi).toBeDefined();
    expect(sdk.MarketLMSRAbi).toBeDefined();
  });

  it("should export v2 ABIs", () => {
    expect(sdk.FactoryV2Abi).toBeDefined();
    expect(sdk.ExchangeAbi).toBeDefined();
    expect(sdk.BackstopRouterAbi).toBeDefined();
    expect(sdk.ShareTokenAbi).toBeDefined();
    expect(sdk.VaultV2Abi).toBeDefined();
    expect(sdk.DelegationRegistryAbi).toBeDefined();
    expect(sdk.MarketLMSRv2Abi).toBeDefined();
  });

  it("all ABIs should be arrays", () => {
    const abis = [
      sdk.MockUSDCAbi,
      sdk.VaultAbi,
      sdk.FactoryAbi,
      sdk.MarketAbi,
      sdk.MarketLMSRAbi,
      sdk.FactoryV2Abi,
      sdk.ExchangeAbi,
      sdk.BackstopRouterAbi,
      sdk.ShareTokenAbi,
      sdk.VaultV2Abi,
      sdk.DelegationRegistryAbi,
      sdk.MarketLMSRv2Abi,
    ];
    for (const abi of abis) {
      expect(Array.isArray(abi)).toBe(true);
      expect(abi.length).toBeGreaterThan(0);
    }
  });
});
