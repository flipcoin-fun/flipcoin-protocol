// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BaseV2Test} from "./BaseV2Test.sol";
import {
    Side, Outcome, ResolutionStatus, MarketParams, TradeIntent, Delegation
} from "../contracts/v2/interfaces/Types.sol";
import {ShareToken} from "../contracts/v2/ShareToken.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {BackstopRouter} from "../contracts/v2/BackstopRouter.sol";
import {VaultV2} from "../contracts/v2/VaultV2.sol";

/**
 * @title IntegrationTest
 * @notice End-to-end integration tests for the full v2 Hybrid CLOB + LMSR stack
 */
contract IntegrationTest is BaseV2Test {

    // ============================================================
    // Test: Factory creates market correctly
    // ============================================================

    function test_createMarket_basic() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        assertTrue(market != address(0), "market should be deployed");
        assertTrue(conditionId != bytes32(0), "conditionId should be set");

        // Verify MarketLMSR state
        MarketLMSR lmsr = MarketLMSR(market);
        assertTrue(lmsr.initialized(), "should be initialized");
        assertTrue(lmsr.configSet(), "should be configured");
        assertEq(lmsr.creator(), alice, "creator should be alice");
        assertEq(lmsr.vault(), address(vault), "vault should match");
        assertEq(lmsr.backstopRouter(), address(backstopRouter), "backstopRouter should match");
        assertEq(lmsr.shareToken(), address(shareToken), "shareToken should match");

        // Verify conditionId registered in BackstopRouter
        assertEq(backstopRouter.backstops(conditionId), market, "backstop should be registered");

        // Verify market whitelisted in Vault
        assertTrue(vault.whitelistedMarkets(market), "market should be whitelisted");

        // Verify token IDs are valid
        uint256 yesId = lmsr.yesTokenId();
        uint256 noId = lmsr.noTokenId();
        assertTrue(yesId != noId, "yes and no token IDs should differ");
        assertEq(yesId % 2, 0, "yes ID should be even");
        assertEq(noId % 2, 1, "no ID should be odd");

        // Verify seed deducted from alice
        assertLt(vault.balances(alice), INITIAL_BALANCE, "alice balance should decrease");
    }

    // ============================================================
    // Test: LMSR Buy (via BackstopRouter direct)
    // ============================================================

    function test_backstopBuy_direct() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        uint256 buyAmount = 10_000_000; // 10 USDC
        uint256 bobBalBefore = vault.balances(bob);

        // Bob buys YES shares via direct BackstopRouter call
        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(
            conditionId,
            Side.Yes,
            true, // isBuy
            buyAmount,
            0, // no slippage protection for test
            10000
        );

        // Verify shares received
        assertTrue(sharesOut > 0, "should receive shares");

        // Verify ERC-1155 balance
        uint256 bobShares = shareToken.balanceOf(bob, yesId);
        assertEq(bobShares, sharesOut, "ERC-1155 balance should match sharesOut");

        // Verify USDC deducted
        uint256 bobBalAfter = vault.balances(bob);
        assertEq(bobBalBefore - bobBalAfter, buyAmount, "USDC deducted should match");
    }

    // ============================================================
    // Test: LMSR Sell (via BackstopRouter direct)
    // ============================================================

    function test_backstopSell_direct() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        // First: Bob buys YES shares
        uint256 buyAmount = 10_000_000; // 10 USDC
        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(
            conditionId, Side.Yes, true, buyAmount, 0, 10000
        );
        assertTrue(sharesOut > 0, "should get shares from buy");

        // Bob approves BackstopRouter to transfer his shares
        vm.prank(bob);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        // Bob sells all YES shares
        uint256 bobBalBefore = vault.balances(bob);

        vm.prank(bob);
        uint256 usdcOut = backstopRouter.executeTrade(
            conditionId, Side.Yes, false, sharesOut, 0, 10000
        );

        // Verify USDC received
        assertTrue(usdcOut > 0, "should receive USDC from sell");

        uint256 bobBalAfter = vault.balances(bob);
        assertEq(bobBalAfter - bobBalBefore, usdcOut, "USDC credited should match");

        // Verify shares burned
        assertEq(shareToken.balanceOf(bob, yesId), 0, "should have 0 shares after full sell");
    }

    // ============================================================
    // Test: LMSR Buy with TradeIntent (gasless via BackstopRouter)
    // ============================================================

    function test_backstopBuyIntent_gasless() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);

        // Create a signing key for bob
        uint256 bobPk = 0xB0B;
        address bobAddr = vm.addr(bobPk);

        // Fund bob's address
        _fundAccount(bobAddr);

        // Build TradeIntent
        TradeIntent memory intent = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000, // 5 USDC
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: 0,
            maxFeeBps: 10000
        });

        // Sign EIP-712
        bytes32 intentHash = _hashTradeIntent(intent);
        bytes32 digest = _hashTypedDataV4BackstopRouter(intentHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Relayer executes
        vm.prank(relayer);
        uint256 sharesOut = backstopRouter.executeTradeIntent(intent, sig);

        assertTrue(sharesOut > 0, "should receive shares from gasless buy");

        uint256 yesId = lmsr.yesTokenId();
        assertEq(shareToken.balanceOf(bobAddr, yesId), sharesOut, "ERC-1155 balance should match");

        // Nonce should have incremented
        assertEq(backstopRouter.nonces(bobAddr), 1, "nonce should be 1");
    }

    // ============================================================
    // Test: Resolution flow (propose → finalize → redeem)
    // ============================================================

    function test_resolution_proposeAndFinalize() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        // Bob buys YES shares
        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(
            conditionId, Side.Yes, true, 10_000_000, 0, 10000
        );
        assertTrue(sharesOut > 0);

        // Fast-forward past deadline
        vm.warp(lmsr.deadline() + 1);

        // Admin proposes YES resolution
        vm.prank(admin);
        shareToken.proposeResolution(conditionId, Outcome.Yes);

        // Verify pending status
        (ResolutionStatus status,,,,,,,) = shareToken.resolutions(conditionId);
        assertEq(uint8(status), uint8(ResolutionStatus.Pending), "should be pending");

        // Fast-forward past dispute period (24h)
        vm.warp(block.timestamp + 24 hours + 1);

        // Anyone can finalize
        shareToken.finalizeResolution(conditionId);

        // Verify resolved
        (status,,,,,,,) = shareToken.resolutions(conditionId);
        assertEq(uint8(status), uint8(ResolutionStatus.Resolved), "should be resolved");

        // Bob redeems YES tokens
        uint256 bobBalBefore = vault.balances(bob);

        vm.prank(bob);
        shareToken.redeemPositions(conditionId);

        uint256 bobBalAfter = vault.balances(bob);
        assertTrue(bobBalAfter > bobBalBefore, "bob should receive USDC from redemption");

        // All YES tokens burned
        assertEq(shareToken.balanceOf(bob, yesId), 0, "YES tokens should be burned");
    }

    // ============================================================
    // Test: Resolution dispute flow
    // ============================================================

    function test_resolution_dispute() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 noId = lmsr.noTokenId();

        // Bob buys NO shares (becomes a token holder who can dispute)
        vm.prank(bob);
        uint256 sharesOut = backstopRouter.executeTrade(
            conditionId, Side.No, true, 10_000_000, 0, 10000
        );
        assertTrue(sharesOut > 0);
        assertTrue(shareToken.balanceOf(bob, noId) > 0, "bob should have NO shares");

        // Fast-forward past deadline
        vm.warp(lmsr.deadline() + 1);

        // Admin proposes YES (bob holds NO → might want to dispute)
        vm.prank(admin);
        shareToken.proposeResolution(conditionId, Outcome.Yes);

        // Bob disputes
        vm.prank(bob);
        shareToken.disputeResolution(conditionId);

        // Verify back to Open
        (ResolutionStatus status,,,,,,,) = shareToken.resolutions(conditionId);
        assertEq(uint8(status), uint8(ResolutionStatus.Open), "should be back to Open");
    }

    // ============================================================
    // Test: markAsInvalid safety valve
    // ============================================================

    function test_markAsInvalid() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();
        uint256 noId = lmsr.noTokenId();

        // Bob buys YES, Carol buys NO
        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 10_000_000, 0, 10000);

        vm.prank(carol);
        backstopRouter.executeTrade(conditionId, Side.No, true, 10_000_000, 0, 10000);

        // Fast-forward past deadline + ADMIN_RESOLVE_WINDOW (24h)
        vm.warp(lmsr.deadline() + 24 hours + 1);

        // Anyone can mark as invalid
        shareToken.markAsInvalid(conditionId);

        // Verify resolved as Invalid
        (ResolutionStatus status,,Outcome finalOutcome,,,,,uint256 payoutPerShare) = shareToken.resolutions(conditionId);
        assertEq(uint8(status), uint8(ResolutionStatus.Resolved), "should be resolved");
        assertEq(uint8(finalOutcome), uint8(Outcome.Invalid), "should be Invalid");
        assertEq(payoutPerShare, 500_000, "payout should be $0.50");

        // Both Bob and Carol can redeem at $0.50 per share
        uint256 bobBalBefore = vault.balances(bob);
        vm.prank(bob);
        shareToken.redeemPositions(conditionId);
        assertTrue(vault.balances(bob) > bobBalBefore, "bob should receive partial refund");

        uint256 carolBalBefore = vault.balances(carol);
        vm.prank(carol);
        shareToken.redeemPositions(conditionId);
        assertTrue(vault.balances(carol) > carolBalBefore, "carol should receive partial refund");
    }

    // ============================================================
    // Test: Delegation flow (session key signs on behalf)
    // ============================================================

    function test_delegation_backstopTrade() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        // Create session key
        uint256 sessionPk = 0x5E55;
        address sessionKey = vm.addr(sessionPk);

        // Alice delegates to session key via DelegationRegistry
        vm.prank(alice);
        delegationRegistry.setDelegation(
            sessionKey,
            address(backstopRouter), // scope = backstopRouter only
            50_000_000, // 50 USDC daily limit
            0 // no expiry
        );

        // Build TradeIntent where trader=alice, signer=sessionKey
        TradeIntent memory intent = TradeIntent({
            trader: alice,
            signer: sessionKey,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000, // 5 USDC
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: 0,
            maxFeeBps: 10000
        });

        // Session key signs
        bytes32 intentHash = _hashTradeIntent(intent);
        bytes32 digest = _hashTypedDataV4BackstopRouter(intentHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Relayer executes
        vm.prank(relayer);
        uint256 sharesOut = backstopRouter.executeTradeIntent(intent, sig);

        assertTrue(sharesOut > 0, "delegation trade should work");

        // Verify spend recorded
        Delegation memory d = delegationRegistry.getDelegation(alice, sessionKey);
        assertTrue(d.spentToday > 0, "spend should be recorded");
    }

    // ============================================================
    // Test: Meta-tx market creation (Mode A)
    // ============================================================

    function test_createMarketFor_modeA() public {
        uint256 creatorPk = 0xCA1;
        address creator = vm.addr(creatorPk);
        _fundAccount(creator);

        MarketParams memory params = MarketParams({
            question: "Meta-tx test market",
            description: "Created via EIP-712",
            category: "test",
            resolutionRules: "Test resolution rules",
            resolutionSource: "https://example.com",
            imageUrl: "",
            deadline: uint64(block.timestamp + 7 days)
        });

        bytes32 requestId = keccak256("unique-request-1");

        // Compute params hash (same as FactoryV2._computeParamsHash)
        bytes32 paramsHash = keccak256(abi.encode(
            keccak256(bytes(params.question)),
            keccak256(bytes(params.description)),
            keccak256(bytes(params.category)),
            keccak256(bytes(params.resolutionRules)),
            keccak256(bytes(params.resolutionSource)),
            keccak256(bytes(params.imageUrl)),
            params.deadline
        ));

        // Build EIP-712 struct hash
        bytes32 structHash = keccak256(abi.encode(
            factory.CREATE_MARKET_TYPEHASH(),
            paramsHash,
            SEED_USDC,
            uint256(5000),
            uint256(0), // nonce
            block.timestamp + 1 hours, // deadline
            requestId
        ));

        bytes32 digest = _hashTypedDataV4Factory(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(creatorPk, digest);

        // Relayer submits
        vm.prank(relayer);
        address market = factory.createMarketFor(
            params, SEED_USDC, 5000,
            creator,
            block.timestamp + 1 hours,
            requestId,
            v, r, s
        );

        assertTrue(market != address(0), "market should be created");
        assertEq(MarketLMSR(market).creator(), creator, "creator should match");
    }

    // ============================================================
    // Test: Multiple buy/sell cycle
    // ============================================================

    function test_multipleTrades_buySellCycle() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        uint256 yesId = lmsr.yesTokenId();

        // Bob buys 3 times
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(bob);
            backstopRouter.executeTrade(conditionId, Side.Yes, true, 5_000_000, 0, 10000);
        }

        uint256 totalShares = shareToken.balanceOf(bob, yesId);
        assertTrue(totalShares > 0, "bob should have accumulated shares");

        // Approve and sell all
        vm.prank(bob);
        shareToken.setApprovalForAll(address(backstopRouter), true);

        vm.prank(bob);
        uint256 usdcBack = backstopRouter.executeTrade(
            conditionId, Side.Yes, false, totalShares, 0, 10000
        );

        assertTrue(usdcBack > 0, "should receive USDC back");
        assertEq(shareToken.balanceOf(bob, yesId), 0, "should have 0 shares");
    }

    // ============================================================
    // Test: Cancel intent
    // ============================================================

    function test_cancelIntent() public {
        (, bytes32 conditionId) = _createDefaultMarket(alice);

        uint256 bobPk = 0xB0B;
        address bobAddr = vm.addr(bobPk);
        _fundAccount(bobAddr);

        TradeIntent memory intent = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: 0,
            maxFeeBps: 10000
        });

        // Bob cancels the intent
        vm.prank(bobAddr);
        backstopRouter.cancelIntent(intent);

        // Try to execute — should fail
        bytes32 intentHash = _hashTradeIntent(intent);
        bytes32 digest = _hashTypedDataV4BackstopRouter(intentHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.IntentAlreadyUsed.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // Test: Vault invariant holds through operations
    // ============================================================

    function test_vaultInvariant_afterTrades() public {
        (address market, bytes32 conditionId) = _createDefaultMarket(alice);

        // Bob buys YES
        vm.prank(bob);
        backstopRouter.executeTrade(conditionId, Side.Yes, true, 20_000_000, 0, 10000);

        // Carol buys NO
        vm.prank(carol);
        backstopRouter.executeTrade(conditionId, Side.No, true, 15_000_000, 0, 10000);

        // Check invariant: USDC.balanceOf(vault) >= totalBalances + splitReserve + feePool
        uint256 usdcBalance = usdc.balanceOf(address(vault));
        uint256 accounting = vault.totalBalances() + vault.splitReserve() + vault.feePool();

        assertGe(usdcBalance, accounting, "vault invariant should hold");
    }

    // ============================================================
    // Test: Nonce bump invalidates old intents
    // ============================================================

    function test_nonceBump() public {
        (, bytes32 conditionId) = _createDefaultMarket(alice);

        uint256 bobPk = 0xB0B;
        address bobAddr = vm.addr(bobPk);
        _fundAccount(bobAddr);

        // Bump nonce to 5
        vm.prank(bobAddr);
        backstopRouter.bumpNonce(5);

        assertEq(backstopRouter.nonces(bobAddr), 5, "nonce should be 5");

        // Old intent with nonce=0 should fail
        TradeIntent memory intent = TradeIntent({
            trader: bobAddr,
            signer: bobAddr,
            conditionId: conditionId,
            side: Side.Yes,
            isBuy: true,
            amount: 5_000_000,
            minOut: 0,
            deadline: block.timestamp + 1 hours,
            nonce: 0,
            maxFeeBps: 10000
        });

        bytes32 intentHash = _hashTradeIntent(intent);
        bytes32 digest = _hashTypedDataV4BackstopRouter(intentHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        vm.expectRevert(BackstopRouter.BadNonce.selector);
        backstopRouter.executeTradeIntent(intent, sig);
    }

    // ============================================================
    // Internal: EIP-712 Helpers
    // ============================================================

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

    function _hashTypedDataV4BackstopRouter(bytes32 structHash) internal view returns (bytes32) {
        // Rebuild EIP-712 domain separator for BackstopRouter
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("FlipCoinBackstopRouter"),
            keccak256("1"),
            block.chainid,
            address(backstopRouter)
        ));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _hashTypedDataV4Factory(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("FlipCoin Factory"),
            keccak256("1"),
            block.chainid,
            address(factory)
        ));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
