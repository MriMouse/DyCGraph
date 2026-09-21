#!/usr/bin/env python3
"""Generate and independently verify connected-core EU/USA mixed workloads.

Defaults: both graphs, 50/75/99 percent of original unique road pairs,
10 batches at 10k/100k/1000k directed records, half additions and half deletions.
Outputs are new datasets; the existing random-50p inputs are never overwritten.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', choices=['both', 'eu', 'usa'], default='both')
    parser.add_argument('--eu-source', type=Path,
                        default=ROOT.parent / 'DataSet/europe_osm/europe_osm.mtx')
    parser.add_argument('--usa-source', type=Path, default=ROOT / 'data/road_usa/road_usa.mtx')
    parser.add_argument('--output-root', type=Path, default=ROOT / 'data/road_connected_v2')
    parser.add_argument('--percents', default='50,75,99')
    parser.add_argument('--scales', default='10000,100000,1000000')
    parser.add_argument('--batches', type=int, default=10)
    parser.add_argument('--seed', type=int, default=42)
    args = parser.parse_args()
    output = args.output_root.resolve()
    if output.exists() and any(output.iterdir()):
        raise SystemExit('Output root must be new or empty; existing data preserved')
    selected = [('europe_osm', args.eu_source.resolve()), ('road_usa', args.usa_source.resolve())]
    if args.dataset != 'both':
        selected = [selected[0 if args.dataset == 'eu' else 1]]
    for _, source in selected:
        if not source.is_file():
            raise SystemExit(f'Missing source: {source}')
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    status = {'state': 'building', 'pid': os.getpid(), 'completed_datasets': []}
    def state(stage, **extra):
        status.update(state=stage, **extra)
        status['elapsed_seconds'] = time.monotonic() - started
        save(output / 'status.json', status)
        print(stage + ': ' + str(extra), flush=True)
    try:
        state('building')
        tools = output / '_tools'
        tools.mkdir()
        compiler = shlex.split(os.environ.get('CXX', 'g++'))
        sources = ['connected_road_generator', 'verify_connected_road_dataset']
        manifest = {'generator_version': 'connected-road-v2', 'cpu_only': True,
                    'arguments': {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                    'sources': {}, 'tools': {}, 'datasets': {}}
        shutil.copy2(__file__, tools / Path(__file__).name)
        for name in sources:
            source = ROOT / 'src' / (name + '.cpp')
            shutil.copy2(source, tools / source.name)
            command = compiler + ['-O3', '-std=c++17', '-I', str(ROOT / 'deps/json'), str(source), '-o', str(tools / name)]
            with (tools / (name + '.build.log')).open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            manifest['tools'][name] = {'source_sha256': sha256(source),
                                        'binary_sha256': sha256(tools / name), 'command': command}
        for name, source in selected:
            state('hashing_source', dataset=name)
            before = source.stat()
            manifest['sources'][name] = {'path': str(source), 'bytes': before.st_size,
                'mtime_ns': before.st_mtime_ns, 'sha256': sha256(source)}
            save(output / 'manifest.json', manifest)
            staging = output / ('.' + name + '.generating')
            command = [str(tools / 'connected_road_generator'), str(source), str(staging), name,
                args.percents, args.scales, str(args.batches), str(args.seed), 'connected-road-v2']
            state('generating', dataset=name)
            with (output / (name + '.generation.log')).open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            after = source.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise RuntimeError('Source changed during generation')
            state('verifying', dataset=name)
            verify_command = [str(tools / 'verify_connected_road_dataset'), str(staging)]
            with (output / (name + '.verification.log')).open('w') as log:
                subprocess.run(verify_command, stdout=log, stderr=subprocess.STDOUT, check=True)
            verification = json.loads((staging / 'verification.json').read_text())
            if verification['state'] != 'passed':
                raise RuntimeError('Missing independent validation success')
            state('hashing_outputs', dataset=name)
            hashes, inodes = {}, {}
            for path in sorted(staging.rglob('*')):
                if not path.is_file():
                    continue
                stat = path.stat()
                inode = (stat.st_dev, stat.st_ino)
                if inode not in inodes:
                    inodes[inode] = sha256(path)
                hashes[str(path.relative_to(staging))] = {'bytes': stat.st_size, 'sha256': inodes[inode]}
            save(staging / 'checksums.json', hashes)
            final = output / name
            staging.rename(final)
            manifest['datasets'][name] = {'directory': str(final), 'state': 'verified',
                'generation_command': command, 'verification_command': verify_command,
                'note': 'Commands used staging directory; published directory has identical content'}
            save(output / 'manifest.json', manifest)
            status['completed_datasets'].append(name)
        state('completed', dataset=None)
    except Exception as error:
        state('failed', error=str(error))
        raise


if __name__ == '__main__':
    main()
