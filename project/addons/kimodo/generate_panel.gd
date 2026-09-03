@tool
extends VBoxContainer

## Generate, in the bottom panel: the prompt sequence, what to sample it with,
## and the button that starts a run.
##
## It used to be the top of the dock. A dock is a column two hundred pixels
## wide, and a sequence is a row of stretches with lengths that only mean
## anything next to each other. Every explanation had to become a tooltip, and
## the answer a refusal gave appeared three sections above the button that had
## been pressed. Down here there is width, so the sequence can be drawn as what
## it is and the numbers can sit on one line.
##
## The dock keeps everything a run is not: the weights, the rig, the preview and
## where the result goes. It hears about a finished run through generated().

const Settings := preload("res://addons/kimodo/settings.gd")
const Checkpoint := preload("res://addons/kimodo/checkpoint.gd")
const ClipFile := preload("res://addons/kimodo/clip_file.gd")
const UI := preload("res://addons/kimodo/ui.gd")
const Timeline := preload("res://addons/kimodo/timeline.gd")

## A run finished and left a readable folder behind. The dock loads it.
signal generated(dir: String)

## What kmd-generate accepts in one sequence.
const MAXIMUM_PROMPTS := 16

## What a prompt inside a sequence is limited to. It is also what the model was
## trained on, so it is the point past which a longer prompt stops helping.
const SEQUENCE_LIMIT := 300

## The shortest single prompt worth asking for. kimodo.cpp accepts less; a
## clip under half a second is not a motion.
const SINGLE_MINIMUM := 16

## Untyped on purpose: refresh() and picked belong to timeline.gd, and a
## reference typed as the Control it extends cannot see either.
var _timeline
var _rows: VBoxContainer
var _add_button: Button
var _transition_row: HBoxContainer
var _transition: SpinBox
var _constraint_cfg: SpinBox
var _steps: SpinBox
var _seed: SpinBox
var _text_cfg: SpinBox
var _generate_button: Button
var _status: Label
var _selected := 0

var _pid := -1
var _pending_output := ""


## Not called Kimodo, which is the dock's name. The editor keys a dock by its
## title, and 4.7 files two of one name into the same group: the panel came up
## as a tab in the dock column beside it rather than along the bottom.
func _init() -> void:
	name = "GenerateMotion"
	add_theme_constant_override(&"separation", 6)


func _ready() -> void:
	_timeline = Timeline.new()
	_timeline.picked.connect(_on_timeline_picked)
	add_child(_timeline)

	_rows = VBoxContainer.new()
	add_child(_rows)
	_add_row(int(Settings.get_value("generation/frames")), "")

	var buttons := HBoxContainer.new()
	add_child(buttons)
	_add_button = UI.button(buttons, "+ Add prompt", _on_add_prompt,
			"Continue the clip with another prompt. The model is given the end of the previous stretch as a constraint, so the body carries over rather than restarting.")

	# Everything that describes the sample rather than the clip, on one line
	# because there is a line to spare. Transition and Continuity are on it too
	# but hidden until a second prompt asks the question they answer.
	var numbers := HBoxContainer.new()
	add_child(numbers)
	_steps = UI.spin(numbers, "Steps", 1, 200, int(Settings.get_value("generation/steps")),
			"Denoising passes the sampler makes. More of them converge further and follow the text more closely, at close to linear cost in time.")
	_steps.value_changed.connect(func(value): Settings.set_value("generation/steps", int(value)))
	_seed = UI.spin(numbers, "Seed", 0, 1 << 30, 0,
			"Which sample you get. One prompt, length, step count and seed give the same clip every time.")
	_text_cfg = UI.spin(numbers, "Guidance", 0.0, 15.0,
			float(Settings.get_value("generation/text_cfg")),
			"How hard the sampler is pushed towards the prompt. Upstream samples at 2. Higher takes the words more literally and tends to move less; lower wanders.",
			0.1)
	_text_cfg.value_changed.connect(func(value): Settings.set_value("generation/text_cfg", value))

	_transition_row = HBoxContainer.new()
	numbers.add_child(_transition_row)
	_transition = UI.spin(_transition_row, "Transition", 1, 60,
			int(Settings.get_value("generation/transition")),
			"Frames of overlap the model is given to join one prompt to the next. Absorbed rather than added, and it has to be shorter than every prompt after the first.")
	_transition.value_changed.connect(func(value):
		Settings.set_value("generation/transition", int(value))
		_refresh())
	_constraint_cfg = UI.spin(_transition_row, "Continuity", 0.0, 15.0,
			float(Settings.get_value("generation/constraint_cfg")),
			"How hard each prompt after the first is pulled onto the end of the one before it. Upstream samples at 2. A single prompt has nothing to join onto and ignores it.",
			0.1)
	_constraint_cfg.value_changed.connect(func(value): Settings.set_value("generation/constraint_cfg", value))

	# Packed to the left at a fixed width. The panel is as wide as the editor,
	# and five spin boxes sharing three thousand pixels between them is three
	# thousand pixels of arrows.
	for box in [_steps, _seed, _text_cfg, _transition, _constraint_cfg]:
		box.get_parent().size_flags_horizontal = Control.SIZE_FILL
		box.get_parent().custom_minimum_size.x = 120.0
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	numbers.add_child(spacer)

	_generate_button = UI.button(self, "Generate", _on_generate)
	_status = UI.message(self, 2)
	UI.set_message(_status, "Nothing generated yet.")

	_refresh()
	set_process(true)


# --- the sequence ------------------------------------------------------------


## One prompt: how long it runs, and what it says. The row is the whole of a
## prompt now, including the first, so there is no special case to keep in step.
func _add_row(frames: int, text: String) -> void:
	var row := HBoxContainer.new()
	_rows.add_child(row)

	var length := SpinBox.new()
	length.min_value = 2
	length.max_value = 600
	length.value = frames
	length.tooltip_text = "Frames this prompt runs for, at 30 fps. A single prompt needs at least %d; inside a sequence the limit is %d." % [SINGLE_MINIMUM, SEQUENCE_LIMIT]
	row.add_child(length)

	var prompt := LineEdit.new()
	prompt.placeholder_text = "A person walks forward and waves their arms."
	prompt.text = text
	prompt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(prompt)

	# Connected once the row is whole. Assigning a SpinBox's value emits
	# value_changed, and the first row is built before the rest of the panel
	# exists for a refresh to read.
	length.value_changed.connect(func(_value): _refresh())
	prompt.text_changed.connect(func(_value): _refresh())
	prompt.focus_entered.connect(func(): _on_row_focused(row))

	UI.button(row, "×", _on_drop_row.bind(row), "Remove this prompt.")


func _on_add_prompt() -> void:
	if _rows.get_child_count() >= MAXIMUM_PROMPTS:
		return
	# The length of the prompt above it, capped: a new stretch is usually meant
	# to be about as long as the one it follows, and inside a sequence nothing
	# may run past the limit anyway.
	var previous: PackedInt32Array = _lengths()
	_add_row(mini(previous[previous.size() - 1], SEQUENCE_LIMIT), "")
	_refresh()
	var row := _rows.get_child(_rows.get_child_count() - 1)
	(row.get_child(1) as LineEdit).grab_focus()


## The last prompt cannot go. An empty sequence has nothing for the timeline to
## draw and nothing for Generate to refuse, so the row stays and is emptied by
## hand like any other.
func _on_drop_row(row: Control) -> void:
	if _rows.get_child_count() <= 1:
		return
	_rows.remove_child(row)
	row.queue_free()
	_selected = mini(_selected, _rows.get_child_count() - 1)
	_refresh()


func _on_row_focused(row: Control) -> void:
	_selected = row.get_index()
	_refresh()


func _on_timeline_picked(index: int) -> void:
	if index < 0 or index >= _rows.get_child_count():
		return
	_selected = index
	(_rows.get_child(index).get_child(1) as LineEdit).grab_focus()


func _prompts() -> PackedStringArray:
	var out := PackedStringArray()
	for row in _rows.get_children():
		out.append((row.get_child(1) as LineEdit).text.strip_edges())
	return out


func _lengths() -> PackedInt32Array:
	var out := PackedInt32Array()
	for row in _rows.get_children():
		out.append(int((row.get_child(0) as SpinBox).value))
	return out


## Everything that follows from the rows: what the strip draws, whether the two
## join settings have anything to answer, and how long the clip runs.
func _refresh() -> void:
	var lengths := _lengths()
	var sequence := lengths.size() > 1
	_timeline.refresh(_prompts(), lengths, int(_transition.value) if sequence else 0, _selected)
	_transition_row.visible = sequence
	_add_button.disabled = _rows.get_child_count() >= MAXIMUM_PROMPTS
	# The first row is the length a new panel starts with, so it is the one
	# worth remembering between sessions. Guarded because this runs on every
	# keystroke, and an editor setting is a file on disk.
	if int(Settings.get_value("generation/frames")) != lengths[0]:
		Settings.set_value("generation/frames", lengths[0])


# --- generation --------------------------------------------------------------


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		UI.set_message(_status, "Cannot write %s." % path)
		return false
	file.store_string(text)
	file.close()
	return true


func _on_generate() -> void:
	if _pid >= 0:
		return
	if Settings.generator_path().is_empty():
		UI.set_message(_status, "No kmd-generate in the addon. Build it with scons.")
		return
	if not Settings.weights_present():
		UI.set_message(_status, "The weights are incomplete. Download them under Setup in the Kimodo dock.")
		return

	var prompts := _prompts()
	var lengths := _lengths()
	for index in prompts.size():
		if prompts[index].is_empty():
			UI.set_message(_status, "Prompt %d is empty." % (index + 1))
			return

	var transition := int(_transition.value)
	var total := 0
	for length in lengths:
		total += length
	# Checked here rather than left to an exit code, because the generator's
	# limits on a sequence are tighter than on a single prompt.
	if prompts.size() > 1:
		for index in lengths.size():
			if lengths[index] > SEQUENCE_LIMIT:
				UI.set_message(_status, "Prompt %d asks for %d frames. Inside a sequence the limit is %d." % [
						index + 1, lengths[index], SEQUENCE_LIMIT])
				return
		for index in range(1, lengths.size()):
			if transition >= lengths[index]:
				UI.set_message(_status, "The transition is %d frames and prompt %d is only %d. It has to be shorter than every prompt after the first." % [
						transition, index + 1, lengths[index]])
				return
	elif lengths[0] < SINGLE_MINIMUM:
		UI.set_message(_status, "A single prompt needs at least %d frames." % SINGLE_MINIMUM)
		return

	var stamp := str(Time.get_unix_time_from_system()).replace(".", "")
	var out_dir: String = Settings.output_dir().path_join("gen_%s" % stamp)
	DirAccess.make_dir_recursive_absolute(out_dir)

	# prompt.txt is what the clip list reads for its label, so it carries the
	# whole sequence on one line whatever the shape of the run.
	if not _write_text(out_dir.path_join("prompt.txt"), " -> ".join(prompts)):
		return
	# Written before the generator starts rather than after it finishes, so a
	# run that crashes still leaves behind what was asked of it.
	if not _write_text(out_dir.path_join("recipe.json"),
			JSON.stringify(_recipe(prompts, lengths, transition), "\t")):
		return
	var paths := PackedStringArray()
	for index in prompts.size():
		if prompts.size() == 1:
			paths.append(out_dir.path_join("prompt.txt"))
			break
		var path := out_dir.path_join("prompt_%d.txt" % index)
		if not _write_text(path, prompts[index]):
			return
		paths.append(path)

	_pid = _spawn_generator(_generator_arguments(prompts, lengths, paths, transition, out_dir))
	if _pid < 0:
		UI.set_message(_status, "Could not start %s." % Settings.generator_path())
		return
	_pending_output = out_dir
	_generate_button.disabled = true
	UI.set_message(_status, "Generating %d frames from %d prompt%s into %s ..." % [
			total, prompts.size(), "" if prompts.size() == 1 else "s", out_dir])


## What the run was, in the form a clip carries. Everything here is known before
## the generator starts, so nothing has to be read back out of its output.
##
## The revision is the setting rather than a commit resolved against Hugging
## Face: it is what the download asked for, and asking again at generation time
## would put a network call in front of the GPU.
func _recipe(prompts: PackedStringArray, lengths: PackedInt32Array, transition: int) -> Dictionary:
	var key := Settings.skeleton()
	var recipe := {
		"prompts": Array(prompts),
		"lengths": Array(lengths),
		# A single prompt has nothing to transition to, and recording the spin
		# box anyway would make two clips differ over a number neither used.
		"transition": transition if prompts.size() > 1 else 0,
		"steps": int(_steps.value),
		"seed": int(_seed.value),
		"text_cfg": _text_cfg.value,
		# Recorded whatever the shape of the run: a recipe says what the
		# generator was given, not what it turned out to have a use for.
		"constraint_cfg": _constraint_cfg.value,
		"skeleton": key,
		"motion_repo": Settings.motion_repo(key),
		"text_repo": String(Settings.get_value("weights/text_repo")),
		"revision": String(Settings.get_value("weights/revision")),
	}
	# A converted SMPL-X GGUF was never downloaded, so no repository revision
	# names those bytes. The checkpoint it came from is what does, and
	# checkpoint.gd wrote it down at conversion time for exactly this.
	var pinned := Checkpoint.checkpoint_dir(
			String(Settings.get_value("paths/models_dir"))).path_join("REVISION")
	if key == "smplx22" and FileAccess.file_exists(pinned):
		recipe["checkpoint"] = FileAccess.get_file_as_string(pinned).strip_edges()
	return ClipFile.stamp(recipe)


## The generator reads two shapes off one command line and tells them apart by
## what sits in argv[3]: a prompt file for a single run, the word --sequence for
## several. A sequence adds no frames of its own; the transition is absorbed
## into the prompts either side of it.
func _generator_arguments(prompts: PackedStringArray, lengths: PackedInt32Array,
		paths: PackedStringArray, transition: int, out_dir: String) -> PackedStringArray:
	var arguments := PackedStringArray([
		ProjectSettings.globalize_path(Settings.motion_gguf_path()),
		ProjectSettings.globalize_path(Settings.text_bundle_path()),
	])
	if prompts.size() == 1:
		arguments.append(ProjectSettings.globalize_path(paths[0]))
		arguments.append(str(lengths[0]))
	else:
		arguments.append("--sequence")
		arguments.append(str(transition))
	arguments.append(str(int(_steps.value)))
	arguments.append(str(int(_seed.value)))
	arguments.append(ProjectSettings.globalize_path(out_dir))
	if prompts.size() > 1:
		for index in prompts.size():
			arguments.append(str(lengths[index]))
			arguments.append(ProjectSettings.globalize_path(paths[index]))
	return arguments


## The one place that knows how a motion gets generated.
func _spawn_generator(arguments: PackedStringArray) -> int:
	# OS.create_process() takes no environment, and every knob the child reads is
	# an environment variable, so they go on the editor process to be inherited.
	var environment := Settings.runtime_environment()
	for variable in environment:
		var value: String = environment[variable]
		if value.is_empty():
			OS.unset_environment(variable)
		else:
			OS.set_environment(variable, value)

	return OS.create_process(ProjectSettings.globalize_path(Settings.generator_path()), arguments, false)


## kmd-generate owns the GPU for the length of a run, so only one is allowed at
## a time and the button is the lock.
func _process(_delta: float) -> void:
	if _pid < 0 or OS.is_process_running(_pid):
		return

	var exit_code := OS.get_process_exit_code(_pid)
	_pid = -1
	_generate_button.disabled = false

	if exit_code != 0:
		UI.set_message(_status, "kmd-generate exited with %d. See its console output." % exit_code)
		return
	UI.set_message(_status, "Generated. The Kimodo dock has it under Motion.")
	generated.emit(_pending_output)
