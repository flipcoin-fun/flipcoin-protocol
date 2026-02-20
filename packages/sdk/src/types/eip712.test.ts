import { describe, it, expect } from "vitest";
import {
  Side,
  SignatureType,
  MatchType,
  ResolutionStatus,
  OutcomeV2,
  getTradeIntentTypedData,
  getOrderTypedData,
  getBackstopRouterDomain,
  getExchangeDomain,
  type TradeIntent,
  type Order,
} from "./eip712";

// ============================================================
// Enum values
// ============================================================

describe("Side enum", () => {
  it("YES = 0, NO = 1", () => {
    expect(Side.YES).toBe(0);
    expect(Side.NO).toBe(1);
  });
});

describe("SignatureType enum", () => {
  it("has correct values", () => {
    expect(SignatureType.EOA).toBe(0);
    expect(SignatureType.POLY_PROXY).toBe(1);
    expect(SignatureType.POLY_GNOSIS_SAFE).toBe(2);
  });
});

describe("MatchType enum", () => {
  it("has correct values", () => {
    expect(MatchType.COMPLEMENTARY).toBe(0);
    expect(MatchType.MINT).toBe(1);
    expect(MatchType.MERGE).toBe(2);
  });
});

describe("ResolutionStatus enum", () => {
  it("has correct values", () => {
    expect(ResolutionStatus.Open).toBe(0);
    expect(ResolutionStatus.Pending).toBe(1);
    expect(ResolutionStatus.Resolved).toBe(2);
  });
});

describe("OutcomeV2 enum", () => {
  it("has correct values", () => {
    expect(OutcomeV2.None).toBe(0);
    expect(OutcomeV2.Yes).toBe(1);
    expect(OutcomeV2.No).toBe(2);
    expect(OutcomeV2.Invalid).toBe(3);
  });
});

// ============================================================
// Domain helpers
// ============================================================

describe("getBackstopRouterDomain", () => {
  it("returns correct domain", () => {
    const addr = "0x7b050032226E574AA823FF681f6887561cDEab94" as const;
    const domain = getBackstopRouterDomain(addr, 84532);
    expect(domain).toEqual({
      name: "FlipCoinBackstopRouter",
      version: "1",
      chainId: 84532,
      verifyingContract: addr,
    });
  });

  it("accepts custom chainId", () => {
    const addr = "0x7b050032226E574AA823FF681f6887561cDEab94" as const;
    const domain = getBackstopRouterDomain(addr, 1);
    expect(domain.chainId).toBe(1);
  });
});

describe("getExchangeDomain", () => {
  it("returns correct domain", () => {
    const addr = "0x09a11B89951ADC0C7D786d2d313CF60fE9B72d9a" as const;
    const domain = getExchangeDomain(addr, 84532);
    expect(domain).toEqual({
      name: "FlipCoinExchange",
      version: "1",
      chainId: 84532,
      verifyingContract: addr,
    });
  });

  it("accepts custom chainId", () => {
    const addr = "0x09a11B89951ADC0C7D786d2d313CF60fE9B72d9a" as const;
    const domain = getExchangeDomain(addr, 8453);
    expect(domain.chainId).toBe(8453);
  });
});

// ============================================================
// TradeIntent typed data
// ============================================================

describe("getTradeIntentTypedData", () => {
  const domain = {
    name: "FlipCoinBackstopRouter",
    version: "1",
    chainId: 84532,
    verifyingContract: "0x7b050032226E574AA823FF681f6887561cDEab94" as const,
  };

  const intent: TradeIntent = {
    trader: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    signer: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    conditionId: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
    side: Side.YES,
    isBuy: true,
    amount: 10_000_000n, // 10 USDC
    minOut: 9_500_000n,
    deadline: 1700000000n,
    nonce: 0n,
    maxFeeBps: 200n,
  };

  it("returns correct primaryType", () => {
    const typedData = getTradeIntentTypedData(domain, intent);
    expect(typedData.primaryType).toBe("TradeIntent");
  });

  it("returns correct domain", () => {
    const typedData = getTradeIntentTypedData(domain, intent);
    expect(typedData.domain).toEqual(domain);
  });

  it("includes all 10 TradeIntent fields in types", () => {
    const typedData = getTradeIntentTypedData(domain, intent);
    expect(typedData.types.TradeIntent).toHaveLength(10);
    const fieldNames = typedData.types.TradeIntent.map((f) => f.name);
    expect(fieldNames).toEqual([
      "trader",
      "signer",
      "conditionId",
      "side",
      "isBuy",
      "amount",
      "minOut",
      "deadline",
      "nonce",
      "maxFeeBps",
    ]);
  });

  it("maps message fields correctly", () => {
    const typedData = getTradeIntentTypedData(domain, intent);
    expect(typedData.message.trader).toBe(intent.trader);
    expect(typedData.message.signer).toBe(intent.signer);
    expect(typedData.message.conditionId).toBe(intent.conditionId);
    expect(typedData.message.side).toBe(Side.YES);
    expect(typedData.message.isBuy).toBe(true);
    expect(typedData.message.amount).toBe(10_000_000n);
    expect(typedData.message.minOut).toBe(9_500_000n);
    expect(typedData.message.deadline).toBe(1700000000n);
    expect(typedData.message.nonce).toBe(0n);
    expect(typedData.message.maxFeeBps).toBe(200n);
  });

  it("handles sell NO side", () => {
    const sellIntent: TradeIntent = { ...intent, side: Side.NO, isBuy: false };
    const typedData = getTradeIntentTypedData(domain, sellIntent);
    expect(typedData.message.side).toBe(Side.NO);
    expect(typedData.message.isBuy).toBe(false);
  });

  it("handles zero amounts", () => {
    const zeroIntent: TradeIntent = { ...intent, amount: 0n, minOut: 0n };
    const typedData = getTradeIntentTypedData(domain, zeroIntent);
    expect(typedData.message.amount).toBe(0n);
    expect(typedData.message.minOut).toBe(0n);
  });

  it("handles large amounts", () => {
    const largeIntent: TradeIntent = { ...intent, amount: 10_000_000_000n }; // 10k USDC
    const typedData = getTradeIntentTypedData(domain, largeIntent);
    expect(typedData.message.amount).toBe(10_000_000_000n);
  });
});

// ============================================================
// Order typed data
// ============================================================

describe("getOrderTypedData", () => {
  const domain = {
    name: "FlipCoinExchange",
    version: "1",
    chainId: 84532,
    verifyingContract: "0x09a11B89951ADC0C7D786d2d313CF60fE9B72d9a" as const,
  };

  const order: Order = {
    salt: 123456n,
    maker: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    signer: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    taker: "0x0000000000000000000000000000000000000000", // any taker
    tokenId: 1n,
    makerAmount: 5_000_000n, // 5 USDC
    takerAmount: 10_000_000n, // 10 shares
    expiration: 1700000000n,
    nonce: 0n,
    maxFeeBps: 200n,
    side: Side.YES,
    sigType: SignatureType.EOA,
  };

  it("returns correct primaryType", () => {
    const typedData = getOrderTypedData(domain, order);
    expect(typedData.primaryType).toBe("Order");
  });

  it("returns correct domain", () => {
    const typedData = getOrderTypedData(domain, order);
    expect(typedData.domain).toEqual(domain);
  });

  it("includes all 12 Order fields in types", () => {
    const typedData = getOrderTypedData(domain, order);
    expect(typedData.types.Order).toHaveLength(12);
    const fieldNames = typedData.types.Order.map((f) => f.name);
    expect(fieldNames).toEqual([
      "salt",
      "maker",
      "signer",
      "taker",
      "tokenId",
      "makerAmount",
      "takerAmount",
      "expiration",
      "nonce",
      "maxFeeBps",
      "side",
      "sigType",
    ]);
  });

  it("maps all Order types correctly", () => {
    const typedData = getOrderTypedData(domain, order);
    const typeMap = Object.fromEntries(
      typedData.types.Order.map((f) => [f.name, f.type]),
    );
    expect(typeMap["salt"]).toBe("uint256");
    expect(typeMap["maker"]).toBe("address");
    expect(typeMap["signer"]).toBe("address");
    expect(typeMap["taker"]).toBe("address");
    expect(typeMap["tokenId"]).toBe("uint256");
    expect(typeMap["makerAmount"]).toBe("uint256");
    expect(typeMap["takerAmount"]).toBe("uint256");
    expect(typeMap["expiration"]).toBe("uint256");
    expect(typeMap["nonce"]).toBe("uint256");
    expect(typeMap["maxFeeBps"]).toBe("uint256");
    expect(typeMap["side"]).toBe("uint8");
    expect(typeMap["sigType"]).toBe("uint8");
  });

  it("maps message fields correctly", () => {
    const typedData = getOrderTypedData(domain, order);
    expect(typedData.message.salt).toBe(123456n);
    expect(typedData.message.maker).toBe(order.maker);
    expect(typedData.message.signer).toBe(order.signer);
    expect(typedData.message.taker).toBe(order.taker);
    expect(typedData.message.tokenId).toBe(1n);
    expect(typedData.message.makerAmount).toBe(5_000_000n);
    expect(typedData.message.takerAmount).toBe(10_000_000n);
    expect(typedData.message.expiration).toBe(1700000000n);
    expect(typedData.message.nonce).toBe(0n);
    expect(typedData.message.maxFeeBps).toBe(200n);
    expect(typedData.message.side).toBe(Side.YES);
    expect(typedData.message.sigType).toBe(SignatureType.EOA);
  });

  it("handles NO side with different sigType", () => {
    const noOrder: Order = { ...order, side: Side.NO, sigType: SignatureType.POLY_GNOSIS_SAFE };
    const typedData = getOrderTypedData(domain, noOrder);
    expect(typedData.message.side).toBe(Side.NO);
    expect(typedData.message.sigType).toBe(SignatureType.POLY_GNOSIS_SAFE);
  });

  it("handles zero taker (any taker)", () => {
    const typedData = getOrderTypedData(domain, order);
    expect(typedData.message.taker).toBe("0x0000000000000000000000000000000000000000");
  });

  it("handles max uint256 values", () => {
    const maxOrder: Order = {
      ...order,
      makerAmount: 2n ** 256n - 1n,
      takerAmount: 2n ** 256n - 1n,
    };
    const typedData = getOrderTypedData(domain, maxOrder);
    expect(typedData.message.makerAmount).toBe(2n ** 256n - 1n);
    expect(typedData.message.takerAmount).toBe(2n ** 256n - 1n);
  });
});

// ============================================================
// Type field consistency with Solidity ABI
// ============================================================

describe("EIP-712 type field consistency", () => {
  it("TradeIntent field order matches Solidity struct", () => {
    // The ABI shows: trader, signer, conditionId, side, isBuy, amount, minOut, deadline, nonce, maxFeeBps
    const domain = getBackstopRouterDomain("0x7b050032226E574AA823FF681f6887561cDEab94", 84532);
    const intent: TradeIntent = {
      trader: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      signer: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      conditionId: "0x0000000000000000000000000000000000000000000000000000000000000001",
      side: Side.YES,
      isBuy: true,
      amount: 1n,
      minOut: 0n,
      deadline: 1n,
      nonce: 0n,
      maxFeeBps: 200n,
    };
    const typedData = getTradeIntentTypedData(domain, intent);

    // ABI struct component order
    const abiFieldOrder = [
      "trader",
      "signer",
      "conditionId",
      "side",
      "isBuy",
      "amount",
      "minOut",
      "deadline",
      "nonce",
      "maxFeeBps",
    ];
    const typedDataFieldOrder = typedData.types.TradeIntent.map((f) => f.name);
    expect(typedDataFieldOrder).toEqual(abiFieldOrder);
  });

  it("Order field order matches Solidity struct", () => {
    // ABI shows: salt, maker, signer, taker, tokenId, makerAmount, takerAmount, expiration, nonce, maxFeeBps, side, sigType
    const domain = getExchangeDomain("0x09a11B89951ADC0C7D786d2d313CF60fE9B72d9a", 84532);
    const order: Order = {
      salt: 1n,
      maker: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      signer: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      taker: "0x0000000000000000000000000000000000000000",
      tokenId: 1n,
      makerAmount: 1n,
      takerAmount: 1n,
      expiration: 1n,
      nonce: 0n,
      maxFeeBps: 200n,
      side: Side.YES,
      sigType: SignatureType.EOA,
    };
    const typedData = getOrderTypedData(domain, order);

    const abiFieldOrder = [
      "salt",
      "maker",
      "signer",
      "taker",
      "tokenId",
      "makerAmount",
      "takerAmount",
      "expiration",
      "nonce",
      "maxFeeBps",
      "side",
      "sigType",
    ];
    const typedDataFieldOrder = typedData.types.Order.map((f) => f.name);
    expect(typedDataFieldOrder).toEqual(abiFieldOrder);
  });
});
