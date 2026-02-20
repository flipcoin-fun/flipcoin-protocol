// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BaseV2Test} from "./BaseV2Test.sol";
import {Side, MarketParams} from "../contracts/v2/interfaces/Types.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {LMSRMath} from "../contracts/v2/libraries/LMSRMath.sol";

/**
 * @title MarketLMSRMathTest
 * @notice Unit tests for v2 MarketLMSR with full LMSRMath integration
 * @dev Tests sigmoid prices, buy/sell math, Polymarket guarantee, collateralization
 */
contract MarketLMSRMathTest is BaseV2Test {

    // ============================================================
    // Price Tests
    // ============================================================

    function test_prices_sumTo10000_at50percent() public {
        (address market,) = _createDefaultMarket(alice); // 50% initial price
        MarketLMSR lmsr = MarketLMSR(market);

        (uint256 priceYes, uint256 priceNo) = lmsr.getPrices();
        assertEq(priceYes + priceNo, 10000, "prices should sum to 10000");
        // At 50/50, both should be ~5000
        assertApproxEqAbs(priceYes, 5000, 10, "YES price should be ~5000 at 50/50");
    }

    function test_prices_sumTo10000_at70percent() public {
        (address market,) = _createMarketWithPrice(alice, 7000); // 70%
        MarketLMSR lmsr = MarketLMSR(market);

        (uint256 priceYes, uint256 priceNo) = lmsr.getPrices();
        assertEq(priceYes + priceNo, 10000, "prices should sum to 10000");
        assertApproxEqAbs(priceYes, 7000, 100, "YES price should be ~7000");
    }

    function test_prices_sumTo10000_at20percent() public {
        (address market,) = _createMarketWithPrice(alice, 2000); // 20%
        MarketLMSR lmsr = MarketLMSR(market);

        (uint256 priceYes, uint256 priceNo) = lmsr.getPrices();
        assertEq(priceYes + priceNo, 10000, "prices should sum to 10000");
        assertApproxEqAbs(priceYes, 2000, 100, "YES price should be ~2000");
    }

    function test_buyYes_increasesYesPrice() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);

        (uint256 priceBefore,) = lmsr.getPrices();

        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0);

        (uint256 priceAfter,) = lmsr.getPrices();
        assertGt(priceAfter, priceBefore, "YES price should increase after buying YES");
    }

    function test_buyNo_decreasesYesPrice() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);

        (uint256 priceBefore,) = lmsr.getPrices();

        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.No, true, 10_000_000, 0);

        (uint256 priceAfter,) = lmsr.getPrices();
        assertLt(priceAfter, priceBefore, "YES price should decrease after buying NO");
    }

    function test_prices_alwaysInValidRange() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);

        // Buy lots of YES to push price high
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            backstopRouter.executeTrade(conditionId, Side.Yes, true, 20_000_000, 0);
        }

        (uint256 priceYes, uint256 priceNo) = lmsr.getPrices();
        assertGe(priceYes, 1, "YES price should be >= 1");
        assertLe(priceYes, 9999, "YES price should be <= 9999");
        assertGe(priceNo, 1, "NO price should be >= 1");
        assertLe(priceNo, 9999, "NO price should be <= 9999");
        assertEq(priceYes + priceNo, 10000, "prices should still sum to 10000");
    }

    // ============================================================
    // Buy Tests — Polymarket Guarantee
    // ============================================================

    function test_buy_polymarketGuarantee_sharesGteNet() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        uint256 buyAmount = 10_000_000; // 10 USDC
        uint256 fee = buyAmount * DEFAULT_TOTAL_FEE_BPS / 10000;
        uint256 net = buyAmount - fee;

        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, buyAmount, 0);

        // Polymarket guarantee: sharesOut >= net
        assertGe(sharesOut, net, "shares should be >= net USDC (Polymarket guarantee)");
    }

    function test_buy_polymarketGuarantee_atBias() public {
        // Test with biased market (70% YES)
        (address market, bytes32 conditionId) = _createMarketWithPrice(alice, 7000);
        MarketLMSR lmsr = MarketLMSR(market);

        uint256 buyAmount = 5_000_000; // 5 USDC
        uint256 fee = buyAmount * DEFAULT_TOTAL_FEE_BPS / 10000;
        uint256 net = buyAmount - fee;

        // Buy YES (expensive side)
        vm.prank(bob);
        uint256 sharesYes = backstopRouter.executeTrade(conditionId, Side.Yes, true, buyAmount, 0);
        assertGe(sharesYes, net, "YES shares should be >= net (Polymarket guarantee)");

        // Buy NO (cheap side) — should get even more
        vm.prank(carol);
        uint256 sharesNo = backstopRouter.executeTrade(conditionId, Side.No, true, buyAmount, 0);
        assertGe(sharesNo, net, "NO shares should be >= net (Polymarket guarantee)");
    }

    function testFuzz_buy_polymarketGuarantee(uint256 amount) public {
        amount = bound(amount, 100_000, 50_000_000); // 0.1 to 50 USDC

        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        uint256 fee = amount * DEFAULT_TOTAL_FEE_BPS / 10000;
        uint256 net = amount - fee;

        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, amount, 0);

        assertGe(sharesOut, net, "fuzz: Polymarket guarantee violated");
    }

    // ============================================================
    // Buy Tests — Share Calculations
    // ============================================================

    function test_buy_sharesDecrease_asMoreBought() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        uint256 buyAmount = 10_000_000;

        // First buy
        vm.prank(bob);
        uint256 shares1 = backstopRouter.executeTrade(conditionId, Side.Yes, true, buyAmount, 0);

        // Second buy (price is now higher)
        vm.prank(bob);
        uint256 shares2 = backstopRouter.executeTrade(conditionId, Side.Yes, true, buyAmount, 0);

        assertGt(shares1, shares2, "should get fewer shares at higher price");
    }

    function test_buy_erc1155BalanceMatches() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0);

        assertEq(shareToken.balanceOf(bob, yesId), sharesOut, "ERC-1155 balance should match");
    }

    // ============================================================
    // Sell Tests — Cost Difference
    // ============================================================

    function test_sell_receivesCostDifference() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        // Buy YES
        uint256 buyAmount = 10_000_000;
        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, buyAmount, 0);

        // Approve BackstopRouter
        vm.prank(bob);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        // Record balance before sell
        uint256 bobBalBefore = vault.balances(bob);

        // Sell all shares
        vm.prank(bob);
        uint256 usdcOut = backstopRouter.executeTrade(conditionId, Side.Yes, false, sharesOut, 0);

        // Should receive positive USDC
        assertGt(usdcOut, 0, "should receive USDC from sell");

        // Balance should increase by exactly usdcOut
        assertEq(vault.balances(bob) - bobBalBefore, usdcOut, "balance increase should match usdcOut");

        // All shares should be burned
        assertEq(shareToken.balanceOf(bob, yesId), 0, "should have 0 shares after sell");
    }

    function test_sell_priceDecreases() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);

        // Buy YES
        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0);

        (uint256 priceBefore,) = lmsr.getPrices();

        // Sell YES
        vm.prank(bob);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, false, sharesOut, 0);

        (uint256 priceAfter,) = lmsr.getPrices();
        assertLt(priceAfter, priceBefore, "YES price should decrease after selling YES");
    }

    function test_buySell_roundtrip_losesFees() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        uint256 buyAmount = 10_000_000; // 10 USDC
        uint256 bobBalStart = vault.balances(bob);

        // Buy YES
        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, buyAmount, 0);

        // Sell YES
        vm.prank(bob);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, false, sharesOut, 0);

        uint256 bobBalEnd = vault.balances(bob);

        // Bob should lose approximately 2x fees (buy fee + sell fee)
        // With 1% total fee, loss should be ~2% of original amount
        assertLt(bobBalEnd, bobBalStart, "should lose USDC to fees on roundtrip");
        assertGt(bobBalEnd, bobBalStart - buyAmount, "loss should be less than full amount");
    }

    // ============================================================
    // Initial Q Tests
    // ============================================================

    function test_initialQ_symmetric_at50percent() public {
        (address market,) = _createDefaultMarket(alice); // 50%
        MarketLMSR lmsr = MarketLMSR(market);

        int256 qY = lmsr.qYes();
        int256 qN = lmsr.qNo();

        // At 50%, qYes should equal qNo (both 0)
        assertEq(qY, qN, "qYes should equal qNo at 50%");
        assertEq(qY, 0, "qYes should be 0 at 50%");
    }

    function test_initialQ_biased_at70percent() public {
        (address market,) = _createMarketWithPrice(alice, 7000); // 70%
        MarketLMSR lmsr = MarketLMSR(market);

        int256 qY = lmsr.qYes();
        int256 qN = lmsr.qNo();

        // At 70%, qYes > qNo
        assertGt(qY, qN, "qYes should be greater than qNo at 70%");
        // They should be symmetric: qYes = -qNo
        assertEq(qY, -qN, "qYes and qNo should be symmetric around 0");
    }

    function test_initialQ_biased_at20percent() public {
        (address market,) = _createMarketWithPrice(alice, 2000); // 20%
        MarketLMSR lmsr = MarketLMSR(market);

        int256 qY = lmsr.qYes();
        int256 qN = lmsr.qNo();

        // At 20%, qYes < qNo
        assertLt(qY, qN, "qYes should be less than qNo at 20%");
    }

    // ============================================================
    // Collateralization Invariant
    // ============================================================

    function test_collateralization_afterBuys() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        // Multiple buys on both sides
        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 20_000_000, 0);

        vm.prank(carol);
        backstopRouter.executeTrade(conditionId, Side.No, true, 15_000_000, 0);

        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0);

        // Vault invariant: USDC.balanceOf(vault) >= totalBalances + splitReserve + feePool
        uint256 usdcBalance = usdc.balanceOf(address(vault));
        uint256 accounting = vault.totalBalances() + vault.splitReserve() + vault.feePool();
        assertGe(usdcBalance, accounting, "vault invariant should hold after buys");
    }

    function test_collateralization_afterBuyAndSell() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        // Buy YES
        vm.prank(bob);
        uint256 shares = backstopRouter.executeTrade(conditionId, Side.Yes, true, 20_000_000, 0);

        // Sell half
        vm.prank(bob);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, false, shares / 2, 0);

        uint256 usdcBalance = usdc.balanceOf(address(vault));
        uint256 accounting = vault.totalBalances() + vault.splitReserve() + vault.feePool();
        assertGe(usdcBalance, accounting, "vault invariant should hold after buy+sell");
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_prices_alwaysSumTo10000(uint256 buyAmount, bool isYes) public {
        buyAmount = bound(buyAmount, 100_000, 50_000_000);

        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);

        Side side = isYes ? Side.Yes : Side.No;

        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, side, true, buyAmount, 0);

        (uint256 priceYes, uint256 priceNo) = lmsr.getPrices();
        assertEq(priceYes + priceNo, 10000, "fuzz: prices should always sum to 10000");
        assertGe(priceYes, 1, "fuzz: YES >= 1");
        assertLe(priceYes, 9999, "fuzz: YES <= 9999");
    }

    function testFuzz_collateralization_invariant(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 100_000, 30_000_000);
        amount2 = bound(amount2, 100_000, 30_000_000);

        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, amount1, 0);

        vm.prank(carol);
        backstopRouter.executeTrade(conditionId, Side.No, true, amount2, 0);

        uint256 usdcBalance = usdc.balanceOf(address(vault));
        uint256 accounting = vault.totalBalances() + vault.splitReserve() + vault.feePool();
        assertGe(usdcBalance, accounting, "fuzz: vault invariant violated");
    }

    // ============================================================
    // Edge Cases
    // ============================================================

    function test_minTrade_works() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        // MIN_TRADE_USDC = 10_000 (0.01 USDC)
        vm.prank(bob);
        uint256 shares = backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000, 0);
        assertGt(shares, 0, "min trade should still produce shares");
    }

    function test_largeTrade_works() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        // Large trade: 1000 USDC
        vm.prank(bob);
        uint256 shares = backstopRouter.executeTrade(conditionId, Side.Yes, true, 1_000_000_000, 0);
        assertGt(shares, 0, "large trade should produce shares");
    }

    function test_multipleBuyers_bothSides() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();
        uint256 noId = lmsr.noTokenId();

        // Bob buys YES, Carol buys NO
        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0);

        vm.prank(carol);
        backstopRouter.executeTrade(conditionId, Side.No, true, 10_000_000, 0);

        assertGt(shareToken.balanceOf(bob, yesId), 0, "bob should have YES");
        assertGt(shareToken.balanceOf(carol, noId), 0, "carol should have NO");

        (uint256 priceYes, uint256 priceNo) = lmsr.getPrices();
        assertEq(priceYes + priceNo, 10000, "prices should sum to 10000 after both-side trades");
    }

    // ============================================================
    // Cost Function Monotonicity
    // ============================================================

    function test_costFunction_increasesWithQ() public {
        // Test that cost function increases when q increases
        int256 _b = 50_000_000 * 1e12; // 50 USDC in SD59x18

        uint256 cost1 = LMSRMath.calcCostUsdc(_b, 0, 0);
        uint256 cost2 = LMSRMath.calcCostUsdc(_b, 10_000_000 * 1e12, 0);
        uint256 cost3 = LMSRMath.calcCostUsdc(_b, 20_000_000 * 1e12, 0);

        assertGt(cost2, cost1, "cost should increase with qYes");
        assertGt(cost3, cost2, "cost should keep increasing");
    }

    function test_costFunction_symmetric() public {
        int256 _b = 50_000_000 * 1e12;
        int256 delta = 10_000_000 * 1e12;

        uint256 costYes = LMSRMath.calcCostUsdc(_b, delta, 0);
        uint256 costNo = LMSRMath.calcCostUsdc(_b, 0, delta);

        assertEq(costYes, costNo, "cost should be symmetric for qYes and qNo");
    }

    // ============================================================
    // Sigmoid Accuracy Tests (Library Direct)
    // ============================================================

    function test_sigmoid_at50percent() public pure {
        int256 _b = 50_000_000 * 1e12;
        uint256 price = LMSRMath.sigmoid(_b, 0); // diff = 0 → 50%
        assertApproxEqAbs(price, 5000, 1, "sigmoid(0) should be ~5000");
    }

    function test_sigmoid_extreme_high() public pure {
        int256 _b = 50_000_000 * 1e12;
        int256 largeDiff = _b * 15; // very large diff
        uint256 price = LMSRMath.sigmoid(_b, largeDiff);
        assertGe(price, 9900, "extreme positive diff should give very high price");
    }

    function test_sigmoid_extreme_low() public pure {
        int256 _b = 50_000_000 * 1e12;
        int256 largeDiff = -_b * 15;
        uint256 price = LMSRMath.sigmoid(_b, largeDiff);
        assertLe(price, 100, "extreme negative diff should give very low price");
    }

    // ============================================================
    // MarketLMSR.quoteBuy / quoteSell View Tests
    // ============================================================

    function test_quoteBuy_returnsSharesAndFee() public {
        (address market,) = _createDefaultMarket(alice);
        (uint256 sharesOut, uint256 fee) = MarketLMSR(market).quoteBuy(Side.Yes, 10_000_000);
        assertTrue(sharesOut > 0, "quoteBuy should return shares > 0");
        assertTrue(fee > 0, "quoteBuy should return fee > 0");
        assertTrue(sharesOut >= 10_000_000 - fee, "Polymarket guarantee");
    }

    function test_quoteSell_returnsAmountAndFee() public {
        (address market, bytes32 cId) = _createDefaultMarket(alice);

        // Buy first to have shares to sell
        vm.prank(alice);
        backstopRouter.executeTrade(cId, Side.Yes, true, 10_000_000, 0);

        (uint256 amountOut, uint256 fee) = MarketLMSR(market).quoteSell(Side.Yes, 5_000_000);
        assertTrue(amountOut > 0, "quoteSell should return amount > 0");
        assertTrue(fee > 0, "quoteSell should return fee > 0");
    }

    function test_quoteBuy_matchesActualBuy() public {
        (address market, bytes32 cId) = _createDefaultMarket(alice);

        // Quote
        (uint256 quotedShares,) = MarketLMSR(market).quoteBuy(Side.Yes, 5_000_000);

        // Actual trade
        vm.prank(alice);
        uint256 actualShares = backstopRouter.executeTrade(cId, Side.Yes, true, 5_000_000, 0);

        assertEq(quotedShares, actualShares, "quote must match actual trade");
    }

    function test_quoteSell_matchesActualSell() public {
        (address market, bytes32 cId) = _createDefaultMarket(alice);

        // Buy shares first
        vm.prank(alice);
        uint256 boughtShares = backstopRouter.executeTrade(cId, Side.Yes, true, 10_000_000, 0);

        // Quote sell
        uint256 sellAmount = boughtShares / 2;
        (uint256 quotedAmount,) = MarketLMSR(market).quoteSell(Side.Yes, sellAmount);

        // Approve BackstopRouter to transfer ERC-1155 shares
        vm.prank(alice);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        // Actual sell
        vm.prank(alice);
        uint256 actualAmount = backstopRouter.executeTrade(cId, Side.Yes, false, sellAmount, 0);

        assertEq(quotedAmount, actualAmount, "quoteSell must match actual sell");
    }

    function test_quoteBuy_pureView_noStateChange() public {
        (address market,) = _createDefaultMarket(alice);

        // Get prices before
        (uint256 priceBefore,) = MarketLMSR(market).getPrices();

        // Call quoteBuy multiple times
        MarketLMSR(market).quoteBuy(Side.Yes, 50_000_000);
        MarketLMSR(market).quoteBuy(Side.No, 50_000_000);
        MarketLMSR(market).quoteBuy(Side.Yes, 1_000_000);

        // Prices should not change
        (uint256 priceAfter,) = MarketLMSR(market).getPrices();
        assertEq(priceBefore, priceAfter, "quoteBuy is view - must not change state");
    }
}
