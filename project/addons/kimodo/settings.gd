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


## Absolute path of the motion GGUF under the configured model directory.
static func motion_gguf_path() -> String:
	return String(editor_get("paths/models_dir")).path_join(MOTION_RELATIVE)


static func text_bundle_path() -> String:
	return String(editor_get("paths/models_dir")).path_join(TEXT_BUNDLE_RELATIVE)


## The three environment variables kimodo.cpp reads. OS.create_process() cannot
## pass an environment to the child, so the caller sets them on the editor
## process and lets the child inherit them.
static func runtime_environment() -> Dictionary:
	var out := {}
	out["KIMODO_TEXT_LAYER_CHUNK"] = str(int(editor_get("runtime/text_layer_chunk")))
	# Only the exact value "cpu" forces the CPU backend; anything else tries
	# Vulkan first, so "auto" is expressed by clearing the variable.
	out["KIMODO_BACKEND"] = "cpu" if String(editor_get("runtime/backend")) == "cpu" else ""
	var threads := int(editor_get("runtime/cpu_threads"))
	out["KIMODO_THREADS"] = str(threads) if threads > 0 else ""
	return out
