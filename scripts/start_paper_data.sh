#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output="$root/data/paper_data"
mkdir -p "$output"
if ! command -v ionice >/dev/null; then echo 'ionice is required' >&2; exit 1; fi
if ! command -v flock >/dev/null; then echo 'flock is required' >&2; exit 1; fi
if flock -n "$output/.launch.lock" true && [[ -f "$output/generator.pid" ]] && kill -0 "$(cat "$output/generator.pid")" 2>/dev/null; then
 echo "Generator is already running: PID $(cat "$output/generator.pid")"
 exit 0
fi
setsid nohup nice -n 15 ionice -c 3 flock -n "$output/.generation.lock" \
 env OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 python3 -u "$root/scripts/prepare_paper_data.py" \
 --datasets USA EU OK WK RMAT TW FS UK --output "$output" \
 >> "$output/generation.log" 2>&1 < /dev/null &
pid=$!
echo "$pid" > "$output/generator.pid"
echo "Started paper-data generator PID $pid; log: $output/generation.log"
