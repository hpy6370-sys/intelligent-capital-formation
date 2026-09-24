# LAF 3x3x3 Scenario Matrix

> Sprint B task #10
> Provides a systematic framework for the simulation and analysis chapter of Journal 2

## Three dimensions

### Dim 1: Team Integrity

| Level | Definition | Behaviour pattern |
|------|------|---------|
| **Honest** | A team that genuinely does the work | Develops to plan, updates regularly, uses funds reasonably |
| **Negligent** | Not malicious but irresponsible | Development delays, less communication, opaque use of funds but no exit |
| **Malicious** | Premeditated fraud | Plans to siphon funds after deployment, fakes progress, plans a rug pull |

### Dim 2: Market Condition

| Level | Definition | Effect on LAF |
|------|------|-------------|
| **Bull** | Prices rising, sentiment optimistic | Investors in no hurry to exit; few rage quits; low governance participation (everyone is making money, who watches governance) |
| **Neutral** | Sideways | Normal participation, occasional rage quit |
| **Bear** | Prices falling, panic spreading | Rage quits cluster; bank-run risk; signals trigger frequently |

### Dim 3: Adversary

| Level | Definition | Attack methods |
|------|------|---------|
| **None** | No external adversary | Purely internal governance scenario |
| **Opportunistic** | Exploits a crisis | Buys share tokens cheaply during a market panic, pushes up the rage quit ratio to extract a larger share |
| **Sophisticated** | Coordinated multi-vector attack | Sybil voting + signal gaming + flash loan manipulation |

---

## 27 scenario combinations

> ★ = covered by stress test  ☆ = mapped by counterfactual analysis  ○ = new analysis needed

### Honest Team

| # | Team | Market | Adversary | Scenario name | Coverage | Expected outcome |
|---|------|--------|-----------|---------|---------|---------|
| 1 | Honest | Bull | None | **Normal operation (baseline)** | ★ unit tests | LAF runs frictionlessly, team claims to plan |
| 2 | Honest | Bull | Opportunistic | **Bull-market speculation** | ○ | Adversary has no opening, everything normal |
| 3 | Honest | Bull | Sophisticated | **Bull-market premeditation** | ○ | Sybil voting tries to HALT an honest project. Quadratic voting weakens sybil but does not eliminate it (★ the Sybil stress test already covers this mechanism) |
| 4 | Honest | Neutral | None | **Stable operation** | ★ unit tests | Regular checkpoints, occasional votes, normal release |
| 5 | Honest | Neutral | Opportunistic | **Neutral-market speculation** | ○ | Adversary may manipulate votes to lower the rate, but the honest team suffers no substantive harm |
| 6 | Honest | Neutral | Sophisticated | **Governance attack** | ★ Sybil | Sybil voting + signal gaming. Key question: can an honest project resist malicious governance manipulation? |
| 7 | Honest | Bear | None | **Bear-market panic** | ★ Bank run | Investors exit in panic, Rule 2 auto-pauses. The honest team is collateral damage, this is LAF's cost |
| 8 | Honest | Bear | Opportunistic | **Bear-market arbitrage** | ○ | Adversary buys tokens cheaply in the panic, amplifies the rage quit ratio, honest team takes a bigger hit |
| 9 | Honest | Bear | Sophisticated | **Systemic attack** | ★ Cascade | Full pressure: panic + Sybil + signal manipulation. LAF's limit test |

### Negligent Team

| # | Team | Market | Adversary | Scenario name | Coverage | Expected outcome |
|---|------|--------|-----------|---------|---------|---------|
| 10 | Negligent | Bull | None | **Lazy bull market** | ★ Apathy | Team stops updating but investors do not care (bull market), checkpoints are a formality |
| 11 | Negligent | Bull | Opportunistic | **Insider burn** | ○ | Team overspends funds but not deliberately fraudulent. Streaming limits daily consumption |
| 12 | Negligent | Bull | Sophisticated | **Exploited team** | ○ | Adversary exploits the team's inaction and extracts funds through governance votes |
| 13 | Negligent | Neutral | None | **Gradual decline** | ☆ Friend.tech | Team gradually stops working. Signal Monitor's commit / activity metrics start to trigger |
| 14 | Negligent | Neutral | Opportunistic | **Arbitrage during decline** | ○ | As the project declines the adversary buys tokens cheaply and initiates a HALT vote to carve up the remaining funds |
| 15 | Negligent | Neutral | Sophisticated | **Accelerated demise** | ○ | Adversary actively accelerates project failure (mass rage quit + HALT vote) |
| 16 | Negligent | Bear | None | **Natural death** | ○ | Passive team + falling market = natural death. LAF ensures funds are not locked up |
| 17 | Negligent | Bear | Opportunistic | **Carve-up game** | ○ | Multiple parties compete for the remaining funds: team wants to finish streaming, investors want to rage quit, adversary wants HALT |
| 18 | Negligent | Bear | Sophisticated | **Total collapse** | ○ | The scenario closest to the Friend.tech counterfactual |

### Malicious Team

| # | Team | Market | Adversary | Scenario name | Coverage | Expected outcome |
|---|------|--------|-----------|---------|---------|---------|
| 19 | Malicious | Bull | None | **Boiling frog** | ○ | Bull market masks the anomaly, team slowly siphons funds. Can Signal Monitor detect it before the community notices? |
| 20 | Malicious | Bull | Opportunistic | **Double drain** | ○ | Team and adversary target the pool at the same time |
| 21 | Malicious | Bull | Sophisticated | **Insider-outsider collusion** | ○ | Team colludes with the adversary (team reports fake metrics, adversary manipulates votes). LAF's hardest scenario |
| 22 | Malicious | Neutral | None | **Typical rug pull** | ☆ Friend.tech | Team plans to exit. Streaming limits the extractable amount, checkpoint provides a community intervention window |
| 23 | Malicious | Neutral | Opportunistic | **Rug pull + arbitrage** | ○ | Once the team's exit signal appears, the adversary front-runs and worsens the loss |
| 24 | Malicious | Neutral | Sophisticated | **Coordinated-attack rug** | ○ | Malicious team + sophisticated adversary = worst scenario. How much loss can LAF recover? |
| 25 | Malicious | Bear | None | **Rug pull under panic** | ☆ Terra/Fei | Team accelerates its exit in a bear market. Streaming blocks a one-off withdrawal |
| 26 | Malicious | Bear | Opportunistic | **Bear-market rug + arbitrage** | ○ | Double pressure: team exits + adversary manipulates during the panic |
| 27 | Malicious | Bear | Sophisticated | **Doomsday scenario** | ★ Cascade | All adversarial factors at once. LAF's goal is not to prevent all loss but to reduce the loss ratio |

---

## Analysis priority

### P0: Journal 2 must cover (9)

Selection criterion: the extreme combinations of each dimension + the baseline

| Priority | Scenario # | Name | Rationale |
|--------|--------|------|------|
| P0 | 1 | Normal operation | Baseline: show LAF does not obstruct a normal project |
| P0 | 7 | Bear-market panic | Show how Rule 2 behaves in a legitimate panic |
| P0 | 9 | Systemic attack | Worst case for an honest team |
| P0 | 13 | Gradual decline | Signal Monitor's core use case |
| P0 | 16 | Natural death | Typical ending for a Negligent team |
| P0 | 19 | Boiling frog | The malicious team's most covert tactic |
| P0 | 22 | Typical rug pull | LAF's core value proposition |
| P0 | 25 | Rug pull under panic | Connects to the Fei/Terra counterfactual analysis |
| P0 | 27 | Doomsday scenario | Upper-bound analysis: what LAF can do in the worst case |

### P1: valuable but can go in the Final Report (6)

| Scenario # | Name | Rationale |
|--------|------|------|
| 3 | Bull-market premeditation | Illustrates the limits of Sybil resistance |
| 8 | Bear-market arbitrage | Illustrates the effect of external arbitrage on rage quit |
| 10 | Lazy bull market | Already covered by the Apathy test |
| 17 | Carve-up game | The multi-party game analysis is interesting |
| 21 | Insider-outsider collusion | LAF's hardest scenario |
| 24 | Coordinated-attack rug | Worst malicious scenario |

---

## Simulation parameter template

Each scenario's simulation needs to specify:

```
Pool Size:           100 ETH (fixed)
Investor Count:      [10, 50, 100] (adjusted per scenario)
Team Wallet Count:   [1, 3]
Rate Per Second:     [default: pool / 365 days]
Checkpoint Interval: 90 days
Checkpoint Window:   14 days
Rage Quit Threshold: 25% (Rule 2 trigger value)
Max Pause Duration:  30 days

# Dimension-specific parameters
Team Behavior:       [honest_claim, front_load, slow_drain, rug_attempt]
Market Sentiment:    [hold, gradual_exit, panic_exit]
Adversary Strategy:  [none, buy_and_dump, sybil_vote, signal_game, coordinate]
```

## Evaluation metrics

1. **Team extraction ratio**: funds actually extracted by the team / total pool
2. **Investor recovery ratio**: share recovered by investors through rage quit
3. **Response time**: time from the appearance of an anomaly to the system's response
4. **False-positive rate**: number of times an honest team is paused or halted
5. **Adversary gain**: excess benefit obtained by the adversary through manipulation
6. **Residual funds**: share of funds left locked in the contract at the end

## Mapping to existing tests

| Stress test | Scenario # |
|---------|--------|
| Bank Run | 7, 25, 27 |
| Sybil Checkpoint | 3, 6, 9, 21 |
| Signal Gaming | 19, 21 |
| Cascade | 9, 27 |
| Governance Apathy | 10, 16 |

## Mapping to the counterfactual analysis

| Case | Closest scenario # |
|------|----------|
| Fei Protocol | 25 (rug pull under panic + re-entrancy attack) |
| Friend.tech | 13 (gradual decline) -> 22 (rug pull) |
| Terra/LUNA | 7 (bear-market panic) + 25 (team burns reserves) |

---

## Next steps

1. ~~Design the matrix~~ done
2. Write detailed analyses for the 9 P0 scenarios (1-2 pages each)
3. Pick 3-5 core scenarios for Solidity or Python simulation
4. Integrate into the "Evaluation" chapter of Journal 2
