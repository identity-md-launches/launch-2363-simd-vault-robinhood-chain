// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestBase} from "./TestBase.sol";
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {CompensationVault} from "../src/CompensationVault.sol";
import {Network} from "../src/Network.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {MockToken, MockFactory} from "./mocks/Mocks.sol";

contract VaultHandler is Test {
    SIMDVault public immutable vault;
    HolderRewards public immutable rewards;
    CompensationVault public immutable compensation;
    MockToken public immutable imd = MockToken(Network.IMD);
    MockToken public immutable token;
    uint256 public immutable marketingNativeBefore;
    uint256 public nativeFunded;
    uint256 public successfulClaims;

    constructor(SIMDVault vault_) {
        vault = vault_;
        rewards = vault_.holderRewards();
        compensation = vault_.compensationVault();
        token = MockToken(vault_.token());
        marketingNativeBefore = Network.MARKETING.balance;
    }

    function receiveFees(uint96 rawIMD, uint96 rawTokens, uint96 rawNative, bool fromFactory) external {
        address recipient = fromFactory ? Network.FACTORY : address(vault);
        imd.mint(recipient, bound(rawIMD, 0, 1e25));
        token.mint(recipient, bound(rawTokens, 0, 1e25));
        uint256 nativeAmount = bound(rawNative, 0, 10 ether);
        nativeFunded += nativeAmount;
        vm.deal(recipient, recipient.balance + nativeAmount);
    }

    function attemptDistribution() external {
        uint256 next = vault.nextDistributionAt();
        if (vm.getBlockTimestamp() < next) {
            vm.expectRevert(SIMDVault.TooEarly.selector);
            vault.distribute();
            assertEq(vault.nextDistributionAt(), next);
        } else {
            vault.distribute();
            assertEq(vault.nextDistributionAt(), vm.getBlockTimestamp() + 7 days);
            assertEq(token.balanceOf(address(vault)), 0);
            assertEq(address(vault).balance, 0);
        }
    }

    function distribute(uint128 amount, bool rejectClaim) external {
        imd.mint(address(vault), bound(amount, 0, 1e25));
        uint256 next = vault.nextDistributionAt();
        if (vm.getBlockTimestamp() < next) vm.warp(next);
        vm.roll(vm.getBlockNumber() + 10);
        MockFactory(payable(Network.FACTORY)).setReject(rejectClaim);
        vault.distribute();
    }

    function advance(uint32 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 8 days));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function rollover(uint64 rawId) external {
        uint256 count = rewards.currentEpoch();
        if (count == 0) return;
        uint256 id = bound(rawId, 1, count);
        HolderRewards.Epoch memory e = rewards.getEpoch(id);
        if (e.closed || vm.getBlockTimestamp() < e.createdAt + 28 days) return;
        rewards.rollover(id);
    }

    function settleAndClaim(uint64 rawId, uint128 rawAmount) external {
        uint256 count = rewards.currentEpoch();
        if (count == 0) return;
        uint256 id = bound(rawId, 1, count);
        HolderRewards.Epoch memory e = rewards.getEpoch(id);
        if (
            e.closed || e.ready || rewards.pending(e.requestId) == 0
                || vm.getBlockTimestamp() >= e.createdAt + 28 days
        ) return;
        uint256 amount = bound(rawAmount, 0, e.snapshotPot);
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode(id, e.requestId));
        a.chainId = 4663;
        a.questionHash = e.questionHash;
        a.answerType = 2;
        a.answer = abi.encode(keccak256(bytes.concat(keccak256(abi.encode(address(this), amount)))));
        a.fromBlock = uint64(e.snapshotBlock);
        a.toBlock = uint64(e.snapshotBlock);
        a.panelSize = 30;
        a.quorum = 20;
        a.agreed = 25;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xa11ce, rewards.attestationDigest(a));
        vm.prank(Network.INTAKE);
        rewards.onOracleResult(e.requestId, a, abi.encodePacked(r, s, v));
        rewards.claim(id, amount, new bytes32[](0));
        ++successfulClaims;
    }

    function buyback(uint96 amount) external {
        if (compensation.buybackComplete()) return;
        if (!compensation.buybackStarted()) imd.mint(address(compensation), bound(amount, 0, 1e25));
        uint256 next = compensation.buybackAvailableAt();
        if (compensation.nextBuybackAt() > next) next = compensation.nextBuybackAt();
        if (vm.getBlockTimestamp() < next) vm.warp(next);
        compensation.buyback();
    }

    function requestJob() external {
        try vault.jobsVault().requestJob("{}") {} catch {}
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract VaultInvariantsTest is TestBase {
    VaultHandler private handler;

    function setUp() public override {
        super.setUp();
        bind();
        handler = new VaultHandler(vault);
        token.mint(address(handler), 1_000_000 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.distribute.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.rollover.selector;
        selectors[3] = handler.settleAndClaim.selector;
        selectors[4] = handler.buyback.selector;
        selectors[5] = handler.requestJob.selector;
        selectors[6] = handler.receiveFees.selector;
        selectors[7] = handler.attemptDistribution.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantEpochAccountingIsFullyBacked() public view {
        uint256 reserve;
        for (uint256 id = 1; id <= rewards.currentEpoch(); ++id) {
            HolderRewards.Epoch memory e = rewards.getEpoch(id);
            assertLe(e.claimed, e.snapshotPot);
            assertLe(e.claimed, e.pot);
            if (!e.closed) {
                reserve += e.pot - e.claimed;
                assertEq(e.pot, e.snapshotPot + e.carry);
                assertLe(e.carry, e.pot - e.claimed);
            }
            if (e.closed || e.ready) assertEq(rewards.pending(e.requestId), 0);
        }
        assertEq(reserve, rewards.totalReserved());
        assertEq(imd.balanceOf(address(rewards)), reserve);
    }

    function invariantBuybackNeverExceedsFrozenBudgetOrTenTranches() public view {
        assertLe(compensation.tranches(), 10);
        assertLe(compensation.totalSpent(), compensation.initialIMD());
        assertEq(compensation.totalSpent(), compensation.tranches() * compensation.trancheCap());
    }

    function invariantAllIMDRemainsAtAuthorizedDestinations() public view {
        uint256 accounted = imd.balanceOf(address(vault)) + imd.balanceOf(address(rewards))
            + imd.balanceOf(address(jobs)) + imd.balanceOf(address(compensation)) + imd.balanceOf(Network.DEV)
            + imd.balanceOf(Network.INTAKE) + imd.balanceOf(Network.POOL_MANAGER)
            + imd.balanceOf(address(handler)) + imd.balanceOf(Network.FACTORY);
        assertEq(accounted, imd.totalSupply());
    }

    function invariantNativeAndLaunchTokensRemainAtAuthorizedDestinations() public view {
        assertEq(
            address(vault).balance + Network.FACTORY.balance
                + (Network.MARKETING.balance - handler.marketingNativeBefore()),
            handler.nativeFunded()
        );
        uint256 tokensAccounted = token.balanceOf(address(vault)) + token.balanceOf(Network.FACTORY)
            + token.balanceOf(Network.POOL_MANAGER) + token.balanceOf(address(compensation))
            + token.balanceOf(Network.BURN) + token.balanceOf(address(handler));
        assertEq(tokensAccounted, token.totalSupply());
        assertEq(token.balanceOf(Network.DEV), 0, "launch tokens must be burned, never paid to dev");
        assertEq(imd.allowance(address(vault), Network.INTAKE), 0);
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
        assertEq(imd.allowance(address(jobs), Network.INTAKE), 0);
    }
}
