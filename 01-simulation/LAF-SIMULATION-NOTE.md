# LAF in the Monte Carlo simulation (v5.0, 2026-09-08)

## 1. What was added

v5 adds LAF as a third mechanism to the v4 Monte Carlo harness next to DAICO and RDA, on the same agents and the same 7 scenarios x 3 scales, N=50 runs per cell, fixed seeds. DAICO and RDA results are unchanged: the v4 scripts were not edited; v5 imports them, calls `v4.run_single()` as is, then replays the fundraising prefix under the same seed to recover the identical agents, with an assert that the replayed raise equals the v4 pool plus released amount (relative error 1e-9), passing in all 50 x 21 runs. Of the 622 v4 output lines only the 2 header lines differ in v5, the other 620 appear verbatim, and v5 appends 555 lines. Three consecutive v5 runs are byte-identical. LAF uses its own `random.Random(seed x 1000003 + 20260908)`, so the global random stream is consumed only by v4 code.

## 2. Modelling assumptions

Identical to `LAF_ASSUMPTIONS` in the code, printed at the top of the output.

**A1 Population.** Same agents as DAICO, same seed. Each agent's DAICO contribution is its LAF deposit, shares minted 1:1 (`LAFVault.deposit()`). No new agents, no secondary market. RDA keeps its own v4 population: it is a fundraising-stage mechanism, not a post-raise layer.

**A2 Time.** 1 round = 7 days: v3 50 rounds = 350 days, small 20 rounds = 140 days, large 80 rounds = 560 days. Checkpoints every 90 days, 14-day window, giving 3 / 1 / 5 scheduled checkpoints (the interval is measured from the previous resolution, so one cycle is 90 + 14 days).

**A3 Release rate.** ratePerRound = tap_rate x total raised, linear on the initial raise. Same nominal rate parameter as DAICO, which decays geometrically on the remaining pool. The team claims every round. Release cap with no intervention: 50% / 40% / 64%.

**A4 Loss of confidence.** The DAICO destroy-vote probability p = max(0.005, 0.03 - 0.02 x fomo) is reused unchanged as the per-round probability that a rational or whale enters the persistent concerned state. The most sensitive assumption in the set; see section 7.

**A5 Exit rules** (full exit only, no partial exit):
- rational: exits when concerned or when any CRITICAL signal is live; under WARNING p=0.5 per round. Exit precedes voice.
- whale: voice first. When concerned it votes PAUSE_FOR_AUDIT at the next checkpoint and exits only if that resolves CONTINUE (voice failed). Exits at once on CRITICAL.
- speculator: no token price, so "exit at a profit" cannot be modelled; treated as a trend follower: p=0.5 per round under WARNING, p=0.5 after a PAUSE or HALT resolution, always on CRITICAL.
- fomo_follower: per round p = herding_sensitivity x (share of supply that rage quit over the previous four rounds (28 days)), plus 0.5 under CRITICAL.
- late_entrant: passive, p=0.5 only under CRITICAL.
- all: when the vault turns terminal (Rule 4) everyone exits pro rata; that is the Rule 4 liquidation.

**A6 Voting** (weight sqrt(shares at window open), one vote per holder per window, current holders only):
- An audit vote opens only if a holder is concerned or a signal is live; otherwise the window closes as CONTINUE (governance apathy, Limitation 5).
- rational: PAUSE_FOR_AUDIT under CRITICAL, DECREASE_RATE under WARNING, else abstains.
- whale: PAUSE_FOR_AUDIT when concerned or under CRITICAL, DECREASE_RATE under WARNING, else CONTINUE.
- speculator: INCREASE_RATE with p = 0.15 + 0.15 x fomo (the DAICO raise-vote rule), else abstains.
- fomo_follower: joins the current plurality (the action with the largest tally so far, which may be below 50%) with p = herding_sensitivity (tallied last), else abstains.
- late_entrant: abstains.

**A7 Resolution** (mirrors `QuadraticGovernor.resolveCheckpoint`). quorum = 20% x sqrt(total shares at window open) (the contract uses `totalSupply()` at resolution time, i.e. after in-window rage quits, so the simulated quorum base is slightly larger than the contract's); the winner needs over 50% of cast weight, else CONTINUE. INCREASE and DECREASE step the rate by 30% of the initial rate (cap 15% of the raise per round, floor 0). PAUSE_FOR_AUDIT pauses 30 days. HALT sets the rate to 0 until a later INCREASE_RATE. Pauses end by timeout (Rule 1b); no separate resume vote.

**A8 Rule 2** (mirrors the contract). Cumulative rage quits since the last window open above 25% of the balance snapshot at that open pause the vault 60 days. Before the first window the snapshot is 0 and the rule is inactive, as in `LAFVault.withdrawForRageQuit`.

**A9 Rule 4.** Unreleased balance < 10% of the raise is terminal: rate 0, everyone exits pro rata. No new checkpoints open and signals stop (a window already open at that moment is still resolved and counted), since `claim()` reverts permanently and no governor action matters; their counts describe only the live phase.

**A10 Signal proxies.** TVL = vault balance; active addresses = holders with shares > 0; team outflow = current rate / initial rate; HHI = sum of squared share fractions; all compared with 28 days (4 rounds) earlier. Early checkpoints at most once per 30 days, never while a window is open (Rule 3).

**A11.** No exogenous project-failure process in the FOMO/herding scenarios; the signal layer fires only when agents' own exits push a proxy over its threshold.

## 3. Metrics that cannot be computed and why

| Metric | Status | Reason |
|---|---|---|
| COMMIT_INACTIVITY (signal 3) | skipped | Needs a GitHub commit stream; the model has no development-activity variable |
| speculator "exit at a profit" | replaced by trend following | No token price, so no notion of profit or loss; LAF share NAV only falls monotonically as funds are released |
| LAF price volatility (counterpart of RDA volatility) | not applicable | LAF has no auction price series |
| LAF timing corr | computed but structural | Correlation between exit round and recovery is -0.99, because recovery is simply the NAV at exit and NAV falls linearly. It shows that "leave early, take more" is endogenous to the mechanism, not a manipulation signal |
| TEAM_OUTFLOW signal | computed, never fires | The rate can only be raised by INCREASE_RATE votes; reaching 3x needs 7 consecutive increases, which never occurred in the 21 scenarios |
| partial rage quit, secondary transfer, malicious team | not modelled | These are the LAF-specific stress scenarios of Proposal v3 section 7.3, outside the scope of "same agents, same scenarios" |

Averages for laf_whale_vote_share, laf_timing_corr and laf_recovery_quitters skip undefined runs (nobody voted / fewer than 3 quitters / nobody quit); everything else averages over N=50 as in v4.

## 4. Results

Column key. DAICO Eff: release efficiency, destroyed runs count as 0. RDA Partic: participants. LAF TeamRcv: share of the raise the team received (capital retention). Gini$: Gini of dollar outcomes (rage-quit proceeds plus remaining shares at final NAV), same basis as the DAICO token Gini since DAICO tokens are 1:1 with dollars. RecovQ: average share of principal recovered by quitters. RecovAll: rage-quit proceeds over total raise. Quit: share of agents that exited. Term: share of runs terminated by Rule 4. WhaleVote: whale share of cast vote weight. PAUSE / INCREASE: PAUSE_FOR_AUDIT / INCREASE_RATE resolutions passed per run. R2: Rule 2 automatic pauses per run.

### v3 defaults (30 agents, 50 rounds = 350 days, tap 0.01)

| Scenario | DAICO Eff / Gini / Whale / Destroy | RDA Gini / Whale / Partic | LAF TeamRcv / Gini$ / Whale | RecovQ / RecovAll / Quit / Term | WhaleVote / PAUSE / R2 |
|---|---|---|---|---|---|
| Baseline | 33.2% / 0.487 / 40.5% / 24% | 0.516 / 38.8% / 24.4 | 43.4% / 0.496 / 39.9% | 74.5% / 34.0% / 45.5% / 8% | 74.3% / 0.52 / 0.66 |
| FOMO 0.3 | 40.1% / 0.487 / 40.8% / 14% | 0.414 / 30.9% / 30.0 | 45.5% / 0.498 / 39.8% | 75.1% / 29.9% / 39.7% / 2% | 69.1% / 0.36 / 0.60 |
| FOMO 0.5 | 47.1% / 0.488 / 40.9% / 4% | 0.407 / 29.4% / 30.0 | 46.4% / 0.498 / 40.3% | 75.5% / 28.5% / 38.3% / 2% | 69.4% / 0.26 / 0.52 |
| FOMO 0.7 | 48.3% / 0.489 / 41.1% / 10% | 0.401 / 28.4% / 30.0 | 46.7% / 0.499 / 39.0% | 76.0% / 27.2% / 36.5% / 0% | 67.7% / 0.16 / 0.50 |
| F0.5+H0.3 | 49.8% / 0.487 / 40.7% / 22% | 0.407 / 29.3% / 30.0 | 45.0% / 0.475 / 45.2% | 74.4% / 32.9% / 51.6% / 6% | 57.5% / 0.44 / 0.54 |
| F0.5+H0.6 | 61.3% / 0.486 / 40.4% / 20% | 0.406 / 29.2% / 30.0 | 45.2% / 0.473 / 44.3% | 73.3% / 34.5% / 56.8% / 10% | 54.6% / 0.40 / 0.66 |
| F0.7+H0.5 | 64.4% / 0.488 / 40.7% / 14% | 0.400 / 28.3% / 30.0 | 45.1% / 0.473 / 46.6% | 73.2% / 32.2% / 53.2% / 4% | 55.9% / 0.36 / 0.72 |

### small_project (20 agents, 20 rounds = 140 days, tap 0.02)

| Scenario | DAICO Eff / Gini / Whale / Destroy | RDA Gini / Whale / Partic | LAF TeamRcv / Gini$ / Whale | RecovQ / RecovAll / Quit / Term | WhaleVote / PAUSE / R2 |
|---|---|---|---|---|---|
| Baseline | 23.2% / 0.477 / 38.3% / 34% | 0.544 / 43.5% / 16.2 | 38.0% / 0.476 / 40.3% | 74.7% / 18.8% / 26.7% / 2% | 79.8% / 0.12 / 0.14 |
| FOMO 0.3 | 28.8% / 0.477 / 38.6% / 26% | 0.445 / 37.0% / 20.0 | 38.4% / 0.476 / 40.3% | 75.3% / 16.4% / 23.0% / 0% | 78.5% / 0.10 / 0.10 |
| FOMO 0.5 | 27.9% / 0.477 / 38.7% / 26% | 0.432 / 35.2% / 20.0 | 38.4% / 0.475 / 40.4% | 74.8% / 16.0% / 23.0% / 0% | 76.7% / 0.10 / 0.12 |
| FOMO 0.7 | 32.8% / 0.478 / 38.9% / 16% | 0.425 / 34.0% / 20.0 | 38.8% / 0.475 / 40.2% | 75.0% / 15.5% / 22.2% / 0% | 75.9% / 0.06 / 0.12 |
| F0.5+H0.3 | 37.7% / 0.476 / 38.5% / 12% | 0.432 / 35.1% / 20.0 | 38.4% / 0.470 / 40.8% | 76.1% / 15.7% / 26.3% / 2% | 61.7% / 0.12 / 0.12 |
| F0.5+H0.6 | 41.6% / 0.475 / 38.3% / 14% | 0.433 / 35.0% / 20.0 | 37.8% / 0.468 / 39.3% | 75.8% / 19.8% / 32.9% / 8% | 60.6% / 0.12 / 0.18 |
| F0.7+H0.5 | 38.3% / 0.477 / 38.6% / 18% | 0.424 / 33.8% / 20.0 | 39.1% / 0.469 / 40.6% | 76.1% / 17.4% / 30.6% / 4% | 58.1% / 0.06 / 0.12 |

### large_project (340 agents, 80 rounds = 560 days, tap 0.008)

| Scenario | DAICO Eff / Gini / Whale / Destroy | RDA Gini / Whale / Partic | LAF TeamRcv / Gini$ / Whale | RecovQ / RecovAll / Quit / Term | WhaleVote / INCREASE / R2 |
|---|---|---|---|---|---|
| Baseline | 47.4% / 0.519 / 43.7% / 0% | 0.564 / 43.1% / 271.8 | 49.3% / 0.648 / 0.0% | 50.7% / 50.7% / 100% / 100% | 59.7% / 1.08 / 0.78 |
| FOMO 0.3 | 47.4% / 0.519 / 43.9% / 0% | 0.442 / 31.9% / 340.0 | 52.4% / 0.647 / 0.0% | 47.6% / 47.6% / 100% / 100% | 56.9% / 1.16 / 0.48 |
| FOMO 0.5 | 47.4% / 0.520 / 44.1% / 0% | 0.435 / 30.6% / 340.0 | 54.6% / 0.646 / 0.0% | 45.4% / 45.4% / 100% / 100% | 56.7% / 1.22 / 0.22 |
| FOMO 0.7 | 47.4% / 0.521 / 44.3% / 0% | 0.432 / 30.1% / 340.0 | 57.8% / 0.644 / 0.0% | 42.2% / 42.2% / 100% / 100% | 56.1% / 1.28 / 0.04 |
| F0.5+H0.3 | 47.4% / 0.519 / 43.8% / 0% | 0.435 / 30.6% / 340.0 | 49.8% / 0.585 / 0.0% | 50.2% / 50.2% / 100% / 100% | 46.5% / 0.76 / 0.60 |
| F0.5+H0.6 | 48.0% / 0.518 / 43.5% / 0% | 0.436 / 30.6% / 340.0 | 49.2% / 0.568 / 0.0% | 50.8% / 50.8% / 100% / 100% | 50.0% / 0.82 / 0.66 |
| F0.7+H0.5 | 47.9% / 0.520 / 43.8% / 0% | 0.432 / 30.1% / 340.0 | 51.1% / 0.569 / 0.0% | 48.9% / 48.9% / 100% / 100% | 47.8% / 0.80 / 0.48 |

PAUSE_FOR_AUDIT passes 0.00 times in all 7 large scenarios: the concerned whales at any checkpoint are a small fraction of the 40 whales, the rest vote CONTINUE, so PAUSE never reaches 50%. Those whales then exit as a block, the electorate tilts toward speculators, and INCREASE_RATE passes about once per run.

Other LAF metrics in the baseline scenario (v3 / small / large): Gini of final shares (quitters counted as 0) 0.669 / 0.607 / 0.000; top 10% share 51.7% / 46.3% / 0%; timing corr -0.991 / -0.996 / -0.991; ROI dispersion 0.1220 / 0.0383 / 0.2232 (DAICO is always 0, RDA 0.0731 / 0.0513 / 0.0571); checkpoints per run 2.96 / 1.00 / 3.84; signal fires per run 0.06 / 0.08 / 0.00; paused days 44.4 / 7.0 / 43.7.

## 5. Where LAF does better and where it does worse

Better:
1. The team receives more, more reliably: v3 baseline LAF 43.4% vs DAICO 33.2%, small 38.0% vs 23.2%. DAICO destroys 24% / 34% of runs to zero; LAF reaches terminal in 8% / 2%. A linear stream is not dragged down by a shrinking pool, and individual exits do not cut off the team's future funding the way a collective destroy does.
2. Dissatisfied investors leave with money: quitters recover 73% to 76% of principal in all v3 and small scenarios. DAICO refunds only if destroy passes; an RDA purchase is final.
3. Dollar outcomes are not distributed worse: Gini$ at v3 / small is essentially the DAICO token Gini (0.496 vs 0.487, 0.476 vs 0.477), so no agent type systematically captures the exit-timing advantage.
4. Governance capacity is real: about 3 checkpoints per run at v3, PAUSE passes 0.16 to 0.52 times per run, and stronger herding brings more fomo_followers to the vote, cutting the whale share of cast weight from 74% to 55%.

Worse:
1. Long projects are terminated by Rule 4: at the large scale 100% of runs reach terminal around day 450 and the team receives 49% to 58%, while DAICO gives a stable 47.4% with 0% destroy. See section 6.
2. Final shares are more concentrated than at raise time: the whale share among stayers is unchanged (about 40%), but more rationals leave, so the Gini of final shares rises from 0.487 to 0.669 (v3) and the top 10% share from 39% to 52%.
3. sqrt weighting does not restrain whales: they hold about 40% of shares but 55% to 80% of cast weight, because rationals abstain by default and late_entrants never vote. sqrt trims one large holder; it cannot fix "only large holders show up".
4. Leaving early pays, structurally: timing corr is -0.99, whoever leaves first gets the higher NAV, an information-advantage channel DAICO does not have.
5. RDA is still the only mechanism that pushes Gini to around 0.4 under FOMO (0.400 to 0.445). LAF, like DAICO, is insensitive to FOMO because its fundraising stage is untouched by it; only herding moves LAF outcomes, through follow-on exits.

## 6. Four design findings for the prototype

1. **Rule 4 threshold.** Phenomenon: `unreleased < 10% x totalDeposited` treats "64% vested normally, then 30% of holders exit" as depletion. Large baseline trace (seed 0): day 448, claimed 51%, exited 39%, remainder under 10%, terminal. Cause: the threshold is relative to the initial raise, so it cannot tell a nearly complete vesting schedule from a drained vault. Fix: define it relative to the unvested balance, or switch Rule 4 off once released funds pass a set fraction.
2. **Quorum is trivially met.** Phenomenon: quorum never bound in any run; only the 50% majority did. Cause: 20% x sqrt(totalSupply) is compared with sum(sqrt(balance_i)); one whale with 40% of shares supplies sqrt(0.4) = 63% of sqrt(total) and clears quorum alone. Fix: define quorum on the same aggregate as the vote weights, or on a head count.
3. **Rule 2 snapshot timing.** Phenomenon: a single-round block exit of 13.2% of the raise (16.7% of supply, day 112; cumulative exits had reached 21.6% by then) in the large baseline did not trigger Rule 2. Cause: the snapshot is taken at window open, but the block exit comes after the checkpoint resolves (whales exit only when voice fails), when the window is closed and the snapshot stale, so cumulative exits often miss 25%. Fix: a rolling threshold (the other reading of design document section 8, question 3) would be stricter.
4. **The signal layer is nearly inert without exogenous deterioration.** Phenomenon: across 21 scenarios signals fire 0 to 0.08 times per run, always because of agent exits themselves. Cause: A11. Fix: stress-test the layer with the dedicated section 7.3 scenarios rather than FOMO/herding.

## 7. Sensitivity to assumption A4

`sim_v5_sensitivity.py` multiplies the A4 loss-of-confidence probability by 1.0 / 0.5 / 0.25 / 0.0 and runs the baseline scenario (output in `output/simulation_v5_sensitivity.txt`):

| Scale | scale | TeamRcv | RecovAll | RecovQ | Quit | Term | Gini$ | PAUSE | R2 |
|---|---|---|---|---|---|---|---|---|---|
| v3 | 1.00 | 43.4% | 34.0% | 74.5% | 45.5% | 8% | 0.496 | 0.52 | 0.66 |
| v3 | 0.50 | 47.5% | 25.7% | 72.7% | 30.9% | 2% | 0.513 | 0.18 | 0.42 |
| v3 | 0.25 | 50.0% | 12.6% | 69.1% | 16.8% | 0% | 0.492 | 0.08 | 0.10 |
| v3 | 0.00 | 50.0% | 0.0% | n/a | 0.0% | 0% | 0.487 | 0.00 | 0.00 |
| small | 1.00 | 38.0% | 18.8% | 74.7% | 26.7% | 2% | 0.476 | 0.12 | 0.14 |
| small | 0.50 | 38.8% | 11.2% | 77.1% | 15.9% | 0% | 0.476 | 0.10 | 0.06 |
| small | 0.25 | 39.0% | 6.7% | 76.9% | 8.6% | 0% | 0.477 | 0.08 | 0.04 |
| small | 0.00 | 40.0% | 0.0% | n/a | 0.0% | 0% | 0.477 | 0.00 | 0.00 |
| large | 1.00 | 49.3% | 50.7% | 50.7% | 100.0% | 100% | 0.648 | 0.00 | 0.78 |
| large | 0.50 | 60.6% | 38.8% | 41.0% | 96.1% | 98% | 0.659 | 0.00 | 0.00 |
| large | 0.25 | 64.0% | 19.7% | 62.1% | 24.2% | 2% | 0.605 | 0.00 | 0.00 |
| large | 0.00 | 64.0% | 0.0% | n/a | 0.0% | 0% | 0.519 | 0.00 | 0.00 |

Two validation points. At scale 0 the team receives exactly tap_rate x rounds (50% / 40% / 64%) and Gini$ equals the DAICO Gini exactly (0.487 / 0.477 / 0.519), so with no dissatisfaction LAF degenerates to the DAICO share distribution and the pipeline is sound. At the large scale the terminal cliff sits between scale 0.25 (2%) and 0.5 (98%): once the per-round loss-of-confidence probability exceeds roughly 1%, a 560-day project is terminated by Rule 4.

## 8. Figures

All in `01-simulation/figures/` in this package. The five v4 figures sit in the same directory for side-by-side comparison and are not overwritten (their filenames carry no suffix).

| File | Content |
|---|---|
| `fig1_gini_comparison_v5.png` | Three-mechanism Gini, one panel per scale, 7 scenarios as grouped bars, 0.4 threshold line |
| `fig2_fomo_fairness_v5.png` | Gini vs FOMO from 0 to 0.7, small / large, with the LAF line added |
| `fig3_efficiency_tradeoff_v5.png` | Team share received vs Gini; grey lines connect the DAICO and LAF points of the same scenario and same agents |
| `fig4_laf_capital_split_v5.png` | Stacked bars of where the LAF raise went (team / returned to investors / left in vault), DAICO retention marked as reference |
| `fig5_metric_heatmap_v5.png` | 21 rows x 10 columns heatmap, left 5 columns v4 metrics, right 5 columns LAF metrics, orange worse, blue better |
| `capstone_v5_figures.pdf` | The five figures above in one file |

Colours are fixed per mechanism: DAICO blue #0173B2, RDA orange #DE8F05, LAF green #029E73 (seaborn colorblind), checked for CVD separation and contrast. The heatmap uses an orange-grey-blue diverging scale instead of the v4 red-yellow-green. No dual-axis charts.

## 9. How to reproduce

Run from `01-simulation/` in the package, N=50, all 7 scenarios x 3 scales:

```
python capstone_sim_v5.py > output/simulation_v5_results.txt
python capstone_viz_v5.py
python sim_v5_sensitivity.py > output/simulation_v5_sensitivity.txt
```

Measured run times: simulation 12.7 s, figures 18.8 s, sensitivity 6.7 s. Rerunning v4 alone gives an empty diff against `output/simulation_v4_results.txt` (md5 8f116354...).
