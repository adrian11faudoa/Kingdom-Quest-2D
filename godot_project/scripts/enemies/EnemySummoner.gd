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
