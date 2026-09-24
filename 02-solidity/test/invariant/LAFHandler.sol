// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {LAFVault} from "../../src/LAFVault.sol";
import {LAFShareToken} from "../../src/LAFShareToken.sol";
import {RageQuitModule} from "../../src/RageQuitModule.sol";
import {IQuadraticGovernor} from "../../src/interfaces/IQuadraticGovernor.sol";
import {QuadraticGovernor} from "../../src/QuadraticGovernor.sol";
import {SignalMonitor} from "../../src/SignalMonitor.sol";

/**
 * @title LAFHandler
 * @notice Stateful handler for Foundry invariant testing of the LAF system.
 *
 * Exposes bounded actions that the fuzzer can call in any order.
 * Each action mirrors a real user/role interaction but bounds inputs
 * to valid ranges so we exercise interesting state transitions rather
 * than trivially reverting on bad inputs.
 *
 * Ghost variables track cumulative state for cross-checking invariants.
 */
contract LAFHandler is Test {
    LAFVault public vault;
    LAFShareToken public shareToken;
    RageQuitModule public rageQuit;
    QuadraticGovernor public governor;
    SignalMonitor public monitor;

    address public admin;
    address public team;

    // Bounded set of investors the fuzzer picks from
    address[] public investors;
    uint256 public constant NUM_INVESTORS = 5;

    // Candidate reporters the fuzzer may register/unregister on the monitor
    address[] public reporterCandidates;
    uint256 public constant NUM_REPORTER_CANDIDATES = 3;

    // Ghost variables for invariant assertions
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalClaimed;
    uint256 public ghost_totalRageQuit;
    uint256 public ghost_totalMinted;
    uint256 public ghost_totalBurned;
    bool    public ghost_wasTerminal; // tracks if terminal was ever set

    // When each monitor metric was last recomputed on-chain (reportMetric,
    // removeReporter, evaluate). INV-10 judges freshness as of this time.
    mapping(uint8 => uint256) public ghost_lastRecomputeAt;

    // Call counters for debugging / coverage
    uint256 public calls_deposit;
    uint256 public calls_claim;
    uint256 public calls_rageQuit;
    uint256 public calls_openCheckpoint;
    uint256 public calls_resolveCheckpoint;
    uint256 public calls_reportMetric;
    uint256 public calls_evaluate;
    uint256 public calls_addReporter;
    uint256 public calls_removeReporter;
    uint256 public calls_pauseForAudit;
    uint256 public calls_resumeStreaming;
    uint256 public calls_resumeIfTimedOut;
    uint256 public calls_checkPoolDepletion;
    uint256 public calls_closeFunding;
    uint256 public calls_warp;

    constructor(
        LAFVault _vault,
        LAFShareToken _shareToken,
        RageQuitModule _rageQuit,
        QuadraticGovernor _governor,
        SignalMonitor _monitor,
        address _admin,
        address _team
    ) {
        vault = _vault;
        shareToken = _shareToken;
        rageQuit = _rageQuit;
        governor = _governor;
        monitor = _monitor;
        admin = _admin;
        team = _team;

        // Create bounded investor set
        for (uint256 i = 0; i < NUM_INVESTORS; i++) {
            investors.push(address(uint160(0x1000 + i)));
        }

        // Create bounded reporter candidate set
        for (uint256 i = 0; i < NUM_REPORTER_CANDIDATES; i++) {
            reporterCandidates.push(address(uint160(0x2000 + i)));
        }
    }

    // ================================================================
    //                        INVESTOR ACTIONS
    // ================================================================

    function deposit(uint256 investorSeed, uint256 amount) external {
        // Only during funding phase
        if (vault.fundingClosed()) return;

        address investor = investors[investorSeed % NUM_INVESTORS];
        amount = bound(amount, 0.01 ether, 10 ether);

        deal(investor, amount);
        vm.prank(investor);
        vault.deposit{value: amount}();

        ghost_totalDeposited += amount;
        ghost_totalMinted += amount; // 1:1 mint
        calls_deposit++;
    }

    function closeFunding(uint256 rateSeed) external {
        if (vault.fundingClosed()) return;
        if (vault.totalDeposited() == 0) return;

        // Rate that exhausts the pool in 30-365 days
        uint256 total = vault.totalDeposited();
        uint256 minRate = total / (365 days);
        uint256 maxRate = total / (30 days);
        if (minRate == 0) minRate = 1;
        if (maxRate <= minRate) maxRate = minRate + 1;

        uint256 rate = bound(rateSeed, minRate, maxRate);

        vm.prank(admin);
        vault.closeFunding(rate);
        calls_closeFunding++;
    }

    // ================================================================
    //                         TEAM ACTIONS
    // ================================================================

    function claim() external {
        if (!vault.fundingClosed()) return;
        if (vault.paused()) return;
        if (vault.terminal()) return;
        if (vault.claimable() == 0) return;

        vm.prank(team);
        vault.claim();

        // Update ghost (re-read from contract since claimable was calculated there)
        ghost_totalClaimed = vault.totalClaimedByTeam();
        calls_claim++;
    }

    // ================================================================
    //                      RAGE QUIT (LAYER 2)
    // ================================================================

    function rageQuitAction(uint256 investorSeed, uint256 shareFraction) external {
        if (!vault.fundingClosed()) return;

        address investor = investors[investorSeed % NUM_INVESTORS];
        uint256 balance = shareToken.balanceOf(investor);
        if (balance == 0) return;

        // Quit between 1% and 100% of holdings
        shareFraction = bound(shareFraction, 1, 100);
        uint256 shareAmount = (balance * shareFraction) / 100;
        if (shareAmount == 0) shareAmount = 1;
        if (shareAmount > balance) shareAmount = balance;

        // Check if payout would be zero (avoid revert)
        uint256 totalSupply = shareToken.totalSupply();
        if (totalSupply == 0) return;
        uint256 unreleased = vault.unreleasedBalance();
        uint256 payout = (unreleased * shareAmount) / totalSupply;
        if (payout == 0) return;

        vm.prank(investor);
        rageQuit.rageQuit(shareAmount);

        ghost_totalRageQuit = vault.totalExitedViaRageQuit();
        ghost_totalBurned += shareAmount;
        calls_rageQuit++;
    }

    // ================================================================
    //                    GOVERNANCE (LAYER 3)
    // ================================================================

    function openCheckpoint() external {
        if (!vault.fundingClosed()) return;

        try governor.openCheckpointWindow() {
            calls_openCheckpoint++;
        } catch {
            // Interval not elapsed or other constraint
        }
    }

    function initiateAndVote(uint256 investorSeed, uint256 actionSeed) external {
        if (!vault.fundingClosed()) return;
        if (governor.nextCheckpointId() == 0) return;

        uint256 cpId = governor.nextCheckpointId() - 1;
        address investor = investors[investorSeed % NUM_INVESTORS];

        if (shareToken.balanceOf(investor) == 0) return;

        // Try to initiate (might already be initiated)
        IQuadraticGovernor.CheckpointAction action = IQuadraticGovernor.CheckpointAction(
            bound(actionSeed, 0, 4)
        );

        vm.startPrank(investor);
        try governor.initiateAuditVote(cpId, action, 100) {} catch {}
        try governor.vote(cpId, action) {} catch {}
        vm.stopPrank();
    }

    function resolveCheckpoint() external {
        if (governor.nextCheckpointId() == 0) return;

        uint256 cpId = governor.nextCheckpointId() - 1;

        try governor.resolveCheckpoint(cpId) {
            calls_resolveCheckpoint++;
            // Sync ghost state after potential rate/pause changes
            ghost_totalClaimed = vault.totalClaimedByTeam();
        } catch {
            // Window still open or already resolved
        }
    }

    // ================================================================
    //                    SIGNAL MONITOR (LAYER 4)
    // ================================================================

    /// @dev Pick a random currently-registered reporter and have it report.
    function reportMetric(uint256 reporterSeed, uint256 metricSeed, uint256 valueBps) external {
        uint256 n = monitor.reporterCount();
        if (n == 0) return;

        address reporter = monitor.reporters(reporterSeed % n);
        uint8 metricId = uint8(bound(metricSeed, 0, 4));
        valueBps = bound(valueBps, 0, 120000);

        vm.prank(reporter);
        monitor.reportMetric(metricId, valueBps);
        ghost_lastRecomputeAt[metricId] = block.timestamp;
        calls_reportMetric++;
    }

    function _markAllRecomputed() internal {
        for (uint8 m = 0; m < monitor.NUM_METRICS(); m++) {
            ghost_lastRecomputeAt[m] = block.timestamp;
        }
    }

    /// @dev Register or unregister one candidate reporter, so freshCount and
    ///      reporterCount move independently under fuzzing.
    function toggleReporter(uint256 candidateSeed) external {
        address candidate = reporterCandidates[candidateSeed % NUM_REPORTER_CANDIDATES];
        bool registered = monitor.isReporter(candidate); // read before prank: a view call would consume it

        vm.prank(admin);
        if (registered) {
            monitor.removeReporter(candidate); // recomputes every metric
            _markAllRecomputed();
            calls_removeReporter++;
        } else {
            monitor.addReporter(candidate);
            calls_addReporter++;
        }
    }

    function evaluate() external {
        try monitor.evaluate() {
            _markAllRecomputed(); // evaluate() recomputes all five before deciding
            calls_evaluate++;
        } catch {}
    }

    // ================================================================
    //                     GOVERNANCE RESUME/PAUSE
    // ================================================================

    function pauseForAudit(uint256 periodSeed) external {
        if (!vault.fundingClosed()) return;
        if (vault.terminal()) return;

        uint256 period = bound(periodSeed, 1 days, 60 days);

        vm.prank(address(governor));
        try vault.pauseForAudit(period) {
            calls_pauseForAudit++;
        } catch {}
    }

    function resumeStreaming() external {
        if (!vault.paused()) return;

        vm.prank(address(governor));
        try vault.resumeStreaming() {
            calls_resumeStreaming++;
        } catch {}
    }

    function resumeIfTimedOut() external {
        if (!vault.paused()) return;

        try vault.resumeIfTimedOut() {
            calls_resumeIfTimedOut++;
        } catch {}
    }

    // ================================================================
    //                     PERMISSIONLESS
    // ================================================================

    function checkPoolDepletion() external {
        if (!vault.fundingClosed()) return;
        if (vault.terminal()) return;

        try vault.checkPoolDepletion() {
            calls_checkPoolDepletion++;
            if (vault.terminal()) {
                ghost_wasTerminal = true;
            }
        } catch {}
    }

    // ================================================================
    //                        TIME WARP
    // ================================================================

    function warpForward(uint256 seconds_) external {
        // Warp 1 second to 30 days forward
        seconds_ = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + seconds_);

        // Also advance block number proportionally (1 block per 12 sec)
        vm.roll(block.number + (seconds_ / 12) + 1);
        calls_warp++;
    }

    // ================================================================
    //                     HELPER GETTERS
    // ================================================================

    function getInvestor(uint256 i) external view returns (address) {
        return investors[i % NUM_INVESTORS];
    }

    function callSummary() external view {
        console.log("--- Call Summary ---");
        console.log("deposit:           ", calls_deposit);
        console.log("closeFunding:      ", calls_closeFunding);
        // calls_claim only increments after vault.claim() succeeds (a revert
        // rolls the increment back), so it is the successful-claim count.
        console.log("claim (succeeded): ", calls_claim);
        console.log("totalClaimedByTeam:", vault.totalClaimedByTeam());
        console.log("rageQuit:          ", calls_rageQuit);
        console.log("openCheckpoint:    ", calls_openCheckpoint);
        console.log("resolveCheckpoint: ", calls_resolveCheckpoint);
        console.log("reportMetric:      ", calls_reportMetric);
        console.log("evaluate:          ", calls_evaluate);
        console.log("addReporter:       ", calls_addReporter);
        console.log("removeReporter:    ", calls_removeReporter);
        console.log("pauseForAudit:     ", calls_pauseForAudit);
        console.log("resumeStreaming:    ", calls_resumeStreaming);
        console.log("resumeIfTimedOut:  ", calls_resumeIfTimedOut);
        console.log("checkPoolDepletion:", calls_checkPoolDepletion);
        console.log("warp:              ", calls_warp);
    }
}
