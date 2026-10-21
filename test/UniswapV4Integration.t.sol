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

contract UniswapV4IntegrationTest is TestBase {
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
