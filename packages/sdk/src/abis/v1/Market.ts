/**
 * Minimal ABI for Market contract
 * Only includes functions used in dev playground
 */
export const MarketAbi = [
  // Trading
  {
    type: "function",
    name: "buyYes",
    inputs: [
      { name: "amountUsdc", type: "uint256" },
      { name: "minSharesOut", type: "uint256" },
    ],
    outputs: [{ name: "sharesOut", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "buyNo",
    inputs: [
      { name: "amountUsdc", type: "uint256" },
      { name: "minSharesOut", type: "uint256" },
    ],
    outputs: [{ name: "sharesOut", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "sellYes",
    inputs: [
      { name: "shares", type: "uint256" },
      { name: "minAmountOut", type: "uint256" },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "sellNo",
    inputs: [
      { name: "shares", type: "uint256" },
      { name: "minAmountOut", type: "uint256" },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  // Resolution
  {
    type: "function",
    name: "resolveMarket",
    inputs: [{ name: "_outcome", type: "uint8" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "redeem",
    inputs: [],
    outputs: [{ name: "payout", type: "uint256" }],
    stateMutability: "nonpayable",
  },
  // View - Prices
  {
    type: "function",
    name: "getPrices",
    inputs: [],
    outputs: [
      { name: "priceYesBps", type: "uint256" },
      { name: "priceNoBps", type: "uint256" },
    ],
    stateMutability: "view",
  },
  // View - Position
  {
    type: "function",
    name: "getUserPosition",
    inputs: [{ name: "user", type: "address" }],
    outputs: [
      { name: "yesShares", type: "uint256" },
      { name: "noShares", type: "uint256" },
    ],
    stateMutability: "view",
  },
  // User shares mappings (public getters)
  {
    type: "function",
    name: "yesShares",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "noShares",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  // View - State
  {
    type: "function",
    name: "status",
    inputs: [],
    outputs: [{ type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "outcome",
    inputs: [],
    outputs: [{ type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "deadline",
    inputs: [],
    outputs: [{ type: "uint64" }],
    stateMutability: "view",
  },
  // View - AMM State (public variables)
  {
    type: "function",
    name: "yesReserve",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "noReserve",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "k",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "totalFeeBps",
    inputs: [],
    outputs: [{ type: "uint16" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "usdcPool",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "payoutPerShare",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "yesSharesTotal",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "noSharesTotal",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "question",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "creator",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "resolutionRules",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "resolutionSource",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "imageUrl",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "description",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "category",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "view",
  },
  // LMSR-specific (MarketLMSR only)
  {
    type: "function",
    name: "b",
    inputs: [],
    outputs: [{ type: "int256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "qYes",
    inputs: [],
    outputs: [{ type: "int256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "qNo",
    inputs: [],
    outputs: [{ type: "int256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "baseCost",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  // Constants
  {
    type: "function",
    name: "MIN_RESERVE",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "MIN_TRADE_USDC",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "BPS",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  // Events
  {
    type: "event",
    name: "Trade",
    inputs: [
      { name: "trader", type: "address", indexed: true },
      { name: "side", type: "uint8", indexed: false },
      { name: "isBuy", type: "bool", indexed: false },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "amountOut", type: "uint256", indexed: false },
      { name: "fee", type: "uint256", indexed: false },
      { name: "priceYesAfter", type: "uint256", indexed: false },
      { name: "yesReserveAfter", type: "uint256", indexed: false },
      { name: "noReserveAfter", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "MarketResolved",
    inputs: [
      { name: "outcome", type: "uint8", indexed: false },
      { name: "payoutPerShare", type: "uint256", indexed: false },
      { name: "winningSharesTotal", type: "uint256", indexed: false },
      { name: "resolvedAt", type: "uint64", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Redeemed",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "claimShares", type: "uint256", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
] as const;
