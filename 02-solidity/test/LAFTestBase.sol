// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LAFShareToken} from "../src/LAFShareToken.sol";
import {LAFVault} from "../src/LAFVault.sol";
import {RageQuitModule} from "../src/RageQuitModule.sol";
import {QuadraticGovernor} from "../src/QuadraticGovernor.sol";
import {SignalMonitor} from "../src/SignalMonitor.sol";

/**
 * @title LAFTestBase
 * @notice Shared test helper that deploys the full LAF stack with default params.
 */
abstract contract LAFTestBase is Test {
    LAFShareToken public shareToken;
    LAFVault public vault;
    RageQuitModule public rageQuit;
    QuadraticGovernor public governor;
    SignalMonitor public monitor;

    address public admin = makeAddr("admin");
    address public team = makeAddr("team");
    address public reporter = makeAddr("reporter");

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    // Default params
    uint256 constant RAGE_QUIT_AUTO_PAUSE_BPS = 2500;  // 25%
    uint256 constant POOL_DEPLETION_BPS = 1000;         // 10%
    uint256 constant MAX_PAUSE_DURATION = 60 days;
    uint256 constant CHECKPOINT_INTERVAL = 90 days;
    uint256 constant CHECKPOINT_WINDOW = 14 days;
    uint256 constant QUORUM_BPS = 2000;                  // 20%
    uint256 constant MAJORITY_BPS = 5000;                // 50%
    uint256 constant DEFAULT_PAUSE_PERIOD = 30 days;
    uint256 constant SIGNAL_RATE_LIMIT = 30 days;

    // Common test amounts
    uint256 constant INITIAL_DEPOSIT = 100 ether;
    uint256 constant RATE_PER_SECOND = 0.001 ether;      // ~86.4 ETH/day

    function setUp() public virtual {
        vm.startPrank(admin);

        // Deploy
        shareToken = new LAFShareToken(admin);

        vault = new LAFVault(
            admin, team, shareToken,
            RAGE_QUIT_AUTO_PAUSE_BPS,
            POOL_DEPLETION_BPS,
            MAX_PAUSE_DURATION
        );

        rageQuit = new RageQuitModule(vault, shareToken);

        governor = new QuadraticGovernor(
            admin, vault, shareToken,
            CHECKPOINT_INTERVAL,
            CHECKPOINT_WINDOW,
            QUORUM_BPS,
            MAJORITY_BPS,
            DEFAULT_PAUSE_PERIOD,
            SIGNAL_RATE_LIMIT
        );

        // quorum=1, window=365d: v1-equivalent behaviour with a single reporter
        monitor = new SignalMonitor(admin, governor, 2, 1, 1, 365 days);

        // Grant roles
        vault.grantRole(vault.GOVERNOR_ROLE(), address(governor));
        vault.grantRole(vault.GOVERNOR_ROLE(), admin); // admin can also act as governor in tests
        vault.grantRole(vault.RAGEQUIT_ROLE(), address(rageQuit));
        shareToken.grantRole(shareToken.MINTER_ROLE(), address(vault));
        shareToken.grantRole(shareToken.BURNER_ROLE(), address(rageQuit));
        governor.grantRole(governor.SIGNAL_ROLE(), address(monitor));
        monitor.addReporter(reporter);

        vm.stopPrank();

        // Fund test accounts
        vm.deal(alice, 200 ether);
        vm.deal(bob, 200 ether);
        vm.deal(carol, 200 ether);
    }

    // ---- Helpers ----

    /// @dev Have investors deposit and close funding with default rate.
    function _fundAndClose() internal {
        _fundAndClose(RATE_PER_SECOND);
    }

    function _fundAndClose(uint256 rate) internal {
        vm.prank(alice);
        vault.deposit{value: 50 ether}();

        vm.prank(bob);
        vault.deposit{value: 30 ether}();

        vm.prank(carol);
        vault.deposit{value: 20 ether}();

        vm.prank(admin);
        vault.closeFunding(rate);
    }

    /// @dev Warp time forward and mine a block.
    function _warp(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + 1);
    }
}
