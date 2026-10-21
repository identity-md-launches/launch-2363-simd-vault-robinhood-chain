// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestBase} from "./TestBase.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {VaultChild} from "../src/VaultChild.sol";
import {Network} from "../src/Network.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {OracleQuestion} from "../src/oracle/OracleQuestion.sol";

contract HolderRewardsTest is TestBase {
    function setUp() public override {
        super.setUp();
        bind();
    }

    function testDepositRequestsCanonicalBodyAtActualArbitrumDepositBlock() public {
        vm.roll(32_123_456);
        deposit(100 ether);
        HolderRewards.Epoch memory e = rewards.getEpoch(1);
        assertEq(e.snapshotBlock, 32_123_456);
        assertEq(e.pot, 100 ether - PRICE);
        assertEq(e.snapshotPot, e.pot);
        assertEq(e.questionHash, OracleQuestion.hash(rewards.question(1)));
        assertEq(intake.lastPayer(), address(rewards));
        assertEq(intake.lastAction(), Network.ORACLE_ACTION);
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
        (address target, bytes4 selector) = intake.lastCallback();
        assertEq(target, address(rewards));
        assertEq(selector, rewards.onOracleResult.selector);
        string memory body = string(intake.lastBody());
        assertEq(vm.parseJsonUint(body, ".window.fromBlock"), 32_123_456);
        assertEq(vm.parseJsonUint(body, ".window.toBlock"), 32_123_456);
        assertEq(vm.parseJsonUint(body, ".chainId"), 4663);
        assertEq(vm.parseJsonString(body, ".answerType"), "bytes32");
        assertLt(bytes(body).length, 16385);
        OracleQuestion.Question memory q = rewards.question(1);
        for (uint256 i; i < q.definitions.length; ++i) {
            assertLe(bytes(q.definitions[i].value).length, 512);
        }
    }

    function testOnlyVaultCanSetTokenOrCreateEpochsOrSpendFromSelfCall() public {
        vm.expectRevert(VaultChild.OnlyVault.selector);
        rewards.onDeposit(1);
        vm.expectRevert(VaultChild.OnlyVault.selector);
        rewards.setToken(address(token));
        vm.prank(address(vault));
        vm.expectRevert(VaultChild.AlreadyConfigured.selector);
        rewards.setToken(address(token));
        vm.expectRevert(HolderRewards.OnlySelf.selector);
        rewards.requestDepositedEpoch(1, 1);
        vm.prank(address(vault));
        vm.expectRevert(HolderRewards.InsufficientDeposit.selector);
        rewards.onDeposit(1);
    }

    function testSnapshotEntitlementIndependentOfCurrentBalanceAndDoubleClaimFails() public {
        token.mint(alice, 100 ether);
        deposit(100 ether + PRICE);
        uint256 aliceAmount = 60 ether;
        uint256 bobAmount = 40 ether;
        deliver(1, pair(leaf(alice, aliceAmount), leaf(bob, bobAmount)));
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        vm.prank(alice);
        rewards.claim(1, aliceAmount, proof(leaf(bob, bobAmount)));
        assertEq(imd.balanceOf(alice), aliceAmount);
        vm.prank(alice);
        vm.expectRevert(HolderRewards.AlreadyClaimed.selector);
        rewards.claim(1, aliceAmount, proof(leaf(bob, bobAmount)));
        vm.prank(bob);
        rewards.claim(1, bobAmount, proof(leaf(alice, aliceAmount)));
        assertEq(rewards.getEpoch(1).claimed, 100 ether);
        assertEq(imd.balanceOf(address(rewards)), 0);
    }

    function testOversizedSignedTreeCannotDrainAnotherEpoch() public {
        deposit(10 ether + PRICE);
        deposit(100 ether + PRICE);
        deliver(1, leaf(alice, 11 ether));
        vm.prank(alice);
        vm.expectRevert(HolderRewards.PotExceeded.selector);
        rewards.claim(1, 11 ether, new bytes32[](0));
        assertEq(rewards.getEpoch(1).claimed, 0);
        assertEq(imd.balanceOf(address(rewards)), 110 ether);
    }

    function testAggregateClaimsCannotExceedPot() public {
        deposit(10 ether + PRICE);
        deliver(1, pair(leaf(alice, 7 ether), leaf(bob, 7 ether)));
        vm.prank(alice);
        rewards.claim(1, 7 ether, proof(leaf(bob, 7 ether)));
        vm.prank(bob);
        vm.expectRevert(HolderRewards.PotExceeded.selector);
        rewards.claim(1, 7 ether, proof(leaf(alice, 7 ether)));
        assertEq(rewards.getEpoch(1).claimed, 7 ether);
    }

    function testWrongLeafAndProofCannotClaim() public {
        deposit(10 ether + PRICE);
        deliver(1, leaf(alice, 10 ether));
        vm.prank(bob);
        vm.expectRevert(HolderRewards.BadProof.selector);
        rewards.claim(1, 10 ether, new bytes32[](0));
        vm.prank(alice);
        vm.expectRevert(HolderRewards.BadProof.selector);
        rewards.claim(1, 9 ether, new bytes32[](0));
        assertEq(rewards.getEpoch(1).claimed, 0);
    }

    function testClaimsRemainAvailableUntilRolloverAndTransferFailureIsAtomic() public {
        deposit(10 ether + PRICE);
        deliver(1, leaf(alice, 10 ether));
        vm.warp(vm.getBlockTimestamp() + 29 days);
        imd.setReject(true);
        vm.prank(alice);
        vm.expectRevert();
        rewards.claim(1, 10 ether, new bytes32[](0));
        assertFalse(rewards.hasClaimed(1, alice));
        assertEq(rewards.getEpoch(1).claimed, 0);
        assertEq(rewards.totalReserved(), 10 ether);
        imd.setReject(false);
        vm.prank(alice);
        rewards.claim(1, 10 ether, new bytes32[](0));
        rewards.rollover(1);
        assertEq(rewards.getEpoch(2).pot, 0);
        assertEq(rewards.totalReserved(), 0);
    }

    function testOnlyIntakeUnknownIdAndReplayRejected() public {
        deposit(10 ether + PRICE);
        OracleAttestation.Attestation memory a = answer(1, leaf(alice, 10 ether));
        bytes memory sig = signature(a);
        bytes32 id = rewards.getEpoch(1).requestId;
        vm.expectRevert(HolderRewards.OnlyIntake.selector);
        rewards.onOracleResult(id, a, sig);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.UnknownRequest.selector);
        rewards.onOracleResult(bytes32(uint256(123)), a, sig);
        vm.prank(Network.INTAKE);
        rewards.onOracleResult(id, a, sig);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.UnknownRequest.selector);
        rewards.onOracleResult(id, a, sig);
    }

    function testAnotherEpochAnswerCannotBePairedWithRequest() public {
        deposit(10 ether + PRICE);
        vm.roll(vm.getBlockNumber() + 20);
        deposit(20 ether + PRICE);
        OracleAttestation.Attestation memory a = answer(1, leaf(alice, 10 ether));
        bytes memory sig = signature(a);
        bytes32 requestId = rewards.getEpoch(2).requestId;
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.InvalidAnswer.selector);
        rewards.onOracleResult(requestId, a, sig);
    }

    function testWrongChainBlockTypeAndWeakPanelRejected() public {
        deposit(10 ether + PRICE);
        OracleAttestation.Attestation memory a = answer(1, leaf(alice, 10 ether));
        a.chainId = 1;
        _reject(a, HolderRewards.InvalidAnswer.selector);
        a.chainId = 4663;
        a.toBlock++;
        _reject(a, HolderRewards.InvalidAnswer.selector);
        a.toBlock--;
        a.panelSize = 29;
        _reject(a, HolderRewards.InvalidAnswer.selector);
        a.panelSize = 30;
        a.agreed = 19;
        _reject(a, HolderRewards.InvalidAnswer.selector);
        a.agreed = 25;
        a.answerType = 3;
        _reject(a, OracleAttestationConsumer.WrongAnswerType.selector);
    }

    function testExpiredFutureAndTamperedAttestationsRejected() public {
        deposit(10 ether + PRICE);
        OracleAttestation.Attestation memory a = answer(1, leaf(alice, 10 ether));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        _reject(a, OracleAttestationConsumer.AttestationExpired.selector);
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 301);
        _reject(a, OracleAttestationConsumer.AttestationNotYetValid.selector);
        a.issuedAt = uint64(vm.getBlockTimestamp());
        bytes memory sig = signature(a);
        a.answer = abi.encode(bytes32(uint256(99)));
        bytes32 requestId = rewards.getEpoch(1).requestId;
        vm.prank(Network.INTAKE);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        rewards.onOracleResult(requestId, a, sig);
    }

    function testRolloverMovesExactlyUnclaimedAndNextDepositSnapshotsCarry() public {
        deposit(100 ether + PRICE);
        deliver(1, leaf(alice, 30 ether));
        vm.prank(alice);
        rewards.claim(1, 30 ether, new bytes32[](0));
        uint256 firstAt = rewards.getEpoch(1).createdAt;
        vm.warp(firstAt + 21 days);
        vm.roll(vm.getBlockNumber() + 100);
        deposit(20 ether + PRICE);
        deliver(2, leaf(bob, 20 ether));
        vm.warp(firstAt + 28 days - 1);
        vm.expectRevert(HolderRewards.TooEarly.selector);
        rewards.rollover(1);
        vm.warp(firstAt + 28 days);
        rewards.rollover(1);
        assertTrue(rewards.getEpoch(1).closed);
        assertEq(rewards.getEpoch(2).pot, 90 ether);
        assertEq(rewards.getEpoch(2).carry, 70 ether);
        assertEq(rewards.totalReserved(), 90 ether);
        vm.prank(bob);
        rewards.claim(2, 20 ether, new bytes32[](0));
        vm.roll(vm.getBlockNumber() + 1);
        deposit(10 ether + PRICE);
        assertEq(rewards.getEpoch(2).pot, 20 ether);
        assertEq(rewards.getEpoch(2).carry, 0);
        assertEq(rewards.getEpoch(3).pot, 80 ether);
        assertEq(rewards.getEpoch(3).snapshotPot, 80 ether);
        assertEq(rewards.totalReserved(), 80 ether);
        deliver(3, leaf(alice, 80 ether));
        vm.prank(alice);
        rewards.claim(3, 80 ether, new bytes32[](0));
        assertEq(imd.balanceOf(address(rewards)), 0);
        vm.expectRevert(HolderRewards.EpochClosed.selector);
        rewards.rollover(1);
    }

    function testRolloverCarryCannotBeSpentByAnOversizedCurrentTree() public {
        deposit(100 ether + PRICE);
        uint256 created = vm.getBlockTimestamp();
        vm.warp(created + 21 days);
        deposit(20 ether + PRICE);
        deliver(2, leaf(alice, 21 ether));
        vm.warp(created + 28 days);
        rewards.rollover(1);
        vm.prank(alice);
        vm.expectRevert(HolderRewards.PotExceeded.selector);
        rewards.claim(2, 21 ether, new bytes32[](0));
        assertEq(rewards.totalReserved(), 120 ether);
    }

    function testUnansweredLatestEpochCanRollAndLateCallbackCannotReviveIt() public {
        deposit(100 ether + PRICE);
        OracleAttestation.Attestation memory a = answer(1, leaf(alice, 100 ether));
        bytes memory sig = signature(a);
        bytes32 requestId = rewards.getEpoch(1).requestId;
        vm.warp(vm.getBlockTimestamp() + 28 days);
        rewards.rollover(1);
        assertEq(rewards.currentEpoch(), 2);
        assertEq(rewards.getEpoch(2).pot, 100 ether);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.UnknownRequest.selector);
        rewards.onOracleResult(requestId, a, sig);
        vm.prank(alice);
        vm.expectRevert(HolderRewards.EpochClosed.selector);
        rewards.claim(1, 100 ether, new bytes32[](0));
    }

    function testEmptyRootCanRollOver() public {
        deposit(100 ether + PRICE);
        deliver(1, bytes32(0));
        assertTrue(rewards.getEpoch(1).ready);
        vm.warp(vm.getBlockTimestamp() + 28 days);
        rewards.rollover(1);
        assertEq(rewards.getEpoch(2).pot, 100 ether);
    }

    function testSmallDepositNeverSpendsPreviousEpochReserve() public {
        deposit(100 ether + PRICE);
        deposit(PRICE - 1);
        assertEq(rewards.getEpoch(1).pot, 100 ether);
        assertEq(rewards.getEpoch(2).pot, PRICE - 1);
        assertEq(rewards.getEpoch(2).requestId, bytes32(0));
        assertEq(imd.balanceOf(address(rewards)), 100 ether + PRICE - 1);
        assertEq(intake.paid(), PRICE);
    }

    function testRetrySponsorPaysAndOldIdBecomesInvalid() public {
        deposit(100 ether + PRICE);
        bytes32 old = rewards.getEpoch(1).requestId;
        imd.mint(alice, PRICE);
        vm.prank(alice);
        imd.approve(address(rewards), PRICE);
        vm.prank(alice);
        vm.expectRevert(HolderRewards.TooEarly.selector);
        rewards.retryOracle(1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        rewards.retryOracle(1);
        assertEq(rewards.pending(old), 0);
        assertEq(rewards.getEpoch(1).pot, 100 ether);
        assertEq(imd.balanceOf(address(rewards)), 100 ether);
        assertEq(imd.balanceOf(alice), 0);
        deliver(1, leaf(alice, 100 ether));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzClaimsAndRolloverConserveFunds(uint128 rawPot, uint128 rawClaim) public {
        uint256 pot = bound(rawPot, 1, 1e32);
        uint256 claimed = bound(rawClaim, 0, pot);
        deposit(pot + PRICE);
        deliver(1, leaf(alice, claimed));
        vm.prank(alice);
        rewards.claim(1, claimed, new bytes32[](0));
        vm.warp(vm.getBlockTimestamp() + 28 days);
        rewards.rollover(1);
        assertEq(rewards.getEpoch(2).pot, pot - claimed);
        assertEq(rewards.totalReserved(), pot - claimed);
        assertEq(imd.balanceOf(address(rewards)), pot - claimed);
        assertEq(imd.balanceOf(alice) + rewards.totalReserved(), pot);
    }

    function _reject(OracleAttestation.Attestation memory a, bytes4 error_) private {
        bytes memory sig = signature(a);
        bytes32 requestId = rewards.getEpoch(1).requestId;
        vm.prank(Network.INTAKE);
        vm.expectPartialRevert(error_);
        rewards.onOracleResult(requestId, a, sig);
    }
}
