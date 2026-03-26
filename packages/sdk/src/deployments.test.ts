/**
 * Tests for deployment address registry
 *
 * Validates:
 * - Lookup functions return correct deployments per chain
 * - Address format (0x + 40 hex chars)
 * - Chain ID support detection
 * - v2 deployments include all additional contracts
 * - Mainnet USDC address matches canonical
 */

import { describe, it, expect } from "vitest";
import {
  // Types
  type Deployments,
  type DeploymentsV2,
  type SupportedChainId,

  // v1 Deployments
  deploymentsLocal,
  deploymentsBaseSepolia,
  deploymentsBaseMainnet,
  deploymentsSepolia,

  // v2 Deployments
  deploymentsBaseSepoliaV2,
  deploymentsBaseMainnetV2,

  // Lookup functions
  getDeployments,
  getDeploymentsV2,

  // Chain support
  SUPPORTED_CHAIN_IDS,
  isSupportedChain,
} from "./deployments";

// ============================================================
// Helpers
// ============================================================

const ADDRESS_REGEX = /^0x[0-9a-fA-F]{40}$/;

function isValidAddress(addr: string): boolean {
  return ADDRESS_REGEX.test(addr);
}

function isZeroAddress(addr: string): boolean {
  return addr === "0x0000000000000000000000000000000000000000";
}

// ============================================================
// getDeployments (v1)
// ============================================================

describe("getDeployments", () => {
  it("should return Anvil Local for chainId 31337", () => {
    const d = getDeployments(31337);
    expect(d).not.toBeNull();
    expect(d!.chainId).toBe(31337);
    expect(d!.chainName).toBe("Anvil Local");
    expect(d).toBe(deploymentsLocal);
  });

  it("should return Base Sepolia for chainId 84532", () => {
    const d = getDeployments(84532);
    expect(d).not.toBeNull();
    expect(d!.chainId).toBe(84532);
    expect(d!.chainName).toBe("Base Sepolia");
    expect(d).toBe(deploymentsBaseSepolia);
  });

  it("should return Base Mainnet for chainId 8453", () => {
    const d = getDeployments(8453);
    expect(d).not.toBeNull();
    expect(d!.chainId).toBe(8453);
    expect(d!.chainName).toBe("Base");
    expect(d).toBe(deploymentsBaseMainnet);
  });

  it("should return Sepolia for chainId 11155111", () => {
    const d = getDeployments(11155111);
    expect(d).not.toBeNull();
    expect(d!.chainId).toBe(11155111);
    expect(d!.chainName).toBe("Sepolia");
    expect(d).toBe(deploymentsSepolia);
  });

  it("should return null for unsupported chainId", () => {
    expect(getDeployments(0)).toBeNull();
    expect(getDeployments(1)).toBeNull(); // Ethereum mainnet
    expect(getDeployments(137)).toBeNull(); // Polygon
    expect(getDeployments(999999)).toBeNull();
  });
});

// ============================================================
// getDeploymentsV2
// ============================================================

describe("getDeploymentsV2", () => {
  it("should return Base Sepolia v2 for chainId 84532", () => {
    const d = getDeploymentsV2(84532);
    expect(d).not.toBeNull();
    expect(d!.chainId).toBe(84532);
    expect(d).toBe(deploymentsBaseSepoliaV2);
  });

  it("should return Base Mainnet v2 for chainId 8453", () => {
    const d = getDeploymentsV2(8453);
    expect(d).not.toBeNull();
    expect(d!.chainId).toBe(8453);
    expect(d).toBe(deploymentsBaseMainnetV2);
  });

  it("should return null for chains without v2", () => {
    expect(getDeploymentsV2(31337)).toBeNull(); // Anvil — no v2
    expect(getDeploymentsV2(11155111)).toBeNull(); // Sepolia — no v2
    expect(getDeploymentsV2(1)).toBeNull();
    expect(getDeploymentsV2(0)).toBeNull();
  });
});

// ============================================================
// Address format validation
// ============================================================

describe("Address format", () => {
  const v1Deployments = [
    deploymentsLocal,
    deploymentsBaseSepolia,
    deploymentsBaseMainnet,
    deploymentsSepolia,
  ];

  const v2Deployments = [deploymentsBaseSepoliaV2, deploymentsBaseMainnetV2];

  it("all v1 deployments should have valid address format", () => {
    for (const d of v1Deployments) {
      expect(isValidAddress(d.usdc), `${d.chainName} usdc`).toBe(true);
      expect(isValidAddress(d.vault), `${d.chainName} vault`).toBe(true);
      expect(isValidAddress(d.factory), `${d.chainName} factory`).toBe(true);
    }
  });

  it("all v2 deployments should have valid address format", () => {
    for (const d of v2Deployments) {
      expect(isValidAddress(d.usdc), `${d.chainName} usdc`).toBe(true);
      expect(isValidAddress(d.vault), `${d.chainName} vault`).toBe(true);
      expect(isValidAddress(d.factory), `${d.chainName} factory`).toBe(true);
      expect(
        isValidAddress(d.delegationRegistry),
        `${d.chainName} delegationRegistry`
      ).toBe(true);
      expect(isValidAddress(d.shareToken), `${d.chainName} shareToken`).toBe(
        true
      );
      expect(isValidAddress(d.exchange), `${d.chainName} exchange`).toBe(true);
      expect(
        isValidAddress(d.backstopRouter),
        `${d.chainName} backstopRouter`
      ).toBe(true);
      expect(
        isValidAddress(d.marketImplementation),
        `${d.chainName} marketImplementation`
      ).toBe(true);
    }
  });

  it("Base Sepolia v2 should have non-zero contract addresses", () => {
    const d = deploymentsBaseSepoliaV2;
    expect(isZeroAddress(d.usdc)).toBe(false);
    expect(isZeroAddress(d.vault)).toBe(false);
    expect(isZeroAddress(d.factory)).toBe(false);
    expect(isZeroAddress(d.delegationRegistry)).toBe(false);
    expect(isZeroAddress(d.shareToken)).toBe(false);
    expect(isZeroAddress(d.exchange)).toBe(false);
    expect(isZeroAddress(d.backstopRouter)).toBe(false);
    expect(isZeroAddress(d.marketImplementation)).toBe(false);
  });

  it("Base Mainnet v2 should have non-zero contract addresses", () => {
    const d = deploymentsBaseMainnetV2;
    expect(isZeroAddress(d.usdc)).toBe(false);
    expect(isZeroAddress(d.vault)).toBe(false);
    expect(isZeroAddress(d.factory)).toBe(false);
    expect(isZeroAddress(d.delegationRegistry)).toBe(false);
    expect(isZeroAddress(d.shareToken)).toBe(false);
    expect(isZeroAddress(d.exchange)).toBe(false);
    expect(isZeroAddress(d.backstopRouter)).toBe(false);
    expect(isZeroAddress(d.marketImplementation)).toBe(false);
    expect(isZeroAddress(d.depositRouter)).toBe(false);
  });
});

// ============================================================
// Canonical USDC addresses
// ============================================================

describe("Canonical USDC addresses", () => {
  it("Base Mainnet USDC should match canonical address", () => {
    // https://basescan.org/token/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    const canonical = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
    expect(deploymentsBaseMainnet.usdc).toBe(canonical);
  });

  it("v1 and v2 Base Mainnet should use same USDC address", () => {
    expect(deploymentsBaseMainnet.usdc).toBe(deploymentsBaseMainnetV2.usdc);
  });
});

// ============================================================
// Deploy blocks
// ============================================================

describe("Deploy blocks", () => {
  it("Base Sepolia v1 should have non-zero deploy block", () => {
    expect(deploymentsBaseSepolia.deployBlock).toBeGreaterThan(0n);
  });

  it("Base Sepolia v2 should have non-zero deploy block", () => {
    expect(deploymentsBaseSepoliaV2.deployBlock).toBeGreaterThan(0n);
  });

  it("v2 deploy block should be after v1 deploy block", () => {
    expect(deploymentsBaseSepoliaV2.deployBlock).toBeGreaterThan(
      deploymentsBaseSepolia.deployBlock
    );
  });

  it("Anvil deploy block should be 0", () => {
    expect(deploymentsLocal.deployBlock).toBe(0n);
  });
});

// ============================================================
// Chain support
// ============================================================

describe("SUPPORTED_CHAIN_IDS", () => {
  it("should include all expected chains", () => {
    expect(SUPPORTED_CHAIN_IDS).toContain(31337); // Anvil
    expect(SUPPORTED_CHAIN_IDS).toContain(84532); // Base Sepolia
    expect(SUPPORTED_CHAIN_IDS).toContain(8453); // Base Mainnet
    expect(SUPPORTED_CHAIN_IDS).toContain(11155111); // Sepolia
  });

  it("should have exactly 4 supported chains", () => {
    expect(SUPPORTED_CHAIN_IDS).toHaveLength(4);
  });
});

describe("isSupportedChain", () => {
  it("should return true for supported chains", () => {
    expect(isSupportedChain(31337)).toBe(true);
    expect(isSupportedChain(84532)).toBe(true);
    expect(isSupportedChain(8453)).toBe(true);
    expect(isSupportedChain(11155111)).toBe(true);
  });

  it("should return false for unsupported chains", () => {
    expect(isSupportedChain(1)).toBe(false);
    expect(isSupportedChain(137)).toBe(false);
    expect(isSupportedChain(0)).toBe(false);
    expect(isSupportedChain(-1)).toBe(false);
    expect(isSupportedChain(42161)).toBe(false); // Arbitrum
  });
});

// ============================================================
// v2 extends v1 interface
// ============================================================

describe("DeploymentsV2 interface", () => {
  it("should include all v1 fields plus v2-specific fields", () => {
    const d = deploymentsBaseSepoliaV2;
    // v1 fields
    expect(d).toHaveProperty("chainId");
    expect(d).toHaveProperty("chainName");
    expect(d).toHaveProperty("usdc");
    expect(d).toHaveProperty("vault");
    expect(d).toHaveProperty("factory");
    expect(d).toHaveProperty("deployBlock");
    // v2-specific fields
    expect(d).toHaveProperty("delegationRegistry");
    expect(d).toHaveProperty("shareToken");
    expect(d).toHaveProperty("exchange");
    expect(d).toHaveProperty("backstopRouter");
    expect(d).toHaveProperty("marketImplementation");
  });

  it("v2 addresses should all be distinct (no duplicates)", () => {
    const d = deploymentsBaseSepoliaV2;
    const addresses = [
      d.usdc,
      d.vault,
      d.factory,
      d.delegationRegistry,
      d.shareToken,
      d.exchange,
      d.backstopRouter,
      d.marketImplementation,
    ];
    const uniqueAddresses = new Set(addresses);
    expect(uniqueAddresses.size).toBe(addresses.length);
  });
});
