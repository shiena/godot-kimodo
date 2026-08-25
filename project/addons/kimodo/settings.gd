@tool
extends RefCounted

## Where each Kimodo knob lives.
##
## EditorSettings holds what is true of this machine: where the binaries and the
## multi-gigabyte weights sit, what this GPU and CPU can take, and a personal
## access token. None of that belongs in version control, and a teammate on
## different hardware needs different answers.
##
## ProjectSettings holds what the project agrees on: which weights to fetch and
## at which revision, where generated output and the shared AnimationLibrary
## live, and the house defaults for a new clip. Everyone who opens the project
## should get the same answers, so these travel with project.godot.
##
## The prompt and the seed live in neither. They belong to one invocation.

const EDITOR_PREFIX := "kimodo/"
const PROJECT_PREFIX := "kimodo/"

const EDITOR_DEFAULTS := {
	"paths/generator": "",
	"paths/models_dir": "user://kimodo_models",
	"runtime/backend": "auto",
	"runtime/cpu_threads": 0,
	"runtime/text_layer_chunk": 8,
	"runtime/gpu_index": 0,
	"runtime/sysmem_fallback": false,
	"download/access_token": "",
}

const PROJECT_DEFAULTS := {
	"weights/motion_repo": "LocalAI-io/Kimodo-SMPLX-RP-v1-GGML",
	"weights/text_repo": "LocalAI-io/Llama-3-Kimodo-GGML",
	"weights/revision": "main",
	"output/root": "user://kimodo_out",
	"output/library": "res://kimodo_clips.tres",
	"generation/frames": 120,
	"generation/steps": 30,
	"target/bone_map": "",
}

## Shown in Project Settings, which is the only UI these get.
const PROJECT_HINTS := {
	"weights/revision": {"hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "a branch, tag or commit"},
	"output/root": {"hint": PROPERTY_HINT_GLOBAL_DIR, "hint_string": ""},
	"output/library": {"hint": PROPERTY_HINT_FILE, "hint_string": "*.tres,*.res"},
	"generation/frames": {"hint": PROPERTY_HINT_RANGE, "hint_string": "16,600,1"},
	"generation/steps": {"hint": PROPERTY_HINT_RANGE, "hint_string": "1,200,1"},
	"target/bone_map": {"hint": PROPERTY_HINT_FILE, "hint_string": "*.tres,*.res"},
}

## The layout the upstream download script writes, and therefore the layout
## kmd-generate is handed. Not settings: changing them would mean the bundle no
## longer matches what kimodo.cpp expects.
const MOTION_RELATIVE := "models/kimodo-smplx-rp-v1-f32.gguf"
const TEXT_BUNDLE_RELATIVE := "generated/llm2vec-text-bundle"


static func editor_get(key: String) -> Variant:
	var settings := EditorInterface.get_editor_settings()
	var full := EDITOR_PREFIX + key
	if not settings.has_setting(full):
		return EDITOR_DEFAULTS[key]
	return settings.get_setting(full)


static func editor_set(key: String, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_setting(EDITOR_PREFIX + key, value)


static func project_get(key: String) -> Variant:
	var full := PROJECT_PREFIX + key
	if not ProjectSettings.has_setting(full):
		return PROJECT_DEFAULTS[key]
	return ProjectSettings.get_setting_with_override(full)


static func project_set(key: String, value: Variant) -> void:
	ProjectSettings.set_setting(PROJECT_PREFIX + key, value)
	ProjectSettings.save()


## Declares the project-side settings so they appear in Project Settings even
## before anyone has changed one.
static func register() -> void:
	for key in PROJECT_DEFAULTS:
		var full: String = PROJECT_PREFIX + key
		var value: Variant = PROJECT_DEFAULTS[key]
		if not ProjectSettings.has_setting(full):
			ProjectSettings.set_setting(full, value)
		ProjectSettings.set_initial_value(full, value)

		var info := {"name": full, "type": typeof(value)}
		if PROJECT_HINTS.has(key):
			info.merge(PROJECT_HINTS[key])
		ProjectSettings.add_property_info(info)


## kmd-generate as scons bundles it. A path in the editor settings overrides
## this, for a build made somewhere else.
static func bundled_generator_path() -> String:
	var platform := OS.get_name().to_lower()
	return "res://addons/kimodo/bin/%s/kmd-generate%s" % [platform, ".exe" if platform == "windows" else ""]


## The generator to run, or an empty string when there is none to run.
static func generator_path() -> String:
	var override := String(editor_get("paths/generator")).strip_edges()
	if not override.is_empty():
		return override
	var bundled := bundled_generator_path()
	return bundled if FileAccess.file_exists(bundled) else ""


## Absolute path of the motion GGUF under the configured model directory.
static func motion_gguf_path() -> String:
	return String(editor_get("paths/models_dir")).path_join(MOTION_RELATIVE)


static func text_bundle_path() -> String:
	return String(editor_get("paths/models_dir")).path_join(TEXT_BUNDLE_RELATIVE)


## Everything the child process reads from its environment. OS.create_process()
## cannot pass an environment, so the caller sets these on the editor process
## and lets the child inherit them. An empty value means unset.
static func runtime_environment() -> Dictionary:
	var out := {}

	# kimodo.cpp reads these three.
	out["KIMODO_TEXT_LAYER_CHUNK"] = str(int(editor_get("runtime/text_layer_chunk")))
	# Only the exact string "cpu" forces the CPU backend. Every other value,
	# "gpu" included, means the same as unset: try Vulkan and fall back to CPU
	# when no device answers. There is no way to require the GPU.
	out["KIMODO_BACKEND"] = "cpu" if String(editor_get("runtime/backend")) == "cpu" else ""
	var threads := int(editor_get("runtime/cpu_threads"))
	out["KIMODO_THREADS"] = str(threads) if threads > 0 else ""

	# These two are ggml's rather than kimodo's, but the same process reads them.
	# kimodo.cpp calls ggml_backend_vk_init(0), so choosing a GPU on a machine
	# with several means reordering which one device 0 is.
	var gpu := int(editor_get("runtime/gpu_index"))
	out["GGML_VK_VISIBLE_DEVICES"] = str(gpu) if gpu > 0 else ""
	# Lets a buffer land in system memory when device-local VRAM runs out. It
	# then crosses the PCIe bus on every access, so it buys completion rather
	# than speed.
	out["GGML_VK_ALLOW_SYSMEM_FALLBACK"] = "1" if bool(editor_get("runtime/sysmem_fallback")) else ""

	return out
