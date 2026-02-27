// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Delegation} from "./interfaces/Types.sol";

/**
 * @title DelegationRegistry
 * @notice Universal signer delegation with scope-based access and daily USDC limits
 * @dev Supports 3 scope modes:
 *   - Specific contract (scope = Exchange or BackstopRouter address)
 *   - Wildcard (scope = address(0)) — covers all authorized contracts
 *
 * Used by Exchange, BackstopRouter, and Factory to verify delegated signers
 * and enforce spending limits for agent session keys.
 *
 * See HYBRID_SPEC_v5.2 §5 for full specification.
 */
contract DelegationRegistry {
    // ============================================================
    // State
    // ============================================================

    /// @notice Owner → Signer → Delegation configuration
    mapping(address => mapping(address => Delegation)) public delegations;

    /// @notice Contracts authorized to call recordSpend (Exchange, BackstopRouter, Factory)
    mapping(address => bool) public authorizedContracts;

    /// @notice Admin address (can manage authorizedContracts)
    address public admin;

    // ============================================================
    // Events
    // ============================================================

    event DelegationSet(
        address indexed owner,
        address indexed signer,
        address scope,
        uint256 maxNotionalPerDay,
        uint64 expiresAt
    );

    event DelegationRevoked(address indexed owner, address indexed signer);

    event SpendRecorded(
        address indexed owner,
        address indexed signer,
        address indexed caller,
        uint256 usdcAmount
    );

    event AuthorizedContractAdded(address indexed contractAddr);
    event AuthorizedContractRemoved(address indexed contractAddr);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ============================================================
    // Errors
    // ============================================================

    error NotAdmin();
    error NotAuthorizedContract();
    error DelegationNotActive();
    error ScopeMismatch();
    error DailyLimitExceeded();
    error DelegationExpired();
    error InvalidSigner();

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyAuthorizedContract() {
        if (!authorizedContracts[msg.sender]) revert NotAuthorizedContract();
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================

    constructor(address _admin) {
        require(_admin != address(0), "zero admin");
        admin = _admin;
    }

    // ============================================================
    // Owner Functions (msg.sender = owner)
    // ============================================================

    /**
     * @notice Set or update delegation for a signer
     * @param signer Address authorized to sign on behalf of owner
     * @param scope Contract scope (address(0) = wildcard, covers all)
     * @param maxNotionalPerDay Daily USDC spending limit (6 decimals, 0 = unlimited)
     * @param expiresAt Delegation expiry timestamp (0 = no expiry)
     */
    function setDelegation(
        address signer,
        address scope,
        uint256 maxNotionalPerDay,
        uint64 expiresAt
    ) external {
        if (signer == address(0)) revert InvalidSigner();
        require(signer != msg.sender, "cannot delegate to self");

        delegations[msg.sender][signer] = Delegation({
            active: true,
            scope: scope,
            maxNotionalPerDay: maxNotionalPerDay,
            spentToday: 0,
            dayStart: uint64(block.timestamp),
            expiresAt: expiresAt
        });

        emit DelegationSet(msg.sender, signer, scope, maxNotionalPerDay, expiresAt);
    }

    /**
     * @notice Revoke delegation for a signer
     * @param signer Address to revoke
     */
    function revokeDelegation(address signer) external {
        Delegation storage d = delegations[msg.sender][signer];
        require(d.active, "not active");
        d.active = false;
        emit DelegationRevoked(msg.sender, signer);
    }

    // ============================================================
    // View Functions
    // ============================================================

    /**
     * @notice Check if a signer is authorized to act on behalf of owner
     * @param owner The delegating address
     * @param signer The delegated signer
     * @param caller The contract calling (for scope check)
     * @param conditionId The market condition (unused in v2 scope model, reserved)
     * @return authorized Whether the signer is authorized
     */
    function isAuthorized(
        address owner,
        address signer,
        address caller,
        bytes32 conditionId
    ) external view returns (bool authorized) {
        // Suppress unused parameter warning
        conditionId;

        Delegation storage d = delegations[owner][signer];

        if (!d.active) return false;

        // Check expiry
        if (d.expiresAt > 0 && block.timestamp > d.expiresAt) return false;

        // Check scope: address(0) = wildcard (any contract), otherwise must match caller
        if (d.scope != address(0) && d.scope != caller) return false;

        return true;
    }

    /**
     * @notice Get full delegation struct
     */
    function getDelegation(address owner, address signer) external view returns (Delegation memory) {
        return delegations[owner][signer];
    }

    // ============================================================
    // Authorized Contract Functions
    // ============================================================

    /**
     * @notice Record USDC spend for a delegated signer (daily limit enforcement)
     * @param owner The delegating address
     * @param signer The delegated signer
     * @param usdcAmount Amount of USDC spent (6 decimals)
     * @dev Only callable by authorized contracts (Exchange, BackstopRouter, Factory).
     *
     * DAILY LIMIT WINDOW: Uses a rolling 24-hour window anchored to `dayStart`.
     * When the first spend occurs after `dayStart + 24h`, the window resets:
     * `dayStart = block.timestamp` and `spentToday = 0`. This means the window
     * is NOT a strict calendar day — it slides forward from the last reset.
     * Example: if dayStart=Mon 10:00 and next spend is Wed 15:00, the window
     * resets to Wed 15:00, allowing full daily limit from that point.
     * This is simpler than a true sliding window but provides adequate protection
     * for session key spending limits.
     */
    function recordSpend(
        address owner,
        address signer,
        uint256 usdcAmount
    ) external onlyAuthorizedContract {
        Delegation storage d = delegations[owner][signer];
        if (!d.active) revert DelegationNotActive();

        // Check expiry
        if (d.expiresAt > 0 && block.timestamp > d.expiresAt) revert DelegationExpired();

        // Check scope
        if (d.scope != address(0) && d.scope != msg.sender) revert ScopeMismatch();

        // Rolling 24h window: reset if new day
        if (block.timestamp >= d.dayStart + 24 hours) {
            d.dayStart = uint64(block.timestamp);
            d.spentToday = 0;
        }

        // Enforce daily limit (0 = unlimited)
        if (d.maxNotionalPerDay > 0) {
            if (d.spentToday + usdcAmount > d.maxNotionalPerDay) revert DailyLimitExceeded();
        }

        d.spentToday += usdcAmount;

        emit SpendRecorded(owner, signer, msg.sender, usdcAmount);
    }

    // ============================================================
    // Admin Functions
    // ============================================================

    /**
     * @notice Add a contract to the authorized list
     * @param contractAddr Contract to authorize (Exchange, BackstopRouter, Factory)
     */
    function addAuthorizedContract(address contractAddr) external onlyAdmin {
        require(contractAddr != address(0), "zero address");
        authorizedContracts[contractAddr] = true;
        emit AuthorizedContractAdded(contractAddr);
    }

    /**
     * @notice Remove a contract from the authorized list
     */
    function removeAuthorizedContract(address contractAddr) external onlyAdmin {
        authorizedContracts[contractAddr] = false;
        emit AuthorizedContractRemoved(contractAddr);
    }

    /**
     * @notice Transfer admin role
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        address old = admin;
        admin = newAdmin;
        emit AdminTransferred(old, newAdmin);
    }
}
