// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Side, Outcome, ResolutionStatus, Condition, Resolution} from "./interfaces/Types.sol";

/**
 * @title ShareToken
 * @notice ERC-1155 conditional tokens with supply tracking, resolution, and split/merge
 * @dev Central token contract for FlipCoin v2.
 *
 * Token IDs: deterministic from conditionId + collateral
 *   base = uint256(keccak256(conditionId, collateral))
 *   YES tokenId = (base << 1)      — even number
 *   NO  tokenId = (base << 1) | 1  — odd number
 *
 * Authorized callers (Exchange, MarketLMSR clones) can split/merge positions.
 * Resolution is two-phase: propose → 24h dispute → finalize.
 *
 * See HYBRID_SPEC_v5.2 §3 for full specification.
 */
contract ShareToken is ERC1155Supply, ReentrancyGuard {
    // ============================================================
    // Constants
    // ============================================================

    uint64 public constant DISPUTE_PERIOD = 24 hours;
    uint64 public constant ADMIN_RESOLVE_WINDOW = 6 hours;
    uint256 public constant PAYOUT_PER_SHARE_WINNER = 1_000_000; // $1 per winning share
    uint256 public constant PAYOUT_PER_SHARE_INVALID = 500_000;  // $0.50 per share (both sides)
    uint256 public constant BPS = 10_000;

    // ============================================================
    // State
    // ============================================================

    address public admin;
    address public factory;
    address public vault;       // VaultV2 address for releaseForRedeem
    address public exchange;    // Exchange address for pauseCondition callback

    /// @notice Addresses authorized to call splitPosition/mergePositions
    /// (Exchange + MarketLMSR clones registered by Factory)
    mapping(address => bool) public authorizedCallers;

    /// @notice Condition metadata (set by Factory via prepareCondition)
    mapping(bytes32 => Condition) public conditions;

    /// @notice Resolution state per condition
    mapping(bytes32 => Resolution) public resolutions;

    /// @notice Lookup: tokenId → conditionId
    mapping(uint256 => bytes32) public tokenCondition;

    // ============================================================
    // Events
    // ============================================================

    event ConditionPrepared(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 questionId,
        uint256 yesTokenId,
        uint256 noTokenId
    );

    event PositionSplit(
        bytes32 indexed conditionId,
        address indexed to,
        uint256 amount
    );

    event PositionsMerged(
        bytes32 indexed conditionId,
        address indexed from,
        uint256 amount
    );

    event ResolutionProposed(
        bytes32 indexed conditionId,
        Outcome proposedOutcome,
        uint64 proposedAt,
        uint64 finalizeAfter
    );

    event ResolutionDisputed(
        bytes32 indexed conditionId,
        address indexed challenger,
        Outcome proposedOutcome
    );

    event ResolutionFinalized(
        bytes32 indexed conditionId,
        Outcome outcome,
        uint256 payoutPerShare
    );

    event MarkedAsInvalid(
        bytes32 indexed conditionId,
        address indexed caller,
        uint64 markedAt
    );

    event PositionRedeemed(
        bytes32 indexed conditionId,
        address indexed holder,
        uint256 sharesBurned,
        uint256 usdcPayout
    );

    event AuthorizedCallerAdded(address indexed caller);
    event AuthorizedCallerRemoved(address indexed caller);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ============================================================
    // Errors
    // ============================================================

    error NotAdmin();
    error NotFactory();
    error NotOracle();
    error NotAuthorizedCaller();
    error ConditionNotPrepared();
    error ConditionAlreadyPrepared();
    error ResolutionNotOpen();
    error ResolutionNotPending();
    error ResolutionNotResolved();
    error NotTokenHolder();
    error DeadlineNotReached();
    error DisputePeriodNotOver();
    error InvalidWindowNotReached();
    error InvalidOutcome();
    error AlreadyResolved();
    error NothingToRedeem();

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyAuthorizedCaller() {
        if (!authorizedCallers[msg.sender]) revert NotAuthorizedCaller();
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================

    constructor(string memory uri_, address _admin) ERC1155(uri_) {
        require(_admin != address(0), "zero admin");
        admin = _admin;
    }

    // ============================================================
    // Admin Setup (called after deployment)
    // ============================================================

    function setFactory(address _factory) external onlyAdmin {
        require(_factory != address(0), "zero factory");
        factory = _factory;
    }

    function setVault(address _vault) external onlyAdmin {
        require(_vault != address(0), "zero vault");
        vault = _vault;
    }

    function setExchange(address _exchange) external onlyAdmin {
        require(_exchange != address(0), "zero exchange");
        exchange = _exchange;
    }

    function addAuthorizedCaller(address caller) external {
        require(msg.sender == admin || msg.sender == factory, "not admin or factory");
        require(caller != address(0), "zero address");
        authorizedCallers[caller] = true;
        emit AuthorizedCallerAdded(caller);
    }

    function removeAuthorizedCaller(address caller) external onlyAdmin {
        authorizedCallers[caller] = false;
        emit AuthorizedCallerRemoved(caller);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        address old = admin;
        admin = newAdmin;
        emit AdminTransferred(old, newAdmin);
    }

    // ============================================================
    // Token ID Derivation (pure functions)
    // ============================================================

    /**
     * @notice Compute conditionId from oracle and questionId
     */
    function getConditionId(address oracle, bytes32 questionId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, questionId));
    }

    /**
     * @notice Compute YES/NO token IDs from conditionId and collateral
     * @dev YES = even, NO = odd
     */
    function getTokenIds(bytes32 conditionId, address collateral)
        public pure returns (uint256 yesTokenId, uint256 noTokenId)
    {
        uint256 base = uint256(keccak256(abi.encodePacked(conditionId, collateral)));
        yesTokenId = (base << 1);
        noTokenId = (base << 1) | 1;
    }

    // ============================================================
    // Factory Functions
    // ============================================================

    /**
     * @notice Prepare a new condition (market). Called by Factory during market creation.
     * @param oracle Address authorized to propose resolution (typically admin)
     * @param questionId Unique identifier for the market question
     * @param collateral USDC token address
     * @param deadline Resolution eligibility timestamp
     * @return conditionId The computed condition ID
     */
    function prepareCondition(
        address oracle,
        bytes32 questionId,
        address collateral,
        uint64 deadline
    ) external onlyFactory returns (bytes32 conditionId) {
        conditionId = getConditionId(oracle, questionId);
        if (conditions[conditionId].prepared) revert ConditionAlreadyPrepared();

        (uint256 yesId, uint256 noId) = getTokenIds(conditionId, collateral);

        conditions[conditionId] = Condition({
            conditionId: conditionId,
            oracle: oracle,
            questionId: questionId,
            collateral: collateral,
            yesTokenId: yesId,
            noTokenId: noId,
            deadline: deadline,
            prepared: true
        });

        // Initialize resolution as Open
        resolutions[conditionId].status = ResolutionStatus.Open;

        // Store reverse lookup
        tokenCondition[yesId] = conditionId;
        tokenCondition[noId] = conditionId;

        emit ConditionPrepared(conditionId, oracle, questionId, yesId, noId);
    }

    // ============================================================
    // Split / Merge (called by Exchange and MarketLMSR clones)
    // ============================================================

    /**
     * @notice Mint equal YES+NO shares to recipient (split position)
     * @dev Caller must have ensured USDC is locked in Vault.splitReserve
     * @param conditionId The market condition
     * @param to Recipient of the minted tokens
     * @param amount Number of shares to mint (both YES and NO)
     */
    function splitPosition(bytes32 conditionId, address to, uint256 amount)
        external
        onlyAuthorizedCaller
        nonReentrant
    {
        Condition storage c = conditions[conditionId];
        if (!c.prepared) revert ConditionNotPrepared();
        require(resolutions[conditionId].status == ResolutionStatus.Open, "not open");
        require(amount > 0, "zero amount");

        // Mint equal YES + NO tokens
        _mint(to, c.yesTokenId, amount, "");
        _mint(to, c.noTokenId, amount, "");

        emit PositionSplit(conditionId, to, amount);
    }

    /**
     * @notice Burn equal YES+NO shares from sender (merge positions)
     * @dev After merge, caller should release USDC from Vault.splitReserve
     * @param conditionId The market condition
     * @param from Address whose tokens are burned
     * @param amount Number of share pairs to burn
     */
    function mergePositions(bytes32 conditionId, address from, uint256 amount)
        external
        onlyAuthorizedCaller
        nonReentrant
    {
        Condition storage c = conditions[conditionId];
        if (!c.prepared) revert ConditionNotPrepared();
        require(resolutions[conditionId].status == ResolutionStatus.Open, "not open");
        require(amount > 0, "zero amount");

        // Burn equal YES + NO tokens
        _burn(from, c.yesTokenId, amount);
        _burn(from, c.noTokenId, amount);

        emit PositionsMerged(conditionId, from, amount);
    }

    // ============================================================
    // Resolution — Two-Phase with Dispute Period
    // ============================================================

    /**
     * @notice Propose a resolution outcome (starts 24h dispute period)
     * @param conditionId The market condition
     * @param outcome Proposed outcome (Yes, No, or Invalid)
     */
    function proposeResolution(bytes32 conditionId, Outcome outcome) external {
        Condition storage c = conditions[conditionId];
        if (!c.prepared) revert ConditionNotPrepared();
        require(msg.sender == c.oracle, "not oracle");
        require(block.timestamp >= c.deadline, "deadline not reached");
        if (outcome == Outcome.None) revert InvalidOutcome();

        Resolution storage r = resolutions[conditionId];
        if (r.status != ResolutionStatus.Open) revert ResolutionNotOpen();

        r.status = ResolutionStatus.Pending;
        r.proposedOutcome = outcome;
        r.proposedAt = uint64(block.timestamp);
        r.finalizeAfter = uint64(block.timestamp) + DISPUTE_PERIOD;
        r.disputed = false;

        emit ResolutionProposed(conditionId, outcome, r.proposedAt, r.finalizeAfter);
    }

    /**
     * @notice Dispute a proposed resolution (only token holders)
     * @dev Resets status to Open for oracle to re-investigate
     */
    function disputeResolution(bytes32 conditionId) external {
        Resolution storage r = resolutions[conditionId];
        if (r.status != ResolutionStatus.Pending) revert ResolutionNotPending();

        Condition storage c = conditions[conditionId];

        // Only shareholders can dispute
        uint256 yesBal = balanceOf(msg.sender, c.yesTokenId);
        uint256 noBal = balanceOf(msg.sender, c.noTokenId);
        if (yesBal == 0 && noBal == 0) revert NotTokenHolder();

        // Reset to Open
        r.status = ResolutionStatus.Open;
        r.disputed = true;
        Outcome previousProposal = r.proposedOutcome;
        r.proposedOutcome = Outcome.None;
        r.proposedAt = 0;
        r.finalizeAfter = 0;

        emit ResolutionDisputed(conditionId, msg.sender, previousProposal);
    }

    /**
     * @notice Finalize resolution after dispute period (anyone can call)
     * @dev Pauses condition in Exchange to prevent further trading
     */
    function finalizeResolution(bytes32 conditionId) external nonReentrant {
        Resolution storage r = resolutions[conditionId];
        if (r.status != ResolutionStatus.Pending) revert ResolutionNotPending();
        require(block.timestamp >= r.finalizeAfter, "dispute period active");

        Outcome outcome = r.proposedOutcome;
        r.status = ResolutionStatus.Resolved;
        r.finalOutcome = outcome;
        r.resolvedAt = uint64(block.timestamp);

        // Set payout
        if (outcome == Outcome.Invalid) {
            r.payoutPerShare = PAYOUT_PER_SHARE_INVALID;
        } else {
            r.payoutPerShare = PAYOUT_PER_SHARE_WINNER;
        }

        // Pause condition in Exchange (no more CLOB trading)
        if (exchange != address(0)) {
            _tryPauseCondition(conditionId);
        }

        emit ResolutionFinalized(conditionId, outcome, r.payoutPerShare);
    }

    /**
     * @notice Mark market as Invalid if oracle didn't resolve within window
     * @dev Anyone can call after deadline + ADMIN_RESOLVE_WINDOW
     *      Hardcoded $0.50 payout, irreversible
     */
    function markAsInvalid(bytes32 conditionId) external nonReentrant {
        Condition storage c = conditions[conditionId];
        if (!c.prepared) revert ConditionNotPrepared();

        Resolution storage r = resolutions[conditionId];
        if (r.status == ResolutionStatus.Resolved) revert AlreadyResolved();
        if (r.status == ResolutionStatus.Pending) revert ResolutionNotOpen();

        // Must be past deadline + admin window
        require(
            block.timestamp >= c.deadline + ADMIN_RESOLVE_WINDOW,
            "invalid window not reached"
        );

        r.status = ResolutionStatus.Resolved;
        r.finalOutcome = Outcome.Invalid;
        r.resolvedAt = uint64(block.timestamp);
        r.payoutPerShare = PAYOUT_PER_SHARE_INVALID;

        // Pause condition in Exchange
        if (exchange != address(0)) {
            _tryPauseCondition(conditionId);
        }

        emit MarkedAsInvalid(conditionId, msg.sender, uint64(block.timestamp));
        emit ResolutionFinalized(conditionId, Outcome.Invalid, PAYOUT_PER_SHARE_INVALID);
    }

    // ============================================================
    // Redemption
    // ============================================================

    /**
     * @notice Redeem positions after resolution for USDC payout
     * @param conditionId The resolved market condition
     * @dev Burns winning tokens (or both for Invalid) and releases USDC from Vault
     */
    function redeemPositions(bytes32 conditionId) external nonReentrant {
        Resolution storage r = resolutions[conditionId];
        if (r.status != ResolutionStatus.Resolved) revert ResolutionNotResolved();

        Condition storage c = conditions[conditionId];
        uint256 payout;
        uint256 sharesBurned;

        if (r.finalOutcome == Outcome.Yes) {
            uint256 yesBal = balanceOf(msg.sender, c.yesTokenId);
            if (yesBal == 0) revert NothingToRedeem();
            _burn(msg.sender, c.yesTokenId, yesBal);
            sharesBurned = yesBal;
            payout = yesBal; // 1:1 redemption for winner
        } else if (r.finalOutcome == Outcome.No) {
            uint256 noBal = balanceOf(msg.sender, c.noTokenId);
            if (noBal == 0) revert NothingToRedeem();
            _burn(msg.sender, c.noTokenId, noBal);
            sharesBurned = noBal;
            payout = noBal; // 1:1 redemption for winner
        } else if (r.finalOutcome == Outcome.Invalid) {
            uint256 yesBal = balanceOf(msg.sender, c.yesTokenId);
            uint256 noBal = balanceOf(msg.sender, c.noTokenId);
            if (yesBal == 0 && noBal == 0) revert NothingToRedeem();
            if (yesBal > 0) _burn(msg.sender, c.yesTokenId, yesBal);
            if (noBal > 0) _burn(msg.sender, c.noTokenId, noBal);
            sharesBurned = yesBal + noBal;
            // Invalid: each share gets $0.50 (500_000 per 1_000_000)
            payout = (yesBal + noBal) * PAYOUT_PER_SHARE_INVALID / 1e6;
        } else {
            revert InvalidOutcome();
        }

        require(payout > 0, "zero payout");

        // Release USDC from Vault splitReserve to user
        IVaultV2Minimal(vault).releaseForRedeem(msg.sender, payout);

        emit PositionRedeemed(conditionId, msg.sender, sharesBurned, payout);
    }

    // ============================================================
    // View Functions
    // ============================================================

    /**
     * @notice Get resolution info for a condition
     */
    function getResolution(bytes32 conditionId) external view returns (Resolution memory) {
        return resolutions[conditionId];
    }

    /**
     * @notice Get condition info
     */
    function getCondition(bytes32 conditionId) external view returns (Condition memory) {
        return conditions[conditionId];
    }

    /**
     * @notice Check if a condition is resolved
     */
    function isResolved(bytes32 conditionId) external view returns (bool) {
        return resolutions[conditionId].status == ResolutionStatus.Resolved;
    }

    // ============================================================
    // Internal
    // ============================================================

    /**
     * @dev Try to pause condition in Exchange. Non-reverting to avoid bricking resolution.
     */
    function _tryPauseCondition(bytes32 conditionId) internal {
        // Low-level call to avoid revert if Exchange has issues
        (bool success,) = exchange.call(
            abi.encodeWithSignature("pauseCondition(bytes32)", conditionId)
        );
        // We don't revert if this fails — resolution should still complete
        success; // suppress unused warning
    }

    // Override required by Solidity for ERC1155Supply
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155Supply)
    {
        super._update(from, to, ids, values);
    }
}

// ============================================================
// Minimal interface for Vault (avoids circular import)
// ============================================================

interface IVaultV2Minimal {
    function releaseForRedeem(address to, uint256 amount) external;
}
