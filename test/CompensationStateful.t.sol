// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "./TestBase.sol";
import {MigrationClaims} from "./fixtures/MigrationClaims.sol";
import {CompensationVault} from "src/CompensationVault.sol";
import {Network} from "src/Network.sol";
import {MockToken, MockManager} from "./mocks/Mocks.sol";

/// @dev Tests the actual child deployed by SIMDVault, using two real migration beneficiary proofs.
contract CompensationSequenceHandler is Test {
    CompensationVault public immutable compensation;
    MockToken public immutable token;
    MockToken private constant imd = MockToken(Network.IMD);
    MockManager private constant manager = MockManager(Network.POOL_MANAGER);
    uint256 public constant WEIGHT = 201084680772174552329559308;
    address public immutable FIRST;
    address public immutable SECOND;
    uint256 private immutable firstWeight;
    uint256 private immutable secondWeight;
    bytes32[] private firstProof;
    bytes32[] private secondProof;
    address public immutable outsider;
    uint256 public immutable availableAt;
    uint256 public imdIn;
    uint256 public tokenIn;
    uint256 public expectedInitial;
    uint256 public spent;
    uint256 public bought;
    uint256 public swaps;
    uint256 public nextAt;
    uint256 public frozenTokens;
    uint256 public paidTotal;
    uint256[2] public paidAmounts;
    bool[2] public paidOnce;
    bool public started;
    bool public complete;
    bool public airdropStarted;
    uint256 public rejectedCalls;

    constructor(CompensationVault c, MockToken token_) {
        compensation = c;
        token = token_;
        availableAt = c.buybackAvailableAt();
        outsider = makeAddr("compensation unlisted submitter");
        (address[] memory accounts, uint256[] memory weights, bytes32[][] memory proofs) =
            MigrationClaims.all();
        FIRST = accounts[0];
        SECOND = accounts[1];
        firstWeight = weights[0];
        secondWeight = weights[1];
        firstProof = proofs[0];
        secondProof = proofs[1];
    }

    function fundIMD(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, 1e24);
        // Budget funding before the first tranche. Later donations are outside the frozen budget.
        if (started) return;
        imdIn += amount;
        imd.mint(address(compensation), amount);
    }

    function fundTokens(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, 1e24);
        tokenIn += amount;
        token.mint(address(compensation), amount);
    }

    function advance(uint32 elapsed) public {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 40 minutes));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function buyback(bool rejectSwap) public {
        manager.setReject(rejectSwap);
        uint256 now_ = vm.getBlockTimestamp();
        uint256 cap = (started ? expectedInitial : imdIn) / 10;
        bytes memory expectedError;
        if (complete) {
            expectedError = abi.encodeWithSelector(CompensationVault.BuybackFinished.selector);
        } else if (now_ < availableAt || now_ < nextAt) {
            expectedError = abi.encodeWithSelector(CompensationVault.TooEarly.selector);
        } else if (cap != 0 && rejectSwap) {
            expectedError = abi.encodeWithSignature("Error(string)", "bad swap");
        }
        vm.prank(outsider);
        (bool ok, bytes memory result) = address(compensation).call(abi.encodeCall(compensation.buyback, ()));
        manager.setReject(false);
        if (expectedError.length != 0) {
            assertFalse(ok, "invalid tranche was allowed");
            assertEq(result, expectedError);
            ++rejectedCalls;
            return;
        }
        assertTrue(ok, "valid tranche reverted");
        if (!started) {
            started = true;
            expectedInitial = imdIn;
        }
        if (cap == 0) {
            complete = true;
            return;
        }
        spent += cap;
        bought += 2 * cap; // The accounting mock exchanges two token units per IMD unit.
        ++swaps;
        nextAt = now_ + 10 minutes;
        complete = swaps == 10 || spent == imdIn;
    }

    /// @dev Random batch order, within/across-batch duplicates, changed weight, bad proof, unlisted
    /// account, token transfer failure, and calls before completion all run through the same entry.
    function airdrop(uint8 mode, bool reverse, bool rejectTransfer) public {
        mode %= 5;
        address[] memory accounts = new address[](3);
        uint256[] memory weights = new uint256[](3);
        bytes32[][] memory proofs = new bytes32[][](3);
        accounts[0] = reverse ? SECOND : FIRST;
        accounts[1] = reverse ? FIRST : SECOND;
        for (uint256 i; i < 2; ++i) {
            weights[i] = accounts[i] == FIRST ? firstWeight : secondWeight;
            proofs[i] = accounts[i] == FIRST ? firstProof : secondProof;
        }
        if (mode == 1) weights[0]++;
        if (mode == 2) proofs[0][0] = bytes32(0);
        if (mode == 3) accounts[0] = outsider;
        if (mode == 4) {
            weights[0] = 0;
            weights[1] = WEIGHT + 1;
        }
        accounts[2] = accounts[0];
        weights[2] = weights[0];
        proofs[2] = proofs[0];

        uint256 balance = tokenIn + bought - paidTotal;
        bool[2] memory shouldPay;
        if (mode == 0) shouldPay[reverse ? 1 : 0] = !paidOnce[reverse ? 1 : 0];
        if (mode != 4) shouldPay[reverse ? 0 : 1] = !paidOnce[reverse ? 0 : 1];
        bytes memory expectedError;
        if (!complete) {
            expectedError = abi.encodeWithSelector(CompensationVault.BuybackNotFinished.selector);
        } else if (!airdropStarted && balance == 0) {
            expectedError = abi.encodeWithSelector(CompensationVault.NoTokens.selector);
        } else if (rejectTransfer && (shouldPay[0] || shouldPay[1])) {
            expectedError = abi.encodeWithSignature("Error(string)", "transfer rejected");
        }
        token.setReject(rejectTransfer);
        vm.prank(outsider);
        (bool ok, bytes memory result) =
            address(compensation).call(abi.encodeCall(compensation.airdrop, (accounts, weights, proofs)));
        token.setReject(false);
        if (expectedError.length != 0) {
            assertFalse(ok);
            assertEq(result, expectedError);
            ++rejectedCalls;
            return;
        }
        assertTrue(ok, "valid batch reverted");
        if (!airdropStarted) {
            frozenTokens = balance;
            airdropStarted = true;
        }
        for (uint256 i; i < 2; ++i) {
            if (shouldPay[i]) {
                uint256 weight = i == 0 ? firstWeight : secondWeight;
                paidAmounts[i] = frozenTokens * weight / WEIGHT;
                paidTotal += paidAmounts[i];
                paidOnce[i] = true;
            }
        }
    }

    function finish() external {
        while (!complete) {
            uint256 next = availableAt > nextAt ? availableAt : nextAt;
            if (vm.getBlockTimestamp() < next) vm.warp(next);
            buyback(false);
        }
        airdrop(0, false, false);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract CompensationStatefulTest is TestBase {
    CompensationVault private fixture;
    CompensationSequenceHandler private handler;

    function setUp() public override {
        super.setUp();
        bind();
        fixture = compensation;
        handler = new CompensationSequenceHandler(fixture, token);
        handler.fundIMD(1000 ether);
        handler.fundTokens(500 ether);
        handler.buyback(false); // Must reject before the anti-sniper window.
        handler.airdrop(0, false, false); // Must reject before completion.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.fundIMD.selector;
        selectors[1] = handler.fundTokens.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.buyback.selector;
        selectors[4] = handler.airdrop.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantBuybackAndAirdropConserveBothAssets() public view {
        assertEq(fixture.buybackStarted(), handler.started());
        assertEq(fixture.buybackComplete(), handler.complete());
        assertEq(fixture.initialIMD(), handler.expectedInitial());
        assertEq(fixture.tranches(), handler.swaps());
        assertEq(fixture.totalSpent(), handler.spent());
        assertEq(fixture.nextBuybackAt(), handler.nextAt());
        assertLe(fixture.tranches(), 10);
        assertLe(handler.spent(), handler.imdIn());
        assertEq(imd.balanceOf(address(fixture)), handler.imdIn() - handler.spent());
        assertEq(imd.balanceOf(Network.POOL_MANAGER), handler.spent());
        assertEq(token.balanceOf(Network.POOL_MANAGER) + handler.bought(), 1e32);
        assertEq(
            token.balanceOf(address(fixture)), handler.tokenIn() + handler.bought() - handler.paidTotal()
        );
        assertEq(fixture.airdropStarted(), handler.airdropStarted());
        assertEq(fixture.tokenBalanceAtAirdropStart(), handler.frozenTokens());
        assertEq(fixture.airdropped(), handler.paidTotal());
        assertLe(handler.paidTotal(), handler.frozenTokens());
        assertEq(fixture.paid(handler.FIRST()), handler.paidOnce(0));
        assertEq(fixture.paid(handler.SECOND()), handler.paidOnce(1));
        assertEq(token.balanceOf(handler.FIRST()), handler.paidAmounts(0));
        assertEq(token.balanceOf(handler.SECOND()), handler.paidAmounts(1));
        assertEq(token.balanceOf(handler.outsider()), 0);
        assertEq(imd.balanceOf(handler.outsider()), 0);
        assertEq(fixture.MERKLE_ROOT(), 0xe84256f66c03a4565c29addd32238495f1a0d5dda8c618e5f81ff8637c296347);
    }

    function afterInvariant() public {
        // Every random prefix must still be able to finish and pay both real beneficiaries once.
        handler.finish();
        invariantBuybackAndAirdropConserveBothAssets();
        assertTrue(fixture.buybackComplete());
        assertTrue(fixture.paid(handler.FIRST()));
        assertTrue(fixture.paid(handler.SECOND()));
    }
}
