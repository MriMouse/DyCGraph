"""Serial GPU integration check; refuses an occupied GPU 0."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from run_i16_road_validation import gpu_idle, parse_log
if '--cpu-pq' in sys.argv:
    raise SystemExit('CPU road runtime retired; use archived binary for historical replay')

if not gpu_idle():
    raise SystemExit('GPU 0 occupied; smoke not started')
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    graph, updates, sizes = (root / name for name in ('graph.txt', 'updates.txt', 'sizes.txt'))
    edges = sorted({(u, (u+1) % 2048) for u in range(2048)} |
                   {((u+1) % 2048, u) for u in range(2048)})
    graph.write_text(''.join(f'{u} {v}\n' for u, v in edges))
    forward = 'd 0 1 1\nd 1 0 1\na 0 2 1\na 2 0 1\n'
    reverse = 'd 0 2 1\nd 2 0 1\na 0 1 1\na 1 0 1\n'
    updates.write_text(forward + reverse + forward)
    sizes.write_text('2 2\n' * 3)
    snapshot = root / 'snapshot.bin'
    command = [str(ROOT / 'build/hybrid_sssp'), f'--graphfile={graph}', f'--updatefile={updates}',
               f'--update_size={sizes}', '--format=market_big', '--weight_num=1', '--weight=1',
               '--source_node=0', '--SEGMENT=512', '--n_stream=3', '--hybrid=0', '--cache=2',
               '--sssp_cpu_partition_capacity=0', '--check=true', '--verbose=false',
               '--sssp_max_batches=3', '--sssp_print_checksum=true', f'--i16_repair_snapshot={snapshot}']
    log = ROOT / 'logs/i16_capture_smoke.log'
    with log.open('w') as output:
        subprocess.run(command, env={**os.environ, 'CUDA_VISIBLE_DEVICES': '0', 'CG_MUTATION_WORKERS': '20'},
                       stdout=output, stderr=subprocess.STDOUT, check=True, timeout=300)
    result = parse_log(log.read_text(), 3)
    assert result['has_repair_work']
    assert log.read_text().count('[I16-SNAPSHOT]') == 1
    report = ROOT / 'logs/i16_capture_smoke_oracle.json'
    subprocess.run([str(ROOT / 'build/i16_repair_oracle'), str(snapshot), str(report)], check=True)
    assert json.loads(report.read_text())['state'] == 'passed'
    print('Three-batch GPU capture and CPU oracle passed')
