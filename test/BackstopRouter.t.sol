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
 * @title BackstopRouterTest
 * @notice Comprehensive tests for BackstopRouter: direct trades, gasless intents,
 *         fee ceilings, delegation, nonce management, replay protection, cancellation.
 */
contract BackstopRouterTest is BaseV2Test {

    // ── Deterministic private keys for signing ──
    uint256 constant BOB_PK = 0xB0B;
    uint256 constant SESSION_PK = 0x5E55;
    uint256 constant RANDOM_PK = 0xBAD;

    address bobAddr;
    address sessionKey;
    address randomAddr;

    // ── Market state (set per test via _setupMarket) ──
    address market;
    bytes32 conditionId;

    function setUp() public override {
        super.setUp();

        // Derive addresses from private keys
        bobAddr = vm.addr(BOB_PK);
        sessionKey = vm.addr(SESSION_PK);
        randomAddr = vm.addr(RANDOM_PK);

        // Fund the PK-based accounts
        _fundAccount(bobAddr);
        _fundAccount(sessionKey);
        _fundAccount(randomAddr);
    }

    // ============================================================
    // Internal Helpers
    // ============================================================

    /// @dev Create a default 50/50 market and store in contract state
    function _setupMarket() internal {
        (market, conditionId) = _createDefaultMarket(alice);
    }

    /// @dev Build a standard buy intent for bobAddr (self-signed)
    function _buildBobBuyIntent(uint256 amount, uint256 maxFee) internal view returns (TradeIntent memory) {
        return TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: amount,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(bobAddr),
            maxFeeBps: maxFee
        });
    }

    /// @dev Sign an intent with the given private key
    function _signIntent(TradeIntent memory intent, uint256 pk) internal view returns (bytes memory) {
        bytes32 intentHash = _hashTradeIntent(intent);
        bytes32 digest = _hashTypedDataV4BackstopRouter(intentHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Hash a TradeIntent struct (mirrors BackstopRouter._hashIntent)
    function _hashTradeIntent(TradeIntent memory intent) internal view returns (bytes32) {
        return keccak256(abi.encode(
            backstopRouter.TRADE_INTENT_TYPEHASH(),
            intent.trader,
            intent.signer,
            intent.conditionId,
            uint8(intent.side),
            intent.isBuy,
            intent.amount,
            intent.minOut,
            intent.deadline,
            intent.nonce,
            intent.maxFeeBps
        ));
    }

    /// @dev Rebuild EIP-712 domain separator and produce the final digest
    function _hashTypedDataV4BackstopRouter(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("FlipCoinBackstopRouter"),
            keccak256("1"),
            block.chainid,
            address(backstopRouter)
        ));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // ============================================================
    // 1. Fee Ceiling — Revert
    // ============================================================

    function test_feeCeilingRevert_maxFeeBpsTooLow() public {
        _setupMarket();

        // Market totalFeeBps = 100 (1%). Intent maxFeeBps = 50 (0.5%) → should revert.
        TradeIntent memory intent = _buildBobBuyIntent(5_000_000, 50);
        bytes memory sig = _signIntent(intent, BOB_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.FeeExceedsMax.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 2. Fee Ceiling — Pass
    // ============================================================

    function test_feeCeilingPass_maxFeeBpsSufficient() public {
        _setupMarket();

        // Market totalFeeBps = 100 (1%). Intent maxFeeBps = 200 (2%) → should succeed.
        TradeIntent memory intent = _buildBobBuyIntent(5_000_000, 200);
        bytes memory sig = _signIntent(intent, BOB_PK);

        vm.prank(relayer);
        uint256 sharesOut = backstopRouter.executeTradeIntent(intent, sig);

        assertTrue(sharesOut > 0, "trade should succeed with sufficient maxFeeBps");
    }

    // ============================================================
    // 3. Delegation Spend Limit — Revert
    // ============================================================

    function test_delegationSpendLimit_exceededReverts() public {
        _setupMarket();

        // Alice delegates to sessionKey with 5 USDC daily limit
        vm.prank(alice);
        delegationRegistry.setDelegation(
            sessionKey,
            address(backstopRouter),
            5_000_000, // 5 USDC max per day
            0          // no expiry
        );

        // sessionKey signs intent for 10 USDC on behalf of alice → exceeds 5 USDC limit
        TradeIntent memory intent = TradeIntent({
            trader: alice,
            signer: sessionKey,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 10_000_000, // 10 USDC
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(sessionKey),
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, SESSION_PK);

        vm.prank(relayer);
        vm.expectRevert(DelegationRegistry.DailyLimitExceeded.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 4. Delegation Spend Recording
    // ============================================================

    function test_delegationSpendRecording_afterSuccessfulTrade() public {
        _setupMarket();

        // Alice delegates to sessionKey with 50 USDC daily limit
        vm.prank(alice);
        delegationRegistry.setDelegation(
            sessionKey,
            address(backstopRouter),
            50_000_000, // 50 USDC
            0
        );

        uint256 tradeAmount = 5_000_000; // 5 USDC

        TradeIntent memory intent = TradeIntent({
            trader: alice,
            signer: sessionKey,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: tradeAmount,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(sessionKey),
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, SESSION_PK);

        Delegation memory dBefore = delegationRegistry.getDelegation(alice, sessionKey);
        uint256 spentBefore = dBefore.spentToday;

        vm.prank(relayer);
        backstopRouter.executeTradeIntent(intent, sig);

        Delegation memory dAfter = delegationRegistry.getDelegation(alice, sessionKey);
        assertEq(dAfter.spentToday, spentBefore + tradeAmount, "spentToday should increase by trade amount");
    }

    // ============================================================
    // 5. Expired Intent
    // ============================================================

    function test_expiredIntent_reverts() public {
        _setupMarket();

        TradeIntent memory intent = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp - 1, // deadline in the past
            nonce: backstopRouter.nonces(bobAddr),
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, BOB_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.IntentExpired.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 6. Bad Nonce
    // ============================================================

    function test_badNonce_reverts() public {
        _setupMarket();

        // Current nonce for bobAddr is 0. Use nonce = 99 → should revert.
        TradeIntent memory intent = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: 99,
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, BOB_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.BadNonce.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 7. Replay Prevention
    // ============================================================

    function test_replayPrevention_secondExecutionReverts() public {
        _setupMarket();

        TradeIntent memory intent = _buildBobBuyIntent(5_000_000, 10000);
        bytes memory sig = _signIntent(intent, BOB_PK);

        // First execution succeeds
        vm.prank(relayer);
        uint256 sharesOut = backstopRouter.executeTradeIntent(intent, sig);
        assertTrue(sharesOut > 0, "first execution should succeed");

        // Second execution with same intent → IntentAlreadyUsed
        // Note: nonce is now 1, but the intent has nonce=0, so BadNonce fires first.
        // To test pure replay, we need the intent hash to be marked used.
        // Since nonce incremented, BadNonce will revert first — this is correct behavior.
        // The intent hash is also marked used, providing double protection.
        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.BadNonce.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 8. Bad Signature
    // ============================================================

    function test_badSignature_wrongSigner() public {
        _setupMarket();

        TradeIntent memory intent = _buildBobBuyIntent(5_000_000, 10000);

        // Sign with a DIFFERENT private key (not bobAddr's)
        bytes memory sig = _signIntent(intent, RANDOM_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.BadSignature.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    function test_badSignature_tamperedData() public {
        _setupMarket();

        TradeIntent memory intent = _buildBobBuyIntent(5_000_000, 10000);

        // Sign the original intent
        bytes memory sig = _signIntent(intent, BOB_PK);

        // Tamper with the intent after signing (change amount)
        intent.amount = 9_000_000;

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.BadSignature.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 9. Direct Trade — Buy
    // ============================================================

    function test_directTrade_buyYes() public {
        _setupMarket();
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        uint256 buyAmount = 10_000_000; // 10 USDC
        uint256 balBefore = vault.balances(bob);

        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(
            conditionId,
            Side.Yes,
            true,
            buyAmount,
            0
        );

        assertTrue(sharesOut > 0, "should receive shares");
        assertEq(shareToken.balanceOf(bob, yesId), sharesOut, "ERC-1155 balance should match");
        assertEq(balBefore - vault.balances(bob), buyAmount, "USDC deducted should match buyAmount");
    }

    // ============================================================
    // 10. Direct Trade — Sell
    // ============================================================

    function test_directTrade_buyThenSell() public {
        _setupMarket();
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        uint256 buyAmount = 10_000_000; // 10 USDC

        // Bob buys YES shares
        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(
            conditionId, Side.Yes, true, buyAmount, 0
        );
        assertTrue(sharesOut > 0, "should receive shares from buy");

        // Approve BackstopRouter to transfer shares
        vm.prank(bob);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        // Bob sells all YES shares
        uint256 balBefore = vault.balances(bob);

        vm.prank(bob);
        uint256 usdcOut = backstopRouter.executeTrade(
            conditionId, Side.Yes, false, sharesOut, 0
        );

        assertTrue(usdcOut > 0, "should receive USDC from sell");
        assertEq(vault.balances(bob) - balBefore, usdcOut, "USDC credited should match");
        assertEq(shareToken.balanceOf(bob, yesId), 0, "should have 0 shares after sell");
    }

    // ============================================================
    // 11. Cancel Intent Then Execute
    // ============================================================

    function test_cancelIntent_thenExecuteReverts() public {
        _setupMarket();

        TradeIntent memory intent = _buildBobBuyIntent(5_000_000, 10000);

        // Bob cancels the intent
        vm.prank(bobAddr);
        backstopRouter.cancelIntent(intent);

        // Verify the intent hash is marked used
        bytes32 intentHash = _hashTradeIntent(intent);
        assertTrue(backstopRouter.usedIntentHashes(intentHash), "intent hash should be marked used");

        // Try to execute the cancelled intent → IntentAlreadyUsed
        bytes memory sig = _signIntent(intent, BOB_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.IntentAlreadyUsed.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // 12. Only Trader or Signer Can Cancel
    // ============================================================

    function test_cancelIntent_notTraderOrSigner_reverts() public {
        _setupMarket();

        TradeIntent memory intent = _buildBobBuyIntent(5_000_000, 10000);

        // Random address tries to cancel bob's intent
        vm.prank(randomAddr);
        vm.expectRevert(BackstopRouter.NotTraderOrSigner.selector);
        backstopRouter.cancelIntent(intent);
    }

    function test_cancelIntent_traderCanCancel() public {
        _setupMarket();

        // Intent where trader = alice, signer = sessionKey
        vm.prank(alice);
        delegationRegistry.setDelegation(sessionKey, address(backstopRouter), 0, 0);

        TradeIntent memory intent = TradeIntent({
            trader: alice,
            signer: sessionKey,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(sessionKey),
            maxFeeBps: 10000
        });

        // Alice (trader) can cancel even though she is not the signer
        vm.prank(alice);
        backstopRouter.cancelIntent(intent);

        bytes32 intentHash = _hashTradeIntent(intent);
        assertTrue(backstopRouter.usedIntentHashes(intentHash), "intent should be cancelled");
    }

    function test_cancelIntent_signerCanCancel() public {
        _setupMarket();

        // Intent where trader = alice, signer = sessionKey
        vm.prank(alice);
        delegationRegistry.setDelegation(sessionKey, address(backstopRouter), 0, 0);

        TradeIntent memory intent = TradeIntent({
            trader: alice,
            signer: sessionKey,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(sessionKey),
            maxFeeBps: 10000
        });

        // sessionKey (signer) can cancel
        vm.prank(sessionKey);
        backstopRouter.cancelIntent(intent);

        bytes32 intentHash = _hashTradeIntent(intent);
        assertTrue(backstopRouter.usedIntentHashes(intentHash), "intent should be cancelled by signer");
    }

    // ============================================================
    // 13. Nonce Bump
    // ============================================================

    function test_nonceBump_invalidatesOldNonces() public {
        _setupMarket();

        // Bump bobAddr nonce to 5
        vm.prank(bobAddr);
        backstopRouter.bumpNonce(5);
        assertEq(backstopRouter.nonces(bobAddr), 5, "nonce should be 5");

        // Intent with nonce=3 → BadNonce
        TradeIntent memory intentOld = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: 3,
            maxFeeBps: 10000
        });
        bytes memory sigOld = _signIntent(intentOld, BOB_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.BadNonce.selector);
        backstopRouter.executeTradeIntent(intentOld, sigOld);

        // Intent with nonce=5 → should succeed
        TradeIntent memory intentNew = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: 5,
            maxFeeBps: 10000
        });
        bytes memory sigNew = _signIntent(intentNew, BOB_PK);

        vm.prank(relayer);
        uint256 sharesOut = backstopRouter.executeTradeIntent(intentNew, sigNew);
        assertTrue(sharesOut > 0, "intent with correct nonce should succeed");
        assertEq(backstopRouter.nonces(bobAddr), 6, "nonce should increment to 6");
    }

    // ============================================================
    // 14. No Backstop — Unregistered conditionId
    // ============================================================

    function test_noBackstop_unregisteredConditionId() public {
        _setupMarket(); // creates a valid market, but we'll use a fake conditionId

        bytes32 fakeConditionId = keccak256("nonexistent");

        TradeIntent memory intent = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: fakeConditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(bobAddr),
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, BOB_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.NoBackstop.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    function test_noBackstop_directTrade_reverts() public {
        // Don't set up any market — use a fake conditionId
        bytes32 fakeConditionId = keccak256("no-market");

        vm.prank(bob);
        vm.expectRevert(BackstopRouter.NoBackstop.selector);
        backstopRouter.executeTrade(fakeConditionId, Side.Yes, true, 5_000_000, 0);
    }

    // ============================================================
    // 15. Delegation Not Authorized
    // ============================================================

    function test_delegationNotAuthorized_reverts() public {
        _setupMarket();

        // sessionKey signs on behalf of alice, but NO delegation is set
        TradeIntent memory intent = TradeIntent({
            trader: alice,
            signer: sessionKey,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(sessionKey),
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, SESSION_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.NotDelegated.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // Additional edge-case tests
    // ============================================================

    /// @dev Fee ceiling at exact boundary: maxFeeBps == market fee → should pass
    function test_feeCeilingExactBoundary_passes() public {
        _setupMarket();

        // Market totalFeeBps = 100. Intent maxFeeBps = 100 → exact match → should pass
        TradeIntent memory intent = _buildBobBuyIntent(5_000_000, 100);
        bytes memory sig = _signIntent(intent, BOB_PK);

        vm.prank(relayer);
        uint256 sharesOut = backstopRouter.executeTradeIntent(intent, sig);
        assertTrue(sharesOut > 0, "exact fee boundary should pass");
    }

    /// @dev Nonce bump requires strictly greater nonce
    function test_nonceBump_cannotBumpToSameOrLower() public {
        vm.prank(bobAddr);
        vm.expectRevert("nonce not increased");
        backstopRouter.bumpNonce(0);
    }

    /// @dev Direct trade for NO side works
    function test_directTrade_buyNo() public {
        _setupMarket();
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 noId = lmsr.noTokenId();

        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(
            conditionId, Side.No, true, 10_000_000, 0
        );

        assertTrue(sharesOut > 0, "should receive NO shares");
        assertEq(shareToken.balanceOf(bob, noId), sharesOut, "NO token balance should match");
    }

    /// @dev Gasless sell intent via BackstopRouter
    function test_gaslessSellIntent() public {
        _setupMarket();
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        // First: bob buys YES directly
        vm.prank(bobAddr);
        uint256 sharesOut = backstopRouter.executeTrade(
            conditionId, Side.Yes, true, 10_000_000, 0
        );
        assertTrue(sharesOut > 0);

        // Approve BackstopRouter for share transfers
        vm.prank(bobAddr);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        // Build sell intent
        TradeIntent memory intent = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: false,
            amount: sharesOut,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: backstopRouter.nonces(bobAddr),
            maxFeeBps: 10000
        });
        bytes memory sig = _signIntent(intent, BOB_PK);

        uint256 balBefore = vault.balances(bobAddr);

        vm.prank(relayer);
        uint256 usdcOut = backstopRouter.executeTradeIntent(intent, sig);

        assertTrue(usdcOut > 0, "gasless sell should return USDC");
        assertEq(vault.balances(bobAddr) - balBefore, usdcOut, "USDC credited should match");
        assertEq(shareToken.balanceOf(bobAddr, yesId), 0, "shares should be gone");
    }

    /// @dev Sequential nonce enforcement: must use nonces in order
    function test_sequentialNonce_mustUseInOrder() public {
        _setupMarket();

        // Execute nonce 0
        TradeIntent memory intent0 = _buildBobBuyIntent(2_000_000, 10000);
        bytes memory sig0 = _signIntent(intent0, BOB_PK);

        vm.prank(relayer);
        backstopRouter.executeTradeIntent(intent0, sig0);
        assertEq(backstopRouter.nonces(bobAddr), 1);

        // Skip nonce 1, try nonce 2 → BadNonce
        TradeIntent memory intent2 = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 2_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: 2,
            maxFeeBps: 10000
        });
        bytes memory sig2 = _signIntent(intent2, BOB_PK);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.BadNonce.selector);
        backstopRouter.executeTradeIntent(intent2, sig2);

        // Use nonce 1 → should work
        TradeIntent memory intent1 = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 2_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: 1,
            maxFeeBps: 10000
        });
        bytes memory sig1 = _signIntent(intent1, BOB_PK);

        vm.prank(relayer);
        uint256 shares = backstopRouter.executeTradeIntent(intent1, sig1);
        assertTrue(shares > 0);
        assertEq(backstopRouter.nonces(bobAddr), 2);
    }

    /// @dev Cancel already-used intent should revert
    function test_cancelAlreadyUsedIntent_reverts() public {
        _setupMarket();

        TradeIntent memory intent = _buildBobBuyIntent(5_000_000, 10000);
        bytes memory sig = _signIntent(intent, BOB_PK);

        // Execute intent first
        vm.prank(relayer);
        backstopRouter.executeTradeIntent(intent, sig);

        // Try to cancel the already-used intent
        vm.prank(bobAddr);
        vm.expectRevert("already used/cancelled");
        backstopRouter.cancelIntent(intent);
    }

    // ============================================================
    // 8. Quote Functions
    // ============================================================

    function test_quoteBuy_returnsNonZero() public {
        _setupMarket();
        uint256 amountUsdc = 10_000_000; // $10

        (uint256 sharesOut, uint256 fee) = backstopRouter.quoteBuy(conditionId, Side.Yes, amountUsdc);
        assertTrue(sharesOut > 0, "sharesOut should be > 0");
        assertTrue(fee > 0, "fee should be > 0");
        assertTrue(sharesOut >= amountUsdc - fee, "Polymarket guarantee: shares >= net");
    }

    function test_quoteSell_returnsNonZero() public {
        _setupMarket();

        // First buy some shares
        vm.prank(alice);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0);

        // Quote sell
        (uint256 amountOut, uint256 fee) = backstopRouter.quoteSell(conditionId, Side.Yes, 5_000_000);
        assertTrue(amountOut > 0, "amountOut should be > 0");
        assertTrue(fee > 0, "fee should be > 0");
    }

    function test_quoteBuy_matchesActualTrade() public {
        _setupMarket();
        uint256 amountUsdc = 5_000_000; // $5

        // Quote first
        (uint256 quotedShares,) = backstopRouter.quoteBuy(conditionId, Side.Yes, amountUsdc);

        // Execute actual trade
        vm.prank(alice);
        uint256 actualShares = backstopRouter.executeTrade(conditionId, Side.Yes, true, amountUsdc, 0);

        // Should match exactly (same state)
        assertEq(quotedShares, actualShares, "quote must match actual trade");
    }

    function test_quoteBuy_noBackstop_reverts() public {
        bytes32 fakeCondition = keccak256("nonexistent");
        vm.expectRevert("no backstop");
        backstopRouter.quoteBuy(fakeCondition, Side.Yes, 1_000_000);
    }

    function test_quoteSell_noBackstop_reverts() public {
        bytes32 fakeCondition = keccak256("nonexistent");
        vm.expectRevert("no backstop");
        backstopRouter.quoteSell(fakeCondition, Side.Yes, 1_000_000);
    }

    function test_quoteBuy_yesVsNo_sumApproximatelyInput() public {
        _setupMarket();
        uint256 amountUsdc = 10_000_000; // $10

        (uint256 sharesYes, uint256 feeYes) = backstopRouter.quoteBuy(conditionId, Side.Yes, amountUsdc);
        (uint256 sharesNo, uint256 feeNo) = backstopRouter.quoteBuy(conditionId, Side.No, amountUsdc);

        // At 50/50 market, YES and NO quotes should be equal
        assertEq(sharesYes, sharesNo, "50/50 market: YES and NO should give same shares");
        assertEq(feeYes, feeNo, "50/50 market: fees should be identical");
    }
}
