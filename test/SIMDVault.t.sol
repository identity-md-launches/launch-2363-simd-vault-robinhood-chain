// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestBase} from "./TestBase.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {CompensationVault} from "../src/CompensationVault.sol";
import {Network} from "../src/Network.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";

contract SIMDVaultTest is TestBase {
    function testLaunchOnlyDevOnlyOnceExactApprovalVaultPayer() public {
        imd.mint(address(vault), 2 ether);
        vm.expectRevert(SIMDVault.OnlyDev.selector);
        vault.launch("{}");
        vm.prank(Network.DEV);
        bytes32 id = vault.launch("{\"objective\":\"Test\"}");
        assertEq(id, vault.launchRequestId());
        assertEq(intake.lastPayer(), address(vault));
        assertEq(intake.lastAction(), bytes32("launch.open@launch-1"));
        assertEq(intake.allowanceSeen(), PRICE);
        assertEq(imd.allowance(address(vault), Network.INTAKE), 0);
        assertEq(imd.balanceOf(address(vault)), 2 ether - PRICE);
        // No value moves on either call back: the result is a record, the failure reopens the ask.
        (address target, bytes4 selector) = intake.lastCallback();
        assertEq(target, address(vault));
        assertEq(selector, vault.onLaunchResult.selector);
        assertEq(intake.lastFailureSelector(), vault.onLaunchFailure.selector);
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.AlreadyLaunched.selector);
        vault.launch("{}");
    }

    function testRefusedLaunchReopensTheOneTimeCallAndOnlyIntakeForTheOwnRequest() public {
        imd.mint(address(vault), 3 * PRICE);
        vm.prank(Network.DEV);
        bytes32 first = vault.launch("{\"objective\":\"Test\"}");
        // Only the Intake, and only for the vault's own pending request.
        vm.expectRevert(SIMDVault.OnlyIntake.selector);
        vault.onLaunchFailure(first, 1, bytes32("body_refused"), 0, 0, "");
        vm.prank(Network.INTAKE);
        vm.expectRevert(SIMDVault.UnknownRequest.selector);
        vault.onLaunchFailure(bytes32(uint256(1)), 1, bytes32("body_refused"), 0, 0, "");
        assertTrue(vault.launched());
        // The plane refuses the body off chain: the price is spent and the call reopens.
        assertTrue(intake.fail(first, 1, bytes32("body_refused")), "failure call must fit the stipend");
        assertFalse(vault.launched());
        assertEq(vault.launchRequestId(), bytes32(0));
        assertEq(imd.balanceOf(address(vault)), 2 * PRICE);
        vm.prank(Network.INTAKE);
        vm.expectRevert(SIMDVault.UnknownRequest.selector);
        vault.onLaunchFailure(first, 1, bytes32("body_refused"), 0, 0, "");
        vm.prank(Network.DEV);
        bytes32 second = vault.launch("{\"objective\":\"Test again\"}");
        assertTrue(second != first);
        // A late result for the first ask is refused; the second ask's result is recorded once.
        vm.prank(Network.INTAKE);
        vm.expectRevert(SIMDVault.UnknownRequest.selector);
        vault.onLaunchResult(first, keccak256("old"), "ipfs://old");
        assertTrue(intake.deliver(second, abi.encode(second, keccak256("result"), "ipfs://cid/result.json")));
        assertEq(vault.launchResultHash(), keccak256("result"));
        vm.prank(Network.INTAKE);
        vm.expectRevert(SIMDVault.UnknownRequest.selector);
        vault.onLaunchResult(second, keccak256("other"), "ipfs://other");
        // A failure after a result, or after binding, cannot reopen the launch.
        vm.prank(Network.INTAKE);
        vm.expectRevert(SIMDVault.UnknownRequest.selector);
        vault.onLaunchFailure(second, 2, bytes32("failed"), 0, 0, "");
        assertTrue(vault.launched());
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.AlreadyLaunched.selector);
        vault.launch("{}");
    }

    function testBoundLaunchCannotBeReopenedByALateFailure() public {
        imd.mint(address(vault), PRICE);
        vm.prank(Network.DEV);
        bytes32 id = vault.launch("{\"objective\":\"Test\"}");
        bind();
        vm.prank(Network.INTAKE);
        vm.expectRevert(SIMDVault.UnknownRequest.selector);
        vault.onLaunchFailure(id, 2, bytes32("cancelled"), 0, 0, "");
        assertTrue(vault.launched());
    }

    function testRejectedLaunchCanRetryAndUnsoldCannotLaunch() public {
        vm.startPrank(Network.DEV);
        vm.expectRevert();
        vault.launch("{}");
        assertFalse(vault.launched());
        imd.mint(address(vault), PRICE);
        intake.setPrice(0);
        vm.expectRevert(SIMDVault.ActionNotSold.selector);
        vault.launch("{}");
        intake.setPrice(PRICE);
        intake.setReject(true);
        vm.expectRevert();
        vault.launch("{}");
        assertFalse(vault.launched());
        intake.setReject(false);
        vault.launch("{}");
        vm.stopPrank();
    }

    function testBindOnlyDevOnceAndValidatesRequesterTokenAndPool() public {
        vm.expectRevert(SIMDVault.OnlyDev.selector);
        vault.bindLaunch(7, address(token));
        factory.configure(key, alice);
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.NotRequester.selector);
        vault.bindLaunch(7, address(token));
        factory.configure(key, address(vault));
        manager.setInitialized(false);
        vm.prank(Network.DEV);
        vm.expectRevert(CompensationVault.InvalidPool.selector);
        vault.bindLaunch(7, address(token));
        assertFalse(vault.bound());
        manager.setInitialized(true);
        vm.prank(Network.DEV);
        vm.expectRevert();
        vault.bindLaunch(7, Network.IMD);
        bind();
        assertEq(vault.token(), address(token));
        assertEq(rewards.token(), address(token));
        assertEq(jobs.token(), address(token));
        assertEq(compensation.token(), address(token));
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.AlreadyBound.selector);
        vault.bindLaunch(8, address(token));
    }

    function testSplitBurnFactoryNativePayoutAndWeekBoundary() public {
        vm.expectRevert(SIMDVault.NotBound.selector);
        vault.distribute();
        bind();
        imd.mint(address(vault), 4000 ether);
        imd.mint(Network.FACTORY, 6000 ether);
        token.mint(address(vault), 23 ether);
        token.mint(Network.FACTORY, 17 ether);
        vm.deal(Network.FACTORY, 2 ether);
        vm.deal(address(vault), 1 ether);
        uint256 nativeBefore = Network.MARKETING.balance;
        vault.distribute();
        assertEq(imd.balanceOf(address(rewards)), 4000 ether - PRICE);
        assertEq(rewards.getEpoch(1).pot, 4000 ether - PRICE);
        assertEq(imd.balanceOf(address(jobs)), 2572 ether);
        assertEq(imd.balanceOf(Network.DEV), 3428 ether);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(Network.BURN), 40 ether);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(Network.MARKETING.balance - nativeBefore, 3 ether);
        assertEq(address(vault).balance, 0);
        vm.expectRevert(SIMDVault.TooEarly.selector);
        vault.distribute();
        vm.warp(vault.nextDistributionAt() - 1);
        vm.expectRevert(SIMDVault.TooEarly.selector);
        vault.distribute();
        vm.warp(vault.nextDistributionAt());
        vm.roll(vm.getBlockNumber() + 1);
        vault.distribute();
        assertEq(rewards.currentEpoch(), 2);
    }

    function testRejectingMarketingCodeKeepsEthWithoutBlockingSplitOrBurn() public {
        bind();
        vm.etch(Network.MARKETING, hex"5f5ffd"); // PUSH0 PUSH0 REVERT: rejects every call
        imd.mint(address(vault), 100 ether);
        token.mint(address(vault), 10 ether);
        vm.deal(address(vault), 1 ether);
        vault.distribute();
        assertEq(imd.balanceOf(address(jobs)), 25.72 ether);
        assertEq(token.balanceOf(Network.BURN), 10 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function testRejectedClaimAndOracleCannotBlockDistributionOrBurn() public {
        bind();
        factory.setReject(true);
        intake.setReject(true);
        imd.mint(address(vault), 100 ether);
        token.mint(address(vault), 10 ether);
        vault.distribute();
        assertEq(imd.balanceOf(address(rewards)), 40 ether);
        assertEq(rewards.getEpoch(1).pot, 40 ether);
        assertEq(rewards.getEpoch(1).requestId, bytes32(0));
        assertEq(imd.balanceOf(address(jobs)), 25.72 ether);
        assertEq(token.balanceOf(Network.BURN), 10 ether);
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
    }

    function testReentrantFactoryAndIMDTransfersCannotDoubleDistribute() public {
        bind();
        imd.mint(address(vault), 100 ether);
        factory.setReenter(address(vault));
        imd.setReenter(address(vault), abi.encodeCall(vault.distribute, ()));
        vault.distribute();
        assertFalse(factory.reenterSucceeded());
        assertFalse(imd.reenterSucceeded());
        assertEq(rewards.currentEpoch(), 1);
        assertEq(imd.balanceOf(address(jobs)), 25.72 ether);
    }

    function testGasExhaustingFactoryAndOracleDoNotPreventSplitAndBurn() public {
        bind();
        imd.mint(address(vault), 100 ether);
        token.mint(address(vault), 10 ether);
        factory.setExhaustGas(true);
        intake.setExhaustGas(true);
        vault.distribute{gas: 6_000_000}();
        assertEq(imd.balanceOf(address(rewards)), 40 ether);
        assertEq(imd.balanceOf(address(jobs)), 25.72 ether);
        assertEq(imd.balanceOf(Network.DEV), 34.28 ether);
        assertEq(token.balanceOf(Network.BURN), 10 ether);
        assertEq(rewards.getEpoch(1).pot, 40 ether);
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
    }

    function testNoAdminOrRequesterTransferOrArbitraryWithdrawal() public {
        bytes4[5] memory selectors = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("withdraw(address,uint256)")),
            bytes4(keccak256("setRequester(uint64,address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(vault).call(abi.encodeWithSelector(selectors[i], alice, 1));
            assertFalse(ok);
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzSplitConservesFundsAndDust(uint128 rawAmount) public {
        bind();
        uint256 amount = rawAmount;
        imd.mint(address(vault), amount);
        vault.distribute();
        uint256 holders = amount * 4000 / 10000;
        uint256 jobShare = amount * 2572 / 10000;
        uint256 devShare = amount * 1714 / 10000;
        uint256 oraclePaid = holders > PRICE ? PRICE : 0;
        assertEq(imd.balanceOf(address(rewards)) + oraclePaid, holders);
        assertEq(imd.balanceOf(address(jobs)), jobShare);
        assertEq(imd.balanceOf(Network.DEV), 2 * devShare);
        assertEq(imd.balanceOf(address(vault)), amount - holders - jobShare - 2 * devShare);
        assertLt(imd.balanceOf(address(vault)), 4);
        assertEq(
            imd.balanceOf(address(rewards)) + imd.balanceOf(address(jobs)) + imd.balanceOf(Network.DEV)
                + imd.balanceOf(address(vault)) + imd.balanceOf(Network.INTAKE),
            amount
        );
    }
}
