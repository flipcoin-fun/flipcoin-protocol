// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DepositIntent} from "./interfaces/Types.sol";
import {VaultV2} from "./VaultV2.sol";
import {DelegationRegistry} from "./DelegationRegistry.sol";

/**
 * @title DepositRouter
 * @notice Delegated USDC deposits into VaultV2 via signed EIP-712 intents
 * @dev Enables agents (session keys) to autonomously deposit USDC from
 *      the owner's wallet into VaultV2 without the owner being online.
 *
 * Prerequisites:
 *   1. Owner approves USDC spending to this contract (one-time)
 *   2. Owner delegates session key via DelegationRegistry (scope = this contract or wildcard)
 *   3. Admin whitelists this contract on VaultV2 (addWhitelistedMarket) for transferBetween
 *   4. Admin authorizes this contract on DelegationRegistry (addAuthorizedContract)
 *
 * Deposit flow (3-step, atomic):
 *   1. Pull USDC from owner: usdc.transferFrom(owner, this, amount)
 *   2. Deposit into VaultV2: vault.deposit(amount) → credits this contract's balance
 *   3. Transfer to owner: vault.transferBetween(this, owner, amount)
 *
 * Security:
 *   - CEI pattern (nonce committed before external calls)
 *   - nonReentrant guard
 *   - DelegationRegistry authorization (scope, expiry)
 *   - DelegationRegistry recordSpend (on-chain daily limit enforcement)
 *   - maxDepositPerTx cap (admin-configurable)
 *   - EIP-712 replay protection via sequential nonces
 *   - Deadline for intent expiry
 *   - Pause kill switch
 *
 * See HYBRID_SPEC_v5.2 for full protocol specification.
 */
contract DepositRouter is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ============================================================
    // Constants
    // ============================================================

    bytes32 public constant DEPOSIT_INTENT_TYPEHASH = keccak256(
        "DepositIntent(address owner,address signer,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    // ============================================================
    // State
    // ============================================================

    VaultV2 public immutable vault;
    DelegationRegistry public immutable delegationRegistry;
    IERC20 public immutable usdc;
    address public admin;
    bool public paused;

    /// @notice Per-transaction deposit cap (6 decimals), 0 = unlimited
    uint256 public maxDepositPerTx;

    /// @notice Signer → next expected nonce (STRICT sequential)
    mapping(address => uint256) public nonces;

    /// @notice Intent hash → used flag (replay protection + cancel support)
    mapping(bytes32 => bool) public usedIntentHashes;

    // ============================================================
    // Events
    // ============================================================

    event DelegatedDeposit(
        address indexed owner,
        address indexed signer,
        uint256 amount,
        bytes32 intentHash
    );

    event IntentCancelled(bytes32 indexed intentHash, address indexed signer);
    event NonceBumped(address indexed signer, uint256 oldNonce, uint256 newNonce);
    event MaxDepositPerTxUpdated(uint256 oldMax, uint256 newMax);
    event Paused(address indexed admin);
    event Unpaused(address indexed admin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ============================================================
    // Errors
    // ============================================================

    error DepositExpired();
    error BadNonce();
    error IntentAlreadyUsed();
    error BadSignature();
    error NotDelegated();
    error MaxDepositExceeded();
    error NotOwnerOrSigner();
    error NotAdmin();
    error RouterPaused();
    error ZeroAmount();

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert RouterPaused();
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================

    constructor(
        address _vault,
        address _delegationRegistry,
        address _usdc,
        address _admin,
        uint256 _maxDepositPerTx
    ) EIP712("FlipCoinDepositRouter", "1") {
        require(
            _vault != address(0) && _delegationRegistry != address(0) &&
            _usdc != address(0) && _admin != address(0),
            "zero addr"
        );
        vault = VaultV2(_vault);
        delegationRegistry = DelegationRegistry(_delegationRegistry);
        usdc = IERC20(_usdc);
        admin = _admin;
        maxDepositPerTx = _maxDepositPerTx;

        // Pre-approve VaultV2 for max USDC (so deposit() can transferFrom)
        IERC20(_usdc).approve(_vault, type(uint256).max);
    }

    // ============================================================
    // Core: Execute Signed DepositIntent (CEI-compliant)
    // ============================================================

    /**
     * @notice Execute a signed DepositIntent (operator is relayer)
     * @param intent The signed deposit intent
     * @param sig EIP-712 signature from intent.signer
     */
    function executeDepositIntent(DepositIntent calldata intent, bytes calldata sig)
        external
        nonReentrant
        whenNotPaused
    {
        // ── CHECKS ──

        // 1. Amount
        if (intent.amount == 0) revert ZeroAmount();

        // 2. Per-tx cap
        if (maxDepositPerTx > 0 && intent.amount > maxDepositPerTx) revert MaxDepositExceeded();

        // 3. Deadline
        if (block.timestamp > intent.deadline) revert DepositExpired();

        // 4. Nonce (STRICT sequential)
        if (intent.nonce != nonces[intent.signer]) revert BadNonce();

        // 5. Replay (secondary check + cancel support)
        bytes32 intentHash = _hashIntent(intent);
        if (usedIntentHashes[intentHash]) revert IntentAlreadyUsed();

        // 6. Signature (OZ ECDSA.recover)
        bytes32 digest = _hashTypedDataV4(intentHash);
        address recovered = ECDSA.recover(digest, sig);

        if (intent.signer == intent.owner) {
            // Owner signs directly
            if (recovered != intent.owner) revert BadSignature();
        } else {
            // Delegated signer (session key)
            if (recovered != intent.signer) revert BadSignature();
            if (!delegationRegistry.isAuthorized(
                intent.owner, intent.signer, address(this), bytes32(0)
            )) revert NotDelegated();
        }

        // ── EFFECTS (before external calls — CEI pattern) ──

        // 7. Commit nonce + replay hash
        nonces[intent.signer]++;
        usedIntentHashes[intentHash] = true;

        // ── INTERACTIONS ──

        // 8. Pull USDC from owner's wallet
        usdc.safeTransferFrom(intent.owner, address(this), intent.amount);

        // 9. Deposit into VaultV2 (credits this contract's ledger balance)
        vault.deposit(intent.amount);

        // 10. Transfer ledger balance from this contract to owner
        vault.transferBetween(address(this), intent.owner, intent.amount);

        // 11. Record delegation spend (daily limit enforcement)
        if (intent.signer != intent.owner) {
            delegationRegistry.recordSpend(intent.owner, intent.signer, intent.amount);
        }

        // 12. Emit event
        emit DelegatedDeposit(intent.owner, intent.signer, intent.amount, intentHash);
    }

    // ============================================================
    // Cancel & Nonce Management
    // ============================================================

    /**
     * @notice Cancel a pending intent (only owner or signer)
     * @param intent The intent to cancel (marks hash as used)
     */
    function cancelDepositIntent(DepositIntent calldata intent) external {
        if (msg.sender != intent.owner && msg.sender != intent.signer) {
            revert NotOwnerOrSigner();
        }

        bytes32 intentHash = _hashIntent(intent);
        usedIntentHashes[intentHash] = true;
        emit IntentCancelled(intentHash, msg.sender);
    }

    /**
     * @notice Bump nonce to invalidate all pending intents below newNonce
     * @param newNonce Must be > current nonce
     */
    function bumpNonce(uint256 newNonce) external {
        uint256 current = nonces[msg.sender];
        require(newNonce > current, "nonce must increase");
        nonces[msg.sender] = newNonce;
        emit NonceBumped(msg.sender, current, newNonce);
    }

    // ============================================================
    // Admin Functions
    // ============================================================

    function setMaxDepositPerTx(uint256 _maxDepositPerTx) external onlyAdmin {
        uint256 old = maxDepositPerTx;
        maxDepositPerTx = _maxDepositPerTx;
        emit MaxDepositPerTxUpdated(old, _maxDepositPerTx);
    }

    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        address old = admin;
        admin = newAdmin;
        emit AdminTransferred(old, newAdmin);
    }

    // ============================================================
    // Views
    // ============================================================

    function nonceOf(address signer) external view returns (uint256) {
        return nonces[signer];
    }

    // ============================================================
    // Internal
    // ============================================================

    function _hashIntent(DepositIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            DEPOSIT_INTENT_TYPEHASH,
            intent.owner,
            intent.signer,
            intent.amount,
            intent.nonce,
            intent.deadline
        ));
    }
}
