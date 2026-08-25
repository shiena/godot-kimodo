#!/usr/bin/env python3
"""Write a synthetic SMPL-X 22 motion in the format kmd-generate emits.

This is a plumbing fixture, not a validation of the model. It exercises the
file layout, the quaternion component order and the animation track wiring so
that the Godot side can be finished before real weights are available. It says
nothing about whether the real model agrees with these conventions -- that is
exactly what stage 1 has to check against generated output.

The clip walks forward along +Z and raises the LEFT arm, so a left/right flip
or a 180 degree facing error is visible in the preview scene.

    python scripts/make_sample_motion.py project/motion_sample
"""

from __future__ import annotations

import math
import struct
import sys
from pathlib import Path

JOINT_COUNT = 22

# Parent-local rest offsets, duplicated from src/smplx22.cpp.
REST_OFFSET = [
    (0.0, 0.0, 0.0),
    (0.052299, -0.093936, -0.027607),
    (-0.057193, -0.106548, -0.022218),
    (-0.001496, 0.112930, -0.024981),
    (0.058867, -0.416442, -0.006557),
    (-0.048074, -0.397560, -0.014061),
    (0.006900, 0.145636, -0.006859),
    (-0.041738, -0.437584, -0.029512),
    (0.014489, -0.446853, -0.018030),
    (-0.010334, 0.056082, 0.021116),
    (0.049294, -0.065279, 0.126259),
    (-0.040575, -0.065287, 0.127076),
    (-0.011026, 0.171365, -0.028827),
    (0.047725, 0.087643, -0.008375),
    (-0.046636, 0.086612, -0.014864),
    (0.024654, 0.175391, 0.024463),
    (0.126285, 0.057680, -0.013885),
    (-0.109342, 0.053674, -0.009118),
    (0.272907, -0.069853, -0.039094),
    (-0.292029, -0.035440, -0.024565),
    (0.276174, 0.021254, -0.002478),
    (-0.271878, -0.004835, -0.016445),
]

PARENT = [-1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 12, 13, 14, 16, 17, 18, 19]

LEFT_SHOULDER = 16
LEFT_ELBOW = 18

FPS = 30.0
FRAMES = 120
WALK_SPEED = 0.6  # meters per second along +Z


def rest_positions() -> list[tuple[float, float, float]]:
    out: list[tuple[float, float, float]] = []
    for joint, offset in enumerate(REST_OFFSET):
        parent = PARENT[joint]
        base = (0.0, 0.0, 0.0) if parent < 0 else out[parent]
        out.append((base[0] + offset[0], base[1] + offset[1], base[2] + offset[2]))
    return out


def quaternion_about_z(angle: float) -> tuple[float, float, float, float]:
    """Rotation about +Z, which carries +X toward +Y for a positive angle."""
    return (0.0, 0.0, math.sin(angle * 0.5), math.cos(angle * 0.5))


def smoothstep(t: float) -> float:
    t = min(1.0, max(0.0, t))
    return t * t * (3.0 - 2.0 * t)


def main(argv: list[str]) -> int:
    out_dir = Path(argv[1] if len(argv) > 1 else "project/motion_sample")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Stand the pelvis high enough that the lowest rest joint sits on y = 0.
    pelvis_height = -min(position[1] for position in rest_positions())

    rotations = bytearray()
    positions = bytearray()

    for frame in range(FRAMES):
        time = frame / FPS

        # The arm goes up over the first second and comes back down over the last.
        raise_amount = smoothstep(time / 1.0) - smoothstep((time - (FRAMES / FPS - 1.5)) / 1.0)
        shoulder = quaternion_about_z(math.radians(95.0) * raise_amount)
        elbow = quaternion_about_z(math.radians(25.0) * raise_amount)

        for joint in range(JOINT_COUNT):
            if joint == LEFT_SHOULDER:
                quaternion = shoulder
            elif joint == LEFT_ELBOW:
                quaternion = elbow
            else:
                quaternion = (0.0, 0.0, 0.0, 1.0)
            rotations += struct.pack("<4f", *quaternion)

        bob = 0.012 * math.sin(time * 2.0 * math.pi * 1.8)
        positions += struct.pack("<3f", 0.0, pelvis_height + bob, WALK_SPEED * time)

    (out_dir / "local_rotations_xyzw.f32").write_bytes(rotations)
    (out_dir / "root_positions.f32").write_bytes(positions)

    print(f"wrote {FRAMES} frames at {FPS:g} fps to {out_dir}")
    print(f"pelvis height {pelvis_height:.3f} m, forward travel {WALK_SPEED * FRAMES / FPS:.2f} m along +Z")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
