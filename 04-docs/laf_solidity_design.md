# LAF (Layered Accountability Framework) — Solidity Architecture Design

**Project:** SC6131 Capstone — Ethereum Foundation ("Intelligent Capital Formation")
**Phase:** Phase 2 (2026/08/01–10/04) — Solidity prototype
**Sources:** Journal 1 §5.4 / Appendix D (preliminary architecture direction) + Proposal v3 §6 (formal spec, inter-layer interaction rules, Layer 4 metrics)
**Status:** Design document, pre-implementation. Target stack: Solidity 0.8.x + Foundry.

> **Note on sources:** Journal 1's Appendix D sketches the four layers at a high level. Proposal v3 §6.6–6.8 formalizes exact interaction rules, thresholds, and defaults. This document follows Proposal v3 as the authoritative spec wherever the two differ, and calls out explicitly where a parameter isn't pinned down in either source (flagged `[UNSPECIFIED — assumed default, revisit]`).

---

## 0. Design Philosophy

The LAF is **defense-in-depth**, not a single mechanism (Proposal v3 §6.1). Each layer independently mitigates one failure mode, and — critically — **no layer's failure compromises the others** (Rule 5, Layer Independence Principle):

| Layer | Failure mode it targets | If this layer is fully compromised, what still holds |
|---|---|---|
| 1. Streaming Release | Exit scam (team grabs everything day 1) | N/A — this is the innermost layer; its own bound (`rate × elapsed`) is what layers 2–4 all key off of |
| 2. Rage Quit | Whale-dominated / captured governance leaving minority investors stuck | Available **even if Layer 3 is captured and Layer 4 is disabled** — Layer 1's time-lock still bounds the team's maximum extraction rate regardless |
| 3. Quadratic Governance | Governance capture by large holders | If Layer 4's oracle fails, the **regular** 90-day checkpoint schedule still runs unaffected — Layer 3 doesn't depend on Layer 4 to function |
| 4. Signal Monitor | Information asymmetry (team knows the project is dying before holders do) | Purely additive — it only ever triggers a Layer 3 checkpoint early; if disabled, the framework degrades to time-scheduled checkpoints only (Limitation 3, §6.8) |

**Key architectural principle carried through the whole design:** Layer 4 **never** touches the vault directly. It is "a smoke alarm, not a fire marshal" (Proposal v3 §6.5) — its only privileged action is requesting an early governance checkpoint on Layer 3, rate-limited to prevent it from being a griefing vector. All fund-affecting decisions (pause, resume, rate change) flow through the same `GOVERNOR_ROLE` path, whether the checkpoint was scheduled or signal-triggered. This is a correction from the very first draft of this document, which had `SignalMonitor` calling `pause()` directly on the vault — that violates the "monitor doesn't decide" principle from the proposal and has been removed.

Implementation stays minimal: OpenZeppelin primitives where they exist (`AccessControl`, `ReentrancyGuard`, `SafeERC20`), no upgradability, no proxy patterns. This is a research artifact for stress-testing the framework (3×3×3 scenario matrix + LAF-specific stress scenarios per Proposal v3 §7.3), not a production system.

---

## 1. Contract Architecture Diagram

```
                         ┌───────────────────────────┐
                         │      LAFShareToken         │
                         │  (ERC20, mint on deposit,  │
                         │   burn on rage quit)       │
                         └─────────────┬───────────────┘
                                        │ balanceOf() / totalSupply()
                                        │ (pro-rata math + sqrt vote weighting)
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
              ▼                         ▼                         ▼
   ┌────────────────────┐   ┌────────────────────────┐  ┌────────────────────────┐
   │   RageQuitModule    │   │   QuadraticGovernor      │  │    SignalMonitor         │
   │ ------------------- │   │ ----------------------   │  │ ----------------------   │
   │ rageQuit(amount)     │   │ openCheckpointWindow()   │  │ reportMetric(id, value)  │
   │ quitableAmount(addr) │   │ initiateAuditVote()      │  │ evaluate()               │
   │                      │   │ vote(id, option)         │  │  -> calls Governor only  │
   │                      │   │ resolveCheckpoint(id)     │  │                          │
   │                      │   │ triggerEarlyCheckpoint()◄─┼──┤ (SIGNAL_ROLE on Governor,│
   │                      │   │   [called by Monitor]     │  │  rate-limited 1/30 days) │
   └──────────┬───────────┘   └───────────┬────────────┘  └───────────────────────────┘
              │ RAGEQUIT_ROLE             │ GOVERNOR_ROLE
              │ withdrawForRageQuit()     │ setStreamRate() / pauseForAudit()
              │ (Vault applies Rule 2 &   │ resumeStreaming() / checkPoolDepletion()
              │  Rule 4 checks inline)    │
              ▼                           ▼
   ┌──────────────────────────────────────────────────────────────────────────┐
   │                              LAFVault (core)                             │
   │ -------------------------------------------------------------------------│
   │ deposit() / closeFunding(rate)                                           │
   │ claim()                       <- TEAM_ROLE, streaming withdrawal         │
   │ streamedAmount() / unreleasedBalance()   <- read by RageQuit & Governor  │
   │ setStreamRate(rate)           <- GOVERNOR_ROLE only                      │
   │ pauseForAudit(responsePeriod) <- GOVERNOR_ROLE only (Rule 1)             │
   │ resumeStreaming()             <- GOVERNOR_ROLE only, or auto-timeout     │
   │ withdrawForRageQuit(to,amt)   <- RAGEQUIT_ROLE only (Rule 2 inline)      │
   │ checkPoolDepletion()          <- permissionless (Rule 4)                 │
   │ isTerminal() / isPaused()                                                │
   │                                                                          │
   │ Holds: treasury balance, AccessControl roles, StreamConfig,              │
   │        VaultAccounting, CheckpointWindowState (for Rule 2 tracking)      │
   └──────────────────────────────────────────────────────────────────────────┘
                                        ▲
                                        │ deposits (funding phase only)
                                        │
                                   Investors
```

**Note vs. the original sketch:** `SignalMonitor` now points at `QuadraticGovernor`, not `LAFVault`. `RageQuitModule` still points at `LAFVault` directly, but the vault itself now internally enforces Rule 2 (25% cumulative rage-quit auto-pause) and Rule 4 (10% pool depletion → terminal state) on every `withdrawForRageQuit` call, rather than those rules living in a separate contract — they're accounting invariants of the vault's own state, not independent decisions, so they belong where the money is.

---

## 2. Contract List & Responsibilities

| Contract | Responsibility | Roles it holds |
|---|---|---|
| **`LAFVault.sol`** | Core treasury. Deposits, share minting, linear streaming release (Layer 1), pause/resume state machine bounded by Rule 1, inline enforcement of Rule 2 (rage-quit-triggered auto-pause) and Rule 4 (pool depletion → terminal state). Only contract that ever moves funds. | — |
| **`LAFShareToken.sol`** | ERC20 investor-claim token. Minted 1:1 on deposit, burned on rage quit. No transfer restrictions (secondary market allowed by design — matches real investor behavior and is itself a stress-test variable). Vote-weight source for `QuadraticGovernor`. | — |
| **`RageQuitModule.sol`** | Layer 2. Atomic, unconditional, no-delay individual exit (Proposal v3 §6.3). Burns caller's shares for `unstreamed_balance / total_supply` at time of burn. Always available — including mid-checkpoint, mid-pause (Rule 1, Rule 2). | `RAGEQUIT_ROLE` on `LAFVault` |
| **`QuadraticGovernor.sol`** | Layer 3. Runs the 90-day regular checkpoint cadence with default-continue semantics; lets any holder `initiateAuditVote()` during an open window; tallies sqrt-weighted votes; resolves to CONTINUE / INCREASE_RATE / DECREASE_RATE / PAUSE_FOR_AUDIT / HALT; applies the result to the vault. Also exposes `triggerEarlyCheckpoint()`, callable only by an address holding `SIGNAL_ROLE` (i.e. `SignalMonitor`), rate-limited to once per 30-day window (Rule 3). | `GOVERNOR_ROLE` on `LAFVault` |
| **`SignalMonitor.sol`** | Layer 4. Tracks five on-chain/oracle-fed metrics against warning/critical thresholds (Proposal v3 §6.5 table). Pure alerting: `evaluate()` counts warnings/criticals and, if the combinator condition is met (≥2 warnings OR ≥1 critical), calls `Governor.triggerEarlyCheckpoint()`. **Cannot pause anything itself.** Metric values are pushed by a `REPORTER_ROLE` address (represents off-chain oracle infra — Graph/Chainlink/GitHub bot — explicitly out of scope to build for the prototype; documented as a known simplification). | `SIGNAL_ROLE` on `QuadraticGovernor` |
| **`ILAFVault.sol`** / **`IRageQuit.sol`** / **`IQuadraticGovernor.sol`** / **`ISignalMonitor.sol`** | Interfaces for each layer (Section 4). | — |
| **`LAFErrors.sol`** (optional) | Shared custom errors for gas-efficient reverts. | — |

**Deliberately out of scope for the prototype** (mirrors Proposal v3 §6.8's honest-limitations framing — document these as prototype boundaries in Journal 2, not hidden gaps):

- No upgradability / proxy — redeploy for iteration between stress-test scenarios.
- Single-asset treasury (native ETH or one ERC20) per vault instance.
- The funding phase itself (ICO/RDA/bonding curve/LBP — the mechanisms from Journal 1's comparative study) is a **pre-condition**, not part of LAF. `deposit()` is a plain capital-in/share-out function so LAF stays composable with any of the five upstream mechanisms.
- `SignalMonitor`'s TVL / active-address / commit-frequency / HHI metrics require off-chain data feeds by nature (The Graph, GitHub, Chainlink per Proposal v3 §6.5). The prototype implements the **on-chain evaluation logic** (thresholds, combinator, rate-limited trigger) and a `REPORTER_ROLE`-gated push interface for these values, but does **not** implement the oracle/indexer infrastructure itself. Team-wallet outflow anomaly is the one metric partially computable on-chain (from `LAFShareToken`/treasury transfer events) and is designed to actually be self-contained where the others are stubs — documented as Limitation 3 territory (signal gaming / oracle dependency).

---

## 3. Key Data Structures

```solidity
// ---- LAFVault.sol ----

enum PauseReason { NONE, AUDIT_RESOLUTION, RAGE_QUIT_THRESHOLD }

struct StreamConfig {
    uint256 ratePerSecond;    // wei/sec currently streaming to the team
    uint256 startTime;        // when streaming began (funding close)
    uint256 lastClaimTime;    // last time team called claim()
    bool    paused;
    PauseReason pausedReason; // AUDIT_RESOLUTION (Rule 1) or RAGE_QUIT_THRESHOLD (Rule 2)
    uint256 pausedAt;         // 0 if not paused
    uint256 pauseResponsePeriod; // set at pause time; default 30 days, capped at 60 (Rule 1)
    uint256 totalPausedTime;  // cumulative paused seconds, excluded from streamed-amount math
    bool    terminal;         // Rule 4: true once pool depletion triggers wind-down
}

struct VaultAccounting {
    uint256 totalDeposited;
    uint256 totalClaimedByTeam;
    uint256 totalExitedViaRageQuit;
    uint256 totalShares;          // mirrors LAFShareToken.totalSupply(), cached for gas
    bool    fundingClosed;
}

// Rule 2 bookkeeping — reset every time a new checkpoint window opens
struct CheckpointWindowState {
    uint256 windowId;                    // mirrors QuadraticGovernor's checkpoint id
    uint256 unreleasedBalanceAtOpen;      // "remaining pool" snapshot Rule 2 measures against
    uint256 cumulativeRageQuitInWindow;   // reset to 0 on each openCheckpointWindow() call
}

// Core invariants, enforced by construction and checked in Foundry invariant tests:
//   address(this).balance == totalDeposited - totalClaimedByTeam - totalExitedViaRageQuit
//   cumulativeRageQuitInWindow <= unreleasedBalanceAtOpen * RAGE_QUIT_AUTO_PAUSE_BPS / 10000
//     (once exceeded, vault auto-pauses with PauseReason.RAGE_QUIT_THRESHOLD before the
//      triggering withdrawal completes — see §5.3)


// ---- QuadraticGovernor.sol ----

enum CheckpointAction { CONTINUE, INCREASE_RATE, DECREASE_RATE, PAUSE_FOR_AUDIT, HALT }
//   PAUSE_FOR_AUDIT = the "audit resolution" from Proposal v3 §6.4: bounded pause,
//   team must respond, distinct from HALT (a deliberate permanent-until-next-vote stop).

enum CheckpointTrigger { SCHEDULED, SIGNAL }

struct Checkpoint {
    uint256 id;
    uint256 windowStart;
    uint256 windowEnd;             // = windowStart + CHECKPOINT_WINDOW_DURATION
    CheckpointTrigger trigger;
    uint256 snapshotBlock;         // block used for sqrt(balanceOfAt()) vote weight
    bool    auditInitiated;        // false until someone calls initiateAuditVote()
    bool    resolved;
    CheckpointAction resolvedAction;
    mapping(CheckpointAction => uint256) tallies;  // sqrt-weighted vote sums
    mapping(address => bool) hasVoted;
    uint256 proposedRateDelta;     // for INCREASE_RATE / DECREASE_RATE only
}

// governance apathy (Limitation 5): if auditInitiated == false at windowEnd,
// OR quorum not met, resolvedAction defaults to CONTINUE — no revert, no special case.


// ---- SignalMonitor.sol ----

enum MetricId { TVL_DECLINE, ACTIVE_ADDR_DECLINE, TEAM_OUTFLOW, COMMIT_INACTIVITY, HHI_INCREASE }

struct MetricThresholds {
    uint256 warningBps;   // basis points, semantics vary per metric (see §6, table)
    uint256 criticalBps;
    uint256 windowSeconds; // measurement window (30 days for most metrics)
}

struct MetricState {
    uint256 lastValueBps;     // last reported value (decline %, multiplier, HHI delta — all in bps)
    uint256 lastReportedAt;
    bool    warningActive;
    bool    criticalActive;
}
```

---

## 4. Interface Definitions (Solidity)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILAFVault
/// @notice Core interface for the LAF treasury / streaming vault (Layer 1 + accounting
/// invariants that Layer 2 and Layer 3 both depend on).
interface ILAFVault {
    event Deposited(address indexed investor, uint256 amount, uint256 sharesMinted);
    event FundingClosed(uint256 totalRaised, uint256 streamStart, uint256 ratePerSecond);
    event Claimed(address indexed team, uint256 amount);
    event StreamRateUpdated(uint256 oldRate, uint256 newRate);
    event PausedForAudit(uint256 responsePeriod, uint8 reason); // reason = PauseReason
    event Resumed(bool wasAutoTimeout);
    event RageQuitPayout(address indexed to, uint256 amount);
    event RageQuitThresholdBreached(uint256 checkpointWindowId, uint256 cumulativeAmount);
    event TerminalStateEntered(uint256 finalUnreleasedBalance);

    function deposit() external payable;
    function closeFunding(uint256 ratePerSecond) external;
    function claim() external;
    function claimableAmount() external view returns (uint256);

    /// @notice Funds still in the vault: totalDeposited - totalClaimedByTeam - totalExitedViaRageQuit.
    /// This is the number Layer 2 and Layer 3 both key off of.
    function unreleasedBalance() external view returns (uint256);

    function isPaused() external view returns (bool);
    function isTerminal() external view returns (bool);

    // --- GOVERNOR_ROLE only (called by QuadraticGovernor after a resolved checkpoint) ---

    function setStreamRate(uint256 newRatePerSecond) external;

    /// @notice Rule 1: pause bounded by [1, MAX_PAUSE_DURATION]. Reverts if responsePeriod
    /// exceeds the configured cap.
    function pauseForAudit(uint256 responsePeriod) external;

    /// @notice Rule 1(a): explicit governance-approved resume after team response + new vote.
    function resumeStreaming() external;

    /// @notice Rule 1(b): permissionless — anyone may call this once pausedAt + pauseResponsePeriod
    /// has elapsed with no new pause imposed. Auto-resumes without requiring a vote.
    function resumeIfTimedOut() external returns (bool resumed);

    /// @notice Governor calls this exactly once per checkpoint window it opens, so the vault
    /// can snapshot unreleasedBalance() for Rule 2's 25% threshold and reset the window counter.
    function markCheckpointWindowOpen(uint256 checkpointId) external;

    // --- RAGEQUIT_ROLE only (called by RageQuitModule) ---

    /// @notice Pays `amount` to `to` from unreleasedBalance(). Internally: (a) checks Rule 4
    /// (would this withdrawal push the vault below the depletion threshold — informational,
    /// does not block the withdrawal, Rule 4 is evaluated separately via checkPoolDepletion()),
    /// (b) adds `amount` to the current checkpoint window's cumulativeRageQuitInWindow and, if
    /// that now exceeds RAGE_QUIT_AUTO_PAUSE_BPS of unreleasedBalanceAtOpen, auto-pauses the
    /// vault with PauseReason.RAGE_QUIT_THRESHOLD *before* returning (Rule 2).
    function withdrawForRageQuit(address to, uint256 amount) external;

    // --- permissionless ---

    /// @notice Rule 4: anyone may call. If unreleasedBalance() < POOL_DEPLETION_BPS of
    /// totalDeposited, sets terminal = true and permanently zeroes the stream rate.
    /// After this, claim() always reverts; rageQuit() remains the only exit path, which
    /// naturally implements "distribute remaining proportionally" — no separate
    /// distribution logic needed (see §5.5).
    function checkPoolDepletion() external returns (bool triggered);
}

/// @title IRageQuit
/// @notice Layer 2 — individual exit rights (Moloch-style rage quit, Proposal v3 §6.3).
interface IRageQuit {
    event RageQuit(address indexed holder, uint256 sharesBurned, uint256 amountReceived);

    /// @notice Burn `shareAmount` of caller's LAFShareToken; receive
    /// unreleasedBalance() * shareAmount / totalShares at call time. Atomic,
    /// unconditional, no delay, no vote — available even mid-pause, mid-checkpoint.
    function rageQuit(uint256 shareAmount) external;

    function quitableAmount(uint256 shareAmount) external view returns (uint256);
}

/// @title IQuadraticGovernor
/// @notice Layer 3 — periodic quadratic-weighted governance checkpoints (Proposal v3 §6.4).
interface IQuadraticGovernor {
    enum CheckpointAction { CONTINUE, INCREASE_RATE, DECREASE_RATE, PAUSE_FOR_AUDIT, HALT }
    enum CheckpointTrigger { SCHEDULED, SIGNAL }

    event CheckpointWindowOpened(uint256 indexed id, uint256 windowStart, uint256 windowEnd, CheckpointTrigger trigger);
    event AuditVoteInitiated(uint256 indexed id, address indexed initiator);
    event VoteCast(uint256 indexed id, address indexed voter, CheckpointAction option, uint256 weight);
    event CheckpointResolved(uint256 indexed id, CheckpointAction action, bool quorumMet);

    /// @notice Permissionless. Opens a new checkpoint window if CHECKPOINT_INTERVAL has
    /// elapsed since the last window closed. Default state within the window is CONTINUE —
    /// if nobody calls initiateAuditVote(), resolveCheckpoint() closes it as a no-op.
    function openCheckpointWindow() external returns (uint256 checkpointId);

    /// @notice SIGNAL_ROLE only (SignalMonitor). Opens an early checkpoint window outside
    /// the regular schedule. Reverts if called more than once per 30-day window (Rule 3),
    /// or is a no-op (logged only) if a checkpoint window is already open (Rule 3).
    function triggerEarlyCheckpoint() external returns (uint256 checkpointId);

    /// @notice Any holder may start the actual vote within an open, not-yet-initiated window.
    function initiateAuditVote(uint256 checkpointId, CheckpointAction proposedAction, uint256 proposedRateDelta) external;

    /// @notice sqrt(balanceAt(snapshotBlock))-weighted vote. One vote per address per checkpoint.
    /// Only callable after initiateAuditVote() for that checkpoint.
    function vote(uint256 checkpointId, CheckpointAction option) external;

    /// @notice After windowEnd: tally, check quorum (20% of sqrt(total_supply)) and majority
    /// (>50%), and apply the result to LAFVault. If audit was never initiated, or quorum
    /// wasn't met, resolves to CONTINUE (Limitation 5 — governance apathy defaults safe).
    function resolveCheckpoint(uint256 checkpointId) external;

    function votingPowerOf(address account, uint256 snapshotBlock) external view returns (uint256);
}

/// @title ISignalMonitor
/// @notice Layer 4 — on-chain/oracle-fed early warning system (Proposal v3 §6.5).
/// Deliberately has NO capability to pause or otherwise touch LAFVault. Its only
/// privileged call anywhere in the system is Governor.triggerEarlyCheckpoint().
interface ISignalMonitor {
    event MetricReported(uint8 indexed metricId, uint256 valueBps, uint256 timestamp);
    event ThresholdCrossed(uint8 indexed metricId, bool warning, bool critical);
    event CheckpointTriggerAttempted(bool success, string reason);

    /// @notice REPORTER_ROLE only — represents the off-chain oracle/indexer push
    /// (Graph subgraph for TVL/active addresses, GitHub bot for commit frequency,
    /// direct on-chain read for team wallet outflow / HHI). Out of scope to build
    /// the oracle infra itself for the prototype; this is the trust boundary.
    function reportMetric(uint8 metricId, uint256 valueBps) external;

    /// @notice Permissionless. Recomputes warning/critical flags from the latest
    /// reported values and, if the combinator condition is met (>=2 metrics at
    /// warning, OR >=1 metric at critical), calls Governor.triggerEarlyCheckpoint().
    /// Never calls anything on LAFVault directly.
    function evaluate() external returns (bool triggered);

    function warningCount() external view returns (uint256);
    function criticalCount() external view returns (uint256);
    function isMetricWarning(uint8 metricId) external view returns (bool);
    function isMetricCritical(uint8 metricId) external view returns (bool);
}
```

---

## 5. Configurable Constants

Every parameter from Proposal v3 §6.4–6.6 is a constructor argument or `AccessControl`-gated setter (default values shown), not a hardcoded magic number — required so the 3×3×3 scenario matrix and LAF-specific stress tests (Proposal v3 §7.3) can sweep them directly from Foundry:

```solidity
// ---- QuadraticGovernor constructor params ----
uint256 public checkpointInterval;        // default: 90 days
uint256 public checkpointWindowDuration;  // [UNSPECIFIED — assumed default 14 days;
                                           //  neither Journal 1 nor Proposal v3 pins down
                                           //  how long a window stays open for initiateAuditVote()
                                           //  + voting; flagged for mentor/sim calibration]
uint256 public quorumBps;                 // default: 2000  (20% of sqrt(total_supply))
uint256 public majorityBps;               // default: 5000  (>50%)
uint256 public defaultPauseResponsePeriod;// default: 30 days
uint256 public maxPauseDuration;          // default: 60 days  (Rule 1 hard cap)
uint256 public signalTriggerRateLimit;    // default: 30 days  (Rule 3)

// ---- LAFVault constructor params ----
uint256 public rageQuitAutoPauseBps;      // default: 2500  (25% of remaining pool, Rule 2)
uint256 public poolDepletionBps;          // default: 1000  (10% of initial raise, Rule 4)

// ---- SignalMonitor constructor params (per-metric, Proposal v3 §6.5 table) ----
// metricId 0: TVL_DECLINE            warningBps=4000 (40%)  criticalBps=7000 (70%)  window=30d
// metricId 1: ACTIVE_ADDR_DECLINE    warningBps=5000 (50%)  criticalBps=8000 (80%)  window=30d
// metricId 2: TEAM_OUTFLOW           warningBps=30000 (3x)  criticalBps=100000(10x) window=1d avg
// metricId 3: COMMIT_INACTIVITY      warningDays=60         criticalDays=120        (not bps — day count)
// metricId 4: HHI_INCREASE           warningBps=1500 (0.15) criticalBps=3000 (0.30) window=30d
uint256 public warningCombinatorThreshold; // default: 2   (>=2 warnings triggers checkpoint)
uint256 public criticalCombinatorThreshold;// default: 1   (>=1 critical triggers checkpoint)
```

All of §6.4/§6.6/§6.5's "default" and "preliminary threshold range" language in Proposal v3 is intentional — the proposal explicitly defers final calibration to Phase 3 simulation (§6.5: "subject to Phase 3 calibration via simulation"). Keeping every one of these as a constructor argument (rather than a `constant`) is what makes that calibration possible without redeploying new contract code for each sweep — only new deployment parameters.

---

## 6. Layer Interaction Flows

### 6.1 Happy path (no intervention)

```
Investor.deposit() → LAFVault mints LAFShareToken
   ...funding window closes...
Admin.closeFunding(rate) → StreamConfig.startTime = now, ratePerSecond = rate
   ...time passes...
Team.claim() → transfers min(streamed - totalClaimedByTeam, unreleasedBalance()) to team
Anyone.openCheckpointWindow() every 90 days → Vault.markCheckpointWindowOpen(id)
   ...nobody calls initiateAuditVote() within the window...
Anyone.resolveCheckpoint(id) → resolves CONTINUE (no-op) — default-continue semantics,
   this is the expected outcome for a healthy project and costs nothing but one tx
```

### 6.2 Rage quit flow (Layer 2, always available)

```
Holder → RageQuitModule.rageQuit(shareAmount)
   1. payout = LAFVault.unreleasedBalance() * shareAmount / LAFShareToken.totalSupply()
   2. LAFShareToken.burnFrom(holder, shareAmount)
   3. LAFVault.withdrawForRageQuit(holder, payout)   [RAGEQUIT_ROLE]
      -> Vault updates totalExitedViaRageQuit += payout, transfers payout
      -> Vault adds payout to CheckpointWindowState.cumulativeRageQuitInWindow
      -> if cumulativeRageQuitInWindow > unreleasedBalanceAtOpen * rageQuitAutoPauseBps / 10000:
             Vault auto-pauses (PauseReason.RAGE_QUIT_THRESHOLD), emits RageQuitThresholdBreached
             (Rule 2 — this fires INSIDE the same transaction as the triggering rage quit;
              the triggering holder still gets their payout, the *next* claim() by team is
              what's blocked)
```
`unreleasedBalance()` is read live, not cached — every prior claim() and every prior rage quit changes what's left for the next quitter. This is the core reentrancy-relevant interaction: order of operations (burn shares → then transfer funds, `ReentrancyGuard` on the vault's transfer function) is what's tested in §7.2.

### 6.3 Governance checkpoint changes the stream (Layer 3 acting on Layer 1)

```
Anyone → QuadraticGovernor.openCheckpointWindow()  [gated: interval elapsed]
   -> Governor calls LAFVault.markCheckpointWindowOpen(id)  [snapshots unreleasedBalanceAtOpen]
Holder → initiateAuditVote(id, PAUSE_FOR_AUDIT, 0)   [anyone can start it; window was default-continue until now]
Holders → vote(id, option) with weight = sqrt(balanceAt(snapshotBlock))
   ...window closes...
Anyone → resolveCheckpoint(id)
   1. tally sqrt-weighted votes
   2. if quorum (20% of sqrt(total_supply)) not met -> resolve CONTINUE (Limitation 5)
   3. if PAUSE_FOR_AUDIT wins with >50% majority:
        Governor calls LAFVault.pauseForAudit(defaultPauseResponsePeriod)   [GOVERNOR_ROLE]
   4. if HALT wins: Governor calls LAFVault.setStreamRate(0) — a deliberate governance
      decision, distinct from an audit pause; resuming requires a future checkpoint voting
      to increase the rate again, not the Rule 1(a)/(b) resume path
   5. if INCREASE_RATE / DECREASE_RATE wins: Governor calls LAFVault.setStreamRate(newRate)
```

### 6.4 Signal monitor triggers an early checkpoint (Layer 4 → Layer 3 only, never → Layer 1)

```
Reporter (oracle/keeper, off-chain infra out of scope) → SignalMonitor.reportMetric(TVL_DECLINE, 4500)
   ... more metrics reported over time ...
Anyone → SignalMonitor.evaluate()
   1. recompute warning/critical flags per metric against thresholds (§5 table)
   2. if warningCount >= 2 OR criticalCount >= 1:
        SignalMonitor calls QuadraticGovernor.triggerEarlyCheckpoint()   [SIGNAL_ROLE]
          -> Governor checks: has an early checkpoint already fired in the last 30 days?
               if yes -> no-op, just log (Rule 3 rate limit)
          -> Governor checks: is a checkpoint window already open (scheduled or signal)?
               if yes -> no-op, just log (Rule 3, "already in progress")
          -> otherwise: opens a new checkpoint window, trigger = SIGNAL
   3. SignalMonitor NEVER calls LAFVault. It has no role there and no interface to it.
      Whatever happens next (audit initiated, voted, resolved to PAUSE_FOR_AUDIT or not)
      goes through the exact same path as §6.3 — Layer 4 only ever gets you to the front
      door of Layer 3, it never lets itself in.
```

### 6.5 Pool depletion → terminal state (Rule 4)

```
Anyone (any interested party — could be a holder before deciding whether to rage quit,
        or a keeper) → LAFVault.checkPoolDepletion()
   if unreleasedBalance() < totalDeposited * poolDepletionBps / 10000:
        terminal = true
        ratePerSecond = 0 permanently
        emit TerminalStateEntered(unreleasedBalance())
   claim() now reverts unconditionally (team can never withdraw again)
   rageQuit() remains fully functional — and because payout is always
        unreleasedBalance() * shareAmount / totalShares, this *is* the proportional
        wind-down distribution Rule 4 calls for. No separate distribution loop over
        holders is needed — reusing Layer 2's existing math for the terminal case
        keeps the implementation and its test surface small.
```

### 6.6 Combined worst case (why layering matters — traces Rule 1 → Rule 2 → Rule 3 together)

```
T0: Team is malicious from day 1. Stream caps their max take at rate * elapsed regardless (Layer 1).
T10: Team starts routing tokens toward an exchange wallet — SignalMonitor's TEAM_OUTFLOW metric
     crosses warning at T10, HHI_INCREASE crosses warning at T12 (2 warnings -> combinator fires)
T12: SignalMonitor.evaluate() -> Governor.triggerEarlyCheckpoint() (Rule 3, first use of the
     30-day allowance this window)
T13: A sharp-eyed holder doesn't wait for the vote — RageQuitModule.rageQuit() immediately for
     their pro-rata share (Layer 2, always available, no coordination needed)
T13-T18: More holders follow; cumulative rage quit crosses 25% of unreleasedBalanceAtOpen
     -> Vault auto-pauses with PauseReason.RAGE_QUIT_THRESHOLD (Rule 2) — this happens
     independently of and possibly before the signal-triggered checkpoint even resolves
T20: The signal-triggered checkpoint resolves PAUSE_FOR_AUDIT with quorum (remaining holders
     are alarmed) -> Governor calls pauseForAudit() again / extends via governance decision
T20-T50: Team never responds. At T50 (within the 60-day max), pauseResponsePeriod expires with
     no new vote -> resumeIfTimedOut() is callable, OR unreleasedBalance() has by now dropped
     under 10% of totalDeposited from cumulative rage quits -> checkPoolDepletion() flips
     terminal = true first, whichever condition is hit first
Net result: team's maximum extraction is bounded by rate * ~12 days of undetected streaming,
capped further by however much was left once Rule 2's threshold fired — nowhere near
"all funds day 1," and the exact bound is now a concrete, testable number instead of a
qualitative claim (this is what §7's counterfactual analysis needs to be able to compute
per historically-failed project).
```

This is also a direct illustration of Proposal v3's **Limitation 2 (Layer Interaction Complexity)**: a signal trigger, a rage-quit threshold breach, and an audit-pause can all cascade within the same short window. Rate-limiting (Rule 3) and bounded pause duration (Rule 1) are the two mechanisms explicitly designed to stop this from becoming an infinite feedback loop — worth testing directly (see §7.6 below).

---

## 7. Suggested Test Scenarios (Foundry)

Organize as `test/unit/`, `test/integration/`, `test/invariant/`, `test/stress/` (the last one maps directly onto Proposal v3 §7.3's LAF-specific stress scenarios).

### 7.1 Unit — LAFVault
- `test_deposit_mintsSharesProportionally()`
- `test_claim_revertsBeforeFundingClosed()`
- `test_claim_returnsExactlyStreamedAmount(uint256 elapsed)` — fuzz
- `test_claim_cappedAtUnreleasedBalance()`
- `test_claim_revertsAfterTerminal()`
- `test_setStreamRate_onlyGovernorRole()`
- `test_pauseForAudit_revertsIfResponsePeriodExceedsMax()` — enforces the 60-day cap (Rule 1)
- `test_pauseForAudit_excludesPausedTimeFromStreamCalculation()`
- `test_resumeIfTimedOut_onlyAfterResponsePeriodElapsed()`
- `test_resumeStreaming_onlyGovernorRole()`
- `test_withdrawForRageQuit_onlyRageQuitRole()`
- `test_checkPoolDepletion_triggersTerminalBelowThreshold()`
- `test_checkPoolDepletion_noOpAboveThreshold()`
- `invariant_vaultBalanceEqualsAccountingIdentity()` — `balance == totalDeposited - totalClaimedByTeam - totalExitedViaRageQuit`

### 7.2 Unit — RageQuitModule
- `test_rageQuit_paysCorrectProportionalShare()`
- `test_rageQuit_burnsSharesBeforeTransferringFunds()` — checks-effects-interactions
- `test_rageQuit_reentrancy()` — malicious receiver reenters `rageQuit()`/`withdrawForRageQuit()`; must revert
- `test_rageQuit_sequentialQuittersEachGetCorrectShareOfShrinkingPool()`
- `test_rageQuit_availableDuringPause()` — Layer 2 must work when Layer 1 is halted by Layer 3
- `test_rageQuit_availableDuringTerminal()` — this is the actual Rule 4 distribution mechanism
- `test_rageQuit_crossing25PercentThreshold_autoPausesVault()` — Rule 2, the key cross-layer test
- `test_rageQuit_belowThreshold_doesNotPause()`

### 7.3 Unit — QuadraticGovernor
- `test_votingWeight_isSqrtOfBalance()` — 100x larger holder gets ~10x weight
- `test_openCheckpointWindow_revertsBeforeIntervalElapsed()`
- `test_windowCloses_asContinue_ifAuditNeverInitiated()` — default-continue semantics
- `test_initiateAuditVote_onlyOncePerWindow()`
- `test_vote_oneVotePerAddressPerCheckpoint()`
- `test_resolveCheckpoint_defaultsToContinue_ifQuorumNotMet()` — Limitation 5
- `test_resolveCheckpoint_appliesEachAction()` — CONTINUE / INCREASE_RATE / DECREASE_RATE / PAUSE_FOR_AUDIT / HALT
- `test_resolveCheckpoint_cannotExecuteTwice()`
- `test_triggerEarlyCheckpoint_onlySignalRole()`
- `test_triggerEarlyCheckpoint_rateLimitedTo1Per30Days()` — Rule 3
- `test_triggerEarlyCheckpoint_noOpIfWindowAlreadyOpen()` — Rule 3
- `test_whaleCannotSingleHandedlyReachQuorum()` — one address at 90% of shares; verify sqrt + quorum design prevents unilateral control (core empirical claim for Layer 3, must be demonstrated not asserted)

### 7.4 Unit — SignalMonitor
- `test_reportMetric_onlyReporterRole()`
- `test_evaluate_triggersOnTwoWarnings()`
- `test_evaluate_triggersOnOneCritical()`
- `test_evaluate_noOpOnSingleWarning()`
- `test_evaluate_neverCallsVaultDirectly()` — structural test: assert no call trace touches `LAFVault` from `SignalMonitor`, only `QuadraticGovernor.triggerEarlyCheckpoint()`
- `test_perMetricThresholds_matchProposalTable()` — parametrized over all 5 metrics' warning/critical values

### 7.5 Integration — cross-layer
- `test_integration_signalTriggersCheckpoint_thenAuditPassesAndPauses()` — full §6.4 flow
- `test_integration_rageQuitDuringActiveVote_doesNotBreakTally()` — snapshot voting must be immune to post-snapshot balance changes
- `test_integration_governorHaltsStream_rageQuitStillAvailable()`
- `test_integration_massRageQuitCrossesThresholdDuringOpenCheckpoint()` — Rule 2 firing concurrently with an active Layer 3 vote
- `test_integration_poolDepletionDuringActivePause()` — Rule 4 can fire while Rule 1's pause is also active; verify no conflicting state
- `test_integration_pauseTimeoutThenAutoResume()` — full Rule 1(b) path
- `test_integration_worstCaseMaliciousTeam()` — reproduce §6.6 end-to-end, assert total team extraction is bounded by the expected closed-form formula (feeds directly into the counterfactual analysis deliverable, Proposal v3 §7.1 Phase 3 work item 4)

### 7.6 Stress scenarios (directly from Proposal v3 §7.3)
- `test_stress_bankRun()` — 60% of holders attempt rage quit within 48 hours; verify Rule 2 auto-pause fires correctly and doesn't itself cause reverts/DoS for legitimate quitters mid-batch
- `test_stress_sybilCheckpoint()` — adversary splits tokens across 100 wallets to try to capture a quadratic vote; measure actual voting power gained vs. cost (Limitation 4 — document, don't claim solved)
- `test_stress_signalGaming()` — adversary keeps reported metrics artificially "healthy" (e.g. reports low HHI, low outflow) while draining value through an unmonitored channel; verify the system degrades gracefully to the 90-day scheduled-checkpoint baseline rather than failing open
- `test_stress_cascade()` — Layer 4 trigger fires during an already-open checkpoint with simultaneous rage-quit pressure; verify Rule 3's "no-op if window already open" and Rule 1's bounded pause duration actually prevent the infinite-loop case described in Limitation 2
- `test_stress_governanceApathy()` — <5% participation across several consecutive checkpoints; verify repeated default-continue resolution doesn't silently break any invariant (e.g. `CheckpointWindowState` resets correctly every time even when nothing happens)

### 7.7 Invariant / fuzz suite (Foundry `invariant_*`, stateful handler pattern)
- Vault balance never negative, `totalShares` always mirrors `LAFShareToken.totalSupply()`.
- `totalClaimedByTeam + totalExitedViaRageQuit <= totalDeposited`, always.
- Stream never claimable while `paused == true` or `terminal == true`.
- `cumulativeRageQuitInWindow` never persists across a window boundary — always resets exactly at `markCheckpointWindowOpen()`.
- No sequence of calls from a non-privileged address can invoke `setStreamRate`, `pauseForAudit`, `resumeStreaming`, or `withdrawForRageQuit` directly on the vault except through the correct module.
- Once `terminal == true`, it never flips back to `false` (one-way state).

---

## 8. Open Questions for Journal 2 / Mentor Review

1. **`checkpointWindowDuration` is unspecified in both source documents** — flagged in §5. Needs a value before the stress-test matrix can run; recommend picking something short enough that `PAUSE_FOR_AUDIT` resolutions land well inside the 30-day default response period, e.g. 7–14 days, and treating it as a swept parameter alongside the others rather than guessing once and moving on.
2. **`PAUSE_FOR_AUDIT` vs. `HALT` are new, explicit action types added in this design** to reconcile Journal 1 Appendix D's four-option vote ("continue, increase, decrease, or halt") with Proposal v3 §6.4's "audit resolution... pauses streaming for a configurable response period." Worth confirming with the mentor that this five-way action set (CONTINUE / INCREASE_RATE / DECREASE_RATE / PAUSE_FOR_AUDIT / HALT) is the intended reading rather than collapsing PAUSE_FOR_AUDIT and HALT into one action.
3. **Rule 2's "remaining pool" baseline** — this design snapshots `unreleasedBalanceAtOpen` once per checkpoint window and measures cumulative rage quit against that fixed snapshot. An alternative reading is a rolling 25%-of-current-balance threshold (recomputed on every rage quit rather than snapshotted). The fixed-snapshot version is simpler and matches "during a single checkpoint" more literally, but worth confirming — the rolling version would be much stricter (harder to reach 25% of a shrinking base) and changes the bank-run stress test's expected trigger point materially.
4. **Team wallet registration for the TEAM_OUTFLOW metric** is admin-set; teams could route dumps through fresh wallets to evade detection. Same open question as before — worth a governance-updatable watchlist, itself becoming a sixth `CheckpointAction`? Or accept as part of Limitation 3 (signal gaming) and move on.
5. **Reporter trust model for Layer 4** — `REPORTER_ROLE` is a single trusted address in the prototype (stand-in for Graph/Chainlink/GitHub oracle infra). For the stress-test matrix's "attacker presence: well-resourced" scenarios, is a compromised/lying reporter in scope, or is Layer 4's oracle assumed honest-but-possibly-stale for the prototype (with signal gaming modeled instead as *legitimate* metrics staying artificially healthy, per `test_stress_signalGaming`)? This materially affects whether `SignalMonitor` needs any reporter redundancy/median-of-N logic in the prototype or can stay single-source.
