"""I19 asymmetric 1/3 and 3/1 mixed batches, checked by Bellman and CPU PQ."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from run_i16_road_validation import parse_log

busy = subprocess.check_output(['nvidia-smi', '-i', '0', '--query-compute-apps=pid',
                                '--format=csv,noheader'], text=True).strip()
memory = subprocess.check_output(['nvidia-smi', '-i', '0', '--query-gpu=memory.used',
                                  '--format=csv,noheader,nounits'], text=True).strip()
if busy or int(memory):
    raise SystemExit('GPU 0 occupied; smoke not started')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=ROOT / 'logs/i19_20260914_v2/asymmetric_smoke')
parser.add_argument('--binary', type=Path, default=ROOT / 'build/hybrid_sssp')
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(exist_ok=False)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    graph, updates, sizes = [root / name for name in ('graph', 'updates', 'sizes')]
    edges = {(u, (u + 1) % 2048) for u in range(2048)}
    edges.update((u, 1024) for u in range(1024))
    graph.write_text(''.join(f'{u} {v}\n' for u, v in sorted(edges)))
    forward = 'd 0 1024 1\nd 2 3 1\nd 4 5 1\na 1 1025 1\n'
    reverse = 'd 1 1025 1\na 0 1024 1\na 2 3 1\na 4 5 1\n'
    updates.write_text(forward + reverse + forward)
    sizes.write_text('1 3\n3 1\n1 3\n')
    snapshot = out / 'snapshot.bin'
    command = [str(args.binary.resolve()), f'--graphfile={graph}',
               f'--updatefile={updates}', f'--update_size={sizes}', '--format=market_big',
               '--weight_num=1', '--weight=1', '--source_node=0', '--SEGMENT=512',
               '--n_stream=3', '--hybrid=0', '--cache=2', '--sssp_cpu_partition_capacity=0',
               '--check=true', '--verbose=false', '--sssp_max_batches=3',
               '--sssp_print_checksum=true', f'--i16_repair_snapshot={snapshot}']
    with (out / 'run.log').open('w') as log:
        subprocess.run(command, env={**os.environ, 'CUDA_VISIBLE_DEVICES': '0',
            'CG_MUTATION_WORKERS': '20', 'CG_REVERSE_SHARDS': '64',
            'CG_ORDERED_REPAIR': '0', 'CG_COMM_METER': '1'}, stdout=log,
            stderr=subprocess.STDOUT, check=True, timeout=300)
    result = parse_log((out / 'run.log').read_text(), 3)
    assert result['has_repair_work']
    report = out / 'oracle.json'
    subprocess.run([str(ROOT / 'build/i16_repair_oracle'), str(snapshot), str(report)], check=True)
    assert json.loads(report.read_text())['state'] == 'passed'
    print('I19 asymmetric batches: Bellman and CPU PQ oracle passed')
