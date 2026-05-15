## HitboxComponent.gd
## Reusable hitbox — the part of an entity that deals damage to others.
##
## DESIGN: Attach as Area2D child. Set damage metadata. Enable monitoring
## only during active attack frames (avoids continuous damage).
## The owner entity's attack stats are baked in when the attack starts.
##
## Usage:
##   hitbox.set_damage(stats.get_total_attack(), &"physical")
##   hitbox.monitoring = true   # activate
##   hitbox.monitoring = false  # deactivate after swing
##
class_name HitboxComponent
extends Area2D

signal hit_confirmed(target_hurtbox: Area2D)

## Set these before enabling monitoring
var damage: int = 10
var damage_type: StringName = &"physical"
var knockback_force: float = 150.0
var source_entity: Node = null

## Track targets already hit this swing to prevent multi-hit on same target
var _hit_this_swing: Array[Node] = []

func _ready() -> void:
	monitoring = false
	collision_layer = 0
	collision_mask = 0
	# Hitboxes hit enemy hurtboxes (layer 3) and player hurtboxes (layer 2)
	# Set the appropriate mask in the Inspector per entity
	area_entered.connect(_on_area_entered)

## Call this before enabling monitoring to configure damage values
func set_damage(p_damage: int, p_type: StringName = &"physical",
		p_knockback: float = 150.0) -> void:
	damage       = p_damage
	damage_type  = p_type
	knockback_force = p_knockback
	set_meta("damage",      damage)
	set_meta("damage_type", damage_type)
	set_meta("knockback",   knockback_force)

func _on_area_entered(area: Area2D) -> void:
	if not monitoring:
		return
	var target := area.get_parent()
	# Prevent hitting the same target twice per swing
	if target in _hit_this_swing:
		return
	if target == source_entity:
		return
	_hit_this_swing.append(target)
	hit_confirmed.emit(area)

## Call when attack animation ends or monitoring is disabled
func reset_swing() -> void:
	_hit_this_swing.clear()

## Override monitoring setter to auto-reset on deactivation
func set_monitoring(value: bool) -> void:
	super.monitoring = value
	if not value:
		reset_swing()

# ──────────────────────────────────────────────────────────────────────────────

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
