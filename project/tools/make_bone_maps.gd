extends SceneTree

## Writes one sample BoneMap per skeleton, mapping SkeletonProfileHumanoid onto
## that skeleton's own joint names.
##
##     godot --headless --path project -s res://tools/make_bone_maps.gd
##
## Regenerate rather than hand-edit: the pairing comes from KimodoSkeleton, so
## the two cannot drift apart.
##
## A joint the humanoid profile has no slot for is skipped. That is most of G1,
## which spends twenty of its thirty-four joints on single axes no rig gives a
## bone to.

const OUTPUT := {
	"smplx22": "res://addons/kimodo/samples/smplx_bone_map.tres",
	"soma30": "res://addons/kimodo/samples/soma_bone_map.tres",
	"g1skel34": "res://addons/kimodo/samples/g1_bone_map.tres",
}


func _initialize() -> void:
	for key in OUTPUT:
		if not _write(key, String(OUTPUT[key])):
			quit(1)
			return
	quit()


func _write(key: String, path: String) -> bool:
	var bone_map := BoneMap.new()
	bone_map.profile = SkeletonProfileHumanoid.new()

	var profile_bones := KimodoSkeleton.get_humanoid_bone_names(key)
	var joint_names := KimodoSkeleton.get_joint_names(key)
	var pairs := 0
	for joint in KimodoSkeleton.get_joint_count(key):
		if profile_bones[joint].is_empty():
			continue
		bone_map.set_skeleton_bone_name(profile_bones[joint], joint_names[joint])
		pairs += 1

	var error := ResourceSaver.save(bone_map, path)
	if error != OK:
		printerr("cannot write %s (%d)" % [path, error])
		return false
	print("wrote %s with %d pairs" % [path, pairs])
	return true
