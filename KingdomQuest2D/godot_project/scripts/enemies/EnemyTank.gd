## EnemyTank.gd
## Tank archetype: slow, high defense, charges through obstacles.
## Has a telegraphed charge attack.
class_name EnemyTank
extends EnemyBase

var _is_charging: bool = false
var _charge_dir: Vector2 = Vector2.ZERO
var _charge_timer: float = 0.0
const CHARGE_SPEED := 280.0
const CHARGE_DURATION := 0.6
const CHARGE_WINDUP := 0.8  # seconds of telegraph before charge

func _ready() -> void:
	super._ready()
	attack_radius = 60.0
	stagger_duration = 0.1  # Hard to stagger

func _execute_attack() -> void:
	if _is_charging:
		return
	_can_attack = false
	attack_timer.start(attack_cooldown * 1.5)

	# Windup telegraph
	sprite.play("charge_windup")
	await get_tree().create_timer(CHARGE_WINDUP).timeout

	if not is_instance_valid(self) or stats.is_dead:
		return
	if target == null:
		return

	# Execute charge
	_is_charging = true
	_charge_dir = (target.global_position - global_position).normalized()
	_charge_timer = CHARGE_DURATION
	sprite.play("run")

func _ai_attack(delta: float) -> void:
	if _is_charging:
		_charge_timer -= delta
		velocity = _charge_dir * CHARGE_SPEED
		# Deal damage to anything in path
		for body in $AttackArea.get_overlapping_bodies():
			if body.is_in_group("player"):
				var target_stats: StatsComponent = body.get_node_or_null("StatsComponent")
				if target_stats:
					target_stats.take_damage(stats.get_total_attack() * 2, &"physical", self)
		if _charge_timer <= 0.0:
			_is_charging = false
			velocity = Vector2.ZERO
	else:
		super._ai_attack(delta)

# ──────────────────────────────────────────────────────────────────────────────

