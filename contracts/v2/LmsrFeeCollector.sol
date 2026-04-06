// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultV2} from "./VaultV2.sol";

/**
 * @title LmsrFeeCollector
 * @notice Minimal helper to withdraw LMSR fees stranded in VaultV2.feePool
 * @dev
 *   Problem: MarketLMSR accumulates fees via vault.accumulateFee() into feePool,
 *   but has no counter or withdrawal function. Exchange and ShareToken track their
 *   own portions (protocolFeesAccumulated, creatorFeesAccumulated, resolutionFeesAccumulated),
 *   but the LMSR remainder is stuck.
 *
 *   Solution: This contract is whitelisted on VaultV2 via addWhitelistedMarket(),
 *   giving it settlement-level access to call vault.withdrawFeePool(). Admin calls
 *   withdraw() here → we proxy to vault.withdrawFeePool(to, amount).
 *
 *   No VaultV2 redeployment needed. Reversible via vault.removeWhitelistedMarket().
 */
contract LmsrFeeCollector {
    VaultV2 public immutable vault;
    address public admin;

    error NotAdmin();
    error ZeroAmount();
    error ZeroAddress();

    event FeeWithdrawn(address indexed to, uint256 amount);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address _vault, address _admin) {
        require(_vault != address(0), "zero vault");
        require(_admin != address(0), "zero admin");
        vault = VaultV2(_vault);
        admin = _admin;
    }

    /**
     * @notice Withdraw LMSR fees from VaultV2.feePool to a recipient's vault balance
     * @param to Recipient address (typically treasury)
     * @param amount USDC amount to withdraw from feePool
     * @dev Admin should only withdraw the untracked LMSR remainder:
     *      lmsrFees = vault.feePool() - exchange.protocolFeesAccumulated()
     *                 - Σ(exchange.creatorFeesAccumulated) - shareToken.resolutionFeesAccumulated()
     */
    function withdraw(address to, uint256 amount) external onlyAdmin {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        vault.withdrawFeePool(to, amount);
        emit FeeWithdrawn(to, amount);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero admin");
        address old = admin;
        admin = newAdmin;
        emit AdminTransferred(old, newAdmin);
    }
}
