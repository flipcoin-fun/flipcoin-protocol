/**
 * Minimal ABI for Vault contract
 * Only includes functions used in dev playground
 */
export const VaultAbi = [
  // User methods
  {
    type: "function",
    name: "deposit",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "withdraw",
    inputs: [
      { name: "amount", type: "uint256" },
      { name: "to", type: "address" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "approveMarket",
    inputs: [
      { name: "market", type: "address" },
      { name: "allowanceAmount", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  // View methods
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "allowance",
    inputs: [
      { name: "user", type: "address" },
      { name: "market", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "usdcToken",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isWhitelistedMarket",
    inputs: [{ name: "market", type: "address" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
] as const;
