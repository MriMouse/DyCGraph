#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_dir="${1:?Provide a fresh run directory}"
python3 "$root/scripts/run_i14_validation.py" "$run_dir" --gpu 0
python3 "$root/scripts/run_i15_hotness_audit.py" "$run_dir/audit" \
    --binary "$run_dir/hybrid_sssp" --require-paired
