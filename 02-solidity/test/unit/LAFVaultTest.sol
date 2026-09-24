// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LAFTestBase} from "../LAFTestBase.sol";
import {LAFVault} from "../../src/LAFVault.sol";

/**
 * @title LAFVaultTest
 * @notice Unit tests for LAFVault (Layer 1) — §7.1 of laf_solidity_design.md.
 */
contract LAFVaultTest is LAFTestBase {
    // ================================================================
    //                         DEPOSIT TESTS
    // ================================================================

    function test_deposit_mintsSharesProportionally() public {
        vm.prank(alice);
        vault.deposit{value: 10 ether}();

        assertEq(shareToken.balanceOf(alice), 10 ether, "Shares should be 1:1 with ETH");
        assertEq(vault.totalDeposited(), 10 ether);
        assertEq(address(vault).balance, 10 ether);
    }

    function test_deposit_multipleInvestors() public {
        vm.prank(alice);
        vault.deposit{value: 50 ether}();

        vm.prank(bob);
        vault.deposit{value: 30 ether}();

        assertEq(shareToken.balanceOf(alice), 50 ether);
        assertEq(shareToken.balanceOf(bob), 30 ether);
        assertEq(vault.totalDeposited(), 80 ether);
    }

    function test_deposit_revertsAfterFundingClosed() public {
        _fundAndClose();

        vm.prank(alice);
        vm.expectRevert(LAFVault.FundingAlreadyClosed.selector);
        vault.deposit{value: 1 ether}();
    }

    function test_deposit_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(LAFVault.ZeroDeposit.selector);
        vault.deposit{value: 0}();
    }

    // ================================================================
    //                          CLAIM TESTS
    // ================================================================

    function test_claim_revertsBeforeFundingClosed() public {
        vm.prank(alice);
        vault.deposit{value: 10 ether}();

        vm.prank(team);
        vm.expectRevert(LAFVault.FundingNotClosed.selector);
        vault.claim();
    }

    function test_claim_returnsStreamedAmount() public {
        _fundAndClose();

        // Advance 1000 seconds: should have streamed 1000 * 0.001 = 1 ETH
        _warp(1000);

        uint256 claimable = vault.claimable();
        assertEq(claimable, 1 ether, "Should be 1 ETH after 1000 seconds");

        uint256 teamBalBefore = team.balance;
        vm.prank(team);
        vault.claim();

        assertEq(team.balance - teamBalBefore, 1 ether, "Team should receive 1 ETH");
        assertEq(vault.totalClaimedByTeam(), 1 ether);
    }

    function test_claim_cappedAtUnreleasedBalance() public {
        _fundAndClose();

        // Advance way past total amount (100 ETH at 0.001/sec = 100000 seconds)
        _warp(200000);

        uint256 claimable = vault.claimable();
        // Can't claim more than what's in the vault
        assertLe(claimable, 100 ether, "Claimable should not exceed total deposited");
    }

    function test_claim_revertsAfterTerminal() public {
        _fundAndClose();

        // Force terminal state: have most holders rage quit
        // Alice has 50 ETH worth of shares
        vm.prank(alice);
        rageQuit.rageQuit(50 ether);

        // Bob has 30 ETH
        vm.prank(bob);
        rageQuit.rageQuit(30 ether);

        // Carol has 20 ETH — after alice+bob exit, pool is very small
        vm.prank(carol);
        rageQuit.rageQuit(20 ether);

        // Now the vault is empty, checkPoolDepletion should trigger terminal
        vault.checkPoolDepletion();

        _warp(100);

        vm.prank(team);
        vm.expectRevert(LAFVault.VaultTerminal.selector);
        vault.claim();
    }

    function test_claim_onlyTeamRole() public {
        _fundAndClose();
        _warp(1000);

        vm.prank(alice);
        vm.expectRevert();
        vault.claim();
    }

    // ================================================================
    //                     STREAM RATE TESTS
    // ================================================================

    function test_setStreamRate_onlyGovernorRole() public {
        _fundAndClose();

        vm.prank(alice);
        vm.expectRevert();
        vault.setStreamRate(0.002 ether);
    }

    function test_setStreamRate_changesRate() public {
        _fundAndClose();
        _warp(1000);

        // Team claims at old rate first
        vm.prank(team);
        vault.claim();
        uint256 claimed1 = vault.totalClaimedByTeam();
        assertEq(claimed1, 1 ether, "1 ETH at 0.001/sec for 1000s");

        // Governor changes rate (admin has GOVERNOR_ROLE from setUp)
        vm.prank(admin);
        vault.setStreamRate(0.002 ether);

        // Advance another 1000 seconds at new rate
        _warp(1000);

        vm.prank(team);
        vault.claim();
        uint256 claimed2 = vault.totalClaimedByTeam() - claimed1;
        assertEq(claimed2, 2 ether, "2 ETH at 0.002/sec for 1000s");
    }

    // ================================================================
    //                       PAUSE TESTS
    // ================================================================

    function test_pauseForAudit_revertsIfResponsePeriodExceedsMax() public {
        _fundAndClose();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                LAFVault.ResponsePeriodExceedsMax.selector,
                90 days,
                MAX_PAUSE_DURATION
            )
        );
        vault.pauseForAudit(90 days);
    }

    function test_pauseForAudit_blocksClaimDuringPause() public {
        _fundAndClose();
        _warp(1000);

        // Pause (admin has GOVERNOR_ROLE from setUp)
        vm.prank(admin);
        vault.pauseForAudit(30 days);

        assertTrue(vault.paused(), "Vault should be paused");

        // Team can't claim during pause
        vm.prank(team);
        vm.expectRevert(LAFVault.VaultPaused.selector);
        vault.claim();
    }

    function test_pauseForAudit_excludesPausedTimeFromStream() public {
        _fundAndClose();

        // Stream for 1000s
        _warp(1000);

        // Pause for 5000s (admin has GOVERNOR_ROLE from setUp)
        vm.prank(admin);
        vault.pauseForAudit(30 days);
        _warp(5000);

        // Resume
        vm.prank(admin);
        vault.resumeStreaming();

        // Stream for another 1000s
        _warp(1000);

        // Total effective time should be 2000s, not 7000s
        uint256 claimable = vault.claimable();
        assertEq(claimable, 2 ether, "Should be 2 ETH (2000 effective seconds)");
    }

    function test_resumeIfTimedOut_onlyAfterResponsePeriod() public {
        _fundAndClose();

        vm.prank(admin);
        vault.pauseForAudit(30 days);

        // Try to resume before timeout
        vm.expectRevert(LAFVault.PauseNotTimedOut.selector);
        vault.resumeIfTimedOut();

        // Advance past timeout
        _warp(30 days + 1);

        // Now it should work (permissionless)
        vault.resumeIfTimedOut();
        assertFalse(vault.paused(), "Should be unpaused after timeout");
    }

    function test_resumeStreaming_onlyGovernorRole() public {
        _fundAndClose();

        vm.prank(admin);
        vault.pauseForAudit(30 days);

        vm.prank(alice);
        vm.expectRevert();
        vault.resumeStreaming();
    }

    // ================================================================
    //                   RAGE QUIT WITHDRAWAL TESTS
    // ================================================================

    function test_withdrawForRageQuit_onlyRageQuitRole() public {
        _fundAndClose();

        vm.prank(alice);
        vm.expectRevert();
        vault.withdrawForRageQuit(alice, 10 ether);
    }

    // ================================================================
    //                  POOL DEPLETION TESTS (RULE 4)
    // ================================================================

    function test_checkPoolDepletion_triggersTerminalBelowThreshold() public {
        _fundAndClose();

        // Have alice rage quit most of her shares
        vm.prank(alice);
        rageQuit.rageQuit(50 ether);

        // Bob rage quits
        vm.prank(bob);
        rageQuit.rageQuit(30 ether);

        // Pool should be around 20 ETH now (carol's deposit)
        // But some may have streamed. With 100 ETH total, 10% threshold = 10 ETH
        // 20 ETH remaining > 10 ETH threshold, so should not trigger yet

        // Carol exits too, leaving basically nothing
        vm.prank(carol);
        rageQuit.rageQuit(20 ether);

        // Now pool should be ~0
        vault.checkPoolDepletion();
        assertTrue(vault.terminal(), "Should be terminal after all rage quits");
        assertEq(vault.ratePerSecond(), 0, "Rate should be zeroed");
    }

    function test_checkPoolDepletion_noOpAboveThreshold() public {
        _fundAndClose();

        // With 100 ETH and 10% threshold, need to be above 10 ETH
        vault.checkPoolDepletion();
        assertFalse(vault.terminal(), "Should not be terminal with full balance");
    }

    // ================================================================
    //                      INVARIANT CHECKS
    // ================================================================

    function test_invariant_balanceEqualsAccounting() public {
        _fundAndClose();
        _warp(1000);

        // Team claims
        vm.prank(team);
        vault.claim();

        // Alice rage quits half
        vm.prank(alice);
        rageQuit.rageQuit(25 ether);

        // Verify: vault balance == totalDeposited - totalClaimed - totalExited
        uint256 expected = vault.totalDeposited() - vault.totalClaimedByTeam() - vault.totalExitedViaRageQuit();
        assertEq(address(vault).balance, expected, "Accounting identity must hold");
    }

    // ================================================================
    //                        FUZZ TESTS
    // ================================================================

    function testFuzz_claim_returnsExactlyStreamedAmount(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 100000); // 1 to 100000 seconds

        _fundAndClose();
        _warp(elapsed);

        uint256 expectedStreamed = elapsed * RATE_PER_SECOND;
        uint256 unreleased = vault.unreleasedBalance();
        uint256 expectedClaimable = expectedStreamed > unreleased ? unreleased : expectedStreamed;

        assertEq(vault.claimable(), expectedClaimable, "Claimable should match stream formula");
    }
}
