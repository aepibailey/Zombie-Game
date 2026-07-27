#!/usr/bin/env python3
"""Generate placeholder zombie footstep WAVs for Patrol Base Zero.

These are stand-ins for real recordings. Each step is a filtered noise burst
(scuff) plus a low thump (weight), with a fast attack and short decay —
roughly 120-200ms. They only need to be locatable in 3D space.

Re-roll the set by changing the parameters in CONFIG below and re-running:

    python3 tools/gen_placeholder_audio.py

Output: assets/audio/zombie/footstep_01.wav ... footstep_NN.wav
"""

import math
import os
import random
import struct
import wave

# --- CONFIG — tweak these and re-run to re-roll the set --------------------
CONFIG = {
    "count": 5,            # how many variations to generate
    "sample_rate": 22050,
    "dur_min": 0.12,       # seconds (spec: 120-200ms)
    "dur_max": 0.20,
    "attack_min": 0.002,   # seconds of fade-in (keeps it from clicking)
    "attack_max": 0.008,
    "decay_shape_min": 2.0,  # higher = snappier decay
    "decay_shape_max": 3.5,
    "lowpass_hz_min": 1400,  # scuff brightness
    "lowpass_hz_max": 3200,
    "highpass_hz": 180,      # trims mud so it sits in the mix
    "thump_hz_min": 55,      # low-end weight
    "thump_hz_max": 95,
    "thump_level": 0.55,
    "noise_level": 0.75,
    "peak": 0.85,            # final normalisation target
    "seed": 20260727,        # change for a completely different set
}

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "audio", "zombie",
)


def one_pole_lowpass(samples, cutoff_hz, sr):
    """Simple one-pole IIR lowpass."""
    rc = 1.0 / (2.0 * math.pi * cutoff_hz)
    dt = 1.0 / sr
    alpha = dt / (rc + dt)
    out = []
    prev = 0.0
    for x in samples:
        prev = prev + alpha * (x - prev)
        out.append(prev)
    return out


def one_pole_highpass(samples, cutoff_hz, sr):
    """Highpass = signal minus its lowpassed self."""
    low = one_pole_lowpass(samples, cutoff_hz, sr)
    return [x - l for x, l in zip(samples, low)]


def make_footstep(rng, cfg):
    sr = cfg["sample_rate"]
    dur = rng.uniform(cfg["dur_min"], cfg["dur_max"])
    n = int(sr * dur)

    lowpass_hz = rng.uniform(cfg["lowpass_hz_min"], cfg["lowpass_hz_max"])
    thump_hz = rng.uniform(cfg["thump_hz_min"], cfg["thump_hz_max"])
    decay_shape = rng.uniform(cfg["decay_shape_min"], cfg["decay_shape_max"])
    attack = rng.uniform(cfg["attack_min"], cfg["attack_max"])

    # Scuff: shaped noise.
    noise = [rng.uniform(-1.0, 1.0) for _ in range(n)]
    noise = one_pole_lowpass(noise, lowpass_hz, sr)
    noise = one_pole_highpass(noise, cfg["highpass_hz"], sr)

    out = []
    for i in range(n):
        t = i / sr
        frac = i / n
        # Fast attack, exponential-ish decay.
        env_attack = min(1.0, t / attack) if attack > 0 else 1.0
        env_decay = (1.0 - frac) ** decay_shape
        env = env_attack * env_decay

        thump = math.sin(2.0 * math.pi * thump_hz * t) * math.exp(-t / 0.035)
        s = noise[i] * cfg["noise_level"] + thump * cfg["thump_level"]
        out.append(s * env)

    # Normalise to a consistent peak so variations match in loudness.
    peak = max(abs(s) for s in out) or 1.0
    scale = cfg["peak"] / peak
    return [s * scale for s in out]


def write_wav(path, samples, sr):
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        frames = bytearray()
        for s in samples:
            s = max(-1.0, min(1.0, s))
            frames += struct.pack("<h", int(s * 32767))
        w.writeframes(frames)


def main():
    cfg = CONFIG
    os.makedirs(OUT_DIR, exist_ok=True)
    rng = random.Random(cfg["seed"])
    for i in range(1, cfg["count"] + 1):
        samples = make_footstep(rng, cfg)
        path = os.path.join(OUT_DIR, "footstep_%02d.wav" % i)
        write_wav(path, samples, cfg["sample_rate"])
        print("wrote %s (%d samples, %.0fms)" % (
            path, len(samples), 1000.0 * len(samples) / cfg["sample_rate"]))


if __name__ == "__main__":
    main()
