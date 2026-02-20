// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseV2Test} from "./BaseV2Test.sol";
import {
    Side, Outcome, ResolutionStatus, Resolution
} from "../contracts/v2/interfaces/Types.sol";
import {ShareToken} from "../contracts/v2/ShareToken.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";

/**
 * @title ShareTokenAdvancedTest
 * @notice Advanced tests: dispute after finalization, admin transfer, authorized caller
 *         management, duplicate condition, and redemption edge cases.
 */
contract ShareTokenAdvancedTest is BaseV2Test {
    address internal market;
    bytes32 internal conditionId;
    uint256 internal yesTokenId;
    uint256 internal noTokenId;
    uint64 internal marketDeadline;

    function _setupMarket() internal {
        (market, conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        yesTokenId = lmsr.yesTokenId();
        noTokenId = lmsr.noTokenId();
        marketDeadline = lmsr.deadline();
    }

    function _buyShares(address buyer, Side side, uint256 amountUsdc) internal returns (uint256) {
        vm.prank(buyer);
        return backstopRouter.executeTrade(conditionId, side, true, amountUsdc, 0);
    }

    function _warpPastDeadline() internal {
        vm.warp(marketDeadline + 1);
    }

    function _proposeResolution(Outcome outcome) internal {
        vm.prank(admin);
        shareToken.proposeResolution(conditionId, outcome);
    }

    function _resolveMarket(Outcome outcome) internal {
        _proposeResolution(outcome);
        vm.warp(block.timestamp + 24 hours + 1);
        shareToken.finalizeResolution(conditionId);
    }

    // ============================================================
    // 1. Dispute After Finalization — Reverts (Resolved status)
    // ============================================================

    function test_disputeAfterFinalization_reverts() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _resolveMarket(Outcome.Yes);

        // Try to dispute after finalization — should revert since status = Resolved
        vm.prank(bob);
        vm.expectRevert(ShareToken.ResolutionNotPending.selector);
        shareToken.disputeResolution(conditionId);
    }

    // ============================================================
    // 2. Propose After Resolution — Reverts
    // ============================================================

    function test_proposeAfterResolution_reverts() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _resolveMarket(Outcome.Yes);

        // Try to propose after resolution — status is Resolved, not Open
        vm.prank(admin);
        vm.expectRevert(ShareToken.ResolutionNotOpen.selector);
        shareToken.proposeResolution(conditionId, Outcome.No);
    }

    // ============================================================
    // 3. Admin Transfer
    // ============================================================

    function test_transferAdmin_shareToken() public {
        address newAdmin = makeAddr("newShareTokenAdmin");

        vm.prank(admin);
        shareToken.transferAdmin(newAdmin);

        // Old admin can no longer call admin-only functions
        vm.prank(admin);
        vm.expectRevert(ShareToken.NotAdmin.selector);
        shareToken.removeAuthorizedCaller(makeAddr("someAddr"));

        // New admin can call admin-only functions
        address testCaller = makeAddr("testCaller");
        vm.prank(newAdmin);
        shareToken.addAuthorizedCaller(testCaller);
        assertTrue(shareToken.authorizedCallers(testCaller), "new admin should add caller");

        vm.prank(newAdmin);
        shareToken.removeAuthorizedCaller(testCaller);
        assertFalse(shareToken.authorizedCallers(testCaller), "new admin should remove caller");
    }

    function test_transferAdmin_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert("zero admin");
        shareToken.transferAdmin(address(0));
    }

    function test_transferAdmin_nonAdmin_reverts() public {
        vm.prank(bob);
        vm.expectRevert(ShareToken.NotAdmin.selector);
        shareToken.transferAdmin(bob);
    }

    // ============================================================
    // 4. Authorized Caller Management
    // ============================================================

    function test_addAuthorizedCaller_onlyAdminOrFactory() public {
        address newCaller = makeAddr("newCaller");

        // Random user cannot add
        vm.prank(bob);
        vm.expectRevert("not admin or factory");
        shareToken.addAuthorizedCaller(newCaller);

        // Admin can add
        vm.prank(admin);
        shareToken.addAuthorizedCaller(newCaller);
        assertTrue(shareToken.authorizedCallers(newCaller));
    }

    function test_addAuthorizedCaller_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert("zero address");
        shareToken.addAuthorizedCaller(address(0));
    }

    function test_removeAuthorizedCaller_onlyAdmin() public {
        address newCaller = makeAddr("removableCaller");
        vm.prank(admin);
        shareToken.addAuthorizedCaller(newCaller);

        vm.prank(bob);
        vm.expectRevert(ShareToken.NotAdmin.selector);
        shareToken.removeAuthorizedCaller(newCaller);

        vm.prank(admin);
        shareToken.removeAuthorizedCaller(newCaller);
        assertFalse(shareToken.authorizedCallers(newCaller));
    }

    // ============================================================
    // 5. Redemption — Invalid Outcome Pays 50%
    // ============================================================

    function test_redeem_invalid_exactPayout() public {
        _setupMarket();

        uint256 sharesOut = _buyShares(bob, Side.Yes, 20_000_000);
        uint256 bobYes = shareToken.balanceOf(bob, yesTokenId);

        _warpPastDeadline();
        _resolveMarket(Outcome.Invalid);

        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(r.payoutPerShare, 500_000, "Invalid payout should be exactly $0.50");

        uint256 bobVaultBefore = vault.balances(bob);
        vm.prank(bob);
        shareToken.redeemPositions(conditionId);
        uint256 payout = vault.balances(bob) - bobVaultBefore;

        // Invalid: payout = yesBal * 500_000 / 1_000_000 = yesBal / 2
        assertEq(payout, bobYes * 500_000 / 1_000_000, "payout should be exactly 50% of YES shares");
    }

    // ============================================================
    // 6. Multiple Users Redeem Sequentially — State Consistency
    // ============================================================

    function test_multipleUsers_redeemSequential() public {
        _setupMarket();

        // 3 users buy YES
        _buyShares(alice, Side.Yes, 10_000_000);
        _buyShares(bob, Side.Yes, 15_000_000);
        _buyShares(carol, Side.Yes, 5_000_000);

        uint256 aliceYes = shareToken.balanceOf(alice, yesTokenId);
        uint256 bobYes = shareToken.balanceOf(bob, yesTokenId);
        uint256 carolYes = shareToken.balanceOf(carol, yesTokenId);

        _warpPastDeadline();
        _resolveMarket(Outcome.Yes);

        // Redeem sequentially
        uint256 aliceBefore = vault.balances(alice);
        vm.prank(alice);
        shareToken.redeemPositions(conditionId);
        assertEq(vault.balances(alice) - aliceBefore, aliceYes, "alice payout");

        uint256 bobBefore = vault.balances(bob);
        vm.prank(bob);
        shareToken.redeemPositions(conditionId);
        assertEq(vault.balances(bob) - bobBefore, bobYes, "bob payout");

        uint256 carolBefore = vault.balances(carol);
        vm.prank(carol);
        shareToken.redeemPositions(conditionId);
        assertEq(vault.balances(carol) - carolBefore, carolYes, "carol payout");

        // All tokens burned
        assertEq(shareToken.balanceOf(alice, yesTokenId), 0);
        assertEq(shareToken.balanceOf(bob, yesTokenId), 0);
        assertEq(shareToken.balanceOf(carol, yesTokenId), 0);

        // Vault invariant
        assertTrue(vault.checkInvariant(), "vault invariant after all redemptions");
    }

    // ============================================================
    // 7. Condition Exchange Pause After Resolution
    // ============================================================

    function test_exchangePaused_afterFinalizeResolution() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _resolveMarket(Outcome.Yes);

        // Exchange condition should be paused after finalization
        assertTrue(
            exchange.conditionPaused(conditionId),
            "Exchange should pause condition after resolution"
        );
    }

    // ============================================================
    // 8. Set Exchange — Only Admin
    // ============================================================

    function test_setExchange_onlyAdmin() public {
        vm.prank(bob);
        vm.expectRevert(ShareToken.NotAdmin.selector);
        shareToken.setExchange(bob);
    }

    function test_setExchange_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert("zero exchange");
        shareToken.setExchange(address(0));
    }

    // ============================================================
    // 9. Holder With Both Sides — YES Wins
    // ============================================================

    function test_redeem_holderBothSides_yesWins() public {
        _setupMarket();

        // Bob buys both YES and NO
        _buyShares(bob, Side.Yes, 10_000_000);
        _buyShares(bob, Side.No, 5_000_000);

        uint256 bobYes = shareToken.balanceOf(bob, yesTokenId);
        uint256 bobNo = shareToken.balanceOf(bob, noTokenId);

        _warpPastDeadline();
        _resolveMarket(Outcome.Yes);

        // YES wins → bob gets payout for YES shares only (NO tokens are worthless)
        uint256 bobBefore = vault.balances(bob);
        vm.prank(bob);
        shareToken.redeemPositions(conditionId);
        uint256 payout = vault.balances(bob) - bobBefore;

        // payout = yesBal (1:1 for winning side only)
        assertEq(payout, bobYes, "YES winner should get payout only for YES tokens");

        // Only YES tokens burned; NO tokens remain (worthless, not burned by contract)
        assertEq(shareToken.balanceOf(bob, yesTokenId), 0, "YES burned");
        assertEq(shareToken.balanceOf(bob, noTokenId), bobNo, "NO tokens remain (worthless)");
    }
}
