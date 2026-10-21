// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestBase} from "./TestBase.sol";
import {JobsVault} from "../src/JobsVault.sol";
import {VaultChild} from "../src/VaultChild.sol";
import {Network} from "../src/Network.sol";
import {MockToken} from "./mocks/Mocks.sol";

contract JobsVaultTest is TestBase {
    function testExactThresholdAndPerWalletDailyBoundary() public {
        bind();
        imd.mint(address(jobs), 10 ether);
        token.mint(alice, 1_000_000 ether - 1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientHolding.selector);
        jobs.requestJob("{}");
        token.mint(alice, 1);
        token.mint(bob, 1_000_000 ether);
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(intake.lastPayer(), address(jobs));
        assertEq(intake.lastAction(), Network.JOB_ACTION);
        (address cb, bytes4 sel) = intake.lastCallback();
        assertEq(cb, address(0));
        assertEq(sel, bytes4(0));
        vm.prank(alice);
        vm.expectRevert(JobsVault.DailyLimit.selector);
        jobs.requestJob("{}");
        // A second holder in the same block hits the vault-wide one-job-per-block limit.
        vm.prank(bob);
        vm.expectRevert(JobsVault.DailyLimit.selector);
        jobs.requestJob("{}");
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        jobs.requestJob("{}");
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(jobs.nextRequestAt(alice) - 1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.DailyLimit.selector);
        jobs.requestJob("{}");
        vm.warp(jobs.nextRequestAt(alice));
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(imd.balanceOf(address(jobs)), 10 ether - 3 * PRICE);
        assertEq(imd.allowance(address(jobs), Network.INTAKE), 0);
    }

    function testHoldingHoppedBetweenWalletsCannotDrainBudget() public {
        bind();
        imd.mint(address(jobs), 100 ether);
        uint256 opened;
        for (uint256 i; i < 50; ++i) {
            address wallet = address(uint160(0x5000 + i));
            token.mint(wallet, 1_000_000 ether);
            vm.prank(wallet);
            try jobs.requestJob("{}") {
                ++opened;
            } catch {}
            // Same block for the first ten wallets, then one block each.
            if (i >= 9) vm.roll(vm.getBlockNumber() + 1);
        }
        assertEq(opened, 1 + jobs.MAX_JOBS_PER_DAY() - 1);
        assertEq(imd.balanceOf(address(jobs)), 100 ether - jobs.MAX_JOBS_PER_DAY() * PRICE);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(0xFEED));
        token.mint(address(0xFEED), 1_000_000 ether);
        vm.prank(address(0xFEED));
        jobs.requestJob("{}");
    }

    function testNotConfiguredAndSetTokenOnlyVaultOnce() public {
        vm.expectRevert(VaultChild.NotConfigured.selector);
        jobs.requestJob("{}");
        vm.expectRevert(VaultChild.OnlyVault.selector);
        jobs.setToken(address(token));
        bind();
        vm.prank(address(vault));
        vm.expectRevert(VaultChild.AlreadyConfigured.selector);
        jobs.setToken(address(token));
    }

    function testSixDecimalsThreshold() public {
        JobsVault six = new JobsVault(address(this));
        MockToken sixToken = new MockToken(6);
        six.setToken(address(sixToken));
        imd.mint(address(six), PRICE);
        sixToken.mint(alice, 1_000_000 * 1e6);
        vm.prank(alice);
        six.requestJob("{}");
        assertEq(imd.balanceOf(address(six)), 0);
    }

    function testRejectedRequestsDontConsumeDailySlotAndReentryFails() public {
        bind();
        token.mint(alice, 1_000_000 ether);
        vm.prank(alice);
        vm.expectRevert();
        jobs.requestJob("{}");
        assertEq(jobs.nextRequestAt(alice), 0);
        imd.mint(address(jobs), PRICE);
        intake.setReject(true);
        vm.prank(alice);
        vm.expectRevert();
        jobs.requestJob("{}");
        assertEq(jobs.nextRequestAt(alice), 0);
        intake.setReject(false);
        token.mint(Network.INTAKE, 1_000_000 ether);
        intake.setReenter(address(jobs), abi.encodeCall(jobs.requestJob, (bytes("{}"))));
        vm.prank(alice);
        jobs.requestJob("{}");
        assertFalse(intake.reenterSucceeded());
        assertEq(jobs.nextRequestAt(Network.INTAKE), 0);
    }

    function testInvalidBodyAndUnsoldActionRejected() public {
        bind();
        token.mint(alice, 1_000_000 ether);
        imd.mint(address(jobs), PRICE);
        vm.startPrank(alice);
        vm.expectRevert(JobsVault.InvalidBody.selector);
        jobs.requestJob("");
        vm.expectRevert(JobsVault.InvalidBody.selector);
        jobs.requestJob(new bytes(16385));
        intake.setPrice(0);
        vm.expectRevert(JobsVault.ActionNotSold.selector);
        jobs.requestJob("{}");
        vm.stopPrank();
        assertEq(jobs.nextRequestAt(alice), 0);
    }
}
