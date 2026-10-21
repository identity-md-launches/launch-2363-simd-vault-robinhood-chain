// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The Identity.md Intake as these contracts call it.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId);
}

/// @notice Intake version 2's ask with a failure function: `onFailure` names a second function on
/// `callback.target` that the plane calls when the ask is refused (status 1) or ends without a
/// result (status 2). Kept apart from `IIntake` so a stand-in that implements only `request` still
/// satisfies that interface.
interface IIntakeWithFailure {
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        IIntake.Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId);
}
