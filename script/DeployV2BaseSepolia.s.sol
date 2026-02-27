// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/mocks/MockUSDC.sol";
import "../contracts/v2/DelegationRegistry.sol";
import "../contracts/v2/ShareToken.sol";
import "../contracts/v2/VaultV2.sol";
import "../contracts/v2/Exchange.sol";
import "../contracts/v2/BackstopRouter.sol";
import "../contracts/v2/MarketLMSR.sol";
import "../contracts/v2/FactoryV2.sol";

/**
 * @title DeployV2BaseSepolia
 * @notice Deploys the full v2 Hybrid CLOB + LMSR stack to Base Sepolia
 *
 * Deployment order:
 *   1. MockUSDC (testnet only — replace with real USDC on mainnet)
 *   2. DelegationRegistry
 *   3. ShareToken (ERC-1155)
 *   4. VaultV2 (Model A: 4 pools)
 *   5. Exchange (CLOB)
 *   6. BackstopRouter (LMSR entry point)
 *   7. MarketLMSR (implementation for EIP-1167 clones)
 *   8. FactoryV2 (market creation)
 *
 * Post-deploy wiring:
 *   - ShareToken: setFactory, setVault, setExchange, addAuthorizedCaller(exchange)
 *   - VaultV2: addTrustedFactory, setExchange, setShareToken, setBackstopRouter
 *   - Exchange: setFactory
 *   - BackstopRouter: setFactory
 *   - DelegationRegistry: addAuthorizedContract(exchange, backstopRouter, factory)
 *   - FactoryV2: addRelayer(deployer)
 *
 * Usage:
 *   cd contracts
 *   source .env
 *   forge script v2/script/DeployV2BaseSepolia.s.sol:DeployV2BaseSepoliaScript \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract DeployV2BaseSepoliaScript is Script {
    // ── Fee Config ──
    uint16 constant DEFAULT_CREATOR_FEE_BPS = 50;    // 0.5%
    uint16 constant DEFAULT_MAKER_FEE_BPS = 0;       // 0% (makers pay only creator fee)
    uint16 constant DEFAULT_TAKER_FEE_BPS = 50;      // 0.5% (takers pay creator + protocol)

    // ── Duration Config ──
    uint64 constant MIN_MARKET_DURATION = 5 minutes;  // Short for testnet
    uint64 constant MAX_MARKET_DURATION = 365 days;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_METAMASK");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== FlipCoin v2 Deployment (Base Sepolia) ===");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ================================================================
        // Phase 1: Deploy all contracts
        // ================================================================

        // 1. MockUSDC (testnet only)
        MockUSDC usdc = new MockUSDC();
        console.log("[1/8] MockUSDC:", address(usdc));

        // 2. DelegationRegistry
        DelegationRegistry delegationRegistry = new DelegationRegistry(deployer);
        console.log("[2/8] DelegationRegistry:", address(delegationRegistry));

        // 3. ShareToken
        ShareToken shareToken = new ShareToken("", deployer);
        console.log("[3/8] ShareToken:", address(shareToken));

        // 4. VaultV2
        VaultV2 vault = new VaultV2(address(usdc), deployer);
        console.log("[4/8] VaultV2:", address(vault));

        // 5. Exchange (CLOB)
        Exchange exchange = new Exchange(
            deployer,                       // admin
            deployer,                       // operator (deployer for testnet)
            address(shareToken),
            address(vault),
            address(delegationRegistry),
            deployer,                       // protocolFeeRecipient
            DEFAULT_MAKER_FEE_BPS,
            DEFAULT_TAKER_FEE_BPS
        );
        console.log("[5/8] Exchange:", address(exchange));

        // 6. BackstopRouter (LMSR)
        BackstopRouter backstopRouter = new BackstopRouter(
            address(vault),
            address(shareToken),
            address(delegationRegistry),
            deployer                        // admin
        );
        console.log("[6/8] BackstopRouter:", address(backstopRouter));

        // 7. MarketLMSR implementation (EIP-1167 clone template)
        MarketLMSR marketImpl = new MarketLMSR();
        console.log("[7/8] MarketLMSR impl:", address(marketImpl));

        // 8. FactoryV2
        FactoryV2 factory = new FactoryV2(
            deployer,                       // admin
            deployer,                       // protocolAddress
            address(marketImpl),
            address(vault),
            address(shareToken),
            address(exchange),
            address(backstopRouter),
            address(delegationRegistry),
            DEFAULT_CREATOR_FEE_BPS,
            DEFAULT_MAKER_FEE_BPS,
            DEFAULT_TAKER_FEE_BPS,
            MIN_MARKET_DURATION,
            MAX_MARKET_DURATION
        );
        console.log("[8/8] FactoryV2:", address(factory));

        // ================================================================
        // Phase 2: Post-deploy wiring
        // ================================================================
        console.log("");
        console.log("--- Wiring contracts ---");

        // ShareToken wiring
        shareToken.setFactory(address(factory));
        shareToken.setVault(address(vault));
        shareToken.setExchange(address(exchange));
        shareToken.addAuthorizedCaller(address(exchange));
        // Resolution fee: mechanism deployed but inactive (resolutionFeeBps = 0)
        // TODO: Replace deployer with treasury/multisig at mainnet
        shareToken.setResolutionFeeRecipient(deployer);
        console.log("ShareToken: factory, vault, exchange set + exchange authorized + resolutionFeeRecipient set");

        // VaultV2 wiring
        vault.addTrustedFactory(address(factory));
        vault.setExchange(address(exchange));
        vault.setShareToken(address(shareToken));
        vault.setBackstopRouter(address(backstopRouter));
        console.log("VaultV2: factory trusted, exchange/shareToken/backstopRouter set");

        // Exchange wiring
        exchange.setFactory(address(factory));
        console.log("Exchange: factory set");

        // BackstopRouter wiring
        backstopRouter.setFactory(address(factory));
        console.log("BackstopRouter: factory set");

        // DelegationRegistry wiring
        delegationRegistry.addAuthorizedContract(address(exchange));
        delegationRegistry.addAuthorizedContract(address(backstopRouter));
        delegationRegistry.addAuthorizedContract(address(factory));
        console.log("DelegationRegistry: exchange, backstopRouter, factory authorized");

        // FactoryV2 — add deployer as relayer for testnet meta-tx
        factory.addRelayer(deployer);
        console.log("FactoryV2: deployer added as relayer");

        // ================================================================
        // Phase 3: Mint test USDC
        // ================================================================
        usdc.mint(deployer, 1_000_000 * 10 ** 6); // 1M USDC for testing
        console.log("Minted 1,000,000 USDC to deployer");

        vm.stopBroadcast();

        // ================================================================
        // Summary
        // ================================================================
        console.log("");
        console.log("=== v2 Deployment Complete ===");
        console.log("");
        console.log("MockUSDC:           ", address(usdc));
        console.log("DelegationRegistry: ", address(delegationRegistry));
        console.log("ShareToken:         ", address(shareToken));
        console.log("VaultV2:            ", address(vault));
        console.log("Exchange:           ", address(exchange));
        console.log("BackstopRouter:     ", address(backstopRouter));
        console.log("MarketLMSR impl:    ", address(marketImpl));
        console.log("FactoryV2:          ", address(factory));
        console.log("");
        console.log("Fee config: creator=%d makerProtocol=%d takerProtocol=%d bps",
            DEFAULT_CREATOR_FEE_BPS, DEFAULT_MAKER_FEE_BPS, DEFAULT_TAKER_FEE_BPS);
        console.log("Duration: min=%d max=%d seconds",
            MIN_MARKET_DURATION, MAX_MARKET_DURATION);
        console.log("");
        console.log("Update deployments.local.ts with the addresses above.");
        console.log("Set deployBlock to the block number of the first tx.");
    }
}
