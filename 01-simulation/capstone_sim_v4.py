"""
Capstone: Intelligent Capital Formation - Simulation v4
DAICO vs Reverse Dutch Auction - CALIBRATED WITH REAL PROJECT DATA

v3 used plausible but hand-picked constants (n_agents=30, capital 1-30 in
arbitrary units, RDA start/end price 10 -> 1, DAICO tap_rate=0.01). v4 keeps
the exact same simulation mechanics (Agent, DAICOSim, RDASim, Gini, Monte
Carlo) but derives its default parameters from the 50-project dataset in
the initial 50-project dataset (merged into 03-dataset/dataset_82_projects.md) wherever the dataset actually supports a number,
and clearly flags the handful of places where no real figure exists and a
reasoned assumption was substituted instead.

New in v4.2 (vs v4.1, 2026-08-31, audit fixes):
- Fixed rda_timing_corr: now uses actual first_buy_round instead of
  arbitrary agent.id. Records purchase timing in RDASim.first_buy_round.
- Fixed daico_retention: now shows released/contributed (meaningful even
  when not destroyed). Previously was degenerate (always 1.0 or 0).
- Fixed roi_by_type comment: returns std dev, not variance.
- Explicit zero-std guard in Pearson correlation (no more `or 1` hack).

New in v4.1 (vs v4, 2026-08-31):
- Added Shyam's 3 evaluation dimensions as explicit metrics:
  D1 Allocation Efficiency: Gini coefficient, Top 10% concentration (existing)
  D2 Manipulation Resistance: whale dominance (new), RDA timing correlation (new),
     price volatility (existing)
  D3 Incentive Alignment: ROI dispersion across agent types (new),
     DAICO capital retention (new)
- Summary table reorganized by dimension
- Comparison table shows dimension grouping

New in v4 (vs v3):
- `RealDataCalibration` class: stores the real per-project figures used,
  computes derived stats (avg contribution per participant, RDA price
  decline ratio) at runtime, and exposes `small_project_config()` /
  `large_project_config()` calibrated parameter dicts.
- Agent capital distributions are rescaled by a `capital_scale` factor
  derived from real average contribution size (Solana, Casper, Mina, Flow
  RDA sales; The Abyss DAICO), instead of the arbitrary 1-30 units in v3.
- RDA price decline ratio calibrated from Algorand's actual auction
  ($10 -> $2.40 clearing over 4,000 rounds = 24% of start price), the only
  project in the dataset with both a start and a clearing price. Solana's
  $0.22 flat clearing price is used only as a cross-check that our price
  scale isn't absurd (the two tokens aren't priced on a comparable scale,
  so it can't calibrate a ratio).
- n_agents for the two profiles is scaled down from real participant counts
  (Solana: 445 bidders: Casper/Mina/Flow median: ~34,000 participants) by a
  fixed factor of 100, with a floor of 20 agents so Monte Carlo still has
  enough cross-sectional variance to be meaningful.
- DAICO tap_rate split small vs large is a *reasoned assumption*, not a
  data-derived number - the dataset records that The Abyss ran the world's
  first on-chain DAICO tap poll, but reports no tap-rate percentage for any
  project. This is called out explicitly rather than presented as if it
  were measured.
- Same scenario sweep as v3 (baseline / FOMO levels / herding), run once
  under v3's original defaults and once under each calibrated profile, with
  a comparison table at the end showing how the numbers move.
"""

import random
import math
from dataclasses import dataclass, field


# ---------------------------------------------------------------------------
# Core simulation primitives (same structure as v3; capital distribution is
# now parameterised via `capital_scale` instead of hardcoded ranges).
# ---------------------------------------------------------------------------

@dataclass
class Agent:
    id: int
    capital: float
    agent_type: str  # rational, speculator, whale, fomo_follower, late_entrant
    fomo_sensitivity: float = 0.0
    herding_sensitivity: float = 0.0
    tokens_held: float = 0.0
    total_spent: float = 0.0


def make_agents(n: int, fomo_level: float = 0.0, herding_level: float = 0.0,
                 capital_scale: float = 1.0) -> list[Agent]:
    """Same 5-type population as v3. `capital_scale` multiplies every
    agent's drawn capital, letting us re-express the same relative capital
    distribution (whale >> rational >> late_entrant) at a realistic dollar
    scale instead of v3's arbitrary 1-30 units."""
    agents = []
    types = [
        ("rational", 0.4, lambda: random.uniform(1, 5)),
        ("speculator", 0.2, lambda: random.uniform(2, 8)),
        ("whale", 0.1, lambda: random.uniform(10, 30)),
        ("fomo_follower", 0.2, lambda: random.uniform(0.5, 3)),
        ("late_entrant", 0.1, lambda: random.uniform(0.5, 2)),
    ]
    for i in range(n):
        r = random.random()
        cumulative = 0.0
        for atype, prob, capital_fn in types:
            cumulative += prob
            if r <= cumulative:
                fomo = fomo_level * (1.5 if atype == "fomo_follower" else 0.3 if atype == "rational" else 0.8)
                herd = herding_level * (1.5 if atype in ("fomo_follower", "speculator") else 0.5)
                agents.append(Agent(
                    id=i, capital=capital_fn() * capital_scale, agent_type=atype,
                    fomo_sensitivity=min(fomo, 1.0), herding_sensitivity=min(herd, 1.0),
                ))
                break
    return agents


def gini(values: list[float]) -> float:
    if not values or all(v == 0 for v in values):
        return 0.0
    sorted_v = sorted(values)
    n = len(sorted_v)
    total = sum(sorted_v)
    if total == 0:
        return 0.0
    weighted_sum = 0.0
    for i, v in enumerate(sorted_v):
        weighted_sum += (2 * (i + 1) - n - 1) * v
    return weighted_sum / (n * total)


@dataclass
class DAICOSim:
    pool: float = 0.0
    tap_rate: float = 0.01
    released: float = 0.0
    destroyed: bool = False
    rounds: int = 0
    contributions: dict = field(default_factory=dict)

    def contribute(self, agent: Agent, amount: float, participation_rate: float = 0.0):
        """FOMO increases contribution fraction; herding scales with how many
        have already contributed (participation_rate 0-1)."""
        fomo_boost = agent.fomo_sensitivity * 0.3   # up to +30% of capital
        herd_boost = agent.herding_sensitivity * participation_rate * 0.2
        adjusted = amount * (1.0 + fomo_boost + herd_boost)
        actual = min(adjusted, agent.capital)
        if actual <= 0:
            return
        self.pool += actual
        agent.capital -= actual
        agent.total_spent += actual
        agent.tokens_held += actual  # 1:1 for simplicity
        self.contributions[agent.id] = self.contributions.get(agent.id, 0) + actual

    def tick(self, agents: list[Agent]):
        if self.destroyed:
            return
        self.rounds += 1
        release = self.pool * self.tap_rate
        self.released += release
        self.pool -= release

        # --- Eligible voter pools ---
        eligible_raise = [a for a in agents if a.agent_type in ("speculator", "fomo_follower")]
        eligible_destroy = [a for a in agents if a.agent_type in ("rational", "whale")]

        # Raise votes: speculators + herding fomo_followers
        vote_raise = sum(1 for a in agents
                         if a.agent_type == "speculator"
                         and random.random() < 0.15 + a.fomo_sensitivity * 0.15)
        herd_raise = sum(1 for a in agents
                         if a.agent_type == "fomo_follower"
                         and a.herding_sensitivity > 0
                         and random.random() < a.herding_sensitivity * (vote_raise / max(len(eligible_raise), 1)))
        vote_raise += herd_raise

        # Destroy votes: rational/whale, reduced by FOMO
        vote_destroy = sum(1 for a in agents
                           if a.agent_type in ("rational", "whale")
                           and random.random() < max(0.005, 0.03 - a.fomo_sensitivity * 0.02))

        # Dynamic thresholds: % of eligible voters, not total agents
        if vote_raise >= max(2, len(eligible_raise) * 0.3):
            self.tap_rate = min(self.tap_rate * 1.3, 0.15)
        if vote_destroy >= max(2, len(eligible_destroy) * 0.2):
            self.destroyed = True


@dataclass
class RDASim:
    start_price: float = 10.0
    end_price: float = 1.0
    duration: int = 50
    pool: float = 0.0
    tokens_sold: float = 0.0
    rounds: int = 0
    closed: bool = False
    price_history: list = field(default_factory=list)
    purchases: dict = field(default_factory=dict)
    first_buy_round: dict = field(default_factory=dict)

    def current_price(self) -> float:
        if self.closed or self.rounds >= self.duration:
            return self.end_price
        progress = self.rounds / self.duration
        return self.start_price - (self.start_price - self.end_price) * progress

    def try_buy(self, agent: Agent, participation_rate: float):
        if self.closed:
            return
        price = self.current_price()
        will_buy = False

        if agent.agent_type == "rational":
            will_buy = price <= self.start_price * 0.4
        elif agent.agent_type == "speculator":
            will_buy = random.random() < 0.3 + agent.fomo_sensitivity * 0.3
        elif agent.agent_type == "whale":
            will_buy = price <= self.start_price * 0.6 or random.random() < agent.fomo_sensitivity
        elif agent.agent_type == "fomo_follower":
            herd_boost = agent.herding_sensitivity * participation_rate
            will_buy = random.random() < agent.fomo_sensitivity + herd_boost
        elif agent.agent_type == "late_entrant":
            will_buy = self.rounds > self.duration * 0.6 and random.random() < 0.5

        if will_buy and agent.capital > 0:
            spend = min(agent.capital * random.uniform(0.1, 0.5), agent.capital)
            tokens = spend / price
            self.pool += spend
            self.tokens_sold += tokens
            agent.capital -= spend
            agent.total_spent += spend
            agent.tokens_held += tokens
            self.purchases[agent.id] = self.purchases.get(agent.id, 0) + tokens
            if agent.id not in self.first_buy_round:
                self.first_buy_round[agent.id] = self.rounds

    def tick(self):
        self.rounds += 1
        self.price_history.append(self.current_price())
        if self.rounds >= self.duration:
            self.closed = True


def price_volatility(prices: list[float]) -> float:
    if len(prices) < 2:
        return 0.0
    returns = [(prices[i] - prices[i - 1]) / prices[i - 1] for i in range(1, len(prices)) if prices[i - 1] != 0]
    if not returns:
        return 0.0
    mean_r = sum(returns) / len(returns)
    var = sum((r - mean_r) ** 2 for r in returns) / len(returns)
    return math.sqrt(var)


def run_single(n_agents=30, rounds=50, fomo=0.0, herding=0.0, seed=None,
               capital_scale=1.0, tap_rate=0.01,
               rda_start_price=10.0, rda_end_price=1.0):
    if seed is not None:
        random.seed(seed)

    agents_daico = make_agents(n_agents, fomo, herding, capital_scale)
    agents_rda = make_agents(n_agents, fomo, herding, capital_scale)

    daico = DAICOSim(tap_rate=tap_rate)
    rda = RDASim(start_price=rda_start_price, end_price=rda_end_price, duration=rounds)

    # Shuffle contribution order so herding participation_rate builds up
    random.shuffle(agents_daico)
    for i, a in enumerate(agents_daico):
        participation_rate = i / max(n_agents, 1)
        amount = a.capital * random.uniform(0.3, 0.8)
        daico.contribute(a, amount, participation_rate)

    for r in range(rounds):
        daico.tick(agents_daico)
        rda.tick()

        participation_rate = len(rda.purchases) / n_agents if n_agents > 0 else 0
        for a in agents_rda:
            rda.try_buy(a, participation_rate)

    tokens_daico = [a.tokens_held for a in agents_daico]
    tokens_rda = [a.tokens_held for a in agents_rda]

    daico_eff = daico.released / (daico.released + daico.pool) if (daico.released + daico.pool) > 0 and not daico.destroyed else 0
    rda_participants = sum(1 for a in agents_rda if a.tokens_held > 0)

    top10_daico = sorted(tokens_daico, reverse=True)
    top10_rda = sorted(tokens_rda, reverse=True)
    total_d = sum(tokens_daico) or 1
    total_r = sum(tokens_rda) or 1
    top10pct_d = sum(top10_daico[:max(1, n_agents // 10)]) / total_d
    top10pct_r = sum(top10_rda[:max(1, n_agents // 10)]) / total_r

    # --- Shyam Metric 2: Manipulation Resistance ---
    # Whale dominance: fraction of total tokens held by whale-type agents
    whale_tokens_d = sum(a.tokens_held for a in agents_daico if a.agent_type == "whale")
    whale_tokens_r = sum(a.tokens_held for a in agents_rda if a.agent_type == "whale")
    whale_dom_d = whale_tokens_d / total_d
    whale_dom_r = whale_tokens_r / total_r

    # Early-buyer advantage (RDA only): Pearson correlation between first
    # purchase round and tokens acquired. In a manipulation-resistant auction,
    # early buyers pay higher prices so should get fewer tokens per dollar.
    # Positive correlation (later round -> more tokens) = expected baseline.
    # Near-zero or negative = potential timing manipulation advantage.
    rda_buy_timing = []
    rda_buy_tokens = []
    for a in agents_rda:
        if a.tokens_held > 0 and a.id in rda.first_buy_round:
            rda_buy_timing.append(rda.first_buy_round[a.id])
            rda_buy_tokens.append(a.tokens_held)
    if len(rda_buy_timing) >= 3:
        n_p = len(rda_buy_timing)
        mean_t = sum(rda_buy_timing) / n_p
        mean_k = sum(rda_buy_tokens) / n_p
        cov = sum((rda_buy_timing[i] - mean_t) * (rda_buy_tokens[i] - mean_k) for i in range(n_p)) / n_p
        std_t = math.sqrt(sum((t - mean_t) ** 2 for t in rda_buy_timing) / n_p)
        std_k = math.sqrt(sum((k - mean_k) ** 2 for k in rda_buy_tokens) / n_p)
        if std_t == 0 or std_k == 0:
            rda_timing_corr = 0.0
        else:
            rda_timing_corr = cov / (std_t * std_k)
    else:
        rda_timing_corr = 0.0

    # --- Shyam Metric 3: Incentive Alignment ---
    # Capital retention ratio: fraction of raised capital the project actually
    # received (released) vs total contributed. On destroy, remaining pool is
    # refunded but already-released funds stay with the project.
    total_contributed = sum(a.total_spent for a in agents_daico)
    if total_contributed > 0:
        daico_retention = daico.released / total_contributed
    else:
        daico_retention = 0.0

    # ROI dispersion across agent types: lower = better alignment.
    # If all agent types get similar value per dollar spent, incentives are
    # aligned. High dispersion means some types extract at others' expense.
    # Returns standard deviation of type-mean ROIs.
    def roi_by_type(agents):
        by_type = {}
        for a in agents:
            if a.total_spent > 0:
                roi = a.tokens_held / a.total_spent
                by_type.setdefault(a.agent_type, []).append(roi)
        type_means = [sum(vs) / len(vs) for vs in by_type.values() if vs]
        if len(type_means) < 2:
            return 0.0
        overall_mean = sum(type_means) / len(type_means)
        return math.sqrt(sum((m - overall_mean) ** 2 for m in type_means) / len(type_means))

    daico_roi_var = roi_by_type(agents_daico)
    rda_roi_var = roi_by_type(agents_rda)

    return {
        "daico_pool": daico.pool,
        "daico_released": daico.released,
        "daico_efficiency": daico_eff,
        "daico_destroyed": daico.destroyed,
        # Dimension 1: Allocation Efficiency
        "daico_gini": gini(tokens_daico),
        "daico_top10pct": top10pct_d,
        # Dimension 2: Manipulation Resistance
        "daico_whale_dom": whale_dom_d,
        # Dimension 3: Incentive Alignment
        "daico_retention": daico_retention,
        "daico_roi_var": daico_roi_var,
        "rda_pool": rda.pool,
        "rda_tokens_sold": rda.tokens_sold,
        "rda_participants": rda_participants,
        # Dimension 1: Allocation Efficiency
        "rda_gini": gini(tokens_rda),
        "rda_top10pct": top10pct_r,
        # Dimension 2: Manipulation Resistance
        "rda_volatility": price_volatility(rda.price_history),
        "rda_whale_dom": whale_dom_r,
        "rda_timing_corr": rda_timing_corr,
        # Dimension 3: Incentive Alignment
        "rda_roi_var": rda_roi_var,
    }


def run_monte_carlo(n_runs=100, **kwargs):
    results = []
    for i in range(n_runs):
        results.append(run_single(seed=i, **kwargs))

    avg = {}
    for key in results[0]:
        if isinstance(results[0][key], bool):
            avg[key] = sum(1 for r in results if r[key]) / n_runs
        else:
            avg[key] = sum(r[key] for r in results) / n_runs
    return avg


def print_results(label, res):
    print(f"\n{'='*60}")
    print(f"  {label}")
    print(f"{'='*60}")
    print(f"  DAICO:")
    print(f"    Pool remaining:    {res['daico_pool']:.2f}")
    print(f"    Released:          {res['daico_released']:.2f}")
    print(f"    Release efficiency:{res['daico_efficiency']:.1%}")
    d_val = res['daico_destroyed']
    print(f"    Destroyed by vote: {d_val:.0%}" if isinstance(d_val, float) else f"    Destroyed: {d_val}")
    print(f"    [D1] Gini coefficient:  {res['daico_gini']:.3f}")
    print(f"    [D1] Top 10% share:     {res['daico_top10pct']:.1%}")
    print(f"    [D2] Whale dominance:   {res['daico_whale_dom']:.1%}")
    print(f"    [D3] Capital retention: {res['daico_retention']:.1%}")
    print(f"    [D3] ROI variance:      {res['daico_roi_var']:.4f}")
    print(f"  RDA:")
    print(f"    Total raised:      {res['rda_pool']:.2f}")
    print(f"    Tokens sold:       {res['rda_tokens_sold']:.2f}")
    print(f"    Participants:      {res['rda_participants']:.1f}")
    print(f"    [D1] Gini coefficient:  {res['rda_gini']:.3f}")
    print(f"    [D1] Top 10% share:     {res['rda_top10pct']:.1%}")
    print(f"    [D2] Price volatility:  {res['rda_volatility']:.4f}")
    print(f"    [D2] Whale dominance:   {res['rda_whale_dom']:.1%}")
    print(f"    [D2] Timing corr:       {res['rda_timing_corr']:.3f}")
    print(f"    [D3] ROI variance:      {res['rda_roi_var']:.4f}")
    print(f"  [D1]=Allocation Efficiency  [D2]=Manipulation Resistance  [D3]=Incentive Alignment")


# ---------------------------------------------------------------------------
# RealDataCalibration - extracts parameters from the initial 50-project dataset (merged into 03-dataset/dataset_82_projects.md)
# ---------------------------------------------------------------------------

class RealDataCalibration:
    """Holds the real project figures from the initial 50-project dataset (merged into 03-dataset/dataset_82_projects.md) that
    are used to calibrate the simulation, and derives simulation parameter
    profiles from them.

    Every number below is transcribed directly from the dataset. Anything
    the dataset does not report (e.g. an explicit DAICO tap-rate percentage)
    is NOT invented here as a fake "real" figure - it's handled separately
    as a documented assumption in small_project_config/large_project_config.
    """

    # DAICO projects with a usable (raised, contributors) pair.
    # Only The Abyss reports both numbers; the rest are raised-only.
    DAICO_PROJECTS = [
        {"name": "The Abyss", "raised": 15_362_418, "contributors": 4_897},
        {"name": "Aavegotchi", "raised": 30_000_000, "contributors": None},
        {"name": "ICOVO", "raised": 803_390, "contributors": None},              # ICO Drops verified 2026-08-31
        {"name": "Presto", "raised": 1_000_000, "contributors": None},        # approx, marked '?'
        {"name": "Coin Governance System", "raised": 500_000, "contributors": None},  # approx, marked '?'
        {"name": "Modex", "raised": 5_000_000, "contributors": None},         # approx, marked '?'
        {"name": "DxDAO (Fairmint)", "raised": 1_500_000, "contributors": None},
    ]

    # RDA projects with a usable (raised, participants) pair, plus the two
    # projects with real price data (Algorand: start + clearing; Solana:
    # clearing only, no start price reported).
    RDA_PROJECTS = [
        {"name": "Polkadot", "raised": 145_000_000, "participants": None},
        {"name": "Algorand", "raised": 60_000_000, "participants": None,
         "start_price": 10.0, "clearing_price": 2.40, "duration_rounds": 4_000},
        {"name": "Casper Network", "raised": 33_000_000, "participants": 34_000},
        {"name": "Mina Protocol", "raised": 18_750_000, "participants": 40_500, "clearing_price": 0.25},
        {"name": "Flow (Dapper Labs)", "raised": 18_000_000, "participants": 12_500},
        {"name": "Gnosis", "raised": 12_500_000, "participants": None,
         "duration_minutes": 10},  # sold out in ~10 min: extreme-FOMO reference point
        {"name": "Solana", "raised": 1_760_000, "participants": 445, "clearing_price": 0.22},
    ]

    V3_BASELINE_AVG_CAPITAL = 3.0  # midpoint of v3's "rational" range (1-5), the implicit unit v3 was built around
    SCALE_DOWN = 100               # real participant counts / 100 = simulated n_agents (Monte Carlo tractability)
    MIN_AGENTS = 20                # floor so small-project runs still have cross-sectional variance

    # -- derived stats, computed from the tables above, not hardcoded --

    @classmethod
    def daico_avg_contribution(cls) -> float:
        """Raised / contributors for the one DAICO with both numbers (The Abyss)."""
        abyss = cls.DAICO_PROJECTS[0]
        return abyss["raised"] / abyss["contributors"]

    @classmethod
    def rda_contributions(cls) -> dict:
        """{project_name: raised/participants} for every RDA project that reports participants."""
        return {p["name"]: p["raised"] / p["participants"]
                for p in cls.RDA_PROJECTS if p["participants"]}

    @classmethod
    def rda_price_decline_ratio(cls) -> float:
        """clearing_price / start_price. Algorand is the only project in the
        dataset with both figures ($10 -> $2.40 over 4,000 rounds), so it is
        the sole source for this ratio."""
        algo = next(p for p in cls.RDA_PROJECTS if p["name"] == "Algorand")
        return algo["clearing_price"] / algo["start_price"]

    @classmethod
    def rda_large_participants_median(cls) -> float:
        """Median participant count of the three big, well-documented RDAs
        (Casper, Mina, Flow) - all in the 12,500-40,500 range."""
        counts = sorted(p["participants"] for p in cls.RDA_PROJECTS
                         if p["name"] in ("Casper Network", "Mina Protocol", "Flow (Dapper Labs)"))
        mid = len(counts) // 2
        return counts[mid] if len(counts) % 2 else (counts[mid - 1] + counts[mid]) / 2

    @classmethod
    def rda_large_contribution_median(cls) -> float:
        contribs = sorted(v for k, v in cls.rda_contributions().items()
                           if k in ("Casper Network", "Mina Protocol", "Flow (Dapper Labs)"))
        mid = len(contribs) // 2
        return contribs[mid] if len(contribs) % 2 else (contribs[mid - 1] + contribs[mid]) / 2

    @classmethod
    def small_project_capital_scale(cls) -> float:
        """Small/niche projects (Solana: 445 bidders; The Abyss DAICO: 4,897
        contributors) had HIGHER average per-participant contribution than
        the large public sales - fewer backers, each putting in more."""
        solana = cls.rda_contributions()["Solana"]
        avg = (solana + cls.daico_avg_contribution()) / 2
        return avg / cls.V3_BASELINE_AVG_CAPITAL

    @classmethod
    def large_project_capital_scale(cls) -> float:
        """Large public sales (Casper/Mina/Flow, 12,500-40,500 participants)
        had LOWER average per-participant contribution - broader, more
        retail-driven participation."""
        return cls.rda_large_contribution_median() / cls.V3_BASELINE_AVG_CAPITAL

    @classmethod
    def small_project_n_agents(cls) -> int:
        return max(cls.MIN_AGENTS, round(cls.RDA_PROJECTS[-1]["participants"] / cls.SCALE_DOWN))  # Solana: 445

    @classmethod
    def large_project_n_agents(cls) -> int:
        return max(cls.MIN_AGENTS, round(cls.rda_large_participants_median() / cls.SCALE_DOWN))

    @classmethod
    def small_project_config(cls) -> dict:
        """Solana/Gnosis-scale: small, fast, contribution-heavy raises.
        rounds=20 stands in for Gnosis's ~10-minute sellout (extreme FOMO,
        very little time for price discovery). tap_rate=0.02 is a REASONED
        ASSUMPTION (see class docstring), not a dataset figure: a small,
        tightly-knit contributor base (matching Abyss's 4,897) can coordinate
        a faster tap-increase vote than a large dispersed one."""
        return dict(
            n_agents=cls.small_project_n_agents(),
            rounds=20,
            capital_scale=cls.small_project_capital_scale(),
            tap_rate=0.02,
            rda_start_price=10.0,
            rda_end_price=10.0 * cls.rda_price_decline_ratio(),
        )

    @classmethod
    def large_project_config(cls) -> dict:
        """Casper/Mina/Flow/Algorand-scale: large, slower, broad-participation
        raises. rounds=80 stands in for Algorand's 4,000-round gradual
        auction (scaled down, same idea: slow decline, not a FOMO sprint).
        tap_rate=0.008 is a REASONED ASSUMPTION, not a dataset figure: a
        large, dispersed contributor base is slower to organize a
        tap-increase vote than a small one."""
        return dict(
            n_agents=cls.large_project_n_agents(),
            rounds=80,
            capital_scale=cls.large_project_capital_scale(),
            tap_rate=0.008,
            rda_start_price=10.0,
            rda_end_price=10.0 * cls.rda_price_decline_ratio(),
        )

    @classmethod
    def summary_lines(cls) -> list[str]:
        rda_c = cls.rda_contributions()
        lines = [
            "Real-data parameters extracted from the initial 50-project dataset (merged into 03-dataset/dataset_82_projects.md):",
            "",
            "  DAICO avg contribution (The Abyss: $15,362,418 / 4,897 contributors)"
            f" = ${cls.daico_avg_contribution():,.2f}",
            "  RDA avg contribution by project (raised / participants):",
        ]
        for name, val in rda_c.items():
            lines.append(f"    {name:<20} ${val:,.2f}")
        lines += [
            f"  RDA price decline ratio (Algorand $10 -> $2.40 clearing, 4,000 rounds)"
            f" = {cls.rda_price_decline_ratio():.2%} of start price",
            "    (Solana's $0.22 flat clearing price is not on a comparable token scale,"
            " so it is used only as a sanity check, not folded into the ratio.)",
            "",
            f"  small_project profile: n_agents={cls.small_project_n_agents()}"
            f" (Solana's 445 bidders / {cls.SCALE_DOWN}, floored at {cls.MIN_AGENTS}),"
            f" capital_scale={cls.small_project_capital_scale():.1f}x v3 baseline",
            f"  large_project profile: n_agents={cls.large_project_n_agents()}"
            f" (median of Casper/Mina/Flow participants / {cls.SCALE_DOWN}),"
            f" capital_scale={cls.large_project_capital_scale():.1f}x v3 baseline",
            "",
            "  NOTE: DAICO tap_rate (0.02 small / 0.008 large) is a reasoned assumption,"
            " not a dataset figure - no project reports an explicit tap-rate %.",
        ]
        return lines


SCENARIOS = [
    ("Baseline (no behavioral effects)", {"fomo": 0.0, "herding": 0.0}),
    ("FOMO = 0.3", {"fomo": 0.3, "herding": 0.0}),
    ("FOMO = 0.5", {"fomo": 0.5, "herding": 0.0}),
    ("FOMO = 0.7", {"fomo": 0.7, "herding": 0.0}),
    ("FOMO=0.5 + Herding=0.3", {"fomo": 0.5, "herding": 0.3}),
    ("FOMO=0.5 + Herding=0.6", {"fomo": 0.5, "herding": 0.6}),
    ("High FOMO=0.7 + Herding=0.5", {"fomo": 0.7, "herding": 0.5}),
]


def run_sweep(N, extra_params, header):
    print(f"\n{'#'*60}")
    print(f"# {header}")
    print(f"{'#'*60}")
    all_results = []
    for label, params in SCENARIOS:
        res = run_monte_carlo(n_runs=N, **{**extra_params, **params})
        print_results(label, res)
        all_results.append((label, res))

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
    return all_results


if __name__ == "__main__":
    import sys
    sys.stdout.reconfigure(encoding='utf-8')

    N = 50
    print("Capstone ICF Simulation v4 -- calibrated with real project data")
    print(f"DAICO vs Reverse Dutch Auction | Monte Carlo N={N}")
    print()
    for line in RealDataCalibration.summary_lines():
        print(line)

    v3_defaults = {"n_agents": 30, "rounds": 50, "capital_scale": 1.0, "tap_rate": 0.01,
                   "rda_start_price": 10.0, "rda_end_price": 1.0}

    results_v3 = run_sweep(N, v3_defaults, "v3 defaults (uncalibrated, for reference)")
    results_small = run_sweep(N, RealDataCalibration.small_project_config(),
                               "small_project profile (Solana/Gnosis/Abyss-scale, calibrated)")
    results_large = run_sweep(N, RealDataCalibration.large_project_config(),
                               "large_project profile (Casper/Mina/Flow/Algorand-scale, calibrated)")

    # --- Comparison: how do the calibrated profiles differ from v3 defaults? ---
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
