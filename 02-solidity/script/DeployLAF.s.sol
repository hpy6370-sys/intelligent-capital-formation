// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {LAFShareToken} from "../src/LAFShareToken.sol";
import {LAFVault} from "../src/LAFVault.sol";
import {RageQuitModule} from "../src/RageQuitModule.sol";
import {QuadraticGovernor} from "../src/QuadraticGovernor.sol";
import {SignalMonitor} from "../src/SignalMonitor.sol";

/**
 * @title DeployLAF
 * @notice Deploys the full LAF stack with default parameters.
 *         Usage: forge script script/DeployLAF.s.sol --broadcast
 */
contract DeployLAF is Script {
    error TeamMustDifferFromAdmin();

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        // Require a distinct explicit team address. LAFVault additionally
        // locks its value-moving roles after this stack is configured.
        address team = vm.envAddress("TEAM_ADDRESS");
        if (team == deployer) revert TeamMustDifferFromAdmin();

        vm.startBroadcast(deployerKey);

        // 1. Share token
        LAFShareToken shareToken = new LAFShareToken(deployer);

        // 2. Vault (Layer 1)
        LAFVault vault = new LAFVault(
            deployer,           // admin
            team,               // team
            shareToken,
            2500,               // rageQuitAutoPauseBps: 25%
            1000,               // poolDepletionBps: 10%
            60 days,            // maxPauseDuration
            365 days            // minimumVestingDuration, locked before deposits
        );

        // 3. Rage Quit Module (Layer 2)
        RageQuitModule rageQuit = new RageQuitModule(vault, shareToken);

        // 4. Quadratic Governor (Layer 3)
        QuadraticGovernor governor = new QuadraticGovernor(
            deployer,           // admin
            vault,
            shareToken,
            90 days,            // checkpointInterval
            14 days,            // checkpointWindowDuration
            5001,               // quorumBps: >50% of snapshot shares
            5000,               // majorityBps: 50%
            30 days,            // defaultPauseResponsePeriod
            30 days             // signalRateLimit (Rule 3)
        );

        // 5. Signal Monitor (Layer 4)
        SignalMonitor monitor = new SignalMonitor(
            deployer,           // admin
            governor,
            2,                  // warningCombinatorThreshold
            1,                  // criticalCombinatorThreshold
            1,                  // quorum: fresh submissions needed per metric
            365 days            // reportWindow: how long a submission stays fresh
        );

        // 6. Install the value-moving modules once. The contracts permanently
        // lock these role admins so the deployer cannot later add itself.
        vault.configureModules(address(governor), address(rageQuit));
        shareToken.configureModules(address(vault), address(rageQuit));
        // Governor: signal monitor can trigger early checkpoints
        governor.grantRole(governor.SIGNAL_ROLE(), address(monitor));

        vm.stopBroadcast();

        console.log("=== LAF Deployment ===");
        console.log("ShareToken:", address(shareToken));
        console.log("Vault:     ", address(vault));
        console.log("RageQuit:  ", address(rageQuit));
        console.log("Governor:  ", address(governor));
        console.log("Monitor:   ", address(monitor));
    }
}
