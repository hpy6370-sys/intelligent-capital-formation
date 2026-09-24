"""
Capstone: Intelligent Capital Formation - Simulation v5.0
DAICO vs Reverse Dutch Auction vs LAF (Layered Accountability Framework)

v5.0 (2026-09-08) adds LAF as a third mechanism next to the v4.2 DAICO and
RDA mechanisms. Ground rules for this version:

- capstone_sim_v4.py is imported, NOT edited. Every DAICO / RDA number v4
  prints is reproduced here byte-for-byte. v5's run_single() first calls
  v4.run_single() (which seeds and consumes the global `random` stream
  exactly as before), then replays the DAICO funding prefix with the same
  seed to recover the identical agent population and contributions (checked
  by an assert against v4's pool + released), and finally runs LAF on that
  population with a *separate* random.Random instance. The v4 stream is
  never touched, so v4's results cannot drift.
- LAF uses the SAME agents and the SAME funding outcome as the DAICO run.
  Each agent's DAICO contribution becomes its LAF deposit (shares minted
  1:1, as LAFVault.deposit() does). DAICO-vs-LAF differences are therefore
  caused by the post-funding mechanism only, not by a different draw of
  agents or a different raise. RDA keeps its own (v4) population because
  it is a different funding phase, not a post-funding layer.
- LAF rules mirror the Solidity prototype in 02-solidity/src
  (LAFVault, RageQuitModule, QuadraticGovernor, SignalMonitor) and the
  design doc laf_solidity_design.md. Everything the prototype leaves open,
  and everything the simulation cannot compute, is listed in LAF_ASSUMPTIONS
  and LAF_SIGNALS_SKIPPED below and printed at the top of the output.

Run:  python capstone_sim_v5.py > output/simulation_v5_results.txt
"""

import math
import random
import sys
from dataclasses import dataclass, field

import capstone_sim_v4 as v4
from capstone_sim_v4 import Agent, make_agents, gini, SCENARIOS, RealDataCalibration

VERSION = "5.0"

# ---------------------------------------------------------------------------
# LAF parameters. Values mirror the contract constructor defaults
# (laf_solidity_design.md section 5) unless marked ASSUMPTION.
# ---------------------------------------------------------------------------
LAF_DAYS_PER_ROUND = 7            # ASSUMPTION: one simulation round = one week
LAF_CHECKPOINT_INTERVAL_DAYS = 90 # QuadraticGovernor.checkpointInterval
LAF_CHECKPOINT_WINDOW_DAYS = 14   # QuadraticGovernor.checkpointWindowDuration
LAF_QUORUM = 0.20                 # quorumBps 2000: 20% of sqrt(totalSupply)
LAF_MAJORITY = 0.50               # majorityBps 5000: winner needs > 50% of cast weight
LAF_PAUSE_RESPONSE_DAYS = 30      # defaultPauseResponsePeriod
LAF_MAX_PAUSE_DAYS = 60           # maxPauseDuration (also the Rule 2 pause length)
LAF_SIGNAL_RATE_LIMIT_DAYS = 30   # signalRateLimit (Rule 3)
LAF_RAGE_QUIT_AUTO_PAUSE = 0.25   # rageQuitAutoPauseBps 2500 (Rule 2)
LAF_POOL_DEPLETION = 0.10         # poolDepletionBps 1000 (Rule 4)
LAF_SIGNAL_WINDOW_DAYS = 30       # SignalMonitor measurement window
LAF_WARNING_COMBINATOR = 2        # >= 2 warnings trigger an early checkpoint
LAF_CRITICAL_COMBINATOR = 1       # >= 1 critical triggers an early checkpoint
LAF_RATE_STEP = 0.30              # ASSUMPTION: INCREASE/DECREASE delta = 30% of initial rate (DAICO raise = x1.3)
LAF_RATE_CAP_ABS = 0.15           # ASSUMPTION: rate cap = 15% of raise per round (DAICO caps tap_rate at 0.15)
LAF_CONCERN_SCALE = 1.0           # multiplier on the A4 discontent probability; 1.0 = DAICO parity.
                                  # Only sim_v5_sensitivity.py changes this; the main run uses 1.0.

# SignalMonitor thresholds (warning, critical), Proposal v3 section 6.5
SIGNAL_THRESHOLDS = {
    "TVL_DECLINE": (0.40, 0.70),          # 30-day decline of vault balance
    "ACTIVE_ADDR_DECLINE": (0.50, 0.80),  # 30-day decline of share-holder count
    "TEAM_OUTFLOW": (3.0, 10.0),          # team claim rate vs initial rate (multiplier)
    "HHI_INCREASE": (0.15, 0.30),         # 30-day rise of share-concentration HHI
}
LAF_SIGNALS_SKIPPED = {
    "COMMIT_INACTIVITY": "needs a GitHub commit feed; the model has no development activity variable, so it is not evaluated",
}

CONTINUE, INCREASE_RATE, DECREASE_RATE, PAUSE_FOR_AUDIT, HALT = (
    "CONTINUE", "INCREASE_RATE", "DECREASE_RATE", "PAUSE_FOR_AUDIT", "HALT")
ACTIONS = [CONTINUE, INCREASE_RATE, DECREASE_RATE, PAUSE_FOR_AUDIT, HALT]

# ---------------------------------------------------------------------------
# Behavioral rules, written out once and printed in the output. The code in
# LAFSim follows these lines one for one.
# ---------------------------------------------------------------------------
LAF_ASSUMPTIONS = [
    "A1 Population: LAF runs on the DAICO agent population of the same seed; each agent's DAICO",
    "   contribution is its LAF deposit, shares minted 1:1. No new agents, no secondary market.",
    "A2 Time: 1 round = 7 days. Horizons: v3 50 rounds = 350 d, small 20 rounds = 140 d, large 80 rounds",
    "   = 560 d. Scheduled checkpoints (90 d interval, 14 d window) therefore fire 3 / 1 / 5 times",
    "   (the interval is measured from the previous resolution, so one cycle is 90 + 14 days).",
    "A3 Stream rate: ratePerRound = tap_rate x total raised (linear on the initial raise). This is the",
    "   same headline rate as DAICO's tap, which is geometric on the remaining pool. Team claims every round.",
    "A4 Discontent: the DAICO destroy-vote propensity p = max(0.005, 0.03 - 0.02 x fomo) is reused as the",
    "   per-round probability that a rational or whale agent becomes 'concerned' (persistent flag).",
    "A5 Exit rules (rage quit is always full-stake; partial quits not modeled):",
    "   rational      quits when concerned, or when any CRITICAL signal is active, or with p=0.5 per round",
    "                 while any WARNING signal is active (exit over voice).",
    "   whale         votes first: concerned whale votes PAUSE_FOR_AUDIT at the next checkpoint and quits only",
    "                 if that checkpoint resolves CONTINUE (voice failed); quits at once on CRITICAL.",
    "   speculator    no token price exists in the model, so profit-taking cannot be modeled; speculators are",
    "                 trend-followers: quit with p=0.5 per round on WARNING, p=0.5 after a PAUSE/HALT",
    "                 resolution, always on CRITICAL.",
    "   fomo_follower quits with p = herding_sensitivity x (share of supply that rage-quit in the last 30 d),",
    "                 +0.5 on CRITICAL.",
    "   late_entrant  passive: quits with p=0.5 per round on CRITICAL only.",
    "   everyone      quits when the vault is terminal (Rule 4): that IS the pro-rata wind-down.",
    "A6 Voting (sqrt(shares at window open) weight, one vote per holder per window, only current holders vote):",
    "   audit vote is initiated if any concerned holder exists or any signal is active; otherwise the window",
    "   resolves CONTINUE untouched (governance apathy default, Limitation 5).",
    "   rational      PAUSE_FOR_AUDIT on CRITICAL, DECREASE_RATE on WARNING, else abstains.",
    "   whale         PAUSE_FOR_AUDIT if concerned or CRITICAL, DECREASE_RATE on WARNING, else CONTINUE.",
    "   speculator    INCREASE_RATE with p = 0.15 + 0.15 x fomo (DAICO raise-vote rule), else abstains.",
    "   fomo_follower with p = herding_sensitivity votes the current plurality (votes are tallied after the",
    "                 other types), else abstains.",
    "   late_entrant  abstains.",
    "A7 Resolution (mirrors QuadraticGovernor.resolveCheckpoint): quorum = 20% of sqrt(total shares at open),",
    "   winner must exceed 50% of cast weight, else CONTINUE. INCREASE/DECREASE move the rate by 30% of the",
    "   initial rate (cap 15% of raise per round, floor 0). PAUSE_FOR_AUDIT pauses 30 d. HALT sets rate 0",
    "   until a later INCREASE_RATE. Pauses end by timeout (Rule 1b); no separate resume vote is modeled.",
    "A8 Rule 2 mirrors the contract: cumulative rage quit since the last window open > 25% of the balance",
    "   snapshotted at that open pauses the stream 60 d. Before the first window opens the snapshot is 0 and",
    "   the rule is inactive, exactly as in LAFVault.withdrawForRageQuit.",
    "A9 Rule 4: unreleased balance < 10% of the raise makes the vault terminal (rate 0, everyone exits pro rata).",
    "   Once terminal, checkpoints and signals stop: claim() reverts forever, so no governor action can change",
    "   anything. Checkpoint / signal counts therefore describe the live phase only.",
    "A10 Signals use model proxies: TVL = vault balance, active addresses = holders with shares > 0, team",
    "    outflow = current rate / initial rate, HHI = sum of squared share fractions. Each is compared with",
    "    its value 28 d (4 rounds) earlier. COMMIT_INACTIVITY has no proxy and is skipped. Early checkpoints",
    "    are rate-limited to one per 30 d and are a no-op while a window is open (Rule 3).",
    "A11 No exogenous project failure process exists in the FOMO/herding scenarios, so signal-driven",
    "    behaviour is only exercised when agent exits themselves move the proxies past a threshold.",
]


@dataclass
class LAFHolder:
    id: int
    agent_type: str
    fomo_sensitivity: float
    herding_sensitivity: float
    deposited: float
    shares: float
    concerned: bool = False
    voice_failed: bool = False
    quit_round: int = -1
    payout: float = 0.0

    @classmethod
    def from_agent(cls, a: Agent) -> "LAFHolder":
        return cls(id=a.id, agent_type=a.agent_type,
                   fomo_sensitivity=a.fomo_sensitivity,
                   herding_sensitivity=a.herding_sensitivity,
                   deposited=a.tokens_held, shares=a.tokens_held)


@dataclass
class Window:
    open_day: int
    end_day: int
    trigger: str
    weights: dict                      # holder id -> sqrt(shares at open)
    total_shares_at_open: float
    initiated: bool = False
    tallies: dict = field(default_factory=lambda: {a: 0.0 for a in ACTIONS})
    total_weight: float = 0.0
    whale_weight: float = 0.0
    voted: set = field(default_factory=set)


class LAFSim:
    """One LAF vault + governor + monitor, stepped one round (7 days) at a time.
    All randomness comes from `rng` (a private random.Random), never from the
    global `random` module, so the v4 DAICO/RDA stream is untouched."""

    def __init__(self, holders: list[LAFHolder], tap_rate: float, rng: random.Random):
        self.holders = holders
        self.rng = rng
        self.D = LAF_DAYS_PER_ROUND
        self.total_deposited = sum(h.deposited for h in holders)
        self.total_shares = self.total_deposited
        self.initial_rate = tap_rate * self.total_deposited      # per round (A3)
        self.rate_mult = 1.0
        self.rate_cap_mult = LAF_RATE_CAP_ABS / tap_rate
        self.day = 0
        self.round = 0
        self.accrued = 0.0        # LAFVault._totalStreamed()
        self.claimed = 0.0        # totalClaimedByTeam
        self.exited = 0.0         # totalExitedViaRageQuit
        self.paused = False
        self.paused_at = 0
        self.pause_period = 0
        self.paused_days = 0
        self.terminal = False
        # Rule 2 bookkeeping (LAFVault.markCheckpointWindowOpen)
        self.unreleased_at_open = 0.0
        self.cum_rq_in_window = 0.0
        # Governance
        self.window: Window | None = None
        self.last_checkpoint_end = 0
        self.last_signal_day = None
        self.adverse_resolution = False
        # Signal monitor
        self.signal_window_rounds = max(1, round(LAF_SIGNAL_WINDOW_DAYS / self.D))
        self.history: list[tuple] = []          # (unreleased, holders, hhi) at end of each round
        self.quit_frac_by_round: list[float] = []
        self.warning_active: set = set()
        self.critical_active: set = set()
        # Stats
        self.checkpoints = 0
        self.signal_triggers = 0
        self.rule2_pauses = 0
        self.actions = {a: 0 for a in ACTIONS}
        self.whale_vote_shares: list[float] = []
        self.warning_rounds = 0

    # ---- vault views --------------------------------------------------
    @property
    def unreleased(self) -> float:
        return max(0.0, self.total_deposited - self.claimed - self.exited)

    def holders_count(self) -> int:
        return sum(1 for h in self.holders if h.shares > 0)

    def hhi(self) -> float:
        if self.total_shares <= 0:
            return 0.0
        return sum((h.shares / self.total_shares) ** 2 for h in self.holders if h.shares > 0)

    # ---- main loop ----------------------------------------------------
    def run(self, rounds: int):
        for _ in range(rounds):
            self.tick()

    def tick(self):
        self.round += 1
        self.day += self.D

        # Rule 1(b): pause timeout is permissionless, so it resolves as soon as it is due.
        if self.paused and self.day >= self.paused_at + self.pause_period:
            self.paused = False

        # Layer 1: linear stream, team claims every round (A3).
        if self.paused:
            self.paused_days += self.D
        elif not self.terminal:
            self.accrued += self.initial_rate * self.rate_mult
        claim = min(max(self.accrued - self.claimed, 0.0), self.unreleased)
        if self.paused or self.terminal:
            claim = 0.0
        self.claimed += claim

        self._check_depletion()                       # Rule 4

        if self.window is not None and self.day > self.window.end_day:
            self._resolve()                           # Layer 3 resolution

        # After Rule 4 the vault is terminal: claim() reverts forever, so every
        # governor action is a no-op and the monitor has nothing left to protect.
        # Governance and signals stop here so the checkpoint / signal counts only
        # measure the live phase (A9).
        if not self.terminal:
            self._evaluate_signals()                  # Layer 4 (may open a SIGNAL window)
            if self.window is None and self.day >= self.last_checkpoint_end + LAF_CHECKPOINT_INTERVAL_DAYS:
                self._open_window("SCHEDULED")

        shares_before = self.total_shares
        self._agents_act()                            # Layer 2 exits (A5)
        self.quit_frac_by_round.append(
            (shares_before - self.total_shares) / shares_before if shares_before > 0 else 0.0)
        self._check_depletion()                       # Rule 4 again after exits

        if self.window is not None and self.day <= self.window.end_day and not self.terminal:
            self._voting()                            # Layer 3 votes (A6)

        self.history.append((self.unreleased, self.holders_count(), self.hhi()))
        self.adverse_resolution = False

    # ---- Rule 4 ---------------------------------------------------------
    def _check_depletion(self):
        if not self.terminal and self.unreleased < self.total_deposited * LAF_POOL_DEPLETION:
            self.terminal = True
            self.rate_mult = 0.0

    # ---- Layer 4 --------------------------------------------------------
    def _evaluate_signals(self):
        k = self.signal_window_rounds
        if len(self.history) < k:
            return
        then_unrel, then_holders, then_hhi = self.history[-k]
        vals = {
            "TVL_DECLINE": 1 - self.unreleased / then_unrel if then_unrel > 0 else 0.0,
            "ACTIVE_ADDR_DECLINE": 1 - self.holders_count() / then_holders if then_holders > 0 else 0.0,
            "TEAM_OUTFLOW": 0.0 if (self.paused or self.terminal) else self.rate_mult,
            "HHI_INCREASE": self.hhi() - then_hhi,
        }
        self.warning_active = {m for m, v in vals.items() if v >= SIGNAL_THRESHOLDS[m][0]}
        self.critical_active = {m for m, v in vals.items() if v >= SIGNAL_THRESHOLDS[m][1]}
        if self.warning_active:
            self.warning_rounds += 1
        fires = (len(self.warning_active) >= LAF_WARNING_COMBINATOR
                 or len(self.critical_active) >= LAF_CRITICAL_COMBINATOR)
        if not fires:
            return
        # Rule 3: rate limit and no-op while a window is open.
        if self.last_signal_day is not None and self.day < self.last_signal_day + LAF_SIGNAL_RATE_LIMIT_DAYS:
            return
        if self.window is not None:
            return
        self.last_signal_day = self.day
        self.signal_triggers += 1
        self._open_window("SIGNAL")

    # ---- Layer 3 --------------------------------------------------------
    def _open_window(self, trigger: str):
        self.window = Window(
            open_day=self.day, end_day=self.day + LAF_CHECKPOINT_WINDOW_DAYS, trigger=trigger,
            weights={h.id: math.sqrt(h.shares) for h in self.holders if h.shares > 0},
            total_shares_at_open=self.total_shares,
        )
        # LAFVault.markCheckpointWindowOpen: snapshot for Rule 2, reset the window counter.
        self.unreleased_at_open = self.unreleased
        self.cum_rq_in_window = 0.0

    def _voting(self):
        w = self.window
        crit, warn = bool(self.critical_active), bool(self.warning_active)
        if not w.initiated and (crit or warn or any(h.concerned and h.shares > 0 for h in self.holders)):
            w.initiated = True
        if not w.initiated:
            return
        ordered = ([h for h in self.holders if h.agent_type != "fomo_follower"]
                   + [h for h in self.holders if h.agent_type == "fomo_follower"])
        for h in ordered:
            if h.shares <= 0 or h.id in w.voted or h.id not in w.weights:
                continue
            opt = None
            if h.agent_type == "rational":
                opt = PAUSE_FOR_AUDIT if crit else DECREASE_RATE if warn else None
            elif h.agent_type == "whale":
                opt = (PAUSE_FOR_AUDIT if (h.concerned or crit)
                       else DECREASE_RATE if warn else CONTINUE)
            elif h.agent_type == "speculator":
                if self.rng.random() < 0.15 + h.fomo_sensitivity * 0.15:
                    opt = INCREASE_RATE
            elif h.agent_type == "fomo_follower":
                if w.total_weight > 0 and self.rng.random() < h.herding_sensitivity:
                    opt = max(ACTIONS, key=lambda a: w.tallies[a])
            if opt is None:
                continue
            weight = w.weights[h.id]
            w.tallies[opt] += weight
            w.total_weight += weight
            w.voted.add(h.id)
            if h.agent_type == "whale":
                w.whale_weight += weight

    def _resolve(self):
        w = self.window
        action = CONTINUE
        if w.initiated and w.total_weight > 0:
            quorum = LAF_QUORUM * math.sqrt(w.total_shares_at_open)
            if w.total_weight >= quorum:
                best = max(ACTIONS, key=lambda a: w.tallies[a])
                if w.tallies[best] > LAF_MAJORITY * w.total_weight:
                    action = best
            self.whale_vote_shares.append(w.whale_weight / w.total_weight)
        self._apply(action)
        for h in self.holders:
            if h.agent_type == "whale" and h.concerned and h.shares > 0:
                if action == CONTINUE:
                    h.voice_failed = True          # voice failed: whale exits next round (A5)
                else:
                    h.concerned = False            # governance responded
                    h.voice_failed = False
        self.actions[action] += 1
        self.checkpoints += 1
        self.last_checkpoint_end = self.day
        self.adverse_resolution = action in (PAUSE_FOR_AUDIT, HALT)
        self.window = None

    def _apply(self, action: str):
        if action == INCREASE_RATE:
            self.rate_mult = min(self.rate_mult + LAF_RATE_STEP, self.rate_cap_mult)
        elif action == DECREASE_RATE:
            self.rate_mult = max(0.0, self.rate_mult - LAF_RATE_STEP)
        elif action == PAUSE_FOR_AUDIT:
            if not self.terminal:
                self._pause(LAF_PAUSE_RESPONSE_DAYS)
        elif action == HALT:
            self.rate_mult = 0.0

    def _pause(self, period_days: int):
        self.paused = True
        self.paused_at = self.day
        self.pause_period = period_days

    # ---- Layer 2 --------------------------------------------------------
    def _agents_act(self):
        k = self.signal_window_rounds
        trailing_quit = sum(self.quit_frac_by_round[-k:]) if self.quit_frac_by_round else 0.0
        crit, warn = bool(self.critical_active), bool(self.warning_active)
        rng = self.rng
        for h in self.holders:
            if h.shares <= 0:
                continue
            if h.agent_type in ("rational", "whale") and not h.concerned:
                if rng.random() < LAF_CONCERN_SCALE * max(0.005, 0.03 - h.fomo_sensitivity * 0.02):   # A4
                    h.concerned = True
            if self.terminal:
                quit_now = True
            elif h.agent_type == "rational":
                quit_now = h.concerned or crit or (warn and rng.random() < 0.5)
            elif h.agent_type == "whale":
                quit_now = crit or (h.concerned and h.voice_failed)
            elif h.agent_type == "speculator":
                quit_now = (crit or (warn and rng.random() < 0.5)
                            or (self.adverse_resolution and rng.random() < 0.5))
            elif h.agent_type == "fomo_follower":
                p = min(1.0, h.herding_sensitivity * trailing_quit + (0.5 if crit else 0.0))
                quit_now = rng.random() < p
            else:  # late_entrant
                quit_now = crit and rng.random() < 0.5
            if quit_now:
                self._rage_quit(h)

    def _rage_quit(self, h: LAFHolder):
        if self.total_shares <= 0:
            return
        payout = self.unreleased * h.shares / self.total_shares
        if payout <= 0:
            return                                   # RageQuitModule: ZeroPayout revert
        self.exited += payout
        self.total_shares -= h.shares
        if self.total_shares < 1e-9:
            self.total_shares = 0.0
        h.payout = payout
        h.quit_round = self.round
        h.shares = 0.0
        # Rule 2 (LAFVault.withdrawForRageQuit)
        self.cum_rq_in_window += payout
        if (self.unreleased_at_open > 0
                and self.cum_rq_in_window > self.unreleased_at_open * LAF_RAGE_QUIT_AUTO_PAUSE
                and not self.paused and not self.terminal):
            self._pause(LAF_MAX_PAUSE_DAYS)
            self.rule2_pauses += 1


# ---------------------------------------------------------------------------
# Metrics. Same definitions as v4 wherever a DAICO/RDA counterpart exists.
# ---------------------------------------------------------------------------

def _pearson(xs, ys):
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    cov = sum((xs[i] - mx) * (ys[i] - my) for i in range(n)) / n
    sx = math.sqrt(sum((x - mx) ** 2 for x in xs) / n)
    sy = math.sqrt(sum((y - my) ** 2 for y in ys) / n)
    if sx == 0 or sy == 0:
        return 0.0
    return cov / (sx * sy)


def laf_metrics(sim: LAFSim, n_agents: int) -> dict:
    hs = sim.holders
    total_dep = sim.total_deposited
    shares = [h.shares for h in hs]
    total_sh = sum(shares) or 1.0
    nav = sim.unreleased / sim.total_shares if sim.total_shares > 0 else 0.0

    top = sorted(shares, reverse=True)
    top10pct = sum(top[:max(1, n_agents // 10)]) / total_sh
    whale_dom = sum(h.shares for h in hs if h.agent_type == "whale") / total_sh
    # Dollar outcome per holder: rage-quit payout plus remaining shares at end NAV.
    # DAICO tokens are 1:1 with dollars, so DAICO's token Gini is also a dollar
    # Gini; this is the LAF quantity on the same footing (it stays defined when
    # everyone has exited, unlike the final-share Gini which collapses to 0).
    value = [h.payout + h.shares * nav for h in hs]

    # ROI per dollar = (rage-quit payout + remaining shares at end-NAV) / deposit.
    # DAICO's tokens/spent is 1.0 for everyone; LAF's analogue is dollar value
    # recovered or still held per dollar deposited, which depends on exit timing.
    by_type: dict[str, list[float]] = {}
    for h in hs:
        if h.deposited > 0:
            by_type.setdefault(h.agent_type, []).append((h.payout + h.shares * nav) / h.deposited)
    type_means = [sum(v) / len(v) for v in by_type.values() if v]
    if len(type_means) < 2:
        roi_var = 0.0
    else:
        m = sum(type_means) / len(type_means)
        roi_var = math.sqrt(sum((t - m) ** 2 for t in type_means) / len(type_means))

    quitters = [h for h in hs if h.quit_round > 0]
    q_dep = sum(h.deposited for h in quitters)
    q_pay = sum(h.payout for h in quitters)
    timing_corr = _pearson([h.quit_round for h in quitters],
                           [h.payout / h.deposited for h in quitters if h.deposited > 0])

    return {
        "laf_pool": sim.unreleased,
        "laf_released": sim.claimed,
        "laf_exited": sim.exited,
        "laf_efficiency": 0.0 if sim.terminal else (sim.claimed / total_dep if total_dep > 0 else 0.0),
        "laf_terminal": sim.terminal,
        # Dimension 1
        "laf_gini": gini(shares),
        "laf_gini_value": gini(value),
        "laf_top10pct": top10pct,
        # Dimension 2
        "laf_whale_dom": whale_dom,
        "laf_whale_vote_share": (sum(sim.whale_vote_shares) / len(sim.whale_vote_shares)
                                 if sim.whale_vote_shares else None),
        "laf_timing_corr": timing_corr,
        # Dimension 3
        "laf_retention": sim.claimed / total_dep if total_dep > 0 else 0.0,
        "laf_roi_var": roi_var,
        # LAF-specific
        "laf_recovery_quitters": (q_pay / q_dep) if q_dep > 0 else None,
        "laf_recovery_total": q_pay / total_dep if total_dep > 0 else 0.0,
        "laf_quit_frac": len(quitters) / len(hs) if hs else 0.0,
        "laf_team_received": sim.claimed / total_dep if total_dep > 0 else 0.0,
        "laf_participants": sim.holders_count(),
        "laf_nav_end": nav,
        "laf_checkpoints": sim.checkpoints,
        "laf_signal_triggers": sim.signal_triggers,
        "laf_rule2_pauses": sim.rule2_pauses,
        "laf_paused_days": sim.paused_days,
        "laf_warning_rounds": sim.warning_rounds,
        "laf_act_continue": sim.actions[CONTINUE],
        "laf_act_increase": sim.actions[INCREASE_RATE],
        "laf_act_decrease": sim.actions[DECREASE_RATE],
        "laf_act_pause": sim.actions[PAUSE_FOR_AUDIT],
        "laf_act_halt": sim.actions[HALT],
    }


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def run_single(n_agents=30, rounds=50, fomo=0.0, herding=0.0, seed=None,
               capital_scale=1.0, tap_rate=0.01,
               rda_start_price=10.0, rda_end_price=1.0):
    if seed is None:
        raise ValueError("v5 run_single needs a seed to replay the v4 funding prefix")

    # 1. v4 as-is: seeds the global RNG and consumes it exactly as v4.2 does.
    res = v4.run_single(n_agents=n_agents, rounds=rounds, fomo=fomo, herding=herding,
                        seed=seed, capital_scale=capital_scale, tap_rate=tap_rate,
                        rda_start_price=rda_start_price, rda_end_price=rda_end_price)

    # 2. Replay v4's funding prefix (same seed, same call order) to recover the
    #    identical DAICO population and contributions.
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
    assert abs(daico.pool - v4_total) <= 1e-9 * max(1.0, v4_total), \
        f"replayed DAICO funding {daico.pool} != v4 pool+released {v4_total} (seed {seed})"

    # 3. LAF on the same population, private RNG.
    holders = [LAFHolder.from_agent(a) for a in agents if a.tokens_held > 0]
    sim = LAFSim(holders, tap_rate, random.Random(seed * 1_000_003 + 20260908))
    sim.run(rounds)
    # Accounting identity from LAFVault: balance == deposited - claimed - exited
    assert sim.unreleased >= 0 and sim.claimed + sim.exited <= sim.total_deposited * (1 + 1e-9)

    return {**res, **laf_metrics(sim, n_agents)}


def run_monte_carlo(n_runs=100, **kwargs):
    results = [run_single(seed=i, **kwargs) for i in range(n_runs)]
    avg = {}
    for key in results[0]:
        vals = [r[key] for r in results if r[key] is not None]
        if not vals:
            avg[key] = 0.0
        elif isinstance(vals[0], bool):
            avg[key] = sum(1 for v in vals if v) / n_runs
        else:
            avg[key] = sum(vals) / len(vals)       # None-valued runs are skipped (undefined, not zero)
    return avg


def print_laf(res):
    print(f"  LAF:")
    print(f"    Pool remaining:    {res['laf_pool']:.2f}")
    print(f"    Released to team:  {res['laf_released']:.2f}")
    print(f"    Exited (rage quit):{res['laf_exited']:.2f}")
    print(f"    Release efficiency:{res['laf_efficiency']:.1%}")
    print(f"    Terminal (Rule 4): {res['laf_terminal']:.0%}")
    print(f"    [D1] Gini coefficient:  {res['laf_gini']:.3f}   (final shares; 0 when everyone has exited)")
    print(f"    [D1] Gini of $ outcome: {res['laf_gini_value']:.3f}   (payout + held shares at end NAV)")
    print(f"    [D1] Top 10% share:     {res['laf_top10pct']:.1%}")
    print(f"    [D2] Whale dominance:   {res['laf_whale_dom']:.1%}")
    print(f"    [D2] Whale vote weight: {res['laf_whale_vote_share']:.1%}")
    print(f"    [D2] Timing corr:       {res['laf_timing_corr']:.3f}")
    print(f"    [D3] Capital retention: {res['laf_retention']:.1%}")
    print(f"    [D3] ROI variance:      {res['laf_roi_var']:.4f}")
    print(f"    [LAF] Investor recovery (quitters):    {res['laf_recovery_quitters']:.1%}")
    print(f"    [LAF] Investor recovery (all capital): {res['laf_recovery_total']:.1%}")
    print(f"    [LAF] Team received:                   {res['laf_team_received']:.1%}")
    print(f"    [LAF] Rage-quit rate (agents):         {res['laf_quit_frac']:.1%}"
          f"   holders remaining: {res['laf_participants']:.1f}   end NAV/share: {res['laf_nav_end']:.3f}")
    print(f"    [LAF] Checkpoints: {res['laf_checkpoints']:.2f}  signal-triggered: {res['laf_signal_triggers']:.2f}"
          f"  Rule-2 pauses: {res['laf_rule2_pauses']:.2f}  paused days: {res['laf_paused_days']:.1f}"
          f"  warning rounds: {res['laf_warning_rounds']:.2f}")
    print(f"    [LAF] Outcomes/run: CONTINUE {res['laf_act_continue']:.2f}  INCREASE {res['laf_act_increase']:.2f}"
          f"  DECREASE {res['laf_act_decrease']:.2f}  PAUSE {res['laf_act_pause']:.2f}  HALT {res['laf_act_halt']:.2f}")


def print_results(label, res):
    v4.print_results(label, res)       # DAICO + RDA block, unchanged
    print_laf(res)


def run_sweep(N, extra_params, header):
    print(f"\n{'#'*60}")
    print(f"# {header}")
    print(f"{'#'*60}")
    all_results = []
    for label, params in SCENARIOS:
        print(f"  [v5] {header[:20]:<20} | {label}", file=sys.stderr, flush=True)
        res = run_monte_carlo(n_runs=N, **{**extra_params, **params})
        print_results(label, res)
        all_results.append((label, res))

    # v4 summary table, verbatim
    print(f"\n{'-'*120}")
    print("  Summary Table (3 Shyam Dimensions)")
    print(f"{'-'*120}")
    print(f"{'Scenario':<30} | {'D1:AllocEff':^20} | {'D2:ManipResist':^25} | {'D3:IncentAlign':^20}")
    print(f"{'':30} | {'D_Gini':>8} {'R_Gini':>8} | {'R_Vol':>8} {'D_Whale':>8} {'R_Whale':>8} | {'D_ROIv':>8} {'R_ROIv':>8}")
    print("-" * 120)
    for label, res in all_results:
        print(f"{label:<30} | {res['daico_gini']:>8.3f} {res['rda_gini']:>8.3f} | "
              f"{res['rda_volatility']:>8.4f} {res['daico_whale_dom']:>7.1%} {res['rda_whale_dom']:>7.1%} | "
              f"{res['daico_roi_var']:>8.4f} {res['rda_roi_var']:>8.4f}")

    # v5 three-mechanism table
    print(f"\n{'-'*150}")
    print("  Three-mechanism Table (v5): DAICO | RDA | LAF, one row per scenario")
    print(f"{'-'*150}")
    print(f"{'Scenario':<30} | {'DAICO':^24} | {'RDA':^24} | {'LAF':^58}")
    print(f"{'':30} | {'Eff':>7} {'Gini':>7} {'Whale':>7} | {'Gini':>7} {'Whale':>7} {'Partic':>7} | "
          f"{'TeamRcv':>7} {'Gini$':>7} {'Whale':>7} {'RecovQ':>7} {'Quit%':>7} {'Term%':>6} {'CP':>5} {'Sig':>5}")
    print("-" * 150)
    for label, res in all_results:
        print(f"{label:<30} | {res['daico_efficiency']:>7.1%} {res['daico_gini']:>7.3f} {res['daico_whale_dom']:>7.1%} | "
              f"{res['rda_gini']:>7.3f} {res['rda_whale_dom']:>7.1%} {res['rda_participants']:>7.1f} | "
              f"{res['laf_team_received']:>7.1%} {res['laf_gini_value']:>7.3f} {res['laf_whale_dom']:>7.1%} "
              f"{res['laf_recovery_quitters']:>7.1%} {res['laf_quit_frac']:>7.1%} {res['laf_terminal']:>6.0%} "
              f"{res['laf_checkpoints']:>5.2f} {res['laf_signal_triggers']:>5.2f}")
    print("  Gini$ = Gini of dollar outcome (rage-quit payout + held shares at end NAV); comparable with DAICO Gini,")
    print("  whose tokens are 1:1 dollars. Whale = whale share of remaining shares (0 when everyone has exited).")
    return all_results


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding='utf-8')

    N = 50
    print(f"Capstone ICF Simulation v{VERSION} -- calibrated with real project data")
    print(f"DAICO vs Reverse Dutch Auction vs LAF | Monte Carlo N={N}")
    print()
    for line in RealDataCalibration.summary_lines():
        print(line)

    print()
    print("LAF (Layered Accountability Framework) modeling assumptions and agent rules:")
    for line in LAF_ASSUMPTIONS:
        print("  " + line)
    print("  Signals not evaluated:")
    for name, why in LAF_SIGNALS_SKIPPED.items():
        print(f"    {name}: {why}")
    print("  Monte Carlo averages of laf_whale_vote_share, laf_timing_corr and laf_recovery_quitters skip runs")
    print("  where the quantity is undefined (no votes cast / fewer than 3 quitters / no quitters).")

    v3_defaults = {"n_agents": 30, "rounds": 50, "capital_scale": 1.0, "tap_rate": 0.01,
                   "rda_start_price": 10.0, "rda_end_price": 1.0}

    results_v3 = run_sweep(N, v3_defaults, "v3 defaults (uncalibrated, for reference)")
    results_small = run_sweep(N, RealDataCalibration.small_project_config(),
                               "small_project profile (Solana/Gnosis/Abyss-scale, calibrated)")
    results_large = run_sweep(N, RealDataCalibration.large_project_config(),
                               "large_project profile (Casper/Mina/Flow/Algorand-scale, calibrated)")

    # --- v4 comparison block, verbatim ---
    print(f"\n{'='*90}")
    print("  Comparison: v3 defaults vs v4 calibrated profiles (baseline scenario)")
    print(f"{'='*90}")
    baseline_label = SCENARIOS[0][0]
    v3_base = dict(results_v3)[baseline_label]
    small_base = dict(results_small)[baseline_label]
    large_base = dict(results_large)[baseline_label]

    def row(name, key, fmt):
        v3v, smv, lgv = v3_base[key], small_base[key], large_base[key]
        print(f"  {name:<28} v3={fmt(v3v):>12}   small={fmt(smv):>12}   large={fmt(lgv):>12}")

    print("  -- Core --")
    row("DAICO release efficiency", "daico_efficiency", lambda v: f"{v:.1%}")
    row("RDA total raised", "rda_pool", lambda v: f"{v:,.2f}")
    row("RDA participants", "rda_participants", lambda v: f"{v:.1f}")
    print("  -- D1: Allocation Efficiency --")
    row("DAICO Gini", "daico_gini", lambda v: f"{v:.3f}")
    row("RDA Gini", "rda_gini", lambda v: f"{v:.3f}")
    print("  -- D2: Manipulation Resistance --")
    row("RDA price volatility", "rda_volatility", lambda v: f"{v:.4f}")
    row("DAICO whale dominance", "daico_whale_dom", lambda v: f"{v:.1%}")
    row("RDA whale dominance", "rda_whale_dom", lambda v: f"{v:.1%}")
    row("RDA timing correlation", "rda_timing_corr", lambda v: f"{v:.3f}")
    print("  -- D3: Incentive Alignment --")
    row("DAICO capital retention", "daico_retention", lambda v: f"{v:.1%}")
    row("DAICO ROI variance", "daico_roi_var", lambda v: f"{v:.4f}")
    row("RDA ROI variance", "rda_roi_var", lambda v: f"{v:.4f}")

    print()
    print("  Key calibration effects vs v3 defaults:")
    print(f"    - RDA end price is {RealDataCalibration.rda_price_decline_ratio():.0%} of start price"
          f" (Algorand-derived), not v3's 10% -- auctions clear higher and raise more per token.")
    print(f"    - small_project has fewer, richer agents ({RealDataCalibration.small_project_n_agents()} agents,"
          f" {RealDataCalibration.small_project_capital_scale():.1f}x capital) -- niche-raise pattern.")
    print(f"    - large_project has many more, smaller-capital agents ({RealDataCalibration.large_project_n_agents()} agents,"
          f" {RealDataCalibration.large_project_capital_scale():.1f}x capital) -- mass-raise pattern,"
          f" typically pulling Gini down and participant counts up relative to v3's flat n_agents=30.")

    # --- v5 LAF comparison block ---
    print(f"\n{'='*90}")
    print("  Comparison (v5): LAF vs DAICO on the same agents, baseline scenario")
    print(f"{'='*90}")
    print("  -- Core --")
    row("LAF release efficiency", "laf_efficiency", lambda v: f"{v:.1%}")
    row("LAF team received", "laf_team_received", lambda v: f"{v:.1%}")
    row("LAF exited via rage quit", "laf_exited", lambda v: f"{v:,.2f}")
    row("LAF terminal (Rule 4) rate", "laf_terminal", lambda v: f"{v:.0%}")
    print("  -- D1: Allocation Efficiency --")
    row("LAF Gini (final shares)", "laf_gini", lambda v: f"{v:.3f}")
    row("LAF Gini ($ outcome)", "laf_gini_value", lambda v: f"{v:.3f}")
    row("LAF top 10% share", "laf_top10pct", lambda v: f"{v:.1%}")
    print("  -- D2: Manipulation Resistance --")
    row("LAF whale dominance", "laf_whale_dom", lambda v: f"{v:.1%}")
    row("LAF whale vote weight", "laf_whale_vote_share", lambda v: f"{v:.1%}")
    row("LAF timing correlation", "laf_timing_corr", lambda v: f"{v:.3f}")
    print("  -- D3: Incentive Alignment --")
    row("LAF capital retention", "laf_retention", lambda v: f"{v:.1%}")
    row("LAF ROI variance", "laf_roi_var", lambda v: f"{v:.4f}")
    print("  -- LAF-specific --")
    row("Investor recovery (quitters)", "laf_recovery_quitters", lambda v: f"{v:.1%}")
    row("Investor recovery (all cap.)", "laf_recovery_total", lambda v: f"{v:.1%}")
    row("Rage-quit rate (agents)", "laf_quit_frac", lambda v: f"{v:.1%}")
    row("Checkpoints per run", "laf_checkpoints", lambda v: f"{v:.2f}")
    row("Signal-triggered per run", "laf_signal_triggers", lambda v: f"{v:.2f}")
    row("Rule-2 pauses per run", "laf_rule2_pauses", lambda v: f"{v:.2f}")
    print()
    print("  Reading guide: DAICO and LAF share the same raise and the same initial share distribution, so")
    print("  DAICO Gini equals LAF's Gini at day 0; LAF's final Gini reflects who exited. 'Team received' for")
    print("  LAF is the linear-stream analogue of DAICO capital retention. Investor recovery (quitters) is the")
    print("  average fraction of a quitter's deposit returned by rage quit; DAICO/RDA have no exit path, so no")
    print("  counterpart exists there.")
