// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {Network} from "../src/Network.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {ILaunchFactory} from "../src/interfaces/ILaunchFactory.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

interface ILiveFactory is ILaunchFactory {
    struct LaunchRecord {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct CustomParams {
        uint64 launchNumber;
        bytes tokenCreationCode;
        bytes32 tokenName;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        Currency pairedCurrency;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        LaunchRecord record;
        uint256[] agentIds;
        address requester;
    }
    function deployer() external view returns (address);
    function poolManager() external view returns (address);
    function launchCustom(CustomParams calldata p)
        external
        returns (address token, address[] memory contracts, address distributor);
}

/// @dev Synthetic token used only inside a local fork, never deployed by the application.
contract ForkToken is ERC20 {
    constructor() ERC20("Fork integration token", "FIT") {
        _mint(msg.sender, 1e26);
    }
}

/// @dev Default suite is network-free. Supply --fork-url explicitly to run these against real code.
contract RobinhoodForkTest is Test {
    uint64 private constant TEST_LAUNCH = type(uint64).max - 4663;
    ILiveFactory private constant factory = ILiveFactory(Network.FACTORY);
    SIMDVault private vault;

    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
        }
        assertEq(block.chainid, 4663);
        assertGt(Network.INTAKE.code.length, 0);
        assertGt(Network.FACTORY.code.length, 0);
        assertEq(factory.poolManager(), Network.POOL_MANAGER);
        vault = new SIMDVault();
        // Align the test's NUMBER with the fork's native L2 snapshot head. No ArbSys mocks.
        vm.roll(vault.holderRewards().snapshotHead());
    }

    function testRealIntakeLaunchPaymentPayerAndOneTimeDevRestriction() public {
        uint256 price = IIntake(Network.INTAKE).priceOf(Network.LAUNCH_ACTION, Network.IMD);
        assertGt(price, 0);
        deal(Network.IMD, address(vault), 2 * price);
        bytes memory body = bytes(
            '{"objective":"Launch Test (TEST), supply 1000000000, plain ERC20 paired with IMD.","onchain":"custom_token","chainId":4663,"economics":{"poolBps":8000,"initialMarketCapWei":"1000000000000000000000"}}'
        );
        vm.expectRevert(SIMDVault.OnlyDev.selector);
        vault.launch(body);
        vm.prank(Network.DEV);
        bytes32 requestId = vault.launch(body);
        assertTrue(requestId != bytes32(0));
        assertEq(IERC20(Network.IMD).balanceOf(address(vault)), price);
        assertEq(IERC20(Network.IMD).allowance(address(vault), Network.INTAKE), 0);
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.AlreadyLaunched.selector);
        vault.launch(body);
    }

    function testRealFactoryBindBuybackFeePayoutSplitAndBurn() public {
        address token = _launchFor(address(vault));
        vm.expectRevert(SIMDVault.OnlyDev.selector);
        vault.bindLaunch(TEST_LAUNCH, token);
        vm.prank(Network.DEV);
        vault.bindLaunch(TEST_LAUNCH, token);
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.AlreadyBound.selector);
        vault.bindLaunch(TEST_LAUNCH, token);
        deal(Network.IMD, address(vault.compensationVault()), 1000 ether);
        vm.warp(vault.compensationVault().buybackAvailableAt());
        // The fixed-reference band can make the vault's own price impact step the reference between
        // fills, so allow more calls than tranches: the budget still ends in ten full tranches.
        for (uint256 i; i < 60 && !vault.compensationVault().buybackComplete(); ++i) {
            vault.compensationVault().buyback();
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
        }
        assertTrue(vault.compensationVault().buybackComplete());
        assertEq(vault.compensationVault().tranches(), 10);
        assertEq(IERC20(Network.IMD).balanceOf(address(vault.compensationVault())), 0);
        // The live factory pays its real position's accrued IMD fees to its requester.
        factory.claimFees(TEST_LAUNCH);
        uint256 fees = IERC20(Network.IMD).balanceOf(address(vault));
        assertGt(fees, 0);
        deal(token, address(vault), 100 ether);
        uint256 burnedBefore = IERC20(token).balanceOf(Network.BURN);
        uint256 devBefore = IERC20(Network.IMD).balanceOf(Network.DEV);
        uint256 price = IIntake(Network.INTAKE).priceOf(Network.ORACLE_ACTION, Network.IMD);
        vault.distribute();
        assertEq(IERC20(token).balanceOf(Network.BURN) - burnedBefore, 100 ether);
        assertEq(IERC20(Network.IMD).balanceOf(address(vault.jobsVault())), fees * 2572 / 10000);
        assertEq(IERC20(Network.IMD).balanceOf(Network.DEV) - devBefore, 2 * (fees * 1714 / 10000));
        assertEq(vault.holderRewards().getEpoch(1).pot, fees * 4000 / 10000 - price);
        assertEq(vault.holderRewards().getEpoch(1).snapshotBlock, vm.getBlockNumber());
        vm.expectRevert(SIMDVault.TooEarly.selector);
        vault.distribute();
    }

    function testRealFactoryRejectsLaunchOwnedByAnotherRequester() public {
        address token = _launchFor(address(this));
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.NotRequester.selector);
        vault.bindLaunch(TEST_LAUNCH, token);
    }

    function _launchFor(address requester) private returns (address token) {
        // Only fork-local impersonation; this never submits a transaction or uses a key.
        ILiveFactory.CustomParams memory p;
        p.launchNumber = TEST_LAUNCH;
        p.tokenCreationCode = type(ForkToken).creationCode;
        p.tokenName = "ForkToken";
        p.contractCreationCodes = new bytes[](0);
        p.contractNames = new bytes32[](0);
        p.expectedContracts = new address[](0);
        p.totalSupply = 1e26;
        p.poolBps = 8000;
        p.remainderTo = address(vault.compensationVault());
        p.merkleRoot = keccak256("fork fixture swarm allocation");
        p.sweepDelaySeconds = 90 days;
        p.pairedCurrency = Currency.wrap(Network.IMD);
        p.tickSpacing = 60;
        p.sqrtPriceX96 = uint160(1 << 96);
        p.tickLower = -600;
        p.tickUpper = 600;
        p.liquidity = 1e24;
        p.requester = requester;
        p.agentIds = new uint256[](0);
        deal(Network.IMD, Network.FACTORY, 1e26);
        address deployer = factory.deployer();
        vm.prank(deployer);
        (token,,) = factory.launchCustom(p);
        (PoolKey memory key,,, address payer) = factory.positionOf(TEST_LAUNCH);
        assertEq(payer, requester);
        assertTrue(
            Currency.unwrap(key.currency0) == Network.IMD || Currency.unwrap(key.currency1) == Network.IMD
        );
    }
}
