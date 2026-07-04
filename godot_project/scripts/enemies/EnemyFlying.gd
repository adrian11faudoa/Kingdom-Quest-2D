## EnemyFlying.gd
## Flying archetype: ignores pathfinding, moves directly toward target.
## Dive-bombs the player.
class_name EnemyFlying
extends EnemyBase

func _ready() -> void:
	super._ready()
	# Flying enemies bypass nav mesh — override movement
	nav_agent.avoidance_enabled = false

func _move_toward_position(target_pos: Vector2, speed: float, delta: float) -> void:
	# Fly directly — no pathfinding needed
	var direction := (target_pos - global_position).normalized()
	velocity = velocity.move_toward(direction * speed, 900.0 * delta)
	_update_facing(direction)

func _execute_attack() -> void:
	_can_attack = false
	attack_timer.start(attack_cooldown)

	# Dive bomb — charge at player rapidly then pull back
	if target and is_instance_valid(target):
		var dive_target := target.global_position
		var tween := create_tween()
		tween.tween_property(self, "global_position", dive_target, 0.15)
		tween.tween_property(self, "global_position",
			global_position + (global_position - dive_target).normalized() * 60.0, 0.2)
		tween.finished.connect(func():
			if is_instance_valid(self) and target and is_instance_valid(target):
				if global_position.distance_to(target.global_position) < attack_radius:
					var target_stats: StatsComponent = target.get_node_or_null("StatsComponent")
					if target_stats:
						target_stats.take_damage(stats.get_total_attack(), &"physical", self)
		)

# ──────────────────────────────────────────────────────────────────────────────

