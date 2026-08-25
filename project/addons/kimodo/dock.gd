@tool
extends VBoxContainer

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

const SETTING_PREFIX := "kimodo/"
const DEFAULTS := {
	"generator_path": "",
	"motion_gguf": "",
	"text_bundle": "",
	"output_root": "user://kimodo_out",
}

var _fields := {}
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
var _motion_dir := ""
var _bone_map: BoneMap
var _pid := -1
var _pending_output := ""
var _dialog: FileDialog


func _init() -> void:
	name = "Kimodo"


func _ready() -> void:
	_build_ui()
	set_process(false)


func _build_ui() -> void:
	add_theme_constant_override(&"separation", 6)

	_section("Generator")
	for key in ["generator_path", "motion_gguf", "text_bundle"]:
		_fields[key] = _path_row(key.capitalize(), key, key != "text_bundle")
	_fields["output_root"] = _path_row("Output root", "output_root", false)

	_prompt = TextEdit.new()
	_prompt.placeholder_text = "a person walks forward and waves with the left hand"
	_prompt.custom_minimum_size = Vector2(0.0, 64.0)
	_prompt.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	add_child(_prompt)

	var numbers := HBoxContainer.new()
	add_child(numbers)
	_frames = _spin(numbers, "Frames", 16, 600, 120)
	_steps = _spin(numbers, "Steps", 1, 200, 30)
	_seed = _spin(numbers, "Seed", 0, 1 << 30, 0)

	_generate_button = Button.new()
	_generate_button.text = "Generate"
	_generate_button.pressed.connect(_on_generate)
	add_child(_generate_button)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	_section("Motion")
	var load_button := Button.new()
	load_button.text = "Load an existing output folder..."
	load_button.pressed.connect(_on_load_folder)
	add_child(load_button)
	_motion_label = Label.new()
	_motion_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_motion_label.text = "No motion loaded."
	add_child(_motion_label)

	_section("Target")
	var bone_map_row := HBoxContainer.new()
	add_child(bone_map_row)
	_bone_map_path = LineEdit.new()
	_bone_map_path.placeholder_text = "BoneMap resource (leave empty for profile names)"
	_bone_map_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bone_map_path.text_changed.connect(_on_bone_map_changed)
	bone_map_row.add_child(_bone_map_path)
	var pick_map := Button.new()
	pick_map.text = "..."
	pick_map.pressed.connect(func(): _pick(_bone_map_path, true, "*.tres,*.res"))
	bone_map_row.add_child(pick_map)

	var refresh := Button.new()
	refresh.text = "Use the selected Skeleton3D"
	refresh.pressed.connect(_refresh_target)
	add_child(refresh)

	_target_label = RichTextLabel.new()
	_target_label.fit_content = true
	_target_label.custom_minimum_size = Vector2(0.0, 60.0)
	add_child(_target_label)

	var apply := Button.new()
	apply.text = "Bake onto the target"
	apply.pressed.connect(_on_apply)
	add_child(apply)

	_section("Save")
	_clip_name = LineEdit.new()
	_clip_name.text = "kimodo_motion"
	add_child(_clip_name)
	var save_clip := Button.new()
	save_clip.text = "Save the clip as a resource..."
	save_clip.pressed.connect(_on_save_clip)
	add_child(save_clip)
	var save_library := Button.new()
	save_library.text = "Add to an AnimationLibrary..."
	save_library.pressed.connect(_on_save_library)
	add_child(save_library)

	_refresh_target()


func _section(title: String) -> void:
	var separator := HSeparator.new()
	add_child(separator)
	var label := Label.new()
	label.text = title
	label.add_theme_color_override(&"font_color", Color(0.6, 0.75, 1.0))
	add_child(label)


func _path_row(label_text: String, key: String, file_mode: bool) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	add_child(label)

	var row := HBoxContainer.new()
	add_child(row)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text = _setting(key)
	edit.text_submitted.connect(func(value): _store(key, value))
	edit.focus_exited.connect(func(): _store(key, edit.text))
	row.add_child(edit)

	var browse := Button.new()
	browse.text = "..."
	browse.pressed.connect(func(): _pick(edit, file_mode, "*", key))
	row.add_child(browse)
	return edit


func _spin(parent: Control, label_text: String, low: int, high: int, value: int) -> SpinBox:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(box)
	var label := Label.new()
	label.text = label_text
	box.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.value = value
	box.add_child(spin)
	return spin


## Typed access, so the callers keep their String inference.
func _field(key: String) -> LineEdit:
	return _fields[key]


func _setting(key: String) -> String:
	var settings := EditorInterface.get_editor_settings()
	var full := SETTING_PREFIX + key
	if not settings.has_setting(full):
		return DEFAULTS[key]
	return str(settings.get_setting(full))


func _store(key: String, value: String) -> void:
	EditorInterface.get_editor_settings().set_setting(SETTING_PREFIX + key, value)


func _pick(target: LineEdit, file_mode: bool, filter: String = "*", key: String = "") -> void:
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
		_store(key, path)
	if target == _bone_map_path:
		_on_bone_map_changed(path)


# --- generation --------------------------------------------------------------


func _on_generate() -> void:
	if _pid >= 0:
		return
	var missing := PackedStringArray()
	for key in ["generator_path", "motion_gguf", "text_bundle"]:
		if _field(key).text.strip_edges().is_empty():
			missing.append(key)
	if not missing.is_empty():
		_status.text = "Set %s first." % ", ".join(missing)
		return
	if _prompt.text.strip_edges().is_empty():
		_status.text = "The prompt is empty."
		return

	var stamp := str(Time.get_unix_time_from_system()).replace(".", "")
	var out_dir := _field("output_root").text.path_join("gen_%s" % stamp)
	DirAccess.make_dir_recursive_absolute(out_dir)

	var prompt_path := out_dir.path_join("prompt.txt")
	var file := FileAccess.open(prompt_path, FileAccess.WRITE)
	if file == null:
		_status.text = "Cannot write %s." % prompt_path
		return
	file.store_string(_prompt.text.strip_edges())
	file.close()

	_pid = _spawn_generator(prompt_path, out_dir)
	if _pid < 0:
		_status.text = "Could not start %s." % _field("generator_path").text
		return
	_pending_output = out_dir
	_generate_button.disabled = true
	_status.text = "Generating into %s ..." % out_dir
	set_process(true)


## The one place that knows how a motion gets generated.
func _spawn_generator(prompt_path: String, out_dir: String) -> int:
	var arguments := [
		ProjectSettings.globalize_path(_field("motion_gguf").text),
		ProjectSettings.globalize_path(_field("text_bundle").text),
		ProjectSettings.globalize_path(prompt_path),
		str(int(_frames.value)),
		str(int(_steps.value)),
		str(int(_seed.value)),
		ProjectSettings.globalize_path(out_dir),
	]
	return OS.create_process(ProjectSettings.globalize_path(_field("generator_path").text), arguments, false)


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
		_status.text = "kmd-generate exited with %d. See its console output." % exit_code
	elif _load_motion(_pending_output):
		_status.text = "Done."
	else:
		_status.text = "%s produced no readable motion. See the console." % _pending_output


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
		_motion_label.text = "Failed to load %s." % dir
		return false
	_motion = motion
	_motion_dir = dir
	_motion_label.text = "%s\n%d frames, %.2f s at %.0f fps" % [dir, motion.get_frame_count(),
			motion.get_duration(), motion.get_fps()]
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
		_target_label.text = "[i]No Skeleton3D in the open scene. Select one, or open a scene that has one.[/i]"
		return

	var report := KimodoRetarget.describe_mapping(skeleton, _bone_map)
	var missing: PackedStringArray = report["missing"]
	var lines := PackedStringArray()
	lines.append("[b]%s[/b] (%d bones)" % [skeleton.name, skeleton.get_bone_count()])
	lines.append("mapped %d / 22, scale %.3f (%.3f m -> %.3f m)"
			% [report["mapped"].size(), report["scale"], report["source_height"], report["target_height"]])
	if missing.is_empty():
		lines.append("[color=#7fd07f]every joint resolved[/color]")
	else:
		lines.append("[color=#e0a050]unmapped: %s[/color]" % ", ".join(missing))
	_target_label.text = "\n".join(lines)


func _bake() -> Animation:
	if _motion == null:
		_status.text = "Load or generate a motion first."
		return null
	var skeleton := _target_skeleton()
	if skeleton == null:
		_status.text = "No Skeleton3D to bake onto."
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
		_status.text = "Open a scene to bake into."
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
	_status.text = "Baked into %s as kimodo/%s." % [player.name, _clip_name.text]
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
	_save_dialog("res://%s.tres" % _clip_name.text, func(path):
		var error := KimodoLibrary.save_animation(animation, path)
		_status.text = "Saved %s." % path if error == OK else "Save failed (%d)." % error
		EditorInterface.get_resource_filesystem().scan())


func _on_save_library() -> void:
	var animation := _bake()
	if animation == null:
		return
	_save_dialog("res://kimodo_clips.tres", func(path):
		var error := KimodoLibrary.save_to_library(animation, path, StringName(_clip_name.text))
		_status.text = "Added %s to %s." % [_clip_name.text, path] if error == OK \
				else "Save failed (%d)." % error
		EditorInterface.get_resource_filesystem().scan())


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
