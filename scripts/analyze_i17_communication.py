#!/usr/bin/env python3
"""Summarize explicit CUDA API payloads without inferring physical/ZC bytes."""
import collections
import json
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
contract = re.findall(r'\[I17-B7-COMM-CONTRACT\] ([^\n]+)', text)
if len(contract) != 1 or 'Overall: Test passed' not in text:
    raise SystemExit('Expected one completed, successful run with communication metering enabled')
pattern = (r'\[I17-B7-COMM\] batch=(-?\d+) stage=(\w+) category=(\w+) '
           r'direction=(\w+) bytes=(\d+) calls=(\d+)')
rows = []
algorithm = collections.Counter()
for batch, stage, category, direction, size, calls in re.findall(pattern, text):
    batch, size, calls = int(batch), int(size), int(calls)
    rows.append(dict(batch=batch, stage=stage, category=category,
                     direction=direction, bytes=size, calls=calls))
    if batch >= 0 and stage not in ('delete_check', 'batch_check'):
        algorithm[direction] += size
if not rows:
    raise SystemExit('No payload records found')
print(json.dumps({'contract': contract[0],
                  'scope': 'explicit successful CUDA API payload; not a system comparison',
                  'algorithm_payload_bytes_by_direction': dict(algorithm),
                  'records': rows}, indent=2))
