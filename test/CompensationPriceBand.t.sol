// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {LiquiditySeeder} from "./UniswapV4Integration.t.sol";
import {CompensationVault} from "../src/CompensationVault.sol";
import {Network} from "../src/Network.sol";
import {MockToken} from "./mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

/// @dev A sandwicher: exact-input swaps through the real PoolManager, settled and taken in one unlock.
contract Sandwicher is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external {
        manager.unlock(abi.encode(key, zeroForOne, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        settle(key.currency0, delta.amount0());
        settle(key.currency1, delta.amount1());
        return "";
    }

    function settle(Currency c, int128 delta) private {
        if (delta < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(c, address(this), uint256(uint128(delta)));
        }
    }
}

/// @dev Same-transaction price manipulation must not trigger a tranche, and every tranche trades only
/// inside the band around a reference recorded at an earlier timestamp. Real v4 PoolManager.
contract CompensationPriceBandTest is TestBase {
    using StateLibrary for IPoolManager;

    IPoolManager private v4;
    PoolKey private livePool;
    address private constant TOKEN = address(0x1000);
    Sandwicher private attacker;

    function setUp() public override {
        super.setUp();
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), Network.POOL_MANAGER);
        v4 = IPoolManager(Network.POOL_MANAGER);
        vm.etch(TOKEN, address(new MockToken(18)).code);
        livePool = poolFor(TOKEN);
        v4.initialize(livePool, uint160(1 << 96));
        LiquiditySeeder seeder = new LiquiditySeeder(v4);
        imd.mint(address(seeder), 1e30);
        MockToken(TOKEN).mint(address(seeder), 1e30);
        seeder.seed(livePool, 1e24);
        factory.configure(livePool, address(vault));
        vm.prank(Network.DEV);
        vault.bindLaunch(7, TOKEN);
        attacker = new Sandwicher(v4);
        imd.mint(address(attacker), 1e28);
        MockToken(TOKEN).mint(address(attacker), 1e28);
        imd.mint(address(compensation), 1000 ether);
    }

    function price() private view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = v4.getSlot0(livePool.toId());
    }

    function testReferenceIsRecordedAtBindingAndBandIsSymmetric() public view {
        assertEq(compensation.referenceSqrtPrice(), uint256(1 << 96));
        assertEq(compensation.referenceSetAt(), vm.getBlockTimestamp());
        (uint160 lower, uint160 upper) = compensation.priceBand();
        assertEq(lower, uint160((uint256(1 << 96) * 9850) / 10_000));
        assertEq(upper, uint160((uint256(1 << 96) * 10_150) / 10_000));
    }

    function testPricePushedInSameTransactionOnlyRecordsReferenceAndSpendsNothing() public {
        vm.warp(compensation.buybackAvailableAt());
        // IMD is currency1: buying TEST with IMD raises the price, exactly what a sandwich front-run does.
        attacker.swap(livePool, false, 2e22); // sqrt price +2%: out of band, still inside the ±600-tick range
        uint160 pushed = price();
        (, uint160 upper) = compensation.priceBand();
        assertGe(pushed, upper, "front-run must leave the band for this test to mean anything");
        uint256 tokensBefore = IERC20(TOKEN).balanceOf(address(compensation));
        compensation.buyback();
        assertEq(compensation.tranches(), 0);
        assertEq(compensation.totalSpent(), 0);
        assertEq(imd.balanceOf(address(compensation)), 1000 ether);
        assertEq(IERC20(TOKEN).balanceOf(address(compensation)), tokensBefore);
        assertEq(price(), pushed, "the vault did not trade into the manipulated price");
        // The reference moves one band step towards the pushed price, never onto it.
        assertEq(compensation.referenceSqrtPrice(), upper);
        assertLt(compensation.referenceSqrtPrice(), pushed);
        assertEq(compensation.referenceSetAt(), vm.getBlockTimestamp());
        assertEq(compensation.nextBuybackAt(), 0, "an out-of-band call is not a tranche");
        // The budget froze on the first call; it cannot be retried in the same timestamp.
        assertTrue(compensation.buybackStarted());
        assertEq(compensation.trancheCap(), 100 ether);
        vm.expectRevert(CompensationVault.TooEarly.selector);
        compensation.buyback();
    }

    /// A large push only walks the reference one band step per ten minutes: the vault cannot be made
    /// to trade at a price the manipulator did not hold against arbitrage for that long.
    function testLargePushWalksReferenceOneStepPerInterval() public {
        vm.warp(compensation.buybackAvailableAt());
        attacker.swap(livePool, false, 5e22); // well past one band step, inside the seeded range
        uint160 pushed = price();
        uint256 ref0 = compensation.referenceSqrtPrice();
        (, uint160 upper0) = compensation.priceBand();
        assertGt(pushed, upper0);
        compensation.buyback();
        assertEq(compensation.referenceSqrtPrice(), upper0);
        uint256 setAt = compensation.referenceSetAt();
        (, uint160 upper1) = compensation.priceBand();
        assertGt(pushed, upper1, "still out of band after one step");
        // Still out of band before the interval: refused, nothing spent, reference unchanged.
        vm.warp(setAt + 10 minutes - 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(CompensationVault.TooEarly.selector);
        compensation.buyback();
        vm.warp(setAt + 10 minutes);
        compensation.buyback();
        assertEq(compensation.referenceSqrtPrice(), upper1);
        assertGt(upper1, ref0);
        assertEq(compensation.totalSpent(), 0);
        assertEq(compensation.tranches(), 0);
        assertEq(imd.balanceOf(address(compensation)), 1000 ether);
    }

    function testTrancheAfterReRecordTradesOnlyInsideNewBand() public {
        vm.warp(compensation.buybackAvailableAt());
        attacker.swap(livePool, false, 2e22); // sqrt price +2%: out of band, still inside the ±600-tick range
        compensation.buyback();
        (uint160 lower, uint160 upper) = compensation.priceBand();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        compensation.buyback();
        assertEq(compensation.tranches(), 1);
        assertGt(compensation.totalSpent(), 0);
        assertLe(compensation.totalSpent(), 100 ether);
        assertEq(imd.balanceOf(address(compensation)), 1000 ether - compensation.totalSpent());
        uint160 after_ = price();
        assertGt(after_, lower);
        assertLe(after_, upper);
        assertEq(compensation.referenceSqrtPrice(), after_);
        assertEq(compensation.nextBuybackAt(), vm.getBlockTimestamp() + 10 minutes);
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzzAnyFrontRunNeverPushesTrancheOutsideEarlierBand(uint96 rawPush, bool direction) public {
        vm.warp(compensation.buybackAvailableAt());
        uint256 push = bound(rawPush, 0, 1e24);
        if (push != 0) attacker.swap(livePool, direction, push);
        (uint160 lower, uint160 upper) = compensation.priceBand();
        uint160 before = price();
        compensation.buyback();
        uint160 after_ = price();
        assertLe(compensation.totalSpent(), 100 ether);
        assertEq(imd.balanceOf(address(compensation)), 1000 ether - compensation.totalSpent());
        if (before <= lower || before >= upper) {
            assertEq(compensation.totalSpent(), 0);
            assertEq(after_, before);
        } else {
            // A buy moves the price up, never past the band recorded before this transaction.
            assertGe(after_, before);
            assertLe(after_, upper);
        }
    }
}
