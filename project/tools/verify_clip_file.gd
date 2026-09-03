extends SceneTree

## Headless check of the .kimodo clip container.
##
##     godot --headless --path project -s res://tools/verify_clip_file.gd
##
## It round-trips the synthetic fixture through clip_file.gd and then feeds the
## reader files that are wrong in each of the ways a reader has to survive: a
## foreign file, a newer version, and a payload that stops early. The negative
## cases are meant to print nothing, so error output is off while they run.

const ClipFile := preload("res://addons/kimodo/clip_file.gd")

const MOTION_DIR := "res://motion_sample"
const CLIP := "user://verify_clip_file.kimodo"
const BROKEN := "user://verify_clip_file_broken.kimodo"

var _failures := 0


func _initialize() -> void:
	var motion := _check_source()
	if motion != null:
		var reread := _check_round_trip(motion)
		if reread != null:
			_check_recipe_survives(motion, reread)
	_check_stamp()
	_check_refusals()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(CLIP))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BROKEN))

	if _failures == 0:
		print("clip file: all checks passed")
	else:
		printerr("clip file: %d check(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)


func _check_source() -> KimodoMotion:
	var motion := KimodoMotion.new()
	if not _expect(motion.load_directory(MOTION_DIR) == OK, "the fixture loads"):
		return null
	motion.recipe = ClipFile.stamp({
		"prompts": ["a person walks forward", "and stops"],
		"lengths": [90, 30],
		"transition": 15,
		"steps": 150,
		"seed": 7,
		"skeleton": motion.get_skeleton_key(),
		"motion_repo": "LocalAI-io/Kimodo-SMPLX-RP-v1-GGML",
		"text_repo": "LocalAI-io/Llama-3-Kimodo-GGML",
		"revision": "main",
	})
	return motion


func _check_round_trip(motion: KimodoMotion) -> KimodoMotion:
	if not _expect(ClipFile.write(CLIP, motion) == OK, "the clip writes"):
		return null
	var reread: KimodoMotion = ClipFile.read(CLIP)
	if not _expect(reread != null, "the clip reads back"):
		return null

	# Exact rather than approximate: the payload is copied, not converted, so
	# anything but equality means a length or an offset is wrong.
	_expect(reread.local_rotations_raw == motion.local_rotations_raw,
			"every rotation float survives")
	_expect(reread.root_positions_raw == motion.root_positions_raw,
			"every root position float survives")
	_expect(reread.get_frame_count() == motion.get_frame_count(),
			"the frame count is derived the same way")
	_expect(reread.get_skeleton_key() == motion.get_skeleton_key(),
			"the skeleton is recognised the same way")
	return reread


func _check_recipe_survives(motion: KimodoMotion, reread: KimodoMotion) -> void:
	# Compared as numbers: JSON has one number type, so the 7 that went in comes
	# back as 7.0 and only their values are the same.
	_expect(float(reread.recipe.get("seed", -1)) == float(motion.recipe["seed"]),
			"the seed survives")
	_expect(Array(reread.recipe.get("prompts", [])) == Array(motion.recipe["prompts"]),
			"the prompts survive")
	# The point of hashing the canonical form: a recipe off disk has floats
	# where the one in memory had ints, and the two still name the same run.
	_expect(ClipFile.canonical(reread.recipe) == ClipFile.canonical(motion.recipe),
			"the recipe canonicalises the same before and after a round trip")


func _check_stamp() -> void:
	var recipe := {"seed": 7, "steps": 150, "prompts": ["walk"]}
	var first: Dictionary = ClipFile.stamp(recipe)
	# Key order must not reach the hash, so the same run written down backwards
	# is still the same run.
	var second: Dictionary = ClipFile.stamp({"prompts": ["walk"], "steps": 150, "seed": 7})
	_expect(first["hash"] == second["hash"], "the hash ignores the order keys were written in")
	_expect(String(first["hash"]).length() == 64, "the hash is a sha256")
	_expect(first.has("generated"), "the stamp records when it ran")

	var third: Dictionary = ClipFile.stamp(first)
	_expect(third["hash"] == first["hash"], "stamping a stamped recipe does not change its hash")
	_expect(ClipFile.stamp({"seed": 8, "steps": 150, "prompts": ["walk"]})["hash"] != first["hash"],
			"a different seed is a different hash")


## Each of these is a file the reader has to refuse rather than crash on.
func _check_refusals() -> void:
	var printing := Engine.print_error_messages
	Engine.print_error_messages = false

	_expect(ClipFile.read("user://verify_clip_file_absent.kimodo") == null,
			"a missing file is refused")

	_write_bytes("not a kimodo clip at all, just some bytes".to_utf8_buffer())
	_expect(ClipFile.read(BROKEN) == null, "a foreign file is refused")

	var newer := ClipFile.MAGIC.to_ascii_buffer()
	newer.append_array(_u32(ClipFile.VERSION + 1))
	_write_bytes(newer)
	_expect(ClipFile.read(BROKEN) == null, "a newer version is refused")

	# A header that promises more than the file holds. The reader has to answer
	# from the length it has left rather than by attempting the allocation.
	var truncated := ClipFile.MAGIC.to_ascii_buffer()
	truncated.append_array(_u32(ClipFile.VERSION))
	truncated.append_array(_u32(1 << 30))
	_write_bytes(truncated)
	_expect(ClipFile.read(BROKEN) == null, "a recipe longer than the file is refused")

	var short_payload := ClipFile.MAGIC.to_ascii_buffer()
	short_payload.append_array(_u32(ClipFile.VERSION))
	var header := "{}".to_utf8_buffer()
	short_payload.append_array(_u32(header.size()))
	short_payload.append_array(header)
	short_payload.append_array(_u32(1000))
	short_payload.append_array(_u32(4))
	_write_bytes(short_payload)
	_expect(ClipFile.read(BROKEN) == null, "a payload shorter than its count is refused")

	Engine.print_error_messages = printing


func _u32(value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, value)
	return out


func _write_bytes(bytes: PackedByteArray) -> void:
	var file := FileAccess.open(BROKEN, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


func _expect(condition: bool, what: String) -> bool:
	if condition:
		print("  ok    %s" % what)
	else:
		_failures += 1
		printerr("  FAIL  %s" % what)
	return condition
