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
  /** LmsrFeeCollector — whitelisted on VaultV2 for LMSR fee withdrawal. Optional until deployed per chain. */
  feeCollector?: `0x${string}`;
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
  usdc: "0xf60a5a0fca9805bFc5a5cdf9356F67091aD5DebD",
  vault: "0xF23527BD7989fbde345059D1AaAFa663532C01c1",
  factory: "0xa681D7D1AeECBf426C1c28DAeD56987A436C52AF",
  delegationRegistry: "0x945f5557b3B0037b9cEB694303C33d418251762A",
  shareToken: "0xDdBD56caDaBd4336a0743D2cAf623eb400e0C290",
  exchange: "0xeAeF77160e87C5a107156B3cB7324Ab587087850",
  backstopRouter: "0x7b0E6aa1DAEC704003f81e2fEef3Fa5DAB157b2a",
  marketImplementation: "0xDd70070758c4Cb78E7F72310D0f98657B2F77FC9",
  depositRouter: "0xdCcFD2db3Def560E753365A5eaF2F44251B9843a",
  deployBlock: 38314732n,
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
  feeCollector: "0x12a20Aa075277391b18e97b64FAc1e12980e10d3",
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
