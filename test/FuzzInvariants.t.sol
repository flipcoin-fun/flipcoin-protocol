// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BaseV2Test} from "./BaseV2Test.sol";
import {Side, Outcome, MarketParams} from "../contracts/v2/interfaces/Types.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";

/**
 * @title FuzzInvariants
 * @notice Fuzz tests for critical system invariants:
 *   1. Vault: USDC.balanceOf(vault) >= totalBalances + splitReserve + feePool
 *   2. ShareToken: totalSupply(yesId) == totalSupply(noId) before resolution
 *   3. Polymarket guarantee: sharesOut >= netUsdc for every buy
 *   4. Solvency through full lifecycle (trades + resolution + redemption)
 */
contract FuzzInvariantsTest is BaseV2Test {

    // ============================================================
    // Helpers
    // ============================================================

    function _assertVaultInvariant(string memory ctx) internal view {
        uint256 usdcBal = usdc.balanceOf(address(vault));
        uint256 accounting = vault.totalBalances() + vault.splitReserve() + vault.feePool();
        assertGe(usdcBal, accounting, string.concat("vault invariant violated: ", ctx));
    }

    function _assertPairInvariant(address market, string memory ctx) internal view {
        uint256 yesId = MarketLMSR(market).yesTokenId();
        uint256 noId = MarketLMSR(market).noTokenId();
        assertEq(
            shareToken.totalSupply(yesId),
            shareToken.totalSupply(noId),
            string.concat("pair invariant violated: ", ctx)
        );
    }

    function _assertPriceInvariant(address market, string memory ctx) internal view {
        (uint256 pYes, uint256 pNo) = MarketLMSR(market).getPrices();
        assertEq(pYes + pNo, 10_000, string.concat("price sum != 10000: ", ctx));
    }

    // ============================================================
    // 1. Vault Invariant — Random Trade Sequences
    // ============================================================

    /// @dev Random buy amounts, alternating YES/NO — vault invariant must hold after each trade
    function testFuzz_vaultInvariant_randomBuys(
        uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 sideSeed
    ) public {
        a1 = bound(a1, 100_000, 20_000_000);  // $0.10 - $20
        a2 = bound(a2, 100_000, 20_000_000);
        a3 = bound(a3, 100_000, 20_000_000);
        a4 = bound(a4, 100_000, 20_000_000);

        (address market, bytes32 cId) = _createDefaultMarket(alice);
        _assertVaultInvariant("after create");
        _assertPairInvariant(market, "after create");

        // Trade 1
        vm.prank(alice);
        backstopRouter.executeTrade(cId, sideSeed % 2 == 0 ? Side.Yes : Side.No, true, a1, 0);
        _assertVaultInvariant("after trade 1");
        _assertPairInvariant(market, "after trade 1");

        // Trade 2
        vm.prank(bob);
        backstopRouter.executeTrade(cId, sideSeed % 3 == 0 ? Side.Yes : Side.No, true, a2, 0);
        _assertVaultInvariant("after trade 2");
        _assertPairInvariant(market, "after trade 2");

        // Trade 3
        vm.prank(carol);
        backstopRouter.executeTrade(cId, sideSeed % 5 == 0 ? Side.No : Side.Yes, true, a3, 0);
        _assertVaultInvariant("after trade 3");
        _assertPairInvariant(market, "after trade 3");

        // Trade 4
        vm.prank(alice);
        backstopRouter.executeTrade(cId, sideSeed % 7 == 0 ? Side.No : Side.Yes, true, a4, 0);
        _assertVaultInvariant("after trade 4");
        _assertPairInvariant(market, "after trade 4");
        _assertPriceInvariant(market, "after trade 4");
    }

    /// @dev Random buy then sell — vault invariant through full cycle
    function testFuzz_vaultInvariant_buySellCycle(
        uint256 buyAmount, uint256 sellFraction, bool isYes
    ) public {
        buyAmount = bound(buyAmount, 500_000, 30_000_000);   // $0.50 - $30
        sellFraction = bound(sellFraction, 10, 90);           // sell 10-90% of shares

        (address market, bytes32 cId) = _createDefaultMarket(alice);
        Side side = isYes ? Side.Yes : Side.No;

        // Buy
        vm.prank(alice);
        uint256 shares = backstopRouter.executeTrade(cId, side, true, buyAmount, 0);
        _assertVaultInvariant("after buy");
        _assertPairInvariant(market, "after buy");

        // Sell fraction
        uint256 sellShares = shares * sellFraction / 100;
        if (sellShares == 0) sellShares = 1;

        vm.prank(alice);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        vm.prank(alice);
        backstopRouter.executeTrade(cId, side, false, sellShares, 0);
        _assertVaultInvariant("after sell");
        _assertPairInvariant(market, "after sell");
        _assertPriceInvariant(market, "after sell");
    }

    // ============================================================
    // 2. ShareToken Pair Invariant — Multi-user Trading
    // ============================================================

    /// @dev Multiple users buy and sell — pair invariant always holds
    function testFuzz_pairInvariant_multiUser(
        uint256 a1, uint256 a2, uint256 a3, uint256 sellAmt
    ) public {
        a1 = bound(a1, 100_000, 15_000_000);
        a2 = bound(a2, 100_000, 15_000_000);
        a3 = bound(a3, 100_000, 15_000_000);
        sellAmt = bound(sellAmt, 10, 80); // percentage

        (address market, bytes32 cId) = _createDefaultMarket(alice);

        // Alice buys YES
        vm.prank(alice);
        uint256 aliceShares = backstopRouter.executeTrade(cId, Side.Yes, true, a1, 0);
        _assertPairInvariant(market, "alice buy YES");

        // Bob buys NO
        vm.prank(bob);
        backstopRouter.executeTrade(cId, Side.No, true, a2, 0);
        _assertPairInvariant(market, "bob buy NO");

        // Carol buys YES
        vm.prank(carol);
        backstopRouter.executeTrade(cId, Side.Yes, true, a3, 0);
        _assertPairInvariant(market, "carol buy YES");

        // Alice sells portion of YES
        uint256 sellShares = aliceShares * sellAmt / 100;
        if (sellShares == 0) sellShares = 1;

        vm.prank(alice);
        shareToken.setApprovalForAll(address(backstopRouter), true);
        vm.prank(alice);
        backstopRouter.executeTrade(cId, Side.Yes, false, sellShares, 0);
        _assertPairInvariant(market, "alice sell YES");
        _assertVaultInvariant("after multi-user trades");
    }

    // ============================================================
    // 3. Polymarket Guarantee — sharesOut >= netUsdc
    // ============================================================

    /// @dev For any buy amount, shares received >= net USDC (price <= $1)
    function testFuzz_polymarketGuarantee_allAmounts(uint256 amount, bool isYes) public {
        amount = bound(amount, 100_000, 50_000_000); // $0.10 - $50

        (address market, bytes32 cId) = _createDefaultMarket(alice);
        Side side = isYes ? Side.Yes : Side.No;

        // Quote (view — no state change)
        (uint256 sharesOut, uint256 fee) = MarketLMSR(market).quoteBuy(side, amount);
        uint256 net = amount - fee;

        assertGe(sharesOut, net, "Polymarket guarantee: shares must be >= net USDC");
    }

    /// @dev Polymarket guarantee holds even after market is biased from prior trades
    function testFuzz_polymarketGuarantee_afterBias(
        uint256 priorBuy, uint256 testBuy, bool priorIsYes, bool testIsYes
    ) public {
        priorBuy = bound(priorBuy, 1_000_000, 30_000_000);
        testBuy = bound(testBuy, 100_000, 30_000_000);

        (address market, bytes32 cId) = _createDefaultMarket(alice);

        // Create bias with prior trade
        vm.prank(bob);
        backstopRouter.executeTrade(cId, priorIsYes ? Side.Yes : Side.No, true, priorBuy, 0);

        // Quote after bias
        Side side = testIsYes ? Side.Yes : Side.No;
        (uint256 sharesOut, uint256 fee) = MarketLMSR(market).quoteBuy(side, testBuy);
        uint256 net = testBuy - fee;

        assertGe(sharesOut, net, "Polymarket guarantee must hold after market bias");
    }

    // ============================================================
    // 4. Full Lifecycle — Trades + Resolution + Redemption
    // ============================================================

    /// @dev Full lifecycle: random trades → resolution → redemption — vault stays solvent
    function testFuzz_fullLifecycle_solvency(
        uint256 a1, uint256 a2, uint256 a3, bool resolveYes
    ) public {
        a1 = bound(a1, 500_000, 20_000_000);
        a2 = bound(a2, 500_000, 20_000_000);
        a3 = bound(a3, 500_000, 20_000_000);

        (address market, bytes32 cId) = _createDefaultMarket(alice);
        uint256 yesId = MarketLMSR(market).yesTokenId();
        uint256 noId = MarketLMSR(market).noTokenId();

        // Trades
        vm.prank(alice);
        backstopRouter.executeTrade(cId, Side.Yes, true, a1, 0);

        vm.prank(bob);
        backstopRouter.executeTrade(cId, Side.No, true, a2, 0);

        vm.prank(carol);
        backstopRouter.executeTrade(cId, Side.Yes, true, a3, 0);

        _assertVaultInvariant("before resolution");
        _assertPairInvariant(market, "before resolution");

        // Fast-forward past deadline
        uint64 deadline = MarketLMSR(market).deadline();
        vm.warp(deadline + 1);

        // Propose resolution
        vm.prank(admin);
        shareToken.proposeResolution(cId, resolveYes ? Outcome.Yes : Outcome.No);

        // Fast-forward past dispute period (24h)
        vm.warp(block.timestamp + 24 hours + 1);

        // Finalize
        shareToken.finalizeResolution(cId);

        _assertVaultInvariant("after resolution");

        // Redeem — try all users, some may have no winning tokens
        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 yesBal = shareToken.balanceOf(users[i], yesId);
            uint256 noBal = shareToken.balanceOf(users[i], noId);
            if (yesBal > 0 || noBal > 0) {
                vm.prank(users[i]);
                try shareToken.redeemPositions(cId) {} catch {}
            }
        }

        _assertVaultInvariant("after redemption");

        // Vault must still be solvent — USDC balance >= accounting sum
        assertTrue(vault.checkInvariant(), "vault must remain solvent after full lifecycle");
    }

    // ============================================================
    // 5. Market Creation — Different Initial Prices
    // ============================================================

    /// @dev Invariants hold for markets created at various initial prices
    function testFuzz_invariants_atDifferentPrices(uint256 priceBps, uint256 buyAmt) public {
        priceBps = bound(priceBps, 100, 9900);  // 1% - 99%
        buyAmt = bound(buyAmt, 100_000, 10_000_000);

        (address market, bytes32 cId) = _createMarketWithPrice(alice, priceBps);

        _assertVaultInvariant("after create at custom price");
        _assertPairInvariant(market, "after create at custom price");
        _assertPriceInvariant(market, "after create at custom price");

        // Buy
        vm.prank(bob);
        backstopRouter.executeTrade(cId, Side.Yes, true, buyAmt, 0);

        _assertVaultInvariant("after buy at custom price");
        _assertPairInvariant(market, "after buy at custom price");
        _assertPriceInvariant(market, "after buy at custom price");
    }
}
