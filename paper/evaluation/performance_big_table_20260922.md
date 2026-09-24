# Performance comparison matrix from the 2026-09-21 sweep

Times are the sum of P0 timers. The main tables contain 10 batches per run.
Ratios are diagnostic `original/current` values from single runs and are not yet
correctness-qualified or repeated formal speedups.

## Cache = 2 GB: main batch-size matrix

| Graph | 1K original/current (s) | ratio | 10K original/current (s) | ratio | 100K original/current (s) | ratio | Current usability |
|---|---:|---:|---:|---:|---:|---:|---|
| OK | 0.997703 / 0.037129 | 26.871x | 1.655830 / 0.088451 | 18.720x | 2.461738 / 0.616459 | 3.993x | Preliminary table; add repeats |
| WK | 2.514156 / 0.097310 | 25.837x | 2.992313 / 0.175380 | 17.062x | 4.414476 / 0.865219 | 5.102x | Preliminary table; add repeats |
| TW | 3.382121 / 0.225432 | 15.003x | 3.865290 / 0.334565 | 11.553x | 5.061686 / 1.427084 | 3.547x | Preliminary table; add repeats |
| FS | 8.407039 / 1.336045 | 6.292x | 9.057687 / 1.409551 | 6.426x | 10.405554 / 2.235084 | 4.656x | Preliminary table; add repeats |
| UK | NULL / NULL | NULL | NULL / NULL | NULL | NULL / NULL | NULL | Both systems fail before P0; capacity result only |

## Cache = 4 GB: cache-sensitivity matrix

| Graph | 1K original/current (s) | ratio | 10K original/current (s) | ratio | 100K original/current (s) | ratio | Current usability |
|---|---:|---:|---:|---:|---:|---:|---|
| OK | 1.081776 / 0.035395 | 30.563x | 1.744280 / 0.086861 | 20.081x | 2.552299 / 0.641817 | 3.977x | Preliminary cache-sensitivity table |
| WK | 2.585365 / 0.096614 | 26.760x | 3.093720 / 0.175071 | 17.671x | 4.457804 / 0.832158 | 5.357x | Preliminary cache-sensitivity table |
| TW | 3.470233 / 0.223875 | 15.501x | 3.919414 / 0.348664 | 11.241x | 5.139267 / 1.315804 | 3.906x | Preliminary cache-sensitivity table |
| FS | NULL / NULL | NULL | NULL / NULL | NULL | NULL / NULL | NULL | Both systems OOM; no timing comparison |
| UK | NULL / NULL | NULL | NULL / NULL | NULL | NULL / NULL | NULL | Both systems fail before P0 |

## Current-only extensions in the same sweep

EU and USA use the median of two complete `ordered=1, regular` runs. TW/FS 1M
are separate scaling cohorts with only two batches, so they must not be joined
to the ten-batch curves as if they were the same experiment.

| Graph/cohort | Batch size | Batches | Original (s) | Current (s) | Current mode | Missing experiment |
|---|---:|---:|---:|---:|---|---|
| EU | 10K | 10 | NULL | 31.699242 | ordered + regular | Original plus formal repeats |
| EU | 100K | 10 | NULL | 88.671786 | ordered + regular | Original plus formal repeats |
| EU | 1M | 10 | NULL | 225.989513 | ordered + regular | Original plus formal repeats |
| USA | 10K | 10 | NULL | 12.166775 | ordered + regular | Original plus formal repeats |
| USA | 100K | 10 | NULL | 38.465880 | ordered + regular | Original plus formal repeats |
| USA | 1M | 10 | NULL | 104.236968 | ordered + regular | Original plus formal repeats |
| TW scaling | 1M | 2 | NULL | 1.853709 | unordered + regular | Original and ten-batch same-cohort run |
| FS scaling | 1M | 2 | NULL | 1.958088 | unordered + regular | Original and ten-batch same-cohort run |

## What can be used now

- The cache=2 OK/WK/TW/FS table is the cleanest preliminary graph-by-batch-size
  table. All 12 cells have complete ten-batch timing on both systems.
- The cache=4 OK/WK/TW table can be used as a secondary cache sensitivity table.
- EU/USA current-only values can be used to show current-system scaling, but not
  original/current speedup.
- UK and FS cache=4 are capacity observations, not performance bars.

## Minimum additions for the formal version

1. Repeat the 12 cache=2 OK/WK/TW/FS pairs at least three times using interleaved
   original/current order.
2. Add original EU/USA at 10K, 100K, and 1M under the same resources and batch
   sequence as current ordered mode.
3. Decide whether 1M TW/FS is a formal curve. If yes, run the same cohort and
   number of batches on both systems; do not extrapolate the existing two-batch
   totals to ten batches.
4. Keep cache=4 as a sensitivity table only if it matters to the paper; otherwise
   the cache=2 matrix is sufficient and avoids FS/UK capacity holes.
5. Before calling the ratios speedups, qualify both systems with a common result
   oracle. Until then, label them as timing ratios in the draft.
