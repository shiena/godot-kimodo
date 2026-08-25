# godot-kimodo

A Godot 4 GDExtension that brings [kimodo.cpp](https://github.com/localai-org/kimodo.cpp)
text-to-motion output into Godot as `Animation` resources.

Kimodo generates SMPL-X 22 motion: parent-local quaternions in XYZW order and a
root translation in meters. All three of those conventions match Godot, so the
mapping onto a `Skeleton3D` and an `Animation` is close to one-to-one. See
[GODOT_INTEGRATION.md](GODOT_INTEGRATION.md) for the full analysis (in Japanese).

## Status

The whole path is in place: read a clip, retarget it onto a rig, preview it,
save it. What is not confirmed is the part only generated output can settle --
whether the real model agrees with the coordinate system, the left/right
assignment and the facing axis assumed here. The checks below run against a
synthetic clip, so they prove the wiring and nothing about the model.

Generation runs `kmd-generate` as a separate process rather than through the
GDExtension. The text encoder is an 8B LLM2Vec, and sharing the editor's Vulkan
device with it means competing for VRAM and taking the editor down with a failed
generation. `_spawn_generator()` in the dock is the only place that knows how
generation is invoked, so linking kimodo.cpp directly later is a contained
change.

## Classes

`KimodoMotion` (`Resource`) holds one clip.

| Member | Purpose |
|---|---|
| `load_directory(dir)` | Reads `local_rotations_xyzw.f32` and `root_positions.f32` from a `kmd-generate` OUT_DIR |
| `load_files(rotations, root_positions)` | The same, with explicit paths |
| `frame_count`, `fps`, `get_duration()` | Frame count comes from the file size; fps defaults to 30 |
| `get_local_rotation(frame, joint)` | Parent-local quaternion, normalized |
| `get_root_position(frame)` | Pelvis world position in meters |
| `get_global_rotation(frame, joint)` | Accumulated down the parent chain |
| `get_global_positions(frame)` | Forward kinematics over the SMPL-X rest offsets |
| `bake_animation(skeleton_path)` | 22 rotation tracks plus one pelvis position track, for a skeleton carrying the SMPL-X rest verbatim |

`KimodoSmplx` (static) holds the skeleton reference data and builds preview rigs.

| Member | Purpose |
|---|---|
| `get_parents()`, `get_joint_names()` | The 22-joint hierarchy, matching `motion_decode.cpp` |
| `get_humanoid_bone_names()` | The `SkeletonProfileHumanoid` name for each joint |
| `get_rest_offsets()`, `get_rest_positions()`, `get_rest_height()` | Rest pose, and the height the retarget scale is measured against |
| `create_rest_skeleton()` | A fresh 22-bone `Skeleton3D` under SMPL-X joint names |
| `create_humanoid_skeleton()` | The same rest under profile bone names, so the no-model preview is a retarget target like any other |
| `build_mannequin(skeleton, owner)` | Hangs boxes and capsules off the bones. Left limbs warm, right limbs cold, spine grey, with a yellow nose marker for facing |

`KimodoRetarget` (static) drives an arbitrary humanoid rig.

| Member | Purpose |
|---|---|
| `resolve_bones(skeleton, bone_map)` | Target bone per SMPL-X joint. A null bone map matches profile names directly |
| `describe_mapping(skeleton, bone_map)` | What resolved, what did not, and the rest heights behind the scale |
| `get_scale(skeleton, bone_map)` | Rest height ratio, measured over the mapped joints only |
| `bake_animation(motion, skeleton, bone_map, path)` | Rotation tracks for the mapped bones plus the scaled pelvis translation |
| `build_mannequin(skeleton, bone_map, owner)` | Preview geometry for a mapped rig |

`KimodoLibrary` (static) writes the result out.

| Member | Purpose |
|---|---|
| `save_animation(animation, path)` | One clip on its own; missing directories are created |
| `save_to_library(animation, library_path, name)` | Adds or replaces a name in an `AnimationLibrary`, creating it if needed |
| `attach_library(player, library_path, library_name)` | Loads a saved library onto an `AnimationPlayer` |

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
`project/bin/kimodo.gdextension` looks. The editor dock is GDScript under
`project/addons/kimodo/`, so it needs no build of its own.

Only x86_64 Linux and Windows are listed in the `.gdextension`, because those are
the platforms kimodo.cpp itself supports: it needs a C++23 compiler and the GGML
Vulkan backend, and its 8B LLM2Vec text encoder needs desktop-class VRAM.

## The dock

Enable **Kimodo** under Project Settings > Plugins and the dock appears on the
right. Its Setup pane downloads the weights and points at `kmd-generate`; the
rest of the panel generates a clip, or loads an OUT_DIR that already exists,
bakes it onto the selected `Skeleton3D`, and saves the result.

### Weights

The Setup pane fetches both published repositories and verifies every file
against the manifest the same way `scripts/download_gguf_weights.sh` does. That
is 1.05 GiB of motion GGUF and 14.14 GiB of text bundle, split across 36 files,
and neither repository needs an access token.

The transfer runs through **curl**, which is the one external dependency the
addon has. It ships with Windows 10 and later, macOS, and effectively every
Linux distribution. curl is used rather than `HTTPRequest` because it resumes a
partial file: over 15 GiB a dropped connection is a matter of when, not whether,
and `HTTPRequest` would restart the file it was on.

### Runtime knobs

kimodo.cpp reads three environment variables, and `OS.create_process()` takes no
environment, so the dock sets them on the editor process and lets `kmd-generate`
inherit them.

| Setting | Variable | Effect |
|---|---|---|
| Text layers per chunk | `KIMODO_TEXT_LAYER_CHUNK` | 1 to 32, default 8. Fewer layers lowers peak VRAM and costs speed |
| Backend | `KIMODO_BACKEND` | `cpu` forces the CPU backend; anything else tries Vulkan first |
| CPU threads | `KIMODO_THREADS` | Only applies on the CPU backend; 0 leaves it to the machine |

`kmd-generate` takes seven positional arguments and nothing else, so the two
classifier-free guidance weights it passes are fixed at 2.0. Exposing them would
mean widening that command line first.

### Where each setting lives

**Editor settings** (`kimodo/`, per machine, never in version control) hold what
is true of this machine: where `kmd-generate` and the multi-gigabyte weights sit,
what this GPU and CPU can take, and a personal access token.

**Project settings** (`kimodo/`, committed in `project.godot`) hold what the
project agrees on: which repositories to fetch and at which revision, where
generated output and the shared `AnimationLibrary` live, the house defaults for
frames and steps, and the project's `BoneMap`.

The prompt and the seed live in neither. They belong to one invocation.

## Preview scene

`project/smplx_preview.tscn` plays a clip and reads out the things that have to
be judged by eye: root position, both hands, the hips facing vector, and how
close the lowest bone sits to the ground plane. Press T to cycle the target
between the raw SMPL-X rest, the humanoid-named rest reached through the
retargeting path, and an imported model.

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
godot --headless --path project -s res://tools/verify_stage2.gd
godot --headless --path project -s res://tools/verify_stage4.gd
```

Stage 1 covers the file layout, the quaternion component order, forward
kinematics, and that a baked `Animation` drives the bones its tracks name.
Stage 2 covers retargeting, including a rig with prefixed bone names behind a
`BoneMap`, rest rotations that are not identity, and an unmapped twist bone
between two mapped ones. Stage 4 covers saving and library management.

All three run against the synthetic fixture and confirm nothing about the real
model's conventions. That check needs generated output and a look at the
preview.
