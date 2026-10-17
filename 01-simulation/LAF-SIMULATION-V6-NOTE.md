# LAF current-rule simulation (v6.0, 2026-10-17)

**Status.** Current-rule model of the Solidity prototype in `02-solidity/src`
(rules as described in `02-solidity/PROTOTYPE-V2-CHANGES.md`). The historical
v5 model (`capstone_sim_v5.py`, `LAF-SIMULATION-NOTE.md`) and its stored
outputs are unchanged and remain the record of the 2026-09-08 rules. Outputs:
`output/simulation_v6_results.txt` (stdout) and
`output/simulation_v6_summary.json` (machine-readable headline numbers).
Every figure below is a modelled outcome of the v5 agent rules under the
stated assumptions. None of them is an empirical observation.

## 1. Design

- `capstone_sim_v6.py` imports `capstone_sim_v4.py` and `capstone_sim_v5.py` and
  does not edit them. The 7 behavioural scenarios × 3 profiles, the seeds, the
  DAICO funding replay and all DAICO / RDA numbers come from `v4.run_single`,
  unchanged. The 21 DAICO / RDA blocks in `simulation_v6_results.txt` match
  those in `simulation_v5_results.txt` byte for byte (441 lines compared).
- `LAFSimV6` subclasses `v5.LAFSim` and replaces only the rule engine. A
  `RuleSet` chooses v5 or current semantics for each rule:
  - **`v5`**: the historical engine.
  - **`current`**: the contracts with deployment defaults; this is the primary result.
  - **`parity`**: `current`, but with the minimum vesting duration shortened so
    that the v5 tap rate is admissible. This separates the effect of the rule
    changes from the effect of the rate clamp.
- Agent behaviour is v5 verbatim (A1–A11 in `simulation_v5_results.txt`). Each
  addition needed by a scenario is a subclass and is listed in section 5 and
  in `V6_ASSUMPTIONS`, which is printed at the top of the output.

## 2. Rule mapping: v5 vs current

The contract line numbers refer to the 2026-10-17 working tree. `LAFVault.sol`
was still being edited, so treat the function names as the reference. Default
values come from `script/DeployLAF.s.sol`.

| Rule | v5 (`capstone_sim_v5.py`) | Current contract | v6 `current` |
|---|---|---|---|
| Vote weight | sqrt(shares at window open) (L314) | One snapshot share = one vote: `QuadraticGovernor.votingPowerOf` → `getPastVotes` (L224-226), snapshot taken at `block.number - 1` when the window opens (L249). `LAFShareToken._update` auto-delegates holders (L84-90) | Linear shares at window open; only current holders vote |
| Quorum | Cast ≥ 0.20 × √(total at open) (L48, L358). In practice never binds | Cast ≥ ceil(5001 bps × snapshot supply): `resolveCheckpoint` (L200-204), `_ceilBasisPoints` (L229); Deploy 5001 (L53) | Cast ≥ 0.5001 × snapshot supply |
| Winner | Largest tally above 50 % of cast; ties go to the first action (L360-362) | Same: `_findWinner` (L270-294); action order in `IQuadraticGovernor` enum; Deploy 5000 (L54) | Unchanged |
| Rate step | ±0.30 × initial rate; this was a v5 assumption (L58) | ±(initial+1)/2; the proposer's delta must be 0: `_applyAction` (L297-313), `initiateAuditVote` (L156) | ±0.5 × initial |
| Rate cap | 15 % of the raise per round = 15× / 7.5× / 18.75× initial (L59, L180) | 2 × initial: `LAFVault.setStreamRate` (L247); the governor saturates at the cap (QG L306-308) | 2 × initial, saturating |
| Initial-rate bound | None | rate ≤ totalDeposited / (2 × minimumVestingDuration): `closeFunding` (L203-206); minimum duration is immutable (L78); Deploy 365 d (L40) | Clamped to the bound (`current`) or duration shortened (`parity`), see §3 |
| Rule 2 (rage-quit auto-pause) | Exits since the last window opened > 25 % of the balance at that opening; inactive before the first window (L436-442, L317-319) | Exits in today's bucket plus the previous 29 daily buckets > 25 % (strict) of the balance just before this exit; active from funding close: `withdrawForRageQuit` (L301-343, Rule 2 block L312-338), `recentRageQuit` (L389), lookback constant (L69); Deploy 2500 (L37) | Same, with each round's exits in one daily bucket (§7) |
| Pause | Rule 2 pause lasts 60 d. A passed PAUSE vote pauses 30 d and overwrites an active pause (L383-385) | `pauseForAudit` reverts if already paused (L265). The governor skips PAUSE when the vault is paused (QG L318). Rule 2 pause = `maxPauseDuration` (L335). Pauses end by timeout (`resumeIfTimedOut`); the governor never calls `resumeStreaming`. Deploy 60 d / 30 d (L39, L55) | An existing pause and its deadline are kept |
| Rule 4 (terminal) | Unreleased < 10 % of deposits (L276-279) | remaining == 0, or remaining < 10 % × (deposited − streamed): `checkPoolDepletion` (L350-368, condition L360); Deploy 1000 (L38) | Same |
| Resolution while terminal | Action is still applied and counted (L251-258, L372) | Recorded as CONTINUE (`resolveCheckpoint` L213) | CONTINUE |
| Schedule | First window ≥ 90 d after close, then ≥ 90 d after each resolution; 14-d window; one window at a time | Same: QG L117-128, L239-262, L190 | Unchanged (v5 already matched) |
| Rule 3 (signal rate limit), payout | At most one signal window per 30 d; pro-rata payout (L423-435) | QG L131-142; `RageQuitModule.rageQuit` (L45) | Unchanged |
| Signals | v5 proxies computed each round | `SignalMonitor` takes the median of fresh reporter submissions (L245-293), thresholds at L114-118. The deploy script registers **no** reporter | v5 proxies (one honest reporter); COMMIT_INACTIVITY added only in S2 / S3 |

## 3. Initial-rate bound

The deployed minimum vesting duration is 365 days. The initial rate may
therefore be at most 0.959 % of the raise per 7-day round, and the 2× cap
keeps any rate path at least 365 days long.

The v5 tap rates are 1.0 % (v3) and 2.0 % (small); `closeFunding` would reject
both. The large profile's 0.8 % is admissible.

- **`current` (primary, matches the deployment):** clamp the initial rate to the
  bound.
- **`parity` (secondary):** shorten the minimum duration to 350 d (v3) or 175 d
  (small), so the v5 rate is kept and only the rule changes differ.

For large, `current` and `parity` are identical.

**Horizon truncation.** Team receipts are measured at the v5 horizon (350 /
140 / 560 days). At the bound, the 140-day small profile can stream at most
140/730 = 19.2 % of the raise (38.4 % at the 2× cap). The remaining 59–64 % is
still in the vault at day 140 (column `Left`). That money is not lost: it keeps
streaming to the team, or stays redeemable by holders, after the horizon.

The drop in small-profile team receipts (38 % → 18 %) is therefore a timing
effect of the 365-day schedule. It does not mean investors or the team lost
funds. `parity` shows the rule effect alone: 37 %.

## 4. Verification

- **Parity.** Ruleset `v5` run through `LAFSimV6` reproduced all 47 metrics of
  `v5.run_single` (DAICO, RDA and LAF) exactly in 1,650 runs: 21 cells × 50
  seeds, plus 3 × 200 headline seeds. The script asserts this and stops on any
  mismatch.
- **Rule fixtures.** 14 of 14 pass. They are deterministic asserts that run
  before the sweep:

| # | Check | Mirrors |
|---|---|---|
| F1 | A 40 % holder cannot reach quorum; 50.02 % can; the v5 sqrt quorum is met by 40 % | `QuadraticGovernorTest.test_singleFortyPercentHolderCannotReachQuorum` |
| F2 | 95 of 100 vested and claimed is not terminal (the v5 rule makes it terminal); a full vesting path never triggers terminal | `LAFVaultTest.test_normalVestingDoesNotTriggerTerminal` |
| F3 | A PAUSE vote during a Rule 2 pause keeps the cause and deadline (v5 overwrote them) | `QuadraticGovernorTest.test_pauseVoteDuringExistingPauseResolvesWithoutExtendingDeadline` |
| F4 | INCREASE at the 2× cap still resolves; an increase near the cap saturates | `QuadraticGovernorTest.test_increaseAtRateCapStillResolves` |
| F5 | A rate above raise / (2 × 365 d) is rejected (clamped); the parity duration admits the v5 rate; 2× cap ⇒ ≥ 365 d | `LAFVaultTest.test_closeFunding_rejectsRateAboveTheCommittedVestingLimit` |
| F6 | A 30 % rage quit pauses for 60 d before any checkpoint; 20 % does not; the v5 rule was inactive at that point | `RageQuitTest.test_rageQuit_crossing25PercentThreshold_autoPausesVault`, `..._belowThreshold_doesNotPause` |
| F7 | A checkpoint resolving after terminal records CONTINUE; the rate stays 0 | `QuadraticGovernorTest.test_checkpointResolutionCannotReviveTerminalVault` |
| F8 | Exactly 25 % does not pause; 25.001 % does | strict `>` in `LAFVault.withdrawForRageQuit` |
| F9 | Exits aged 29 days count toward Rule 2; exits aged 30 days do not (direct check and via exits) | `RageQuitTest.test_rageQuitLookbackExpiresOldExits` |
| F10 | Rule 4: remaining = 10 % of unvested is not terminal; below that it is | `LAFVaultTest.test_checkPoolDepletion_noOpAboveThreshold` / `_triggersTerminalBelowThreshold` |
| F11 | Rage quit pays pro rata during a pause and in terminal | `RageQuitTest.test_rageQuit_availableDuringPause` / `_availableDuringTerminal` |
| F12 | An uninitiated window and a missed quorum both resolve CONTINUE | `QuadraticGovernorTest.test_resolveCheckpoint_defaultsToContinue_ifQuorumNotMet` |
| F13 | A passed PAUSE pauses for 30 d; a terminal vault cannot be paused | `LAFVaultTest.test_pauseForAudit_blocksClaimDuringPause`, `test_claim_revertsAfterTerminal` |
| F14 | Splitting 40 % across 10 wallets: linear weight unchanged, sqrt weight × √10 | `QuadraticGovernorTest.test_votingWeight_isLinearBalance` |

- **Determinism.** Two consecutive full runs produced byte-identical
  `simulation_v6_results.txt` and `simulation_v6_summary.json`.

## 5. Scenarios added in v6

All scenarios use the three profiles, the baseline population (no FOMO or
herding) and seeds 0–49. S4 (governance apathy) was not run.

- **S1 Honest team + bank run.** A4 discontent is switched off. In one round
  (day 35, before the first checkpoint, or day 126, after it), each non-whale
  holder exits with probability q = 0.3 or 0.5 for an external reason. Each run
  is compared with the same seed and rules without the panic. Any pause is a
  false positive.
- **S2 Malicious team at the maximum permitted rate.** For every ruleset the
  initial rate sits at the 365-day bound. The team delivers nothing from day 0:
  there are no commits, so COMMIT_INACTIVITY equals days since close (warning
  at 60 d, critical at 120 d). Variants:
  - **a:** investors react only through signals (A4 off);
  - **b:** confidence tracks health (A4 at the v5 level).
- **S3 Gradual deterioration.** Project health H = 1 until an onset day drawn
  uniformly from 60–240, then falls linearly to 0 over 180 d. On each day the
  team commits with probability H. Health is external: investor exits do not
  affect it. Variants:
  - **a:** A4 off;
  - **b:** A4 scale = 1 − H (zero while the project is healthy).
- **S5 Whale concentration.** A team-aligned holder with 40 % or 55 % of the
  raise is added to the baseline population, in 1 wallet or split across 10.
  It never exits before terminal, opens a ballot in every window (any holder
  may) and votes INCREASE_RATE. Everyone else follows the v5 rules.

## 6. Results

### 6.1 Headline: baseline, N = 200 (seeds 0–199)

| Profile | Rules | Team received | Recovery (quitters) | Recovery (all) | Quit | Terminal | Terminal day: mean (p10/p50/p90) | Balance at terminal | Quorum met | PAUSE / INC passed per run | Rule 2 pauses per run (before / after 1st window) | Paused days | Left in vault | Whale vote share |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| v3 | v5 | 44.7 % | 73.2 % | 33.9 % | 45.8 % | 12 % | 305 (238/336/350) | 7.5 % | 100 % | 0.45 / 0.24 | 0.00 / 0.58 | 38.7 | 21.4 % | 72 % |
| v3 | current | 41.2 % | 74.7 % | 36.5 % | 45.8 % | 10 % | 256 (133/245/350) | 4.4 % | 76 % | 0.36 / 0.01 | 0.01 / 0.69 | 40.8 | 22.3 % | 82 % |
| v3 | parity | 42.9 % | 73.6 % | 36.0 % | 45.8 % | 10 % | 255 (133/245/350) | 4.3 % | 76 % | 0.36 / 0.01 | 0.01 / 0.69 | 40.8 | 21.1 % | 82 % |
| small | v5 | 37.9 % | 76.2 % | 17.0 % | 24.4 % | 2 % | 131 (126/133/133) | 2.5 % | 100 % | 0.14 / 0.03 | 0.00 / 0.14 | 7.7 | 45.2 % | 79 % |
| small | current | 17.7 % | 88.5 % | 21.8 % | 24.9 % | 3 % | 132 (126/133/133) | 3.0 % | 73 % | 0.09 / 0.01 | 0.01 / 0.28 | 10.6 | 60.5 % | 86 % |
| small | parity | 37.0 % | 76.0 % | 18.8 % | 25.8 % | 4 % | 132 (126/133/133) | 2.6 % | 73 % | 0.09 / 0.01 | 0.01 / 0.28 | 10.7 | 44.3 % | 86 % |
| large | v5 | 49.9 % | 50.1 % | 50.1 % | 100 % | 100 % | 456 (427/455/483) | 9.4 % | 100 % | 0.00 / 1.11 | 0.00 / 0.73 | 40.9 | 0.0 % | 58 % |
| large | current = parity | 51.3 % | 49.7 % | 48.4 % | 97.1 % | 97 % | 510 (476/511/546) | 4.4 % | 40 % | 0.01 / 0.00 | 0.00 / 1.36 | 74.1 | 0.3 % | 70 % |

All seven behavioural scenarios (N = 50); current, with v5 in brackets:

- **v3:** team received 40.4–44.2 % (43.4–46.7 %; parity 42.1–46.1 %); terminal 0–10 % (0–10 %); quorum met in 75–93 % of initiated windows (100 %).
- **small:** team received 17.2–18.1 % (37.8–39.1 %; parity 35.9–37.8 %); quitters recover 87.8–88.3 % (74.7–76.1 %); 59.4–63.6 % left in the vault at day 140.
- **large:** team received 50.5–59.3 % (49.2–57.8 %); terminal 80–98 % (100 % in every scenario); Rule 2 pauses 1.04–1.64 per run (0.04–0.78); quorum met 45–99 % (100 %); INCREASE passes 0–0.18 per run (0.76–1.28).

Signals fire 0–0.10 times per run in every cell.

### 6.2 S1 honest team + bank run (N = 50; v5 → current)

| Profile | Panic | False-pause rate | Team funding lost (pp) | Terminal | Recovery (quitters) |
|---|---|---|---|---|---|
| v3 | day 35, q 0.3 | 2 % → 34 % | 1.1 → 3.3 | 2 % → 2 % | 94.9 → 95.2 % |
| v3 | day 35, q 0.5 | 22 % → 84 % | 9.8 → 15.6 | 28 % → 16 % | 90.4 → 94.8 % |
| v3 | day 126, q 0.5 | 62 % → 84 % | 10.1 → 12.4 | 16 % → 14 % | 81.7 → 82.7 % |
| small | day 35, q 0.3 | 10 % → 40 % | 2.5 → 3.5 (parity 7.2) | 10 % → 6 % | 89.3 → 95.2 % |
| small | day 35, q 0.5 | 48 % → 74 % | 12.3 → 8.4 (parity 17.6) | 40 % → 34 % | 88.1 → 95.2 % |
| large | day 35, q 0.3 | 0 % → 4 % | 0.0 → 0.3 | 0 % → 0 % | 96.0 → 96.0 % |
| large | day 35, q 0.5 | 0 % → 100 % (56 d) | 2.1 → 7.5 | **58 % → 0 %** | **63.3 → 96.0 %** |
| large | day 126, q 0.5 | 74 % → 100 % | 5.3 → 7.3 | 2 % → 0 % | 85.1 → 85.6 % |

Under current rules, a q = 0.5 panic pauses an honest project for 60 days in
74–100 % of runs (v5: 0–62 %). Early panics now trigger the pause too, because
v5's Rule 2 was inactive before day 91. In return, the old Rule 4 cliff
disappears: under v5 the large-profile day-35 panic later pushed 58 % of these
honest projects into terminal.

### 6.3 S2 malicious team at the maximum permitted rate (N = 50)

Variant a (investors react only through signals). Variant b gives the same
money figures within 0.5 pp; its alarm comes up to 12 days later.

| Profile | Rules | Alarm day | First protective event (days, type) | Streamed before it | Team received (= investor loss) | Investor recovery | Terminal |
|---|---|---|---|---|---|---|---|
| v3 | v5 | 86 | 98, DECREASE (42/50) | 13.5 % | 15.3 % | 84.7 % | 100 % |
| v3 | current | 88 | 66, Rule 2 pause (50/50) | 9.1 % | 9.4 % | 90.6 % | 100 % |
| small | v5 | 85 | 97, DECREASE (37/50) | 13.2 % | 14.9 % | 85.0 % | 100 % |
| small | current | 87 | 68, Rule 2 pause (48/50) | 9.3 % | 9.6 % | 90.0 % | 98 % |
| large | v5 | 85 | 104, DECREASE (50/50) | 14.2 % | 16.3 % | 83.7 % | 100 % |
| large | current | 91 | 64, Rule 2 pause (50/50) | 8.7 % | 9.2 % | 90.8 % | 100 % |

How the sequence unfolds:
1. The commit-inactivity WARNING arrives at day 63.
2. Under the v5 agent rules, rational holders and speculators then exit with probability 0.5 per round.
3. Those exits trip the current rolling Rule 2 within about a week.
4. They also add TVL and active-address warnings, so the monitor's combinator fires at about days 85–103.
5. At CRITICAL (day 126) the remaining holders exit, and the vault goes terminal in 98–100 % of runs.

Under current rules, a team taking the maximum permitted rate keeps about 9 % of
the raise, against about 15 % under the v5 rules at the same rate.

### 6.4 S3 gradual deterioration (N = 50; mean onset day 163)

| Profile | Variant | Rules | Detected within horizon | Detection lag (d) | Funding after onset | Team received | Terminal |
|---|---|---|---|---|---|---|---|
| v3 | a | v5 / current / parity | 22 % / 22 % / 22 % | 236 | 26.2 / 24.9 / 26.0 % | 49.1 / 46.9 / 48.9 % | 0 % |
| v3 | b | v5 / current / parity | 20 % | 230 | 25.6 / 24.3 / 25.3 % | 48.5 / 46.2 / 48.2 % | 4 / 6 / 6 % |
| small | a, b | all | 0 % (horizon 140 d) | n/a | 11.2 / 5.4 / 11.2 % | 40.0 / 19.2 / 40.0 % | 0 % |
| large | a | v5 / current / parity | 100 % | 248 / 250 / 250 | 27.1 / 26.2 / 26.2 % | 45.4 / 44.5 / 44.5 % | 100 % |
| large | b | v5 / current / parity | 100 % | 250 / 251 / 251 | 26.4 / 25.9 / 25.9 % | 44.7 / 44.2 / 44.2 % | 100 % |

Commit inactivity is a lagging indicator. Gradual decline is detected 230–250
days after onset, and roughly a quarter of the raise is streamed after onset.

The rule changes barely affect this: `parity` is within 1 pp of `v5`. In v3,
`current` is about 1.3 pp lower than `v5`, and that gap comes from the rate
clamp. In the large profile the first protective event is a Rule 2 pause about
221–233 days after onset.

### 6.5 S5 whale concentration (N = 50)

Each cell shows v5 / current.

| Profile | Aligned holder | Aligned share of cast weight | INCREASE wins | Peak rate | Team received | Non-aligned holders' recovery |
|---|---|---|---|---|---|---|
| v3 | 40 %, 1 wallet | 41 / 59 % | 71 / 99 % | 1.64 / 2.00× | 58.5 / 72.2 % | 48.2 / 33.2 % |
| v3 | 40 %, 10 wallets | 64 / 59 % | 100 / 99 % | 1.90 / 2.00× | 66.2 / 72.2 % | 38.4 / 33.2 % |
| v3 | 55 %, 1 wallet | 49 / 72 % | 83 / 100 % | 1.75 / 2.00× | 61.8 / 72.9 % | 47.6 / 34.1 % |
| small | 40 %, 1 wallet | 44 / 61 % | 64 / 88 % | 1.19 / 1.44× | 41.2 / 20.9 % (parity 43.4 %) | 60.3 / 79.8 % (parity 57.9 %) |
| small | 40 %, 10 wallets | 70 / 61 % | 100 / 88 % | 1.30 / 1.44× | 42.4 / 20.9 % | 58.9 / 79.8 % |
| large | 40 %, 1 wallet | 18 / 60 % | 55 / 99 % | 1.65 / 2.00× | 68.1 / 88.0 % | 44.4 / 19.4 % |
| large | 40 %, 10 wallets | 36 / 59 % | 84 / 99 % | 2.01 / 2.00× | 75.1 / 88.0 % | 33.7 / 19.3 % |
| large | 55 %, 1 wallet | 23 / 77 % | 63 / 99 % | 1.75 / 2.00× | 74.2 / 91.0 % | 42.8 / 19.6 % |
| large | 55 %, 10 wallets | 40 / 74 % | 100 / 99 % | 2.20 / 2.00× | 82.7 / 91.0 % | 25.4 / 19.5 % |

For reference, the `current` baseline without an aligned holder has team
receipts of 40.4 % (v3), 17.9 % (small) and 50.6 % (large). Team received
includes the aligned holder's own stake. Non-aligned recovery = (payouts +
shares at end NAV) / deposits.

**Linear weights.** Splitting into wallets no longer changes anything: the
weight and the outcome are identical for 1 or 10 wallets. Under the v5 sqrt
rule, splitting raised the large-profile win rate from 55 % to 84 % (and 63 %
to 100 % for the 55 % holder).

**The 50.01 % quorum does not stop a 40 % holder.**
- The aligned holder brings 40 %. The opposing whales, who always vote CONTINUE
  under v5 behaviour, bring about 26 %. Together they clear quorum, and the
  aligned holder then holds about 60 % of cast weight.
- Result: INCREASE wins about 99 % of windows and the rate reaches the 2× cap.
- In the 560-day profile, non-aligned holders then recover 19 % instead of 44 %
  under v5 rules.
- What limits the damage is the cap and the 365-day bound: even at the cap the
  raise cannot be streamed faster than 437 days at large's rate. The quorum
  does not limit it.
- Against the 40 % holder, opponents who abstained instead of voting CONTINUE
  would keep turnout below quorum (40 % plus a few speculator votes), and the
  result would be CONTINUE. A 55 % holder meets quorum on its own.

### 6.6 Sensitivity to A4 (baseline, N = 50)

A4 is v5's per-round probability that a rational or whale holder becomes
discontent. Each cell shows v5 / current.

| Profile | A4 scale | Terminal | Mean terminal day | Team received | Recovery (quitters) |
|---|---|---|---|---|---|
| v3 | 1.0 | 8 / 10 % | 257 / 213 | 43.4 / 40.4 % | 74.5 / 74.0 % |
| v3 | 0.5 | 2 / 0 % | 343 / – | 47.5 / 44.4 % | 72.7 / 73.7 % |
| v3 | 0.25 | 0 / 2 % | – / 245 | 50.0 / 46.9 % | 69.1 / 70.5 % |
| small | 1.0 | 2 / 4 % | 126 / 130 | 38.0 / 17.9 % | 74.7 / 87.8 % |
| small | 0.5 | 0 / 0 % | – | 38.8 / 18.4 % | 77.1 / 88.8 % |
| large | 1.0 | 100 / 98 % | 455 / 509 | 49.3 / 50.6 % | 50.7 / 50.7 % |
| large | 0.5 | **98 / 34 %** | 524 / 549 | 60.6 / 62.8 % | 41.0 / 55.1 % |
| large | 0.25 | 2 / 0 % | 560 / – | 64.0 / 64.0 % | 62.1 / 62.5 % |

At scale 0, nobody exits under either ruleset, and the team receives exactly
the stream: 50 / 47.9 %, 40 / 19.2 % and 64 / 64 %. The v5 rows reproduce
`output/simulation_v5_sensitivity.txt`.

The vesting-relative Rule 4 moves the large-profile terminal cliff from between
0.25 and 0.5 to between 0.5 and 1.0. At the default A4, terminal is delayed
(about day 455 → 510) and shrinks (balance at terminal about 9 % → 4.5 % of the
raise), but it is not removed.

## 7. Limitations (state these with any v6 number)

1. **v5 agent behaviour drives the results.** The large-profile terminal outcome
   is mostly an A4 artifact (§6.6). The voting rules (rationals abstain without
   signals, late entrants never vote, whales always vote, a no-quorum result
   counts as failed voice) now decide governance outcomes, because the 50.01 %
   quorum binds. S2 detection depends on the v5 rule that a single WARNING makes
   rational holders exit.
2. **Votes.** Opposing holders who vote help the proposal reach quorum. In S5,
   the whales' CONTINUE votes are what let a 40 % aligned holder clear quorum
   and win with about 60 % of cast weight; whales that strategically abstained
   would block it. Exited holders keep their snapshot vote on-chain, which is
   not modelled.
3. **Time step.** Rounds are weekly. All of a round's exits share one daily
   bucket, so Rule 2's 30-day lookback spans 5 rounds; the prototype check with
   a 4-round window moved large-profile terminal 98 → 100 % and paused days
   79 → 69. A 60-day pause stops 56 days of accrual and a 30-day pause stops 28
   days.
4. **Keepers.** The permissionless calls (`checkPoolDepletion`,
   `resumeIfTimedOut`, opening and resolving checkpoints, `evaluate`) are
   assumed to happen every round with no delay. The team claims every round.
5. **Signals.** One perfect reporter is assumed; the deploy script registers
   none, so the monitor would be silent as deployed. TEAM_OUTFLOW (warning 3×)
   cannot fire under the 2× cap. COMMIT_INACTIVITY exists only in S2 / S3.
   Reporter noise, staleness and collusion are not modelled.
6. **Horizon.** Receipts are measured at the horizon; `Left` is not a loss
   (§3). The stream rate is absolute, so when holders exit, those who stay bear
   the full stream.
7. **Not modelled:** a strategic team (claim timing, choosing a lower initial
   rate), share transfers or a secondary market, partial rage quits, S4
   governance apathy.
8. **Monte Carlo error.** At N = 50 the standard error on a 10 % rate is about
   4 pp (about 2 pp at N = 200). The v6 random draws follow v5's per-run stream,
   so once the rules diverge the paired differences include noise.

## 8. Reproduce

From `01-simulation/` with Python 3.10+ and the standard library only:

```
python capstone_sim_v6.py --json output/simulation_v6_summary.json > output/simulation_v6_results.txt
```

Measured on 2026-10-17 with Python 3.14.0 on Windows: 122 s in total.

| Stage | Time |
|---|---|
| Fixtures and sweep with parity checks | 46 s |
| Headline N = 200 | 23 s |
| S1 | 24 s |
| S2 | 2 s |
| S3 | 6 s |
| S5 | 13 s |
| A4 sensitivity | 8 s |

On Windows the stdout file has CRLF line endings, like the other stored
outputs; the JSON uses LF. The script writes no bytecode cache. `--quick` runs
a tiny N to check the code paths; its numbers are not results.
