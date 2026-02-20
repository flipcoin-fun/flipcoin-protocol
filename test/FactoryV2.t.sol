// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {BaseV2Test} from "./BaseV2Test.sol";
import {
    MarketParams, MarketInfo
} from "../contracts/v2/interfaces/Types.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {FactoryV2} from "../contracts/v2/FactoryV2.sol";

/**
 * @title FactoryV2Test
 * @notice Comprehensive tests for FactoryV2 contract — all 3 creation modes,
 *         param validation, EIP-712 signatures, delegation, replay protection, pausing.
 */
contract FactoryV2Test is BaseV2Test {
    // ============================================================
    // Constants — EIP-712 Typehashes (mirrors FactoryV2)
    // ============================================================

    bytes32 internal constant CREATE_MARKET_TYPEHASH = keccak256(
        "CreateMarket(bytes32 paramsHash,uint256 seedUsdc,uint256 initialPriceYesBps,"
        "uint256 nonce,uint256 deadline,bytes32 requestId)"
    );

    bytes32 internal constant DELEGATED_CREATE_TYPEHASH = keccak256(
        "DelegatedCreateMarket(bytes32 paramsHash,uint256 seedUsdc,uint256 initialPriceYesBps,"
        "uint256 nonce,uint256 deadline,bytes32 requestId,address owner)"
    );

    // ============================================================
    // Helpers — Default Params
    // ============================================================

    function _defaultParams() internal view returns (MarketParams memory) {
        return MarketParams({
            question: "Will ETH reach $10k by end of 2026?",
            description: "Resolves based on CoinGecko ETH/USD price",
            category: "crypto",
            resolutionRules: "Resolve YES if ETH price exceeds $10,000 at any point before deadline",
            resolutionSource: "https://www.coingecko.com/en/coins/ethereum",
            imageUrl: "https://example.com/eth.png",
            deadline: uint64(block.timestamp + 7 days)
        });
    }

    // ============================================================
    // Helpers — EIP-712 Hashing
    // ============================================================

    function _computeParamsHash(MarketParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            keccak256(bytes(params.question)),
            keccak256(bytes(params.description)),
            keccak256(bytes(params.category)),
            keccak256(bytes(params.resolutionRules)),
            keccak256(bytes(params.resolutionSource)),
            keccak256(bytes(params.imageUrl)),
            params.deadline
        ));
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

    // ============================================================
    // Helpers — Mode A Signature (CreateMarket)
    // ============================================================

    function _signCreateMarket(
        uint256 signerPk,
        MarketParams memory params,
        uint256 seedUsdc,
        uint256 initialPriceYesBps,
        uint256 nonce,
        uint256 deadline,
        bytes32 requestId
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 paramsHash = _computeParamsHash(params);

        bytes32 structHash = keccak256(abi.encode(
            CREATE_MARKET_TYPEHASH,
            paramsHash,
            seedUsdc,
            initialPriceYesBps,
            nonce,
            deadline,
            requestId
        ));

        bytes32 digest = _hashTypedDataV4Factory(structHash);
        (v, r, s) = vm.sign(signerPk, digest);
    }

    // ============================================================
    // Helpers — Mode B Signature (DelegatedCreateMarket)
    // ============================================================

    function _signDelegatedCreateMarket(
        uint256 signerPk,
        MarketParams memory params,
        uint256 seedUsdc,
        uint256 initialPriceYesBps,
        uint256 nonce,
        uint256 deadline,
        bytes32 requestId,
        address owner
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 paramsHash = _computeParamsHash(params);

        bytes32 structHash = keccak256(abi.encode(
            DELEGATED_CREATE_TYPEHASH,
            paramsHash,
            seedUsdc,
            initialPriceYesBps,
            nonce,
            deadline,
            requestId,
            owner
        ));

        bytes32 digest = _hashTypedDataV4Factory(structHash);
        (v, r, s) = vm.sign(signerPk, digest);
    }

    // ============================================================
    // 1. Mode 0 (Direct) — basic market creation
    // ============================================================

    function test_mode0_direct_createMarket() public {
        MarketParams memory params = _defaultParams();
        uint256 aliceBalBefore = vault.balances(alice);

        vm.prank(alice);
        address market = factory.createMarket(params, SEED_USDC, 5000);

        // Market address is non-zero
        assertTrue(market != address(0), "market should be deployed");

        // MarketLMSR state is correct
        MarketLMSR lmsr = MarketLMSR(market);
        assertTrue(lmsr.initialized(), "should be initialized");
        assertTrue(lmsr.configSet(), "should be configured");
        assertEq(lmsr.creator(), alice, "creator should be alice");
        assertEq(lmsr.admin(), admin, "admin should match");
        assertEq(lmsr.vault(), address(vault), "vault should match");
        assertEq(lmsr.factory(), address(factory), "factory should match");
        assertEq(lmsr.backstopRouter(), address(backstopRouter), "backstopRouter should match");
        assertEq(lmsr.shareToken(), address(shareToken), "shareToken should match");
        assertEq(lmsr.protocolAddress(), protocolAddress, "protocolAddress should match");
        assertEq(lmsr.deadline(), params.deadline, "deadline should match");
        assertEq(lmsr.question(), params.question, "question should match");
        assertEq(lmsr.totalFeeBps(), DEFAULT_TOTAL_FEE_BPS, "totalFeeBps should match");
        assertEq(lmsr.creatorFeeBps(), DEFAULT_CREATOR_FEE_BPS, "creatorFeeBps should match");
        assertEq(lmsr.protocolFeeBps(), DEFAULT_PROTOCOL_FEE_BPS, "protocolFeeBps should match");

        // Token IDs are valid and distinct
        bytes32 conditionId = lmsr.conditionId();
        assertTrue(conditionId != bytes32(0), "conditionId should be non-zero");
        uint256 yesId = lmsr.yesTokenId();
        uint256 noId = lmsr.noTokenId();
        assertTrue(yesId != noId, "yes and no token IDs should differ");

        // Factory registry updated
        uint64 marketId = factory.marketIdByAddress(market);
        assertTrue(marketId > 0, "marketId should be assigned");
        assertEq(factory.getMarketById(marketId), market, "getMarketById should return market");
        assertEq(factory.getMarketByCondition(conditionId), market, "getMarketByCondition should return market");

        MarketInfo memory info = factory.getMarketInfo(marketId);
        assertEq(info.market, market, "info.market should match");
        assertEq(info.creator, alice, "info.creator should be alice");
        assertEq(info.conditionId, conditionId, "info.conditionId should match");
        assertEq(info.deadline, params.deadline, "info.deadline should match");
        assertEq(info.createdAt, uint64(block.timestamp), "info.createdAt should be now");

        // Seed deducted from alice
        uint256 aliceBalAfter = vault.balances(alice);
        assertEq(aliceBalBefore - aliceBalAfter, SEED_USDC, "seed should be deducted from alice");

        // Market whitelisted in vault
        assertTrue(vault.whitelistedMarkets(market), "market should be whitelisted in vault");

        // Backstop registered
        assertEq(backstopRouter.backstops(conditionId), market, "backstop should be registered");
    }

    // ============================================================
    // 2. Mode A (Meta-tx) — creator signs, relayer submits
    // ============================================================

    function test_modeA_createMarketFor() public {
        uint256 creatorPk = 0xCA1;
        address creatorAddr = vm.addr(creatorPk);

        // Fund the creator
        _fundAccount(creatorAddr);

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("modeA-request-1");
        uint256 nonce = factory.nonces(creatorAddr);

        // Creator signs the EIP-712 message
        (uint8 v, bytes32 r, bytes32 s) = _signCreateMarket(
            creatorPk, params, SEED_USDC, 5000, nonce, sigDeadline, requestId
        );

        uint256 creatorBalBefore = vault.balances(creatorAddr);

        // Relayer submits the meta-transaction
        vm.prank(relayer);
        address market = factory.createMarketFor(
            params, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId,
            v, r, s
        );

        // Market created successfully
        assertTrue(market != address(0), "market should be deployed");

        // Creator is the signer, not the relayer
        MarketLMSR lmsr = MarketLMSR(market);
        assertEq(lmsr.creator(), creatorAddr, "creator should be the signer");

        // Factory info records creator correctly
        uint64 marketId = factory.marketIdByAddress(market);
        MarketInfo memory info = factory.getMarketInfo(marketId);
        assertEq(info.creator, creatorAddr, "info.creator should be the signer");

        // Seed deducted from creator
        uint256 creatorBalAfter = vault.balances(creatorAddr);
        assertEq(creatorBalBefore - creatorBalAfter, SEED_USDC, "seed should be deducted from creator");

        // RequestId marked as used
        assertTrue(factory.usedRequestIds(requestId), "requestId should be marked used");

        // Nonce incremented
        assertEq(factory.nonces(creatorAddr), nonce + 1, "nonce should be incremented");
    }

    // ============================================================
    // 3. Mode B (Delegated) — session key signs on behalf of owner
    // ============================================================

    function test_modeB_createMarketForDelegated() public {
        uint256 sessionPk = 0x5E55;
        address sessionKey = vm.addr(sessionPk);

        // Alice delegates to session key via DelegationRegistry
        // scope = factory address, daily limit = 1000 USDC, no expiry
        vm.prank(alice);
        delegationRegistry.setDelegation(
            sessionKey,
            address(factory),
            1_000_000_000, // 1000 USDC daily limit
            0              // no expiry
        );

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("modeB-request-1");
        uint256 nonce = factory.nonces(sessionKey); // nonce is per-signer (session key)

        // Session key signs the DELEGATED_CREATE_TYPEHASH (includes owner address)
        (uint8 v, bytes32 r, bytes32 s) = _signDelegatedCreateMarket(
            sessionPk, params, SEED_USDC, 5000, nonce, sigDeadline, requestId, alice
        );

        uint256 aliceBalBefore = vault.balances(alice);

        // Relayer submits the meta-transaction
        vm.prank(relayer);
        address market = factory.createMarketForDelegated(
            params, SEED_USDC, 5000,
            alice,       // owner
            sessionKey,  // signer (session key)
            sigDeadline, requestId,
            v, r, s
        );

        // Market created successfully
        assertTrue(market != address(0), "market should be deployed");

        // Creator is alice (owner), NOT the session key
        MarketLMSR lmsr = MarketLMSR(market);
        assertEq(lmsr.creator(), alice, "creator should be alice (owner), not session key");

        // Factory info records alice as creator
        uint64 marketId = factory.marketIdByAddress(market);
        MarketInfo memory info = factory.getMarketInfo(marketId);
        assertEq(info.creator, alice, "info.creator should be alice");

        // Seed deducted from alice (owner)
        uint256 aliceBalAfter = vault.balances(alice);
        assertEq(aliceBalBefore - aliceBalAfter, SEED_USDC, "seed should be deducted from alice");

        // RequestId marked as used
        assertTrue(factory.usedRequestIds(requestId), "requestId should be marked used");

        // Nonce incremented for session key
        assertEq(factory.nonces(sessionKey), nonce + 1, "session key nonce should be incremented");
    }

    // ============================================================
    // 4. Mode B without delegation — should revert NotDelegated
    // ============================================================

    function test_modeB_noDelegation_reverts() public {
        uint256 sessionPk = 0x5E55;
        address sessionKey = vm.addr(sessionPk);

        // NOTE: No delegation set for sessionKey

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("modeB-no-delegation");
        uint256 nonce = factory.nonces(sessionKey);

        (uint8 v, bytes32 r, bytes32 s) = _signDelegatedCreateMarket(
            sessionPk, params, SEED_USDC, 5000, nonce, sigDeadline, requestId, alice
        );

        vm.prank(relayer);
        vm.expectRevert(FactoryV2.NotDelegated.selector);
        factory.createMarketForDelegated(
            params, SEED_USDC, 5000,
            alice, sessionKey, sigDeadline, requestId,
            v, r, s
        );
    }

    // ============================================================
    // 5. requestId idempotency — same requestId reverts
    // ============================================================

    function test_requestId_idempotency_reverts() public {
        uint256 creatorPk = 0xCA1;
        address creatorAddr = vm.addr(creatorPk);
        _fundAccount(creatorAddr);

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("idempotent-request");

        // First call: succeeds
        uint256 nonce1 = factory.nonces(creatorAddr);
        (uint8 v1, bytes32 r1, bytes32 s1) = _signCreateMarket(
            creatorPk, params, SEED_USDC, 5000, nonce1, sigDeadline, requestId
        );

        vm.prank(relayer);
        factory.createMarketFor(
            params, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId,
            v1, r1, s1
        );

        // Second call with same requestId: reverts
        // Need new signature with incremented nonce, but same requestId
        uint256 nonce2 = factory.nonces(creatorAddr);
        // Use different params to get a unique market (different question)
        MarketParams memory params2 = _defaultParams();
        params2.question = "Will BTC reach $200k by 2027?";

        (uint8 v2, bytes32 r2, bytes32 s2) = _signCreateMarket(
            creatorPk, params2, SEED_USDC, 5000, nonce2, sigDeadline, requestId
        );

        vm.prank(relayer);
        vm.expectRevert(FactoryV2.RequestAlreadyUsed.selector);
        factory.createMarketFor(
            params2, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId,
            v2, r2, s2
        );
    }

    // ============================================================
    // 6. Param validation — seed too low
    // ============================================================

    function test_seedTooLow_reverts() public {
        MarketParams memory params = _defaultParams();

        vm.prank(alice);
        vm.expectRevert(FactoryV2.SeedTooLow.selector);
        factory.createMarket(params, 1_000_000, 5000); // 1 USDC < 10 USDC min
    }

    // ============================================================
    // 7. Param validation — seed too high
    // ============================================================

    function test_seedTooHigh_reverts() public {
        MarketParams memory params = _defaultParams();

        vm.prank(alice);
        vm.expectRevert(FactoryV2.SeedTooHigh.selector);
        factory.createMarket(params, 100_000_000_000, 5000); // 100,000 USDC > 10,000 max
    }

    // ============================================================
    // 8. Param validation — price out of range
    // ============================================================

    function test_priceZero_reverts() public {
        MarketParams memory params = _defaultParams();

        vm.prank(alice);
        vm.expectRevert(FactoryV2.PriceOutOfRange.selector);
        factory.createMarket(params, SEED_USDC, 0);
    }

    function test_price10000_reverts() public {
        MarketParams memory params = _defaultParams();

        vm.prank(alice);
        vm.expectRevert(FactoryV2.PriceOutOfRange.selector);
        factory.createMarket(params, SEED_USDC, 10000);
    }

    function test_priceTooLow_50bps_reverts() public {
        MarketParams memory params = _defaultParams();

        vm.prank(alice);
        vm.expectRevert(FactoryV2.PriceOutOfRange.selector);
        factory.createMarket(params, SEED_USDC, 50); // below 100
    }

    function test_priceTooHigh_9950bps_reverts() public {
        MarketParams memory params = _defaultParams();

        vm.prank(alice);
        vm.expectRevert(FactoryV2.PriceOutOfRange.selector);
        factory.createMarket(params, SEED_USDC, 9950); // above 9900
    }

    function test_priceBoundary_100_succeeds() public {
        MarketParams memory params = _defaultParams();

        vm.prank(alice);
        address market = factory.createMarket(params, SEED_USDC, 100);
        assertTrue(market != address(0), "market at 100 bps should succeed");
    }

    function test_priceBoundary_9900_succeeds() public {
        MarketParams memory params = _defaultParams();
        params.question = "Boundary 9900 market"; // unique question

        vm.prank(alice);
        address market = factory.createMarket(params, SEED_USDC, 9900);
        assertTrue(market != address(0), "market at 9900 bps should succeed");
    }

    // ============================================================
    // 9. Param validation — duration too short
    // ============================================================

    function test_durationTooShort_reverts() public {
        MarketParams memory params = _defaultParams();
        params.deadline = uint64(block.timestamp + 1 minutes); // 1 min < 1 hour min

        vm.prank(alice);
        vm.expectRevert(FactoryV2.DurationTooShort.selector);
        factory.createMarket(params, SEED_USDC, 5000);
    }

    // ============================================================
    // 10. Param validation — question required
    // ============================================================

    function test_questionRequired_reverts() public {
        MarketParams memory params = _defaultParams();
        params.question = ""; // empty question

        vm.prank(alice);
        vm.expectRevert(FactoryV2.QuestionRequired.selector);
        factory.createMarket(params, SEED_USDC, 5000);
    }

    // ============================================================
    // 11. Param validation — resolutionSource must be https
    // ============================================================

    function test_resolutionSourceNotHttps_reverts() public {
        MarketParams memory params = _defaultParams();
        params.resolutionSource = "http://example.com/insecure";

        vm.prank(alice);
        vm.expectRevert("resolutionSource must be https");
        factory.createMarket(params, SEED_USDC, 5000);
    }

    // ============================================================
    // 12. Signature expired — Mode A with deadline in past
    // ============================================================

    function test_modeA_signatureExpired_reverts() public {
        uint256 creatorPk = 0xCA1;
        address creatorAddr = vm.addr(creatorPk);
        _fundAccount(creatorAddr);

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp - 1; // already expired
        bytes32 requestId = keccak256("expired-sig");
        uint256 nonce = factory.nonces(creatorAddr);

        (uint8 v, bytes32 r, bytes32 s) = _signCreateMarket(
            creatorPk, params, SEED_USDC, 5000, nonce, sigDeadline, requestId
        );

        vm.prank(relayer);
        vm.expectRevert(FactoryV2.SignatureExpired.selector);
        factory.createMarketFor(
            params, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId,
            v, r, s
        );
    }

    // ============================================================
    // 13. Invalid signature — Mode A wrong signer
    // ============================================================

    function test_modeA_invalidSignature_reverts() public {
        uint256 creatorPk = 0xCA1;
        address creatorAddr = vm.addr(creatorPk);
        _fundAccount(creatorAddr);

        // Sign with a DIFFERENT private key
        uint256 wrongPk = 0xBAD;

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("wrong-signer");
        uint256 nonce = factory.nonces(creatorAddr);

        // Sign with wrongPk but claim creatorAddr as creator
        (uint8 v, bytes32 r, bytes32 s) = _signCreateMarket(
            wrongPk, params, SEED_USDC, 5000, nonce, sigDeadline, requestId
        );

        vm.prank(relayer);
        vm.expectRevert(FactoryV2.InvalidSignature.selector);
        factory.createMarketFor(
            params, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId,
            v, r, s
        );
    }

    // ============================================================
    // 14. Not relayer — non-relayer calls createMarketFor
    // ============================================================

    function test_modeA_notRelayer_reverts() public {
        uint256 creatorPk = 0xCA1;
        address creatorAddr = vm.addr(creatorPk);
        _fundAccount(creatorAddr);

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("not-relayer-test");
        uint256 nonce = factory.nonces(creatorAddr);

        (uint8 v, bytes32 r, bytes32 s) = _signCreateMarket(
            creatorPk, params, SEED_USDC, 5000, nonce, sigDeadline, requestId
        );

        // Bob (not a relayer) tries to submit
        vm.prank(bob);
        vm.expectRevert(FactoryV2.NotRelayer.selector);
        factory.createMarketFor(
            params, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId,
            v, r, s
        );
    }

    function test_modeB_notRelayer_reverts() public {
        uint256 sessionPk = 0x5E55;
        address sessionKey = vm.addr(sessionPk);

        vm.prank(alice);
        delegationRegistry.setDelegation(sessionKey, address(factory), 1_000_000_000, 0);

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("not-relayer-modeB");
        uint256 nonce = factory.nonces(sessionKey);

        (uint8 v, bytes32 r, bytes32 s) = _signDelegatedCreateMarket(
            sessionPk, params, SEED_USDC, 5000, nonce, sigDeadline, requestId, alice
        );

        // Carol (not a relayer) tries to submit
        vm.prank(carol);
        vm.expectRevert(FactoryV2.NotRelayer.selector);
        factory.createMarketForDelegated(
            params, SEED_USDC, 5000,
            alice, sessionKey, sigDeadline, requestId,
            v, r, s
        );
    }

    // ============================================================
    // 15. Creation paused — createMarket reverts CreationIsPaused
    // ============================================================

    function test_creationPaused_mode0_reverts() public {
        // Admin pauses creation
        vm.prank(admin);
        factory.pauseCreation();

        assertTrue(factory.creationPaused(), "creation should be paused");

        MarketParams memory params = _defaultParams();

        vm.prank(alice);
        vm.expectRevert(FactoryV2.CreationIsPaused.selector);
        factory.createMarket(params, SEED_USDC, 5000);
    }

    function test_creationPaused_modeA_reverts() public {
        uint256 creatorPk = 0xCA1;
        address creatorAddr = vm.addr(creatorPk);
        _fundAccount(creatorAddr);

        // Admin pauses creation
        vm.prank(admin);
        factory.pauseCreation();

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("paused-modeA");
        uint256 nonce = factory.nonces(creatorAddr);

        (uint8 v, bytes32 r, bytes32 s) = _signCreateMarket(
            creatorPk, params, SEED_USDC, 5000, nonce, sigDeadline, requestId
        );

        vm.prank(relayer);
        vm.expectRevert(FactoryV2.CreationIsPaused.selector);
        factory.createMarketFor(
            params, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId,
            v, r, s
        );
    }

    function test_creationUnpause_resumesCreation() public {
        // Pause
        vm.prank(admin);
        factory.pauseCreation();

        // Unpause
        vm.prank(admin);
        factory.unpauseCreation();

        assertFalse(factory.creationPaused(), "creation should be unpaused");

        // Market creation should work again
        MarketParams memory params = _defaultParams();
        vm.prank(alice);
        address market = factory.createMarket(params, SEED_USDC, 5000);
        assertTrue(market != address(0), "market should be created after unpause");
    }

    // ============================================================
    // 16. Multiple markets independent
    // ============================================================

    function test_multipleMarkets_independent() public {
        // Create first market
        MarketParams memory params1 = _defaultParams();
        vm.prank(alice);
        address market1 = factory.createMarket(params1, SEED_USDC, 5000);

        // Create second market (different question to get different conditionId)
        MarketParams memory params2 = _defaultParams();
        params2.question = "Will BTC reach $200k by end of 2027?";
        vm.prank(bob);
        address market2 = factory.createMarket(params2, SEED_USDC, 3000);

        // Addresses are different
        assertTrue(market1 != market2, "market addresses should differ");

        // ConditionIds are different
        bytes32 conditionId1 = MarketLMSR(market1).conditionId();
        bytes32 conditionId2 = MarketLMSR(market2).conditionId();
        assertTrue(conditionId1 != conditionId2, "conditionIds should differ");

        // Creators are different
        assertEq(MarketLMSR(market1).creator(), alice, "market1 creator should be alice");
        assertEq(MarketLMSR(market2).creator(), bob, "market2 creator should be bob");

        // MarketIds are sequential
        uint64 id1 = factory.marketIdByAddress(market1);
        uint64 id2 = factory.marketIdByAddress(market2);
        assertEq(id2, id1 + 1, "market IDs should be sequential");

        // Each market has its own token IDs
        uint256 yesId1 = MarketLMSR(market1).yesTokenId();
        uint256 yesId2 = MarketLMSR(market2).yesTokenId();
        assertTrue(yesId1 != yesId2, "yes token IDs should differ");

        // Both backstops registered independently
        assertEq(backstopRouter.backstops(conditionId1), market1, "backstop1 should point to market1");
        assertEq(backstopRouter.backstops(conditionId2), market2, "backstop2 should point to market2");

        // Both whitelisted
        assertTrue(vault.whitelistedMarkets(market1), "market1 should be whitelisted");
        assertTrue(vault.whitelistedMarkets(market2), "market2 should be whitelisted");
    }

    // ============================================================
    // 17. Nonce increment after Mode A create
    // ============================================================

    function test_nonce_increment_modeA() public {
        uint256 creatorPk = 0xCA1;
        address creatorAddr = vm.addr(creatorPk);
        _fundAccount(creatorAddr);

        // Nonce starts at 0
        assertEq(factory.nonces(creatorAddr), 0, "initial nonce should be 0");

        MarketParams memory params1 = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId1 = keccak256("nonce-test-1");

        // First creation
        (uint8 v1, bytes32 r1, bytes32 s1) = _signCreateMarket(
            creatorPk, params1, SEED_USDC, 5000, 0, sigDeadline, requestId1
        );

        vm.prank(relayer);
        factory.createMarketFor(
            params1, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId1,
            v1, r1, s1
        );

        assertEq(factory.nonces(creatorAddr), 1, "nonce should be 1 after first create");

        // Second creation (must use nonce=1)
        MarketParams memory params2 = _defaultParams();
        params2.question = "Second nonce market question?";
        bytes32 requestId2 = keccak256("nonce-test-2");

        (uint8 v2, bytes32 r2, bytes32 s2) = _signCreateMarket(
            creatorPk, params2, SEED_USDC, 5000, 1, sigDeadline, requestId2
        );

        vm.prank(relayer);
        factory.createMarketFor(
            params2, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId2,
            v2, r2, s2
        );

        assertEq(factory.nonces(creatorAddr), 2, "nonce should be 2 after second create");
    }

    function test_nonce_increment_modeB() public {
        uint256 sessionPk = 0x5E55;
        address sessionKey = vm.addr(sessionPk);

        // Alice delegates to session key with high daily limit
        vm.prank(alice);
        delegationRegistry.setDelegation(sessionKey, address(factory), 10_000_000_000, 0);

        assertEq(factory.nonces(sessionKey), 0, "session key initial nonce should be 0");

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("nonce-modeB-1");

        (uint8 v, bytes32 r, bytes32 s) = _signDelegatedCreateMarket(
            sessionPk, params, SEED_USDC, 5000, 0, sigDeadline, requestId, alice
        );

        vm.prank(relayer);
        factory.createMarketForDelegated(
            params, SEED_USDC, 5000,
            alice, sessionKey, sigDeadline, requestId,
            v, r, s
        );

        assertEq(factory.nonces(sessionKey), 1, "session key nonce should be 1 after create");
    }

    // ============================================================
    // Additional Edge Cases
    // ============================================================

    function test_mode0_seedBoundary_10USDC_succeeds() public {
        MarketParams memory params = _defaultParams();

        vm.prank(alice);
        address market = factory.createMarket(params, 10_000_000, 5000); // exactly 10 USDC
        assertTrue(market != address(0), "market at min seed should succeed");
    }

    function test_mode0_seedBoundary_10000USDC_succeeds() public {
        MarketParams memory params = _defaultParams();
        params.question = "Max seed boundary market";

        vm.prank(alice);
        address market = factory.createMarket(params, 10_000_000_000, 5000); // exactly 10,000 USDC
        assertTrue(market != address(0), "market at max seed should succeed");
    }

    function test_durationTooLong_reverts() public {
        MarketParams memory params = _defaultParams();
        params.deadline = uint64(block.timestamp + 366 days); // over 365 days max

        vm.prank(alice);
        vm.expectRevert(FactoryV2.DurationTooLong.selector);
        factory.createMarket(params, SEED_USDC, 5000);
    }

    function test_resolutionSourceEmpty_reverts() public {
        MarketParams memory params = _defaultParams();
        params.resolutionSource = "";

        vm.prank(alice);
        vm.expectRevert("resolutionSource required");
        factory.createMarket(params, SEED_USDC, 5000);
    }

    function test_resolutionRulesEmpty_reverts() public {
        MarketParams memory params = _defaultParams();
        params.resolutionRules = "";

        vm.prank(alice);
        vm.expectRevert("resolutionRules required");
        factory.createMarket(params, SEED_USDC, 5000);
    }

    function test_nextMarketId_startsAt1() public {
        assertEq(factory.nextMarketId(), 1, "nextMarketId should start at 1");

        (address market,) = _createDefaultMarket(alice);
        uint64 marketId = factory.marketIdByAddress(market);
        assertEq(marketId, 1, "first market should have id 1");
        assertEq(factory.nextMarketId(), 2, "nextMarketId should be 2 after first create");
    }

    function test_modeA_replayOldNonce_reverts() public {
        uint256 creatorPk = 0xCA1;
        address creatorAddr = vm.addr(creatorPk);
        _fundAccount(creatorAddr);

        MarketParams memory params1 = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId1 = keccak256("replay-test-1");

        // First creation with nonce=0
        (uint8 v1, bytes32 r1, bytes32 s1) = _signCreateMarket(
            creatorPk, params1, SEED_USDC, 5000, 0, sigDeadline, requestId1
        );

        vm.prank(relayer);
        factory.createMarketFor(
            params1, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId1,
            v1, r1, s1
        );

        // Try to replay with nonce=0 again (different requestId to bypass that check)
        MarketParams memory params2 = _defaultParams();
        params2.question = "Replay attempt question?";
        bytes32 requestId2 = keccak256("replay-test-2");

        (uint8 v2, bytes32 r2, bytes32 s2) = _signCreateMarket(
            creatorPk, params2, SEED_USDC, 5000, 0, sigDeadline, requestId2
        );

        // Should fail because nonce is now 1, but signature was made with nonce 0
        vm.prank(relayer);
        vm.expectRevert(FactoryV2.InvalidSignature.selector);
        factory.createMarketFor(
            params2, SEED_USDC, 5000,
            creatorAddr, sigDeadline, requestId2,
            v2, r2, s2
        );
    }

    function test_modeB_signatureExpired_reverts() public {
        uint256 sessionPk = 0x5E55;
        address sessionKey = vm.addr(sessionPk);

        vm.prank(alice);
        delegationRegistry.setDelegation(sessionKey, address(factory), 1_000_000_000, 0);

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp - 1; // expired
        bytes32 requestId = keccak256("modeB-expired");
        uint256 nonce = factory.nonces(sessionKey);

        (uint8 v, bytes32 r, bytes32 s) = _signDelegatedCreateMarket(
            sessionPk, params, SEED_USDC, 5000, nonce, sigDeadline, requestId, alice
        );

        vm.prank(relayer);
        vm.expectRevert(FactoryV2.SignatureExpired.selector);
        factory.createMarketForDelegated(
            params, SEED_USDC, 5000,
            alice, sessionKey, sigDeadline, requestId,
            v, r, s
        );
    }

    function test_modeB_requestId_idempotency_reverts() public {
        uint256 sessionPk = 0x5E55;
        address sessionKey = vm.addr(sessionPk);

        vm.prank(alice);
        delegationRegistry.setDelegation(sessionKey, address(factory), 10_000_000_000, 0);

        MarketParams memory params = _defaultParams();
        uint256 sigDeadline = block.timestamp + 1 hours;
        bytes32 requestId = keccak256("modeB-idempotent");

        // First call succeeds
        uint256 nonce1 = factory.nonces(sessionKey);
        (uint8 v1, bytes32 r1, bytes32 s1) = _signDelegatedCreateMarket(
            sessionPk, params, SEED_USDC, 5000, nonce1, sigDeadline, requestId, alice
        );

        vm.prank(relayer);
        factory.createMarketForDelegated(
            params, SEED_USDC, 5000,
            alice, sessionKey, sigDeadline, requestId,
            v1, r1, s1
        );

        // Second call with same requestId reverts
        uint256 nonce2 = factory.nonces(sessionKey);
        MarketParams memory params2 = _defaultParams();
        params2.question = "Second attempt same requestId";
        (uint8 v2, bytes32 r2, bytes32 s2) = _signDelegatedCreateMarket(
            sessionPk, params2, SEED_USDC, 5000, nonce2, sigDeadline, requestId, alice
        );

        vm.prank(relayer);
        vm.expectRevert(FactoryV2.RequestAlreadyUsed.selector);
        factory.createMarketForDelegated(
            params2, SEED_USDC, 5000,
            alice, sessionKey, sigDeadline, requestId,
            v2, r2, s2
        );
    }
}
