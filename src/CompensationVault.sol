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
    uint256 public constant BUYBACK_WINDOW = 3 days;
    uint256 public constant PRICE_BAND_BPS = 150;
    uint256 private constant BPS = 10_000;

    error InvalidPool();
    error TooEarly();
    error BuybackFinished();
    error BuybackNotFinished();
    error UnexpectedCallback();
    error InvalidSwap();
    error InvalidBatch();
    error NoTokens();
    error NothingToBuy();

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
    uint256 public referenceSqrtPrice;
    uint256 public referenceSetAt;
    uint256 private pendingSwap;

    event LaunchSet(address indexed token, bytes32 indexed poolId, uint256 buybackAvailableAt);
    event ReferencePriceRecorded(uint160 sqrtPriceX96);
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
        _recordReference(price);
        emit LaunchSet(token_, PoolId.unwrap(key.toId()), buybackAvailableAt);
    }

    /// @notice Spend at most floor(initial balance / 10), at most ten times, ten minutes apart.
    /// @dev Every swap is bounded to PRICE_BAND_BPS (in sqrt price) around a reference price that was
    /// recorded at an earlier timestamp, so a caller cannot move the price and trigger a tranche in
    /// the same transaction. A price outside that band only re-records the reference; the tranche
    /// runs on a later call. A partial fill at the band counts as a tranche; a swap that buys
    /// nothing ends the buyback. After BUYBACK_WINDOW anyone can end it so the airdrop always opens.
    function buyback() external nonReentrant {
        if (token == address(0)) revert NotConfigured();
        if (buybackComplete) revert BuybackFinished();
        if (block.timestamp < buybackAvailableAt || block.timestamp < nextBuybackAt) revert TooEarly();
        if (block.timestamp >= buybackAvailableAt + BUYBACK_WINDOW) {
            _finishBuyback();
            return;
        }
        if (!buybackStarted) {
            uint256 balance = IERC20(Network.IMD).balanceOf(address(this));
            // Wait for the anti-sniper fee instead of freezing an empty budget.
            if (balance < MAX_TRANCHES) revert NothingToBuy();
            buybackStarted = true;
            initialIMD = balance;
            trancheCap = balance / MAX_TRANCHES;
        }
        uint256 spend = Math.min(trancheCap, IERC20(Network.IMD).balanceOf(address(this)));
        if (spend == 0) {
            _finishBuyback();
            return;
        }
        // V4 represents each currency delta as int128.
        if (spend > uint256(uint128(type(int128).max))) revert InvalidSwap();
        if (referenceSetAt >= block.timestamp) revert TooEarly();
        (uint160 price,,,) = IPoolManager(Network.POOL_MANAGER).getSlot0(poolKey.toId());
        (uint160 lower, uint160 upper) = priceBand();
        if (price <= lower || price >= upper) {
            _recordReference(price);
            return;
        }
        uint256 beforeTokens = IERC20(token).balanceOf(address(this));
        uint256 beforeIMD = IERC20(Network.IMD).balanceOf(address(this));
        pendingSwap = spend;
        bytes memory result = IPoolManager(Network.POOL_MANAGER).unlock(abi.encode(spend));
        (uint256 paid,) = abi.decode(result, (uint256, uint256));
        if (
            pendingSwap != 0 || paid > spend
                || beforeIMD - IERC20(Network.IMD).balanceOf(address(this)) != paid
        ) {
            revert InvalidSwap();
        }
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeTokens;
        totalSpent += paid;
        (price,,,) = IPoolManager(Network.POOL_MANAGER).getSlot0(poolKey.toId());
        _recordReference(price);
        if (received == 0) {
            // The pool cannot sell any more tokens for a tranche: nothing left worth buying.
            _finishBuyback();
            return;
        }
        ++tranches;
        nextBuybackAt = block.timestamp + TRANCHE_INTERVAL;
        emit BoughtBack(tranches, paid, received);
        if (tranches == MAX_TRANCHES || IERC20(Network.IMD).balanceOf(address(this)) == 0) _finishBuyback();
    }

    /// @notice The sqrt prices a tranche may trade between; a swap stops at the band edge.
    function priceBand() public view returns (uint160 lower, uint160 upper) {
        uint256 ref = referenceSqrtPrice;
        lower = uint160(Math.max(ref * (BPS - PRICE_BAND_BPS) / BPS, uint256(TickMath.MIN_SQRT_PRICE) + 1));
        upper = uint160(Math.min(ref * (BPS + PRICE_BAND_BPS) / BPS, uint256(TickMath.MAX_SQRT_PRICE) - 1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != Network.POOL_MANAGER || pendingSwap == 0) revert UnexpectedCallback();
        uint256 spend = abi.decode(data, (uint256));
        if (spend != pendingSwap) revert UnexpectedCallback();
        pendingSwap = 0;
        PoolKey memory key = poolKey;
        bool zeroForOne = Currency.unwrap(key.currency0) == Network.IMD;
        (uint160 lower, uint160 upper) = priceBand();
        BalanceDelta delta = IPoolManager(Network.POOL_MANAGER)
            .swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(spend),
                    sqrtPriceLimitX96: zeroForOne ? lower : upper
                }),
                bytes("")
            );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta > 0 || outputDelta < 0 || -int256(inputDelta) > int256(spend)) revert InvalidSwap();
        uint256 paid = uint256(-int256(inputDelta));
        uint256 received = uint256(uint128(outputDelta));
        IPoolManager manager = IPoolManager(Network.POOL_MANAGER);
        if (paid != 0) {
            manager.sync(Currency.wrap(Network.IMD));
            IERC20(Network.IMD).safeTransfer(Network.POOL_MANAGER, paid);
            if (manager.settle() != paid) revert InvalidSwap();
        }
        if (received != 0) manager.take(Currency.wrap(token), address(this), received);
        return abi.encode(paid, received);
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

    function _recordReference(uint160 price) private {
        referenceSqrtPrice = price;
        referenceSetAt = block.timestamp;
        emit ReferencePriceRecorded(price);
    }

    function _finishBuyback() private {
        buybackComplete = true;
        emit BuybackCompleted(totalSpent, IERC20(Network.IMD).balanceOf(address(this)));
    }
}
