// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LAFTestBase} from "../LAFTestBase.sol";
import {RageQuitModule} from "../../src/RageQuitModule.sol";

/**
 * @title RageQuitTest
 * @notice Unit tests for RageQuitModule (Layer 2) — §7.2 of laf_solidity_design.md.
 */
contract RageQuitTest is LAFTestBase {
    // ================================================================
    //                     PRO-RATA PAYOUT
    // ================================================================

    function test_rageQuit_paysCorrectProportionalShare() public {
        _fundAndClose();

        // Alice has 50/100 = 50% of shares
        uint256 unreleased = vault.unreleasedBalance();
        uint256 expectedPayout = (unreleased * 50 ether) / 100 ether;

        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        rageQuit.rageQuit(50 ether);

        assertEq(alice.balance - aliceBalBefore, expectedPayout, "Should receive 50% of pool");
        assertEq(shareToken.balanceOf(alice), 0, "Shares should be burned");
    }

    function test_rageQuit_sequentialQuittersGetCorrectShare() public {
        _fundAndClose();

        // Alice exits first (50/100 shares, gets 50% of 100 ETH = 50 ETH)
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        rageQuit.rageQuit(50 ether);
        uint256 alicePayout = alice.balance - aliceBefore;
        assertEq(alicePayout, 50 ether, "Alice gets 50 ETH");

        // Bob exits second (30/50 remaining shares, gets 60% of 50 ETH = 30 ETH)
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        rageQuit.rageQuit(30 ether);
        uint256 bobPayout = bob.balance - bobBefore;
        assertEq(bobPayout, 30 ether, "Bob gets 30 ETH from remaining pool");

        // Carol exits last (20/20 remaining shares, gets 100% of 20 ETH = 20 ETH)
        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        rageQuit.rageQuit(20 ether);
        uint256 carolPayout = carol.balance - carolBefore;
        assertEq(carolPayout, 20 ether, "Carol gets the remaining 20 ETH");

        // Vault should be empty
        assertEq(address(vault).balance, 0, "Vault should be empty after all rage quits");
    }

    // ================================================================
    //                   AVAILABLE DURING PAUSE
    // ================================================================

    function test_rageQuit_availableDuringPause() public {
        _fundAndClose();

        // Pause the vault (admin has GOVERNOR_ROLE from setUp)
        vm.prank(admin);
        vault.pauseForAudit(30 days);

        assertTrue(vault.paused(), "Vault should be paused");

        // Alice can still rage quit during pause
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        rageQuit.rageQuit(50 ether);

        assertGt(alice.balance - aliceBefore, 0, "Should receive payout even during pause");
    }

    // ================================================================
    //                  AVAILABLE DURING TERMINAL
    // ================================================================

    function test_rageQuit_availableDuringTerminal() public {
        _fundAndClose();

        // Force terminal: have most people rage quit until pool < 10%
        vm.prank(alice);
        rageQuit.rageQuit(50 ether);
        vm.prank(bob);
        rageQuit.rageQuit(30 ether);

        // Check pool depletion (20 ETH remaining out of 100 = 20%, not terminal yet)
        vault.checkPoolDepletion();

        // Carol exits enough to trigger terminal (need < 10 ETH remaining)
        // Carol has 20 shares out of 20 remaining, representing 20 ETH
        // If carol exits 12 shares: 12/20 * 20 = 12 ETH out, leaving 8 ETH (< 10%)
        vm.prank(carol);
        rageQuit.rageQuit(12 ether);

        vault.checkPoolDepletion();
        assertTrue(vault.terminal(), "Should be terminal");

        // Carol can still exit remaining shares
        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        rageQuit.rageQuit(8 ether);

        assertGt(carol.balance - carolBefore, 0, "Should receive payout in terminal state");
    }

    // ================================================================
    //                RULE 2: 25% THRESHOLD AUTO-PAUSE
    // ================================================================

    function test_rageQuit_crossing25PercentThreshold_autoPausesVault() public {
        _fundAndClose();

        // Open a checkpoint window first so Rule 2 has a baseline
        // Need to advance past the initial checkpoint interval
        _warp(CHECKPOINT_INTERVAL + 1);
        governor.openCheckpointWindow();

        // Pool is 100 ETH, 25% threshold = 25 ETH
        // Alice rage quits 30 ETH worth, crossing the threshold
        assertFalse(vault.paused(), "Should not be paused yet");

        vm.prank(alice);
        rageQuit.rageQuit(30 ether);

        // The vault should auto-pause because 30 > 25 (25% of 100)
        assertTrue(vault.paused(), "Should be auto-paused after 25% threshold breach");
    }

    function test_rageQuit_belowThreshold_doesNotPause() public {
        _fundAndClose();

        _warp(CHECKPOINT_INTERVAL + 1);
        governor.openCheckpointWindow();

        // Carol rage quits 20 ETH, below 25% threshold
        vm.prank(carol);
        rageQuit.rageQuit(20 ether);

        assertFalse(vault.paused(), "Should not pause for 20% of pool");
    }

    // ================================================================
    //                      ERROR CASES
    // ================================================================

    function test_rageQuit_revertsOnZeroShares() public {
        _fundAndClose();

        vm.prank(alice);
        vm.expectRevert(RageQuitModule.ZeroShares.selector);
        rageQuit.rageQuit(0);
    }

    function test_rageQuit_revertsOnInsufficientShares() public {
        _fundAndClose();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                RageQuitModule.InsufficientShares.selector,
                100 ether,
                50 ether
            )
        );
        rageQuit.rageQuit(100 ether);
    }

    // ================================================================
    //                      PARTIAL EXIT
    // ================================================================

    function test_rageQuit_partialExit() public {
        _fundAndClose();

        // Alice exits 25 of her 50 shares (25%)
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        rageQuit.rageQuit(25 ether);

        assertEq(alice.balance - aliceBefore, 25 ether, "Should get 25% of pool");
        assertEq(shareToken.balanceOf(alice), 25 ether, "Should have 25 shares left");
    }
}
