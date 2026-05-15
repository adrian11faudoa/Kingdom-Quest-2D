## EnemyRanged.gd
## Ranged archetype: keeps its distance and fires projectiles.
## Strafes around the player instead of charging directly.
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

## EnemySummoner.gd
## Summoner archetype: hangs back, periodically summons minions.
## Vulnerable during summon animation.
class_name EnemySummoner
extends EnemyBase

@export var max_minions: int = 3
@export var summon_cooldown: float = 8.0
@export var summon_scene: PackedScene

var _active_minions: Array[Node] = []
var _summon_timer: float = 0.0
var _is_summoning: bool = false

func _ready() -> void:
	super._ready()
	preferred_distance = 180.0  # Stay far back
	attack_radius = 200.0

func _ai_chase(delta: float) -> void:
	# Summoner barely chases — it maintains range and summons
	_summon_timer -= delta
	if _summon_timer <= 0.0 and not _is_summoning:
		_try_summon()
	super._ai_chase(delta)

func _execute_attack() -> void:
	_try_summon()

func _try_summon() -> void:
	# Clean up dead minions
	_active_minions = _active_minions.filter(func(m): return is_instance_valid(m))

	if _active_minions.size() >= max_minions or _is_summoning:
		return

	_is_summoning = true
	_summon_timer = summon_cooldown
	sprite.play("summon")
	AudioManager.play_sfx("res://assets/audio/sfx/enemy_summon.ogg", global_position, 0.05)

	await get_tree().create_timer(0.8).timeout

	if not is_instance_valid(self) or stats.is_dead:
		return

	if summon_scene:
		var minion := summon_scene.instantiate()
		get_parent().add_child(minion)
		# Spawn at a random offset
		minion.global_position = global_position + Vector2(
			randf_range(-40, 40), randf_range(-40, 40))
		_active_minions.append(minion)

	_is_summoning = false
	_can_attack = false
	attack_timer.start(attack_cooldown)
