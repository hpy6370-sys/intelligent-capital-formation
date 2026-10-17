# LAF Capstone: artefacts and results to date

> **Prototype revision (2026-09-27, hardened 2026-10-17):** The Solidity
> contracts use share-weighted five-action voting, a majority-of-supply quorum,
> a live 30-day rage-quit alarm, a vesting-relative terminal threshold, a
> pre-deposit minimum vesting bound and locked module roles. The v5 simulation,
> counterfactuals and original design document describe the earlier mechanism;
> `01-simulation/capstone_sim_v6.py` re-runs the same agents under the current
> rules (see `01-simulation/LAF-SIMULATION-V6-NOTE.md`). The counterfactual
> estimates have not been recalculated. See `02-solidity/PROTOTYPE-V2-CHANGES.md`
> for the exact contract changes.

> **Empirical-data status:** all 82 rows of
> `03-dataset/dataset_82_projects.md` are coded under the
> [failure-coding codebook](03-dataset/FAILURE-CODING-CODEBOOK.md): record type,
> duplicates, mechanism fit, outcome at the mid-2026 cutoff and failure mode with
> dated evidence. 59 rows are eligible fundraising campaigns; 47 were surviving
> and 12 had failed. The inventory remains a curated list coded by one coder,
> so its shares are descriptive. Tables: `03-dataset/output/descriptive_tables.md`.

**Project:** Intelligent Capital Formation
NTU SC6131 MSc Capstone, in collaboration with the Ethereum Foundation. Industry mentor: Shyam Sridhar.

## What you asked for on 28 August, and where it is

| Your request | Where to look |
|---|---|
| Results from the simulations that test various counterfactuals | `05-counterfactuals/` (5-case analysis, 27-scenario matrix, 9 P0 deep dives) and `01-simulation/` (Monte Carlo, 7 behavioural scenarios x 3 project profiles; v5 of 2026-09-08 adds LAF alongside DAICO and RDA on the same agents, see `01-simulation/LAF-SIMULATION-NOTE.md`). Key numbers are summarised in "Key results" below |
| Working flow of the Solidity prototype | `02-solidity/PROTOTYPE-V2-CHANGES.md` for the current rules; `02-solidity/WALKTHROUGH.md` records the 2026-09-08 baseline; integration paths are in `02-solidity/test/integration/CrossLayerTest.sol` |
| DAICO data gap | Not fillable from public sources (only 4 of 11 DAICO raises moved funds); listed as Limitation 1 and future work below |
| Intermediary roles and legal/regulatory aspects | Reserved for the discussion section of the final report, with a first pass in Journal 2; not in this package (Limitation 8) |
| All results, artefacts and work so far | This repository. `MANIFEST.txt` is the historical 2026-09-09 package inventory |

How the counterfactuals are delivered. `05-counterfactuals/` answers "what would LAF have done in a specific known failure": each of the five cases and nine P0 scenarios is worked through by hand against the layer rules at one parameter point (100 ETH streamed over 365 days), so its recovery figures (derived for six of the nine P0 scenarios; the other three are left undetermined in the file) are analytical estimates with no distribution behind them. `01-simulation/` answers a different question, "how do the same agents fare under DAICO, RDA and LAF across FOMO/herding scenarios": v5 puts LAF on the v4 Monte Carlo agents (N = 50 per cell, 7 x 3 cells) and reports distributions, but it has no malicious-team or exogenous-deterioration process, so it does not reproduce the rug-pull or gradual-decline cases in 05. The two overlap only where investor exits drive the outcome: the bank-run scenario (#7) corresponds to the Rule 2 pause and rage-quit recovery columns in v5, and the governance-apathy scenario (#16) to the abstention-driven CONTINUE resolutions. Monte Carlo versions of the malicious-team scenarios (Proposal v3 section 7.3) are the next step and are not in this package.

## What the project is

Existing on-chain fundraising mechanisms (ICO, reverse Dutch auction, bonding curve, DAICO, LBP) solve token *allocation*; none of them constrains what the team does with the money afterwards. The working hypothesis is that most failures are accountability gaps, not allocation-design flaws. The proposed answer is the **Layered Accountability Framework (LAF)**, a defence-in-depth composition of four independent layers, each targeting one failure mode and each still useful if the others are compromised:

| Layer | Contract | Mechanism |
|---|---|---|
| 1 Streaming Release | `LAFVault` | Team can only `claim()` funds at a linear `ratePerSecond`; the minimum vesting duration is immutable before deposits, and the initial rate is capped so even a 2x governance increase cannot exhaust the raise faster |
| 2 Rage Quit | `RageQuitModule` | Any share holder can exit any time, pro rata of the unreleased pool, no vote needed (works during pause and terminal state; before funding closes it returns the deposit) |
| 3 Checkpoint Voting | `QuadraticGovernor` | First scheduled window 90 days after funding closes, then 90 days after each resolution; one 14-day window at a time. Votes on all five actions are weighted by snapshot shares; quorum is more than 50 % of snapshot supply, and the winning action needs more than 50 % of cast weight. No quorum = CONTINUE |
| 4 Signal Monitor | `SignalMonitor` | 5 health metrics (TVL decline, active-address decline, team outflow, commit inactivity, HHI increase) with warning/critical thresholds, each reported by a registered set of up to 16 reporters; a metric only has an effective value when at least `quorum` reporters have submitted within `reportWindow`, taken as the median of those fresh submissions (v2). >=2 warnings or >=1 critical requests an early checkpoint from the Governor. It never touches the vault |

Inter-layer rules (all in code, defaults in `02-solidity/script/DeployLAF.s.sol`): the deployed vault fixes a 365-day minimum vesting duration before deposits; at funding close, the admin-selected initial rate must be no more than `totalDeposited / (2 * minimumVestingDuration)`, so the governor's 2x rate cap cannot stream the full raise faster than the committed duration. Rule 2, exits during the current and previous 29 calendar days greater than 25 % of the balance immediately before the latest exit auto-pause the vault, whether a checkpoint is open or not (unless it is already paused or terminal); Rule 3, signal-triggered checkpoints are rate-limited to one per 30 days; Rule 4, a zero balance or an unreleased balance below 10 % of the amount not yet vested under the stream puts the vault in a one-way terminal state once anyone calls the permissionless `checkPoolDepletion()`. A rate-change vote uses a fixed step of half the initial rate, and the overall rate cannot exceed twice the initial rate. Pause is bounded (30-day default response period, 60-day maximum). An active pause cannot be reset or extended by a second pause action; a passed pause vote during an existing pause preserves its original timeout.

## What is in each folder

- `01-simulation/` Monte Carlo simulator. `capstone_sim_v4.py` (v4.2, DAICO vs reverse Dutch auction, calibrated to dataset figures) and `capstone_sim_v5.py` (v5.0, adds LAF on the same agents and scenarios without changing the v4 numbers), `capstone_viz_v4.py` / `capstone_viz_v5.py` (5 figures + PDF each), `sim_v5_sensitivity.py` (sensitivity of the LAF results to assumption A4), `verify_daico_patch.py` (checks the DAICO voting-threshold fix), stored outputs in `output/`, figures in `figures/` (v5 files carry a `_v5` suffix). `LAF-SIMULATION-NOTE.md` explains the LAF modelling assumptions, the three-mechanism results and four design findings for the prototype. `capstone_sim_v6.py` (v6.0, 2026-10-17) imports v4/v5 unchanged and re-runs LAF under the current contract rules, with a parity check against v5, 14 rule fixtures and four targeted scenarios; `LAF-SIMULATION-V6-NOTE.md` documents it and `output/simulation_v6_summary.json` holds its headline numbers. Configuration is in-code (`SCENARIOS`, `RealDataCalibration`, `N = 50`); v4/v5 print to stdout only.
- `02-solidity/` Foundry project: 5 contracts plus interfaces, a deploy script, and unit, integration, stress and invariant tests. Build artefacts (`out/`, `cache/`) and vendored dependencies (`lib/`) are excluded from the repository; see `VERIFICATION.md` and `DEPLOYMENT.md`. The 8 September log is archival; the 11 October and 17 October dated runs retain their raw output and provenance, and `test-output/verification-2026-10-17-role-lock/` is the current record (117 tests, 10 invariants).
- `03-dataset/` The source-linked 82-row inventory (2026-08-31; ICO 18 / RDA 14 / bonding curve 16 / DAICO 11 / LBP 23) and its coding. `coding/row_codes.csv` holds one coded decision per row (record type, entity, duplicate link, mechanism fit, eligibility, capital raised, outcome, failure mode, evidence, confidence); `coding/research_evidence_2026-10-17.md` lists the dated sources for failed campaigns; `code_inventory.py` validates the codes against `FAILURE-CODING-CODEBOOK.md` and writes `output/dataset_82_coded.csv`, `coding_summary.json` and `descriptive_tables.md`. The source file keeps its original rows, with a header note on known errata.
- `04-docs/` Original Solidity design document, Proposal v3 (English) and the submitted Journal 1 (PDF). The original design document and walkthrough predate the current voting, funding-rate, Rule 2 and Rule 4 semantics; consult `02-solidity/PROTOTYPE-V2-CHANGES.md` for current behavior and `02-solidity/DEPLOYMENT.md` for deployment assumptions.
- `05-counterfactuals/` Three files: the counterfactual case analysis (5 cases, 2026-08-31), the 3x3x3 scenario matrix (27 scenarios) and the deep dive on the 9 P0 scenarios. Key figures are summarised below.

## How to run

Simulation (Python 3.10+, `numpy`, `matplotlib`, `seaborn` for the figures; sim itself is stdlib only). Verified on 2026-09-06 with Python 3.13, ~8 s and ~12 s respectively:

```
cd 01-simulation
python capstone_sim_v4.py > output/simulation_v4_results.txt   # seeded, reproduces the stored file byte for byte
python capstone_viz_v4.py                                       # writes figures/ next to the script
python capstone_sim_v5.py > output/simulation_v5_results.txt   # v5.0, LAF added; ~13 s; DAICO/RDA lines identical to v4
python capstone_viz_v5.py                                       # five *_v5 figures + capstone_v5_figures.pdf; ~19 s
python sim_v5_sensitivity.py > output/simulation_v5_sensitivity.txt   # ~7 s
PYTHONIOENCODING=utf-8 python verify_daico_patch.py             # UTF-8 needed for its console output on Windows
python capstone_sim_v6.py --json output/simulation_v6_summary.json > output/simulation_v6_results.txt   # ~2 min; deterministic
```

Dataset coding (Python 3.10+, standard library):

```
cd 03-dataset
python code_inventory.py      # validates coding/row_codes.csv, rewrites output/
```

Solidity toolchain: all repository-owned Solidity files and `foundry.toml`
use solc 0.8.28. The verification workflow pins Foundry v1.8.5 and restores
dependencies at the exact Git revisions in `foundry.lock`.

From the repository root, with `forge` on PATH:

```sh
python3 scripts/verify_prototype.py --install-deps
```

The runner verifies clean dependency checkouts, uses seed `0x6131`, enforces
256 fuzz runs and invariant settings of 128 runs / depth 64, and saves raw
output plus JSON provenance to `02-solidity/test-output/current/`. It exits
nonzero for failed/skipped tests, missing invariants, changed source during
the run, or an unexpected compiler/sampling configuration. Existing vendored
folders without Git metadata are rejected: use a separate clean clone rather
than replacing an existing working dependency directory.

A dated local verification is retained in
`02-solidity/test-output/verification-2026-10-11/`. Its metadata identifies
the Git base revision, working-tree state, tested source hash, toolchain,
dependency revisions and log hash. The raw 2026-09-08 `forge-test.txt` remains
an archive of the earlier prototype. GitHub Actions repeats the same checks
for relevant pushes/PRs and retains its own per-commit evidence as an artifact.
See `02-solidity/VERIFICATION.md` for reproduction and interpretation.

## Key results (each with the file that produces it)

**Simulation** (`01-simulation/output/simulation_v4_results.txt`, N = 50 Monte Carlo per scenario, 7 behavioural scenarios x 3 profiles: v3 defaults n = 30 agents, calibrated small project n = 20, calibrated large project n = 340; 5 agent types: rational, speculator, whale, FOMO follower, late entrant)
- FOMO improves RDA allocation fairness: RDA Gini 0.516 (baseline) to 0.401 (FOMO = 0.7), top-10 % share 36.4 % to 27.6 %, whale dominance 38.8 % to 28.4 % (v3-defaults profile). Same direction in both calibrated profiles (small: 0.544 to 0.425; large: 0.564 to 0.432).
- DAICO allocation is FOMO-invariant: within each profile the DAICO Gini moves by at most 0.003 across the 7 scenarios (v3 defaults 0.486-0.489, small 0.475-0.478, large 0.518-0.521), because contribution maps 1:1 to tokens. DAICO ROI dispersion across agent types is 0 by construction.
- DAICO governance does not scale: in the large-project profile (n = 340) the destroy vote triggers in 0 % of runs in every scenario, and `verify_daico_patch_output.txt` (header in Chinese; the tables are self-explanatory) shows that even after the dynamic-threshold patch destroy stays at 0 % at n = 340 (3.8 % at n = 5). This mirrors the empirical near-zero DAICO adoption.
- Calibration provenance is printed at the top of the results file (Abyss average contribution $3,137; Algorand clearing at 24 % of start price; tap rates flagged as assumptions).

**LAF in the historical v5 simulation** (`01-simulation/output/simulation_v5_results.txt`, v5.0 of 2026-09-08; these figures are for the prior mechanism and must not be presented as outcomes of the revised Solidity contracts)
- The team receives more, and more reliably: v3-defaults profile LAF 43.4 % of the raise vs DAICO 33.2 %; small project 38.0 % vs 23.2 %. DAICO is destroyed in 24 % / 34 % of runs in those two profiles, LAF reaches its terminal state in 8 % / 2 %.
- Dissatisfied investors can leave with money: rage-quitters recover on average 73 % to 76 % of principal (v3 and small profiles, all scenarios); DAICO refunds only if the destroy vote passes and RDA never refunds.
- Dollar-outcome inequality is unchanged: LAF Gini on dollar outcomes 0.496 vs DAICO token Gini 0.487 (v3), 0.476 vs 0.477 (small).
- Where LAF does worse: in the large profile (n = 340, 560 days) every run hits Rule 4 (unreleased < 10 % of deposits) around day 450 (seed 0 at day 448; across the 50 seeds the terminal day ranges 420 to 525, mean 455) and goes terminal, with the team receiving 49 % to 58 % against DAICO's stable 47.4 %; end-of-run share concentration rises (Gini 0.487 to 0.669 in v3); sqrt weighting does not stop whales holding up to 80 % of cast weight because rational holders abstain.
- Four prototype design findings came out of this run (Rule 4 threshold definition, quorum trivially met by one 40 % whale, Rule 2 snapshot timing, signal layer silent without exogenous deterioration); they are set out in the note and are the first items for the v2 design discussion.
- The results are most sensitive to assumption A4 (DAICO's 3 % per-round destroy propensity translated into loss of confidence): at scale 0 LAF collapses exactly to the DAICO share distribution (checked), and the large-profile terminal cliff sits between scale 0.25 and 0.5 (`simulation_v5_sensitivity.txt`).

**Coded dataset** (`03-dataset/output/descriptive_tables.md`)
- 82 rows: 63 campaign rows, 12 platforms, 4 projects without an attributable raise, 1 governance event, 1 proposal, 1 aggregate; two raises appear twice (Aavegotchi, Bancor). 59 rows are eligible campaigns.
- Outcomes at the mid-2026 cutoff: 47 surviving, 12 failed. Coded failure modes: slow death 3, soft rug 1, regulatory shutdown 1, other documented cause 2, unknown 5. No eligible campaign met the exit-scam, governance-failure or liquidity-trap threshold.
- Capital raised by eligible campaigns: US$9.85B (median US$17.35M); the ~US$11.0B inventory headline included revenue, volume, pool sizes and duplicates.

**LAF under the current contract rules, v6** (`01-simulation/output/simulation_v6_results.txt`; 200 runs per baseline cell, 50 per scenario cell)
- Single-whale quorum and stale snapshots are fixed, but quorum is met in only 76 % / 73 % / 40 % of initiated checkpoints (v3 / small / large) and no rate increase passes.
- The large-profile terminal cliff is delayed, not removed: 97 % of runs end terminal at day 510 on average (v5: 100 % at day 456). The result depends strongly on assumption A4.
- Malicious team streaming at the maximum permitted rate: its take falls from about 15 % to about 9 % of the raise and holders recover about 90 %.
- Honest team hit by a panic of half the non-whale holders: Rule 2 now pauses streaming in 74-100 % of runs (v5: 0-62 %), although false terminal states in the large profile disappear.
- Gradual deterioration is detected before the horizon in only about a fifth of v3 runs and in no small-profile run, under either rule set.
- Wallet splitting no longer adds voting weight, but a team-aligned 40 % holder can still push the rate to its 2x cap; the minimum-vesting bound is then the binding protection.

**Solidity prototype, 2026-09-08 baseline** (`02-solidity/test-output/forge-test.txt`; see `02-solidity/PROTOTYPE-V2-CHANGES.md` for the current code)
- Historical 8 September baseline: 83/83 tests passed: `LAFVaultTest` 21 (incl. 1 fuzz), `RageQuitTest` 9, `QuadraticGovernorTest` 17 (added 2026-09-08 from section 7.3 of the design document: window timing, sqrt weighting, quorum and majority, all five resolve actions, Rule 3 rate limit, role checks; one test is renamed to record that a single 40 % holder meets quorum alone, and one is a regression for the unopened-checkpoint fix below), `SignalMonitorTest` 13 (v2 multi-reporter: registration, quorum bounds, median, staleness, flag clearing, role-mutation guards), `CrossLayerTest` 7, `StressTest` 5 (bank run, Sybil checkpoint, signal gaming, cascade, governance apathy), `LAFInvariant` 11 (10 invariants plus a handler sanity test).
- Fixed on 2026-09-08 while writing the governor tests: `resolveCheckpoint()` did not revert for a checkpoint id that had never been opened, so anyone could call it every 90 days, move `lastCheckpointEnd` forward and defer the scheduled checkpoint indefinitely (signal-triggered checkpoints were unaffected). A `windowStart == 0` guard now reverts with `WindowNotOpen`; `test_resolveCheckpoint_revertsForUnopenedId` pins it.
- Core invariant held over 8,192 random calls per property: `totalDeposited == totalClaimedByTeam + totalExitedViaRageQuit + vault balance` (`invariant_vaultBalanceEqualsAccountingIdentity`), plus outflow bound, terminal one-way, no claim while paused/terminal, share supply bounded.
- Working flow of the prototype: `deposit()` mints `LAFShareToken` 1:1 -> `closeFunding()` starts streaming -> team `claim()` -> holders `rageQuit()` at any time -> `openCheckpointWindow()` every 90 days (or `SignalMonitor.evaluate()` -> `triggerEarlyCheckpoint()`) -> `initiateAuditVote()` / `vote()` -> `resolveCheckpoint()` applies the action to the vault; `checkPoolDepletion()` and `resumeIfTimedOut()` are permissionless. `test/integration/CrossLayerTest.sol` walks through these paths end to end.

**Counterfactual and scenario analysis** (`05-counterfactuals/`; analytical estimates, not Monte Carlo output)
- Five historical cases (`counterfactual_analysis_5_cases.md`): estimated recoverable share of attributable losses under LAF: Fei Protocol ~50-70 % of ~$280M, Friend.tech ~50-70 % of $44M, The Abyss ~40-60 % of ~$14.5M, Ordibank ~70-80 % of ~$8M (low confidence), SKALE not applicable (pre-raise front-running is outside LAF scope). Layer-by-layer applicability tables per case.
- Nine P0 scenarios out of the 27-cell Team x Market x Adversary matrix (`scenario-deep-dive.md`), assuming a 100 ETH pool streamed over 365 days: investor recovery ~51 % in a typical rug pull at day 182 (vs ~0 % without LAF), ~75 % in a bear-market rug, ~82 % in the worst case (malicious team + bear + Sybil adversary), ~60 % in an honest-team bank run (where the honest team is the collateral damage), ~40 % in a gradual decline and ~30 % in a natural death under governance apathy (the two weakest cases). The file itself notes these are single-parameter-point estimates and that a sensitivity sweep is still to do.

## Known gaps and shortcomings (as admitted in the code and docs)

1. **DAICO data gap.** Of 11 DAICO rows only 4 raises actually moved funds (The Abyss, Aavegotchi, ICOVO, LUKSO rICO, ~$64M total), so DAICO calibration rests largely on The Abyss and the tap rate is an assumption. Listed as future work.
2. **Single trusted reporter (v1, addressed in v2 on 2026-09-07).** v1 pushed metrics from one `REPORTER_ROLE` address. v2 registers up to 16 reporters and, when deployed with `quorum` >= 2, requires that many fresh submissions per metric and takes their median, so no single reporter can raise a false alarm or suppress a real one on its own. The packaged `DeployLAF.s.sol` deploys with `quorum` = 1 and a 365-day `reportWindow` as a development default and registers no reporter (the admin adds them with `addReporter` after deployment, as the walkthrough describes; until then the monitor cannot raise a flag), and the shared test fixture `LAFTestBase.sol` registers one; both reproduce v1 behaviour and leave staleness expiry effectively off; the multi-reporter guarantees are exercised in `SignalMonitorTest` (3 reporters, quorum 2, 1-day window, plus a quorum = 16 boundary case), not in the deploy script. Choosing production defaults (for example 3 of 5 reporters and a 7-day window) is one of the open v2 questions. What remains: the median tolerates fewer than half of the fresh reporters colluding; a colluding majority can still both trigger and suppress. Reporter staking and slashing, and the off-chain oracle network itself, are outside this prototype.
3. **Governance tradeoff after removing quadratic weighting.** Share-weighted voting prevents wallet splitting from creating extra weight, but it gives large holders influence in proportion to their stake. The 2026-09-27 revision uses a quorum above 50 % of snapshot supply, so a 40 % holder cannot act alone. Identity-aware or bond voting remains research work.
4. **Governance apathy defaults to CONTINUE** (`test_stress_governanceApathy`); an inattentive holder base gives no protection.
5. **"Boiling frog"**: misuse within the permitted streaming rate is undetectable by any layer.
6. **Bank-run false positives**: honest teams get paused by Rule 2 in a panic (scenario #7); bounded pause and checkpoint override are the only mitigations.
7. **Simulator limitations**: `rda_volatility` is constant because the RDA price path is deterministic; the RDA loop calls `tick()` before `try_buy()` so agents never see the start price or the final round; DAICO vs RDA "total raised" is not like-for-like; no secondary market. In v5 there is no exogenous project-deterioration process, so LAF's exit behaviour rests on assumption A4 (see the LAF note and the sensitivity file); the commit-inactivity signal has no counterpart in the model.
8. **Not done**: quantitative intermediary and jurisdictional analysis (RQ3 and RQ4 are discussed qualitatively in the final report, as agreed with the mentor); a second coder for the dataset; recalculation of the counterfactual estimates under the current rules; a public testnet deployment; and an independent professional audit. Journals and the final report are separate submissions and are not included in this repository.

## Status of the research-readiness items (October 2026)

The five items proposed on 3 October and how they were closed:

1. **Normalize the empirical unit of analysis.** Done: stable row and entity
   identifiers, record types, duplicate links and eligibility decisions are in
   `03-dataset/coding/row_codes.csv`; totals are recomputed from eligible
   campaigns.
2. **Apply the failure codebook.** Done for every row by one coder, with dated
   evidence for each failed campaign; the second-reviewer step remains open.
3. **Build a versioned simulation for the current prototype.** Done:
   `01-simulation/capstone_sim_v6.py`, with v5 preserved and a parity check.
4. **Add failure and honest-project scenarios.** Done for an honest team under
   a bank run, a malicious team at the maximum permitted rate, gradual
   deterioration and a team-aligned whale; governance apathy as a separate
   scenario and strategic team behaviour remain future work.
5. **Revisit counterfactuals and open research questions.** RQ3/RQ4 are
   treated qualitatively in the final report; the analytical counterfactual
   estimates are kept and labelled as pre-revision estimates.

**Evidence boundary:** the dated 11 October verification includes raw output
and provenance for the current Solidity sources. Historical v5 simulation
results describe the earlier rules and v6 models the current rules under the
same behavioural assumptions; neither, and no passing contract test,
establishes real-world investor recovery or project-success rates. The 17 October
review run is retained in `02-solidity/test-output/verification-2026-10-17/`
(106 tests). The current record, after the independent review that locked the
module roles and opened exits before funding close, is
`02-solidity/test-output/verification-2026-10-17-role-lock/`: 117 tests passed,
no tests failed or skipped, and ten invariant properties passed under Foundry
v1.8.5 / solc 0.8.28. A gas report for the same tree is in
`02-solidity/test-output/gas-report-2026-10-17.txt`.

The prototype is not an audited or production-ready fundraising system. The
deploy script requires a team address distinct from the deployer/admin, and the
vault and share token lock their value-moving roles after a one-time module
setup, so the admin cannot later grant itself team, rage-quit, governor, mint
or burn rights. The admin is still trusted for that setup, for closing funding
and for the signal layer (reporter set and signal role); the reporter
configuration remains a 1-of-1 development setting and the script registers no
reporter at deployment. A production deployment would need an independently
governed admin, a multi-reporter oracle setup and testnet review. The required
environment variables, the setup checks investors should make and the
funding-rate bound are documented in `02-solidity/DEPLOYMENT.md`; known rule
limitations are listed in `02-solidity/PROTOTYPE-V2-CHANGES.md`.

## Not included / available on request

`02-solidity/lib/` (forge-std, OpenZeppelin v5.7.0; 17 MB, restorable with `forge install`), `out/` and `cache/` build artefacts, internal meeting notes, review notes, status logs, journals and email drafts, and Chinese-language working notes. Nothing in this package exceeds 1 MB.

The numbers above are taken directly from the three files in `05-counterfactuals/`.
