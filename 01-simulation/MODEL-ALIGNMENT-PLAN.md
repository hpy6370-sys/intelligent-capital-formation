# Simulation Alignment Plan: Historical v5 to the 2026-09-27 Prototype

**Status:** implementation plan only. The v5 simulator and its stored results
remain historical; this file does not change them or claim new simulation
results.

## Objective

Build a separately versioned simulation that represents the current Solidity
prototype and can be compared with the existing historical v5 model. The
comparison should test how revised voting, exit-pause, and terminal-state rules
change capital delivery and participant protection under both adversarial and
honest-project conditions.

Keep `capstone_sim_v5.py`, its inputs, and outputs intact as a reproducible
record of the earlier design. Put the revised implementation in a new version
(for example, `capstone_sim_v6.py`) and document every changed rule and
assumption. Do not relabel v5 figures as outcomes of the current contracts.

## Contract-to-model mapping

Use `02-solidity/PROTOTYPE-V2-CHANGES.md` as the source of truth. Before coding,
write each mapping as a small rule-level fixture with inputs, expected state
transition, and the corresponding contract test or invariant.

| Current contract behavior | Required simulation representation | Check before using results |
|---|---|---|
| Shares are minted 1:1 with deposits; votes are share-weighted, not quadratic | Each share contributes one snapshot vote; wallet splitting must not increase total weight | A split-wallet agent has the same aggregate vote weight as one wallet |
| Deployment quorum is 50.01% of snapshot supply; winning action needs >50% of cast weight | Model quorum against snapshot total supply and decision majority against cast weight as two separate conditions | Boundary cases below, at, and above quorum and majority match contract semantics |
| Scheduled checkpoint first opens 90 days after funding closes and then 90 days after resolution; vote window is 14 days | Separate funding close, opening, expiry, and resolution times; do not schedule from a fixed 90-day grid after close | No pre-close opening; an unresolved expired window blocks a later scheduled window |
| No-quorum resolution defaults to `CONTINUE` | Model abstention and missed quorum without creating an intervention | Apathy does not generate a protective vote |
| Rate adjustment is a fixed half of the initial rate per passed action; total rate is capped at twice initial | Remove agent-chosen arbitrary rate deltas; model the fixed step, cap, saturation, and no-op at the cap | Rate bounds and checkpoint resolution agree with the contract |
| Rule 2 sums exits in the current and prior 29 UTC calendar-day buckets; it pauses when exits are strictly >25% of the unreleased balance immediately before the latest exit | Track dated exit amounts and calculate the trigger on each exit using the pre-exit balance | Test calendar-day boundaries, exactly 25%, above 25%, and repeated exits |
| Rule 2 can trigger before or between checkpoints; rage quit remains possible during pause | Evaluate the alarm continuously and permit exits while streaming is paused | A pause stops claims, not exits; no checkpoint is required for the alarm |
| Pause uses a 30-day default response period with a 60-day maximum; a second pause cannot reset/extend an active timeout; a passed pause vote preserves an existing pause | Track configured response period, maximum, pause reason, and deadline; prevent extension while active | Repeated exit triggers and vote-triggered pause do not extend the original deadline |
| Rule 4 is terminal at zero balance or when balance is below 10% of the amount still unvested under the stream | Recompute unvested amount over time; compare remaining funds to that moving amount rather than initial deposits | Normal vesting alone does not trigger terminal; boundary tests match the vault |
| Signal monitor uses fresh submissions from registered reporters (up to 16), a quorum, and the median; at least two warnings or one critical flag can request an early checkpoint, rate-limited to one per 30 days | Represent the five metrics, reporter count, freshness, quorum, thresholds, and signal accuracy as explicit parameters; model the trigger as requesting a checkpoint, not directly changing vault state | No effective metric below quorum; stale values expire; monitor cannot itself pause or terminate the vault |

The deployment script uses development defaults (reporter quorum 1, 365-day
report window, and no reporters registered). A production-like simulation
should make those defaults visible and include a more robust multi-reporter
configuration as a separate scenario; do not silently substitute one for the
other.

## Experiment design

### Preserve comparability

- Reuse the same investor populations and matched random seeds when comparing
  the historical and revised LAF rules. Keep DAICO and RDA baselines unchanged
  unless a separate, documented correction is made.
- First reproduce stored v5 output from the existing script. Then run a
  no-behavior-change parity fixture in the new code to isolate implementation
  changes from rule changes.
- Choose the number of runs per cell after a pilot reports Monte Carlo error;
  retain seeds, parameters, code revision, and environment with the outputs.
- Do not compare a single LAF output column with a DAICO/RDA measure on a
  different denominator. Define each metric and its eligible population first.

### Scenarios to add

Keep the current FOMO/herding scenarios for continuity, then add scenarios that
v5 does not model:

1. Healthy team delivering on plan, with normal market volatility.
2. Deliberate treasury diversion or malicious team behavior.
3. Gradual project deterioration, including the commit-inactivity signal.
4. Governance apathy and competing checkpoint actions.
5. Market panic with an honest team, to measure false-positive Rule 2 pauses.
6. Signal noise, stale reports, missing quorum, and a colluding reporter
   minority/majority.
7. Large-holder concentration and wallet splitting under share-weighted votes.

Separate exogenous project health from market price and investor confidence.
Record which processes are observed proxies and which are assumptions. The
simulation must not assume that every exit signal means the team is malicious.

## Outcomes to report

For each mechanism and scenario, report distributions (not only averages) for:

- amount streamed to the team and share of the raise delivered;
- investor principal recovered and timing of exits;
- funds left locked or unclaimed at the end of the horizon;
- number, duration, and reason for pauses, including honest-team false
  positives;
- checkpoint openings, quorum rates, winning actions, and voter concentration;
- terminal-state frequency and time to terminal;
- project completion/health outcome and the gap between funding delivered and
  the scenario's project need;
- sensitivity to Rule 2 threshold/window, Rule 4 threshold, reporter
  configuration, and behavior assumptions.

Use common denominators where comparisons require them. Label every output as
historical v5 or current-rule simulation and state whether it is a modeled
outcome, calibration input, or empirical observation.

## Validation and release gates

1. **Rule fixtures:** match each contract behavior in the table, especially
   exact thresholds and time boundaries.
2. **Accounting:** reconcile deposits to team claims, investor exits, and
   remaining vault balance at every step.
3. **Parity:** reproduce the unchanged v5 path and preserve DAICO/RDA outputs
   under the same seeds when no rule change is intended.
4. **Sensitivity:** identify conclusions that reverse under reasonable
   parameter changes; report null or adverse cases alongside favorable ones.
5. **Documentation:** update the simulation note and figures only after the
   new version passes the fixtures and accounting checks. Keep prior outputs
   labeled historical and do not replace them in place.

The current contract note reports a 2026-09-27 Foundry result of 84 passing
tests and 10 invariant properties; `02-solidity/test-output/forge-test.txt` is
an older 2026-09-08 log. Refresh and reconcile the checked-in validation record
before claiming a single current verification artifact. The simulator work
should cite the current contract note and its corresponding rule tests rather
than infer correctness from the older log.
