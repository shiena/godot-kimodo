@tool
extends "res://addons/kimodo/downloader.gd"

## Everything the SMPL-X GGUF needs that a download cannot supply: the gated
## checkpoint it is converted from, and the conversion itself.
##
## The upstream licence forbids distributing a converted model, so nobody can
## publish this one GGUF. Converting it for yourself is allowed, which is why
## the work happens here rather than being fetched like the other two.
##
## The conversion is kimodo.cpp's own scripts/convert_motion_to_gguf.py, copied
## into the addon by scons. It is not reimplemented in GDScript: it is the
## parser upstream reviews, it imports nothing outside the standard library,
## and a second copy of a format reader is a second thing to get wrong.
##
## The transfer plumbing comes from the downloader this extends. What differs
## is that a checkpoint publishes no manifest of ours, so the file list is
## written down here and the sizes come from the Hugging Face API.

const REPO := "nvidia/Kimodo-SMPLX-RP-v1"
const CONVERTER := "res://addons/kimodo/scripts/convert_motion_to_gguf.py"

## What the converter opens. Everything else in the repository is a model card.
const FILES := [
	"model.safetensors",
	"config.yaml",
	"stats/motion/global_root/mean.npy",
	"stats/motion/global_root/std.npy",
	"stats/motion/local_root/mean.npy",
	"stats/motion/local_root/std.npy",
	"stats/motion/body/mean.npy",
	"stats/motion/body/std.npy",
]

## The converter refuses to run against a Python that lacks str.removeprefix.
const MINIMUM_PYTHON := Vector2i(3, 9)

## The command that produced the last failure, so a person can run it by hand
## and read what the addon could not capture.
var last_command := ""


## Where the checkpoint is unpacked. Beside the bundle rather than inside it:
## kmd-generate is handed models/ and generated/, and this is neither.
static func checkpoint_dir(models_dir: String) -> String:
	return models_dir.path_join("checkpoints").path_join(REPO.get_file())


static func converter_path() -> String:
	return CONVERTER


## Fetch, then convert, reporting through the inherited progress and finished
## signals so the dock treats it like any other long transfer.
func run_conversion(models_dir: String, token: String, output: String) -> void:
	if is_busy():
		return
	_begin()

	var message := await _run_conversion(models_dir, token, output)
	_end(message, "The SMPL-X GGUF is converted and in place.")


func _run_conversion(models_dir: String, token: String, output: String) -> String:
	if not _has_curl():
		return "curl was not found on PATH. It ships with Windows 10 and later, macOS and most Linux distributions."

	if not FileAccess.file_exists(CONVERTER):
		return "%s is missing. It is copied into the addon by scons, so a source build needs to have run." % CONVERTER
	var script := ProjectSettings.globalize_path(CONVERTER)

	var interpreter := find_interpreter()
	if interpreter.is_empty():
		return ("No Python was found on PATH. The converter needs %d.%d or later. Install one, or install uv "
				+ "and it will supply its own.") % [MINIMUM_PYTHON.x, MINIMUM_PYTHON.y]

	# Before the gigabyte rather than after it. A version string says an
	# interpreter exists; running the converter says it can be run, which is
	# the question. It also makes uv fetch its Python now, while there is
	# nothing to lose by waiting.
	_current_label = "checking the converter runs"
	_current_part = ""
	_current_item_bytes = 0
	var probe := interpreter.duplicate()
	probe.append(script)
	probe.append("--help")
	var probe_program: String = probe[0]
	probe.remove_at(0)
	var probe_code := await _run_process(probe_program, probe, "")
	if _cancelled:
		return "Cancelled."
	if probe_code != 0:
		return "%s cannot run the converter (exited with %d). Try it by hand: %s %s" % [
				probe_program, probe_code, probe_program, " ".join(probe)]

	var info := await _repo_info(token)
	if info.has("error"):
		return info["error"]

	var destination := checkpoint_dir(models_dir)
	var work := []
	for relative in FILES:
		if not info["sizes"].has(relative):
			return "%s does not publish %s." % [REPO, relative]
		work.append({
			"url": _blob_url(REPO, info["sha"], relative),
			"path": destination.path_join(relative),
			"bytes": int(info["sizes"][relative]),
			# The checkpoint publishes no hashes of its own. There is nothing
			# to compare against, and pretending otherwise would be worse than
			# saying so: the conversion records the SHA-256 it actually read.
			"sha256": "",
			"label": relative.get_file(),
		})

	for item in work:
		_total_bytes += item["bytes"]
	for item in work:
		if _cancelled:
			return "Cancelled."
		var error := await _fetch_one(item, token, false)
		if not error.is_empty():
			return error
		_done_bytes += item["bytes"]

	# The converter reads this to confirm the checkpoint is one it knows, and
	# records the pair in the GGUF. download_weights.sh writes the same line.
	var revision := FileAccess.open(destination.path_join("REVISION"), FileAccess.WRITE)
	if revision == null:
		return "Cannot write REVISION into %s." % destination
	revision.store_line("%s  %s" % [info["sha"], REPO])
	revision.close()

	return await _convert(interpreter, script, destination, output)


## Runs the converter and watches the temporary file it publishes from, which
## is the only progress a separate process offers.
func _convert(interpreter: PackedStringArray, script: String, source: String, output: String) -> String:
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var arguments := interpreter.duplicate()
	arguments.append(script)
	arguments.append_array(PackedStringArray([
		"--input", ProjectSettings.globalize_path(source),
		"--output", ProjectSettings.globalize_path(output),
	]))
	var program: String = arguments[0]
	arguments.remove_at(0)
	last_command = "%s %s" % [program, " ".join(arguments)]

	_current_label = "converting to %s" % output.get_file()
	_current_item_bytes = 0
	# The converter writes a sibling and renames it at the end, so the .tmp is
	# where the gigabyte actually lands while it runs.
	var code := await _run_process(program, arguments, output + ".tmp")
	if _cancelled:
		return "Cancelled."
	if code != 0:
		return ("The converter exited with %d. Run it by hand to see what it said: %s"
				% [code, last_command])
	if not FileAccess.file_exists(output):
		return "The converter reported success but %s is not there." % output
	return ""


## The Hugging Face metadata API answers for a gated repository without a
## token, which is what makes it possible to resolve the revision and the
## sizes before asking anyone to paste one.
func _repo_info(token: String) -> Dictionary:
	var scratch := "user://kimodo_checkpoint_info.json"
	_current_label = "%s listing" % REPO
	_current_part = ""

	var args := PackedStringArray(["--location", "--fail", "--silent", "--show-error",
			"--output", ProjectSettings.globalize_path(scratch),
			"https://huggingface.co/api/models/%s?blobs=true" % REPO])
	if not token.is_empty():
		args.append_array(PackedStringArray(["--header", "Authorization: Bearer " + token]))

	var code := await _run_process("curl", args, "")
	if code != 0:
		return {"error": "Cannot read what %s publishes (curl %d)." % [REPO, code]}

	var file := FileAccess.open(scratch, FileAccess.READ)
	if file == null:
		return {"error": "Cannot read the downloaded listing of %s." % REPO}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	DirAccess.remove_absolute(scratch)

	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("sha"):
		return {"error": "%s did not answer with a model listing." % REPO}
	var sizes := {}
	for sibling in parsed.get("siblings", []):
		if sibling.has("size"):
			sizes[String(sibling.get("rfilename", ""))] = sibling["size"]
	return {"sha": String(parsed["sha"]), "sizes": sizes}


## The interpreter to run the converter with, as the command and the arguments
## that precede the script. Empty when there is none.
##
## A Python already on PATH is preferred: the converter imports nothing outside
## the standard library, so uv would only be supplying an interpreter that is
## already there. uv is the answer for a machine without one, and it downloads
## its own.
static func find_interpreter() -> PackedStringArray:
	for name in ["python3", "python"]:
		var found := on_path(name)
		if not found.is_empty() and python_version(found) >= MINIMUM_PYTHON:
			return PackedStringArray([found])
	var uv := on_path("uv")
	if uv.is_empty():
		return PackedStringArray()
	# --no-project, or uv walks up looking for a pyproject.toml that has
	# nothing to do with this.
	return PackedStringArray([uv, "run", "--no-project", "--python", "3.12"])


## Zero for anything that does not answer with a version, which on Windows
## includes the Microsoft Store stub that sits on PATH pretending to be Python
## until someone installs one.
static func python_version(program: String) -> Vector2i:
	var output := []
	if OS.execute(program, ["--version"], output, true) != 0 or output.is_empty():
		return Vector2i.ZERO
	var fields := String(output[0]).strip_edges().split(" ")
	if fields.size() < 2:
		return Vector2i.ZERO
	var parts := fields[1].split(".")
	if parts.size() < 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))
