// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Network} from "./Network.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";
import {HolderRewards} from "./HolderRewards.sol";
import {JobsVault} from "./JobsVault.sol";
import {CompensationVault} from "./CompensationVault.sol";

/// @notice The permanent payer/requester of the Test launch. No owner or arbitrary execution path.
contract SIMDVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyDev();
    error AlreadyLaunched();
    error AlreadyBound();
    error NotBound();
    error NotRequester();
    error TooEarly();
    error InvalidBody();
    error ActionNotSold();

    HolderRewards public immutable holderRewards;
    JobsVault public immutable jobsVault;
    CompensationVault public immutable compensationVault;
    uint256 public constant DISTRIBUTION_INTERVAL = 7 days;
    uint256 public constant CLAIM_GAS_LIMIT = 1_000_000;
    address public constant IMD = Network.IMD;
    address public constant INTAKE = Network.INTAKE;
    address public constant FACTORY = Network.FACTORY;
    address public constant DEV = Network.DEV;
    address public constant MARKETING = Network.MARKETING;
    address public token;
    uint64 public launchNumber;
    bool public launched;
    bool public bound;
    uint256 public nextDistributionAt;
    bytes32 public launchRequestId;

    event LaunchRequested(bytes32 indexed requestId, uint256 price);
    event LaunchBound(uint64 indexed launchNumber, address indexed token);
    event FeeClaimFailed(uint64 indexed launchNumber);
    event Distributed(
        uint256 imdBalance,
        uint256 holders,
        uint256 jobs,
        uint256 dev,
        uint256 marketing,
        uint256 burned,
        uint256 nativePaid
    );

    constructor() {
        jobsVault = new JobsVault(address(this));
        compensationVault = new CompensationVault(address(this));
        holderRewards = new HolderRewards(address(this), address(jobsVault), address(compensationVault));
    }

    receive() external payable {}

    modifier onlyDev() {
        if (msg.sender != DEV) revert OnlyDev();
        _;
    }

    function launch(bytes calldata body) external onlyDev nonReentrant returns (bytes32 requestId) {
        if (launched) revert AlreadyLaunched();
        if (body.length == 0 || body.length > 16_384) revert InvalidBody();
        uint256 price = IIntake(INTAKE).priceOf(Network.LAUNCH_ACTION, IMD);
        if (price == 0) revert ActionNotSold();
        launched = true;
        IERC20(IMD).forceApprove(INTAKE, price);
        requestId = IIntake(INTAKE)
            .request(Network.LAUNCH_ACTION, body, IIntake.Callback(address(0), bytes4(0)), IMD, price);
        IERC20(IMD).forceApprove(INTAKE, 0);
        launchRequestId = requestId;
        emit LaunchRequested(requestId, price);
    }

    function bindLaunch(uint64 number, address token_) external onlyDev nonReentrant {
        if (bound) revert AlreadyBound();
        (PoolKey memory key,,, address requester) = ILaunchFactory(FACTORY).positionOf(number);
        if (requester != address(this)) revert NotRequester();
        bound = true;
        token = token_;
        launchNumber = number;
        holderRewards.setToken(token_);
        jobsVault.setToken(token_);
        compensationVault.setLaunch(token_, key);
        emit LaunchBound(number, token_);
    }

    function distribute() external nonReentrant {
        if (!bound) revert NotBound();
        if (block.timestamp < nextDistributionAt) revert TooEarly();
        nextDistributionAt = block.timestamp + DISTRIBUTION_INTERVAL;
        try ILaunchFactory(FACTORY).claimFees{gas: CLAIM_GAS_LIMIT}(launchNumber) {}
        catch {
            emit FeeClaimFailed(launchNumber);
        }
        IERC20 imd = IERC20(IMD);
        uint256 balance = imd.balanceOf(address(this));
        uint256 holders = Math.mulDiv(balance, 4000, 10_000);
        uint256 jobs = Math.mulDiv(balance, 2572, 10_000);
        uint256 dev = Math.mulDiv(balance, 1714, 10_000);
        uint256 marketing = Math.mulDiv(balance, 1714, 10_000);
        imd.safeTransfer(address(holderRewards), holders);
        holderRewards.onDeposit(holders);
        imd.safeTransfer(address(jobsVault), jobs);
        imd.safeTransfer(DEV, dev);
        imd.safeTransfer(MARKETING, marketing);
        uint256 burned = IERC20(token).balanceOf(address(this));
        if (burned != 0) IERC20(token).safeTransfer(Network.BURN, burned);
        uint256 nativePaid = address(this).balance;
        if (nativePaid != 0) {
            // A rejected native push never blocks the split or the burn: the ETH waits for next week.
            (bool ok,) = MARKETING.call{value: nativePaid}("");
            if (!ok) nativePaid = 0;
        }
        emit Distributed(balance, holders, jobs, dev, marketing, burned, nativePaid);
    }
}
