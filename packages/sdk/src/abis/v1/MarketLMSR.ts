/**
 * ABI for MarketLMSR contract
 * LMSR (Logarithmic Market Scoring Rule) prediction market
 */
export const MarketLMSRAbi = [
  // ============================================================
  // Trading
  // ============================================================
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

  // ============================================================
  // Resolution (with Timelock)
  // ============================================================
  {
    type: "function",
    name: "proposeResolution",
    inputs: [{ name: "_outcome", type: "uint8" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "disputeResolution",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "finalizeResolution",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
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
  {
    type: "function",
    name: "markAsInvalid",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  // Timelock state
  {
    type: "function",
    name: "proposedOutcome",
    inputs: [],
    outputs: [{ type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "proposedAt",
    inputs: [],
    outputs: [{ type: "uint64" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "disputed",
    inputs: [],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "DISPUTE_PERIOD",
    inputs: [],
    outputs: [{ type: "uint64" }],
    stateMutability: "view",
  },

  // ============================================================
  // View - Prices
  // ============================================================
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

  // ============================================================
  // View - Position
  // ============================================================
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

  // ============================================================
  // User shares mappings (public getters)
  // ============================================================
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

  // ============================================================
  // LMSR-specific state (SD59x18)
  // ============================================================
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

  // ============================================================
  // View - State
  // ============================================================
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
  {
    type: "function",
    name: "initialized",
    inputs: [],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },

  // ============================================================
  // View - Totals
  // ============================================================
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
    name: "payoutPerShare",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "winningSharesTotal",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },

  // ============================================================
  // View - Fees
  // ============================================================
  {
    type: "function",
    name: "creatorFeesAcc",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "protocolFeesAcc",
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
    name: "creatorFeeBps",
    inputs: [],
    outputs: [{ type: "uint16" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "protocolFeeBps",
    inputs: [],
    outputs: [{ type: "uint16" }],
    stateMutability: "view",
  },

  // ============================================================
  // View - Market metadata
  // ============================================================
  {
    type: "function",
    name: "question",
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
    name: "creator",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "admin",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "vault",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "factory",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "createdAt",
    inputs: [],
    outputs: [{ type: "uint64" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "resolvedAt",
    inputs: [],
    outputs: [{ type: "uint64" }],
    stateMutability: "view",
  },

  // ============================================================
  // Constants
  // ============================================================
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
  {
    type: "function",
    name: "PAYOUT_PER_SHARE",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "ADMIN_RESOLVE_WINDOW",
    inputs: [],
    outputs: [{ type: "uint64" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "MAX_TRADE_USDC",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },

  // ============================================================
  // Emergency Controls
  // ============================================================
  {
    type: "function",
    name: "paused",
    inputs: [],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "maxTradeUsdc",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "pauseMarket",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "unpauseMarket",
    inputs: [],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "setMaxTrade",
    inputs: [{ name: "newMax", type: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },

  // ============================================================
  // Events
  // ============================================================
  {
    type: "event",
    name: "MarketInitialized",
    inputs: [
      { name: "b", type: "int256", indexed: false },
      { name: "seedUsdc", type: "uint256", indexed: false },
      { name: "initialPriceYesBps", type: "uint256", indexed: false },
      { name: "creator", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "Trade",
    inputs: [
      { name: "trader", type: "address", indexed: true },
      { name: "side", type: "uint8", indexed: false },
      { name: "isBuy", type: "bool", indexed: false },
      { name: "amountUsdc", type: "uint256", indexed: false },
      { name: "shares", type: "uint256", indexed: false },
      { name: "fee", type: "uint256", indexed: false },
      { name: "priceYesBps", type: "uint256", indexed: false },
      { name: "qYesAfter", type: "int256", indexed: false },
      { name: "qNoAfter", type: "int256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ResolutionProposed",
    inputs: [
      { name: "proposedOutcome", type: "uint8", indexed: false },
      { name: "proposedAt", type: "uint64", indexed: false },
      { name: "finalizeAfter", type: "uint64", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ResolutionDisputed",
    inputs: [
      { name: "challenger", type: "address", indexed: true },
      { name: "proposedOutcome", type: "uint8", indexed: false },
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
  {
    type: "event",
    name: "MarketMarkedInvalid",
    inputs: [
      { name: "caller", type: "address", indexed: true },
      { name: "markedAt", type: "uint64", indexed: false },
    ],
  },
  {
    type: "event",
    name: "MarketPaused",
    inputs: [{ name: "admin", type: "address", indexed: true }],
  },
  {
    type: "event",
    name: "MarketUnpaused",
    inputs: [{ name: "admin", type: "address", indexed: true }],
  },
  {
    type: "event",
    name: "MaxTradeUpdated",
    inputs: [{ name: "newMax", type: "uint256", indexed: false }],
  },
] as const;
