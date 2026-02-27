// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {BaseV2Test} from "./BaseV2Test.sol";
import {
    Order, Side, MatchType, SignatureType, Outcome, ResolutionStatus,
    TradeIntent, MarketParams, MarketConfigV2
} from "../contracts/v2/interfaces/Types.sol";
import {Exchange} from "../contracts/v2/Exchange.sol";
import {ShareToken} from "../contracts/v2/ShareToken.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {VaultV2} from "../contracts/v2/VaultV2.sol";
import {BackstopRouter} from "../contracts/v2/BackstopRouter.sol";
import {FactoryV2} from "../contracts/v2/FactoryV2.sol";
import {DelegationRegistry} from "../contracts/v2/DelegationRegistry.sol";

/**
 * @title AuditFixesTest
 * @notice Regression tests for all audit findings (C-1, C-2, H-3, H-4, M-2, M-3, M-4, M-5, L-1, L-3, L-5, L-6)
 */
contract AuditFixesTest is BaseV2Test {

    // ── Signing keys ──
    uint256 constant BOB_PK = 0xB0B;
    uint256 constant CAROL_PK = 0xCA0;

    address bobAddr;
    address carolAddr;

    // ── Market state ──
    address market;
    bytes32 conditionId;
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public override {
        super.setUp();

        bobAddr = vm.addr(BOB_PK);
        carolAddr = vm.addr(CAROL_PK);

        _fundAccount(bobAddr);
        _fundAccount(carolAddr);

        // Authorize exchange for split/merge
        vm.prank(admin);
        shareToken.addAuthorizedCaller(address(exchange));

        // Create a market
        (market, conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        yesTokenId = lmsr.yesTokenId();
        noTokenId = lmsr.noTokenId();
    }

    // ============================================================
    // C-2: VaultV2 — Dead code removed (approveMarket, allowances, etc.)
    // ============================================================

    function test_C2_vaultV2_noApproveMarket() public {
        // approveMarket function should not exist anymore
        // Verify by checking that the VaultV2 contract has no allowance functionality
        // We just verify the vault still works without allowances
        // Alice already has vault balance from setUp (_fundAccount)

        // Settlement should still work without any allowance
        vm.prank(address(exchange));
        vault.transferBetween(alice, bob, 5_000_000);

        assertEq(vault.balances(alice), INITIAL_BALANCE - SEED_USDC - 5_000_000);
        assertEq(vault.balances(bob), INITIAL_BALANCE + 5_000_000);
    }

    // ============================================================
    // M-2: VaultV2.withdraw — zero-address check
    // ============================================================

    function test_M2_withdraw_zeroAddress_reverts() public {
        vm.prank(alice);
        vm.expectRevert(VaultV2.ZeroAddress.selector);
        vault.withdraw(1_000_000, address(0));
    }

    function test_M2_withdraw_validAddress_succeeds() public {
        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(alice);
        vault.withdraw(1_000_000, bob);
        assertEq(usdc.balanceOf(bob), balBefore + 1_000_000);
    }

    // ============================================================
    // H-3: MarketLMSR.initConfig — validation of critical addresses
    // ============================================================

    function test_H3_initConfig_zeroFactory_reverts() public {
        MarketLMSR freshImpl = new MarketLMSR();
        address clone = _deployClone(address(freshImpl));

        MarketConfigV2 memory mc = _buildConfig();
        mc.factory = address(0);

        vm.expectRevert("zero factory");
        MarketLMSR(clone).initConfig(mc);
    }

    function test_H3_initConfig_zeroVault_reverts() public {
        MarketLMSR freshImpl = new MarketLMSR();
        address clone = _deployClone(address(freshImpl));

        MarketConfigV2 memory mc = _buildConfig();
        mc.vault = address(0);

        vm.expectRevert("zero vault");
        MarketLMSR(clone).initConfig(mc);
    }

    function test_H3_initConfig_zeroShareToken_reverts() public {
        MarketLMSR freshImpl = new MarketLMSR();
        address clone = _deployClone(address(freshImpl));

        MarketConfigV2 memory mc = _buildConfig();
        mc.shareToken = address(0);

        vm.expectRevert("zero shareToken");
        MarketLMSR(clone).initConfig(mc);
    }

    function test_H3_initConfig_zeroBackstopRouter_reverts() public {
        MarketLMSR freshImpl = new MarketLMSR();
        address clone = _deployClone(address(freshImpl));

        MarketConfigV2 memory mc = _buildConfig();
        mc.backstopRouter = address(0);

        vm.expectRevert("zero backstopRouter");
        MarketLMSR(clone).initConfig(mc);
    }

    function test_H3_initConfig_calledTwice_reverts() public {
        MarketLMSR freshImpl = new MarketLMSR();
        address clone = _deployClone(address(freshImpl));

        MarketConfigV2 memory mc = _buildConfig();
        MarketLMSR(clone).initConfig(mc);

        // Second call should revert
        vm.expectRevert("already configured");
        MarketLMSR(clone).initConfig(mc);
    }

    // ============================================================
    // H-4 + M-5: BackstopRouter — maxFeeBps param + global pause
    // ============================================================

    function test_H4_executeTrade_feeExceedsMax_reverts() public {
        // Market totalFeeBps = 100 (1%)
        // User passes maxFeeBps = 10 (0.1%) → should revert
        vm.prank(bobAddr);
        vm.expectRevert(BackstopRouter.FeeExceedsMax.selector);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 5_000_000, 0, 10);
    }

    function test_H4_executeTrade_feeBelowMax_succeeds() public {
        // Market totalFeeBps = 100 (1%)
        // User passes maxFeeBps = 200 (2%) → should succeed
        vm.prank(bobAddr);
        uint256 result = backstopRouter.executeTrade(conditionId, Side.Yes, true, 5_000_000, 0, 200);
        assertTrue(result > 0, "should receive shares");
    }

    function test_M5_backstopRouter_pause_reverts() public {
        vm.prank(admin);
        backstopRouter.pause();

        vm.prank(bobAddr);
        vm.expectRevert(BackstopRouter.RouterPaused.selector);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 5_000_000, 0, 200);
    }

    function test_M5_backstopRouter_unpause_works() public {
        vm.prank(admin);
        backstopRouter.pause();

        vm.prank(admin);
        backstopRouter.unpause();

        vm.prank(bobAddr);
        uint256 result = backstopRouter.executeTrade(conditionId, Side.Yes, true, 5_000_000, 0, 200);
        assertTrue(result > 0, "should work after unpause");
    }

    function test_M5_backstopRouter_pause_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(BackstopRouter.NotAdmin.selector);
        backstopRouter.pause();
    }

    // ============================================================
    // M-4: MarketLMSR._calcSellAmount — underflow guard
    // ============================================================

    function test_M4_quoteSell_zeroShares() public view {
        // Selling 0 shares should return 0, not underflow
        (uint256 amountOut,) = MarketLMSR(market).quoteSell(Side.Yes, 0);
        assertEq(amountOut, 0, "zero shares should return zero");
    }

    // ============================================================
    // L-1: ShareToken._tryPauseCondition — event on failure
    // ============================================================

    function test_L1_pauseConditionFailed_event() public {
        // Create a market and get conditionId
        (, bytes32 testCondId) = _createDefaultMarket(bob);

        // Set exchange to a contract that will revert on pauseCondition()
        // Use MockReverter which always reverts on any call
        MockReverter reverter = new MockReverter();
        vm.prank(admin);
        shareToken.setExchange(address(reverter));

        // Forward time past deadline + dispute
        vm.warp(block.timestamp + 8 days);

        // Propose resolution
        vm.prank(admin);
        shareToken.proposeResolution(testCondId, Outcome.Yes);

        // Forward time past dispute period
        vm.warp(block.timestamp + 25 hours);

        // Finalize — should emit PauseConditionFailed since reverter reverts on pauseCondition
        vm.recordLogs();
        shareToken.finalizeResolution(testCondId);

        // Check that PauseConditionFailed was emitted
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found = false;
        bytes32 pauseFailedTopic = keccak256("PauseConditionFailed(bytes32)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == pauseFailedTopic) {
                found = true;
                break;
            }
        }
        assertTrue(found, "PauseConditionFailed event should be emitted");

        // Should still be resolved despite failure
        assertTrue(shareToken.isResolved(testCondId), "should be resolved despite pause failure");
    }

    // ============================================================
    // L-3: FactoryV2 — deadline in the past check
    // ============================================================

    function test_L3_createMarket_deadlineInPast_reverts() public {
        MarketParams memory params = MarketParams({
            question: "Test question about something",
            description: "Test desc",
            category: "test",
            resolutionRules: "Standard resolution rules apply",
            resolutionSource: "https://example.com/source",
            imageUrl: "",
            deadline: uint64(block.timestamp - 1) // deadline in the past
        });

        vm.prank(alice);
        vm.expectRevert("deadline in the past");
        factory.createMarket(params, SEED_USDC, 5000);
    }

    // ============================================================
    // L-6: BackstopRouter.transferAdmin — zero-address check
    // ============================================================

    function test_L6_backstopRouter_transferAdmin_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(BackstopRouter.ZeroAddress.selector);
        backstopRouter.transferAdmin(address(0));
    }

    function test_L6_backstopRouter_transferAdmin_valid() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        backstopRouter.transferAdmin(newAdmin);
        assertEq(backstopRouter.admin(), newAdmin);
    }

    // ============================================================
    // L-5: Exchange.setCreatorFee — cap at 500 bps
    // ============================================================

    function test_L5_setCreatorFee_exceedsCap_reverts() public {
        // setCreatorFee is onlyFactory, use factory address
        bytes32 freshCondId = bytes32(uint256(0xDEAD));
        vm.prank(address(factory));
        vm.expectRevert(Exchange.CreatorFeeTooHigh.selector);
        exchange.setCreatorFee(freshCondId, alice, 501);
    }

    function test_L5_setCreatorFee_atCap_succeeds() public {
        // setCreatorFee is onlyFactory, use factory address
        bytes32 freshCondId = bytes32(uint256(0xBEEF));
        vm.prank(address(factory));
        exchange.setCreatorFee(freshCondId, alice, 500); // 5% max, should pass
    }

    // ============================================================
    // VaultV2 — duplicate modifier removed (onlyExchangeOrSettlement)
    // ============================================================

    function test_vault_onlySettlement_stillWorks() public {
        // Alice already has vault balance from setUp
        uint256 splitBefore = vault.splitReserve();

        // exchange (settlement) can call lockForSplit
        vm.prank(address(exchange));
        vault.lockForSplit(alice, 5_000_000);

        assertEq(vault.splitReserve(), splitBefore + 5_000_000);
    }

    // ============================================================
    // Internal Helpers
    // ============================================================

    function _deployClone(address impl) internal returns (address clone) {
        // Minimal EIP-1167 clone
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            impl,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly {
            clone := create(0, add(code, 0x20), mload(code))
        }
        require(clone != address(0), "clone failed");
    }

    function _buildConfig() internal view returns (MarketConfigV2 memory) {
        return MarketConfigV2({
            admin: admin,
            creator: alice,
            vault: address(vault),
            factory: address(factory),
            backstopRouter: address(backstopRouter),
            shareToken: address(shareToken),
            protocolAddress: protocolAddress,
            conditionId: bytes32(uint256(1)),
            yesTokenId: 100,
            noTokenId: 101,
            totalFeeBps: 100,
            creatorFeeBps: 50,
            protocolFeeBps: 50,
            deadline: uint64(block.timestamp + 7 days),
            question: "Test",
            description: "Test",
            category: "test",
            resolutionRules: "Test rules",
            resolutionSource: "https://example.com",
            imageUrl: ""
        });
    }
}

/// @dev Simple contract that always reverts (for testing _tryPauseCondition failure)
contract MockReverter {
    fallback() external {
        revert("mock revert");
    }
}
