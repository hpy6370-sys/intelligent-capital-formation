// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {LAFVault} from "../../src/LAFVault.sol";
import {LAFShareToken} from "../../src/LAFShareToken.sol";
import {RageQuitModule} from "../../src/RageQuitModule.sol";
import {QuadraticGovernor} from "../../src/QuadraticGovernor.sol";
import {SignalMonitor} from "../../src/SignalMonitor.sol";
import {LAFHandler} from "./LAFHandler.sol";

/**
 * @title LAFInvariantTest
 * @notice Foundry invariant tests for the LAF system (Design doc section 7.7).
 *
 * Uses a stateful handler pattern: the fuzzer calls random sequences of
 * bounded actions on LAFHandler, and after each call we assert that all
 * system invariants still hold.
 *
 * Invariants tested (ten `invariant_*` functions below): vault balance identity,
 * outflow bound, unreleased-balance consistency, no claim while paused or terminal,
 * terminal is a one-way latch, non-negative balances, share supply matches mints
 * minus burns, zero rate when terminal, claimable bound, and SignalMonitor flags
 * backed by >= quorum fresh submissions.
 */
contract LAFInvariantTest is Test {
    LAFVault public vault;
    LAFShareToken public shareToken;
    RageQuitModule public rageQuitModule;
    QuadraticGovernor public governor;
    SignalMonitor public monitor;
    LAFHandler public handler;

    // makeAddr, not low literals: 0x0a..0x11 are precompiles under the default
    // EVM (Prague), and ETH transfers to them fail, so a team at 0xB never
    // managed a single successful claim.
    address public admin;
    address public teamAddr;

    function setUp() public {
        admin = makeAddr("admin");
        teamAddr = makeAddr("team");

        // Deploy share token
        shareToken = new LAFShareToken(admin);

        // Deploy vault (Layer 1)
        vault = new LAFVault(
            admin,
            teamAddr,
            shareToken,
            2500,       // rageQuitAutoPauseBps: 25%
            1000,       // poolDepletionBps: 10%
            60 days     // maxPauseDuration
        );

        // Deploy rage quit module (Layer 2)
        rageQuitModule = new RageQuitModule(vault, shareToken);

        // Deploy governor (Layer 3)
        governor = new QuadraticGovernor(
            admin,
            vault,
            shareToken,
            90 days,    // checkpointInterval
            14 days,    // checkpointWindowDuration
            2000,       // quorumBps: 20%
            5000,       // majorityBps: 50%
            30 days,    // defaultPauseResponsePeriod
            30 days     // signalRateLimit (Rule 3)
        );

        // Deploy signal monitor (Layer 4)
        monitor = new SignalMonitor(
            admin,
            governor,
            2,          // warningCombinatorThreshold
            1,          // criticalCombinatorThreshold
            2,          // quorum: below the 3 registered reporters so removals can cross it
            365 days    // reportWindow
        );

        // Grant roles
        vm.startPrank(admin);
        vault.grantRole(vault.GOVERNOR_ROLE(), address(governor));
        vault.grantRole(vault.RAGEQUIT_ROLE(), address(rageQuitModule));
        shareToken.grantRole(shareToken.MINTER_ROLE(), address(vault));
        shareToken.grantRole(shareToken.BURNER_ROLE(), address(rageQuitModule));
        governor.grantRole(governor.SIGNAL_ROLE(), address(monitor));
        vm.stopPrank();

        // Deploy handler
        handler = new LAFHandler(
            vault,
            shareToken,
            rageQuitModule,
            governor,
            monitor,
            admin,
            teamAddr
        );

        // Register every handler candidate up front. toggleReporter may remove
        // any of them, so reporterCount can fall 3 -> 2 (quorum) -> 1 -> 0 and
        // the below-quorum clearing path in _recompute gets fuzzed for real.
        vm.startPrank(admin);
        for (uint256 i = 0; i < handler.NUM_REPORTER_CANDIDATES(); i++) {
            monitor.addReporter(handler.reporterCandidates(i));
        }
        vm.stopPrank();
        assertEq(monitor.reporterCount(), 3);

        // Target only the handler for invariant calls
        targetContract(address(handler));

        // Seed with some initial deposits so the fuzzer has material to work with
        for (uint256 i = 0; i < 3; i++) {
            address investor = handler.getInvestor(i);
            deal(investor, 5 ether);
            vm.prank(investor);
            vault.deposit{value: 5 ether}();
        }

        // Close funding with a reasonable rate (drains pool in ~180 days)
        uint256 total = vault.totalDeposited();
        uint256 rate = total / (180 days);
        vm.prank(admin);
        vault.closeFunding(rate);
    }

    // ================================================================
    //          SANITY: the handler's claim path actually pays the team
    // ================================================================

    /// @notice Deterministic witness that vault.claim() succeeds for teamAddr
    ///         through the exact handler path the fuzzer uses. With
    ///         teamAddr = address(0xB) this reverted on every call
    ///         (TransferFailed: 0xB is a precompile), so totalClaimedByTeam
    ///         stayed 0 across all 8192 fuzz calls and INV-1/2/6/9 never saw
    ///         a claim.
    function test_handlerClaimPaysTeam() public {
        handler.warpForward(1 days);
        handler.claim();

        assertGt(vault.totalClaimedByTeam(), 0, "team claim never succeeded");
        assertEq(handler.calls_claim(), 1, "handler did not record the successful claim");
        assertEq(teamAddr.balance, vault.totalClaimedByTeam(), "ETH did not reach the team");
    }

    // ================================================================
    //                 INVARIANT 1: Vault ETH balance identity
    // ================================================================

    /// @notice The vault's ETH balance must always equal
    ///         totalDeposited - totalClaimedByTeam - totalExitedViaRageQuit.
    function invariant_vaultBalanceEqualsAccountingIdentity() public view {
        uint256 expected = vault.totalDeposited()
            - vault.totalClaimedByTeam()
            - vault.totalExitedViaRageQuit();
        uint256 actual = address(vault).balance;

        assertEq(actual, expected, "INV-1: Vault ETH != accounting identity");
    }

    // ================================================================
    //                 INVARIANT 2: Accounting bounds
    // ================================================================

    /// @notice totalClaimedByTeam + totalExitedViaRageQuit <= totalDeposited, always.
    function invariant_outflowNeverExceedsDeposits() public view {
        uint256 outflow = vault.totalClaimedByTeam() + vault.totalExitedViaRageQuit();
        uint256 deposits = vault.totalDeposited();

        assertLe(outflow, deposits, "INV-2: Outflow exceeds deposits");
    }

    // ================================================================
    //                 INVARIANT 3: Share token supply consistency
    // ================================================================

    /// @notice unreleasedBalance() must equal totalDeposited - totalClaimed - totalExited.
    ///         This is a tautology given the implementation, but verifies the view
    ///         function agrees with raw state.
    function invariant_unreleasedBalanceConsistent() public view {
        uint256 expected = vault.totalDeposited()
            - vault.totalClaimedByTeam()
            - vault.totalExitedViaRageQuit();
        uint256 actual = vault.unreleasedBalance();

        assertEq(actual, expected, "INV-3: unreleasedBalance() disagrees with components");
    }

    // ================================================================
    //                 INVARIANT 4: No claimable while paused/terminal
    // ================================================================

    /// @notice When vault is paused or terminal, claimable() must return 0.
    function invariant_noClaimableWhenPausedOrTerminal() public view {
        if (vault.paused() || vault.terminal()) {
            assertEq(vault.claimable(), 0, "INV-4: claimable > 0 while paused/terminal");
        }
    }

    // ================================================================
    //                 INVARIANT 5: Terminal is one-way
    // ================================================================

    /// @notice Once terminal == true, it never flips back to false.
    function invariant_terminalIsOneWay() public view {
        if (handler.ghost_wasTerminal()) {
            assertTrue(vault.terminal(), "INV-5: terminal flipped from true to false");
        }
    }

    // ================================================================
    //                 INVARIANT 6: Vault balance never negative
    // ================================================================

    /// @notice The vault's ETH balance is never negative (trivially true for uint256,
    ///         but the accounting identity should never underflow).
    function invariant_vaultBalanceNonNegative() public view {
        uint256 deposited = vault.totalDeposited();
        uint256 claimed = vault.totalClaimedByTeam();
        uint256 exited = vault.totalExitedViaRageQuit();

        // If this assertion passes, it means no underflow occurred
        assertGe(deposited, claimed + exited, "INV-6: Underflow in vault accounting");
    }

    // ================================================================
    //                 INVARIANT 7: Share supply consistency
    // ================================================================

    /// @notice shareToken.totalSupply() should be non-negative (always true) and
    ///         should never exceed totalDeposited (since shares are minted 1:1).
    function invariant_shareSupplyBounded() public view {
        uint256 supply = shareToken.totalSupply();
        uint256 deposited = vault.totalDeposited();

        assertLe(supply, deposited, "INV-7: Share supply exceeds total deposited");
    }

    // ================================================================
    //                 INVARIANT 8: Stream rate zero when terminal
    // ================================================================

    /// @notice When terminal, ratePerSecond must be 0.
    function invariant_terminalImpliesZeroRate() public view {
        if (vault.terminal()) {
            assertEq(vault.ratePerSecond(), 0, "INV-8: rate > 0 in terminal state");
        }
    }

    // ================================================================
    //                 INVARIANT 9: Claimable bounded by unreleased
    // ================================================================

    /// @notice claimable() must never exceed unreleasedBalance().
    function invariant_claimableBoundedByUnreleased() public view {
        assertLe(
            vault.claimable(),
            vault.unreleasedBalance(),
            "INV-9: claimable > unreleasedBalance"
        );
    }

    // ================================================================
    //          INVARIANT 10: Signal flags backed by quorum
    // ================================================================

    /// @notice Recount every metric from raw storage, without trusting the
    ///         contract's freshCount, and check the flags against it.
    ///
    ///         Flags are as of the metric's last recompute (reportMetric,
    ///         removeReporter, evaluate); the handler stamps that time in
    ///         ghost_lastRecomputeAt. Submissions cannot change without a
    ///         recompute, and a reporter added afterwards has no submissions,
    ///         so the stored submissions of the current reporters are exactly
    ///         the set that recompute saw. Freshness is therefore judged at
    ///         that timestamp with the same window rule as the contract:
    ///         asOf - reportedAt <= reportWindow.
    ///
    ///         Checks: freshCount <= reporterCount; freshCount == recount;
    ///         below quorum every flag is off and effectiveValue is 0; at or
    ///         above quorum effectiveValue is the lower median of the fresh
    ///         values and each flag matches its threshold; and any active flag
    ///         is backed by >= quorum stored submissions from current reporters.
    function invariant_signalFlagsBackedByQuorum() public view {
        uint256 n = monitor.reporterCount();
        uint256 k = monitor.quorum();
        uint256 window = monitor.reportWindow();

        for (uint8 i = 0; i < monitor.NUM_METRICS(); i++) {
            uint256 asOf = handler.ghost_lastRecomputeAt(i);
            uint256[] memory fresh = new uint256[](n);
            uint256 count;
            uint256 stored;

            for (uint256 j = 0; j < n; j++) {
                (uint256 v, uint256 at) = monitor.submissions(i, monitor.reporters(j));
                if (at == 0) continue;
                stored++;
                if (asOf - at > window) continue;

                // Insertion sort so the median below is over sorted values
                uint256 p = count;
                while (p > 0 && fresh[p - 1] > v) {
                    fresh[p] = fresh[p - 1];
                    p--;
                }
                fresh[p] = v;
                count++;
            }

            bool warning = monitor.isMetricWarning(i);
            bool critical = monitor.isMetricCritical(i);

            assertLe(monitor.freshCount(i), n, "INV-10: freshCount > reporterCount");
            assertEq(monitor.freshCount(i), count, "INV-10: freshCount != independent recount");

            if (count < k) {
                assertFalse(warning, "INV-10: warning active below quorum");
                assertFalse(critical, "INV-10: critical active below quorum");
                assertEq(monitor.effectiveValue(i), 0, "INV-10: effectiveValue != 0 below quorum");
            } else {
                uint256 median = fresh[(count - 1) / 2];
                (uint256 warningBps, uint256 criticalBps) = monitor.thresholds(i);
                assertEq(monitor.effectiveValue(i), median, "INV-10: effectiveValue != lower median");
                assertEq(warning, median >= warningBps, "INV-10: warning flag != median vs threshold");
                assertEq(critical, median >= criticalBps, "INV-10: critical flag != median vs threshold");
            }

            if (warning || critical) {
                assertGe(stored, k, "INV-10: flag active with < quorum stored submissions");
            }
        }
    }

    // ================================================================
    //                        AFTER INVARIANT
    // ================================================================

    /// @notice Print call summary for debugging coverage after a run.
    function afterInvariant() public view {
        handler.callSummary();
    }
}
