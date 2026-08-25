extends SceneTree

## Writes the sample BoneMap that maps SkeletonProfileHumanoid onto SMPL-X
## joint names.
##
##     godot --headless --path project -s res://tools/make_smplx_bone_map.gd
##
## Regenerate rather than hand-edit: the pairing comes from KimodoSmplx, so the
## two cannot drift apart.

const OUTPUT := "res://addons/kimodo/samples/smplx_bone_map.tres"


func _initialize() -> void:
	var bone_map := BoneMap.new()
	bone_map.profile = SkeletonProfileHumanoid.new()

	var profile_bones := KimodoSmplx.get_humanoid_bone_names()
	var joint_names := KimodoSmplx.get_joint_names()
	for joint in KimodoSmplx.get_joint_count():
		bone_map.set_skeleton_bone_name(profile_bones[joint], joint_names[joint])

	var error := ResourceSaver.save(bone_map, OUTPUT)
	if error != OK:
		printerr("cannot write %s (%d)" % [OUTPUT, error])
		quit(1)
		return
	print("wrote %s with %d pairs" % [OUTPUT, KimodoSmplx.get_joint_count()])
	quit()
