# godot-kimodo

English | [日本語](README_ja.md)

Generate character animation from a sentence, inside the Godot editor.

godot-kimodo is an editor addon around [kimodo.cpp](https://github.com/localai-org/kimodo.cpp),
a text-to-motion model. It generates for the 22-joint SMPL-X skeleton, the
30-joint SOMA one or Unitree's 34-joint G1 robot; the addon runs whichever you
pick, retargets the result onto a `Skeleton3D` in your scene, and hands you an
ordinary Godot `Animation`.

What you save is a plain `Animation` resource. It has no dependency on this
addon, on kimodo.cpp, or on the 15 GiB of weights that produced it. Nothing here
reaches an exported game.

Kimodo emits parent-local quaternions in XYZW order, a root translation in
metres, and 30 frames per second. All three match Godot's own conventions, which
is why the bulk of the work is retargeting rather than conversion.

The addon running in the editor:

[![kimodo.cpp integrated godot engine](https://img.youtube.com/vi/79CiinR9L58/maxresdefault.jpg)](https://youtu.be/79CiinR9L58)

## Requirements

The model sets the bar, not the addon.

| | Needs | Why |
|---|---|---|
| Disk | **15.2 GiB** | 1.05 GiB of motion GGUF and 14.14 GiB of text bundle, across 36 files. The three models are within 1% of each other in size, and all of them share the one text bundle |
| VRAM | **2 GB** in practice, 1002 MiB at the floor | `token_embedding.weight` is one 128,256 x 4096 BF16 tensor of 1,050,673,152 bytes, and a tensor cannot be split across buffers, so no setting gets under it |
| Vulkan | **1.2** | ggml-vulkan refuses to initialise below it |
| Platform | x86_64 Linux or Windows | kimodo.cpp needs a C++23 compiler and the GGML Vulkan backend, which rules out mobile and web |
| Python | **3.9** or later, or `uv` | Only to convert SMPL-X, and only once. The converter imports nothing outside the standard library, so uv is the answer for a machine with no Python rather than a dependency resolver |
| Godot | **4.4** or later | What the extension declares as its `compatibility_minimum`, and the godot-cpp branch it is built against. Development happens on 4.7 |

Those figures are peaks, not a sum. The text encoder frees the token embedding
before its layer loop, and frees each chunk of layers before the next. The motion
weights load only after the prompt is encoded.

With no Vulkan device the run falls back to the CPU and the same figures move
from VRAM to RAM. The fallback is silent, and there is no setting that makes the
GPU mandatory.

## Install

Download `godot-kimodo-vX.Y.Z.zip` from the
[releases](https://github.com/shiena/godot-kimodo/releases) and copy the
`addons/kimodo` folder inside it into your project's `addons/`. One archive
covers both platforms. Enable **Kimodo** under **Project Settings > Plugins**, and
the dock appears on the right.

The weights are not in the archive. The addon downloads them, once, on first
use. The SMPL-X model is the exception and has to be converted locally; see
[The motion model](#the-motion-model).

To compile it yourself instead, see [Build from source](#build-from-source).

## The motion model

Three models generate motion, and **Model** in the Setup pane picks between
them. They differ in the skeleton they predict, which decides how much of a
humanoid rig the result can drive.

| Model | Joints | Reaches | Weights |
|---|---|---|---|
| **SMPL-X** | 22 | all 22 | convert it yourself |
| **SOMA** | 30 | 25, adding a jaw, eyes and fingertips | published |
| **Unitree G1** | 34 | 16; a robot with no head, and three single-axis joints where a rig has one | published |

They share the one text encoder, so switching models re-downloads about 1 GiB
and nothing else.

SOMA and G1 download like anything else: click **Download**. They are under the
[NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/),
which allows the conversion to be redistributed.

SMPL-X is the one that cannot. `LocalAI-io/Kimodo-SMPLX-RP-v1-GGML` carried a
converted GGUF until its maintainers read the upstream licence, which forbids
distributing a derivative model. The repository now holds a model card and
nothing else, so **Download** leaves that GGUF missing however many times you
press it.

Converting the SMPL-X checkpoint for yourself is allowed; publishing the result
is not, so **Convert SMPL-X...** in the Setup pane does it on your machine.

1. Click **Model page** with SMPL-X selected. It opens
   [nvidia/Kimodo-SMPLX-RP-v1](https://huggingface.co/nvidia/Kimodo-SMPLX-RP-v1),
   which is gated. Accept the licence there and mint a token under
   [Settings > Access Tokens](https://huggingface.co/settings/tokens). Nothing
   in the addon can do this part for you.
2. Paste the token into the token field.
3. Click **Convert SMPL-X...**. It fetches the 1.05 GiB checkpoint, writes the
   revision it pinned, and runs the converter on it. Expect about 2.1 GiB of
   disk while it works, half of which is the checkpoint you can delete
   afterwards.

The converter is kimodo.cpp's own `convert_motion_to_gguf.py`, copied into
`addons/kimodo/scripts/` by the build rather than rewritten in GDScript: it is
the parser upstream reviews, it imports nothing outside the standard library,
and a second reader of a binary format is a second thing to get wrong. The
addon runs it with whatever Python is on `PATH`, and falls back to
`uv run --no-project --python 3.12` on a machine that has none.

The presence line updates when it finishes, and reads all 36 files.

A clip names no skeleton: it is two headerless buffers of floats. The addon
recognises which model produced one from its width, since 22, 30 and 34 joints
are three different widths. So an old clip keeps working, and a clip generated
with the wrong model in the picker still loads as what it actually is.

## Generate your first clip

1. Open the **Setup** pane, pick a **Model**, and check **Model directory**.
   This is where the weights land.
2. Click **Download**, and wait. The download is 15.2 GiB, and the pane reports
   each file as it arrives. On SMPL-X it ends by reporting the motion GGUF as
   missing, which is expected: convert it as
   [The motion model](#the-motion-model) describes.
3. Open the **Generate Motion** panel along the bottom of the editor, set the
   length in frames and enter a prompt.
4. Click **Generate**. The clip appears under **Motion** in the dock when the
   run finishes, and **Preview** plays it on a built-in mannequin.
5. Open a scene containing the rig you want to animate. **Target** finds its
   `Skeleton3D` and reports how many of the joints it could map.
6. Name the clip under **Save**, then click **Bake** to put it on an
   `AnimationPlayer` in that scene. **Save clip** writes it out as a resource
   instead, and **Save motion** keeps the take itself so it can be baked onto
   another rig later.

## The Generate panel

A bottom panel rather than part of the dock, because a sequence of prompts is
a row of lengths that only mean anything next to each other, and a dock is a
column two hundred pixels wide. Open it from the **Generate Motion** button
along the bottom of the editor.

The strip across the top is the clip as it will be generated: one block per
prompt, as wide as the frames it runs for, over a ruler in seconds. The
hatched head of a block is the overlap the model is given to join it onto the
one before. Clicking a block selects that prompt.

Under it, one row per prompt: how long it runs, what it says, and a button to
drop it. Then the sampling settings, then the button.

**The prompt** is followed much more closely when it takes the shape the
training captions took. NVIDIA's own
[best practices](https://research.nvidia.com/labs/sil/projects/kimodo/docs/key_concepts/limitations.html)
give the rules:

- **Start with the subject.** `A person...`, `An old person...`, `A zombie...`.
- **One behaviour, or two.** More than that blurs what the motion is meant to be.
- **Aim for the middle.** `A person walks.` is too short to steer anything. A
  list of what each limb does is too far the other way.
- **Stay inside what it was trained on.** That is locomotion, gestures,
  everyday activities, common object interactions, videogame combat, and
  dancing. The styles are tired, angry, happy, sad, scared, drunk, injured,
  stealthy, old, and childlike. `A baseball player walks up to the plate and
  swings a bat` fails because nothing in the data is baseball.
- **Neutral, physical terms.** The model card asks for
  `A person walks slowly with shuffled steps` rather than a description of who
  the person is.
- **In a sequence, each prompt stands on its own.** `Then the person stops`
  gives the model no subject and no starting point. `A person comes to a stop`
  does.

So this:

```
A person runs forward and then leaps over an obstacle in front of them.
```

rather than `running`. A single word steers almost nothing. What fills the gap
is the training set itself: 700 hours of professional and stunt capture, with
combat among its categories. A run generated from one word can end in a
two-handed weapon carry and a turn to check behind. That is a staple of a game
animation library, and nothing in the prompt asked for it.

No prop is drawn. SMPL-X is 22 body joints with no hands, so what the clip
holds is an arm and torso configuration. Nothing in the data is a weapon; the
shape of the arms is what suggests one.

**The length** of each prompt is in frames at 30 fps. Three limits apply and
only the last of them is about quality:

| Bound by | Frames | |
|---|---|---|
| the field | 2 to 600, and at least 16 for a single prompt | what the panel accepts |
| kimodo.cpp | 1 to 10,000 alone, 2 to 300 in a sequence | what the generator accepts |
| the model | **300** | 10 seconds, the longest it was trained on |

Past 300 the model has nothing left to draw on, and the tail of the clip
wanders. That looks the same as a prompt that ran out of things to say. Keep
the length near what the sentence describes.

**Steps** is how many denoising passes the sampler makes. More of them means a
more converged sample and closer adherence to the text. The cost in time is
close to linear. The default is 150 and the field goes to 200; kimodo.cpp's own
demo asks for 100. Down in the tens is where a prompt stops being followed at
all.

**Seed** picks which sample you get. One prompt, length, step count, and seed
give the same clip every time. Change the seed to ask for another take of the
same instruction rather than a different instruction. It is stored nowhere and
starts at 0 each session, because it belongs to a single invocation.

**Guidance** is the classifier-free guidance weight on the text, the same
knob a diffusion image model calls by that name. Upstream samples at 2, and
so does this. Higher takes the words more literally and tends to move less;
lower wanders away from them. At 0 the prompt is ignored entirely.

**+ Add prompt** adds a row, up to 16 of them, and carries the clip on into
that prompt:
`A person walks forward.`, then `A person sits down.`, then `A person waves.`,
as one continuous take. The joins are not crossfades between separate clips.
The model receives the end of the previous stretch as a constraint on the root,
every joint position, and the ankle and wrist orientations. It generates the
next stretch from there, so the pose carries over and the character keeps the
distance it travelled.

**Transition** is how many frames of overlap it gets. Those frames are absorbed
rather than added, so a clip is always as long as its prompts add up to. The
transition has to be shorter than every prompt after the first.

**Continuity** is the second guidance weight, the one on that constraint. It
decides how hard each prompt after the first is pulled onto the end of the
one before it. It appears alongside Transition, and for the same reason: the
first stretch is sampled with nothing to join onto, so a single prompt has
nothing for the weight to act on and ignores it.

A sequence costs what its prompts cost. The 8B text encoder runs once per
prompt, and the denoiser once per stretch.

Generation runs as a separate process. The text encoder is an 8B LLM2Vec model.
Sharing the editor's Vulkan device with it would mean competing for VRAM, and
losing the editor to a failed run.

Both guidance weights reach the generator through its environment rather than
its command line, along with everything else under
[Runtime environment](#runtime-environment).

## The dock

One column, read top to bottom: **Setup**, **Motion**, **Target**, **Save**,
**Preview**. Everything either side of a run; the run itself is
[the bottom panel](#the-generate-panel). Each section reports on a line of its
own, so an answer appears beside the button that produced it.

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

**Model** picks which of the three skeletons to generate for, and everything
else in the pane follows it: which GGUF has to be on disk, which repository
serves it, and which mannequin stands in for the rig in **Preview**.

**Convert SMPL-X...** is enabled only for the model nobody may publish, and
says so on the other two.

With SMPL-X picked, a note above the token field says what the conversion asks
for: a Hugging Face token, and Python 3.9 or later, or uv. **Model page** sits
beside it and opens that gated model on Hugging Face, which is where the
licence is accepted and the token minted. Both belong to SMPL-X alone, so both
are gone on the other two.

**Weights** fetches the configured repositories and checks every file against
their manifests. A repository that will not serve its manifest costs its own
files and no others, which is what leaves the text bundle downloadable while
the SMPL-X GGUF is not. No published repository needs an access token; the
field is there for a gated mirror of your own, and for the SMPL-X checkpoint,
which is gated for everyone. Setting **Motion repo** in Editor Settings
overrides the published repository for whichever model is picked.

The checkpoint publishes no hashes, so there is nothing to verify it against
beyond the size Hugging Face reports and curl's own transfer. The conversion
records the SHA-256 it actually read into the GGUF, which is the honest place
for it.

Downloading keeps whatever is already on disk, so it resumes an interrupted
fetch and repairs a damaged one. Clicking it when all 36 files are present asks
first, and says what it would do. It compares sizes against the manifest and
re-fetches only a mismatch, which usually transfers nothing but the
manifests.
Selecting **Re-hash existing** reads all 15.2 GiB back to check contents as well,
and the question says so.

Transfers run through **curl**, the addon's one external dependency. It ships
with Windows 10 and later, macOS, and effectively every Linux distribution.
curl resumes a partial file, which over 15 GiB matters: a dropped connection is
a question of when.

**Runtime** is how the generator uses the machine. What each control sets in
the environment is listed under [Runtime environment](#runtime-environment);
three of them are worth a word here.

**Chunk** is how many of the text encoder's 32 layers are held at once, from 1
to 32, and 8 by default. The encoder frees each chunk before loading the next,
so a smaller number lowers the peak and costs speed. It cannot lower it past
the 1002 MiB token embedding, which is a single tensor and loads whole whatever
this says.

**Threads** applies on the CPU backend and nowhere else. 0, the default, leaves
the count to the machine.

**GPU** picks which Vulkan device generates. kimodo.cpp always opens device 0,
so this reorders the list rather than choosing from it: 2 hides the others, and
what was device 2 becomes the only device there is. At 0 nothing is set, and
every device stays visible in its own order.

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

**Skeleton** is the rig to animate. It is resolved when you click a button: the selected `Skeleton3D`, or the first one in the open scene. The
report underneath follows the editor's selection, so what it describes is what a
bake would reach.

**Bone map** translates the joint names of whichever model produced the clip
into the names that rig uses. It is only needed when those names are not
`SkeletonProfileHumanoid`'s. The field is a one-session override of the
`kimodo/paths/bone_map` setting, and shows that setting as its placeholder
while it is empty.

The report names the model, reads out how many joints resolved and which did
not, and gives the scale between the two rest heights:

```
Skeleton3D  56 bones
SMPL-X: mapped 22/22, scale 0.999
every joint resolved
```

The count is against what the humanoid profile can carry, not against the joint
count. G1 reads `mapped 16/16` on a rig that resolves everything, because the
other 18 of its 34 joints are single axes no rig gives a bone to.

A sample map sits at `addons/kimodo/samples/smplx_bone_map.tres` and is where
the setting starts, with `soma_bone_map.tres` and `g1_bone_map.tres` alongside
it. Each pairs the humanoid profile with one model own joint names, so a rig
carrying those names verbatim is a valid target, and they double as worked
examples of the format. Regenerate them rather than editing them:

```sh
godot --headless --path project -s res://tools/make_bone_maps.gd
```

For Mixamo, VRM, or any other rig, Godot builds the map itself. Create a
`BoneMap` and set its profile to `SkeletonProfileHumanoid`. The inspector then
offers to match it against a skeleton automatically.

### Save

**Bake** and **Save clip** both retarget onto the skeleton Target resolved, and
differ only in where the result goes. Bake puts it on an `AnimationPlayer` in
the open scene. Save clip writes it as a standalone resource, and reveals it in
the FileSystem dock afterwards.

Both need a `Skeleton3D` in the open scene, because an animation's track paths
are that skeleton's path within it.

**Save motion** needs neither. It writes the take itself, before any
retargeting, as a [`.kimodo` clip](#the-clip-file) in the project. That is what
makes a generation outlive the session that produced it: an `Animation` is
already committed to one rig, and the folder the generator wrote cannot be
committed at all.

**Clip name** names the animation and suggests the file name. The two sets of
rules differ, so it is checked against both. An `AnimationLibrary` rejects `,`
and `[`, which a file name accepts. A file name rejects `*`, `?`, and `|`, which
a library accepts.

To gather several clips into an `AnimationLibrary`, use the `AnimationPlayer`'s
own Animation panel.

### Preview

Plays the clip that Motion has loaded, on a mannequin bundled with the addon
rather than on the target rig. The target rig belongs to the edited scene, and
cannot be in two places at once.

Click the viewport to take it, which lights the frame in the editor's accent
colour. Drag then orbits and the wheel zooms; before that the wheel belongs to
the dock scrolling underneath. Escape releases it, as does clicking anywhere
else. The slider scrubs either way, and the grip below the viewport drags it
taller.

The camera follows the root while the grid stays fixed to the world, so travel
and ground contact both have something to read against.

The bundled mannequin is dimensioned from the same rest pose SMPL-X motion is
decoded against. It therefore maps all 22 joints at a scale of 1.0, and stands
on the floor without adjustment. Its left limbs are warm and its right limbs
cold, with a marker on the face, because a uniformly grey figure cannot show a
mirrored clip. Removing the model leaves the addon working: the preview falls
back to procedural capsules.

## The clip file

A run leaves two headerless `.f32` buffers in a folder named after the second it
started, under the output directory. Nothing in that folder records the seed or
the model. That is enough to play a take back and not enough to keep one.

A `.kimodo` file is those two buffers with the recipe in front of them:

| Field | |
|---|---|
| `prompts`, `lengths`, `transition` | the sequence as it was typed |
| `steps`, `seed`, `text_cfg`, `constraint_cfg` | what the sampler was given |
| `skeleton`, `motion_repo`, `text_repo`, `revision` | which weights ran |
| `checkpoint` | for a converted SMPL-X, the checkpoint revision the GGUF came from |
| `hash` | sha256 of all of the above; two runs of one recipe hash alike |
| `generated` | when it ran, in UTC |

The same recipe is written into the generation folder as `recipe.json` before
the generator starts, so a run that crashes still says what was asked of it, and
a clip loaded from an older folder simply has no recipe rather than being
refused.

The addon registers an importer for the extension, so a `.kimodo` file in the
project behaves like any other asset: it has a UID, `load()` returns a
`KimodoMotion`, and the Import dock carries its settings. The import is a format
conversion and never runs the generator. Godot reimports on its own, when a
project is opened and whenever a source file changes, and an importer that
generated would answer a fresh checkout by taking the GPU for an hour.

One import setting so far, **fps**, which overrides the 30 frames a second the
model generates at. Zero, the default, leaves it alone.

There is no checksum of the weights. Hashing a gigabyte of GGUF on every run
costs seconds to repeat what the repository and revision already say, and for
the one model that has no revision the `checkpoint` line names those bytes
instead.

## Settings

Everything the addon remembers is an editor setting, under `kimodo/` in Editor
Settings. Nothing is written to `project.godot`. The addon runs only in the
editor and never ships in an export, so none of it has to reach a running game.
Pointing the weights or the output at another drive is a personal answer, and it
should not arrive as a change to a tracked file.

All 20 are declared when the plugin loads, so the Editor Settings dialog
lists each with a range, a file filter, or an enum before the dock has written
anything.

Editor settings belong to the editor rather than to one project. That matters
for the single `res://` path among them, the bone map, because it carries into
the next project opened with the same editor. When the stored path is not in the current
project, the addon falls back to the bundled sample rather than hand the
retargeter a file that does not open.

The prompt and the seed are stored nowhere. They belong to one invocation.

### Runtime environment

kimodo.cpp reads its configuration from the environment, and kmd-generate
reads its two guidance weights the same way. Since a process cannot be given
an environment directly here, the dock sets these on the editor and lets the
generator inherit them.

| Setting | Variable | Effect |
|---|---|---|
| Text layers per chunk | `KIMODO_TEXT_LAYER_CHUNK` | 1 to 32, default 8. Fewer layers lowers peak VRAM and costs speed |
| Backend | `KIMODO_BACKEND` | Only the exact string `cpu` has an effect; anything else means "try Vulkan, fall back to the CPU" |
| CPU threads | `KIMODO_THREADS` | Applies only on the CPU backend; 0 leaves it to the machine |
| Guidance | `KIMODO_TEXT_CFG` | Classifier-free guidance on the text, default 2.0 |
| Continuity | `KIMODO_CONSTRAINT_CFG` | Classifier-free guidance on the sequence constraint, default 2.0. A single prompt is sampled unconstrained and ignores it |
| GPU index | `GGML_VK_VISIBLE_DEVICES` | kimodo.cpp always opens Vulkan device 0, so choosing a GPU means reordering which one that is |
| Spill to system memory | `GGML_VK_ALLOW_SYSMEM_FALLBACK` | Lets a buffer land in host memory when device-local VRAM runs out. It then crosses PCIe on every access, buying completion rather than speed |

On Windows, kimodo.cpp's own FP32 parity guard is compiled out, because it is
written for Unix. `GGML_VK_DISABLE_COOPMAT`, `GGML_VK_DISABLE_COOPMAT2`, and
`GGML_VK_DISABLE_F16` are therefore unset, and the cooperative-matrix path may
convert the F32 reference weights to FP16. Set them by hand if output has to
match the reference bit for bit.

## Limitations

**Left and right are unverified against the model.** The coordinate system,
ground contact, and facing axis have been checked against generated motion, and
Kimodo walks along +Z. Which side of the body a joint belongs to has not been
confirmed the same way, and the automated tests cannot confirm it because they
run against a synthetic fixture. A prompt that raises one named hand would
settle it.

**The rest pose is approximate.** It is not carried in the motion GGUF, so the
addon holds a table calibrated from the upstream reference implementation. That
table is slightly asymmetric and bows the knees further outward than a leg does,
and the retargeting scale is measured against it. It can be dropped once the
model files expose the rest pose directly.

**The SOMA and G1 mappings are unverified.** SMPL-X has been watched against
generated motion; the other two have not, because getting a clip out of them
needs the weights, a GPU run and something to compare against. Which humanoid
bone each of their joints drives is a reading of the joint names and the rest
offsets, and a reading can be wrong. G1 in particular resolves its three
single-axis hip joints onto one thigh bone by taking the last of the three,
which is right if the chain is ordered pitch, roll, yaw as the names say.

**Nothing below the wrist is animated.** SMPL-X stops at 22 body joints, and
what SOMA adds beyond them is a jaw, two eyes and one fingertip per hand, which
is not a hand. `SkeletonProfileHumanoid` has 56 bones, so a fully rigged
character keeps its fingers at rest whichever model produced the clip.

## Build from source

To build godot-kimodo you need SCons, Python 3, and a C++17 toolchain: MSVC on
Windows, GCC or Clang on Linux.

```sh
git submodule update --init --recursive
scons
```

The build writes `project/addons/kimodo/bin/<platform>/`, which is where
`project/addons/kimodo/kimodo.gdextension` looks for it. Everything lives inside
the addon folder, so `addons/kimodo` is both the whole of a release and the
whole of what anyone copies into a project. The dock is GDScript and needs no
build of its own.

The same run copies kimodo.cpp's `convert_motion_to_gguf.py` into
`project/addons/kimodo/scripts/`. Neither that nor `bin/` is committed: the
copy that ships belongs to the pinned submodule revision, so there is no second
version of either to keep in step.

The released libraries are single precision. For a double-precision Godot,
build with `scons precision=double` and add the matching entries to the
`.gdextension`.

### kmd-generate

The same `scons` invocation builds `kmd-generate` from kimodo.cpp and places it,
with the shared libraries it loads, alongside the extension. The dock looks
there first, so a working build needs no configuration to generate a motion.

SCons drives CMake for this rather than compiling it directly, because
reproducing that build would mean reproducing GGML and the compilation of its
Vulkan shaders. Beyond SCons and a C++ toolchain, it needs:

- cmake 3.25 or newer
- the Vulkan SDK, for the `glslc` that compiles the GGML Vulkan shaders
- the `ggml` submodule inside kimodo.cpp, which `git submodule update --recursive`
  brings in

Any of these missing is a warning and a skip rather than a failure, because the
addon still reads, retargets, and saves motion that was generated elsewhere.
`kimodo_native=no` skips it deliberately.

On Windows, SCons hands CMake the MSVC environment it has already located, so no
developer command prompt is needed. It also finds the cmake that ships as a
Visual Studio component, rather than requiring one on PATH. The result is around
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
| `0003-guidance-weights-from-the-environment.patch` | kmd-generate passed a literal 2.0 for both guidance weights, so no caller could set either |

The first two are build fixes and belong upstream. The third is not a fix: it
makes a demo command line configurable, and it is a patch because the file is
someone else's. It stays deliberately small for that reason, reading two
environment variables rather than changing the argv shape both the demo and
this dock depend on.

`.gitmodules` marks kimodo.cpp `ignore = dirty` so the patched tree does not
appear as a change on every `git status`, while the submodule still points at
the pinned revision.

### Continuous integration

Each platform builds on a runner of its own with its native toolchain:
`ubuntu-24.04` with GCC, `windows-2022` with MSVC. MSVC is the compiler
kimodo.cpp's CMake configuration has a branch for, the one the patches in `patches/`
target, and the one ggml's own CI uses for a Windows Vulkan build.

`.github/actions/setup-build` installs the rest per platform, including the
Vulkan SDK, which both sides need for `glslc`.

`ci.yml` builds both targets on every push. `make_build.yml` is run by hand with
a version number. It builds both target types, assembles `addons/kimodo` with
all four libraries and the SMPL-X converter in it, and publishes that as a zip
on a GitHub release. The converter comes from the Linux release build, since it
is the same file on every platform and only exists after scons has run. It
commits `plugin.cfg` and nothing else, since built libraries stay out of the
repository and reach people through the release asset.

Cross-compiling is possible but untested. Naming a CMake toolchain in
`KIMODO_CMAKE_TOOLCHAIN` and appending to the configure line through
`KIMODO_CMAKE_ARGS` is all the build itself needs. The obstacle is that no mingw
import library exists for the Vulkan loader, which ggml-vulkan requires at link
time.

### Tests

```sh
godot --headless --path project --import
godot --headless --path project -s res://tools/verify_stage1.gd
godot --headless --path project -s res://tools/verify_stage2.gd
godot --headless --path project -s res://tools/verify_stage4.gd
godot --headless --path project -s res://tools/verify_clip_file.gd
```

Stage 1 covers the file layout, quaternion component order, forward kinematics,
and that a baked `Animation` drives the bones its tracks name. Stage 2 covers
retargeting: a rig with prefixed bone names behind a `BoneMap`, rest rotations
that are not identity, and an unmapped twist bone between two mapped ones.
Stage 4 covers saving and library management. The clip file check round-trips a
motion through the `.kimodo` container and then feeds the reader a foreign file,
a newer version, and a payload that stops early.

All four run against a synthetic fixture, so they confirm the wiring and nothing
about the model's own conventions.

### The preview scene

`project/smplx_preview.tscn` plays a clip and reads out what has to be judged by
eye: root position, both hands, the hips facing vector, and how close the lowest
bone sits to the ground. Press T to cycle the target between the raw SMPL-X rest, the
same rest under humanoid names reached through the retargeting path, and an
imported model.

Without the real weights, build a synthetic clip first. It walks forward along
+Z and raises the left arm. A mirrored clip or a 180 degree facing error is
therefore visible immediately:

```sh
python scripts/make_sample_motion.py project/motion_sample
```

Then open `project/` in Godot and run it, or point it at real output:

```sh
godot --path project -- --motion=/path/to/kmd-generate/out
```

Drag to orbit and use the wheel to zoom.
Press Space to play or pause, and the Left and Right arrow keys to step one
frame.

### The mannequin

`addons/kimodo/samples/kimodo_mannequin.glb` is 40 KB, 22 bones and 300
triangles. The repository carries the recipe rather than the model's source.
Regenerate it rather than editing it:

```sh
blender --background --python scripts/make_mannequin.py
```

Its bones are laid out from the SMPL-X rest and already carry
`SkeletonProfileHumanoid` names, which is what lets the preview use it with no
bone map and no import-time rest correction.

Only SMPL-X ships one. SOMA and G1 fall back to capsules generated from their
own rest pose, which is a worse-looking answer and a correct one. Each model
has a mannequin setting of its own under `kimodo/paths`, so a modeller can
point one at a figure of their own. It has to meet the same two conditions:
`SkeletonProfileHumanoid` bone names, and standing on the floor at rest.

## Licence

godot-kimodo is licensed under the [Apache License 2.0](LICENSE), which is also
what kimodo.cpp is under, so one licence covers the source here and the binaries
built from it.

The release archive additionally bundles [ggml](https://github.com/ggml-org/ggml),
which is MIT. [NOTICE](NOTICE) carries the attributions Apache 2.0 asks for,
including which files this project patches and why.

The weights are not distributed with the addon. It downloads what is published,
which is the text encoder and two of the three motion models. The SMPL-X
conversion is not published, because converting that checkpoint is allowed and
redistributing the result is not. Every one of them carries terms of its own;
read those before shipping anything generated with them.
