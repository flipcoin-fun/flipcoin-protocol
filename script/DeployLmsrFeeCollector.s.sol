// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/v2/VaultV2.sol";
import "../contracts/v2/LmsrFeeCollector.sol";

/**
 * @title DeployLmsrFeeCollector
 * @notice Deploys LmsrFeeCollector and whitelists it on existing VaultV2
 *
 * Does NOT redeploy VaultV2. Only:
 *   1. Deploys LmsrFeeCollector(vault, admin)
 *   2. Calls vault.addWhitelistedMarket(feeCollector) — gives it withdrawFeePool access
 *
 * After deployment, add the address to flipcoin-app deployments.local.ts:
 *   deploymentsBaseMainnetV2.feeCollector = "0x...";
 *
 * Usage (testnet):
 *   source .env
 *   forge script script/DeployLmsrFeeCollector.s.sol:DeployLmsrFeeCollectorScript \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --broadcast -vvvv
 *
 * Usage (mainnet — multisig):
 *   forge script script/DeployLmsrFeeCollector.s.sol:DeployLmsrFeeCollectorScript \
 *     --rpc-url $BASE_RPC_URL \
 *     --broadcast -vvvv
 *
 * For multisig deployment: use the generated tx data from --broadcast output
 * and submit through Safe (gnosis-safe.io).
 */
contract DeployLmsrFeeCollectorScript is Script {
    function run() external {
        // ── Config: update these for your target network ──

        // Base mainnet VaultV2
        address VAULT = 0xACBf5A2f23d2b959D0623fe4345D3F9369dEA15a;
        // Multisig admin
        address ADMIN = 0x2196031BeA489f695a653396680B6A3916d9a208;

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== LmsrFeeCollector Deployment ===");
        console.log("Deployer:", deployer);
        console.log("VaultV2: ", VAULT);
        console.log("Admin:   ", ADMIN);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy LmsrFeeCollector
        LmsrFeeCollector collector = new LmsrFeeCollector(VAULT, ADMIN);
        console.log("[1/2] LmsrFeeCollector:", address(collector));

        // 2. Whitelist on VaultV2
        //    NOTE: This call must come from VaultV2.admin (the multisig).
        //    If deployer != admin, this will revert — use Safe to queue this tx.
        if (deployer == ADMIN) {
            VaultV2(VAULT).addWhitelistedMarket(address(collector));
            console.log("[2/2] Whitelisted on VaultV2");
        } else {
            console.log("[2/2] SKIP: deployer != admin. Queue this tx via Safe:");
            console.log("       vault.addWhitelistedMarket(%s)", address(collector));
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("LmsrFeeCollector:", address(collector));
        console.log("");
        console.log("Next steps:");
        console.log("  1. If not done above: vault.addWhitelistedMarket(<address>) via Safe");
        console.log("  2. Add to flipcoin-app: deploymentsBaseMainnetV2.feeCollector = '0x...'");
        console.log("  3. Verify on Basescan: verify contract source");
    }
}
