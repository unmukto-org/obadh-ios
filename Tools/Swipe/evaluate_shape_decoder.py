#!/usr/bin/env python3
"""Reproducible, offline screening probe for a Bangla shape decoder.

This is deliberately outside the keyboard. Synthetic trails establish whether a
geometric baseline is worth pursuing; they are NOT evidence of human accuracy.
The input is the engine-verified Roman/Bangla/frequency TSV produced by the
Android gesture-vocabulary builder. No Android decoder or binary is used.
"""

import argparse
import math
import time
from pathlib import Path

import numpy as np

QWERTY = ("qwertyuiop", "asdfghjkl", "zxcvbnm")
CENTERS = {
    key: np.array((column + offset, row), dtype=np.float32)
    for row, (letters, offset) in enumerate(zip(QWERTY, (0.0, 0.5, 1.5)))
    for column, key in enumerate(letters)
}


def resample(points: np.ndarray, count: int = 32) -> np.ndarray:
    steps = np.linalg.norm(np.diff(points, axis=0), axis=1)
    cumulative = np.concatenate(([0.0], np.cumsum(steps)))
    keep = np.concatenate(([True], np.diff(cumulative) > 1e-5))
    cumulative, points = cumulative[keep], points[keep]
    if len(points) == 1:
        return np.repeat(points, count, axis=0)
    positions = np.linspace(0, cumulative[-1], count)
    return np.stack(
        [np.interp(positions, cumulative, points[:, axis]) for axis in (0, 1)], axis=-1
    ).astype(np.float32)


def load_rows(path: Path, limit: int):
    best = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        spelling, word, frequency = line.split("\t")
        if not (2 <= len(spelling) <= 28) or any(key not in CENTERS for key in spelling):
            continue
        frequency = int(frequency)
        previous = best.get((spelling, word))
        if previous is None or frequency > previous:
            best[spelling, word] = frequency
    rows = sorted(((spelling, word, frequency) for (spelling, word), frequency in best.items()),
                  key=lambda row: (-row[2], row[0], row[1]))[:limit]
    return rows


def templates_for(rows):
    return np.stack([resample(np.stack([CENTERS[key] for key in spelling]))
                     for spelling, _, _ in rows])


def synthetic_trail(spelling: str, rng: np.random.Generator, noise: float, cut: float):
    keys = np.stack([CENTERS[key] for key in spelling])
    # Off-key landings and rounded corners model two distinct sources of error.
    keys = keys + rng.normal(0, noise, keys.shape).astype(np.float32)
    pieces = [keys[0]]
    for index in range(1, len(keys)):
        start, end = keys[index - 1], keys[index]
        for fraction in (cut, 0.5, 1.0 - cut):
            pieces.append(start + (end - start) * fraction)
        pieces.append(end)
    points = np.stack(pieces)
    return resample(points + rng.normal(0, noise / 3, points.shape).astype(np.float32))


def evaluate(rows, templates, trials, noise, cut, seed):
    rng = np.random.default_rng(seed)
    frequencies = np.array([row[2] for row in rows], dtype=np.float32)
    # Sample log-uniformly across the vocabulary: common and uncommon paths both
    # matter, without allowing the highest-frequency words to dominate the probe.
    weights = np.sqrt(frequencies)
    weights /= weights.sum()
    selected = rng.choice(len(rows), size=trials, replace=True, p=weights)
    starts, ends = templates[:, 0], templates[:, -1]
    top1 = top3 = 0
    durations = []
    for target in selected:
        path = synthetic_trail(rows[target][0], rng, noise, cut)
        begin = time.perf_counter()
        endpoint = np.sum((starts - path[0]) ** 2, axis=1) + np.sum((ends - path[-1]) ** 2, axis=1)
        shortlist = np.argpartition(endpoint, min(2047, len(rows) - 1))[:min(2048, len(rows))]
        shape = np.mean(np.sum((templates[shortlist] - path) ** 2, axis=2), axis=1)
        score = shape + 0.6 * endpoint[shortlist] - 0.055 * np.log1p(frequencies[shortlist])
        leaders = shortlist[np.argsort(score)[:3]]
        durations.append((time.perf_counter() - begin) * 1000)
        target_word = rows[target][1]
        top1 += rows[leaders[0]][1] == target_word
        top3 += any(rows[index][1] == target_word for index in leaders)
    return top1 / trials, top3 / trials, float(np.percentile(durations, 95))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vocabulary", type=Path, help="engine-verified gesture TSV")
    parser.add_argument("--limit", type=int, default=60000)
    parser.add_argument("--trials", type=int, default=300)
    args = parser.parse_args()
    rows = load_rows(args.vocabulary, args.limit)
    if len(rows) < 100:
        parser.error("expected at least 100 valid gesture spellings")
    templates = templates_for(rows)
    print(f"paths={len(rows)} templates={templates.nbytes / 1024 / 1024:.1f} MiB", flush=True)
    for noise, cut in ((0.0, 0.0), (0.15, 0.1), (0.30, 0.2)):
        top1, top3, p95 = evaluate(rows, templates, args.trials, noise, cut, 20261010)
        print(f"noise={noise:.2f} corner_cut={cut:.2f} top1={top1:.3f} "
              f"top3={top3:.3f} host_p95={p95:.2f}ms", flush=True)


if __name__ == "__main__":
    main()
