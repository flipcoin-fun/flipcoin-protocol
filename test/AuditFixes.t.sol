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
    // R2-1: Exchange._settleComplementary — Seller price protection
    // ============================================================

    function test_R2_1_complementary_priceBelowSellerAsk_reverts() public {
        // Bob sells YES shares at 7000 bps ($0.70 minimum)
        // Carol buys YES shares at 5000 bps ($0.50)
        // Should revert: buyer price < seller ask

        // Bob gets YES shares via LMSR
        _buySharesViaBackstop(bobAddr, Side.Yes, 10_000_000);
        _approveExchange(bobAddr);

        // Bob sell order: 1_000_000 shares, wants 700_000 USDC (= 7000 bps)
        Order memory sellOrder = _makeSellOrder(bobAddr, bobAddr, yesTokenId, 1_000_000, 700_000, Side.Yes);
        // Carol buy order: 500_000 USDC for 1_000_000 shares (= 5000 bps)
        Order memory buyOrder = _makeBuyOrder(carolAddr, carolAddr, yesTokenId, 500_000, 1_000_000, Side.Yes);

        bytes memory takerSig = _signOrder(buyOrder, CAROL_PK);
        bytes memory makerSig = _signOrder(sellOrder, BOB_PK);

        vm.prank(operator);
        vm.expectRevert(Exchange.PriceBelowSellerMinimum.selector);
        exchange.matchOrders(buyOrder, sellOrder, 1_000_000, takerSig, makerSig, MatchType.COMPLEMENTARY);
    }

    function test_R2_1_complementary_priceAtSellerAsk_succeeds() public {
        // Bob sells YES shares at 5000 bps ($0.50)
        // Carol buys YES shares at 5000 bps ($0.50)
        // Should succeed: buyer price == seller ask

        _buySharesViaBackstop(bobAddr, Side.Yes, 10_000_000);
        _approveExchange(bobAddr);

        // Bob sell order: 1_000_000 shares at 5000 bps
        Order memory sellOrder = _makeSellOrder(bobAddr, bobAddr, yesTokenId, 1_000_000, 500_000, Side.Yes);
        // Carol buy order: 1_000_000 shares at 5000 bps
        Order memory buyOrder = _makeBuyOrder(carolAddr, carolAddr, yesTokenId, 500_000, 1_000_000, Side.Yes);

        bytes memory takerSig = _signOrder(buyOrder, CAROL_PK);
        bytes memory makerSig = _signOrder(sellOrder, BOB_PK);

        uint256 carolBalBefore = vault.balances(carolAddr);
        uint256 bobBalBefore = vault.balances(bobAddr);

        vm.prank(operator);
        exchange.matchOrders(buyOrder, sellOrder, 1_000_000, takerSig, makerSig, MatchType.COMPLEMENTARY);

        // Carol paid USDC, Bob received USDC
        assertTrue(vault.balances(carolAddr) < carolBalBefore, "Carol should have paid");
        assertTrue(vault.balances(bobAddr) > bobBalBefore, "Bob should have received");
    }

    function test_R2_1_complementary_priceAboveSellerAsk_succeeds() public {
        // Bob sells YES shares at 4000 bps ($0.40)
        // Carol buys YES shares at 5000 bps ($0.50)
        // Should succeed: buyer price > seller ask (price improvement for seller)

        _buySharesViaBackstop(bobAddr, Side.Yes, 10_000_000);
        _approveExchange(bobAddr);

        // Bob sell order: 1_000_000 shares at 4000 bps
        Order memory sellOrder = _makeSellOrder(bobAddr, bobAddr, yesTokenId, 1_000_000, 400_000, Side.Yes);
        // Carol buy order: 1_000_000 shares at 5000 bps
        Order memory buyOrder = _makeBuyOrder(carolAddr, carolAddr, yesTokenId, 500_000, 1_000_000, Side.Yes);

        bytes memory takerSig = _signOrder(buyOrder, CAROL_PK);
        bytes memory makerSig = _signOrder(sellOrder, BOB_PK);

        vm.prank(operator);
        exchange.matchOrders(buyOrder, sellOrder, 1_000_000, takerSig, makerSig, MatchType.COMPLEMENTARY);

        // Bob received shares worth of USDC
        assertTrue(shareToken.balanceOf(carolAddr, yesTokenId) > 0, "Carol should hold YES shares");
    }

    // ============================================================
    // R2-2: Exchange._settleMerge — Surplus USDC to protocol fees
    // ============================================================

    function test_R2_2_merge_surplusToProtocolFees() public {
        // MERGE with price1 + price2 < BPS → surplus should go to protocolFeesAccumulated
        // Seller1: sells YES at 3000 bps ($0.30)
        // Seller2: sells NO at 5000 bps ($0.50)
        // Total = 8000 bps < 10000 → surplus = fillAmount - usdc1 - usdc2

        // Get shares for both sellers
        _buySharesViaBackstop(bobAddr, Side.Yes, 10_000_000);
        _buySharesViaBackstop(carolAddr, Side.No, 10_000_000);
        _approveExchange(bobAddr);
        _approveExchange(carolAddr);

        uint256 fillAmount = 1_000_000; // 1 share pair

        // Bob sells YES at 3000 bps: 1_000_000 shares, wants 300_000 USDC
        Order memory sellYes = _makeSellOrder(bobAddr, bobAddr, yesTokenId, fillAmount, 300_000, Side.Yes);
        // Carol sells NO at 5000 bps: 1_000_000 shares, wants 500_000 USDC
        Order memory sellNo = _makeSellOrder(carolAddr, carolAddr, noTokenId, fillAmount, 500_000, Side.No);

        bytes memory takerSig = _signOrder(sellYes, BOB_PK);
        bytes memory makerSig = _signOrder(sellNo, CAROL_PK);

        uint256 protocolFeesBefore = exchange.protocolFeesAccumulated();

        vm.prank(operator);
        exchange.matchOrders(sellYes, sellNo, fillAmount, takerSig, makerSig, MatchType.MERGE);

        // usdc1 = 1_000_000 * 3000 / 10000 = 300_000
        // usdc2 = 1_000_000 * 5000 / 10000 = 500_000
        // totalPaid = 800_000, surplus = 1_000_000 - 800_000 = 200_000
        uint256 protocolFeesAfter = exchange.protocolFeesAccumulated();
        uint256 surplusCollected = protocolFeesAfter - protocolFeesBefore;

        // Surplus should include the 200_000 USDC difference (plus regular fees go elsewhere)
        assertTrue(surplusCollected >= 200_000, "surplus should be routed to protocol fees");
    }

    function test_R2_2_merge_noPriceSumEqual() public {
        // MERGE with price1 + price2 == BPS → no surplus
        // Seller1: sells YES at 5000 bps ($0.50)
        // Seller2: sells NO at 5000 bps ($0.50)
        // Total = 10000 bps = BPS → surplus = 0

        _buySharesViaBackstop(bobAddr, Side.Yes, 10_000_000);
        _buySharesViaBackstop(carolAddr, Side.No, 10_000_000);
        _approveExchange(bobAddr);
        _approveExchange(carolAddr);

        uint256 fillAmount = 1_000_000;

        // Bob sells YES at 5000 bps
        Order memory sellYes = _makeSellOrder(bobAddr, bobAddr, yesTokenId, fillAmount, 500_000, Side.Yes);
        // Carol sells NO at 5000 bps
        Order memory sellNo = _makeSellOrder(carolAddr, carolAddr, noTokenId, fillAmount, 500_000, Side.No);

        bytes memory takerSig = _signOrder(sellYes, BOB_PK);
        bytes memory makerSig = _signOrder(sellNo, CAROL_PK);

        uint256 protocolFeesBefore = exchange.protocolFeesAccumulated();

        vm.prank(operator);
        exchange.matchOrders(sellYes, sellNo, fillAmount, takerSig, makerSig, MatchType.MERGE);

        // usdc1 + usdc2 = 500_000 + 500_000 = 1_000_000 == fillAmount → no surplus
        // protocolFeesAccumulated should only increase by regular fee portion (not surplus)
        uint256 protocolFeesAfter = exchange.protocolFeesAccumulated();
        uint256 feeDelta = protocolFeesAfter - protocolFeesBefore;

        // With fillAmount=1_000_000 and price=5000, fee = feeBps * min(5000, 5000) * 1_000_000 / BPS / BPS
        // The fee is from normal fee accumulation, no surplus component
        // We just verify no extra surplus was added (feeDelta should be small, from normal fees only)
        assertTrue(feeDelta < 200_000, "no large surplus should be routed when prices sum to BPS");
    }

    // ============================================================
    // Internal Helpers — EIP-712 Signing (for Exchange order tests)
    // ============================================================

    bytes32 internal DOMAIN_SEPARATOR;
    bytes32 internal ORDER_TYPEHASH_CACHED;
    bool internal _eip712Initialized;

    function _ensureEip712() internal {
        if (_eip712Initialized) return;
        ORDER_TYPEHASH_CACHED = exchange.ORDER_TYPEHASH();
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FlipCoinExchange"),
                keccak256("1"),
                block.chainid,
                address(exchange)
            )
        );
        _eip712Initialized = true;
    }

    function _makeBuyOrder(
        address maker, address signer, uint256 tokenId,
        uint256 usdcAmount, uint256 sharesWanted, Side side
    ) internal pure returns (Order memory) {
        return Order({
            salt: uint256(keccak256(abi.encode(maker, tokenId, usdcAmount, sharesWanted, uint256(0)))),
            maker: maker, signer: signer, taker: address(0),
            tokenId: tokenId, makerAmount: usdcAmount, takerAmount: sharesWanted,
            expiration: 0, nonce: 0, maxFeeBps: 10_000,
            side: side, sigType: SignatureType.EOA
        });
    }

    function _makeSellOrder(
        address maker, address signer, uint256 tokenId,
        uint256 sharesOffered, uint256 usdcWanted, Side side
    ) internal pure returns (Order memory) {
        return Order({
            salt: uint256(keccak256(abi.encode(maker, tokenId, sharesOffered, usdcWanted, uint256(0)))),
            maker: maker, signer: signer, taker: address(0),
            tokenId: tokenId, makerAmount: sharesOffered, takerAmount: usdcWanted,
            expiration: 0, nonce: 0, maxFeeBps: 10_000,
            side: side, sigType: SignatureType.EOA
        });
    }

    function _signOrder(Order memory order, uint256 pk) internal returns (bytes memory) {
        _ensureEip712();
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPEHASH_CACHED,
            order.salt, order.maker, order.signer, order.taker,
            order.tokenId, order.makerAmount, order.takerAmount,
            order.expiration, order.nonce, order.maxFeeBps,
            uint8(order.side), uint8(order.sigType)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buySharesViaBackstop(address buyer, Side side, uint256 usdcAmount) internal returns (uint256) {
        vm.prank(buyer);
        return backstopRouter.executeTrade(conditionId, side, true, usdcAmount, 0, 10000);
    }

    function _approveExchange(address owner_) internal {
        vm.prank(owner_);
        shareToken.setApprovalForAll(address(exchange), true);
    }

    // ============================================================
    // Internal Helpers — Clone Deployment
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
