// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Immutable deployment choices from the SIMD Vault brief.
library Network {
    address internal constant IMD = address(0x005f7bb59365ce557c26dbcaa4ee9d39a4b95b7127);
    address internal constant INTAKE = address(0x00a43e6f75ee006411f79ac1c84120606c2330de82);
    address internal constant FACTORY = address(0x009c9d2fcb75c2c132c0ac0c42df3819a42347265e);
    address internal constant DEV = address(0x00dfa1f1f6feaa04f7874eff0b7754b7ffaebd8bc0);
    address internal constant MARKETING = DEV;
    address internal constant POOL_MANAGER = address(0x008366a39cc670b4001a1121b8f6a443a643e40951);
    address internal constant ORACLE_SIGNER = address(0x005598aa9146215bc13eb26f2c692ad1461fd32982);
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant LAUNCH_ACTION = bytes32("launch.open@launch-1");
    bytes32 internal constant JOB_ACTION = bytes32("job.open@job-1");
    bytes32 internal constant ORACLE_ACTION = bytes32("oracle.request@oracle-1");
}
