#!/usr/bin/env python3
"""Measures FaceID's recognition on Labeled Faces in the Wild: the standard 10-fold accuracy and, more important for
unlocking, how often the owner is recognized when a stranger may pass only once in 1 000 … 1 000 000 comparisons.
The thresholds of Strictness (Sources/FaceID/AppSettings.swift) come from this table.

    python3 scripts/eval_lfw.py <folder with lfw/ and pairs.txt>

LFW: https://ndownloader.figshare.com/files/5976018 (lfw.tgz, SHA-256 055f7d9c…) and
https://ndownloader.figshare.com/files/5976006 (pairs.txt). Needs numpy (scripts/fetch_models.sh installs it into
Vendor/downloads/venv) and builds faceid-cli in release mode.

October 2026 result (SFace fp16, Vision alignment): accuracy 99.48 %; at a false accept rate of 1e-4 the threshold is
0.418 (98.2 % of the owner's photos pass), 1e-5 → 0.468 (96.8 %), 1e-6 → about 0.53 (91 %)."""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main(folder):
    lines = open(os.path.join(folder, "pairs.txt")).read().split("\n")
    folds, per = map(int, lines[0].split())
    path = lambda name, n: os.path.join(folder, "lfw", name, f"{name}_{int(n):04d}.jpg")
    pairs = []
    for line in lines[1:]:
        p = line.split("\t")
        if len(p) == 3:
            pairs.append((path(p[0], p[1]), path(p[0], p[2]), 1))
        elif len(p) == 4:
            pairs.append((path(p[0], p[1]), path(p[2], p[3]), 0))
    images = sorted({a for a, _, _ in pairs} | {b for _, b, _ in pairs})
    index = {p: i for i, p in enumerate(images)}
    identity = np.array([os.path.basename(os.path.dirname(p)) for p in images])

    subprocess.run(["swift", "build", "-c", "release", "--product", "faceid-cli"], cwd=ROOT, check=True,
                   env={k: v for k, v in os.environ.items() if k != "SDKROOT"})
    with tempfile.TemporaryDirectory() as work:
        listing, output = os.path.join(work, "list.txt"), os.path.join(work, "embeddings.f32")
        open(listing, "w").write("\n".join(images) + "\n")
        subprocess.run([os.path.join(ROOT, ".build/release/faceid-cli"), "embed", listing, output, "--center"], check=True)
        E = np.fromfile(output, np.float32).reshape(-1, 128)

    ok = np.linalg.norm(E, axis=1) > 0
    P = np.array([(index[a], index[b], same) for a, b, same in pairs])
    scores = np.einsum("ij,ij->i", E[P[:, 0]], E[P[:, 1]])
    scores[~(ok[P[:, 0]] & ok[P[:, 1]])] = -1
    same = P[:, 2].astype(bool)
    accuracies = []
    for k in range(folds):
        test = np.zeros(len(P), bool)
        test[k * per * 2:(k + 1) * per * 2] = True
        candidates = np.sort(scores[~test])
        best = max(candidates, key=lambda t: np.mean((scores[~test] >= t) == same[~test]))
        accuracies.append(np.mean((scores[test] >= best) == same[test]))
    print(f"no face found in {np.sum(~ok)} of {len(images)} photos")
    print(f"LFW accuracy {np.mean(accuracies) * 100:.2f}% ± {np.std(accuracies) * 100:.2f}")

    # The owner: every pair of photos of the same person; strangers: 3 million random pairs of different people.
    found = np.where(ok)[0]
    by_person = {}
    for i in found:
        by_person.setdefault(identity[i], []).append(i)
    genuine = np.array([E[a] @ E[b] for v in by_person.values() for x, a in enumerate(v) for b in v[x + 1:]])
    rng = np.random.default_rng(0)
    a, b = rng.choice(found, 3_000_000), rng.choice(found, 3_000_000)
    different = identity[a] != identity[b]
    impostor = np.einsum("ij,ij->i", E[a[different]], E[b[different]])
    print(f"{len(genuine)} pairs of the same person, {len(impostor)} pairs of different people")
    for far in [1e-3, 1e-4, 1e-5, 1e-6]:
        threshold = np.quantile(impostor, 1 - far)
        print(f"  strangers pass {far:.0e}: threshold {threshold:.3f}, the owner passes {np.mean(genuine >= threshold) * 100:.1f}%")
    print(json.dumps({"accuracy": float(np.mean(accuracies))}))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
