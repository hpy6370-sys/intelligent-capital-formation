// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LAFTestBase} from "../LAFTestBase.sol";
import {LAFVault} from "../../src/LAFVault.sol";
import {QuadraticGovernor} from "../../src/QuadraticGovernor.sol";
import {IQuadraticGovernor} from "../../src/interfaces/IQuadraticGovernor.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title QuadraticGovernorTest
 * @notice Unit tests for Layer 3 (QuadraticGovernor), section 7.3 of laf_solidity_design.md.
 *
 * Default parameters from LAFTestBase: 90-day interval, 14-day window, quorum >50%,
 * majority 50%, 30-day default pause response period, 30-day signal rate limit.
 * Default holders from _fundAndClose(): alice 50 ETH, bob 30 ETH, carol 20 ETH
 * (linear weights 50/30/20 ETH; quorum is 50.01 ETH of 100 ETH).
 *
 * The snapshot block is `block.number - 1`, so every test rolls at least one
 * block between minting shares and opening a window.
 */
contract QuadraticGovernorTest is LAFTestBase {
    IQuadraticGovernor.CheckpointAction constant CONTINUE = IQuadraticGovernor.CheckpointAction.CONTINUE;
    IQuadraticGovernor.CheckpointAction constant INCREASE_RATE = IQuadraticGovernor.CheckpointAction.INCREASE_RATE;
    IQuadraticGovernor.CheckpointAction constant DECREASE_RATE = IQuadraticGovernor.CheckpointAction.DECREASE_RATE;
    IQuadraticGovernor.CheckpointAction constant PAUSE_FOR_AUDIT = IQuadraticGovernor.CheckpointAction.PAUSE_FOR_AUDIT;
    IQuadraticGovernor.CheckpointAction constant HALT = IQuadraticGovernor.CheckpointAction.HALT;

    // ---- Helpers ----

    /// @dev Warp past the interval (also rolls a block for the snapshot) and open a scheduled window.
    function _openScheduled() internal returns (uint256 id) {
        _warp(CHECKPOINT_INTERVAL + 1);
        id = governor.openCheckpointWindow();
    }

    function _initiate(address who, uint256 id, IQuadraticGovernor.CheckpointAction action, uint256 delta) internal {
        vm.prank(who);
        governor.initiateAuditVote(id, action, delta);
    }

    function _vote(address who, uint256 id, IQuadraticGovernor.CheckpointAction action) internal {
        vm.prank(who);
        governor.vote(id, action);
    }

    /// @dev Warp past the window end and resolve.
    function _closeAndResolve(uint256 id) internal {
        _warp(CHECKPOINT_WINDOW + 1);
        governor.resolveCheckpoint(id);
    }

    /// @dev Full checkpoint where all three default holders vote for `action`.
    function _unanimousCheckpoint(IQuadraticGovernor.CheckpointAction action)
        internal
        returns (uint256 id)
    {
        id = _openScheduled();
        _initiate(alice, id, action, 0);
        _vote(alice, id, action);
        _vote(bob, id, action);
        _vote(carol, id, action);
        _closeAndResolve(id);
    }

    function _resolvedAction(uint256 id) internal view returns (IQuadraticGovernor.CheckpointAction action) {
        (,,,,,, action,,,) = governor.checkpoints(id);
    }

    function _quorumThreshold() internal view returns (uint256) {
        uint256 supply = shareToken.totalSupply();
        return (supply / 10_000) * QUORUM_BPS
            + ((supply % 10_000) * QUORUM_BPS + 9_999) / 10_000;
    }

    // ================================================================
    //  Linear snapshot weight cannot be increased by splitting wallets.
    // ================================================================

    function test_votingWeight_isLinearBalance() public {
        vm.prank(alice);
        vault.deposit{value: 100 ether}();
        vm.prank(bob);
        vault.deposit{value: 1 ether}();
        vm.prank(admin);
        vault.closeFunding(RATE_PER_SECOND);

        _warp(CHECKPOINT_INTERVAL + 1);
        uint256 id = governor.openCheckpointWindow();
        (,,, uint256 snapshotBlock,,,,,,) = governor.checkpoints(id);
        assertEq(snapshotBlock, block.number - 1, "snapshot is the previous block");

        uint256 wAlice = governor.votingPowerOf(alice, snapshotBlock);
        uint256 wBob = governor.votingPowerOf(bob, snapshotBlock);

        assertEq(shareToken.balanceOf(alice), 100 * shareToken.balanceOf(bob), "balances differ 100x");
        assertEq(wAlice, 100 ether, "weight equals snapshot shares");
        assertEq(wBob, 1 ether);
        assertEq(wAlice, 100 * wBob);

        // Weight recorded on vote matches votingPowerOf
        _initiate(alice, id, HALT, 0);
        vm.expectEmit(true, true, false, true, address(governor));
        emit IQuadraticGovernor.Voted(id, alice, HALT, wAlice);
        _vote(alice, id, HALT);
        assertEq(governor.tallies(id, HALT), wAlice);
    }

    function test_transferredSharesHaveSnapshotVotes() public {
        _fundAndClose();
        address transferee = makeAddr("transferee");
        vm.prank(alice);
        shareToken.transfer(transferee, 10 ether);
        assertEq(shareToken.delegates(transferee), transferee);

        uint256 id = _openScheduled();
        (,,, uint256 snapshotBlock,,,,,,) = governor.checkpoints(id);
        assertEq(governor.votingPowerOf(transferee, snapshotBlock), 10 ether);
        _initiate(transferee, id, HALT, 0);
        _vote(transferee, id, HALT);
        assertEq(governor.tallies(id, HALT), 10 ether);
    }

    // ================================================================
    //  7.3 #2  test_openCheckpointWindow_revertsBeforeIntervalElapsed
    //  90-day interval measured from the previous resolution
    // ================================================================

    function test_openCheckpointWindow_revertsBeforeIntervalElapsed() public {
        _fundAndClose();
        uint256 first = _openScheduled();
        _closeAndResolve(first);
        uint256 lastEnd = governor.lastCheckpointEnd();
        assertEq(lastEnd, block.timestamp, "lastCheckpointEnd set at resolution");

        // Immediately after resolution
        vm.expectRevert(QuadraticGovernor.IntervalNotElapsed.selector);
        governor.openCheckpointWindow();

        // One second short of the interval
        _warp(CHECKPOINT_INTERVAL - 1);
        assertEq(block.timestamp, lastEnd + CHECKPOINT_INTERVAL - 1);
        vm.expectRevert(QuadraticGovernor.IntervalNotElapsed.selector);
        governor.openCheckpointWindow();

        // Exactly at the interval boundary the gate opens
        _warp(1);
        uint256 second = governor.openCheckpointWindow();
        assertEq(second, first + 1);
        assertEq(governor.nextCheckpointId(), 2);
    }

    // ================================================================
    //  First scheduled window begins after the first full interval.
    // ================================================================

    function test_firstWindow_requiresInterval_andIs14DaysLong() public {
        _fundAndClose();
        assertEq(governor.lastCheckpointEnd(), 0);

        _warp(1);
        vm.expectRevert(QuadraticGovernor.IntervalNotElapsed.selector);
        governor.openCheckpointWindow();
        _warp(CHECKPOINT_INTERVAL - 1);
        vm.expectEmit(true, false, false, true, address(governor));
        emit IQuadraticGovernor.CheckpointWindowOpened(0, IQuadraticGovernor.CheckpointTrigger.SCHEDULED);
        uint256 id = governor.openCheckpointWindow();
        assertEq(id, 0);

        (uint256 windowStart, uint256 windowEnd, IQuadraticGovernor.CheckpointTrigger trigger,,,,,,,) =
            governor.checkpoints(id);
        assertEq(windowStart, block.timestamp);
        assertEq(windowEnd - windowStart, CHECKPOINT_WINDOW, "window length is 14 days");
        assertEq(uint256(trigger), uint256(IQuadraticGovernor.CheckpointTrigger.SCHEDULED));

        // Vault was told to snapshot for Rule 2
        assertEq(vault.currentWindowId(), id);
        assertEq(vault.unreleasedBalanceAtOpen(), vault.unreleasedBalance());
    }

    // ================================================================
    //  7.3 #3  test_windowCloses_asContinue_ifAuditNeverInitiated
    //  default-continue semantics
    // ================================================================

    function test_windowCloses_asContinue_ifAuditNeverInitiated() public {
        _fundAndClose();
        uint256 rateBefore = vault.ratePerSecond();
        uint256 id = _openScheduled();

        _warp(CHECKPOINT_WINDOW + 1);
        vm.expectEmit(true, false, false, true, address(governor));
        emit IQuadraticGovernor.CheckpointResolved(id, CONTINUE);
        governor.resolveCheckpoint(id);

        (,,,, bool auditInitiated, bool resolved,,,, uint256 totalVoteWeight) = governor.checkpoints(id);
        assertFalse(auditInitiated);
        assertTrue(resolved);
        assertEq(totalVoteWeight, 0);
        assertEq(uint256(_resolvedAction(id)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), rateBefore, "stream untouched");
        assertFalse(vault.paused());
    }

    // ================================================================
    //  7.3 #4  test_initiateAuditVote_onlyOncePerWindow
    // ================================================================

    function test_initiateAuditVote_onlyOncePerWindow() public {
        _fundAndClose();
        uint256 id = _openScheduled();

        // Voting before initiation is rejected
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.AuditNotInitiated.selector, id));
        governor.vote(id, HALT);

        // Non-holder cannot initiate
        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(QuadraticGovernor.NotAShareHolder.selector);
        governor.initiateAuditVote(id, HALT, 0);

        vm.expectEmit(true, false, false, true, address(governor));
        emit IQuadraticGovernor.AuditVoteInitiated(id, DECREASE_RATE, alice);
        _initiate(alice, id, DECREASE_RATE, 0);

        // Second initiation in the same window, by anyone, is rejected
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.AuditAlreadyInitiated.selector, id));
        governor.initiateAuditVote(id, HALT, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.AuditAlreadyInitiated.selector, id));
        governor.initiateAuditVote(id, HALT, 0);

        // Proposal fields are the first initiator's
        (,,,, bool auditInitiated,,, IQuadraticGovernor.CheckpointAction proposed, uint256 delta,) =
            governor.checkpoints(id);
        assertTrue(auditInitiated);
        assertEq(uint256(proposed), uint256(DECREASE_RATE));
        assertEq(delta, 0);
    }

    // ================================================================
    //  7.3 #5  test_vote_oneVotePerAddressPerCheckpoint
    // ================================================================

    function test_vote_oneVotePerAddressPerCheckpoint() public {
        _fundAndClose();
        uint256 id = _openScheduled();
        _initiate(alice, id, HALT, 0);

        _vote(alice, id, HALT);
        uint256 tallyAfterFirst = governor.tallies(id, HALT);
        assertTrue(governor.hasVoted(id, alice));

        // Same action again
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.AlreadyVoted.selector, id));
        governor.vote(id, HALT);

        // Different action, still the same address
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.AlreadyVoted.selector, id));
        governor.vote(id, CONTINUE);

        assertEq(governor.tallies(id, HALT), tallyAfterFirst, "tally unchanged by rejected votes");
        assertEq(governor.tallies(id, CONTINUE), 0);
        (,,,,,,,,, uint256 totalVoteWeight) = governor.checkpoints(id);
        assertEq(totalVoteWeight, tallyAfterFirst);

        // The lock is per checkpoint: alice can vote in the next one
        _closeAndResolve(id);
        uint256 next = _openScheduled();
        _initiate(alice, next, HALT, 0);
        _vote(alice, next, HALT);
        assertTrue(governor.hasVoted(next, alice));
    }

    // ================================================================
    //  7.3 #6  test_resolveCheckpoint_defaultsToContinue_ifQuorumNotMet
    //  Limitation 5. A 1 ETH holder out of 101 ETH is below the >50% supply quorum.
    // ================================================================

    function test_resolveCheckpoint_defaultsToContinue_ifQuorumNotMet() public {
        address dave = makeAddr("dave");
        vm.deal(dave, 1 ether);
        vm.prank(dave);
        vault.deposit{value: 1 ether}();
        _fundAndClose();
        uint256 rateBefore = vault.ratePerSecond();

        uint256 id = _openScheduled();
        _initiate(dave, id, HALT, 0);
        _vote(dave, id, HALT);

        (,,,,,,,,, uint256 totalVoteWeight) = governor.checkpoints(id);
        assertEq(totalVoteWeight, 1 ether);
        assertLt(totalVoteWeight, _quorumThreshold(), "dave alone is below quorum");

        _closeAndResolve(id);

        // HALT had 100% of cast weight but quorum failed, so nothing happens
        assertEq(uint256(_resolvedAction(id)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), rateBefore, "HALT not applied");
        assertFalse(vault.paused());
    }

    // ================================================================
    //  A 50/50 tie between the proposal and CONTINUE does not pass.
    //  falls back to CONTINUE (strict > in _findWinner)
    // ================================================================

    function test_resolveCheckpoint_pluralityBelowMajority_isContinue() public {
        _fundAndClose();
        uint256 rateBefore = vault.ratePerSecond();

        // Alice votes HALT with 50 shares; Bob and Carol vote CONTINUE with 50.
        uint256 id = _openScheduled();
        _initiate(alice, id, HALT, 0);
        _vote(alice, id, HALT);
        _vote(bob, id, CONTINUE);
        _vote(carol, id, CONTINUE);

        (,,,,,,,,, uint256 total) = governor.checkpoints(id);
        assertGe(total, _quorumThreshold(), "quorum is met");
        uint256 best = governor.tallies(id, HALT);
        assertEq(best, governor.tallies(id, CONTINUE));
        assertLe(best, (total * MAJORITY_BPS) / 10000, "plurality but not majority");

        _closeAndResolve(id);
        assertEq(uint256(_resolvedAction(id)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), rateBefore);
        assertFalse(vault.paused());

        // Alice and Bob together carry 80% of the snapshot supply.
        uint256 id2 = _openScheduled();
        _initiate(alice, id2, HALT, 0);
        _vote(alice, id2, HALT);
        _vote(bob, id2, HALT);
        _vote(carol, id2, CONTINUE);
        _closeAndResolve(id2);
        assertEq(uint256(_resolvedAction(id2)), uint256(HALT));
        assertEq(vault.ratePerSecond(), 0);
    }

    // ================================================================
    //  7.3 #7  test_resolveCheckpoint_appliesEachAction
    //  CONTINUE / INCREASE_RATE / DECREASE_RATE / PAUSE_FOR_AUDIT / HALT,
    //  run back to back on one vault so each effect is observed on state.
    // ================================================================

    function test_resolveCheckpoint_appliesEachAction() public {
        _fundAndClose();
        uint256 rate0 = vault.ratePerSecond();
        assertEq(rate0, RATE_PER_SECOND);

        // CONTINUE: no-op
        uint256 idContinue = _unanimousCheckpoint(CONTINUE);
        assertEq(uint256(_resolvedAction(idContinue)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), rate0, "CONTINUE leaves rate");
        assertFalse(vault.paused(), "CONTINUE leaves pause state");

        // INCREASE_RATE: rate += the protocol-defined half-initial step.
        uint256 up = RATE_PER_SECOND / 2;
        uint256 idInc = _unanimousCheckpoint(INCREASE_RATE);
        assertEq(uint256(_resolvedAction(idInc)), uint256(INCREASE_RATE));
        assertEq(vault.ratePerSecond(), rate0 + up, "INCREASE_RATE adds delta");

        // DECREASE_RATE: rate -= delta
        uint256 down = RATE_PER_SECOND / 2;
        uint256 idDec = _unanimousCheckpoint(DECREASE_RATE);
        assertEq(uint256(_resolvedAction(idDec)), uint256(DECREASE_RATE));
        assertEq(vault.ratePerSecond(), rate0 + up - down, "DECREASE_RATE subtracts delta");

        // PAUSE_FOR_AUDIT: vault paused with the governor's default response period
        uint256 idPause = _unanimousCheckpoint(PAUSE_FOR_AUDIT);
        assertEq(uint256(_resolvedAction(idPause)), uint256(PAUSE_FOR_AUDIT));
        assertTrue(vault.paused(), "PAUSE_FOR_AUDIT pauses the vault");
        assertEq(uint256(vault.pausedReason()), uint256(LAFVault.PauseReason.AUDIT_RESOLUTION));
        assertEq(vault.pauseResponsePeriod(), DEFAULT_PAUSE_PERIOD, "uses defaultPauseResponsePeriod");
        assertEq(vault.pausedAt(), block.timestamp);
        assertEq(vault.ratePerSecond(), rate0, "PAUSE_FOR_AUDIT does not touch the rate");

        // HALT: rate set to 0 (pause state is left as is)
        uint256 idHalt = _unanimousCheckpoint(HALT);
        assertEq(uint256(_resolvedAction(idHalt)), uint256(HALT));
        assertEq(vault.ratePerSecond(), 0, "HALT zeroes the rate");
        assertTrue(vault.paused(), "HALT does not resume");
    }

    function test_increaseAtRateCapStillResolves() public {
        _fundAndClose();
        uint256 maximum = RATE_PER_SECOND * 2;

        // A partial increase at the ceiling must be capped, not reverted.
        vm.prank(admin);
        vault.setStreamRate(maximum - 1);
        uint256 first = _unanimousCheckpoint(INCREASE_RATE);
        assertEq(uint256(_resolvedAction(first)), uint256(INCREASE_RATE));
        assertEq(vault.ratePerSecond(), maximum);

        // A further increase is a no-op, but the checkpoint still closes.
        uint256 second = _unanimousCheckpoint(INCREASE_RATE);
        assertEq(uint256(_resolvedAction(second)), uint256(INCREASE_RATE));
        assertEq(vault.ratePerSecond(), maximum);
        assertTrue(governor.lastCheckpointEnd() > 0);
    }

    function test_pauseVoteDuringExistingPauseResolvesWithoutExtendingDeadline() public {
        _fundAndClose();

        vm.prank(admin);
        vault.pauseForAudit(MAX_PAUSE_DURATION);
        uint256 pauseAt = vault.pausedAt();
        uint256 pausePeriod = vault.pauseResponsePeriod();

        _warp(1);
        vm.prank(address(monitor));
        uint256 id = governor.triggerEarlyCheckpoint();
        _initiate(alice, id, PAUSE_FOR_AUDIT, 0);
        _vote(alice, id, PAUSE_FOR_AUDIT);
        _vote(bob, id, PAUSE_FOR_AUDIT);
        _vote(carol, id, PAUSE_FOR_AUDIT);
        _closeAndResolve(id);

        assertEq(uint256(_resolvedAction(id)), uint256(PAUSE_FOR_AUDIT));
        assertTrue(vault.paused());
        assertEq(vault.pausedAt(), pauseAt, "vote cannot reset an active pause");
        assertEq(vault.pauseResponsePeriod(), pausePeriod, "vote cannot extend deadline");
    }

    // ================================================================
    //  7.3 #8  test_resolveCheckpoint_cannotExecuteTwice
    //  Also covers the window-still-open guard (timestamp <= windowEnd)
    // ================================================================

    function test_resolveCheckpoint_cannotExecuteTwice() public {
        _fundAndClose();
        uint256 id = _openScheduled();
        (, uint256 windowEnd,,,,,,,,) = governor.checkpoints(id);

        // Inside the window
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.WindowStillOpen.selector, id));
        governor.resolveCheckpoint(id);

        // At windowEnd exactly, still open
        vm.warp(windowEnd);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.WindowStillOpen.selector, id));
        governor.resolveCheckpoint(id);

        // One second later it resolves
        vm.warp(windowEnd + 1);
        governor.resolveCheckpoint(id);
        (,,,,, bool resolved,,,,) = governor.checkpoints(id);
        assertTrue(resolved);
        uint256 lastEnd = governor.lastCheckpointEnd();

        // Second resolution rejected, at once and much later
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.AlreadyResolved.selector, id));
        governor.resolveCheckpoint(id);
        _warp(365 days);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.AlreadyResolved.selector, id));
        governor.resolveCheckpoint(id);
        assertEq(governor.lastCheckpointEnd(), lastEnd, "lastCheckpointEnd not moved by rejected calls");

        // A never-opened id has windowStart == 0 and cannot be voted on
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.WindowNotOpen.selector, 99));
        governor.vote(99, HALT);
    }

    // ================================================================
    //  Extra C  vote / initiate after the window closed revert
    // ================================================================

    function test_vote_revertsAfterWindowClosed() public {
        _fundAndClose();
        uint256 id = _openScheduled();
        _initiate(alice, id, HALT, 0);
        _vote(alice, id, HALT);
        (, uint256 windowEnd,,,,,,,,) = governor.checkpoints(id);

        // Last second of the window still accepts votes
        vm.warp(windowEnd);
        _vote(bob, id, HALT);

        // First second after the window: closed, whether or not resolved yet
        vm.warp(windowEnd + 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.WindowNotOpen.selector, id));
        governor.vote(id, HALT);

        governor.resolveCheckpoint(id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.WindowNotOpen.selector, id));
        governor.vote(id, HALT);

        // initiateAuditVote goes through the same guard
        uint256 id2 = _openScheduled();
        _warp(CHECKPOINT_WINDOW + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.WindowNotOpen.selector, id2));
        governor.initiateAuditVote(id2, HALT, 0);

        // Only alice and bob counted in the first checkpoint
        (,,,,,,,,, uint256 total) = governor.checkpoints(id);
        assertEq(total, 80 ether);
    }

    // ================================================================
    //  7.3 #9  test_triggerEarlyCheckpoint_onlySignalRole
    // ================================================================

    function test_triggerEarlyCheckpoint_onlySignalRole() public {
        _fundAndClose();
        _warp(1);
        bytes32 role = governor.SIGNAL_ROLE();

        // A holder is not enough
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        governor.triggerEarlyCheckpoint();

        // Neither is the admin without the role
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        governor.triggerEarlyCheckpoint();
        assertEq(governor.nextCheckpointId(), 0, "nothing opened");
        assertEq(governor.lastSignalTrigger(), 0);

        // The monitor holds SIGNAL_ROLE from setUp
        assertTrue(governor.hasRole(role, address(monitor)));
        vm.expectEmit(true, false, false, true, address(governor));
        emit IQuadraticGovernor.CheckpointWindowOpened(0, IQuadraticGovernor.CheckpointTrigger.SIGNAL);
        vm.expectEmit(true, false, false, false, address(governor));
        emit IQuadraticGovernor.EarlyCheckpointTriggered(0);
        vm.prank(address(monitor));
        uint256 id = governor.triggerEarlyCheckpoint();

        assertEq(id, 0);
        assertEq(governor.lastSignalTrigger(), block.timestamp);
        (,, IQuadraticGovernor.CheckpointTrigger trigger,,,,,,,) = governor.checkpoints(id);
        assertEq(uint256(trigger), uint256(IQuadraticGovernor.CheckpointTrigger.SIGNAL));
    }

    // ================================================================
    //  7.3 #10  test_triggerEarlyCheckpoint_rateLimitedTo1Per30Days
    //  Rule 3. The limit is measured from the previous signal trigger and
    //  is independent of the 90-day scheduled interval.
    // ================================================================

    function test_triggerEarlyCheckpoint_rateLimitedTo1Per30Days() public {
        _fundAndClose();
        _warp(1);

        vm.prank(address(monitor));
        uint256 first = governor.triggerEarlyCheckpoint();
        uint256 t0 = block.timestamp;
        _closeAndResolve(first); // now t0 + 14 days + 1, no window open

        // 15 days after the trigger: rate limited even though no window is open
        _warp(1 days);
        vm.prank(address(monitor));
        vm.expectRevert(QuadraticGovernor.SignalRateLimited.selector);
        governor.triggerEarlyCheckpoint();

        // One second before the limit
        vm.warp(t0 + SIGNAL_RATE_LIMIT - 1);
        vm.roll(block.number + 1);
        vm.prank(address(monitor));
        vm.expectRevert(QuadraticGovernor.SignalRateLimited.selector);
        governor.triggerEarlyCheckpoint();
        assertEq(governor.nextCheckpointId(), 1, "still one checkpoint");

        // Exactly 30 days after: allowed. The scheduled path is still gated by 90 days.
        vm.warp(t0 + SIGNAL_RATE_LIMIT);
        vm.roll(block.number + 1);
        vm.expectRevert(QuadraticGovernor.IntervalNotElapsed.selector);
        governor.openCheckpointWindow();

        vm.prank(address(monitor));
        uint256 second = governor.triggerEarlyCheckpoint();
        assertEq(second, first + 1);
        assertEq(governor.lastSignalTrigger(), t0 + SIGNAL_RATE_LIMIT);
    }

    // ================================================================
    //  7.3 #11  test_triggerEarlyCheckpoint_noOpIfWindowAlreadyOpen
    //  Rule 3. The governor reverts with CheckpointWindowAlreadyOpen;
    //  SignalMonitor.evaluate() wraps the call in try/catch, which is
    //  where the "no-op" in the design document is realised.
    // ================================================================

    function test_triggerEarlyCheckpoint_noOpIfWindowAlreadyOpen() public {
        _fundAndClose();
        uint256 id = _openScheduled();
        assertEq(governor.nextCheckpointId(), 1);

        vm.prank(address(monitor));
        vm.expectRevert(QuadraticGovernor.CheckpointWindowAlreadyOpen.selector);
        governor.triggerEarlyCheckpoint();

        assertEq(governor.nextCheckpointId(), 1, "no second window");
        assertEq(governor.lastSignalTrigger(), 0, "rejected trigger does not consume the rate limit");

        // Through the monitor the rejection is swallowed and reported as false
        vm.prank(reporter);
        monitor.reportMetric(0, 7500); // TVL critical, k=1 in the base monitor
        assertFalse(monitor.evaluate(), "monitor sees no-op");
        assertEq(governor.nextCheckpointId(), 1);

        // An expired window must be resolved before any successor can open.
        _warp(CHECKPOINT_WINDOW + 1);
        vm.prank(address(monitor));
        vm.expectRevert(QuadraticGovernor.CheckpointWindowAlreadyOpen.selector);
        governor.triggerEarlyCheckpoint();
        governor.resolveCheckpoint(id);
        vm.prank(address(monitor));
        uint256 early = governor.triggerEarlyCheckpoint();
        assertEq(early, id + 1);
        assertEq(governor.nextCheckpointId(), 2);
    }

    // ================================================================
    //  A 40% holder cannot reach a >50% supply quorum alone.
    // ================================================================

    function test_singleFortyPercentHolderCannotReachQuorum() public {
        // whale 40 ETH, six holders 10 ETH each, total 100 ETH
        address whale = makeAddr("whale");
        vm.deal(whale, 40 ether);
        vm.prank(whale);
        vault.deposit{value: 40 ether}();

        address[6] memory small;
        for (uint256 i = 0; i < 6; i++) {
            small[i] = makeAddr(string(abi.encodePacked("small", i)));
            vm.deal(small[i], 10 ether);
            vm.prank(small[i]);
            vault.deposit{value: 10 ether}();
        }
        vm.prank(admin);
        vault.closeFunding(RATE_PER_SECOND);
        assertEq(shareToken.totalSupply(), 100 ether);

        uint256 id = _openScheduled();
        (,,, uint256 snapshotBlock,,,,,,) = governor.checkpoints(id);

        uint256 whaleWeight = governor.votingPowerOf(whale, snapshotBlock);
        uint256 quorum = _quorumThreshold();
        assertEq(whaleWeight, 40 ether);
        assertEq(quorum, 50.01 ether);
        uint256 summedWeight = whaleWeight;
        for (uint256 i = 0; i < 6; i++) {
            summedWeight += governor.votingPowerOf(small[i], snapshotBlock);
        }
        assertEq(summedWeight, 100 ether, "all snapshot weights sum to supply");

        // Whale alone initiates, votes HALT, nobody else shows up
        _initiate(whale, id, HALT, 0);
        _vote(whale, id, HALT);
        (,,,,,,,,, uint256 total) = governor.checkpoints(id);
        assertEq(total, whaleWeight);
        assertLt(total, quorum, "a 40% holder cannot reach quorum alone");

        _closeAndResolve(id);
        assertEq(uint256(_resolvedAction(id)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), RATE_PER_SECOND);
    }

    // ================================================================
    //  A 4% holder has exactly 4% vote weight and cannot halt alone.
    // ================================================================

    function test_fourPercentHolderCannotMeetQuorum() public {
        address minnow = makeAddr("minnow");
        vm.deal(minnow, 4 ether);
        vm.prank(minnow);
        vault.deposit{value: 4 ether}();

        address rest = makeAddr("rest");
        vm.deal(rest, 96 ether);
        vm.prank(rest);
        vault.deposit{value: 96 ether}();

        vm.prank(admin);
        vault.closeFunding(RATE_PER_SECOND);
        assertEq(shareToken.totalSupply(), 100 ether);

        uint256 id = _openScheduled();
        (,,, uint256 snapshotBlock,,,,,,) = governor.checkpoints(id);

        uint256 w = governor.votingPowerOf(minnow, snapshotBlock);
        assertEq(w, 4 ether);
        assertEq(_quorumThreshold(), 50.01 ether);
        assertLt(w, _quorumThreshold());

        _initiate(minnow, id, HALT, 0);
        _vote(minnow, id, HALT);
        _closeAndResolve(id);
        assertEq(uint256(_resolvedAction(id)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), RATE_PER_SECOND);
    }

    /// @dev Regression for the unopened-id hole found on 2026-09-08: resolving a checkpoint that was
    /// never opened must revert, otherwise anyone could push lastCheckpointEnd forward every 90 days
    /// and defer the scheduled Layer 3 path indefinitely.
    function test_resolveCheckpoint_revertsForUnopenedId() public {
        _fundAndClose();
        uint256 before = governor.lastCheckpointEnd();
        vm.expectRevert(abi.encodeWithSelector(QuadraticGovernor.WindowNotOpen.selector, uint256(99)));
        governor.resolveCheckpoint(99);
        assertEq(governor.lastCheckpointEnd(), before, "unopened id must not move lastCheckpointEnd");
        assertEq(governor.nextCheckpointId(), 0, "no checkpoint was created");
        // The scheduled path is still reachable afterwards.
        uint256 id = _openScheduled();
        assertEq(id, 0);
    }

    function test_checkpointCannotOpenBeforeFundingCloses() public {
        _warp(CHECKPOINT_INTERVAL + 1);
        vm.expectRevert(QuadraticGovernor.FundingNotClosed.selector);
        governor.openCheckpointWindow();
        vm.prank(address(monitor));
        vm.expectRevert(QuadraticGovernor.FundingNotClosed.selector);
        governor.triggerEarlyCheckpoint();
    }

    function test_scheduledWindowCannotReplaceUnresolvedWindow() public {
        _fundAndClose();
        uint256 first = _openScheduled();

        vm.expectRevert(QuadraticGovernor.CheckpointWindowAlreadyOpen.selector);
        governor.openCheckpointWindow();
        assertEq(governor.nextCheckpointId(), 1);

        _warp(CHECKPOINT_WINDOW + 1);
        vm.expectRevert(QuadraticGovernor.CheckpointWindowAlreadyOpen.selector);
        governor.openCheckpointWindow();
        governor.resolveCheckpoint(first);
        vm.expectRevert(QuadraticGovernor.IntervalNotElapsed.selector);
        governor.openCheckpointWindow();
    }

    function test_rateDeltaIsFixedAndInitiatorCannotRestrictBallot() public {
        _fundAndClose();
        uint256 id = _openScheduled();

        vm.prank(alice);
        vm.expectRevert(QuadraticGovernor.InvalidRateDelta.selector);
        governor.initiateAuditVote(id, INCREASE_RATE, RATE_PER_SECOND);
        vm.prank(alice);
        vm.expectRevert(QuadraticGovernor.InvalidRateDelta.selector);
        governor.initiateAuditVote(id, HALT, 1);

        // A first caller can announce CONTINUE, but cannot block an increase vote.
        _initiate(alice, id, CONTINUE, 0);
        _vote(alice, id, INCREASE_RATE);
        _vote(bob, id, INCREASE_RATE);
        _vote(carol, id, CONTINUE);
        _closeAndResolve(id);
        assertEq(vault.ratePerSecond(), RATE_PER_SECOND + RATE_PER_SECOND / 2);
    }

    function test_checkpointResolutionCannotReviveTerminalVault() public {
        _fundAndClose();
        _warp(1);
        vm.prank(address(monitor));
        uint256 id = governor.triggerEarlyCheckpoint();
        _initiate(alice, id, INCREASE_RATE, 0);
        _vote(alice, id, INCREASE_RATE);
        _vote(bob, id, INCREASE_RATE);

        vm.prank(alice);
        rageQuit.rageQuit(50 ether);
        vm.prank(bob);
        rageQuit.rageQuit(30 ether);
        vm.prank(carol);
        rageQuit.rageQuit(20 ether);
        vault.checkPoolDepletion();
        assertTrue(vault.terminal());

        _closeAndResolve(id);
        assertEq(uint256(_resolvedAction(id)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), 0);
    }
}
