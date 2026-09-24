// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LAFTestBase} from "../LAFTestBase.sol";
import {IQuadraticGovernor} from "../../src/interfaces/IQuadraticGovernor.sol";

/**
 * @title CrossLayerTest
 * @notice Integration tests for cross-layer interactions — §7.5 of laf_solidity_design.md.
 */
contract CrossLayerTest is LAFTestBase {
    // ================================================================
    //  Signal triggers checkpoint, then audit passes and pauses (§6.4)
    // ================================================================

    function test_integration_signalTriggersCheckpoint_thenAuditPassesAndPauses() public {
        _fundAndClose();
        _warp(1); // need at least 1 block for snapshot

        // Reporter reports 2 warning-level metrics
        vm.startPrank(reporter);
        monitor.reportMetric(0, 4500); // TVL_DECLINE at 45% (warning threshold 40%)
        monitor.reportMetric(1, 5500); // ACTIVE_ADDR_DECLINE at 55% (warning threshold 50%)
        vm.stopPrank();

        // Evaluate triggers early checkpoint via governor
        monitor.evaluate();

        // Verify checkpoint window was opened
        uint256 cpId = governor.nextCheckpointId() - 1;
        (uint256 windowStart,,,,,,,,,) = governor.checkpoints(cpId);
        assertGt(windowStart, 0, "Checkpoint window should be open");

        // Alice initiates audit vote for PAUSE_FOR_AUDIT
        vm.prank(alice);
        governor.initiateAuditVote(cpId, IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT, 0);

        // All holders vote for PAUSE_FOR_AUDIT
        vm.prank(alice);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT);
        vm.prank(bob);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT);
        vm.prank(carol);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT);

        // Advance past window end
        _warp(CHECKPOINT_WINDOW + 1);

        // Resolve — should pause the vault
        governor.resolveCheckpoint(cpId);

        assertTrue(vault.paused(), "Vault should be paused after PAUSE_FOR_AUDIT resolution");
    }

    // ================================================================
    //  Rage quit during active vote doesn't break tally (snapshot voting)
    // ================================================================

    function test_integration_rageQuitDuringActiveVote_doesNotBreakTally() public {
        _fundAndClose();
        _warp(CHECKPOINT_INTERVAL + 1);

        // Open checkpoint
        uint256 cpId = governor.openCheckpointWindow();

        // Alice initiates vote
        vm.prank(alice);
        governor.initiateAuditVote(cpId, IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT, 0);

        // Alice votes first
        vm.prank(alice);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT);

        // Bob rage quits all his shares AFTER the snapshot block
        vm.prank(bob);
        rageQuit.rageQuit(30 ether);

        // Bob's balance is now 0, but his snapshot vote should still count
        assertEq(shareToken.balanceOf(bob), 0, "Bob should have 0 shares after rage quit");

        // Carol votes — her vote should still work normally
        vm.prank(carol);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT);

        // Advance past window and resolve
        _warp(CHECKPOINT_WINDOW + 1);
        governor.resolveCheckpoint(cpId);

        // The checkpoint should resolve successfully despite Bob's rage quit
        (,,,,,bool resolved,,,,) = governor.checkpoints(cpId);
        assertTrue(resolved, "Checkpoint should resolve despite mid-vote rage quit");
    }

    // ================================================================
    //  Governor halts stream, rage quit still available
    // ================================================================

    function test_integration_governorHaltsStream_rageQuitStillAvailable() public {
        _fundAndClose();
        _warp(CHECKPOINT_INTERVAL + 1);

        // Open checkpoint, vote to HALT
        uint256 cpId = governor.openCheckpointWindow();

        vm.prank(alice);
        governor.initiateAuditVote(cpId, IQuadraticGovernor.CheckpointAction.HALT, 0);

        vm.prank(alice);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.HALT);
        vm.prank(bob);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.HALT);
        vm.prank(carol);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.HALT);

        _warp(CHECKPOINT_WINDOW + 1);
        governor.resolveCheckpoint(cpId);

        // Stream rate should be 0
        assertEq(vault.ratePerSecond(), 0, "Rate should be 0 after HALT");

        // But rage quit should still work
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        rageQuit.rageQuit(50 ether);

        assertGt(alice.balance - aliceBefore, 0, "Rage quit should work after HALT");
    }

    // ================================================================
    //  Mass rage quit crosses threshold during open checkpoint
    // ================================================================

    function test_integration_massRageQuitCrossesThresholdDuringOpenCheckpoint() public {
        _fundAndClose();
        _warp(CHECKPOINT_INTERVAL + 1);

        // Open checkpoint
        uint256 cpId = governor.openCheckpointWindow();

        // Alice initiates vote
        vm.prank(alice);
        governor.initiateAuditVote(cpId, IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT, 0);

        assertFalse(vault.paused(), "Should not be paused initially");

        // Alice rage quits 30 ETH during the open checkpoint window
        // This should trigger Rule 2 auto-pause (30 > 25% of 100)
        vm.prank(alice);
        rageQuit.rageQuit(30 ether);

        assertTrue(vault.paused(), "Should be auto-paused by Rule 2 during checkpoint");

        // The vote can still be resolved after window closes
        vm.prank(bob);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT);

        _warp(CHECKPOINT_WINDOW + 1);

        // Resolving should work — Rule 2 and Layer 3 can coexist
        governor.resolveCheckpoint(cpId);
        (,,,,,bool resolved,,,,) = governor.checkpoints(cpId);
        assertTrue(resolved, "Checkpoint should resolve despite Rule 2 pause");
    }

    // ================================================================
    //  Pool depletion during active pause
    // ================================================================

    function test_integration_poolDepletionDuringActivePause() public {
        _fundAndClose();

        // Pause the vault
        vm.prank(admin);
        vault.pauseForAudit(30 days);
        assertTrue(vault.paused(), "Should be paused");

        // Holders rage quit during pause until pool is depleted
        vm.prank(alice);
        rageQuit.rageQuit(50 ether);
        vm.prank(bob);
        rageQuit.rageQuit(30 ether);
        vm.prank(carol);
        rageQuit.rageQuit(15 ether);

        // Pool should be below 10% threshold now (5 ETH out of 100)
        vault.checkPoolDepletion();

        assertTrue(vault.terminal(), "Should be terminal");
        assertTrue(vault.paused(), "Pause state should still be set");
        // Terminal + paused is a valid combined state
        // claim() is blocked by both; rage quit still works
    }

    // ================================================================
    //  Pause timeout then auto resume (Rule 1b)
    // ================================================================

    function test_integration_pauseTimeoutThenAutoResume() public {
        _fundAndClose();
        _warp(1000);

        // Governor pauses
        vm.prank(admin);
        vault.pauseForAudit(30 days);

        assertTrue(vault.paused(), "Should be paused");

        // Team can't claim
        vm.prank(team);
        vm.expectRevert();
        vault.claim();

        // Advance past timeout
        _warp(30 days + 1);

        // Anyone can trigger auto-resume
        vault.resumeIfTimedOut();
        assertFalse(vault.paused(), "Should be resumed after timeout");

        // Team can claim again
        vm.prank(team);
        vault.claim();

        assertGt(vault.totalClaimedByTeam(), 0, "Team should be able to claim after resume");
    }

    // ================================================================
    //  Worst case malicious team scenario (§6.6)
    // ================================================================

    function test_integration_worstCaseMaliciousTeam() public {
        // Use a lower rate so team doesn't drain the pool in 10 days
        // 100 ETH pool, 0.0001 ETH/sec = ~8.64 ETH/day, 10 days = ~86.4 ETH claimed
        // That's too much. Use 0.00001 ETH/sec = ~0.864 ETH/day
        uint256 lowRate = 0.00001 ether;
        _fundAndClose(lowRate);

        // T0-T10: Team streams normally for 10 days
        _warp(10 days);

        // Team claims what they've streamed so far
        vm.prank(team);
        vault.claim();
        uint256 teamTake1 = vault.totalClaimedByTeam();

        // T12: Signal monitor detects anomaly (2 warnings)
        vm.startPrank(reporter);
        monitor.reportMetric(2, 35000); // TEAM_OUTFLOW at 3.5x (warning: 3x)
        monitor.reportMetric(4, 2000);  // HHI_INCREASE at 0.20 (warning: 0.15)
        vm.stopPrank();

        _warp(1);
        monitor.evaluate(); // triggers early checkpoint

        // T13: Sharp-eyed holder rage quits immediately
        vm.prank(carol);
        rageQuit.rageQuit(20 ether);

        // T13-T18: More holders follow, crossing 25% threshold
        vm.prank(bob);
        rageQuit.rageQuit(30 ether);

        // Rule 2 should have auto-paused by now (50 ETH cumulative > 25%)
        assertTrue(vault.paused(), "Should be auto-paused after mass rage quit");

        // Team can't claim during pause
        vm.prank(team);
        vm.expectRevert();
        vault.claim();

        // Net result: team's extraction is bounded by ~10 days of streaming
        assertLe(
            teamTake1,
            10 days * lowRate + 1, // +1 for rounding
            "Team extraction should be bounded by streaming before detection"
        );

        // Alice still has shares and can rage quit too
        vm.prank(alice);
        rageQuit.rageQuit(50 ether);

        // Everyone got out, team only took what streamed in the first 10 days
        assertEq(vault.totalClaimedByTeam(), teamTake1, "Team should not have claimed more");
    }
}
