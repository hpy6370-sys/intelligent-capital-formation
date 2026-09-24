// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILAFVault} from "./interfaces/ILAFVault.sol";
import {LAFShareToken} from "./LAFShareToken.sol";

/**
 * @title LAFVault
 * @notice Layer 1 — Streaming Fund Release with inline enforcement of Rule 2 and Rule 4.
 *
 * Holds all deposited capital. After funding closes, the team claims
 * funds linearly over time at `ratePerSecond`. Governance (Layer 3)
 * can pause, resume, halt, or adjust the rate via GOVERNOR_ROLE.
 * Rage-quit payouts (Layer 2) are deducted from the unreleased balance
 * via RAGEQUIT_ROLE.
 *
 * All configurable parameters are constructor arguments.
 * No upgradability, no proxy — redeploy for iteration.
 */
contract LAFVault is ILAFVault, AccessControl, ReentrancyGuard {
    // ---- Roles ----
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant RAGEQUIT_ROLE = keccak256("RAGEQUIT_ROLE");
    bytes32 public constant TEAM_ROLE = keccak256("TEAM_ROLE");

    // ---- Enums ----
    enum PauseReason { NONE, AUDIT_RESOLUTION, RAGE_QUIT_THRESHOLD }

    // ---- State ----
    LAFShareToken public immutable shareToken;

    // Stream configuration
    uint256 public override ratePerSecond;
    uint256 public streamStartTime;
    uint256 public lastClaimTime;
    bool    public override paused;
    PauseReason public pausedReason;
    uint256 public pausedAt;
    uint256 public pauseResponsePeriod;
    uint256 public totalPausedTime;
    bool    public override terminal;

    // Tracks total streamed amount at the time of the last rate change,
    // so claimable() works correctly across rate changes.
    uint256 public accruedAtLastRateChange;
    uint256 public effectiveElapsedAtLastRateChange;

    // Accounting
    uint256 public override totalDeposited;
    uint256 public override totalClaimedByTeam;
    uint256 public override totalExitedViaRageQuit;
    bool    public fundingClosed;

    // Rule 2 — checkpoint window state
    uint256 public currentWindowId;
    uint256 public unreleasedBalanceAtOpen;
    uint256 public cumulativeRageQuitInWindow;

    // Constructor params (configurable for stress-test sweeps)
    uint256 public immutable rageQuitAutoPauseBps;  // default 2500 (25%)
    uint256 public immutable poolDepletionBps;       // default 1000 (10%)
    uint256 public immutable maxPauseDuration;       // default 60 days

    // ---- Errors ----
    error FundingNotOpen();
    error FundingAlreadyClosed();
    error FundingNotClosed();
    error ZeroDeposit();
    error NothingToClaim();
    error VaultPaused();
    error VaultTerminal();
    error NotTerminal();
    error ResponsePeriodExceedsMax(uint256 requested, uint256 max);
    error NotPaused();
    error PauseNotTimedOut();
    error AlreadyTerminal();
    error TransferFailed();

    constructor(
        address admin,
        address team,
        LAFShareToken _shareToken,
        uint256 _rageQuitAutoPauseBps,
        uint256 _poolDepletionBps,
        uint256 _maxPauseDuration
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TEAM_ROLE, team);

        shareToken = _shareToken;
        rageQuitAutoPauseBps = _rageQuitAutoPauseBps;
        poolDepletionBps = _poolDepletionBps;
        maxPauseDuration = _maxPauseDuration;
    }

    // ================================================================
    //                      INVESTOR ACTIONS
    // ================================================================

    /// @inheritdoc ILAFVault
    function deposit() external payable override {
        if (fundingClosed) revert FundingAlreadyClosed();
        if (msg.value == 0) revert ZeroDeposit();

        totalDeposited += msg.value;

        // Mint shares 1:1 with deposited ETH
        shareToken.mint(msg.sender, msg.value);

        emit Deposited(msg.sender, msg.value, msg.value);
    }

    // ================================================================
    //                        ADMIN ACTIONS
    // ================================================================

    /// @inheritdoc ILAFVault
    function closeFunding(uint256 _ratePerSecond) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fundingClosed) revert FundingAlreadyClosed();
        require(_ratePerSecond > 0, "Rate must be positive");

        fundingClosed = true;
        ratePerSecond = _ratePerSecond;
        streamStartTime = block.timestamp;
        lastClaimTime = block.timestamp;

        emit FundingClosed(_ratePerSecond);
    }

    // ================================================================
    //                         TEAM ACTIONS
    // ================================================================

    /// @inheritdoc ILAFVault
    function claim() external override onlyRole(TEAM_ROLE) nonReentrant {
        if (!fundingClosed) revert FundingNotClosed();
        if (paused) revert VaultPaused();
        if (terminal) revert VaultTerminal();

        uint256 amount = claimable();
        if (amount == 0) revert NothingToClaim();

        totalClaimedByTeam += amount;
        lastClaimTime = block.timestamp;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Claimed(msg.sender, amount);
    }

    // ================================================================
    //                      GOVERNOR ACTIONS
    // ================================================================

    /// @inheritdoc ILAFVault
    function setStreamRate(uint256 newRate) external override onlyRole(GOVERNOR_ROLE) {
        if (!fundingClosed) revert FundingNotClosed();

        // Settle any accrued but unclaimed streaming before changing rate
        _settleStream();

        uint256 oldRate = ratePerSecond;
        ratePerSecond = newRate;

        emit StreamRateChanged(oldRate, newRate);
    }

    /// @inheritdoc ILAFVault
    function pauseForAudit(uint256 _responsePeriod) external override onlyRole(GOVERNOR_ROLE) {
        if (!fundingClosed) revert FundingNotClosed();
        if (terminal) revert VaultTerminal();
        if (_responsePeriod > maxPauseDuration) {
            revert ResponsePeriodExceedsMax(_responsePeriod, maxPauseDuration);
        }

        // Settle stream before pausing so claimable() stays correct
        _settleStream();

        paused = true;
        pausedReason = PauseReason.AUDIT_RESOLUTION;
        pausedAt = block.timestamp;
        pauseResponsePeriod = _responsePeriod;

        emit PausedForAudit(block.timestamp + _responsePeriod);
    }

    /// @inheritdoc ILAFVault
    function resumeStreaming() external override onlyRole(GOVERNOR_ROLE) {
        if (!paused) revert NotPaused();

        _resume();
        emit Resumed(msg.sender);
    }

    /// @inheritdoc ILAFVault
    function markCheckpointWindowOpen(uint256 checkpointId) external override onlyRole(GOVERNOR_ROLE) {
        currentWindowId = checkpointId;
        unreleasedBalanceAtOpen = unreleasedBalance();
        cumulativeRageQuitInWindow = 0;
    }

    // ================================================================
    //                     RAGEQUIT ACTIONS
    // ================================================================

    /// @inheritdoc ILAFVault
    function withdrawForRageQuit(address holder, uint256 amount) external override onlyRole(RAGEQUIT_ROLE) nonReentrant {
        if (!fundingClosed) revert FundingNotClosed();

        totalExitedViaRageQuit += amount;

        // Rule 2: track cumulative rage quit in the current checkpoint window
        cumulativeRageQuitInWindow += amount;

        // Transfer funds to holder
        (bool ok,) = holder.call{value: amount}("");
        if (!ok) revert TransferFailed();

        // Rule 2 check: if cumulative rage quit exceeds threshold, auto-pause
        if (
            unreleasedBalanceAtOpen > 0 &&
            cumulativeRageQuitInWindow * 10000 > unreleasedBalanceAtOpen * rageQuitAutoPauseBps &&
            !paused &&
            !terminal
        ) {
            // Settle stream before auto-pausing
            _settleStream();

            paused = true;
            pausedReason = PauseReason.RAGE_QUIT_THRESHOLD;
            pausedAt = block.timestamp;
            // Use the max pause duration as default for rage-quit triggered pause
            pauseResponsePeriod = maxPauseDuration;

            emit RageQuitThresholdBreached(cumulativeRageQuitInWindow, rageQuitAutoPauseBps);
        }
    }

    // ================================================================
    //                      PERMISSIONLESS
    // ================================================================

    /// @inheritdoc ILAFVault
    function checkPoolDepletion() external override {
        if (!fundingClosed) revert FundingNotClosed();
        if (terminal) revert AlreadyTerminal();

        // Rule 4: if unreleased balance drops below threshold, enter terminal state
        if (unreleasedBalance() * 10000 < totalDeposited * poolDepletionBps) {
            _settleStream();

            terminal = true;
            ratePerSecond = 0;

            emit TerminalStateEntered(unreleasedBalance());
        }
    }

    /// @inheritdoc ILAFVault
    function resumeIfTimedOut() external override {
        if (!paused) revert NotPaused();
        if (block.timestamp < pausedAt + pauseResponsePeriod) revert PauseNotTimedOut();

        _resume();
        emit Resumed(address(0)); // address(0) indicates auto-resume
    }

    // ================================================================
    //                        VIEW FUNCTIONS
    // ================================================================

    /// @inheritdoc ILAFVault
    function unreleasedBalance() public view override returns (uint256) {
        return totalDeposited - totalClaimedByTeam - totalExitedViaRageQuit;
    }

    /// @inheritdoc ILAFVault
    function claimable() public view override returns (uint256) {
        if (!fundingClosed || paused || terminal) return 0;

        uint256 totalStreamed = _totalStreamed();
        uint256 unreleased = unreleasedBalance();

        // Can't claim more than what's in the vault
        if (totalStreamed <= totalClaimedByTeam) return 0;
        uint256 available = totalStreamed - totalClaimedByTeam;

        return available > unreleased ? unreleased : available;
    }

    // ================================================================
    //                        INTERNAL
    // ================================================================

    /// @dev Calculates effective elapsed time excluding paused periods.
    function _effectiveElapsed() internal view returns (uint256) {
        if (!fundingClosed) return 0;

        uint256 currentTime = paused ? pausedAt : block.timestamp;
        uint256 rawElapsed = currentTime - streamStartTime;

        return rawElapsed > totalPausedTime ? rawElapsed - totalPausedTime : 0;
    }

    /// @dev Total amount streamed to date, accounting for rate changes.
    function _totalStreamed() internal view returns (uint256) {
        uint256 elapsed = _effectiveElapsed();
        uint256 elapsedSinceRateChange = elapsed - effectiveElapsedAtLastRateChange;
        return accruedAtLastRateChange + (elapsedSinceRateChange * ratePerSecond);
    }

    /// @dev Settles the stream by snapshotting accrued amount before rate/pause changes.
    function _settleStream() internal {
        accruedAtLastRateChange = _totalStreamed();
        effectiveElapsedAtLastRateChange = _effectiveElapsed();
        lastClaimTime = block.timestamp;
    }

    /// @dev Common resume logic. Accumulates paused time and clears pause state.
    function _resume() internal {
        totalPausedTime += block.timestamp - pausedAt;
        paused = false;
        pausedReason = PauseReason.NONE;
        pausedAt = 0;
        pauseResponsePeriod = 0;
        lastClaimTime = block.timestamp;
    }
}
