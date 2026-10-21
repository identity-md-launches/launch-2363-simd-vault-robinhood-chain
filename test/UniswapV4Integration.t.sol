// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestBase} from "./TestBase.sol";
import {CompensationVault} from "../src/CompensationVault.sol";
import {Network} from "../src/Network.sol";
import {MockToken} from "./mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

contract LiquiditySeeder is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function seed(PoolKey memory key, uint128 amount) external {
        manager.unlock(abi.encode(key, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, uint128 amount) = abi.decode(data, (PoolKey, uint128));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: int256(uint256(amount)), salt: bytes32(0)
            }),
            ""
        );
        pay(key.currency0, delta.amount0());
        pay(key.currency1, delta.amount1());
        return "";
    }

    function pay(Currency c, int128 delta) private {
        if (delta < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(c, address(this), uint256(uint128(delta)));
        }
    }
}

/// Swaps exact input with the pool's outer limit, settling v4 deltas: a price pusher.
contract Pusher is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) external {
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
        pay(key.currency0, delta.amount0());
        pay(key.currency1, delta.amount1());
        return "";
    }

    function pay(Currency c, int128 delta) private {
        if (delta < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(c, address(this), uint256(uint128(delta)));
        }
    }
}

contract UniswapV4IntegrationTest is TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function testRealV4UnlockSettlementTenSwapsTokenAsCurrencyZero() public {
        exercise(address(0x1000));
    }

    function testRealV4UnlockSettlementTenSwapsTokenAsCurrencyOne() public {
        exercise(address(uint160(type(uint160).max) - 1));
    }

    function testUninitializedPoolCannotBind() public {
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), Network.POOL_MANAGER);
        vm.prank(Network.DEV);
        vm.expectRevert(CompensationVault.InvalidPool.selector);
        vault.bindLaunch(7, address(token));
    }

    /// Thin launch range: each tranche stops at the price band around its earlier reference,
    /// spends only what the pool consumed, and the buyback still ends so the airdrop can open.
    function testRealV4ThinPoolTranchesStayInsidePriceBandAndBuybackEnds() public {
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), Network.POOL_MANAGER);
        IPoolManager actual = IPoolManager(Network.POOL_MANAGER);
        address tokenAddress = address(0x1000);
        vm.etch(tokenAddress, address(new MockToken(18)).code);
        PoolKey memory actualKey = poolFor(tokenAddress);
        actual.initialize(actualKey, uint160(1 << 96));
        LiquiditySeeder seeder = new LiquiditySeeder(actual);
        imd.mint(address(seeder), 1e27);
        MockToken(tokenAddress).mint(address(seeder), 1e27);
        seeder.seed(actualKey, 1e20);
        factory.configure(actualKey, address(vault));
        vm.prank(Network.DEV);
        vault.bindLaunch(7, tokenAddress);
        imd.mint(address(compensation), 1000 ether);
        vm.warp(compensation.buybackAvailableAt());
        for (uint256 i; i < 40 && !compensation.buybackComplete(); ++i) {
            (uint160 lower, uint160 upper) = compensation.priceBand();
            uint256 spentBefore = compensation.totalSpent();
            compensation.buyback();
            assertLe(compensation.totalSpent() - spentBefore, 100 ether);
            uint256 price = compensation.referenceSqrtPrice();
            assertTrue(price >= lower && price <= upper || compensation.totalSpent() == spentBefore);
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
        }
        assertTrue(compensation.buybackComplete());
        assertLt(compensation.totalSpent(), 1000 ether);
        assertEq(imd.balanceOf(address(compensation)), 1000 ether - compensation.totalSpent());
    }

    /// A price pushed out of the band fills no tranche, in that block or the next: the reference
    /// follows it by one band step per ten minutes, so the pusher must hold the price against
    /// arbitrage for the whole climb. Once the price is back, the tranche fills near the original
    /// reference.
    function testRealV4PushedPriceMovesReferenceOneStepPerIntervalAndFillsNothing() public {
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), Network.POOL_MANAGER);
        IPoolManager actual = IPoolManager(Network.POOL_MANAGER);
        address tokenAddress = address(0x1000);
        vm.etch(tokenAddress, address(new MockToken(18)).code);
        MockToken actualToken = MockToken(tokenAddress);
        PoolKey memory actualKey = poolFor(tokenAddress);
        actual.initialize(actualKey, uint160(1 << 96));
        LiquiditySeeder seeder = new LiquiditySeeder(actual);
        imd.mint(address(seeder), 1e27);
        actualToken.mint(address(seeder), 1e27);
        seeder.seed(actualKey, 1e24);
        factory.configure(actualKey, address(vault));
        vm.prank(Network.DEV);
        vault.bindLaunch(7, tokenAddress);
        imd.mint(address(compensation), 1000 ether);
        uint256 startRef = compensation.referenceSqrtPrice();
        (, uint160 upper) = compensation.priceBand();
        vm.warp(compensation.buybackAvailableAt());
        // Push TEST up about 10% (sqrt price about 5%) with IMD, well outside the 1.5% band.
        Pusher pusher = new Pusher(actual);
        imd.mint(address(pusher), 1e26);
        bool imdIsZero = Currency.unwrap(actualKey.currency0) == Network.IMD;
        pusher.swapExactIn(actualKey, imdIsZero, 5e22);
        (uint160 pushed,,,) = actual.getSlot0(actualKey.toId());
        assertGt(pushed, upper);
        // Same block as an earlier reference: nothing fills, the reference steps once to the band edge.
        compensation.buyback();
        assertEq(compensation.totalSpent(), 0);
        assertEq(compensation.referenceSqrtPrice(), upper);
        // The next block cannot step again or fill: the step is rate limited to the tranche interval.
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(CompensationVault.TooEarly.selector);
        compensation.buyback();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        compensation.buyback();
        assertEq(compensation.totalSpent(), 0);
        uint256 twoSteps = compensation.referenceSqrtPrice();
        assertGt(twoSteps, upper);
        assertLe(twoSteps, startRef * 1_030_225 / 1_000_000 + 2); // two compounded 1.5% steps
        assertLt(twoSteps, pushed);
        // Holding the price has a cost. Once it is sold back the reference walks down again, one
        // step per interval, and the first tranche fills near the original 1:1 price.
        pusher.swapExactIn(actualKey, !imdIsZero, actualToken.balanceOf(address(pusher)));
        uint256 beforeTokens = actualToken.balanceOf(address(compensation));
        uint256 calls;
        while (compensation.totalSpent() == 0 && calls < 4) {
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            compensation.buyback();
            ++calls;
        }
        assertEq(calls, 2);
        assertEq(compensation.totalSpent(), 100 ether);
        // At about 1:1 a 100 IMD tranche buys close to 100 TEST less the pool fee.
        assertGt(actualToken.balanceOf(address(compensation)) - beforeTokens, 96 ether);
    }

    function exercise(address tokenAddress) private {
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), Network.POOL_MANAGER);
        IPoolManager actual = IPoolManager(Network.POOL_MANAGER);
        vm.etch(tokenAddress, address(new MockToken(18)).code);
        MockToken actualToken = MockToken(tokenAddress);
        PoolKey memory actualKey = poolFor(tokenAddress);
        actual.initialize(actualKey, uint160(1 << 96));
        LiquiditySeeder seeder = new LiquiditySeeder(actual);
        imd.mint(address(seeder), 1e27);
        actualToken.mint(address(seeder), 1e27);
        seeder.seed(actualKey, 1e26);
        factory.configure(actualKey, address(vault));
        vm.prank(Network.DEV);
        vault.bindLaunch(7, tokenAddress);
        imd.mint(address(compensation), 1000 ether);
        vm.warp(compensation.buybackAvailableAt());
        for (uint256 i; i < 10; ++i) {
            uint256 previous = actualToken.balanceOf(address(compensation));
            compensation.buyback();
            assertGt(actualToken.balanceOf(address(compensation)), previous);
            assertEq(compensation.totalSpent(), 100 ether * (i + 1));
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
        }
        assertEq(imd.balanceOf(address(compensation)), 0);
        assertTrue(compensation.buybackComplete());
        assertGt(actualToken.balanceOf(address(compensation)), 990 ether);
        assertLt(actualToken.balanceOf(address(compensation)), 1000 ether);
    }
}
