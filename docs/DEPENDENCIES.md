# Vendored dependencies

All dependencies are ordinary files, not git submodules. No install or fetch is needed during compilation or tests.

| Source | Version/revision | Included |
| --- | --- | --- |
| OpenZeppelin/openzeppelin-contracts | v5.5.0 (`fcbae5394ae8ad52d8e580a3477db99814b9d565`) | contracts and MIT license |
| foundry-rs/forge-std | v1.9.7 | src and Apache/MIT licenses |
| Uniswap/v4-core | v4.0.0 | src and licenses; production uses interfaces/types/internal libraries, tests also use PoolManager |
| transmissions11/solmate | `89365b880c4f3c786bdd453d4b8e8fe410344a69` | Owned.sol (MIT) and upstream license notice, used by the real v4 test PoolManager |
| IdentityMD OracleAttestation / OracleQuestion | task's pinned oracle-consumer reference | canonical Solidity copied into src/oracle; protocol vector copied into tests |

Upstream repositories: https://github.com/OpenZeppelin/openzeppelin-contracts, https://github.com/foundry-rs/forge-std, https://github.com/Uniswap/v4-core, https://github.com/transmissions11/solmate.

Factory ABI used in fork tests was read from the verified source at https://robin.etherscan.io/address/0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e#code. Its `positionOf` tuple and `claimFees` signatures match the brief. No copied factory implementation is deployed by this project.
