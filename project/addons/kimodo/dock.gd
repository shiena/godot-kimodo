@tool
extends ScrollContainer

## The Kimodo dock: prompt in, Animation on a rig out.
##
## Generation runs kmd-generate as a separate process rather than through the
## GDExtension. The text encoder is an 8B LLM2Vec, and sharing the editor's
## Vulkan device with it means competing for VRAM and taking the editor down
## with a failed generation. _spawn_generator() is the only place that knows
## how generation is invoked, so linking kimodo.cpp directly later is a change
## confined to that one function.
##
## kmd-generate owns the GPU for the length of a run, so only one is allowed at
## a time.
##
## Setup folds away, because after the first run nobody touches the weights or
## the runtime knobs. It carries an arrow so it reads as a pane rather than a
## button that lost its panel, and it opens itself whenever a file it configures
## is missing, which now includes a download that stopped halfway.
##
## A dock is narrow, so anything longer than a few words goes in a tooltip. A
## wrapped sentence turns into ten lines of height here, and a button that does
## not wrap sets a minimum width the user cannot pull back in.

const Settings := preload("res://addons/kimodo/settings.gd")
const Downloader := preload("res://addons/kimodo/downloader.gd")
const MANNEQUIN := "res://addons/kimodo/samples/kimodo_mannequin.glb"

var _body: VBoxContainer

var _setup_toggle: Button
var _setup: VBoxContainer

var _prompt: TextEdit
var _frames: SpinBox
var _steps: SpinBox
var _seed: SpinBox
var _generate_button: Button
var _status: Label

var _clips: OptionButton
var _clip_dirs := PackedStringArray()
var _rename_button: Button
var _delete_button: Button
var _rename_field: LineEdit
var _motion_label: Label
var _target_label: RichTextLabel
var _bone_map_path: LineEdit
var _clip_name: LineEdit
var _last_saved := ""

var _preview: SubViewport
var _preview_skeleton: Skeleton3D
var _preview_player: AnimationPlayer
var _preview_camera: Camera3D
var _preview_play: Button
var _preview_slider: HSlider
var _preview_time := 0.0
# Paused until asked: a dock that opens with a figure running in it is a dock
# that animates in the corner of the eye all day.
var _preview_running := false
var _preview_yaw := 0.6
var _preview_pitch := 0.05
var _preview_distance := 2.8
var _preview_container: SubViewportContainer
var _preview_grip: HSeparator
var _preview_figure: Node3D
var _preview_retargets := false

var _models_dir: LineEdit
var _output_dir: LineEdit
## What to run after a path row changes, by settings key.
var _path_hooks := {}
var _token: LineEdit
var _reverify: CheckBox
var _download_button: Button
var _cancel_button: Button
var _download_bar: ProgressBar
var _download_status: Label
var _presence: RichTextLabel

var _backend: OptionButton
var _threads: SpinBox
var _chunk: SpinBox
var _gpu_index: SpinBox
var _sysmem: CheckBox

var _motion: KimodoMotion
var _loaded_clip := ""
var _bone_map: BoneMap
var _pid := -1
var _pending_output := ""
var _dialog: FileDialog
var _confirm: ConfirmationDialog
var _downloader: Node


func _init() -> void:
	name = "Kimodo"
	# Vertical scrolling keeps a long status message from stretching the dock;
	# horizontal scrolling stays off so the children wrap instead of sliding
	# out of reach.
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	follow_focus = true


func _ready() -> void:
	_downloader = Downloader.new()
	_downloader.name = "Downloader"
	_downloader.progress.connect(_on_download_progress)
	_downloader.finished.connect(_on_download_finished)
	add_child(_downloader)

	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override(&"separation", 6)
	add_child(_body)

	_setup_toggle = Button.new()
	_setup_toggle.toggle_mode = true
	_setup_toggle.tooltip_text = "Folders, the weight download and the runtime knobs."
	_setup_toggle.toggled.connect(_on_setup_toggled)
	_body.add_child(_setup_toggle)

	_setup = VBoxContainer.new()
	_setup.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_setup)
	_build_folders()
	_build_weights()
	_build_runtime()

	_build_generate()
	_build_motion()
	_build_target()
	_build_save()
	_build_preview()

	# Bake resolves the target afresh, so the report has to describe whatever
	# is selected right now or the two disagree without saying so. Following
	# the selection is cheaper than remembering a node that can be deleted.
	EditorInterface.get_selection().selection_changed.connect(_refresh_target)

	_on_bone_map_changed(_bone_map_path.text)
	_refresh_presence()
	_refresh_clips()
	_on_setup_toggled(not _weights_present())
	set_process(true)


func _build_generate() -> void:
	_section(_body, "Generate")
	# The three numbers are set once and left alone, so they go above the prompt
	# rather than between it and the button that acts on it.
	var numbers := HBoxContainer.new()
	_body.add_child(numbers)
	_frames = _spin(numbers, "Frames", 16, 600, int(Settings.get_value("generation/frames")))
	_frames.value_changed.connect(func(value): Settings.set_value("generation/frames", int(value)))
	_steps = _spin(numbers, "Steps", 1, 200, int(Settings.get_value("generation/steps")))
	_steps.value_changed.connect(func(value): Settings.set_value("generation/steps", int(value)))
	_seed = _spin(numbers, "Seed", 0, 1 << 30, 0)

	_prompt = TextEdit.new()
	_prompt.placeholder_text = "a person walks forward and waves"
	_prompt.custom_minimum_size = Vector2(0.0, 64.0)
	_prompt.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body.add_child(_prompt)

	_generate_button = _button(_body, "Generate", _on_generate)
	_status = _message(_body, 3)


func _build_motion() -> void:
	_section(_body, "Motion")

	var row := HBoxContainer.new()
	_body.add_child(row)
	_clips = OptionButton.new()
	_clips.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clips.tooltip_text = "Everything generated under the output directory, newest first."
	_clips.item_selected.connect(_on_clip_selected)
	row.add_child(_clips)
	var refresh := _browse(_refresh_clips)
	refresh.text = "↻"
	refresh.tooltip_text = "Look again for generated clips."
	row.add_child(refresh)

	var manage := HBoxContainer.new()
	_body.add_child(manage)
	_rename_button = _button(manage, "Rename...", _on_rename_clip,
			"Rename the folder the clip lives in. Two takes of one prompt are otherwise indistinguishable.")
	_rename_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_delete_button = _button(manage, "Delete", _on_delete_clip,
			"Send the clip to the system trash.")
	_delete_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_button(_body, "Open folder", _on_open_clip_folder,
			"Show the selected clip in the file manager, or the output directory when nothing is picked.")
	_motion_label = _message(_body, 2)
	_motion_label.text = "No motion loaded."


func _build_target() -> void:
	_section(_body, "Target")
	var bone_map_row := HBoxContainer.new()
	_body.add_child(bone_map_row)
	_bone_map_path = LineEdit.new()
	# Empty by default: the standing answer is the editor setting, and repeating
	# it here would make a field that has to be kept in step with one.
	_bone_map_path.placeholder_text = _bone_map_placeholder()
	_bone_map_path.tooltip_text = "Overrides kimodo/paths/bone_map for this session. Empty falls back to that setting, which is itself empty for a rig that already uses SkeletonProfileHumanoid bone names."
	_bone_map_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bone_map_path.text_changed.connect(_on_bone_map_changed)
	bone_map_row.add_child(_bone_map_path)
	bone_map_row.add_child(_browse(func(): _pick_into(_bone_map_path, true, "*.tres,*.res")))

	_button(_body, "Find target", _on_find_target,
			"Look again for the target: the selected Skeleton3D, or the first one in the open scene, and re-read the BoneMap setting. The report follows the selection by itself.")

	_target_label = RichTextLabel.new()
	_target_label.bbcode_enabled = true
	_target_label.fit_content = true
	_target_label.custom_minimum_size = Vector2(0.0, 54.0)
	_body.add_child(_target_label)

	_button(_body, "Bake", _on_apply, "Put the clip on an AnimationPlayer in the open scene.")


func _build_save() -> void:
	_section(_body, "Save")
	# Labelled, because an unlabelled field under a header called Save and
	# holding something that looks like a stem reads as a path.
	var name_label := Label.new()
	name_label.text = "Clip name"
	name_label.tooltip_text = "Names the animation inside the AnimationPlayer that Bake writes to, and suggests the file name that Save clip offers."
	_body.add_child(name_label)
	_clip_name = LineEdit.new()
	_clip_name.text = "kimodo_motion"
	_clip_name.tooltip_text = name_label.tooltip_text
	_body.add_child(_clip_name)
	_button(_body, "Save clip...", _on_save_clip, "Write the Animation as a standalone resource.")
	_button(_body, "Open folder", _on_open_folder,
			"Show the last file saved here in the file manager, or where Save clip offers to put one.")


## Both of these are gigabytes of files nobody commits, and both are a personal
## answer, so they sit together and both live in editor settings.
func _build_folders() -> void:
	_section(_setup, "Folders")
	_models_dir = _path_row(_setup, "Model directory", "paths/models_dir",
			"Root of the bundle. The motion GGUF and the text bundle sit under it in the layout the upstream download script writes.")
	_output_dir = _path_row(_setup, "Output directory", "paths/output_dir",
			"Where a generation writes its folder. Per machine, so a teammate can put takes on another drive without touching project.godot.",
			_refresh_clips)


func _build_weights() -> void:
	_section(_setup, "Weights")
	var source := Label.new()
	source.text = "Source: kimodo/weights"
	source.tooltip_text = "%s\n%s\nat %s\n\nChange them in Editor Settings under kimodo/weights." % [
		Settings.get_value("weights/motion_repo"), Settings.get_value("weights/text_repo"),
		Settings.get_value("weights/revision")]
	source.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.75))
	_setup.add_child(source)

	_presence = RichTextLabel.new()
	_presence.bbcode_enabled = true
	_presence.fit_content = true
	_presence.custom_minimum_size = Vector2(0.0, 40.0)
	_setup.add_child(_presence)

	_token = LineEdit.new()
	_token.secret = true
	_token.placeholder_text = "Hugging Face token"
	_token.tooltip_text = "Only needed for a gated mirror. The published repositories do not ask for one."
	_token.text = String(Settings.get_value("download/access_token"))
	_token.text_changed.connect(func(value): Settings.set_value("download/access_token", value))
	_setup.add_child(_token)

	_reverify = CheckBox.new()
	_reverify.text = "Re-hash existing"
	_reverify.tooltip_text = "Check the files already on disk against the manifest instead of trusting their size. Slow over 15 GiB."
	_setup.add_child(_reverify)

	var buttons := HBoxContainer.new()
	_setup.add_child(buttons)
	_download_button = _button(buttons, "Download", _on_download,
			"Fetch both repositories and verify every file against the manifest. About 15.2 GiB. Files already in place are kept, so this also resumes and repairs.")
	_download_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cancel_button = _button(buttons, "Cancel", func(): _downloader.cancel())
	_cancel_button.disabled = true

	_download_bar = ProgressBar.new()
	_download_bar.max_value = 1.0
	_download_bar.step = 0.001
	_setup.add_child(_download_bar)

	_download_status = _message(_setup, 2)


func _build_runtime() -> void:
	_section(_setup, "Runtime")
	var backend_row := HBoxContainer.new()
	_setup.add_child(backend_row)
	var backend_label := Label.new()
	backend_label.text = "Backend"
	backend_row.add_child(backend_label)
	_backend = OptionButton.new()
	_backend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_backend.tooltip_text = "Only CPU is forced. The other choice tries Vulkan 1.2 and falls back to the CPU when no device answers, so nothing here can require the GPU."
	_backend.add_item("Vulkan if present")
	_backend.add_item("CPU")
	_backend.selected = 1 if String(Settings.get_value("runtime/backend")) == "cpu" else 0
	_backend.item_selected.connect(_on_backend_selected)
	backend_row.add_child(_backend)

	var numbers := HBoxContainer.new()
	_setup.add_child(numbers)
	_chunk = _spin(numbers, "Chunk", 1, 32, int(Settings.get_value("runtime/text_layer_chunk")),
			"Text layers held at once, 1 to 32. Fewer lowers peak VRAM and costs speed, but never below the 1002 MiB token embedding.")
	_chunk.value_changed.connect(func(value): Settings.set_value("runtime/text_layer_chunk", int(value)))
	_threads = _spin(numbers, "Threads", 0, 256, int(Settings.get_value("runtime/cpu_threads")),
			"Only applies on the CPU backend. 0 leaves it to the machine.")
	_threads.value_changed.connect(func(value): Settings.set_value("runtime/cpu_threads", int(value)))
	_gpu_index = _spin(numbers, "GPU", 0, 15, int(Settings.get_value("runtime/gpu_index")),
			"kimodo.cpp always opens Vulkan device 0, so this reorders which device that is.")
	_gpu_index.value_changed.connect(func(value): Settings.set_value("runtime/gpu_index", int(value)))

	_sysmem = CheckBox.new()
	_sysmem.text = "Spill to system RAM"
	_sysmem.tooltip_text = "Lets a buffer land in host memory when device-local VRAM runs out. It then crosses PCIe on every access, so it buys completion rather than speed."
	_sysmem.button_pressed = bool(Settings.get_value("runtime/sysmem_fallback"))
	_sysmem.toggled.connect(func(pressed): Settings.set_value("runtime/sysmem_fallback", pressed))
	_setup.add_child(_sysmem)


## A folding pane has to look like one, or it reads as a button that lost its
## panel.
func _on_setup_toggled(pressed: bool) -> void:
	_setup.visible = pressed
	_setup_toggle.text = "▾  Setup" if pressed else "▸  Setup"


func _on_backend_selected(index: int) -> void:
	Settings.set_value("runtime/backend", "cpu" if index == 1 else "auto")


# --- widget helpers ----------------------------------------------------------


func _section(parent: Control, title: String) -> void:
	parent.add_child(HSeparator.new())
	var label := Label.new()
	label.text = title
	label.add_theme_color_override(&"font_color", Color(0.6, 0.75, 1.0))
	parent.add_child(label)


## Deliberately no clip_text. Setting it drops the text from the button's
## minimum size, so a button that does not expand shrinks to its padding and
## loses its label entirely. Short labels are what keeps the dock narrow.
func _button(parent: Control, text: String, action: Callable, tooltip: String = "") -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _browse(action: Callable) -> Button:
	var button := Button.new()
	button.text = "..."
	button.pressed.connect(action)
	return button


## A status line. It wraps, and it is capped so that one long path cannot push
## everything below it off the dock.
func _message(parent: Control, lines: int) -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.max_lines_visible = lines
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	parent.add_child(label)
	return label


func _path_row(parent: Control, label_text: String, key: String, tooltip: String,
		on_changed: Callable = Callable()) -> LineEdit:
	if on_changed.is_valid():
		_path_hooks[key] = on_changed
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tooltip
	parent.add_child(label)

	var row := HBoxContainer.new()
	parent.add_child(row)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.tooltip_text = tooltip
	edit.text = String(Settings.get_value(key))
	edit.text_changed.connect(_on_path_typed.bind(key))
	row.add_child(edit)
	row.add_child(_browse(func(): _pick_into(edit, false, "*", key)))
	return edit


func _on_path_typed(value: String, key: String) -> void:
	Settings.set_value(key, value)
	_path_changed(key)


func _path_changed(key: String) -> void:
	_refresh_presence()
	if _path_hooks.has(key):
		_path_hooks[key].call()


func _spin(parent: Control, label_text: String, low: int, high: int, value: int,
		tooltip: String = "") -> SpinBox:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(box)
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tooltip
	box.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.value = value
	spin.tooltip_text = tooltip
	box.add_child(spin)
	return spin


func _pick_into(target: LineEdit, file_mode: bool, filter: String = "*", key: String = "") -> void:
	if is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE if file_mode else FileDialog.FILE_MODE_OPEN_DIR
	if file_mode and filter != "*":
		_dialog.filters = PackedStringArray(filter.split(","))
	_dialog.size = Vector2i(720, 480)
	_dialog.dir_selected.connect(func(path): _accept_pick(target, key, path))
	_dialog.file_selected.connect(func(path): _accept_pick(target, key, path))
	add_child(_dialog)
	_dialog.popup_centered()


func _accept_pick(target: LineEdit, key: String, path: String) -> void:
	target.text = path
	if not key.is_empty():
		Settings.set_value(key, path)
	if target == _bone_map_path:
		_on_bone_map_changed(path)
	_path_changed(key)


# --- weights -----------------------------------------------------------------


## The files llm_text_encoder::load() insists on, so that "present" means
## kmd-generate will accept the bundle rather than only that a directory turned
## up. Checking the directory alone let a download that stopped halfway read as
## complete.
func _missing_weights() -> PackedStringArray:
	var missing := PackedStringArray()
	if not FileAccess.file_exists(Settings.motion_gguf_path()):
		missing.append("kimodo-smplx-rp-v1-f32.gguf")

	var bundle := Settings.text_bundle_path()
	for name in ["tokenizer.gguf", "embedding.gguf", "final-norm.gguf"]:
		if not FileAccess.file_exists(bundle.path_join(name)):
			missing.append(name)
	for layer in 32:
		var name := "layer-%02d.gguf" % layer
		if not FileAccess.file_exists(bundle.path_join(name)):
			missing.append(name)
	return missing


func _weights_present() -> bool:
	return _missing_weights().is_empty()


func _refresh_presence() -> void:
	var generator := Settings.generator_path()
	var missing := _missing_weights()

	var lines := PackedStringArray()
	lines.append(_presence_line("kmd-generate", not generator.is_empty()))
	if missing.is_empty():
		lines.append(_presence_line("weights, all 36 files", true))
	else:
		lines.append(_presence_line("weights, %d of 36 missing" % missing.size(), false))
	_presence.text = "\n".join(lines)

	# Long paths and a long list of names both wrap into a wall of text, so the
	# detail lives here.
	_presence.tooltip_text = "%s\n%s\n%s\n\n%s" % [
			generator if not generator.is_empty() else Settings.bundled_generator_path() + "  (not built)",
			Settings.motion_gguf_path(), Settings.text_bundle_path(),
			"complete" if missing.is_empty() else "missing: " + ", ".join(missing)]

	# The same answer on the folded pane, so "are the weights there?" does not
	# need the pane opened to answer it.
	_setup_toggle.tooltip_text = "The weight download and the runtime knobs.\n\nWeights: %s" % (
			"all 36 files present" if missing.is_empty() else "%d of 36 missing" % missing.size())


func _presence_line(label: String, present: bool) -> String:
	var colour := "#7fd07f" if present else "#e0a050"
	return "[color=%s]%s[/color]  %s" % [colour, "present" if present else "missing", label]


func _on_download() -> void:
	if _downloader.is_busy():
		return
	# A resume needs no ceremony. Asking is for the case where there is nothing
	# obvious to gain, so the question has to say what pressing it actually costs.
	if _weights_present():
		_ask_before_redownload()
		return
	_start_download()


func _ask_before_redownload() -> void:
	if is_instance_valid(_confirm):
		_confirm.queue_free()
	_confirm = ConfirmationDialog.new()
	_confirm.title = "The weights are already here"
	_confirm.ok_button_text = "Download"
	_confirm.dialog_text = ("All 36 files are in place.\n\n" + (
			"Re-hash existing is on, so this reads about 15.2 GiB off disk to check every file against the manifest, and re-fetches only what fails."
			if _reverify.button_pressed else
			"This compares their sizes against the manifest and re-fetches only what does not match, so it normally transfers nothing but the two manifests. Tick Re-hash existing first to check the contents too."))
	_confirm.confirmed.connect(_start_download)
	add_child(_confirm)
	_confirm.popup_centered()


func _start_download() -> void:
	var destination := _models_dir.text.strip_edges()
	if destination.is_empty():
		_set_message(_download_status, "Set a model directory first.")
		return

	var revision := String(Settings.get_value("weights/revision"))
	var repos := [
		{
			"repo": String(Settings.get_value("weights/motion_repo")),
			"revision": revision,
			"include": [Settings.MOTION_RELATIVE],
		},
		{
			"repo": String(Settings.get_value("weights/text_repo")),
			"revision": revision,
			"include": [Settings.TEXT_BUNDLE_RELATIVE + "/*"],
		},
	]

	_download_button.disabled = true
	_cancel_button.disabled = false
	_set_message(_download_status, "Reading the manifests...")
	_downloader.run(destination, repos, _token.text.strip_edges(), _reverify.button_pressed)


func _on_download_progress(text: String, ratio: float) -> void:
	_download_bar.value = ratio
	_set_message(_download_status, text)


func _on_download_finished(ok: bool, message: String) -> void:
	_download_button.disabled = false
	_cancel_button.disabled = true
	_download_bar.value = 1.0 if ok else 0.0
	_set_message(_download_status, message)
	_refresh_presence()


## Capped labels drop the tail, so the whole message stays reachable as a
## tooltip.
func _set_message(label: Label, text: String) -> void:
	label.text = text
	label.tooltip_text = text


# --- generation --------------------------------------------------------------


func _on_generate() -> void:
	if _pid >= 0:
		return
	if Settings.generator_path().is_empty():
		_set_message(_status, "No kmd-generate in the addon. Build it with scons.")
		return
	if not _weights_present():
		_set_message(_status, "The weights are incomplete. Download them under Weights below.")
		return
	if _prompt.text.strip_edges().is_empty():
		_set_message(_status, "The prompt is empty.")
		return

	var stamp := str(Time.get_unix_time_from_system()).replace(".", "")
	var out_dir: String = Settings.output_dir().path_join("gen_%s" % stamp)
	DirAccess.make_dir_recursive_absolute(out_dir)

	var prompt_path := out_dir.path_join("prompt.txt")
	var file := FileAccess.open(prompt_path, FileAccess.WRITE)
	if file == null:
		_set_message(_status, "Cannot write %s." % prompt_path)
		return
	file.store_string(_prompt.text.strip_edges())
	file.close()

	_pid = _spawn_generator(prompt_path, out_dir)
	if _pid < 0:
		_set_message(_status, "Could not start %s." % Settings.generator_path())
		return
	_pending_output = out_dir
	_generate_button.disabled = true
	_set_message(_status, "Generating into %s ..." % out_dir)


## The one place that knows how a motion gets generated.
func _spawn_generator(prompt_path: String, out_dir: String) -> int:
	# OS.create_process() takes no environment, and every knob the child reads is
	# an environment variable, so they go on the editor process to be inherited.
	var environment := Settings.runtime_environment()
	for variable in environment:
		var value: String = environment[variable]
		if value.is_empty():
			OS.unset_environment(variable)
		else:
			OS.set_environment(variable, value)

	var arguments := [
		ProjectSettings.globalize_path(Settings.motion_gguf_path()),
		ProjectSettings.globalize_path(Settings.text_bundle_path()),
		ProjectSettings.globalize_path(prompt_path),
		str(int(_frames.value)),
		str(int(_steps.value)),
		str(int(_seed.value)),
		ProjectSettings.globalize_path(out_dir),
	]
	return OS.create_process(ProjectSettings.globalize_path(Settings.generator_path()), arguments, false)


func _process(delta: float) -> void:
	_advance_preview(delta)
	if _pid < 0 or OS.is_process_running(_pid):
		return

	var exit_code := OS.get_process_exit_code(_pid)
	_pid = -1
	_generate_button.disabled = false

	if exit_code != 0:
		_set_message(_status, "kmd-generate exited with %d. See its console output." % exit_code)
	elif _load_motion(_pending_output):
		_refresh_clips()
		_clips.select(_clip_dirs.find(_pending_output))
		_set_message(_status, "Done.")
	else:
		_set_message(_status, "%s produced no readable motion. See the console." % _pending_output)


# --- motion ------------------------------------------------------------------


## Every generation under the output root, newest first. Picking one here is
## what the Target and Save sections then work on, so an older take can be
## revisited without hunting for its folder.
func _refresh_clips() -> void:
	var root := Settings.output_dir()
	var found := []
	for name in DirAccess.get_directories_at(root):
		var dir := root.path_join(name)
		var positions := dir.path_join("root_positions.f32")
		if not FileAccess.file_exists(positions):
			continue
		found.append({"dir": dir, "time": FileAccess.get_modified_time(positions)})
	found.sort_custom(func(a, b): return a["time"] > b["time"])

	_clips.clear()
	_clip_dirs = PackedStringArray()
	if found.is_empty():
		_clips.add_item("no clips under %s" % root)
		_clips.set_item_disabled(0, true)
		_clips.disabled = true
		_refresh_clip_buttons()
		return

	_clips.disabled = false
	for entry in found:
		_clip_dirs.append(entry["dir"])
		_clips.add_item(_clip_label(entry["dir"]))
	# Nothing is selected by a refresh: loading a clip is the user asking for
	# it, not a side effect. The clip already loaded is the exception, so that
	# deleting or renaming another one does not look like it deselected this
	# one. select() does not emit item_selected, so nothing reloads.
	_clips.select(_clip_dirs.find(_loaded_clip) if not _loaded_clip.is_empty() else -1)
	_refresh_clip_buttons()


## A folder still called gen_<stamp> has nothing to say, so it shows its
## prompt. One that has been renamed shows the name, which is the whole point
## of renaming it.
func _clip_label(dir: String) -> String:
	var folder := dir.get_file()
	var prompt := folder
	if folder.begins_with("gen_"):
		var file := FileAccess.open(dir.path_join("prompt.txt"), FileAccess.READ)
		if file != null:
			prompt = file.get_as_text().strip_edges().replace("
", " ")
			file.close()
	if prompt.is_empty():
		prompt = folder
	if prompt.length() > 26:
		prompt = prompt.substr(0, 25) + "…"

	var frames := 0
	var positions := FileAccess.open(dir.path_join("root_positions.f32"), FileAccess.READ)
	if positions != null:
		frames = int(positions.get_length() / 12)
		positions.close()
	return "%s  %d" % [prompt, frames]


func _on_clip_selected(index: int) -> void:
	_refresh_clip_buttons()
	if index < 0 or index >= _clip_dirs.size():
		return
	_load_motion(_clip_dirs[index])


func _refresh_clip_buttons() -> void:
	var picked := _selected_clip()
	_rename_button.disabled = picked.is_empty()
	_delete_button.disabled = picked.is_empty()


func _selected_clip() -> String:
	var index := _clips.get_selected()
	return _clip_dirs[index] if index >= 0 and index < _clip_dirs.size() else ""


## Renaming the folder rather than storing a label beside it: the folder name is
## what a person sees in a file manager too, and two takes of one prompt are
## otherwise the same line twice.
func _on_rename_clip() -> void:
	var clip := _selected_clip()
	if clip.is_empty():
		return
	if is_instance_valid(_confirm):
		_confirm.queue_free()
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Rename clip"
	_confirm.ok_button_text = "Rename"
	_rename_field = LineEdit.new()
	_rename_field.text = clip.get_file()
	_rename_field.custom_minimum_size = Vector2(320.0, 0.0)
	_confirm.add_child(_rename_field)
	_confirm.register_text_enter(_rename_field)
	_confirm.confirmed.connect(_apply_rename.bind(clip))
	add_child(_confirm)
	_confirm.popup_centered()
	_rename_field.select_all()
	_rename_field.grab_focus()


func _apply_rename(clip: String) -> void:
	var name := _rename_field.text.strip_edges()
	if name.is_empty():
		return
	# validate_filename() sanitises rather than judges, so a difference is the
	# answer to whether the name was usable, and also what to suggest instead.
	var usable := name.validate_filename()
	if name != usable:
		_set_message(_motion_label, "A folder cannot be called %s. Try %s." % [name, usable])
		return
	var destination := clip.get_base_dir().path_join(name)
	if destination == clip:
		return
	if DirAccess.dir_exists_absolute(destination):
		_set_message(_motion_label, "%s is already there." % name)
		return

	var error := DirAccess.rename_absolute(clip, destination)
	if error != OK:
		_set_message(_motion_label, "Rename failed (%d)." % error)
		return
	if _loaded_clip == clip:
		_loaded_clip = destination
	_refresh_clips()
	_set_message(_motion_label, "Renamed to %s." % name)


## The trash rather than a delete: a clip is minutes of GPU time, and a list
## with a Delete button next to it is a list someone will misclick.
func _on_delete_clip() -> void:
	var clip := _selected_clip()
	if clip.is_empty():
		return
	if is_instance_valid(_confirm):
		_confirm.queue_free()
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Delete clip"
	_confirm.ok_button_text = "Move to trash"
	_confirm.dialog_text = "%s goes to the system trash.

%s" % [clip.get_file(), clip]
	_confirm.confirmed.connect(_apply_delete.bind(clip))
	add_child(_confirm)
	_confirm.popup_centered()


func _apply_delete(clip: String) -> void:
	var error := OS.move_to_trash(ProjectSettings.globalize_path(clip))
	if error != OK:
		_set_message(_motion_label, "Could not move %s to the trash (%d)." % [clip.get_file(), error])
		return
	if _loaded_clip == clip:
		_motion = null
		_loaded_clip = ""
		_reload_preview()
		_set_message(_motion_label, "No motion loaded.")
	_refresh_clips()
	_set_message(_status, "%s is in the trash." % clip.get_file())


## Looking inside a take is a file manager's job. Reading one straight into the
## dock was the other half of this button and is gone with it: a clip outside
## the output root ends up loaded but unlisted, with Rename and Delete unable to
## reach it. Point the output directory at it instead and it joins the list.
func _on_open_clip_folder() -> void:
	var target := _selected_clip()
	if target.is_empty():
		target = Settings.output_dir()
	if not DirAccess.dir_exists_absolute(target):
		_set_message(_motion_label, "%s is not there yet." % target)
		return
	var absolute := ProjectSettings.globalize_path(target)
	if OS.shell_show_in_file_manager(absolute, true) != OK:
		_set_message(_motion_label, "Could not open %s." % absolute)


func _load_motion(dir: String) -> bool:
	var motion := KimodoMotion.new()
	if motion.load_directory(dir) != OK:
		_motion = null
		_set_message(_motion_label, "Failed to load %s." % dir)
		return false
	_motion = motion
	_loaded_clip = dir
	_reload_preview()
	_set_message(_motion_label, "%d frames, %.2f s at %.0f fps\n%s" % [motion.get_frame_count(),
			motion.get_duration(), motion.get_fps(), dir])
	return true


# --- target ------------------------------------------------------------------


## The one place kimodo/paths/bone_map is re-read. Editor settings can change
## while the dock is open and nothing announces it, so the button that goes
## looking for the target picks that up on the same press.
func _on_find_target() -> void:
	_bone_map_path.placeholder_text = _bone_map_placeholder()
	_on_bone_map_changed(_bone_map_path.text)


## What the empty field stands for, so that leaving it alone is not a guess.
func _bone_map_placeholder() -> String:
	var fallback := Settings.bone_map_path()
	return fallback.get_file() if not fallback.is_empty() else "BoneMap (optional)"


## The field is an override, not the answer. Empty means the editor setting,
## and only when that is empty too does the rig go unmapped, which is right for
## one already named after SkeletonProfileHumanoid.
func _on_bone_map_changed(path: String) -> void:
	var resolved := path.strip_edges()
	if resolved.is_empty():
		resolved = Settings.bone_map_path()
	_bone_map = null
	# Guarded rather than loaded blind: this runs on every keystroke, and a
	# half-typed path is a console error for each one.
	if not resolved.is_empty() and FileAccess.file_exists(resolved):
		_bone_map = ResourceLoader.load(resolved, "BoneMap", ResourceLoader.CACHE_MODE_REUSE)
	_refresh_target()


func _target_skeleton() -> Skeleton3D:
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is Skeleton3D:
			return node
	return _find_skeleton(EditorInterface.get_edited_scene_root())


func _find_skeleton(node: Node) -> Skeleton3D:
	if node == null:
		return null
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


## The plugin's answer to the edited scene changing: the skeleton the report
## describes may not be in the new scene at all.
func refresh_target() -> void:
	_refresh_target()


func _refresh_target() -> void:
	var skeleton := _target_skeleton()
	if skeleton == null:
		_target_label.text = "[i]No Skeleton3D in the open scene.[/i]"
		_target_label.tooltip_text = "Select a Skeleton3D, or open a scene that has one."
		return

	var report := KimodoRetarget.describe_mapping(skeleton, _bone_map)
	var missing: PackedStringArray = report["missing"]
	var lines := PackedStringArray()
	lines.append("[b]%s[/b]  %d bones" % [skeleton.name, skeleton.get_bone_count()])
	lines.append("mapped %d/22, scale %.3f" % [report["mapped"].size(), report["scale"]])
	if missing.is_empty():
		lines.append("[color=#7fd07f]every joint resolved[/color]")
	else:
		lines.append("[color=#e0a050]unmapped: %s[/color]" % ", ".join(missing))
	_target_label.text = "\n".join(lines)
	_target_label.tooltip_text = "%.3f m retargets to %.3f m.\n%s" % [report["source_height"],
			report["target_height"], "\n".join(report["mapped"])]


func _bake() -> Animation:
	if _motion == null:
		_set_message(_status, "Load or generate a motion first.")
		return null
	var skeleton := _target_skeleton()
	if skeleton == null:
		_set_message(_status, "No Skeleton3D to bake onto.")
		return null

	var root := EditorInterface.get_edited_scene_root()
	var path := root.get_path_to(skeleton) if root != null else NodePath(skeleton.name)
	return KimodoRetarget.bake_animation(_motion, skeleton, _bone_map, path)


func _on_apply() -> void:
	var animation := _bake()
	if animation == null:
		return

	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_set_message(_status, "Open a scene to bake into.")
		return

	var player := _find_player(root)
	if player == null:
		player = AnimationPlayer.new()
		player.name = "KimodoPlayer"
		root.add_child(player)
		player.owner = root

	var library_name := StringName("kimodo")
	if player.has_animation_library(library_name):
		# Only when it is playing out of the library about to go, so baking
		# does not stop a player that was showing something else.
		if player.assigned_animation.begins_with("%s/" % library_name):
			player.stop()
		player.remove_animation_library(library_name)
	var library := AnimationLibrary.new()
	library.add_animation(StringName(_clip_name.text), animation)
	player.add_animation_library(library_name, library)

	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(player)
	_set_message(_status, "Baked into %s as kimodo/%s." % [player.name, _clip_name.text])
	_refresh_target()


func _find_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_player(child)
		if found != null:
			return found
	return null


# --- saving ------------------------------------------------------------------


func _on_save_clip() -> void:
	var animation := _bake()
	if animation == null:
		return
	_save_dialog("res://%s.tres" % _clip_name.text, _write_clip.bind(animation))


func _write_clip(path: String, animation: Animation) -> void:
	var error := KimodoLibrary.save_animation(animation, path)
	if error == OK:
		_last_saved = path
		_set_message(_status, "Saved %s." % path)
	else:
		_set_message(_status, "Saving %s failed (%d)." % [path, error])
	EditorInterface.get_resource_filesystem().scan()


## A viewport of its own, on the SMPL-X mannequin rather than the target rig:
## the rig lives in the edited scene and cannot be in two worlds at once. What
## it shows is the motion as generated, before retargeting.
func _build_preview() -> void:
	_section(_body, "Preview")

	_preview_container = SubViewportContainer.new()
	_preview_container.stretch = true
	# A ScrollContainer hands every child its minimum height and scrolls the
	# rest, so expanding does nothing here and the number below is the height.
	_preview_container.custom_minimum_size = Vector2(0.0, float(Settings.get_value("preview/height")))
	_preview_container.tooltip_text = "Drag to orbit, wheel to zoom."
	_preview_container.gui_input.connect(_on_preview_input)
	_body.add_child(_preview_container)

	_preview_grip = HSeparator.new()
	_preview_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	_preview_grip.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	_preview_grip.custom_minimum_size = Vector2(0.0, 8.0)
	_preview_grip.tooltip_text = "Drag to make the preview taller or shorter."
	_preview_grip.gui_input.connect(_on_preview_resized)
	_body.add_child(_preview_grip)

	_preview = SubViewport.new()
	# Without its own world this would render whatever the editor viewport is
	# looking at.
	_preview.own_world_3d = true
	_preview.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_preview_container.add_child(_preview)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.10, 0.10, 0.12)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.35, 0.36, 0.42)
	environment.ambient_light_energy = 0.6

	_preview_camera = Camera3D.new()
	_preview_camera.current = true
	_preview_camera.near = 0.02
	_preview_camera.environment = environment
	_preview.add_child(_preview_camera)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
	_preview.add_child(sun)

	var ground := MeshInstance3D.new()
	ground.mesh = _preview_grid()
	_preview.add_child(ground)

	_build_preview_figure()

	# The player goes inside the figure. Parented above it the bone poses still
	# move while a skinned mesh goes on rendering its rest.
	_preview_player = AnimationPlayer.new()
	_preview_figure.add_child(_preview_player)

	var row := HBoxContainer.new()
	_body.add_child(row)
	_preview_play = _button(row, "Play", _on_preview_play)
	_preview_slider = HSlider.new()
	_preview_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_preview_slider.min_value = 0.0
	_preview_slider.max_value = 1.0
	_preview_slider.step = 0.001
	_preview_slider.value_changed.connect(_on_preview_scrubbed)
	row.add_child(_preview_slider)

	_aim_preview()


## The bundled mannequin when it is there, the procedural capsules when it is
## not, so stripping the model out leaves the addon working.
##
## Its bones already carry SkeletonProfileHumanoid names and it already stands
## on the floor, which is why nothing here needs a BoneMap or an import-time
## rest fix.
func _build_preview_figure() -> void:
	var scene: PackedScene = load(MANNEQUIN) if ResourceLoader.exists(MANNEQUIN) else null
	if scene != null:
		var model := scene.instantiate() as Node3D
		_preview.add_child(model)
		_preview_skeleton = _find_skeleton(model)
		if _preview_skeleton != null:
			_preview_figure = model
			_preview_retargets = true
			return
		_preview.remove_child(model)
		model.queue_free()

	_preview_figure = Node3D.new()
	_preview_figure.name = "Figure"
	_preview.add_child(_preview_figure)
	_preview_skeleton = KimodoSmplx.create_rest_skeleton()
	_preview_figure.add_child(_preview_skeleton)
	KimodoSmplx.build_mannequin(_preview_skeleton, null)
	_preview_retargets = false


## A ground plane to judge contact against. The camera follows the root, so a
## world-fixed grid also gives the travel something to read against.
func _preview_grid() -> ImmediateMesh:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var extent := 16.0
	var offset := -extent
	while offset <= extent + 0.001:
		var colour := Color(0.30, 0.30, 0.34) if not is_zero_approx(fmod(offset, 1.0)) 				else Color(0.42, 0.42, 0.48)
		for pair in [[Vector3(-extent, 0.0, offset), Vector3(extent, 0.0, offset)],
				[Vector3(offset, 0.0, -extent), Vector3(offset, 0.0, extent)]]:
			mesh.surface_set_color(colour)
			mesh.surface_add_vertex(pair[0])
			mesh.surface_set_color(colour)
			mesh.surface_add_vertex(pair[1])
		offset += 0.25
	mesh.surface_end()
	return mesh


## Rebuilt whenever the motion changes, because the clip is baked once rather
## than evaluated per frame.
func _reload_preview() -> void:
	if _preview_player == null:
		return
	# Stop before removing. A playing AnimationPlayer holds a bare pointer to
	# the animation it is on, and taking the library away underneath it is a
	# segfault on the next frame rather than an error.
	_preview_player.stop()
	if _preview_player.has_animation_library(&""):
		_preview_player.remove_animation_library(&"")
	_preview_time = 0.0
	if _motion == null:
		return

	var path := _preview_figure.get_path_to(_preview_skeleton)
	var animation := KimodoRetarget.bake_animation(_motion, _preview_skeleton, null, path) 			if _preview_retargets else _motion.bake_animation(path)
	if animation == null:
		return
	animation.loop_mode = Animation.LOOP_LINEAR
	var library := AnimationLibrary.new()
	library.add_animation(&"motion", animation)
	_preview_player.add_animation_library(&"", library)
	# Playing at zero speed rather than paused. A paused player still takes a
	# seek and the bone poses do move, but a skinned mesh goes on rendering its
	# rest, so only the skeleton animates. At zero speed the player keeps
	# processing and the skin follows, while the clock below stays the only
	# thing that moves time.
	_preview_player.play(&"motion")
	_preview_player.speed_scale = 0.0


## The clock is turned by hand: seeking keeps the slider and the pose describing
## the same frame, and it works on a paused player.
##
## The readiness test is assigned_animation rather than current_animation.
## current_animation reports an empty name whenever the player is not playing,
## which is exactly the state this preview sits in, so guarding on it meant
## never advancing at all.
func _advance_preview(delta: float) -> void:
	if _motion == null or _preview_player == null or _preview_player.assigned_animation.is_empty():
		return
	var length := _motion.get_duration()
	if _preview_running and length > 0.0:
		_preview_time = fmod(_preview_time + delta, length)
		_preview_slider.set_value_no_signal(_preview_time / length)
	_preview_player.seek(_preview_time, true)
	_aim_preview()


func _aim_preview() -> void:
	var pivot := _preview_pivot()
	var direction := Vector3(
			cos(_preview_pitch) * sin(_preview_yaw),
			sin(_preview_pitch),
			cos(_preview_pitch) * cos(_preview_yaw))
	# look_at() refuses to work on a node that is not in the tree yet, and this
	# runs once while the pane is still being built.
	_preview_camera.look_at_from_position(pivot + direction * _preview_distance, pivot, Vector3.UP)


## The height is a setting rather than a session value: a dock that forgets how
## tall the preview was is a dock that has to be adjusted every time it opens.
func _on_preview_resized(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT)):
		return
	var height := clampf(_preview_container.custom_minimum_size.y + event.relative.y, 120.0, 900.0)
	_preview_container.custom_minimum_size.y = height
	Settings.set_value("preview/height", int(height))
	_preview_grip.accept_event()


## Orbit and zoom turn around the middle of the model itself. A guessed height
## aims at nothing in particular, and with no motion loaded the rest skeleton
## keeps its pelvis at the origin with its feet below, so a fixed pivot pointed
## at empty air above the mannequin.
func _preview_pivot() -> Vector3:
	if _preview_skeleton == null or _preview_skeleton.get_bone_count() == 0:
		return Vector3.ZERO
	var low := Vector3.INF
	var high := -Vector3.INF
	for bone in _preview_skeleton.get_bone_count():
		var origin := _preview_bone_origin(bone)
		low = low.min(origin)
		high = high.max(origin)
	return (low + high) * 0.5


## Composed by hand: get_bone_global_pose() still reports the rest when it is
## read in the same frame as the seek that posed the skeleton.
func _preview_bone_origin(bone: int) -> Vector3:
	var transform := _preview_skeleton.get_bone_pose(bone)
	var parent := _preview_skeleton.get_bone_parent(bone)
	while parent >= 0:
		transform = _preview_skeleton.get_bone_pose(parent) * transform
		parent = _preview_skeleton.get_bone_parent(parent)
	return transform.origin


func _on_preview_play() -> void:
	_set_preview_running(not _preview_running)


## One place decides the label, so the button cannot end up describing a state
## the preview is not in.
func _set_preview_running(running: bool) -> void:
	_preview_running = running
	_preview_play.text = "Pause" if running else "Play"


func _on_preview_scrubbed(value: float) -> void:
	_set_preview_running(false)
	_preview_time = value * maxf(0.001, _motion.get_duration() if _motion != null else 1.0)


## Whatever the viewport uses, it also swallows. The dock scrolls, so a wheel
## that both zoomed and slid the panel out from under the pointer would make
## the preview unusable.
func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_preview_yaw -= event.relative.x * 0.008
		_preview_pitch = clampf(_preview_pitch - event.relative.y * 0.008, -1.4, 1.4)
		_aim_preview()
		_preview_container.accept_event()
	elif event is InputEventMouseButton and event.pressed:
		# Zooming by a ratio rather than a step: a fixed step is coarse up close
		# and glacial far out. The near end is a hand's width from a joint.
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_preview_distance = clampf(_preview_distance * 0.85, 0.12, 30.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_preview_distance = clampf(_preview_distance * 1.18, 0.12, 30.0)
		else:
			return
		_aim_preview()
		_preview_container.accept_event()


## Reveals the last file saved from here, so the answer to "where did that go?"
## is one press rather than a path read off a status line. Before anything has
## been saved it falls back to where Save clip would offer to put one.
func _on_open_folder() -> void:
	var target := _last_saved
	if target.is_empty() or not FileAccess.file_exists(target):
		target = "res://"

	var absolute := ProjectSettings.globalize_path(target)
	if not (FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target)):
		_set_message(_status, "%s is not there yet." % target)
		return
	if OS.shell_show_in_file_manager(absolute, true) != OK:
		_set_message(_status, "Could not open %s." % absolute)


func _save_dialog(default_path: String, on_selected: Callable) -> void:
	if is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_RESOURCES
	_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_dialog.filters = PackedStringArray(["*.tres", "*.res"])
	_dialog.current_path = default_path
	_dialog.size = Vector2i(720, 480)
	_dialog.file_selected.connect(on_selected)
	add_child(_dialog)
	_dialog.popup_centered()
