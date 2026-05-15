## Projectile.gd
## Base class for all projectiles: arrows, magic bolts, enemy projectiles.
## Uses object pooling — implements on_acquire/on_release interface.
##
## DESIGN: Projectiles are Area2D nodes (not CharacterBody2D) because they
## don't need physics collision response — they just detect overlaps and
## return to pool. This is significantly cheaper than CharacterBody2D.
##
class_name Projectile
extends Area2D

# ─── CONFIG ──────────────────────────────────────────────────────────────────

@export var speed: float        = 280.0
@export var max_lifetime: float = 3.0
@export var pierce_count: int   = 0       # 0 = destroy on first hit
@export var damage: int         = 10
@export var damage_type: StringName = &"physical"

# ─── RUNTIME STATE ───────────────────────────────────────────────────────────

var direction: Vector2 = Vector2.RIGHT
var shooter: Node = null            # Entity that fired this (for friendly fire check)
var _lifetime: float = 0.0
var _hit_count: int  = 0

@onready var sprite: Sprite2D = $Sprite2D
@onready var trail: GPUParticles2D = $Trail  # Optional visual trail

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	_lifetime += delta
	if _lifetime >= max_lifetime:
		_despawn()
		return

	position += direction * speed * delta
	# Rotate sprite to face movement direction
	rotation = direction.angle()

# ─── POOL INTERFACE ──────────────────────────────────────────────────────────

func on_acquire() -> void:
	_lifetime  = 0.0
	_hit_count = 0
	direction  = Vector2.RIGHT
	shooter    = null
	monitoring = true
	set_meta("damage",      damage)
	set_meta("damage_type", damage_type)
	if trail:
		trail.emitting = true

func on_release() -> void:
	monitoring = false
	if trail:
		trail.emitting = false

# ─── COLLISION ───────────────────────────────────────────────────────────────

func _on_area_entered(area: Area2D) -> void:
	# Hit a hurtbox
	if not area.has_meta("damage"):  # It's a hurtbox if parent has StatsComponent
		return
	var target := area.get_parent()
	if target == shooter:
		return
	_apply_hit(area)

func _on_body_entered(_body: Node2D) -> void:
	# Hit solid world geometry
	_despawn()

func _apply_hit(area: Area2D) -> void:
	var target := area.get_parent()
	var target_stats: StatsComponent = target.get_node_or_null("StatsComponent")
	if target_stats:
		var is_crit := false
		if shooter:
			var shooter_stats: StatsComponent = shooter.get_node_or_null("StatsComponent")
			if shooter_stats:
				is_crit = shooter_stats.roll_crit()
		var final_dmg := damage
		if is_crit and shooter:
			var s_stats: StatsComponent = shooter.get_node_or_null("StatsComponent")
			if s_stats:
				final_dmg = int(damage * s_stats.crit_multiplier)
		target_stats.take_damage(final_dmg, damage_type, shooter, is_crit)
		AudioManager.play_sfx(
			"res://assets/audio/sfx/arrow_hit.ogg", global_position, 0.12)

	_hit_count += 1
	if _hit_count > pierce_count:
		_despawn()

func _despawn() -> void:
	ObjectPool.release(self)
