# Original dataset count audit

Run from the repository root:

```sh
python3 paper/evaluation/dataset_audit/verify.py
```

The script resolves each original source through `data/paper_data/<name>/ready.json`,
compiles a temporary single-threaded counter, and scans every original edge record.
Results are saved in `source_counts.json`. Sources are opened read-only.

- `edge_records`: parsed records, excluding comments and Matrix Market dimensions.
  Duplicate endpoint pairs and self-loops count as stored records. Symmetric Matrix
  Market data are not expanded into reciprocal edges, matching workload generation.
- `distinct_endpoint_vertices`: distinct IDs occurring at either endpoint, counted
  with a bitmap; this is not the maximum ID plus one and excludes isolated vertices
  absent from the edge list.
- `source_header`: original Matrix Market dimensions or Friendster header for
  comparison with the independently scanned counts.
- `matches_generation_source`: source size and modification time agree with the
  generation manifest. The script also checks that sources do not change during
  scanning and that scanned edge counts agree with the generation manifest.

Twitter uses one little-endian packed uint64 per edge (two uint32 endpoint IDs),
following the workload generator's reader. Its scanned count is additionally
checked against file size divided by eight. The scanner reuses the generator's
parser but computes vertex counts independently over the full source.

These are full-source counts, not the smaller initial snapshots. For batch size
`b`, each generated initial graph withholds `5*b` insertion records; ten batches
each contain `b/2` insertions and `b/2` deletions.
