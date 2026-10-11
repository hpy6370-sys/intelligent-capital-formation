# Reproducible prototype verification

This validation addition freezes the contract rules. It addresses the gap
between the archived 83-test log and later verification claims made only in
prose. It does not alter v5 simulation inputs or outcomes.

## Run from a clean checkout

Install Foundry v1.8.5, then, from the repository root:

```sh
python3 scripts/verify_prototype.py --install-deps
```

Python 3.10+ is sufficient; no Python packages are required. The runner clones
missing dependencies and checks out the exact revisions in `foundry.lock`.
It refuses modified dependencies or a different revision. It does not replace
an existing directory, so the earlier `forge install --no-git` instructions
produce a vendored tree this stricter runner cannot verify; use a clean clone.
`forge test` compiles the contracts and executes all suites.

`--output /path/to/evidence` selects a different output directory. By default,
local output goes to `02-solidity/test-output/current/` (Git-ignored). CI puts
output outside the checkout and uploads it even when a test run fails.

## What is retained

- `forge-test.txt`: complete, uncoloured output, including suite summaries and
  invariant sampling records.
- `metadata.json`: UTC recording time, Git base revision and worktree changes,
  source/config/lockfile SHA-256, tested filenames, verification runner hash,
  Forge build version, dependency Git revisions and Solidity-source hashes,
  compiler, command, fixed seed, sampling settings, counts, passing invariant
  names, process exit status and raw-log SHA-256.

The source digest covers all repository-owned Solidity in `src/`, `test/`
and `script/`, plus `foundry.toml` and `foundry.lock`. Paths are relative to
`02-solidity`; hashes frame names and content lengths to avoid concatenation
ambiguity. The runner checks that these inputs did not change during testing.
A working-tree run records its base commit and changes instead of claiming
that every uncommitted file already belongs to that commit. For the dated
record, compare this source hash with the committed source tree; the Git base
can predate the commit that adds the verification tooling itself.

A run is marked verified only when Forge exits zero, a nonempty test summary
exists, no tests failed or were skipped, ten distinct `invariant_*` properties
passed, and the source digest is unchanged. Full-suite filters/skips are rejected; fixed-depth invariants must be checked
after every call. Compiler 0.8.28, 256 fuzz runs and
128 invariant runs at depth 64 are required. The fixed seed is `0x6131`.
The runner is deliberately tied to the present ten-property suite: update
that expected inventory explicitly when adding or removing a property.

## Dated evidence and limits

The 11 October 2026 record is in `test-output/verification-2026-10-11/`.
`test-output/forge-test.txt` remains the historical 8 September run. Earlier
84/95-test statements are historical reports; the new raw log supplies its
own actual count, toolchain and source identity.

Passing tests demonstrate the exercised functional properties under the
configured sampling budget. They are not a production audit, full formal
verification, testnet deployment, or a new economic evaluation. The historical
v5 recovery and terminal-rate figures still cannot be attributed to revised
contracts. Fixed seeds and versions improve traceability; timings and gas
output can differ across operating systems, toolchains and environments.
