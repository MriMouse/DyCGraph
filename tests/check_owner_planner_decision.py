#!/usr/bin/env python3
import csv, sys
row = next(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
if row["winner"] != sys.argv[2] or row["memory_eligible"] != "1":
    raise SystemExit(f"unexpected decision: {row}")
