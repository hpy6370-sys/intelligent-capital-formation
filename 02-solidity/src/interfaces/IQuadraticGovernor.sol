// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IQuadraticGovernor
 * @notice Layer 3 — Quadratic Governance Checkpoints.
 *
 * Opens checkpoint windows at regular intervals (default 90 days).
 * Within a window, any holder can initiate an audit vote; votes are
 * weighted by sqrt(balanceAtSnapshot). If no vote is initiated,
 * the checkpoint resolves as CONTINUE (default-continue semantics).
 *
 * Actions: CONTINUE, INCREASE_RATE, DECREASE_RATE, PAUSE_FOR_AUDIT, HALT.
 */
interface IQuadraticGovernor {
    enum CheckpointAction { CONTINUE, INCREASE_RATE, DECREASE_RATE, PAUSE_FOR_AUDIT, HALT }
    enum CheckpointTrigger { SCHEDULED, SIGNAL }

    event CheckpointWindowOpened(uint256 indexed id, CheckpointTrigger trigger);
    event AuditVoteInitiated(uint256 indexed id, CheckpointAction proposedAction, address initiator);
    event Voted(uint256 indexed id, address indexed voter, CheckpointAction action, uint256 weight);
    event CheckpointResolved(uint256 indexed id, CheckpointAction outcome);
    event EarlyCheckpointTriggered(uint256 indexed id);

    /// @notice Open a scheduled checkpoint window. Reverts if interval hasn't elapsed.
    function openCheckpointWindow() external returns (uint256 id);

    /// @notice Initiate an audit vote within an open window.
    function initiateAuditVote(uint256 checkpointId, CheckpointAction action, uint256 newRateDelta) external;

    /// @notice Cast a vote. Weight = sqrt(balanceAtSnapshot).
    function vote(uint256 checkpointId, CheckpointAction action) external;

    /// @notice Resolve a checkpoint after the window closes.
    function resolveCheckpoint(uint256 checkpointId) external;

    /// @notice SIGNAL_ROLE only. Opens an early checkpoint window if rate-limit allows.
    function triggerEarlyCheckpoint() external returns (uint256 id);
}
