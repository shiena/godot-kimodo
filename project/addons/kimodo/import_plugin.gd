@tool
extends EditorImportPlugin

## Turns a .kimodo clip into the KimodoMotion the rest of the addon works on.
##
## The import is a format conversion and nothing else. It reads a file that is
## already on disk; it never runs kmd-generate. That matters more than it
## sounds: Godot reimports on its own, when a project is opened and whenever a
## source file changes, and an importer that generated would answer a fresh
## checkout by taking the GPU for an hour without being asked.
##
## Generating stays where a person can see it, under Generate in the dock. What
## the importer gives back in exchange is the Import dock: a clip is an asset
## with settings and a Reimport button, rather than a folder somebody has to
## remember the name of.

const ClipFile := preload("res://addons/kimodo/clip_file.gd")


func _get_importer_name() -> String:
	return "kimodo.clip"


func _get_visible_name() -> String:
	return "Kimodo Motion"


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["kimodo"])


func _get_save_extension() -> String:
	return "res"


func _get_resource_type() -> String:
	return "KimodoMotion"


func _get_priority() -> float:
	return 1.0


func _get_import_order() -> int:
	return 0


func _get_preset_count() -> int:
	return 1


func _get_preset_name(_preset_index: int) -> String:
	return "Default"


## Zero rather than 30 as the default, so the setting reads as an override
## rather than a second opinion. Kimodo generates at 30 fps and KimodoMotion
## says so once, in C++; anyone typing a number here is deliberately playing a
## clip at a rate it was not made at.
func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	return [{
		"name": "fps",
		"default_value": 0.0,
		"property_hint": PROPERTY_HINT_RANGE,
		"hint_string": "0,240,1,or_greater",
	}]


func _get_option_visibility(_path: String, _option_name: StringName, _options: Dictionary) -> bool:
	return true


func _import(source_file: String, save_path: String, options: Dictionary,
		_platform_variants: Array[String], _gen_files: Array[String]) -> Error:
	var motion := ClipFile.read(source_file)
	if motion == null:
		# ClipFile.read() has already said which part of the file was wrong.
		return ERR_FILE_UNRECOGNIZED
	var fps := float(options.get("fps", 0.0))
	if fps > 0.0:
		motion.fps = fps
	return ResourceSaver.save(motion, "%s.%s" % [save_path, _get_save_extension()])
