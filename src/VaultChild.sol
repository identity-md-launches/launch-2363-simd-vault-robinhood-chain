// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

abstract contract VaultChild is ReentrancyGuard {
    error OnlyVault();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidToken();

    address public immutable vault;
    address public token;

    event TokenSet(address indexed token);

    constructor(address vault_) {
        require(vault_ != address(0), "zero vault");
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function _setToken(address token_) internal {
        if (token != address(0)) revert AlreadyConfigured();
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = token_;
        emit TokenSet(token_);
    }
}
