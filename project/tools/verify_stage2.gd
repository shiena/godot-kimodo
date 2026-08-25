extends SceneTree

## Headless check for stage 2, retargeting onto an arbitrary humanoid rig.
##
##     godot --headless --path project -s res://tools/verify_stage2.gd
##
## Two targets are exercised. The humanoid-named skeleton is the no-model
## preview, where every bone the mapping needs is present and named after the
## profile. The synthetic rig is the awkward case: prefixed bone names behind a
## BoneMap, rest rotations that are not identity, and an unmapped twist bone
## sitting between two mapped ones.

const MOTION_DIR := "res://motion_sample"
const PEAK_FRAME := 45

var _failures := 0


func _initialize() -> void:
	var motion := KimodoMotion.new()
	if motion.load_directory(MOTION_DIR) != OK:
		printerr("stage 2: no sample motion in %s; run scripts/make_sample_motion.py first" % MOTION_DIR)
		quit(1)
		return

	_check_humanoid_skeleton()
	_check_humanoid_mapping()
	_check_rest_is_recovered(motion)
	_check_sides_survive(motion)
	_check_custom_rig(motion)

	if _failures == 0:
		print("stage 2: all checks passed")
	else:
		printerr("stage 2: %d check(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)


func _check_humanoid_skeleton() -> void:
	var profile := SkeletonProfileHumanoid.new()
	var unknown := PackedStringArray()
	for profile_bone in KimodoSmplx.get_humanoid_bone_names():
		if profile.find_bone(profile_bone) < 0:
			unknown.append(profile_bone)
	_expect(unknown.is_empty(), "every mapped name is a real profile bone (%s)" % [unknown])

	var skeleton := KimodoSmplx.create_humanoid_skeleton()
	_expect(skeleton.get_bone_count() == 22, "the humanoid skeleton carries the 22 drivable bones")
	_expect(skeleton.get_bone_name(0) == "Hips", "bone 0 is Hips")
	_expect(skeleton.get_bone_parent(skeleton.find_bone("LeftLowerArm")) == skeleton.find_bone("LeftUpperArm"),
			"the arm chain is wired up")
	_expect(skeleton.get_bone_rest(skeleton.find_bone("Hips")).basis.is_equal_approx(Basis()),
			"the rest is rotation free, like the SMPL-X rest it comes from")
	# What SkeletonProfile.get_reference_pose() would have given instead.
	_expect(profile.get_reference_pose(profile.find_bone("LeftLowerArm")).origin.normalized()
			.is_equal_approx(Vector3.UP),
			"the profile reference pose points limbs up +Y, which is why it is not used as a rest")
	skeleton.free()


func _check_humanoid_mapping() -> void:
	var skeleton := KimodoSmplx.create_humanoid_skeleton()
	var report := KimodoRetarget.describe_mapping(skeleton, null)
	_expect(report["missing"].is_empty(),
			"all 22 joints resolve by profile name (missing %s)" % [report["missing"]])
	_expect(report["mapped"].size() == 22, "22 joints mapped")
	_expect(absf(report["scale"] - 1.0) < 0.001,
			"the default target is SMPL-X sized, so the scale is 1 (%.3f)" % report["scale"])
	_expect(absf(report["source_height"] - KimodoSmplx.get_rest_height()) < 0.001,
			"with every joint mapped the source height is the full SMPL-X extent")
	skeleton.free()


## The correction collapses to the target's own rest when the motion contributes
## nothing. Frame 0 of the sample is all identity, so the rig must sit exactly
## at rest -- this is the single check that catches a transposed quaternion.
func _check_rest_is_recovered(motion: KimodoMotion) -> void:
	var stage := Node3D.new()
	get_root().add_child(stage)
	var skeleton := KimodoSmplx.create_humanoid_skeleton()
	stage.add_child(skeleton)

	_play(stage, skeleton, KimodoRetarget.bake_animation(motion, skeleton, null, NodePath(skeleton.name)), 0)

	var worst := 0.0
	var worst_bone := ""
	for bone in skeleton.get_bone_count():
		var drift: float = _global_pose(skeleton, bone).basis.get_rotation_quaternion().angle_to(
				skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion())
		if drift > worst:
			worst = drift
			worst_bone = skeleton.get_bone_name(bone)
	_expect(worst < 0.001, "an identity frame leaves the rig at rest (worst %s, %.4f rad)" % [worst_bone, worst])

	var hips := skeleton.find_bone("Hips")
	var scale: float = KimodoRetarget.get_scale(skeleton, null)
	_expect(skeleton.get_bone_pose_position(hips).is_equal_approx(motion.get_root_position(0) * scale),
			"the pelvis carries the root translation, scaled to the target")
	stage.free()


func _check_sides_survive(motion: KimodoMotion) -> void:
	var stage := Node3D.new()
	get_root().add_child(stage)
	var skeleton := KimodoSmplx.create_humanoid_skeleton()
	stage.add_child(skeleton)

	_play(stage, skeleton, KimodoRetarget.bake_animation(motion, skeleton, null, NodePath(skeleton.name)),
			PEAK_FRAME)

	var left := _global_pose(skeleton, skeleton.find_bone("LeftHand")).origin
	var right := _global_pose(skeleton, skeleton.find_bone("RightHand")).origin
	_expect(left.y - right.y > 0.2,
			"the raised arm stays on the left after retargeting (dy %.3f)" % (left.y - right.y))
	_expect(left.x > 0.0, "the left hand is still on +X")
	stage.free()


## An unmapped bone between two mapped ones has to stay at its own rest while
## the mapped bone below it still lands on D[j] * G[j]. Working in global pose
## rotations and converting to local at the end is what makes that hold.
func _check_custom_rig(motion: KimodoMotion) -> void:
	var stage := Node3D.new()
	get_root().add_child(stage)
	var skeleton := _build_custom_rig()
	stage.add_child(skeleton)

	var bone_map := _build_custom_bone_map()
	var report := KimodoRetarget.describe_mapping(skeleton, bone_map)
	_expect(report["missing"] == PackedStringArray(["LeftToes", "RightToes"]),
			"only the bones the rig lacks go missing (%s)" % [report["missing"]])

	var twist := skeleton.find_bone("rig_LeftArmTwist")
	_expect(KimodoRetarget.resolve_bones(skeleton, bone_map).find(twist) == -1,
			"the twist bone is not a retarget target")

	var animation := KimodoRetarget.bake_animation(motion, skeleton, bone_map, NodePath(skeleton.name))
	_expect(animation.get_track_count() == 21,
			"20 mapped rotations plus the pelvis position (got %d)" % animation.get_track_count())
	for track in animation.get_track_count():
		_expect_quiet(animation.track_get_path(track) != NodePath("%s:rig_LeftArmTwist" % skeleton.name),
				"no track addresses the twist bone")

	_play(stage, skeleton, animation, PEAK_FRAME)

	var twist_drift: float = skeleton.get_bone_pose_rotation(twist).angle_to(
			skeleton.get_bone_rest(twist).basis.get_rotation_quaternion())
	_expect(twist_drift < 0.001, "the twist bone holds its rest (%.4f rad)" % twist_drift)

	var bones := KimodoRetarget.resolve_bones(skeleton, bone_map)
	var worst := 0.0
	var worst_joint := ""
	for joint in KimodoSmplx.get_joint_count():
		if bones[joint] < 0:
			continue
		var expected: Quaternion = motion.get_global_rotation(PEAK_FRAME, joint) \
				* skeleton.get_bone_global_rest(bones[joint]).basis.get_rotation_quaternion()
		var actual: Quaternion = _global_pose(skeleton, bones[joint]).basis.get_rotation_quaternion()
		var drift: float = actual.angle_to(expected)
		if drift > worst:
			worst = drift
			worst_joint = KimodoSmplx.get_joint_names()[joint]
	_expect(worst < 0.001,
			"every mapped bone lands on D[j] * G[j], twist bone included (worst %s, %.4f rad)"
			% [worst_joint, worst])
	stage.free()


## A rig that is deliberately awkward: prefixed names so a BoneMap is needed,
## limb bones whose rest points down their own +Y rather than along the world
## axes, an unmapped twist bone, and no toes.
func _build_custom_rig() -> Skeleton3D:
	var down := Basis(Vector3(0.0, 0.0, 1.0), PI)
	var out_left := Basis(Vector3(0.0, 0.0, 1.0), -PI / 2.0)
	var out_right := Basis(Vector3(0.0, 0.0, 1.0), PI / 2.0)
	var forward := Basis(Vector3(1.0, 0.0, 0.0), PI / 2.0)

	var bones := [
		["rig_Root", "", Vector3.ZERO, Basis()],
		["rig_Hips", "rig_Root", Vector3(0.0, 1.10, 0.0), Basis()],
		["rig_Spine", "rig_Hips", Vector3(0.0, 0.14, 0.0), Basis()],
		["rig_Chest", "rig_Spine", Vector3(0.0, 0.16, 0.0), Basis()],
		["rig_UpperChest", "rig_Chest", Vector3(0.0, 0.10, 0.0), Basis()],
		["rig_Neck", "rig_UpperChest", Vector3(0.0, 0.18, 0.0), Basis()],
		["rig_Head", "rig_Neck", Vector3(0.0, 0.10, 0.0), Basis()],
		["rig_LeftShoulder", "rig_UpperChest", Vector3(0.05, 0.12, 0.0), out_left],
		["rig_LeftUpperArm", "rig_LeftShoulder", Vector3(0.0, 0.12, 0.0), Basis()],
		["rig_LeftArmTwist", "rig_LeftUpperArm", Vector3(0.0, 0.15, 0.0), Basis()],
		["rig_LeftLowerArm", "rig_LeftArmTwist", Vector3(0.0, 0.15, 0.0), Basis()],
		["rig_LeftHand", "rig_LeftLowerArm", Vector3(0.0, 0.28, 0.0), Basis()],
		["rig_RightShoulder", "rig_UpperChest", Vector3(-0.05, 0.12, 0.0), out_right],
		["rig_RightUpperArm", "rig_RightShoulder", Vector3(0.0, 0.12, 0.0), Basis()],
		["rig_RightLowerArm", "rig_RightUpperArm", Vector3(0.0, 0.30, 0.0), Basis()],
		["rig_RightHand", "rig_RightLowerArm", Vector3(0.0, 0.28, 0.0), Basis()],
		["rig_LeftUpperLeg", "rig_Hips", Vector3(0.09, -0.05, 0.0), down],
		["rig_LeftLowerLeg", "rig_LeftUpperLeg", Vector3(0.0, 0.45, 0.0), Basis()],
		["rig_LeftFoot", "rig_LeftLowerLeg", Vector3(0.0, 0.48, 0.0), forward],
		["rig_RightUpperLeg", "rig_Hips", Vector3(-0.09, -0.05, 0.0), down],
		["rig_RightLowerLeg", "rig_RightUpperLeg", Vector3(0.0, 0.45, 0.0), Basis()],
		["rig_RightFoot", "rig_RightLowerLeg", Vector3(0.0, 0.48, 0.0), forward],
	]

	var skeleton := Skeleton3D.new()
	skeleton.name = "CustomRig"
	for bone in bones:
		skeleton.add_bone(bone[0])
	for index in bones.size():
		var parent: String = bones[index][1]
		if not parent.is_empty():
			skeleton.set_bone_parent(index, skeleton.find_bone(parent))
		skeleton.set_bone_rest(index, Transform3D(bones[index][3], bones[index][2]))
	skeleton.reset_bone_poses()
	return skeleton


func _build_custom_bone_map() -> BoneMap:
	var bone_map := BoneMap.new()
	bone_map.profile = SkeletonProfileHumanoid.new()
	for profile_bone in KimodoSmplx.get_humanoid_bone_names():
		if profile_bone in ["LeftToes", "RightToes"]:
			continue
		bone_map.set_skeleton_bone_name(profile_bone, "rig_" + profile_bone)
	return bone_map


## Skeleton3D.get_bone_global_pose() still reports the rest when it is read in
## the same frame as the seek that posed the skeleton, so the test composes the
## chain itself and does not depend on when the engine refreshes its cache.
func _global_pose(skeleton: Skeleton3D, bone: int) -> Transform3D:
	var transform := skeleton.get_bone_pose(bone)
	var parent := skeleton.get_bone_parent(bone)
	while parent >= 0:
		transform = skeleton.get_bone_pose(parent) * transform
		parent = skeleton.get_bone_parent(parent)
	return transform


func _play(stage: Node3D, _skeleton: Skeleton3D, animation: Animation, frame: int) -> void:
	var player := AnimationPlayer.new()
	stage.add_child(player)
	var library := AnimationLibrary.new()
	library.add_animation(&"motion", animation)
	player.add_animation_library(&"", library)
	player.play(&"motion")
	player.seek(frame / 30.0, true)


func _expect(condition: bool, description: String) -> void:
	if condition:
		print("  ok   ", description)
	else:
		_failures += 1
		printerr("  FAIL ", description)


## For assertions inside a loop, where one line per iteration would drown the
## report. Only failures are printed.
func _expect_quiet(condition: bool, description: String) -> void:
	if not condition:
		_failures += 1
		printerr("  FAIL ", description)
