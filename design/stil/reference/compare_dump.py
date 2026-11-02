#!/usr/bin/env python3
"""Compare a Swift dump of every entry (ParityTests) with the Python reference.
    python3 compare_dump.py STIL.txt swift_all.json"""
import json
import sys

from stil_reference import parse, read_stil, build_entry, initials_index, initials_for


def norm(x):
    # Swift's JSONEncoder omits nil optionals; Python writes null. Compare without nulls.
    if isinstance(x, dict):
        return {k: norm(v) for k, v in x.items() if v is not None}
    if isinstance(x, list):
        return [norm(v) for v in x]
    return x


entries = parse(read_stil(sys.argv[1]))
idx = initials_index(entries)
swift = json.load(open(sys.argv[2], encoding="utf-8"))
diff = [p for p, r in entries.items()
        if norm(build_entry(r, initials=initials_for(p, idx))) != norm(swift.get(p))]
print(f"{len(entries)} entries, {len(diff)} differ")
for p in diff[:5]:
    print("  ", p)
sys.exit(1 if diff else 0)
