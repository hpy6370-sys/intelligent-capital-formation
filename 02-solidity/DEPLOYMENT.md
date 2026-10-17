# LAF Prototype Deployment Notes

This guide describes the current reference contracts. The prototype has not
been deployed to a public testnet and has not received an independent security
audit.

## Before deployment

The `LAFVault` constructor fixes `minimumVestingDuration` before investors can
deposit. The sample deploy script sets it to 365 days. It requires an explicit
`TEAM_ADDRESS` distinct from the deployer/admin. After the module contracts are
deployed, the script calls the one-time `configureModules` functions on the
vault and share token. Those functions install the governor, rage-quit module,
vault minter and token burner, while their AccessControl role admins are locked
to an unassigned role. The deployer therefore cannot later grant itself the
team, governor, rage-quit, mint or burn role through the ordinary role API.

`configureModules` rejects modules wired to another vault or share token,
swapped governor/rage-quit arguments (only the governor exposes a checkpoint
schedule), and a token burner that is not the rage-quit module the vault pays.
Configure the vault before the share token, as the script does. The locked
roles cannot be rotated: a mistaken setup means redeploying the stack.

The deployer remains a trusted administrator in three places, so this
separation is not a substitute for a reviewed, independently governed
deployment process:

- **Module setup.** The checks above cannot prove that a module contract is the
  published, source-verified one. Before depositing, investors should check the
  `RoleGranted` events: `GOVERNOR_ROLE` and `RAGEQUIT_ROLE` on the vault and
  `MINTER_ROLE` and `BURNER_ROLE` on the token must belong to the published
  addresses.
- **Funding close.** Only the admin closes funding and chooses the initial rate
  within the bound below. Until then a holder can rage quit and receive the
  deposit back, so funds are never locked by an admin who does not close.
- **Signal layer.** The governor's `SIGNAL_ROLE` and the monitor's reporter set
  stay admin-controlled. An admin can disable Layer 4 or open signal windows
  itself (still limited to one per 30 days); Layer 4 therefore trusts the admin.

The administrator still selects the initial stream rate when it closes
funding. The vault rejects a rate above:

```text
maximum initial rate = totalDeposited / (2 * minimumVestingDuration)
```

The governor can increase the initial rate by at most 2x. Therefore, even at
that maximum, the full raise cannot stream faster than the duration fixed at
deployment. A slower initial rate is allowed. Publish the funding-close
transaction and chosen rate with the fundraising terms.

## Deploy the reference stack

Use Foundry v1.8.5 and the exact Solidity/dependency versions in
`foundry.toml` and `foundry.lock`. Set `PRIVATE_KEY`, `TEAM_ADDRESS`, and the
chosen chain's RPC endpoint in the local environment, then run:

```sh
cd 02-solidity
forge script script/DeployLAF.s.sol:DeployLAF --rpc-url "$RPC_URL" --broadcast
```

`PRIVATE_KEY` is the deployer and initial administrator; `TEAM_ADDRESS` must be
a different address. Keep the administrator separate from the team in any
deployment intended for evaluation. The script configures the module roles
once, grants `SIGNAL_ROLE` to the monitor and prints all five deployed
addresses. It does not close fundraising or register signal reporters.

After deployment, the admin should register reporters using
`SignalMonitor.addReporter(address)`. The sample script uses quorum 1 and a
365-day reporting window and registers no reporter, so the signal layer is
inactive until setup is complete. Multi-reporter deployments should be
configured and tested explicitly; the sample values are development settings,
not production recommendations.

Operational duties: `checkPoolDepletion()`, `resumeIfTimedOut()`,
`openCheckpointWindow()`, `resolveCheckpoint()` and `SignalMonitor.evaluate()`
are permissionless but never run by themselves. Someone must call them; until
then, for example, Rule 4 has not taken effect. The team should claim
regularly, because rage quit pays out of the whole unreleased balance,
including amounts already vested but not yet claimed. Further known
limitations are listed in `PROTOTYPE-V2-CHANGES.md`.

## Verify

From a clean repository checkout, install Foundry v1.8.5 and run the pinned
verification workflow from the repository root:

```sh
python3 scripts/verify_prototype.py --install-deps
```

See `VERIFICATION.md` for the exact source hashes and evidence format. The
recorded test suite checks functional behavior; it does not establish economic
performance, oracle correctness, production security, or legal compliance.
