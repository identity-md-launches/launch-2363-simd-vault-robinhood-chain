# SIMD vault test coverage

All test and fixture changes are under `test/`; the separately requested `.imd-findings.json` reports the tooling defect. Application contracts, configuration, and dependencies are unchanged. The default suite uses the vendored dependencies and needs no network.

## Coverage added to the accepted suite

| Test file | Additional checks |
| --- | --- |
| `AdversarialLifecycle.t.sol` | Unauthorized launch/bind fuzzing; body limits and live pricing; rollback when a later child rejects binding; rollback after burn or native payment failure; maximum uint256 splitting; dust carried into the next week; invalid signed oracle fields; duplicate oracle UUIDs; retry failure and changed pricing; frozen snapshot during retries; deferred requests; zero claims; out-of-order rollovers; holding checks across decimals 0–71 and after transferring tokens away. |
| `CompensationFailures.t.sol` | Malformed batches; atomic rollback when the second recipient rejects payment; airdrop reentrancy; repeated and duplicate entries in either order; arbitrary unproven claims against the production root; token/IMD transfer failures during first and later tranches; inputs that exceed v4's signed delta range. |
| `JobsStateful.t.sol` | Four actors move token holdings, fund the jobs vault, advance time, change external Intake price/availability, and submit valid/invalid requests. An independent model predicts every success or revert, tracks each wallet's cooldown, and reconciles every IMD payment. |
| `CompensationStateful.t.sol` | Random funding, time advances, successful/reverting buybacks, and valid/invalid/duplicate/reverting airdrop batches against the actual child deployed by SIMDVault. Independent ledgers reconcile both assets, frozen budgets, tranche timing, and two real beneficiaries' payments. `afterInvariant` finishes every random prefix and checks both can still be paid. |
| `MigrationClaims.t.sol` | All 62 actual historical beneficiaries and proofs match the committed root and total. Production-instance payouts after ten buybacks, multiple batches, post-start donations, repeated claims, corrupted proofs, changed weights, and 1,000 allocation/order fuzz cases. |
| `VaultInvariants.t.sol` | Extends the existing multi-contract handler with factory/direct IMD, token and ETH receipts and distribution attempts before the cooldown. Checks native/token custody, zero residual Intake approvals, reward carry accounting, and closed/settled requests in addition to IMD solvency. |
| `RobinhoodFork.t.sol` | Adds live Intake job eligibility/cooldown tests, oracle payment and callback authorization, and native receipt/distribution. Supports an explicitly configured RPC while still skipping cleanly offline. |

New fuzz properties run 1,000 cases each. Each of the three invariant suites runs 256 sequences of 64 handler calls, with `fail-on-revert = true`. Expected failures are checked inside the handlers; unexpected reverts fail the suite. Counts are stored as inline Foundry configuration in the tests.

The existing tests continue to cover the weekly percentages and burn, factory claim failure/gas exhaustion, exact approvals, one-time initialization, oversize and double claims, the 28-day rollover, canonical oracle vectors and the 200,000-gas callback, 30-minute/10-minute buyback boundaries, production commitment constants, and actual v4 PoolManager swaps in both currency orders.

## Reproduction

```sh
forge build
FOUNDRY_FUZZ_SEED=0x547f4d53a2f8e5ab7d131094c43e5240c29a493ed4b594ab5c19e1e9aaafa71e forge test
```

The default configuration runs on chain ID 4663. Tests use `vm.roll` and `vm.warp`, never a mock at ArbSys address 100. The existing oracle protocol-vector test temporarily uses the vector's canonical chain ID to check its published signature.

The fork suite retains real bytecode at the supplied Intake, factory, IMD and PoolManager addresses. It impersonates the factory's deployer only inside the fork to create a test position; it never broadcasts transactions. To run against the public RPC:

```sh
FOUNDRY_FUZZ_SEED=0x547f4d53a2f8e5ab7d131094c43e5240c29a493ed4b594ab5c19e1e9aaafa71e \
forge test --match-path test/RobinhoodFork.t.sol \
  --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

Alternatively provide `ROBINHOOD_RPC_URL` to the test process and, optionally, `ROBINHOOD_FORK_BLOCK` for an archival RPC. Missing configuration skips the fork suite; a configured RPC failure or assertion failure is not silently skipped. No test calls `vm.setEnv` or commits credentials.

## Verified results

Checked on 2026-10-21 with Forge 1.8.3, Solc 0.8.26, the unchanged project configuration, and the exact fuzz seed above:

| Check | Result |
| --- | --- |
| `forge build` | Pass |
| Default `forge test` | 81 passed, 0 failed; optional fork setup skipped without RPC configuration |
| Explicit Robinhood fork suite, public RPC at latest head | 5 passed, 0 failed, 0 skipped |
| Stateful suites | 49,152 random handler calls total, 0 unexpected reverts; terminal compensation checks also pass |
| Real migration fixture | All 62 proofs and payouts pass; raw transfer/snapshot evidence reconciles exactly |
| Existing compensation proof CLI | Reproduced rejection of the valid dataset; reported separately, tool unchanged |

## Limits

The migration preimages were independently recovered from public Ethereum records through Alchemy. Token `0xbb0c1f82a2ea0253ea3d91c2f05caded82133415` sent 65 transfers from 63 senders to the specified migration wallet after snapshot block 26213125. Capping each sender's total at its historical snapshot balance leaves 62 positive weights and exactly `201084680772174552329559308` total weight. The one zero-weight sender is recorded in the evidence but excluded from the tree. Every supplied proof verifies against the specified root, and the production CompensationVault pays every beneficiary in the tests.

`fixtures/migration-evidence.json` records transaction hashes, raw transfer values, historical balances, and block hashes. `fixtures/migration-weights.json` is the eligible dataset; `fixtures/MigrationClaims.sol` embeds the resulting proofs so no network, FFI, runtime JSON reads, or new filesystem permissions are needed. The committed tree sorts leaves, hashes sorted pairs, and promotes an unpaired node unchanged. This differs from OpenZeppelin StandardMerkleTree's complete-tree layout while remaining fully compatible with OpenZeppelin MerkleProof.

The existing synthetic two-leaf fixture remains in arithmetic and fault-injection unit tests. Production-root coverage no longer depends on it. The stateful compensation tests also use the real root and real proofs.

The repository's compensation proof CLI rejects this matching dataset because it always builds the complete-tree layout. This separate, low-severity tooling defect is reported in `.imd-findings.json` with an offline reproduction; the tool is outside this assignment's permitted edit paths. No test asserts that rejection is correct.

The separate Test token/hook launch is not provided. Funding is simulated in local tests, so its intended 10% allocation and actual anti-sniper-fee delivery are not verified. Live fork tests cover on-chain payment and integration, not off-chain admission, panel consensus, or publication of Merkle proofs.
