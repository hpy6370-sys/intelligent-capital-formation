// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LAFTestBase} from "../LAFTestBase.sol";
import {SignalMonitor} from "../../src/SignalMonitor.sol";
import {ISignalMonitor} from "../../src/interfaces/ISignalMonitor.sol";
import {IQuadraticGovernor} from "../../src/interfaces/IQuadraticGovernor.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title SignalMonitorTest
 * @notice Multi-reporter SignalMonitor (v2). N=3 reporters, quorum=2, window=1 day.
 *
 * Verifies that a single reporter can no longer open an early checkpoint on
 * its own (v1 Limitation 2), that the median resists an outlier, that stale
 * submissions expire, that removing a reporter drops its submission, and that
 * N=1/k=1 reproduces v1 behaviour.
 */
contract SignalMonitorTest is LAFTestBase {
    uint256 constant QUORUM = 2;
    uint256 constant WINDOW = 1 days;

    uint8 constant TVL = 0;
    uint256 constant TVL_CRITICAL = 7500; // >= 7000 critical, >= 4000 warning

    address r1 = makeAddr("r1");
    address r2 = makeAddr("r2");
    address r3 = makeAddr("r3");

    function setUp() public override {
        super.setUp();

        // Replace the base monitor (N=1, k=1) with the multi-reporter config
        vm.startPrank(admin);
        monitor = new SignalMonitor(admin, governor, 2, 1, QUORUM, WINDOW);
        governor.grantRole(governor.SIGNAL_ROLE(), address(monitor));
        monitor.addReporter(r1);
        monitor.addReporter(r2);
        monitor.addReporter(r3);
        vm.stopPrank();

        assertEq(monitor.reporterCount(), 3);
    }

    function _report(address who, uint8 metricId, uint256 valueBps) internal {
        vm.prank(who);
        monitor.reportMetric(metricId, valueBps);
    }

    // ================================================================
    //  1. One reporter alone cannot light a flag or trigger (Limitation 2)
    // ================================================================

    function test_singleReporterCannotTrigger() public {
        _fundAndClose();

        _report(r1, TVL, TVL_CRITICAL);

        assertEq(monitor.freshCount(TVL), 1, "one fresh submission");
        assertEq(monitor.effectiveValue(TVL), 0, "no effective value below quorum");
        assertFalse(monitor.isMetricWarning(TVL), "warning must not light");
        assertFalse(monitor.isMetricCritical(TVL), "critical must not light");

        bool triggered = monitor.evaluate();
        assertFalse(triggered, "single reporter must not trigger");
        assertEq(governor.nextCheckpointId(), 0, "no window opened");
    }

    // ================================================================
    //  2. Quorum reached: flag lights, evaluate opens a SIGNAL window
    // ================================================================

    function test_quorumTriggers() public {
        _fundAndClose();

        _report(r1, TVL, TVL_CRITICAL);
        assertFalse(monitor.isMetricCritical(TVL), "not yet at quorum");

        // Second submission reaches quorum; event fires on the false->true edge
        vm.expectEmit(true, false, false, true, address(monitor));
        emit ISignalMonitor.MetricCritical(TVL, TVL_CRITICAL);
        _report(r2, TVL, TVL_CRITICAL);

        assertEq(monitor.freshCount(TVL), 2);
        assertEq(monitor.effectiveValue(TVL), TVL_CRITICAL);
        assertTrue(monitor.isMetricWarning(TVL));
        assertTrue(monitor.isMetricCritical(TVL));

        bool triggered = monitor.evaluate();
        assertTrue(triggered, "quorum must trigger");
        assertEq(governor.nextCheckpointId(), 1, "one window opened");

        (,, IQuadraticGovernor.CheckpointTrigger trigger,,,,,,,) = governor.checkpoints(0);
        assertEq(uint256(trigger), uint256(IQuadraticGovernor.CheckpointTrigger.SIGNAL));
    }

    // ================================================================
    //  3. Median: one outlier reporter cannot drag the value up
    // ================================================================

    function test_medianResistsOutlier() public {
        _fundAndClose();

        _report(r1, TVL, 9000); // bad reporter
        _report(r2, TVL, 500);
        _report(r3, TVL, 600);

        assertEq(monitor.freshCount(TVL), 3);
        assertEq(monitor.effectiveValue(TVL), 600, "median of {500,600,9000}");
        assertFalse(monitor.isMetricWarning(TVL));
        assertFalse(monitor.isMetricCritical(TVL));
        assertFalse(monitor.evaluate());
    }

    // ================================================================
    //  4. Submissions older than the window stop counting
    // ================================================================

    function test_staleSubmissionExpires() public {
        _fundAndClose();

        _report(r1, TVL, TVL_CRITICAL);
        _report(r2, TVL, TVL_CRITICAL);
        assertTrue(monitor.isMetricCritical(TVL), "lit at quorum");

        _warp(WINDOW + 1);

        // Flag is still stored until something recomputes ...
        assertTrue(monitor.isMetricCritical(TVL), "stale flag persists until recompute");

        // ... evaluate() recomputes first, so the expired flag cannot trigger
        bool triggered = monitor.evaluate();
        assertFalse(triggered, "expired submissions must not trigger");
        assertEq(monitor.freshCount(TVL), 0);
        assertEq(monitor.effectiveValue(TVL), 0);
        assertFalse(monitor.isMetricWarning(TVL));
        assertFalse(monitor.isMetricCritical(TVL));
        assertEq(governor.nextCheckpointId(), 0);
    }

    // ================================================================
    //  5. Removing a reporter discards its submission and recomputes
    // ================================================================

    function test_removeReporterDropsSubmission() public {
        _fundAndClose();

        _report(r1, TVL, TVL_CRITICAL);
        _report(r2, TVL, TVL_CRITICAL);
        assertTrue(monitor.isMetricCritical(TVL));

        vm.expectEmit(true, false, false, true, address(monitor));
        emit ISignalMonitor.ReporterRemoved(r2);
        vm.prank(admin);
        monitor.removeReporter(r2);

        assertEq(monitor.reporterCount(), 2);
        assertFalse(monitor.isReporter(r2));
        assertFalse(monitor.hasRole(monitor.REPORTER_ROLE(), r2));
        (, uint256 reportedAt) = monitor.submissions(TVL, r2);
        assertEq(reportedAt, 0, "submission deleted");

        assertEq(monitor.freshCount(TVL), 1);
        assertFalse(monitor.isMetricCritical(TVL), "flag dropped below quorum");
        assertFalse(monitor.evaluate());

        // Removed reporter can no longer report
        vm.prank(r2);
        vm.expectRevert();
        monitor.reportMetric(TVL, TVL_CRITICAL);
    }

    // ================================================================
    //  6. N=1, k=1, large window reproduces v1 (StressTest gaming + cascade)
    // ================================================================

    function test_v1Compat() public {
        vm.startPrank(admin);
        SignalMonitor v1 = new SignalMonitor(admin, governor, 2, 1, 1, 365 days);
        governor.grantRole(governor.SIGNAL_ROLE(), address(v1));
        v1.addReporter(reporter);
        vm.stopPrank();

        _fundAndClose();

        // --- signal gaming: healthy metrics never trigger ---
        vm.startPrank(reporter);
        v1.reportMetric(0, 500);
        v1.reportMetric(1, 1000);
        v1.reportMetric(2, 5000);
        v1.reportMetric(3, 1000);
        v1.reportMetric(4, 500);
        vm.stopPrank();

        assertFalse(v1.evaluate(), "gamed metrics must not trigger");
        assertEq(v1.warningCount(), 0);
        assertEq(v1.criticalCount(), 0);
        assertEq(v1.freshCount(0), 1);
        assertEq(v1.effectiveValue(0), 500, "single value is its own median");

        // Regular checkpoint still works
        _warp(CHECKPOINT_INTERVAL + 1);
        uint256 cpId = governor.openCheckpointWindow();
        (uint256 windowStart,,,,,,,,,) = governor.checkpoints(cpId);
        assertGt(windowStart, 0);

        // --- cascade: critical during open window is a no-op ---
        vm.prank(reporter);
        v1.reportMetric(0, TVL_CRITICAL);
        assertTrue(v1.isMetricCritical(0), "single reporter suffices at k=1");
        assertEq(v1.criticalCount(), 1);
        assertEq(v1.warningCount(), 1);
        assertFalse(v1.evaluate(), "window already open");

        // Once resolved, the same single-reporter critical does trigger (v1 semantics)
        _warp(CHECKPOINT_WINDOW + 1);
        governor.resolveCheckpoint(cpId);
        assertTrue(v1.evaluate(), "k=1 trigger after window resolved");
        assertEq(governor.nextCheckpointId(), cpId + 2);
    }

    // ================================================================
    //  7. Reporter set is capped at MAX_REPORTERS
    // ================================================================

    function test_addReporterBeyondMaxReverts() public {
        uint256 max = monitor.MAX_REPORTERS();

        vm.startPrank(admin);
        for (uint256 i = monitor.reporterCount(); i < max; i++) {
            monitor.addReporter(makeAddr(string(abi.encodePacked("extra", i))));
        }
        assertEq(monitor.reporterCount(), max);

        vm.expectRevert(SignalMonitor.TooManyReporters.selector);
        monitor.addReporter(makeAddr("one-too-many"));
        vm.stopPrank();

        assertEq(monitor.reporterCount(), max);
    }

    // ================================================================
    //  Constructor guard: quorum must be >= 1
    // ================================================================

    function test_zeroQuorumReverts() public {
        vm.expectRevert(SignalMonitor.InvalidQuorum.selector);
        new SignalMonitor(admin, governor, 2, 1, 0, WINDOW);
    }

    // ================================================================
    //  Constructor guard: quorum must be <= MAX_REPORTERS (immutable, so
    //  a larger value would be a monitor that can never light a flag)
    // ================================================================

    function test_quorumAboveMaxReportersReverts() public {
        uint256 max = monitor.MAX_REPORTERS();

        vm.expectRevert(SignalMonitor.InvalidQuorum.selector);
        new SignalMonitor(admin, governor, 2, 1, max + 1, WINDOW); // 17

        // The bound itself is allowed
        SignalMonitor atMax = new SignalMonitor(admin, governor, 2, 1, max, WINDOW);
        assertEq(atMax.quorum(), max);
    }

    // ================================================================
    //  Constructor guard: reportWindow must be > 0
    // ================================================================

    function test_zeroWindowReverts() public {
        vm.expectRevert(SignalMonitor.InvalidWindow.selector);
        new SignalMonitor(admin, governor, 2, 1, QUORUM, 0);
    }

    // ================================================================
    //  REPORTER_ROLE cannot be changed through raw AccessControl calls
    // ================================================================

    function test_rawRoleMutationReverts() public {
        bytes32 role = monitor.REPORTER_ROLE();
        bytes32 adminRole = monitor.DEFAULT_ADMIN_ROLE();
        address outsider = makeAddr("outsider");

        vm.startPrank(admin);
        vm.expectRevert(SignalMonitor.UseReporterRegistry.selector);
        monitor.grantRole(role, outsider);

        vm.expectRevert(SignalMonitor.UseReporterRegistry.selector);
        monitor.revokeRole(role, r1);
        vm.stopPrank();

        // A reporter cannot freeze its last vote by renouncing its own role
        vm.prank(r1);
        vm.expectRevert(SignalMonitor.UseReporterRegistry.selector);
        monitor.renounceRole(role, r1);

        // Nothing moved
        assertTrue(monitor.isReporter(r1));
        assertTrue(monitor.hasRole(role, r1));
        assertFalse(monitor.hasRole(role, outsider));
        assertEq(monitor.reporterCount(), 3);
        _report(r1, TVL, TVL_CRITICAL);
        assertEq(monitor.freshCount(TVL), 1);

        // Other roles still fall through to AccessControl
        vm.prank(admin);
        monitor.grantRole(adminRole, outsider);
        assertTrue(monitor.hasRole(adminRole, outsider));
    }

    // ================================================================
    //  removeReporter is the only exit: membership, role and the old
    //  submission all go, and later recomputes never see it again
    // ================================================================

    function test_removeReporterExcludesOldSubmission() public {
        bytes32 role = monitor.REPORTER_ROLE();

        _report(r1, TVL, TVL_CRITICAL);
        _report(r2, TVL, TVL_CRITICAL);
        _report(r3, TVL, 100);
        assertEq(monitor.freshCount(TVL), 3);
        assertEq(monitor.effectiveValue(TVL), TVL_CRITICAL, "median of {100,7500,7500}");
        assertTrue(monitor.isMetricCritical(TVL));

        vm.prank(admin);
        monitor.removeReporter(r2);

        assertFalse(monitor.isReporter(r2));
        assertFalse(monitor.hasRole(role, r2));
        (uint256 storedValue, uint256 storedAt) = monitor.submissions(TVL, r2);
        assertEq(storedValue, 0, "submission value cleared");
        assertEq(storedAt, 0, "submission timestamp cleared");

        // r2's 7500 no longer counts: lower median of {100, 7500} is 100
        assertEq(monitor.freshCount(TVL), 2);
        assertEq(monitor.effectiveValue(TVL), 100);
        assertFalse(monitor.isMetricWarning(TVL));
        assertFalse(monitor.isMetricCritical(TVL));

        // Later recomputes (a fresh report, then evaluate) still exclude it
        _report(r1, TVL, TVL_CRITICAL);
        assertEq(monitor.freshCount(TVL), 2);
        assertEq(monitor.effectiveValue(TVL), 100);
        assertFalse(monitor.evaluate());
        assertEq(monitor.freshCount(TVL), 2);
        assertFalse(monitor.isMetricCritical(TVL));

        // And the role really is gone, so r2 cannot re-enter by reporting
        vm.prank(r2);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, r2, role)
        );
        monitor.reportMetric(TVL, TVL_CRITICAL);
    }

    // ================================================================
    //  Freshness uses block.timestamp - reportedAt <= reportWindow, so
    //  neither a huge window nor a huge timestamp can overflow (0x11)
    // ================================================================

    function test_freshnessNoPanicAtExtremes() public {
        // Max window: `reportedAt + reportWindow` would panic on the first report.
        vm.startPrank(admin);
        SignalMonitor wide = new SignalMonitor(admin, governor, 2, 1, 1, type(uint256).max);
        wide.addReporter(r1);
        vm.stopPrank();

        vm.prank(r1);
        wide.reportMetric(TVL, TVL_CRITICAL);
        assertEq(wide.freshCount(TVL), 1);
        assertTrue(wide.isMetricCritical(TVL));

        // Max timestamp the EVM will take: age is enormous but still <= window
        vm.warp(type(uint64).max);
        vm.prank(r1);
        wide.reportMetric(1, 100); // recompute of metric 1 only; metric 0 untouched
        assertEq(wide.freshCount(1), 1, "submission at the extreme timestamp is fresh");
        wide.evaluate(); // recomputes all five; no SIGNAL_ROLE so the trigger is caught
        assertEq(wide.freshCount(TVL), 1, "old submission still within max window");
        assertTrue(wide.isMetricCritical(TVL));

        // Normal window (1 day) pushed to the top of the timestamp range:
        // age == W stays fresh, age == W + 1 expires, no panic either way.
        uint256 t0 = type(uint64).max - WINDOW - 1;
        vm.warp(t0);
        _report(r1, TVL, TVL_CRITICAL);
        _report(r2, TVL, TVL_CRITICAL);
        assertTrue(monitor.isMetricCritical(TVL));

        vm.warp(t0 + WINDOW);
        _report(r3, TVL, 100); // recompute: r1, r2 at age == W still count
        assertEq(monitor.freshCount(TVL), 3);
        assertEq(monitor.effectiveValue(TVL), TVL_CRITICAL);
        assertTrue(monitor.isMetricCritical(TVL));

        vm.warp(t0 + WINDOW + 1);
        _report(r3, TVL, 100); // recompute: r1, r2 at age == W + 1 are gone
        assertEq(monitor.freshCount(TVL), 1);
        assertEq(monitor.effectiveValue(TVL), 0);
        assertFalse(monitor.isMetricCritical(TVL));
    }
}
