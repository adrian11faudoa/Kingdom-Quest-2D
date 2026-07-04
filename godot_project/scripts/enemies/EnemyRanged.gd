## EnemyRanged.gd
## Ranged archetype: keeps its distance and fires projectiles.
## Strafes around the player instead of charging directly.
class_name EnemyRanged
extends EnemyBase

@export var preferred_distance: float = 120.0
@export var strafe_speed: float = 60.0
var _strafe_dir: int = 1

func _ready() -> void:
	super._ready()
	attack_radius = 140.0  # Can attack from far

func _ai_chase(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		_change_ai_state(AIState.ALERT)
		return

	var dist := global_position.distance_to(target.global_position)

	if dist <= attack_radius:
		_change_ai_state(AIState.ATTACK)
		return

	# Back away if player gets close
	if dist < preferred_distance * 0.7:
		var flee_dir := (global_position - target.global_position).normalized()
		velocity = velocity.move_toward(flee_dir * stats.get_total_speed(), 800.0 * delta)
	else:
		# Strafe around player at preferred distance
		var to_player := (target.global_position - global_position).normalized()
		var strafe_vec := Vector2(-to_player.y, to_player.x) * _strafe_dir

		if randf() < 0.005:  # Occasionally reverse strafe direction
			_strafe_dir *= -1

		velocity = velocity.move_toward(strafe_vec * strafe_speed, 600.0 * delta)

	sprite.play("walk")
	_last_known_position = target.global_position

func _execute_attack() -> void:
	_can_attack = false
	attack_timer.start(attack_cooldown)
	sprite.play("attack")

	if target == null or not is_instance_valid(target):
		return

	var bolt = ObjectPool.acquire("magic_bolt", get_parent())
	if bolt:
		bolt.global_position = global_position
		bolt.direction = (target.global_position - global_position).normalized()
		bolt.damage = stats.get_total_attack()
		bolt.shooter = self

	AudioManager.play_sfx("res://assets/audio/sfx/enemy_ranged_fire.ogg", global_position, 0.1)

# ──────────────────────────────────────────────────────────────────────────────

