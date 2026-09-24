// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILAFVault
 * @notice Layer 1 — Streaming Fund Release.
 *
 * Holds all deposited capital. After funding closes, the team claims
 * funds linearly over time at `ratePerSecond`. Governance (Layer 3)
 * can pause, resume, halt, or adjust the rate. Rage-quit payouts
 * (Layer 2) are deducted from the unreleased balance.
 *
 * All configurable parameters are constructor arguments or
 * AccessControl-gated setters — no hardcoded magic numbers.
 */
interface ILAFVault {
    // ---- Events ----
    event Deposited(address indexed investor, uint256 amount, uint256 sharesMinted);
    event FundingClosed(uint256 ratePerSecond);
    event Claimed(address indexed team, uint256 amount);
    event StreamRateChanged(uint256 oldRate, uint256 newRate);
    event PausedForAudit(uint256 responsePeriodEnd);
    event Resumed(address indexed caller);
    event RageQuitThresholdBreached(uint256 cumulativeInWindow, uint256 thresholdBps);
    event TerminalStateEntered(uint256 remainingBalance);

    // ---- View functions ----
    function totalDeposited() external view returns (uint256);
    function totalClaimedByTeam() external view returns (uint256);
    function totalExitedViaRageQuit() external view returns (uint256);
    function ratePerSecond() external view returns (uint256);
    function paused() external view returns (bool);
    function terminal() external view returns (bool);

    /// @notice The amount of capital not yet claimed by the team and not yet
    ///         exited via rage quit. This is the pool available for future
    ///         claims and rage-quit payouts.
    function unreleasedBalance() external view returns (uint256);

    /// @notice How much the team has earned via streaming but not yet claimed.
    function claimable() external view returns (uint256);

    // ---- Investor actions ----
    /// @notice Deposit ETH during funding phase. Mints proportional shares.
    function deposit() external payable;

    // ---- Team actions ----
    /// @notice Claim streamed funds. Reverts if paused or terminal.
    function claim() external;

    // ---- Admin actions ----
    /// @notice Close funding and start the stream at the given rate.
    function closeFunding(uint256 _ratePerSecond) external;

    // ---- Governor actions (GOVERNOR_ROLE) ----
    function setStreamRate(uint256 newRate) external;
    function pauseForAudit(uint256 responsePeriod) external;
    function resumeStreaming() external;

    // ---- Checkpoint window management (GOVERNOR_ROLE) ----
    function markCheckpointWindowOpen(uint256 checkpointId) external;

    // ---- RageQuit actions (RAGEQUIT_ROLE) ----
    function withdrawForRageQuit(address holder, uint256 amount) external;

    // ---- Permissionless ----
    /// @notice Check if pool has depleted below threshold. If so, enter terminal state.
    function checkPoolDepletion() external;

    /// @notice Resume streaming if audit response period has timed out. (Rule 1b)
    function resumeIfTimedOut() external;
}
