// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultChild} from "./VaultChild.sol";
import {Network} from "./Network.sol";
import {IIntake} from "./interfaces/IIntake.sol";

contract JobsVault is VaultChild {
    using SafeERC20 for IERC20;

    error InsufficientHolding();
    error DailyLimit();
    error ActionNotSold();
    error InvalidBody();

    uint256 public constant COOLDOWN = 1 days;
    /// @notice Vault-wide limits: a holding moved between wallets still opens at most one job per
    /// block and the whole vault opens at most MAX_JOBS_PER_DAY jobs per 24-hour period.
    uint256 public constant MAX_JOBS_PER_DAY = 24;
    uint256 public lastJobBlock;
    uint256 public periodStart;
    uint256 public jobsInPeriod;
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
        if (lastJobBlock == block.number) revert DailyLimit();
        if (block.timestamp >= periodStart + COOLDOWN) {
            periodStart = block.timestamp;
            jobsInPeriod = 0;
        }
        if (jobsInPeriod >= MAX_JOBS_PER_DAY) revert DailyLimit();
        ++jobsInPeriod;
        lastJobBlock = block.number;
        nextRequestAt[msg.sender] = block.timestamp + COOLDOWN;
        IERC20(Network.IMD).forceApprove(Network.INTAKE, price);
        requestId = IIntake(Network.INTAKE)
            .request(Network.JOB_ACTION, body, IIntake.Callback(address(0), bytes4(0)), Network.IMD, price);
        IERC20(Network.IMD).forceApprove(Network.INTAKE, 0);
        emit JobRequested(msg.sender, requestId, price);
    }
}
