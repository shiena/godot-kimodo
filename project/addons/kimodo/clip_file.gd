@tool
extends RefCounted

## The .kimodo clip file: one motion, and the run that produced it, in one file.
##
## kmd-generate writes two headerless .f32 buffers into a folder of its own,
## outside the project, and nothing in that folder records the seed or the model
## that ran. That is enough to play a take back and not enough to keep one: a
## folder called gen_1756272000 cannot be committed, is not in the FileSystem
## dock, and cannot say what would have to be typed to make it again.
##
## A .kimodo file is that pair of buffers with the recipe in front of them, so
## the editor imports it like any other asset and the answer to "how was this
## made" travels with the clip rather than with the person who made it.
##
## The payload stays binary instead of becoming base64 inside a .tres: 600
## frames of a 34-joint skeleton is 326 KiB of floats, and text would be half as
## large again in exchange for a diff nobody can read anyway.

## A PackedByteArray literal is not a constant expression, so the eight bytes
## are spelled as text and converted where they are used. The end-of-file and
## newline on the tail are PNG's trick: a file dragged through a text-mode
## copy no longer matches, and says so instead of decoding into nonsense.
const MAGIC := "KIMODO
"
const VERSION := 1

## What every float in the payload costs, which is also the unit the two counts
## in front of them are written in.
const FLOAT_SIZE := 4


## The bytes on disk, in order. Little-endian throughout, which is what
## FileAccess writes and what PackedFloat32Array.to_byte_array() produces, and
## the .f32 files this replaces were read the same way on the same platforms.
##
##     MAGIC                8 bytes
##     version              u32
##     recipe               u32 length, then that many bytes of UTF-8 JSON
##     local rotations      u32 float count, then that many f32
##     root positions       u32 float count, then that many f32
static func write(path: String, motion: KimodoMotion) -> Error:
	if motion == null or motion.get_frame_count() <= 0:
		push_error("Kimodo: there is no motion to write to %s." % path)
		return ERR_INVALID_DATA

	var directory := path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		var error := DirAccess.make_dir_recursive_absolute(directory)
		if error != OK:
			push_error("Kimodo: cannot create %s (%d)." % [directory, error])
			return error

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var error := FileAccess.get_open_error()
		push_error("Kimodo: cannot write %s (%d)." % [path, error])
		return error

	var header := JSON.stringify(motion.recipe).to_utf8_buffer()
	var rotations := motion.local_rotations_raw
	var positions := motion.root_positions_raw

	file.store_buffer(MAGIC.to_ascii_buffer())
	file.store_32(VERSION)
	file.store_32(header.size())
	file.store_buffer(header)
	file.store_32(rotations.size())
	file.store_buffer(rotations.to_byte_array())
	file.store_32(positions.size())
	file.store_buffer(positions.to_byte_array())
	file.close()
	return OK


## The clip in a file, or null having said on the console what was wrong with
## it. Every length is checked against what is left of the file before it is
## read, so a truncated or mistyped file is refused rather than turned into a
## gigabyte allocation.
static func read(path: String) -> KimodoMotion:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Kimodo: cannot open %s (%d)." % [path, FileAccess.get_open_error()])
		return null

	if file.get_buffer(MAGIC.length()) != MAGIC.to_ascii_buffer():
		push_error("Kimodo: %s does not start like a Kimodo clip." % path)
		return null
	var version := file.get_32()
	if version != VERSION:
		push_error("Kimodo: %s is a version %d clip and this addon reads version %d." % [
				path, version, VERSION])
		return null

	# An empty read is a refusal in every case here, including the recipe: the
	# shortest one a writer can produce is the two bytes of an empty object.
	var header := _read_bytes(file, path, "the recipe", file.get_32(), 1)
	if header.is_empty():
		return null
	var recipe = JSON.parse_string(header.get_string_from_utf8())
	if not (recipe is Dictionary):
		push_error("Kimodo: the recipe in %s is not a JSON object." % path)
		return null

	var rotations := _read_bytes(file, path, "the rotations", file.get_32(), FLOAT_SIZE)
	if rotations.is_empty():
		return null
	var positions := _read_bytes(file, path, "the root positions", file.get_32(), FLOAT_SIZE)
	if positions.is_empty():
		return null
	file.close()

	var motion := KimodoMotion.new()
	motion.local_rotations_raw = rotations.to_float32_array()
	motion.root_positions_raw = positions.to_float32_array()
	# The two buffers describe their own shape between them, so a frame count of
	# zero here means they disagree rather than that the clip is empty.
	if motion.get_frame_count() <= 0:
		push_error("Kimodo: the two buffers in %s do not describe a skeleton this addon knows." % path)
		return null
	motion.recipe = recipe
	return motion


static func _read_bytes(file: FileAccess, path: String, what: String, count: int,
		element_size: int) -> PackedByteArray:
	var wanted := count * element_size
	var left := file.get_length() - file.get_position()
	if count < 0 or wanted > left:
		push_error("Kimodo: %s claims %d bytes for %s and has %d left." % [path, wanted, what, left])
		return PackedByteArray()
	return file.get_buffer(wanted)


## Fills in the two fields a recipe cannot supply for itself: when it ran, and
## the hash that names it.
##
## The hash covers the inputs alone. Two runs of the same recipe are the same
## clip and hash alike, which is the whole use of it; folding the timestamp in
## would make every clip unique and say nothing.
static func stamp(recipe: Dictionary) -> Dictionary:
	var stamped := recipe.duplicate(true)
	stamped.erase("generated")
	stamped.erase("hash")
	stamped["hash"] = canonical(stamped).sha256_text()
	# UTC. A clip outlives the machine that made it and often the timezone too.
	stamped["generated"] = Time.get_datetime_string_from_system(true) + "Z"
	return stamped


## The text a recipe hashes as. JSON.stringify() sorts keys, so the order they
## were written in does not change the hash. The round trip through the parser
## is what makes a recipe read back off disk hash like the one that was written:
## JSON has one number type, so 150 returns as 150.0 and the two do not
## stringify alike.
static func canonical(recipe: Dictionary) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(recipe)))
