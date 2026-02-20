/**
 * ABI structural integrity tests
 *
 * Validates that ABI exports:
 * - Are non-empty arrays
 * - Contain expected critical functions and events
 * - Match the contract interface (no accidental removals)
 *
 * These tests catch ABI export regressions — if a contract is recompiled
 * and an ABI is re-exported, missing functions/events break here first.
 */

import { describe, it, expect } from "vitest";

// v1 ABIs
import { MockUSDCAbi } from "./v1/MockUSDC";
import { VaultAbi } from "./v1/Vault";
import { FactoryAbi } from "./v1/Factory";
import { MarketAbi } from "./v1/Market";
import { MarketLMSRAbi } from "./v1/MarketLMSR";

// v2 ABIs
import { FactoryV2Abi } from "./v2/FactoryV2";
import { ExchangeAbi } from "./v2/Exchange";
import { BackstopRouterAbi } from "./v2/BackstopRouter";
import { ShareTokenAbi } from "./v2/ShareToken";
import { VaultV2Abi } from "./v2/VaultV2";
import { DelegationRegistryAbi } from "./v2/DelegationRegistry";
import { MarketLMSRv2Abi } from "./v2/MarketLMSRv2";

// ============================================================
// Helpers
// ============================================================

type AbiEntry = {
  type: string;
  name?: string;
  inputs?: Array<{ name: string; type: string }>;
  outputs?: Array<{ name: string; type: string }>;
  stateMutability?: string;
};

function getFunctionNames(abi: AbiEntry[]): string[] {
  return abi.filter((e) => e.type === "function").map((e) => e.name!);
}

function getEventNames(abi: AbiEntry[]): string[] {
  return abi.filter((e) => e.type === "event").map((e) => e.name!);
}

function hasFunction(abi: AbiEntry[], name: string): boolean {
  return abi.some((e) => e.type === "function" && e.name === name);
}

function hasEvent(abi: AbiEntry[], name: string): boolean {
  return abi.some((e) => e.type === "event" && e.name === name);
}

// ============================================================
// v1: MockUSDC
// ============================================================

describe("MockUSDC ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(MockUSDCAbi)).toBe(true);
    expect(MockUSDCAbi.length).toBeGreaterThan(0);
  });

  it("should contain ERC-20 functions", () => {
    expect(hasFunction(MockUSDCAbi, "approve")).toBe(true);
    expect(hasFunction(MockUSDCAbi, "balanceOf")).toBe(true);
    expect(hasFunction(MockUSDCAbi, "allowance")).toBe(true);
    expect(hasFunction(MockUSDCAbi, "decimals")).toBe(true);
  });

  it("should contain faucet/mint", () => {
    const hasFaucetOrMint =
      hasFunction(MockUSDCAbi, "faucet") || hasFunction(MockUSDCAbi, "mint");
    expect(hasFaucetOrMint).toBe(true);
  });
});

// ============================================================
// v1: Vault
// ============================================================

describe("Vault ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(VaultAbi)).toBe(true);
    expect(VaultAbi.length).toBeGreaterThan(0);
  });

  it("should contain core vault functions", () => {
    expect(hasFunction(VaultAbi, "deposit")).toBe(true);
    expect(hasFunction(VaultAbi, "withdraw")).toBe(true);
    expect(hasFunction(VaultAbi, "balanceOf")).toBe(true);
  });
});

// ============================================================
// v1: Factory
// ============================================================

describe("Factory ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(FactoryAbi)).toBe(true);
    expect(FactoryAbi.length).toBeGreaterThan(0);
  });

  it("should contain market creation functions", () => {
    expect(hasFunction(FactoryAbi, "createMarket")).toBe(true);
    expect(hasFunction(FactoryAbi, "createMarketFor")).toBe(true);
  });

  it("should contain delegation functions", () => {
    expect(hasFunction(FactoryAbi, "createMarketForDelegated")).toBe(true);
    expect(hasFunction(FactoryAbi, "addDelegatedSigner")).toBe(true);
    expect(hasFunction(FactoryAbi, "removeDelegatedSigner")).toBe(true);
  });

  it("should have MarketLMSRCreated event", () => {
    expect(hasEvent(FactoryAbi, "MarketLMSRCreated")).toBe(true);
  });
});

// ============================================================
// v1: Market (CPMM)
// ============================================================

describe("Market ABI (CPMM)", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(MarketAbi)).toBe(true);
    expect(MarketAbi.length).toBeGreaterThan(0);
  });

  it("should contain trading functions", () => {
    expect(hasFunction(MarketAbi, "buyYes")).toBe(true);
    expect(hasFunction(MarketAbi, "buyNo")).toBe(true);
    expect(hasFunction(MarketAbi, "sellYes")).toBe(true);
    expect(hasFunction(MarketAbi, "sellNo")).toBe(true);
  });

  it("should contain resolution functions", () => {
    expect(hasFunction(MarketAbi, "resolveMarket")).toBe(true);
    expect(hasFunction(MarketAbi, "redeem")).toBe(true);
  });

  it("should have Trade event", () => {
    expect(hasEvent(MarketAbi, "Trade")).toBe(true);
  });
});

// ============================================================
// v1: MarketLMSR
// ============================================================

describe("MarketLMSR ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(MarketLMSRAbi)).toBe(true);
    expect(MarketLMSRAbi.length).toBeGreaterThan(0);
  });

  it("should contain trading functions", () => {
    expect(hasFunction(MarketLMSRAbi, "buyYes")).toBe(true);
    expect(hasFunction(MarketLMSRAbi, "buyNo")).toBe(true);
    expect(hasFunction(MarketLMSRAbi, "sellYes")).toBe(true);
    expect(hasFunction(MarketLMSRAbi, "sellNo")).toBe(true);
  });

  it("should contain two-phase resolution functions", () => {
    expect(hasFunction(MarketLMSRAbi, "proposeResolution")).toBe(true);
    expect(hasFunction(MarketLMSRAbi, "disputeResolution")).toBe(true);
    expect(hasFunction(MarketLMSRAbi, "finalizeResolution")).toBe(true);
    expect(hasFunction(MarketLMSRAbi, "markAsInvalid")).toBe(true);
  });

  it("should have LMSR state variables", () => {
    expect(hasFunction(MarketLMSRAbi, "b")).toBe(true);
    expect(hasFunction(MarketLMSRAbi, "qYes")).toBe(true);
    expect(hasFunction(MarketLMSRAbi, "qNo")).toBe(true);
    expect(hasFunction(MarketLMSRAbi, "baseCost")).toBe(true);
  });

  it("should have resolution events", () => {
    expect(hasEvent(MarketLMSRAbi, "ResolutionProposed")).toBe(true);
    expect(hasEvent(MarketLMSRAbi, "ResolutionDisputed")).toBe(true);
    expect(hasEvent(MarketLMSRAbi, "Trade")).toBe(true);
  });
});

// ============================================================
// v2: FactoryV2
// ============================================================

describe("FactoryV2 ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(FactoryV2Abi)).toBe(true);
    expect(FactoryV2Abi.length).toBeGreaterThan(0);
  });

  it("should contain EIP-712 typehashes", () => {
    expect(hasFunction(FactoryV2Abi, "CREATE_MARKET_TYPEHASH")).toBe(true);
    expect(hasFunction(FactoryV2Abi, "DELEGATED_CREATE_TYPEHASH")).toBe(true);
  });

  it("should contain market creation functions", () => {
    expect(hasFunction(FactoryV2Abi, "createMarket")).toBe(true);
    expect(hasFunction(FactoryV2Abi, "createMarketFor")).toBe(true);
    expect(hasFunction(FactoryV2Abi, "createMarketForDelegated")).toBe(true);
  });

  it("should contain relayer management", () => {
    expect(hasFunction(FactoryV2Abi, "addRelayer")).toBe(true);
    expect(hasFunction(FactoryV2Abi, "removeRelayer")).toBe(true);
    expect(hasFunction(FactoryV2Abi, "trustedRelayers")).toBe(true);
  });

  it("should have nonce and request ID tracking", () => {
    expect(hasFunction(FactoryV2Abi, "nonces")).toBe(true);
    expect(hasFunction(FactoryV2Abi, "usedRequestIds")).toBe(true);
  });

  it("should have creation pause control", () => {
    expect(hasFunction(FactoryV2Abi, "pauseCreation")).toBe(true);
    expect(hasFunction(FactoryV2Abi, "unpauseCreation")).toBe(true);
  });

  it("should have MarketV2Created event", () => {
    expect(hasEvent(FactoryV2Abi, "MarketV2Created")).toBe(true);
  });

  it("should have eip712Domain for EIP-5267", () => {
    expect(hasFunction(FactoryV2Abi, "eip712Domain")).toBe(true);
  });
});

// ============================================================
// v2: Exchange (CLOB)
// ============================================================

describe("Exchange ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(ExchangeAbi)).toBe(true);
    expect(ExchangeAbi.length).toBeGreaterThan(0);
  });

  it("should contain core CLOB functions", () => {
    expect(hasFunction(ExchangeAbi, "matchOrders")).toBe(true);
    expect(hasFunction(ExchangeAbi, "cancelOrder")).toBe(true);
    expect(hasFunction(ExchangeAbi, "getOrderHash")).toBe(true);
    expect(hasFunction(ExchangeAbi, "bumpNonce")).toBe(true);
  });

  it("should contain fee management", () => {
    expect(hasFunction(ExchangeAbi, "protocolFeeBps")).toBe(true);
    expect(hasFunction(ExchangeAbi, "setProtocolFeeBps")).toBe(true);
    expect(hasFunction(ExchangeAbi, "withdrawProtocolFees")).toBe(true);
  });

  it("should contain condition pause control", () => {
    expect(hasFunction(ExchangeAbi, "pauseCondition")).toBe(true);
    expect(hasFunction(ExchangeAbi, "unpauseCondition")).toBe(true);
    expect(hasFunction(ExchangeAbi, "conditionPaused")).toBe(true);
  });

  it("should have ORDER_TYPEHASH", () => {
    expect(hasFunction(ExchangeAbi, "ORDER_TYPEHASH")).toBe(true);
  });

  it("should have critical events", () => {
    expect(hasEvent(ExchangeAbi, "OrdersMatched")).toBe(true);
    expect(hasEvent(ExchangeAbi, "OrderCancelled")).toBe(true);
    expect(hasEvent(ExchangeAbi, "OrderFilled")).toBe(true);
  });

  it("should support ERC-1155 receiver interface", () => {
    expect(hasFunction(ExchangeAbi, "onERC1155Received")).toBe(true);
    expect(hasFunction(ExchangeAbi, "onERC1155BatchReceived")).toBe(true);
  });
});

// ============================================================
// v2: BackstopRouter
// ============================================================

describe("BackstopRouter ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(BackstopRouterAbi)).toBe(true);
    expect(BackstopRouterAbi.length).toBeGreaterThan(0);
  });

  it("should contain trade execution functions", () => {
    expect(hasFunction(BackstopRouterAbi, "executeTrade")).toBe(true);
    expect(hasFunction(BackstopRouterAbi, "executeTradeIntent")).toBe(true);
  });

  it("should contain quote functions", () => {
    expect(hasFunction(BackstopRouterAbi, "quoteBuy")).toBe(true);
    expect(hasFunction(BackstopRouterAbi, "quoteSell")).toBe(true);
  });

  it("should contain backstop management", () => {
    expect(hasFunction(BackstopRouterAbi, "registerBackstop")).toBe(true);
    expect(hasFunction(BackstopRouterAbi, "backstops")).toBe(true);
  });

  it("should have TRADE_INTENT_TYPEHASH", () => {
    expect(hasFunction(BackstopRouterAbi, "TRADE_INTENT_TYPEHASH")).toBe(true);
  });

  it("should have intent cancellation", () => {
    expect(hasFunction(BackstopRouterAbi, "cancelIntent")).toBe(true);
    expect(hasFunction(BackstopRouterAbi, "bumpNonce")).toBe(true);
  });

  it("should have BackstopTrade event", () => {
    expect(hasEvent(BackstopRouterAbi, "BackstopTrade")).toBe(true);
  });
});

// ============================================================
// v2: ShareToken (ERC-1155)
// ============================================================

describe("ShareToken ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(ShareTokenAbi)).toBe(true);
    expect(ShareTokenAbi.length).toBeGreaterThan(0);
  });

  it("should contain ERC-1155 functions", () => {
    expect(hasFunction(ShareTokenAbi, "balanceOf")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "balanceOfBatch")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "safeTransferFrom")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "safeBatchTransferFrom")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "setApprovalForAll")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "isApprovedForAll")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "supportsInterface")).toBe(true);
  });

  it("should contain conditional token functions", () => {
    expect(hasFunction(ShareTokenAbi, "prepareCondition")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "splitPosition")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "mergePositions")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "redeemPositions")).toBe(true);
  });

  it("should contain two-phase resolution functions", () => {
    expect(hasFunction(ShareTokenAbi, "proposeResolution")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "disputeResolution")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "finalizeResolution")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "markAsInvalid")).toBe(true);
  });

  it("should have resolution constants", () => {
    expect(hasFunction(ShareTokenAbi, "DISPUTE_PERIOD")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "ADMIN_RESOLVE_WINDOW")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "PAYOUT_PER_SHARE_WINNER")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "PAYOUT_PER_SHARE_INVALID")).toBe(true);
  });

  it("should have condition and token query functions", () => {
    expect(hasFunction(ShareTokenAbi, "getCondition")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "getConditionId")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "getTokenIds")).toBe(true);
    expect(hasFunction(ShareTokenAbi, "getResolution")).toBe(true);
  });

  it("should have critical events", () => {
    expect(hasEvent(ShareTokenAbi, "ConditionPrepared")).toBe(true);
    expect(hasEvent(ShareTokenAbi, "PositionSplit")).toBe(true);
    expect(hasEvent(ShareTokenAbi, "PositionsMerged")).toBe(true);
    expect(hasEvent(ShareTokenAbi, "PositionRedeemed")).toBe(true);
    expect(hasEvent(ShareTokenAbi, "ResolutionProposed")).toBe(true);
    expect(hasEvent(ShareTokenAbi, "ResolutionDisputed")).toBe(true);
    expect(hasEvent(ShareTokenAbi, "ResolutionFinalized")).toBe(true);
    expect(hasEvent(ShareTokenAbi, "MarkedAsInvalid")).toBe(true);
  });

  it("should have ERC-1155 events", () => {
    expect(hasEvent(ShareTokenAbi, "TransferSingle")).toBe(true);
    expect(hasEvent(ShareTokenAbi, "TransferBatch")).toBe(true);
    expect(hasEvent(ShareTokenAbi, "ApprovalForAll")).toBe(true);
  });
});

// ============================================================
// v2: VaultV2
// ============================================================

describe("VaultV2 ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(VaultV2Abi)).toBe(true);
    expect(VaultV2Abi.length).toBeGreaterThan(0);
  });

  it("should contain core deposit/withdraw", () => {
    expect(hasFunction(VaultV2Abi, "deposit")).toBe(true);
    expect(hasFunction(VaultV2Abi, "withdraw")).toBe(true);
    expect(hasFunction(VaultV2Abi, "balanceOf")).toBe(true);
  });

  it("should contain split/merge accounting", () => {
    expect(hasFunction(VaultV2Abi, "lockForSplit")).toBe(true);
    expect(hasFunction(VaultV2Abi, "releaseForRedeem")).toBe(true);
    expect(hasFunction(VaultV2Abi, "releaseFromMerge")).toBe(true);
    expect(hasFunction(VaultV2Abi, "splitReserve")).toBe(true);
  });

  it("should contain fee accounting", () => {
    expect(hasFunction(VaultV2Abi, "accumulateFee")).toBe(true);
    expect(hasFunction(VaultV2Abi, "feePool")).toBe(true);
    expect(hasFunction(VaultV2Abi, "withdrawFeePool")).toBe(true);
  });

  it("should contain invariant check", () => {
    expect(hasFunction(VaultV2Abi, "checkInvariant")).toBe(true);
  });

  it("should contain pause control", () => {
    expect(hasFunction(VaultV2Abi, "pause")).toBe(true);
    expect(hasFunction(VaultV2Abi, "unpause")).toBe(true);
    expect(hasFunction(VaultV2Abi, "paused")).toBe(true);
  });
});

// ============================================================
// v2: DelegationRegistry
// ============================================================

describe("DelegationRegistry ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(DelegationRegistryAbi)).toBe(true);
    expect(DelegationRegistryAbi.length).toBeGreaterThan(0);
  });

  it("should contain delegation management", () => {
    expect(hasFunction(DelegationRegistryAbi, "setDelegation")).toBe(true);
    expect(hasFunction(DelegationRegistryAbi, "revokeDelegation")).toBe(true);
    expect(hasFunction(DelegationRegistryAbi, "getDelegation")).toBe(true);
    expect(hasFunction(DelegationRegistryAbi, "isAuthorized")).toBe(true);
  });

  it("should contain spend tracking", () => {
    expect(hasFunction(DelegationRegistryAbi, "recordSpend")).toBe(true);
  });

  it("should contain authorized contract management", () => {
    expect(hasFunction(DelegationRegistryAbi, "addAuthorizedContract")).toBe(
      true
    );
    expect(hasFunction(DelegationRegistryAbi, "removeAuthorizedContract")).toBe(
      true
    );
  });

  it("should have delegation events", () => {
    expect(hasEvent(DelegationRegistryAbi, "DelegationSet")).toBe(true);
    expect(hasEvent(DelegationRegistryAbi, "DelegationRevoked")).toBe(true);
    expect(hasEvent(DelegationRegistryAbi, "SpendRecorded")).toBe(true);
  });
});

// ============================================================
// v2: MarketLMSRv2
// ============================================================

describe("MarketLMSRv2 ABI", () => {
  it("should be a non-empty array", () => {
    expect(Array.isArray(MarketLMSRv2Abi)).toBe(true);
    expect(MarketLMSRv2Abi.length).toBeGreaterThan(0);
  });

  it("should contain trading functions", () => {
    expect(hasFunction(MarketLMSRv2Abi, "buyYes")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "buyNo")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "sellYes")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "sellNo")).toBe(true);
  });

  it("should contain LMSR state variables", () => {
    expect(hasFunction(MarketLMSRv2Abi, "b")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "qYes")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "qNo")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "baseCost")).toBe(true);
  });

  it("should contain LMSR constants", () => {
    expect(hasFunction(MarketLMSRv2Abi, "UNIT_INT")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "LN2")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "USDC_TO_SD59x18")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "PAYOUT_PER_SHARE")).toBe(true);
  });

  it("should contain initialization", () => {
    expect(hasFunction(MarketLMSRv2Abi, "initConfig")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "initialize")).toBe(true);
  });

  it("should contain two-phase resolution", () => {
    expect(hasFunction(MarketLMSRv2Abi, "proposeResolution")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "disputeResolution")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "finalizeResolution")).toBe(true);
    expect(hasFunction(MarketLMSRv2Abi, "markAsInvalid")).toBe(true);
  });

  it("should have Trade event with LMSR signature", () => {
    const tradeEvent = MarketLMSRv2Abi.find(
      (e: AbiEntry) => e.type === "event" && e.name === "Trade"
    ) as AbiEntry | undefined;
    expect(tradeEvent).toBeDefined();

    // Verify Trade event has the LMSR-specific fields
    const inputNames = tradeEvent!.inputs!.map((i) => i.name);
    expect(inputNames).toContain("side");
    expect(inputNames).toContain("isBuy");
    expect(inputNames).toContain("amountUsdc");
    expect(inputNames).toContain("shares");
    expect(inputNames).toContain("fee");
    expect(inputNames).toContain("priceYesBps");
    expect(inputNames).toContain("qYesAfter");
    expect(inputNames).toContain("qNoAfter");
  });
});

// ============================================================
// Cross-version consistency
// ============================================================

describe("Cross-version ABI consistency", () => {
  it("v1 MarketLMSR and v2 MarketLMSR should both have Trade event", () => {
    expect(hasEvent(MarketLMSRAbi, "Trade")).toBe(true);
    expect(hasEvent(MarketLMSRv2Abi, "Trade")).toBe(true);
  });

  it("v1 Factory and v2 Factory should both have createMarketFor", () => {
    expect(hasFunction(FactoryAbi, "createMarketFor")).toBe(true);
    expect(hasFunction(FactoryV2Abi, "createMarketFor")).toBe(true);
  });

  it("v1 Vault and v2 Vault should both have deposit/withdraw", () => {
    expect(hasFunction(VaultAbi, "deposit")).toBe(true);
    expect(hasFunction(VaultV2Abi, "deposit")).toBe(true);
    expect(hasFunction(VaultAbi, "withdraw")).toBe(true);
    expect(hasFunction(VaultV2Abi, "withdraw")).toBe(true);
  });

  it("v2 MarketLMSR Trade event should have LMSR fields (not CPMM)", () => {
    const v2Trade = MarketLMSRv2Abi.find(
      (e: AbiEntry) => e.type === "event" && e.name === "Trade"
    ) as AbiEntry | undefined;
    const v1CpmmTrade = MarketAbi.find(
      (e: AbiEntry) => e.type === "event" && e.name === "Trade"
    ) as AbiEntry | undefined;

    expect(v2Trade).toBeDefined();
    expect(v1CpmmTrade).toBeDefined();

    const v2Fields = v2Trade!.inputs!.map((i) => i.name);
    const v1CpmmFields = v1CpmmTrade!.inputs!.map((i) => i.name);

    // v2 LMSR has qYesAfter/qNoAfter, CPMM v1 does not
    expect(v2Fields).toContain("qYesAfter");
    expect(v2Fields).toContain("qNoAfter");
    expect(v1CpmmFields).not.toContain("qYesAfter");
  });
});
