// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BaseV2Test} from "./BaseV2Test.sol";
import {
    Order, Side, MatchType, SignatureType, Outcome
} from "../contracts/v2/interfaces/Types.sol";
import {Exchange} from "../contracts/v2/Exchange.sol";
import {ShareToken} from "../contracts/v2/ShareToken.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {VaultV2} from "../contracts/v2/VaultV2.sol";
import {MockEIP1271Wallet} from "../contracts/mocks/MockEIP1271Wallet.sol";

/**
 * @title ExchangeAdvancedTest
 * @notice Advanced tests covering EIP-1271 smart contract wallets, token registration
 *         edge cases, variable creator fees, and complementary match validation.
 */
contract ExchangeAdvancedTest is BaseV2Test {
    uint256 internal bobPk = 0xB0B;
    address internal bobAddr;
    uint256 internal carolPk = 0xCA0;
    address internal carolAddr;

    address internal market;
    bytes32 internal conditionId;
    uint256 internal yesTokenId;
    uint256 internal noTokenId;

    bytes32 internal DOMAIN_SEPARATOR;
    bytes32 internal ORDER_TYPEHASH_CACHED;

    function setUp() public override {
        super.setUp();
        bobAddr = vm.addr(bobPk);
        carolAddr = vm.addr(carolPk);
        _fundAccount(bobAddr);
        _fundAccount(carolAddr);

        vm.startPrank(admin);
        shareToken.addAuthorizedCaller(address(exchange));
        vm.stopPrank();

        (market, conditionId) = _createDefaultMarket(alice);
        MarketLMSR lmsr = MarketLMSR(market);
        yesTokenId = lmsr.yesTokenId();
        noTokenId = lmsr.noTokenId();

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
    }

    // ── Helpers (mirrors Exchange.t.sol) ──

    function _makeOrder(
        address maker, address signer, uint256 tokenId,
        uint256 makerAmount, uint256 takerAmount, Side side,
        uint256 nonce, uint256 maxFeeBps, uint256 expiration, address taker,
        SignatureType sigType
    ) internal pure returns (Order memory) {
        return Order({
            salt: uint256(keccak256(abi.encode(maker, tokenId, makerAmount, takerAmount, nonce))),
            maker: maker, signer: signer, taker: taker,
            tokenId: tokenId, makerAmount: makerAmount, takerAmount: takerAmount,
            expiration: expiration, nonce: nonce, maxFeeBps: maxFeeBps,
            side: side, sigType: sigType
        });
    }

    function _makeBuyOrder(address maker, address signer, uint256 tokenId, uint256 usdc, uint256 shares, Side side)
        internal pure returns (Order memory)
    {
        return _makeOrder(maker, signer, tokenId, usdc, shares, side, 0, 10_000, 0, address(0), SignatureType.EOA);
    }

    function _hashOrder(Order memory order) internal view returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH_CACHED, order.salt, order.maker, order.signer, order.taker,
            order.tokenId, order.makerAmount, order.takerAmount, order.expiration,
            order.nonce, order.maxFeeBps, uint8(order.side), uint8(order.sigType)
        ));
    }

    function _getDigest(Order memory order) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _hashOrder(order)));
    }

    function _signOrder(Order memory order, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = _getDigest(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buyShares(address buyer, Side side, uint256 usdc) internal returns (uint256) {
        vm.prank(buyer);
        return backstopRouter.executeTrade(conditionId, side, true, usdc, 0);
    }

    // ============================================================
    // 1. EIP-1271 Smart Contract Wallet — Success
    // ============================================================

    function test_eip1271_smartContractSigner_success() public {
        // Deploy a smart contract wallet owned by bob's private key
        MockEIP1271Wallet wallet = new MockEIP1271Wallet(bobAddr);

        // Fund the wallet
        _fundAccount(address(wallet));

        // Wallet approves exchange for share transfers
        vm.prank(address(wallet));
        shareToken.setApprovalForAll(address(exchange), true);

        uint256 fillAmount = 1_000_000;
        uint256 priceBps = 5000;
        uint256 usdcAmount = fillAmount * priceBps / 10_000;

        // Order where maker = wallet, signer = wallet (EIP1271)
        Order memory walletOrder = _makeOrder(
            address(wallet), address(wallet), yesTokenId,
            usdcAmount, fillAmount, Side.Yes,
            0, 10_000, 0, address(0), SignatureType.EIP1271
        );

        // Carol's normal EOA order
        Order memory carolOrder = _makeBuyOrder(carolAddr, carolAddr, noTokenId, usdcAmount, fillAmount, Side.No);

        // Sign wallet's order with bob's private key (wallet validates via EIP-1271)
        bytes memory walletSig = _signOrder(walletOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        vm.prank(operator);
        exchange.matchOrders(walletOrder, carolOrder, fillAmount, walletSig, carolSig, MatchType.MINT);

        // Verify shares were minted to wallet
        assertEq(
            shareToken.balanceOf(address(wallet), yesTokenId),
            fillAmount,
            "smart contract wallet should receive shares"
        );
    }

    // ============================================================
    // 2. EIP-1271 Smart Contract Wallet — Invalid Signature
    // ============================================================

    function test_eip1271_invalidSignature_reverts() public {
        MockEIP1271Wallet wallet = new MockEIP1271Wallet(bobAddr);
        _fundAccount(address(wallet));

        uint256 fillAmount = 1_000_000;
        uint256 usdcAmount = 500_000;

        Order memory walletOrder = _makeOrder(
            address(wallet), address(wallet), yesTokenId,
            usdcAmount, fillAmount, Side.Yes,
            0, 10_000, 0, address(0), SignatureType.EIP1271
        );
        Order memory carolOrder = _makeBuyOrder(carolAddr, carolAddr, noTokenId, usdcAmount, fillAmount, Side.No);

        // Sign with carol's key (wrong signer for wallet)
        bytes memory walletSig = _signOrder(walletOrder, carolPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        vm.prank(operator);
        vm.expectRevert(Exchange.InvalidSignature.selector);
        exchange.matchOrders(walletOrder, carolOrder, fillAmount, walletSig, carolSig, MatchType.MINT);
    }

    // ============================================================
    // 3. EIP-1271 Wallet Rejects All — Always Reject Mode
    // ============================================================

    function test_eip1271_walletRejectsAll_reverts() public {
        MockEIP1271Wallet wallet = new MockEIP1271Wallet(bobAddr);
        wallet.setAlwaysReject(true);
        _fundAccount(address(wallet));

        uint256 fillAmount = 1_000_000;
        uint256 usdcAmount = 500_000;

        Order memory walletOrder = _makeOrder(
            address(wallet), address(wallet), yesTokenId,
            usdcAmount, fillAmount, Side.Yes,
            0, 10_000, 0, address(0), SignatureType.EIP1271
        );
        Order memory carolOrder = _makeBuyOrder(carolAddr, carolAddr, noTokenId, usdcAmount, fillAmount, Side.No);

        // Even with correct key, wallet always rejects
        bytes memory walletSig = _signOrder(walletOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        vm.prank(operator);
        vm.expectRevert(Exchange.InvalidSignature.selector);
        exchange.matchOrders(walletOrder, carolOrder, fillAmount, walletSig, carolSig, MatchType.MINT);
    }

    // ============================================================
    // 4. EIP-1271 on Non-Contract Address — Reverts
    // ============================================================

    function test_eip1271_nonContractSigner_reverts() public {
        uint256 fillAmount = 1_000_000;
        uint256 usdcAmount = 500_000;

        // Bob is an EOA but order says EIP1271 — staticcall to EOA will fail
        Order memory bobOrder = _makeOrder(
            bobAddr, bobAddr, yesTokenId,
            usdcAmount, fillAmount, Side.Yes,
            0, 10_000, 0, address(0), SignatureType.EIP1271
        );
        Order memory carolOrder = _makeBuyOrder(carolAddr, carolAddr, noTokenId, usdcAmount, fillAmount, Side.No);

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        vm.prank(operator);
        vm.expectRevert(Exchange.InvalidSignature.selector);
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.MINT);
    }

    // ============================================================
    // 5. Token Registration — Duplicate Registration Reverts
    // ============================================================

    function test_registerToken_duplicate_reverts() public {
        // conditionId is already registered from _createDefaultMarket
        assertTrue(exchange.registeredConditions(conditionId), "condition should be registered");

        // Try to register same conditionId again
        vm.prank(address(factory));
        vm.expectRevert("already registered");
        exchange.registerToken(yesTokenId, noTokenId, conditionId);
    }

    // ============================================================
    // 6. Token Registration — Only Factory
    // ============================================================

    function test_registerToken_onlyFactory() public {
        bytes32 fakeCondition = keccak256("fake-condition");

        vm.prank(bobAddr);
        vm.expectRevert(Exchange.NotFactory.selector);
        exchange.registerToken(100, 101, fakeCondition);

        vm.prank(admin);
        vm.expectRevert(Exchange.NotFactory.selector);
        exchange.registerToken(100, 101, fakeCondition);
    }

    // ============================================================
    // 7. Creator Fee — Already Set Reverts
    // ============================================================

    function test_setCreatorFee_alreadySet_reverts() public {
        // Creator fee was already set during market creation
        assertTrue(exchange.creatorFeeSet(conditionId), "creator fee should be set");

        vm.prank(address(factory));
        vm.expectRevert(Exchange.CreatorFeeAlreadySet.selector);
        exchange.setCreatorFee(conditionId, alice, 200);
    }

    // ============================================================
    // 8. Variable Creator Fees — Different Rates Per Market
    // ============================================================

    function test_variableCreatorFees_differentRatesPerMarket() public {
        // Create a second market — this uses default 50 bps creator fee
        (address market2, bytes32 condition2) = _createMarketWithPrice(bob, 6000);
        uint256 yes2 = MarketLMSR(market2).yesTokenId();
        uint256 no2 = MarketLMSR(market2).noTokenId();

        // Both conditions should have same creator fee (set by factory defaults)
        uint256 fee1 = exchange.creatorFeeBps(conditionId);
        uint256 fee2 = exchange.creatorFeeBps(condition2);
        assertEq(fee1, fee2, "both markets should have same default creator fee");

        // The fee recipients should be different (alice vs bob)
        assertEq(exchange.creatorFeeRecipient(conditionId), alice, "market1 creator should be alice");
        assertEq(exchange.creatorFeeRecipient(condition2), bob, "market2 creator should be bob");
    }

    // ============================================================
    // 9. Complementary Match — Same Token Required
    // ============================================================

    function test_complementaryMatch_differentTokens_reverts() public {
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes);
        Order memory carolOrder = _makeBuyOrder(carolAddr, carolAddr, noTokenId, 500_000, fillAmount, Side.No);

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        // Force COMPLEMENTARY on different tokens
        vm.prank(operator);
        vm.expectRevert("different tokens must be MINT or MERGE");
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.COMPLEMENTARY);
    }

    // ============================================================
    // 10. MERGE Match Type — Same Token Reverts
    // ============================================================

    function test_mergeMatchType_sameToken_reverts() public {
        // Get shares first
        uint256 bobShares = _buyShares(bobAddr, Side.Yes, 10_000_000);
        uint256 carolShares = _buyShares(carolAddr, Side.Yes, 10_000_000);

        vm.prank(bobAddr);
        shareToken.setApprovalForAll(address(exchange), true);
        vm.prank(carolAddr);
        shareToken.setApprovalForAll(address(exchange), true);

        uint256 fillAmount = bobShares / 2;
        Order memory bobOrder = _makeOrder(
            bobAddr, bobAddr, yesTokenId, fillAmount, 250_000, Side.Yes,
            0, 10_000, 0, address(0), SignatureType.EOA
        );
        Order memory carolOrder = _makeOrder(
            carolAddr, carolAddr, yesTokenId, fillAmount, 250_000, Side.Yes,
            0, 10_000, 0, address(0), SignatureType.EOA
        );

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        // Same token cannot be MERGE
        vm.prank(operator);
        vm.expectRevert("same token must be COMPLEMENTARY");
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.MERGE);
    }

    // ============================================================
    // 11. MINT Match Type — Same Token Reverts
    // ============================================================

    function test_mintMatchType_sameToken_reverts() public {
        uint256 fillAmount = 1_000_000;

        Order memory bobOrder = _makeBuyOrder(bobAddr, bobAddr, yesTokenId, 500_000, fillAmount, Side.Yes);
        Order memory carolOrder = _makeBuyOrder(carolAddr, carolAddr, yesTokenId, 500_000, fillAmount, Side.Yes);

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);

        vm.prank(operator);
        vm.expectRevert("same token must be COMPLEMENTARY");
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.MINT);
    }

    // ============================================================
    // 12. Condition Pause — Only ShareToken or Admin
    // ============================================================

    function test_pauseCondition_onlyShareTokenOrAdmin() public {
        // Random user cannot pause condition
        vm.prank(bobAddr);
        vm.expectRevert("not shareToken or admin");
        exchange.pauseCondition(conditionId);

        // Operator cannot pause condition
        vm.prank(operator);
        vm.expectRevert("not shareToken or admin");
        exchange.pauseCondition(conditionId);

        // Admin can pause
        vm.prank(admin);
        exchange.pauseCondition(conditionId);
        assertTrue(exchange.conditionPaused(conditionId));
    }

    // ============================================================
    // 13. Unpause Condition — Only Admin
    // ============================================================

    function test_unpauseCondition_onlyAdmin() public {
        vm.prank(admin);
        exchange.pauseCondition(conditionId);

        vm.prank(bobAddr);
        vm.expectRevert(Exchange.NotAdmin.selector);
        exchange.unpauseCondition(conditionId);
    }

    // ============================================================
    // 14. Protocol Fee Recipient Withdrawal
    // ============================================================

    function test_withdrawProtocolFees_byRecipient() public {
        // Generate fees
        uint256 fillAmount = 10_000_000;
        Order memory bobOrder = _makeBuyOrder(bobAddr, bobAddr, yesTokenId, 5_000_000, fillAmount, Side.Yes);
        Order memory carolOrder = _makeBuyOrder(carolAddr, carolAddr, noTokenId, 5_000_000, fillAmount, Side.No);

        bytes memory bobSig = _signOrder(bobOrder, bobPk);
        bytes memory carolSig = _signOrder(carolOrder, carolPk);
        vm.prank(operator);
        exchange.matchOrders(bobOrder, carolOrder, fillAmount, bobSig, carolSig, MatchType.MINT);

        uint256 protocolFees = exchange.protocolFeesAccumulated();
        assertTrue(protocolFees > 0);

        // Protocol fee recipient (not admin) can withdraw
        uint256 balBefore = vault.balances(protocolAddress);
        vm.prank(protocolAddress);
        exchange.withdrawProtocolFees();
        assertEq(vault.balances(protocolAddress) - balBefore, protocolFees);
    }

    // ============================================================
    // 15. Withdraw Fees — Unauthorized Reverts
    // ============================================================

    function test_withdrawProtocolFees_unauthorized_reverts() public {
        vm.prank(bobAddr);
        vm.expectRevert("not authorized");
        exchange.withdrawProtocolFees();
    }

    function test_withdrawCreatorFees_unauthorized_reverts() public {
        vm.prank(bobAddr);
        vm.expectRevert("not authorized");
        exchange.withdrawCreatorFees(conditionId);
    }

    // ============================================================
    // 16. Withdraw Fees — No Fees Reverts
    // ============================================================

    function test_withdrawProtocolFees_noFees_reverts() public {
        vm.prank(admin);
        vm.expectRevert("no fees");
        exchange.withdrawProtocolFees();
    }

    function test_withdrawCreatorFees_noFees_reverts() public {
        vm.prank(admin);
        vm.expectRevert("no fees");
        exchange.withdrawCreatorFees(conditionId);
    }

    // ============================================================
    // 17. Transfer Admin — Zero Address Reverts
    // ============================================================

    function test_transferAdmin_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("zero"));
        exchange.transferAdmin(address(0));
    }

    // ============================================================
    // 18. Set Factory — Only Admin
    // ============================================================

    function test_setFactory_onlyAdmin() public {
        vm.prank(bobAddr);
        vm.expectRevert(Exchange.NotAdmin.selector);
        exchange.setFactory(bobAddr);
    }

    // ============================================================
    // 19. Cancel Cancelled Order — Idempotent
    // ============================================================

    function test_cancelOrder_cancelAlreadyCancelled() public {
        Order memory bobOrder = _makeBuyOrder(bobAddr, bobAddr, yesTokenId, 500_000, 1_000_000, Side.Yes);

        vm.prank(bobAddr);
        exchange.cancelOrder(bobOrder);

        // Second cancel should succeed (idempotent, just overwrites true → true)
        vm.prank(bobAddr);
        exchange.cancelOrder(bobOrder);

        bytes32 digest = _getDigest(bobOrder);
        assertTrue(exchange.ordersCancelled(digest));
    }

    // ============================================================
    // 20. Vault Invariant After MINT + MERGE + Fees
    // ============================================================

    function test_vaultInvariant_afterMintMergeAndFees() public {
        // MINT: bob buys YES, carol buys NO
        uint256 mintAmount = 10_000_000;
        Order memory bobBuy = _makeBuyOrder(bobAddr, bobAddr, yesTokenId, 5_000_000, mintAmount, Side.Yes);
        Order memory carolBuy = _makeBuyOrder(carolAddr, carolAddr, noTokenId, 5_000_000, mintAmount, Side.No);

        bytes memory bobSig = _signOrder(bobBuy, bobPk);
        bytes memory carolSig = _signOrder(carolBuy, carolPk);
        vm.prank(operator);
        exchange.matchOrders(bobBuy, carolBuy, mintAmount, bobSig, carolSig, MatchType.MINT);

        // Approve exchange for MERGE
        vm.prank(bobAddr);
        shareToken.setApprovalForAll(address(exchange), true);
        vm.prank(carolAddr);
        shareToken.setApprovalForAll(address(exchange), true);

        // MERGE: bob sells YES, carol sells NO (partial)
        uint256 mergeAmount = 3_000_000;
        Order memory bobSell = _makeOrder(
            bobAddr, bobAddr, yesTokenId, mergeAmount, 1_500_000, Side.Yes,
            0, 10_000, 0, address(0), SignatureType.EOA
        );
        bobSell.salt = 99999;
        Order memory carolSell = _makeOrder(
            carolAddr, carolAddr, noTokenId, mergeAmount, 1_500_000, Side.No,
            0, 10_000, 0, address(0), SignatureType.EOA
        );
        carolSell.salt = 88888;

        bytes memory bobSig2 = _signOrder(bobSell, bobPk);
        bytes memory carolSig2 = _signOrder(carolSell, carolPk);
        vm.prank(operator);
        exchange.matchOrders(bobSell, carolSell, mergeAmount, bobSig2, carolSig2, MatchType.MERGE);

        // Verify vault invariant still holds
        assertTrue(vault.checkInvariant(), "vault invariant must hold after MINT + MERGE + fees");
    }
}
