// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {VaultV2} from "../contracts/v2/VaultV2.sol";

contract VaultV2Test is Test {
    MockUSDC public usdc;
    VaultV2 public vault;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public exchange = makeAddr("exchange");
    address public market = makeAddr("market");
    address public factory = makeAddr("factory");
    address public shareToken = makeAddr("shareToken");

    function setUp() public {
        usdc = new MockUSDC();

        vm.prank(admin);
        vault = new VaultV2(address(usdc), admin);

        // Setup roles
        vm.startPrank(admin);
        vault.setExchange(exchange);
        vault.setShareToken(shareToken);
        vault.addWhitelistedMarket(market);
        vault.addTrustedFactory(factory);
        vm.stopPrank();

        // Fund alice
        usdc.mint(alice, 1_000_000_000); // 1000 USDC
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_deposit() public {
        vm.prank(alice);
        vault.deposit(100_000_000); // 100 USDC

        assertEq(vault.balances(alice), 100_000_000);
        assertEq(vault.totalBalances(), 100_000_000);
        assertEq(usdc.balanceOf(address(vault)), 100_000_000);
    }

    function test_withdraw() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(alice);
        vault.withdraw(50_000_000, alice);

        assertEq(vault.balances(alice), 50_000_000);
        assertEq(vault.totalBalances(), 50_000_000);
    }

    function test_withdraw_insufficientBalance() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(alice);
        vm.expectRevert(VaultV2.InsufficientBalance.selector);
        vault.withdraw(200_000_000, alice);
    }

    function test_lockForSplit() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(exchange);
        vault.lockForSplit(alice, 30_000_000);

        assertEq(vault.balances(alice), 70_000_000);
        assertEq(vault.totalBalances(), 70_000_000);
        assertEq(vault.splitReserve(), 30_000_000);
    }

    function test_releaseFromMerge() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(exchange);
        vault.lockForSplit(alice, 30_000_000);

        vm.prank(exchange);
        vault.releaseFromMerge(alice, 30_000_000);

        assertEq(vault.balances(alice), 100_000_000);
        assertEq(vault.splitReserve(), 0);
    }

    function test_releaseForRedeem() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(exchange);
        vault.lockForSplit(alice, 30_000_000);

        vm.prank(shareToken);
        vault.releaseForRedeem(bob, 20_000_000);

        assertEq(vault.balances(bob), 20_000_000);
        assertEq(vault.splitReserve(), 10_000_000);
    }

    function test_accumulateFee() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(exchange);
        vault.accumulateFee(alice, 5_000_000);

        assertEq(vault.balances(alice), 95_000_000);
        assertEq(vault.feePool(), 5_000_000);
        assertEq(vault.totalBalances(), 95_000_000);
    }

    function test_withdrawFeePool() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(exchange);
        vault.accumulateFee(alice, 5_000_000);

        vm.prank(exchange);
        vault.withdrawFeePool(bob, 5_000_000);

        assertEq(vault.feePool(), 0);
        assertEq(vault.balances(bob), 5_000_000);
    }

    function test_transferBetween() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(exchange);
        vault.transferBetween(alice, bob, 40_000_000);

        assertEq(vault.balances(alice), 60_000_000);
        assertEq(vault.balances(bob), 40_000_000);
        // totalBalances unchanged
        assertEq(vault.totalBalances(), 100_000_000);
    }

    function test_pullForNewMarket() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(factory);
        vault.pullForNewMarket(alice, market, 50_000_000);

        assertEq(vault.balances(alice), 50_000_000);
        assertEq(vault.balances(market), 50_000_000);
    }

    function test_notAuthorized_lockForSplit() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(alice); // not exchange/market/backstopRouter
        vm.expectRevert(VaultV2.NotAuthorized.selector);
        vault.lockForSplit(alice, 10_000_000);
    }

    function test_pause_unpause() public {
        vm.prank(admin);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(VaultV2.VaultPaused.selector);
        vault.deposit(100_000_000);

        vm.prank(admin);
        vault.unpause();

        vm.prank(alice);
        vault.deposit(100_000_000); // should work now
        assertEq(vault.balances(alice), 100_000_000);
    }

    // ============================================================
    // releaseForRedeemWithFee
    // ============================================================

    function test_releaseForRedeemWithFee_accounting() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        // Lock into splitReserve
        vm.prank(exchange);
        vault.lockForSplit(alice, 50_000_000);

        uint256 payout = 30_000_000;
        uint256 fee = 75_000; // 0.25% of 30M

        uint256 splitBefore = vault.splitReserve();
        uint256 feeBefore = vault.feePool();
        uint256 bobBalBefore = vault.balances(bob);

        vm.prank(shareToken);
        vault.releaseForRedeemWithFee(bob, payout, fee);

        assertEq(vault.splitReserve(), splitBefore - payout, "splitReserve should decrease by payout");
        assertEq(vault.feePool(), feeBefore + fee, "feePool should increase by fee");
        assertEq(vault.balances(bob), bobBalBefore + payout - fee, "bob should receive net payout");

        // Invariant: USDC == totalBalances + splitReserve + feePool
        uint256 usdcBal = usdc.balanceOf(address(vault));
        uint256 accounting = vault.totalBalances() + vault.splitReserve() + vault.feePool();
        assertEq(usdcBal, accounting, "invariant should hold after releaseForRedeemWithFee");
    }

    function test_releaseForRedeemWithFee_feeExceedsPayout_reverts() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(exchange);
        vault.lockForSplit(alice, 50_000_000);

        // fee >= payout should revert
        vm.prank(shareToken);
        vm.expectRevert("fee >= payout");
        vault.releaseForRedeemWithFee(bob, 1000, 1000);
    }

    function test_releaseForRedeemWithFee_onlyShareToken() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(exchange);
        vault.lockForSplit(alice, 50_000_000);

        // Non-shareToken should revert
        vm.prank(alice);
        vm.expectRevert();
        vault.releaseForRedeemWithFee(bob, 10_000_000, 25_000);
    }

    // ============================================================
    // withdrawFeePoolByShareToken
    // ============================================================

    function test_withdrawFeePoolByShareToken() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        // Accumulate fee via exchange
        vm.prank(exchange);
        vault.accumulateFee(alice, 5_000_000);

        uint256 feeBefore = vault.feePool();
        uint256 bobBalBefore = vault.balances(bob);

        vm.prank(shareToken);
        vault.withdrawFeePoolByShareToken(bob, 3_000_000);

        assertEq(vault.feePool(), feeBefore - 3_000_000, "feePool should decrease");
        assertEq(vault.balances(bob), bobBalBefore + 3_000_000, "bob should receive withdrawal");
    }

    function test_withdrawFeePoolByShareToken_insufficientFeePool() public {
        // No fees accumulated — should revert
        vm.prank(shareToken);
        vm.expectRevert();
        vault.withdrawFeePoolByShareToken(bob, 1_000_000);
    }

    // ============================================================
    // Invariant
    // ============================================================

    function test_invariant_holds() public {
        vm.prank(alice);
        vault.deposit(100_000_000);

        vm.prank(exchange);
        vault.lockForSplit(alice, 30_000_000);

        vm.prank(exchange);
        vault.accumulateFee(alice, 5_000_000);

        // USDC.balanceOf(vault) >= totalBalances + splitReserve + feePool
        uint256 usdcBal = usdc.balanceOf(address(vault));
        uint256 accounting = vault.totalBalances() + vault.splitReserve() + vault.feePool();
        assertEq(usdcBal, accounting, "invariant: USDC should exactly match accounting");
    }
}
