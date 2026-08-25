extends Node3D

## Stage 1 of the Godot integration: play a Kimodo motion on the SMPL-X rest
## skeleton with no retargeting in between, so that coordinate system, left and
## right, and ground contact can be checked before a second unknown is added.
##
## Point motion_dir at an OUT_DIR produced by kmd-generate:
##
##     kmd-generate MOTION.gguf TEXT_BUNDLE prompt.txt FRAMES STEPS SEED OUT_DIR
##
## It can also be given on the command line as `-- --motion=<dir>`.

const GRID_EXTENT := 3.0
const GRID_STEP := 0.25

@export_dir var motion_dir: String = ""
@export var autoplay: bool = true

var _motion: KimodoMotion
var _skeleton: Skeleton3D
var _player: AnimationPlayer
var _readout: Label

var _camera: Camera3D
var _pivot := Vector3(0.0, 0.95, 0.0)
var _yaw := 0.0
var _pitch := 0.04
var _distance := 2.4
var _orbiting := false

var _lowest_joint_y := INF


func _ready() -> void:
	_build_stage()
	_build_skeleton()
	_load_motion()


func _build_stage() -> void:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation_degrees = Vector3(-45.0, -35.0, 0.0)
	light.light_energy = 1.1
	add_child(light)

	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation_degrees = Vector3(-20.0, 150.0, 0.0)
	fill.light_energy = 0.35
	add_child(fill)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.10, 0.10, 0.12)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.35, 0.36, 0.42)
	environment.ambient_light_energy = 0.6
	var world := WorldEnvironment.new()
	world.name = "World"
	world.environment = environment
	add_child(world)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	add_child(_camera)
	_update_camera()

	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = _make_grid_mesh()
	add_child(ground)

	var layer := CanvasLayer.new()
	layer.name = "Hud"
	add_child(layer)
	_readout = Label.new()
	_readout.name = "Readout"
	_readout.position = Vector2(12.0, 10.0)
	_readout.add_theme_color_override(&"font_color", Color(0.92, 0.92, 0.95))
	_readout.add_theme_color_override(&"font_outline_color", Color(0.0, 0.0, 0.0))
	_readout.add_theme_constant_override(&"outline_size", 4)
	layer.add_child(_readout)


## The +Z half of the Z axis is drawn in the same yellow as the mannequin nose.
## If the nose tracks that line, +Z forward is confirmed.
func _make_grid_mesh() -> ImmediateMesh:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true

	var minor := Color(0.26, 0.26, 0.30)
	var axis := Color(0.62, 0.62, 0.68)
	var forward := Color(0.95, 0.80, 0.25)

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var offset := -GRID_EXTENT
	while offset <= GRID_EXTENT + 0.001:
		var on_axis := is_zero_approx(offset)
		_add_line(mesh, Vector3(-GRID_EXTENT, 0.0, offset), Vector3(GRID_EXTENT, 0.0, offset),
				axis if on_axis else minor)
		if on_axis:
			_add_line(mesh, Vector3(offset, 0.0, -GRID_EXTENT), Vector3(offset, 0.0, 0.0), axis)
			_add_line(mesh, Vector3(offset, 0.0, 0.0), Vector3(offset, 0.0, GRID_EXTENT), forward)
		else:
			_add_line(mesh, Vector3(offset, 0.0, -GRID_EXTENT), Vector3(offset, 0.0, GRID_EXTENT), minor)
		offset += GRID_STEP
	mesh.surface_end()
	return mesh


func _add_line(mesh: ImmediateMesh, from: Vector3, to: Vector3, color: Color) -> void:
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(from)
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(to)


func _build_skeleton() -> void:
	_skeleton = KimodoSmplx.create_rest_skeleton()
	add_child(_skeleton)
	KimodoSmplx.build_mannequin(_skeleton, null)

	_player = AnimationPlayer.new()
	_player.name = "AnimationPlayer"
	add_child(_player)


func _load_motion() -> void:
	var dir := _resolve_motion_dir()
	if dir.is_empty():
		_readout.text = "No motion directory set.\nSet motion_dir on the scene root, or run with -- --motion=<dir>."
		return

	_motion = KimodoMotion.new()
	if _motion.load_directory(dir) != OK:
		_motion = null
		_readout.text = "Failed to load a motion from %s.\nSee the console for the reason." % dir
		return

	var animation := _motion.bake_animation(NodePath(_skeleton.name))
	var library := AnimationLibrary.new()
	library.add_animation(&"motion", animation)
	_player.add_animation_library(&"", library)

	_lowest_joint_y = INF
	for frame in _motion.get_frame_count():
		for position in _motion.get_global_positions(frame):
			_lowest_joint_y = minf(_lowest_joint_y, position.y)

	if autoplay:
		_player.play(&"motion")


func _resolve_motion_dir() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--motion="):
			return argument.trim_prefix("--motion=")
	return motion_dir


func _process(_delta: float) -> void:
	if _motion == null:
		return
	var frame := _current_frame()
	# Follow the root, or the subject walks out of frame within a few seconds.
	_pivot = _motion.get_root_position(frame) * Vector3(1.0, 0.0, 1.0) + Vector3(0.0, 0.95, 0.0)
	_update_camera()
	_readout.text = _describe_frame(frame)


func _current_frame() -> int:
	if _player.current_animation.is_empty():
		return 0
	return clampi(roundi(_player.current_animation_position * _motion.get_fps()), 0,
			_motion.get_frame_count() - 1)


## Everything stage 1 has to confirm, read off one frame: where the root is,
## which side each wrist ends up on, where the pelvis faces, and how close the
## lowest joint sits to the ground plane.
func _describe_frame(frame: int) -> String:
	var joints := _motion.get_global_positions(frame)
	var facing := _motion.get_global_rotation(frame, 0) * Vector3(0.0, 0.0, 1.0)
	var lowest := INF
	for position in joints:
		lowest = minf(lowest, position.y)

	var lines := PackedStringArray()
	lines.append("frame %d / %d   %.1f fps   %.2f s" % [frame, _motion.get_frame_count() - 1,
			_motion.get_fps(), _motion.get_duration()])
	lines.append("root            %s" % _format(_motion.get_root_position(frame)))
	lines.append("left wrist  (warm)  %s" % _format(joints[20]))
	lines.append("right wrist (cold)  %s" % _format(joints[21]))
	lines.append("pelvis facing   %s" % _format(facing))
	lines.append("lowest joint    y %+0.3f   (clip minimum %+0.3f)" % [lowest, _lowest_joint_y])
	lines.append("")
	lines.append("space play/pause   left/right step   drag orbit   wheel zoom")
	return "\n".join(lines)


func _format(value: Vector3) -> String:
	return "x %+0.3f  y %+0.3f  z %+0.3f" % [value.x, value.y, value.z]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_orbiting = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				_distance = maxf(0.6, _distance - 0.2)
				_update_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				_distance = minf(12.0, _distance + 0.2)
				_update_camera()
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= event.relative.x * 0.006
		_pitch = clampf(_pitch - event.relative.y * 0.006, -1.4, 1.4)
		_update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				_toggle_play()
			KEY_LEFT:
				_step(-1)
			KEY_RIGHT:
				_step(1)


func _update_camera() -> void:
	var direction := Vector3(
			cos(_pitch) * sin(_yaw),
			sin(_pitch),
			cos(_pitch) * cos(_yaw))
	_camera.position = _pivot + direction * _distance
	_camera.look_at(_pivot, Vector3.UP)


func _toggle_play() -> void:
	if _player.current_animation.is_empty():
		_player.play(&"motion")
	else:
		_player.pause() if _player.is_playing() else _player.play()


func _step(frames: int) -> void:
	if _motion == null or _player.current_animation.is_empty():
		return
	_player.pause()
	var frame := clampi(_current_frame() + frames, 0, _motion.get_frame_count() - 1)
	_player.seek(frame / _motion.get_fps(), true)
