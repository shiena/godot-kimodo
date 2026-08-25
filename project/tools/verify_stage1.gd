extends SceneTree

## Headless smoke test for stage 1 of the Godot integration.
##
##     godot --headless --path project -s res://tools/verify_stage1.gd
##
## It checks the wiring only: file layout, quaternion component order, forward
## kinematics, and that a baked Animation drives the bones it names. It runs
## against the synthetic fixture from scripts/make_sample_motion.py, so it can
## confirm nothing about the real model's conventions.

const MOTION_DIR := "res://motion_sample"
const PEAK_FRAME := 45  # the sample holds the left arm up here

var _failures := 0


func _initialize() -> void:
	_check_tables()
	_check_rest_skeleton()
	var motion := _check_motion_load()
	if motion != null:
		_check_forward_kinematics(motion)
		_check_baked_animation(motion)
	_check_mannequin()

	if _failures == 0:
		print("stage 1: all checks passed")
	else:
		printerr("stage 1: %d check(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)


func _check_tables() -> void:
	_expect(KimodoSmplx.get_joint_count() == 22, "joint count is 22")
	_expect(KimodoSmplx.get_parents() == PackedInt32Array(
			[-1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 9, 12, 13, 14, 16, 17, 18, 19]),
			"parent array matches motion_decode.cpp")
	_expect(KimodoSmplx.get_joint_names().size() == 22, "22 joint names")
	_expect(KimodoSmplx.get_humanoid_bone_names()[0] == "Hips", "joint 0 maps to Hips")
	_expect(KimodoSmplx.get_humanoid_bone_names()[20] == "LeftHand", "joint 20 maps to LeftHand")

	var rest := KimodoSmplx.get_rest_positions()
	_expect(rest[0] == Vector3.ZERO, "pelvis sits at the rest origin")
	_expect(rest[16].x > 0.0 and rest[17].x < 0.0, "+X is the character's left")
	_expect(rest[15].y > rest[10].y, "head is above the toes")
	# Head joint to right toe joint. It excludes the skull cap and the sole, so
	# it reads shorter than the body height it stands in for.
	_expect(absf(KimodoSmplx.get_rest_height() - 1.678) < 0.002,
			"rest joint extent is 1.678 m (got %.3f)" % KimodoSmplx.get_rest_height())


func _check_rest_skeleton() -> void:
	var skeleton := KimodoSmplx.create_rest_skeleton()
	_expect(skeleton.get_bone_count() == 22, "rest skeleton has 22 bones")
	_expect(skeleton.get_bone_name(0) == "pelvis", "bone 0 is the pelvis")
	_expect(skeleton.get_bone_parent(20) == 18, "left wrist hangs off the left elbow")
	_expect(skeleton.get_bone_rest(0).origin == Vector3.ZERO, "pelvis rest is at the origin")
	_expect(skeleton.get_bone_rest(4).basis.is_equal_approx(Basis()),
			"rest rotations are identity, so the rest is translation only")
	skeleton.free()


func _check_motion_load() -> KimodoMotion:
	var motion := KimodoMotion.new()
	if motion.load_directory(MOTION_DIR) != OK:
		_expect(false, "loaded the sample motion from %s" % MOTION_DIR)
		return null
	_expect(motion.get_frame_count() == 120, "sample has 120 frames")
	_expect(is_equal_approx(motion.get_fps(), 30.0), "fps defaults to 30")
	_expect(absf(motion.get_duration() - 119.0 / 30.0) < 1e-5, "duration spans the last key")
	_expect(motion.get_local_rotation(0, 0).is_equal_approx(Quaternion()),
			"frame 0 pelvis rotation is identity")
	return motion


func _check_forward_kinematics(motion: KimodoMotion) -> void:
	var rest_frame := motion.get_global_positions(0)
	_expect(absf(rest_frame[20].x + rest_frame[21].x) < 0.05,
			"at rest the wrists mirror across x")
	var lowest := INF
	for position in rest_frame:
		lowest = minf(lowest, position.y)
	_expect(absf(lowest) < 0.001,
			"the sample stands with its lowest joint on y = 0 (got %.4f)" % lowest)

	var peak := motion.get_global_positions(PEAK_FRAME)
	_expect(peak[20].y - peak[21].y > 0.5,
			"the LEFT wrist is raised, the right is not (dy %.3f)" % (peak[20].y - peak[21].y))
	_expect(peak[20].y > peak[15].y,
			"the raised left wrist clears the head")
	_expect(peak[21].is_equal_approx(rest_frame[21] + Vector3(0.0, peak[0].y - rest_frame[0].y,
			peak[0].z - rest_frame[0].z)),
			"the right arm only follows the root, it is not animated")

	var forward: Vector3 = motion.get_global_rotation(PEAK_FRAME, 0) * Vector3(0.0, 0.0, 1.0)
	_expect(forward.is_equal_approx(Vector3(0.0, 0.0, 1.0)), "the sample keeps facing +Z")
	_expect(motion.get_root_position(119).z > motion.get_root_position(0).z,
			"the root travels along +Z")


func _check_baked_animation(motion: KimodoMotion) -> void:
	var stage := Node3D.new()
	get_root().add_child(stage)

	var skeleton := KimodoSmplx.create_rest_skeleton()
	stage.add_child(skeleton)

	var player := AnimationPlayer.new()
	stage.add_child(player)

	var animation := motion.bake_animation(NodePath(skeleton.name))
	_expect(animation.get_track_count() == 23, "22 rotation tracks plus one pelvis position track")
	_expect(animation.track_get_type(0) == Animation.TYPE_ROTATION_3D, "track 0 is a rotation track")
	_expect(animation.track_get_path(0) == NodePath("SmplxSkeleton:pelvis"),
			"track 0 addresses the pelvis bone (got %s)" % animation.track_get_path(0))
	_expect(animation.track_get_type(22) == Animation.TYPE_POSITION_3D,
			"the last track is the pelvis position")
	_expect(animation.track_get_key_count(0) == 120, "every frame becomes a key")

	var library := AnimationLibrary.new()
	library.add_animation(&"motion", animation)
	player.add_animation_library(&"", library)
	player.play(&"motion")
	player.seek(PEAK_FRAME / motion.get_fps(), true)

	var shoulder := skeleton.find_bone("left_shoulder")
	_expect(skeleton.get_bone_pose_rotation(shoulder).is_equal_approx(
			motion.get_local_rotation(PEAK_FRAME, 16)),
			"the animation drives the bone the track names")
	_expect(skeleton.get_bone_pose_position(0).is_equal_approx(motion.get_root_position(PEAK_FRAME)),
			"the pelvis position track carries the root translation")
	_expect(skeleton.get_bone_pose_position(20).is_equal_approx(skeleton.get_bone_rest(20).origin),
			"no other bone gets a position track, so bone lengths stay the rig's")

	stage.free()


func _check_mannequin() -> void:
	var skeleton := KimodoSmplx.create_rest_skeleton()
	KimodoSmplx.build_mannequin(skeleton, null)
	var attachments := skeleton.get_children().filter(func(node): return node is BoneAttachment3D)
	_expect(attachments.size() == 22, "one attachment per bone (got %d)" % attachments.size())

	var meshes := 0
	for attachment in attachments:
		meshes += attachment.get_children().filter(func(node): return node is MeshInstance3D).size()
	# 21 limb capsules, 5 leaf spheres and the nose marker.
	_expect(meshes == 27, "mannequin has 27 mesh parts (got %d)" % meshes)

	KimodoSmplx.clear_mannequin(skeleton)
	_expect(skeleton.get_child_count() == 0, "clear_mannequin removes what it built")
	skeleton.free()


func _expect(condition: bool, description: String) -> void:
	if condition:
		print("  ok   ", description)
	else:
		_failures += 1
		printerr("  FAIL ", description)
