#!/usr/bin/env python3
"""Generate the explosion report for Patrol Base Zero's area-damage system.

Placeholder for a real recording. Structure: a sharp transient crack, a
low-frequency body thump that decays slowly, and a long filtered-noise tail
standing in for debris and reflections off the treeline.

Deliberately much longer and lower than the gunshot sample so a detonation is
never mistaken for weapons fire at range.

    python3 tools/gen_blast_audio.py

Output: assets/audio/fx/grenade_blast.wav
"""

import math
import os
import random
import struct
import wave

CONFIG = {
    "sample_rate": 22050,
    "duration": 1.60,
    "crack_dur": 0.045,      # initial transient
    "crack_level": 1.00,
    "body_hz_start": 110.0,  # pitch-descending thump = "big"
    "body_hz_end": 32.0,
    "body_dur": 0.55,
    "body_level": 0.95,
    "tail_level": 0.55,
    "tail_lp_hz": 1100,      # rumble/debris
    "tail_decay": 2.6,
    "peak": 0.95,
    "seed": 20260803,
}

OUT = "assets/audio/fx/grenade_blast.wav"


def generate(cfg):
    sr = cfg["sample_rate"]
    n = int(sr * cfg["duration"])
    rnd = random.Random(cfg["seed"])

    lp_a = math.exp(-2.0 * math.pi * cfg["tail_lp_hz"] / sr)
    lp = 0.0
    phase = 0.0
    out = []

    for i in range(n):
        t = i / sr
        frac = i / max(1, n - 1)

        # 1. Transient crack: full-band noise, near-instant decay.
        crack = 0.0
        if t < cfg["crack_dur"]:
            e = (1.0 - t / cfg["crack_dur"]) ** 2.0
            crack = rnd.uniform(-1.0, 1.0) * e * cfg["crack_level"]

        # 2. Body: descending sine, the "weight" of the blast.
        body = 0.0
        if t < cfg["body_dur"]:
            bf = frac / (cfg["body_dur"] / cfg["duration"])
            f = cfg["body_hz_start"] + (cfg["body_hz_end"] - cfg["body_hz_start"]) * min(1.0, bf)
            phase += 2.0 * math.pi * f / sr
            e = (1.0 - t / cfg["body_dur"]) ** 1.6
            body = math.sin(phase) * e * cfg["body_level"]

        # 3. Tail: low-passed noise rumble over the whole event.
        white = rnd.uniform(-1.0, 1.0)
        lp = lp_a * lp + (1.0 - lp_a) * white
        tail = lp * ((1.0 - frac) ** cfg["tail_decay"]) * cfg["tail_level"]

        out.append(crack + body + tail)

    peak = max(abs(s) for s in out) or 1.0
    scale = cfg["peak"] / peak
    # Soft clip so the transient stays punchy without hard digital edges.
    return [int(max(-1.0, min(1.0, math.tanh(s * scale * 1.15))) * 32767) for s in out]


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(root, OUT)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = generate(CONFIG)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(CONFIG["sample_rate"])
        w.writeframes(b"".join(struct.pack("<h", s) for s in data))
    print("wrote %s (%.2fs)" % (OUT, len(data) / CONFIG["sample_rate"]))


if __name__ == "__main__":
    main()
