// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LAFTestBase} from "../LAFTestBase.sol";
import {LAFVault} from "../../src/LAFVault.sol";
import {QuadraticGovernor} from "../../src/QuadraticGovernor.sol";
import {IQuadraticGovernor} from "../../src/interfaces/IQuadraticGovernor.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title QuadraticGovernorTest
 * @notice Unit tests for Layer 3 (QuadraticGovernor), section 7.3 of laf_solidity_design.md.
 *
 * Default parameters from LAFTestBase: 90-day interval, 14-day window, quorum 20%,
 * majority 50%, 30-day default pause response period, 30-day signal rate limit.
 * Default holders from _fundAndClose(): alice 50 ETH, bob 30 ETH, carol 20 ETH
 * (sqrt weights ~7.07e9, ~5.48e9, ~4.47e9; sqrt(totalSupply) = 1e10; quorum = 2e9).
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
    function _unanimousCheckpoint(IQuadraticGovernor.CheckpointAction action, uint256 delta)
        internal
        returns (uint256 id)
    {
        id = _openScheduled();
        _initiate(alice, id, action, delta);
        _vote(alice, id, action);
        _vote(bob, id, action);
        _vote(carol, id, action);
        _closeAndResolve(id);
    }

    function _resolvedAction(uint256 id) internal view returns (IQuadraticGovernor.CheckpointAction action) {
        (,,,,,, action,,,) = governor.checkpoints(id);
    }

    function _quorumThreshold() internal view returns (uint256) {
        return (Math.sqrt(shareToken.totalSupply()) * QUORUM_BPS) / 10000;
    }

    // ================================================================
    //  7.3 #1  test_votingWeight_isSqrtOfBalance
    //  100x larger holder gets exactly 10x weight
    // ================================================================

    function test_votingWeight_isSqrtOfBalance() public {
        vm.prank(alice);
        vault.deposit{value: 100 ether}();
        vm.prank(bob);
        vault.deposit{value: 1 ether}();
        vm.prank(admin);
        vault.closeFunding(RATE_PER_SECOND);

        _warp(1);
        uint256 id = governor.openCheckpointWindow();
        (,,, uint256 snapshotBlock,,,,,,) = governor.checkpoints(id);
        assertEq(snapshotBlock, block.number - 1, "snapshot is the previous block");

        uint256 wAlice = governor.votingPowerOf(alice, snapshotBlock);
        uint256 wBob = governor.votingPowerOf(bob, snapshotBlock);

        assertEq(shareToken.balanceOf(alice), 100 * shareToken.balanceOf(bob), "balances differ 100x");
        assertEq(wAlice, Math.sqrt(100 ether), "weight is integer sqrt of balance");
        assertEq(wBob, Math.sqrt(1 ether));
        assertEq(wAlice, 10 * wBob, "sqrt compresses 100x balance into 10x weight");

        // Weight recorded on vote matches votingPowerOf
        _initiate(alice, id, HALT, 0);
        vm.expectEmit(true, true, false, true, address(governor));
        emit IQuadraticGovernor.Voted(id, alice, HALT, wAlice);
        _vote(alice, id, HALT);
        assertEq(governor.tallies(id, HALT), wAlice);
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
    //  Extra A  first window has no interval gate (lastCheckpointEnd == 0)
    //           and every window is exactly checkpointWindowDuration long
    // ================================================================

    function test_firstWindow_opensWithoutIntervalGate_andIs14DaysLong() public {
        _fundAndClose();
        assertEq(governor.lastCheckpointEnd(), 0);

        _warp(1); // only for the snapshot block, not for the interval
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
        _initiate(alice, id, DECREASE_RATE, 123);

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
        assertEq(delta, 123);
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
    //  Limitation 5. Needs a holder whose sqrt weight is below 20% of
    //  sqrt(totalSupply): 1 ETH out of 101 ETH gives 1e9 < ~2.01e9.
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
        assertEq(totalVoteWeight, Math.sqrt(1 ether));
        assertLt(totalVoteWeight, _quorumThreshold(), "dave alone is below quorum");

        _closeAndResolve(id);

        // HALT had 100% of cast weight but quorum failed, so nothing happens
        assertEq(uint256(_resolvedAction(id)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), rateBefore, "HALT not applied");
        assertFalse(vault.paused());
    }

    // ================================================================
    //  Extra B  quorum met but no action exceeds 50% of cast weight
    //  falls back to CONTINUE (strict > in _findWinner)
    // ================================================================

    function test_resolveCheckpoint_pluralityBelowMajority_isContinue() public {
        _fundAndClose();
        uint256 rateBefore = vault.ratePerSecond();

        // Three-way split: alice HALT (~7.07e9), bob PAUSE (~5.48e9), carol DECREASE (~4.47e9)
        uint256 id = _openScheduled();
        _initiate(alice, id, HALT, 0);
        _vote(alice, id, HALT);
        _vote(bob, id, PAUSE_FOR_AUDIT);
        _vote(carol, id, DECREASE_RATE);

        (,,,,,,,,, uint256 total) = governor.checkpoints(id);
        assertGe(total, _quorumThreshold(), "quorum is met");
        uint256 best = governor.tallies(id, HALT);
        assertGt(best, governor.tallies(id, PAUSE_FOR_AUDIT));
        assertLe(best, (total * MAJORITY_BPS) / 10000, "plurality but not majority");

        _closeAndResolve(id);
        assertEq(uint256(_resolvedAction(id)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), rateBefore);
        assertFalse(vault.paused());

        // Same electorate, alice + bob on HALT (~12.55e9 of ~17.02e9) clears 50%
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
        uint256 idContinue = _unanimousCheckpoint(CONTINUE, 0);
        assertEq(uint256(_resolvedAction(idContinue)), uint256(CONTINUE));
        assertEq(vault.ratePerSecond(), rate0, "CONTINUE leaves rate");
        assertFalse(vault.paused(), "CONTINUE leaves pause state");

        // INCREASE_RATE: rate += delta
        uint256 up = 0.0004 ether;
        uint256 idInc = _unanimousCheckpoint(INCREASE_RATE, up);
        assertEq(uint256(_resolvedAction(idInc)), uint256(INCREASE_RATE));
        assertEq(vault.ratePerSecond(), rate0 + up, "INCREASE_RATE adds delta");

        // DECREASE_RATE: rate -= delta
        uint256 down = 0.0009 ether;
        uint256 idDec = _unanimousCheckpoint(DECREASE_RATE, down);
        assertEq(uint256(_resolvedAction(idDec)), uint256(DECREASE_RATE));
        assertEq(vault.ratePerSecond(), rate0 + up - down, "DECREASE_RATE subtracts delta");

        // DECREASE_RATE with delta >= rate floors at 0 instead of underflowing
        uint256 idFloor = _unanimousCheckpoint(DECREASE_RATE, type(uint256).max);
        assertEq(uint256(_resolvedAction(idFloor)), uint256(DECREASE_RATE));
        assertEq(vault.ratePerSecond(), 0, "DECREASE_RATE floors at zero");

        // Put a rate back so HALT below is observable
        vm.prank(admin);
        vault.setStreamRate(rate0);

        // PAUSE_FOR_AUDIT: vault paused with the governor's default response period
        uint256 idPause = _unanimousCheckpoint(PAUSE_FOR_AUDIT, 0);
        assertEq(uint256(_resolvedAction(idPause)), uint256(PAUSE_FOR_AUDIT));
        assertTrue(vault.paused(), "PAUSE_FOR_AUDIT pauses the vault");
        assertEq(uint256(vault.pausedReason()), uint256(LAFVault.PauseReason.AUDIT_RESOLUTION));
        assertEq(vault.pauseResponsePeriod(), DEFAULT_PAUSE_PERIOD, "uses defaultPauseResponsePeriod");
        assertEq(vault.pausedAt(), block.timestamp);
        assertEq(vault.ratePerSecond(), rate0, "PAUSE_FOR_AUDIT does not touch the rate");

        // HALT: rate set to 0 (pause state is left as is)
        uint256 idHalt = _unanimousCheckpoint(HALT, 0);
        assertEq(uint256(_resolvedAction(idHalt)), uint256(HALT));
        assertEq(vault.ratePerSecond(), 0, "HALT zeroes the rate");
        assertTrue(vault.paused(), "HALT does not resume");
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
        assertEq(total, Math.sqrt(50 ether) + Math.sqrt(30 ether));
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

        // Once the window has expired (even before resolution) the guard no longer applies
        _warp(CHECKPOINT_WINDOW + 1);
        vm.prank(address(monitor));
        uint256 early = governor.triggerEarlyCheckpoint();
        assertEq(early, id + 1);
        assertEq(governor.nextCheckpointId(), 2);
    }

    // ================================================================
    //  7.3 #12  renamed from test_whaleCannotSingleHandedlyReachQuorum
    //
    //  The design document (section 7.3, last item) planned a test that a
    //  single large holder cannot reach quorum on its own. Under the
    //  prototype's actual rule that assertion is false, so it is not
    //  written that way here and the contract is deliberately left alone.
    //
    //  Known design issue (v5 simulation report, "Four design findings for
    //  the prototype", finding 2, see 01-simulation/LAF-SIMULATION-NOTE.md): quorum is 20% x sqrt(totalSupply) but it is
    //  compared against sum(sqrt(balance_i)). A holder with 40% of shares
    //  contributes sqrt(0.4) = 63% of sqrt(totalSupply), so one address
    //  clears quorum alone; the simulation never saw quorum bind, only the
    //  50% majority. The suggested fix is to define quorum on the same
    //  aggregate as the vote weights or on a head count. Until that is
    //  decided this test pins the current behaviour so a future fix shows
    //  up as a deliberate test change, not a silent one.
    // ================================================================

    function test_singleWhaleCanReachQuorumAlone() public {
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
        uint256 sqrtTotal = Math.sqrt(shareToken.totalSupply());
        uint256 quorum = _quorumThreshold();
        assertEq(quorum, (sqrtTotal * 2000) / 10000);

        // sqrt(0.4) of sqrt(totalSupply) is ~63%, more than three times the 20% bar
        assertEq((whaleWeight * 100) / sqrtTotal, 63, "whale supplies 63% of sqrt(totalSupply)");
        assertGe(whaleWeight, 3 * quorum, "whale weight alone exceeds 3x quorum");

        // Against the aggregate the votes are actually summed over, the whale is only ~25%
        uint256 sumSqrt = whaleWeight;
        for (uint256 i = 0; i < 6; i++) {
            sumSqrt += governor.votingPowerOf(small[i], snapshotBlock);
        }
        assertEq((whaleWeight * 100) / sumSqrt, 25, "whale is 25% of sum(sqrt(balance_i))");

        // Whale alone initiates, votes HALT, nobody else shows up
        _initiate(whale, id, HALT, 0);
        _vote(whale, id, HALT);
        (,,,,,,,,, uint256 total) = governor.checkpoints(id);
        assertEq(total, whaleWeight);
        assertGe(total, quorum, "quorum met by one address");

        _closeAndResolve(id);
        assertEq(uint256(_resolvedAction(id)), uint256(HALT), "whale's action carried unilaterally");
        assertEq(vault.ratePerSecond(), 0, "stream halted by a single holder");
    }

    // ================================================================
    //  Extra D  the same mismatch at the boundary: 4% of supply gives
    //  sqrt(0.04) = 20% of sqrt(totalSupply), exactly the quorum bar,
    //  and >= lets it through.
    // ================================================================

    function test_fourPercentHolderMeetsQuorumExactly() public {
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
        assertEq(w, 2e9, "sqrt(4e18) is exact");
        assertEq(_quorumThreshold(), 2e9, "20% of sqrt(100e18)");
        assertEq(w, _quorumThreshold(), "4% holder sits exactly on the quorum line");

        _initiate(minnow, id, HALT, 0);
        _vote(minnow, id, HALT);
        _closeAndResolve(id);
        assertEq(uint256(_resolvedAction(id)), uint256(HALT), "4% of supply halts the stream alone");
        assertEq(vault.ratePerSecond(), 0);
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
}
