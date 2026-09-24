// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IQuadraticGovernor} from "./interfaces/IQuadraticGovernor.sol";
import {LAFShareToken} from "./LAFShareToken.sol";
import {LAFVault} from "./LAFVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title QuadraticGovernor
 * @notice Layer 3 — Periodic quadratic-weighted governance checkpoints.
 *
 * Opens checkpoint windows at regular intervals (default 90 days).
 * Within a window, any holder can initiate an audit vote; votes are
 * weighted by sqrt(balanceAtSnapshot). If no vote is initiated or
 * quorum is not met, the checkpoint resolves as CONTINUE.
 *
 * SignalMonitor (SIGNAL_ROLE) can trigger early checkpoints, rate-limited
 * to once per signalRateLimit days (Rule 3).
 */
contract QuadraticGovernor is IQuadraticGovernor, AccessControl {
    bytes32 public constant SIGNAL_ROLE = keccak256("SIGNAL_ROLE");

    LAFVault public immutable vault;
    LAFShareToken public immutable shareToken;

    // Constructor params (configurable for stress-test sweeps)
    uint256 public immutable checkpointInterval;        // default 90 days
    uint256 public immutable checkpointWindowDuration;  // default 14 days
    uint256 public immutable quorumBps;                 // default 2000 (20%)
    uint256 public immutable majorityBps;               // default 5000 (50%)
    uint256 public immutable defaultPauseResponsePeriod;// default 30 days
    uint256 public immutable signalRateLimit;           // default 30 days

    // State
    uint256 public nextCheckpointId;
    uint256 public lastCheckpointEnd;    // timestamp when last window closed
    uint256 public lastSignalTrigger;    // timestamp of last signal-triggered checkpoint

    struct Checkpoint {
        uint256 windowStart;
        uint256 windowEnd;
        CheckpointTrigger trigger;
        uint256 snapshotBlock;
        bool auditInitiated;
        bool resolved;
        CheckpointAction resolvedAction;
        CheckpointAction proposedAction;
        uint256 proposedRateDelta;
        uint256 totalVoteWeight;
    }

    mapping(uint256 => Checkpoint) public checkpoints;
    mapping(uint256 => mapping(CheckpointAction => uint256)) public tallies;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // Errors
    error IntervalNotElapsed();
    error WindowNotOpen(uint256 checkpointId);
    error WindowStillOpen(uint256 checkpointId);
    error AuditAlreadyInitiated(uint256 checkpointId);
    error AuditNotInitiated(uint256 checkpointId);
    error AlreadyVoted(uint256 checkpointId);
    error AlreadyResolved(uint256 checkpointId);
    error SignalRateLimited();
    error NotAShareHolder();
    error CheckpointWindowAlreadyOpen();

    constructor(
        address admin,
        LAFVault _vault,
        LAFShareToken _shareToken,
        uint256 _checkpointInterval,
        uint256 _checkpointWindowDuration,
        uint256 _quorumBps,
        uint256 _majorityBps,
        uint256 _defaultPauseResponsePeriod,
        uint256 _signalRateLimit
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        vault = _vault;
        shareToken = _shareToken;
        checkpointInterval = _checkpointInterval;
        checkpointWindowDuration = _checkpointWindowDuration;
        quorumBps = _quorumBps;
        majorityBps = _majorityBps;
        defaultPauseResponsePeriod = _defaultPauseResponsePeriod;
        signalRateLimit = _signalRateLimit;
    }

    // ================================================================
    //                      CHECKPOINT MANAGEMENT
    // ================================================================

    /// @inheritdoc IQuadraticGovernor
    function openCheckpointWindow() external override returns (uint256 id) {
        // Check interval has elapsed since last window closed
        if (lastCheckpointEnd != 0 && block.timestamp < lastCheckpointEnd + checkpointInterval) {
            revert IntervalNotElapsed();
        }

        id = _openWindow(CheckpointTrigger.SCHEDULED);
    }

    /// @inheritdoc IQuadraticGovernor
    function triggerEarlyCheckpoint() external override onlyRole(SIGNAL_ROLE) returns (uint256 id) {
        // Rule 3: rate-limited to once per signalRateLimit
        if (lastSignalTrigger != 0 && block.timestamp < lastSignalTrigger + signalRateLimit) {
            revert SignalRateLimited();
        }

        // Rule 3: no-op if a window is already open
        if (nextCheckpointId > 0) {
            Checkpoint storage latest = checkpoints[nextCheckpointId - 1];
            if (!latest.resolved && block.timestamp <= latest.windowEnd) {
                revert CheckpointWindowAlreadyOpen();
            }
        }

        lastSignalTrigger = block.timestamp;
        id = _openWindow(CheckpointTrigger.SIGNAL);

        emit EarlyCheckpointTriggered(id);
    }

    /// @inheritdoc IQuadraticGovernor
    function initiateAuditVote(
        uint256 checkpointId,
        CheckpointAction action,
        uint256 newRateDelta
    ) external override {
        Checkpoint storage cp = checkpoints[checkpointId];
        _requireWindowOpen(cp, checkpointId);
        if (cp.auditInitiated) revert AuditAlreadyInitiated(checkpointId);
        if (shareToken.balanceOf(msg.sender) == 0) revert NotAShareHolder();

        cp.auditInitiated = true;
        cp.proposedAction = action;
        cp.proposedRateDelta = newRateDelta;

        emit AuditVoteInitiated(checkpointId, action, msg.sender);
    }

    /// @inheritdoc IQuadraticGovernor
    function vote(uint256 checkpointId, CheckpointAction action) external override {
        Checkpoint storage cp = checkpoints[checkpointId];
        _requireWindowOpen(cp, checkpointId);
        if (!cp.auditInitiated) revert AuditNotInitiated(checkpointId);
        if (hasVoted[checkpointId][msg.sender]) revert AlreadyVoted(checkpointId);

        uint256 weight = votingPowerOf(msg.sender, cp.snapshotBlock);
        if (weight == 0) revert NotAShareHolder();

        hasVoted[checkpointId][msg.sender] = true;
        tallies[checkpointId][action] += weight;
        cp.totalVoteWeight += weight;

        emit Voted(checkpointId, msg.sender, action, weight);
    }

    /// @inheritdoc IQuadraticGovernor
    function resolveCheckpoint(uint256 checkpointId) external override {
        Checkpoint storage cp = checkpoints[checkpointId];
        // A checkpoint that was never opened has windowStart == 0. Without this guard anyone could
        // "resolve" an unopened id every 90 days, push lastCheckpointEnd forward and defer the
        // scheduled Layer 3 path indefinitely (found while writing the governor unit tests, 2026-09-08).
        if (cp.windowStart == 0) revert WindowNotOpen(checkpointId);
        if (cp.resolved) revert AlreadyResolved(checkpointId);
        if (block.timestamp <= cp.windowEnd) revert WindowStillOpen(checkpointId);

        cp.resolved = true;
        lastCheckpointEnd = block.timestamp;

        CheckpointAction action = CheckpointAction.CONTINUE;

        if (cp.auditInitiated) {
            // Check quorum: 20% of sqrt(totalSupply)
            uint256 sqrtTotal = Math.sqrt(shareToken.totalSupply());
            uint256 quorumThreshold = (sqrtTotal * quorumBps) / 10000;

            if (cp.totalVoteWeight >= quorumThreshold) {
                // Find the winning action (highest tally with > majorityBps)
                action = _findWinner(checkpointId, cp.totalVoteWeight);
            }
            // If quorum not met, action stays CONTINUE (Limitation 5)
        }

        cp.resolvedAction = action;
        _applyAction(action, cp.proposedRateDelta);

        emit CheckpointResolved(checkpointId, action);
    }

    // ================================================================
    //                        VIEW FUNCTIONS
    // ================================================================

    function votingPowerOf(address account, uint256 snapshotBlock) public view returns (uint256) {
        // Use getPastVotes from ERC20Votes for snapshot-based balance
        uint256 balance = shareToken.getPastVotes(account, snapshotBlock);
        return Math.sqrt(balance);
    }

    // ================================================================
    //                        INTERNAL
    // ================================================================

    function _openWindow(CheckpointTrigger trigger) internal returns (uint256 id) {
        id = nextCheckpointId++;

        checkpoints[id] = Checkpoint({
            windowStart: block.timestamp,
            windowEnd: block.timestamp + checkpointWindowDuration,
            trigger: trigger,
            snapshotBlock: block.number - 1, // snapshot at previous block
            auditInitiated: false,
            resolved: false,
            resolvedAction: CheckpointAction.CONTINUE,
            proposedAction: CheckpointAction.CONTINUE,
            proposedRateDelta: 0,
            totalVoteWeight: 0
        });

        // Notify the vault to snapshot its unreleased balance for Rule 2
        vault.markCheckpointWindowOpen(id);

        emit CheckpointWindowOpened(id, trigger);
    }

    function _requireWindowOpen(Checkpoint storage cp, uint256 checkpointId) internal view {
        if (cp.windowStart == 0) revert WindowNotOpen(checkpointId);
        if (block.timestamp > cp.windowEnd) revert WindowNotOpen(checkpointId);
        if (cp.resolved) revert AlreadyResolved(checkpointId);
    }

    function _findWinner(
        uint256 checkpointId,
        uint256 totalWeight
    ) internal view returns (CheckpointAction) {
        uint256 majorityThreshold = (totalWeight * majorityBps) / 10000;

        CheckpointAction best = CheckpointAction.CONTINUE;
        uint256 bestTally = 0;

        for (uint8 i = 0; i < 5; i++) {
            CheckpointAction action = CheckpointAction(i);
            uint256 tally = tallies[checkpointId][action];
            if (tally > bestTally) {
                bestTally = tally;
                best = action;
            }
        }

        // Winner must exceed majority threshold
        if (bestTally <= majorityThreshold) {
            return CheckpointAction.CONTINUE;
        }

        return best;
    }

    function _applyAction(CheckpointAction action, uint256 rateDelta) internal {
        if (action == CheckpointAction.CONTINUE) {
            // No-op
            return;
        } else if (action == CheckpointAction.INCREASE_RATE) {
            uint256 currentRate = vault.ratePerSecond();
            vault.setStreamRate(currentRate + rateDelta);
        } else if (action == CheckpointAction.DECREASE_RATE) {
            uint256 currentRate = vault.ratePerSecond();
            uint256 newRate = rateDelta >= currentRate ? 0 : currentRate - rateDelta;
            vault.setStreamRate(newRate);
        } else if (action == CheckpointAction.PAUSE_FOR_AUDIT) {
            vault.pauseForAudit(defaultPauseResponsePeriod);
        } else if (action == CheckpointAction.HALT) {
            vault.setStreamRate(0);
        }
    }
}
