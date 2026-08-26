# godot-kimodo

Generate character animation from a sentence, inside the Godot editor.

godot-kimodo is an editor addon around [kimodo.cpp](https://github.com/localai-org/kimodo.cpp),
a text-to-motion model that produces SMPL-X skeletal animation. The addon runs
the model, retargets the result onto a `Skeleton3D` in your scene, and hands you
an ordinary Godot `Animation`.

What you save is a plain `Animation` resource. It has no dependency on this
addon, on kimodo.cpp, or on the 15 GiB of weights that produced it, so nothing
here reaches an exported game.

Kimodo emits parent-local quaternions in XYZW order, a root translation in
metres, and 30 frames per second. All three match Godot's own conventions, which
is why the bulk of the work is retargeting rather than conversion.

## Requirements

The model sets the bar, not the addon.

| | Needs | Why |
|---|---|---|
| Disk | **15.2 GiB** | 1.05 GiB of motion GGUF and 14.14 GiB of text bundle, across 36 files |
| VRAM | **2 GB** in practice, 1002 MiB at the floor | `token_embedding.weight` is one 128256 x 4096 BF16 tensor of 1,050,673,152 bytes, and a tensor cannot be split across buffers, so no setting gets under it |
| Vulkan | **1.2** | ggml-vulkan refuses to initialise below it |
| Platform | x86_64 Linux or Windows | kimodo.cpp needs a C++23 compiler and the GGML Vulkan backend, which rules out mobile and web |
| Godot | **4.4** or later | What the extension declares as its `compatibility_minimum`, and the godot-cpp branch it is built against. Development happens on 4.7 |

Those figures are peaks, not a sum. The text encoder frees the token embedding
before its layer loop and frees each chunk of layers before the next, and the
motion weights only load once the prompt is encoded.

With no Vulkan device the run falls back to the CPU and the same figures move
from VRAM to RAM. The fallback is silent, and there is no setting that makes the
GPU mandatory.

## Install

Download `godot-kimodo-vX.Y.Z.zip` from the
[releases](https://github.com/shiena/godot-kimodo/releases) and copy the
`addons/kimodo` folder inside it into your project's `addons/`. One archive
covers both platforms. Enable **Kimodo** under Project Settings > Plugins, and
the dock appears on the right.

The weights are not in the archive. The addon downloads them, once, on first
use.

To compile it yourself instead, see [Building from source](#building-from-source).

## A first clip

1. Open the **Setup** pane and check **Model directory**, which is where the
   weights will land. Press **Download** and leave it: 15.2 GiB takes a while,
   and the pane reports each file as it arrives.
2. Under **Generate**, set the length in frames, type a prompt, and press
   **Generate**. The clip appears in **Motion** when the run finishes, and
   **Preview** plays it on a built-in mannequin.
3. Open a scene containing the rig you want to animate. **Target** finds its
   `Skeleton3D` and reports how many of the 22 joints it could map.
4. Name the clip under **Save**, then press **Bake** to put it on an
   `AnimationPlayer` in that scene, or **Save clip** to write it out as a
   resource.

## The dock

One column, read top to bottom: **Setup**, **Generate**, **Motion**,
**Target**, **Save**, **Preview**. Each section reports on a line of its own, so
an answer appears beside the button that produced it.

### Setup

Holds the parts that are configured once: where files live, which weights to
fetch, and how the generator uses the machine. It stays folded until something
it configures is missing, and opens itself when that happens.

"Missing" means any of the 36 files the text encoder loads, so a download that
stopped halfway opens the pane rather than passing for complete. The presence
line inside the pane and the pane's own tooltip both carry the state, so the
answer survives the pane being folded again.

**Folders** holds the two directories that fill up: where the weights sit, and
where generated clips are written. Both belong to the machine rather than to the
project.

**Weights** fetches two published repositories and checks every file against
their manifests. Neither needs an access token; the field is there for a gated
mirror.

Downloading keeps whatever is already on disk, so it resumes an interrupted
fetch and repairs a damaged one. Pressing it when all 36 files are present asks
first, and says what it would do: compare sizes against the manifest and
re-fetch only a mismatch, which usually transfers nothing but the two manifests.
Ticking **Re-hash existing** reads all 15.2 GiB back to check contents as well,
and the question says so.

Transfers run through **curl**, the addon's one external dependency. It ships
with Windows 10 and later, macOS, and effectively every Linux distribution.
curl resumes a partial file, which over 15 GiB matters: a dropped connection is
a question of when.

**Runtime** is described under [Runtime environment](#runtime-environment).

### Generate

Length in frames, denoising steps, and a seed; then the prompt; then the button.

**+ Add prompt** carries the clip on into another prompt, up to sixteen of them:
"walks forward", then "sits down", then "waves", as one continuous take. The
joins are not crossfades between separate clips. The model is handed the end of
the previous stretch as a constraint on the root, every joint position and the
ankle and wrist orientations, and generates the next stretch from there, so the
body carries over and the character keeps the ground it covered.

**Transition** is how many frames of overlap it gets. Those frames are absorbed
rather than added, so a clip is always as long as its prompts add up to, and the
transition has to be shorter than every prompt after the first. Each prompt in a
sequence is limited to 300 frames, where a single prompt on its own may run to
10000.

A sequence costs what its prompts cost. The 8B text encoder runs once per
prompt, and the denoiser once per stretch.

Generation runs as a separate process. The text encoder is an 8B LLM2Vec model,
and sharing the editor's Vulkan device with it would mean competing for VRAM and
losing the editor to a failed run.

The classifier-free guidance weights are whatever the generator was compiled
with, currently 2.0 each. Nothing on its command line sets them.

### Motion

Every clip under the output directory, newest first. The one picked here is what
Target and Save work on, so an earlier take can be revisited without hunting for
its folder. **Open folder** shows it in the file manager.

A clip is labelled with the prompt that produced it until it is renamed.
**Rename** names the folder itself, and the list shows that name instead, which
is what tells two takes of one prompt apart. **Delete** moves the folder to the
system trash: a clip is minutes of GPU time, and this button sits next to the
one that loads it.

### Target

Two fields, both used on every bake.

**Skeleton** is the rig to animate. It is resolved at the moment a button is
pressed: the selected `Skeleton3D`, or the first one in the open scene. The
report underneath follows the editor's selection, so what it describes is what a
bake would reach.

**Bone map** translates SMPL-X joint names into the names that rig uses. It is
only needed when those names are not `SkeletonProfileHumanoid`'s. The field is a
one-session override of the `kimodo/paths/bone_map` setting, and shows that
setting as its placeholder while it is empty.

The report reads out how many of the 22 joints resolved, which did not, and the
scale between the two rest heights:

```
Skeleton3D  56 bones
mapped 22/22, scale 0.999
every joint resolved
```

A sample map sits at `addons/kimodo/samples/smplx_bone_map.tres` and is where
the setting starts. It pairs the humanoid profile with SMPL-X joint names, so a
rig carrying those names verbatim is a valid target, and it doubles as a worked
example of the format.

For Mixamo, VRM or any other rig, Godot builds the map itself: create a
`BoneMap`, set its profile to `SkeletonProfileHumanoid`, and the inspector
offers to match it against a skeleton automatically.

### Save

Both buttons retarget onto the skeleton Target resolved, and differ only in
where the result goes. **Bake** puts it on an `AnimationPlayer` in the open
scene. **Save clip** writes it as a standalone resource, and reveals it in the
FileSystem dock afterwards.

Both need a `Skeleton3D` in the open scene, because an animation's track paths
are that skeleton's path within it.

**Clip name** names the animation and suggests the file name. It is checked
against both sets of rules, which differ: an `AnimationLibrary` rejects `,` and
`[`, which a file name accepts, and a file name rejects `*`, `?` and `|`, which
a library accepts.

To gather several clips into an `AnimationLibrary`, use the `AnimationPlayer`'s
own Animation panel.

### Preview

Plays the clip that Motion has loaded, on a mannequin bundled with the addon
rather than on the target rig, which belongs to the edited scene and cannot be
in two places at once.

Click the viewport to take it, which lights the frame in the editor's accent
colour. Drag then orbits and the wheel zooms; before that the wheel belongs to
the dock scrolling underneath. Escape releases it, as does clicking anywhere
else. The slider scrubs either way, and the grip below the viewport drags it
taller.

The camera follows the root while the grid stays fixed to the world, so travel
and ground contact both have something to read against.

The mannequin is dimensioned from the same rest pose the motion is decoded
against, so it maps all 22 joints at a scale of 1.0 and stands on the floor
without adjustment. Its left limbs are warm and its right limbs cold, with a
marker on the face, because a uniformly grey figure cannot show a mirrored clip.
Removing the model leaves the addon working: the preview falls back to
procedural capsules.

## Settings

Everything the addon remembers is an editor setting, under `kimodo/` in Editor
Settings. Nothing is written to `project.godot`. The addon runs only in the
editor and never ships in an export, so none of it has to reach a running game,
while pointing the weights or the output at another drive is a personal answer
that should not arrive as a change to a tracked file.

All sixteen are declared when the plugin loads, so the Editor Settings dialog
lists each with a range, a file filter or an enum before the dock has written
anything.

Editor settings belong to the editor rather than to one project, which matters
for the single `res://` path among them, the bone map: it carries into the next
project opened with the same editor. When the stored path is not in the current
project, the addon falls back to the bundled sample rather than hand the
retargeter a file that will not open.

The prompt and the seed are stored nowhere. They belong to one invocation.

### Runtime environment

kimodo.cpp reads its configuration from the environment. Since a process cannot
be given one directly here, the dock sets these on the editor and lets the
generator inherit them.

| Setting | Variable | Effect |
|---|---|---|
| Text layers per chunk | `KIMODO_TEXT_LAYER_CHUNK` | 1 to 32, default 8. Fewer layers lowers peak VRAM and costs speed |
| Backend | `KIMODO_BACKEND` | Only the exact string `cpu` has an effect; anything else means "try Vulkan, fall back to the CPU" |
| CPU threads | `KIMODO_THREADS` | Applies only on the CPU backend; 0 leaves it to the machine |
| GPU index | `GGML_VK_VISIBLE_DEVICES` | kimodo.cpp always opens Vulkan device 0, so choosing a GPU means reordering which one that is |
| Spill to system memory | `GGML_VK_ALLOW_SYSMEM_FALLBACK` | Lets a buffer land in host memory when device-local VRAM runs out. It then crosses PCIe on every access, buying completion rather than speed |

On Windows, kimodo.cpp's own FP32 parity guard is compiled out, because it is
written for Unix. `GGML_VK_DISABLE_COOPMAT`, `GGML_VK_DISABLE_COOPMAT2` and
`GGML_VK_DISABLE_F16` are therefore unset, and the cooperative-matrix path may
convert the F32 reference weights to FP16. Set them by hand if output has to
match the reference bit for bit.

## Limitations

**Left and right are unverified against the model.** The coordinate system,
ground contact and facing axis have been checked against generated motion, and
Kimodo walks along +Z. Which side of the body a joint belongs to has not been
confirmed the same way, and the automated tests cannot confirm it because they
run against a synthetic fixture. A prompt that raises one named hand would
settle it.

**The rest pose is approximate.** It is not carried in the motion GGUF, so the
addon holds a table calibrated from the upstream reference implementation. That
table is slightly asymmetric and bows the knees further outward than a leg does,
and the retargeting scale is measured against it. It can be dropped once the
model files expose the rest pose directly.

**Only the 22 body joints are used.** Kimodo is SMPL-X, but this addon reads the
body skeleton alone: no hands, no face. `SkeletonProfileHumanoid` has 56 bones,
so a fully rigged character keeps its fingers at rest.

## Building from source

Needs SCons, Python 3, and a C++17 toolchain: MSVC on Windows, GCC or Clang on
Linux.

```sh
git submodule update --init --recursive
scons
```

The build writes `project/addons/kimodo/bin/<platform>/`, which is where
`project/addons/kimodo/kimodo.gdextension` looks for it. Everything lives inside
the addon folder, so `addons/kimodo` is both the whole of a release and the
whole of what anyone copies into a project. The dock is GDScript and needs no
build of its own.

The released libraries are single precision. For a double-precision Godot,
build with `scons precision=double` and add the matching entries to the
`.gdextension`.

### kmd-generate

The same `scons` invocation builds `kmd-generate` from kimodo.cpp and places it,
with the shared libraries it loads, alongside the extension. The dock looks
there first, so a working build needs no configuration to generate a motion.

SCons drives CMake for this rather than compiling it directly, because
reproducing that build would mean reproducing GGML and the compilation of its
Vulkan shaders. On top of the requirements above it needs:

- cmake 3.25 or newer
- the Vulkan SDK, for the `glslc` that compiles the GGML Vulkan shaders
- the `ggml` submodule inside kimodo.cpp, which `--recursive` above brings in

Any of these missing is a warning and a skip rather than a failure, because the
addon still reads, retargets and saves motion that was generated elsewhere.
`kimodo_native=no` skips it deliberately.

On Windows, SCons hands CMake the MSVC environment it has already located, so no
developer command prompt is needed, and it finds the cmake that ships as a
Visual Studio component rather than requiring one on PATH. The result is around
55 MB, most of it the Vulkan shaders compiled into `ggml-vulkan.dll`.

Each target builds in its own tree under `kimodo.cpp/build/`, so builds for
different platforms out of one checkout do not share a CMake cache.

### Patches to kimodo.cpp

kimodo.cpp documents a Linux build, and the pinned revision does not compile
with MSVC. The fixes live in `patches/`, and SCons applies them to the submodule
working tree before configuring, so they stay visible instead of becoming
invisible local edits. Each is skipped when already applied.

| Patch | What it fixes |
|---|---|
| `0001-narrow-path-for-gguf_init_from_file.patch` | `std::filesystem::path::value_type` is `wchar_t` on Windows, so `path.c_str()` is not the narrow string `gguf_init_from_file` takes |
| `0002-include-stdexcept.patch` | `std::runtime_error` used without `<stdexcept>`. libstdc++ pulls it in transitively; the MSVC STL does not |

Both belong upstream. `.gitmodules` marks kimodo.cpp `ignore = dirty` so the
patched tree does not appear as a change on every `git status`, while the
submodule still points at the pinned revision.

### Continuous integration

Each platform builds on a runner of its own with its native toolchain:
`ubuntu-24.04` with GCC, `windows-2022` with MSVC. MSVC is the compiler
kimodo.cpp's CMake configuration has a branch for, the one the patches above
target, and the one ggml's own CI uses for a Windows Vulkan build.

`.github/actions/setup-build` installs the rest per platform, including the
Vulkan SDK, which both sides need for `glslc`.

`ci.yml` builds both targets on every push. `make_build.yml` is run by hand with
a version number: it builds both target types, assembles `addons/kimodo` with
all four libraries in it, and publishes that as a zip on a GitHub release. It
commits `plugin.cfg` and nothing else, since built libraries stay out of the
repository and reach people through the release asset.

Cross-compiling is possible but untested. Naming a CMake toolchain in
`KIMODO_CMAKE_TOOLCHAIN` and appending to the configure line through
`KIMODO_CMAKE_ARGS` is all the build itself needs; the obstacle is that no
mingw import library exists for the Vulkan loader, which ggml-vulkan wants at
link time.

### Tests

```sh
godot --headless --path project --import
godot --headless --path project -s res://tools/verify_stage1.gd
godot --headless --path project -s res://tools/verify_stage2.gd
godot --headless --path project -s res://tools/verify_stage4.gd
```

Stage 1 covers the file layout, quaternion component order, forward kinematics,
and that a baked `Animation` drives the bones its tracks name. Stage 2 covers
retargeting: a rig with prefixed bone names behind a `BoneMap`, rest rotations
that are not identity, and an unmapped twist bone between two mapped ones.
Stage 4 covers saving and library management.

All three run against a synthetic fixture, so they confirm the wiring and
nothing about the model's own conventions.

### The preview scene

`project/smplx_preview.tscn` plays a clip and reads out what has to be judged by
eye: root position, both hands, the hips facing vector, and how close the lowest
bone sits to the ground. T cycles the target between the raw SMPL-X rest, the
same rest under humanoid names reached through the retargeting path, and an
imported model.

Without the real weights, build a synthetic clip first. It walks forward along
+Z and raises the left arm, so a mirrored clip or a 180 degree facing error is
visible immediately:

```sh
python scripts/make_sample_motion.py project/motion_sample
```

Then open `project/` in Godot and run it, or point it at real output:

```sh
godot --path project -- --motion=/path/to/kmd-generate/out
```

Drag to orbit, wheel to zoom, space to play or pause, left and right arrows to
step one frame.

### The mannequin

`addons/kimodo/samples/kimodo_mannequin.glb` is 40 KB, 22 bones and 300
triangles. The repository carries the recipe rather than the model's source, so
regenerate it rather than editing it:

```sh
blender --background --python scripts/make_mannequin.py
```

Its bones are laid out from the SMPL-X rest and already carry
`SkeletonProfileHumanoid` names, which is what lets the preview use it with no
bone map and no import-time rest correction.

## Licence

godot-kimodo is licensed under the [Apache License 2.0](LICENSE), which is also
what kimodo.cpp is under, so one licence covers the source here and the binaries
built from it.

The release archive additionally bundles [ggml](https://github.com/ggml-org/ggml),
which is MIT. [NOTICE](NOTICE) carries the attributions Apache 2.0 asks for,
including which files this project patches and why.

The weights are not distributed with the addon. It downloads them from their
published repositories, and they carry terms of their own; read those before
shipping anything generated with them.
