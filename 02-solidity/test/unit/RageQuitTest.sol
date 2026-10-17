// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LAFTestBase} from "../LAFTestBase.sol";
import {RageQuitModule} from "../../src/RageQuitModule.sol";
import {LAFVault} from "../../src/LAFVault.sol";
import {LAFShareToken} from "../../src/LAFShareToken.sol";

/// @dev Holder contract that records the vault state when its payout arrives.
contract PauseObserver {
    LAFVault public immutable vault;
    RageQuitModule public immutable rageQuit;
    bool public received;
    bool public sawPaused;

    constructor(LAFVault _vault, RageQuitModule _rageQuit) payable {
        vault = _vault;
        rageQuit = _rageQuit;
    }

    function deposit(uint256 amount) external {
        vault.deposit{value: amount}();
    }

    function quit(uint256 shares) external {
        rageQuit.rageQuit(shares);
    }

    receive() external payable {
        received = true;
        sawPaused = vault.paused();
    }
}

/**
 * @title RageQuitTest
 * @notice Unit tests for RageQuitModule (Layer 2) — §7.2 of laf_solidity_design.md.
 */
contract RageQuitTest is LAFTestBase {
    // ================================================================
    //                 EXIT BEFORE FUNDING CLOSES
    // ================================================================

    function test_rageQuitBeforeFundingClosesReturnsTheDeposit() public {
        vm.prank(alice);
        vault.deposit{value: 50 ether}();
        vm.prank(bob);
        vault.deposit{value: 30 ether}();

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        rageQuit.rageQuit(20 ether);

        assertEq(alice.balance - aliceBefore, 20 ether, "exact deposit returned");
        assertEq(vault.totalDeposited(), 60 ether, "raise shrinks");
        assertEq(vault.totalExitedViaRageQuit(), 0, "not a post-close exit");
        assertEq(shareToken.totalSupply(), 60 ether);
        assertEq(vault.unreleasedBalance(), 60 ether);
        assertEq(address(vault).balance, 60 ether);
        assertFalse(vault.paused(), "Rule 2 does not apply before the stream");

        // The initial-rate bound uses the net raise.
        uint256 maxRate = 60 ether / (MINIMUM_VESTING_DURATION * 2);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(LAFVault.RateTooHigh.selector, maxRate + 1, maxRate));
        vault.closeFunding(maxRate + 1);
        vm.prank(admin);
        vault.closeFunding(maxRate);
        assertEq(vault.initialRatePerSecond(), maxRate);
    }

    function test_fullWithdrawalBeforeCloseLeavesNothingToClose() public {
        vm.prank(alice);
        vault.deposit{value: 10 ether}();
        vm.prank(alice);
        rageQuit.rageQuit(10 ether);

        assertEq(vault.totalDeposited(), 0);
        vm.prank(admin);
        vm.expectRevert(LAFVault.NoDeposits.selector);
        vault.closeFunding(RATE_PER_SECOND);
    }

    function test_rule2PauseIsFinalBeforeThePayoutIsSent() public {
        PauseObserver observer = new PauseObserver{value: 40 ether}(vault, rageQuit);
        observer.deposit(40 ether);
        vm.prank(alice);
        vault.deposit{value: 60 ether}();
        vm.prank(admin);
        vault.closeFunding(RATE_PER_SECOND);

        // 30 of 100 ETH unreleased crosses the 25% alarm.
        observer.quit(30 ether);
        assertTrue(observer.received(), "payout delivered");
        assertTrue(observer.sawPaused(), "pause applied before the transfer");
        assertTrue(vault.paused());
    }

    function test_constructorRejectsZeroDependencies() public {
        vm.expectRevert(RageQuitModule.ZeroAddress.selector);
        new RageQuitModule(vault, LAFShareToken(address(0)));

        vm.expectRevert(RageQuitModule.ZeroAddress.selector);
        new RageQuitModule(LAFVault(payable(address(0))), shareToken);
    }

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

        // Pause the vault through its configured governor module.
        vm.prank(address(governor));
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

        // Pool is 100 ETH, 25% threshold = 25 ETH
        // Alice rage quits before any checkpoint, crossing the threshold.
        assertFalse(vault.paused(), "Should not be paused yet");

        vm.prank(alice);
        rageQuit.rageQuit(30 ether);

        // The vault should auto-pause because 30 > 25 (25% of 100)
        assertTrue(vault.paused(), "Should be auto-paused after 25% threshold breach");
    }

    function test_rageQuit_belowThreshold_doesNotPause() public {
        _fundAndClose();

        // Carol rage quits 20 ETH, below 25% threshold
        vm.prank(carol);
        rageQuit.rageQuit(20 ether);

        assertFalse(vault.paused(), "Should not pause for 20% of pool");
    }

    function test_rageQuitLookbackExpiresOldExits() public {
        _fundAndClose();
        vm.prank(alice);
        rageQuit.rageQuit(20 ether);
        assertEq(vault.recentRageQuit(), 20 ether);
        assertFalse(vault.paused());

        _warp(31 days);
        assertEq(vault.recentRageQuit(), 0, "old exits leave the lookback");
        vm.prank(bob);
        rageQuit.rageQuit(20 ether);
        assertEq(vault.recentRageQuit(), 20 ether);
        assertFalse(vault.paused(), "expired exits do not accumulate forever");
    }

    function test_rageQuitAlarmRemainsActiveAfterCheckpointResolution() public {
        _fundAndClose();
        _warp(CHECKPOINT_INTERVAL + 1);
        uint256 id = governor.openCheckpointWindow();
        _warp(CHECKPOINT_WINDOW + 1);
        governor.resolveCheckpoint(id);

        vm.prank(alice);
        rageQuit.rageQuit(30 ether);
        assertTrue(vault.paused(), "a resolved checkpoint cannot disable Rule 2");
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
