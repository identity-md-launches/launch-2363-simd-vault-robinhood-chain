// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {CompensationProofFixture} from "./CompensationVault.t.sol";
import {CompensationVault} from "src/CompensationVault.sol";
import {Network} from "src/Network.sol";
import {MockToken} from "./mocks/Mocks.sol";

contract RecipientRejectingToken is MockToken {
    address public rejectedRecipient;

    constructor() MockToken(18) {}

    function setRejectedRecipient(address recipient) external {
        rejectedRecipient = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != rejectedRecipient, "recipient transfer rejected");
        return super.transfer(to, amount);
    }
}

contract CompensationFailuresTest is TestBase {
    uint256 private constant WEIGHT = 201084680772174552329559308;
    address private constant FIRST = address(0xA11CE);
    address private constant SECOND = address(0xB0B);

    function testMalformedBatchCannotFreezeAirdropBalance() public {
        CompensationProofFixture c = readyFixture(token);
        token.mint(address(c), 100 ether);
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) = validBatch();
        vm.expectRevert(CompensationVault.InvalidBatch.selector);
        c.airdrop(new address[](0), new uint256[](0), new bytes32[][](0));
        vm.expectRevert(CompensationVault.InvalidBatch.selector);
        c.airdrop(accounts, new uint256[](1), proofs);
        vm.expectRevert(CompensationVault.InvalidBatch.selector);
        c.airdrop(accounts, weights, new bytes32[][](1));
        assertFalse(c.airdropStarted());
        assertEq(c.tokenBalanceAtAirdropStart(), 0);
        token.mint(address(c), 100 ether);
        c.airdrop(accounts, weights, proofs);
        assertEq(c.tokenBalanceAtAirdropStart(), 200 ether);
    }

    function testSecondRecipientRejectionRevertsFirstPaymentAndAllFlags() public {
        RecipientRejectingToken localToken = new RecipientRejectingToken();
        CompensationProofFixture c = readyFixture(localToken);
        localToken.mint(address(c), 1000 ether);
        localToken.setRejectedRecipient(SECOND);
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) = validBatch();
        vm.expectRevert(bytes("recipient transfer rejected"));
        c.airdrop(accounts, weights, proofs);
        assertEq(localToken.balanceOf(FIRST), 0);
        assertEq(localToken.balanceOf(SECOND), 0);
        assertEq(localToken.balanceOf(address(c)), 1000 ether);
        assertFalse(c.paid(FIRST));
        assertFalse(c.paid(SECOND));
        assertFalse(c.airdropStarted());
        assertEq(c.airdropped(), 0);
        localToken.setRejectedRecipient(address(0));
        c.airdrop(accounts, weights, proofs);
        assertEq(localToken.balanceOf(FIRST), 1000 ether * weights[0] / WEIGHT);
        assertEq(localToken.balanceOf(SECOND), 1000 ether * weights[1] / WEIGHT);
    }

    function testAirdropTransferReentryCannotPayAnotherBatch() public {
        CompensationProofFixture c = readyFixture(token);
        token.mint(address(c), 1000 ether);
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) = validBatch();
        token.setReenter(address(c), abi.encodeCall(c.airdrop, (accounts, weights, proofs)));
        c.airdrop(accounts, weights, proofs);
        assertFalse(token.reenterSucceeded());
        assertEq(token.balanceOf(FIRST), 1000 ether * weights[0] / WEIGHT);
        assertEq(token.balanceOf(SECOND), 1000 ether * weights[1] / WEIGHT);
        assertEq(c.airdropped(), token.balanceOf(FIRST) + token.balanceOf(SECOND));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzDuplicateEntriesAndRepeatedBatchesNeverOverpay(uint96 rawBalance, bool reverse) public {
        uint256 balance = bound(rawBalance, 1, 1e28);
        CompensationProofFixture c = readyFixture(token);
        token.mint(address(c), balance);
        (
            address[] memory originalAccounts,
            uint256[] memory originalWeights,
            bytes32[][] memory originalProofs
        ) = validBatch();
        address[] memory accounts = new address[](4);
        uint256[] memory weights = new uint256[](4);
        bytes32[][] memory proofs = new bytes32[][](4);
        for (uint256 i; i < 4; ++i) {
            uint256 source = reverse ? 1 - i % 2 : i % 2;
            accounts[i] = originalAccounts[source];
            weights[i] = originalWeights[source];
            proofs[i] = originalProofs[source];
        }
        vm.prank(bob);
        c.airdrop(accounts, weights, proofs);
        c.airdrop(accounts, weights, proofs);
        uint256 first = balance * originalWeights[0] / WEIGHT;
        uint256 second = balance * originalWeights[1] / WEIGHT;
        assertEq(token.balanceOf(FIRST), first);
        assertEq(token.balanceOf(SECOND), second);
        assertEq(token.balanceOf(bob), 0);
        assertEq(c.airdropped(), first + second);
        assertEq(token.balanceOf(address(c)), balance - first - second);
        assertLe(balance - first - second, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzProductionRootRejectsUnprovenClaims(address account, uint128 weight) public {
        bind();
        vm.warp(compensation.buybackAvailableAt());
        compensation.buyback();
        token.mint(address(compensation), 100 ether);
        address[] memory accounts = new address[](1);
        uint256[] memory weights = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        accounts[0] = account;
        weights[0] = bound(weight, 1, WEIGHT); // Reach proof verification, not the invalid-weight shortcut.
        proofs[0] = new bytes32[](0);
        uint256 beforeBalance = token.balanceOf(account);
        compensation.airdrop(accounts, weights, proofs);
        assertFalse(compensation.paid(account));
        assertEq(compensation.airdropped(), 0);
        assertEq(token.balanceOf(account), beforeBalance);
        assertEq(token.balanceOf(address(compensation)), 100 ether);
    }

    function testOutputTransferRejectionDoesNotConsumeFirstBuyback() public {
        bind();
        imd.mint(address(compensation), 1000 ether);
        vm.warp(compensation.buybackAvailableAt());
        token.setReject(true);
        vm.expectRevert(bytes("transfer rejected"));
        compensation.buyback();
        assertFalse(compensation.buybackStarted());
        assertEq(compensation.initialIMD(), 0);
        assertEq(compensation.tranches(), 0);
        assertEq(compensation.nextBuybackAt(), 0);
        assertEq(compensation.totalSpent(), 0);
        assertEq(imd.balanceOf(address(compensation)), 1000 ether);
        assertEq(imd.balanceOf(Network.POOL_MANAGER), 0);
        token.setReject(false);
        compensation.buyback();
        assertEq(compensation.totalSpent(), 100 ether);
    }

    function testLaterTrancheRejectionRetainsOriginalBudgetAndCanRetryImmediately() public {
        bind();
        imd.mint(address(compensation), 1000 ether);
        vm.warp(compensation.buybackAvailableAt());
        compensation.buyback();
        uint256 next = compensation.nextBuybackAt();
        vm.warp(next);
        imd.setReject(true);
        vm.expectRevert(bytes("transfer rejected"));
        compensation.buyback();
        assertEq(compensation.initialIMD(), 1000 ether);
        assertEq(compensation.tranches(), 1);
        assertEq(compensation.nextBuybackAt(), next);
        assertEq(compensation.totalSpent(), 100 ether);
        assertEq(token.balanceOf(address(compensation)), 200 ether);
        assertEq(imd.balanceOf(address(compensation)), 900 ether);
        imd.setReject(false);
        compensation.buyback();
        assertEq(compensation.tranches(), 2);
        assertEq(compensation.totalSpent(), 200 ether);
    }

    function testUnrepresentableV4DeltaRevertsBeforeAnyAssetMoves() public {
        bind();
        uint256 amount = (uint256(uint128(type(int128).max)) + 1) * 10;
        imd.mint(address(compensation), amount);
        vm.warp(compensation.buybackAvailableAt());
        vm.expectRevert(CompensationVault.InvalidSwap.selector);
        compensation.buyback();
        assertFalse(compensation.buybackStarted());
        assertEq(compensation.initialIMD(), 0);
        assertEq(imd.balanceOf(address(compensation)), amount);
        assertEq(imd.balanceOf(Network.POOL_MANAGER), 0);
    }

    function readyFixture(MockToken t) private returns (CompensationProofFixture c) {
        c = new CompensationProofFixture(address(this));
        c.setLaunch(address(t), poolFor(address(t)));
        vm.warp(c.buybackAvailableAt());
        c.buyback();
    }

    function validBatch()
        private
        pure
        returns (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs)
    {
        accounts = new address[](2);
        weights = new uint256[](2);
        proofs = new bytes32[][](2);
        accounts[0] = FIRST;
        accounts[1] = SECOND;
        weights[0] = WEIGHT / 3;
        weights[1] = WEIGHT - weights[0];
        proofs[0] = proof(leaf(SECOND, weights[1]));
        proofs[1] = proof(leaf(FIRST, weights[0]));
    }
}
