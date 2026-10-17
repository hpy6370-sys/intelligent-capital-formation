# LAF Prototype Deployment Notes

This guide describes the current reference contracts. The prototype has not
been deployed to a public testnet and has not received an independent security
audit.

## Before deployment

The `LAFVault` constructor fixes `minimumVestingDuration` before investors can
deposit. The sample deploy script sets it to 365 days. It also requires an
explicit `TEAM_ADDRESS` and rejects using the deployer/admin account as the
team, preventing a single key from both changing administrative settings and
claiming team funds.

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
deployment intended for evaluation. The script grants the required contract
roles and prints all five deployed addresses. It does not close fundraising or
register signal reporters.

After deployment, the admin should register reporters using
`SignalMonitor.addReporter(address)`. The sample script uses quorum 1 and a
365-day reporting window and registers no reporter, so the signal layer is
inactive until setup is complete. Multi-reporter deployments should be
configured and tested explicitly; the sample values are development settings,
not production recommendations.

## Verify

From a clean repository checkout, install Foundry v1.8.5 and run the pinned
verification workflow from the repository root:

```sh
python3 scripts/verify_prototype.py --install-deps
```

See `VERIFICATION.md` for the exact source hashes and evidence format. The
recorded test suite checks functional behavior; it does not establish economic
performance, oracle correctness, production security, or legal compliance.
