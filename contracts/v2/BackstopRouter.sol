// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Side, TradeIntent} from "./interfaces/Types.sol";
import {ShareToken} from "./ShareToken.sol";
import {VaultV2} from "./VaultV2.sol";
import {DelegationRegistry} from "./DelegationRegistry.sol";
import {MarketLMSR} from "./MarketLMSR.sol";

/**
 * @title BackstopRouter
 * @notice Entry point for all LMSR backstop trades (gasless + direct)
 * @dev Implements TradeIntent EIP-712 for gasless trades where operator is pure relayer.
 *
 * Two entry points:
 *   - executeTradeIntent(): Operator relays signed TradeIntent (gasless)
 *   - executeTrade(): User calls directly (pays gas)
 *
 * CEI-compliant: nonce/hash committed BEFORE external calls.
 * nonReentrant: defense-in-depth against safeTransferFrom reentrancy.
 *
 * BackstopTrade event fields are NORMALIZED:
 *   amountUsdc is ALWAYS USDC, shares is ALWAYS shares — regardless of isBuy.
 *
 * See HYBRID_SPEC_v5.2 §7 for full specification.
 */
contract BackstopRouter is EIP712, ReentrancyGuard {
    using ECDSA for bytes32;

    // ============================================================
    // Constants
    // ============================================================

    bytes32 public constant TRADE_INTENT_TYPEHASH = keccak256(
        "TradeIntent(address trader,address signer,bytes32 conditionId,"
        "uint8 side,bool isBuy,uint256 amount,uint256 minOut,"
        "uint256 deadline,uint256 nonce,uint256 maxFeeBps)"
    );

    // ============================================================
    // State
    // ============================================================

    VaultV2 public vault;
    ShareToken public shareToken;
    DelegationRegistry public delegationRegistry;
    address public factory;
    address public admin;

    /// @notice conditionId → MarketLMSR clone address
    mapping(bytes32 => address) public backstops;

    /// @notice Signer → next expected nonce (STRICT sequential)
    mapping(address => uint256) public nonces;

    /// @notice Intent hash → used flag (replay protection + cancel support)
    mapping(bytes32 => bool) public usedIntentHashes;

    // ============================================================
    // Events
    // ============================================================

    event BackstopRegistered(bytes32 indexed conditionId, address indexed backstop);

    event BackstopTrade(
        bytes32 indexed conditionId,
        address indexed trader,
        Side side,
        bool isBuy,
        uint256 amountUsdc,  // ALWAYS USDC (normalized)
        uint256 shares,      // ALWAYS shares (normalized)
        bytes32 intentHash
    );

    event IntentCancelled(bytes32 indexed intentHash, address indexed trader);
    event NonceBumped(address indexed signer, uint256 oldNonce, uint256 newNonce);

    // ============================================================
    // Errors
    // ============================================================

    error IntentExpired();
    error BadNonce();
    error IntentAlreadyUsed();
    error BadSignature();
    error NotDelegated();
    error FeeExceedsMax();
    error NoBackstop();
    error NotTraderOrSigner();
    error NotFactory();
    error NotAdmin();

    // ============================================================
    // Constructor
    // ============================================================

    constructor(
        address _vault,
        address _shareToken,
        address _delegationRegistry,
        address _admin
    ) EIP712("FlipCoinBackstopRouter", "1") {
        require(
            _vault != address(0) && _shareToken != address(0) &&
            _delegationRegistry != address(0) && _admin != address(0),
            "zero addr"
        );
        vault = VaultV2(_vault);
        shareToken = ShareToken(_shareToken);
        delegationRegistry = DelegationRegistry(_delegationRegistry);
        admin = _admin;
    }

    // ============================================================
    // Gasless: Execute Signed TradeIntent (CEI-compliant)
    // ============================================================

    /**
     * @notice Execute a signed TradeIntent (operator is relayer, not counterparty)
     * @param intent The signed trade intent
     * @param sig EIP-712 signature from intent.signer
     * @return result Shares received (if buy) or USDC received (if sell)
     */
    function executeTradeIntent(TradeIntent calldata intent, bytes calldata sig)
        external
        nonReentrant
        returns (uint256 result)
    {
        // ── CHECKS ──

        // 1. Deadline
        if (block.timestamp > intent.deadline) revert IntentExpired();

        // 2. Nonce (STRICT sequential)
        if (intent.nonce != nonces[intent.signer]) revert BadNonce();

        // 3. Replay (secondary check + cancel support)
        bytes32 intentHash = _hashIntent(intent);
        if (usedIntentHashes[intentHash]) revert IntentAlreadyUsed();

        // 4. Signature (OZ ECDSA.recover)
        bytes32 digest = _hashTypedDataV4(intentHash);
        address recovered = ECDSA.recover(digest, sig);

        if (intent.signer == intent.trader) {
            if (recovered != intent.trader) revert BadSignature();
        } else {
            if (recovered != intent.signer) revert BadSignature();
            if (!delegationRegistry.isAuthorized(
                intent.trader, intent.signer, address(this), intent.conditionId
            )) revert NotDelegated();
        }

        // 5. Fee check
        address lmsrAddr = backstops[intent.conditionId];
        if (lmsrAddr == address(0)) revert NoBackstop();
        uint256 lmsrTotalFee = MarketLMSR(lmsrAddr).totalFeeBpsView();
        if (lmsrTotalFee > intent.maxFeeBps) revert FeeExceedsMax();

        // ── EFFECTS (before external calls — CEI pattern) ──

        // 6. Commit nonce + replay hash
        nonces[intent.signer]++;
        usedIntentHashes[intentHash] = true;

        // ── INTERACTIONS ──

        // 7. Execute via MarketLMSR
        if (intent.isBuy) {
            result = _executeBuy(intent);
        } else {
            result = _executeSell(intent);
        }

        // 8. Record delegation spend (USDC notional)
        if (intent.signer != intent.trader) {
            uint256 usdcNotional = intent.isBuy ? intent.amount : result;
            delegationRegistry.recordSpend(intent.trader, intent.signer, usdcNotional);
        }

        // 9. Emit event (normalized: amountUsdc=USDC, shares=shares)
        uint256 amountUsdc = intent.isBuy ? intent.amount : result;
        uint256 shares = intent.isBuy ? result : intent.amount;
        emit BackstopTrade(
            intent.conditionId, intent.trader, intent.side,
            intent.isBuy, amountUsdc, shares, intentHash
        );
    }

    // ============================================================
    // Direct: User Pays Gas (no signature needed)
    // ============================================================

    /**
     * @notice Direct LMSR trade (msg.sender = trader)
     */
    function executeTrade(
        bytes32 conditionId,
        Side side,
        bool isBuy,
        uint256 amount,
        uint256 minOut
    ) external nonReentrant returns (uint256 result) {
        address lmsrAddr = backstops[conditionId];
        if (lmsrAddr == address(0)) revert NoBackstop();

        TradeIntent memory intent = TradeIntent({
            trader: msg.sender,
            signer: msg.sender,
            conditionId: conditionId,
            side: side,
            isBuy: isBuy,
            amount: amount,
            minOut: minOut,
            deadline: block.timestamp,
            nonce: 0, // not used for direct trades
            maxFeeBps: 10000 // no fee ceiling for direct trades
        });

        if (isBuy) {
            result = _executeBuy(intent);
        } else {
            result = _executeSell(intent);
        }

        uint256 amountUsdc = isBuy ? amount : result;
        uint256 shares = isBuy ? result : amount;
        emit BackstopTrade(conditionId, msg.sender, side, isBuy, amountUsdc, shares, bytes32(0));
    }

    // ============================================================
    // User Self-Service: Cancel + Nonce Management
    // ============================================================

    /**
     * @notice Cancel a specific intent (per-intent, NOT per-nonce-slot)
     */
    function cancelIntent(TradeIntent calldata intent) external {
        if (msg.sender != intent.trader && msg.sender != intent.signer) revert NotTraderOrSigner();
        bytes32 intentHash = _hashIntent(intent);
        require(!usedIntentHashes[intentHash], "already used/cancelled");
        usedIntentHashes[intentHash] = true;
        emit IntentCancelled(intentHash, intent.trader);
    }

    /**
     * @notice Bump nonce for bulk cancellation (invalidates all intents with nonce < newNonce)
     */
    function bumpNonce(uint256 newNonce) external {
        require(newNonce > nonces[msg.sender], "nonce not increased");
        uint256 oldNonce = nonces[msg.sender];
        nonces[msg.sender] = newNonce;
        emit NonceBumped(msg.sender, oldNonce, newNonce);
    }

    // ============================================================
    // Factory Functions
    // ============================================================

    /**
     * @notice Register a MarketLMSR backstop for a condition
     */
    function registerBackstop(bytes32 conditionId, address backstop) external {
        require(msg.sender == factory, "not factory");
        backstops[conditionId] = backstop;
        emit BackstopRegistered(conditionId, backstop);
    }

    // ============================================================
    // Admin
    // ============================================================

    function setFactory(address _factory) external {
        if (msg.sender != admin) revert NotAdmin();
        factory = _factory;
    }

    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin) revert NotAdmin();
        admin = newAdmin;
    }

    // ============================================================
    // Views — Quote Functions
    // ============================================================

    function quoteBuy(bytes32 conditionId, Side side, uint256 amountUsdc)
        external view returns (uint256 sharesOut, uint256 fee)
    {
        address lmsr = backstops[conditionId];
        require(lmsr != address(0), "no backstop");
        return MarketLMSR(lmsr).quoteBuy(side, amountUsdc);
    }

    function quoteSell(bytes32 conditionId, Side side, uint256 shares)
        external view returns (uint256 amountOut, uint256 fee)
    {
        address lmsr = backstops[conditionId];
        require(lmsr != address(0), "no backstop");
        return MarketLMSR(lmsr).quoteSell(side, shares);
    }

    // ============================================================
    // Internal — Trade Execution
    // ============================================================

    function _executeBuy(TradeIntent memory intent) internal returns (uint256 sharesOut) {
        address lmsr = backstops[intent.conditionId];
        if (intent.side == Side.Yes) {
            sharesOut = MarketLMSR(lmsr).buyYes(intent.trader, intent.amount, intent.minOut);
        } else {
            sharesOut = MarketLMSR(lmsr).buyNo(intent.trader, intent.amount, intent.minOut);
        }
    }

    function _executeSell(TradeIntent memory intent) internal returns (uint256 amountOut) {
        address lmsr = backstops[intent.conditionId];

        // Determine token ID for the side being sold
        uint256 tokenId;
        if (intent.side == Side.Yes) {
            tokenId = MarketLMSR(lmsr).yesTokenId();
        } else {
            tokenId = MarketLMSR(lmsr).noTokenId();
        }

        // Transfer shares from trader to MarketLMSR
        // BackstopRouter is approved by user (one-time setApprovalForAll)
        shareToken.safeTransferFrom(intent.trader, lmsr, tokenId, intent.amount, "");

        // Execute sell on LMSR
        if (intent.side == Side.Yes) {
            amountOut = MarketLMSR(lmsr).sellYes(intent.trader, intent.amount, intent.minOut);
        } else {
            amountOut = MarketLMSR(lmsr).sellNo(intent.trader, intent.amount, intent.minOut);
        }
    }

    // ============================================================
    // Internal — Hashing
    // ============================================================

    function _hashIntent(TradeIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            TRADE_INTENT_TYPEHASH,
            intent.trader,
            intent.signer,
            intent.conditionId,
            uint8(intent.side),
            intent.isBuy,
            intent.amount,
            intent.minOut,
            intent.deadline,
            intent.nonce,
            intent.maxFeeBps
        ));
    }

    function _hashIntentMemory(TradeIntent memory intent) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            TRADE_INTENT_TYPEHASH,
            intent.trader,
            intent.signer,
            intent.conditionId,
            uint8(intent.side),
            intent.isBuy,
            intent.amount,
            intent.minOut,
            intent.deadline,
            intent.nonce,
            intent.maxFeeBps
        ));
    }
}
