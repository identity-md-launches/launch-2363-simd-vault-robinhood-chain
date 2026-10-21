// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {VaultChild} from "./VaultChild.sol";
import {Network} from "./Network.sol";

contract CompensationVault is VaultChild, IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    bytes32 public constant MERKLE_ROOT = 0xe84256f66c03a4565c29addd32238495f1a0d5dda8c618e5f81ff8637c296347;
    uint256 public constant TOTAL_WEIGHT = 201084680772174552329559308;
    uint256 public constant WALLET_COUNT = 62;
    uint256 public constant ANTI_SNIPER_WINDOW = 30 minutes;
    uint256 public constant TRANCHE_INTERVAL = 10 minutes;
    uint256 public constant MAX_TRANCHES = 10;

    error InvalidPool();
    error TooEarly();
    error BuybackFinished();
    error BuybackNotFinished();
    error UnexpectedCallback();
    error InvalidSwap();
    error InvalidBatch();
    error NoTokens();

    PoolKey public poolKey;
    uint256 public buybackAvailableAt;
    uint256 public initialIMD;
    uint256 public trancheCap;
    uint256 public totalSpent;
    uint256 public nextBuybackAt;
    uint256 public tranches;
    uint256 public tokenBalanceAtAirdropStart;
    uint256 public airdropped;
    bool public buybackStarted;
    bool public buybackComplete;
    bool public airdropStarted;
    mapping(address => bool) public paid;
    uint256 private pendingSwap;

    event LaunchSet(address indexed token, bytes32 indexed poolId, uint256 buybackAvailableAt);
    event BoughtBack(uint256 indexed tranche, uint256 spent, uint256 received);
    event BuybackCompleted(uint256 totalSpent, uint256 remainingIMD);
    event AirdropStarted(uint256 tokenBalance);
    event CompensationPaid(address indexed account, uint256 weight, uint256 amount);

    constructor(address vault_) VaultChild(vault_) {}

    /// @dev V4 exposes initialization state, not its timestamp. Starting the wait at binding is a
    /// conservative upper bound on initialization time; it cannot shorten the anti-sniper window.
    function setLaunch(address token_, PoolKey calldata key) external onlyVault {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            c0 >= c1 || token_ == Network.IMD
                || !((c0 == Network.IMD && c1 == token_) || (c0 == token_ && c1 == Network.IMD))
        ) revert InvalidPool();
        (uint160 price,,,) = IPoolManager(Network.POOL_MANAGER).getSlot0(key.toId());
        if (price == 0) revert InvalidPool();
        _setToken(token_);
        poolKey = key;
        buybackAvailableAt = block.timestamp + ANTI_SNIPER_WINDOW;
        emit LaunchSet(token_, PoolId.unwrap(key.toId()), buybackAvailableAt);
    }

    /// @notice Spend at most floor(initial balance / 10), at most ten times, ten minutes apart.
    /// @dev A remainder below ten IMD base units and post-start donations are never spendable.
    function buyback() external nonReentrant {
        if (token == address(0)) revert NotConfigured();
        if (buybackComplete) revert BuybackFinished();
        if (block.timestamp < buybackAvailableAt || block.timestamp < nextBuybackAt) revert TooEarly();
        if (!buybackStarted) {
            buybackStarted = true;
            initialIMD = IERC20(Network.IMD).balanceOf(address(this));
            trancheCap = initialIMD / MAX_TRANCHES;
        }
        if (trancheCap == 0) {
            _finishBuyback();
            return;
        }
        uint256 spend = Math.min(trancheCap, IERC20(Network.IMD).balanceOf(address(this)));
        if (spend == 0) {
            _finishBuyback();
            return;
        }
        // V4 represents each currency delta as int128.
        if (spend > uint256(uint128(type(int128).max))) revert InvalidSwap();
        uint256 beforeTokens = IERC20(token).balanceOf(address(this));
        uint256 beforeIMD = IERC20(Network.IMD).balanceOf(address(this));
        pendingSwap = spend;
        IPoolManager(Network.POOL_MANAGER).unlock(abi.encode(spend));
        if (pendingSwap != 0 || beforeIMD - IERC20(Network.IMD).balanceOf(address(this)) != spend) {
            revert InvalidSwap();
        }
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeTokens;
        if (received == 0) revert InvalidSwap();
        totalSpent += spend;
        ++tranches;
        nextBuybackAt = block.timestamp + TRANCHE_INTERVAL;
        emit BoughtBack(tranches, spend, received);
        if (tranches == MAX_TRANCHES || IERC20(Network.IMD).balanceOf(address(this)) == 0) _finishBuyback();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != Network.POOL_MANAGER || pendingSwap == 0) revert UnexpectedCallback();
        uint256 spend = abi.decode(data, (uint256));
        if (spend != pendingSwap) revert UnexpectedCallback();
        pendingSwap = 0;
        PoolKey memory key = poolKey;
        bool zeroForOne = Currency.unwrap(key.currency0) == Network.IMD;
        BalanceDelta delta = IPoolManager(Network.POOL_MANAGER)
            .swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(spend),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                bytes("")
            );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (int256(inputDelta) != -int256(spend) || outputDelta <= 0) revert InvalidSwap();
        IPoolManager manager = IPoolManager(Network.POOL_MANAGER);
        manager.sync(Currency.wrap(Network.IMD));
        IERC20(Network.IMD).safeTransfer(Network.POOL_MANAGER, spend);
        if (manager.settle() != spend) revert InvalidSwap();
        manager.take(Currency.wrap(token), address(this), uint256(uint128(outputDelta)));
        return bytes("");
    }

    function airdrop(address[] calldata accounts, uint256[] calldata weights, bytes32[][] calldata proofs)
        external
        nonReentrant
    {
        if (!buybackComplete) revert BuybackNotFinished();
        if (accounts.length == 0 || accounts.length != weights.length || accounts.length != proofs.length) {
            revert InvalidBatch();
        }
        // Freeze the balance on the first successful batch call, even if its proofs all fail.
        // A zero-balance call reverts so it cannot consume the future launch allocation.
        if (!airdropStarted) {
            tokenBalanceAtAirdropStart = IERC20(token).balanceOf(address(this));
            if (tokenBalanceAtAirdropStart == 0) revert NoTokens();
            airdropStarted = true;
            emit AirdropStarted(tokenBalanceAtAirdropStart);
        }
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            uint256 weight = weights[i];
            if (paid[account] || weight == 0 || weight > TOTAL_WEIGHT) continue;
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, weight))));
            if (!MerkleProof.verifyCalldata(proofs[i], _merkleRoot(), leaf)) continue;
            uint256 amount = Math.mulDiv(tokenBalanceAtAirdropStart, weight, TOTAL_WEIGHT);
            paid[account] = true;
            airdropped += amount;
            assert(airdropped <= tokenBalanceAtAirdropStart);
            IERC20(token).safeTransfer(account, amount);
            emit CompensationPaid(account, weight, amount);
        }
    }

    /// @dev Virtual only for synthetic proof fixtures in tests. The instance created by SIMDVault
    /// always uses this literal constant and has no setter, proxy or delegatecall.
    function _merkleRoot() internal pure virtual returns (bytes32) {
        return MERKLE_ROOT;
    }

    function _finishBuyback() private {
        buybackComplete = true;
        emit BuybackCompleted(totalSpent, IERC20(Network.IMD).balanceOf(address(this)));
    }
}
