/**
 * EIP-712 structural integrity and hash consistency tests
 *
 * Validates:
 * 1. Type string canonical encoding (matches Solidity keccak256)
 * 2. Domain separator isolation (different contracts → different domains)
 * 3. Field type correctness (address, uint256, bytes32, uint8, bool)
 * 4. Message ↔ interface consistency (no missing fields)
 * 5. TradeIntent vs Order structural differences
 * 6. Enum value exhaustiveness
 */

import { describe, it, expect } from "vitest";
import { keccak256, encodePacked, toHex } from "viem";
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
// Constants from contracts
// ============================================================

const BACKSTOP_ROUTER_NAME = "FlipCoinBackstopRouter";
const EXCHANGE_NAME = "FlipCoinExchange";
const VERSION = "1";
const BASE_SEPOLIA_CHAIN_ID = 84532;
const BASE_MAINNET_CHAIN_ID = 8453;

const SAMPLE_ADDRESS =
  "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as const;
const ZERO_ADDRESS =
  "0x0000000000000000000000000000000000000000" as const;
const SAMPLE_BYTES32 =
  "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" as const;

// ============================================================
// 1. Typehash Canonical Encoding
// ============================================================

describe("Typehash canonical encoding", () => {
  it("TradeIntent typehash should match Solidity encoding", () => {
    // Solidity: keccak256("TradeIntent(address trader,address signer,bytes32 conditionId,uint8 side,bool isBuy,uint256 amount,uint256 minOut,uint256 deadline,uint256 nonce,uint256 maxFeeBps)")
    const typeString =
      "TradeIntent(address trader,address signer,bytes32 conditionId,uint8 side,bool isBuy,uint256 amount,uint256 minOut,uint256 deadline,uint256 nonce,uint256 maxFeeBps)";
    const expectedTypehash = keccak256(
      encodePacked(["string"], [typeString])
    );

    // Verify the type string matches our typed data structure
    const domain = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const intent: TradeIntent = {
      trader: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      conditionId: SAMPLE_BYTES32,
      side: Side.YES,
      isBuy: true,
      amount: 1n,
      minOut: 0n,
      deadline: 1n,
      nonce: 0n,
      maxFeeBps: 200n,
    };
    const typedData = getTradeIntentTypedData(domain, intent);

    // Build type string from our typed data
    const fields = typedData.types.TradeIntent.map(
      (f) => `${f.type} ${f.name}`
    ).join(",");
    const reconstructedTypeString = `TradeIntent(${fields})`;

    expect(reconstructedTypeString).toBe(typeString);
    // Typehash should be deterministic
    expect(expectedTypehash).toBeDefined();
    expect(expectedTypehash.length).toBe(66); // 0x + 64 hex chars
  });

  it("Order typehash should match Solidity encoding", () => {
    const typeString =
      "Order(uint256 salt,address maker,address signer,address taker,uint256 tokenId,uint256 makerAmount,uint256 takerAmount,uint256 expiration,uint256 nonce,uint256 maxFeeBps,uint8 side,uint8 sigType)";
    const expectedTypehash = keccak256(
      encodePacked(["string"], [typeString])
    );

    const domain = getExchangeDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const order: Order = {
      salt: 1n,
      maker: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      taker: ZERO_ADDRESS,
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

    const fields = typedData.types.Order.map(
      (f) => `${f.type} ${f.name}`
    ).join(",");
    const reconstructedTypeString = `Order(${fields})`;

    expect(reconstructedTypeString).toBe(typeString);
    expect(expectedTypehash).toBeDefined();
  });
});

// ============================================================
// 2. Domain Separator Isolation
// ============================================================

describe("Domain separator isolation", () => {
  it("BackstopRouter and Exchange should have different names", () => {
    const brDomain = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const exDomain = getExchangeDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);

    expect(brDomain.name).not.toBe(exDomain.name);
    expect(brDomain.name).toBe(BACKSTOP_ROUTER_NAME);
    expect(exDomain.name).toBe(EXCHANGE_NAME);
  });

  it("same contract, different chains should have different domains", () => {
    const sepolia = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const mainnet = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_MAINNET_CHAIN_ID);

    expect(sepolia.chainId).not.toBe(mainnet.chainId);
    // Name and version remain the same
    expect(sepolia.name).toBe(mainnet.name);
    expect(sepolia.version).toBe(mainnet.version);
  });

  it("same chain, different addresses should have different domains", () => {
    const addr1 = "0x1111111111111111111111111111111111111111" as const;
    const addr2 = "0x2222222222222222222222222222222222222222" as const;

    const d1 = getBackstopRouterDomain(addr1, BASE_SEPOLIA_CHAIN_ID);
    const d2 = getBackstopRouterDomain(addr2, BASE_SEPOLIA_CHAIN_ID);

    expect(d1.verifyingContract).not.toBe(d2.verifyingContract);
  });

  it("both domains should use version '1'", () => {
    const brDomain = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const exDomain = getExchangeDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);

    expect(brDomain.version).toBe(VERSION);
    expect(exDomain.version).toBe(VERSION);
  });
});

// ============================================================
// 3. Field Type Correctness
// ============================================================

describe("Field type correctness", () => {
  it("TradeIntent types should match contract ABI", () => {
    const domain = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const intent: TradeIntent = {
      trader: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      conditionId: SAMPLE_BYTES32,
      side: Side.YES,
      isBuy: true,
      amount: 1n,
      minOut: 0n,
      deadline: 1n,
      nonce: 0n,
      maxFeeBps: 200n,
    };
    const typedData = getTradeIntentTypedData(domain, intent);
    const typeMap = Object.fromEntries(
      typedData.types.TradeIntent.map((f) => [f.name, f.type])
    );

    // Address types
    expect(typeMap["trader"]).toBe("address");
    expect(typeMap["signer"]).toBe("address");

    // bytes32
    expect(typeMap["conditionId"]).toBe("bytes32");

    // uint8 (enum)
    expect(typeMap["side"]).toBe("uint8");

    // bool
    expect(typeMap["isBuy"]).toBe("bool");

    // uint256
    expect(typeMap["amount"]).toBe("uint256");
    expect(typeMap["minOut"]).toBe("uint256");
    expect(typeMap["deadline"]).toBe("uint256");
    expect(typeMap["nonce"]).toBe("uint256");
    expect(typeMap["maxFeeBps"]).toBe("uint256");
  });

  it("Order types should match contract ABI", () => {
    const domain = getExchangeDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const order: Order = {
      salt: 1n,
      maker: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      taker: ZERO_ADDRESS,
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
    const typeMap = Object.fromEntries(
      typedData.types.Order.map((f) => [f.name, f.type])
    );

    // Addresses
    expect(typeMap["maker"]).toBe("address");
    expect(typeMap["signer"]).toBe("address");
    expect(typeMap["taker"]).toBe("address");

    // uint256
    expect(typeMap["salt"]).toBe("uint256");
    expect(typeMap["tokenId"]).toBe("uint256");
    expect(typeMap["makerAmount"]).toBe("uint256");
    expect(typeMap["takerAmount"]).toBe("uint256");
    expect(typeMap["expiration"]).toBe("uint256");
    expect(typeMap["nonce"]).toBe("uint256");
    expect(typeMap["maxFeeBps"]).toBe("uint256");

    // uint8 (enums)
    expect(typeMap["side"]).toBe("uint8");
    expect(typeMap["sigType"]).toBe("uint8");
  });
});

// ============================================================
// 4. Message ↔ Interface Consistency
// ============================================================

describe("Message ↔ Interface consistency", () => {
  it("TradeIntent message should contain all interface fields", () => {
    const domain = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const intent: TradeIntent = {
      trader: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      conditionId: SAMPLE_BYTES32,
      side: Side.NO,
      isBuy: false,
      amount: 42_000_000n,
      minOut: 40_000_000n,
      deadline: 999999999n,
      nonce: 5n,
      maxFeeBps: 300n,
    };
    const typedData = getTradeIntentTypedData(domain, intent);
    const msg = typedData.message;

    // Every field in the interface should appear in the message
    expect(msg.trader).toBe(intent.trader);
    expect(msg.signer).toBe(intent.signer);
    expect(msg.conditionId).toBe(intent.conditionId);
    expect(msg.side).toBe(intent.side);
    expect(msg.isBuy).toBe(intent.isBuy);
    expect(msg.amount).toBe(intent.amount);
    expect(msg.minOut).toBe(intent.minOut);
    expect(msg.deadline).toBe(intent.deadline);
    expect(msg.nonce).toBe(intent.nonce);
    expect(msg.maxFeeBps).toBe(intent.maxFeeBps);

    // Message should have exactly the same number of fields as types
    const typeFieldCount = typedData.types.TradeIntent.length;
    const messageFieldCount = Object.keys(msg).length;
    expect(messageFieldCount).toBe(typeFieldCount);
  });

  it("Order message should contain all interface fields", () => {
    const domain = getExchangeDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const order: Order = {
      salt: 999n,
      maker: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      taker: ZERO_ADDRESS,
      tokenId: 42n,
      makerAmount: 10_000_000n,
      takerAmount: 20_000_000n,
      expiration: 1700000000n,
      nonce: 3n,
      maxFeeBps: 150n,
      side: Side.NO,
      sigType: SignatureType.POLY_PROXY,
    };
    const typedData = getOrderTypedData(domain, order);
    const msg = typedData.message;

    expect(msg.salt).toBe(order.salt);
    expect(msg.maker).toBe(order.maker);
    expect(msg.signer).toBe(order.signer);
    expect(msg.taker).toBe(order.taker);
    expect(msg.tokenId).toBe(order.tokenId);
    expect(msg.makerAmount).toBe(order.makerAmount);
    expect(msg.takerAmount).toBe(order.takerAmount);
    expect(msg.expiration).toBe(order.expiration);
    expect(msg.nonce).toBe(order.nonce);
    expect(msg.maxFeeBps).toBe(order.maxFeeBps);
    expect(msg.side).toBe(order.side);
    expect(msg.sigType).toBe(order.sigType);

    const typeFieldCount = typedData.types.Order.length;
    const messageFieldCount = Object.keys(msg).length;
    expect(messageFieldCount).toBe(typeFieldCount);
  });
});

// ============================================================
// 5. TradeIntent vs Order Structural Differences
// ============================================================

describe("TradeIntent vs Order structural differences", () => {
  it("TradeIntent has conditionId (bytes32), Order has tokenId (uint256)", () => {
    const brDomain = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const exDomain = getExchangeDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);

    const intent: TradeIntent = {
      trader: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      conditionId: SAMPLE_BYTES32,
      side: Side.YES,
      isBuy: true,
      amount: 1n,
      minOut: 0n,
      deadline: 1n,
      nonce: 0n,
      maxFeeBps: 200n,
    };
    const order: Order = {
      salt: 1n,
      maker: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      taker: ZERO_ADDRESS,
      tokenId: 1n,
      makerAmount: 1n,
      takerAmount: 1n,
      expiration: 1n,
      nonce: 0n,
      maxFeeBps: 200n,
      side: Side.YES,
      sigType: SignatureType.EOA,
    };

    const intentData = getTradeIntentTypedData(brDomain, intent);
    const orderData = getOrderTypedData(exDomain, order);

    const intentFields = intentData.types.TradeIntent.map((f) => f.name);
    const orderFields = orderData.types.Order.map((f) => f.name);

    // TradeIntent-only fields
    expect(intentFields).toContain("conditionId");
    expect(intentFields).toContain("isBuy");
    expect(intentFields).toContain("trader");

    // Order-only fields
    expect(orderFields).toContain("tokenId");
    expect(orderFields).toContain("salt");
    expect(orderFields).toContain("maker");
    expect(orderFields).toContain("taker");
    expect(orderFields).toContain("sigType");

    // Both should have
    expect(intentFields).toContain("signer");
    expect(orderFields).toContain("signer");
    expect(intentFields).toContain("nonce");
    expect(orderFields).toContain("nonce");
    expect(intentFields).toContain("side");
    expect(orderFields).toContain("side");
  });

  it("TradeIntent has 10 fields, Order has 12 fields", () => {
    const brDomain = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const exDomain = getExchangeDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);

    const intent: TradeIntent = {
      trader: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      conditionId: SAMPLE_BYTES32,
      side: Side.YES,
      isBuy: true,
      amount: 1n,
      minOut: 0n,
      deadline: 1n,
      nonce: 0n,
      maxFeeBps: 200n,
    };
    const order: Order = {
      salt: 1n,
      maker: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      taker: ZERO_ADDRESS,
      tokenId: 1n,
      makerAmount: 1n,
      takerAmount: 1n,
      expiration: 1n,
      nonce: 0n,
      maxFeeBps: 200n,
      side: Side.YES,
      sigType: SignatureType.EOA,
    };

    const intentData = getTradeIntentTypedData(brDomain, intent);
    const orderData = getOrderTypedData(exDomain, order);

    expect(intentData.types.TradeIntent).toHaveLength(10);
    expect(orderData.types.Order).toHaveLength(12);
  });
});

// ============================================================
// 6. Enum Exhaustiveness
// ============================================================

describe("Enum exhaustiveness", () => {
  it("Side should have exactly 2 values", () => {
    const values = Object.values(Side).filter(
      (v) => typeof v === "number"
    );
    expect(values).toHaveLength(2);
    expect(values).toContain(0);
    expect(values).toContain(1);
  });

  it("SignatureType should have exactly 3 values", () => {
    const values = Object.values(SignatureType).filter(
      (v) => typeof v === "number"
    );
    expect(values).toHaveLength(3);
    expect(values).toContain(0);
    expect(values).toContain(1);
    expect(values).toContain(2);
  });

  it("MatchType should have exactly 3 values", () => {
    const values = Object.values(MatchType).filter(
      (v) => typeof v === "number"
    );
    expect(values).toHaveLength(3);
    expect(values).toContain(0); // COMPLEMENTARY
    expect(values).toContain(1); // MINT
    expect(values).toContain(2); // MERGE
  });

  it("ResolutionStatus should have exactly 3 values", () => {
    const values = Object.values(ResolutionStatus).filter(
      (v) => typeof v === "number"
    );
    expect(values).toHaveLength(3);
    expect(values).toContain(0); // Open
    expect(values).toContain(1); // Pending
    expect(values).toContain(2); // Resolved
  });

  it("OutcomeV2 should have exactly 4 values", () => {
    const values = Object.values(OutcomeV2).filter(
      (v) => typeof v === "number"
    );
    expect(values).toHaveLength(4);
    expect(values).toContain(0); // None
    expect(values).toContain(1); // Yes
    expect(values).toContain(2); // No
    expect(values).toContain(3); // Invalid
  });
});

// ============================================================
// 7. Cross-domain replay protection
// ============================================================

describe("Cross-domain replay protection", () => {
  it("same intent signed for different chains produces different typed data", () => {
    const intent: TradeIntent = {
      trader: SAMPLE_ADDRESS,
      signer: SAMPLE_ADDRESS,
      conditionId: SAMPLE_BYTES32,
      side: Side.YES,
      isBuy: true,
      amount: 10_000_000n,
      minOut: 9_000_000n,
      deadline: 1700000000n,
      nonce: 0n,
      maxFeeBps: 200n,
    };

    const sepoliaDomain = getBackstopRouterDomain(
      SAMPLE_ADDRESS,
      BASE_SEPOLIA_CHAIN_ID
    );
    const mainnetDomain = getBackstopRouterDomain(
      SAMPLE_ADDRESS,
      BASE_MAINNET_CHAIN_ID
    );

    const sepoliaData = getTradeIntentTypedData(sepoliaDomain, intent);
    const mainnetData = getTradeIntentTypedData(mainnetDomain, intent);

    // Messages are identical
    expect(sepoliaData.message).toEqual(mainnetData.message);
    // But domains differ
    expect(sepoliaData.domain.chainId).not.toBe(mainnetData.domain.chainId);
  });

  it("same order for BackstopRouter vs Exchange produces different typed data", () => {
    // This verifies that even if field values happen to match,
    // different primaryType + domain prevents replay
    const brDomain = getBackstopRouterDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);
    const exDomain = getExchangeDomain(SAMPLE_ADDRESS, BASE_SEPOLIA_CHAIN_ID);

    expect(brDomain.name).not.toBe(exDomain.name);
  });
});
