#!/usr/bin/env python3
"""I19 nested, valid ratio cohorts; retain the exact existing base graph."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def identity(path):
    s = path.stat()
    return dict(path=str(path.resolve()), bytes=s.st_size, mtime_ns=s.st_mtime_ns)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(16 << 20), b''):
            h.update(block)
    return h.hexdigest()


def emit(out, base, source, source_node, batch_size, batches, seed, identities):
    meta = json.loads((out/'pool.json').read_text())
    stride = batch_size * 9 // 10
    pools = {}
    for op, suffix in [('d', 'delete'), ('a', 'insert')]:
        pools[op] = [tuple(map(int, line.split())) for line in (out/f'pool.{suffix}.tsv').read_text().splitlines()]
        if len(pools[op]) != stride*batches:
            raise ValueError('candidate count mismatch')
        if len({r[2] for r in pools[op]}) != len(pools[op]):
            raise ValueError('reused occurrence')
    if {r[2] for r in pools['d']} & {r[2] for r in pools['a']}:
        raise ValueError('overlapping occurrence pools')
    initial = {(s, d): m for pool in pools.values() for s, d, _, m, _ in pool}
    for pool in pools.values():
        for s, d, _, m, _ in pool:
            if not (0 <= s < meta['nodes'] and 0 <= d < meta['nodes']) or initial[s,d] != m:
                raise ValueError('ID or multiplicity mismatch')
    if not 0 <= source_node < meta['nodes']:
        raise ValueError('source outside universe')
    base_identity = dict(identities['base'], sha256=digest(base))
    pool_identity = {p.name: digest(p) for p in out.glob('pool.*')}
    for percent in range(10, 100, 10):
        folder = out/f'p{percent:02}'
        folder.mkdir(exist_ok=False)
        # Manifest reference avoids duplicating or modifying the shared base.
        state = initial.copy()
        degrees = {s: degree for pool in pools.values() for s, _, _, _, degree in pool}
        edges = meta['base_edges']
        per_batch = []
        update = folder/'updates.txt'
        size_file = folder/'stream_size.txt'
        adds = batch_size*percent//100
        dels = batch_size-adds
        with update.open('w') as f, size_file.open('w') as sizes:
            for b in range(batches):
                touched = set()
                before = {}
                effective_records = 0
                pair_counts = Counter()
                for op, count in [('d', dels), ('a', adds)]:
                    selected = pools[op][b*stride:b*stride+count]
                    for s, d, _, _, _ in selected:
                        pair = s,d
                        before.setdefault(s, degrees[s])
                        if op == 'd':
                            if state[pair] <= 0:
                                raise ValueError('invalid deletion')
                            state[pair] -= 1
                            degrees[s] -= 1
                            edges -= 1
                        else:
                            if state[pair] != 0:
                                raise ValueError('parallel insertion prohibited')
                            state[pair] += 1
                            degrees[s] += 1
                            edges += 1
                        touched.add(s)
                        pair_counts[op, s, d] += 1
                        f.write(f'{op} {s} {d} 1\n')
                    effective_records += len({(s,d) for s,d,*_ in selected}) if op == 'd' else len(selected)
                sizes.write(f'{adds} {dels}\n')  # Loader: additions first.
                if edges != meta['base_edges']+(b+1)*(adds-dels):
                    raise ValueError('net edge mismatch')
                values = sorted(before.values())
                per_batch.append(dict(batch=b, B=batch_size, U=batch_size,
                    additions=adds, deletions=dels, effective_records=effective_records,
                    graph_edges=edges, touched_sources=len(touched),
                    source_min=min(touched), source_max=max(touched),
                    touched_degree_before=dict(min=values[0], median=values[len(values)//2],
                        p90=values[int(.9*(len(values)-1))], max=values[-1], total=sum(values)),
                    touched_degree_after_total=sum(degrees[s] for s in touched),
                    repeated_requests=sum(n-1 for n in pair_counts.values()), valid=True))
        manifest = dict(schema=1, status='ready', base=base_identity,
            source=identities['source'], source_node=source_node,
            source_sha256=identities['source_sha256'],
            seed=seed, nodes=meta['nodes'], base_edges=meta['base_edges'],
            B=batch_size, batches=batches, insertion_percent=percent,
            ratio_definition='insertions / (insertions + deletions)',
            update_file_weight=1, sssp_weight_rule='uint32(src + dst) % 128 + 1', stream_fields=['additions','deletions'], operation_order='delete then add',
            pool=meta, pool_hashes=pool_identity,
            pool_policy='one shared SplitMix64(occurrence XOR seed) rank for both disjoint pools; disjoint per-batch slots, nested prefixes; held-out source occurrences; insertion pairs initially absent and unique across ten batches; deletion consumes multiplicity',
            mapping='full-source sorted dense IDs' if (out/'pool.mapping.u32').exists() else 'original IDs, universe max(source ID)+1',
            updates=dict(path=str(update.resolve()), sha256=digest(update)),
            sizes=dict(path=str(size_file.resolve()), sha256=digest(size_file)),
            validation=per_batch, command=sys.argv)
        (folder/'ready.json').write_text(json.dumps(manifest, indent=2)+'\n')
    (out/'ready.json').write_text(json.dumps(dict(status='ready', datasets=9, meta=meta), indent=2)+'\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dataset', choices=['wiki','friendster'], required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--source', type=Path)
    p.add_argument('--base', type=Path)
    p.add_argument('--source-node', type=int)
    p.add_argument('--batch-size', type=int, default=100000)
    p.add_argument('--batches', type=int, default=10)
    p.add_argument('--seed', type=int, default=20260914)
    p.add_argument('--pool-binary', type=Path, default=ROOT/'build/i19_ratio_pool')
    a = p.parse_args()
    if a.batch_size <= 0 or a.batch_size % 10 or a.batches <= 0:
        p.error('positive batch-size divisible by ten and positive batches required')
    source = a.source or ROOT.parent/'DataSet'/('out.wikipedia_link_en' if a.dataset=='wiki' else 'com-friendster.ungraph.txt')
    base = a.base or ROOT/'data'/f'input_{a.dataset}_50p_100k.txt'
    node = a.source_node if a.source_node is not None else (134151 if a.dataset=='wiki' else 0)
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    status = out/'status.json'
    try:
        identities = dict(source=identity(source), base=identity(base))
        status.write_text(json.dumps(dict(state='pool_scan', pid=os.getpid(), inputs=identities)))
        with (out/'pool.log').open('w') as log:
            subprocess.run([str(a.pool_binary.resolve()), str(source), str(base), str(out/'pool'),
                'dense' if a.dataset=='friendster' else 'identity',
                str(a.batch_size*9//10*a.batches), str(a.seed)], check=True, stdout=log, stderr=subprocess.STDOUT)
        status.write_text(json.dumps(dict(state='hash_and_validate', pid=os.getpid())))
        identities['source_sha256'] = digest(source)
        emit(out, base, source, node, a.batch_size, a.batches, a.seed, identities)
        if identity(source)!=identities['source'] or identity(base)!=identities['base']:
            raise ValueError('input identity changed during generation')
        status.write_text(json.dumps(dict(state='complete', completed=time.time())))
    except BaseException as e:
        for ready in out.rglob('ready.json'):
            ready.unlink()
        status.write_text(json.dumps(dict(state='failed', error=repr(e))))
        raise

if __name__ == '__main__':
    main()
