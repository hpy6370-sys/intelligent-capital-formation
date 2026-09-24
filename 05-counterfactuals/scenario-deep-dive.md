# P0 Scenario Deep Dive

> Based on the 3x3x3 scenario matrix, a detailed analysis of the 9 scenarios that Journal 2 must cover
> Each scenario includes: setup, LAF behaviour timeline, key metrics, conclusion

> Note: the timelines below assume the rolling reading of Rule 2 (design document section 8, question 3), under which the 25% threshold is measured against the current unreleased balance at any time. The shipped prototype measures it against a snapshot taken at checkpoint window open and is inactive before the first window; see `LAF-SIMULATION-NOTE.md` A8 and design finding 3.

---

## Scenario #1: Normal operation (Honest x Bull x None)

### Setup
- Honest team develops normally, monthly updates, reasonable use of funds
- Market rising, investors hold
- No external adversary

### LAF behaviour timeline

```
Day 0:     funding closes, streaming starts
Day 1-89:  team claims funds daily, nothing abnormal
Day 90:    first checkpoint window opens
Day 90-104: 14-day window, nobody initiates an audit vote
Day 104:   checkpoint resolves, default CONTINUE
Day 105+:  normal release continues
```

### Key metrics
- Team extraction ratio: 100% (all claimed as planned)
- Investor recovery ratio: 0% (nobody rage quits)
- False positives: 0 (no pause/halt)
- Signal Monitor triggers: 0 (all metrics normal)

### Analysis
LAF's overhead in normal operation is:
1. Gas cost: the team must call claim() periodically (vs a one-off withdrawal)
2. Governance cost: a checkpoint every 90 days requires at least some attention
3. Liquidity constraint: the team cannot obtain all funds at once

**Conclusion**: LAF imposes acceptable friction on an honest project. Streaming does not obstruct normal development (the team can claim its released share at any time), and a checkpoint completes automatically when uncontested. This is the "harmlessness" argument for LAF.

---

## Scenario #7: Bear-market panic (Honest x Bear x None)

### Setup
- Honest team keeps developing, but the market crashes
- Investors panic and rage quit en masse
- No external adversary, a purely market-driven panic

### LAF behaviour timeline

```
Day 0:     100 ETH raised, streaming starts
Day 1-45:  normal operation
Day 46:    market drops 30%, panic spreads
Day 46-47: investors start to rage quit
           - alice exits 30 ETH (30% of unreleased)
           -> Rule 2 triggers: automatic PAUSE
Day 47:    team cannot claim new funds
Day 47-50: more investors rage quit (allowed during pause)
           - bob exits 20 ETH
           - carol exits 10 ETH
Day 50:    total exit 60%; the TVL signal crosses critical and SignalMonitor.evaluate() opens an early checkpoint
Day 50-64: window period: investors vote
           - if CONTINUE: team continues to claim the remaining funds
           - if DECREASE: rate is lowered
           - if HALT: project terminates, remaining funds distributed pro rata
```

### Key metrics
- Team extraction ratio: ~12% (45 days of streaming out of 365 days)
- Investor recovery ratio: ~60% (via rage quit)
- False positives: 1 (honest team paused)
- Signal Monitor triggers: possible (sharp TVL drop)

### Analysis
**This is LAF's key tradeoff scenario.**

LAF correctly protected investors: 60% of funds returned to investors via rage quit. Without LAF (as with Fei Protocol), investors could only sell at a loss on the secondary market.

But the honest team was hit as collateral damage. The team's funds were frozen even though their development was entirely normal. This is not a bug, it is LAF's design choice:

> Investor protection takes priority over team convenience. The cost of wrongly pausing an honest team < the cost of letting a malicious team through.

**Mitigations**:
- The checkpoint vote gives the community a chance to correct (voting CONTINUE restores release)
- The pause is time-bounded (MAX_PAUSE_DURATION), it never freezes forever
- An honest team can win back investor trust through transparent communication

---

## Scenario #9: Systemic attack (Honest x Bear x Sophisticated)

### Setup
- Honest team faces a market crash + a sophisticated adversary
- Adversary tactics: Sybil voting + signal gaming + panic amplification

### LAF behaviour timeline

```
Day 0-30:  normal operation
Day 31:    adversary begins positioning: 100 Sybil wallets each buy 0.1 ETH of shares
Day 45:    market crashes, adversary amplifies panic (large on-chain sells to create FUD)
Day 46:    the adversary's Sybil wallets rage quit in a coordinated way, artificially raising the exit ratio
           -> Rule 2 triggers
Day 47:    checkpoint window opens
Day 48:    the adversary's 100 Sybil wallets vote HALT
           Quadratic voting:
           - 100 x sqrt(0.1 ETH) ≈ 31.6 weight units
           - 1 whale x sqrt(90 ETH) ≈ 9.5 weight units
           -> Sybil has a 3.3x voting advantage (!!)
```

### Key finding

**Quadratic voting is not enough to resist Sybil.** This is a known limitation (Limitation 4).

sqrt(N x small) > sqrt(1 x big) when N is large enough:
- 100 x sqrt(0.1) = 100 x 0.316 = 31.6
- 1 x sqrt(10) = 3.16

The total voting power of 100 small wallets is 10x that of a single 10 ETH wallet.

**How the paper should handle it**: do not avoid it. List it explicitly as a "Known Limitation" and discuss:
1. Existing mitigation: quorum requirement (sufficient participation is required)
2. Possible v2 improvement: stake-weighted quadratic (sqrt(balance) x identity score)
3. **Bond voting** (Mohan, Khezr & Berg, Management Science 2024): use time commitment as a second voting dimension. Voters must lock tokens for a period, and longer locks carry more weight. Key insight: token quantity alone cannot resist both Sybil and plutocracy at the same time; a second dimension is needed. Splitting into Sybil wallets does not increase total time commitment, and locking has a high opportunity cost for large holders. This is a candidate upgrade direction for the QuadraticGovernor in LAF v2
4. Ultimate solution: on-chain identity (e.g. Worldcoin proof-of-humanity), but this is beyond the scope of this paper

---

## Scenario #13: Gradual decline (Negligent x Neutral x None)

### Setup
- The team starts working and gradually loses interest
- Market flat, no external pressure
- This is a simplified version of the Friend.tech counterfactual

### LAF behaviour timeline

```
Day 0-90:  team develops normally
Day 91:    first checkpoint, vote CONTINUE
Day 90-180: team update frequency drops (weekly to monthly to none)
Day 180:   second checkpoint
           Signal Monitor detects:
           - commit activity down 80%
           - active addresses down 50%
           -> WARNING triggered, checkpoint opened early automatically
Day 180-194: community votes DECREASE (lower the rate but do not terminate)
Day 195+:  team receives less funding, but the project is not dead
Day 270:   third checkpoint, team completely inactive
           Signal Monitor: CRITICAL (commit activity is 0)
           community votes HALT
Day 271:   remaining funds distributed pro rata to investors
```

### Key metrics
- Team extraction ratio: ~50% (270/365 days of streaming, but the rate was already lowered for the last 90 days)
- Investor recovery ratio: ~40% (pro-rata distribution of the remainder after HALT)
- Signal Monitor triggers: 2 (WARNING + CRITICAL)

### Analysis
LAF's performance in the gradual-decline scenario:
1. **Signal Monitor provided early warning** (at Day 180, not at Day 365 when the funds were already gone)
2. **DECREASE gave the team a second chance** (not an immediate HALT)
3. **Investors recovered about 40% of funds** (vs ~0% in Friend.tech)

This is LAF's most natural use case: it does not require "heroic" intervention, only systematic monitoring and a gradual governance response.

---

## Scenario #16: Natural death (Negligent x Bear x None)

### Setup
- Inactive team + falling market = the project dies naturally
- No malicious party, but nobody tries to save it either

### LAF behaviour timeline

```
Day 0-60:  team did some work, market starts to weaken
Day 60-90: team gradually disappears, investors start to rage quit
Day 90:    Rule 2 may trigger (if exit >25%)
Day 90:    Signal Monitor detects multiple CRITICAL
           -> checkpoint triggered automatically
Day 90-104: nobody votes (Governance Apathy scenario)
Day 104:   default CONTINUE (!! apathy means no change)
Day 180:   team has extracted ~50%, investors have rage quit ~40%
Day 270:   pool nearly empty
```

### Key finding

**Governance Apathy is LAF's fatal weakness.** When no investor votes:
- The checkpoint defaults to CONTINUE
- Nobody initiates a HALT
- The team can keep claiming until the pool is empty

This closely resembles the Friend.tech ending: the project died, but there was no explicit "termination" moment.

**How the paper should handle it**:
1. Acknowledge the apathy problem
2. Discuss possible mitigations:
   - Inverted default (if below quorum, default to PAUSE instead of CONTINUE)
   - Automatic rate reduction (N consecutive checkpoints with no votes -> rate halves automatically)
3. Leave these improvements for the v2 discussion

---

## Scenario #19: Boiling frog (Malicious x Bull x None)

### Setup
- A malicious team slowly siphons funds during a bull market
- The rising market masks the anomaly
- No external overseer notices

### LAF behaviour timeline

```
Day 0:     team designs a project that looks legitimate
Day 1-365: team claims streaming funds on schedule, used for:
           - 40% actual development
           - 60% privately transferred to personal wallets
Day 90:    first checkpoint, team shows development progress (that 40%)
           investors satisfied in the bull market, vote CONTINUE
Day 180:   second checkpoint, same as above
Day 270:   third checkpoint, team starts preparing to exit
Day 365:   streaming complete, team took 100% of the funds
           but 60% was wasted / embezzled
```

### Key finding

**LAF cannot prevent misuse of funds within the streaming allowance.** If the team's "spending" looks like normal operations, the checkpoint vote will not be triggered.

This is not a design flaw of LAF; it is a limitation common to all governance systems. VCs face the same problem (internal corruption in a portfolio company).

What LAF can do:
1. **Rate limiting**: the team cannot take all funds at once (streaming)
2. **Provide checkpoints**: if someone spots an anomaly, an audit vote can be initiated
3. **Signal Monitor may detect it**: abnormal outflow (large transfers out after the team claims), but this requires on-chain analytics capability

**Difference from a rug pull (scenario #22)**: the boiling frog is harder to detect because there is no obvious "exit" moment. This is a boundary condition the LAF paper should discuss honestly.

---

## Scenario #22: Typical rug pull (Malicious x Neutral x None)

### Setup
- The team plans from the start to exit at some point
- Market flat, no external disturbance

### Timeline without LAF (what actually happened with Friend.tech)

```
Day 0:     fundraising succeeds
Day 1-180: team operates the project
Day 181:   team decides to exit
Day 182:   contract ownership transferred to the zero address
Day 183:   investors find out, token crashes 98%
Day 184:   team has taken $44M
```

### Timeline with LAF

```
Day 0:     fundraising succeeds, streaming starts
Day 1-180: team operates the project but can only claim the funds released by streaming
           @ rate = 100 ETH / 365 days ≈ 0.274 ETH/day
           over 180 days the team can extract at most ~49.3 ETH (about 49%)
Day 181:   team wants to exit, but cannot withdraw the remaining 50.7 ETH at once
           option A: keep claiming slowly (but has lost interest)
           option B: stop claiming, investors notice and rage quit
Day 182:   team stops activity
Day 190:   Signal Monitor triggers WARNING (commit activity is 0)
Day 190:   automatic checkpoint opens
Day 190-204: community votes HALT
Day 205:   remaining ~50.7 ETH distributed pro rata to investors
```

### Key metrics
- Without LAF: team takes 100%, investors recover 0%
- With LAF: team takes ~49%, investors recover ~51%

### Analysis
**LAF reduces the rug pull loss from 100% to ~49%.** This is LAF's strongest value proposition.

Core mechanisms:
1. Streaming limits the total the team can extract before exiting
2. Signal Monitor issues a warning when the team stops activity
3. The checkpoint vote lets the community terminate the project and recover the remainder
4. Rage quit provides an individual exit channel that does not depend on voting

**Friend.tech mapping**: had Friend.tech used LAF, only ~$22M of the $44M would have been extracted by the team, and the remaining $22M would have returned to investors.

---

## Scenario #25: Rug pull under panic (Malicious x Bear x None)

### Setup
- A malicious team accelerates its exit during a market crash
- Similar to Terra's LFG burning through $2.8B of reserves in 5 days

### Timeline with LAF

```
Day 0:     fundraising succeeds
Day 1-90:  team operates while secretly preparing to exit
Day 91:    market crashes 50%
Day 92:    team tries to accelerate extraction, but streaming caps the daily amount
           team can only claim the portion already released
Day 93:    investors panic and start to rage quit
           -> Rule 2 triggers: automatic PAUSE
Day 94:    team's claims are frozen
Day 94:    Signal Monitor detects sharp TVL drop + abnormal team extraction pattern
           -> automatic checkpoint
Day 94-108: community votes HALT
Day 109:   remaining funds distributed to investors
```

### Comparison with Terra

| Aspect | Terra actual | With LAF |
|------|-----------|--------|
| Reserve consumption | $2.8B burned within 5 days | streaming caps the daily amount, PAUSE freezes extraction |
| Community participation | entirely passive (Do Kwon's unilateral decisions) | checkpoint vote brings the community into the decision |
| Exit path | mint LUNA (accelerates the death spiral) | rage quit redeems underlying assets pro rata |
| Final loss | $60B (including LUNA inflation) | depends on the share already released before the exit |

---

## Scenario #27: Doomsday scenario (Malicious x Bear x Sophisticated)

### Setup
- All the worst factors at once
- Malicious team + market crash + sophisticated adversary
- This is the upper-bound test for LAF: what can it still do?

### LAF behaviour timeline

```
Day 0-30:  appears normal
Day 31:    adversary begins Sybil positioning
Day 45:    market crashes
Day 46:    malicious team tries to accelerate extraction
Day 47:    adversary rage quits en masse -> Rule 2 triggers
Day 48:    Signal Monitor triggers, but the adversary may manipulate the reporter
Day 49:    checkpoint opens, Sybil voting may produce a wrong decision
Day 50-64: chaotic voting period
```

### Key finding

**Even in the doomsday scenario, LAF still provides three lines of defence:**

1. **Streaming cannot be bypassed.** Even if Sybil manipulates the vote and the reporter is bought, streaming still physically limits the speed of fund release. It is hard-coded and depends on no governance.

2. **Rage quit is always available.** Investors can exit at any moment without anyone's approval. This is individual-level protection, unaffected by collective governance failure.

3. **Rule 2 is automatic.** The 25% exit threshold triggers a pause with no human intervention. Even if governance fails completely (all votes manipulated by Sybil), Rule 2 still freezes fund release in a crisis.

**What LAF cannot do**:
- Prevent Sybil from manipulating vote outcomes
- Prevent a bought reporter from disabling the signals
- Recover funds the team has already claimed
- Stop the adversary from extracting excess gains through rage quit

### Loss estimate

Assume a 100 ETH pool, the team extracted about 12.6 ETH before Day 46 (46/365), and the adversary obtained about 5 ETH of excess gains through manipulation:

- Without LAF: team 100 ETH + uncertain adversary profit -> investors recover 0%
- With LAF: team ~13 ETH + adversary ~5 ETH -> investors recover ~82%

**Even in the worst case, LAF reduces investor loss from 100% to ~18%.**

---

## Summary table

| Scenario # | Name | Investor recovery (with LAF) | Investor recovery (without LAF) | LAF improvement |
|--------|------|---------------------|---------------------|-------------|
| 1 | Normal operation | N/A (nobody exits) | N/A | N/A |
| 7 | Bear-market panic | ~60% | ~0-30%* | +30-60% |
| 9 | Systemic attack | not derived (the scenario text stops at the Sybil vote and gives no recovery figure) | ~0% | not derived |
| 13 | Gradual decline | ~40% | ~0% | +40% |
| 16 | Natural death | ~30% | ~10%* | +20% |
| 19 | Boiling frog | ~0% (misuse stays inside the streaming allowance) | ~0% | none |
| 22 | Typical rug pull | ~51% | ~0% | +51% |
| 25 | Rug pull under panic | ~75% | ~0% | +75% |
| 27 | Doomsday scenario | ~82% | ~0% | +82% |

*Without LAF but with a secondary-market exit

> Note: the figures above are estimates based on a 100 ETH / 365 day streaming rate.
> Actual figures depend on the timing of the exit, the rage quit ratio, and market conditions.
> Journal 2 should do a parameter sensitivity analysis rather than fixing on a single number.
