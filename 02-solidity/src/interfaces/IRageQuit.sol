// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRageQuit
 * @notice Layer 2 — Individual Exit (Rage Quit).
 *
 * Any share holder can exit at any time, receiving their pro-rata
 * share of the vault's unreleased balance. Works during pauses
 * and even after terminal state (this IS the Rule 4 distribution).
 *
 * Burns shares before transferring funds (checks-effects-interactions).
 */
interface IRageQuit {
    event RageQuit(address indexed holder, uint256 sharesBurned, uint256 payout);

    /// @notice Exit by burning `shareAmount` of LAFShareToken and receiving
    ///         the proportional share of unreleasedBalance().
    /// @param shareAmount Number of share tokens to burn.
    function rageQuit(uint256 shareAmount) external;
}
