// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "./TestBase.sol";
import {JobsVault} from "src/JobsVault.sol";
import {Network} from "src/Network.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockToken, MockIntake} from "./mocks/Mocks.sol";

/// @dev Ghost accounting is driven by inputs and successful calls, never by JobsVault's bookkeeping.
contract JobBudgetHandler is Test {
    JobsVault public immutable jobs;
    MockToken public immutable token;
    MockToken private constant imd = MockToken(Network.IMD);
    MockIntake private constant intake = MockIntake(Network.INTAKE);
    address[4] public actors;
    uint256[4] public holdings;
    uint256[4] public nextAllowed;
    uint256 public funded;
    uint256 public spent;
    uint256 public requests;
    uint256 public rejectedRequests;
    uint256 public price = 0.5 ether;
    bool public intakeRejects;

    constructor(JobsVault jobs_, MockToken token_) {
        jobs = jobs_;
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("job actor ", vm.toString(i)));
            holdings[i] = i < 2 ? 1_000_000 ether : 1_000_000 ether - 1;
            token.mint(actors[i], holdings[i]);
        }
    }

    function fund(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, 10 ether);
        funded += amount;
        imd.mint(address(jobs), amount);
    }

    function advance(uint32 elapsed) public {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 2 days));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function transferHolding(uint8 rawFrom, uint8 rawTo, uint96 rawAmount) public {
        uint256 from = rawFrom % 4;
        uint256 to = rawTo % 4;
        uint256 amount = bound(rawAmount, 0, holdings[from]);
        vm.prank(actors[from]);
        token.transfer(actors[to], amount);
        holdings[from] -= amount;
        holdings[to] += amount;
    }

    function setIntakeAvailability(uint96 rawPrice, bool reject) public {
        price = bound(rawPrice, 0, 2 ether);
        intakeRejects = reject;
        intake.setPrice(price);
        intake.setReject(reject);
    }

    function request(uint8 rawActor, bool emptyBody) public {
        uint256 actor = rawActor % 4;
        uint256 now_ = vm.getBlockTimestamp();
        bytes memory body =
            emptyBody ? bytes("") : bytes("{\"objective\":\"a report\",\"template\":\"research\"}");
        bytes4 expectedError;
        if (holdings[actor] < 1_000_000 ether) expectedError = JobsVault.InsufficientHolding.selector;
        else if (now_ < nextAllowed[actor]) expectedError = JobsVault.DailyLimit.selector;
        else if (emptyBody) expectedError = JobsVault.InvalidBody.selector;
        else if (price == 0) expectedError = JobsVault.ActionNotSold.selector;
        else if (intakeRejects) expectedError = bytes4(keccak256("Error(string)"));
        else if (funded - spent < price) expectedError = IERC20Errors.ERC20InsufficientBalance.selector;

        vm.prank(actors[actor]);
        (bool ok, bytes memory result) = address(jobs).call(abi.encodeCall(jobs.requestJob, (body)));
        if (expectedError != bytes4(0)) {
            assertFalse(ok, "an ineligible request spent the jobs budget");
            assertEq(bytes4(result), expectedError, "reverted for a reason the model did not predict");
            ++rejectedRequests;
        } else {
            assertTrue(ok, "a funded, eligible request unexpectedly reverted");
            assertTrue(abi.decode(result, (bytes32)) != bytes32(0));
            assertEq(intake.lastPayer(), address(jobs));
            assertEq(intake.lastAction(), bytes32("job.open@job-1"));
            assertEq(intake.lastBody(), body);
            assertEq(intake.allowanceSeen(), price);
            nextAllowed[actor] = now_ + 1 days;
            spent += price;
            ++requests;
        }
        assertEq(jobs.nextRequestAt(actors[actor]), nextAllowed[actor]);
        assertEq(imd.allowance(address(jobs), Network.INTAKE), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract JobsStatefulTest is TestBase {
    JobBudgetHandler private handler;

    function setUp() public override {
        super.setUp();
        bind();
        handler = new JobBudgetHandler(jobs, token);
        handler.fund(5 ether);
        // Exercise both branches before random sequences so this cannot pass vacuously.
        handler.request(0, false);
        handler.request(0, false);
        handler.request(2, false);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.transferHolding.selector;
        selectors[3] = handler.setIntakeAvailability.selector;
        selectors[4] = handler.request.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantJobBudgetPaysOnlySuccessfulEligibleRequests() public view {
        assertGt(handler.requests(), 0);
        assertGt(handler.rejectedRequests(), 0);
        assertEq(imd.balanceOf(address(jobs)), handler.funded() - handler.spent());
        assertEq(imd.balanceOf(Network.INTAKE), handler.spent());
        assertEq(intake.paid(), handler.spent());
        assertEq(intake.nonce(), handler.requests());
        assertEq(imd.totalSupply(), handler.funded());
        assertEq(imd.allowance(address(jobs), Network.INTAKE), 0);
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(jobs.nextRequestAt(actor), handler.nextAllowed(i));
            assertEq(token.balanceOf(actor), handler.holdings(i));
            assertEq(imd.balanceOf(actor), 0, "job callers never receive the vault's IMD");
        }
    }
}
