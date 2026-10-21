// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultChild} from "./VaultChild.sol";
import {Network} from "./Network.sol";
import {IIntake} from "./interfaces/IIntake.sol";

/// @notice Pays Identity.md jobs for holders: any wallet holding at least 1,000,000 of the launched
/// token may open one job per 24 hours, paid from this vault's IMD. Exactly the brief's rule and
/// nothing vault-wide: a vault-wide cap can be filled by one holder moving a bag through fresh
/// wallets and then refuses every other eligible holder, so the per-wallet rule is the only limit.
/// The eligibility check is a spot balance; the same tokens moved between wallets can open more than
/// one job per day. That is a property of the requested rule and is documented in the README.
contract JobsVault is VaultChild {
    using SafeERC20 for IERC20;

    error InsufficientHolding();
    error DailyLimit();
    error ActionNotSold();
    error InvalidBody();

    uint256 public constant COOLDOWN = 1 days;
    uint256 public minimumHolding;
    mapping(address => uint256) public nextRequestAt;

    event JobRequested(address indexed holder, bytes32 indexed requestId, uint256 price);

    constructor(address vault_) VaultChild(vault_) {}

    function setToken(address token_) external onlyVault {
        _setToken(token_);
        uint8 decimals = IERC20Metadata(token_).decimals();
        if (decimals > 71) revert InvalidToken();
        minimumHolding = 1_000_000 * 10 ** uint256(decimals);
    }

    function requestJob(bytes calldata body) external nonReentrant returns (bytes32 requestId) {
        if (token == address(0)) revert NotConfigured();
        if (IERC20(token).balanceOf(msg.sender) < minimumHolding) revert InsufficientHolding();
        if (block.timestamp < nextRequestAt[msg.sender]) revert DailyLimit();
        if (body.length == 0 || body.length > 16_384) revert InvalidBody();
        uint256 price = IIntake(Network.INTAKE).priceOf(Network.JOB_ACTION, Network.IMD);
        if (price == 0) revert ActionNotSold();
        nextRequestAt[msg.sender] = block.timestamp + COOLDOWN;
        IERC20(Network.IMD).forceApprove(Network.INTAKE, price);
        requestId = IIntake(Network.INTAKE)
            .request(Network.JOB_ACTION, body, IIntake.Callback(address(0), bytes4(0)), Network.IMD, price);
        IERC20(Network.IMD).forceApprove(Network.INTAKE, 0);
        emit JobRequested(msg.sender, requestId, price);
    }
}
