// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";

import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {DelegationRegistry} from "../contracts/v2/DelegationRegistry.sol";
import {ShareToken} from "../contracts/v2/ShareToken.sol";
import {VaultV2} from "../contracts/v2/VaultV2.sol";
import {Exchange} from "../contracts/v2/Exchange.sol";
import {BackstopRouter} from "../contracts/v2/BackstopRouter.sol";
import {MarketLMSR} from "../contracts/v2/MarketLMSR.sol";
import {FactoryV2} from "../contracts/v2/FactoryV2.sol";
import {
    Side, Outcome, ResolutionStatus, MarketParams, MarketConfigV2,
    MarketInfo, TradeIntent, Order, SignatureType, MatchType, Delegation
} from "../contracts/v2/interfaces/Types.sol";

/**
 * @title BaseV2Test
 * @notice Shared test setup for all v2 contract tests
 * @dev Deploys full v2 stack and provides helper functions
 */
abstract contract BaseV2Test is Test {
    // ── Contracts ──
    MockUSDC public usdc;
    DelegationRegistry public delegationRegistry;
    ShareToken public shareToken;
    VaultV2 public vault;
    Exchange public exchange;
    BackstopRouter public backstopRouter;
    MarketLMSR public marketImpl;
    FactoryV2 public factory;

    // ── Actors ──
    address public admin = makeAddr("admin");
    address public operator = makeAddr("operator");
    address public protocolAddress = makeAddr("protocol");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public relayer = makeAddr("relayer");

    // ── Config ──
    uint16 public constant DEFAULT_TOTAL_FEE_BPS = 100;   // 1%
    uint16 public constant DEFAULT_CREATOR_FEE_BPS = 50;   // 0.5%
    uint16 public constant DEFAULT_PROTOCOL_FEE_BPS = 50;  // 0.5%
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 365 days;

    // ── Test Helpers ──
    uint256 public constant INITIAL_BALANCE = 100_000_000_000; // 100,000 USDC
    uint256 public constant SEED_USDC = 100_000_000; // 100 USDC

    function setUp() public virtual {
        vm.startPrank(admin);

        // 1. Deploy MockUSDC
        usdc = new MockUSDC();

        // 2. Deploy VaultV2
        vault = new VaultV2(address(usdc), admin);

        // 3. Deploy ShareToken
        shareToken = new ShareToken("", admin);

        // 4. Deploy DelegationRegistry
        delegationRegistry = new DelegationRegistry(admin);

        // 5. Deploy Exchange
        exchange = new Exchange(
            admin,
            operator,
            address(shareToken),
            address(vault),
            address(delegationRegistry),
            protocolAddress,
            DEFAULT_PROTOCOL_FEE_BPS
        );

        // 6. Deploy BackstopRouter
        backstopRouter = new BackstopRouter(
            address(vault),
            address(shareToken),
            address(delegationRegistry),
            admin
        );

        // 7. Deploy MarketLMSR implementation
        marketImpl = new MarketLMSR();

        // 8. Deploy FactoryV2
        factory = new FactoryV2(
            admin,
            protocolAddress,
            address(marketImpl),
            address(vault),
            address(shareToken),
            address(exchange),
            address(backstopRouter),
            address(delegationRegistry),
            DEFAULT_TOTAL_FEE_BPS,
            DEFAULT_CREATOR_FEE_BPS,
            DEFAULT_PROTOCOL_FEE_BPS,
            MIN_DURATION,
            MAX_DURATION
        );

        // ── Post-deploy wiring ──

        // Vault
        vault.addTrustedFactory(address(factory));
        vault.setExchange(address(exchange));
        vault.setShareToken(address(shareToken));
        vault.setBackstopRouter(address(backstopRouter));

        // ShareToken
        shareToken.setFactory(address(factory));
        shareToken.setExchange(address(exchange));
        shareToken.setVault(address(vault));

        // Exchange — set factory
        exchange.setFactory(address(factory));

        // BackstopRouter — set factory
        backstopRouter.setFactory(address(factory));

        // DelegationRegistry — authorize contracts
        delegationRegistry.addAuthorizedContract(address(exchange));
        delegationRegistry.addAuthorizedContract(address(backstopRouter));
        delegationRegistry.addAuthorizedContract(address(factory));

        // Relayer
        factory.addRelayer(relayer);

        vm.stopPrank();

        // ── Fund test accounts ──
        _fundAccount(alice);
        _fundAccount(bob);
        _fundAccount(carol);
    }

    // ============================================================
    // Helper Functions
    // ============================================================

    function _fundAccount(address account) internal {
        usdc.mint(account, INITIAL_BALANCE);

        vm.startPrank(account);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(INITIAL_BALANCE);
        vm.stopPrank();
    }

    function _createDefaultMarket(address creator) internal returns (address market, bytes32 conditionId) {
        MarketParams memory params = MarketParams({
            question: "Will ETH reach $10k?",
            description: "Test market",
            category: "crypto",
            resolutionRules: "Resolve YES if ETH > $10k on Jan 1 2026",
            resolutionSource: "https://www.coingecko.com",
            imageUrl: "https://example.com/img.png",
            deadline: uint64(block.timestamp + 7 days)
        });

        vm.prank(creator);
        market = factory.createMarket(params, SEED_USDC, 5000); // 50% initial price

        // Get conditionId from the MarketLMSR clone
        conditionId = MarketLMSR(market).conditionId();
    }

    function _createMarketWithPrice(address creator, uint256 priceYesBps)
        internal returns (address market, bytes32 conditionId)
    {
        MarketParams memory params = MarketParams({
            question: "Test market with custom price",
            description: "Custom price market",
            category: "test",
            resolutionRules: "Test rules for resolution",
            resolutionSource: "https://example.com/source",
            imageUrl: "",
            deadline: uint64(block.timestamp + 30 days)
        });

        vm.prank(creator);
        market = factory.createMarket(params, SEED_USDC, priceYesBps);
        conditionId = MarketLMSR(market).conditionId();
    }

    function _getYesTokenId(address market) internal view returns (uint256) {
        return MarketLMSR(market).yesTokenId();
    }

    function _getNoTokenId(address market) internal view returns (uint256) {
        return MarketLMSR(market).noTokenId();
    }
}
