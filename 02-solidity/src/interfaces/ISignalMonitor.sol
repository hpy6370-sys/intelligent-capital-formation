// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISignalMonitor
 * @notice Layer 4 — On-chain Signal Monitor.
 *
 * Tracks 5 health metrics reported by a set of registered reporters
 * (each granted REPORTER_ROLE, at most MAX_REPORTERS). A metric has an
 * effective value only when at least `quorum` reporters have submitted
 * within the last `reportWindow` seconds; the effective value is the
 * median of those fresh submissions. Below quorum the metric is treated
 * as having no data and its flags are cleared.
 *
 * When the combinator condition fires (>=2 warnings OR >=1 critical),
 * calls Governor.triggerEarlyCheckpoint(). Never calls LAFVault directly.
 *
 * "Smoke alarm, not fire marshal."
 *
 * Metrics (from Proposal v3 §6.5):
 *   0: TVL_DECLINE           warning 40%, critical 70%
 *   1: ACTIVE_ADDR_DECLINE   warning 50%, critical 80%
 *   2: TEAM_OUTFLOW          warning 3x,  critical 10x
 *   3: COMMIT_INACTIVITY     warning 60d, critical 120d
 *   4: HHI_INCREASE          warning 0.15, critical 0.30
 */
interface ISignalMonitor {
    event MetricReported(uint8 indexed metricId, uint256 valueBps, address reporter);
    /// @dev valueBps is the median that crossed the threshold.
    event MetricWarning(uint8 indexed metricId, uint256 valueBps);
    /// @dev valueBps is the median that crossed the threshold.
    event MetricCritical(uint8 indexed metricId, uint256 valueBps);
    event EarlyCheckpointRequested();
    event ReporterAdded(address indexed reporter);
    event ReporterRemoved(address indexed reporter);

    /// @notice DEFAULT_ADMIN_ROLE only. Register a reporter and grant it REPORTER_ROLE.
    ///         Reverts once MAX_REPORTERS are registered.
    function addReporter(address reporter) external;

    /// @notice DEFAULT_ADMIN_ROLE only. Unregister a reporter, revoke REPORTER_ROLE,
    ///         discard its submissions and recompute every metric.
    function removeReporter(address reporter) external;

    /// @notice Registered reporters only. Submit this reporter's latest value for
    ///         a metric; the metric's effective value is recomputed immediately.
    function reportMetric(uint8 metricId, uint256 valueBps) external;

    /// @notice Permissionless. Recompute all metrics from fresh submissions and
    ///         trigger an early checkpoint if the combinator condition is met.
    function evaluate() external returns (bool triggered);

    function warningCount() external view returns (uint256);
    function criticalCount() external view returns (uint256);
    function isMetricWarning(uint8 metricId) external view returns (bool);
    function isMetricCritical(uint8 metricId) external view returns (bool);

    /// @notice Median of fresh submissions as of the last recompute; 0 when below quorum.
    function effectiveValue(uint8 metricId) external view returns (uint256);

    /// @notice Number of fresh submissions as of the last recompute.
    function freshCount(uint8 metricId) external view returns (uint256);

    /// @notice Number of currently registered reporters.
    function reporterCount() external view returns (uint256);
}
