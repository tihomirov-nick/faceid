#!/usr/bin/env python3
"""Prints every unique key of L("...") calls in the app and core sources (Swift source form)."""
import re, glob, json, sys
keys = []
for path in sorted(glob.glob("Sources/FaceID/**/*.swift", recursive=True) + glob.glob("Sources/FaceCore/*.swift")):
    src = open(path).read()
    for m in re.finditer(r'\bL\("((?:[^"\\\n]|\\.)*)"', src):
        k = m.group(1)
        if k not in keys:
            keys.append(k)
json.dump(keys, sys.stdout, ensure_ascii=False, indent=0)
