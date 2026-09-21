#!/usr/bin/env python3
"""Compare a completed development pair; never treat it as a median result."""
import json
from pathlib import Path
import re
import sys

def read(root):
    root = Path(root)
    status = json.loads((root / 'status.json').read_text())
    if status['status'] != 'complete':
        raise ValueError(f'incomplete run: {root}')
    log = (root / 'run.log').read_text()
    checksums = re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', log)
    if len(checksums) != 1:
        raise ValueError(f'missing final checksum: {root}')
    return status, checksums[0]

a, ac = read(sys.argv[1])
b, bc = read(sys.argv[2])
if (a['argv'][1:] != b['argv'][1:] or a['env'] != b['env'] or a['meter'] != b['meter']
        or a.get('numa_node') != b.get('numa_node')):
    raise ValueError('cohort/settings differ')
if ac != bc or len(a['batches']) != len(b['batches']):
    raise ValueError('distance checksum/batch count differs')
print(json.dumps({'scope': 'single development pair; not repeated median or original-system comparison',
                  'before_ms': a['paper_ms'], 'after_ms': b['paper_ms'],
                  'reduction_percent': 100 * (1-b['paper_ms']/a['paper_ms']),
                  'distance_checksum': ac, 'checksum_match': True}, indent=2))
