// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BaseV2Test} from "./BaseV2Test.sol";
import {
    Order, Side, MatchType, SignatureType, Outcome, ResolutionStatus, TradeIntent
} from "../contracts/v2/interfaces/Types.sol";
import {Exchange} from "../contracts/v2/Exchange.sol";
import {ShareToken} from "../contracts/v2/ShareToken.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {VaultV2} from "../contracts/v2/VaultV2.sol";

/**
 * @title ExchangeTest
 * @notice Comprehensive tests for the Exchange CLOB settlement contract
 * @dev Tests all match types (COMPLEMENTARY, MINT, MERGE), fee calculations,
 *      order management, access control, and edge cases.
 */
contract ExchangeTest is BaseV2Test {
    // ── Signing keys ──
    uint256 internal bobPk = 0xB0B;
    address internal bobAddr;

    uint256 internal carolPk = 0xCA0;
    address internal carolAddr;

    // ── Market state ──
    address internal market;
    bytes32 internal conditionId;
    uint256 internal yesTokenId;
    uint256 internal noTokenId;

    // ── EIP-712 cached values (avoids external calls that consume prank) ──
    bytes32 internal DOMAIN_SEPARATOR;
    bytes32 internal ORDER_TYPEHASH_CACHED;

    function setUp() public override {
        super.setUp();

        // Derive addresses from private keys
        bobAddr = vm.addr(bobPk);
        carolAddr = vm.addr(carolPk);

        // Fund the pk-derived addresses
        _fundAccount(bobAddr);
        _fundAccount(carolAddr);

        // Ensure Exchange is an authorized caller on ShareToken (for split/merge)
        vm.startPrank(admin);
        shareToken.addAuthorizedCaller(address(exchange));
        vm.stopPrank();

        // Create a default market
        (market, conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        yesTokenId = lmsr.yesTokenId();
        noTokenId = lmsr.noTokenId();

        // Cache EIP-712 constants (avoids external calls later that consume prank)
        ORDER_TYPEHASH_CACHED = exchange.ORDER_TYPEHASH();
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("FlipCoinExchange"),
                keccak256("1"),
                block.chainid,
                address(exchange)
            )
        );
    }

    // ============================================================
    // Internal Helpers — Order Construction & Signing
    // ============================================================

    function _makeOrder(
        address maker,
        address signer,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side,
        uint256 nonce,
        uint256 maxFeeBps,
        uint256 expiration,
        address taker
    ) internal pure returns (Order memory) {
        return Order({
            salt: uint256(keccak256(abi.encode(maker, tokenId, makerAmount, takerAmount, nonce))),
            maker: maker,
            signer: signer,
            taker: taker,
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: expiration,
            nonce: nonce,
            maxFeeBps: maxFeeBps,
            side: side,
            sigType: SignatureType.EOA
        });
    }

    /// @dev Build a buy order: maker provides USDC (makerAmount), wants shares (takerAmount)
    function _makeBuyOrder(
        address maker,
        address signer,
        uint256 tokenId,
        uint256 usdcAmount,
        uint256 sharesWanted,
        Side side
    ) internal pure returns (Order memory) {
        return _makeOrder(
            maker,
            signer,
            tokenId,
            usdcAmount,       // makerAmount = USDC willing to pay
            sharesWanted,     // takerAmount = shares wanting
            side,
            0,                // nonce
            10_000,           // maxFeeBps — generous ceiling
            0,                // no expiration
            address(0)        // any taker
        );
    }

    /// @dev Build a sell order: maker provides shares (makerAmount), wants USDC (takerAmount)
    function _makeSellOrder(
        address maker,
        address signer,
        uint256 tokenId,
        uint256 sharesOffered,
        uint256 usdcWanted,
        Side side
    ) internal pure returns (Order memory) {
        return _makeOrder(
            maker,
            signer,
            tokenId,
            sharesOffered,    // makerAmount = shares to sell
            usdcWanted,       // takerAmount = USDC wanting
            side,
            0,                // nonce
            10_000,           // maxFeeBps — generous ceiling
            0,                // no expiration
            address(0)        // any taker
        );
    }

    /// @dev Hash an order struct (uses cached typehash to avoid consuming prank)
    function _hashOrder(Order memory order) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH_CACHED,
                order.salt,
                order.maker,
                order.signer,
                order.taker,
                order.tokenId,
                order.makerAmount,
                order.takerAmount,
                order.expiration,
                order.nonce,
                order.maxFeeBps,
                uint8(order.side),
                uint8(order.sigType)
            )
        );
    }

    /// @dev Compute EIP-712 digest (uses cached domain separator)
    function _getDigest(Order memory order) internal view returns (bytes32) {
        bytes32 structHash = _hashOrder(order);
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /// @dev Sign an order with the given private key (no external calls)
    function _signOrder(Order memory order, uint256 pk)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 digest = _getDigest(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Buy shares for `buyer` via BackstopRouter direct call
    function _buySharesViaBackstop(address buyer, Side side, uint256 usdcAmount)
        internal
        returns (uint256 sharesOut)
    {
        vm.prank(buyer);
        sharesOut = backstopRouter.executeTrade(conditionId, side, true, usdcAmount, 0);
    }

    /// @dev Approve exchange to transfer shares on behalf of `owner`
    function _approveExchange(address owner_) internal {
        vm.prank(owner_);
        shareToken.setApprovalForAll(address(exchange), true);
    }

    /// @dev Helper to match orders as operator (signs first, then pranks)
    function _matchAsOperator(
        Order memory takerOrder,
        Order memory makerOrder,
        uint256 fillAmount,
        uint256 takerPk,
        uint256 makerPk
    ) internal {
        MatchType mt = _inferMatchType(takerOrder, makerOrder);
        bytes memory takerSig = _signOrder(takerOrder, takerPk);
        bytes memory makerSig = _signOrder(makerOrder, makerPk);
        vm.prank(operator);
        exchange.matchOrders(takerOrder, makerOrder, fillAmount, takerSig, makerSig, mt);
    }

    /// @dev Helper to match with explicit match type
    function _matchAsOperatorWithType(
        Order memory takerOrder,
        Order memory makerOrder,
        uint256 fillAmount,
        uint256 takerPk,
        uint256 makerPk,
        MatchType mt
    ) internal {
        bytes memory takerSig = _signOrder(takerOrder, takerPk);
        bytes memory makerSig = _signOrder(makerOrder, makerPk);
        vm.prank(operator);
        exchange.matchOrders(takerOrder, makerOrder, fillAmount, takerSig, makerSig, mt);
    }

    /// @dev Helper to expect revert when matching as operator
    function _matchAsOperatorExpectRevert(
        Order memory takerOrder,
        Order memory makerOrder,
        uint256 fillAmount,
        uint256 takerPk,
        uint256 makerPk,
        bytes4 expectedError
    ) internal {
        MatchType mt = _inferMatchType(takerOrder, makerOrder);
        bytes memory takerSig = _signOrder(takerOrder, takerPk);
        bytes memory makerSig = _signOrder(makerOrder, makerPk);
        vm.prank(operator);
        vm.expectRevert(expectedError);
        exchange.matchOrders(takerOrder, makerOrder, fillAmount, takerSig, makerSig, mt);
    }

    /// @dev Helper to expect revert with string message when matching
    function _matchAsOperatorExpectRevertStr(
        Order memory takerOrder,
        Order memory makerOrder,
        uint256 fillAmount,
        uint256 takerPk,
        uint256 makerPk,
        string memory expectedMsg
    ) internal {
        MatchType mt = _inferMatchType(takerOrder, makerOrder);
        bytes memory takerSig = _signOrder(takerOrder, takerPk);
        bytes memory makerSig = _signOrder(makerOrder, makerPk);
        vm.prank(operator);
        vm.expectRevert(bytes(expectedMsg));
        exchange.matchOrders(takerOrder, makerOrder, fillAmount, takerSig, makerSig, mt);
    }

    /// @dev Helper to match orders as operator with pre-signed signatures
    function _matchAsOperatorPresigned(
        Order memory takerOrder,
        Order memory makerOrder,
        uint256 fillAmount,
        bytes memory takerSig,
        bytes memory makerSig
    ) internal {
        MatchType mt = _inferMatchType(takerOrder, makerOrder);
        vm.prank(operator);
        exchange.matchOrders(takerOrder, makerOrder, fillAmount, takerSig, makerSig, mt);
    }

    /// @dev Infer match type from token IDs (default: MINT for different tokens)
    function _inferMatchType(Order memory taker, Order memory maker)
        internal pure returns (MatchType)
    {
        if (taker.tokenId == maker.tokenId) return MatchType.COMPLEMENTARY;
        return MatchType.MINT;
    }

    // ============================================================
    // 1. COMPLEMENTARY Match — buyer + seller of same token
    // ============================================================

    function test_complementary_basicMatch() public {
        // Bob acquires YES shares via backstop so he can sell them
        uint256 buyUsdc = 10_000_000; // 10 USDC
        uint256 bobShares = _buySharesViaBackstop(bobAddr, Side.Yes, buyUsdc);
        assertTrue(bobShares > 0, "bob should have YES shares");

        // Bob approves exchange to transfer his shares
        _approveExchange(bobAddr);

        uint256 sellShares = bobShares / 2; // Sell half
        uint256 pricePerShareBps = 5000; // 50 cents per share
        uint256 usdcForShares = sellShares * pricePerShareBps / 10_000;

        // Carol wants to buy YES at 50% price (taker=buyer)
        // Bob sells YES (maker=seller)
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, yesTokenId, usdcForShares, sellShares, Side.Yes
        );
        Order memory bobOrder = _makeSellOrder(
            bobAddr, bobAddr, yesTokenId, sellShares, usdcForShares, Side.Yes
        );

        // Record balances before
        uint256 carolUsdcBefore = vault.balances(carolAddr);
        uint256 bobUsdcBefore = vault.balances(bobAddr);
        uint256 carolSharesBefore = shareToken.balanceOf(carolAddr, yesTokenId);
        uint256 bobSharesBefore = shareToken.balanceOf(bobAddr, yesTokenId);

        _matchAsOperator(carolOrder, bobOrder, sellShares, carolPk, bobPk);

        // Verify share transfer: carol receives shares
        uint256 carolSharesAfter = shareToken.balanceOf(carolAddr, yesTokenId);
        assertEq(
            carolSharesAfter - carolSharesBefore,
            sellShares,
            "carol should receive shares"
        );

        // Verify bob lost shares
        uint256 bobSharesAfter = shareToken.balanceOf(bobAddr, yesTokenId);
        assertEq(
            bobSharesBefore - bobSharesAfter,
            sellShares,
            "bob should have transferred shares"
        );

        // Verify USDC transfer: carol pays, bob receives
        uint256 carolUsdcAfter = vault.balances(carolAddr);
        uint256 bobUsdcAfter = vault.balances(bobAddr);
        assertTrue(carolUsdcBefore > carolUsdcAfter, "carol USDC should decrease");
        assertTrue(bobUsdcAfter > bobUsdcBefore, "bob USDC should increase");
    }

    // ============================================================
    // 2. MINT Match — two buyers of opposite tokens
    // ============================================================

    function test_mint_basicMatch() public {
        uint256 fillAmount = 1_000_000; // 1 share pair (1 USDC face value)
        uint256 priceYesBps = 6000; // 60 cents for YES
        uint256 priceNoBps = 4000; // 40 cents for NO

        uint256 usdcYes = fillAmount * priceYesBps / 10_000;
        uint256 usdcNo = fillAmount * priceNoBps / 10_000;

        // Bob wants to buy YES at 60%, Carol wants to buy NO at 40%
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, usdcYes, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, usdcNo, fillAmount, Side.No
        );

        uint256 bobUsdcBefore = vault.balances(bobAddr);
        uint256 carolUsdcBefore = vault.balances(carolAddr);
        uint256 bobSharesBefore = shareToken.balanceOf(bobAddr, yesTokenId);
        uint256 carolSharesBefore = shareToken.balanceOf(carolAddr, noTokenId);

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        // Verify: Bob receives YES shares
        uint256 bobSharesAfter = shareToken.balanceOf(bobAddr, yesTokenId);
        assertEq(
            bobSharesAfter - bobSharesBefore,
            fillAmount,
            "bob should receive YES shares from mint"
        );

        // Verify: Carol receives NO shares
        uint256 carolSharesAfter = shareToken.balanceOf(carolAddr, noTokenId);
        assertEq(
            carolSharesAfter - carolSharesBefore,
            fillAmount,
            "carol should receive NO shares from mint"
        );

        // Verify: USDC deducted from both
        uint256 bobUsdcAfter = vault.balances(bobAddr);
        uint256 carolUsdcAfter = vault.balances(carolAddr);
        assertTrue(bobUsdcBefore > bobUsdcAfter, "bob USDC should decrease");
        assertTrue(carolUsdcBefore > carolUsdcAfter, "carol USDC should decrease");

        // Verify splitReserve increased (tokens were minted)
        assertTrue(vault.splitReserve() > 0, "splitReserve should hold locked USDC");
    }

    function test_mint_largeFill() public {
        uint256 fillAmount = 50_000_000; // 50 shares
        uint256 priceYesBps = 5000;
        uint256 priceNoBps = 5000;

        uint256 usdcYes = fillAmount * priceYesBps / 10_000;
        uint256 usdcNo = fillAmount * priceNoBps / 10_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, usdcYes, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, usdcNo, fillAmount, Side.No
        );

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        assertEq(
            shareToken.balanceOf(bobAddr, yesTokenId),
            fillAmount,
            "bob should have 50 YES shares"
        );
        assertEq(
            shareToken.balanceOf(carolAddr, noTokenId),
            fillAmount,
            "carol should have 50 NO shares"
        );
    }

    // ============================================================
    // 3. MERGE Match — testing share creation for merge readiness
    // ============================================================

    // Note: The current _deriveMatchType always returns MINT for different tokens.
    // MERGE settlement path requires future update to match type derivation.
    // This test verifies MINT-then-verify-shares flow as merge prerequisite.

    function test_merge_viaMintFirst() public {
        // Mint some shares via MINT match so both bob and carol have tokens
        uint256 fillAmount = 5_000_000;
        uint256 priceYesBps = 5000;
        uint256 priceNoBps = 5000;

        uint256 usdcYes = fillAmount * priceYesBps / 10_000;
        uint256 usdcNo = fillAmount * priceNoBps / 10_000;

        Order memory bobBuy = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, usdcYes, fillAmount, Side.Yes
        );
        Order memory carolBuy = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, usdcNo, fillAmount, Side.No
        );

        _matchAsOperator(bobBuy, carolBuy, fillAmount, bobPk, carolPk);

        // Now bob has YES shares, carol has NO shares
        assertEq(shareToken.balanceOf(bobAddr, yesTokenId), fillAmount);
        assertEq(shareToken.balanceOf(carolAddr, noTokenId), fillAmount);

        // Record splitReserve — should hold locked USDC
        uint256 splitReserveCurrent = vault.splitReserve();
        assertTrue(splitReserveCurrent > 0, "split reserve should have funds after mint");

        // Verify the MINT created shares correctly
        assertTrue(
            shareToken.totalSupply(yesTokenId) >= fillAmount,
            "YES supply should include minted shares"
        );
        assertTrue(
            shareToken.totalSupply(noTokenId) >= fillAmount,
            "NO supply should include minted shares"
        );
    }

    // ============================================================
    // 4. Fee Calculations
    // ============================================================

    function test_fees_accumulatedOnMint() public {
        uint256 fillAmount = 10_000_000;
        uint256 priceYesBps = 5000;
        uint256 priceNoBps = 5000;

        uint256 usdcYes = fillAmount * priceYesBps / 10_000;
        uint256 usdcNo = fillAmount * priceNoBps / 10_000;

        uint256 protocolFeesBefore = exchange.protocolFeesAccumulated();
        uint256 creatorFeesBefore = exchange.creatorFeesAccumulated(conditionId);

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, usdcYes, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, usdcNo, fillAmount, Side.No
        );

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        uint256 protocolFeesAfter = exchange.protocolFeesAccumulated();
        uint256 creatorFeesAfter = exchange.creatorFeesAccumulated(conditionId);

        assertTrue(
            protocolFeesAfter > protocolFeesBefore,
            "protocol fees should accumulate"
        );
        assertTrue(
            creatorFeesAfter > creatorFeesBefore,
            "creator fees should accumulate"
        );

        // Total fees should be split between protocol and creator
        uint256 totalFees = (protocolFeesAfter - protocolFeesBefore)
            + (creatorFeesAfter - creatorFeesBefore);
        assertTrue(totalFees > 0, "total fees should be positive");
    }

    function test_fees_complementaryMatch() public {
        // Bob gets YES shares
        uint256 bobShares = _buySharesViaBackstop(bobAddr, Side.Yes, 10_000_000);
        _approveExchange(bobAddr);

        uint256 sellShares = bobShares / 2;
        uint256 pricePerShareBps = 5000;
        uint256 usdcForShares = sellShares * pricePerShareBps / 10_000;

        uint256 protocolFeesBefore = exchange.protocolFeesAccumulated();
        uint256 creatorFeesBefore = exchange.creatorFeesAccumulated(conditionId);

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, yesTokenId, usdcForShares, sellShares, Side.Yes
        );
        Order memory bobOrder = _makeSellOrder(
            bobAddr, bobAddr, yesTokenId, sellShares, usdcForShares, Side.Yes
        );

        _matchAsOperator(carolOrder, bobOrder, sellShares, carolPk, bobPk);

        uint256 protocolFeesAfter = exchange.protocolFeesAccumulated();
        uint256 creatorFeesAfter = exchange.creatorFeesAccumulated(conditionId);

        uint256 totalFeesCollected = (protocolFeesAfter - protocolFeesBefore)
            + (creatorFeesAfter - creatorFeesBefore);
        assertTrue(totalFeesCollected > 0, "fees should be collected on complementary match");

        // Verify protocol/creator fee ratio (50/50 for default config)
        uint256 protocolPortion = protocolFeesAfter - protocolFeesBefore;
        uint256 creatorPortion = creatorFeesAfter - creatorFeesBefore;
        assertEq(protocolPortion, creatorPortion, "protocol and creator fees should be equal");
    }

    function test_fees_protocolFeeView() public view {
        uint256 totalFee = exchange.getTotalFeeBps(conditionId);
        assertEq(
            totalFee,
            DEFAULT_PROTOCOL_FEE_BPS + DEFAULT_CREATOR_FEE_BPS,
            "total fee should equal protocol + creator"
        );
    }

    // ============================================================
    // 5. Order Cancellation
    // ============================================================

    function test_cancelOrder_setsFlag() public {
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 5_000_000, 10_000_000, Side.Yes
        );

        // Bob cancels his order
        vm.prank(bobAddr);
        exchange.cancelOrder(bobOrder);

        // Verify the cancellation flag is set on the EIP-712 digest
        bytes32 digest = _getDigest(bobOrder);
        assertTrue(exchange.ordersCancelled(digest), "digest should be marked cancelled");
    }

    function test_cancelOrder_emitsEvent() public {
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 5_000_000, 10_000_000, Side.Yes
        );

        bytes32 digest = _getDigest(bobOrder);
        vm.prank(bobAddr);
        vm.expectEmit(true, true, false, true);
        emit Exchange.OrderCancelled(digest, bobAddr);
        exchange.cancelOrder(bobOrder);
    }

    function test_cancelOrder_onlyMaker() public {
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 5_000_000, 10_000_000, Side.Yes
        );

        // Carol tries to cancel Bob's order — should revert
        vm.prank(carolAddr);
        vm.expectRevert("not maker");
        exchange.cancelOrder(bobOrder);
    }

    function test_cancelOrder_makerCancelDoesNotAffectCounterparty() public {
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 5_000_000, 10_000_000, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 5_000_000, 10_000_000, Side.No
        );

        // Bob cancels his order
        vm.prank(bobAddr);
        exchange.cancelOrder(bobOrder);

        // Carol's order should NOT be cancelled (different hash)
        bytes32 carolDigest = _getDigest(carolOrder);
        assertFalse(exchange.ordersCancelled(carolDigest), "carol order should not be cancelled");
    }

    // ============================================================
    // 6. Nonce Bump
    // ============================================================

    function test_nonceBump_invalidatesOldOrders() public {
        // Bob creates order with nonce=0
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 5_000_000, 10_000_000, Side.Yes
        );
        bobOrder.nonce = 0;

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 5_000_000, 10_000_000, Side.No
        );

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        // Bob bumps nonce to 5
        vm.prank(bobAddr);
        exchange.bumpNonce(5);

        assertEq(exchange.nonces(bobAddr), 5, "nonce should be 5");

        // Order with nonce=0 should now fail (nonce < current)
        vm.prank(operator);
        vm.expectRevert(Exchange.InvalidNonce.selector);
        exchange.matchOrders(bobOrder, carolOrder, 10_000_000, bobSig, carolSig, MatchType.MINT);
    }

    function test_nonceBump_mustIncrease() public {
        vm.prank(bobAddr);
        exchange.bumpNonce(3);

        // Trying to bump to a lower value should fail
        vm.prank(bobAddr);
        vm.expectRevert("nonce not increased");
        exchange.bumpNonce(2);

        // Trying to bump to same value should fail
        vm.prank(bobAddr);
        vm.expectRevert("nonce not increased");
        exchange.bumpNonce(3);
    }

    function test_nonceBump_orderWithValidNonceStillWorks() public {
        // Bump to nonce=2
        vm.prank(bobAddr);
        exchange.bumpNonce(2);

        // Order with nonce=2 should still work (nonce >= current)
        uint256 fillAmount = 1_000_000;
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        bobOrder.nonce = 2;

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );
        carolOrder.nonce = 0; // Carol's nonce is still 0

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        assertEq(shareToken.balanceOf(bobAddr, yesTokenId), fillAmount, "match should succeed");
    }

    // ============================================================
    // 7. Expired Order
    // ============================================================

    function test_expiredOrder_takerExpired() public {
        // Warp to a future timestamp so we can set expiration in the past
        vm.warp(1000);

        uint256 fillAmount = 1_000_000;

        // Bob's order already expired
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        bobOrder.expiration = block.timestamp - 1;

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.OrderExpired.selector
        );
    }

    function test_expiredOrder_makerExpired() public {
        vm.warp(1000);

        uint256 fillAmount = 1_000_000;

        // Taker order has no expiry, maker order is expired
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        bobOrder.expiration = 0; // No expiry

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );
        carolOrder.expiration = block.timestamp - 1; // Expired

        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.OrderExpired.selector
        );
    }

    function test_validExpiration_inFuture() public {
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        bobOrder.expiration = block.timestamp + 1 hours;

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );
        carolOrder.expiration = block.timestamp + 2 hours;

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        assertEq(
            shareToken.balanceOf(bobAddr, yesTokenId),
            fillAmount,
            "match with valid expiration should succeed"
        );
    }

    // ============================================================
    // 8. Fill Capacity — partial fills and overfill
    // ============================================================

    function test_partialFill_thenRemainder() public {
        uint256 totalShares = 10_000_000;
        uint256 priceBps = 5000;
        uint256 totalUsdc = totalShares * priceBps / 10_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, totalUsdc, totalShares, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, totalUsdc, totalShares, Side.No
        );

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        // Partial fill: 4M out of 10M
        uint256 firstFill = 4_000_000;
        _matchAsOperatorPresigned(bobOrder, carolOrder, firstFill, bobSig, carolSig);

        assertEq(
            shareToken.balanceOf(bobAddr, yesTokenId),
            firstFill,
            "bob should have 4M shares after partial fill"
        );

        // Fill the remainder: 6M
        uint256 secondFill = 6_000_000;
        _matchAsOperatorPresigned(bobOrder, carolOrder, secondFill, bobSig, carolSig);

        assertEq(
            shareToken.balanceOf(bobAddr, yesTokenId),
            totalShares,
            "bob should have all 10M shares after second fill"
        );
    }

    function test_overfill_reverts() public {
        uint256 totalShares = 5_000_000;
        uint256 priceBps = 5000;
        uint256 totalUsdc = totalShares * priceBps / 10_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, totalUsdc, totalShares, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, totalUsdc, totalShares, Side.No
        );

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        // Fill the full amount first
        _matchAsOperatorPresigned(bobOrder, carolOrder, totalShares, bobSig, carolSig);

        // Try to fill even 1 more — should revert
        vm.prank(operator);
        vm.expectRevert("taker fill capacity");
        exchange.matchOrders(bobOrder, carolOrder, 1, bobSig, carolSig, MatchType.MINT);
    }

    function test_fillCapacity_partialThenOverfill() public {
        uint256 totalShares = 10_000_000;
        uint256 priceBps = 5000;
        uint256 totalUsdc = totalShares * priceBps / 10_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, totalUsdc, totalShares, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, totalUsdc, totalShares, Side.No
        );

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        // Fill 7M out of 10M
        _matchAsOperatorPresigned(bobOrder, carolOrder, 7_000_000, bobSig, carolSig);

        // Try to fill 4M more (would exceed capacity by 1M) — should revert
        vm.prank(operator);
        vm.expectRevert("taker fill capacity");
        exchange.matchOrders(bobOrder, carolOrder, 4_000_000, bobSig, carolSig, MatchType.MINT);
    }

    // ============================================================
    // 9. Condition Paused — after resolution, trading should be blocked
    // ============================================================

    function test_conditionPaused_afterResolution() public {
        // First, mint some shares via a trade
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        // Fast-forward past deadline and resolve the market
        MarketLMSR lmsr = MarketLMSR(market);
        vm.warp(lmsr.deadline() + 1);

        // Propose resolution
        vm.prank(admin);
        shareToken.proposeResolution(conditionId, Outcome.Yes);

        // Fast-forward past dispute period
        vm.warp(block.timestamp + 24 hours + 1);

        // Finalize — this should pause the condition in Exchange
        shareToken.finalizeResolution(conditionId);

        // Verify condition is paused
        assertTrue(exchange.conditionPaused(conditionId), "condition should be paused after resolution");

        // Now try to match new orders — should revert
        Order memory bobOrder2 = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        bobOrder2.salt = 999;

        Order memory carolOrder2 = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );
        carolOrder2.salt = 998;

        _matchAsOperatorExpectRevert(
            bobOrder2, carolOrder2, fillAmount, bobPk, carolPk, Exchange.ConditionIsPaused.selector
        );
    }

    function test_conditionPaused_adminCanPause() public {
        // Admin pauses condition directly
        vm.prank(admin);
        exchange.pauseCondition(conditionId);
        assertTrue(exchange.conditionPaused(conditionId), "admin should be able to pause");

        uint256 fillAmount = 1_000_000;
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.ConditionIsPaused.selector
        );
    }

    function test_conditionPaused_adminCanUnpause() public {
        vm.prank(admin);
        exchange.pauseCondition(conditionId);

        vm.prank(admin);
        exchange.unpauseCondition(conditionId);
        assertFalse(exchange.conditionPaused(conditionId), "condition should be unpaused");

        // Trading should work again
        uint256 fillAmount = 1_000_000;
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        assertEq(shareToken.balanceOf(bobAddr, yesTokenId), fillAmount, "should trade after unpause");
    }

    // ============================================================
    // 10. Fee Exceeds Max
    // ============================================================

    function test_feeExceedsMax_takerOrder() public {
        uint256 fillAmount = 1_000_000;

        // Bob's order has maxFeeBps = 10 (0.1%), but total fee is 100 (1%)
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        bobOrder.maxFeeBps = 10;

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.FeeExceedsMax.selector
        );
    }

    function test_feeExceedsMax_makerOrder() public {
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );

        // Carol's order has maxFeeBps too low
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );
        carolOrder.maxFeeBps = 10;

        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.FeeExceedsMax.selector
        );
    }

    function test_feeExceedsMax_exactlyEqual() public {
        uint256 fillAmount = 1_000_000;

        // Total fee is protocolFeeBps + creatorFeeBps = 50 + 50 = 100
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        bobOrder.maxFeeBps = 100; // Exactly matches total fee

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );
        carolOrder.maxFeeBps = 100;

        // Should succeed since fee == maxFee (not strictly >)
        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        assertEq(
            shareToken.balanceOf(bobAddr, yesTokenId),
            fillAmount,
            "exact fee should work"
        );
    }

    // ============================================================
    // 11. Only Operator Can Match
    // ============================================================

    function test_onlyOperator_canMatchOrders() public {
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        // Alice (non-operator) tries to match
        vm.prank(alice);
        vm.expectRevert(Exchange.NotOperator.selector);
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.MINT);

        // Bob (non-operator) tries to match
        vm.prank(bobAddr);
        vm.expectRevert(Exchange.NotOperator.selector);
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.MINT);

        // Admin (not operator) tries to match
        vm.prank(admin);
        vm.expectRevert(Exchange.NotOperator.selector);
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.MINT);
    }

    function test_operatorCanMatch() public {
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        assertEq(shareToken.balanceOf(bobAddr, yesTokenId), fillAmount, "operator match should work");
    }

    // ============================================================
    // 12. Taker Restriction
    // ============================================================

    function test_takerRestriction_correctTaker() public {
        uint256 fillAmount = 1_000_000;

        // Bob specifies carol as taker
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        bobOrder.taker = carolAddr;

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        assertEq(
            shareToken.balanceOf(bobAddr, yesTokenId),
            fillAmount,
            "restricted taker match should work"
        );
    }

    function test_takerRestriction_wrongTaker() public {
        uint256 fillAmount = 1_000_000;

        // Create a third actor
        uint256 davePk = 0xDA7E;
        address daveAddr = vm.addr(davePk);
        _fundAccount(daveAddr);

        // Bob specifies dave as taker, but carol is the counterparty
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        bobOrder.taker = daveAddr;

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.InvalidTaker.selector
        );
    }

    function test_takerRestriction_makerSideRestriction() public {
        uint256 fillAmount = 1_000_000;

        uint256 davePk = 0xDA7E;
        address daveAddr = vm.addr(davePk);
        _fundAccount(daveAddr);

        // Carol (maker) specifies dave as taker, but bob is the taker
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );

        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );
        carolOrder.taker = daveAddr;

        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.InvalidTaker.selector
        );
    }

    // ============================================================
    // Additional: Zero Fill Amount
    // ============================================================

    function test_zeroFillAmount_reverts() public {
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        vm.prank(operator);
        vm.expectRevert(Exchange.ZeroFillAmount.selector);
        exchange.matchOrders(bobOrder, carolOrder, 0, bobSig, carolSig, MatchType.MINT);
    }

    // ============================================================
    // Additional: Invalid Signature
    // ============================================================

    function test_invalidSignature_reverts() public {
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        // Sign bob's order with carol's key (wrong signer)
        bytes memory wrongBobSig = _signOrder(bobOrder, carolPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        vm.prank(operator);
        vm.expectRevert(Exchange.InvalidSignature.selector);
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, wrongBobSig, carolSig, MatchType.MINT);
    }

    // ============================================================
    // Additional: Exchange Global Pause
    // ============================================================

    function test_globalPause_blocksMatching() public {
        vm.prank(admin);
        exchange.pause();
        assertTrue(exchange.paused(), "exchange should be paused");

        uint256 fillAmount = 1_000_000;
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.ExchangePaused.selector
        );
    }

    function test_globalPause_unblockAfterUnpause() public {
        vm.prank(admin);
        exchange.pause();

        vm.prank(admin);
        exchange.unpause();

        uint256 fillAmount = 1_000_000;
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        assertEq(shareToken.balanceOf(bobAddr, yesTokenId), fillAmount, "should work after unpause");
    }

    // ============================================================
    // Additional: Token Not Registered
    // ============================================================

    function test_unregisteredToken_reverts() public {
        uint256 fillAmount = 1_000_000;
        uint256 fakeTokenId = 999999;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, fakeTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.TokenNotRegistered.selector
        );
    }

    // ============================================================
    // Additional: Vault Invariant After Exchange Trades
    // ============================================================

    function test_vaultInvariant_afterExchangeTrades() public {
        // Perform several MINT matches
        for (uint256 i = 0; i < 3; i++) {
            uint256 fillAmount = 2_000_000;
            uint256 priceBps = 5000;
            uint256 usdcAmount = fillAmount * priceBps / 10_000;

            Order memory bobOrder = _makeBuyOrder(
                bobAddr, bobAddr, yesTokenId, usdcAmount, fillAmount, Side.Yes
            );
            bobOrder.salt = i * 1000 + 1;

            Order memory carolOrder = _makeBuyOrder(
                carolAddr, carolAddr, noTokenId, usdcAmount, fillAmount, Side.No
            );
            carolOrder.salt = i * 1000 + 2;

            _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);
        }

        // Check invariant: USDC.balanceOf(vault) >= totalBalances + splitReserve + feePool
        uint256 usdcBalance = usdc.balanceOf(address(vault));
        uint256 accounting = vault.totalBalances() + vault.splitReserve() + vault.feePool();

        assertGe(usdcBalance, accounting, "vault invariant should hold after exchange trades");
    }

    // ============================================================
    // Additional: Admin Functions
    // ============================================================

    function test_setOperator_onlyAdmin() public {
        address newOperator = makeAddr("newOperator");

        vm.prank(admin);
        exchange.setOperator(newOperator);
        assertEq(exchange.operator(), newOperator, "operator should be updated");

        // Non-admin cannot set operator
        vm.prank(bobAddr);
        vm.expectRevert(Exchange.NotAdmin.selector);
        exchange.setOperator(bobAddr);
    }

    function test_setProtocolFeeBps_onlyAdmin() public {
        vm.prank(admin);
        exchange.setProtocolFeeBps(100); // 1%
        assertEq(exchange.protocolFeeBps(), 100, "fee should be updated");

        // Non-admin cannot set fee
        vm.prank(bobAddr);
        vm.expectRevert(Exchange.NotAdmin.selector);
        exchange.setProtocolFeeBps(200);
    }

    function test_setProtocolFeeBps_maxLimit() public {
        // Cannot exceed 5% (500 bps)
        vm.prank(admin);
        vm.expectRevert("fee too high");
        exchange.setProtocolFeeBps(501);
    }

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        exchange.transferAdmin(newAdmin);
        assertEq(exchange.admin(), newAdmin, "admin should be transferred");

        // Old admin can no longer act
        vm.prank(admin);
        vm.expectRevert(Exchange.NotAdmin.selector);
        exchange.pause();

        // New admin can act
        vm.prank(newAdmin);
        exchange.pause();
        assertTrue(exchange.paused(), "new admin should be able to pause");
    }

    // ============================================================
    // Additional: Fee Withdrawal
    // ============================================================

    function test_withdrawProtocolFees() public {
        // Generate some fees via MINT match
        uint256 fillAmount = 10_000_000;
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 5_000_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 5_000_000, fillAmount, Side.No
        );

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        uint256 protocolFees = exchange.protocolFeesAccumulated();
        assertTrue(protocolFees > 0, "should have protocol fees");

        uint256 protocolBalBefore = vault.balances(protocolAddress);

        vm.prank(protocolAddress);
        exchange.withdrawProtocolFees();

        assertEq(exchange.protocolFeesAccumulated(), 0, "protocol fees should be zero after withdrawal");
        assertEq(
            vault.balances(protocolAddress) - protocolBalBefore,
            protocolFees,
            "protocol should receive fees"
        );
    }

    function test_withdrawCreatorFees() public {
        // Generate fees
        uint256 fillAmount = 10_000_000;
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 5_000_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 5_000_000, fillAmount, Side.No
        );

        _matchAsOperator(bobOrder, carolOrder, fillAmount, bobPk, carolPk);

        uint256 creatorFees = exchange.creatorFeesAccumulated(conditionId);
        assertTrue(creatorFees > 0, "should have creator fees");

        uint256 aliceBalBefore = vault.balances(alice); // alice is the market creator

        vm.prank(alice);
        exchange.withdrawCreatorFees(conditionId);

        assertEq(
            exchange.creatorFeesAccumulated(conditionId),
            0,
            "creator fees should be zero after withdrawal"
        );
        assertEq(
            vault.balances(alice) - aliceBalBefore,
            creatorFees,
            "creator should receive fees"
        );
    }

    // ============================================================
    // Additional: getOrderHash view
    // ============================================================

    function test_getOrderHash_matchesInternalHash() public view {
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, 1_000_000, Side.Yes
        );

        // The external getOrderHash wraps _hashOrder with _hashTypedDataV4
        bytes32 externalHash = exchange.getOrderHash(bobOrder);
        bytes32 localDigest = _getDigest(bobOrder);

        assertEq(externalHash, localDigest, "external and local hash should match");
    }

    // ============================================================
    // Additional: Condition Mismatch
    // ============================================================

    function test_conditionMismatch_reverts() public {
        // Create a second market with a different question to avoid ConditionAlreadyPrepared
        (address market2,) = _createMarketWithPrice(alice, 5000);
        uint256 market2YesId = MarketLMSR(market2).yesTokenId();

        uint256 fillAmount = 1_000_000;

        // Bob order on market1 YES, carol order on market2 YES — different conditions
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, market2YesId, 500_000, fillAmount, Side.Yes
        );

        _matchAsOperatorExpectRevertStr(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, "condition mismatch"
        );
    }

    // ============================================================
    // C-1: Cancel order prevents matching (end-to-end)
    // ============================================================

    function test_cancelOrder_preventsMatch() public {
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        // Bob cancels his order
        vm.prank(bobAddr);
        exchange.cancelOrder(bobOrder);

        // Try to match — should revert with OrderAlreadyCancelled
        _matchAsOperatorExpectRevert(
            bobOrder, carolOrder, fillAmount, bobPk, carolPk, Exchange.OrderAlreadyCancelled.selector
        );
    }

    function test_cancelOrder_hashMatchesGetOrderHash() public {
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, 1_000_000, Side.Yes
        );

        // Cancel the order
        vm.prank(bobAddr);
        exchange.cancelOrder(bobOrder);

        // The digest used by cancelOrder should match getOrderHash
        bytes32 externalHash = exchange.getOrderHash(bobOrder);
        assertTrue(exchange.ordersCancelled(externalHash), "getOrderHash should match cancel key");
    }

    // ============================================================
    // C-2: MERGE match — two sellers merge complementary tokens
    // ============================================================

    function test_merge_basicMatch() public {
        // First, create shares via MINT
        uint256 mintAmount = 10_000_000;
        uint256 priceBps = 5000;
        uint256 usdcAmount = mintAmount * priceBps / 10_000;

        Order memory bobBuy = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, usdcAmount, mintAmount, Side.Yes
        );
        Order memory carolBuy = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, usdcAmount, mintAmount, Side.No
        );
        _matchAsOperator(bobBuy, carolBuy, mintAmount, bobPk, carolPk);

        // Verify shares exist
        assertEq(shareToken.balanceOf(bobAddr, yesTokenId), mintAmount);
        assertEq(shareToken.balanceOf(carolAddr, noTokenId), mintAmount);

        // Both approve exchange to transfer their shares
        _approveExchange(bobAddr);
        _approveExchange(carolAddr);

        // Now both want to sell — bob sells YES, carol sells NO → MERGE
        uint256 sellAmount = 5_000_000;
        uint256 sellPrice = 5000;
        uint256 usdcWanted = sellAmount * sellPrice / 10_000;

        Order memory bobSell = _makeSellOrder(
            bobAddr, bobAddr, yesTokenId, sellAmount, usdcWanted, Side.Yes
        );
        bobSell.salt = 12345;
        Order memory carolSell = _makeSellOrder(
            carolAddr, carolAddr, noTokenId, sellAmount, usdcWanted, Side.No
        );
        carolSell.salt = 67890;

        uint256 bobUsdcBefore = vault.balances(bobAddr);
        uint256 carolUsdcBefore = vault.balances(carolAddr);
        uint256 splitReserveBefore = vault.splitReserve();

        // Match as MERGE
        _matchAsOperatorWithType(bobSell, carolSell, sellAmount, bobPk, carolPk, MatchType.MERGE);

        // Verify: shares burned
        assertEq(
            shareToken.balanceOf(bobAddr, yesTokenId),
            mintAmount - sellAmount,
            "bob YES shares should decrease"
        );
        assertEq(
            shareToken.balanceOf(carolAddr, noTokenId),
            mintAmount - sellAmount,
            "carol NO shares should decrease"
        );

        // Verify: USDC released (sellers get paid)
        assertTrue(vault.balances(bobAddr) > bobUsdcBefore, "bob should receive USDC from merge");
        assertTrue(vault.balances(carolAddr) > carolUsdcBefore, "carol should receive USDC from merge");

        // Verify: splitReserve decreased
        assertTrue(vault.splitReserve() < splitReserveBefore, "splitReserve should decrease after merge");
    }

    function test_merge_invalidMatchType_reverts() public {
        uint256 fillAmount = 1_000_000;

        // Two buy orders on different tokens — should be MINT, not COMPLEMENTARY
        Order memory bobOrder = _makeBuyOrder(
            bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No
        );

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        // Operator incorrectly specifies COMPLEMENTARY for different-token orders
        vm.prank(operator);
        vm.expectRevert("different tokens must be MINT or MERGE");
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.COMPLEMENTARY);
    }

    // ============================================================
    // H-2: Delegation spend recording in Exchange
    // ============================================================

    function test_delegatedOrder_recordsSpend() public {
        // Setup: create a delegated signer for bob
        uint256 delegatePk = 0xDE1E;
        address delegateAddr = vm.addr(delegatePk);

        // Bob delegates to delegateAddr via DelegationRegistry
        vm.prank(bobAddr);
        delegationRegistry.setDelegation(
            delegateAddr,
            address(0), // any scope
            1_000_000_000, // 1000 USDC daily limit
            0  // no expiry
        );

        uint256 fillAmount = 1_000_000;
        uint256 priceBps = 5000;
        uint256 usdcAmount = fillAmount * priceBps / 10_000;

        // Bob's order signed by delegate
        Order memory bobOrder = _makeOrder(
            bobAddr,       // maker = bob
            delegateAddr,  // signer = delegate
            yesTokenId,
            usdcAmount,
            fillAmount,
            Side.Yes,
            0, 10_000, 0, address(0)
        );

        // Carol's normal order
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, usdcAmount, fillAmount, Side.No
        );

        // Sign bob's order with delegate key, carol's with her own
        bytes memory bobSig = _signOrder(bobOrder, delegatePk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        vm.prank(operator);
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.MINT);

        // Verify delegation spend was recorded
        (,,, uint256 spentToday,,) = delegationRegistry.delegations(bobAddr, delegateAddr);
        assertTrue(spentToday > 0, "delegation spend should be recorded");
    }

    function test_delegatedOrder_dailyLimitEnforced() public {
        uint256 delegatePk = 0xDE1E;
        address delegateAddr = vm.addr(delegatePk);

        // Bob delegates with very low daily limit (1 USDC = 1_000_000)
        vm.prank(bobAddr);
        delegationRegistry.setDelegation(
            delegateAddr,
            address(0),
            1_000_000, // 1 USDC daily limit
            0
        );

        // Trade notional = 200 USDC — far exceeds 1 USDC daily limit
        uint256 fillAmount = 400_000_000; // 400 shares
        uint256 priceBps = 5000;
        uint256 usdcAmount = fillAmount * priceBps / 10_000; // 200_000_000 = 200 USDC

        // Fund bob and carol with enough USDC
        _fundAccount(bobAddr);
        _fundAccount(carolAddr);

        Order memory bobOrder = _makeOrder(
            bobAddr, delegateAddr, yesTokenId,
            usdcAmount, fillAmount, Side.Yes,
            0, 10_000, 0, address(0)
        );
        Order memory carolOrder = _makeBuyOrder(
            carolAddr, carolAddr, noTokenId, usdcAmount, fillAmount, Side.No
        );

        bytes memory bobSig = _signOrder(bobOrder, delegatePk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        // Should revert due to daily limit exceeded in recordSpend
        vm.prank(operator);
        vm.expectRevert();
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.MINT);
    }
}
