@tool
extends EditorPlugin

## Adds the Kimodo dock. Everything the dock does is a call into the
## GDExtension; the plugin itself only owns the panel.

const KimodoDock := preload("res://addons/kimodo/dock.gd")
const KimodoPanel := preload("res://addons/kimodo/generate_panel.gd")
const KimodoImporter := preload("res://addons/kimodo/import_plugin.gd")
const Settings := preload("res://addons/kimodo/settings.gd")

var _dock: Control
## Untyped, because generated() belongs to generate_panel.gd rather than to
## the VBoxContainer it extends.
var _panel
var _importer: EditorImportPlugin


func _enter_tree() -> void:
	# Declared here rather than from the dock, so the settings are listed in
	# Editor Settings whether or not anyone opens the panel.
	Settings.register()

	# Before the dock, because a .kimodo already in the project is imported as
	# the plugin comes up. An extension nothing claims is a broken entry in the
	# FileSystem dock until somebody reimports it by hand.
	_importer = KimodoImporter.new()
	add_import_plugin(_importer)

	# The manager is handed over rather than looked up: get_undo_redo() is an
	# EditorPlugin method, and the dock is the half of this that edits scenes.
	_dock = KimodoDock.new(get_undo_redo())
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	# Selection changes reach the dock on their own. Opening another scene does
	# not, and it can take the target skeleton with it.
	# The wide half. It is left closed: a bottom panel that opens itself on
	# every project load takes the vertical space whether or not anyone is
	# generating today.
	_panel = KimodoPanel.new()
	_panel.generated.connect(_on_generated)
	add_control_to_bottom_panel(_panel, "Generate Motion")

	scene_changed.connect(_on_scene_changed)


func _on_generated(dir: String) -> void:
	if is_instance_valid(_dock):
		_dock.load_generated(dir)


func _on_scene_changed(_root: Node) -> void:
	if is_instance_valid(_dock):
		_dock.refresh_target()


func _exit_tree() -> void:
	if _importer != null:
		remove_import_plugin(_importer)
		_importer = null
	if is_instance_valid(_panel):
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
	if not is_instance_valid(_dock):
		return
	remove_control_from_docks(_dock)
	_dock.queue_free()
	_dock = null
