## CompanionAI.gd
## Base AI for companions — follow player, assist in combat, use abilities.
## Attach to any companion scene. Override _execute_ability() per companion.
##
class_name CompanionAI
extends CharacterBody2D

enum State { FOLLOW, COMBAT, ABILITY, IDLE }

@export var companion_id: StringName = &"fox"
@export var follow_distance: float  = 60.0   # Preferred gap from player
@export var combat_radius: float    = 120.0
@export var attack_damage: int      = 8
@export var attack_cooldown: float  = 2.0
@export var ability_cooldown: float = 15.0

@onready var sprite: AnimatedSprite2D     = $AnimatedSprite2D
@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D
@onready var attack_timer: Timer          = $AttackTimer
@onready var ability_timer: Timer         = $AbilityTimer

var ai_state: State = State.FOLLOW
var _target_enemy: Node = null
var _can_attack: bool   = true
var _can_ability: bool  = true

func _ready() -> void:
	add_to_group("companions")
	attack_timer.wait_time  = attack_cooldown
	ability_timer.wait_time = ability_cooldown
	attack_timer.timeout.connect(func(): _can_attack = true)
	ability_timer.timeout.connect(func(): _can_ability = true)

func _physics_process(delta: float) -> void:
	_scan_for_enemies()
	match ai_state:
		State.FOLLOW:  _follow_player(delta)
		State.COMBAT:  _combat_loop(delta)
		State.IDLE:    velocity = velocity.move_toward(Vector2.ZERO, 400.0 * delta)
	move_and_slide()

func _follow_player(delta: float) -> void:
	if GameManager.player_node == null:
		return
	var player_pos := GameManager.player_node.global_position
	var dist := global_position.distance_to(player_pos)
	if dist < follow_distance:
		velocity = velocity.move_toward(Vector2.ZERO, 500.0 * delta)
		sprite.play("idle")
		return
	_move_toward(player_pos, 100.0, delta)
	sprite.play("walk")

func _combat_loop(delta: float) -> void:
	if _target_enemy == null or not is_instance_valid(_target_enemy):
		_target_enemy = null
		ai_state = State.FOLLOW
		return
	var dist := global_position.distance_to(_target_enemy.global_position)
	if dist < 48.0 and _can_attack:
		_attack_enemy()
	elif dist >= 48.0:
		_move_toward(_target_enemy.global_position, 110.0, delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, 400.0 * delta)
	sprite.play("walk")

func _scan_for_enemies() -> void:
	if _target_enemy != null and is_instance_valid(_target_enemy):
		return
	var enemies := get_tree().get_nodes_in_group("enemies")
	var closest_dist := combat_radius
	_target_enemy = null
	if GameManager.player_node == null:
		return
	for enemy in enemies:
		var d := GameManager.player_node.global_position.distance_to(enemy.global_position)
		if d < closest_dist:
			closest_dist = d
			_target_enemy = enemy
	ai_state = State.COMBAT if _target_enemy != null else State.FOLLOW

func _attack_enemy() -> void:
	_can_attack = false
	attack_timer.start()
	sprite.play("attack")
	if _target_enemy and is_instance_valid(_target_enemy):
		var target_stats: StatsComponent = _target_enemy.get_node_or_null("StatsComponent")
		if target_stats:
			target_stats.take_damage(attack_damage, &"physical", self)

func use_ability() -> void:
	if not _can_ability:
		return
	_can_ability = false
	ability_timer.start()
	ai_state = State.ABILITY
	_execute_ability()
	EventBus.companion_ability_used.emit(companion_id, &"main_ability")

## Override per companion
func _execute_ability() -> void:
	# Base: heal the player a little
	if GameManager.player_node:
		var s: StatsComponent = GameManager.player_node.get_node_or_null("StatsComponent")
		if s:
			s.heal(20)
	await get_tree().create_timer(1.0).timeout
	ai_state = State.FOLLOW

func _move_toward(target_pos: Vector2, speed: float, delta: float) -> void:
	nav_agent.target_position = target_pos
	if nav_agent.is_navigation_finished():
		return
	var next := nav_agent.get_next_path_position()
	var dir  := (next - global_position).normalized()
	velocity  = velocity.move_toward(dir * speed, 800.0 * delta)
	sprite.flip_h = dir.x < 0
