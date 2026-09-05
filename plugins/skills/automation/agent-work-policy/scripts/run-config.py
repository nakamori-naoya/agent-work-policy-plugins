#!/usr/bin/env python3
"""A resolved config survives shells; cleanup is scoped to the returned run path."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['create', 'cleanup'])
    p.add_argument('--config')
    p.add_argument('--root')
    a, remainder = p.parse_known_args()
    if a.command == 'cleanup':
        path = Path(a.config or '').absolute()
        if path.name != 'resolved.yml' or path.parent.is_symlink() or path.is_symlink():
            raise ValueError('invalid run config path')
        metadata = path.parent / 'run.json'
        info = json.loads(metadata.read_text())
        if info != {'schema': 1, 'config': str(path), 'uid': os.getuid()} or metadata.is_symlink():
            raise ValueError('run ownership mismatch')
        if {x.name for x in path.parent.iterdir()} - {'resolved.yml', 'run.json'}:
            raise ValueError('unexpected run files; refusing cleanup')
        path.unlink(missing_ok=True)
        metadata.unlink()
        path.parent.rmdir()
        return
    root = Path(a.root or '').resolve(strict=True)
    directory = Path(tempfile.mkdtemp(prefix='harness-run-')).resolve()
    path = directory / 'resolved.yml'
    try:
        arguments = remainder[1:] if remainder[:1] == ['--'] else remainder
        with path.open('w') as output:
            result = subprocess.run(['bash', str(root / 'scripts/resolve.sh'), *arguments], stdout=output)
        if result.returncode or not path.stat().st_size:
            raise ValueError('config resolution failed')
        path.chmod(0o600)
        (directory / 'run.json').write_text(json.dumps({'schema': 1, 'config': str(path), 'uid': os.getuid()}))
        (directory / 'run.json').chmod(0o600)
        print(path)
    except BaseException:
        shutil.rmtree(directory)
        raise

if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError) as exc:
        print('[error] ' + str(exc), file=sys.stderr)
        raise SystemExit(2)
