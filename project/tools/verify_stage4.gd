extends SceneTree

## Headless check for stage 4, saving a baked clip and keeping it in a library.
##
##     godot --headless --path project -s res://tools/verify_stage4.gd
##
## Everything is written under user:// and removed again, so a run leaves the
## project untouched.

const MOTION_DIR := "res://motion_sample"
const WORK_DIR := "user://kimodo_verify"
const CLIP_PATH := WORK_DIR + "/walk.tres"
const LIBRARY_PATH := WORK_DIR + "/nested/clips.tres"

var _failures := 0


func _initialize() -> void:
	var motion := KimodoMotion.new()
	if motion.load_directory(MOTION_DIR) != OK:
		printerr("stage 4: no sample motion in %s; run scripts/make_sample_motion.py first" % MOTION_DIR)
		quit(1)
		return

	var skeleton := KimodoSkeleton.create_humanoid_skeleton()
	var animation := KimodoRetarget.bake_animation(motion, skeleton, null, NodePath("Skeleton3D"))
	skeleton.free()

	_clean()
	_check_standalone_save(animation)
	_check_library(animation)
	_check_attach()
	_clean()

	if _failures == 0:
		print("stage 4: all checks passed")
	else:
		printerr("stage 4: %d check(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)


func _check_standalone_save(animation: Animation) -> void:
	_expect(KimodoLibrary.save_animation(animation, CLIP_PATH) == OK, "a clip saves on its own")
	_expect(FileAccess.file_exists(CLIP_PATH), "the file is where it was asked for")

	var reloaded: Animation = ResourceLoader.load(CLIP_PATH, "Animation", ResourceLoader.CACHE_MODE_IGNORE)
	_expect(reloaded != null and reloaded.get_track_count() == animation.get_track_count(),
			"it comes back with every track")
	_expect(reloaded != null and is_equal_approx(reloaded.length, animation.length),
			"and with the same length")


func _check_library(animation: Animation) -> void:
	# The nested path also proves the missing directory gets created.
	_expect(KimodoLibrary.save_to_library(animation, LIBRARY_PATH, &"walk") == OK,
			"a clip saves into a library that does not exist yet")

	var library := _load_library()
	_expect(library != null and library.has_animation(&"walk"), "the library holds the clip")

	_expect(KimodoLibrary.save_to_library(animation, LIBRARY_PATH, &"walk") == OK,
			"saving the same name again succeeds")
	library = _load_library()
	_expect(library != null and library.get_animation_list().size() == 1,
			"it replaced the clip rather than piling up duplicates (%d entries)"
			% [0 if library == null else library.get_animation_list().size()])

	_expect(KimodoLibrary.save_to_library(animation, LIBRARY_PATH, &"wave") == OK, "a second name saves too")
	library = _load_library()
	_expect(library != null and library.get_animation_list().size() == 2, "and sits alongside the first")


func _check_attach() -> void:
	var player := AnimationPlayer.new()
	get_root().add_child(player)

	_expect(KimodoLibrary.attach_library(player, LIBRARY_PATH, &"kimodo") == OK, "a saved library attaches")
	_expect(player.has_animation(&"kimodo/walk"), "the player can play it by qualified name")
	_expect(KimodoLibrary.attach_library(player, LIBRARY_PATH, &"kimodo") == OK,
			"attaching twice replaces rather than fails")

	player.free()


func _load_library() -> AnimationLibrary:
	return ResourceLoader.load(LIBRARY_PATH, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)


func _clean() -> void:
	for path in [CLIP_PATH, LIBRARY_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	for directory in [WORK_DIR + "/nested", WORK_DIR]:
		if DirAccess.dir_exists_absolute(directory):
			DirAccess.remove_absolute(directory)


func _expect(condition: bool, description: String) -> void:
	if condition:
		print("  ok   ", description)
	else:
		_failures += 1
		printerr("  FAIL ", description)
