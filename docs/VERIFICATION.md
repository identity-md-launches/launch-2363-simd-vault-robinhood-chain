# Local verification record

Completed on 2026-10-21 with Forge 1.8.3 and the repository-pinned Solidity 0.8.26 configuration. These are local results, not an independent audit or attestation.

| Check | Result |
| --- | --- |
| `forge build --sizes` | Pass |
| `forge fmt --check` | Pass |
| `forge test` with the supplied seed below | 51 passed, 0 failed; optional fork suite skipped without an active fork |
| Explicit Robinhood public-RPC fork suite at its latest head | 3 passed, 0 failed, 0 skipped |
| `python3 -m unittest discover -s tools -p 'test_*.py'` | 4 passed |
| Stateful accounting/custody/tranche invariants | 64 runs, 2,048 handler calls, 0 reverts |

Fuzz seed: `0x547f4d53a2f8e5ab7d131094c43e5240c29a493ed4b594ab5c19e1e9aaafa71e`. Each of the three arithmetic fuzz tests ran 256 cases. Production runtime sizes: SIMDVault 5,200 bytes, HolderRewards 16,135, JobsVault 2,422, CompensationVault 6,887. SIMDVault initcode, including all child deployments, is 32,986 bytes. No size-limit override is configured.

The fork suite retained live bytecode at all four fixed protocol addresses and successfully tested real Intake payment, factory requester validation, a fork-local factory launch, ten v4 buyback swaps, real factory fee payout, the weekly split, and burning. The public RPC pruned the initial historical block during development, so the final successful run used its latest head; use an archival RPC to replay a fixed historical block. Nothing was broadcast.

The old stack-depth failure is addressed by the pinned via-IR build. The old HolderRewards deposit failure was reproduced as an empty ArbSys response in the local EVM and repaired with a low-level precompile probe that supports both the actual Orbit precompile and an empty offline EVM. Tests never etch or mock ArbSys. Foundry block/time getters also avoid optimizer assumptions across `vm.roll` and `vm.warp`.

Still outside the verified scope: live off-chain oracle wording admission/consensus, independently recovered preimages for the supplied compensation commitment, and the separate Test token/hook's launch economics. `README.md` and `docs/REVIEW.md` explain these boundaries and the operational responsibilities. The attempted oracle preflight endpoint was blocked by network policy; no claim of successful wording-screen validation is made.
