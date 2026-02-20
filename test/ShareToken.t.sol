// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseV2Test} from "./BaseV2Test.sol";
import {
    Side, Outcome, ResolutionStatus, Condition, Resolution
} from "../contracts/v2/interfaces/Types.sol";
import {ShareToken} from "../contracts/v2/ShareToken.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";

/**
 * @title ShareTokenTest
 * @notice Comprehensive tests for ShareToken ERC-1155 conditional token contract
 * @dev Tests split/merge invariants, resolution lifecycle, redemption, access control
 */
contract ShareTokenTest is BaseV2Test {

    // Reusable market state set up by helper
    address internal market;
    bytes32 internal conditionId;
    uint256 internal yesTokenId;
    uint256 internal noTokenId;
    uint64 internal marketDeadline;

    // ============================================================
    // Setup Helpers
    // ============================================================

    /// @dev Creates a default market and caches its token IDs + deadline
    function _setupMarket() internal {
        (market, conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        yesTokenId = lmsr.yesTokenId();
        noTokenId = lmsr.noTokenId();
        marketDeadline = lmsr.deadline();
    }

    /// @dev Buy shares for a user via BackstopRouter.executeTrade
    function _buyShares(address buyer, Side side, uint256 amountUsdc) internal returns (uint256 sharesOut) {
        vm.prank(buyer);
        sharesOut = backstopRouter.executeTrade(conditionId, side, true, amountUsdc, 0);
    }

    /// @dev Advance time past the market deadline
    function _warpPastDeadline() internal {
        vm.warp(marketDeadline + 1);
    }

    /// @dev Advance time past deadline + ADMIN_RESOLVE_WINDOW (6h)
    function _warpPastAdminWindow() internal {
        vm.warp(marketDeadline + 6 hours + 1);
    }

    /// @dev Propose resolution as admin (oracle)
    function _proposeResolution(Outcome outcome) internal {
        vm.prank(admin);
        shareToken.proposeResolution(conditionId, outcome);
    }

    /// @dev Full resolution: propose → warp 24h → finalize
    function _resolveMarket(Outcome outcome) internal {
        _proposeResolution(outcome);
        vm.warp(block.timestamp + 24 hours + 1);
        shareToken.finalizeResolution(conditionId);
    }

    // ============================================================
    // 1. Split/Merge Invariant
    // ============================================================

    function test_splitMerge_equalYesNo() public {
        _setupMarket();

        // Bob buys YES — internally this splits YES+NO, gives YES to bob, NO stays in market
        uint256 sharesOut = _buyShares(bob, Side.Yes, 10_000_000);
        assertTrue(sharesOut > 0, "should receive shares");

        // Bob has YES shares
        uint256 bobYes = shareToken.balanceOf(bob, yesTokenId);
        assertEq(bobYes, sharesOut, "bob YES balance should match sharesOut");

        // Total supply of YES == total supply of NO (split invariant)
        uint256 totalYes = shareToken.totalSupply(yesTokenId);
        uint256 totalNo = shareToken.totalSupply(noTokenId);
        assertEq(totalYes, totalNo, "total supply YES should equal NO after split");
    }

    function test_splitMerge_afterMultipleTrades() public {
        _setupMarket();

        // Bob buys YES, Carol buys NO
        _buyShares(bob, Side.Yes, 10_000_000);
        _buyShares(carol, Side.No, 5_000_000);

        // Invariant must still hold
        uint256 totalYes = shareToken.totalSupply(yesTokenId);
        uint256 totalNo = shareToken.totalSupply(noTokenId);
        assertEq(totalYes, totalNo, "total YES == total NO after multiple buys");

        // Bob sells YES (merge destroys equal pair)
        uint256 bobYes = shareToken.balanceOf(bob, yesTokenId);
        vm.prank(bob);
        shareToken.setApprovalForAll(address(backstopRouter), true);
        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, false, bobYes, 0);

        // Invariant still holds
        totalYes = shareToken.totalSupply(yesTokenId);
        totalNo = shareToken.totalSupply(noTokenId);
        assertEq(totalYes, totalNo, "total YES == total NO after sell (merge)");
    }

    // ============================================================
    // 2. Split Only When Open
    // ============================================================

    function test_split_revertsWhenPending() public {
        _setupMarket();

        // Buy some shares first (to have a meaningful market)
        _buyShares(bob, Side.Yes, 5_000_000);

        // Propose resolution → status = Pending
        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        // Verify status is Pending
        (ResolutionStatus status,,,,,,,) = shareToken.resolutions(conditionId);
        assertEq(uint8(status), uint8(ResolutionStatus.Pending));

        // Try to buy (which triggers split) → should revert
        vm.prank(carol);
        vm.expectRevert("not open");
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 5_000_000, 0);
    }

    // ============================================================
    // 3. Merge Only When Open
    // ============================================================

    function test_merge_revertsWhenPending() public {
        _setupMarket();

        // Bob buys YES shares
        uint256 sharesOut = _buyShares(bob, Side.Yes, 10_000_000);

        // Approve backstopRouter
        vm.prank(bob);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        // Propose resolution → Pending
        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        // Try to sell (which triggers merge) → should revert
        vm.prank(bob);
        vm.expectRevert("not open");
        backstopRouter.executeTrade(conditionId, Side.Yes, false, sharesOut, 0);
    }

    // ============================================================
    // 4. Only Authorized Callers for Split
    // ============================================================

    function test_split_revertsNotAuthorizedCaller() public {
        _setupMarket();

        address randomUser = makeAddr("randomUser");

        // Random user tries to call splitPosition directly
        vm.prank(randomUser);
        vm.expectRevert(ShareToken.NotAuthorizedCaller.selector);
        shareToken.splitPosition(conditionId, randomUser, 1_000_000);
    }

    function test_merge_revertsNotAuthorizedCaller() public {
        _setupMarket();

        address randomUser = makeAddr("randomUser");

        // Random user tries to call mergePositions directly
        vm.prank(randomUser);
        vm.expectRevert(ShareToken.NotAuthorizedCaller.selector);
        shareToken.mergePositions(conditionId, randomUser, 1_000_000);
    }

    // ============================================================
    // 5. Resolution Propose — Happy Path
    // ============================================================

    function test_proposeResolution_happyPath() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();

        uint256 timestampBefore = block.timestamp;
        vm.prank(admin);
        shareToken.proposeResolution(conditionId, Outcome.Yes);

        // Verify resolution state
        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Pending), "status should be Pending");
        assertEq(uint8(r.proposedOutcome), uint8(Outcome.Yes), "proposed outcome should be Yes");
        assertEq(r.proposedAt, uint64(timestampBefore), "proposedAt should match");
        assertEq(r.finalizeAfter, uint64(timestampBefore) + 24 hours, "finalizeAfter should be +24h");
        assertFalse(r.disputed, "disputed should be false");
    }

    // ============================================================
    // 6. Resolution Propose Before Deadline
    // ============================================================

    function test_proposeResolution_revertsBeforeDeadline() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 5_000_000);

        // Do NOT warp past deadline — still before deadline
        vm.prank(admin);
        vm.expectRevert("deadline not reached");
        shareToken.proposeResolution(conditionId, Outcome.Yes);
    }

    // ============================================================
    // 7. Resolution Propose by Non-Oracle
    // ============================================================

    function test_proposeResolution_revertsNotOracle() public {
        _setupMarket();
        _warpPastDeadline();

        // Bob (not oracle/admin) tries to propose
        vm.prank(bob);
        vm.expectRevert("not oracle");
        shareToken.proposeResolution(conditionId, Outcome.Yes);
    }

    // ============================================================
    // 8. Dispute by Token Holder — Resets to Open
    // ============================================================

    function test_disputeResolution_byTokenHolder() public {
        _setupMarket();

        // Bob buys NO shares (he will want to dispute a YES resolution)
        _buyShares(bob, Side.No, 10_000_000);
        assertTrue(shareToken.balanceOf(bob, noTokenId) > 0, "bob should hold NO shares");

        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        // Verify Pending
        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Pending));

        // Bob disputes
        vm.prank(bob);
        shareToken.disputeResolution(conditionId);

        // Verify reset to Open
        r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Open), "status should be Open after dispute");
        assertEq(uint8(r.proposedOutcome), uint8(Outcome.None), "proposedOutcome should be None");
        assertEq(r.proposedAt, 0, "proposedAt should be 0");
        assertEq(r.finalizeAfter, 0, "finalizeAfter should be 0");
        assertTrue(r.disputed, "disputed flag should be true");
    }

    function test_disputeResolution_byYesHolder() public {
        _setupMarket();

        // Carol buys YES shares — she can also dispute
        _buyShares(carol, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _proposeResolution(Outcome.No);

        // Carol disputes
        vm.prank(carol);
        shareToken.disputeResolution(conditionId);

        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Open), "should reset to Open");
    }

    // ============================================================
    // 9. Dispute by Non-Holder — Reverts
    // ============================================================

    function test_disputeResolution_revertsNotTokenHolder() public {
        _setupMarket();

        // Bob buys shares, Carol does NOT
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        // Carol has no shares — dispute should revert
        assertEq(shareToken.balanceOf(carol, yesTokenId), 0, "carol should have 0 YES");
        assertEq(shareToken.balanceOf(carol, noTokenId), 0, "carol should have 0 NO");

        vm.prank(carol);
        vm.expectRevert(ShareToken.NotTokenHolder.selector);
        shareToken.disputeResolution(conditionId);
    }

    // ============================================================
    // 10. Dispute After 24h (Before Finalize)
    // ============================================================

    function test_disputeResolution_after24h_beforeFinalize() public {
        _setupMarket();

        // Bob buys YES shares
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _proposeResolution(Outcome.No);

        // Warp 25 hours — past dispute period but nobody finalized yet
        vm.warp(block.timestamp + 25 hours);

        // Bob disputes — contract only checks status == Pending, no time check on dispute
        // So this should succeed as long as nobody finalized
        vm.prank(bob);
        shareToken.disputeResolution(conditionId);

        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Open), "should still be Open after late dispute");
    }

    // ============================================================
    // 11. Finalize After 24h — Anyone Can Call
    // ============================================================

    function test_finalizeResolution_after24h() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        // Warp past 24h dispute period
        vm.warp(block.timestamp + 24 hours + 1);

        // Carol (random person, not admin) finalizes
        vm.prank(carol);
        shareToken.finalizeResolution(conditionId);

        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Resolved), "should be Resolved");
        assertEq(uint8(r.finalOutcome), uint8(Outcome.Yes), "final outcome should be Yes");
        assertEq(r.payoutPerShare, 1_000_000, "payout should be $1 for winner");
        assertTrue(r.resolvedAt > 0, "resolvedAt should be set");
    }

    // ============================================================
    // 12. Finalize During Dispute Period — Reverts
    // ============================================================

    function test_finalizeResolution_revertsDuringDisputePeriod() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        // Only 12 hours — still within dispute period
        vm.warp(block.timestamp + 12 hours);

        vm.expectRevert("dispute period active");
        shareToken.finalizeResolution(conditionId);
    }

    function test_finalizeResolution_revertsAtExactBoundary() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        // Get exact finalizeAfter
        Resolution memory r = shareToken.getResolution(conditionId);
        uint64 finalizeAfter = r.finalizeAfter;

        // Warp to exactly 1 second before finalizeAfter
        vm.warp(finalizeAfter - 1);

        vm.expectRevert("dispute period active");
        shareToken.finalizeResolution(conditionId);

        // Warp to exactly finalizeAfter — should succeed
        vm.warp(finalizeAfter);
        shareToken.finalizeResolution(conditionId);

        r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Resolved));
    }

    // ============================================================
    // 13. markAsInvalid — Timing
    // ============================================================

    function test_markAsInvalid_afterAdminWindow() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        // Warp past deadline + 6h
        _warpPastAdminWindow();

        // Anyone can mark as invalid
        vm.prank(carol);
        shareToken.markAsInvalid(conditionId);

        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Resolved), "should be Resolved");
        assertEq(uint8(r.finalOutcome), uint8(Outcome.Invalid), "should be Invalid");
        assertEq(r.payoutPerShare, 500_000, "payout should be $0.50");
    }

    function test_markAsInvalid_revertsBefore6h() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        // Warp past deadline but NOT past 6h window
        _warpPastDeadline();

        vm.expectRevert("invalid window not reached");
        shareToken.markAsInvalid(conditionId);
    }

    function test_markAsInvalid_revertsBeforeDeadline() public {
        _setupMarket();

        // Don't warp at all — before deadline
        vm.expectRevert("invalid window not reached");
        shareToken.markAsInvalid(conditionId);
    }

    // ============================================================
    // 14. markAsInvalid After Resolution — Reverts
    // ============================================================

    function test_markAsInvalid_revertsAlreadyResolved() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);
        vm.warp(block.timestamp + 24 hours + 1);
        shareToken.finalizeResolution(conditionId);

        // Now try markAsInvalid
        vm.expectRevert(ShareToken.AlreadyResolved.selector);
        shareToken.markAsInvalid(conditionId);
    }

    // ============================================================
    // 15. Redeem YES Winner
    // ============================================================

    function test_redeem_yesWinner() public {
        _setupMarket();

        // Bob buys YES shares
        uint256 sharesOut = _buyShares(bob, Side.Yes, 10_000_000);
        uint256 bobYesBal = shareToken.balanceOf(bob, yesTokenId);
        assertEq(bobYesBal, sharesOut);

        // Resolve as YES
        _warpPastDeadline();
        _resolveMarket(Outcome.Yes);

        // Bob redeems — verify PositionRedeemed event emits correct sharesBurned
        uint256 bobVaultBefore = vault.balances(bob);
        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit ShareToken.PositionRedeemed(conditionId, bob, bobYesBal, bobYesBal);
        shareToken.redeemPositions(conditionId);

        uint256 bobVaultAfter = vault.balances(bob);

        // YES winner gets 1:1 redemption (payout = yesBal)
        assertEq(bobVaultAfter - bobVaultBefore, bobYesBal, "payout should be 1:1 for YES winner");

        // YES tokens burned
        assertEq(shareToken.balanceOf(bob, yesTokenId), 0, "YES tokens should be burned");
    }

    // ============================================================
    // 16. Redeem NO Winner
    // ============================================================

    function test_redeem_noWinner() public {
        _setupMarket();

        // Carol buys NO shares
        uint256 sharesOut = _buyShares(carol, Side.No, 10_000_000);
        uint256 carolNoBal = shareToken.balanceOf(carol, noTokenId);
        assertEq(carolNoBal, sharesOut);

        // Resolve as NO
        _warpPastDeadline();
        _resolveMarket(Outcome.No);

        // Carol redeems — verify PositionRedeemed event emits correct sharesBurned
        uint256 carolVaultBefore = vault.balances(carol);
        vm.prank(carol);
        vm.expectEmit(true, true, false, true);
        emit ShareToken.PositionRedeemed(conditionId, carol, carolNoBal, carolNoBal);
        shareToken.redeemPositions(conditionId);

        uint256 carolVaultAfter = vault.balances(carol);

        // NO winner gets 1:1 redemption
        assertEq(carolVaultAfter - carolVaultBefore, carolNoBal, "payout should be 1:1 for NO winner");
        assertEq(shareToken.balanceOf(carol, noTokenId), 0, "NO tokens should be burned");
    }

    // ============================================================
    // 17. Redeem Invalid — Both Sides Get $0.50
    // ============================================================

    function test_redeem_invalid_bothSides() public {
        _setupMarket();

        // Bob buys YES, Carol buys NO
        _buyShares(bob, Side.Yes, 10_000_000);
        _buyShares(carol, Side.No, 10_000_000);

        uint256 bobYesBal = shareToken.balanceOf(bob, yesTokenId);
        uint256 carolNoBal = shareToken.balanceOf(carol, noTokenId);

        // Resolve as Invalid
        _warpPastDeadline();
        _resolveMarket(Outcome.Invalid);

        // Verify payout per share
        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(r.payoutPerShare, 500_000, "Invalid payout should be $0.50");

        // Bob redeems (YES holder in Invalid)
        uint256 bobVaultBefore = vault.balances(bob);
        vm.prank(bob);
        shareToken.redeemPositions(conditionId);
        uint256 bobPayout = vault.balances(bob) - bobVaultBefore;

        // Invalid: payout = (yesBal + noBal) * 500_000 / 1e6 = yesBal * 0.5
        // Bob only has YES, so payout = bobYesBal * 500_000 / 1_000_000
        assertEq(bobPayout, bobYesBal * 500_000 / 1_000_000, "bob should get 50% of YES shares");

        // Carol redeems (NO holder in Invalid)
        uint256 carolVaultBefore = vault.balances(carol);
        vm.prank(carol);
        shareToken.redeemPositions(conditionId);
        uint256 carolPayout = vault.balances(carol) - carolVaultBefore;

        assertEq(carolPayout, carolNoBal * 500_000 / 1_000_000, "carol should get 50% of NO shares");
    }

    function test_redeem_invalid_holderWithBothSides() public {
        _setupMarket();

        // Bob buys both YES and NO
        _buyShares(bob, Side.Yes, 10_000_000);
        _buyShares(bob, Side.No, 5_000_000);

        uint256 bobYes = shareToken.balanceOf(bob, yesTokenId);
        uint256 bobNo = shareToken.balanceOf(bob, noTokenId);

        // Resolve as Invalid
        _warpPastDeadline();
        _resolveMarket(Outcome.Invalid);

        uint256 bobVaultBefore = vault.balances(bob);
        vm.prank(bob);
        shareToken.redeemPositions(conditionId);
        uint256 bobPayout = vault.balances(bob) - bobVaultBefore;

        // Invalid: (yesBal + noBal) * 500_000 / 1e6
        uint256 expectedPayout = (bobYes + bobNo) * 500_000 / 1_000_000;
        assertEq(bobPayout, expectedPayout, "payout should cover both YES and NO at 50%");

        // Both burned
        assertEq(shareToken.balanceOf(bob, yesTokenId), 0, "YES should be burned");
        assertEq(shareToken.balanceOf(bob, noTokenId), 0, "NO should be burned");
    }

    // ============================================================
    // 18. Redeem Losing Side — NothingToRedeem
    // ============================================================

    function test_redeem_losingYes_whenNoWins() public {
        _setupMarket();

        // Bob buys YES (losing side when NO wins)
        _buyShares(bob, Side.Yes, 10_000_000);
        assertTrue(shareToken.balanceOf(bob, yesTokenId) > 0);

        // Resolve as NO
        _warpPastDeadline();
        _resolveMarket(Outcome.No);

        // Bob tries to redeem his YES tokens — should revert NothingToRedeem
        // (redeemPositions checks noBal for NO win; bob has no NO tokens)
        vm.prank(bob);
        vm.expectRevert(ShareToken.NothingToRedeem.selector);
        shareToken.redeemPositions(conditionId);
    }

    function test_redeem_losingNo_whenYesWins() public {
        _setupMarket();

        // Carol buys NO (losing side when YES wins)
        _buyShares(carol, Side.No, 10_000_000);
        assertTrue(shareToken.balanceOf(carol, noTokenId) > 0);

        // Resolve as YES
        _warpPastDeadline();
        _resolveMarket(Outcome.Yes);

        // Carol tries to redeem NO tokens — should revert
        vm.prank(carol);
        vm.expectRevert(ShareToken.NothingToRedeem.selector);
        shareToken.redeemPositions(conditionId);
    }

    // ============================================================
    // 19. Double Redeem — Second Call Reverts
    // ============================================================

    function test_redeem_doubleRedeem_reverts() public {
        _setupMarket();

        // Bob buys YES
        _buyShares(bob, Side.Yes, 10_000_000);

        // Resolve as YES
        _warpPastDeadline();
        _resolveMarket(Outcome.Yes);

        // First redeem succeeds
        vm.prank(bob);
        shareToken.redeemPositions(conditionId);
        assertEq(shareToken.balanceOf(bob, yesTokenId), 0, "shares should be burned");

        // Second redeem reverts — no shares left
        vm.prank(bob);
        vm.expectRevert(ShareToken.NothingToRedeem.selector);
        shareToken.redeemPositions(conditionId);
    }

    // ============================================================
    // 20. Re-Propose After Dispute
    // ============================================================

    function test_reProposeAfterDispute() public {
        _setupMarket();

        // Bob buys NO shares
        _buyShares(bob, Side.No, 10_000_000);

        _warpPastDeadline();

        // First proposal: YES
        _proposeResolution(Outcome.Yes);

        // Bob disputes
        vm.prank(bob);
        shareToken.disputeResolution(conditionId);

        // Verify back to Open
        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Open));
        assertTrue(r.disputed);

        // Admin re-proposes with different outcome (NO)
        vm.prank(admin);
        shareToken.proposeResolution(conditionId, Outcome.No);

        r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Pending), "should be Pending again");
        assertEq(uint8(r.proposedOutcome), uint8(Outcome.No), "proposed outcome should be No");
        assertTrue(r.finalizeAfter > 0, "finalizeAfter should be set");

        // Finalize the re-proposal
        vm.warp(block.timestamp + 24 hours + 1);
        shareToken.finalizeResolution(conditionId);

        r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Resolved), "should be Resolved");
        assertEq(uint8(r.finalOutcome), uint8(Outcome.No), "final outcome should be No");
    }

    // ============================================================
    // Additional Edge Cases
    // ============================================================

    function test_tokenIds_yesEven_noOdd() public {
        _setupMarket();
        assertEq(yesTokenId % 2, 0, "YES token ID should be even");
        assertEq(noTokenId % 2, 1, "NO token ID should be odd");
        assertTrue(yesTokenId != noTokenId, "YES and NO IDs should differ");
    }

    function test_proposeResolution_revertsOutcomeNone() public {
        _setupMarket();
        _warpPastDeadline();

        vm.prank(admin);
        vm.expectRevert(ShareToken.InvalidOutcome.selector);
        shareToken.proposeResolution(conditionId, Outcome.None);
    }

    function test_proposeResolution_revertsWhenAlreadyPending() public {
        _setupMarket();
        _warpPastDeadline();

        _proposeResolution(Outcome.Yes);

        // Try to propose again while Pending → ResolutionNotOpen
        vm.prank(admin);
        vm.expectRevert(ShareToken.ResolutionNotOpen.selector);
        shareToken.proposeResolution(conditionId, Outcome.No);
    }

    function test_finalizeResolution_revertsWhenNotPending() public {
        _setupMarket();

        // Status is Open — not Pending
        vm.expectRevert(ShareToken.ResolutionNotPending.selector);
        shareToken.finalizeResolution(conditionId);
    }

    function test_disputeResolution_revertsWhenNotPending() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        // Status is Open — not Pending
        vm.prank(bob);
        vm.expectRevert(ShareToken.ResolutionNotPending.selector);
        shareToken.disputeResolution(conditionId);
    }

    function test_redeem_revertsBeforeResolution() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        // Market is still Open — not Resolved
        vm.prank(bob);
        vm.expectRevert(ShareToken.ResolutionNotResolved.selector);
        shareToken.redeemPositions(conditionId);
    }

    function test_redeem_revertsWhenPending() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        // Status is Pending, not Resolved
        vm.prank(bob);
        vm.expectRevert(ShareToken.ResolutionNotResolved.selector);
        shareToken.redeemPositions(conditionId);
    }

    function test_markAsInvalid_revertsWhenPending() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        // Propose resolution
        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        // Warp past admin window
        vm.warp(marketDeadline + 6 hours + 1);

        // markAsInvalid should revert when Pending (blocks dispute bypass)
        vm.expectRevert(ShareToken.ResolutionNotOpen.selector);
        shareToken.markAsInvalid(conditionId);
    }

    function test_markAsInvalid_afterDisputeResetsToOpen() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        // Propose resolution, then dispute
        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        vm.prank(bob);
        shareToken.disputeResolution(conditionId);

        // Status is back to Open — now markAsInvalid should work
        vm.warp(marketDeadline + 6 hours + 1);
        shareToken.markAsInvalid(conditionId);

        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Resolved));
        assertEq(uint8(r.finalOutcome), uint8(Outcome.Invalid));
    }

    function test_multipleDisputeCycles() public {
        _setupMarket();

        // Bob and Carol buy shares
        _buyShares(bob, Side.Yes, 10_000_000);
        _buyShares(carol, Side.No, 10_000_000);

        _warpPastDeadline();

        // Cycle 1: propose YES, bob is happy, carol disputes
        _proposeResolution(Outcome.Yes);
        vm.prank(carol);
        shareToken.disputeResolution(conditionId);

        Resolution memory r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Open));

        // Cycle 2: propose NO, carol is happy, bob disputes
        _proposeResolution(Outcome.No);
        vm.prank(bob);
        shareToken.disputeResolution(conditionId);

        r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Open));

        // Cycle 3: propose Invalid, nobody disputes, finalize
        _proposeResolution(Outcome.Invalid);
        vm.warp(block.timestamp + 24 hours + 1);
        shareToken.finalizeResolution(conditionId);

        r = shareToken.getResolution(conditionId);
        assertEq(uint8(r.status), uint8(ResolutionStatus.Resolved));
        assertEq(uint8(r.finalOutcome), uint8(Outcome.Invalid));
    }

    function test_conditionMetadata() public {
        _setupMarket();

        Condition memory c = shareToken.getCondition(conditionId);
        assertTrue(c.prepared, "condition should be prepared");
        assertEq(c.oracle, admin, "oracle should be admin");
        assertEq(c.collateral, address(usdc), "collateral should be USDC");
        assertEq(c.yesTokenId, yesTokenId, "yesTokenId should match");
        assertEq(c.noTokenId, noTokenId, "noTokenId should match");
        assertEq(c.deadline, marketDeadline, "deadline should match");
    }

    function test_isResolved_view() public {
        _setupMarket();
        _buyShares(bob, Side.Yes, 10_000_000);

        assertFalse(shareToken.isResolved(conditionId), "should not be resolved initially");

        _warpPastDeadline();
        _proposeResolution(Outcome.Yes);

        assertFalse(shareToken.isResolved(conditionId), "should not be resolved when Pending");

        vm.warp(block.timestamp + 24 hours + 1);
        shareToken.finalizeResolution(conditionId);

        assertTrue(shareToken.isResolved(conditionId), "should be resolved after finalize");
    }

    function test_vaultInvariant_afterRedemption() public {
        _setupMarket();

        // Bob buys YES, Carol buys NO
        _buyShares(bob, Side.Yes, 20_000_000);
        _buyShares(carol, Side.No, 15_000_000);

        // Resolve as YES
        _warpPastDeadline();
        _resolveMarket(Outcome.Yes);

        // Bob redeems
        vm.prank(bob);
        shareToken.redeemPositions(conditionId);

        // Vault invariant should hold
        assertTrue(vault.checkInvariant(), "vault invariant should hold after redemption");
    }
}
