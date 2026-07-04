## DamageNumber.gd
## Floating damage text popup. Uses object pooling.
## Floats upward, fades out, then returns to pool.
##
class_name DamageNumber
extends Node2D

@onready var label: Label = $Label

const FLOAT_SPEED  := 40.0
const FLOAT_TIME   := 0.9
const CRIT_SCALE   := 1.6

func _ready() -> void:
	label.text = ""

# ─── POOL INTERFACE ──────────────────────────────────────────────────────────

func on_acquire() -> void:
	label.modulate.a = 1.0
	label.scale = Vector2.ONE

func on_release() -> void:
	label.text = ""

# ─── DISPLAY ─────────────────────────────────────────────────────────────────

func show_damage(value: int, is_crit: bool = false,
		color: Color = Color.WHITE) -> void:
	label.text = str(value)
	label.add_theme_color_override("font_color",
		Color(1.0, 0.9, 0.0) if is_crit else color)

	# Crits are bigger and bounce slightly
	if is_crit:
		label.scale = Vector2(CRIT_SCALE, CRIT_SCALE)
		label.text  = "CRIT! " + str(value)
		_animate_crit()
	else:
		_animate_normal()

func show_heal(value: int) -> void:
	label.text = "+" + str(value)
	label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	_animate_normal()

func show_miss() -> void:
	label.text = "MISS"
	label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_animate_normal()

func _animate_normal() -> void:
	# Random horizontal drift + float up + fade
	var drift := randf_range(-12.0, 12.0)
	var tween := create_tween().set_parallel()
	tween.tween_property(self, "position:y",
		position.y - FLOAT_SPEED, FLOAT_TIME)
	tween.tween_property(self, "position:x",
		position.x + drift, FLOAT_TIME)
	tween.tween_property(label, "modulate:a", 0.0, FLOAT_TIME * 0.6) \
		.set_delay(FLOAT_TIME * 0.4)
	tween.chain().tween_callback(func(): ObjectPool.release(self))

func _animate_crit() -> void:
	var tween := create_tween().set_parallel()
	# Pop up, scale to normal, then float
	tween.tween_property(label, "scale", Vector2.ONE * CRIT_SCALE, 0.08) \
		.set_trans(Tween.TRANS_BACK)
	tween.tween_property(self, "position:y",
		position.y - FLOAT_SPEED * 1.4, FLOAT_TIME * 1.1)
	tween.tween_property(label, "modulate:a", 0.0, FLOAT_TIME * 0.5) \
		.set_delay(FLOAT_TIME * 0.6)
	tween.chain().tween_callback(func(): ObjectPool.release(self))
