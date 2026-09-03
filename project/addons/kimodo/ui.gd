@tool
extends RefCounted

## The handful of controls the dock and the Generate panel both build.
##
## They were the dock's private helpers until the panel needed the same
## section headings, the same capped status lines and the same labelled spin
## boxes. Two copies of a status line is two places for one to stop wrapping.


static func section(parent: Control, title: String) -> void:
	parent.add_child(HSeparator.new())
	var label := Label.new()
	label.text = title
	label.add_theme_color_override(&"font_color", Color(0.6, 0.75, 1.0))
	parent.add_child(label)


## Deliberately no clip_text. Setting it drops the text from the button's
## minimum size, so a button that does not expand shrinks to its padding and
## loses its label entirely. Short labels are what keeps the dock narrow.
static func button(parent: Control, text: String, action: Callable, tooltip: String = "") -> Button:
	var control := Button.new()
	control.text = text
	control.tooltip_text = tooltip
	control.pressed.connect(action)
	parent.add_child(control)
	return control


## Floats rather than ints, so the guidance weights can share it with the frame
## counts. Callers that want whole numbers leave the step at 1 and read the
## value back through int().
static func spin(parent: Control, label_text: String, low: float, high: float, value: float,
		tooltip: String = "", step: float = 1.0) -> SpinBox:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(box)
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tooltip
	box.add_child(label)
	var control := SpinBox.new()
	control.min_value = low
	control.max_value = high
	control.step = step
	control.value = value
	control.tooltip_text = tooltip
	box.add_child(control)
	return control


## A status line. It wraps, and it is capped so that one long path cannot push
## everything below it out of the panel it lives in.
static func message(parent: Control, lines: int) -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.max_lines_visible = lines
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	parent.add_child(label)
	return label


## Capped labels drop the tail, so the whole message stays reachable as a
## tooltip.
static func set_message(label: Label, text: String) -> void:
	label.text = text
	label.tooltip_text = text
