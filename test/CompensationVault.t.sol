// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestBase} from "./TestBase.sol";
import {CompensationVault} from "../src/CompensationVault.sol";
import {VaultChild} from "../src/VaultChild.sol";
import {Network} from "../src/Network.sol";

/// @dev The brief supplies a commitment, not its preimages. Synthetic preimages exercise the
/// exact production proof/payment path; tests separately assert the actual deployed commitment.
contract CompensationProofFixture is CompensationVault {
    constructor(address vault_) CompensationVault(vault_) {}

    function _merkleRoot() internal pure override returns (bytes32) {
        bytes32 a = keccak256(bytes.concat(keccak256(abi.encode(address(0xA11CE), TOTAL_WEIGHT / 3))));
        bytes32 b =
            keccak256(bytes.concat(keccak256(abi.encode(address(0xB0B), TOTAL_WEIGHT - TOTAL_WEIGHT / 3))));
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}

contract CompensationVaultTest is TestBase {
    function setUp() public override {
        super.setUp();
        bind();
    }

    function testFixedCommitmentAndNoMutationOrWithdrawEntrypoints() public {
        assertEq(
            compensation.MERKLE_ROOT(), 0xe84256f66c03a4565c29addd32238495f1a0d5dda8c618e5f81ff8637c296347
        );
        assertEq(compensation.TOTAL_WEIGHT(), 201084680772174552329559308);
        assertEq(compensation.WALLET_COUNT(), 62);
        (bool ok,) =
            address(compensation).call(abi.encodeWithSignature("setRoot(bytes32)", bytes32(uint256(1))));
        assertFalse(ok);
        (ok,) =
            address(compensation).call(abi.encodeWithSignature("withdraw(address,uint256)", Network.IMD, 1));
        assertFalse(ok);
        vm.expectRevert(VaultChild.OnlyVault.selector);
        compensation.setLaunch(address(token), key);
        vm.prank(address(vault));
        vm.expectRevert(VaultChild.AlreadyConfigured.selector);
        compensation.setLaunch(address(token), key);
    }

    function testThirtyMinuteBoundaryTenPercentAndTenMinuteSpacing() public {
        imd.mint(address(compensation), 1000 ether);
        vm.expectRevert(CompensationVault.TooEarly.selector);
        compensation.buyback();
        vm.warp(compensation.buybackAvailableAt() - 1);
        vm.expectRevert(CompensationVault.TooEarly.selector);
        compensation.buyback();
        vm.warp(compensation.buybackAvailableAt());
        compensation.buyback();
        assertEq(compensation.initialIMD(), 1000 ether);
        assertEq(compensation.trancheCap(), 100 ether);
        assertEq(compensation.totalSpent(), 100 ether);
        assertEq(token.balanceOf(address(compensation)), 200 ether);
        vm.expectRevert(CompensationVault.TooEarly.selector);
        compensation.buyback();
        vm.warp(compensation.nextBuybackAt() - 1);
        vm.expectRevert(CompensationVault.TooEarly.selector);
        compensation.buyback();
        for (uint256 i = 1; i < 10; ++i) {
            vm.warp(compensation.nextBuybackAt());
            compensation.buyback();
            assertEq(compensation.totalSpent(), (i + 1) * 100 ether);
        }
        assertTrue(compensation.buybackComplete());
        assertEq(imd.balanceOf(address(compensation)), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(CompensationVault.BuybackFinished.selector);
        compensation.buyback();
    }

    function testPartialOrRevertedSwapRollsBackBudgetAndCooldown() public {
        imd.mint(address(compensation), 1000 ether);
        vm.warp(compensation.buybackAvailableAt());
        manager.setPartial(true);
        vm.expectRevert(CompensationVault.InvalidSwap.selector);
        compensation.buyback();
        assertFalse(compensation.buybackStarted());
        assertEq(compensation.tranches(), 0);
        assertEq(imd.balanceOf(address(compensation)), 1000 ether);
        manager.setPartial(false);
        manager.setReject(true);
        vm.expectRevert();
        compensation.buyback();
        manager.setReject(false);
        compensation.buyback();
        assertEq(compensation.tranches(), 1);
    }

    function testUnlockCallbackAuthenticatedAndReentryCannotSpendTwice() public {
        vm.expectRevert(CompensationVault.UnexpectedCallback.selector);
        compensation.unlockCallback(abi.encode(1));
        vm.prank(Network.POOL_MANAGER);
        vm.expectRevert(CompensationVault.UnexpectedCallback.selector);
        compensation.unlockCallback(abi.encode(1));
        imd.mint(address(compensation), 1000 ether);
        vm.warp(compensation.buybackAvailableAt());
        imd.setReenter(address(compensation), abi.encodeCall(compensation.buyback, ()));
        compensation.buyback();
        assertFalse(imd.reenterSucceeded());
        assertEq(compensation.totalSpent(), 100 ether);
    }

    function testFrozenBudgetIgnoresDonationsAndLeavesOnlyOriginalRoundingDust() public {
        imd.mint(address(compensation), 1007);
        vm.warp(compensation.buybackAvailableAt());
        compensation.buyback();
        imd.mint(address(compensation), 500);
        for (uint256 i = 1; i < 10; ++i) {
            vm.warp(compensation.nextBuybackAt());
            compensation.buyback();
        }
        assertTrue(compensation.buybackComplete());
        assertEq(compensation.totalSpent(), 1000);
        assertEq(imd.balanceOf(address(compensation)), 507);
    }

    function testZeroOrSubTenWeiBudgetCompletesAfterWindowWithoutSwap() public {
        imd.mint(address(compensation), 9);
        vm.warp(compensation.buybackAvailableAt());
        compensation.buyback();
        assertTrue(compensation.buybackComplete());
        assertEq(compensation.tranches(), 0);
        assertEq(imd.balanceOf(address(compensation)), 9);
    }

    function testAirdropBlockedBeforeBuybackAndBadProductionProofSkips() public {
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) = batch();
        vm.expectRevert(CompensationVault.BuybackNotFinished.selector);
        compensation.airdrop(accounts, weights, proofs);
        vm.warp(compensation.buybackAvailableAt());
        compensation.buyback();
        token.mint(address(compensation), 100 ether);
        compensation.airdrop(accounts, weights, proofs);
        assertEq(token.balanceOf(address(0xA11CE)), 0);
        assertEq(token.balanceOf(address(0xB0B)), 0);
        assertEq(token.balanceOf(address(compensation)), 100 ether);
        assertFalse(compensation.paid(address(0xA11CE)));
    }

    function testAirdropPaysListedAccountsOnceProRataUsingFixedBalance() public {
        CompensationProofFixture c = fixture();
        token.mint(address(c), 1000 ether);
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) = batch();
        // First batch pays one real leaf and skips an unlisted one.
        accounts[1] = alice;
        c.airdrop(accounts, weights, proofs);
        uint256 first = 1000 ether * weights[0] / c.TOTAL_WEIGHT();
        assertEq(token.balanceOf(address(0xA11CE)), first);
        assertEq(token.balanceOf(alice), 0);
        assertEq(c.tokenBalanceAtAirdropStart(), 1000 ether);
        token.mint(address(c), 100 ether);
        accounts[1] = address(0xB0B);
        c.airdrop(accounts, weights, proofs);
        uint256 second = 1000 ether * weights[1] / c.TOTAL_WEIGHT();
        assertEq(token.balanceOf(address(0xA11CE)), first);
        assertEq(token.balanceOf(address(0xB0B)), second);
        c.airdrop(accounts, weights, proofs);
        assertEq(c.airdropped(), first + second);
        assertEq(token.balanceOf(address(c)), 1100 ether - first - second);
    }

    function testEmptyBalanceDoesNotConsumeEligibilityAndBadWeightsSkip() public {
        CompensationProofFixture c = fixture();
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) = batch();
        vm.expectRevert(CompensationVault.NoTokens.selector);
        c.airdrop(accounts, weights, proofs);
        assertFalse(c.paid(accounts[0]));
        token.mint(address(c), 100 ether);
        weights[0]++;
        proofs[1][0] = bytes32(0);
        c.airdrop(accounts, weights, proofs);
        assertEq(c.airdropped(), 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzTranchesNeverExceedTenPercent(uint96 rawBudget) public {
        uint256 budget = bound(rawBudget, 10, 1e27);
        imd.mint(address(compensation), budget);
        vm.warp(compensation.buybackAvailableAt());
        for (uint256 i; i < 10; ++i) {
            uint256 beforeIMD = imd.balanceOf(address(compensation));
            compensation.buyback();
            assertLe(beforeIMD - imd.balanceOf(address(compensation)), budget / 10);
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
        }
        assertEq(compensation.totalSpent(), 10 * (budget / 10));
        assertEq(imd.balanceOf(address(compensation)), budget % 10);
    }

    function fixture() private returns (CompensationProofFixture c) {
        c = new CompensationProofFixture(address(this));
        c.setLaunch(address(token), key);
        vm.warp(c.buybackAvailableAt());
        c.buyback();
    }

    function batch()
        private
        pure
        returns (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs)
    {
        accounts = new address[](2);
        weights = new uint256[](2);
        proofs = new bytes32[][](2);
        accounts[0] = address(0xA11CE);
        accounts[1] = address(0xB0B);
        weights[0] = uint256(201084680772174552329559308) / 3;
        weights[1] = 201084680772174552329559308 - weights[0];
        proofs[0] = proof(leaf(accounts[1], weights[1]));
        proofs[1] = proof(leaf(accounts[0], weights[0]));
    }
}
