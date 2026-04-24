// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/v2/DepositRouter.sol";
import "../contracts/v2/VaultV2.sol";
import "../contracts/v2/DelegationRegistry.sol";

/**
 * @title DeployDepositRouter
 * @notice Deploys DepositRouter and wires it with existing VaultV2 + DelegationRegistry
 *
 * Prerequisites:
 *   - VaultV2 and DelegationRegistry already deployed
 *   - Deployer is admin of both contracts
 *
 * Usage:
 *   source .env
 *   forge script script/DeployDepositRouter.s.sol:DeployDepositRouterScript \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract DeployDepositRouterScript is Script {
    // ── Existing v2 deployments on Base Sepolia ──
    address constant USDC = 0xF60a5A0fca9805bFc5a5cdf9356F67091aD5DebD;
    address constant VAULT_V2 = 0xF23527BD7989fbde345059D1AaAFa663532C01c1;
    address constant DELEGATION_REGISTRY = 0x945f5557b3B0037b9cEB694303C33d418251762A;

    // ── Config ──
    uint256 constant MAX_DEPOSIT_PER_TX = 100_000 * 10 ** 6; // $100,000 per tx

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_METAMASK");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DepositRouter Deployment (Base Sepolia) ===");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        console.log("");
        console.log("Using existing contracts:");
        console.log("  USDC:               ", USDC);
        console.log("  VaultV2:            ", VAULT_V2);
        console.log("  DelegationRegistry: ", DELEGATION_REGISTRY);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy DepositRouter
        DepositRouter depositRouter = new DepositRouter(
            VAULT_V2,
            DELEGATION_REGISTRY,
            USDC,
            deployer,
            MAX_DEPOSIT_PER_TX
        );
        console.log("[1/3] DepositRouter deployed:", address(depositRouter));

        // 2. Wire VaultV2: whitelist DepositRouter for transferBetween
        VaultV2(VAULT_V2).addWhitelistedMarket(address(depositRouter));
        console.log("[2/3] VaultV2: DepositRouter whitelisted");

        // 3. Wire DelegationRegistry: authorize DepositRouter
        DelegationRegistry(DELEGATION_REGISTRY).addAuthorizedContract(address(depositRouter));
        console.log("[3/3] DelegationRegistry: DepositRouter authorized");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DepositRouter Deployment Complete ===");
        console.log("DepositRouter:", address(depositRouter));
        console.log("MaxDepositPerTx: $100,000");
        console.log("");
        console.log("Update deployments.local.ts: deploymentsBaseSepoliaV2.depositRouter");
    }
}
