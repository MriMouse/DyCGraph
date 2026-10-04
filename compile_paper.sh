#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEX_DIR="$ROOT_DIR/paper/IEEE-conference-template-062824"
TEX_FILE="$TEX_DIR/IEEE-conference-template-062824.tex"
OUTPUT_DIR="$ROOT_DIR/build/paper"

if ! command -v latexmk >/dev/null 2>&1; then
    echo "Error: latexmk is required. Install latexmk and a LaTeX distribution first." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
latexmk -cd -pdf -outdir="$OUTPUT_DIR" "$TEX_FILE"

echo "PDF created: $OUTPUT_DIR/IEEE-conference-template-062824.pdf"
