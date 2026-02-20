/**
 * ABI for FactoryLMSR contract
 * Supports direct createMarket, meta-tx createMarketFor, and delegated createMarketForDelegated (EIP-712)
 */
export const FactoryAbi = [
  // Direct market creation (creator = msg.sender)
  {
    type: "function",
    name: "createMarket",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "question", type: "string" },
          { name: "description", type: "string" },
          { name: "category", type: "string" },
          { name: "resolutionRules", type: "string" },
          { name: "resolutionSource", type: "string" },
          { name: "imageUrl", type: "string" },
          { name: "deadline", type: "uint64" },
        ],
      },
      { name: "seedUsdc", type: "uint256" },
      { name: "initialPriceYesBps", type: "uint256" },
    ],
    outputs: [{ name: "market", type: "address" }],
    stateMutability: "nonpayable",
  },
  // Meta-transaction market creation (creator = signer of EIP-712 signature)
  {
    type: "function",
    name: "createMarketFor",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "question", type: "string" },
          { name: "description", type: "string" },
          { name: "category", type: "string" },
          { name: "resolutionRules", type: "string" },
          { name: "resolutionSource", type: "string" },
          { name: "imageUrl", type: "string" },
          { name: "deadline", type: "uint64" },
        ],
      },
      { name: "seedUsdc", type: "uint256" },
      { name: "initialPriceYesBps", type: "uint256" },
      { name: "creator", type: "address" },
      { name: "deadline", type: "uint256" },
      { name: "requestId", type: "bytes32" },
      { name: "v", type: "uint8" },
      { name: "r", type: "bytes32" },
      { name: "s", type: "bytes32" },
    ],
    outputs: [{ name: "market", type: "address" }],
    stateMutability: "nonpayable",
  },
  // Delegated meta-transaction market creation (signer signs, owner gets creator role)
  {
    type: "function",
    name: "createMarketForDelegated",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "question", type: "string" },
          { name: "description", type: "string" },
          { name: "category", type: "string" },
          { name: "resolutionRules", type: "string" },
          { name: "resolutionSource", type: "string" },
          { name: "imageUrl", type: "string" },
          { name: "deadline", type: "uint64" },
        ],
      },
      { name: "seedUsdc", type: "uint256" },
      { name: "initialPriceYesBps", type: "uint256" },
      { name: "owner", type: "address" },
      { name: "signer", type: "address" },
      { name: "deadline", type: "uint256" },
      { name: "requestId", type: "bytes32" },
      { name: "v", type: "uint8" },
      { name: "r", type: "bytes32" },
      { name: "s", type: "bytes32" },
    ],
    outputs: [{ name: "market", type: "address" }],
    stateMutability: "nonpayable",
  },
  // Add delegated signer (owner calls to authorize a session key)
  {
    type: "function",
    name: "addDelegatedSigner",
    inputs: [{ name: "signer", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  // Remove delegated signer (owner calls to revoke a session key)
  {
    type: "function",
    name: "removeDelegatedSigner",
    inputs: [{ name: "signer", type: "address" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  // Check if signer is delegated for owner
  {
    type: "function",
    name: "delegatedSigners",
    inputs: [
      { name: "owner", type: "address" },
      { name: "signer", type: "address" },
    ],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  // Delegated create typehash
  {
    type: "function",
    name: "DELEGATED_CREATE_TYPEHASH",
    inputs: [],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
  // Check if requestId has been used (on-chain idempotency)
  {
    type: "function",
    name: "usedRequestIds",
    inputs: [{ name: "requestId", type: "bytes32" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  // View functions
  {
    type: "function",
    name: "getMarketById",
    inputs: [{ name: "id", type: "uint64" }],
    outputs: [{ name: "market", type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "nextMarketId",
    inputs: [],
    outputs: [{ type: "uint64" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "nonces",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "DOMAIN_SEPARATOR",
    inputs: [],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
  // EIP-1167 clone implementation address
  {
    type: "function",
    name: "marketImplementation",
    inputs: [],
    outputs: [{ type: "address" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "trustedRelayers",
    inputs: [{ name: "relayer", type: "address" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  // Events
  {
    type: "event",
    name: "MarketLMSRCreated",
    inputs: [
      { name: "marketId", type: "uint64", indexed: true },
      { name: "market", type: "address", indexed: true },
      { name: "creator", type: "address", indexed: true },
      { name: "b", type: "int256", indexed: false },
      { name: "seedUsdc", type: "uint256", indexed: false },
      { name: "initialPriceYesBps", type: "uint256", indexed: false },
      { name: "deadline", type: "uint64", indexed: false },
    ],
  },
  {
    type: "event",
    name: "RelayerAdded",
    inputs: [{ name: "relayer", type: "address", indexed: true }],
  },
  {
    type: "event",
    name: "RelayerRemoved",
    inputs: [{ name: "relayer", type: "address", indexed: true }],
  },
  // Event for meta-transaction market creation (includes relayer for audit)
  {
    type: "event",
    name: "MarketCreatedViaRelayer",
    inputs: [
      { name: "marketId", type: "uint64", indexed: true },
      { name: "market", type: "address", indexed: true },
      { name: "creator", type: "address", indexed: true },
      { name: "relayer", type: "address", indexed: false },
      { name: "requestId", type: "bytes32", indexed: false },
    ],
  },
  // Delegation events
  {
    type: "event",
    name: "DelegatedSignerAdded",
    inputs: [
      { name: "owner", type: "address", indexed: true },
      { name: "signer", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "DelegatedSignerRemoved",
    inputs: [
      { name: "owner", type: "address", indexed: true },
      { name: "signer", type: "address", indexed: true },
    ],
  },
] as const;
