"""Opt-in GPU PR regression: signed incremental residuals vs double Jacobi.

Run in the background for the full configuration set; results are saved as each
configuration finishes. No third-party Python packages are needed.
"""
import argparse
from collections import Counter
import json
import math
import os
from pathlib import Path
import re
import subprocess


def oracle(edges, n):
    rows = [[] for _ in range(n)]
    for (u, v), count in edges.items():
        rows[u].extend([v] * count)
    x = [0.0] * n
    for _ in range(1000):
        y = [0.15] * n
        for u, row in enumerate(rows):
            if row:
                value = 0.85 * x[u] / len(row)
                for v in row:
                    y[v] += value
        if sum(abs(a-b) for a, b in zip(x, y)) < n * 1e-12:
            return y
        x = y
    raise AssertionError('CPU oracle failed to converge')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--gpu', type=int, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    n = 4096
    base = [(0, 1), (1, 2), (2, 0), (3, 4), (4, 3), (8, 9), (8, 9),
            (10, 10), (n-1, n-1)]
    base += [(20, v) for v in range(21, 1800)]  # CTA high-degree scheduler
    base += [(v, 20) for v in range(21, 1800)]
    # A short acyclic path (fits the 100-round contract), disconnected components,
    # sinks and isolated vertices. The capped-continuation case tests truncation.
    base += [(v, v+1) for v in range(2000, 2020)]
    original = Counter(base)
    (out/'graph').write_text(''.join(f'{u} {v} 777\n' for u, v in sorted(base)))
    batches = [([], []), ([(2, 0)], []), ([], [(2, 3)]),
               ([(3, 4)], [(3, 4)]), ([(8, 9)], []),
               ([(8, 9), (10, 10)], [(9, 8)]),
               ([(20, v) for v in range(21, 1800, 3)], [(20, 2000), (2020, 20)]),
               ([(2000, 2001), (4000, 4001)], [(0, 8), (3, 10)]),
               ([], [(10, 10), (10, 3), (8, 9), (8, 9)]),
               ([(20, 2000), (2020, 20)], [(2000, 2001)])]
    edges, updates, sizes = original.copy(), [], []
    for deleted, added in batches:
        for u, v in deleted:
            edges[u, v] = max(0, edges[u, v] - 1)
            updates.append(f'd {u} {v} 999\n')
        for u, v in added:
            edges[u, v] += 1
            updates.append(f'a {u} {v} 123\n')
        sizes.append(f'{len(added)} {len(deleted)}\n')
    (out/'updates').write_text(''.join(updates))
    (out/'sizes').write_text(''.join(sizes))
    expected = oracle(edges, n)
    initial = oracle(original, n)
    results = []
    env = {k: v for k, v in os.environ.items() if not k.startswith('CG_')}
    env.update(CUDA_VISIBLE_DEVICES=str(args.gpu), CG_MUTATION_WORKERS='2')
    base_cmd = [str(args.binary.resolve()), f'--graphfile={out / "graph"}',
                '--format=market_big', '--weight=true', '--weight_num=0',
                '--SEGMENT=32', '--n_stream=3', '--hybrid=0', '--verbose=false',
                '--error=1e-6', '--check=true']
    def run(name, extras, code=0):
        with (out/f'{name}.log').open('w') as log:
            proc = subprocess.run(base_cmd + extras, env=env, stdout=log,
                                  stderr=subprocess.STDOUT, timeout=180)
        text = (out/f'{name}.log').read_text()
        assert proc.returncode == code, (name, proc.returncode, text[-3000:])
        return text
    for name, cache, maintenance, merge, checked in [
            ('cached', 2, 'regular', '0', True),
            ('large', 2, 'large', '1', True),
            ('uncached', 0, 'auto', '1', True),
            ('unchecked', 2, 'large', '1', False)]:
        env.update(CG_BATCH_MAINTENANCE=maintenance, CG_MERGE_PUBLICATION_SOURCES=merge)
        env['CG_COMM_METER'] = '1' if name == 'large' else '0'
        output = out/f'{name}.ranks'
        text = run(name, [f'--cache={cache}', f'--updatefile={out / "updates"}',
                         f'--update_size={out / "sizes"}', '--pr_max_batches=99',
                         f'--check={str(checked).lower()}', f'--output={output}'])
        assert 'failed' not in text.lower(), name
        assert len(re.findall(r'\[PR-CHECK\].*passed', text)) == (len(batches)+2 if checked else 0)
        assert len(re.findall(r'\[PR-BATCH\]', text)) == len(batches)
        rows = [line.split() for line in output.read_text().splitlines()]
        assert len(rows) == n
        values = [float(row[1]) for row in rows]
        residual = [float(row[2]) for row in rows]
        assert all(math.isfinite(x) for x in values + residual)
        error = sum(abs(a-b) for a, b in zip(values, expected)) / n
        assert error < 1e-5, (name, error)
        assert max(map(abs, residual)) <= 1.000001e-6
        results.append(dict(name=name, checks=len(batches)+2 if checked else 0,
                            mean_error=error, state='passed'))
        (out/'result.json').write_text(json.dumps(results, indent=2)+'\n')
    # Exercise streams with one or both operation arrays entirely empty.
    for name, deleted, added in [('empty', [], []), ('delete_only', [(2, 0)], []),
                                 ('add_only', [], [(2, 3)])]:
        (out/f'{name}.updates').write_text(''.join(f'd {u} {v} 1\n' for u,v in deleted) +
                                           ''.join(f'a {u} {v} 1\n' for u,v in added))
        (out/f'{name}.sizes').write_text(f'{len(added)} {len(deleted)}\n')
        current = original.copy()
        for e in deleted: current[e] -= 1
        for e in added: current[e] += 1
        reference = oracle(current, n)
        output = out/f'{name}.ranks'
        run(name, ['--cache=2', f'--updatefile={out / (name+".updates")}',
                   f'--update_size={out / (name+".sizes")}', '--pr_max_batches=1', f'--output={output}'])
        actual = [float(line.split()[1]) for line in output.read_text().splitlines()]
        assert sum(abs(a-b) for a,b in zip(actual, reference))/n < 1e-5
        results.append(dict(name=name, state='passed', checks=3))
    output = out/'static.ranks'
    run('static', ['--pr_max_batches=0', '--cache=0', f'--output={output}'])
    values = [float(line.split()[1]) for line in output.read_text().splitlines()]
    assert sum(abs(a-b) for a,b in zip(values, initial))/n < 1e-5
    results.append(dict(name='static', state='passed'))
    # Capped solves must preserve pending residual/frontier across updates.
    output = out/'capped.ranks'
    text = run('capped', ['--pr_max_rounds=1', '--check=false', '--cache=2',
                        f'--updatefile={out / "updates"}',
                        f'--update_size={out / "sizes"}', '--pr_max_batches=99',
                        f'--output={output}'])
    assert len(re.findall(r'\[PR-BATCH\].*rounds=[01] ', text)) == len(batches)
    assert 'stop=iteration_limit' in text
    rows = [line.split() for line in output.read_text().splitlines()]
    x = [float(row[1]) for row in rows]
    r = [float(row[2]) for row in rows]
    degree = [0] * n
    for (u, v), count in edges.items(): degree[u] += count
    next_x = [0.15] * n
    for (u, v), count in edges.items():
        if count: next_x[v] += 0.85 * x[u] * count / degree[u]
    assert sum(abs(a-b-c) for a,b,c in zip(next_x, x, r)) <= 64 * 2**-23 * max(1, sum(map(abs, x)))
    results.append(dict(name='capped_continuation', state='passed'))
    for name, extra, message in [
            ('limit', ['--pr_max_rounds=1'], 'iteration_limit'),
            ('excess_limit', ['--pr_max_rounds=101'], 'pr_max_rounds'),
            ('negative_error', ['--error=-1'], 'finite error'),
            ('ownership', ['--sssp_cpu_partition_capacity=1'], 'incompatible'),
            ('bad_output', [f'--output={out / "missing" / "output"}'], 'Cannot write')]:
        text = run(name, ['--pr_max_batches=0', '--cache=0'] + extra, 1)
        assert message in text, (name, text[-1000:])
        results.append(dict(name=name, state='passed'))
    (out/'result.json').write_text(json.dumps(results, indent=2)+'\n')
    print('PR: dynamic/static oracle and failure contracts passed', flush=True)


if __name__ == '__main__':
    main()
