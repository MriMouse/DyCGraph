#!/usr/bin/env python3
"""Build TW insertion/deletion ratios using the existing paper-data rules.

Default outputs: data/paper_data/TW_{100_0,75_25,25_75,0_100}.
Each folder contains input/update/stream_size files at 1k, 10k and 100k,
with ten batches per scale. This is a substantial CPU and disk-I/O job;
run after timing experiments finish. No GPU is used.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import time
import shutil

from prepare_paper_data import ROOT, compile_backend, write_status

BATCHES = 10
SIZES = {'1k': 1000, '10k': 10000, '100k': 100000}
PERCENTAGES = (100, 75, 25, 0)


def identity(path: Path) -> dict:
    stat = path.stat()
    return {'path': str(path.resolve()), 'bytes': stat.st_size,
            'mtime_ns': stat.st_mtime_ns}


def write_ratio_picks(path: Path, chosen: list[int], percent: int) -> None:
    split = len(chosen) * percent // 100
    records = [(index, 0, rank) for rank, index in enumerate(chosen[:split])]
    records.extend((index, 1, rank) for rank, index in enumerate(chosen[split:]))
    records.sort(key=lambda row: row[0])
    part = path.with_suffix('.bin.part')
    pack = struct.Struct('<QII').pack
    with part.open('wb', buffering=8 << 20) as handle:
        for row in records:
            handle.write(pack(*row))
    part.replace(path)


def run_one(output: Path, backend: Path, reference: dict, source: Path,
            source_identity: dict, chosen: list[int], percent: int,
            resume: bool) -> None:
    folder = output / f'TW_{percent}_{100-percent}'
    insertions = {s: n * percent // 100 * BATCHES for s, n in SIZES.items()}
    deletions = {s: n * BATCHES - insertions[s] for s, n in SIZES.items()}
    request = {'dataset': folder.name, 'source': source_identity,
               'source_edges': reference['source_edges'], 'seed': reference['seed'],
               'batches': BATCHES, 'scales': list(SIZES),
               'insertions': insertions, 'deletions': deletions,
               'generator_schema': 1}
    ready = folder / 'ready.json'
    if ready.exists():
        metadata = json.loads(ready.read_text())
        if any(metadata.get(k) != v for k, v in request.items()):
            raise ValueError(f'{folder}: existing dataset has different parameters')
        for suffix in SIZES:
            for stem in ('input', 'update', 'stream_size'):
                if not (folder / f'{stem}_{suffix}.txt').is_file():
                    raise ValueError(f'{folder}: ready dataset is missing files')
        print(f'{folder.name}: already ready; skipping', flush=True)
        return
    if folder.exists():
        if not resume:
            raise FileExistsError(f'{folder}: incomplete output exists; use --resume to regenerate it')
        request_file = folder / 'request.json'
        if not request_file.exists() or json.loads(request_file.read_text()) != request:
            raise ValueError(f'{folder}: resume parameters do not match request.json')
    else:
        folder.mkdir()
        (folder / 'request.json').write_text(json.dumps(request, indent=2) + '\n')
    try:
        write_status(folder, state='sampling', insertion_percent=percent)
        # Rebuild only this script's incomplete outputs; never touch the reference TW.
        for suffix in SIZES:
            for stem in ('input', 'update', 'stream_size'):
                for ending in ('.txt', '.txt.part'):
                    (folder / f'{stem}_{suffix}{ending}').unlink(missing_ok=True)
        write_ratio_picks(folder / 'picks.bin', chosen, percent)
        write_status(folder, state='generating', insertion_percent=percent)
        with (folder / 'generation.log').open('w') as log:
            subprocess.run([str(backend), 'generate', str(source), 'bin',
                            str(folder / 'picks.bin'), str(folder),
                            str(reference['source_edges']), str(reference['seed']),
                            '26', str(percent)], check=True,
                           stdout=log, stderr=subprocess.STDOUT)
        if identity(source) != source_identity:
            raise RuntimeError('raw source changed during generation')
        for suffix, batch_size in SIZES.items():
            for stem in ('input', 'update'):
                part = folder / f'{stem}_{suffix}.txt.part'
                if not part.is_file():
                    raise RuntimeError(f'missing output: {part}')
                part.replace(folder / f'{stem}_{suffix}.txt')
            adds = batch_size * percent // 100
            (folder / f'stream_size_{suffix}.txt').write_text(
                f'{adds} {batch_size-adds}\n' * BATCHES)
        metadata = dict(request, insertion_percent=percent,
                        deletion_percent=100-percent,
                        initial_edges={s: reference['source_edges'] - n
                                       for s, n in insertions.items()},
                        reference_dataset='TW',
                        semantics='uniform original edge-occurrence sample without replacement; '
                        'initial=all original occurrences except selected insertions; '
                        'deletions initially present; ten shuffled mixed batches; '
                        'smaller scales use nested operation-pool prefixes',
                        ratio_sampling='same one-million sample and shuffled order as reference '
                        'seed; insertion prefix then deletion suffix, split by ratio',
                        sparse_id_remap='dense sorted full-source vertex IDs',
                        symmetric_mtx_expansion=False,
                        stream_fields=['insertions', 'deletions'],
                        completed=time.time())
        temporary = folder / 'ready.json.tmp'
        temporary.write_text(json.dumps(metadata, indent=2) + '\n')
        temporary.replace(ready)
        write_status(folder, state='completed', insertion_percent=percent)
        print(f'{folder.name}: completed', flush=True)
    except BaseException as exc:
        write_status(folder, state='failed', error=repr(exc))
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, default=ROOT / 'data/paper_data/TW')
    parser.add_argument('--output', type=Path, default=ROOT / 'data/paper_data')
    parser.add_argument('--insert-percent', type=int, nargs='+',
                        choices=PERCENTAGES, default=list(PERCENTAGES))
    parser.add_argument('--resume', action='store_true',
                        help='regenerate incomplete folders with matching request.json')
    parser.add_argument('--dry-run', action='store_true',
                        help='show counts and disk estimate without generating or compiling')
    args = parser.parse_args()
    reference = json.loads((args.reference / 'ready.json').read_text())
    if reference.get('dataset') != 'TW' or reference.get('batches') != BATCHES:
        parser.error('reference must be the ten-batch TW paper dataset')
    source = Path(reference['source']['path'])
    source_identity = identity(source)
    if source_identity != reference['source']:
        parser.error('raw source identity differs from the reference TW manifest')
    edges = reference['source_edges']
    if source_identity['bytes'] != edges * 8 or edges < 1_000_000:
        parser.error('raw packed source size/count is invalid')
    percentages = list(dict.fromkeys(args.insert_percent))
    estimate_per_ratio = sum((args.reference / f'input_{s}.txt').stat().st_size
                             for s in SIZES) + (256 << 20)
    pending = [p for p in percentages
               if not (args.output / f'TW_{p}_{100-p}' / 'ready.json').exists()]
    estimate = estimate_per_ratio * len(pending)
    print(f'Source: {edges:,} edges; seed={reference["seed"]}; '
          f'estimated additional disk={estimate / (1 << 30):.1f} GiB', flush=True)
    for percent in percentages:
        print(f'TW_{percent}_{100-percent}: per-batch (insert, delete)=' +
              ', '.join(f'{s}: ({n*percent//100}, {n-n*percent//100})'
                        for s, n in SIZES.items()), flush=True)
    if args.dry_run:
        return
    args.output.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(args.output).free < estimate:
        raise RuntimeError(f'insufficient free disk; need approximately {estimate/(1 << 30):.1f} GiB')
    # Exactly reproduce prepare_paper_data.write_picks' seeded sample and shuffle.
    rng = random.Random(reference['seed'])
    chosen = rng.sample(range(edges), 1_000_000)
    rng.shuffle(chosen)
    backend = compile_backend(args.output)
    for percent in percentages:
        run_one(args.output, backend, reference, source, source_identity,
                chosen, percent, args.resume)


if __name__ == '__main__':
    main()
