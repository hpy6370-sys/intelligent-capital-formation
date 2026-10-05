# Solidity prototype revision: governance and capital safeguards

This document describes the contracts after the 2026-09-27 revision. The
2026-09-08 walkthrough, design proposal, v5 simulation and counterfactual
estimates describe the earlier mechanism. Their figures are not predictions
for this revision.

## Checkpoint lifecycle and rate changes

- A scheduled window can first open 90 days after `closeFunding()`, then 90
  days after the previous window is resolved. A signal can open one earlier.
- Neither path can open before funding closes. A window must be resolved before
  another opens, including when its voting period has expired. Resolution is
  permissionless, so an expired window does not need an administrator.
- Any holder can initiate one ballot per window. Their announced action is
  advisory; voters can choose any of the five actions. The first caller cannot
  lock the window to a harmless option.
- The legacy `newRateDelta` argument must be zero. An increase or decrease
  changes the rate by a protocol-fixed half of the initial rate. The vault
  itself caps the total rate at twice its initial value. An increase that
  reaches the cap is saturated there; another increase at the cap is a no-op,
  so neither case prevents checkpoint resolution.
- If the vault becomes terminal while a ballot is open, the checkpoint can
  still resolve but its action is recorded as `CONTINUE`. The vault rejects any
  later attempt to set a positive stream rate.

## Voting and its tradeoff

Each share at the snapshot supplies one vote. Quorum is 50.01 % of snapshot
total supply in the deployment script; the winning action must also receive
more than half of cast weight. Consequently, a 40 % holder cannot meet quorum
alone and moving 10 ETH of shares into 100 wallets still yields 10 ETH of vote
weight. Shares sent to a new address activate that address's own delegation,
so transfers do not silently remove voting power. The contract retains the
`QuadraticGovernor` name to avoid breaking integrations, but it no longer
implements quadratic voting.

This is token-weighted governance. A holder or coalition with more than half
of the outstanding shares can still control a vote. It does not solve whale
dominance or voter apathy; identity or bond-based voting would require a
separate mechanism and assumptions.

## Rule 2: continuous exit alarm

The vault stores the payout amount in day-indexed buckets. On every rage quit
it sums the current UTC day and preceding 29 calendar days. If that amount is
strictly greater than 25 % of the unreleased balance immediately before the
latest exit, it pauses streaming for up to 60 days. This runs before the first
checkpoint, during voting and between checkpoints. Rage quit remains possible
during a pause. The bucketed window is intentionally calendar-day granular;
near a day boundary its age spans slightly less than 30 exact days.

An active pause cannot be paused again to reset or extend its deadline. If a
checkpoint passes `PAUSE_FOR_AUDIT` while the vault is already paused (for
example by Rule 2), the checkpoint resolves successfully but preserves the
existing pause reason and timeout.

Checkpoint snapshot fields are still emitted/stored for observability, but
they no longer determine the automatic pause. The historical scenario notes
used a different rolling interpretation and must be recalculated.

## Rule 4: vesting-relative terminal threshold

`checkPoolDepletion()` compares the remaining vault balance with the amount
that would still be unvested under the stream. It enters the one-way terminal
state when the balance reaches zero, or when that unvested amount is positive
and the balance is below 10 % of it. Normal vesting alone therefore does not
force terminal when less than 10 % of the initial raise remains. As before,
terminal sets the stream rate to zero; remaining investors may rage quit.

## Verification and next research step

Run `forge test` from this directory. Regression tests cover repeated or
pre-funding checkpoint openings, proposal/action and rate bounds, wallet
splitting, continuous Rule 2, exit-window expiry, and normal vesting under
Rule 4. The existing accounting and terminal-state invariants also run.
On 2026-09-27, Foundry 1.8.3 with solc 0.8.28 reported 84 passing tests,
zero failures, and 10 passing invariant properties (128 runs, depth 64).

The 2026-10-03 contract-hardening changes pin every repository-owned Solidity
file (contracts, interfaces, scripts, and tests) to exact pragma 0.8.28,
validate basis-point constructor parameters, and round the governance quorum
threshold up. A local review run on 2026-10-03 with Foundry 1.8.3 and solc
0.8.28 compiled the hardened tree and passed 95 tests, including 10 invariant
properties (128 runs, depth 64). The earlier 2026-09-27 result predates these
changes; the raw output from the 2026-10-03 run is not checked in.

The v5 Monte Carlo simulator has **not** been revised to use these rules.
Its reported recovery, vote concentration and terminal rates cannot be used
to claim an improvement for the current contracts. The next research step is
to rerun the same agents and failure scenarios under both revisions, with
explicit false-pause and honest-team funding outcomes. This is a prototype,
not an audited deployment.
