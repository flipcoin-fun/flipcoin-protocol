/**
 * FlipCoin protocol deployment addresses per chain
 *
 * Source of truth for all contract addresses.
 * Use getDeployments(chainId) and getDeploymentsV2(chainId) to look up by chain.
 */

export interface Deployments {
  chainId: number;
  chainName: string;
  usdc: `0x${string}`;
  vault: `0x${string}`;
  factory: `0x${string}`;
  /** Block number when Factory was deployed (for event queries) */
  deployBlock: bigint;
}

/** v2 Hybrid CLOB + LMSR deployment addresses */
export interface DeploymentsV2 extends Deployments {
  delegationRegistry: `0x${string}`;
  shareToken: `0x${string}`;
  exchange: `0x${string}`;
  backstopRouter: `0x${string}`;
  marketImplementation: `0x${string}`;
  depositRouter: `0x${string}`;
}

// ============================================================
// v1 Deployments
// ============================================================

export const deploymentsLocal: Deployments = {
  chainId: 31337,
  chainName: "Anvil Local",
  usdc: "0x700b6A60ce7EaaEA56F065753d8dcB9653dbAD35",
  vault: "0xA15BB66138824a1c7167f5E85b957d04Dd34E468",
  factory: "0xb19b36b1456E65E3A6D514D3F715f204BD59f431",
  deployBlock: 0n,
};

export const deploymentsBaseSepolia: Deployments = {
  chainId: 84532,
  chainName: "Base Sepolia",
  usdc: "0x204b379814c17cc5f2a900120ab5875f1a1fefa5",
  vault: "0x4a85b9853e81a090871e5292b19545f4f9faed45",
  factory: "0x142656261cB9f2F9BA4193a0009a29644f04B067",
  deployBlock: 37692643n,
};

export const deploymentsBaseMainnet: Deployments = {
  chainId: 8453,
  chainName: "Base",
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  vault: "0xACBf5A2f23d2b959D0623fe4345D3F9369dEA15a",
  factory: "0x0F5f1863213F3eb831FB5F46bF9b83F5cca6c8A6",
  deployBlock: 43786444n,
};

export const deploymentsSepolia: Deployments = {
  chainId: 11155111,
  chainName: "Sepolia",
  usdc: "0x0000000000000000000000000000000000000000",
  vault: "0x0000000000000000000000000000000000000000",
  factory: "0x0000000000000000000000000000000000000000",
  deployBlock: 0n,
};

// ============================================================
// v2 Deployments (Hybrid CLOB + LMSR)
// ============================================================

export const deploymentsBaseSepoliaV2: DeploymentsV2 = {
  chainId: 84532,
  chainName: "Base Sepolia (v2)",
  usdc: "0x305470163394b589DC20B25E8D281B91e4c0647e",
  vault: "0xFf7F3FB8Cd2531d620A0895f29aB137965E9CC51",
  factory: "0x9AD7a9FF367D6c762c3211070111F47C682293a0",
  delegationRegistry: "0xC732b2851950E7CF6C8100bC992E2737d4EA23fC",
  shareToken: "0xf3b1E673c8FEc06EFDf16d5B9AF6BC9746bcDe48",
  exchange: "0x09a11B89951ADC0C7D786d2d313CF60fE9B72d9a",
  backstopRouter: "0x7b050032226E574AA823FF681f6887561cDEab94",
  marketImplementation: "0x713aCC57BE0f185c84344aFF15d69843a94bf87A",
  depositRouter: "0x0000000000000000000000000000000000000000",
  deployBlock: 37879430n,
};

export const deploymentsBaseMainnetV2: DeploymentsV2 = {
  chainId: 8453,
  chainName: "Base (v2)",
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  vault: "0xACBf5A2f23d2b959D0623fe4345D3F9369dEA15a",
  factory: "0x0F5f1863213F3eb831FB5F46bF9b83F5cca6c8A6",
  delegationRegistry: "0xf7Ee72a9f42dA449907a934B74dF82477Ceae0Ee",
  shareToken: "0x64b050CabF28D28eAb0A121A2259EB284A4fecA8",
  exchange: "0x41fF5e623e5a5a9B00fE876c348cCEfd4cEEd71B",
  backstopRouter: "0x5257985E8170443D9341109419Dda4D206bcE9Af",
  marketImplementation: "0x8F16812c49d015Bc070B587455Cdb88DbAdc9124",
  depositRouter: "0x649ae5e23d44BB6CBEbDb93ac8a32dFbCd77Cc17",
  deployBlock: 43786444n,
};

// ============================================================
// Lookup functions
// ============================================================

export function getDeployments(chainId: number): Deployments | null {
  switch (chainId) {
    case 31337:
      return deploymentsLocal;
    case 84532:
      return deploymentsBaseSepolia;
    case 8453:
      return deploymentsBaseMainnet;
    case 11155111:
      return deploymentsSepolia;
    default:
      return null;
  }
}

export function getDeploymentsV2(chainId: number): DeploymentsV2 | null {
  switch (chainId) {
    case 84532:
      return deploymentsBaseSepoliaV2;
    case 8453:
      return deploymentsBaseMainnetV2;
    default:
      return null;
  }
}

export const SUPPORTED_CHAIN_IDS = [31337, 84532, 8453, 11155111] as const;
export type SupportedChainId = (typeof SUPPORTED_CHAIN_IDS)[number];

export function isSupportedChain(chainId: number): chainId is SupportedChainId {
  return SUPPORTED_CHAIN_IDS.includes(chainId as SupportedChainId);
}
