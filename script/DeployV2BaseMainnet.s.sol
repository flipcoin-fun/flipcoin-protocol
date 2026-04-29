// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/v2/DelegationRegistry.sol";
import "../contracts/v2/ShareToken.sol";
import "../contracts/v2/VaultV2.sol";
import "../contracts/v2/Exchange.sol";
import "../contracts/v2/BackstopRouter.sol";
import "../contracts/v2/MarketLMSR.sol";
import "../contracts/v2/FactoryV2.sol";
import "../contracts/v2/DepositRouter.sol";

/**
 * @title DeployV2BaseMainnet
 * @notice Deploys the full v2 Hybrid CLOB + LMSR stack to Base Mainnet
 *
 * Key differences from testnet:
 *   - Real USDC (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)
 *   - Admin = multisig (0xSAFE_MAIN), NOT deployer
 *   - Fee recipient = treasury, NOT deployer
 *   - MIN_MARKET_DURATION = 6 hours (not 5 minutes)
 *   - DepositRouter included in deployment
 *   - No MockUSDC mint
 *
 * Deployment order (8 contracts):
 *   1. DelegationRegistry
 *   2. ShareToken (ERC-1155)
 *   3. VaultV2 (Model A: 4 pools)
 *   4. Exchange (CLOB)
 *   5. BackstopRouter (LMSR entry point)
 *   6. MarketLMSR (implementation for EIP-1167 clones)
 *   7. FactoryV2 (market creation)
 *   8. DepositRouter (delegated deposits)
 *
 * Post-deploy wiring:
 *   - ShareToken: setFactory, setVault, setExchange, addAuthorizedCaller(exchange)
 *   - ShareToken: setResolutionFeeRecipient(treasury)
 *   - VaultV2: addTrustedFactory, setExchange, setShareToken, setBackstopRouter
 *   - VaultV2: addWhitelistedMarket(depositRouter)
 *   - Exchange: setFactory
 *   - BackstopRouter: setFactory
 *   - DelegationRegistry: addAuthorizedContract(exchange, backstopRouter, factory, depositRouter)
 *   - FactoryV2: addRelayer(deployer)
 *
 * Post-deploy manual steps (from multisig):
 *   1. Verify all contracts on Basescan
 *   2. Transfer admin on ALL contracts to multisig (deployer calls transferOwnership)
 *   3. Smoke test: create market, buy, sell, resolve
 *
 * Usage:
 *   source .env
 *   forge script script/DeployV2BaseMainnet.s.sol:DeployV2BaseMainnetScript \
 *     --rpc-url $BASE_MAINNET_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployV2BaseMainnetScript is Script {
    // ── Addresses ──
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant MULTISIG = 0x2196031BeA489f695a653396680B6A3916d9a208; // 0xSAFE_MAIN
    address constant TREASURY = 0x22fc0734aeFDFFdd7cE22619aD3016043C94f64a; // 0xTREASURY

    // ── Fee Config ──
    uint16 constant DEFAULT_CREATOR_FEE_BPS = 100; // 1.0%
    uint16 constant DEFAULT_MAKER_FEE_BPS = 0;     // 0%
    uint16 constant DEFAULT_TAKER_FEE_BPS = 50;    // 0.5%

    // ── Duration Config ──
    uint64 constant MIN_MARKET_DURATION = 6 hours;
    uint64 constant MAX_MARKET_DURATION = 365 days;

    // ── DepositRouter Config ──
    uint256 constant MAX_DEPOSIT_PER_TX = 100_000 * 10 ** 6; // $100,000

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_METAMASK");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== FlipCoin v2 Deployment (Base MAINNET) ===");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        console.log("Multisig (admin):", MULTISIG);
        console.log("Treasury (fees):", TREASURY);
        console.log("USDC:", USDC);
        console.log("");

        // Safety check: deployer is NOT the multisig (deployer is EOA, admin is multisig)
        require(deployer != MULTISIG, "Deployer must not be multisig");

        vm.startBroadcast(deployerPrivateKey);

        // ================================================================
        // Phase 1: Deploy all contracts (deployer is initial admin)
        // ================================================================

        // 1. DelegationRegistry
        DelegationRegistry delegationRegistry = new DelegationRegistry(deployer);
        console.log("[1/8] DelegationRegistry:", address(delegationRegistry));

        // 2. ShareToken
        ShareToken shareToken = new ShareToken("", deployer);
        console.log("[2/8] ShareToken:", address(shareToken));

        // 3. VaultV2
        VaultV2 vault = new VaultV2(USDC, deployer);
        console.log("[3/8] VaultV2:", address(vault));

        // 4. Exchange (CLOB)
        Exchange exchange = new Exchange(
            deployer,           // admin (transferred to multisig later)
            deployer,           // operator (transferred to multisig later)
            address(shareToken),
            address(vault),
            address(delegationRegistry),
            TREASURY,           // protocolFeeRecipient → treasury
            DEFAULT_MAKER_FEE_BPS,
            DEFAULT_TAKER_FEE_BPS
        );
        console.log("[4/8] Exchange:", address(exchange));

        // 5. BackstopRouter (LMSR)
        BackstopRouter backstopRouter = new BackstopRouter(
            address(vault),
            address(shareToken),
            address(delegationRegistry),
            deployer            // admin (transferred to multisig later)
        );
        console.log("[5/8] BackstopRouter:", address(backstopRouter));

        // 6. MarketLMSR implementation (EIP-1167 clone template)
        MarketLMSR marketImpl = new MarketLMSR();
        console.log("[6/8] MarketLMSR impl:", address(marketImpl));

        // 7. FactoryV2
        FactoryV2 factory = new FactoryV2(
            deployer,           // admin (transferred to multisig later)
            TREASURY,           // protocolAddress → treasury
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
        console.log("[7/8] FactoryV2:", address(factory));

        // 8. DepositRouter
        DepositRouter depositRouter = new DepositRouter(
            address(vault),
            address(delegationRegistry),
            USDC,
            deployer,           // admin (transferred to multisig later)
            MAX_DEPOSIT_PER_TX
        );
        console.log("[8/8] DepositRouter:", address(depositRouter));

        // ================================================================
        // Phase 2: Post-deploy wiring (deployer is still admin)
        // ================================================================
        console.log("");
        console.log("--- Wiring contracts ---");

        // ShareToken wiring
        shareToken.setFactory(address(factory));
        shareToken.setVault(address(vault));
        shareToken.setExchange(address(exchange));
        shareToken.addAuthorizedCaller(address(exchange));
        shareToken.setResolutionFeeRecipient(TREASURY);
        console.log("ShareToken: factory, vault, exchange, resolutionFeeRecipient(treasury) set");

        // VaultV2 wiring
        vault.addTrustedFactory(address(factory));
        vault.setExchange(address(exchange));
        vault.setShareToken(address(shareToken));
        vault.setBackstopRouter(address(backstopRouter));
        vault.addWhitelistedMarket(address(depositRouter));
        console.log("VaultV2: factory, exchange, shareToken, backstopRouter, depositRouter set");

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
        delegationRegistry.addAuthorizedContract(address(depositRouter));
        console.log("DelegationRegistry: exchange, backstopRouter, factory, depositRouter authorized");

        // FactoryV2 — add deployer as relayer for meta-tx
        factory.addRelayer(deployer);
        console.log("FactoryV2: deployer added as relayer");

        // ================================================================
        // Phase 3: Transfer ownership to multisig
        // ================================================================
        console.log("");
        console.log("--- Transferring ownership to multisig ---");

        delegationRegistry.transferAdmin(MULTISIG);
        console.log("DelegationRegistry: admin -> multisig");

        shareToken.transferAdmin(MULTISIG);
        console.log("ShareToken: admin -> multisig");

        vault.transferAdmin(MULTISIG);
        console.log("VaultV2: admin -> multisig");

        exchange.transferAdmin(MULTISIG);
        console.log("Exchange: admin -> multisig");

        backstopRouter.transferAdmin(MULTISIG);
        console.log("BackstopRouter: admin -> multisig");

        factory.transferAdmin(MULTISIG);
        console.log("FactoryV2: admin -> multisig");

        depositRouter.transferAdmin(MULTISIG);
        console.log("DepositRouter: admin -> multisig");

        vm.stopBroadcast();

        // ================================================================
        // Summary
        // ================================================================
        console.log("");
        console.log("=== v2 MAINNET Deployment Complete ===");
        console.log("");
        console.log("USDC (real):        ", USDC);
        console.log("DelegationRegistry: ", address(delegationRegistry));
        console.log("ShareToken:         ", address(shareToken));
        console.log("VaultV2:            ", address(vault));
        console.log("Exchange:           ", address(exchange));
        console.log("BackstopRouter:     ", address(backstopRouter));
        console.log("MarketLMSR impl:    ", address(marketImpl));
        console.log("FactoryV2:          ", address(factory));
        console.log("DepositRouter:      ", address(depositRouter));
        console.log("");
        console.log("Admin (multisig):   ", MULTISIG);
        console.log("Treasury (fees):    ", TREASURY);
        console.log("Relayer:            ", deployer);
        console.log("");
        console.log("Fee config: creator=%d makerProtocol=%d takerProtocol=%d bps",
            DEFAULT_CREATOR_FEE_BPS, DEFAULT_MAKER_FEE_BPS, DEFAULT_TAKER_FEE_BPS);
        console.log("Duration: min=%d max=%d seconds",
            MIN_MARKET_DURATION, MAX_MARKET_DURATION);
        console.log("");
        console.log("IMPORTANT: All admin roles transferred to multisig.");
        console.log("Deployer retains ONLY relayer role (for meta-tx).");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Verify contracts on Basescan (--verify flag)");
        console.log("  2. Update deployments/base-mainnet.json with addresses above");
        console.log("  3. Set NEXT_PUBLIC_CHAIN_ID=8453 in Vercel");
        console.log("  4. Smoke test: deposit, create market, trade, resolve");
    }
}
