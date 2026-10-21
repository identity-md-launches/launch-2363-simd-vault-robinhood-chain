// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {MigrationClaims} from "./fixtures/MigrationClaims.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @dev These are real historical leaves and proofs, not an overridden root or storage injection.
contract MigrationClaimsTest is TestBase {
    bytes32 private constant ROOT = 0xe84256f66c03a4565c29addd32238495f1a0d5dda8c618e5f81ff8637c296347;
    uint256 private constant WEIGHT = 201084680772174552329559308;

    function setUp() public override {
        super.setUp();
        bind();
    }

    function testAll62HistoricalProofsReproduceTheProductionCommitment() public view {
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) =
            MigrationClaims.all();
        assertEq(accounts.length, 62);
        assertEq(accounts.length, compensation.WALLET_COUNT());
        assertEq(compensation.MERKLE_ROOT(), ROOT);
        uint256 total;
        for (uint256 i; i < accounts.length; ++i) {
            assertGt(weights[i], 0);
            if (i > 0) {
                assertGt(uint160(accounts[i]), uint160(accounts[i - 1]), "duplicate/unsorted beneficiary");
            }
            assertTrue(
                MerkleProof.verify(proofs[i], ROOT, leaf(accounts[i], weights[i])),
                "historical proof is invalid"
            );
            total += weights[i];
        }
        assertEq(total, WEIGHT);
        assertEq(compensation.TOTAL_WEIGHT(), total);
    }

    function testAllRealBeneficiariesPaidAfterTenTranchesAcrossBatches() public {
        token.mint(address(compensation), 500 ether);
        imd.mint(address(compensation), 1000 ether);
        vm.warp(compensation.buybackAvailableAt());
        for (uint256 i; i < 10; ++i) {
            compensation.buyback();
            if (i != 9) vm.warp(compensation.nextBuybackAt());
        }
        assertTrue(compensation.buybackComplete());
        assertEq(imd.balanceOf(address(compensation)), 0);
        assertEq(compensation.totalSpent(), 1000 ether);
        uint256 allocation = token.balanceOf(address(compensation));
        assertEq(allocation, 2500 ether);
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) =
            MigrationClaims.all();
        _paySlice(accounts, weights, proofs, 0, 31);
        assertEq(compensation.tokenBalanceAtAirdropStart(), allocation);
        token.mint(address(compensation), 99 ether);
        _paySlice(accounts, weights, proofs, 31, 62);
        // An unlisted relayer receives nothing; retrying every real leaf cannot pay twice.
        vm.prank(bob);
        compensation.airdrop(accounts, weights, proofs);
        uint256 totalPaid = _assertPayments(accounts, weights, allocation);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(compensation)), allocation + 99 ether - totalPaid);
        assertLt(allocation - totalPaid, 62);
    }

    function testCorruptedRealProofsSkipWithoutConsumingEligibility() public {
        vm.warp(compensation.buybackAvailableAt());
        compensation.buyback();
        token.mint(address(compensation), 100 ether);
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) =
            MigrationClaims.all();
        address first = accounts[0];
        address second = accounts[1];
        address third = accounts[2];
        weights[0]++;
        proofs[1][0] = bytes32(uint256(proofs[1][0]) ^ 1);
        accounts[2] = alice;
        compensation.airdrop(accounts, weights, proofs);
        assertFalse(compensation.paid(first));
        assertFalse(compensation.paid(second));
        assertFalse(compensation.paid(third));
        assertFalse(compensation.paid(alice));
        assertEq(token.balanceOf(first) + token.balanceOf(second) + token.balanceOf(third), 0);
        (accounts, weights, proofs) = MigrationClaims.all();
        compensation.airdrop(accounts, weights, proofs);
        _assertPayments(accounts, weights, 100 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzAll62PayoutsConserveSupplyRegardlessOfOrder(uint96 rawAllocation, uint8 rotation)
        public
    {
        uint256 allocation = bound(rawAllocation, 1, 1e28);
        vm.warp(compensation.buybackAvailableAt());
        compensation.buyback();
        token.mint(address(compensation), allocation);
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) =
            MigrationClaims.all();
        address[] memory orderedAccounts = new address[](62);
        uint256[] memory orderedWeights = new uint256[](62);
        bytes32[][] memory orderedProofs = new bytes32[][](62);
        for (uint256 i; i < 62; ++i) {
            uint256 index = (i + uint256(rotation)) % 62;
            orderedAccounts[i] = accounts[index];
            orderedWeights[i] = weights[index];
            orderedProofs[i] = proofs[index];
        }
        compensation.airdrop(orderedAccounts, orderedWeights, orderedProofs);
        compensation.airdrop(accounts, weights, proofs);
        uint256 totalPaid = _assertPayments(accounts, weights, allocation);
        assertEq(token.balanceOf(address(compensation)), allocation - totalPaid);
        assertLt(allocation - totalPaid, 62);
    }

    function _assertPayments(address[] memory accounts, uint256[] memory weights, uint256 allocation)
        private
        view
        returns (uint256 totalPaid)
    {
        for (uint256 i; i < accounts.length; ++i) {
            uint256 expected = allocation * weights[i] / WEIGHT;
            assertTrue(compensation.paid(accounts[i]));
            assertEq(token.balanceOf(accounts[i]), expected);
            totalPaid += expected;
        }
        assertEq(compensation.airdropped(), totalPaid);
        assertEq(compensation.tokenBalanceAtAirdropStart(), allocation);
    }

    function _paySlice(
        address[] memory accounts,
        uint256[] memory weights,
        bytes32[][] memory proofs,
        uint256 from,
        uint256 to
    ) private {
        address[] memory batchAccounts = new address[](to - from);
        uint256[] memory batchWeights = new uint256[](to - from);
        bytes32[][] memory batchProofs = new bytes32[][](to - from);
        for (uint256 i = from; i < to; ++i) {
            batchAccounts[i - from] = accounts[i];
            batchWeights[i - from] = weights[i];
            batchProofs[i - from] = proofs[i];
        }
        compensation.airdrop(batchAccounts, batchWeights, batchProofs);
    }
}
