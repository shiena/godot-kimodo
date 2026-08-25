# godot-kimodo

A Godot 4 GDExtension that brings [kimodo.cpp](https://github.com/localai-org/kimodo.cpp)
text-to-motion output into Godot as `Animation` resources.

Kimodo generates SMPL-X 22 motion: parent-local quaternions in XYZW order and a
root translation in meters. All three of those conventions match Godot, so the
mapping onto a `Skeleton3D` and an `Animation` is close to one-to-one. See
[GODOT_INTEGRATION.md](GODOT_INTEGRATION.md) for the full analysis (in Japanese).

## Status

Stage 1 of five. The extension reads the raw `.f32` pair that `kmd-generate`
writes, builds a `Skeleton3D` carrying the SMPL-X rest, and bakes an `Animation`
that plays on it with no retargeting in between. That is the step where the
coordinate system, left versus right, and ground contact get settled, before
retargeting adds a second thing that can be wrong.

Not built yet: retargeting through `BoneMap` onto an arbitrary humanoid rig, the
editor dock, saving to an `AnimationLibrary`, and the default preview built from
`SkeletonProfileHumanoid`.

Nothing here links kimodo.cpp yet. It consumes files that `kmd-generate` has
already written, so it can be developed and tested without the model weights.

## Classes

`KimodoMotion` (`Resource`) holds one clip.

| Member | Purpose |
|---|---|
| `load_directory(dir)` | Reads `local_rotations_xyzw.f32` and `root_positions.f32` from a `kmd-generate` OUT_DIR |
| `load_files(rotations, root_positions)` | The same, with explicit paths |
| `frame_count`, `fps`, `get_duration()` | Frame count comes from the file size; fps defaults to 30 |
| `get_local_rotation(frame, joint)` | Parent-local quaternion, normalized |
| `get_root_position(frame)` | Pelvis world position in meters |
| `get_global_rotation(frame, joint)` | Accumulated down the parent chain. This is the `D[j]` the retargeting correction needs |
| `get_global_positions(frame)` | Forward kinematics over the SMPL-X rest offsets |
| `bake_animation(skeleton_path)` | 22 rotation tracks plus one pelvis position track |

`KimodoSmplx` (static) holds the skeleton reference data and builds preview nodes.

| Member | Purpose |
|---|---|
| `get_parents()`, `get_joint_names()` | The 22-joint hierarchy, matching `motion_decode.cpp` |
| `get_humanoid_bone_names()` | The `SkeletonProfileHumanoid` name for each joint, for stage 2 |
| `get_rest_offsets()`, `get_rest_positions()`, `get_rest_height()` | Rest pose, needed to scale the pelvis position when retargeting |
| `create_rest_skeleton()` | A fresh 22-bone `Skeleton3D`. Every rest rotation is identity, so the rest is translation only |
| `build_mannequin(skeleton, owner)` | Hangs boxes and capsules off the bones. Left limbs warm, right limbs cold, spine grey, with a yellow nose marker for facing |

The rest offsets are not in the motion GGUF, so `src/smplx22.cpp` duplicates the
table that `kimodo.cpp/demo/index.html` calibrated from the upstream fixture.
Once the converter and the C API expose the rest pose, that table can go.

## Build

Needs SCons, Python 3 and a C++17 toolchain. On Windows that means MSVC; on
Linux, GCC or Clang.

```sh
git submodule update --init godot-cpp
scons
```

The build writes `project/bin/windows/` or `project/bin/linux/`, which is where
`project/bin/kimodo.gdextension` looks. Add `target=editor` once there is an
editor plugin to build; the debug template is what the editor loads today.

Only x86_64 Linux and Windows are listed in the `.gdextension`, because those are
the platforms kimodo.cpp itself supports: it needs a C++23 compiler and the GGML
Vulkan backend, and its 8B LLM2Vec text encoder needs desktop-class VRAM.

## Preview

`project/smplx_preview.tscn` plays a clip on the rest skeleton and reads out the
things stage 1 has to confirm: root position, both wrist positions, the pelvis
facing vector, and how close the lowest joint sits to the ground plane.

Without real weights, generate a synthetic clip first. It walks forward along +Z
and raises the left arm, so a left/right flip or a 180 degree facing error shows
up immediately:

```sh
python scripts/make_sample_motion.py project/motion_sample
```

Then open `project/` in Godot and run it, or point it at real output:

```sh
godot --path project -- --motion=/path/to/kmd-generate/out
```

Drag to orbit, wheel to zoom, space to play or pause, left and right arrows to
step a frame at a time.

## Test

```sh
godot --headless --path project --import
godot --headless --path project -s res://tools/verify_stage1.gd
```

This checks the wiring only: file layout, quaternion component order, forward
kinematics, and that a baked `Animation` drives the bones its tracks name. It
runs against the synthetic fixture, so it confirms nothing about the real
model's conventions. That check needs generated output and a look at the
preview.
