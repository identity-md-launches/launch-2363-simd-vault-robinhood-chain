# SIMD Vault

Four contracts for Robinhood Chain (4663), with no owner, admin, proxy, upgrade, pause, rescue, arbitrary execution, or fee-recipient setter. Deploy **only `src/SIMDVault.sol:SIMDVault`**, with no constructor arguments and no ETH. Its constructor creates and permanently links `HolderRewards`, `JobsVault`, and `CompensationVault`. Deploying separate copies of the children does not configure this system.

The constructor does not call any existing chain contract. The dev has exactly two one-time powers: pay for a launch and bind an initialized factory position whose requester is this vault. Neither permits withdrawing money or transferring the factory requester role.

## Build and verification

```sh
forge build
FOUNDRY_FUZZ_SEED=0x547f4d53a2f8e5ab7d131094c43e5240c29a493ed4b594ab5c19e1e9aaafa71e forge test
forge fmt --check
python3 -m unittest discover -s tools -p 'test_*.py'
```

Solidity 0.8.26, Cancun, optimizer 200 runs, via-IR, and `bytecode_hash = "none"` are pinned in `foundry.toml`. All imported dependencies are ordinary vendored source files under `lib/`; there are no submodules, package installations, FFI, or filesystem permissions. The default tests need no network or environment variables. `via_ir = true` also avoids the earlier attempt's stack-depth build failure.

Run the optional live-state integration suite explicitly:

```sh
forge test --match-contract RobinhoodForkTest \
  --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

This uses the real Intake, factory, IMD, and PoolManager code. It impersonates the factory's deployer **only in the local fork** to create a synthetic test pool, then exercises real `positionOf`, requester validation, ten buybacks, `claimFees`, the weekly split, and burning. It sends no transactions. Without an active fork, this suite skips in `setUp`; all unit, fuzz, invariant, and local v4 integration tests still run. No RPC credentials are stored. The public endpoint prunes historical state: use the latest head there, or add `--fork-block-number` with an archival provider for a reproducible historical run.

Tests never mock or etch ArbSys. They use `vm.roll` and `vm.warp`; timestamp/block assertions use Foundry getters to avoid Solidity caching those values across cheatcodes. `snapshotHead()` first calls ArbSys with a low-level static call, accepting a precompile without EVM bytecode. A plain offline EVM with no ArbSys implementation falls back to `NUMBER`; an existing but failing implementation reverts. On the live Orbit chain, ArbSys supplies the L2 block, not the L1 `block.number`. The fork suite aligns its test block with that L2 head before exercising snapshots.

## Fixed deployment parameters

| Parameter | Value |
| --- | --- |
| IMD | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| Intake v2 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| Launch factory | `0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e` |
| Uniswap v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| Dev and marketing, each | `0xdfa1f1f6feaa04f7874eff0b7754b7ffaebd8bc0` |
| Oracle signer, from supplied protocol reference | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| Token burn destination | `0x000000000000000000000000000000000000dEaD` |
| Weekly interval | 7 days |
| Rollover eligibility | 28 days after epoch creation |
| Job holding threshold / cooldown | 1,000,000 whole TEST / 24 hours per wallet, exactly the brief's rule; no vault-wide cap |
| Oracle panel / quorum / answer validity | 30 / 20 / 7 days |
| Sponsored oracle retry delay | 1 day after the previous paid request; immediate if none succeeded. Earlier requests stay valid; the first answer wins |
| Maximum raw Intake body | 16,384 bytes |
| Isolated factory claim / initial oracle request gas caps | 1,000,000 / 3,000,000 |
| Buyback wait / interval / cap | 30 minutes after binding / 10 minutes / 10 tranches |
| Buyback price band / window | `PRICE_BAND_BPS` = 150 (±1.5% sqrt price, about ±3% price) around a reference recorded at an earlier timestamp; the reference follows an out-of-band price by at most one band step per 10 minutes / `BUYBACK_WINDOW` = 3 days after the wait, then anyone can end the buyback |

Action IDs are zero-padded ASCII `bytes32("launch.open@launch-1")`, `bytes32("oracle.request@oracle-1")`, and `bytes32("job.open@job-1")`, not hashes. Every payment reads `priceOf`, rejects a zero/unsold price, uses an exact allowance, and clears any remaining allowance. Fixed protocol addresses and signer deliberately follow the brief's no-admin requirement rather than the reference examples' configurable ownership model. The launch ask uses Intake version 2's `requestWithFailure` (the fork suite confirms the live Intake accepts it) so that a launch the plane refuses or ends without a result reopens the one-time call; jobs and oracle asks use plain `request`.

## Launch and funding responsibilities

1. Deploy SIMDVault; record its three immutable child addresses. Fund **SIMDVault itself** with enough IMD for the live launch price.
2. The named dev calls `launch(bytes body)` once. The body must describe the Test token launch, its supply, TEST/IMD pool, the intended hook, and the allocations. Validate the raw JSON with IdentityMD's admission service before payment: this contract limits length but does not parse JSON. A refused off-chain launch (status 1) or one that ends without a result (status 2) still spends the fee, but the Intake reports it to `onLaunchFailure`, which reopens the one-time call for the dev's own pending request only, so the vault is never left unbindable. A result (status 0) is recorded in `launchResultHash` and the `LaunchCompleted` event; nothing moves on either call, and neither can reopen a launch that has been bound. If the Intake's failure call itself is lost (it is attempted once, under 200,000 gas), the launch stays marked as pending; that is a liveness assumption on the plane's writer, and the vault then needs a fresh deployment.
3. The launch factory and launch's hook must be configured by that separate Test launch to send **10% of the supply and all intended anti-sniper IMD to `compensationVault()`**. This application neither mints a token nor installs a hook. The Test supply, launch price, and hook economics are not guessed here; they belong in the dev's launch body. The factory requester must remain SIMDVault. The factory's independent network/swarm allocations still apply.
4. After the factory opens the pool, the dev calls `bindLaunch(number, token)`. This checks the factory requester, the sorted TEST/IMD currencies, an initialized pool, and the token's decimals. It stores the pool key, including its actual hook and fee, without caller-selected swap routing. All three child bindings are atomic and permanent.
5. Anyone can call `distribute()` immediately after binding and then at least 7 days after the preceding successful distribution. Keepers must submit transactions; these contracts do not run on a timer.

The first distribution has no additional seven-day deployment wait. A failed factory fee claim is caught; already-held funds are still distributed. Whole IMD balances split as 40%, 25.72%, 17.14%, 17.14%, each rounded down independently. Dev and marketing happen to be the same wallet, so it receives both transfers. At most three IMD base units remain as rounding dust. All TEST held by SIMDVault goes to the burn destination; this is a transfer, not an ERC20 `totalSupply` reduction. All native ETH goes to marketing; if that push is rejected (marketing wallet becomes rejecting code), the ETH stays in the vault for the next week and the IMD split and burn still complete. There are no conversions or other withdrawals.

IMD and TEST must have ordinary, non-rebasing ERC20 accounting. SafeERC20 supports tokens with no boolean return; a false return/revert rolls back the operation. Transfer taxes or rebases are not supported. JobsVault reads decimals once when bound, including six-decimal tokens, rather than assuming the threshold is always `1e24` base units.

## Weekly snapshots, claims, and rollover

Each distribution transfers the holder share and calls `onDeposit` atomically. The new epoch records the **end-of-deposit-block** L2 snapshot. Its reward budget is its own pot (this deposit plus any carry that rolled into it) less the live oracle price, paid from that pot and never from another open epoch's reserve. An epoch funded by carry alone, after a week with no fees, therefore still asks for its root. If the pot cannot cover the price or the Intake reverts, the epoch retains its money and records a deferred request; the other weekly payouts and burn continue. Anyone can sponsor `retryOracle(epoch)` by approving HolderRewards for one current oracle price. Retries do not reduce pots, change the snapshot, or replace a received root, and they do not invalidate the earlier request: every request of an epoch asks the same question over the same block, the first answer the Intake delivers installs the root, and later answers to that epoch revert `AlreadyAnswered`. A sponsor paying for retries can therefore never delay the pot's own answer.

The snapshot block is the block of the permissionless `distribute()` call, as the brief specifies ("at the deposit block"). Whoever calls `distribute()` chooses that block, so a wallet that holds tokens across exactly that block is in the snapshot even if it buys just before and sells just after, at the cost of two swap fees and the price impact of a position large enough to matter. Buying just before a *claim* gains nothing. Moving the snapshot to an earlier or unpredictable block is a design change the requester has not asked for; it is listed here as a known property rather than a defect.

`question(epoch)` and `oracleBody(epoch)` expose the exact request. The oracle enumerates token Transfer recipients/senders, verifies their historical balances, and excludes AMM pool reserves, the PoolManager, factory, all four application addresses, zero, and the burn address. LP owners remain eligible for tokens in their own wallets. The tree commits the **IMD entitlement derived from each snapshot balance**: `floor(snapshotPot * holderBalance / totalEligibleBalance)`. It is not based on current holdings when claiming. A buyer after the snapshot cannot use another account's entitlement.

Leaves are `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`, where `amount` is the IMD entitlement in base units. The tree uses OpenZeppelin StandardMerkleTree's default sorted leaves and sorted-pair internal hashing. `claim(epoch, amount, proof)` transfers to `msg.sender` once. Both `pot` and the immutable `snapshotPot` bound aggregate claims. Even a wrongly oversized signed tree cannot spend another epoch's reserve or unallocated rollover carry.

The callback takes the canonical 15-field `OracleAttestation`, verifies its EIP-712 signature in HolderRewards' own domain, checks Intake as caller, the locally-created request ID, question hash, exact chain/block window, answer type, and panel strength. It consumes the oracle UUID once and does not transfer funds. Protocol digest/signature/question-hash vectors are included in tests; callbacks are also tested under the 200,000 gas stipend.

After 28 days anyone can `rollover(epoch)`. Claims remain possible until rollover actually closes the epoch. Exactly `pot - claimed` becomes carry in the current epoch, with no token movement or fee. An existing Merkle tree cannot fairly be enlarged after some holders claimed, so that carry is excluded from its old entitlements. The next weekly deposit moves it into the new epoch's snapshot budget. Rolling the latest epoch opens an empty current carry epoch; the next distribution gives that carry a new snapshot. Old callbacks and claims cannot revive a rolled epoch. No oracle answer is required to recover unanswered/empty-root epochs this way.

The panel processes requests asynchronously; the deposit block must be at least five L2 blocks deep when the service resolves the absolute window. This code retains the requested deposit block instead of moving the snapshot earlier. If admission happens too early, a sponsor can retry after confirmations. Operators must publish the returned tree/proofs. The public `/requests/check` base URL was not supplied; the attempted `api.identity.md` endpoint was rejected by this machine's network policy as resolving to a local/private address, so live wording-screen acceptance is **not claimed**. Check the exact `oracleBody` with the public admission service before release. The on-chain fork verifies that Intake accepts the payment/body bytes; it does not run the off-chain panel.

## Holder jobs

`requestJob(body)` checks the caller's current TEST balance, per-wallet 24-hour cooldown, and live price. It pays from JobsVault and requests no callback. A reverted payment consumes no daily slot. The caller supplies the whole raw body and bears responsibility for its content/validity; an off-chain refusal does not refund the vault. The payer/project owner is JobsVault, and only opening jobs is supported. There is no withdrawal.

The rule is exactly the brief's: "any wallet holding at least 1,000,000 of the launched token can call `requestJob` at most once per 24 hours". It is a spot balance with a per-wallet cooldown, and nothing vault-wide: a vault-wide cap (per block or per day) is filled by one holder moving a bag through fresh wallets and then refuses every other eligible holder, which contradicts the brief and was reported as a denial of service in review. Known property of the requested rule: the same 1,000,000 tokens moved between wallets can open more than one job per day, in separate blocks or in one transaction, so one holder can spend the week's jobs budget on their own jobs. The IMD goes to the Intake as job payments, not to that holder. Mitigations all change the requester's rule or need data a plain ERC20 cannot give: a vault-wide cap (monopolizable, see above), eligibility from a past snapshot (the launched token has no balance checkpoints), a holding-age requirement, or a stake-to-request escrow. The requester has to choose one of those for the rule to change; until then the per-wallet rule stands.

## Compensation and buyback

The immutable commitment is:

```text
root:        0xe84256f66c03a4565c29addd32238495f1a0d5dda8c618e5f81ff8637c296347
totalWeight: 201084680772174552329559308
wallets:     62
migration:   0xE132be23CE6255930556a45406075E62fb6340C0
snapshot:    26213125
weight:      min(total SIMD sent to migration wallet after snapshot, snapshot SIMD balance)
```

Compensation leaves use the same double-hash format, with `weight` instead of reward `amount`. No setter changes this list. The assignment supplies the commitment, not the 62 preimages; no addresses or proofs have been invented. Positive-payment tests use a clearly marked test-only derived fixture with synthetic leaves; separate tests pin the production constants and reject unlisted production proofs. Operators must obtain/reconstruct and publish the actual dataset and proofs, verifying all three constants before batching payments.

`buyback()` uses the exact bound Uniswap v4 pool, an authenticated unlock callback, exact-input negative `amountSpecified`, and v4 sync/transfer/settle/take accounting. Direct/replayed callbacks revert. Every swap carries a `sqrtPriceLimitX96` at the edge of a ±`PRICE_BAND_BPS` band around a reference price recorded at an *earlier timestamp* (at binding, then after each tranche). If the pool price is outside the band when `buyback()` is called, nothing is swapped; instead, at most once per `TRANCHE_INTERVAL`, the reference moves one band step towards the pool price (it is clamped to the band edge, never set to the pushed price). A caller therefore cannot push the price and trigger a tranche in the same transaction or the next block: to make a tranche fill at a pushed price, someone has to hold that price against arbitrage for ten minutes per 1.5% of sqrt price (about 3% of price), and the tranche then pays at most one further band above the reference. Genuine moves of more than the band simply delay tranches by one interval per step; the 3-day window still ends the buyback. A fill that stops at the band edge spends only what the pool consumed and counts as a tranche. A swap that buys zero tokens (dust tranche, empty range) ends the buyback. A 30-minute wait starts at **binding**, which must follow pool initialization: the factory/PoolManager ABI exposes no trustworthy initialization timestamp, so this conservatively waits at least 30 minutes after opening, potentially longer. It does not guess a hook timestamp ABI.

The first call freezes the IMD budget. Each successful swap spends `floor(initialIMD / 10)` at most, with ten minutes between successful calls and at most ten swaps. All acquired TEST stays in CompensationVault. Later IMD donations cannot increase the budget or restart buyback. Strict integer 10% caps across at most ten calls necessarily leave `initialIMD % 10` base units (at most nine); they remain locked. While the balance is below ten base units, `buyback()` reverts `NothingToBuy` without starting, so an anti-sniper fee that arrives late is still bought. `BUYBACK_WINDOW` (3 days) after the wait, any call ends the buyback so the airdrop always opens. IMD that is unspent then (partial fills, late arrivals) stays locked in the vault; nothing else can move it.

After buyback completes, anyone batches `airdrop(accounts, weights, proofs)`. The first successful, nonempty batch freezes the whole current TEST balance; a zero-balance start reverts. Each valid account receives `floor(frozenTokenBalance * weight / totalWeight)` directly, once. Bad proofs, changed weights, and duplicates are skipped; mismatched array lengths revert. Later TEST donations and division dust remain locked and cannot change later claimants' allocations. There is no deadline, sweep, or refund-to-caller path.

Tranching bounds the amount exposed per transaction and the price band bounds what each tranche can pay relative to a price that predates the call; neither is an oracle-backed price guarantee, because the brief names no trusted price feed or TWAP. Keepers are responsible for monitoring liquidity and execution conditions. Oracle correctness/signing, valid proof availability, the fixed token contracts, the fixed external protocols, and recipient acceptance of ETH remain trust/liveness assumptions. See `docs/REVIEW.md` for the review record and deployment limitations.

## Proof tooling

`tools/merkle.py` needs only Python's standard library and Foundry's `cast`. It performs no network calls and uses no keys.

```sh
python3 tools/merkle.py compensation actual-migration-weights.json > compensation-proofs.json
python3 tools/merkle.py rewards eligible-snapshot-balances.json --pot 1000000000000000000 > rewards-proofs.json
```

Inputs are arrays of `{ "account": "0x...", "weight": "integer" }` or `{ "account": "0x...", "balance": "integer" }`. The compensation command refuses any dataset whose wallet count, total, or root differs from the fixed commitment. Reward inputs must already reflect the exact snapshot block and exclusion rules; the tool does not determine which addresses are pools. Use the epoch's actual `snapshotPot` as `--pot`, never its later carry-inclusive `pot`. The output contains one proof per account. These commands build evidence; only the authenticated oracle callback can install a weekly root.
