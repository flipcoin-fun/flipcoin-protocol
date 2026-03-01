// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Types
 * @notice Shared types for FlipCoin v2 Hybrid CLOB + LMSR protocol
 * @dev Canonical source for enums and structs used across all v2 contracts
 */

// ============================================================
// Enums
// ============================================================

/// @notice Trading side (YES or NO)
enum Side {
    Yes,
    No
}

/// @notice Market resolution outcome
enum Outcome {
    None,    // Not resolved yet
    Yes,     // YES wins
    No,      // NO wins
    Invalid  // Market invalidated, both sides refunded at $0.50
}

/// @notice Resolution lifecycle status (managed by ShareToken)
enum ResolutionStatus {
    Open,     // Trading active
    Pending,  // Resolution proposed, in 24h dispute period
    Resolved  // Final outcome set
}

/// @notice Exchange order match type
enum MatchType {
    COMPLEMENTARY, // Buyer + Seller same token → direct transfer
    MINT,          // Two buyers opposite tokens → mint pair via split
    MERGE          // Two sellers opposite tokens → merge pair + release USDC
}

/// @notice Signature type for Exchange orders
enum SignatureType {
    EOA,     // Standard ECDSA signature
    EIP1271  // Smart contract wallet (ERC-1271)
}

/// @notice Ledger transfer reasons for Vault events
enum LedgerReason {
    UserDeposit,
    UserWithdraw,
    LockForSplit,
    ReleaseFromMerge,
    ReleaseForRedeem,
    AccumulateFee,
    WithdrawFeePool,
    TransferBetween,
    MarketInitLiquidity,
    PlatformSeed          // Treasury deposits seed on behalf of trial market creator
}

// ============================================================
// Structs — Condition & Resolution (ShareToken)
// ============================================================

/// @notice Condition metadata stored in ShareToken
struct Condition {
    bytes32 conditionId;
    address oracle;        // Address authorized to propose resolution
    bytes32 questionId;    // Unique question identifier
    address collateral;    // USDC address
    uint256 yesTokenId;    // ERC-1155 token ID for YES
    uint256 noTokenId;     // ERC-1155 token ID for NO
    uint64 deadline;       // Resolution eligibility timestamp
    bool prepared;         // Whether condition has been prepared
}

/// @notice Resolution state for a condition
struct Resolution {
    ResolutionStatus status;
    Outcome proposedOutcome;
    Outcome finalOutcome;
    uint64 proposedAt;
    uint64 resolvedAt;
    uint64 finalizeAfter;  // proposedAt + DISPUTE_PERIOD
    bool disputed;
    uint256 payoutPerShare; // 1_000_000 for winner, 500_000 for Invalid
}

// ============================================================
// Structs — Exchange Orders
// ============================================================

/// @notice EIP-712 signed order for Exchange CLOB
struct Order {
    uint256 salt;          // Random nonce for uniqueness
    address maker;         // Order owner (receives funds/tokens)
    address signer;        // Who signed (may differ from maker if delegated)
    address taker;         // Specific counterparty (address(0) = any)
    uint256 tokenId;       // ShareToken ERC-1155 token ID
    uint256 makerAmount;   // Amount maker provides (shares if sell, USDC if buy)
    uint256 takerAmount;   // Amount maker wants (USDC if sell, shares if buy)
    uint256 expiration;    // Order expiry timestamp
    uint256 nonce;         // Replay protection (sequential per signer)
    uint256 maxFeeBps;     // MAX total fee ceiling (protocol + creator)
    Side side;             // YES or NO
    SignatureType sigType; // EOA or EIP1271
}

// ============================================================
// Structs — BackstopRouter TradeIntent
// ============================================================

/// @notice EIP-712 signed intent for LMSR backstop trades
struct TradeIntent {
    address trader;        // Funds owner
    address signer;        // == trader, or delegated via DelegationRegistry
    bytes32 conditionId;   // Market condition
    Side side;             // YES or NO
    bool isBuy;            // true = buy shares, false = sell shares
    uint256 amount;        // USDC if buy, shares if sell
    uint256 minOut;        // min shares if buy, min USDC if sell (slippage)
    uint256 deadline;      // Unix timestamp
    uint256 nonce;         // Sequential per-signer
    uint256 maxFeeBps;     // MAX total fee user accepts
}

// ============================================================
// Structs — DelegationRegistry
// ============================================================

/// @notice Delegation configuration for session keys / agents
struct Delegation {
    bool active;
    address scope;             // Contract scope (address(0) = wildcard)
    uint256 maxNotionalPerDay; // Daily USDC limit (6 decimals), 0 = unlimited
    uint256 spentToday;        // USDC spent in current 24h window
    uint64 dayStart;           // Start of current 24h window
    uint64 expiresAt;          // Delegation expiry (0 = no expiry)
}

// ============================================================
// Structs — Factory Market Creation
// ============================================================

/// @notice Parameters for creating a new market via Factory
struct MarketParams {
    string question;
    string description;
    string category;
    string resolutionRules;
    string resolutionSource;
    string imageUrl;
    uint64 deadline;
}

/// @notice Market info stored by Factory
struct MarketInfo {
    uint64 marketId;
    address market;          // MarketLMSR clone address
    address creator;
    bytes32 conditionId;
    uint64 deadline;
    uint64 createdAt;
}

/// @notice MarketLMSR clone configuration (set by Factory)
struct MarketConfigV2 {
    address admin;
    address creator;
    address vault;
    address factory;
    address backstopRouter;
    address shareToken;
    address protocolAddress;
    bytes32 conditionId;
    uint256 yesTokenId;
    uint256 noTokenId;
    uint16 totalFeeBps;
    uint16 creatorFeeBps;
    uint16 protocolFeeBps;
    uint64 deadline;
    string question;
    string description;
    string category;
    string resolutionRules;
    string resolutionSource;
    string imageUrl;
}
