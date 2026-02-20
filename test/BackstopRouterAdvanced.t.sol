// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BaseV2Test} from "./BaseV2Test.sol";
import {
    Side, TradeIntent, Delegation
} from "../contracts/v2/interfaces/Types.sol";
import {ShareToken} from "../contracts/v2/ShareToken.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {BackstopRouter} from "../contracts/v2/BackstopRouter.sol";
import {VaultV2} from "../contracts/v2/VaultV2.sol";
import {DelegationRegistry} from "../contracts/v2/DelegationRegistry.sol";

/**
 * @title BackstopRouterAdvancedTest
 * @notice Advanced tests: minOut slippage protection, admin functions,
 *         delegation expiry edge cases, multi-trade stress.
 */
contract BackstopRouterAdvancedTest is BaseV2Test {
    uint256 constant BOB_PK = 0xB0B;
    uint256 constant SESSION_PK = 0x5E55;

    address bobAddr;
    address sessionKey;

    address market;
    bytes32 conditionId;

    function setUp() public override {
        super.setUp();
        bobAddr = vm.addr(BOB_PK);
        sessionKey = vm.addr(SESSION_PK);
        _fundAccount(bobAddr);
        _fundAccount(sessionKey);
    }

    function _setupMarket() internal {
        (market, conditionId) = _createDefaultMarket(alice);
    }

    function _signIntent(TradeIntent memory intent, uint256 pk) internal view returns (bytes memory) {
        bytes32 intentHash = _hashTradeIntent(intent);
        bytes32 digest = _hashTypedDataV4BackstopRouter(intentHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashTradeIntent(TradeIntent memory intent) internal view returns (bytes32) {
        return keccak256(abi.encode(
            backstopRouter.TRADE_INTENT_TYPEHASH(),
            intent.trader, intent.signer, intent.conditionId,
            uint8(intent.side), intent.isBuy, intent.amount, intent.minOut,
            intent.deadline, intent.nonce, intent.maxFeeBps
        ));
    }

    function _hashTypedDataV4BackstopRouter(bytes32 structHash) internal view returns (bytes32) {
        bytes32 ds = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("FlipCoinBackstopRouter"),
            keccak256("1"),
            block.chainid,
            address(backstopRouter)
        ));
        return keccak256(abi.encodePacked("\x19\x01", ds, structHash));
    }

    // ============================================================
    // 1. minOut Slippage — Direct Trade Buy
    // ============================================================

    function test_minOut_directBuy_enforced() public {
        _setupMarket();

        uint256 buyAmount = 10_000_000;

        // Quote first to know expected shares
        (uint256 expectedShares,) = backstopRouter.quoteBuy(conditionId, Side.Yes, buyAmount);

        // Set minOut higher than what we'd receive → should revert
        vm.prank(bobAddr);
        vm.expectRevert(MarketLMSR.SlippageExceeded.selector);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, buyAmount, expectedShares + 1);
    }

    function test_minOut_directBuy_exactBoundary_passes() public {
        _setupMarket();

        uint256 buyAmount = 10_000_000;
        (uint256 expectedShares,) = backstopRouter.quoteBuy(conditionId, Side.Yes, buyAmount);

        // minOut == actual → should succeed
        vm.prank(bobAddr);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, buyAmount, expectedShares);
        assertEq(sharesOut, expectedShares, "exact minOut should pass");
    }

    // ============================================================
    // 2. minOut Slippage — Direct Trade Sell
    // ============================================================

    function test_minOut_directSell_enforced() public {
        _setupMarket();

        // Buy first
        vm.prank(bobAddr);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0);

        vm.prank(bobAddr);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        // Quote the sell
        (uint256 expectedUsdc,) = backstopRouter.quoteSell(conditionId, Side.Yes, sharesOut);

        // minOut too high → revert
        vm.prank(bobAddr);
        vm.expectRevert(MarketLMSR.SlippageExceeded.selector);
        backstopRouter.executeTrade(conditionId, Side.Yes, false, sharesOut, expectedUsdc + 1);
    }

    function test_minOut_directSell_exactBoundary_passes() public {
        _setupMarket();

        vm.prank(bobAddr);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0);

        vm.prank(bobAddr);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        (uint256 expectedUsdc,) = backstopRouter.quoteSell(conditionId, Side.Yes, sharesOut);

        vm.prank(bobAddr);
        uint256 usdcOut = backstopRouter.executeTrade(conditionId, Side.Yes, false, sharesOut, expectedUsdc);
        assertEq(usdcOut, expectedUsdc, "exact minOut sell should pass");
    }

    // ============================================================
    // 3. minOut Slippage — Gasless Intent Buy
    // ============================================================

    function test_minOut_gaslessIntent_buy_enforced() public {
        _setupMarket();

        uint256 buyAmount = 5_000_000;
        (uint256 expectedShares,) = backstopRouter.quoteBuy(conditionId, Side.Yes, buyAmount);

        TradeIntent memory intent = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: buyAmount,
            minOut: expectedShares + 1, // too high
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(bobAddr),
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, BOB_PK);

        vm.prank(relayer);
        vm.expectRevert(MarketLMSR.SlippageExceeded.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 4. minOut Slippage — Gasless Intent Sell
    // ============================================================

    function test_minOut_gaslessIntent_sell_enforced() public {
        _setupMarket();

        // Buy first
        vm.prank(bobAddr);
        uint256 sharesOut = backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0);

        vm.prank(bobAddr);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        (uint256 expectedUsdc,) = backstopRouter.quoteSell(conditionId, Side.Yes, sharesOut);

        TradeIntent memory intent = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: false,
            amount: sharesOut,
            minOut: expectedUsdc + 1, // too high
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(bobAddr),
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, BOB_PK);

        vm.prank(relayer);
        vm.expectRevert(MarketLMSR.SlippageExceeded.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 5. Admin — setFactory
    // ============================================================

    function test_setFactory_onlyAdmin() public {
        vm.prank(bobAddr);
        vm.expectRevert(BackstopRouter.NotAdmin.selector);
        backstopRouter.setFactory(bobAddr);

        vm.prank(admin);
        backstopRouter.setFactory(bobAddr);
        assertEq(backstopRouter.factory(), bobAddr, "factory should be updated");
    }

    // ============================================================
    // 6. Admin — transferAdmin
    // ============================================================

    function test_transferAdmin_backstopRouter() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(bobAddr);
        vm.expectRevert(BackstopRouter.NotAdmin.selector);
        backstopRouter.transferAdmin(newAdmin);

        vm.prank(admin);
        backstopRouter.transferAdmin(newAdmin);
        assertEq(backstopRouter.admin(), newAdmin, "admin should be transferred");

        // Old admin cannot act
        vm.prank(admin);
        vm.expectRevert(BackstopRouter.NotAdmin.selector);
        backstopRouter.setFactory(address(0));
    }

    // ============================================================
    // 7. Delegation Expiry Edge Case
    // ============================================================

    function test_delegationExpired_beforeExecute_reverts() public {
        _setupMarket();

        // Alice delegates to sessionKey with 1 hour expiry
        uint64 expiryTime = uint64(block.timestamp + 1 hours);
        vm.prank(alice);
        delegationRegistry.setDelegation(
            sessionKey,
            address(backstopRouter),
            0, // unlimited daily
            expiryTime
        );

        uint256 currentNonce = backstopRouter.nonces(sessionKey);

        // Warp just 1 second past delegation expiry
        uint256 postExpiryTime = uint256(expiryTime) + 1;
        vm.warp(postExpiryTime);

        // Intent deadline must be in the future from the warped time
        uint256 intentDeadline = postExpiryTime + 1 hours;

        TradeIntent memory intent = TradeIntent({
            trader: alice,
            signer: sessionKey,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: intentDeadline,
            nonce: currentNonce,
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, SESSION_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.NotDelegated.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 8. Multi-Trade Sequential — Vault Invariant
    // ============================================================

    function test_multiTrade_sequential_vaultInvariant() public {
        _setupMarket();

        // 5 sequential buy trades
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bobAddr);
            backstopRouter.executeTrade(conditionId, Side.Yes, true, 2_000_000, 0);
        }

        // 5 sequential buy NO
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bobAddr);
            backstopRouter.executeTrade(conditionId, Side.No, true, 2_000_000, 0);
        }

        // Sell some YES shares
        vm.prank(bobAddr);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        uint256 yesId = MarketLMSR(market).yesTokenId();
        uint256 yesBal = shareToken.balanceOf(bobAddr, yesId);
        if (yesBal > 1_000_000) {
            vm.prank(bobAddr);
            backstopRouter.executeTrade(conditionId, Side.Yes, false, 1_000_000, 0);
        }

        assertTrue(vault.checkInvariant(), "vault invariant must hold after multi-trade sequence");
    }

    // ============================================================
    // 9. RegisterBackstop — Only Factory
    // ============================================================

    function test_registerBackstop_onlyFactory() public {
        vm.prank(bobAddr);
        vm.expectRevert("not factory");
        backstopRouter.registerBackstop(keccak256("test"), address(1));
    }

    // ============================================================
    // 10. Zero Amount Direct Trade
    // ============================================================

    function test_directTrade_zeroAmount() public {
        _setupMarket();

        // Zero amount buy — MarketLMSR should handle this
        vm.prank(bobAddr);
        vm.expectRevert(); // zero trade should revert somewhere in the stack
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 0, 0);
    }
}
