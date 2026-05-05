// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {LedgerReason} from "./interfaces/Types.sol";

/**
 * @title VaultV2
 * @notice Single custody point for USDC with Model A accounting (4 separate pools)
 * @dev
 *   State variables:
 *     balances[addr]   — User/contract ledger balances
 *     totalBalances    — Running sum of all balances (Σ balances[addr])
 *     splitReserve     — USDC backing outstanding split token pairs
 *     feePool          — Accumulated protocol + creator fees
 *
 *   GLOBAL INVARIANT (enforceable onchain):
 *     USDC.balanceOf(vault) >= totalBalances + splitReserve + feePool
 *
 *   NO overlap: splitReserve, feePool, and totalBalances are three separate buckets.
 *
 *   SECURITY MODEL: Settlement contracts (Exchange, BackstopRouter, MarketLMSR clones)
 *   are fully trusted by admin. They can operate on ANY user balance without per-user
 *   allowance approval. User protection relies on:
 *     1. Only admin can whitelist settlement contracts (onlySettlement modifier)
 *     2. Admin is expected to be a multisig/timelock (see TODO_MAINNET.md)
 *     3. Global pause() as emergency kill switch
 *   This is an intentional design choice for gas efficiency in v2. If granular per-user
 *   allowances are needed, use v1 Vault which requires approveMarket before spending.
 *
 * See HYBRID_SPEC_v5.2 §8 for full specification.
 */
contract VaultV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    // State
    // ============================================================

    IERC20 public immutable usdc;
    address public admin;
    bool public paused;

    /// @notice Platform treasury address — authorized to call depositFor()
    address public treasury;

    /// @notice Internal ledger balances
    mapping(address => uint256) public balances;

    /// @notice Running sum of all balances[addr] — updated on every change
    uint256 public totalBalances;

    /// @notice USDC backing outstanding split token pairs (locked during split, released on merge/redeem)
    uint256 public splitReserve;

    /// @notice Accumulated fees (protocol + creator)
    uint256 public feePool;

    // ── Permission roles ──

    mapping(address => bool) public whitelistedMarkets;
    mapping(address => bool) public trustedFactories;
    address public exchange;
    address public shareToken;
    address public backstopRouter;

    // ============================================================
    // Events
    // ============================================================

    event LedgerTransfer(
        address indexed from,
        address indexed to,
        uint256 amount,
        LedgerReason indexed reason
    );

    event WhitelistedMarketUpdated(address indexed market, bool whitelisted);
    event TrustedFactoryUpdated(address indexed factory, bool trusted);
    event Paused(address indexed admin);
    event Unpaused(address indexed admin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============================================================
    // Errors
    // ============================================================

    error NotAdmin();
    error NotTreasury();
    error VaultPaused();
    error InsufficientBalance();
    error InsufficientSplitReserve();
    error InsufficientFeePool();
    error NotAuthorized();
    error ZeroAmount();
    error ZeroAddress();

    // ============================================================
    // Modifiers
    // ============================================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    /// @dev Exchange, BackstopRouter, or whitelistedMarkets (MarketLMSR clones)
    modifier onlySettlement() {
        if (
            msg.sender != exchange &&
            msg.sender != backstopRouter &&
            !whitelistedMarkets[msg.sender]
        ) revert NotAuthorized();
        _;
    }

    modifier onlyShareToken() {
        require(msg.sender == shareToken, "not shareToken");
        _;
    }

    modifier onlyFactory() {
        require(trustedFactories[msg.sender], "not factory");
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    // ============================================================
    // Constructor
    // ============================================================

    constructor(address _usdc, address _admin) {
        require(_usdc != address(0), "zero usdc");
        require(_admin != address(0), "zero admin");
        usdc = IERC20(_usdc);
        admin = _admin;
    }

    // ============================================================
    // User Functions
    // ============================================================

    /**
     * @notice Deposit USDC into the vault
     * @param amount USDC amount (6 decimals)
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        totalBalances += amount;

        emit LedgerTransfer(address(0), msg.sender, amount, LedgerReason.UserDeposit);
    }

    /**
     * @notice Deposit USDC on behalf of a recipient (platform treasury only)
     * @param recipient Address whose vault balance is credited
     * @param amount USDC amount (6 decimals)
     * @dev Treasury tops up a creator's vault balance so the factory can pull the
     *      seed via pullForNewMarket(). Requires treasury to be configured via
     *      setTreasury() by admin.
     */
    function depositFor(address recipient, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyTreasury
    {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        balances[recipient] += amount;
        totalBalances += amount;

        emit LedgerTransfer(address(0), recipient, amount, LedgerReason.PlatformSeed);
    }

    /**
     * @notice Withdraw USDC from the vault
     * @param amount USDC amount to withdraw
     * @param to Recipient address
     */
    function withdraw(uint256 amount, address to) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (balances[msg.sender] < amount) revert InsufficientBalance();

        balances[msg.sender] -= amount;
        totalBalances -= amount;
        usdc.safeTransfer(to, amount);

        emit LedgerTransfer(msg.sender, to, amount, LedgerReason.UserWithdraw);
    }

    // ============================================================
    // Settlement Functions — lockForSplit / releaseFromMerge
    // ============================================================

    /**
     * @notice Lock USDC from a balance into splitReserve (for token minting)
     * @param from Address whose balance to debit
     * @param amount USDC to lock
     * @dev Called by Exchange (MINT match), MarketLMSR (backstop buy)
     */
    function lockForSplit(address from, uint256 amount) external onlySettlement whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (balances[from] < amount) revert InsufficientBalance();

        balances[from] -= amount;
        totalBalances -= amount;
        splitReserve += amount;

        emit LedgerTransfer(from, address(this), amount, LedgerReason.LockForSplit);
    }

    /**
     * @notice Release USDC from splitReserve back to a balance (after merge)
     * @param to Address to credit
     * @param amount USDC to release
     * @dev Called by Exchange (MERGE match), MarketLMSR (backstop sell)
     */
    function releaseFromMerge(address to, uint256 amount) external onlySettlement whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (splitReserve < amount) revert InsufficientSplitReserve();

        splitReserve -= amount;
        balances[to] += amount;
        totalBalances += amount;

        emit LedgerTransfer(address(this), to, amount, LedgerReason.ReleaseFromMerge);
    }

    /**
     * @notice Release USDC from splitReserve for token redemption
     * @param to Address to credit (token holder)
     * @param amount USDC payout
     * @dev Called ONLY by ShareToken during redeemPositions
     */
    function releaseForRedeem(address to, uint256 amount) external onlyShareToken whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (splitReserve < amount) revert InsufficientSplitReserve();

        splitReserve -= amount;
        balances[to] += amount;
        totalBalances += amount;

        emit LedgerTransfer(address(this), to, amount, LedgerReason.ReleaseForRedeem);
    }

    /**
     * @notice Release USDC from splitReserve with fee split to feePool
     * @param to Address to credit (token holder)
     * @param payout Gross USDC payout (before fee)
     * @param fee Fee amount to route to feePool
     * @dev Called ONLY by ShareToken during redeemPositions when resolutionFeeBps > 0
     */
    function releaseForRedeemWithFee(address to, uint256 payout, uint256 fee)
        external onlyShareToken whenNotPaused
    {
        require(payout > fee, "fee >= payout");
        if (payout == 0) revert ZeroAmount();
        if (splitReserve < payout) revert InsufficientSplitReserve();

        splitReserve -= payout;
        uint256 netPayout = payout - fee;
        balances[to] += netPayout;
        totalBalances += netPayout;
        feePool += fee;

        emit LedgerTransfer(address(this), to, netPayout, LedgerReason.ReleaseForRedeem);
        if (fee > 0) emit LedgerTransfer(address(this), address(this), fee, LedgerReason.AccumulateFee);
    }

    /**
     * @notice Withdraw from feePool to a balance (ShareToken resolution fees)
     * @param to Recipient (resolution fee recipient)
     * @param amount Amount to withdraw
     * @dev Called ONLY by ShareToken for resolution fee withdrawal
     */
    function withdrawFeePoolByShareToken(address to, uint256 amount)
        external onlyShareToken whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        if (feePool < amount) revert InsufficientFeePool();

        feePool -= amount;
        balances[to] += amount;
        totalBalances += amount;

        emit LedgerTransfer(address(this), to, amount, LedgerReason.WithdrawFeePool);
    }

    // ============================================================
    // Settlement Functions — Fees
    // ============================================================

    /**
     * @notice Move USDC from a balance to feePool
     * @param from Address to debit (typically MarketLMSR or Exchange)
     * @param amount Fee amount
     */
    function accumulateFee(address from, uint256 amount) external onlySettlement whenNotPaused {
        if (amount == 0) return; // zero fee on micro-fills is acceptable
        if (balances[from] < amount) revert InsufficientBalance();

        balances[from] -= amount;
        totalBalances -= amount;
        feePool += amount;

        emit LedgerTransfer(from, address(this), amount, LedgerReason.AccumulateFee);
    }

    /**
     * @notice Withdraw from feePool to a balance
     * @param to Recipient (protocol or creator address)
     * @param amount Amount to withdraw
     */
    function withdrawFeePool(address to, uint256 amount) external onlySettlement whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (feePool < amount) revert InsufficientFeePool();

        feePool -= amount;
        balances[to] += amount;
        totalBalances += amount;

        emit LedgerTransfer(address(this), to, amount, LedgerReason.WithdrawFeePool);
    }

    // ============================================================
    // Settlement Functions — Transfers
    // ============================================================

    /**
     * @notice Zero-sum transfer between two ledger balances
     * @param from Address to debit
     * @param to Address to credit
     * @param amount USDC amount
     * @dev Called by Exchange (COMPLEMENTARY match), BackstopRouter (LMSR trades)
     */
    function transferBetween(address from, address to, uint256 amount)
        external
        onlySettlement
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        if (balances[from] < amount) revert InsufficientBalance();

        balances[from] -= amount;
        balances[to] += amount;
        // totalBalances unchanged (zero-sum)

        emit LedgerTransfer(from, to, amount, LedgerReason.TransferBetween);
    }

    // ============================================================
    // Factory Functions
    // ============================================================

    /**
     * @notice Pull initial liquidity from creator to market (Factory only)
     * @dev NO allowance check — special case for market init
     */
    function pullForNewMarket(address creator, address market, uint256 amount) external onlyFactory {
        if (amount == 0) revert ZeroAmount();
        if (balances[creator] < amount) revert InsufficientBalance();

        balances[creator] -= amount;
        balances[market] += amount;
        // totalBalances unchanged (zero-sum)

        emit LedgerTransfer(creator, market, amount, LedgerReason.MarketInitLiquidity);
    }

    // ============================================================
    // Admin Functions
    // ============================================================

    function addWhitelistedMarket(address market) external {
        require(
            msg.sender == admin || trustedFactories[msg.sender],
            "not admin or factory"
        );
        whitelistedMarkets[market] = true;
        emit WhitelistedMarketUpdated(market, true);
    }

    function removeWhitelistedMarket(address market) external onlyAdmin {
        whitelistedMarkets[market] = false;
        emit WhitelistedMarketUpdated(market, false);
    }

    function addTrustedFactory(address _factory) external onlyAdmin {
        trustedFactories[_factory] = true;
        emit TrustedFactoryUpdated(_factory, true);
    }

    function removeTrustedFactory(address _factory) external onlyAdmin {
        trustedFactories[_factory] = false;
        emit TrustedFactoryUpdated(_factory, false);
    }

    function setTreasury(address _treasury) external onlyAdmin {
        address old = treasury;
        treasury = _treasury;
        emit TreasuryUpdated(old, _treasury);
    }

    function setExchange(address _exchange) external onlyAdmin {
        exchange = _exchange;
    }

    function setShareToken(address _shareToken) external onlyAdmin {
        shareToken = _shareToken;
    }

    function setBackstopRouter(address _backstopRouter) external onlyAdmin {
        backstopRouter = _backstopRouter;
    }

    /**
     * @notice Admin escape hatch: withdraw from feePool to any address
     * @dev Covers LMSR fees that have no per-contract tracking/withdrawal path.
     *      Exchange and ShareToken track their own portions via protocolFeesAccumulated,
     *      creatorFeesAccumulated, and resolutionFeesAccumulated — admin should only
     *      withdraw the untracked remainder (LMSR fees).
     * @param to Recipient address (typically treasury)
     * @param amount USDC amount to withdraw from feePool
     */
    function adminWithdrawFeePool(address to, uint256 amount) external onlyAdmin whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (feePool < amount) revert InsufficientFeePool();

        feePool -= amount;
        balances[to] += amount;
        totalBalances += amount;

        emit LedgerTransfer(address(this), to, amount, LedgerReason.WithdrawFeePool);
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

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function usdcToken() external view returns (address) {
        return address(usdc);
    }

    /**
     * @notice Check the global invariant (for testing/monitoring)
     * @return valid Whether USDC balance covers all reserved amounts
     */
    function checkInvariant() external view returns (bool valid) {
        return usdc.balanceOf(address(this)) >= totalBalances + splitReserve + feePool;
    }
}
