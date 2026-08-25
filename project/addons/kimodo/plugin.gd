@tool
extends EditorPlugin

## Adds the Kimodo dock. Everything the dock does is a call into the
## GDExtension; the plugin itself only owns the panel.

const KimodoDock := preload("res://addons/kimodo/dock.gd")

var _dock: Control


func _enter_tree() -> void:
	_dock = KimodoDock.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if not is_instance_valid(_dock):
		return
	remove_control_from_docks(_dock)
	_dock.queue_free()
	_dock = null
