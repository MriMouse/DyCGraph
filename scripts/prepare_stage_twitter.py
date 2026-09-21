#!/usr/bin/env python3
"""Derive true per-batch Twitter scales from the existing larger update pool.

The upstream '1000k' pool contains 100k insertions and 100k deletions per batch.
Use the established ID-remapper once, then take balanced prefixes within each
original batch. Original inputs are immutable; outputs are a distinct cohort.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(os.environ.get('CG_STAGE_ROOT', Path(__file__).resolve().parents[1]))


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 << 20), b''):
            h.update(block)
    return h.hexdigest()


def split_pool(update, sizes, graph, output):
    counts = [[int(v) for v in line.split()] for line in sizes.read_text().splitlines() if line.strip()]
    if len(counts) != 10 or any(row != [100000, 100000] for row in counts):
        raise ValueError('Expected 10 x (100k add, 100k delete) pool')
    adds, deletes = [], []
    seen = {'a': set(), 'd': set()}
    with update.open() as source:
        for line in source:
            op, u, v, w = line.split()
            if op not in seen or w != '1':
                raise ValueError('Invalid update')
            edge = (int(u), int(v))
            if edge in seen[op]:
                raise ValueError('Duplicate operation in source pool')
            seen[op].add(edge)
            (adds if op == 'a' else deletes).append(line)
    if len(adds) != 1000000 or len(deletes) != 1000000 or seen['a'] & seen['d']:
        raise ValueError('Pool count/disjointness mismatch')
    result = {}
    for scale in (1, 10, 100):
        take = scale*1000//2
        base = output/f'input_twitter_stage_{scale}k.txt'
        if not base.exists():
            os.link(graph, base)
        upd = output/f'update_twitter_stage_{scale}k.txt'
        batch = output/f'stream_size_twitter_stage_{scale}k.txt'
        with upd.open('w') as stream:
            for i in range(10):
                begin = i*100000
                stream.writelines(deletes[begin:begin+take])
                stream.writelines(adds[begin:begin+take])
        batch.write_text(f'{take} {take}\n'*10)
        result[str(scale)] = {'records_per_batch': scale*1000, 'update_sha256': digest(upd),
                              'sizes_sha256': digest(batch)}
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    output = args.directory.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output/'ready.json').exists():
        return
    raw = Path('/home/wangshaoyan/proJect/CG/C-GpuStreamGraph/data')
    remap = output/'remapped'
    remap.mkdir(exist_ok=True)
    if not (remap/'twitter_stage_stats.json').exists():
        subprocess.run([sys.executable, os.environ.get('CG_STAGE_REMAPPER', str(ROOT/'data/remap_twitter_vertex_ids.py')), '--data-dir', str(raw),
                        '--output-dir', str(remap), '--configs', '1000k', '--output-prefix', 'twitter_stage',
                        '--overwrite'], check=True)
    graph = remap/'input_twitter_stage_1000k.txt'
    result = split_pool(remap/'update_twitter_stage_1000k.txt', remap/'stream_size_twitter_stage_1000k.txt', graph, output)
    manifest = {'cohort': 'twitter_stage_true_batch', 'scales': result, 'graph_sha256': digest(graph),
        'source_graph': str(raw/'input_twitter_1000k.txt'), 'source_updates': str(raw/'update_twitter_1000k.txt'),
        'source_graph_sha256': digest(raw/'input_twitter_1000k.txt'),
        'source_update_sha256': digest(raw/'update_twitter_1000k.txt'),
        'sampling': 'Within each original batch take first K/2 additions and K/2 deletions; same base for all sizes',
        'limits': '1000k/batch unavailable; source pool is 200k/batch despite its filename. New ID universe changes weight mapping from older remapped cohort.',
        'remap_stats': json.loads((remap/'twitter_stage_stats.json').read_text())}
    (output/'ready.json').write_text(json.dumps(manifest, indent=2)+'\n')


if __name__ == '__main__':
    main()
