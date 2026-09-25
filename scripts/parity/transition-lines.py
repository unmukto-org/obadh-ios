#!/usr/bin/env python3
"""Track the DEBUG probe's horizontal markers in a simulator recording.

Usage: transition-lines.py VIDEO --width 440 --height 956 > markers.json
Requires ffmpeg and numpy. Geometry is in points; output is sampled at 60 Hz,
not a claim about the device's native frame rate. Intended for portrait iPhone
captures. Frames with fewer than two visible markers are left unclassified.
"""
import argparse
import json
import subprocess
import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video")
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    args = parser.parse_args()
    width, height = args.width, args.height
    process = subprocess.Popen([
        "ffmpeg", "-v", "error", "-threads", "2", "-i", args.video,
        "-vf", f"fps=60,scale={width}:{height}",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"
    ], stdout=subprocess.PIPE)
    frame = 0
    samples = []
    try:
        while True:
            data = process.stdout.read(width * height * 3)
            if not data:
                break
            if len(data) != width * height * 3:
                raise RuntimeError("Truncated video frame")
            # Right of the diagnostic text. Keep the two distant yellow lines;
            # do not infer missing/occluded markers during a transition.
            y0 = int(height * 0.4185)
            a = np.frombuffer(data, np.uint8).reshape(height, width, 3)
            a = a[y0:, int(width * .918):int(width * .985)].astype(float)
            r, g, b = a[..., 0], a[..., 1], a[..., 2]
            yellow = ((r > 175) & (g > 140) & (b < 150) & ((r - b) > 70)).mean(axis=1) > .4
            ys = np.where(yellow)[0] + y0
            if len(ys):
                groups = np.split(ys, np.where(np.diff(ys) > 3)[0] + 1)
                if len(groups) >= 2:
                    samples.append({"frame": frame, "t": round(frame / 60, 3),
                                    "lines": [round(float(x.mean()), 2) for x in groups]})
            frame += 1
        if process.wait() != 0:
            raise RuntimeError("ffmpeg failed")
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            process.wait()
    print(json.dumps({"sample_hz": 60, "total_frames": frame, "samples": samples}, indent=2))


if __name__ == "__main__":
    main()
