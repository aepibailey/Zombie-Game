#!/usr/bin/env python3
"""Generate the AH-64's 30mm burst for Patrol Base Zero.

Placeholder for a real recording. This is the sound of a BURST ARRIVING, not
a gun firing next to you: it plays at the impact point (AreaDamageProfile
.sfx_detonate on apache_30mm.tres), because the aircraft is a quarter-
kilometre off and what the player actually experiences is rounds striking
the ground nearby.

Structure, and why it is built this way:

- A train of DISCRETE impulses rather than one continuous noise burst. The
  M230 is a chain gun, not a rotary cannon — you hear individual reports
  hammering, not the GAU-8's saw. Making the impulses discrete is the single
  thing that keeps this from reading as an A-10.
- Impulse count and spacing are derived from the SAME numbers the gun
  actually uses (rounds_per_burst over burst_duration on apache.tres), so
  the sound is as long as the burst is and has as many reports as it fires.
  Change those numbers and re-run this.
- Each impulse is a sharp crack plus a short low thump — a 30mm HEDP round
  hitting dirt, not a rifle shot.
- A single low rumble tail underneath the whole train ties the reports into
  one event instead of twenty separate ones, and outlasts them slightly.

Deliberately distinct from grenade_blast.wav (one big descending thump) and
from gunshot.wav (one short crack): this is many mid-weight cracks in fast
succession over a common rumble.

    python3 tools/gen_apache_30mm.py

Output: assets/audio/fx/apache_30mm.wav
"""

import math
import os
import random
import struct
import wave

CONFIG = {
    "sample_rate": 22050,
    # Matches ApacheConfig.burst_duration (0.8s) plus tail for the rumble to
    # decay after the last round lands.
    "burst_duration": 0.80,
    "tail_extra": 0.85,
    # Matches ApacheConfig.rounds_per_burst.
    "rounds": 20,
    "jitter": 0.0035,        # per-impulse timing scatter, so it isn't a machine
    # Per-impulse crack (the report). MUST stay shorter than the round
    # spacing (burst_duration / rounds = 40ms) or consecutive rounds overlap
    # and the train smears into one continuous wash — which is exactly the
    # rotary-cannon sound this is trying not to be.
    "crack_dur": 0.018,
    "crack_level": 1.00,
    "crack_lp_hz": 5200,     # rolled off — distant, not in your face
    # Per-impulse thump (the round striking earth). Same constraint.
    "thump_hz_start": 190.0,
    "thump_hz_end": 68.0,
    "thump_dur": 0.030,
    "thump_level": 0.72,
    # Common rumble under the whole train.
    "rumble_level": 0.34,
    "rumble_lp_hz": 520,
    "rumble_decay": 2.1,
    "peak": 0.95,
    "seed": 20260826,
}

OUT = "assets/audio/fx/apache_30mm.wav"


def generate(cfg):
    sr = cfg["sample_rate"]
    total = cfg["burst_duration"] + cfg["tail_extra"]
    n = int(sr * total)
    rnd = random.Random(cfg["seed"])

    # Impulse onsets, evenly spread across the burst with a little scatter.
    spacing = cfg["burst_duration"] / max(1, cfg["rounds"])
    onsets = []
    for r in range(cfg["rounds"]):
        t = r * spacing + rnd.uniform(-cfg["jitter"], cfg["jitter"])
        onsets.append(max(0.0, t))
    onsets.sort()
    # Per-round level variation so the train breathes instead of stuttering.
    levels = [rnd.uniform(0.82, 1.0) for _ in onsets]

    crack_a = math.exp(-2.0 * math.pi * cfg["crack_lp_hz"] / sr)
    rumble_a = math.exp(-2.0 * math.pi * cfg["rumble_lp_hz"] / sr)
    crack_lp = 0.0
    rumble_lp = 0.0
    # One running phase per impulse would be 20 oscillators; instead each
    # impulse gets its own phase accumulator only while it is sounding.
    phases = [0.0] * len(onsets)

    out = []
    for i in range(n):
        t = i / sr
        frac = i / max(1, n - 1)

        white = rnd.uniform(-1.0, 1.0)
        crack_lp = crack_a * crack_lp + (1.0 - crack_a) * white
        rumble_lp = rumble_a * rumble_lp + (1.0 - rumble_a) * white

        s = 0.0
        for idx, onset in enumerate(onsets):
            dt = t - onset
            if dt < 0.0 or dt > max(cfg["crack_dur"], cfg["thump_dur"]):
                continue
            lvl = levels[idx]
            # Report: band-limited noise, near-instant decay.
            if dt < cfg["crack_dur"]:
                e = (1.0 - dt / cfg["crack_dur"]) ** 2.2
                s += crack_lp * e * cfg["crack_level"] * lvl
            # Impact: short descending sine, the weight of the round.
            if dt < cfg["thump_dur"]:
                bf = dt / cfg["thump_dur"]
                f = cfg["thump_hz_start"] + (cfg["thump_hz_end"] - cfg["thump_hz_start"]) * bf
                phases[idx] += 2.0 * math.pi * f / sr
                e = (1.0 - bf) ** 1.5
                s += math.sin(phases[idx]) * e * cfg["thump_level"] * lvl

        # Rumble under everything, decaying across the whole file.
        s += rumble_lp * ((1.0 - frac) ** cfg["rumble_decay"]) * cfg["rumble_level"]
        out.append(s)

    peak = max(abs(v) for v in out) or 1.0
    scale = cfg["peak"] / peak
    return [int(max(-1.0, min(1.0, math.tanh(v * scale * 1.10))) * 32767) for v in out]


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
    print("wrote %s (%.2fs, %d impulses)" % (
        OUT, len(data) / CONFIG["sample_rate"], CONFIG["rounds"]))


if __name__ == "__main__":
    main()
