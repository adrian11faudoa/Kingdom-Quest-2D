## EnemyBase.gd
## Base class for all enemies. Implements a state machine AI with
## NavigationAgent2D pathfinding, aggro detection, and combat behaviors.
##
## DESIGN: EnemyBase provides the FSM scaffold and common behaviors.
## Specific enemy archetypes (Melee, Ranged, Tank, Flying, Summoner)
## extend this class and override only what differs.
## Data (hp, speed, damage) comes from DataManager, not hardcoded here.
##
class_name EnemyBase
extends CharacterBody2D

# ─── AI STATES ───────────────────────────────────────────────────────────────

enum AIState {
	IDLE,        # Standing still, no player detected
	PATROL,      # Following patrol waypoints
	ALERT,       # Heard/saw something — moving to investigate
	CHASE,       # Player in aggro range — pursuing
	ATTACK,      # In attack range — executing attack
	STAGGER,     # Hit — brief stun
	FLEE,        # Low health — running away
	DEAD,
}

# ─── CONFIGURATION (overridden from DataManager data) ─────────────────────────

@export var enemy_id: StringName = &"goblin"
@export var detect_radius: float   = 150.0
@export var attack_radius: float   = 40.0
@export var patrol_speed: float    = 50.0
@export var alert_speed: float     = 80.0
@export var chase_speed: float     = 110.0
@export var attack_cooldown: float = 1.5
@export var stagger_duration: float = 0.3
@export var flee_health_threshold: float = 0.2  # 20% hp
@export var patrol_points: Array[Vector2] = []

# ─── NODE REFS ───────────────────────────────────────────────────────────────

@onready var stats: StatsComponent       = $StatsComponent
@onready var sprite: AnimatedSprite2D    = $AnimatedSprite2D
@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D
@onready var hitbox: Area2D              = $HitboxComponent
@onready var hurtbox: Area2D             = $HurtboxComponent
@onready var detection_area: Area2D      = $DetectionArea
@onready var attack_area: Area2D         = $AttackArea
@onready var stagger_timer: Timer        = $StaggerTimer
@onready var attack_timer: Timer         = $AttackTimer
@onready var loot_table_component: Node  = $LootTableComponent

# ─── RUNTIME STATE ───────────────────────────────────────────────────────────

var ai_state: AIState = AIState.IDLE
var target: Node = null            # Current combat target (usually Player)
var _patrol_index: int = 0
var _last_known_position: Vector2 = Vector2.ZERO
var _can_attack: bool = true
var _stagger_remaining: float = 0.0
var _spawn_position: Vector2 = Vector2.ZERO

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	_spawn_position = global_position
	add_to_group("enemies")
	_load_from_data()
	_connect_signals()

func _load_from_data() -> void:
	var data := DataManager.get_enemy(enemy_id)
	if data.is_empty():
		push_warning("[EnemyBase] No data for enemy: %s" % enemy_id)
		return
	stats.max_health    = data.get("max_health",   50)
	stats.base_attack   = data.get("attack",        8)
	stats.base_defense  = data.get("defense",       2)
	stats.base_speed    = data.get("speed",       100.0)
	detect_radius       = data.get("detect_radius", 150.0)
	attack_radius       = data.get("attack_radius",  40.0)
	attack_cooldown     = data.get("attack_cooldown", 1.5)
	stats.xp_reward     = data.get("xp_reward",     20)
	# Reset stats after loading
	stats.current_health = stats.max_health

func _connect_signals() -> void:
	stats.died.connect(_on_died)
	stats.health_changed.connect(_on_health_changed)
	hurtbox.area_entered.connect(_on_hurtbox_hit)
	detection_area.body_entered.connect(_on_detection_entered)
	detection_area.body_exited.connect(_on_detection_exited)
	attack_timer.timeout.connect(func(): _can_attack = true)
	stagger_timer.timeout.connect(func(): _change_ai_state(AIState.CHASE if target else AIState.IDLE))

func _physics_process(delta: float) -> void:
	if ai_state == AIState.DEAD:
		return
	_run_ai(delta)
	move_and_slide()

# ─── AI MAIN LOOP ────────────────────────────────────────────────────────────

func _run_ai(delta: float) -> void:
	match ai_state:
		AIState.IDLE:     _ai_idle(delta)
		AIState.PATROL:   _ai_patrol(delta)
		AIState.ALERT:    _ai_alert(delta)
		AIState.CHASE:    _ai_chase(delta)
		AIState.ATTACK:   _ai_attack(delta)
		AIState.STAGGER:  _ai_stagger(delta)
		AIState.FLEE:     _ai_flee(delta)

func _ai_idle(_delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 400.0)
	sprite.play("idle")
	if not patrol_points.is_empty():
		_change_ai_state(AIState.PATROL)

func _ai_patrol(delta: float) -> void:
	if patrol_points.is_empty():
		_change_ai_state(AIState.IDLE)
		return
	var target_point := patrol_points[_patrol_index]
	_move_toward_position(target_point, patrol_speed, delta)
	sprite.play("walk")
	if global_position.distance_to(target_point) < 8.0:
		_patrol_index = (_patrol_index + 1) % patrol_points.size()

func _ai_alert(_delta: float) -> void:
	# Move toward last known position
	_move_toward_position(_last_known_position, alert_speed, _delta)
	sprite.play("walk")
	if global_position.distance_to(_last_known_position) < 16.0:
		_change_ai_state(AIState.IDLE)

func _ai_chase(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		_change_ai_state(AIState.ALERT)
		return

	var dist := global_position.distance_to(target.global_position)
	if dist <= attack_radius:
		_change_ai_state(AIState.ATTACK)
		return

	# Loose chase: stop chasing if very far away
	if dist > detect_radius * 2.5:
		target = null
		_change_ai_state(AIState.ALERT)
		return

	_move_toward_position(target.global_position, stats.get_total_speed(), delta)
	sprite.play("walk")
	_last_known_position = target.global_position

func _ai_attack(_delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 600.0)
	if target == null or not is_instance_valid(target):
		_change_ai_state(AIState.IDLE)
		return

	var dist := global_position.distance_to(target.global_position)
	if dist > attack_radius * 1.3:
		_change_ai_state(AIState.CHASE)
		return

	if _can_attack:
		_execute_attack()

func _ai_stagger(_delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 800.0)

func _ai_flee(delta: float) -> void:
	if target == null:
		_change_ai_state(AIState.IDLE)
		return
	# Move away from player
	var flee_dir := (global_position - target.global_position).normalized()
	_move_toward_position(global_position + flee_dir * 100.0, stats.get_total_speed() * 1.2, delta)

# ─── MOVEMENT ────────────────────────────────────────────────────────────────

func _move_toward_position(target_pos: Vector2, speed: float, _delta: float) -> void:
	nav_agent.target_position = target_pos
	if nav_agent.is_navigation_finished():
		velocity = velocity.move_toward(Vector2.ZERO, 400.0)
		return
	var next := nav_agent.get_next_path_position()
	var direction := (next - global_position).normalized()
	velocity = velocity.move_toward(direction * speed, 1000.0 * _delta)
	_update_facing(direction)

func _update_facing(direction: Vector2) -> void:
	if abs(direction.x) > 0.1:
		sprite.flip_h = direction.x < 0.0

# ─── ATTACK ──────────────────────────────────────────────────────────────────

## Override in subclasses for different attack behaviors.
func _execute_attack() -> void:
	_can_attack = false
	attack_timer.start(attack_cooldown)
	sprite.play("attack")

	# Melee default — deal damage to nearby player
	if target and is_instance_valid(target):
		var target_stats: StatsComponent = target.get_node_or_null("StatsComponent")
		if target_stats and global_position.distance_to(target.global_position) <= attack_radius * 1.1:
			var dmg := stats.get_total_attack()
			target_stats.take_damage(dmg, &"physical", self)
			AudioManager.play_sfx("res://assets/audio/sfx/enemy_attack.ogg", global_position, 0.1)

# ─── DETECTION ───────────────────────────────────────────────────────────────

func _on_detection_entered(body: Node2D) -> void:
	if body.is_in_group("player") and ai_state in [AIState.IDLE, AIState.PATROL, AIState.ALERT]:
		target = body
		_last_known_position = body.global_position
		_change_ai_state(AIState.CHASE)
		AudioManager.notify_enemy_nearby(true)

func _on_detection_exited(body: Node2D) -> void:
	if body == target:
		_last_known_position = target.global_position
		# Don't immediately lose aggro — go to alert state
		if ai_state == AIState.CHASE:
			_change_ai_state(AIState.ALERT)
		AudioManager.notify_enemy_nearby(false)

# ─── DAMAGE RECEPTION ────────────────────────────────────────────────────────

func _on_hurtbox_hit(area: Area2D) -> void:
	if stats.is_dead or stats.is_invincible:
		return
	if not area.has_meta("damage"):
		return

	var dmg: int = area.get_meta("damage", 5)
	var dmg_type: StringName = area.get_meta("damage_type", &"physical")
	stats.take_damage(dmg, dmg_type, area.get_parent())

	if not stats.is_dead:
		_trigger_stagger()
		_flash_hit()

		# Aggro the attacker
		if target == null and area.get_parent().is_in_group("player"):
			target = area.get_parent()
			_change_ai_state(AIState.CHASE)

func _trigger_stagger() -> void:
	_change_ai_state(AIState.STAGGER)
	stagger_timer.start(stagger_duration)

func _flash_hit() -> void:
	sprite.modulate = Color(1.5, 0.5, 0.5)
	await get_tree().create_timer(0.1).timeout
	if is_instance_valid(self):
		sprite.modulate = Color.WHITE

func _on_health_changed(current: int, maximum: int) -> void:
	# Check flee threshold
	if float(current) / float(maximum) <= flee_health_threshold and \
	   ai_state not in [AIState.FLEE, AIState.DEAD]:
		_change_ai_state(AIState.FLEE)

# ─── DEATH ───────────────────────────────────────────────────────────────────

func _on_died() -> void:
	_change_ai_state(AIState.DEAD)
	hitbox.monitoring  = false
	hurtbox.monitoring = false
	set_physics_process(false)
	sprite.play("death")

	EventBus.enemy_killed.emit(enemy_id, global_position)

	# Drop loot
	if loot_table_component and loot_table_component.has_method("spawn_loot"):
		loot_table_component.spawn_loot(global_position)

	AudioManager.play_sfx("res://assets/audio/sfx/enemy_death.ogg", global_position, 0.15)

	await sprite.animation_finished
	queue_free()

# ─── STATE CHANGE ────────────────────────────────────────────────────────────

func _change_ai_state(new_state: AIState) -> void:
	if ai_state == new_state or ai_state == AIState.DEAD:
		return
	ai_state = new_state
