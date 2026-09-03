@tool
extends Control

## The sequence as a strip: one block per prompt, as wide as the frames it runs
## for, with the overlap each join is given marked on it.
##
## A dock is a column, and a column can only stack prompts. What it cannot show
## is the thing a sequence is actually about: how long each stretch runs next to
## the others, and how much of the one after it the transition eats. Both of
## those are widths, which is the whole reason this lives in a bottom panel.

## A block was clicked. The panel takes it as "edit this prompt".
signal picked(index: int)

## Tall enough for a block carrying two lines of text with the ruler clear
## underneath it: the index and the length on one, the prompt on the next.
const HEIGHT := 64.0
const RULER := 15.0

## What kimodo generates at. The ruler is in seconds because a length in frames
## says nothing about how long a clip feels.
const FPS := 30.0

var _prompts := PackedStringArray()
var _lengths := PackedInt32Array()
var _transition := 0
var _selected := -1


func _init() -> void:
	custom_minimum_size = Vector2(0.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tooltip_text = "The clip as it will be generated. Each block is a prompt, as wide as the frames it runs for. The hatched head of a block is the overlap the model is given to join it onto the one before."


func refresh(prompts: PackedStringArray, lengths: PackedInt32Array, transition: int,
		selected: int) -> void:
	_prompts = prompts
	_lengths = lengths
	_transition = transition
	_selected = selected
	queue_redraw()


func _accent() -> Color:
	var editor_theme := EditorInterface.get_editor_theme()
	return editor_theme.get_color(&"accent_color", &"Editor") if editor_theme != null else Color(0.4, 0.7, 1.0)


func _total() -> int:
	var total := 0
	for length in _lengths:
		total += length
	return total


func _draw() -> void:
	var total := _total()
	var strip := Vector2(size.x, size.y - RULER)
	# An empty sequence still draws its bed, so the panel does not change height
	# the moment a prompt is typed into it.
	draw_rect(Rect2(Vector2.ZERO, strip), Color(0.0, 0.0, 0.0, 0.25))
	if total <= 0 or strip.x <= 0.0:
		return

	var accent := _accent()
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var scale := strip.x / float(total)
	var frame := 0
	for index in _lengths.size():
		var left := frame * scale
		var right := (frame + _lengths[index]) * scale
		var block := Rect2(left, 0.0, maxf(right - left - 1.0, 1.0), strip.y)
		var chosen := index == _selected
		draw_rect(block, Color(accent.r, accent.g, accent.b, 0.32 if chosen else 0.14))

		# The overlap is the head of every block after the first, because the
		# transition is absorbed into the prompt that follows it rather than
		# added between the two.
		if index > 0 and _transition > 0:
			var overlap := Rect2(left, 0.0, minf(_transition * scale, block.size.x), strip.y)
			_draw_hatch(overlap, Color(accent.r, accent.g, accent.b, 0.5))

		if chosen:
			draw_rect(block, accent, false, 1.0)
		_draw_label(block, index, font, font_size)
		frame += _lengths[index]

	_draw_ruler(total, scale, strip.y, font, font_size)


## Diagonals rather than a flat tint: the overlap sits on top of a block that is
## already tinted, and a second tint of the same colour reads as a slightly
## different prompt instead of as a marking on this one.
func _draw_hatch(area: Rect2, colour: Color) -> void:
	# Each diagonal is the set of points where x - y is a constant, so the line
	# is clipped by clamping y into the part of its run that stays inside.
	var step := 6.0
	var offset := -area.size.y
	while offset < area.size.x:
		var low := clampf(-offset, 0.0, area.size.y)
		var high := clampf(area.size.x - offset, 0.0, area.size.y)
		if high > low:
			draw_line(area.position + Vector2(offset + low, low),
					area.position + Vector2(offset + high, high), colour, 1.0)
		offset += step


## The index and the length, and the prompt itself when the block is wide enough
## to be worth reading. A block narrower than its own number gets nothing: a
## clipped "3" is worse than an empty block the ruler already explains.
func _draw_label(block: Rect2, index: int, font: Font, font_size: int) -> void:
	if font == null or block.size.x < 22.0:
		return
	var colour := Color(1.0, 1.0, 1.0, 0.85)
	var baseline := block.position.y + font_size + 3.0
	draw_string(font, Vector2(block.position.x + 4.0, baseline),
			"%d  %df" % [index + 1, _lengths[index]], HORIZONTAL_ALIGNMENT_LEFT,
			block.size.x - 8.0, font_size, colour)
	if block.size.x < 90.0 or index >= _prompts.size():
		return
	draw_string(font, Vector2(block.position.x + 4.0, baseline + font_size + 2.0),
			_prompts[index], HORIZONTAL_ALIGNMENT_LEFT, block.size.x - 8.0,
			font_size, Color(1.0, 1.0, 1.0, 0.55))


## A tick a second, labelled while the labels still fit. Seconds rather than
## frames: the frame counts are already on the blocks, and what a reader wants
## from a ruler is how long the clip runs.
func _draw_ruler(total: int, scale: float, top: float, font: Font, font_size: int) -> void:
	var colour := Color(1.0, 1.0, 1.0, 0.35)
	var spacing := FPS * scale
	var every := 1
	# One label needs about 24 pixels. Below that the ticks stay and the numbers
	# thin out, rather than the ruler turning into a grey smear.
	while spacing * every < 24.0:
		every *= 2
	var second := 0
	while second * FPS <= total:
		var x := second * FPS * scale
		var tall := second % every == 0
		draw_line(Vector2(x, top), Vector2(x, top + (5.0 if tall else 3.0)), colour, 1.0)
		if tall and font != null:
			draw_string(font, Vector2(x + 2.0, top + RULER - 2.0), "%ds" % second,
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size - 2, colour)
		second += 1


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var total := _total()
	if total <= 0 or size.x <= 0.0:
		return
	var frame := int(event.position.x / size.x * total)
	var walked := 0
	for index in _lengths.size():
		walked += _lengths[index]
		if frame < walked:
			picked.emit(index)
			accept_event()
			return
