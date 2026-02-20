// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseV2Test} from "./BaseV2Test.sol";
import {
    Side, Outcome
} from "../contracts/v2/interfaces/Types.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {VaultV2} from "../contracts/v2/VaultV2.sol";

/**
 * @title VaultV2AdvancedTest
 * @notice Advanced vault tests: multi-market solvency, pause on all operations,
 *         admin transfer, checkInvariant view, and authorization edge cases.
 */
contract VaultV2AdvancedTest is BaseV2Test {

    // ============================================================
    // 1. Multi-Market Solvency — Vault Invariant
    // ============================================================

    function test_multiMarket_solvency_afterTrading() public {
        // Create 3 markets
        (,bytes32 cond1) = _createDefaultMarket(alice);
        (,bytes32 cond2) = _createMarketWithPrice(alice, 7000);
        (,bytes32 cond3) = _createMarketWithPrice(bob, 3000);

        // Trade on all 3 markets concurrently
        vm.prank(alice);
        backstopRouter.executeTrade(cond1, Side.Yes, true, 5_000_000, 0);
        vm.prank(bob);
        backstopRouter.executeTrade(cond1, Side.No, true, 3_000_000, 0);

        vm.prank(alice);
        backstopRouter.executeTrade(cond2, Side.No, true, 8_000_000, 0);
        vm.prank(carol);
        backstopRouter.executeTrade(cond2, Side.Yes, true, 6_000_000, 0);

        vm.prank(bob);
        backstopRouter.executeTrade(cond3, Side.Yes, true, 4_000_000, 0);
        vm.prank(carol);
        backstopRouter.executeTrade(cond3, Side.No, true, 4_000_000, 0);

        // Vault invariant must hold across all markets
        assertTrue(vault.checkInvariant(), "multi-market solvency invariant must hold");
    }

    // ============================================================
    // 2. Multi-Market Solvency After Resolution + Redemption
    // ============================================================

    function test_multiMarket_solvency_afterResolution() public {
        (address m1, bytes32 cond1) = _createDefaultMarket(alice);
        (address m2, bytes32 cond2) = _createMarketWithPrice(alice, 7000);

        // Trade on both
        vm.prank(bob);
        backstopRouter.executeTrade(cond1, Side.Yes, true, 10_000_000, 0);
        vm.prank(carol);
        backstopRouter.executeTrade(cond2, Side.No, true, 10_000_000, 0);

        // Warp past both market deadlines (m2 has 30d deadline, so warp past that)
        uint64 latestDeadline = MarketLMSR(m2).deadline();
        vm.warp(latestDeadline + 1);

        // Resolve market1 as YES
        vm.prank(admin);
        shareToken.proposeResolution(cond1, Outcome.Yes);
        vm.warp(block.timestamp + 24 hours + 1);
        shareToken.finalizeResolution(cond1);

        // Bob redeems his winning YES shares
        vm.prank(bob);
        shareToken.redeemPositions(cond1);

        // Market2 still active — invariant must hold
        assertTrue(vault.checkInvariant(), "invariant must hold after partial resolution");

        // Resolve market2 as NO — need fresh warp past cond2 dispute period
        vm.prank(admin);
        shareToken.proposeResolution(cond2, Outcome.No);
        {
            // Read the actual finalizeAfter from the resolution struct
            (, , , , , uint64 finalizeAfter2, , ) = shareToken.resolutions(cond2);
            vm.warp(uint256(finalizeAfter2) + 1);
        }
        shareToken.finalizeResolution(cond2);

        // Carol redeems
        vm.prank(carol);
        shareToken.redeemPositions(cond2);

        assertTrue(vault.checkInvariant(), "invariant must hold after all resolutions");
    }

    // ============================================================
    // 3. Pause Blocks lockForSplit
    // ============================================================

    function test_pause_blocksLockForSplit() public {
        vm.prank(admin);
        vault.pause();

        // Exchange tries lockForSplit — should revert
        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.VaultPaused.selector);
        vault.lockForSplit(alice, 1_000_000);
    }

    // ============================================================
    // 4. Pause Blocks releaseFromMerge
    // ============================================================

    function test_pause_blocksReleaseFromMerge() public {
        // First do a split while unpaused
        vm.prank(address(exchange));
        vault.lockForSplit(alice, 1_000_000);

        // Now pause
        vm.prank(admin);
        vault.pause();

        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.VaultPaused.selector);
        vault.releaseFromMerge(alice, 1_000_000);
    }

    // ============================================================
    // 5. Pause Blocks accumulateFee
    // ============================================================

    function test_pause_blocksAccumulateFee() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.VaultPaused.selector);
        vault.accumulateFee(alice, 1_000_000);
    }

    // ============================================================
    // 6. Pause Blocks transferBetween
    // ============================================================

    function test_pause_blocksTransferBetween() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.VaultPaused.selector);
        vault.transferBetween(alice, bob, 1_000_000);
    }

    // ============================================================
    // 7. Pause Blocks withdrawFeePool
    // ============================================================

    function test_pause_blocksWithdrawFeePool() public {
        // Accumulate some fees first
        vm.prank(address(exchange));
        vault.accumulateFee(alice, 1_000_000);

        vm.prank(admin);
        vault.pause();

        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.VaultPaused.selector);
        vault.withdrawFeePool(bob, 1_000_000);
    }

    // ============================================================
    // 8. Pause Blocks releaseForRedeem
    // ============================================================

    function test_pause_blocksReleaseForRedeem() public {
        vm.prank(address(exchange));
        vault.lockForSplit(alice, 1_000_000);

        vm.prank(admin);
        vault.pause();

        vm.prank(address(shareToken));
        vm.expectRevert(VaultV2.VaultPaused.selector);
        vault.releaseForRedeem(alice, 1_000_000);
    }

    // ============================================================
    // 9. Admin Transfer
    // ============================================================

    function test_transferAdmin_vaultV2() public {
        address newAdmin = makeAddr("newVaultAdmin");

        vm.prank(admin);
        vault.transferAdmin(newAdmin);
        assertEq(vault.admin(), newAdmin, "admin should be transferred");

        // Old admin can no longer act
        vm.prank(admin);
        vm.expectRevert(VaultV2.NotAdmin.selector);
        vault.pause();

        // New admin can act
        vm.prank(newAdmin);
        vault.pause();
        assertTrue(vault.paused(), "new admin should be able to pause");
    }

    function test_transferAdmin_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert("zero admin");
        vault.transferAdmin(address(0));
    }

    // ============================================================
    // 10. checkInvariant — Direct View Test
    // ============================================================

    function test_checkInvariant_initialState() public view {
        assertTrue(vault.checkInvariant(), "invariant should hold in initial state");
    }

    // ============================================================
    // 11. Zero Amount Operations
    // ============================================================

    function test_deposit_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(VaultV2.ZeroAmount.selector);
        vault.deposit(0);
    }

    function test_withdraw_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(VaultV2.ZeroAmount.selector);
        vault.withdraw(0, alice);
    }

    function test_lockForSplit_zeroAmount_reverts() public {
        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.ZeroAmount.selector);
        vault.lockForSplit(alice, 0);
    }

    function test_releaseFromMerge_zeroAmount_reverts() public {
        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.ZeroAmount.selector);
        vault.releaseFromMerge(alice, 0);
    }

    function test_transferBetween_zeroAmount_reverts() public {
        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.ZeroAmount.selector);
        vault.transferBetween(alice, bob, 0);
    }

    // ============================================================
    // 12. Authorization Edge Cases
    // ============================================================

    function test_notAuthorized_releaseFromMerge() public {
        vm.prank(alice);
        vm.expectRevert(VaultV2.NotAuthorized.selector);
        vault.releaseFromMerge(alice, 1_000_000);
    }

    function test_notAuthorized_accumulateFee() public {
        vm.prank(alice);
        vm.expectRevert(VaultV2.NotAuthorized.selector);
        vault.accumulateFee(alice, 1_000_000);
    }

    function test_notAuthorized_transferBetween() public {
        vm.prank(alice);
        vm.expectRevert(VaultV2.NotAuthorized.selector);
        vault.transferBetween(alice, bob, 1_000_000);
    }

    function test_notAuthorized_withdrawFeePool() public {
        vm.prank(alice);
        vm.expectRevert(VaultV2.NotAuthorized.selector);
        vault.withdrawFeePool(alice, 1_000_000);
    }

    // ============================================================
    // 13. Insufficient Split Reserve
    // ============================================================

    function test_releaseFromMerge_insufficientReserve() public {
        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.InsufficientSplitReserve.selector);
        vault.releaseFromMerge(alice, 1_000_000); // no split reserve
    }

    function test_releaseForRedeem_insufficientReserve() public {
        vm.prank(address(shareToken));
        vm.expectRevert(VaultV2.InsufficientSplitReserve.selector);
        vault.releaseForRedeem(alice, 1_000_000); // no split reserve
    }

    // ============================================================
    // 14. Insufficient Fee Pool
    // ============================================================

    function test_withdrawFeePool_insufficientPool() public {
        vm.prank(address(exchange));
        vm.expectRevert(VaultV2.InsufficientFeePool.selector);
        vault.withdrawFeePool(alice, 1_000_000); // no fees
    }

    // ============================================================
    // 15. Market Whitelist Management
    // ============================================================

    function test_addWhitelistedMarket_onlyAdminOrFactory() public {
        address newMarket = makeAddr("newMarket");

        // Random user cannot add
        vm.prank(alice);
        vm.expectRevert("not admin or factory");
        vault.addWhitelistedMarket(newMarket);

        // Admin can add
        vm.prank(admin);
        vault.addWhitelistedMarket(newMarket);
        assertTrue(vault.whitelistedMarkets(newMarket));
    }

    function test_removeWhitelistedMarket_onlyAdmin() public {
        address newMarket = makeAddr("newMarket2");
        vm.prank(admin);
        vault.addWhitelistedMarket(newMarket);

        vm.prank(alice);
        vm.expectRevert(VaultV2.NotAdmin.selector);
        vault.removeWhitelistedMarket(newMarket);

        vm.prank(admin);
        vault.removeWhitelistedMarket(newMarket);
        assertFalse(vault.whitelistedMarkets(newMarket));
    }
}
