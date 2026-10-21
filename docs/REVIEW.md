# Local adversarial review

This is the implementer's review, not an independent audit. An independent review of the compiled application and the separate Test token/hook launch is still a release responsibility.

## Custody and authorization

- Only the fixed dev can launch/bind, each once. Binding checks the factory requester and the actual initialized TEST/IMD pool. Children trust only their immutable parent, which exposes no forwarding function.
- No contract exposes owner, pause, upgrade, rescue, arbitrary-call, or requester-transfer functionality. Constructor deployment from an unrelated factory is tested on an otherwise empty chain. Runtime/initcode size and the protected floor's forbidden-opcode scan are checked locally.
- All spending entry points have reentrancy guards. The compensation callback is deliberately callable inside the guard only by the fixed manager with a one-shot expected input amount. Both token directions are checked against unmodified v4 core.
- Token transfer/payment failures revert accounting and cooldown changes. Native payouts are accepted by SIMDVault and forwarded to the specified marketing wallet; if that recipient rejects ETH, the ETH stays in the vault for the next week and the IMD split and burn still complete.
- The launch ask names a failure function (Intake version 2). Only the Intake can call it, only for the vault's own pending request, and never after binding; it reopens the one-time `launch` and moves nothing. The result function only records the plane's hash and URI.

## Accounting and oracle failure paths

- Every weekly percentage is calculated from the same pre-split balance. Oracle fees are paid only from the new epoch's own pot (deposit plus rolled-in carry) or a retry sponsor. A sponsored retry adds a request; it never invalidates the pending one, and an epoch accepts exactly one answer. Aggregate epoch liabilities are continuously checked against the actual IMD balance in stateful invariants.
- JobsVault enforces only the brief's per-wallet rule (spot balance, 24-hour cooldown). A vault-wide cap was tried and removed: one bag moved through fresh wallets fills it and then every other eligible holder is refused. The remaining budget-capture property of the spot-balance rule is documented in the README for the requester.
- Per-epoch claimed totals, original snapshot budgets, closed flags and per-account flags prevent oversized/double claims from spending another epoch or rollover carry. Carry is allocated with a new snapshot so already-published entitlements never change.
- Callback sender, known request, immutable question hash, window, chain, panel, answer shape/type, EIP-712 signature and replay protection are checked. Signed timestamps are checked for expiration and future issuance. The signature is a trust boundary: a compromised signer/panel can still allocate that epoch's allowed pot incorrectly.
- Failed or absent oracle responses do not block weekly splitting. Sponsor-funded retry and permissionless rollover cover liveness. Absolute deposit-block admission and public proof publication still require functioning off-chain services.
- The caught factory fee claim and initial oracle request have explicit gas caps. Tests exhaust their forwarded gas and confirm the remaining split and burn still complete with an adequately funded transaction gas limit.

## Buyback and compensation

- The pool key comes from the launch factory. V4 deltas must spend exactly the expected IMD and produce positive TEST; settlement amount and actual before/after token balances are checked. A partial/reverted swap leaves the tranche available for retry.
- Frozen initial budget, integer tranche cap, ten-call ceiling, and ten-minute spacing are tested with the supplied fuzz seed and stateful sequences. Strict cap dust and later donations are permanently locked by design; there is no unilateral way to redirect them.
- The production root/total/count are constants. Test-only synthetic proofs cover pro-rata and duplicate/bad-proof handling; a valid leaf from the actual 62-wallet dataset cannot be asserted without that dataset. The proof tool refuses to output compensation proofs unless the whole dataset reproduces the commitment.
- Each tranche swaps inside a ±1.5% sqrt-price band around a reference recorded at an earlier timestamp; an out-of-band price swaps nothing and moves the reference by at most one band step per ten minutes, clamped to the band edge. The real-PoolManager tests cover the same-block and next-block push, the step rate, and the fill after the price returns. Tranches are still not an oracle-backed slippage guarantee: a price held out of band for long enough (exposed to arbitrage all the while) can make later tranches pay up to one band above it. Low liquidity, a malicious launch hook, or token transfer restrictions can still cause poor execution or reverts. These are limitations of the commissioned fixed pool design, not hidden keeper controls.

## Verification scope

Tests cover unauthorized/repeated setup, rejected requester/token/pool binding, payment failures and exact approvals, splits and dust, factory failure, native fee payout, burns, timing boundaries, six-decimal job thresholds, oracle protocol vectors and signature failures, stale/replayed/incorrectly paired answers, 200k callback gas, claims/rollovers, compensation timing/accounting/proofs, reentrancy, deployment constraints, and real v4 swaps in both directions.

The optional Robinhood fork tests retain the real Intake, factory, IMD and PoolManager bytecode. They create a synthetic pool only within fork state. They do not validate the Test launch's as-yet-unsupplied token/hook bytecode, live oracle panel consensus, admission wording acceptance, or reconstruct the original migration dataset. No production deployment, signing, or transaction broadcast is part of this deliverable.
