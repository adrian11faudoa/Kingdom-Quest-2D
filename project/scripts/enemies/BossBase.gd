## BossBase.gd
## Multi-phase boss base class with phase transitions, intros, and special attacks.
##
## DESIGN: Bosses are complex enough to warrant their own class separate from
## EnemyBase. Each phase has its own attack pattern array. Phase transitions
## trigger cinematic pauses and stat changes.
##
class_name BossBase
extends CharacterBody2D

# ─── PHASE DATA ──────────────────────────────────────────────────────────────

## Override in each boss to define phase thresholds (health %)
## Format: [{ "threshold": 0.6, "speed_mult": 1.2, "music": "boss_phase2" }, ...]
@export var phase_thresholds: Array = []

# ─── STATE ───────────────────────────────────────────────────────────────────

enum BossState { INTRO, IDLE, COMBAT, PHASE_TRANSITION, DEAD }

var boss_state: BossState = BossState.INTRO
var current_phase: int = 0
var target: Node = null
var _is_attacking: bool = false
var _attack_queue: Array[Callable] = []

# ─── NODES ───────────────────────────────────────────────────────────────────

@onready var stats: StatsComponent      = $StatsComponent
@onready var sprite: AnimatedSprite2D   = $AnimatedSprite2D
@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D
@onready var hurtbox: Area2D            = $HurtboxComponent
@onready var phase_bar_ui: Control      = $BossHPBar  # Optional UI node

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("enemies")
	add_to_group("bosses")
	stats.died.connect(_on_died)
	stats.health_changed.connect(_on_health_changed)
	hurtbox.area_entered.connect(_on_hurtbox_hit)
	_build_attack_queue()
	_play_intro()

func _physics_process(delta: float) -> void:
	match boss_state:
		BossState.COMBAT: _combat_loop(delta)
		BossState.IDLE:   _idle_movement(delta)

# ─── INTRO ───────────────────────────────────────────────────────────────────

func _play_intro() -> void:
	boss_state = BossState.INTRO
	InputManager.disable_input()
	sprite.play("intro")
	# Example: camera zoom, music change
	EventBus.player_entered_region.emit(&"boss")
	await get_tree().create_timer(2.5).timeout
	InputManager.enable_input()
	boss_state = BossState.COMBAT
	target = GameManager.player_node

# ─── COMBAT LOOP ─────────────────────────────────────────────────────────────

func _combat_loop(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		boss_state = BossState.IDLE
		return

	if not _is_attacking:
		_move_toward_target(delta)
		if _should_attack():
			_run_next_attack()

func _idle_movement(delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 400.0 * delta)

func _move_toward_target(delta: float) -> void:
	if target == null:
		return
	nav_agent.target_position = target.global_position
	if nav_agent.is_navigation_finished():
		return
	var next := nav_agent.get_next_path_position()
	var dir := (next - global_position).normalized()
	var spd := stats.get_total_speed() * _get_phase_speed_mult()
	velocity = velocity.move_toward(dir * spd, 800.0 * delta)
	move_and_slide()

func _should_attack() -> bool:
	if target == null:
		return false
	return global_position.distance_to(target.global_position) < _get_attack_range()

## Override to return attack range for current phase.
func _get_attack_range() -> float:
	return 60.0

## Override to return speed multiplier for current phase.
func _get_phase_speed_mult() -> float:
	if current_phase < phase_thresholds.size():
		return phase_thresholds[current_phase].get("speed_mult", 1.0)
	return 1.0

# ─── ATTACK PATTERNS ─────────────────────────────────────────────────────────

## Override to build attack queue for current phase.
func _build_attack_queue() -> void:
	_attack_queue.clear()
	# Example: subclass adds specific attacks
	# _attack_queue = [_attack_slam, _attack_sweep, _attack_slam]

func _run_next_attack() -> void:
	if _attack_queue.is_empty():
		_build_attack_queue()
		return
	var next_attack: Callable = _attack_queue.pop_front()
	_is_attacking = true
	await next_attack.call()
	_is_attacking = false

## Example attack: telegraphed slam
func _attack_slam() -> void:
	sprite.play("slam_windup")
	await get_tree().create_timer(0.6).timeout
	sprite.play("slam")
	AudioManager.play_sfx("res://assets/audio/sfx/boss_slam.ogg", global_position)

	if target == null:
		return
	if global_position.distance_to(target.global_position) <= 80.0:
		var target_stats: StatsComponent = target.get_node_or_null("StatsComponent")
		if target_stats:
			target_stats.take_damage(stats.get_total_attack() * 2, &"physical", self)

	await get_tree().create_timer(0.4).timeout

# ─── PHASE TRANSITIONS ───────────────────────────────────────────────────────

func _on_health_changed(current: int, maximum: int) -> void:
	var ratio := float(current) / float(maximum)
	for i in phase_thresholds.size():
		var threshold: float = phase_thresholds[i].get("threshold", 0.0)
		if ratio <= threshold and current_phase <= i:
			_trigger_phase_transition(i + 1)
			break

func _trigger_phase_transition(new_phase: int) -> void:
	current_phase = new_phase
	boss_state = BossState.PHASE_TRANSITION
	_is_attacking = false

	# Brief cinematic pause
	Engine.time_scale = 0.2
	await get_tree().create_timer(0.5 * 0.2).timeout  # real time
	Engine.time_scale = 1.0

	# Flash and aura effect
	sprite.modulate = Color(2.0, 0.5, 0.0)
	await get_tree().create_timer(0.3).timeout
	sprite.modulate = Color.WHITE

	# Apply phase modifiers
	var phase_data: Dictionary = phase_thresholds[new_phase - 1] if new_phase <= phase_thresholds.size() else {}
	if phase_data.has("music"):
		EventBus.player_entered_region.emit(StringName(phase_data["music"]))

	# Heal to prevent skipping phases
	stats.current_health = maxi(stats.current_health, 1)
	_build_attack_queue()
	boss_state = BossState.COMBAT

# ─── DAMAGE ──────────────────────────────────────────────────────────────────

func _on_hurtbox_hit(area: Area2D) -> void:
	if stats.is_dead or stats.is_invincible or boss_state == BossState.INTRO:
		return
	if not area.has_meta("damage"):
		return
	var dmg: int = area.get_meta("damage", 5)
	var dmg_type: StringName = area.get_meta("damage_type", &"physical")
	stats.take_damage(dmg, dmg_type, area.get_parent())

# ─── DEATH ───────────────────────────────────────────────────────────────────

func _on_died() -> void:
	boss_state = BossState.DEAD
	set_physics_process(false)
	_is_attacking = false
	sprite.play("death")
	EventBus.enemy_killed.emit(&"boss", global_position)
	AudioManager.play_sfx("res://assets/audio/sfx/boss_death.ogg", global_position)

	await get_tree().create_timer(2.0).timeout
	# Spawn special loot, trigger chest, etc.
	_on_boss_defeated()
	queue_free()

func _on_boss_defeated() -> void:
	# Override in specific boss scripts to handle rewards, story events, etc.
	pass
