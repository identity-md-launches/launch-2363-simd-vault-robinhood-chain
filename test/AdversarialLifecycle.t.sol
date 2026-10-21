// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {SIMDVault} from "src/SIMDVault.sol";
import {HolderRewards} from "src/HolderRewards.sol";
import {JobsVault} from "src/JobsVault.sol";
import {VaultChild} from "src/VaultChild.sol";
import {Network} from "src/Network.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/oracle/OracleAttestation.sol";
import {MockToken} from "./mocks/Mocks.sol";

contract RejectNativePayment {
    receive() external payable {
        revert("recipient rejected");
    }
}

contract BurnRejectingToken is MockToken {
    bool public rejectBurn;

    constructor() MockToken(18) {}

    function setRejectBurn(bool value) external {
        rejectBurn = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!rejectBurn || to != Network.BURN, "burn rejected");
        return super.transfer(to, amount);
    }
}

contract AdversarialLaunchAndDistributionTest is TestBase {
    function testLaunchBodyBoundsDoNotConsumeOneTimePermission() public {
        imd.mint(address(vault), 3 ether);
        vm.startPrank(Network.DEV);
        vm.expectRevert(SIMDVault.InvalidBody.selector);
        vault.launch("");
        vm.expectRevert(SIMDVault.InvalidBody.selector);
        vault.launch(new bytes(16_385));
        vm.stopPrank();
        assertFalse(vault.launched());
        assertEq(vault.launchRequestId(), bytes32(0));
        assertEq(intake.nonce(), 0);
        assertEq(imd.allowance(address(vault), Network.INTAKE), 0);

        // A bounded opaque body is forwarded byte for byte. Admission is an off-chain concern.
        bytes memory body = new bytes(16_384);
        body[0] = "{";
        body[16_383] = "}";
        intake.setPrice(1.25 ether);
        vm.prank(Network.DEV);
        vault.launch(body);
        assertEq(intake.lastBody(), body);
        assertEq(intake.allowanceSeen(), 1.25 ether);
        assertEq(imd.balanceOf(address(vault)), 1.75 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzUnauthorizedLaunchAndBindingLeaveAllStateUntouched(address caller, uint64 number)
        public
    {
        vm.assume(caller != Network.DEV);
        imd.mint(address(vault), PRICE);
        vm.startPrank(caller);
        vm.expectRevert(SIMDVault.OnlyDev.selector);
        vault.launch("{}");
        vm.expectRevert(SIMDVault.OnlyDev.selector);
        vault.bindLaunch(number, address(token));
        vm.stopPrank();
        assertFalse(vault.launched());
        assertFalse(vault.bound());
        assertEq(intake.nonce(), 0);
        assertEq(imd.balanceOf(address(vault)), PRICE);
        assertEq(rewards.token(), address(0));
        assertEq(jobs.token(), address(0));
        assertEq(compensation.token(), address(0));
    }

    function testLateChildConfigurationFailureRollsBackEarlierChildrenAndCanRetry() public {
        MockToken excessiveDecimals = new MockToken(72);
        factory.configure(poolFor(address(excessiveDecimals)), address(vault));
        vm.prank(Network.DEV);
        vm.expectRevert(VaultChild.InvalidToken.selector);
        vault.bindLaunch(77, address(excessiveDecimals));
        assertFalse(vault.bound());
        assertEq(vault.launchNumber(), 0);
        assertEq(vault.token(), address(0));
        assertEq(rewards.token(), address(0));
        assertEq(jobs.token(), address(0));
        assertEq(compensation.token(), address(0));
        factory.configure(key, address(vault));
        bind();
        assertEq(vault.launchNumber(), 7);
        assertEq(rewards.token(), address(token));
    }

    function testBurnFailureRevertsClaimSplitEpochAndCooldownTogether() public {
        BurnRejectingToken burnToken = new BurnRejectingToken();
        token = burnToken;
        key = poolFor(address(token));
        factory.configure(key, address(vault));
        bind();
        imd.mint(address(vault), 100 ether);
        imd.mint(Network.FACTORY, 25 ether);
        token.mint(address(vault), 1 ether);
        token.mint(Network.FACTORY, 2 ether);
        // Fee collection succeeds; only the later transfer to the burn address fails.
        burnToken.setRejectBurn(true);
        vm.expectRevert(bytes("burn rejected"));
        vault.distribute();
        assertEq(vault.nextDistributionAt(), 0);
        assertEq(rewards.currentEpoch(), 0);
        assertEq(rewards.totalReserved(), 0);
        assertEq(imd.balanceOf(address(vault)), 100 ether);
        assertEq(imd.balanceOf(Network.FACTORY), 25 ether);
        assertEq(token.balanceOf(Network.FACTORY), 2 ether);
        assertEq(factory.calls(), 0);
        assertEq(imd.balanceOf(address(jobs)), 0);
        assertEq(imd.balanceOf(Network.DEV), 0);
        assertEq(intake.nonce(), 0);
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
        burnToken.setRejectBurn(false);
        vault.distribute();
        assertEq(token.balanceOf(Network.BURN), 3 ether);
        assertEq(factory.calls(), 1);
        assertEq(rewards.currentEpoch(), 1);
        assertEq(imd.balanceOf(address(jobs)), 32.15 ether);
    }

    function testRejectedNativeRecipientKeepsEthUntilAcceptingWeek() public {
        bind();
        imd.mint(address(vault), 100 ether);
        token.mint(address(vault), 9 ether);
        vm.deal(address(vault), 2 ether);
        vm.etch(Network.MARKETING, address(new RejectNativePayment()).code);
        // The rejected push neither blocks the split/burn nor leaves ETH anywhere but the vault.
        vault.distribute();
        assertEq(vault.nextDistributionAt(), block.timestamp + 7 days);
        assertEq(rewards.currentEpoch(), 1);
        assertEq(imd.balanceOf(address(jobs)), 25.72 ether);
        assertEq(token.balanceOf(Network.BURN), 9 ether);
        assertEq(address(vault).balance, 2 ether);
        // No early retry is possible; the ETH waits for the next week.
        vm.etch(Network.MARKETING, "");
        vm.expectRevert(SIMDVault.TooEarly.selector);
        vault.distribute();
        vm.warp(vault.nextDistributionAt());
        vm.roll(vm.getBlockNumber() + 1);
        vm.deal(address(vault), 3 ether);
        uint256 beforeNative = Network.MARKETING.balance;
        vault.distribute();
        assertEq(Network.MARKETING.balance - beforeNative, 3 ether);
        assertEq(address(vault).balance, 0);
    }

    function testMaximumUintBalanceSplitsWithoutIntermediateOverflow() public {
        bind();
        uint256 amount = type(uint256).max;
        imd.mint(address(vault), amount);
        vault.distribute();
        // Independent quotient/remainder calculation, without multiplying a uint256 balance.
        uint256 holders = (amount / 10_000) * 4000 + (amount % 10_000) * 4000 / 10_000;
        uint256 jobShare = (amount / 10_000) * 2572 + (amount % 10_000) * 2572 / 10_000;
        uint256 devShare = (amount / 10_000) * 1714 + (amount % 10_000) * 1714 / 10_000;
        assertEq(imd.balanceOf(address(rewards)), holders - PRICE);
        assertEq(imd.balanceOf(address(jobs)), jobShare);
        assertEq(imd.balanceOf(Network.DEV), 2 * devShare);
        assertEq(imd.balanceOf(address(vault)), amount - holders - jobShare - 2 * devShare);
        assertLt(imd.balanceOf(address(vault)), 4);
    }

    function testRoundingDustParticipatesInFollowingWeek() public {
        bind();
        imd.mint(address(vault), 9);
        vault.distribute();
        assertEq(imd.balanceOf(address(vault)), 2);
        imd.mint(address(vault), 9_998);
        vm.warp(vault.nextDistributionAt());
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        vault.distribute();
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(imd.balanceOf(address(rewards)), 4_003);
        assertEq(imd.balanceOf(address(jobs)), 2_574);
        assertEq(imd.balanceOf(Network.DEV), 3_430);
    }
}

contract AdversarialOracleLifecycleTest is TestBase {
    function setUp() public override {
        super.setUp();
        bind();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSignedButInvalidOracleFieldsNeverConsumePending(uint8 rawField) public {
        deposit(10 ether + PRICE);
        bytes32 id = rewards.getEpoch(1).requestId;
        OracleAttestation.Attestation memory a = answer(1, leaf(alice, 10 ether));
        uint256 field = bound(rawField, 0, 11);
        if (field == 0) a.questionHash = bytes32(uint256(a.questionHash) ^ 1);
        else if (field == 1) a.chainId = 1;
        else if (field == 2) a.fromBlock--;
        else if (field == 3) a.toBlock++;
        else if (field == 4) a.panelSize = 29;
        else if (field == 5) a.quorum = 19;
        else if (field == 6) a.agreed = a.quorum - 1;
        else if (field == 7) a.agreed = a.panelSize + 1;
        else if (field == 8) a.quorum = a.panelSize + 1;
        else if (field == 9) a.issuedAt = uint64(rewards.getEpoch(1).createdAt - 1);
        else if (field == 10) a.expiresAt = a.issuedAt - 1;
        else a.answer = new bytes(31);
        bytes memory sig = signature(a);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.InvalidAnswer.selector);
        rewards.onOracleResult(id, a, sig);
        assertEq(rewards.pending(id), 1);
        assertFalse(rewards.consumed(a.requestId));
        assertFalse(rewards.getEpoch(1).ready);
        assertEq(rewards.totalReserved(), 10 ether);
        // A refused delivery must leave the real, valid answer usable.
        deliver(1, leaf(alice, 10 ether));
    }

    function testRetryFailurePreservesOriginalRequestAndSponsorFunds() public {
        deposit(10 ether + PRICE);
        HolderRewards.Epoch memory beforeEpoch = rewards.getEpoch(1);
        vm.warp(beforeEpoch.requestedAt + 1 days);
        imd.mint(alice, PRICE);
        vm.prank(alice);
        imd.approve(address(rewards), PRICE);
        intake.setReject(true);
        vm.prank(alice);
        vm.expectRevert(bytes("request rejected"));
        rewards.retryOracle(1);
        assertEq(rewards.pending(beforeEpoch.requestId), 1);
        assertEq(rewards.getEpoch(1).requestId, beforeEpoch.requestId);
        assertEq(rewards.getEpoch(1).requestedAt, beforeEpoch.requestedAt);
        assertEq(imd.balanceOf(alice), PRICE);
        assertEq(imd.balanceOf(address(rewards)), 10 ether);
        assertEq(imd.allowance(alice, address(rewards)), PRICE);
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
        intake.setReject(false);
        deliver(1, leaf(alice, 10 ether));
    }

    function testRetryUsesNewPriceButPreservesDepositBlockBudgetAndQuestion() public {
        deposit(10 ether + PRICE);
        HolderRewards.Epoch memory original = rewards.getEpoch(1);
        OracleAttestation.Attestation memory oldAnswer = answer(1, leaf(alice, 10 ether));
        bytes memory oldSignature = signature(oldAnswer);
        vm.warp(original.requestedAt + 1 days);
        vm.roll(vm.getBlockNumber() + 100_000);
        intake.setPrice(2 ether);
        imd.mint(bob, 2 ether);
        vm.prank(bob);
        imd.approve(address(rewards), 2 ether);
        vm.prank(bob);
        rewards.retryOracle(1);
        HolderRewards.Epoch memory retried = rewards.getEpoch(1);
        assertEq(retried.snapshotBlock, original.snapshotBlock);
        assertEq(retried.snapshotPot, original.snapshotPot);
        assertEq(retried.questionHash, original.questionHash);
        assertEq(retried.pot, original.pot);
        assertEq(intake.allowanceSeen(), 2 ether);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(imd.balanceOf(address(rewards)), 10 ether);
        assertTrue(retried.requestId != original.requestId);
        assertEq(rewards.pending(original.requestId), 1, "a retry never invalidates the paid-for request");
        assertEq(rewards.pending(retried.requestId), 1);
        // The earlier request's answer still settles the epoch: same question, same snapshot block.
        vm.prank(Network.INTAKE);
        rewards.onOracleResult(original.requestId, oldAnswer, oldSignature);
        assertTrue(rewards.getEpoch(1).ready);
        assertEq(rewards.getEpoch(1).root, leaf(alice, 10 ether));
        // The retried request's answer, though validly signed, cannot replace the installed root.
        OracleAttestation.Attestation memory late = answer(1, leaf(bob, 10 ether));
        bytes memory lateSignature = signature(late);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.AlreadyAnswered.selector);
        rewards.onOracleResult(retried.requestId, late, lateSignature);
        assertEq(rewards.getEpoch(1).root, leaf(alice, 10 ether));
        vm.expectRevert(HolderRewards.NotReady.selector);
        rewards.retryOracle(1);
    }

    function testAttestationUUIDCannotSettleTwoEpochsEvenWithTwoValidSignatures() public {
        deposit(10 ether + PRICE);
        deposit(20 ether + PRICE);
        OracleAttestation.Attestation memory first = answer(1, leaf(alice, 10 ether));
        bytes memory sig = signature(first);
        bytes32 id = rewards.getEpoch(1).requestId;
        vm.prank(Network.INTAKE);
        rewards.onOracleResult(id, first, sig);
        OracleAttestation.Attestation memory second = answer(2, leaf(bob, 20 ether));
        second.requestId = first.requestId;
        sig = signature(second);
        id = rewards.getEpoch(2).requestId;
        vm.prank(Network.INTAKE);
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, first.requestId)
        );
        rewards.onOracleResult(id, second, sig);
        assertEq(rewards.pending(id), 2);
        assertFalse(rewards.getEpoch(2).ready);
        deliver(2, leaf(bob, 20 ether));
    }

    function testClaimsRejectAbsentAndUnansweredEpochsWithoutMarkingClaimed() public {
        vm.expectRevert(HolderRewards.InvalidEpoch.selector);
        rewards.claim(0, 0, new bytes32[](0));
        vm.expectRevert(HolderRewards.InvalidEpoch.selector);
        rewards.claim(1, 0, new bytes32[](0));
        deposit(10 ether + PRICE);
        vm.prank(alice);
        vm.expectRevert(HolderRewards.NotReady.selector);
        rewards.claim(1, 0, new bytes32[](0));
        assertFalse(rewards.hasClaimed(1, alice));
        deliver(1, leaf(alice, 0));
        vm.prank(alice);
        rewards.claim(1, 0, new bytes32[](0));
        assertTrue(rewards.hasClaimed(1, alice));
        assertEq(rewards.totalReserved(), 10 ether);
    }

    function testDeferredEpochCanBeSponsoredWithoutTouchingOtherReserves() public {
        deposit(100 ether + PRICE);
        deposit(PRICE); // Exactly the oracle price: preserve the entire pot instead of buying an empty tree.
        deposit(0);
        assertEq(intake.paid(), PRICE);
        assertEq(rewards.getEpoch(2).requestId, bytes32(0));
        assertEq(rewards.getEpoch(3).pot, 0);
        imd.mint(alice, PRICE);
        vm.prank(alice);
        imd.approve(address(rewards), PRICE);
        vm.prank(alice);
        rewards.retryOracle(2);
        assertEq(rewards.getEpoch(1).pot, 100 ether);
        assertEq(rewards.getEpoch(2).pot, PRICE);
        assertEq(rewards.totalReserved(), 100 ether + PRICE);
        deliver(2, leaf(alice, PRICE));
        vm.prank(alice);
        rewards.claim(2, PRICE, new bytes32[](0));
        assertEq(imd.balanceOf(address(rewards)), 100 ether);
    }

    function testOutOfOrderRolloversAndCarryOnlyEpochsPreserveEveryUnclaimedWei() public {
        deposit(10 ether + PRICE);
        deposit(20 ether + PRICE);
        deposit(30 ether + PRICE);
        deliver(1, leaf(alice, 4 ether));
        vm.prank(alice);
        rewards.claim(1, 4 ether, new bytes32[](0));
        vm.warp(vm.getBlockTimestamp() + 28 days);
        rewards.rollover(3); // Opens an empty current epoch to hold the carry.
        rewards.rollover(1);
        rewards.rollover(2);
        assertEq(rewards.getEpoch(4).pot, 56 ether);
        assertEq(rewards.getEpoch(4).carry, 56 ether);
        assertEq(rewards.getEpoch(4).snapshotPot, 0);
        vm.warp(vm.getBlockTimestamp() + 28 days);
        rewards.rollover(4);
        assertEq(rewards.getEpoch(5).pot, 56 ether);
        vm.roll(vm.getBlockNumber() + 1);
        deposit(4 ether + PRICE);
        assertEq(rewards.getEpoch(5).pot, 0);
        assertEq(rewards.getEpoch(5).carry, 0);
        assertEq(rewards.getEpoch(6).snapshotPot, 60 ether);
        deliver(6, leaf(bob, 60 ether));
        vm.prank(bob);
        rewards.claim(6, 60 ether, new bytes32[](0));
        assertEq(imd.balanceOf(address(rewards)), 0);
        assertEq(rewards.totalReserved(), 0);
        for (uint256 id = 1; id <= 4; ++id) {
            assertTrue(rewards.getEpoch(id).closed);
            vm.expectRevert(HolderRewards.EpochClosed.selector);
            rewards.retryOracle(id);
        }
    }
}

contract AdversarialJobsTest is TestBase {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzDecimalsThresholdOneUnitBelowAndExactlyEnough(uint8 rawDecimals) public {
        uint8 decimals = uint8(bound(rawDecimals, 0, 71));
        JobsVault local = new JobsVault(address(this));
        MockToken localToken = new MockToken(decimals);
        local.setToken(address(localToken));
        uint256 threshold = 1_000_000 * 10 ** uint256(decimals);
        localToken.mint(alice, threshold - 1);
        imd.mint(address(local), PRICE);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientHolding.selector);
        local.requestJob("{}");
        localToken.mint(alice, 1);
        vm.prank(alice);
        local.requestJob("{}");
        assertEq(imd.balanceOf(address(local)), 0);
        assertEq(local.nextRequestAt(alice), vm.getBlockTimestamp() + 1 days);
    }

    function testHoldingIsRecheckedAfterCooldownAndFailureDoesNotExtendIt() public {
        bind();
        imd.mint(address(jobs), 5 ether);
        token.mint(alice, 1_000_000 ether);
        vm.prank(alice);
        jobs.requestJob("first");
        uint256 next = jobs.nextRequestAt(alice);
        vm.prank(alice);
        token.transfer(bob, 1);
        vm.warp(next);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientHolding.selector);
        jobs.requestJob("second");
        assertEq(jobs.nextRequestAt(alice), next);
        vm.prank(bob);
        token.transfer(alice, 1);
        intake.setPrice(1.5 ether);
        vm.prank(alice);
        jobs.requestJob("second");
        assertEq(intake.lastBody(), bytes("second"));
        assertEq(intake.allowanceSeen(), 1.5 ether);
        assertEq(imd.balanceOf(address(jobs)), 3 ether);
        assertEq(imd.balanceOf(alice), 0);
    }
}
