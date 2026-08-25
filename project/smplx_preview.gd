extends Node3D

## Plays a Kimodo motion and reads out what has to be judged by eye: the
## coordinate system, left versus right, the facing axis and ground contact.
##
## Three targets, cycled with T:
##
##   SMPLX_REST  the SMPL-X rest itself, with no retargeting in between. Use
##               this one first: it keeps a problem in the motion separate from
##               a problem in the retargeting.
##   HUMANOID    the same rest under SkeletonProfileHumanoid bone names, driven
##               through the retargeting path. The no-model preview.
##   MODEL       an imported scene, resolved through bone_map.
##
## Point motion_dir at an OUT_DIR produced by kmd-generate:
##
##     kmd-generate MOTION.gguf TEXT_BUNDLE prompt.txt FRAMES STEPS SEED OUT_DIR
##
## It can also be given on the command line as `-- --motion=<dir>`.

enum Target {
	SMPLX_REST,
	HUMANOID,
	MODEL,
}

const GRID_EXTENT := 3.0
const GRID_STEP := 0.25

@export_dir var motion_dir: String = ""
@export var target: Target = Target.SMPLX_REST
## Only used by Target.MODEL. The first Skeleton3D in the scene is driven.
@export var model_scene: PackedScene
## Leave null when the rig already uses SkeletonProfileHumanoid bone names.
@export var bone_map: BoneMap
@export var autoplay: bool = true

var _motion: KimodoMotion
var _target_root: Node
var _skeleton: Skeleton3D
var _player: AnimationPlayer
var _readout: Label

var _camera: Camera3D
var _pivot := Vector3(0.0, 0.95, 0.0)
var _yaw := 0.0
var _pitch := 0.04
var _distance := 2.4
var _orbiting := false

var _mapping := {}
var _lowest_seen := INF
# The skeleton still holds its rest for a frame after a bake, and counting that
# frame would report the pelvis-at-origin height as ground contact.
var _settling := 0


func _ready() -> void:
	_build_stage()
	_player = AnimationPlayer.new()
	_player.name = "AnimationPlayer"
	add_child(_player)
	_load_motion()
	_build_target()


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


func _load_motion() -> void:
	var dir := _resolve_motion_dir()
	if dir.is_empty():
		_readout.text = "No motion directory set.\nSet motion_dir on the scene root, or run with -- --motion=<dir>."
		return

	var motion := KimodoMotion.new()
	if motion.load_directory(dir) != OK:
		_readout.text = "Failed to load a motion from %s.\nSee the console for the reason." % dir
		return
	_motion = motion


func _resolve_motion_dir() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--motion="):
			return argument.trim_prefix("--motion=")
	return motion_dir


func _build_target() -> void:
	if is_instance_valid(_target_root):
		remove_child(_target_root)
		_target_root.free()
	_target_root = null
	_skeleton = null
	_mapping = {}

	match target:
		Target.SMPLX_REST:
			_skeleton = KimodoSmplx.create_rest_skeleton()
			_target_root = _skeleton
			add_child(_target_root)
			KimodoSmplx.build_mannequin(_skeleton, null)
		Target.HUMANOID:
			_skeleton = KimodoSmplx.create_humanoid_skeleton()
			_target_root = _skeleton
			add_child(_target_root)
			KimodoRetarget.build_mannequin(_skeleton, null, null)
		Target.MODEL:
			if model_scene == null:
				_readout.text = "Target.MODEL needs model_scene set on the scene root."
				return
			_target_root = model_scene.instantiate()
			add_child(_target_root)
			_skeleton = _find_skeleton(_target_root)
			if _skeleton == null:
				_readout.text = "No Skeleton3D in %s." % model_scene.resource_path
				return

	if target != Target.SMPLX_REST:
		_mapping = KimodoRetarget.describe_mapping(_skeleton, bone_map)
	_bake()


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _bake() -> void:
	if _motion == null or _skeleton == null:
		return

	var path := get_path_to(_skeleton)
	var animation: Animation
	if target == Target.SMPLX_REST:
		animation = _motion.bake_animation(path)
	else:
		animation = KimodoRetarget.bake_animation(_motion, _skeleton, bone_map, path)
	if animation == null:
		return

	if _player.has_animation_library(&""):
		_player.remove_animation_library(&"")
	var library := AnimationLibrary.new()
	library.add_animation(&"motion", animation)
	_player.add_animation_library(&"", library)

	_lowest_seen = INF
	_settling = 2
	if autoplay:
		_player.play(&"motion")


func _process(_delta: float) -> void:
	if _motion == null or _skeleton == null:
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


## Composed from the bone poses rather than read from get_bone_global_pose(),
## which still reports the rest when the skeleton has not refreshed its cache.
func _global_pose(bone: int) -> Transform3D:
	var transform := _skeleton.get_bone_pose(bone)
	var parent := _skeleton.get_bone_parent(bone)
	while parent >= 0:
		transform = _skeleton.get_bone_pose(parent) * transform
		parent = _skeleton.get_bone_parent(parent)
	return transform


func _describe_frame(frame: int) -> String:
	var bones: PackedInt32Array = _mapping.get("bones", PackedInt32Array())
	var hips := 0 if bones.is_empty() else bones[0]
	var left := 20 if bones.is_empty() else bones[20]
	var right := 21 if bones.is_empty() else bones[21]

	var lowest := INF
	for bone in _skeleton.get_bone_count():
		lowest = minf(lowest, _global_pose(bone).origin.y)
	if _settling > 0:
		_settling -= 1
	else:
		_lowest_seen = minf(_lowest_seen, lowest)

	var lines := PackedStringArray()
	lines.append("%s   frame %d / %d   %.1f fps   %.2f s" % [Target.keys()[target], frame,
			_motion.get_frame_count() - 1, _motion.get_fps(), _motion.get_duration()])
	if hips >= 0:
		lines.append("hips            %s" % _format(_global_pose(hips).origin))
		lines.append("hips facing     %s" % _format(_global_pose(hips).basis * Vector3(0.0, 0.0, 1.0)))
	if left >= 0:
		lines.append("left hand  (warm)   %s" % _format(_global_pose(left).origin))
	if right >= 0:
		lines.append("right hand (cold)   %s" % _format(_global_pose(right).origin))
	lines.append("lowest bone     y %+0.3f   (lowest seen %+0.3f)" % [lowest, _lowest_seen])

	if not _mapping.is_empty():
		lines.append("retarget scale  %.3f   (%.3f m -> %.3f m)"
				% [_mapping["scale"], _mapping["source_height"], _mapping["target_height"]])
		var missing: PackedStringArray = _mapping["missing"]
		lines.append("unmapped        %s" % ("none" if missing.is_empty() else ", ".join(missing)))

	lines.append("")
	lines.append("space play/pause   left/right step   T target   drag orbit   wheel zoom")
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
			KEY_T:
				_cycle_target()


func _cycle_target() -> void:
	var next: int = (target + 1) % Target.size()
	if next == Target.MODEL and model_scene == null:
		next = Target.SMPLX_REST
	target = next as Target
	_build_target()


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
