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
        manager.unlock(abi.encode(key, amount, int24(-600), int24(600)));
    }

    function seedFullRange(PoolKey memory key, uint128 amount) external {
        manager.unlock(abi.encode(key, amount, int24(-887220), int24(887220)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, uint128 amount, int24 tickLower, int24 tickUpper) =
            abi.decode(data, (PoolKey, uint128, int24, int24));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(amount)),
                salt: bytes32(0)
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

/// Sandwiches a buyback call: moves the pool to an exact sqrt price, calls buyback(), and sells
/// every token it bought back, all in one transaction.
contract BuybackSandwicher is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager private immutable manager;
    CompensationVault private immutable vault;
    bool private immutable imdIsZero;
    PoolKey private key;

    constructor(IPoolManager manager_, CompensationVault vault_, PoolKey memory key_) {
        manager = manager_;
        vault = vault_;
        key = key_;
        imdIsZero = Currency.unwrap(key_.currency0) == Network.IMD;
    }

    function token() public view returns (address) {
        return imdIsZero ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
    }

    /// @param limit the sqrt price to push the pool to before calling buyback, if it is not past it
    function attack(uint160 limit) external {
        (uint160 current,,,) = manager.getSlot0(key.toId());
        bool alreadyThere = imdIsZero ? current <= limit : current >= limit;
        if (!alreadyThere) manager.unlock(abi.encode(true, limit, uint256(0)));
        vault.buyback();
        uint256 bought = IERC20(token()).balanceOf(address(this));
        if (bought != 0) manager.unlock(abi.encode(false, uint160(0), bought));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bool push, uint160 limit, uint256 amount) = abi.decode(data, (bool, uint160, uint256));
        bool zeroForOne = push ? imdIsZero : !imdIsZero;
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: push ? -int256(1e30) : -int256(amount),
                sqrtPriceLimitX96: push
                    ? limit
                    : zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
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

    /// Thin launch range: each call stops at the price band around its earlier reference and
    /// spends only what the pool consumed. A band-limited fill is not a tranche, never moves the
    /// reference and never ends the buyback; the reference steps one band per interval on the
    /// out-of-band path, and once the range is exhausted only the window ends the buyback, so the
    /// airdrop still opens.
    function testRealV4ThinPoolPartialFillsAreNotTranchesAndOnlyTheWindowEndsBuyback() public {
        (IPoolManager actual, MockToken actualToken, PoolKey memory actualKey) = openRealPool(1e20, false);
        imd.mint(address(compensation), 1000 ether);
        vm.warp(compensation.buybackAvailableAt());
        uint256 fills;
        while (!compensation.buybackComplete()) {
            (uint160 lower, uint160 upper) = compensation.priceBand();
            uint256 spentBefore = compensation.totalSpent();
            uint256 refBefore = compensation.referenceSqrtPrice();
            compensation.buyback();
            uint256 spent = compensation.totalSpent() - spentBefore;
            assertLe(spent, 100 ether);
            if (spent != 0) ++fills;
            uint256 ref = compensation.referenceSqrtPrice();
            // The reference moves only on a call that swaps nothing, by exactly one band step.
            if (ref != refBefore) {
                assertEq(spent, 0);
                assertTrue(ref == lower || ref == upper);
            }
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
        }
        assertEq(compensation.tranches(), 0);
        assertGt(fills, 1);
        assertGt(compensation.totalSpent(), 1 ether);
        assertLt(compensation.totalSpent(), 10 ether);
        assertGt(actualToken.balanceOf(address(compensation)), 0);
        assertGe(vm.getBlockTimestamp(), compensation.buybackAvailableAt() + compensation.BUYBACK_WINDOW());
        assertEq(imd.balanceOf(address(compensation)), 1000 ether - compensation.totalSpent());
        (uint160 price,,,) = actual.getSlot0(actualKey.toId());
        assertGt(price, uint160(1 << 96));
    }

    /// A front-run that parks the pool one unit inside the band edge makes the vault's swap buy
    /// nothing for two wei. That is a partial fill: no tranche, no finished buyback, no reference
    /// change and no cooldown, so the next honest call still fills in full.
    function testRealV4BandEdgeFrontRunCannotEndOrDelayTheBuyback() public {
        (, MockToken actualToken, PoolKey memory actualKey) = openRealPool(20_000e18, true);
        imd.mint(address(compensation), 1000 ether);
        BuybackSandwicher attacker =
            new BuybackSandwicher(IPoolManager(Network.POOL_MANAGER), compensation, actualKey);
        imd.mint(address(attacker), 2000 ether);
        vm.warp(compensation.buybackAvailableAt());
        (uint160 lower, uint160 upper) = compensation.priceBand();
        bool imdIsZero = Currency.unwrap(actualKey.currency0) == Network.IMD;
        attacker.attack(imdIsZero ? lower + 1 : upper - 1);
        assertFalse(compensation.buybackComplete());
        assertEq(compensation.tranches(), 0);
        assertLe(compensation.totalSpent(), 10);
        assertEq(actualToken.balanceOf(address(compensation)), 0);
        assertEq(compensation.referenceSqrtPrice(), uint160(1 << 96));
        assertLe(compensation.nextBuybackAt(), vm.getBlockTimestamp());
        // Ten such calls in a row still consume no tranche and no interval.
        for (uint256 i; i < 10; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 1);
            attacker.attack(imdIsZero ? lower + 1 : upper - 1);
        }
        assertEq(compensation.tranches(), 0);
        assertFalse(compensation.buybackComplete());
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        compensation.buyback();
        assertEq(compensation.tranches(), 1);
        assertEq(compensation.totalSpent(), 100 ether + compensation.totalSpent() % 1 ether);
        assertGt(actualToken.balanceOf(address(compensation)), 99 ether);
    }

    /// An in-band push before every call, sold back after it. The post-swap price never becomes
    /// the reference, so the sandwich is bounded to one band per fill and does not compound: the
    /// run ends at the same reference as an honest one and buys within 2% of what it buys.
    function testRealV4InBandSandwichDoesNotRatchetTheReference() public {
        (, MockToken actualToken, PoolKey memory actualKey) = openRealPool(20_000e18, true);
        imd.mint(address(compensation), 1000 ether);
        vm.warp(compensation.buybackAvailableAt());
        uint256 state = vm.snapshotState();
        for (uint256 i; i < 40 && !compensation.buybackComplete(); ++i) {
            compensation.buyback();
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertEq(compensation.tranches(), 10);
        uint256 honest = actualToken.balanceOf(address(compensation));
        uint256 honestReference = compensation.referenceSqrtPrice();
        assertTrue(vm.revertToState(state));
        BuybackSandwicher attacker =
            new BuybackSandwicher(IPoolManager(Network.POOL_MANAGER), compensation, actualKey);
        imd.mint(address(attacker), 50_000 ether);
        bool imdIsZero = Currency.unwrap(actualKey.currency0) == Network.IMD;
        for (uint256 i; i < 40 && !compensation.buybackComplete(); ++i) {
            uint256 ref = compensation.referenceSqrtPrice();
            attacker.attack(uint160(imdIsZero ? ref * 9905 / 10_000 : ref * 10_095 / 10_000));
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertEq(compensation.tranches(), 10);
        uint256 attacked = actualToken.balanceOf(address(compensation));
        assertEq(compensation.referenceSqrtPrice(), honestReference);
        assertGe(attacked, honest * 98 / 100);
        // The sandwich still nets the attacker a little on each fill; it is bounded, not compounding.
        assertLt(imd.balanceOf(address(attacker)) - 50_000 ether, 5 ether);
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

    function openRealPool(uint128 liquidity, bool fullRange)
        private
        returns (IPoolManager actual, MockToken actualToken, PoolKey memory actualKey)
    {
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), Network.POOL_MANAGER);
        actual = IPoolManager(Network.POOL_MANAGER);
        address tokenAddress = address(0x1000);
        vm.etch(tokenAddress, address(new MockToken(18)).code);
        actualToken = MockToken(tokenAddress);
        actualKey = poolFor(tokenAddress);
        actual.initialize(actualKey, uint160(1 << 96));
        LiquiditySeeder seeder = new LiquiditySeeder(actual);
        imd.mint(address(seeder), 1e40);
        actualToken.mint(address(seeder), 1e40);
        if (fullRange) seeder.seedFullRange(actualKey, liquidity);
        else seeder.seed(actualKey, liquidity);
        factory.configure(actualKey, address(vault));
        vm.prank(Network.DEV);
        vault.bindLaunch(7, tokenAddress);
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
