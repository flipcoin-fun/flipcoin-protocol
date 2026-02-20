// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BaseV2Test} from "./BaseV2Test.sol";
import {
    MarketParams, MarketInfo
} from "../contracts/v2/interfaces/Types.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {FactoryV2} from "../contracts/v2/FactoryV2.sol";

/**
 * @title FactoryV2AdvancedTest
 * @notice Advanced tests: relayer management, duration boundaries,
 *         market info queries, admin functions, creation pause edge cases.
 */
contract FactoryV2AdvancedTest is BaseV2Test {

    function _defaultParams() internal view returns (MarketParams memory) {
        return MarketParams({
            question: "Will BTC reach $200k by 2027?",
            description: "Resolves based on CoinGecko BTC price",
            category: "crypto",
            resolutionRules: "Resolve YES if price exceeds $200k",
            resolutionSource: "https://www.coingecko.com",
            imageUrl: "https://example.com/btc.png",
            deadline: uint64(block.timestamp + 30 days)
        });
    }

    // ============================================================
    // 1. Add Relayer — Only Admin
    // ============================================================

    function test_addRelayer_onlyAdmin() public {
        address newRelayer = makeAddr("newRelayer");

        vm.prank(bob);
        vm.expectRevert(FactoryV2.NotAdmin.selector);
        factory.addRelayer(newRelayer);

        vm.prank(admin);
        factory.addRelayer(newRelayer);
        assertTrue(factory.trustedRelayers(newRelayer), "relayer should be added");
    }

    // ============================================================
    // 2. Add Relayer — Zero Address Reverts
    // ============================================================

    function test_addRelayer_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert("zero address");
        factory.addRelayer(address(0));
    }

    // ============================================================
    // 3. Add Relayer — Duplicate Reverts
    // ============================================================

    function test_addRelayer_duplicate_reverts() public {
        // relayer is already added in BaseV2Test.setUp()
        assertTrue(factory.trustedRelayers(relayer));

        vm.prank(admin);
        vm.expectRevert("already relayer");
        factory.addRelayer(relayer);
    }

    // ============================================================
    // 4. Remove Relayer
    // ============================================================

    function test_removeRelayer_onlyAdmin() public {
        vm.prank(bob);
        vm.expectRevert(FactoryV2.NotAdmin.selector);
        factory.removeRelayer(relayer);

        vm.prank(admin);
        factory.removeRelayer(relayer);
        assertFalse(factory.trustedRelayers(relayer), "relayer should be removed");
    }

    function test_removeRelayer_notRelayer_reverts() public {
        vm.prank(admin);
        vm.expectRevert("not relayer");
        factory.removeRelayer(makeAddr("notARelayer"));
    }

    // ============================================================
    // 5. Duration Boundary — Exactly Min Duration
    // ============================================================

    function test_duration_exactlyMinDuration_succeeds() public {
        MarketParams memory params = _defaultParams();
        params.deadline = uint64(block.timestamp + MIN_DURATION); // exactly 1 hour

        vm.prank(alice);
        address m = factory.createMarket(params, SEED_USDC, 5000);
        assertTrue(m != address(0), "market should be created at min duration");
    }

    // ============================================================
    // 6. Duration Boundary — Exactly Max Duration
    // ============================================================

    function test_duration_exactlyMaxDuration_succeeds() public {
        MarketParams memory params = _defaultParams();
        params.deadline = uint64(block.timestamp + MAX_DURATION); // exactly 365 days

        vm.prank(alice);
        address m = factory.createMarket(params, SEED_USDC, 5000);
        assertTrue(m != address(0), "market should be created at max duration");
    }

    // ============================================================
    // 7. Duration — Too Long Reverts
    // ============================================================

    function test_duration_tooLong_reverts() public {
        MarketParams memory params = _defaultParams();
        params.deadline = uint64(block.timestamp + MAX_DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(FactoryV2.DurationTooLong.selector);
        factory.createMarket(params, SEED_USDC, 5000);
    }

    // ============================================================
    // 8. Duration — Too Short Reverts
    // ============================================================

    function test_duration_tooShort_reverts() public {
        MarketParams memory params = _defaultParams();
        params.deadline = uint64(block.timestamp + MIN_DURATION - 1); // Less than 1 hour

        vm.prank(alice);
        vm.expectRevert(FactoryV2.DurationTooShort.selector);
        factory.createMarket(params, SEED_USDC, 5000);
    }

    // ============================================================
    // 9. Market ID Sequencing
    // ============================================================

    function test_marketId_sequential() public {
        MarketParams memory params1 = _defaultParams();
        params1.question = "Market 1 unique question";
        vm.prank(alice);
        factory.createMarket(params1, SEED_USDC, 5000);

        MarketParams memory params2 = _defaultParams();
        params2.question = "Market 2 unique question";
        vm.prank(alice);
        factory.createMarket(params2, SEED_USDC, 6000);

        MarketParams memory params3 = _defaultParams();
        params3.question = "Market 3 unique question";
        vm.prank(bob);
        factory.createMarket(params3, SEED_USDC, 4000);

        // Verify sequential IDs
        uint64 nextId = factory.nextMarketId();
        assertEq(nextId, 4, "nextMarketId should be 4 after 3 markets");

        // All markets should be accessible by ID
        assertTrue(factory.getMarketById(1) != address(0), "market 1 should exist");
        assertTrue(factory.getMarketById(2) != address(0), "market 2 should exist");
        assertTrue(factory.getMarketById(3) != address(0), "market 3 should exist");
    }

    // ============================================================
    // 10. getMarketById — Non-Existent
    // ============================================================

    function test_getMarketById_nonExistent_returnsZero() public view {
        address m = factory.getMarketById(9999);
        assertEq(m, address(0), "non-existent market should return address(0)");
    }

    // ============================================================
    // 11. getMarketByCondition — Non-Existent
    // ============================================================

    function test_getMarketByCondition_nonExistent_returnsZero() public view {
        address m = factory.getMarketByCondition(keccak256("nonexistent"));
        assertEq(m, address(0), "non-existent condition should return address(0)");
    }

    // ============================================================
    // 12. Creation Pause
    // ============================================================

    function test_creationPause_blocksNewMarkets() public {
        vm.prank(admin);
        factory.pauseCreation();

        MarketParams memory params = _defaultParams();
        params.question = "Should be blocked";

        vm.prank(alice);
        vm.expectRevert(FactoryV2.CreationIsPaused.selector);
        factory.createMarket(params, SEED_USDC, 5000);
    }

    function test_creationPause_onlyAdmin() public {
        vm.prank(bob);
        vm.expectRevert(FactoryV2.NotAdmin.selector);
        factory.pauseCreation();
    }

    function test_creationUnpause_onlyAdmin() public {
        vm.prank(admin);
        factory.pauseCreation();

        vm.prank(bob);
        vm.expectRevert(FactoryV2.NotAdmin.selector);
        factory.unpauseCreation();
    }

    function test_creationPause_alreadyPaused_reverts() public {
        vm.prank(admin);
        factory.pauseCreation();

        vm.prank(admin);
        vm.expectRevert("already paused");
        factory.pauseCreation();
    }

    function test_creationUnpause_notPaused_reverts() public {
        vm.prank(admin);
        vm.expectRevert("not paused");
        factory.unpauseCreation();
    }

    function test_creationUnpause_resumesCreation() public {
        vm.prank(admin);
        factory.pauseCreation();

        vm.prank(admin);
        factory.unpauseCreation();

        MarketParams memory params = _defaultParams();
        params.question = "Should work after unpause";
        vm.prank(alice);
        address m = factory.createMarket(params, SEED_USDC, 5000);
        assertTrue(m != address(0), "market should be created after unpause");
    }

    // ============================================================
    // 13. Transfer Admin
    // ============================================================

    function test_transferAdmin_factoryV2() public {
        address newAdmin = makeAddr("newFactoryAdmin");

        vm.prank(admin);
        factory.transferAdmin(newAdmin);

        // Old admin can no longer act
        vm.prank(admin);
        vm.expectRevert(FactoryV2.NotAdmin.selector);
        factory.pauseCreation();

        // New admin can act
        vm.prank(newAdmin);
        factory.pauseCreation();
    }

    function test_transferAdmin_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert("zero address");
        factory.transferAdmin(address(0));
    }

    // ============================================================
    // 14. Price Boundaries
    // ============================================================

    function test_initialPrice_minBoundary_100bps() public {
        MarketParams memory params = _defaultParams();
        params.question = "100 bps price market";

        vm.prank(alice);
        address m = factory.createMarket(params, SEED_USDC, 100); // 1%
        assertTrue(m != address(0), "1% initial price should work");
    }

    function test_initialPrice_maxBoundary_9900bps() public {
        MarketParams memory params = _defaultParams();
        params.question = "9900 bps price market";

        vm.prank(alice);
        address m = factory.createMarket(params, SEED_USDC, 9900); // 99%
        assertTrue(m != address(0), "99% initial price should work");
    }

    // ============================================================
    // 15. Resolution Source — Must Be HTTPS
    // ============================================================

    function test_resolutionSource_httpOnly_reverts() public {
        MarketParams memory params = _defaultParams();
        params.question = "HTTP source market";
        params.resolutionSource = "http://example.com";

        vm.prank(alice);
        vm.expectRevert(); // FactoryV2 validates https-only
        factory.createMarket(params, SEED_USDC, 5000);
    }

    function test_resolutionSource_empty_reverts() public {
        MarketParams memory params = _defaultParams();
        params.question = "Empty source market";
        params.resolutionSource = "";

        vm.prank(alice);
        vm.expectRevert("resolutionSource required");
        factory.createMarket(params, SEED_USDC, 5000);
    }
}
