// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title MockEIP1271Wallet
 * @notice Smart contract wallet that validates EIP-1271 signatures via an EOA owner
 */
contract MockEIP1271Wallet is IERC1271 {
    using ECDSA for bytes32;

    address public owner;
    bool public alwaysReject;

    bytes4 private constant MAGIC_VALUE = 0x1626ba7e;

    constructor(address _owner) {
        owner = _owner;
    }

    function setAlwaysReject(bool _reject) external {
        alwaysReject = _reject;
    }

    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override
        returns (bytes4)
    {
        if (alwaysReject) return bytes4(0xffffffff);

        address recovered = ECDSA.recover(hash, signature);
        if (recovered == owner) {
            return MAGIC_VALUE;
        }
        return bytes4(0xffffffff);
    }

    // ERC-1155 receiver (needed for receiving shares)
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
