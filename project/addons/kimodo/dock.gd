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
## A dock is narrow, so anything longer than a few words goes in a tooltip. A
## wrapped sentence turns into ten lines of height here, and a button that does
## not wrap sets a minimum width the user cannot pull back in.

const Settings := preload("res://addons/kimodo/settings.gd")
const Downloader := preload("res://addons/kimodo/downloader.gd")

var _body: VBoxContainer

var _setup_toggle: Button
var _setup: VBoxContainer
var _generator_path: LineEdit
var _models_dir: LineEdit
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

var _prompt: TextEdit
var _frames: SpinBox
var _steps: SpinBox
var _seed: SpinBox
var _generate_button: Button
var _status: Label

var _motion_label: Label
var _target_label: RichTextLabel
var _bone_map_path: LineEdit
var _clip_name: LineEdit

var _motion: KimodoMotion
var _bone_map: BoneMap
var _pid := -1
var _pending_output := ""
var _dialog: FileDialog
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

	_build_ui()


func _build_ui() -> void:
	_setup_toggle = Button.new()
	_setup_toggle.toggle_mode = true
	_setup_toggle.text = "Setup"
	_setup_toggle.toggled.connect(func(pressed): _setup.visible = pressed)
	_body.add_child(_setup_toggle)

	_setup = VBoxContainer.new()
	_setup.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_setup)
	_build_setup()

	_section(_body, "Generate")
	_prompt = TextEdit.new()
	_prompt.placeholder_text = "a person walks forward and waves"
	_prompt.custom_minimum_size = Vector2(0.0, 64.0)
	_prompt.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body.add_child(_prompt)

	var numbers := HBoxContainer.new()
	_body.add_child(numbers)
	_frames = _spin(numbers, "Frames", 16, 600, int(Settings.project_get("generation/frames")))
	_steps = _spin(numbers, "Steps", 1, 200, int(Settings.project_get("generation/steps")))
	_seed = _spin(numbers, "Seed", 0, 1 << 30, 0)

	_generate_button = _button(_body, "Generate", _on_generate)
	_status = _message(_body, 3)

	_section(_body, "Motion")
	_button(_body, "Load folder...", _on_load_folder,
			"Read an OUT_DIR that kmd-generate has already written.")
	_motion_label = _message(_body, 2)
	_motion_label.text = "No motion loaded."

	_section(_body, "Target")
	var bone_map_row := HBoxContainer.new()
	_body.add_child(bone_map_row)
	_bone_map_path = LineEdit.new()
	_bone_map_path.placeholder_text = "BoneMap (optional)"
	_bone_map_path.tooltip_text = "Leave empty when the rig already uses SkeletonProfileHumanoid bone names."
	_bone_map_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bone_map_path.text = String(Settings.project_get("target/bone_map"))
	_bone_map_path.text_changed.connect(_on_bone_map_changed)
	bone_map_row.add_child(_bone_map_path)
	bone_map_row.add_child(_browse(func(): _pick_into(_bone_map_path, true, "*.tres,*.res")))

	_button(_body, "Use selection", _refresh_target,
			"Retarget onto the selected Skeleton3D, or the first one in the open scene.")

	_target_label = RichTextLabel.new()
	# Off by default, and without it the tags render as literal text.
	_target_label.bbcode_enabled = true
	_target_label.fit_content = true
	_target_label.custom_minimum_size = Vector2(0.0, 54.0)
	_body.add_child(_target_label)

	_button(_body, "Bake", _on_apply, "Put the clip on an AnimationPlayer in the open scene.")

	_section(_body, "Save")
	_clip_name = LineEdit.new()
	_clip_name.text = "kimodo_motion"
	_clip_name.tooltip_text = "Name the clip takes inside the player and the library."
	_body.add_child(_clip_name)
	_button(_body, "Save clip...", _on_save_clip, "Write the Animation as a standalone resource.")
	_button(_body, "Add to library...", _on_save_library,
			"Add or replace this name in an AnimationLibrary, creating it if needed.")

	_on_bone_map_changed(_bone_map_path.text)
	_refresh_presence()
	# Nothing here works until the generator and the weights are in place, so the
	# setup pane opens itself until they are.
	_setup_toggle.button_pressed = _generator_path.text.is_empty() or not _weights_present()
	_setup.visible = _setup_toggle.button_pressed


func _build_setup() -> void:
	_section(_setup, "Paths")
	_generator_path = _editor_path_row("kmd-generate", "paths/generator", true,
			"The kmd-generate binary built from kimodo.cpp.")
	_models_dir = _editor_path_row("Models", "paths/models_dir", false,
			"Root of the downloaded bundle. The motion GGUF and the text bundle sit under it in the layout the upstream download script writes.")

	_section(_setup, "Weights")
	var source := Label.new()
	source.text = "Source: kimodo/weights"
	source.tooltip_text = "%s\n%s\nat %s\n\nChange them in Project Settings under kimodo/weights." % [
		Settings.project_get("weights/motion_repo"), Settings.project_get("weights/text_repo"),
		Settings.project_get("weights/revision")]
	source.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.75))
	_setup.add_child(source)

	_presence = RichTextLabel.new()
	_presence.bbcode_enabled = true
	_presence.fit_content = true
	_presence.custom_minimum_size = Vector2(0.0, 36.0)
	_setup.add_child(_presence)

	_token = LineEdit.new()
	_token.secret = true
	_token.placeholder_text = "Hugging Face token"
	_token.tooltip_text = "Only needed for a gated mirror. The published repositories do not ask for one."
	_token.text = String(Settings.editor_get("download/access_token"))
	_token.text_changed.connect(func(value): Settings.editor_set("download/access_token", value))
	_setup.add_child(_token)

	_reverify = CheckBox.new()
	_reverify.text = "Re-hash existing"
	_reverify.tooltip_text = "Check the files already on disk against the manifest instead of trusting their size. Slow over 15 GiB."
	_setup.add_child(_reverify)

	var buttons := HBoxContainer.new()
	_setup.add_child(buttons)
	_download_button = _button(buttons, "Download", _on_download,
			"Fetch both repositories and verify every file against the manifest. About 15.2 GiB.")
	_download_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cancel_button = _button(buttons, "Cancel", func(): _downloader.cancel())
	_cancel_button.disabled = true

	_download_bar = ProgressBar.new()
	_download_bar.max_value = 1.0
	_download_bar.step = 0.001
	_setup.add_child(_download_bar)

	_download_status = _message(_setup, 2)

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
	_backend.selected = 1 if String(Settings.editor_get("runtime/backend")) == "cpu" else 0
	_backend.item_selected.connect(_on_backend_selected)
	backend_row.add_child(_backend)

	var runtime_numbers := HBoxContainer.new()
	_setup.add_child(runtime_numbers)
	_chunk = _spin(runtime_numbers, "Chunk", 1, 32, int(Settings.editor_get("runtime/text_layer_chunk")),
			"Text layers held at once, 1 to 32. Fewer lowers peak VRAM and costs speed, but never below the 1002 MiB token embedding.")
	_chunk.value_changed.connect(func(value): Settings.editor_set("runtime/text_layer_chunk", int(value)))
	_threads = _spin(runtime_numbers, "Threads", 0, 256, int(Settings.editor_get("runtime/cpu_threads")),
			"Only applies on the CPU backend. 0 leaves it to the machine.")
	_threads.value_changed.connect(func(value): Settings.editor_set("runtime/cpu_threads", int(value)))
	_gpu_index = _spin(runtime_numbers, "GPU", 0, 15, int(Settings.editor_get("runtime/gpu_index")),
			"kimodo.cpp always opens Vulkan device 0, so this reorders which device that is.")
	_gpu_index.value_changed.connect(func(value): Settings.editor_set("runtime/gpu_index", int(value)))

	_sysmem = CheckBox.new()
	_sysmem.text = "Spill to system RAM"
	_sysmem.tooltip_text = "Lets a buffer land in host memory when device-local VRAM runs out. It then crosses PCIe on every access, so it buys completion rather than speed."
	_sysmem.button_pressed = bool(Settings.editor_get("runtime/sysmem_fallback"))
	_sysmem.toggled.connect(func(pressed): Settings.editor_set("runtime/sysmem_fallback", pressed))
	_setup.add_child(_sysmem)


func _on_backend_selected(index: int) -> void:
	Settings.editor_set("runtime/backend", "cpu" if index == 1 else "auto")


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


func _editor_path_row(label_text: String, key: String, file_mode: bool, tooltip: String) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tooltip
	_setup.add_child(label)

	var row := HBoxContainer.new()
	_setup.add_child(row)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.tooltip_text = tooltip
	edit.text = String(Settings.editor_get(key))
	edit.text_changed.connect(_on_path_typed.bind(key))
	row.add_child(edit)
	row.add_child(_browse(func(): _pick_into(edit, file_mode, "*", key)))
	return edit


func _on_path_typed(value: String, key: String) -> void:
	Settings.editor_set(key, value)
	_refresh_presence()


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
		Settings.editor_set(key, path)
	if target == _bone_map_path:
		_on_bone_map_changed(path)
	_refresh_presence()


# --- weights -----------------------------------------------------------------


func _weights_present() -> bool:
	return FileAccess.file_exists(Settings.motion_gguf_path()) \
			and DirAccess.dir_exists_absolute(Settings.text_bundle_path())


func _refresh_presence() -> void:
	var motion := Settings.motion_gguf_path()
	var bundle := Settings.text_bundle_path()
	var bundle_files := 0
	if DirAccess.dir_exists_absolute(bundle):
		bundle_files = DirAccess.get_files_at(bundle).size()

	var lines := PackedStringArray()
	lines.append(_presence_line("motion GGUF", FileAccess.file_exists(motion)))
	lines.append(_presence_line("text bundle, %d files" % bundle_files, bundle_files > 0))
	_presence.text = "\n".join(lines)
	# The paths are long enough to wrap into a wall of text, so they live here.
	_presence.tooltip_text = "%s\n%s" % [motion, bundle]


func _presence_line(label: String, present: bool) -> String:
	var colour := "#7fd07f" if present else "#e0a050"
	return "[color=%s]%s[/color]  %s" % [colour, "present" if present else "missing", label]


func _on_download() -> void:
	if _downloader.is_busy():
		return
	var destination := _models_dir.text.strip_edges()
	if destination.is_empty():
		_download_status.text = "Set a model directory first."
		return

	var revision := String(Settings.project_get("weights/revision"))
	var repos := [
		{
			"repo": String(Settings.project_get("weights/motion_repo")),
			"revision": revision,
			"include": [Settings.MOTION_RELATIVE],
		},
		{
			"repo": String(Settings.project_get("weights/text_repo")),
			"revision": revision,
			"include": [Settings.TEXT_BUNDLE_RELATIVE + "/*"],
		},
	]

	_download_button.disabled = true
	_cancel_button.disabled = false
	_download_status.text = "Reading the manifests..."
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
	if _generator_path.text.strip_edges().is_empty():
		_set_message(_status, "Set the kmd-generate path under Setup.")
		return
	if not _weights_present():
		_set_message(_status, "The weights are not in place. Download them under Setup.")
		return
	if _prompt.text.strip_edges().is_empty():
		_set_message(_status, "The prompt is empty.")
		return

	var stamp := str(Time.get_unix_time_from_system()).replace(".", "")
	var out_dir: String = String(Settings.project_get("output/root")).path_join("gen_%s" % stamp)
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
		_set_message(_status, "Could not start %s." % _generator_path.text)
		return
	_pending_output = out_dir
	_generate_button.disabled = true
	_set_message(_status, "Generating into %s ..." % out_dir)
	set_process(true)


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
	return OS.create_process(ProjectSettings.globalize_path(_generator_path.text), arguments, false)


func _process(_delta: float) -> void:
	if _pid < 0:
		return
	if OS.is_process_running(_pid):
		return

	set_process(false)
	var exit_code := OS.get_process_exit_code(_pid)
	_pid = -1
	_generate_button.disabled = false

	if exit_code != 0:
		_set_message(_status, "kmd-generate exited with %d. See its console output." % exit_code)
	elif _load_motion(_pending_output):
		_set_message(_status, "Done.")
	else:
		_set_message(_status, "%s produced no readable motion. See the console." % _pending_output)


# --- motion ------------------------------------------------------------------


func _on_load_folder() -> void:
	if is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dialog.size = Vector2i(720, 480)
	_dialog.dir_selected.connect(func(path): _load_motion(path))
	add_child(_dialog)
	_dialog.popup_centered()


func _load_motion(dir: String) -> bool:
	var motion := KimodoMotion.new()
	if motion.load_directory(dir) != OK:
		_motion = null
		_set_message(_motion_label, "Failed to load %s." % dir)
		return false
	_motion = motion
	_set_message(_motion_label, "%d frames, %.2f s at %.0f fps\n%s" % [motion.get_frame_count(),
			motion.get_duration(), motion.get_fps(), dir])
	return true


# --- target ------------------------------------------------------------------


func _on_bone_map_changed(path: String) -> void:
	_bone_map = null
	if not path.strip_edges().is_empty():
		_bone_map = ResourceLoader.load(path, "BoneMap", ResourceLoader.CACHE_MODE_REUSE)
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
		_set_message(_status, "Saved %s." % path)
	else:
		_set_message(_status, "Saving %s failed (%d)." % [path, error])
	EditorInterface.get_resource_filesystem().scan()


func _on_save_library() -> void:
	var animation := _bake()
	if animation == null:
		return
	_save_dialog(String(Settings.project_get("output/library")), _write_library.bind(animation))


func _write_library(path: String, animation: Animation) -> void:
	var error := KimodoLibrary.save_to_library(animation, path, StringName(_clip_name.text))
	if error == OK:
		_set_message(_status, "Added %s to %s." % [_clip_name.text, path])
	else:
		_set_message(_status, "Saving %s failed (%d)." % [path, error])
	EditorInterface.get_resource_filesystem().scan()


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
