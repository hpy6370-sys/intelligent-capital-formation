// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ISignalMonitor} from "./interfaces/ISignalMonitor.sol";
import {QuadraticGovernor} from "./QuadraticGovernor.sol";

/**
 * @title SignalMonitor
 * @notice Layer 4 — On-chain early warning system.
 *
 * Tracks 5 health metrics reported by a set of up to MAX_REPORTERS
 * registered reporters (each holds REPORTER_ROLE). A metric only has an
 * effective value when at least `quorum` reporters have each submitted
 * within the last `reportWindow` seconds; the effective value is the
 * median of those fresh submissions (lower median for even counts).
 * Fewer than `quorum` fresh submissions means "no data": warning and
 * critical flags are cleared for that metric.
 *
 * When the combinator condition fires (>=2 warnings OR >=1 critical),
 * calls Governor.triggerEarlyCheckpoint(). Never touches LAFVault.
 *
 * "Smoke alarm, not fire marshal."
 *
 * Metrics (Proposal v3 §6.5):
 *   0: TVL_DECLINE           warning 40%,  critical 70%
 *   1: ACTIVE_ADDR_DECLINE   warning 50%,  critical 80%
 *   2: TEAM_OUTFLOW          warning 300%, critical 1000% (3x/10x)
 *   3: COMMIT_INACTIVITY     warning 60d,  critical 120d  (in bps: 6000/12000)
 *   4: HHI_INCREASE          warning 0.15, critical 0.30  (in bps: 1500/3000)
 */
contract SignalMonitor is ISignalMonitor, AccessControl {
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");

    uint8 public constant NUM_METRICS = 5;
    uint8 public constant MAX_REPORTERS = 16;

    QuadraticGovernor public immutable governor;

    // Combinator thresholds
    uint256 public immutable warningCombinatorThreshold; // default 2
    uint256 public immutable criticalCombinatorThreshold; // default 1

    // Multi-reporter parameters
    uint256 public immutable quorum; // k: min fresh submissions per metric, >= 1
    uint256 public immutable reportWindow; // W: seconds a submission stays fresh

    struct MetricThresholds {
        uint256 warningBps;
        uint256 criticalBps;
    }

    struct MetricState {
        uint256 lastValueBps; // median of fresh submissions as of last recompute
        uint256 lastReportedAt; // timestamp of the most recent submission for this metric
        uint256 freshCount; // number of fresh submissions as of last recompute
        bool warningActive;
        bool criticalActive;
    }

    struct Submission {
        uint256 valueBps;
        uint256 reportedAt; // 0 == never submitted
    }

    mapping(uint8 => MetricThresholds) public thresholds;
    mapping(uint8 => MetricState) public metrics;

    // Registered reporters. Membership is the source of truth for _recompute;
    // REPORTER_ROLE is granted/revoked alongside so external tooling can see it.
    address[] public reporters;
    mapping(address => bool) public isReporter;

    // metricId => reporter => latest submission
    mapping(uint8 => mapping(address => Submission)) public submissions;

    // Errors
    error InvalidMetricId(uint8 metricId);
    error InvalidQuorum();
    error InvalidWindow();
    error UseReporterRegistry();
    error ZeroAddress();
    error TooManyReporters();
    error ReporterAlreadyRegistered(address reporter);
    error ReporterNotRegistered(address reporter);

    constructor(
        address admin,
        QuadraticGovernor _governor,
        uint256 _warningCombinatorThreshold,
        uint256 _criticalCombinatorThreshold,
        uint256 _quorum,
        uint256 _reportWindow
    ) {
        if (_quorum == 0 || _quorum > MAX_REPORTERS) revert InvalidQuorum();
        if (_reportWindow == 0) revert InvalidWindow();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        governor = _governor;
        warningCombinatorThreshold = _warningCombinatorThreshold;
        criticalCombinatorThreshold = _criticalCombinatorThreshold;
        quorum = _quorum;
        reportWindow = _reportWindow;

        // Default thresholds from Proposal v3 §6.5
        thresholds[0] = MetricThresholds(4000, 7000); // TVL_DECLINE
        thresholds[1] = MetricThresholds(5000, 8000); // ACTIVE_ADDR_DECLINE
        thresholds[2] = MetricThresholds(30000, 100000); // TEAM_OUTFLOW (3x/10x in bps)
        thresholds[3] = MetricThresholds(6000, 12000); // COMMIT_INACTIVITY (60d/120d)
        thresholds[4] = MetricThresholds(1500, 3000); // HHI_INCREASE (0.15/0.30)
    }

    // ================================================================
    //                        ADMIN ACTIONS
    // ================================================================

    /// @inheritdoc ISignalMonitor
    function addReporter(address reporter) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (reporter == address(0)) revert ZeroAddress();
        if (isReporter[reporter]) revert ReporterAlreadyRegistered(reporter);
        if (reporters.length >= MAX_REPORTERS) revert TooManyReporters();

        reporters.push(reporter);
        isReporter[reporter] = true;
        _grantRole(REPORTER_ROLE, reporter);

        emit ReporterAdded(reporter);
    }

    /// @inheritdoc ISignalMonitor
    function removeReporter(address reporter) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isReporter[reporter]) revert ReporterNotRegistered(reporter);

        isReporter[reporter] = false;
        _revokeRole(REPORTER_ROLE, reporter);

        // Swap-and-pop from the array (order is irrelevant to the median)
        uint256 len = reporters.length;
        for (uint256 i = 0; i < len; i++) {
            if (reporters[i] == reporter) {
                reporters[i] = reporters[len - 1];
                reporters.pop();
                break;
            }
        }

        // Drop its submissions and refresh every metric so no flag survives
        // on the strength of a reporter that no longer exists.
        for (uint8 m = 0; m < NUM_METRICS; m++) {
            delete submissions[m][reporter];
            _recompute(m);
        }

        emit ReporterRemoved(reporter);
    }

    // REPORTER_ROLE may only change through addReporter/removeReporter, so the
    // reporters array, isReporter, the role and stored submissions can never
    // drift apart. Other roles fall through to AccessControl unchanged.

    function grantRole(bytes32 role, address account) public override {
        if (role == REPORTER_ROLE) revert UseReporterRegistry();
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override {
        if (role == REPORTER_ROLE) revert UseReporterRegistry();
        super.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == REPORTER_ROLE) revert UseReporterRegistry();
        super.renounceRole(role, callerConfirmation);
    }

    // ================================================================
    //                      REPORTER ACTIONS
    // ================================================================

    /// @inheritdoc ISignalMonitor
    function reportMetric(uint8 metricId, uint256 valueBps) external override onlyRole(REPORTER_ROLE) {
        if (metricId >= NUM_METRICS) revert InvalidMetricId(metricId);
        // Defense in depth: grantRole(REPORTER_ROLE) is blocked above, so role
        // and registry cannot diverge; this guard is kept for the case where
        // that ever changes.
        if (!isReporter[msg.sender]) revert ReporterNotRegistered(msg.sender);

        submissions[metricId][msg.sender] = Submission(valueBps, block.timestamp);
        metrics[metricId].lastReportedAt = block.timestamp;

        _recompute(metricId);

        emit MetricReported(metricId, valueBps, msg.sender);
    }

    // ================================================================
    //                      PERMISSIONLESS
    // ================================================================

    /// @inheritdoc ISignalMonitor
    function evaluate() external override returns (bool triggered) {
        // Refresh first so a flag whose submissions have expired cannot trigger.
        for (uint8 i = 0; i < NUM_METRICS; i++) {
            _recompute(i);
        }

        uint256 warnings = warningCount();
        uint256 criticals = criticalCount();

        if (warnings >= warningCombinatorThreshold || criticals >= criticalCombinatorThreshold) {
            // Attempt to trigger early checkpoint on the governor
            // This may revert if rate-limited (Rule 3) or window already open,
            // which is expected — we catch and return false
            try governor.triggerEarlyCheckpoint() {
                triggered = true;
                emit EarlyCheckpointRequested();
            } catch {
                triggered = false;
            }
        }
    }

    // ================================================================
    //                          INTERNAL
    // ================================================================

    /**
     * @dev Recompute one metric from its fresh submissions.
     *      Fresh: reportedAt != 0 && block.timestamp - reportedAt <= reportWindow
     *      (age exactly reportWindow still counts; age reportWindow + 1 does not).
     *      < quorum fresh -> no data: flags cleared, lastValueBps = 0.
     *      >= quorum      -> lastValueBps = lower median, flags set by thresholds.
     *      Warning/Critical events fire only on false -> true transitions.
     *
     *      Insertion sort over at most MAX_REPORTERS (16) values; bounded gas.
     */
    function _recompute(uint8 metricId) internal {
        MetricState storage state = metrics[metricId];

        uint256 n = reporters.length;
        uint256[] memory fresh = new uint256[](n);
        uint256 count;

        for (uint256 i = 0; i < n; i++) {
            Submission storage s = submissions[metricId][reporters[i]];
            // reportedAt is always a past block.timestamp, so the subtraction cannot underflow.
            if (s.reportedAt == 0 || block.timestamp - s.reportedAt > reportWindow) continue;

            // Insert s.valueBps into the sorted prefix fresh[0..count)
            uint256 v = s.valueBps;
            uint256 j = count;
            while (j > 0 && fresh[j - 1] > v) {
                fresh[j] = fresh[j - 1];
                j--;
            }
            fresh[j] = v;
            count++;
        }

        state.freshCount = count;

        if (count < quorum) {
            state.lastValueBps = 0;
            state.warningActive = false;
            state.criticalActive = false;
            return;
        }

        uint256 median = fresh[(count - 1) / 2]; // lower median for even count (conservative)
        state.lastValueBps = median;

        MetricThresholds storage t = thresholds[metricId];
        bool wasWarning = state.warningActive;
        bool wasCritical = state.criticalActive;

        state.criticalActive = median >= t.criticalBps;
        state.warningActive = median >= t.warningBps;

        if (state.warningActive && !wasWarning) {
            emit MetricWarning(metricId, median);
        }
        if (state.criticalActive && !wasCritical) {
            emit MetricCritical(metricId, median);
        }
    }

    // ================================================================
    //                        VIEW FUNCTIONS
    // ================================================================

    /// @inheritdoc ISignalMonitor
    function warningCount() public view override returns (uint256 count) {
        for (uint8 i = 0; i < NUM_METRICS; i++) {
            if (metrics[i].warningActive) count++;
        }
    }

    /// @inheritdoc ISignalMonitor
    function criticalCount() public view override returns (uint256 count) {
        for (uint8 i = 0; i < NUM_METRICS; i++) {
            if (metrics[i].criticalActive) count++;
        }
    }

    /// @inheritdoc ISignalMonitor
    function isMetricWarning(uint8 metricId) external view override returns (bool) {
        if (metricId >= NUM_METRICS) revert InvalidMetricId(metricId);
        return metrics[metricId].warningActive;
    }

    /// @inheritdoc ISignalMonitor
    function isMetricCritical(uint8 metricId) external view override returns (bool) {
        if (metricId >= NUM_METRICS) revert InvalidMetricId(metricId);
        return metrics[metricId].criticalActive;
    }

    /// @inheritdoc ISignalMonitor
    function effectiveValue(uint8 metricId) external view override returns (uint256) {
        if (metricId >= NUM_METRICS) revert InvalidMetricId(metricId);
        return metrics[metricId].lastValueBps;
    }

    /// @inheritdoc ISignalMonitor
    function freshCount(uint8 metricId) external view override returns (uint256) {
        if (metricId >= NUM_METRICS) revert InvalidMetricId(metricId);
        return metrics[metricId].freshCount;
    }

    /// @inheritdoc ISignalMonitor
    function reporterCount() external view override returns (uint256) {
        return reporters.length;
    }
}
