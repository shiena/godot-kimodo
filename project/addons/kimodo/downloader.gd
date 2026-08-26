@tool
extends Node

## Fetches the published Kimodo GGUF bundle from Hugging Face and verifies it
## against the manifest, the same way scripts/download_gguf_weights.sh does.
##
## The transfer runs through curl rather than HTTPRequest. The text bundle is
## Llama-3-8B split across thirty-odd files, so a dropped connection partway
## through is a matter of when rather than whether, and curl resumes a partial
## file with -C - where HTTPRequest would start it over. curl ships with Windows
## 10 and later, macOS, and effectively every Linux distribution.

signal progress(text: String, ratio: float)
signal finished(ok: bool, message: String)

const MANIFEST_FORMAT := "kimodo-gguf-manifest-v1"
const MANIFEST_NAME := "MANIFEST.json"
const HASH_CHUNK := 1 << 20

var _pid := -1
var _cancelled := false
var _busy := false

var _current_part := ""
var _current_bytes := 0
var _current_item_bytes := 0
var _done_bytes := 0
var _total_bytes := 0
var _current_label := ""


func is_busy() -> bool:
	return _busy


func cancel() -> void:
	_cancelled = true
	if _pid >= 0 and OS.is_process_running(_pid):
		OS.kill(_pid)


## repos is an array of {repo, revision, include}, where include is an array of
## glob patterns matched against the manifest paths.
func run(destination: String, repos: Array, token: String, reverify: bool) -> void:
	if _busy:
		return
	_begin()
	var message := await _run(destination, repos, token, reverify)
	_end(message, "The bundle is complete and verified.")


## Split out so that anything else built on this plumbing reports the same way.
## checkpoint.gd fetches a repository with no manifest and then runs a
## converter, and neither of those is a bundle.
func _begin() -> void:
	_busy = true
	_cancelled = false
	_done_bytes = 0
	_total_bytes = 0


func _end(message: String, success: String) -> void:
	_busy = false
	finished.emit(message.is_empty(), message if not message.is_empty() else success)


func _run(destination: String, repos: Array, token: String, reverify: bool) -> String:
	if not _has_curl():
		return "curl was not found on PATH. It ships with Windows 10 and later, macOS and most Linux distributions."

	var work := []
	# A repository that will not hand over its manifest costs its own files and
	# no others. Returning here instead would mean one withdrawn publication
	# holds back the gigabytes the rest of them still serve, and the person
	# waiting on those gigabytes can do nothing about the withdrawal.
	var refused := PackedStringArray()
	for spec in repos:
		var manifest := await _fetch_manifest(spec["repo"], spec["revision"], token)
		if _cancelled:
			return "Cancelled."
		if manifest.has("error"):
			refused.append(manifest["error"])
			continue

		for entry in manifest["files"]:
			var relative := String(entry.get("path", ""))
			var refusal := _reject_path(relative)
			if not refusal.is_empty():
				return refusal
			if not _matches(relative, spec["include"]):
				continue
			work.append({
				"url": _blob_url(spec["repo"], spec["revision"], relative),
				"path": destination.path_join(relative),
				"bytes": int(entry.get("bytes", 0)),
				"sha256": String(entry.get("sha256", "")),
				"label": relative.get_file(),
			})

	if work.is_empty():
		if not refused.is_empty():
			return " ".join(refused)
		return "The manifests listed nothing matching the expected layout."

	for item in work:
		_total_bytes += item["bytes"]

	for item in work:
		if _cancelled:
			return "Cancelled."
		var error := await _fetch_one(item, token, reverify)
		if not error.is_empty():
			return error
		_done_bytes += item["bytes"]

	return " ".join(refused)


func _fetch_one(item: Dictionary, token: String, reverify: bool) -> String:
	var path: String = item["path"]
	var label: String = item["label"]

	_current_item_bytes = item["bytes"]

	if _is_present(path, item["bytes"]):
		if not reverify:
			return ""
		_current_label = "verifying %s" % label
		_current_bytes = item["bytes"]
		if await _sha256(path) == item["sha256"]:
			return ""
		DirAccess.remove_absolute(path)

	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var part := path + ".part"

	# One retry from scratch: a .part left over from an interrupted run can be
	# the right length and the wrong content, which -C - has no way to notice.
	for attempt in 2:
		if attempt == 1:
			DirAccess.remove_absolute(part)
		_current_label = label
		var code := await _run_process("curl", _download_args(item["url"], part, token), part)
		if _cancelled:
			return "Cancelled."
		if code != 0:
			return "curl exited with %d while fetching %s." % [code, label]

		# A repository that publishes no hashes leaves the transfer itself as
		# the only check there is. Comparing against an empty string would fail
		# every file rather than admit that.
		if String(item["sha256"]).is_empty():
			return _publish(part, path, label)

		_current_label = "verifying %s" % label
		_current_bytes = item["bytes"]
		if await _sha256(part) == item["sha256"]:
			return _publish(part, path, label)

	return "%s failed its checksum twice. The published file may have changed." % label


func _publish(part: String, path: String, label: String) -> String:
	DirAccess.remove_absolute(path)
	var moved := DirAccess.rename_absolute(part, path)
	if moved != OK:
		return "Cannot move %s into place (%d)." % [label, moved]
	return ""


func _download_args(url: String, part: String, token: String) -> PackedStringArray:
	var args := PackedStringArray([
		"--location",
		"--fail",
		"--silent",
		"--show-error",
		"--retry", "3",
		"--retry-delay", "2",
		"--continue-at", "-",
		"--output", ProjectSettings.globalize_path(part),
	])
	if not token.is_empty():
		args.append_array(PackedStringArray(["--header", "Authorization: Bearer " + token]))
	args.append(url)
	return args


func _fetch_manifest(repo: String, revision: String, token: String) -> Dictionary:
	var scratch := "user://kimodo_manifest_%s.json" % repo.replace("/", "__")
	_current_label = "%s manifest" % repo
	_current_part = ""

	var args := PackedStringArray(["--location", "--fail", "--silent", "--show-error",
			"--output", ProjectSettings.globalize_path(scratch)])
	if not token.is_empty():
		args.append_array(PackedStringArray(["--header", "Authorization: Bearer " + token]))
	args.append(_blob_url(repo, revision, MANIFEST_NAME))

	var code := await _run_process("curl", args, "")
	if code != 0:
		return {"error": "Cannot read the manifest of %s at %s (curl %d)." % [repo, revision, code]}

	var file := FileAccess.open(scratch, FileAccess.READ)
	if file == null:
		return {"error": "Cannot read the downloaded manifest of %s." % repo}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	DirAccess.remove_absolute(scratch)

	if typeof(parsed) != TYPE_DICTIONARY or parsed.get("format", "") != MANIFEST_FORMAT:
		return {"error": "%s does not carry a %s manifest." % [repo, MANIFEST_FORMAT]}
	return {"files": parsed.get("files", [])}


## Runs a child and reports what it writes while it does. curl is the usual
## caller; the SMPL-X converter is the other one, and it is watched the same
## way because a separate process offers no progress but the file it is
## filling.
func _run_process(program: String, args: PackedStringArray, watched_part: String) -> int:
	_current_part = watched_part
	_current_bytes = 0
	_pid = OS.create_process(program, args, false)
	if _pid < 0:
		return -1

	var loop := Engine.get_main_loop() as SceneTree
	while OS.is_process_running(_pid):
		_emit_progress()
		if loop == null:
			OS.delay_msec(50)
		else:
			await loop.process_frame

	var code := OS.get_process_exit_code(_pid)
	_pid = -1
	_current_part = ""
	return -1 if _cancelled else code


## Polled from the wait loop rather than from _process, so the downloader does
## not need to be inside the scene tree to report anything.
func _emit_progress() -> void:
	var text := _current_label
	# One layer is 2.9% of the bundle and a 441 MB file takes minutes, so
	# the bar alone leaves a working download looking like a stalled one.
	# The count moves every second and settles the question.
	if not _current_part.is_empty():
		_current_bytes = maxi(0, _file_size(_current_part))
		if _current_item_bytes > 0:
			text = "%s  %d of %d MB" % [_current_label,
					_current_bytes / 1048576, _current_item_bytes / 1048576]
	var ratio := 0.0
	if _total_bytes > 0:
		ratio = clampf(float(_done_bytes + _current_bytes) / float(_total_bytes), 0.0, 1.0)
	progress.emit(text, ratio)


# --- helpers -----------------------------------------------------------------


func _has_curl() -> bool:
	var output := []
	return OS.execute("curl", ["--version"], output, false) == 0


func _blob_url(repo: String, revision: String, path: String) -> String:
	return "https://huggingface.co/%s/resolve/%s/%s" % [repo, revision, path]


## The same refusal the upstream script makes: a manifest is remote input, and a
## path that escapes the destination would write wherever it liked.
func _reject_path(relative: String) -> String:
	if relative.is_empty() or relative.is_absolute_path() or relative.begins_with("/"):
		return "The manifest lists an absolute path: %s" % relative
	if ".." in relative.split("/"):
		return "The manifest lists a path that escapes the destination: %s" % relative
	if not relative.ends_with(".gguf"):
		return "The manifest lists a non-GGUF file: %s" % relative
	return ""


func _matches(relative: String, patterns: Array) -> bool:
	for pattern in patterns:
		if relative.match(pattern):
			return true
	return false


func _is_present(path: String, bytes: int) -> bool:
	return _file_size(path) == bytes and bytes > 0


func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	var size := file.get_length()
	file.close()
	return size


## Hashing runs between files, and reading 441 MB off disk in one go stops
## the editor for as long as that takes. A stopped editor is what a hung
## download looks like, so the read gives a frame back now and then. It is
## chunked already, which is what makes that free.
func _sha256(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var loop := Engine.get_main_loop() as SceneTree
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var chunks := 0
	while not file.eof_reached():
		context.update(file.get_buffer(HASH_CHUNK))
		chunks += 1
		# Every 64 MiB: often enough to keep the editor answering, seldom
		# enough that waiting for frames does not outweigh the read.
		if loop != null and chunks % 64 == 0:
			_emit_progress()
			await loop.process_frame
	file.close()
	return context.finish().hex_encode()
