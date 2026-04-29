// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EmergencySweeper
 * @notice One-shot owner-only relay used for retroactive rescue of stuck USDC in
 *         `splitReserve` of legacy MarketLMSR clones (pre-`sweepInventoryToCreator` impl).
 *
 * @dev DEPRECATED post-migration (2026-04-25). Retained in source for transparency;
 *      the underlying issue is patched in the current MarketLMSR implementation, which
 *      exposes a permissionless `sweepInventoryToCreator()` that releases winning-side
 *      ERC-1155 inventory back to the market creator after resolution.
 *
 *      Newly-created markets (post-migration) inherit the fix via the new FactoryV2
 *      pointing at the sweep-capable MarketLMSR implementation. EmergencySweeper itself
 *      is not used for any new markets and is published here for source-transparency only.
 *
 *      Original usage (atomic multisig batch — historical, no longer needed):
 *      1. Deploy EmergencySweeper(owner=multisig, vault=VaultV2, cap=totalStuckUSDC)
 *      2. `VaultV2.setShareToken(sweeper)` — points the `onlyShareToken` modifier at us
 *      3. For each stuck market: `sweeper.rescue(treasury, amount)` — pulls splitReserve
 *         to the treasury's vault balance via `VaultV2.releaseForRedeem`
 *      4. `VaultV2.setShareToken(realShareToken)` — restore
 *      5. Treasury later calls `VaultV2.withdraw(...)` to pull USDC out on-chain
 *
 *      All steps 2–4 must execute in one atomic batch. Between steps 2 and 4 the real
 *      ShareToken cannot settle redemptions; any tx that lands in that window would revert.
 *      A Safe multicall or a batch Gnosis tx is the expected execution path.
 *
 *      Defense-in-depth: `maxRescueAmount` is an immutable cap set at deployment. Even if
 *      someone later leaves `VaultV2.shareToken` pointing at this contract, the owner
 *      cannot pull more than the pre-computed stuck total. Treasury must compute the cap
 *      off-chain from the enumeration script.
 *
 *      Economic invariant: `releaseForRedeem` moves funds from splitReserve into
 *      `totalBalances[to]` — the sum `totalBalances + splitReserve + feePool` is
 *      preserved. The vault's USDC balance does not change. Invariant unaffected.
 */
interface IVaultV2 {
    function releaseForRedeem(address to, uint256 amount) external;
}

contract EmergencySweeper {
    address public immutable owner;
    IVaultV2 public immutable vault;
    uint256 public immutable maxRescueAmount;
    uint256 public totalRescued;

    event Rescued(address indexed to, uint256 amount, uint256 cumulative);

    error NotOwner();
    error ExceedsCap(uint256 attempted, uint256 cumulative, uint256 cap);
    error ZeroAddress();
    error ZeroAmount();

    constructor(address _owner, address _vault, uint256 _cap) {
        if (_owner == address(0) || _vault == address(0)) revert ZeroAddress();
        if (_cap == 0) revert ZeroAmount();
        owner = _owner;
        vault = IVaultV2(_vault);
        maxRescueAmount = _cap;
    }

    /**
     * @notice Pull stuck splitReserve dust into the treasury's vault balance.
     * @dev Must be invoked while `VaultV2.shareToken` == address(this). Reverts otherwise
     *      (the vault's `onlyShareToken` modifier rejects foreign callers).
     * @param to Recipient address (treasury). Receives `amount` as an internal vault balance.
     * @param amount USDC amount (6-decimal) to release from splitReserve.
     */
    function rescue(address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 newTotal = totalRescued + amount;
        if (newTotal > maxRescueAmount) {
            revert ExceedsCap(amount, totalRescued, maxRescueAmount);
        }

        // Effects before external call (CEI).
        totalRescued = newTotal;
        vault.releaseForRedeem(to, amount);

        emit Rescued(to, amount, newTotal);
    }

    /**
     * @notice Batch variant: release multiple amounts to the same recipient in one call.
     *         Caller is responsible for per-market amount computation off-chain.
     */
    function rescueBatch(address to, uint256[] calldata amounts) external {
        if (msg.sender != owner) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();

        uint256 len = amounts.length;
        if (len == 0) revert ZeroAmount();

        uint256 cumulative = totalRescued;
        for (uint256 i; i < len; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) revert ZeroAmount();
            cumulative += amount;
            if (cumulative > maxRescueAmount) {
                revert ExceedsCap(amount, cumulative - amount, maxRescueAmount);
            }
            totalRescued = cumulative;
            vault.releaseForRedeem(to, amount);
            emit Rescued(to, amount, cumulative);
        }
    }
}
