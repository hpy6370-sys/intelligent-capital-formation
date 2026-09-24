# LAF Solidity Prototype: Working Flow

Sources: `02-solidity/`, package of 2026-09-08.

**LAFVault** (Layer 1) holds all deposited ETH and streams it to the team at `ratePerSecond`; **RageQuitModule** (Layer 2) lets any holder burn `LAFShareToken` for a pro-rata share of the unreleased balance; **QuadraticGovernor** (Layer 3) runs 14-day sqrt-weighted checkpoint votes and applies the result to the vault; **SignalMonitor** (Layer 4) aggregates five health metrics from registered reporters and can only ask the governor for an early checkpoint. Calls flow one way: RageQuitModule to LAFVault (`RAGEQUIT_ROLE`), QuadraticGovernor to LAFVault (`GOVERNOR_ROLE`), SignalMonitor to QuadraticGovernor (`SIGNAL_ROLE`); the vault mints and the module burns `LAFShareToken` (`MINTER_ROLE`, `BURNER_ROLE`). ETH sits only in LAFVault; SignalMonitor has no role on it and no reference to it.

## Deployment order (`DeployLAF.s.sol`)

Every constructor grants `DEFAULT_ADMIN_ROLE` to the deployer; "later" means the step 6 `grantRole` block.

| # | Contract | Constructor arguments | Roles granted |
|---|---|---|---|
| 1 | `LAFShareToken` | `admin`=deployer | later: `MINTER_ROLE`: vault, `BURNER_ROLE`: rageQuit |
| 2 | `LAFVault` | `admin`=deployer, `team`=`TEAM_ADDRESS` env or deployer, `_shareToken`, `_rageQuitAutoPauseBps`=2500, `_poolDepletionBps`=1000, `_maxPauseDuration`=60 days | `TEAM_ROLE`: team; later: `GOVERNOR_ROLE`: governor, `RAGEQUIT_ROLE`: rageQuit |
| 3 | `RageQuitModule` | `_vault`, `_shareToken` | none |
| 4 | `QuadraticGovernor` | `admin`=deployer, `_vault`, `_shareToken`, `_checkpointInterval`=90 days, `_checkpointWindowDuration`=14 days, `_quorumBps`=2000, `_majorityBps`=5000, `_defaultPauseResponsePeriod`=30 days, `_signalRateLimit`=30 days | later: `SIGNAL_ROLE`: monitor |
| 5 | `SignalMonitor` | `admin`=deployer, `_governor`, `_warningCombinatorThreshold`=2, `_criticalCombinatorThreshold`=1, `_quorum`=1, `_reportWindow`=365 days | reporters via `addReporter(address)` afterwards |

## Lifecycle

Lines refer to `test/integration/CrossLayerTest.sol` unless stated; tests fund via `_fundAndClose()` (`test/LAFTestBase.sol` lines 97-109: alice 50, bob 30, carol 20 ETH).

### 1. deposit
Anyone before funding closes. `function deposit() external payable` (LAFVault.sol:103). `totalDeposited+=msg.value`; `shareToken.mint` 1:1 with self-delegation. Emits `Deposited(investor, amount, sharesMinted)`. Test: LAFTestBase.sol:99-105; StressTest.sol:64, 72.

### 2. closeFunding
Admin only. `function closeFunding(uint256 _ratePerSecond) external onlyRole(DEFAULT_ADMIN_ROLE)` (LAFVault.sol:120). Sets `fundingClosed`, `ratePerSecond`, `streamStartTime`, `lastClaimTime`. Emits `FundingClosed(ratePerSecond)`. Test: LAFTestBase.sol:108.

### 3. claim
Team only. `function claim() external onlyRole(TEAM_ROLE) nonReentrant` (LAFVault.sol:137). Reverts while paused or terminal. Pays `claimable()`: streamed (paused time excluded) minus `totalClaimedByTeam`, capped at `unreleasedBalance()`. Updates `totalClaimedByTeam`, `lastClaimTime`. Emits `Claimed(team, amount)`. Test: `test_integration_worstCaseMaliciousTeam` line 243.

### 4. rageQuit
Any holder, any time, even paused or terminal. `function rageQuit(uint256 shareAmount) external nonReentrant` (RageQuitModule.sol:33). `payout=unreleasedBalance()*shareAmount/totalSupply()`; burns shares first, then `withdrawForRageQuit(holder, payout)` (LAFVault.sol:210) adds to `totalExitedViaRageQuit` and `cumulativeRageQuitInWindow`, transfers the ETH, and applies Rule 2: if `cumulativeRageQuitInWindow` now exceeds `rageQuitAutoPauseBps` of `unreleasedBalanceAtOpen` (after a window has opened) it sets `paused`, `pausedReason=RAGE_QUIT_THRESHOLD`, `pauseResponsePeriod=maxPauseDuration`. Emits `RageQuit(holder, sharesBurned, payout)` and, on breach, `RageQuitThresholdBreached(cumulativeInWindow, thresholdBps)`. Test: `test_integration_massRageQuitCrossesThresholdDuringOpenCheckpoint` line 149.

### 5. openCheckpointWindow, or SignalMonitor.evaluate
Scheduled, anyone: `function openCheckpointWindow() external returns (uint256 id)` (QuadraticGovernor.sol:98). Reverts `IntervalNotElapsed` within `checkpointInterval` of the previous resolution (first window ungated). `_openWindow` writes `checkpoints[id]` (`windowEnd=now+checkpointWindowDuration`, `snapshotBlock=block.number-1`), increments `nextCheckpointId`, and calls `vault.markCheckpointWindowOpen(id)` (LAFVault.sol:199), which snapshots `unreleasedBalanceAtOpen` and zeroes `cumulativeRageQuitInWindow`. Emits `CheckpointWindowOpened(id, SCHEDULED)`. Test: `test_integration_rageQuitDuringActiveVote_doesNotBreakTally` line 64.

Signal path: registered reporters call `function reportMetric(uint8 metricId, uint256 valueBps) external onlyRole(REPORTER_ROLE)` (SignalMonitor.sol:181), which stores `submissions[metricId][reporter]` and recomputes the metric from submissions no older than `reportWindow`: fewer than `quorum` clears the flags, otherwise their lower median sets `lastValueBps`, `warningActive`, `criticalActive` against the thresholds. Emits `MetricReported(metricId, valueBps, reporter)`, plus `MetricWarning` / `MetricCritical` when a flag turns on. Anyone then calls `function evaluate() external returns (bool triggered)` (SignalMonitor.sol:201): recomputes all five and, if `warningCount()>=2` or `criticalCount()>=1`, tries `governor.triggerEarlyCheckpoint()`; on success emits `EarlyCheckpointRequested()`, on refusal returns false. Test: `test_integration_signalTriggersCheckpoint_thenAuditPassesAndPauses` lines 22-27.

### 6. triggerEarlyCheckpoint
SignalMonitor only. `function triggerEarlyCheckpoint() external onlyRole(SIGNAL_ROLE) returns (uint256 id)` (QuadraticGovernor.sol:108). Reverts `SignalRateLimited` within `signalRateLimit` of the last signal trigger (Rule 3), or `CheckpointWindowAlreadyOpen` while a window is open. Sets `lastSignalTrigger`, then `_openWindow(SIGNAL)` as in step 5. Emits `CheckpointWindowOpened(id, SIGNAL)` and `EarlyCheckpointTriggered(id)`. v2: reached only when step 5 found `quorum` fresh reporters whose median crossed a threshold. Test: line 27.

### 7. initiateAuditVote, vote
Any holder, once per window: `function initiateAuditVote(uint256 checkpointId, CheckpointAction action, uint256 newRateDelta) external` (QuadraticGovernor.sol:129). Sets `auditInitiated`, `proposedAction`, `proposedRateDelta`. Emits `AuditVoteInitiated(id, proposedAction, initiator)`. Then `function vote(uint256 checkpointId, CheckpointAction action) external` (QuadraticGovernor.sol:147): weight is `sqrt(getPastVotes(voter, snapshotBlock))`, one vote per address; adds to `tallies[id][action]` and `totalVoteWeight`, sets `hasVoted`. Emits `Voted(id, voter, action, weight)`. Test: lines 36, 40-44.

### 8. resolveCheckpoint
Anyone, after `windowEnd`. `function resolveCheckpoint(uint256 checkpointId) external` (QuadraticGovernor.sol:164). Sets `resolved`, `lastCheckpointEnd`, `resolvedAction`. Outcome is CONTINUE unless an audit was initiated, `totalVoteWeight` reaches 20% of `sqrt(totalSupply())`, and the top tally exceeds 50% of `totalVoteWeight`. `_applyAction` then calls the vault: CONTINUE nothing; INCREASE_RATE `setStreamRate(rate+delta)`; DECREASE_RATE `setStreamRate(rate-delta)` floored at 0; PAUSE_FOR_AUDIT `pauseForAudit(defaultPauseResponsePeriod)`, setting `paused`, `pausedReason=AUDIT_RESOLUTION`, `pausedAt`, `pauseResponsePeriod`; HALT `setStreamRate(0)`. Emits `CheckpointResolved(id, outcome)` plus the vault's `StreamRateChanged(oldRate, newRate)` or `PausedForAudit(responsePeriodEnd)`. Tests: line 50 (PAUSE_FOR_AUDIT); `test_integration_governorHaltsStream_rageQuitStillAvailable` line 116 (HALT).

### 9. checkPoolDepletion, resumeIfTimedOut
Both permissionless. `function checkPoolDepletion() external` (LAFVault.sol:247): if `unreleasedBalance()` is below `poolDepletionBps` of `totalDeposited`, sets `terminal=true`, `ratePerSecond=0`, one way; `claim()` then always reverts and `rageQuit` is the wind-down. Emits `TerminalStateEntered(remainingBalance)`. Test: `test_integration_poolDepletionDuringActivePause` line 186. `function resumeIfTimedOut() external` (LAFVault.sol:263): once `pausedAt+pauseResponsePeriod` has passed, adds to `totalPausedTime` and clears `paused`, `pausedReason`, `pausedAt`, `pauseResponsePeriod`. Emits `Resumed(address(0))`. Test: `test_integration_pauseTimeoutThenAutoResume` line 217.

## What the stress tests exercise (`test/stress/StressTest.sol`)

- `test_stress_bankRun` (line 16): step 5, then repeated step 4; Rule 2 pauses after 30 ETH, exits continue until `totalSupply()` hits 0.
- `test_stress_sybilCheckpoint` (line 57): steps 1, 2, 5, 7, 8; 90 ETH whale versus 100 wallets of 0.1 ETH voting HALT; asserts only that it resolves.
- `test_stress_signalGaming` (line 121): step 5 with all five metrics reported healthy: `evaluate()` returns false, the scheduled window still opens.
- `test_stress_cascade` (line 154): steps 5 (scheduled), 6 (refused, `CheckpointWindowAlreadyOpen`), 4 (Rule 2 fires), 8 (CONTINUE), 9 (`resumeIfTimedOut` after `maxPauseDuration`).
- `test_stress_governanceApathy` (line 201): three rounds of steps 5 and 8 with no audit, each CONTINUE, then step 3 still pays.

## Where it stops

- No testnet deployment; only `forge test` (83 tests, 10 invariants, each checked over 128 runs x depth 64 = 8,192 calls).
- Reporters are admin-registered, unstaked and unslashed; the v2 median survives fewer than half of them lying, a colluding majority can still trigger or suppress; no oracle network feeds `reportMetric`.
- Quadratic voting over a transferable ERC-20 is Sybil-vulnerable: in `test_stress_sybilCheckpoint` 100 wallets of 0.1 ETH carry about 3.3 times the sqrt weight of one 90 ETH wallet. Measured, not solved.
