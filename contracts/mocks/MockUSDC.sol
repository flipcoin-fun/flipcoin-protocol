// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token for testing (6 decimals)
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Mint tokens to an address (for testing)
     * @param to Recipient address
     * @param amount Amount to mint (6 decimals)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Convenience faucet - mint 1000 USDC to caller
     */
    function faucet() external {
        _mint(msg.sender, 1000 * 10 ** 6);
    }
}
