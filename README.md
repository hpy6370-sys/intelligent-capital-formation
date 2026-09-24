# LAF Capstone: artefacts and results to date

**Project:** Intelligent Capital Formation
NTU SC6131 MSc Capstone, in collaboration with the Ethereum Foundation. Industry mentor: Shyam Sridhar.

## What you asked for on 28 August, and where it is

| Your request | Where to look |
|---|---|
| Results from the simulations that test various counterfactuals | `05-counterfactuals/` (5-case analysis, 27-scenario matrix, 9 P0 deep dives) and `01-simulation/` (Monte Carlo, 7 behavioural scenarios x 3 project profiles; v5 of 2026-09-08 adds LAF alongside DAICO and RDA on the same agents, see `01-simulation/LAF-SIMULATION-NOTE.md`). Key numbers are summarised in "Key results" below |
| Working flow of the Solidity prototype | `02-solidity/WALKTHROUGH.md` (one page: deployment order, the full lifecycle step by step, each step mapped to the function and the integration test that exercises it), then `02-solidity/test/integration/CrossLayerTest.sol` |
| DAICO data gap | Not fillable from public sources (only 4 of 11 DAICO raises moved funds); listed as Limitation 1 and future work below |
| Intermediary roles and legal/regulatory aspects | Reserved for the discussion section of the final report, with a first pass in Journal 2; not in this package (Limitation 8) |
| All results, artefacts and work so far | This package. `MANIFEST.txt` lists every file with its size |

How the counterfactuals are delivered. `05-counterfactuals/` answers "what would LAF have done in a specific known failure": each of the five cases and nine P0 scenarios is worked through by hand against the layer rules at one parameter point (100 ETH streamed over 365 days), so its recovery figures (derived for six of the nine P0 scenarios; the other three are left undetermined in the file) are analytical estimates with no distribution behind them. `01-simulation/` answers a different question, "how do the same agents fare under DAICO, RDA and LAF across FOMO/herding scenarios": v5 puts LAF on the v4 Monte Carlo agents (N = 50 per cell, 7 x 3 cells) and reports distributions, but it has no malicious-team or exogenous-deterioration process, so it does not reproduce the rug-pull or gradual-decline cases in 05. The two overlap only where investor exits drive the outcome: the bank-run scenario (#7) corresponds to the Rule 2 pause and rage-quit recovery columns in v5, and the governance-apathy scenario (#16) to the abstention-driven CONTINUE resolutions. Monte Carlo versions of the malicious-team scenarios (Proposal v3 section 7.3) are the next step and are not in this package.

## What the project is

Existing on-chain fundraising mechanisms (ICO, reverse Dutch auction, bonding curve, DAICO, LBP) solve token *allocation*; none of them constrains what the team does with the money afterwards. The working hypothesis is that most failures are accountability gaps, not allocation-design flaws. The proposed answer is the **Layered Accountability Framework (LAF)**, a defence-in-depth composition of four independent layers, each targeting one failure mode and each still useful if the others are compromised:

| Layer | Contract | Mechanism |
|---|---|---|
| 1 Streaming Release | `LAFVault` | Team can only `claim()` funds at a linear `ratePerSecond`; capped by elapsed time and by unreleased balance |
| 2 Rage Quit | `RageQuitModule` | Any share holder can exit any time, pro rata of the unreleased pool, no vote needed (works during pause and terminal state) |
| 3 Checkpoint Voting | `QuadraticGovernor` | Every 90 days a 14-day window; sqrt-weighted vote on CONTINUE / INCREASE_RATE / DECREASE_RATE / PAUSE_FOR_AUDIT / HALT; quorum 20 %, majority 50 %; no quorum = CONTINUE |
| 4 Signal Monitor | `SignalMonitor` | 5 health metrics (TVL decline, active-address decline, team outflow, commit inactivity, HHI increase) with warning/critical thresholds, each reported by a registered set of up to 16 reporters; a metric only has an effective value when at least `quorum` reporters have submitted within `reportWindow`, taken as the median of those fresh submissions (v2). >=2 warnings or >=1 critical requests an early checkpoint from the Governor. It never touches the vault |

Inter-layer rules (all in code, defaults in `02-solidity/script/DeployLAF.s.sol`): Rule 2, cumulative rage quit >25 % of the unreleased balance snapshotted at window open auto-pauses the vault; Rule 3, signal-triggered checkpoints rate-limited to one per 30 days; Rule 4, unreleased balance <10 % of total deposits puts the vault in a one-way terminal state. Pause is bounded (30-day default response period, 60-day maximum).

## What is in each folder

- `01-simulation/` Monte Carlo simulator. `capstone_sim_v4.py` (v4.2, DAICO vs reverse Dutch auction, calibrated to dataset figures) and `capstone_sim_v5.py` (v5.0, adds LAF on the same agents and scenarios without changing the v4 numbers), `capstone_viz_v4.py` / `capstone_viz_v5.py` (5 figures + PDF each), `sim_v5_sensitivity.py` (sensitivity of the LAF results to assumption A4), `verify_daico_patch.py` (checks the DAICO voting-threshold fix), stored outputs in `output/`, figures in `figures/` (v5 files carry a `_v5` suffix). `LAF-SIMULATION-NOTE.md` explains the LAF modelling assumptions, the three-mechanism results and four design findings for the prototype. Configuration is in-code (`SCENARIOS`, `RealDataCalibration`, `N = 50`); there is no separate config file and no CSV/JSON export, the simulator prints to stdout.
- `02-solidity/` Foundry project: 5 contracts (1,062 lines) + 4 interfaces (198 lines) in `src/`, deploy script (84 lines), tests in `test/` (unit, integration, stress, invariant), `foundry.toml` / `foundry.lock`. Build artefacts (`out/`, `cache/`) and vendored deps (`lib/`, 17 MB) are excluded; see install notes below. `test-output/forge-test.txt` is the full log of the run made while packaging (2026-09-08).
- `03-dataset/` The merged, source-verified 82-project dataset (2026-08-31; ICO 18 / RDA 14 / bonding curve 16 / DAICO 11 / LBP 23, each row with source link and confidence). It supersedes the May 50-project draft and the August expansion list; the file's changelog records how it was built. A six-mode failure taxonomy (exit scam, soft rug, governance failure, liquidity trap, slow death, regulatory shutdown) is drafted in Proposal v3 but projects have not yet been classified against it; that is pending work, not an artefact here.
- `04-docs/` Solidity design document (English; written before implementation, so a few interface names and event signatures differ from the shipped code, which `02-solidity/WALKTHROUGH.md` describes as built), Proposal v3 (English) and the submitted Journal 1 (PDF).
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
PYTHONIOENCODING=utf-8 python verify_daico_patch.py             # ~4 min; UTF-8 needed for its console output on Windows
```

Solidity (Foundry; verified with forge 1.7.1, solc 0.8.28 pinned in `foundry.toml`):

```
cd 02-solidity
forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.7.0 --no-git   # versions as in foundry.lock
forge build
forge test          # 83 tests; add -vv for the stress-test logs
```

Result of the packaging run (2026-09-08): `Ran 7 test suites: 83 tests passed, 0 failed, 0 skipped`, each of the 10 invariants with `runs: 128, calls: 8192` (`[invariant] runs = 128, depth = 64` in `foundry.toml`).

## Key results (each with the file that produces it)

**Simulation** (`01-simulation/output/simulation_v4_results.txt`, N = 50 Monte Carlo per scenario, 7 behavioural scenarios x 3 profiles: v3 defaults n = 30 agents, calibrated small project n = 20, calibrated large project n = 340; 5 agent types: rational, speculator, whale, FOMO follower, late entrant)
- FOMO improves RDA allocation fairness: RDA Gini 0.516 (baseline) to 0.401 (FOMO = 0.7), top-10 % share 36.4 % to 27.6 %, whale dominance 38.8 % to 28.4 % (v3-defaults profile). Same direction in both calibrated profiles (small: 0.544 to 0.425; large: 0.564 to 0.432).
- DAICO allocation is FOMO-invariant: within each profile the DAICO Gini moves by at most 0.003 across the 7 scenarios (v3 defaults 0.486-0.489, small 0.475-0.478, large 0.518-0.521), because contribution maps 1:1 to tokens. DAICO ROI dispersion across agent types is 0 by construction.
- DAICO governance does not scale: in the large-project profile (n = 340) the destroy vote triggers in 0 % of runs in every scenario, and `verify_daico_patch_output.txt` (header in Chinese; the tables are self-explanatory) shows that even after the dynamic-threshold patch destroy stays at 0 % at n = 340 (3.8 % at n = 5). This mirrors the empirical near-zero DAICO adoption.
- Calibration provenance is printed at the top of the results file (Abyss average contribution $3,137; Algorand clearing at 24 % of start price; tap rates flagged as assumptions).

**LAF in the simulation** (`01-simulation/output/simulation_v5_results.txt`, v5.0 of 2026-09-08; same agents, same 7 x 3 scenarios; DAICO and RDA lines are byte-identical to v4; assumptions and the full tables are in `01-simulation/LAF-SIMULATION-NOTE.md`)
- The team receives more, and more reliably: v3-defaults profile LAF 43.4 % of the raise vs DAICO 33.2 %; small project 38.0 % vs 23.2 %. DAICO is destroyed in 24 % / 34 % of runs in those two profiles, LAF reaches its terminal state in 8 % / 2 %.
- Dissatisfied investors can leave with money: rage-quitters recover on average 73 % to 76 % of principal (v3 and small profiles, all scenarios); DAICO refunds only if the destroy vote passes and RDA never refunds.
- Dollar-outcome inequality is unchanged: LAF Gini on dollar outcomes 0.496 vs DAICO token Gini 0.487 (v3), 0.476 vs 0.477 (small).
- Where LAF does worse: in the large profile (n = 340, 560 days) every run hits Rule 4 (unreleased < 10 % of deposits) around day 450 (seed 0 at day 448; across the 50 seeds the terminal day ranges 420 to 525, mean 455) and goes terminal, with the team receiving 49 % to 58 % against DAICO's stable 47.4 %; end-of-run share concentration rises (Gini 0.487 to 0.669 in v3); sqrt weighting does not stop whales holding up to 80 % of cast weight because rational holders abstain.
- Four prototype design findings came out of this run (Rule 4 threshold definition, quorum trivially met by one 40 % whale, Rule 2 snapshot timing, signal layer silent without exogenous deterioration); they are set out in the note and are the first items for the v2 design discussion.
- The results are most sensitive to assumption A4 (DAICO's 3 % per-round destroy propensity translated into loss of confidence): at scale 0 LAF collapses exactly to the DAICO share distribution (checked), and the large-profile terminal cliff sits between scale 0.25 and 0.5 (`simulation_v5_sensitivity.txt`).

**Solidity prototype** (`02-solidity/`, `test-output/forge-test.txt`)
- 83/83 tests pass: `LAFVaultTest` 21 (incl. 1 fuzz), `RageQuitTest` 9, `QuadraticGovernorTest` 17 (added 2026-09-08 from section 7.3 of the design document: window timing, sqrt weighting, quorum and majority, all five resolve actions, Rule 3 rate limit, role checks; one test is renamed to record that a single 40 % holder meets quorum alone, and one is a regression for the unopened-checkpoint fix below), `SignalMonitorTest` 13 (v2 multi-reporter: registration, quorum bounds, median, staleness, flag clearing, role-mutation guards), `CrossLayerTest` 7, `StressTest` 5 (bank run, Sybil checkpoint, signal gaming, cascade, governance apathy), `LAFInvariant` 11 (10 invariants plus a handler sanity test).
- Fixed on 2026-09-08 while writing the governor tests: `resolveCheckpoint()` did not revert for a checkpoint id that had never been opened, so anyone could call it every 90 days, move `lastCheckpointEnd` forward and defer the scheduled checkpoint indefinitely (signal-triggered checkpoints were unaffected). A `windowStart == 0` guard now reverts with `WindowNotOpen`; `test_resolveCheckpoint_revertsForUnopenedId` pins it.
- Core invariant held over 8,192 random calls per property: `totalDeposited == totalClaimedByTeam + totalExitedViaRageQuit + vault balance` (`invariant_vaultBalanceEqualsAccountingIdentity`), plus outflow bound, terminal one-way, no claim while paused/terminal, share supply bounded.
- Working flow of the prototype: `deposit()` mints `LAFShareToken` 1:1 -> `closeFunding()` starts streaming -> team `claim()` -> holders `rageQuit()` at any time -> `openCheckpointWindow()` every 90 days (or `SignalMonitor.evaluate()` -> `triggerEarlyCheckpoint()`) -> `initiateAuditVote()` / `vote()` -> `resolveCheckpoint()` applies the action to the vault; `checkPoolDepletion()` and `resumeIfTimedOut()` are permissionless. `test/integration/CrossLayerTest.sol` walks through these paths end to end.

**Counterfactual and scenario analysis** (`05-counterfactuals/`; analytical estimates, not Monte Carlo output)
- Five historical cases (`counterfactual_analysis_5_cases.md`): estimated recoverable share of attributable losses under LAF: Fei Protocol ~50-70 % of ~$280M, Friend.tech ~50-70 % of $44M, The Abyss ~40-60 % of ~$14.5M, Ordibank ~70-80 % of ~$8M (low confidence), SKALE not applicable (pre-raise front-running is outside LAF scope). Layer-by-layer applicability tables per case.
- Nine P0 scenarios out of the 27-cell Team x Market x Adversary matrix (`scenario-deep-dive.md`), assuming a 100 ETH pool streamed over 365 days: investor recovery ~51 % in a typical rug pull at day 182 (vs ~0 % without LAF), ~75 % in a bear-market rug, ~82 % in the worst case (malicious team + bear + Sybil adversary), ~60 % in an honest-team bank run (where the honest team is the collateral damage), ~40 % in a gradual decline and ~30 % in a natural death under governance apathy (the two weakest cases). The file itself notes these are single-parameter-point estimates and that a sensitivity sweep is still to do.

## Known gaps and shortcomings (as admitted in the code and docs)

1. **DAICO data gap.** Of 11 DAICO rows only 4 raises actually moved funds (The Abyss, Aavegotchi, ICOVO, LUKSO rICO, ~$64M total), so DAICO calibration rests largely on The Abyss and the tap rate is an assumption. Listed as future work.
2. **Single trusted reporter (v1, addressed in v2 on 2026-09-07).** v1 pushed metrics from one `REPORTER_ROLE` address. v2 registers up to 16 reporters and, when deployed with `quorum` >= 2, requires that many fresh submissions per metric and takes their median, so no single reporter can raise a false alarm or suppress a real one on its own. The packaged `DeployLAF.s.sol` deploys with `quorum` = 1 and a 365-day `reportWindow` as a development default and registers no reporter (the admin adds them with `addReporter` after deployment, as the walkthrough describes; until then the monitor cannot raise a flag), and the shared test fixture `LAFTestBase.sol` registers one; both reproduce v1 behaviour and leave staleness expiry effectively off; the multi-reporter guarantees are exercised in `SignalMonitorTest` (3 reporters, quorum 2, 1-day window, plus a quorum = 16 boundary case), not in the deploy script. Choosing production defaults (for example 3 of 5 reporters and a 7-day window) is one of the open v2 questions. What remains: the median tolerates fewer than half of the fresh reporters colluding; a colluding majority can still both trigger and suppress. Reporter staking and slashing, and the off-chain oracle network itself, are outside this prototype.
3. **Sybil vulnerability of quadratic voting.** Transferable ERC-20 + sqrt weighting: 100 wallets x 0.1 ETH carry about 3.3x the weight of one 90 ETH wallet in `test_stress_sybilCheckpoint`, and about 10x the weight of a single 10 ETH wallet. Documented, not solved; bond voting (Mohan, Khezr & Berg 2024) is the v2 direction.
4. **Governance apathy defaults to CONTINUE** (`test_stress_governanceApathy`); an inattentive holder base gives no protection.
5. **"Boiling frog"**: misuse within the permitted streaming rate is undetectable by any layer.
6. **Bank-run false positives**: honest teams get paused by Rule 2 in a panic (scenario #7); bounded pause and checkpoint override are the only mitigations.
7. **Simulator limitations**: `rda_volatility` is constant because the RDA price path is deterministic; the RDA loop calls `tick()` before `try_buy()` so agents never see the start price or the final round; DAICO vs RDA "total raised" is not like-for-like; no secondary market. In v5 there is no exogenous project-deterioration process, so LAF's exit behaviour rests on assumption A4 (see the LAF note and the sensitivity file); the commit-inactivity signal has no counterpart in the model.
8. **Not yet done**: intermediary and jurisdictional/legal analysis (RQ3, RQ4 in Proposal v3) is to be handled in the discussion section of the final report, with a first pass in Journal 2; Journal 2 (due 2026-10-04) is in preparation and not included; the failure-mode taxonomy has not been applied to the dataset rows; no testnet deployment has been made.

## Not included / available on request

`02-solidity/lib/` (forge-std, OpenZeppelin v5.7.0; 17 MB, restorable with `forge install`), `out/` and `cache/` build artefacts, internal meeting notes, review notes, status logs, journals and email drafts, and Chinese-language working notes. Nothing in this package exceeds 1 MB.

The numbers above are taken directly from the three files in `05-counterfactuals/`.
