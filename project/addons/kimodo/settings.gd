@tool
extends RefCounted

## Where the Kimodo knobs live.
##
## All of them are editor settings. The addon runs in the editor and never ships
## in an export, so nothing it configures has to survive into a running game,
## and almost every answer it needs is about this machine: where the
## multi-gigabyte weights sit, where generated takes go, what this GPU and CPU
## can take, and a personal access token. Put any of that in project.godot and a
## personal answer arrives as a change to a tracked file.
##
## The cost is that editor settings belong to the editor rather than to the
## project, so a res:// path set while one project was open means nothing in the
## next. bone_map_path() falls back to the bundled sample rather than hand the
## retargeter a file that is not here.
##
## The prompt and the seed live in neither. They belong to one invocation.

const PREFIX := "kimodo/"

const SAMPLE_BONE_MAP := "res://addons/kimodo/samples/smplx_bone_map.tres"

const DEFAULTS := {
	"paths/models_dir": "user://kimodo_models",
	"paths/output_dir": "user://kimodo_out",
	"paths/bone_map": SAMPLE_BONE_MAP,
	"weights/motion_repo": "LocalAI-io/Kimodo-SMPLX-RP-v1-GGML",
	"weights/text_repo": "LocalAI-io/Llama-3-Kimodo-GGML",
	"weights/revision": "main",
	"generation/frames": 120,
	"generation/steps": 30,
	"runtime/backend": "auto",
	"runtime/cpu_threads": 0,
	"runtime/text_layer_chunk": 8,
	"runtime/gpu_index": 0,
	"runtime/sysmem_fallback": false,
	"download/access_token": "",
	"preview/height": 360,
}

## Only for the Editor Settings dialog. The dock builds its own controls.
const HINTS := {
	"paths/models_dir": {"hint": PROPERTY_HINT_GLOBAL_DIR, "hint_string": ""},
	"paths/output_dir": {"hint": PROPERTY_HINT_GLOBAL_DIR, "hint_string": ""},
	"paths/bone_map": {"hint": PROPERTY_HINT_FILE, "hint_string": "*.tres,*.res"},
	"weights/revision": {"hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "a branch, tag or commit"},
	"generation/frames": {"hint": PROPERTY_HINT_RANGE, "hint_string": "16,600,1"},
	"generation/steps": {"hint": PROPERTY_HINT_RANGE, "hint_string": "1,200,1"},
	"runtime/backend": {"hint": PROPERTY_HINT_ENUM, "hint_string": "auto,cpu"},
	"runtime/cpu_threads": {"hint": PROPERTY_HINT_RANGE, "hint_string": "0,256,1"},
	"runtime/text_layer_chunk": {"hint": PROPERTY_HINT_RANGE, "hint_string": "1,32,1"},
	"runtime/gpu_index": {"hint": PROPERTY_HINT_RANGE, "hint_string": "0,15,1"},
	"download/access_token": {"hint": PROPERTY_HINT_PASSWORD, "hint_string": ""},
	"preview/height": {"hint": PROPERTY_HINT_RANGE, "hint_string": "160,1200,1"},
}

## The layout the upstream download script writes, and therefore the layout
## kmd-generate is handed. Not settings: changing them would mean the bundle no
## longer matches what kimodo.cpp expects.
const MOTION_RELATIVE := "models/kimodo-smplx-rp-v1-f32.gguf"
const TEXT_BUNDLE_RELATIVE := "generated/llm2vec-text-bundle"


static func get_value(key: String) -> Variant:
	var settings := EditorInterface.get_editor_settings()
	var full := PREFIX + key
	if not settings.has_setting(full):
		return DEFAULTS[key]
	return settings.get_setting(full)


static func set_value(key: String, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_setting(PREFIX + key, value)


## Declares every setting so the Editor Settings dialog lists it with a sensible
## control, and so the ones the dock has no field for are still reachable.
static func register() -> void:
	var settings := EditorInterface.get_editor_settings()
	for key in DEFAULTS:
		var full: String = PREFIX + key
		var value: Variant = DEFAULTS[key]
		if not settings.has_setting(full):
			settings.set_setting(full, value)
		settings.set_initial_value(full, value, false)

		var info := {"name": full, "type": typeof(value)}
		if HINTS.has(key):
			info.merge(HINTS[key])
		settings.add_property_info(info)


## kmd-generate as scons bundles it. There is no setting for this: the addon
## carries its own build, and a different one is a matter of replacing the file.
static func bundled_generator_path() -> String:
	var platform := OS.get_name().to_lower()
	return "res://addons/kimodo/bin/%s/kmd-generate%s" % [platform, ".exe" if platform == "windows" else ""]


## The generator to run, or an empty string when scons has not built one.
static func generator_path() -> String:
	var bundled := bundled_generator_path()
	return bundled if FileAccess.file_exists(bundled) else ""


## Absolute path of the motion GGUF under the configured model directory.
static func motion_gguf_path() -> String:
	return String(get_value("paths/models_dir")).path_join(MOTION_RELATIVE)


static func text_bundle_path() -> String:
	return String(get_value("paths/models_dir")).path_join(TEXT_BUNDLE_RELATIVE)


## Where generated takes land. One folder per generation underneath.
static func output_dir() -> String:
	return String(get_value("paths/output_dir"))


## The BoneMap to start from, or an empty string when the rig already uses
## SkeletonProfileHumanoid names. A stored path that is not in this project came
## from another one, and the bundled sample is a better answer than a file that
## does not open.
static func bone_map_path() -> String:
	var stored := String(get_value("paths/bone_map"))
	if stored.is_empty() or FileAccess.file_exists(stored):
		return stored
	return SAMPLE_BONE_MAP if FileAccess.file_exists(SAMPLE_BONE_MAP) else ""


## Everything the child process reads from its environment. OS.create_process()
## cannot pass an environment, so the caller sets these on the editor process
## and lets the child inherit them. An empty value means unset.
static func runtime_environment() -> Dictionary:
	var out := {}

	# kimodo.cpp reads these three.
	out["KIMODO_TEXT_LAYER_CHUNK"] = str(int(get_value("runtime/text_layer_chunk")))
	# Only the exact string "cpu" forces the CPU backend. Every other value,
	# "gpu" included, means the same as unset: try Vulkan and fall back to CPU
	# when no device answers. There is no way to require the GPU.
	out["KIMODO_BACKEND"] = "cpu" if String(get_value("runtime/backend")) == "cpu" else ""
	var threads := int(get_value("runtime/cpu_threads"))
	out["KIMODO_THREADS"] = str(threads) if threads > 0 else ""

	# These two are ggml's rather than kimodo's, but the same process reads them.
	# kimodo.cpp calls ggml_backend_vk_init(0), so choosing a GPU on a machine
	# with several means reordering which one device 0 is.
	var gpu := int(get_value("runtime/gpu_index"))
	out["GGML_VK_VISIBLE_DEVICES"] = str(gpu) if gpu > 0 else ""
	# Lets a buffer land in system memory when device-local VRAM runs out. It
	# then crosses the PCIe bus on every access, so it buys completion rather
	# than speed.
	out["GGML_VK_ALLOW_SYSMEM_FALLBACK"] = "1" if bool(get_value("runtime/sysmem_fallback")) else ""

	return out
