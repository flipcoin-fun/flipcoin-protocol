// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {VaultV2} from "../contracts/v2/VaultV2.sol";
import {LmsrFeeCollector} from "../contracts/v2/LmsrFeeCollector.sol";

contract LmsrFeeCollectorTest is Test {
    MockUSDC public usdc;
    VaultV2 public vault;
    LmsrFeeCollector public collector;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public market = makeAddr("market");

    function setUp() public {
        usdc = new MockUSDC();

        vm.prank(admin);
        vault = new VaultV2(address(usdc), admin);

        vm.prank(admin);
        collector = new LmsrFeeCollector(address(vault), admin);

        // Whitelist the collector as a settlement contract on VaultV2
        vm.startPrank(admin);
        vault.addWhitelistedMarket(address(collector));
        // Also whitelist a mock market to simulate fee accumulation
        vault.addWhitelistedMarket(market);
        vm.stopPrank();

        // Fund alice → deposit → market accumulates fee (simulating LMSR flow)
        usdc.mint(alice, 1_000_000_000); // 1000 USDC
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============================================================
    // Helper: simulate LMSR fee accumulation
    // ============================================================

    function _simulateLmsrFees(uint256 amount) internal {
        // Alice deposits
        vm.prank(alice);
        vault.deposit(amount);

        // Market takes fee from alice's balance → feePool
        vm.prank(market);
        vault.accumulateFee(alice, amount);
    }

    // ============================================================
    // Constructor
    // ============================================================

    function test_constructor() public view {
        assertEq(address(collector.vault()), address(vault));
        assertEq(collector.admin(), admin);
    }

    function test_constructor_zeroVault_reverts() public {
        vm.expectRevert("zero vault");
        new LmsrFeeCollector(address(0), admin);
    }

    function test_constructor_zeroAdmin_reverts() public {
        vm.expectRevert("zero admin");
        new LmsrFeeCollector(address(vault), address(0));
    }

    // ============================================================
    // Withdraw — happy path
    // ============================================================

    function test_withdraw_movesFromFeePoolToBalance() public {
        _simulateLmsrFees(100_000_000); // 100 USDC in feePool

        assertEq(vault.feePool(), 100_000_000);
        assertEq(vault.balances(treasury), 0);

        vm.prank(admin);
        collector.withdraw(treasury, 100_000_000);

        assertEq(vault.feePool(), 0);
        assertEq(vault.balances(treasury), 100_000_000);
    }

    function test_withdraw_partialAmount() public {
        _simulateLmsrFees(100_000_000);

        vm.prank(admin);
        collector.withdraw(treasury, 40_000_000);

        assertEq(vault.feePool(), 60_000_000);
        assertEq(vault.balances(treasury), 40_000_000);
    }

    function test_withdraw_emitsEvent() public {
        _simulateLmsrFees(50_000_000);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit LmsrFeeCollector.FeeWithdrawn(treasury, 50_000_000);
        collector.withdraw(treasury, 50_000_000);
    }

    function test_withdraw_treasuryCanWithdrawToWallet() public {
        _simulateLmsrFees(100_000_000);

        // Step 1: admin claims fees to treasury's vault balance
        vm.prank(admin);
        collector.withdraw(treasury, 100_000_000);

        // Step 2: treasury withdraws from vault to their wallet
        vm.prank(treasury);
        vault.withdraw(100_000_000, treasury);

        assertEq(usdc.balanceOf(treasury), 100_000_000);
        assertEq(vault.balances(treasury), 0);
    }

    // ============================================================
    // Withdraw — access control
    // ============================================================

    function test_withdraw_onlyAdmin() public {
        _simulateLmsrFees(100_000_000);

        vm.prank(alice);
        vm.expectRevert(LmsrFeeCollector.NotAdmin.selector);
        collector.withdraw(treasury, 100_000_000);
    }

    function test_withdraw_zeroAmount_reverts() public {
        vm.prank(admin);
        vm.expectRevert(LmsrFeeCollector.ZeroAmount.selector);
        collector.withdraw(treasury, 0);
    }

    function test_withdraw_zeroAddress_reverts() public {
        _simulateLmsrFees(100_000_000);

        vm.prank(admin);
        vm.expectRevert(LmsrFeeCollector.ZeroAddress.selector);
        collector.withdraw(address(0), 100_000_000);
    }

    function test_withdraw_exceedsFeePool_reverts() public {
        _simulateLmsrFees(50_000_000);

        vm.prank(admin);
        vm.expectRevert(VaultV2.InsufficientFeePool.selector);
        collector.withdraw(treasury, 100_000_000);
    }

    // ============================================================
    // Withdraw — not whitelisted
    // ============================================================

    function test_withdraw_notWhitelisted_reverts() public {
        // Deploy a new collector that is NOT whitelisted
        vm.prank(admin);
        LmsrFeeCollector rogue = new LmsrFeeCollector(address(vault), admin);
        // Do NOT whitelist it

        _simulateLmsrFees(100_000_000);

        vm.prank(admin);
        vm.expectRevert(VaultV2.NotAuthorized.selector);
        rogue.withdraw(treasury, 100_000_000);
    }

    // ============================================================
    // Withdraw — vault invariant preserved
    // ============================================================

    function test_withdraw_preservesInvariant() public {
        _simulateLmsrFees(100_000_000);

        assertTrue(vault.checkInvariant());

        vm.prank(admin);
        collector.withdraw(treasury, 100_000_000);

        assertTrue(vault.checkInvariant());
    }

    // ============================================================
    // Admin transfer
    // ============================================================

    function test_transferAdmin() public {
        vm.prank(admin);
        collector.transferAdmin(alice);

        assertEq(collector.admin(), alice);
    }

    function test_transferAdmin_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(LmsrFeeCollector.NotAdmin.selector);
        collector.transferAdmin(alice);
    }

    function test_transferAdmin_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert("zero admin");
        collector.transferAdmin(address(0));
    }

    function test_transferAdmin_newAdminCanWithdraw() public {
        _simulateLmsrFees(100_000_000);

        vm.prank(admin);
        collector.transferAdmin(alice);

        vm.prank(alice);
        collector.withdraw(treasury, 100_000_000);

        assertEq(vault.balances(treasury), 100_000_000);
    }

    // ============================================================
    // Reversibility — removeWhitelistedMarket
    // ============================================================

    function test_removeWhitelist_blocksWithdraw() public {
        _simulateLmsrFees(100_000_000);

        // Remove collector from whitelist
        vm.prank(admin);
        vault.removeWhitelistedMarket(address(collector));

        // Withdraw should now revert
        vm.prank(admin);
        vm.expectRevert(VaultV2.NotAuthorized.selector);
        collector.withdraw(treasury, 100_000_000);
    }
}
