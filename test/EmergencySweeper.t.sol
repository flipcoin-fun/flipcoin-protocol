// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EmergencySweeper, IVaultV2} from "../contracts/v2/EmergencySweeper.sol";

/**
 * @title MockVault
 * @notice Minimal mock implementing the `releaseForRedeem` surface used by EmergencySweeper.
 *         Tracks calls so tests can assert relay behavior without a full VaultV2 wiring.
 */
contract MockVault is IVaultV2 {
    address public lastTo;
    uint256 public lastAmount;
    uint256 public callCount;
    uint256 public totalReleased;

    function releaseForRedeem(address to, uint256 amount) external override {
        lastTo = to;
        lastAmount = amount;
        callCount += 1;
        totalReleased += amount;
    }
}

/**
 * @title EmergencySweeperTest
 * @notice Minimal regression coverage for the deprecated EmergencySweeper relay.
 *         Verifies owner-only access, the immutable cap enforcement, and that
 *         a single happy-path `rescueBatch` proxies through to the vault.
 */
contract EmergencySweeperTest is Test {
    EmergencySweeper internal sweeper;
    MockVault internal vault;

    address internal constant OWNER = address(0xABCD);
    address internal constant TREASURY = address(0xBEEF);
    uint256 internal constant CAP = 1_000_000; // 1 USDC (6dp)

    function setUp() public {
        vault = new MockVault();
        sweeper = new EmergencySweeper(OWNER, address(vault), CAP);
    }

    // ── Constructor guards ─────────────────────────────────────────

    function test_constructor_zeroOwner_reverts() public {
        vm.expectRevert(EmergencySweeper.ZeroAddress.selector);
        new EmergencySweeper(address(0), address(vault), CAP);
    }

    function test_constructor_zeroVault_reverts() public {
        vm.expectRevert(EmergencySweeper.ZeroAddress.selector);
        new EmergencySweeper(OWNER, address(0), CAP);
    }

    function test_constructor_zeroCap_reverts() public {
        vm.expectRevert(EmergencySweeper.ZeroAmount.selector);
        new EmergencySweeper(OWNER, address(vault), 0);
    }

    // ── rescue (single) ────────────────────────────────────────────

    function test_rescue_happyPath_proxiesToVault() public {
        vm.prank(OWNER);
        sweeper.rescue(TREASURY, 500_000);

        assertEq(vault.callCount(), 1);
        assertEq(vault.lastTo(), TREASURY);
        assertEq(vault.lastAmount(), 500_000);
        assertEq(sweeper.totalRescued(), 500_000);
    }

    function test_rescue_unauthorized_reverts() public {
        vm.expectRevert(EmergencySweeper.NotOwner.selector);
        sweeper.rescue(TREASURY, 100);
    }

    function test_rescue_zeroAmount_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(EmergencySweeper.ZeroAmount.selector);
        sweeper.rescue(TREASURY, 0);
    }

    function test_rescue_zeroRecipient_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(EmergencySweeper.ZeroAddress.selector);
        sweeper.rescue(address(0), 100);
    }

    function test_rescue_exceedsCap_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencySweeper.ExceedsCap.selector, CAP + 1, 0, CAP)
        );
        sweeper.rescue(TREASURY, CAP + 1);
    }

    function test_rescue_cumulativeCap_reverts() public {
        vm.startPrank(OWNER);
        sweeper.rescue(TREASURY, CAP - 100);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencySweeper.ExceedsCap.selector, 200, CAP - 100, CAP)
        );
        sweeper.rescue(TREASURY, 200);
        vm.stopPrank();
    }

    // ── rescueBatch ────────────────────────────────────────────────

    function test_rescueBatch_happyPath() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100_000;
        amounts[1] = 200_000;
        amounts[2] = 300_000;

        vm.prank(OWNER);
        sweeper.rescueBatch(TREASURY, amounts);

        assertEq(vault.callCount(), 3);
        assertEq(vault.totalReleased(), 600_000);
        assertEq(sweeper.totalRescued(), 600_000);
    }

    function test_rescueBatch_unauthorized_reverts() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        vm.expectRevert(EmergencySweeper.NotOwner.selector);
        sweeper.rescueBatch(TREASURY, amounts);
    }

    function test_rescueBatch_emptyArray_reverts() public {
        uint256[] memory amounts = new uint256[](0);
        vm.prank(OWNER);
        vm.expectRevert(EmergencySweeper.ZeroAmount.selector);
        sweeper.rescueBatch(TREASURY, amounts);
    }

    function test_rescueBatch_zeroAmountElement_reverts() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 0;
        vm.prank(OWNER);
        vm.expectRevert(EmergencySweeper.ZeroAmount.selector);
        sweeper.rescueBatch(TREASURY, amounts);
    }

    function test_rescueBatch_capEnforcedAcrossElements() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = CAP - 100;
        amounts[1] = 200; // would exceed cap
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(EmergencySweeper.ExceedsCap.selector, 200, CAP - 100, CAP)
        );
        sweeper.rescueBatch(TREASURY, amounts);
    }
}
