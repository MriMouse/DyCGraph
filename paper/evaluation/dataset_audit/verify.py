"""Compile a streaming counter and audit original sources from ready.json."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
MODES = dict(OK='mtx', WK='text', TW='bin', FS='text', EU='mtx', USA='mtx')


def main():
    results = {}
    with tempfile.TemporaryDirectory(prefix='cg-source-count-') as temporary:
        binary = Path(temporary) / 'count_graph'
        subprocess.run(['g++', '-O3', '-std=c++17', str(OUT / 'count_graph.cpp'),
                        '-o', str(binary)], check=True)
        for dataset, mode in MODES.items():
            metadata = json.loads((ROOT / 'data/paper_data' / dataset / 'ready.json').read_text())
            source = Path(metadata['source']['path'])
            before = source.stat()
            header = None
            if mode == 'mtx':
                with source.open() as stream:
                    header = next(line.strip() for line in stream if not line.startswith('%'))
            elif dataset == 'FS':
                with source.open() as stream:
                    header = ''.join(next(stream) for _ in range(4)).strip()
            print(f'Scanning {dataset}: {source}', flush=True)
            start = time.monotonic()
            counts = json.loads(subprocess.check_output([str(binary), str(source), mode], text=True))
            after = source.stat()
            assert (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns)
            assert counts['edge_records'] == metadata['source_edges']
            if mode == 'bin':
                assert before.st_size == counts['edge_records'] * 8
            results[dataset] = dict(source=str(source), mode=mode, source_header=header,
                bytes=before.st_size, mtime_ns=before.st_mtime_ns,
                matches_generation_source=(before.st_size == metadata['source']['bytes'] and
                                           before.st_mtime_ns == metadata['source']['mtime_ns']),
                matches_generation_edge_count=True, **counts,
                elapsed_seconds=round(time.monotonic() - start, 3))
            (OUT / 'source_counts.json').write_text(json.dumps(results, indent=2) + '\n')
            print(dataset, counts, flush=True)


if __name__ == '__main__':
    main()
