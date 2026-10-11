#!/usr/bin/env python3
"""Record a versioned Foundry run without changing contract or simulation rules."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / '02-solidity'
SEED = '0x6131'
DEPENDENCIES = {
    'forge-std': 'https://github.com/foundry-rs/forge-std.git',
    'openzeppelin-contracts': 'https://github.com/OpenZeppelin/openzeppelin-contracts.git',
}


def capture(args: list[str], cwd: Path = ROOT) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def digest_files(files: list[Path], base: Path) -> str:
    """Hash relative names and bytes, independent of checkout path and timestamps."""
    h = hashlib.sha256()
    for path in sorted(files):
        name = path.relative_to(base).as_posix().encode()
        data = path.read_bytes()
        h.update(len(name).to_bytes(8, 'big'))
        h.update(name)
        h.update(len(data).to_bytes(8, 'big'))
        h.update(data)
    return h.hexdigest()


def locked_revisions() -> dict[str, str]:
    lock = json.loads((PROJECT / 'foundry.lock').read_text())
    return {Path(key.replace('\\', '/')).name: value['tag']['rev']
            for key, value in lock.items()}


def verify_dependencies(install: bool) -> dict[str, dict[str, str]]:
    result = {}
    for name, url in DEPENDENCIES.items():
        revision = locked_revisions()[name]
        dest = PROJECT / 'lib' / name
        if not dest.exists() and install:
            dest.parent.mkdir(exist_ok=True)
            subprocess.run(['git', 'clone', '--no-checkout', url, str(dest)], check=True)
            subprocess.run(['git', '-C', str(dest), 'checkout', '--detach', revision], check=True)
        if not dest.exists():
            raise RuntimeError(f'{name} missing; rerun with --install-deps')
        # A vendored directory without its Git metadata cannot establish a revision.
        if not (dest / '.git').exists():
            raise RuntimeError(f'{dest}: no Git metadata; use a clean pinned Git checkout')
        actual = capture(['git', 'rev-parse', 'HEAD'], dest)
        if actual != revision:
            raise RuntimeError(f'{name}: expected {revision}, got {actual}')
        if capture(['git', 'status', '--porcelain', '--untracked-files=all'], dest):
            raise RuntimeError(f'{name}: dependency worktree is modified')
        result[name] = {'revision': actual, 'solidity_sha256': digest_files(list((dest / ('src' if name == 'forge-std' else 'contracts')).rglob('*.sol')), dest)}
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install-deps', action='store_true', help='clone missing dependencies at lockfile revisions')
    parser.add_argument('--output', type=Path, default=PROJECT / 'test-output' / 'current', help='output directory')
    args = parser.parse_args()
    forge = shutil.which('forge')
    if not forge:
        parser.error('forge not found on PATH (validated with Foundry v1.8.5)')
    dependencies = verify_dependencies(args.install_deps)
    files = [p for folder in ('src', 'test', 'script') for p in (PROJECT / folder).rglob('*.sol')]
    files += [PROJECT / 'foundry.toml', PROJECT / 'foundry.lock']
    before_hash = digest_files(files, PROJECT)
    config = json.loads(capture([forge, 'config', '--json'], PROJECT))
    # Evidence must not silently inherit a different compiler or sampling budget.
    if str(config['solc']) != '0.8.28':
        raise RuntimeError('expected solc 0.8.28')
    if config['fuzz']['runs'] != 256 or config['invariant']['runs'] != 128 or config['invariant']['depth'] != 64:
        raise RuntimeError('unexpected fuzz/invariant configuration')
    filters = ('skip', 'match_test', 'no_match_test', 'match_contract', 'no_match_contract', 'match_path', 'no_match_path')
    if any(config.get(key) for key in filters):
        raise RuntimeError('test filters/skips are not allowed for full-suite evidence')
    if config['invariant'].get('depth_mode', 'fixed') != 'fixed' or config['invariant'].get('check_interval', 1) != 1:
        raise RuntimeError('expected fixed-depth invariants checked after every call')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, NO_COLOR='1', FOUNDRY_DISABLE_NIGHTLY_WARNING='1')
    command = [forge, 'test', '-vv', '--fuzz-seed', SEED]
    run = subprocess.run(command, cwd=PROJECT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = re.sub(r'\x1b\[[0-9;]*m', '', run.stdout)
    (out / 'forge-test.txt').write_text(log)
    summary = re.search(r'(\d+) tests passed, (\d+) failed, (\d+) skipped \((\d+) total tests\)', log)
    counts = dict(zip(('passed', 'failed', 'skipped', 'total'), map(int, summary.groups()))) if summary else None
    invariants = sorted(set(re.findall(r'\[PASS\]\s+(invariant_\w+)(?:\(|\s|$)', log)))
    source_unchanged = before_hash == digest_files(files, PROJECT)
    verified = (run.returncode == 0 and counts is not None and counts['total'] > 0
                and counts['failed'] == 0 and counts['skipped'] == 0
                and len(invariants) == 10 and source_unchanged)
    metadata = {
        'recorded_at_utc': datetime.now(timezone.utc).isoformat(),
        'git_base_commit': capture(['git', 'rev-parse', 'HEAD']),
        'worktree_changes': capture(['git', 'status', '--porcelain']).splitlines(),
        'tested_source_sha256': before_hash,
        'verification_runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'tested_files': [p.relative_to(PROJECT).as_posix() for p in sorted(files)],
        'source_unchanged_during_run': source_unchanged,
        'forge_version': capture([forge, '--version']),
        'compiler': '0.8.28', 'evm_version': config['evm_version'],
        'optimizer': config['optimizer'], 'optimizer_runs': config['optimizer_runs'],
        'dependencies': dependencies,
        'command': ['forge', *command[1:]], 'fuzz_seed': SEED,
        'fuzz_runs': config['fuzz']['runs'], 'invariant_runs': config['invariant']['runs'],
        'invariant_depth': config['invariant']['depth'],
        'exit_code': run.returncode, 'counts': counts, 'passing_invariants': invariants,
        'log_sha256': hashlib.sha256(log.encode()).hexdigest(), 'verified': verified,
    }
    (out / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps({'verified': verified, 'counts': counts, 'invariants': len(invariants), 'output': str(out)}, indent=2))
    if not verified:
        print(log[-8000:], file=sys.stderr)
    return 0 if verified else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError, OSError, KeyError, ValueError) as exc:
        print(f'Validation failed: {exc}', file=sys.stderr)
        sys.exit(1)
