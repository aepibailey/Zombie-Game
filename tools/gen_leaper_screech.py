#!/usr/bin/env python3
"""Generate the leaper's chase-entry screech for Patrol Base Zero.

This sound is STEALTH-CRITICAL, not decoration: it is the player's only
audio tell that the thing now coming at them is a leaper rather than a
walker, and it fires during the 0.5s chase_entry_delay before the leaper
starts accelerating. It therefore has to be:

  - unmistakably distinct from the zombie footstep/death samples (which are
    low, soft, noise-based) -> this is high, tonal and rising
  - readable at range under NVGs when the silhouette is hard to judge
  - short enough to sit inside the 0.5s tell window

Placeholder until a real recording exists.

    python3 tools/gen_leaper_screech.py

Output: assets/audio/zombie/leaper_screech.wav
"""

import math
import os
import random
import struct
import wave

CONFIG = {
    "sample_rate": 22050,
    "duration": 0.55,        # fits inside chase_entry_delay (0.5s) + tail
    "f_start": 420.0,        # rising shriek: start...
    "f_end": 1150.0,         # ...to end
    "vibrato_hz": 24.0,      # rapid warble so it reads as animal, not a siren
    "vibrato_depth": 0.16,   # fraction of instantaneous frequency
    "harmonics": [(1.0, 1.0), (2.0, 0.45), (3.0, 0.28), (4.5, 0.12)],
    "noise_level": 0.30,     # rasp on top of the tone
    "noise_hp_hz": 900,      # keep the rasp bright
    "attack": 0.012,
    "decay_shape": 1.9,
    "peak": 0.92,
    "seed": 20260803,
}

OUT = "assets/audio/zombie/leaper_screech.wav"


def generate(cfg):
    sr = cfg["sample_rate"]
    n = int(sr * cfg["duration"])
    rnd = random.Random(cfg["seed"])

    # One-pole high-pass state for the rasp layer.
    hp_a = math.exp(-2.0 * math.pi * cfg["noise_hp_hz"] / sr)
    prev_in = 0.0
    prev_out = 0.0

    phase = 0.0
    samples = []
    for i in range(n):
        t = i / sr
        frac = i / max(1, n - 1)

        # Exponential sweep reads as more urgent than a linear one.
        f = cfg["f_start"] * (cfg["f_end"] / cfg["f_start"]) ** frac
        f *= 1.0 + cfg["vibrato_depth"] * math.sin(2.0 * math.pi * cfg["vibrato_hz"] * t)

        phase += 2.0 * math.pi * f / sr
        tone = sum(amp * math.sin(mult * phase) for mult, amp in cfg["harmonics"])
        tone /= sum(amp for _, amp in cfg["harmonics"])

        white = rnd.uniform(-1.0, 1.0)
        hp = hp_a * (prev_out + white - prev_in)
        prev_in, prev_out = white, hp

        v = tone + cfg["noise_level"] * hp

        # Fast attack so it cuts through, long-ish exponential decay.
        env = min(1.0, t / cfg["attack"]) if cfg["attack"] > 0 else 1.0
        env *= (1.0 - frac) ** cfg["decay_shape"]
        samples.append(v * env)

    peak = max(abs(s) for s in samples) or 1.0
    scale = cfg["peak"] / peak
    return [int(max(-1.0, min(1.0, s * scale)) * 32767) for s in samples]


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
    print("wrote %s (%d samples, %.2fs)" % (OUT, len(data), len(data) / CONFIG["sample_rate"]))


if __name__ == "__main__":
    main()
