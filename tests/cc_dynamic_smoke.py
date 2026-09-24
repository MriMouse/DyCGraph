"""Opt-in CC GPU regression against an independent component flood-fill oracle.

Includes bridge/cycle deletion, duplicate occurrences, isolated vertices, empty
phases, mixed batches, non-unit weights, and all production insertion schedules.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import random
import re
import subprocess
import struct


def oracle(edges, nodes):
    adjacency = [[] for _ in range(nodes)]
    for (u, v), count in edges.items():
        if count:
            adjacency[u].append(v)
            adjacency[v].append(u)
    labels = list(range(nodes))
    seen = set()
    for start in range(nodes):
        if start in seen:
            continue
        stack = [start]
        seen.add(start)
        while stack:
            u = stack.pop()
            labels[u] = start
            for v in adjacency[u]:
                if v not in seen:
                    seen.add(v)
                    stack.append(v)
    checksum = 1469598103934665603
    for u, label in enumerate(labels):
        checksum ^= u + 0x9e3779b97f4a7c15 + (label << 6) + (label >> 2)
        checksum = checksum * 1099511628211 & (2**64 - 1)
    return labels, checksum


def paired(edges):
    return [(a, b) for u, v in edges for a, b in ([(u, v)] if u == v else [(u, v), (v, u)])]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--gpu', type=int, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    nodes = 256
    base = [(0, 0), (11, 11), (255, 255)]
    base += [(0, 1), (1, 2), (2, 0), (2, 3), (3, 4), (4, 5), (5, 3)]
    base += [(8, 9), (8, 9), (130, 140), (140, 150), (150, 130)]
    base += [(u, u+1) for u in range(160, 200)]
    original = Counter(paired(base))
    (out/'graph').write_text(''.join(f'{u} {v} 777\n' * count for (u, v), count in sorted(original.items())))
    batches = [([], []), ([(2, 3)], []), ([(0, 1)], []),
               ([(8, 9)], []), ([(8, 9)], [(5, 8)]),
               ([(3, 4), (3, 5)], [(2, 4), (9, 130)]),
               ([(180, 181)], [(150, 190)]),
               ([(210, 211), (11, 11)], [(10, 11)]),
               ([], [(5, 8)]), ([(5, 8)], [(2, 3)])]
    rng = random.Random(20260923)
    for _ in range(6):
        batches.append(([(rng.randrange(nodes), rng.randrange(nodes)) for _ in range(8)],
                        [(rng.randrange(nodes), rng.randrange(nodes)) for _ in range(8)]))
    edges = original.copy()
    expected, updates, sizes = [], [], []
    for deleted, added in batches:
        deleted, added = paired(deleted), paired(added)
        for u, v in deleted:
            edges[u, v] = max(0, edges[u, v]-1)
            updates.append(f'd {u} {v} 999\n')
        expected.append(('CC-DELETE-STAGE-CHECK', oracle(edges, nodes)[1]))
        for u, v in added:
            edges[u, v] += 1
            updates.append(f'a {u} {v} 123\n')
        expected.append(('CC-BATCH-CHECK', oracle(edges, nodes)[1]))
        sizes.append(f'{len(added)} {len(deleted)}\n')
    (out/'updates').write_text(''.join(updates))
    (out/'sizes').write_text(''.join(sizes))
    (out/'domains').write_bytes(struct.pack('<' + 'H'*nodes, *[u % 2 for u in range(nodes)]))
    configs = [('initial', 'block', 'regular', '0', 0, []),
               ('block', 'block', 'regular', '0', len(batches), []),
               ('full_scan', 'block', 'regular', '0', len(batches), []),
               ('merged', 'block', 'large', '0', len(batches), []),
               ('pull', 'block', 'regular', '0', len(batches), []),
               ('thread', 'thread', 'large', '0', len(batches), []),
               ('ordered', 'ordered', 'large', '1', len(batches), []),
               ('uncached', 'block', 'auto', '0', len(batches), ['--cache=0']),
               ('cpu', 'block', 'regular', '0', len(batches), ['--sssp_cpu_partition_capacity=1']),
               ('domains', 'block', 'regular', '0', len(batches), [f'--sssp_cpu_domain_map={out / "domains"}']),
               ('unchecked', 'block', 'large', '0', len(batches), ['--check=false']),
               ('sparse', 'block', 'regular', '0', len(batches), ['--sparse=true'])]
    results = []
    for name, schedule, maintenance, ordered, count, extra in configs:
        env = {k: v for k, v in os.environ.items() if not k.startswith('CG_')}
        env.update(CUDA_VISIBLE_DEVICES=str(args.gpu), CG_INSERTION_SCHEDULE=schedule,
                   CG_BATCH_MAINTENANCE=maintenance, CG_ORDERED_REPAIR=ordered,
                   CG_MUTATION_WORKERS='2', CG_REVERSE_SHARDS='64', CG_COMM_METER='0')
        env['CG_CC_REPAIR'] = 'pull' if name == 'pull' else 'union'
        env['CG_CC_SAMPLED_REPAIR'] = '0' if name == 'full_scan' else '1'
        env['CG_MERGE_PUBLICATION_SOURCES'] = '1' if name == 'merged' else '0'
        output = out/f'{name}.labels'
        command = [str(args.binary.resolve()), f'--graphfile={out/"graph"}',
                   f'--updatefile={out/"updates"}', f'--update_size={out/"sizes"}',
                   '--format=market_big', '--weight_num=0', '--weight=true',
                   '--SEGMENT=32', '--n_stream=3', '--hybrid=0', '--cache=2',
                   '--check=true', '--verbose=false', '--cc_print_checksum=true',
                   f'--cc_max_batches={count}', f'--output={output}'] + extra
        with (out/f'{name}.log').open('w') as log:
            subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=180)
        text = (out/f'{name}.log').read_text()
        if name in ('block', 'merged', 'thread', 'uncached', 'unchecked', 'sparse'):
            assert '[CC-UNION-REPAIR]' in text, name
            assert 'sampled=1' in text, name
            assert not re.search(r'\[B2-GPU-REPAIR\].*affected=[1-9]', text), name
        actual = [(tag, int(value)) for tag, value in re.findall(
            r'\[(CC-DELETE-STAGE-CHECK|CC-BATCH-CHECK)\][^\n]*label_checksum=(\d+)', text)]
        checked = '--check=false' not in extra
        assert actual == (expected if count and checked else []), (name, actual, expected)
        if checked:
            assert '[CC-FINAL-CHECK] passed errors=0' in text, name
        assert 'failed' not in text.lower(), name
        labels, checksum = oracle(edges if count else original, nodes)
        rows = [list(map(int, line.split())) for line in output.read_text().splitlines()]
        assert rows == [[u, label] for u, label in enumerate(labels)], name
        assert re.findall(r'\[CC-FINAL-CHECK\] label_checksum=(\d+)', text) == [str(checksum)]
        results.append(dict(name=name, phase_checks=2*count if checked else 0, state='passed',
                            batch_ms=re.findall(r'\[P0-TIMER\]\[CC\][^\n]*total_batch: ([\d.]+)', text)))
        (out/'result.json').write_text(json.dumps(results, indent=2)+'\n')
    # Entire streams can be empty, not just an individual phase of a mixed stream.
    for name, deleted, added in [('empty', [], []), ('add_only', [], [(2, 3)]),
                                 ('delete_only', [(2, 3)], [])]:
        d, a = paired(deleted), paired(added)
        (out/f'{name}.updates').write_text(''.join(f'd {u} {v} 9\n' for u,v in d) +
                                           ''.join(f'a {u} {v} 7\n' for u,v in a))
        (out/f'{name}.sizes').write_text(f'{len(a)} {len(d)}\n')
        expected_edges = original.copy()
        for e in d: expected_edges[e] -= 1
        for e in a: expected_edges[e] += 1
        output = out/f'{name}.labels'
        cmd = command[:command.index('--sparse=true')] if '--sparse=true' in command else command[:]
        cmd += [f'--updatefile={out/f"{name}.updates"}', f'--update_size={out/f"{name}.sizes"}',
                '--cc_max_batches=1', '--check=true', f'--output={output}']
        with (out/f'{name}.log').open('w') as log:
            subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
        assert [int(line.split()[1]) for line in output.read_text().splitlines()] == oracle(expected_edges, nodes)[0]
        results.append(dict(name=name, state='passed', phase_checks=2))
    contract_cmd = command[:command.index('--sparse=true')] if '--sparse=true' in command else command[:]
    contract_cmd += ['--updatefile=', '--update_size=', '--cc_max_batches=0', '--check=true']
    def contract(name, extra, code, message):
        with (out/f'{name}.log').open('w') as log:
            result = subprocess.run(contract_cmd + extra, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=90)
        assert result.returncode == code, name
        assert message in (out/f'{name}.log').read_text(), name
        results.append(dict(name=name, state='passed', phase_checks=0))
    contract('static', [f'--output={out / "static.labels"}'], 0, '[CC-FINAL-CHECK] passed errors=0')
    assert (out/'static.labels').read_text() == (out/'initial.labels').read_text()
    (out/'asymmetric.graph').write_text('\n'.join(line for line in (out/'graph').read_text().splitlines()
                                                if not line.startswith('1 0 ')) + '\n')
    contract('asymmetric_graph', [f'--graphfile={out / "asymmetric.graph"}'], 0,
             '[CC-INPUT-GRAPH]')
    (out/'asymmetric.updates').write_text('d 2 3 1\n')
    (out/'asymmetric.sizes').write_text('0 1\n')
    contract('asymmetric_updates', [f'--updatefile={out / "asymmetric.updates"}',
             f'--update_size={out / "asymmetric.sizes"}', '--cc_max_batches=1'], 0, '[CC-INPUT-UPDATES]')
    (out/'result.json').write_text(json.dumps(results, indent=2)+'\n')
    print('CC: all labels and per-phase checksums match independent flood-fill', flush=True)


if __name__ == '__main__':
    main()
