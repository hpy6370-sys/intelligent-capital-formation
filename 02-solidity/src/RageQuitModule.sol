// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRageQuit} from "./interfaces/IRageQuit.sol";
import {LAFShareToken} from "./LAFShareToken.sol";
import {LAFVault} from "./LAFVault.sol";

/**
 * @title RageQuitModule
 * @notice Layer 2 — Unconditional individual exit.
 *
 * Any share holder can exit at any time by burning their shares for a
 * pro-rata share of the vault's unreleased balance. This works during
 * pauses and even in terminal state (it IS the Rule 4 distribution).
 *
 * Checks-effects-interactions: burns shares first, then triggers vault payout.
 */
contract RageQuitModule is IRageQuit, ReentrancyGuard {
    LAFVault public immutable vault;
    LAFShareToken public immutable shareToken;

    error ZeroShares();
    error InsufficientShares(uint256 requested, uint256 available);
    error ZeroPayout();

    constructor(LAFVault _vault, LAFShareToken _shareToken) {
        vault = _vault;
        shareToken = _shareToken;
    }

    /// @inheritdoc IRageQuit
    function rageQuit(uint256 shareAmount) external override nonReentrant {
        if (shareAmount == 0) revert ZeroShares();

        uint256 balance = shareToken.balanceOf(msg.sender);
        if (balance < shareAmount) revert InsufficientShares(shareAmount, balance);

        // Calculate payout BEFORE burning (need current totalSupply)
        uint256 totalShares = shareToken.totalSupply();
        uint256 unreleased = vault.unreleasedBalance();
        uint256 payout = (unreleased * shareAmount) / totalShares;

        if (payout == 0) revert ZeroPayout();

        // Effects: burn shares first (checks-effects-interactions)
        shareToken.burn(msg.sender, shareAmount);

        // Interactions: trigger vault payout (vault handles Rule 2 auto-pause check)
        vault.withdrawForRageQuit(msg.sender, payout);

        emit RageQuit(msg.sender, shareAmount, payout);
    }
}
