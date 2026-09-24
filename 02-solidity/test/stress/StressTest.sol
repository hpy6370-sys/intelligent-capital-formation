// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LAFTestBase} from "../LAFTestBase.sol";
import {IQuadraticGovernor} from "../../src/interfaces/IQuadraticGovernor.sol";

/**
 * @title StressTest
 * @notice Stress scenarios from Proposal v3 §7.3 — §7.6 of laf_solidity_design.md.
 */
contract StressTest is LAFTestBase {
    // ================================================================
    //  Bank run: 60% of holders rage quit within 48 hours
    // ================================================================

    function test_stress_bankRun() public {
        _fundAndClose();

        // Open checkpoint so Rule 2 has a baseline
        _warp(CHECKPOINT_INTERVAL + 1);
        governor.openCheckpointWindow();

        // Simulate bank run: alice (50%) and bob (30%) exit = 80% total
        // but split across multiple transactions within 48 hours

        // Alice exits in chunks
        vm.startPrank(alice);
        rageQuit.rageQuit(10 ether);
        rageQuit.rageQuit(10 ether);
        rageQuit.rageQuit(10 ether);
        vm.stopPrank();

        // After 30 ETH exit (30% of pool), Rule 2 should fire
        assertTrue(vault.paused(), "Rule 2 should auto-pause after 30% exits");

        // But alice can still exit the rest even during pause
        vm.prank(alice);
        rageQuit.rageQuit(20 ether);

        // Bob can also exit during pause
        vm.prank(bob);
        rageQuit.rageQuit(30 ether);

        // Carol is the last one, she can still exit
        vm.prank(carol);
        rageQuit.rageQuit(20 ether);

        // Vault should be empty-ish, verify no DoS
        assertEq(shareToken.totalSupply(), 0, "All shares should be burned");
        assertLe(address(vault).balance, 1, "Vault should be essentially empty");
    }

    // ================================================================
    //  Sybil checkpoint: adversary splits tokens across 100 wallets
    // ================================================================

    function test_stress_sybilCheckpoint() public {
        // Create a whale and many sybil wallets
        address whale = makeAddr("whale");
        vm.deal(whale, 200 ether);

        // Whale deposits 90 ETH directly
        vm.prank(whale);
        vault.deposit{value: 90 ether}();

        // Sybil: same 10 ETH split across 100 wallets (0.1 ETH each)
        address[100] memory sybils;
        for (uint256 i = 0; i < 100; i++) {
            sybils[i] = makeAddr(string(abi.encodePacked("sybil", i)));
            vm.deal(sybils[i], 1 ether);
            vm.prank(sybils[i]);
            vault.deposit{value: 0.1 ether}();
        }

        vm.prank(admin);
        vault.closeFunding(RATE_PER_SECOND);
        _warp(CHECKPOINT_INTERVAL + 1);

        uint256 cpId = governor.openCheckpointWindow();

        // Sybil initiates vote
        vm.prank(sybils[0]);
        governor.initiateAuditVote(cpId, IQuadraticGovernor.CheckpointAction.HALT, 0);

        // All 100 sybils vote HALT
        uint256 sybilTotalWeight = 0;
        for (uint256 i = 0; i < 100; i++) {
            uint256 weight = governor.votingPowerOf(sybils[i], block.number - 2);
            if (weight > 0) {
                vm.prank(sybils[i]);
                governor.vote(cpId, IQuadraticGovernor.CheckpointAction.HALT);
                sybilTotalWeight += weight;
            }
        }

        // Whale votes CONTINUE
        uint256 whaleWeight = governor.votingPowerOf(whale, block.number - 2);
        vm.prank(whale);
        governor.vote(cpId, IQuadraticGovernor.CheckpointAction.CONTINUE);

        // sqrt(0.1 ETH) * 100 sybils vs sqrt(90 ETH) * 1 whale
        // sqrt(0.1e18) ~= 316227766 per sybil, * 100 = 31622776601
        // sqrt(90e18) ~= 9486832980 for whale
        // Sybils collectively: ~31.6e9, Whale: ~9.5e9
        // Sybils have MORE sqrt-weighted power than whale despite holding less capital!
        // This is the known Limitation 4 — document, don't claim solved

        _warp(CHECKPOINT_WINDOW + 1);
        governor.resolveCheckpoint(cpId);

        // The important assertion: the system doesn't crash or revert
        // Whether HALT wins or not depends on quorum/majority rules
        (,,,,,bool resolved,,,,) = governor.checkpoints(cpId);
        assertTrue(resolved, "Checkpoint should resolve even under sybil attack");
    }

    // ================================================================
    //  Signal gaming: metrics artificially kept healthy
    // ================================================================

    function test_stress_signalGaming() public {
        _fundAndClose();

        // Adversary controls the reporter and reports healthy metrics
        vm.startPrank(reporter);
        monitor.reportMetric(0, 500);   // TVL only declined 5% (below 40% warning)
        monitor.reportMetric(1, 1000);  // Active addresses only declined 10%
        monitor.reportMetric(2, 5000);  // Team outflow only 0.5x (below 3x warning)
        monitor.reportMetric(3, 1000);  // Commit activity: 10 days (below 60d warning)
        monitor.reportMetric(4, 500);   // HHI only 0.05 (below 0.15 warning)
        vm.stopPrank();

        // Evaluate should NOT trigger
        bool triggered = monitor.evaluate();
        assertFalse(triggered, "Should not trigger with gamed metrics");

        assertEq(monitor.warningCount(), 0, "No warnings with gamed metrics");
        assertEq(monitor.criticalCount(), 0, "No criticals with gamed metrics");

        // System degrades to 90-day scheduled checkpoint baseline
        // After interval, anyone can still open a regular checkpoint
        _warp(CHECKPOINT_INTERVAL + 1);
        uint256 cpId = governor.openCheckpointWindow();

        // Verify the regular checkpoint mechanism still works
        (uint256 windowStart,,,,,,,,,) = governor.checkpoints(cpId);
        assertGt(windowStart, 0, "Regular checkpoint should work despite signal gaming");
    }

    // ================================================================
    //  Cascade: Layer 4 trigger during open checkpoint + rage quit pressure
    // ================================================================

    function test_stress_cascade() public {
        _fundAndClose();
        _warp(CHECKPOINT_INTERVAL + 1);

        // Regular checkpoint opens
        uint256 cpId1 = governor.openCheckpointWindow();

        // During the open checkpoint, signal monitor also detects problems
        vm.startPrank(reporter);
        monitor.reportMetric(0, 7500); // TVL critical (70%)
        vm.stopPrank();

        // Evaluate — should NOT open a new checkpoint since one is already open
        // (Rule 3: no-op if window already open)
        bool triggered = monitor.evaluate();
        assertFalse(triggered, "Should not trigger when window already open");

        // Simultaneously, rage quit pressure
        vm.prank(alice);
        rageQuit.rageQuit(30 ether);

        // Rule 2 auto-pause fires
        assertTrue(vault.paused(), "Rule 2 should fire during cascade");

        // The checkpoint can still be resolved after the window
        // (nobody initiates audit vote — defaults to CONTINUE)

        _warp(CHECKPOINT_WINDOW + 1);
        governor.resolveCheckpoint(cpId1);

        // No infinite loop, everything resolved
        (,,,,,bool resolved,,,,) = governor.checkpoints(cpId1);
        assertTrue(resolved, "Checkpoint should resolve in cascade scenario");

        // Rule 1 bounded pause prevents infinite feedback
        assertTrue(vault.paused(), "Vault should still be paused (Rule 2)");

        // But auto-resume will eventually kick in
        _warp(MAX_PAUSE_DURATION + 1);
        vault.resumeIfTimedOut();
        assertFalse(vault.paused(), "Should auto-resume after max pause");
    }

    // ================================================================
    //  Governance apathy: <5% participation across several checkpoints
    // ================================================================

    function test_stress_governanceApathy() public {
        _fundAndClose();

        // Run 3 consecutive checkpoints where nobody votes
        for (uint256 i = 0; i < 3; i++) {
            _warp(CHECKPOINT_INTERVAL + 1);

            uint256 cpId = governor.openCheckpointWindow();

            // Window opens, nobody initiates audit vote
            _warp(CHECKPOINT_WINDOW + 1);

            // Resolve — defaults to CONTINUE
            governor.resolveCheckpoint(cpId);

            // Verify it resolved correctly
            (,,,,,bool resolved,,,,) = governor.checkpoints(cpId);
            assertTrue(resolved, "Apathetic checkpoint should resolve");
        }

        // Verify vault state is unchanged after 3 apathetic checkpoints
        assertFalse(vault.paused(), "Should not be paused after apathetic checkpoints");
        assertFalse(vault.terminal(), "Should not be terminal");
        assertGt(vault.ratePerSecond(), 0, "Rate should be unchanged");

        // Stream should still work correctly
        _warp(1000);
        uint256 claimable = vault.claimable();
        assertGt(claimable, 0, "Stream should still work after apathetic checkpoints");

        // Team can still claim
        vm.prank(team);
        vault.claim();
        assertGt(vault.totalClaimedByTeam(), 0, "Team should be able to claim");
    }
}
