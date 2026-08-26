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
| `get_rest_offsets()`, `get_rest_positions()`, `get_rest_height()` | Rest pose as SMPL-X publishes it, pelvis at the origin, and the height the retarget scale is measured against |
| `get_ground_offset()` | How far the pelvis is lifted so the skeletons below stand on y = 0 |
| `create_rest_skeleton()` | A fresh 22-bone `Skeleton3D` under SMPL-X joint names, standing on the floor |
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
git submodule update --init --recursive
scons
```

The build writes `project/bin/windows/` or `project/bin/linux/`, which is where
`project/bin/kimodo.gdextension` looks. The editor dock is GDScript under
`project/addons/kimodo/`, so it needs no build of its own.

### kmd-generate

`scons` also builds `kmd-generate` from kimodo.cpp and puts it, with the shared
libraries it loads, in `project/addons/kimodo/bin/<platform>/`. The dock looks
there first, so nothing has to be configured to generate a motion.

SCons drives CMake for this rather than compiling it itself: reproducing that
build would mean reproducing GGML and the compilation of its Vulkan shaders as
well. It needs, on top of the above:

- cmake 3.25 or newer
- the Vulkan SDK, for the `glslc` that compiles the GGML Vulkan shaders
- the `ggml` submodule inside kimodo.cpp, which `--recursive` above brings in

Any of those missing is a skip with a warning rather than a failure, because the
addon still reads, retargets and saves a motion that kmd-generate wrote earlier.
Pass `kimodo_native=no` to skip it deliberately.

On Windows, SCons hands CMake the MSVC environment it has already located, so no
developer command prompt is needed, and it finds the cmake that ships as a
Visual Studio component rather than insisting on one on PATH. The result is
about 55 MB, most of it the Vulkan shaders compiled into `ggml-vulkan.dll`.

### Patches

kimodo.cpp's README documents a Linux build, and the pinned revision does not
compile with MSVC. The fixes live in `patches/` and SCons applies them to the
submodule working tree before configuring, so they stay visible instead of
turning into edits nobody can see. Each is skipped when already applied.

| Patch | What it fixes |
|---|---|
| `0001-narrow-path-for-gguf_init_from_file.patch` | `std::filesystem::path::value_type` is `wchar_t` on Windows, so `path.c_str()` is not the narrow string `gguf_init_from_file` takes |
| `0002-include-stdexcept.patch` | `std::runtime_error` used without `<stdexcept>`. libstdc++ pulls it in transitively; the MSVC STL does not |

Both belong upstream. `.gitmodules` marks kimodo.cpp `ignore = dirty` so the
patched working tree does not show up as a change on every `git status`; the
pinned revision is still what the submodule points at.

Only x86_64 Linux and Windows are listed in the `.gdextension`, because those are
the platforms kimodo.cpp itself supports: it needs a C++23 compiler and the GGML
Vulkan backend, and its 8B LLM2Vec text encoder needs desktop-class VRAM.

## The dock

Enable **Kimodo** under Project Settings > Plugins and the dock appears on the
right. It generates a clip, or loads an OUT_DIR that already exists, bakes it
onto the selected `Skeleton3D`, and saves the result.

A folded **Setup** pane holds the two folder paths, the weight download and the
runtime knobs, and opens itself whenever a file it configures is missing. "Missing" means any of
the 36 files `llm_text_encoder::load()` asks for, so a download that stopped
halfway opens the pane rather than passing for complete. The state is on the
presence line inside the pane and on the pane's own tooltip, so the question
survives the pane being folded.

Download keeps whatever is already in place, which makes it resume an
interrupted fetch and repair a damaged one. Pressing it when all 36 files are
there asks first, and says what it would actually do: compare sizes against the
manifest and re-fetch only a mismatch, which normally transfers nothing but the
two manifests. With **Re-hash existing** ticked it reads 15.2 GiB off disk to
check the contents as well, and the question says that instead.

There is no field for kmd-generate: the addon carries the copy `scons` built,
and a different one is a matter of replacing that file.

A sample `BoneMap` sits at `addons/kimodo/samples/smplx_bone_map.tres`, and
`kimodo/paths/bone_map` starts there. The Target field is an override for one
session and starts empty, showing that setting as its placeholder; `Find target`
re-reads it. It maps the humanoid profile onto SMPL-X joint names, which makes
`KimodoSmplx.create_rest_skeleton()` a valid retarget target and serves as a
worked example of the format. Regenerate it rather than editing it by hand:

```sh
godot --headless --path project -s res://tools/make_smplx_bone_map.gd
```

No map is shipped for Mixamo, VRM or any other rig, because getting one right
means having that rig to check against. Godot fills that gap itself: select a
`BoneMap`, set its profile to `SkeletonProfileHumanoid`, and the inspector
offers auto-mapping against a skeleton.

**Save** retargets onto the Skeleton3D that Target resolved, and differs only
in where the result goes: **Bake** puts it on an `AnimationPlayer` in the open
scene, **Save clip** writes it as a standalone resource. Both name it after
**Clip name**, and **Open folder** reveals the last file saved. Collecting clips
into an `AnimationLibrary` is `KimodoLibrary`'s job from a script; the dock no
longer offers it.

Both need a Skeleton3D in the open scene, because the animation's track paths
are that skeleton's path within it. A scene with no rig in it answers `No
Skeleton3D to bake onto.` on the line under the buttons.

**Preview** at the bottom plays whatever Motion has loaded, on a bundled
mannequin rather than the target rig: the rig belongs to the edited scene and
cannot be in two worlds at once. Click the viewport to take it, which puts an
accent border round the frame; only then do drag and wheel orbit and zoom, and
until then the wheel belongs to the dock scrolling under it. Escape hands it
back, as does a click anywhere else: a button or a field takes the focus itself,
and a press that lands on a label or the gap between two controls is caught by
the dock. The slider scrubs whatever the state. The camera follows the root, and the grid is world-fixed, so travel and
ground contact both have something to read against. The grip under the viewport
drags it taller.

### The mannequin

`addons/kimodo/samples/kimodo_mannequin.glb` is 40 KB, 22 bones and 300
triangles, generated by `scripts/make_mannequin.py`:

```sh
blender --background --python scripts/make_mannequin.py
```

The repository carries the recipe rather than a .blend, and the model is our own
so nothing rides on somebody else's licence. Every humanoid within reach was
wrong in some way: the Godot demo characters are either 24 MB or missing hands
and shoulders, the GDQuest mannequin that Godot's ragdoll demo ships has an
authored rest with folded legs and only two spine bones, and the Khronos test
figures have no clavicles.

It is dimensioned from the same SMPL-X rest the motion is decoded against, so it
maps 22 of 22 at a scale of 1.0, its bones already carry
`SkeletonProfileHumanoid` names, and it already stands on the floor. No BoneMap,
no import-time rest fixing. Left limbs are warm and right cold with a nose on
the facing side, because a grey figure cannot show a mirrored clip.

The preview falls back to procedural capsules when the file is not there, so
stripping it out leaves the addon working.

**Motion** lists every generation under the output directory, newest first.
Picking one is what Target and Save then work on, so an older take can be
revisited without hunting for its folder, and `Open folder` shows it in the file
manager. To work on takes that are somewhere else, point the output directory
there: reading a single OUT_DIR into the dock left it loaded but unlisted, with
Rename and Delete unable to reach it.

A clip still called `gen_<stamp>` is labelled with its prompt; **Rename** gives
the folder a name and the list shows that instead, which is the only way to tell
two takes of one prompt apart. **Delete** sends the folder to the system trash
rather than removing it, because a clip is minutes of GPU time and a list with a
Delete button in it is a list someone will misclick.

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
| Backend | `KIMODO_BACKEND` | Only the exact string `cpu` does anything; everything else means "try Vulkan, fall back to CPU" |
| CPU threads | `KIMODO_THREADS` | Only applies on the CPU backend; 0 leaves it to the machine |
| GPU index | `GGML_VK_VISIBLE_DEVICES` | kimodo.cpp calls `ggml_backend_vk_init(0)`, so picking a GPU means reordering which one is device 0 |
| Spill to system memory | `GGML_VK_ALLOW_SYSMEM_FALLBACK` | Lets a buffer land in host memory when device-local VRAM runs out. It then crosses PCIe on every access |

There is no way to require the GPU. When no Vulkan device answers, the run
falls back to the CPU without saying so.

`kmd-generate` takes seven positional arguments and nothing else, so the two
classifier-free guidance weights it passes are fixed at 2.0. Exposing them would
mean widening that command line first.

### What it takes to run

| | Requirement | Why |
|---|---|---|
| Disk | 15.2 GiB | The published bundle |
| VRAM, Vulkan path | 2 GB in practice, 1002 MiB at the floor | `token_embedding.weight` is one 128256 x 4096 BF16 tensor of 1,050,673,152 bytes, and a tensor cannot be split across buffers. No chunk size gets under it |
| Vulkan | 1.2 | ggml-vulkan refuses to initialise below it |
| RAM, CPU path | The same figures move from VRAM to RAM | The backend allocates from host memory instead |

Those peaks do not add up: `encode()` frees the token embedding before the layer
loop, frees each layer chunk before the next, and the motion weights only load
once the text encoder is done with the prompt.

On Windows, `configure_vulkan_f32_parity()` in kimodo.cpp is compiled out. It is
guarded by `#if defined(__unix__)`, so `GGML_VK_DISABLE_COOPMAT`,
`GGML_VK_DISABLE_COOPMAT2` and `GGML_VK_DISABLE_F16` are not set and the
cooperative-matrix path can convert the F32 reference weights to FP16. Set them
by hand if the output has to match the reference.

### Where each setting lives

All of them are editor settings, under `kimodo/` in Editor Settings, and none of
them is in `project.godot`. The addon runs in the editor and never ships in an
export, so nothing it configures has to reach a running game, while pointing the
weights or the output at another drive is nobody else's business and must not
arrive as a change to a tracked file.

`Settings.register()` declares all fifteen when the plugin loads, so the Editor
Settings dialog lists each one with a range, a file filter or an enum before the
dock has written anything.

The cost is that editor settings belong to the editor rather than to the
project, so the one `res://` path among them, the `BoneMap`, carries into the
next project opened with the same editor. `Settings.bone_map_path()` answers
with the bundled sample when the stored path is not in this project, rather than
hand the retargeter a file that will not open.

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
