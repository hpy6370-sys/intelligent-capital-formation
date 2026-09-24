# Capstone Project Proposal

## Intelligent Capital Formation: From Empirical Failure Modes to a Layered Accountability Framework

---

**Programme:** MSc Blockchain, Nanyang Technological University
**Collaboration:** Ethereum Foundation (Capstone Partnership)
**Supervisor:** Shyam
**Duration:** 6 months
**Version:** Draft v3.0 (May 2026)

---

## 1. Executive Summary

This project adopts a three-stage research paradigm — *empirical analysis, mechanism design, and validation* — to systematically study the evolution of on-chain capital formation mechanisms on Ethereum. We first establish a project-level dataset covering five major mechanisms (ICO, reverse Dutch auction, bonding curve, DAICO, and LBP) spanning 2017–2025. We then identify real-world failure modes from empirical data and test a core hypothesis: **existing mechanism failures stem primarily from accountability gaps rather than flaws in mechanism design itself**.

Informed by empirical findings, we propose the **Layered Accountability Framework (LAF)** — a defense-in-depth architecture that composes four independent, imperfect-but-complementary layers to address distinct failure modes. Unlike single-mechanism solutions (including our earlier MBC-VD candidate), LAF proceeds from the explicit acknowledgment that **every accountability scheme can be circumvented in isolation**; its contribution lies in demonstrating that layered composition raises the cost of circumvention beyond economically rational thresholds under specified conditions.

The primary simulation comparison focuses on **DAICO vs. Reverse Dutch Auction** (per supervisor feedback — both mechanisms address investor protection, making them more commensurable). Behavioral parameters including FOMO and herding effects are incorporated with sensitivity analysis.

Deliverables include: (1) a public on-chain capital formation dataset; (2) a research report combining empirical and design dimensions; (3) a runnable mechanism comparison simulator; (4) LAF reference contracts and formal specification; and (5) companion blog posts on ethresear.ch and Mirror for community discussion.

---

## 2. Background & Motivation

### 2.1 Current State of On-Chain Capital Formation

Since 2017, on-chain capital formation has undergone multiple rounds of mechanism innovation: from undifferentiated ICOs, to reverse Dutch auctions introducing price discovery, to bonding curves enabling continuous pricing, to DAICOs merging DAO governance with fundraising, and finally to LBPs achieving fair distribution through dynamic weight adjustment. Each innovation claims to address shortcomings of its predecessors, yet no single mechanism has emerged as a widely accepted standard.

### 2.2 Core Tensions in Existing Mechanisms

Through preliminary literature review, we identify three systematic tensions:

- **Investment efficiency vs. allocative efficiency** (Heaton & Green, 2022): Low initial prices incentivize early investment but exclude latecomers; high prices produce the opposite effect.
- **Mechanism trust vs. governance trust**: More automated mechanisms (bonding curves) reduce human manipulation but make it harder to hold teams accountable for off-chain failures; conversely, introducing governance (DAICO) increases accountability but expands the voting attack surface.
- **Primary market efficiency vs. secondary market stability**: LBPs optimize price discovery during initial distribution but do not address post-issuance long-term incentive alignment.

### 2.3 The Accountability Gap Hypothesis

Our core hypothesis:

> The failures of existing on-chain fundraising mechanisms are primarily attributable not to mechanism design flaws, but to **accountability gaps** — the fundraising-stage mechanism design is sophisticated, but the continuous accountability chain between investors and teams post-fundraising is either absent (ICO, bonding curve), dependent on flawed governance (DAICO), or masked by market liquidity (LBP).

This hypothesis is both empirically testable and points toward specific design directions. This project will first verify it, then design solutions accordingly.

### 2.4 From Single Mechanisms to Defense-in-Depth

A key insight emerging from both the literature and our preliminary empirical work is that **every individual accountability scheme can be circumvented**. Oracle-dependent systems (MBC-VD) can be gamed through milestone manipulation; governance-dependent systems (DAICO) are vulnerable to whale capture; pure market-based systems suffer from coordination failures. This observation motivates a shift from searching for a "perfect" mechanism to engineering a **layered composition** where circumventing any single layer does not compromise the system, analogous to defense-in-depth architectures in network security.

---

## 3. Research Questions

**RQ1 (Empirical):** What are the predominant failure modes among historical on-chain fundraising projects? Do these failures concentrate in the "accountability gap" category?

**RQ2 (Comparative):** How do the five major mechanisms (ICO, reverse Dutch auction, bonding curve, DAICO, LBP) perform on allocation efficiency, manipulation resistance, and long-term incentive alignment? Where do design promises diverge from actual outcomes?

**RQ3 (Intermediary):** Do intermediaries such as launchpads, market makers, and CEXs amplify or mitigate accountability gaps? What is the correlation between intermediary involvement and long-term project outcomes?

**RQ4 (Jurisdictional):** Is there a systematic correlation between mechanism choice and registration jurisdiction? How do different regulatory frameworks (Howey Test, MiCA, MAS-DPT, FINMA) affect mechanism viability?

**RQ5 (Design):** Can a layered composition of imperfect accountability mechanisms raise the cost of circumvention beyond economically rational thresholds? Under what conditions does the Layered Accountability Framework outperform individual mechanisms, and under what conditions does it fail?

---

## 4. Scope

### 4.1 Mechanisms Covered

This project covers five mechanisms, selecting 10–20 representative projects for each:

| Mechanism | Key Parameters | Representative Projects |
|-----------|---------------|------------------------|
| **ICO** | Fixed/floating price, hard/soft cap, time window | Filecoin, Tezos, EOS |
| **Reverse Dutch Auction** | Start/end price, decay function, time window | Gnosis (GNO), Algorand |
| **Bonding Curve** | Curve function (linear/exponential/sigmoid), reserve ratio | Aragon, Angel Protocol, early CommonStack |
| **DAICO** | Tap rate, voting threshold, self-destruct conditions | The Abyss, Rainbow Network |
| **LBP** | Start/end weights, time window, reserve token selection | Gitcoin (AKITA), Fjord Foundry projects, early Copper projects |

### 4.2 Intermediaries Covered

- **Launchpads:** Polkastarter, CoinList, DAO Maker, Fjord Foundry, Copper
- **Market Makers:** Wintermute, GSR, Jump (publicly observable participation only)
- **CEX Listings:** Binance, Coinbase, OKX — listing timing and subsequent price trajectories
- **Auditors:** As indirect accountability intermediaries (OpenZeppelin, Trail of Bits, ConsenSys Diligence)

### 4.3 Jurisdictions Covered

- **United States:** Howey Test, SEC v. Telegram (2020), SEC v. Kik (2020), SAFT framework
- **European Union:** MiCA (fully effective 2024), whitepaper requirements, CASP licensing
- **Singapore:** MAS Digital Token Offering Guidelines, Payment Services Act (particularly relevant as a local analysis for this capstone)
- **Switzerland:** FINMA three-tier classification (Payment / Utility / Asset)
- **Offshore:** BVI, Cayman, Marshall Islands (DAO LLC)

---

## 5. Methodology

The project is divided into four phases, each with independent deliverables and decoupled risk.

### Phase 1: Empirical Foundation (Month 1–2)

**Objective:** Establish a reliable, publicly available, citable project-level dataset.

**Work Items:**
1. **Project Selection** — Select 10–20 representative projects per mechanism based on market cap, historical significance, and data availability. Target sample: 60–80 projects.
2. **Data Schema Design** — Collect the following fields per project: mechanism parameters, fundraising metadata, team wallet identification, token distribution snapshots, on-chain activity metrics, intermediary participation, legal disclosures, and known failure indicators.
3. **Data Collection Infrastructure** — Dune Analytics queries, Etherscan/Arbiscan API scripts, The Graph subgraphs, and traditional sources (Crunchbase, Messari, CryptoRank).
4. **Data Quality Control** — Clear source prioritization and missing value handling for each field.

**Outputs:** Public PostgreSQL database schema and dump, data collection code repository, dataset description report.

### Phase 2: Mechanism Post-Mortem (Month 3)

**Objective:** Assess the gap between design promises and actual performance for each mechanism, and test the accountability gap hypothesis.

**Work Items:**
1. **Failure Mode Taxonomy** — Categorize project failures: exit scam, soft rug, governance failure, liquidity trap, slow death, regulatory shutdown.
2. **Mechanism × Failure Mode Matrix** — Frequency heatmap of each mechanism's failure patterns.
3. **Designer's Blind Spot Analysis** — Compare original design claims with empirical outcomes.
4. **Intermediary Effect Analysis** — Compare failure rates with/without launchpad involvement; CEX listing impact; market maker patterns.
5. **Jurisdictional Analysis** — Group by registration jurisdiction and compare mechanism choice and failure rates.
6. **Hypothesis Testing** — Statistical attribution of failures to the "accountability gap" category.

**Outputs:** Mid-term research report (30–40 pages), failure mode taxonomy, reproducible Jupyter Notebooks.

**Decision Point:** If the hypothesis is not supported, Phase 3 design objectives will be adjusted accordingly.

### Phase 3: LAF Design & Validation (Month 4–5)

**Objective:** Formalize, implement, and validate the Layered Accountability Framework.

**Work Items:**
1. **Formal Framework Specification** — Semi-formal description of each layer's state space, transitions, incentives, trust assumptions, and inter-layer interaction rules (Section 6.6).
2. **Agent-Based Simulation** — Implement five baseline mechanisms plus LAF. **Primary comparison: DAICO vs. Reverse Dutch Auction** (per supervisor feedback). Define five agent types (rational long-term, speculator, whale, adversarial attacker, late entrant) with **FOMO and herding behavioral parameters** and **sensitivity analysis** across parameter sweeps.
3. **Solidity Reference Contracts** — Core contracts implementing the four-layer composition; research prototype, not production code.
4. **Counterfactual Analysis** — Re-simulate failed projects from Phase 1 dataset under LAF.
5. **Framework Limitations Analysis** — Systematic documentation of failure modes, circumvention strategies, and boundary conditions (Section 6.8).

**Outputs:** Framework specification, simulation repository, Solidity prototype, counterfactual analysis report, limitations analysis.

### Phase 4: Consolidation & Output (Month 6)

**Objective:** Integrate all work into presentable outputs.

**Work Items:** Final research report (60–80 pages), ethresear.ch blog post, Mirror.xyz version, open-source release, defense preparation.

---

## 6. New Primitive: Layered Accountability Framework (LAF)

### 6.1 Design Philosophy

LAF proceeds from three premises:

1. **No single accountability mechanism is sufficient.** Every individual scheme has known circumvention strategies (empirically documented in Phase 2).
2. **Layered composition raises circumvention cost.** An adversary must simultaneously defeat multiple independent defenses, each operating on different attack surfaces.
3. **Graceful degradation over catastrophic failure.** If one layer is compromised, the remaining layers continue to provide partial protection, unlike single-mechanism designs that fail entirely.

The framework is analogous to defense-in-depth in network security: a firewall, IDS, logging, and access controls each have known bypasses, but their composition creates a security posture superior to any individual component.

### 6.2 Layer 1: Time-based Streaming

**Failure mode addressed:** Exit scam (team absconding with funds).

**Mechanism:** All raised capital enters a streaming contract (Sablier protocol). Funds flow to the team wallet at a constant rate over the project lifetime. The team cannot access future funds.

**Formal properties:**
- At time *t*, maximum team-accessible funds = initial_rate × *t* (linear) or per the configured decay curve
- If the team abandons the project at time *t*, remaining funds (total - streamed) remain in the contract
- Stream parameters are immutable post-deployment (no governance can accelerate release)

**Existing precedent:** Sablier (530,000+ streams created, deployed on 27 chains, $2.8B+ streamed).

**Known limitation:** Time-based streaming alone does not punish teams that remain nominally active while producing no value — it only prevents sudden capital extraction.

### 6.3 Layer 2: Individual Exit / Rage Quit

**Failure mode addressed:** Whale-dominated governance preventing minority investors from protecting their capital (the core DAICO failure mode).

**Mechanism:** Any token holder may, at any time, burn their tokens and receive a proportional share of the remaining unstreamed funds in the contract. This is an individual, permissionless action requiring no collective coordination or governance vote.

**Formal properties:**
- Exit value per token = (unstreamed_balance / total_supply) at time of burn
- Exit is atomic and unconditional — no vesting, no voting, no delay
- Token supply decreases with each exit; remaining holders' proportional claim is unaffected

**Existing precedent:** Moloch DAO rage quit mechanism (operational since 2019, $50M+ processed through rage quits across Moloch forks).

**Known limitation:** Mass rage quit (bank run) can drain the pool and terminate a viable project prematurely. This is a feature (market discipline) in cases of genuine team failure but a risk in cases of panic or coordinated manipulation. See Section 6.7 for interaction with other layers.

### 6.4 Layer 3: Quadratic Checkpoints

**Failure mode addressed:** Governance capture by large token holders (whale voting manipulation).

**Mechanism:** At configurable intervals (default: 90 days), the contract enters a checkpoint window. The default state is *continue* — if no action is taken, streaming resumes automatically (minimizing governance friction for well-performing projects). Any token holder may initiate an *audit vote* during the checkpoint window, triggering a quadratic voting round.

**Quadratic voting properties:**
- Voting power = sqrt(tokens_held), compressing whale influence (100 tokens = 10 votes; 10,000 tokens = 100 votes)
- Quorum threshold: minimum 20% of sqrt(total_supply) must participate for the vote to be binding
- Majority threshold: >50% of quadratic votes to pass an audit resolution
- Audit resolution effect: streaming is paused for a configurable response period (default: 30 days), during which the team must address concerns publicly on-chain

**Existing precedent:** Gitcoin Quadratic Voting/Funding system, DoraHacks QV implementations.

**Known limitation:** Quadratic voting is vulnerable to Sybil attacks (splitting tokens across wallets). Mitigation strategies include commit-reveal schemes and minimum stake requirements, but no perfect Sybil resistance exists without identity. This is documented as an open problem.

### 6.5 Layer 4: On-chain Signal Monitor

**Failure mode addressed:** Information asymmetry between team and investors.

**Mechanism:** The contract monitors publicly available on-chain metrics as early-warning signals. When metrics breach predefined thresholds, the monitor automatically triggers an early Layer 3 checkpoint (outside the regular schedule). The monitor does not make decisions — it is a smoke alarm, not a fire marshal.

**Monitored metrics and preliminary threshold ranges:**

| Metric | Data Source | Warning Threshold (preliminary) | Critical Threshold (preliminary) |
|--------|------------|--------------------------------|----------------------------------|
| Protocol TVL decline | The Graph subgraph | >40% decline over 30 days | >70% decline over 30 days |
| Active address count | On-chain events | >50% decline over 30 days | >80% decline over 30 days |
| Team wallet outflow anomaly | Direct monitoring | >3x average daily outflow | >10x average daily outflow |
| Code commit frequency | GitHub oracle (optional, off-chain) | >60 days without commit | >120 days without commit |
| Token concentration (HHI) | Token transfer events | HHI increase >0.15 over 30 days | HHI increase >0.30 over 30 days |

**Signal logic:**
- Single metric at *warning* threshold: no action (noise reduction)
- Two or more metrics at *warning* threshold simultaneously: trigger early checkpoint
- Any single metric at *critical* threshold: trigger early checkpoint
- All thresholds are configurable at deployment and subject to Phase 3 calibration via simulation

**Existing precedent:** Chainlink Data Feeds (price/TVL), The Graph (arbitrary on-chain indexing).

**Known limitation:** On-chain metrics can be gamed (wash trading for volume, Sybil addresses for activity). This is precisely why Layer 4 does not make decisions — it only triggers a checkpoint, and the actual decision is made through Layer 3's quadratic vote. The cost of gaming signals indefinitely while also maintaining the illusion of project health is the economic barrier.

### 6.6 Inter-Layer Interaction Rules

The four layers are not merely stacked but interact through defined protocols. These interaction rules are critical to LAF's coherence and represent a core contribution of the framework design.

**Rule 1: Streaming Pause/Resume Protocol**
- Layer 3 audit resolution pauses Layer 1 streaming
- Pause duration is bounded (maximum 60 days; configurable)
- Resume requires either: (a) team response + new quadratic vote approving resume, or (b) pause duration expiration without further audit vote
- During pause, Layer 2 (rage quit) remains active — investors may exit during the pause

**Rule 2: Rage Quit During Active Checkpoint**
- Layer 2 exits are always available, including during Layer 3 voting periods
- Exit value calculation uses unstreamed_balance at time of exit (not at start of checkpoint)
- If cumulative rage quit during a single checkpoint exceeds a threshold (default: 25% of remaining pool), streaming is automatically paused pending a new checkpoint vote
- This prevents scenarios where a checkpoint vote is rendered meaningless by mass exit during voting

**Rule 3: Signal-Triggered Checkpoint Scheduling**
- Layer 4 signals can trigger at most one early checkpoint per 30-day window (rate limiting to prevent governance fatigue)
- If a regular checkpoint is already in progress, Layer 4 signals are logged but do not trigger additional checkpoints
- Layer 4 trigger events are recorded on-chain for historical audit

**Rule 4: Pool Depletion Safeguard**
- If total remaining pool falls below a minimum viable threshold (default: 10% of initial raise), the contract enters a terminal state
- In terminal state: streaming stops, remaining funds are distributed proportionally to token holders, project is marked "wound down"
- This prevents zombie projects from lingering indefinitely with insufficient capital

**Rule 5: Layer Independence Principle**
- No single layer's failure compromises the contract's basic safety properties
- If Layer 4 oracle fails: regular checkpoint schedule (Layer 3) still operates
- If Layer 3 voting is captured: Layer 2 individual exit remains available
- If Layer 2 is not exercised: Layer 1 time-lock still bounds maximum extraction rate

### 6.7 Advantages Over Previous Candidates

| Dimension | MBC-VD (v2 candidate) | Layered Accountability Framework |
|-----------|----------------------|----------------------------------|
| Oracle dependency | Heavy (core dependency for milestone verification) | Minimal (Layer 4 uses oracles only for alerting, not decision-making) |
| Vote manipulation resistance | Not addressed (no voting layer) | Quadratic voting compresses whale power |
| Milestone rigidity | Requires pre-defining all milestones at deployment | No milestones required; time-triggered + signal-triggered |
| Single point of failure | One defense layer | Four independent layers with graceful degradation |
| Deployability | Requires building new oracle verification infrastructure | Each component has existing production implementations |
| Academic novelty | Combination of bonding curve + oracle | Architectural innovation: composition framework + inter-layer interaction rules |

### 6.8 Framework Limitations

Intellectual honesty requires documenting the conditions under which LAF can fail. This section strengthens rather than weakens the academic contribution.

**Limitation 1: Rage Quit Bank Run**
If investor sentiment turns negative (whether justified or through FUD campaigns), mass rage quit can drain the pool and kill a viable project. LAF's Rule 2 threshold (25% trigger) provides partial mitigation but cannot prevent determined, coordinated exits. This represents an inherent tension: the same mechanism that protects investors from bad teams can be weaponized against good teams.

*Boundary condition:* LAF is most vulnerable to bank runs in its early stages when the pool is small relative to streaming commitments, and when token holder concentration is high (few large holders can independently trigger the 25% threshold).

**Limitation 2: Layer Interaction Complexity**
The interaction rules (Section 6.6) introduce emergent behaviors that may not be fully predictable. For example: a Layer 4 signal triggers a checkpoint, during which rage quit exceeds 25%, triggering a streaming pause, which itself may trigger further panic exits. Cascading interactions can amplify rather than dampen volatility.

*Mitigation approach:* Phase 3 simulation will systematically explore cascade scenarios. Rate-limiting rules (one checkpoint per 30 days, bounded pause duration) are designed to prevent infinite feedback loops.

**Limitation 3: Signal Gaming**
Sophisticated adversaries with sufficient capital can game Layer 4 metrics (wash trading volume, creating Sybil addresses, timing team wallet movements to avoid detection). The cost of sustained gaming is the primary barrier, not impossibility.

*Honest assessment:* Layer 4 is the weakest layer in isolation. Its value is as an early-warning mechanism that is cheap to operate and occasionally useful, not as a reliable enforcement layer. The framework degrades gracefully without it (falling back to time-based checkpoints).

**Limitation 4: Sybil Vulnerability in Quadratic Voting**
Quadratic voting's power-compression property assumes one-person-one-wallet. In pseudonymous environments, any actor can split tokens across multiple wallets to linearize their voting power. Commit-reveal schemes and minimum stake requirements increase the cost of Sybil attacks but do not eliminate them.

*Pragmatic bound:* We do not claim to solve Sybil resistance (an open problem in the broader Ethereum ecosystem). We document the cost of Sybil attacks against Layer 3 and the conditions under which they become economically rational.

**Limitation 5: Governance Apathy**
If token holders do not participate in checkpoint votes (quorum failure), Layer 3 defaults to "continue." An inattentive token holder base provides no governance accountability regardless of mechanism design. This is a known limitation shared with all governance-based approaches.

**Limitation 6: Regulatory Uncertainty**
LAF's rage quit mechanism may be classified as a "redemption right" under certain securities frameworks, potentially triggering securities classification. Jurisdictional analysis (RQ4) will assess this risk across the five jurisdictions in scope.

**Summary: Defense-in-Depth, Not Perfection**

LAF does not claim to be an unbreakable accountability system. Its contribution is demonstrating that:
1. The cost of simultaneously circumventing all four layers exceeds the cost of circumventing any individual mechanism.
2. The framework degrades gracefully — partial failures reduce but do not eliminate protection.
3. The conditions under which LAF fails are documentable, quantifiable, and narrower than those of any single-mechanism approach.

This framing — *acknowledging imperfection while demonstrating improvement* — is itself a methodological contribution to the mechanism design literature, which too often presents proposals as solutions rather than tradeoffs.

---

## 7. Simulation & Stress Testing

### 7.1 Agent Types

| Agent Type | Utility Function | Typical Behavior |
|-----------|-----------------|------------------|
| Rational long-term | Maximize 12-month expected holding value | Fundamental buy-and-hold |
| Speculator | Maximize short-term PnL | Momentum trading, following large holders |
| Whale | Maximize holding share | Large entries, potential price manipulation |
| Adversarial attacker | Maximize mechanism damage | Governance attacks, front-running, coordinated selling |
| Late entrant | FOMO-driven, late entry | Following price increases |

**Behavioral Parameters (per supervisor feedback):**
- FOMO intensity: Controls agent sensitivity to price increases (0=rational, 1=extreme FOMO)
- Herding coefficient: Controls degree to which agents follow others' decisions
- Parameter sweep (5–10 values per parameter) to demonstrate how behavioral assumptions affect mechanism performance

### 7.2 Metrics

**Allocation Efficiency:** Gini coefficient, top 1%/10% wallet holdings, unique participants ratio, early vs. late entrant return differential.

**Manipulation Resistance:** Coordinated buy/sell price impact, Sybil attack cost/benefit in governance, front-running extractable profit ceiling, bribery attack cost threshold.

**Long-term Incentive Alignment:** Team effort correlation with fund release, conditional release ratio, investor retention (churn), price-vs-fundamentals deviation.

**Accountability Rate (novel metric):** Proportion of fund release conditional on verifiable events; principal-agent misalignment quantification.

**LAF-specific metrics:**
- Layer breach frequency: How often each layer's protection is triggered across scenarios
- Cascade event frequency: How often inter-layer interactions produce amplifying feedback
- Circumvention cost ratio: Cost to circumvent LAF vs. cost to circumvent individual mechanisms
- Graceful degradation score: Protection level remaining when 1, 2, or 3 layers are compromised

*Note: Defining our own operational metrics framework constitutes an independent research contribution, as no established benchmarks exist in this space (per supervisor feedback).*

### 7.3 Scenario Matrix

Each mechanism tested across 3×3×3 = 27 scenarios (N=100 Monte Carlo runs each):
- **Team integrity:** Honest / Semi-honest / Malicious
- **Market conditions:** Bull / Stable / Bear
- **Attacker presence:** None / Medium-resource / Well-resourced

**LAF-specific stress scenarios (additional):**
- Bank run scenario: 60% of holders attempt rage quit within 48 hours
- Sybil checkpoint: Adversary splits tokens across 100 wallets to capture quadratic vote
- Signal gaming: Adversary maintains artificial on-chain activity while extracting value off-chain
- Cascade test: Layer 4 trigger during active checkpoint with simultaneous rage quit pressure
- Governance apathy: <5% token holder participation in checkpoint votes across multiple periods

---

## 8. Expected Contributions

### Tool Contribution
- Public 2017–2025 on-chain capital formation dataset (60–80 projects)
- Open-source mechanism comparison simulation framework
- LAF reference contract suite (Solidity)

### Knowledge Contribution
- Systematic failure mode taxonomy for on-chain capital formation
- First empirical test of the "accountability gap" hypothesis
- Quantitative analysis of intermediary and jurisdictional effects
- Documentation of LAF failure modes and boundary conditions

### Design Contribution
- Layered Accountability Framework with formal specification and inter-layer interaction rules
- Counterfactual analysis connecting empirical data to design validation
- Circumvention cost analysis demonstrating defense-in-depth properties
- Honest limitations analysis as methodological template for mechanism design research

### Visibility Contribution
- ethresear.ch technical post, Mirror blog version, open-source repositories

---

## 9. Timeline

| Month | Phase | Key Work | Milestone Deliverable |
|-------|-------|----------|----------------------|
| 1 | Phase 1 | Literature review, project selection, schema design, initial 20 projects | Project list + schema doc |
| 2 | Phase 1 | Complete 60–80 project data collection, quality checks | Dataset v1.0 (public release) |
| 3 | Phase 2 | Failure mode taxonomy, mechanism analysis, hypothesis testing | Mid-term report + decision review |
| 4 | Phase 3 | LAF formal design, inter-layer rules, simulation framework, baselines | Framework spec + sim v1 |
| 5 | Phase 3 | Solidity prototype, stress testing, cascade analysis, counterfactual analysis | Contract prototype + limitations report |
| 6 | Phase 4 | Final report, blog versions, open-source release, defense prep | Final report + portfolio |

---

## 10. Risk Assessment

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Accountability gap hypothesis not supported | High | Medium | Phase 2 decision point; redirect LAF toward empirically-supported failure modes |
| Simulation complexity exceeds timeline | Medium | Medium | Layered implementation: Layers 1-2 first (simpler), Layers 3-4 as extensions |
| Layer interaction produces unexpected emergent behavior | Medium | High | Systematic cascade testing; rate-limiting rules; bounded parameter spaces |
| Insufficient on-chain data for signal calibration | Low | Medium | Use sensitivity analysis with threshold ranges rather than point estimates |
| Sybil resistance inadequacy undermines Layer 3 claims | Low | High | Frame as documented limitation, not claimed solution; quantify attack cost |
| Rage quit bank run invalidates LAF advantages in simulation | Medium | Medium | Document as boundary condition; identify parameter regimes where LAF outperforms |

The phased structure ensures independent deliverables at each stage, maintaining project value even if later phases require scope adjustment. Notably, even if LAF performs poorly in simulation under certain conditions, the *documentation of those conditions* constitutes a valid research contribution.

---

## 11. Relationship to Prior Work

### 11.1 Evolution from MBC-VD

The v2 proposal candidate (MBC-VD: Milestone Bonding Curve with Verifiable Delivery) was abandoned for the following reasons:
1. Heavy oracle dependency creates a single point of trust that contradicts the accountability gap hypothesis
2. Pre-defined milestones introduce rigidity that real-world projects cannot commit to at deployment time
3. No governance layer means no mechanism for handling ambiguous or disputed delivery claims
4. The "accountability via verification" model assumes verifiability — but most meaningful project milestones are not straightforwardly verifiable on-chain

LAF retains MBC-VD's insight (fund release should be conditional) while eliminating its structural weaknesses (oracle dependency, milestone rigidity, single-layer design).

### 11.2 Relationship to Existing Protocols

LAF is explicitly composed of existing, battle-tested components:
- **Sablier** (Layer 1): Production protocol, 530K+ streams
- **Moloch DAO** (Layer 2): Operational since 2019, proven rage quit mechanism
- **Gitcoin QV** (Layer 3): Multiple rounds of quadratic funding/voting
- **Chainlink / The Graph** (Layer 4): Industry-standard data infrastructure

The contribution is not in the individual components but in (a) the composition architecture, (b) the inter-layer interaction rules, and (c) the empirical and simulation-based validation that composition outperforms individual mechanisms. This constitutes what Henderson & Clark (1990) term "architectural innovation" — novel recombination of existing components into a system with emergent properties.

---

## 12. References

1. Buterin, V. (2018). *Explanation of DAICOs*. Ethereum Research.
2. Heaton, H., & Green, S. (2022). *Equitable Continuous Organizations with Self-Assessed Valuations*. arXiv:2203.10644.
3. Mechanism Institute. *Fundraising Library*.
4. Balancer LBP Whitepaper and Documentation.
5. De la Rouviere, S. *Original Bonding Curve Writings*.
6. MiCA Regulation (EU) 2023/1114.
7. MAS Guidelines on Digital Token Offerings (Singapore).
8. Henderson, R. M., & Clark, K. B. (1990). Architectural Innovation: The Reconfiguration of Existing Product Technologies and the Failure of Established Firms. *Administrative Science Quarterly*, 35(1), 9–30.
9. Sablier Protocol Documentation. https://docs.sablier.com
10. Moloch DAO. (2019). *Moloch: A simple Guild of Aligned Interest*. GitHub.
11. Buterin, V., Hitzig, Z., & Weyl, E. G. (2019). A Flexible Design for Funding Public Goods. *Management Science*, 65(11), 5171–5187. (Quadratic Voting/Funding)
12. The Graph Protocol Documentation.
13. Chainlink Data Feeds Documentation.

---

*This proposal is Draft v3.0 (May 2026). Key changes from v2: (1) MBC-VD replaced with Layered Accountability Framework (LAF); (2) Explicit inter-layer interaction rules defined; (3) Framework Limitations section added documenting failure modes and boundary conditions; (4) Layer 4 metrics specified with concrete threshold ranges; (5) RQ5 reformulated to address composition properties rather than single-mechanism optimality; (6) Defense-in-depth framing: "every scheme can be circumvented" acknowledged as premise, not hidden as weakness.*
