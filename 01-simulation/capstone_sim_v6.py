"""
Capstone: Intelligent Capital Formation - Simulation v6.0
DAICO vs Reverse Dutch Auction vs LAF under the current Solidity rules

v6.0 (2026-10-17) asks one question: how do the v5 LAF results change when the
LAF rule engine follows the current Solidity prototype (02-solidity/src,
02-solidity/PROTOTYPE-V2-CHANGES.md) instead of the 2026-09-08 rules that v5
modelled? It also adds four stress scenarios that v5 could not run (S1 honest
team + bank run, S2 malicious team at the maximum permitted rate, S3 gradual
deterioration with an exogenous health path, S5 whale concentration).

Ground rules
- capstone_sim_v4.py and capstone_sim_v5.py are imported, never edited; their
  stored outputs are not touched. Agents, the 7 scenarios x 3 profiles, seeds,
  the DAICO funding replay and every DAICO / RDA number come from
  v4.run_single unchanged, so the DAICO / RDA blocks printed below are the v5
  ones line for line.
- LAFSimV6 subclasses v5.LAFSim and replaces only the rule engine. A RuleSet
  selects, rule by rule, the historical v5 semantics or the current contract
  semantics. Ruleset "v5" reproduces v5 exactly: the sweep asserts that every
  metric v5.run_single returns (DAICO, RDA and LAF) is reproduced bit for bit,
  for every cell and seed, before the results are printed.
- Agent behaviour is v5's (A1-A11 in capstone_sim_v5.LAF_ASSUMPTIONS). The few
  scenario-specific changes are implemented in subclasses and listed in
  V6_ASSUMPTIONS, which is printed at the top of the output.
- Rule fixtures (assert-based, deterministic, mirroring the Foundry tests) run
  before the sweep; the script stops if one fails.
- Deterministic: all randomness is seeded and stdout contains no timings
  (progress and run time go to stderr).

Run (from 01-simulation/, Python 3.10+, stdlib only):
  python capstone_sim_v6.py --json output/simulation_v6_summary.json > output/simulation_v6_results.txt
"""

import argparse
import json
import math
import random
import sys
import time
from contextlib import contextmanager
from dataclasses import asdict, dataclass, replace

sys.dont_write_bytecode = True  # importing v4/v5 must not write __pycache__ next to them

import capstone_sim_v4 as v4  # noqa: E402
import capstone_sim_v5 as v5  # noqa: E402
from capstone_sim_v4 import RealDataCalibration, SCENARIOS, make_agents  # noqa: E402

VERSION = "6.0"
CONTINUE, INCREASE_RATE, DECREASE_RATE, PAUSE_FOR_AUDIT, HALT = (
    v5.CONTINUE, v5.INCREASE_RATE, v5.DECREASE_RATE, v5.PAUSE_FOR_AUDIT, v5.HALT)
ACTIONS = v5.ACTIONS
DAYS = v5.LAF_DAYS_PER_ROUND  # 7 days per round

# ---------------------------------------------------------------------------
# Current deployment defaults (02-solidity/script/DeployLAF.s.sol). Parameters
# that did not change since v5 (25 % Rule 2, 10 % Rule 4, 60-day maximum pause,
# 30-day vote pause, 90-day interval, 14-day window, >50 % majority, 30-day
# signal rate limit, 2-warning / 1-critical combinator) reuse the v5 constants.
# ---------------------------------------------------------------------------
CUR_QUORUM = 0.5001            # quorumBps 5001 of snapshot total supply (rounded up on-chain)
CUR_RATE_STEP = 0.5            # QuadraticGovernor._applyAction: (initialRate + 1) / 2
CUR_RATE_CAP_MULT = 2.0        # LAFVault.setStreamRate: newRate <= 2 x initialRate
CUR_MIN_VESTING_DAYS = 365     # LAFVault.minimumVestingDuration (deploy value)
RULE2_LOOKBACK_DAYS = 30       # LAFVault.RAGE_QUIT_LOOKBACK_DAYS: today + previous 29 days
COMMIT_INACTIVITY_THRESHOLDS = (60.0, 120.0)  # SignalMonitor thresholds[3] = 6000 / 12000 (days x 100)


@dataclass(frozen=True)
class RuleSet:
    name: str
    vote_weight: str = "sqrt"               # "sqrt" (v5; quorum on sqrt(total)) | "linear" (current; snapshot supply)
    quorum: float = v5.LAF_QUORUM
    rate_step: float = v5.LAF_RATE_STEP      # fraction of the initial rate per INCREASE / DECREASE
    rate_cap: str = "abs15"                 # "abs15" (v5: 15 % of raise per round) | "x2" (current: 2 x initial)
    min_vesting_days: float | None = None   # current: 365 -> initial-rate bound (closeFunding)
    rate_parity: bool = False               # shorten the minimum duration so the v5 tap rate is admissible
    rule2: str = "window"                   # "window" (v5 checkpoint snapshot) | "rolling30" (current)
    rule4: str = "raise"                    # "raise" (v5: 10 % of deposits) | "unvested" (current)
    pause_preserve: bool = False            # current: a PAUSE vote during an active pause is a no-op
    terminal_continue: bool = False         # current: a checkpoint resolved while terminal records CONTINUE


V5_RULES = RuleSet("v5")
CURRENT = RuleSet("current", vote_weight="linear", quorum=CUR_QUORUM, rate_step=CUR_RATE_STEP,
                  rate_cap="x2", min_vesting_days=CUR_MIN_VESTING_DAYS, rule2="rolling30",
                  rule4="unvested", pause_preserve=True, terminal_continue=True)
PARITY = replace(CURRENT, name="parity", rate_parity=True)
RULESETS = [V5_RULES, CURRENT, PARITY]

V6_ASSUMPTIONS = [
    "B1 Agents, seeds, raise and agent rules are v5's (A1, A4-A6, A10): same population per seed, same",
    "   exit / voting rules, no secondary market, full-stake rage quit. RDA keeps its own population.",
    "B2 Time: 1 round = 7 days. All exits of a round share one calendar-day bucket stamped with the",
    "   round's day, so the 30-day Rule 2 lookback (today + 29 days) spans 5 rounds (days d-28..d).",
    "   A 60-day pause stops 8 rounds (56 d) of accrual, a 30-day pause 4 rounds (28 d).",
    "B3 Keepers: checkPoolDepletion, resumeIfTimedOut, openCheckpointWindow, resolveCheckpoint and",
    "   SignalMonitor.evaluate are permissionless; they are assumed to be called every round, without",
    "   delay. The team claims every round before investors act (as in v5).",
    "B4 Initial-rate bound: rate <= raise / (2 x minimumVestingDuration). With the deployed 365 days that",
    "   is 0.959 % of the raise per round. 'current' clamps the v5 tap rate to it (v3 1.0 % and small",
    "   2.0 % are above it: closeFunding would revert); 'parity' keeps the v5 tap rate by shortening the",
    "   minimum duration to 350 d (v3) / 175 d (small). large (0.8 %) is admissible in both.",
    "B5 Votes: linear snapshot shares. Only current holders vote (on-chain, holders who exit after the",
    "   snapshot keep their vote; assumed not to use it). Quorum = cast weight >= 50.01 % of snapshot",
    "   supply (float; the contract rounds the threshold up). Winner needs > 50 % of cast weight.",
    "B6 Signals: one honest reporter delivers v5's proxies every round (the deploy script registers no",
    "   reporter). COMMIT_INACTIVITY (warning 60 d, critical 120 d) is evaluated only in S2 / S3, where",
    "   an exogenous commit process exists. TEAM_OUTFLOW (warning 3x) cannot fire under the 2x cap.",
    "B7 Horizon: outcomes are measured at the v5 horizon (350 / 140 / 560 d). 'Left' = funds still in",
    "   the vault at the horizon; they are not lost: they keep streaming to the team or remain",
    "   redeemable by holders after the horizon.",
    "S1 Honest team + bank run: A4 discontent off; in one round (day 35 or day 126) every non-whale",
    "   holder exits with probability q (0.3 / 0.5) for an exogenous reason (market panic). Compared with",
    "   the same seed and rules without the panic.",
    "S2 Malicious team: initial rate at the 365-day bound for every ruleset (the maximum the current",
    "   contract admits), no delivery from day 0: no commits, so COMMIT_INACTIVITY = days since close.",
    "   a: investors react only through signals (A4 off); b: confidence tracks health (A4 at v5 level).",
    "S3 Gradual deterioration: project health H = 1 until onset ~ U(60, 240) d, then falls linearly to 0",
    "   over 180 d. The team commits on each day with probability H, so COMMIT_INACTIVITY is days since",
    "   the last commit. Health is exogenous (investor exits do not change it). a: A4 off; b: A4 scale =",
    "   1 - H (confidence tracks health, zero while healthy).",
    "S5 Whale concentration: one team-aligned holder with 40 % or 55 % of the raise is added to the",
    "   baseline population (in 1 wallet or split over 10). It never exits before terminal, opens a",
    "   ballot in every window (any holder may) and votes INCREASE_RATE first; others follow v5 rules.",
]


# ---------------------------------------------------------------------------
# Rate bound helpers (LAFVault.closeFunding)
# ---------------------------------------------------------------------------

def max_initial_rate_per_round(total_deposited, min_vesting_days):
    """closeFunding bound, per 7-day round: totalDeposited / (2 x minimumVestingDuration)."""
    return total_deposited * DAYS / (2.0 * min_vesting_days)


def close_funding_ok(rate_per_round, total_deposited, min_vesting_days):
    """False where LAFVault.closeFunding reverts (zero rate or RateTooHigh)."""
    return 0 < rate_per_round <= max_initial_rate_per_round(total_deposited, min_vesting_days)


def effective_min_vesting_days(rules, tap_rate):
    if rules.min_vesting_days is None:
        return None
    if rules.rate_parity:
        return min(rules.min_vesting_days, DAYS / (2.0 * tap_rate))
    return rules.min_vesting_days


@contextmanager
def concern_scale(value):
    """Temporarily set v5's A4 multiplier (read by v5.LAFSim._agents_act at call time)."""
    old = v5.LAF_CONCERN_SCALE
    v5.LAF_CONCERN_SCALE = value
    try:
        yield
    finally:
        v5.LAF_CONCERN_SCALE = old


# ---------------------------------------------------------------------------
# Rule engine
# ---------------------------------------------------------------------------

class LAFSimV6(v5.LAFSim):
    """v5.LAFSim with a selectable rule engine. With V5_RULES every override
    either delegates to v5 or repeats the v5 arithmetic, so v5 is reproduced
    exactly; the extra bookkeeping never touches the random stream."""

    def __init__(self, holders, tap_rate, rng, rules, initial_rate_frac=None):
        super().__init__(holders, tap_rate, rng)
        self.rules = rules
        self.mvd_days = effective_min_vesting_days(rules, tap_rate)
        self.rate_clamped = False
        if initial_rate_frac is not None:            # S2: the team picks its own rate
            self.initial_rate = initial_rate_frac * self.total_deposited
        if self.mvd_days is not None:
            bound = max_initial_rate_per_round(self.total_deposited, self.mvd_days)
            if self.initial_rate > bound * (1 + 1e-12):
                self.initial_rate = bound            # closeFunding would revert above the bound
                self.rate_clamped = True
        if rules.rate_cap == "x2":
            self.rate_cap_mult = CUR_RATE_CAP_MULT
        elif self.initial_rate != tap_rate * self.total_deposited:
            self.rate_cap_mult = v5.LAF_RATE_CAP_ABS * self.total_deposited / self.initial_rate
        # bookkeeping
        self.rq_by_day: dict[int, float] = {}
        self.pause_reason = None
        self.first_window_day = None
        self.terminal_day = None
        self.balance_at_terminal = None
        self.initiated_cps = 0
        self.quorum_met_cps = 0
        self.pauses_rule2_pre_cp = 0
        self.pauses_rule2_post_cp = 0
        self.pauses_vote = 0
        self.pause_votes_noop = 0
        self.paused_days_rule2 = 0
        self.paused_days_vote = 0
        self.first_warning_day = None
        self.first_alarm_day = None
        self.first_protect_day = None
        self.first_protect_kind = None
        self.claimed_at_first_protect = None
        self.rate_max = self.rate_mult

    # ---- loop: attribute paused days to their cause -----------------------
    def tick(self):
        nxt = self.day + self.D
        if self.paused and not (nxt >= self.paused_at + self.pause_period):
            if self.pause_reason == "RULE2":
                self.paused_days_rule2 += self.D
            else:
                self.paused_days_vote += self.D
        super().tick()
        if not self.paused:
            self.pause_reason = None

    def _protect(self, kind):
        if self.first_protect_day is None:
            self.first_protect_day = self.day
            self.first_protect_kind = kind
            self.claimed_at_first_protect = self.claimed

    # ---- Layer 4 (unchanged rule; detection bookkeeping only) -------------
    def _evaluate_signals(self):
        super()._evaluate_signals()
        self._note_signals()

    def _note_signals(self):
        if self.warning_active and self.first_warning_day is None:
            self.first_warning_day = self.day
        fires = (len(self.warning_active) >= v5.LAF_WARNING_COMBINATOR
                 or len(self.critical_active) >= v5.LAF_CRITICAL_COMBINATOR)
        if fires and self.first_alarm_day is None:
            self.first_alarm_day = self.day
        return fires

    # ---- Rule 4 -------------------------------------------------------------
    def _check_depletion(self):
        if self.terminal:
            return
        if self.rules.rule4 == "raise":
            super()._check_depletion()
        else:
            # LAFVault.checkPoolDepletion: remaining == 0, or remaining < 10 % of the unvested amount
            unvested = max(0.0, self.total_deposited - self.accrued)
            remaining = self.unreleased
            if remaining <= 1e-12 * self.total_deposited or (
                    unvested > 0 and remaining < v5.LAF_POOL_DEPLETION * unvested):
                self.terminal = True
                self.rate_mult = 0.0
        if self.terminal:
            self.terminal_day = self.day
            self.balance_at_terminal = self.unreleased / self.total_deposited
            self._protect("terminal")

    # ---- Layer 3 ------------------------------------------------------------
    def _open_window(self, trigger):
        super()._open_window(trigger)
        if self.rules.vote_weight == "linear":
            # QuadraticGovernor.votingPowerOf = getPastVotes at the snapshot: one share, one vote
            self.window.weights = {h.id: h.shares for h in self.holders if h.shares > 0}
        if self.first_window_day is None:
            self.first_window_day = self.day

    def _quorum(self, w):
        if self.rules.vote_weight == "sqrt":
            return self.rules.quorum * math.sqrt(w.total_shares_at_open)
        return self.rules.quorum * w.total_shares_at_open

    def _resolve(self):
        w = self.window
        action = CONTINUE
        if w.initiated:
            self.initiated_cps += 1
        if w.initiated and w.total_weight > 0:
            if w.total_weight >= self._quorum(w):
                self.quorum_met_cps += 1
                best = max(ACTIONS, key=lambda a: w.tallies[a])
                if w.tallies[best] > v5.LAF_MAJORITY * w.total_weight:
                    action = best
            self.whale_vote_shares.append(w.whale_weight / w.total_weight)
        if self.rules.terminal_continue and self.terminal:
            action = CONTINUE                          # QuadraticGovernor.resolveCheckpoint
        self._apply(action)
        for h in self.holders:                         # v5 A5: whale voice
            if h.agent_type == "whale" and h.concerned and h.shares > 0:
                if action == CONTINUE:
                    h.voice_failed = True
                else:
                    h.concerned = False
                    h.voice_failed = False
        self.actions[action] += 1
        self.checkpoints += 1
        self.last_checkpoint_end = self.day
        self.adverse_resolution = action in (PAUSE_FOR_AUDIT, HALT)
        self.window = None

    def _apply(self, action):
        r = self.rules
        if action == INCREASE_RATE:
            self.rate_mult = min(self.rate_mult + r.rate_step, self.rate_cap_mult)
            if not self.terminal:
                self.rate_max = max(self.rate_max, self.rate_mult)
        elif action == DECREASE_RATE:
            self.rate_mult = max(0.0, self.rate_mult - r.rate_step)
            if not self.terminal:
                self._protect("decrease")
        elif action == PAUSE_FOR_AUDIT:
            if self.terminal:
                pass
            elif r.pause_preserve and self.paused:
                self.pause_votes_noop += 1             # existing pause and deadline kept
            else:
                self._pause(v5.LAF_PAUSE_RESPONSE_DAYS)
                self.pause_reason = "VOTE"
                self.pauses_vote += 1
                self._protect("vote_pause")
        elif action == HALT:
            self.rate_mult = 0.0
            if not self.terminal:
                self._protect("halt")

    # ---- Layer 2 / Rule 2 ---------------------------------------------------
    def recent_rage_quit(self):
        """LAFVault.recentRageQuit: exits in today's bucket and the previous 29 daily buckets."""
        return sum(v for d, v in self.rq_by_day.items() if 0 <= self.day - d < RULE2_LOOKBACK_DAYS)

    def _rule2_fired(self):
        self.pause_reason = "RULE2"
        if self.first_window_day is None:
            self.pauses_rule2_pre_cp += 1
        else:
            self.pauses_rule2_post_cp += 1
        self._protect("rule2_pause")

    def _rage_quit(self, h):
        if self.rules.rule2 == "window":
            was_paused = self.paused
            super()._rage_quit(h)
            if self.paused and not was_paused:
                self._rule2_fired()
            return
        if self.total_shares <= 0:
            return
        balance_before = self.unreleased
        payout = balance_before * h.shares / self.total_shares   # RageQuitModule: pro rata
        if payout <= 0:
            return
        self.exited += payout
        self.total_shares -= h.shares
        if self.total_shares < 1e-9:
            self.total_shares = 0.0
        h.payout = payout
        h.quit_round = self.round
        h.shares = 0.0
        self.cum_rq_in_window += payout                # kept for observability, as on-chain
        self.rq_by_day[self.day] = self.rq_by_day.get(self.day, 0.0) + payout
        # LAFVault.withdrawForRageQuit: recent exits > 25 % of the balance just before this exit
        if (self.recent_rage_quit() > v5.LAF_RAGE_QUIT_AUTO_PAUSE * balance_before
                and not self.paused and not self.terminal):
            self._pause(v5.LAF_MAX_PAUSE_DAYS)
            self.rule2_pauses += 1
            self._rule2_fired()


# ---------------------------------------------------------------------------
# Scenario engines
# ---------------------------------------------------------------------------

class PanicSim(LAFSimV6):
    """S1: exogenous one-round panic among non-whale holders (honest team)."""

    def __init__(self, holders, tap_rate, rng, rules, panic_day, panic_q, seed):
        super().__init__(holders, tap_rate, rng, rules)
        self.panic_day, self.panic_q = panic_day, panic_q
        self.panic_rng = random.Random(seed * 7_919 + 4_242)

    def _agents_act(self):
        if self.day == self.panic_day and not self.terminal:
            for h in self.holders:
                if h.shares > 0 and h.agent_type != "whale" and self.panic_rng.random() < self.panic_q:
                    self._rage_quit(h)
        super()._agents_act()


class HealthSim(LAFSimV6):
    """S2 / S3: exogenous project health observed through COMMIT_INACTIVITY."""

    def __init__(self, holders, tap_rate, rng, rules, seed, onset_day, decay_days,
                 confidence_tracks_health, initial_rate_frac=None):
        super().__init__(holders, tap_rate, rng, rules, initial_rate_frac=initial_rate_frac)
        self.onset_day, self.decay_days = onset_day, decay_days
        self.confidence_tracks_health = confidence_tracks_health
        self.health_rng = random.Random(seed * 104_729 + 31_337)
        self.last_commit_day = 0
        self.claimed_at_onset = None
        self.alarm_after_onset = None
        self.protect_after_onset = None
        self.claimed_at_protect_after_onset = None

    def health(self, day):
        if day < self.onset_day:
            return 1.0
        if self.decay_days <= 0:
            return 0.0
        return max(0.0, 1.0 - (day - self.onset_day) / self.decay_days)

    def tick(self):
        if self.claimed_at_onset is None and self.day + self.D > self.onset_day:
            self.claimed_at_onset = self.claimed       # funding streamed before onset (whole rounds)
        for d in range(self.day + 1, self.day + self.D + 1):
            if self.health_rng.random() < self.health(d):
                self.last_commit_day = d
        super().tick()

    def _protect(self, kind):
        super()._protect(kind)
        if self.protect_after_onset is None and self.day >= self.onset_day:
            self.protect_after_onset = self.day
            self.claimed_at_protect_after_onset = self.claimed

    def _evaluate_signals(self):
        # v5.LAFSim._evaluate_signals verbatim, plus the exogenous COMMIT_INACTIVITY metric.
        k = self.signal_window_rounds
        if len(self.history) < k:
            return
        then_unrel, then_holders, then_hhi = self.history[-k]
        vals = {
            "TVL_DECLINE": 1 - self.unreleased / then_unrel if then_unrel > 0 else 0.0,
            "ACTIVE_ADDR_DECLINE": 1 - self.holders_count() / then_holders if then_holders > 0 else 0.0,
            "TEAM_OUTFLOW": 0.0 if (self.paused or self.terminal) else self.rate_mult,
            "HHI_INCREASE": self.hhi() - then_hhi,
            "COMMIT_INACTIVITY": float(self.day - self.last_commit_day),
        }
        th = {**v5.SIGNAL_THRESHOLDS, "COMMIT_INACTIVITY": COMMIT_INACTIVITY_THRESHOLDS}
        self.warning_active = {m for m, v in vals.items() if v >= th[m][0]}
        self.critical_active = {m for m, v in vals.items() if v >= th[m][1]}
        if self.warning_active:
            self.warning_rounds += 1
        fires = self._note_signals()
        if fires and self.alarm_after_onset is None and self.day >= self.onset_day:
            self.alarm_after_onset = self.day
        if not fires:
            return
        if self.last_signal_day is not None and self.day < self.last_signal_day + v5.LAF_SIGNAL_RATE_LIMIT_DAYS:
            return
        if self.window is not None:
            return
        self.last_signal_day = self.day
        self.signal_triggers += 1
        self._open_window("SIGNAL")

    def _agents_act(self):
        scale = (1.0 - self.health(self.day)) if self.confidence_tracks_health else 0.0
        with concern_scale(scale):
            super()._agents_act()


class AlignedHolderSim(LAFSimV6):
    """S5: team-aligned holder wallets that open every ballot and vote INCREASE_RATE."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.aligned_cast_shares = []

    def _voting(self):
        w = self.window
        aligned = [h for h in self.holders if h.agent_type == "aligned" and h.shares > 0]
        if aligned and not w.initiated:
            w.initiated = True                         # QuadraticGovernor.initiateAuditVote: any holder
        if not hasattr(w, "aligned_weight"):
            w.aligned_weight = 0.0
        for h in aligned:
            if h.id in w.weights and h.id not in w.voted:
                weight = w.weights[h.id]
                w.tallies[INCREASE_RATE] += weight
                w.total_weight += weight
                w.aligned_weight += weight
                w.voted.add(h.id)
        super()._voting()                              # everyone else: v5 A6 verbatim

    def _resolve(self):
        w = self.window
        if w.initiated and w.total_weight > 0:
            self.aligned_cast_shares.append(getattr(w, "aligned_weight", 0.0) / w.total_weight)
        super()._resolve()

    def _agents_act(self):
        saved = self.holders
        self.holders = [h for h in saved if h.agent_type != "aligned"]
        try:
            super()._agents_act()                      # v5 A5 for everyone else
        finally:
            self.holders = saved
        if self.terminal:                              # pro-rata wind-down, like everyone else
            for h in saved:
                if h.agent_type == "aligned" and h.shares > 0:
                    self._rage_quit(h)


# ---------------------------------------------------------------------------
# Rule fixtures (assert-based; mirror the Foundry tests named in each entry)
# ---------------------------------------------------------------------------

def _fx_holders(shares, agent_type="late_entrant"):
    return [v5.LAFHolder(id=i, agent_type=agent_type, fomo_sensitivity=0.0, herding_sensitivity=0.0,
                         deposited=float(s), shares=float(s)) for i, s in enumerate(shares)]


def _fx_sim(rules, shares, tap_rate=0.005):
    return LAFSimV6(_fx_holders(shares), tap_rate, random.Random(0), rules)


def _fx_vote(sim, votes, before_resolve=None, initiate=True):
    """Open a window, cast {holder id: action}, optionally mutate state, resolve after the window."""
    sim._open_window("SCHEDULED")
    w = sim.window
    w.initiated = initiate
    for hid, action in votes.items():
        weight = w.weights[hid]
        w.tallies[action] += weight
        w.total_weight += weight
        w.voted.add(hid)
    if before_resolve:
        before_resolve(sim)
    sim.day = w.end_day + sim.D
    sim._resolve()


def _fx_quit_at(sim, holder_index, day):
    sim.day = day
    sim._rage_quit(sim.holders[holder_index])


def fixture_quorum():
    s = _fx_sim(CURRENT, [40, 60])
    _fx_vote(s, {0: INCREASE_RATE})
    assert s.quorum_met_cps == 0 and s.actions[CONTINUE] == 1 and s.rate_mult == 1.0
    s = _fx_sim(CURRENT, [50.02, 49.98])
    _fx_vote(s, {0: INCREASE_RATE})
    assert s.actions[INCREASE_RATE] == 1 and s.rate_mult == 1.5
    s = _fx_sim(V5_RULES, [40, 60])                    # historical: sqrt(40) >= 20 % of sqrt(100)
    _fx_vote(s, {0: INCREASE_RATE})
    assert s.actions[INCREASE_RATE] == 1


def fixture_normal_vesting():
    s = _fx_sim(CURRENT, [100])
    s.accrued = s.claimed = 95.0                       # 95 of 100 vested and claimed
    s._check_depletion()
    assert not s.terminal
    s5 = _fx_sim(V5_RULES, [100])
    s5.accrued = s5.claimed = 95.0
    s5._check_depletion()
    assert s5.terminal                                 # the v5 cliff: 5 < 10 % of the raise
    s = LAFSimV6(_fx_holders([100]), 1.0, random.Random(0), CURRENT)   # clamped to the bound
    while s.accrued < 0.999 * s.total_deposited:
        s.accrued += s.initial_rate * s.rate_mult
        s.claimed = min(s.accrued, s.total_deposited)
        s._check_depletion()
        assert s.terminal == (s.unreleased <= 1e-12 * s.total_deposited)


def fixture_pause_preserved():
    s = _fx_sim(CURRENT, [30, 70])
    _fx_quit_at(s, 0, 7)                               # Rule 2 pause at day 7 for 60 days
    assert s.paused and s.pause_reason == "RULE2" and (s.paused_at, s.pause_period) == (7, 60)
    s.day = 21
    s._apply(PAUSE_FOR_AUDIT)
    assert (s.paused_at, s.pause_period, s.pause_reason) == (7, 60, "RULE2") and s.pause_votes_noop == 1
    s5 = _fx_sim(V5_RULES, [100])
    s5.day = 7
    s5._pause(60)
    s5.day = 21
    s5._apply(PAUSE_FOR_AUDIT)
    assert (s5.paused_at, s5.pause_period) == (21, 30)  # historical: overwritten


def fixture_increase_at_cap():
    s = _fx_sim(CURRENT, [60, 40])
    s.rate_mult = 2.0
    _fx_vote(s, {0: INCREASE_RATE})
    assert s.actions[INCREASE_RATE] == 1 and s.rate_mult == 2.0 and s.window is None
    s = _fx_sim(CURRENT, [60, 40])
    s.rate_mult = 1.75
    _fx_vote(s, {0: INCREASE_RATE})
    assert s.rate_mult == 2.0                          # saturates at the cap


def fixture_rate_bound():
    D = 100.0
    b = max_initial_rate_per_round(D, CUR_MIN_VESTING_DAYS)
    assert abs(b - D * 7 / 730) < 1e-12
    assert close_funding_ok(b, D, 365) and not close_funding_ok(b * 1.000001, D, 365) and not close_funding_ok(0, D, 365)
    s = LAFSimV6(_fx_holders([100]), 0.01, random.Random(0), CURRENT)
    assert s.rate_clamped and s.initial_rate == b
    s = LAFSimV6(_fx_holders([100]), 0.01, random.Random(0), PARITY)
    assert not s.rate_clamped and s.initial_rate == 0.01 * 100 and abs(s.mvd_days - 350) < 1e-9
    assert abs(D / (CUR_RATE_CAP_MULT * b) * DAYS - CUR_MIN_VESTING_DAYS) < 1e-9   # 2x cap: >= 365 days


def fixture_rule2_crossing():
    s = _fx_sim(CURRENT, [30, 70])
    _fx_quit_at(s, 0, 7)
    assert s.paused and s.pause_period == v5.LAF_MAX_PAUSE_DAYS and s.pauses_rule2_pre_cp == 1
    s = _fx_sim(CURRENT, [20, 80])
    _fx_quit_at(s, 0, 7)
    assert not s.paused
    s5 = _fx_sim(V5_RULES, [30, 70])                   # historical: inactive before the first window
    _fx_quit_at(s5, 0, 7)
    assert not s5.paused


def fixture_terminal_not_revived():
    def go_terminal(sim):
        sim.terminal = True
        sim.rate_mult = 0.0
    s = _fx_sim(CURRENT, [60, 40])
    _fx_vote(s, {0: INCREASE_RATE}, before_resolve=go_terminal)
    assert s.actions[CONTINUE] == 1 and s.actions[INCREASE_RATE] == 0 and s.rate_mult == 0.0


def fixture_exactly_25():
    s = _fx_sim(CURRENT, [25, 75])
    _fx_quit_at(s, 0, 7)
    assert not s.paused                                # strict '>' : exactly 25 % does not pause
    s = _fx_sim(CURRENT, [25.001, 74.999])
    _fx_quit_at(s, 0, 7)
    assert s.paused


def fixture_bucket_edges():
    s = _fx_sim(CURRENT, [100])
    s.rq_by_day = {70: 10.0, 71: 20.0, 100: 1.0}
    s.day = 100
    assert s.recent_rage_quit() == 21.0                # day 71 (age 29) counts, day 70 (age 30) does not
    s.day = 101
    assert s.recent_rage_quit() == 1.0
    for second_day, pauses in ((36, True), (37, False)):   # 20 % on day 7, then 10 % of the rest
        s = _fx_sim(CURRENT, [20, 10, 70])
        _fx_quit_at(s, 0, 7)
        assert not s.paused
        _fx_quit_at(s, 1, second_day)
        assert s.paused == pauses


def fixture_rule4_boundary():
    s = _fx_sim(CURRENT, [100])
    s.accrued, s.claimed, s.exited = 50.0, 50.0, 45.0  # remaining 5 = 10 % of unvested 50
    s._check_depletion()
    assert not s.terminal
    s.exited = 45.5
    s._check_depletion()
    assert s.terminal and s.rate_mult == 0.0


def fixture_exit_during_pause_and_terminal():
    s = _fx_sim(CURRENT, [40, 60])
    s.claimed = 50.0
    s.day = 7
    s._pause(60)
    _fx_quit_at(s, 0, 14)
    assert abs(s.holders[0].payout - 20.0) < 1e-12     # 40 % of the 50 still in the vault
    s = _fx_sim(CURRENT, [40, 60])
    s.claimed, s.terminal = 50.0, True
    _fx_quit_at(s, 1, 14)
    assert abs(s.holders[1].payout - 30.0) < 1e-12


def fixture_no_quorum_continue():
    s = _fx_sim(CURRENT, [100])
    _fx_vote(s, {}, initiate=False)                    # nobody opens the ballot
    assert s.actions[CONTINUE] == 1 and s.initiated_cps == 0
    s = _fx_sim(CURRENT, [30, 30, 40])
    _fx_vote(s, {0: PAUSE_FOR_AUDIT})                  # 30 % turnout < 50.01 %
    assert s.actions[CONTINUE] == 1 and not s.paused


def fixture_vote_pause():
    s = _fx_sim(CURRENT, [60, 40])
    _fx_vote(s, {0: PAUSE_FOR_AUDIT})
    assert s.paused and s.pause_period == v5.LAF_PAUSE_RESPONSE_DAYS and s.pause_reason == "VOTE"
    s = _fx_sim(CURRENT, [60, 40])
    s.terminal = True
    s._apply(PAUSE_FOR_AUDIT)
    assert not s.paused                                # pauseForAudit reverts when terminal


def fixture_wallet_split():
    single = _fx_sim(CURRENT, [40, 60])
    split = _fx_sim(CURRENT, [4] * 10 + [60])
    single._open_window("SCHEDULED")
    split._open_window("SCHEDULED")
    assert abs(sum(split.window.weights[i] for i in range(10)) - single.window.weights[0]) < 1e-9
    single5 = _fx_sim(V5_RULES, [40, 60])
    split5 = _fx_sim(V5_RULES, [4] * 10 + [60])
    single5._open_window("SCHEDULED")
    split5._open_window("SCHEDULED")
    gain = sum(split5.window.weights[i] for i in range(10)) / single5.window.weights[0]
    assert abs(gain - math.sqrt(10)) < 1e-9            # sqrt weighting rewards splitting by sqrt(k)


FIXTURES = [
    ("F1", "40 % holder cannot reach quorum; 50.02 % can; v5 sqrt quorum met by 40 %",
     "QuadraticGovernorTest.test_singleFortyPercentHolderCannotReachQuorum", fixture_quorum),
    ("F2", "normal vesting (95 of 100 claimed) is not terminal; v5 rule is",
     "LAFVaultTest.test_normalVestingDoesNotTriggerTerminal", fixture_normal_vesting),
    ("F3", "PAUSE vote during a Rule 2 pause keeps reason and deadline; v5 overwrote",
     "QuadraticGovernorTest.test_pauseVoteDuringExistingPauseResolvesWithoutExtendingDeadline", fixture_pause_preserved),
    ("F4", "INCREASE at the 2x cap resolves and saturates",
     "QuadraticGovernorTest.test_increaseAtRateCapStillResolves", fixture_increase_at_cap),
    ("F5", "initial rate above raise/(2 x 365 d) rejected (clamped); parity duration admits v5 rate",
     "LAFVaultTest.test_closeFunding_rejectsRateAboveTheCommittedVestingLimit", fixture_rate_bound),
    ("F6", "rage quit of 30 % pauses 60 d before any checkpoint; 20 % does not; v5 inactive",
     "RageQuitTest.test_rageQuit_crossing25PercentThreshold_autoPausesVault / belowThreshold", fixture_rule2_crossing),
    ("F7", "checkpoint resolving after terminal records CONTINUE, rate stays 0",
     "QuadraticGovernorTest.test_checkpointResolutionCannotReviveTerminalVault", fixture_terminal_not_revived),
    ("F8", "exactly 25 % does not pause, 25.001 % does (strict >)",
     "LAFVault.withdrawForRageQuit (strict comparison)", fixture_exactly_25),
    ("F9", "exits aged 29 days count, aged 30 days do not",
     "RageQuitTest.test_rageQuitLookbackExpiresOldExits", fixture_bucket_edges),
    ("F10", "Rule 4: remaining = 10 % of unvested is not terminal, below it is",
     "LAFVaultTest.test_checkPoolDepletion_noOpAboveThreshold / triggersTerminalBelowThreshold", fixture_rule4_boundary),
    ("F11", "rage quit pays pro rata during a pause and in terminal",
     "RageQuitTest.test_rageQuit_availableDuringPause / availableDuringTerminal", fixture_exit_during_pause_and_terminal),
    ("F12", "uninitiated window and missed quorum resolve CONTINUE",
     "QuadraticGovernorTest.test_resolveCheckpoint_defaultsToContinue_ifQuorumNotMet", fixture_no_quorum_continue),
    ("F13", "passed PAUSE pauses 30 d; no pause on a terminal vault",
     "LAFVaultTest.test_pauseForAudit_blocksClaimDuringPause / test_claim_revertsAfterTerminal", fixture_vote_pause),
    ("F14", "splitting 40 % over 10 wallets: linear weight unchanged, sqrt weight x sqrt(10)",
     "QuadraticGovernorTest.test_votingWeight_isLinearBalance", fixture_wallet_split),
]


def run_fixtures():
    for fid, _, _, fn in FIXTURES:
        try:
            fn()
        except AssertionError as exc:
            raise SystemExit(f"rule fixture {fid} failed: {exc!r}")
    return len(FIXTURES)


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

PROFILES = {
    "v3": {"n_agents": 30, "rounds": 50, "capital_scale": 1.0, "tap_rate": 0.01,
           "rda_start_price": 10.0, "rda_end_price": 1.0},
    "small": RealDataCalibration.small_project_config(),
    "large": RealDataCalibration.large_project_config(),
}
PROFILE_HEADERS = {
    "v3": "v3 defaults (uncalibrated, for reference)",
    "small": "small_project profile (Solana/Gnosis/Abyss-scale, calibrated)",
    "large": "large_project profile (Casper/Mina/Flow/Algorand-scale, calibrated)",
}
BASE = {"fomo": 0.0, "herding": 0.0}
_POP_CACHE = {}


def build_population(seed, n_agents, rounds, fomo, herding, capital_scale, tap_rate,
                     rda_start_price, rda_end_price):
    """v5.run_single steps 1-2 verbatim: v4 run (DAICO / RDA numbers) + DAICO funding replay."""
    res = v4.run_single(n_agents=n_agents, rounds=rounds, fomo=fomo, herding=herding,
                        seed=seed, capital_scale=capital_scale, tap_rate=tap_rate,
                        rda_start_price=rda_start_price, rda_end_price=rda_end_price)
    random.seed(seed)
    agents = make_agents(n_agents, fomo, herding, capital_scale)
    make_agents(n_agents, fomo, herding, capital_scale)      # RDA population draw, discarded
    daico = v4.DAICOSim(tap_rate=tap_rate)
    random.shuffle(agents)
    for i, a in enumerate(agents):
        participation_rate = i / max(n_agents, 1)
        amount = a.capital * random.uniform(0.3, 0.8)
        daico.contribute(a, amount, participation_rate)
    v4_total = res["daico_pool"] + res["daico_released"]
    assert abs(daico.pool - v4_total) <= 1e-9 * max(1.0, v4_total), (seed, daico.pool, v4_total)
    return res, agents


def population(profile, scen_params, seed):
    key = (profile, scen_params["fomo"], scen_params["herding"], seed)
    hit = _POP_CACHE.get(key)
    if hit is None:
        hit = build_population(seed=seed, **{**PROFILES[profile], **scen_params})
        if scen_params == BASE:
            _POP_CACHE[key] = hit
    return hit


def fresh_holders(agents):
    return [v5.LAFHolder.from_agent(a) for a in agents if a.tokens_held > 0]


def laf_rng(seed):
    return random.Random(seed * 1_000_003 + 20260908)          # v5's private LAF stream


def run_metrics(sim, n_agents):
    m = v5.laf_metrics(sim, n_agents)
    D = sim.total_deposited
    m.update({
        "v6_terminal_day": sim.terminal_day,
        "v6_balance_at_terminal": sim.balance_at_terminal,
        "v6_initiated": sim.initiated_cps,
        "v6_quorum_met": sim.quorum_met_cps,
        "v6_pauses_rule2_pre_cp": sim.pauses_rule2_pre_cp,
        "v6_pauses_rule2_post_cp": sim.pauses_rule2_post_cp,
        "v6_pauses_vote": sim.pauses_vote,
        "v6_pause_votes_noop": sim.pause_votes_noop,
        "v6_paused_days_rule2": sim.paused_days_rule2,
        "v6_paused_days_vote": sim.paused_days_vote,
        "v6_left_in_vault": sim.unreleased / D,
        "v6_rate_end": sim.rate_mult,
        "v6_rate_max": sim.rate_max,
        "v6_initial_rate_frac": sim.initial_rate / D,
        "v6_first_warning_day": sim.first_warning_day,
        "v6_first_alarm_day": sim.first_alarm_day,
        "v6_first_protect_day": sim.first_protect_day,
        "v6_first_protect_kind": sim.first_protect_kind,
        "v6_streamed_before_protect": (sim.claimed_at_first_protect / D
                                       if sim.claimed_at_first_protect is not None else None),
    })
    return m


def _mean(rows, key):
    vals = [r[key] for r in rows if r[key] is not None]
    return sum(vals) / len(vals) if vals else None


def _frac(rows, key):
    return sum(1 for r in rows if r[key]) / len(rows)


def _pct(sorted_vals, p):
    """Nearest-rank percentile."""
    if not sorted_vals:
        return None
    return sorted_vals[max(0, math.ceil(p / 100 * len(sorted_vals)) - 1)]


def summarize(rows):
    tdays = sorted(r["v6_terminal_day"] for r in rows if r["v6_terminal_day"] is not None)
    initiated = sum(r["v6_initiated"] for r in rows)
    kinds = {}
    for r in rows:
        k = r["v6_first_protect_kind"] or "none"
        kinds[k] = kinds.get(k, 0) + 1
    return {
        "n_runs": len(rows),
        "team_received": _mean(rows, "laf_team_received"),
        "recov_quitters": _mean(rows, "laf_recovery_quitters"),
        "recov_all": _mean(rows, "laf_recovery_total"),
        "quit": _mean(rows, "laf_quit_frac"),
        "terminal_rate": _frac(rows, "laf_terminal"),
        "terminal_day": {"n": len(tdays), "mean": (sum(tdays) / len(tdays)) if tdays else None,
                         "p10": _pct(tdays, 10), "p50": _pct(tdays, 50), "p90": _pct(tdays, 90)},
        "balance_at_terminal": _mean(rows, "v6_balance_at_terminal"),
        "checkpoints": _mean(rows, "laf_checkpoints"),
        "quorum_met_rate": (sum(r["v6_quorum_met"] for r in rows) / initiated) if initiated else None,
        "actions": {"continue": _mean(rows, "laf_act_continue"), "increase": _mean(rows, "laf_act_increase"),
                    "decrease": _mean(rows, "laf_act_decrease"), "pause": _mean(rows, "laf_act_pause"),
                    "halt": _mean(rows, "laf_act_halt")},
        "pauses": {"rule2_pre_cp": _mean(rows, "v6_pauses_rule2_pre_cp"),
                   "rule2_post_cp": _mean(rows, "v6_pauses_rule2_post_cp"),
                   "vote": _mean(rows, "v6_pauses_vote"),
                   "vote_noop": _mean(rows, "v6_pause_votes_noop")},
        "paused_days": {"total": _mean(rows, "laf_paused_days"), "rule2": _mean(rows, "v6_paused_days_rule2"),
                        "vote": _mean(rows, "v6_paused_days_vote")},
        "signal_triggers": _mean(rows, "laf_signal_triggers"),
        "funds_left_in_vault": _mean(rows, "v6_left_in_vault"),
        "whale_vote_share": _mean(rows, "laf_whale_vote_share"),
        "rate_end": _mean(rows, "v6_rate_end"),
        "rate_max": _mean(rows, "v6_rate_max"),
        "initial_rate_per_round": _mean(rows, "v6_initial_rate_frac"),
        "first_protect_kind": dict(sorted(kinds.items())),
        "streamed_before_protect": _mean(rows, "v6_streamed_before_protect"),
    }


def mc_average(results, n_runs):
    """v5.run_monte_carlo's averaging, verbatim (used for the DAICO / RDA block)."""
    avg = {}
    for key in results[0]:
        vals = [r[key] for r in results if r[key] is not None]
        if not vals:
            avg[key] = 0.0
        elif isinstance(vals[0], bool):
            avg[key] = sum(1 for v in vals if v) / n_runs
        else:
            avg[key] = sum(vals) / len(vals)
    return avg


class Parity:
    runs = 0
    keys = 0


def run_cell(profile, scen_params, n_runs, rulesets=RULESETS, parity=True):
    p = {**PROFILES[profile], **scen_params}
    rows = {rs.name: [] for rs in rulesets}
    v4_rows = []
    for seed in range(n_runs):
        res, agents = population(profile, scen_params, seed)
        v4_rows.append(res)
        for rs in rulesets:
            sim = LAFSimV6(fresh_holders(agents), p["tap_rate"], laf_rng(seed), rs)
            sim.run(p["rounds"])
            assert sim.unreleased >= 0 and sim.claimed + sim.exited <= sim.total_deposited * (1 + 1e-9)
            m = {**res, **run_metrics(sim, p["n_agents"])}
            rows[rs.name].append(m)
            if parity and rs is V5_RULES:
                ref = v5.run_single(seed=seed, **p)
                for k, v in ref.items():
                    if m[k] != v:
                        raise SystemExit(f"v5 parity failed: {profile} {scen_params} seed {seed} {k}: {m[k]!r} != {v!r}")
                Parity.runs += 1
                Parity.keys = len(ref)
    return mc_average(v4_rows, n_runs), {k: summarize(v) for k, v in rows.items()}


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

def run_s1(n_runs):
    out = {}
    for prof in PROFILES:
        p = {**PROFILES[prof], **BASE}
        out[prof] = {}
        for pday in (35, 126):
            for q in (0.3, 0.5):
                key = f"day{pday}_q{q}"
                out[prof][key] = {}
                for rs in RULESETS:
                    rows = []
                    with concern_scale(0.0):
                        for seed in range(n_runs):
                            _, agents = population(prof, BASE, seed)
                            sim = PanicSim(fresh_holders(agents), p["tap_rate"], laf_rng(seed), rs, pday, q, seed)
                            sim.run(p["rounds"])
                            ref = LAFSimV6(fresh_holders(agents), p["tap_rate"], laf_rng(seed), rs)
                            ref.run(p["rounds"])
                            m = run_metrics(sim, p["n_agents"])
                            m["s_ref_team"] = ref.claimed / ref.total_deposited
                            m["s_false_pause"] = (sim.rule2_pauses + sim.pauses_vote) > 0
                            m["s_false_rule2"] = sim.rule2_pauses > 0
                            m["s_ref_pause"] = (ref.rule2_pauses + ref.pauses_vote) > 0
                            rows.append(m)
                    s = summarize(rows)
                    s["team_received_no_panic"] = _mean(rows, "s_ref_team")
                    s["funding_lost_to_panic"] = s["team_received_no_panic"] - s["team_received"]
                    s["false_pause_rate"] = _frac(rows, "s_false_pause")
                    s["false_rule2_pause_rate"] = _frac(rows, "s_false_rule2")
                    s["pause_rate_no_panic"] = _frac(rows, "s_ref_pause")
                    out[prof][key][rs.name] = s
    return out


def run_health(n_runs, onset_fn, decay_days, rulesets, fixed_rate):
    out = {}
    for prof in PROFILES:
        p = {**PROFILES[prof], **BASE}
        horizon = p["rounds"] * DAYS
        out[prof] = {}
        for vname, tracks in (("a_signals_only", False), ("b_confidence_tracks_health", True)):
            out[prof][vname] = {}
            for rs in rulesets:
                rows = []
                for seed in range(n_runs):
                    _, agents = population(prof, BASE, seed)
                    onset = onset_fn(seed)
                    sim = HealthSim(fresh_holders(agents), p["tap_rate"], laf_rng(seed), rs, seed=seed,
                                    onset_day=onset, decay_days=decay_days, confidence_tracks_health=tracks,
                                    initial_rate_frac=fixed_rate)
                    sim.run(p["rounds"])
                    m = run_metrics(sim, p["n_agents"])
                    D = sim.total_deposited
                    m["s_onset"] = onset
                    m["s_onset_in_horizon"] = onset < horizon
                    m["s_before_onset"] = (sim.claimed_at_onset / D) if sim.claimed_at_onset is not None else None
                    m["s_after_onset"] = ((sim.claimed - sim.claimed_at_onset) / D
                                          if sim.claimed_at_onset is not None else None)
                    m["s_detected"] = sim.alarm_after_onset is not None
                    m["s_detect_lag"] = (sim.alarm_after_onset - onset) if sim.alarm_after_onset is not None else None
                    m["s_detect_day"] = sim.alarm_after_onset
                    m["s_protect_lag"] = ((sim.protect_after_onset - onset)
                                          if sim.protect_after_onset is not None else None)
                    m["s_streamed_onset_to_protect"] = (
                        (sim.claimed_at_protect_after_onset - sim.claimed_at_onset) / D
                        if sim.protect_after_onset is not None and sim.claimed_at_onset is not None else None)
                    rows.append(m)
                s = summarize(rows)
                s.update({
                    "onset_day_mean": _mean(rows, "s_onset"),
                    "onset_within_horizon_rate": _frac(rows, "s_onset_in_horizon"),
                    "team_before_onset": _mean(rows, "s_before_onset"),
                    "team_after_onset": _mean(rows, "s_after_onset"),
                    "detection_rate": _frac(rows, "s_detected"),
                    "detection_day_mean": _mean(rows, "s_detect_day"),
                    "detection_lag_mean": _mean(rows, "s_detect_lag"),
                    "protect_lag_mean": _mean(rows, "s_protect_lag"),
                    "streamed_onset_to_first_protection": _mean(rows, "s_streamed_onset_to_protect"),
                })
                out[prof][vname][rs.name] = s
    return out


def run_s2(n_runs):
    bound = DAYS / (2.0 * CUR_MIN_VESTING_DAYS)
    return run_health(n_runs, onset_fn=lambda seed: 0, decay_days=0, rulesets=[V5_RULES, CURRENT],
                      fixed_rate=bound)


def run_s3(n_runs):
    def onset(seed):
        return random.Random(seed * 15_485_863 + 2_718).randint(60, 240)
    return run_health(n_runs, onset_fn=onset, decay_days=180, rulesets=RULESETS, fixed_rate=None)


A4_SCALES = (1.0, 0.5, 0.25, 0.0)


def run_a4_sensitivity(n_runs):
    """Baseline cell with v5's A4 discontent probability scaled (as sim_v5_sensitivity.py does)."""
    out = {}
    for prof in PROFILES:
        out[prof] = {}
        for scale in A4_SCALES:
            with concern_scale(scale):
                _, laf = run_cell(prof, BASE, n_runs, rulesets=[V5_RULES, CURRENT], parity=False)
            out[prof][f"scale{scale:.2f}"] = laf
    return out


def run_s5(n_runs):
    out = {}
    for prof in PROFILES:
        p = {**PROFILES[prof], **BASE}
        out[prof] = {}
        for share in (0.40, 0.55):
            for wallets in (1, 10):
                key = f"share{share:.2f}_wallets{wallets}"
                out[prof][key] = {}
                for rs in RULESETS:
                    rows = []
                    for seed in range(n_runs):
                        _, agents = population(prof, BASE, seed)
                        base = fresh_holders(agents)
                        B = sum(h.deposited for h in base)
                        A = share / (1.0 - share) * B
                        aligned = [v5.LAFHolder(id=100_000 + j, agent_type="aligned", fomo_sensitivity=0.0,
                                                herding_sensitivity=0.0, deposited=A / wallets, shares=A / wallets)
                                   for j in range(wallets)]
                        sim = AlignedHolderSim(base + aligned, p["tap_rate"], laf_rng(seed), rs)
                        sim.run(p["rounds"])
                        m = run_metrics(sim, p["n_agents"])
                        m["s_aligned_cast"] = (sum(sim.aligned_cast_shares) / len(sim.aligned_cast_shares)
                                               if sim.aligned_cast_shares else None)
                        m["s_inc_rate"] = (sim.actions[INCREASE_RATE] / sim.initiated_cps
                                           if sim.initiated_cps else None)
                        nav = sim.unreleased / sim.total_shares if sim.total_shares > 0 else 0.0
                        for tag, grp in (("others", [h for h in sim.holders if h.agent_type != "aligned"]),
                                         ("aligned", [h for h in sim.holders if h.agent_type == "aligned"])):
                            dep = sum(h.deposited for h in grp)
                            m[f"s_{tag}_value"] = sum(h.payout + h.shares * nav for h in grp) / dep
                        rows.append(m)
                    s = summarize(rows)
                    s["aligned_share_of_cast"] = _mean(rows, "s_aligned_cast")
                    s["increase_win_rate"] = _mean(rows, "s_inc_rate")
                    s["others_value_recovered"] = _mean(rows, "s_others_value")
                    s["aligned_value_recovered"] = _mean(rows, "s_aligned_value")
                    out[prof][key][rs.name] = s
    return out


# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

def f(v, spec):
    return "n/a" if v is None else spec.format(v)


LAF_COLS = [
    ("TeamRcv", lambda s: s["team_received"], "{:.1%}"),
    ("RecovQ", lambda s: s["recov_quitters"], "{:.1%}"),
    ("RecovAll", lambda s: s["recov_all"], "{:.1%}"),
    ("Quit", lambda s: s["quit"], "{:.1%}"),
    ("Term", lambda s: s["terminal_rate"], "{:.0%}"),
    ("TDay", lambda s: s["terminal_day"]["mean"], "{:.0f}"),
    ("Bal@T", lambda s: s["balance_at_terminal"], "{:.1%}"),
    ("CP", lambda s: s["checkpoints"], "{:.2f}"),
    ("Quorum", lambda s: s["quorum_met_rate"], "{:.0%}"),
    ("PAUSE", lambda s: s["actions"]["pause"], "{:.2f}"),
    ("INC", lambda s: s["actions"]["increase"], "{:.2f}"),
    ("R2pre", lambda s: s["pauses"]["rule2_pre_cp"], "{:.2f}"),
    ("R2post", lambda s: s["pauses"]["rule2_post_cp"], "{:.2f}"),
    ("PdDays", lambda s: s["paused_days"]["total"], "{:.1f}"),
    ("Sig", lambda s: s["signal_triggers"], "{:.2f}"),
    ("WhVote", lambda s: s["whale_vote_share"], "{:.0%}"),
    ("Left", lambda s: s["funds_left_in_vault"], "{:.1%}"),
]


def laf_header(first="rules", width=8):
    return f"    {first:<{width}} | " + " ".join(f"{h:>8}" for h, _, _ in LAF_COLS)


def laf_row(name, s, width=8):
    return f"    {name:<{width}} | " + " ".join(f"{f(g(s), spec):>8}" for _, g, spec in LAF_COLS)


def print_preamble(n_sweep, n_head, n_scen, n_fixtures):
    print(f"Capstone ICF Simulation v{VERSION} -- current-rule LAF on the v5 agents")
    print(f"DAICO vs Reverse Dutch Auction vs LAF | Monte Carlo N={n_sweep} (headline baseline N={n_head},"
          f" scenarios N={n_scen})")
    print()
    print("Rulesets (LAF only; DAICO / RDA are v4's and identical to simulation_v5_results.txt):")
    print("  v5       historical v5 engine (sqrt votes, 20 % sqrt quorum, step 0.3x, cap 15 % of raise per round,")
    print("           Rule 2 vs checkpoint snapshot, Rule 4 vs 10 % of deposits). Reproduces v5 exactly.")
    print("  current  current contracts with deployment defaults: linear snapshot votes, quorum 50.01 % of snapshot")
    print("           supply, step 0.5x initial, cap 2x initial, initial rate <= raise / (2 x 365 d), Rule 2 over")
    print("           today + 29 days vs the pre-exit balance, Rule 4 vs 10 % of the unvested amount, PAUSE")
    print("           vote cannot extend an active pause, terminal resolutions record CONTINUE.")
    print("  parity   'current' with the minimum vesting duration shortened per profile so that the v5 tap rate")
    print("           is admissible (isolates the rule changes from the rate clamp).")
    print()
    for prof, p in PROFILES.items():
        tap = p["tap_rate"]
        bound = DAYS / (2.0 * CUR_MIN_VESTING_DAYS)
        mvd = effective_min_vesting_days(PARITY, tap)
        print(f"  {prof:<5}: horizon {p['rounds'] * DAYS} d; v5 rate {tap:.3%} of raise per round; 365-d bound"
              f" {bound:.3%}; current initial rate {min(tap, bound):.3%}"
              f" ({'clamped' if tap > bound else 'admissible'}); parity minimum duration {mvd:.1f} d")
    print()
    print("v6 assumptions (agent rules A1-A11 are printed in simulation_v5_results.txt):")
    for line in V6_ASSUMPTIONS:
        print("  " + line)
    print()
    print(f"Rule fixtures: {n_fixtures}/{len(FIXTURES)} passed")
    for fid, desc, mirrors, _ in FIXTURES:
        print(f"  {fid:<4} {desc}  [{mirrors}]")
    print()
    print("Column key: TeamRcv share of raise claimed by the team; RecovQ mean payout/deposit of quitters;")
    print("  RecovAll payouts / raise; Quit share of holders who exited; Term share of runs reaching Rule 4;")
    print("  TDay mean terminal day (terminal runs); Bal@T vault balance at terminal / raise; CP checkpoints")
    print("  per run; Quorum share of initiated windows meeting quorum; PAUSE / INC passed per run; R2pre /")
    print("  R2post Rule 2 pauses per run before / after the first window opened; PdDays paused days per run;")
    print("  Sig signal-triggered windows per run; WhVote whale share of cast weight; Left vault balance at")
    print("  the horizon / raise (not a loss: still streaming or redeemable).")


def print_sweep(n_sweep, store):
    for prof in PROFILES:
        print(f"\n{'#' * 60}")
        print(f"# {PROFILE_HEADERS[prof]}")
        print(f"{'#' * 60}")
        store[prof] = {}
        for label, params in SCENARIOS:
            print(f"  [v6] {prof:<5} | {label}", file=sys.stderr, flush=True)
            daico_rda, laf = run_cell(prof, params, n_sweep)
            store[prof][label] = laf
            v4.print_results(label, daico_rda)       # DAICO + RDA block, identical to v4 / v5
            print("  LAF (v6 rule engines, same agents and seeds):")
            print(laf_header())
            for rs in RULESETS:
                print(laf_row(rs.name, laf[rs.name]))
        print(f"\n  Summary ({prof}): TeamRcv / RecovQ / Term / Quorum / Rule-2 pauses / Left, per ruleset")
        print(f"  {'Scenario':<32} | " + " | ".join(f"{rs.name:^37}" for rs in RULESETS))
        for label, _ in SCENARIOS:
            cells = []
            for rs in RULESETS:
                s = store[prof][label][rs.name]
                r2 = s["pauses"]["rule2_pre_cp"] + s["pauses"]["rule2_post_cp"]
                cells.append(f"{f(s['team_received'], '{:.1%}'):>6} {f(s['recov_quitters'], '{:.1%}'):>6} "
                             f"{f(s['terminal_rate'], '{:.0%}'):>4} {f(s['quorum_met_rate'], '{:.0%}'):>4} "
                             f"{r2:>5.2f} {f(s['funds_left_in_vault'], '{:.1%}'):>6}")
            print(f"  {label:<32} | " + " | ".join(f"{c:^37}" for c in cells))


def print_headline(n_head, head):
    print(f"\n{'=' * 100}")
    print(f"  Headline: baseline scenario, N={n_head} (seeds 0-{n_head - 1}), v5 vs current vs parity")
    print(f"{'=' * 100}")
    print(laf_header("profile/rules", 15))
    for prof in PROFILES:
        for rs in RULESETS:
            print(laf_row(f"{prof}/{rs.name}", head[prof][rs.name], 15))
    print("\n  Terminal day (terminal runs only, nearest-rank percentiles), balance at terminal, pause causes:")
    for prof in PROFILES:
        for rs in RULESETS:
            s = head[prof][rs.name]
            t = s["terminal_day"]
            print(f"    {prof:<5} {rs.name:<7} terminal {s['terminal_rate']:>4.0%} (n={t['n']:>3})  day mean"
                  f" {f(t['mean'], '{:.0f}'):>4} p10 {f(t['p10'], '{}'):>4} p50 {f(t['p50'], '{}'):>4} p90"
                  f" {f(t['p90'], '{}'):>4}  bal@T {f(s['balance_at_terminal'], '{:.1%}'):>6}  pauses/run:"
                  f" R2 pre {s['pauses']['rule2_pre_cp']:.2f} post {s['pauses']['rule2_post_cp']:.2f}"
                  f" vote {s['pauses']['vote']:.2f} (no-op {s['pauses']['vote_noop']:.2f})  paused days R2"
                  f" {s['paused_days']['rule2']:.1f} vote {s['paused_days']['vote']:.1f}"
                  f"  init rate {s['initial_rate_per_round']:.3%}")


def print_s1(n, s1):
    print(f"\n{'=' * 100}")
    print(f"  S1 honest team + exogenous bank run (A4 off), N={n}: non-whale holders exit w.p. q in one round")
    print(f"{'=' * 100}")
    print(f"    {'profile':<6} {'panic':<12} {'rules':<8} | {'FalsePause':>10} {'R2pause':>7} {'PdDays':>7} {'TeamRcv':>8}"
          f" {'NoPanic':>8} {'Lost':>6} {'RecovQ':>7} {'Quit':>6} {'Term':>5} {'Left':>6}")
    for prof in PROFILES:
        for key, by_rs in s1[prof].items():
            for rs in RULESETS:
                s = by_rs[rs.name]
                print(f"    {prof:<6} {key:<12} {rs.name:<8} | {s['false_pause_rate']:>10.0%}"
                      f" {s['false_rule2_pause_rate']:>7.0%}"
                      f" {s['paused_days']['total']:>7.1f} {s['team_received']:>8.1%}"
                      f" {s['team_received_no_panic']:>8.1%} {s['funding_lost_to_panic']:>6.1%}"
                      f" {f(s['recov_quitters'], '{:.1%}'):>7} {s['quit']:>6.1%} {s['terminal_rate']:>5.0%}"
                      f" {s['funds_left_in_vault']:>6.1%}")


def print_health(title, n, res, rulesets):
    print(f"\n{'=' * 100}")
    print(f"  {title}, N={n}")
    print(f"{'=' * 100}")
    print(f"    {'profile':<6} {'variant':<27} {'rules':<8} | {'Onset':>5} {'Detect':>6} {'DetDay':>6} {'Lag':>5}"
          f" {'ProtLag':>7} {'1stProtect':<22} {'StrmB4P':>7} {'PreOns':>6} {'PostOns':>7} {'TeamRcv':>7}"
          f" {'RecovQ':>6} {'RecAll':>6} {'Quit':>6} {'Term':>5} {'Left':>6}")
    for prof in PROFILES:
        for vname, by_rs in res[prof].items():
            for rs in rulesets:
                s = by_rs[rs.name]
                kinds = s["first_protect_kind"]
                top = max(kinds.items(), key=lambda kv: (kv[1], kv[0]))
                print(f"    {prof:<6} {vname:<27} {rs.name:<8} | {s['onset_day_mean']:>5.0f} {s['detection_rate']:>6.0%}"
                      f" {f(s['detection_day_mean'], '{:.0f}'):>6} {f(s['detection_lag_mean'], '{:.0f}'):>5}"
                      f" {f(s['protect_lag_mean'], '{:.0f}'):>7} {top[0] + ' ' + str(top[1]) + '/' + str(s['n_runs']):<22}"
                      f" {f(s['streamed_onset_to_first_protection'], '{:.1%}'):>7}"
                      f" {f(s['team_before_onset'], '{:.1%}'):>6} {f(s['team_after_onset'], '{:.1%}'):>7}"
                      f" {s['team_received']:>7.1%} {f(s['recov_quitters'], '{:.1%}'):>6} {s['recov_all']:>6.1%}"
                      f" {s['quit']:>6.1%} {s['terminal_rate']:>5.0%} {s['funds_left_in_vault']:>6.1%}")


def print_s5(n, s5):
    print(f"\n{'=' * 100}")
    print(f"  S5 whale concentration: team-aligned holder (40 % / 55 %, 1 or 10 wallets) votes INCREASE, N={n}")
    print(f"{'=' * 100}")
    print(f"    {'profile':<6} {'variant':<22} {'rules':<8} | {'AlignCast':>9} {'Quorum':>6} {'INC/run':>7}"
          f" {'INCwin':>6} {'RateMax':>7} {'TeamRcv':>7} {'OthersRec':>9} {'AlignRec':>8} {'Quit':>6} {'Term':>5}"
          f" {'TDay':>5} {'WhVote':>6}")
    for prof in PROFILES:
        for key, by_rs in s5[prof].items():
            for rs in RULESETS:
                s = by_rs[rs.name]
                print(f"    {prof:<6} {key:<22} {rs.name:<8} | {f(s['aligned_share_of_cast'], '{:.0%}'):>9}"
                      f" {f(s['quorum_met_rate'], '{:.0%}'):>6} {s['actions']['increase']:>7.2f}"
                      f" {f(s['increase_win_rate'], '{:.0%}'):>6} {s['rate_max']:>7.2f} {s['team_received']:>7.1%}"
                      f" {s['others_value_recovered']:>9.1%} {s['aligned_value_recovered']:>8.1%}"
                      f" {s['quit']:>6.1%} {s['terminal_rate']:>5.0%} {f(s['terminal_day']['mean'], '{:.0f}'):>5}"
                      f" {f(s['whale_vote_share'], '{:.0%}'):>6}")


def print_a4(n, a4):
    print(f"\n{'=' * 100}")
    print(f"  Sensitivity to v5 assumption A4 (per-round discontent probability x scale), baseline, N={n}")
    print(f"{'=' * 100}")
    print(f"    {'profile':<6} {'scale':>5} {'rules':<8} | {'TeamRcv':>7} {'RecovQ':>6} {'Quit':>6} {'Term':>5}"
          f" {'TDay':>5} {'Bal@T':>6} {'R2':>5} {'Quorum':>6} {'Left':>6}")
    for prof in PROFILES:
        for key, by_rs in a4[prof].items():
            for name in ("v5", "current"):
                s = by_rs[name]
                r2 = s["pauses"]["rule2_pre_cp"] + s["pauses"]["rule2_post_cp"]
                print(f"    {prof:<6} {key[5:]:>5} {name:<8} | {s['team_received']:>7.1%}"
                      f" {f(s['recov_quitters'], '{:.1%}'):>6} {s['quit']:>6.1%} {s['terminal_rate']:>5.0%}"
                      f" {f(s['terminal_day']['mean'], '{:.0f}'):>5} {f(s['balance_at_terminal'], '{:.1%}'):>6}"
                      f" {r2:>5.2f} {f(s['quorum_met_rate'], '{:.0%}'):>6} {s['funds_left_in_vault']:>6.1%}")


def _round(obj):
    if isinstance(obj, float):
        return round(obj, 6)
    if isinstance(obj, dict):
        return {k: _round(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_round(v) for v in obj]
    return obj


def main():
    ap = argparse.ArgumentParser(description="LAF current-rule simulation (v6)")
    ap.add_argument("--json", help="write the machine-readable summary to this path")
    ap.add_argument("--quick", action="store_true", help="tiny N for code checks (not for results)")
    args = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    n_sweep, n_head, n_scen = (4, 6, 4) if args.quick else (50, 200, 50)
    t0 = time.time()

    n_fx = run_fixtures()
    print_preamble(n_sweep, n_head, n_scen, n_fx)

    sweep = {}
    print_sweep(n_sweep, sweep)
    sweep_parity = (Parity.runs, Parity.keys)
    print(f"\nParity: ruleset 'v5' through LAFSimV6 reproduced all {Parity.keys} metrics of v5.run_single"
          f" (DAICO, RDA, LAF) exactly in {Parity.runs} runs (21 cells x {n_sweep} seeds).")
    print(f"  [v6] sweep done {time.time() - t0:.1f}s", file=sys.stderr, flush=True)

    head = {}
    for prof in PROFILES:
        print(f"  [v6] headline {prof}", file=sys.stderr, flush=True)
        _, head[prof] = run_cell(prof, BASE, n_head)
    print_headline(n_head, head)
    print(f"  Parity also holds for the headline runs ({Parity.runs - sweep_parity[0]} more v5 runs, seeds"
          f" 0-{n_head - 1}).")
    print(f"  [v6] headline done {time.time() - t0:.1f}s", file=sys.stderr, flush=True)

    s1 = run_s1(n_scen)
    print_s1(n_scen, s1)
    print(f"  [v6] S1 done {time.time() - t0:.1f}s", file=sys.stderr, flush=True)
    s2 = run_s2(n_scen)
    print_health("S2 malicious team at the maximum permitted rate (no delivery from day 0)", n_scen, s2,
                 [V5_RULES, CURRENT])
    print(f"  [v6] S2 done {time.time() - t0:.1f}s", file=sys.stderr, flush=True)
    s3 = run_s3(n_scen)
    print_health("S3 gradual deterioration (onset U(60,240) d, health to 0 over 180 d)", n_scen, s3, RULESETS)
    print(f"  [v6] S3 done {time.time() - t0:.1f}s", file=sys.stderr, flush=True)
    s5 = run_s5(n_scen)
    print_s5(n_scen, s5)
    print(f"  [v6] S5 done {time.time() - t0:.1f}s", file=sys.stderr, flush=True)
    a4 = run_a4_sensitivity(n_scen)
    print_a4(n_scen, a4)
    print("\n  S1-S3 keys: FalsePause share of runs with any pause (the team is honest), R2pause with a Rule 2")
    print("  pause; Lost = NoPanic - TeamRcv; Detect share of runs whose monitor fires on or after onset within")
    print("  the horizon; DetDay / Lag first firing day / days after onset; ProtLag days from onset to the first")
    print("  protective event (Rule 2 pause, passed PAUSE / DECREASE / HALT, or terminal); 1stProtect most")
    print("  frequent first event; StrmB4P team funding streamed between onset and that event (runs with one);")
    print("  PreOns / PostOns team funding streamed before / after onset; RecAll payouts / raise. S5 keys:")
    print("  AlignCast aligned share of cast weight; INCwin share of initiated windows resolving INCREASE;")
    print("  RateMax highest live rate / initial rate; OthersRec / AlignRec (payouts + shares at end NAV) /")
    print("  deposits of the non-aligned holders / of the aligned holder; TeamRcv includes the aligned stake.")
    print(f"  [v6] all done {time.time() - t0:.1f}s", file=sys.stderr, flush=True)

    if args.json:
        summary = {
            "version": VERSION,
            "generated_by": "01-simulation/capstone_sim_v6.py",
            "status": "current-rule simulation; v5 rules reproduced exactly (parity asserted)",
            "n_runs": {"sweep": n_sweep, "headline_baseline": n_head, "scenarios": n_scen},
            "seeds": {"sweep": f"0-{n_sweep - 1}", "headline_baseline": f"0-{n_head - 1}",
                      "scenarios": f"0-{n_scen - 1}"},
            "rulesets": {rs.name: asdict(rs) for rs in RULESETS},
            "profiles": {prof: {**PROFILES[prof], "horizon_days": PROFILES[prof]["rounds"] * DAYS,
                                "bound_per_round_365d": DAYS / (2.0 * CUR_MIN_VESTING_DAYS),
                                "parity_min_vesting_days": effective_min_vesting_days(PARITY, PROFILES[prof]["tap_rate"])}
                         for prof in PROFILES},
            "fixtures": {"passed": n_fx, "total": len(FIXTURES),
                         "list": [{"id": fid, "check": desc, "mirrors": mirrors} for fid, desc, mirrors, _ in FIXTURES]},
            "parity": {"v5_runs_checked": Parity.runs, "metrics_per_run": Parity.keys, "result": "exact"},
            "metric_notes": {
                "team_received": "claimed by team / raise, at the horizon",
                "recov_quitters": "mean payout / deposit over holders who rage quit (runs with quitters)",
                "recov_all": "rage-quit payouts / raise",
                "terminal_day": "terminal runs only; nearest-rank percentiles",
                "balance_at_terminal": "vault balance / raise when Rule 4 fired (terminal runs)",
                "quorum_met_rate": "initiated windows meeting quorum / initiated windows (pooled)",
                "pauses": "per run; rule2_pre_cp = before the first window opened",
                "funds_left_in_vault": "vault balance / raise at the horizon (not a loss)",
                "whale_vote_share": "whale share of cast weight (runs with votes)",
            },
            "sweep_n50": sweep,
            "headline_baseline": head,
            "scenarios": {
                "S1_honest_team_bank_run": s1,
                "S2_malicious_team_max_rate": s2,
                "S3_gradual_deterioration": s3,
                "S5_whale_concentration": s5,
            },
            "a4_sensitivity_baseline": a4,
        }
        with open(args.json, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(_round(summary), fh, indent=1)
            fh.write("\n")
    print(f"[v6] runtime {time.time() - t0:.1f}s", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
