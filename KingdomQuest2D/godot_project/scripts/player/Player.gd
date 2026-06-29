## Player.gd
## The Player controller — the heart of the game.
##
## DESIGN: Implemented as a finite state machine (FSM). Each state is a
## discrete enum value. _physics_process calls the current state handler.
## Benefits: no spaghetti if/else chains, states are self-contained,
## adding a new state (mount, swimming) is a clean addition.
##
## Node structure expected:
##   Player (CharacterBody2D)
##   ├── StatsComponent
##   ├── AnimatedSprite2D        ← "sprite"
##   ├── CollisionShape2D
##   ├── HitboxComponent         ← sword attack hitbox (disabled by default)
##   ├── HurtboxComponent        ← receives incoming damage
##   ├── CoyoteTimer             ← Timer
##   ├── DodgeCooldownTimer      ← Timer
##   ├── ComboResetTimer         ← Timer
##   ├── InvincibilityTimer      ← Timer
##   ├── InteractionArea         ← Area2D
##   └── CameraArm              ← Node2D → Camera2D
##
class_name Player
extends CharacterBody2D

# ─── STATES ──────────────────────────────────────────────────────────────────

enum State {
	IDLE,
	MOVE,
	SPRINT,
	ATTACK,
	ATTACK_COMBO,
	BOW_AIM,
	MAGIC_CAST,
	DODGE,
	HURT,
	DEAD,
	INTERACT,
	DIALOGUE,
}

# ─── CONSTANTS ───────────────────────────────────────────────────────────────

const WALK_SPEED         := 120.0
const SPRINT_SPEED       := 190.0
const DODGE_SPEED        := 340.0
const DODGE_DURATION     := 0.28  # seconds of dodge movement
const DODGE_COOLDOWN     := 0.7
const DODGE_STAMINA_COST := 25.0
const SPRINT_STAMINA_RATE:= 12.0  # per second
const COMBO_WINDOW       := 0.5   # time to land next hit in combo
const ATTACK_STAM_COST   := 10.0
const HURT_DURATION      := 0.4
const INVINCIBILITY_TIME := 0.6

# ─── NODE REFS ───────────────────────────────────────────────────────────────

@onready var stats: StatsComponent       = $StatsComponent
@onready var sprite: AnimatedSprite2D    = $AnimatedSprite2D
@onready var hitbox: Area2D              = $HitboxComponent
@onready var hurtbox: Area2D             = $HurtboxComponent
@onready var interaction_area: Area2D    = $InteractionArea
@onready var combo_timer: Timer          = $ComboResetTimer
@onready var dodge_cooldown: Timer       = $DodgeCooldownTimer
@onready var invincibility_timer: Timer  = $InvincibilityTimer
@onready var camera: Camera2D            = $CameraArm/Camera2D

# ─── STATE VARS ──────────────────────────────────────────────────────────────

var current_state: State = State.IDLE
var _facing: Vector2 = Vector2.DOWN
var _dodge_direction: Vector2 = Vector2.ZERO
var _dodge_timer: float = 0.0
var _hurt_timer: float = 0.0
var _combo_count: int = 0
var _knockback: Vector2 = Vector2.ZERO
var _can_dodge: bool = true
var _interactable_in_range: Node = null

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	GameManager.player_node = self
	_connect_signals()
	hitbox.monitoring = false
	set_collision_layer_value(2, true)   # player layer
	set_collision_mask_value(1, true)    # world layer
	set_collision_mask_value(3, true)    # enemies layer
	EventBus.player_health_changed.emit(stats.current_health, stats.max_health)
	EventBus.player_mana_changed.emit(stats.current_mana, stats.max_mana)
	EventBus.player_stamina_changed.emit(stats.current_stamina, stats.max_stamina)

func _connect_signals() -> void:
	stats.health_changed.connect(func(c, m): EventBus.player_health_changed.emit(c, m))
	stats.mana_changed.connect(func(c, m): EventBus.player_mana_changed.emit(c, m))
	stats.stamina_changed.connect(func(c, f): EventBus.player_stamina_changed.emit(c, f))
	stats.died.connect(_on_died)
	hurtbox.area_entered.connect(_on_hurtbox_hit)
	interaction_area.body_entered.connect(_on_interactable_entered)
	interaction_area.body_exited.connect(_on_interactable_exited)
	interaction_area.area_entered.connect(_on_interactable_area_entered)
	interaction_area.area_exited.connect(_on_interactable_area_exited)
	dodge_cooldown.timeout.connect(func(): _can_dodge = true)

func _physics_process(delta: float) -> void:
	_apply_knockback(delta)

	match current_state:
		State.IDLE:         _state_idle(delta)
		State.MOVE:         _state_move(delta)
		State.SPRINT:       _state_sprint(delta)
		State.ATTACK:       _state_attack(delta)
		State.ATTACK_COMBO: _state_attack_combo(delta)
		State.BOW_AIM:      _state_bow_aim(delta)
		State.MAGIC_CAST:   _state_magic(delta)
		State.DODGE:        _state_dodge(delta)
		State.HURT:         _state_hurt(delta)
		State.DEAD:         pass
		State.DIALOGUE:     pass

	move_and_slide()

# ─── STATE HANDLERS ───────────────────────────────────────────────────────────

func _state_idle(_delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 800.0 * _delta)

	if InputManager.move_direction.length() > 0.1:
		_change_state(State.MOVE)
		return

	_check_common_actions()
	_play_directional_anim("idle")

func _state_move(delta: float) -> void:
	var dir := InputManager.move_direction
	if dir.length() < 0.1:
		_change_state(State.IDLE)
		return

	_facing = dir.normalized()
	var speed := stats.get_total_speed()
	velocity = velocity.move_toward(dir.normalized() * speed, 1200.0 * delta)

	if InputManager.is_action_pressed(&"sprint") and stats.has_stamina(SPRINT_STAMINA_RATE * delta):
		_change_state(State.SPRINT)
		return

	_check_common_actions()
	_play_directional_anim("walk")

func _state_sprint(delta: float) -> void:
	var dir := InputManager.move_direction
	if dir.length() < 0.1:
		_change_state(State.IDLE)
		return

	if not InputManager.is_action_pressed(&"sprint") or \
	   not stats.spend_stamina(SPRINT_STAMINA_RATE * delta):
		_change_state(State.MOVE)
		return

	_facing = dir.normalized()
	velocity = velocity.move_toward(dir.normalized() * SPRINT_SPEED, 1500.0 * delta)
	_check_common_actions()
	_play_directional_anim("run")

func _state_attack(_delta: float) -> void:
	# Handled by animation callbacks — see _on_attack_anim_finished()
	velocity = velocity.move_toward(Vector2.ZERO, 600.0 * _delta)

func _state_attack_combo(_delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 600.0 * _delta)
	if InputManager.is_action_just_pressed(&"attack") and _combo_count < 3:
		_start_next_combo()

func _state_bow_aim(delta: float) -> void:
	# Slow walk while aiming
	var dir := InputManager.move_direction
	velocity = velocity.move_toward(dir * 50.0, 400.0 * delta)
	_play_directional_anim("bow_aim")

	if InputManager.is_action_just_released(&"aim_bow"):
		_fire_arrow()
		_change_state(State.IDLE)

func _state_magic(_delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, 800.0 * _delta)

func _state_dodge(delta: float) -> void:
	_dodge_timer -= delta
	velocity = _dodge_direction * DODGE_SPEED
	_play_directional_anim("dodge")

	if _dodge_timer <= 0.0:
		stats.is_invincible = false
		sprite.modulate.a = 1.0
		invincibility_timer.stop()
		dodge_cooldown.start(DODGE_COOLDOWN)
		_change_state(State.IDLE)

func _state_hurt(delta: float) -> void:
	_hurt_timer -= delta
	velocity = velocity.move_toward(Vector2.ZERO, 500.0 * delta)
	if _hurt_timer <= 0.0:
		_change_state(State.IDLE)

# ─── COMMON ACTIONS (checked from multiple states) ────────────────────────────

func _check_common_actions() -> void:
	if InputManager.is_action_just_pressed(&"attack"):
		_start_attack()

	elif InputManager.is_action_just_pressed(&"dodge") and _can_dodge:
		_start_dodge()

	elif InputManager.is_action_pressed(&"aim_bow"):
		_change_state(State.BOW_AIM)

	elif InputManager.is_action_just_pressed(&"cast_magic"):
		_start_magic()

	elif InputManager.is_action_just_pressed(&"interact"):
		_try_interact()

# ─── ATTACK ──────────────────────────────────────────────────────────────────

func _start_attack() -> void:
	if not stats.spend_stamina(ATTACK_STAM_COST):
		return
	_combo_count = 1
	combo_timer.stop()
	_play_directional_anim("attack_1")
	hitbox.monitoring = true
	_change_state(State.ATTACK)
	AudioManager.play_sfx("res://assets/audio/sfx/player_sword_swing.ogg", global_position, 0.1)

func _start_next_combo() -> void:
	if not stats.spend_stamina(ATTACK_STAM_COST):
		return
	_combo_count += 1
	EventBus.combo_hit.emit(_combo_count)
	var anim := "attack_%d" % mini(_combo_count, 3)
	_play_directional_anim(anim)
	hitbox.monitoring = true

func _on_hitbox_connected(area: Area2D) -> void:
	# Called by HitboxComponent when it hits an enemy hurtbox
	if area.get_parent().is_in_group("enemies"):
		var is_crit := stats.roll_crit()
		var raw_dmg := stats.get_total_attack()
		if is_crit:
			raw_dmg = int(raw_dmg * stats.crit_multiplier)
		var target_stats: StatsComponent = area.get_parent().get_node_or_null("StatsComponent")
		if target_stats:
			target_stats.take_damage(raw_dmg, &"physical", self, is_crit)
			_spawn_damage_number(area.get_parent().global_position, raw_dmg, is_crit)
		AudioManager.play_sfx("res://assets/audio/sfx/hit_flesh.ogg", area.get_parent().global_position, 0.15)

# ─── DODGE ───────────────────────────────────────────────────────────────────

func _start_dodge() -> void:
	if not stats.spend_stamina(DODGE_STAMINA_COST):
		return

	_can_dodge = false
	_dodge_direction = InputManager.move_direction
	if _dodge_direction.length() < 0.1:
		_dodge_direction = _facing
	_dodge_direction = _dodge_direction.normalized()
	_dodge_timer = DODGE_DURATION

	# Grant invincibility frames for the first 80% of the dodge
	stats.is_invincible = true
	invincibility_timer.start(DODGE_DURATION * 0.8)

	# Visual: flash sprite semi-transparent during i-frames
	_flash_invincibility()
	_change_state(State.DODGE)
	AudioManager.play_sfx("res://assets/audio/sfx/player_dodge.ogg", global_position, 0.05)

func _flash_invincibility() -> void:
	var tween := create_tween().set_loops(5)
	tween.tween_property(sprite, "modulate:a", 0.3, 0.06)
	tween.tween_property(sprite, "modulate:a", 1.0, 0.06)

# ─── BOW & MAGIC ─────────────────────────────────────────────────────────────

func _fire_arrow() -> void:
	if not stats.has_stamina(20.0):
		return
	stats.spend_stamina(20.0)
	var arrow = ObjectPool.acquire("arrow", get_parent())
	if arrow == null:
		return
	arrow.global_position = global_position
	arrow.direction = InputManager.aim_direction if InputManager.aim_direction.length() > 0.1 else _facing
	arrow.damage = stats.get_total_attack()
	arrow.shooter = self
	AudioManager.play_sfx("res://assets/audio/sfx/bow_fire.ogg", global_position, 0.08)

func _start_magic() -> void:
	var spell_cost := 20
	if not stats.spend_mana(spell_cost):
		AudioManager.play_sfx("res://assets/audio/sfx/no_mana.ogg", global_position)
		return
	_change_state(State.MAGIC_CAST)
	_play_directional_anim("cast")
	var bolt = ObjectPool.acquire("magic_bolt", get_parent())
	if bolt:
		bolt.global_position = global_position
		bolt.direction = InputManager.aim_direction if InputManager.aim_direction.length() > 0.1 else _facing
		bolt.damage = int(stats.get_total_attack() * 1.4)
		bolt.shooter = self
	AudioManager.play_sfx("res://assets/audio/sfx/magic_cast.ogg", global_position, 0.05)
	await get_tree().create_timer(0.5).timeout
	if current_state == State.MAGIC_CAST:
		_change_state(State.IDLE)

# ─── INTERACTION ─────────────────────────────────────────────────────────────

func _try_interact() -> void:
	if _interactable_in_range == null:
		return
	if _interactable_in_range.has_method("interact"):
		_interactable_in_range.interact(self)

func _on_interactable_entered(body: Node2D) -> void:
	if body.has_method("interact"):
		_interactable_in_range = body

func _on_interactable_exited(body: Node2D) -> void:
	if _interactable_in_range == body:
		_interactable_in_range = null

func _on_interactable_area_entered(area: Area2D) -> void:
	if area.has_method("interact"):
		_interactable_in_range = area

func _on_interactable_area_exited(area: Area2D) -> void:
	if _interactable_in_range == area:
		_interactable_in_range = null

# ─── DAMAGE RECEPTION ────────────────────────────────────────────────────────

func _on_hurtbox_hit(area: Area2D) -> void:
	if stats.is_invincible or stats.is_dead:
		return
	if not area.has_meta("damage"):
		return
	var dmg: int = area.get_meta("damage", 10)
	var dmg_type: StringName = area.get_meta("damage_type", &"physical")
	var source: Node = area.get_parent()

	# Apply difficulty modifier
	dmg = int(dmg * GameManager.get_difficulty_modifier("damage_taken"))
	stats.take_damage(dmg, dmg_type, source)

	if not stats.is_dead:
		# Knockback away from source
		var knock_dir := (global_position - source.global_position).normalized()
		_knockback = knock_dir * 180.0
		_hurt_timer = HURT_DURATION
		_change_state(State.HURT)
		_flash_hurt()
		AudioManager.play_sfx("res://assets/audio/sfx/player_hurt.ogg", global_position, 0.1)

func _flash_hurt() -> void:
	sprite.modulate = Color(1.0, 0.3, 0.3)
	await get_tree().create_timer(0.15).timeout
	sprite.modulate = Color.WHITE

func _apply_knockback(delta: float) -> void:
	if _knockback.length() < 1.0:
		return
	velocity += _knockback
	_knockback = _knockback.move_toward(Vector2.ZERO, 600.0 * delta)

# ─── DEATH ───────────────────────────────────────────────────────────────────

func _on_died() -> void:
	_change_state(State.DEAD)
	hitbox.monitoring = false
	hurtbox.monitoring = false
	sprite.play("death")
	InputManager.disable_input()
	await get_tree().create_timer(1.5).timeout
	EventBus.player_died.emit()

# ─── ANIMATION ───────────────────────────────────────────────────────────────

## Append directional suffix: _up, _down, _left, _right
func _play_directional_anim(base: String) -> void:
	var dir_suffix := _get_dir_suffix()
	var anim_name := base + dir_suffix
	if sprite.sprite_frames and sprite.sprite_frames.has_animation(anim_name):
		sprite.play(anim_name)
	elif sprite.sprite_frames and sprite.sprite_frames.has_animation(base):
		sprite.play(base)

func _get_dir_suffix() -> String:
	if abs(_facing.x) > abs(_facing.y):
		return "_right" if _facing.x > 0 else "_left"
	return "_down" if _facing.y > 0 else "_up"

func _on_animation_finished() -> void:
	match sprite.animation:
		"attack_1", "attack_2", "attack_3":
			hitbox.monitoring = false
			if _combo_count < 3:
				_change_state(State.ATTACK_COMBO)
				combo_timer.start(COMBO_WINDOW)
			else:
				_combo_count = 0
				_change_state(State.IDLE)
		"cast":
			_change_state(State.IDLE)
		"hurt":
			_change_state(State.IDLE)

# ─── DAMAGE NUMBERS ──────────────────────────────────────────────────────────

func _spawn_damage_number(pos: Vector2, value: int, is_crit: bool) -> void:
	var dn = ObjectPool.acquire("damage_number", get_parent())
	if dn and dn.has_method("show_damage"):
		dn.global_position = pos
		dn.show_damage(value, is_crit)

# ─── STATE CHANGE ────────────────────────────────────────────────────────────

func _change_state(new_state: State) -> void:
	if current_state == new_state:
		return
	_exit_state(current_state)
	current_state = new_state
	_enter_state(new_state)

func _exit_state(state: State) -> void:
	match state:
		State.ATTACK, State.ATTACK_COMBO:
			hitbox.monitoring = false
		State.DODGE:
			stats.is_invincible = false
			sprite.modulate.a = 1.0

func _enter_state(state: State) -> void:
	match state:
		State.DIALOGUE:
			InputManager.disable_input()
			velocity = Vector2.ZERO
		State.IDLE:
			InputManager.enable_input()
		State.DEAD:
			InputManager.disable_input()

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	return {
		"player": {
			"position": { "x": global_position.x, "y": global_position.y },
			"facing":   { "x": _facing.x, "y": _facing.y },
			"stats":    stats.get_save_data(),
		}
	}

func apply_save_data(data: Dictionary) -> void:
	var pdata: Dictionary = data.get("player", {})
	if pdata.has("position"):
		global_position = Vector2(pdata["position"]["x"], pdata["position"]["y"])
	if pdata.has("facing"):
		_facing = Vector2(pdata["facing"]["x"], pdata["facing"]["y"])
	if pdata.has("stats"):
		stats.apply_save_data(pdata["stats"])
