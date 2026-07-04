## HurtboxComponent.gd
## The part of an entity that RECEIVES damage from hitboxes.
## Sits on its own Area2D so it can have a different collision shape
## from the movement CollisionShape2D.
##
class_name HurtboxComponent
extends Area2D

signal damaged(damage: int, damage_type: StringName, source: Node)

## Optional: brief invincibility window after taking a hit
@export var invincibility_duration: float = 0.0

var _is_invincible: bool = false

func _ready() -> void:
	monitoring = true
	area_entered.connect(_on_area_entered)

func _on_area_entered(area: Area2D) -> void:
	if _is_invincible:
		return
	if not area.has_meta("damage"):
		return

	var dmg: int        = area.get_meta("damage", 0)
	var dmg_type: StringName = area.get_meta("damage_type", &"physical")
	var source: Node    = area.get_parent()

	damaged.emit(dmg, dmg_type, source)

	if invincibility_duration > 0.0:
		_start_invincibility()

func _start_invincibility() -> void:
	_is_invincible = true
	await get_tree().create_timer(invincibility_duration).timeout
	_is_invincible = false

func set_invincible(value: bool) -> void:
	_is_invincible = value
