// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {Network} from "../../src/Network.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract MockToken is ERC20 {
    uint8 private immutable digits;
    bool public rejectTransfers;
    address public reenterTarget;
    bytes public reenterData;
    bool public reenterSucceeded;

    constructor(uint8 decimals_) ERC20("Test", "TEST") {
        digits = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return digits;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setReject(bool reject_) external {
        rejectTransfers = reject_;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function transfer(address to, uint256 value) public virtual override returns (bool) {
        require(!rejectTransfers, "transfer rejected");
        if (reenterTarget != address(0)) (reenterSucceeded,) = reenterTarget.call(reenterData);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(!rejectTransfers, "transfer rejected");
        return super.transferFrom(from, to, value);
    }
}

contract MockIntake is IIntake {
    uint256 public price;
    uint256 public nonce;
    bool public reject;
    bool public exhaustGas;
    address public lastPayer;
    bytes32 public lastAction;
    bytes public lastBody;
    Callback public lastCallback;
    uint256 public allowanceSeen;
    uint256 public paid;
    address public reenterTarget;
    bytes public reenterData;
    bool public reenterSucceeded;
    mapping(bytes32 => Callback) public callbacks;

    function setExhaustGas(bool value) external {
        exhaustGas = value;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setReject(bool reject_) external {
        reject = reject_;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function priceOf(bytes32, address asset) external view returns (uint256) {
        require(asset == Network.IMD, "wrong asset");
        return price;
    }

    function request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        if (exhaustGas) {
            assembly ("memory-safe") { invalid() }
        }
        require(!reject && price != 0 && amount == price, "request rejected");
        allowanceSeen = IERC20(asset).allowance(msg.sender, address(this));
        require(allowanceSeen == price, "approval not exact");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        paid += amount;
        lastPayer = msg.sender;
        lastAction = action;
        lastBody = body;
        lastCallback = callback;
        id = keccak256(abi.encode(msg.sender, ++nonce));
        callbacks[id] = callback;
        if (reenterTarget != address(0)) (reenterSucceeded,) = reenterTarget.call(reenterData);
    }

    function deliver(bytes32 id, bytes calldata encodedArguments) external returns (bool ok) {
        Callback memory cb = callbacks[id];
        (ok,) = cb.target.call{gas: 200_000}(bytes.concat(cb.selector, encodedArguments));
    }
}

contract MockFactory {
    PoolKey private key;
    address public requester;
    bool public reject;
    bool public exhaustGas;
    uint256 public calls;
    address public reenterTarget;
    bool public reenterSucceeded;

    receive() external payable {}

    function setExhaustGas(bool value) external {
        exhaustGas = value;
    }

    function configure(PoolKey memory key_, address requester_) external {
        key = key_;
        requester = requester_;
    }

    function setReject(bool reject_) external {
        reject = reject_;
    }

    function setReenter(address target) external {
        reenterTarget = target;
    }

    function positionOf(uint64) external view returns (PoolKey memory, int24, int24, address) {
        return (key, -600, 600, requester);
    }

    function claimFees(uint64) external returns (uint256, uint256) {
        if (exhaustGas) {
            assembly ("memory-safe") { invalid() }
        }
        require(!reject, "claim failed");
        ++calls;
        if (reenterTarget != address(0)) {
            (reenterSucceeded,) = reenterTarget.call(abi.encodeWithSignature("distribute()"));
        }
        address t = Currency.unwrap(key.currency0) == Network.IMD
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);
        uint256 imd = IERC20(Network.IMD).balanceOf(address(this));
        uint256 tokens = IERC20(t).balanceOf(address(this));
        IERC20(Network.IMD).transfer(requester, imd);
        IERC20(t).transfer(requester, tokens);
        if (address(this).balance != 0) {
            (bool ok,) = requester.call{value: address(this).balance}("");
            require(ok, "native payment failed");
        }
        return (imd, tokens);
    }
}

/// @dev Accounting mock for failure injection; separate tests use the unmodified v4 PoolManager.
contract MockManager {
    bool public initialized;
    bool public partialFill;
    bool public reject;
    address public locker;
    uint256 public spent;
    uint256 public output;
    uint256 private synced;

    function setInitialized(bool value) external {
        initialized = value;
    }

    function setPartial(bool value) external {
        partialFill = value;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return initialized ? bytes32(uint256(1 << 96)) : bytes32(0);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        require(locker == address(0), "locked");
        locker = msg.sender;
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        locker = address(0);
        return result;
    }

    function swap(PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (BalanceDelta)
    {
        require(!reject && msg.sender == locker, "bad swap");
        spent = uint256(-params.amountSpecified);
        if (partialFill) spent /= 2;
        output = spent * 2;
        int128 debit = -int128(int256(spent));
        int128 credit = int128(int256(output));
        return params.zeroForOne ? toBalanceDelta(debit, credit) : toBalanceDelta(credit, debit);
    }

    function sync(Currency currency) external {
        synced = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    function settle() external view returns (uint256) {
        return IERC20(Network.IMD).balanceOf(address(this)) - synced;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(msg.sender == locker && amount == output);
        IERC20(Currency.unwrap(currency)).transfer(to, amount);
    }
}

contract TestSigner {
    address private immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 65) return bytes4(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        return ecrecover(hash, v, r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0);
    }
}
