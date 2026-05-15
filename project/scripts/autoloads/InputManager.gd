## InputManager.gd
## Unified input layer that abstracts keyboard/mouse and controller input.
##
## DESIGN: Game code never reads Input directly. It reads from InputManager.
## This means: remappable controls, consistent deadzone handling,
## controller aim assist, and easy input recording/replay for testing.
##
extends Node

# ─── STATE ───────────────────────────────────────────────────────────────────

var using_controller: bool = false
var _input_disabled: bool = false

# Cached this frame to avoid redundant Input calls
var move_direction: Vector2 = Vector2.ZERO
var aim_direction: Vector2 = Vector2.ZERO
var is_attacking: bool = false
var is_dodging: bool = false
var is_sprinting: bool = false

const CONTROLLER_DEADZONE := 0.2
const AIM_STICK_INDEX_X := 2  # Right stick X
const AIM_STICK_INDEX_Y := 3  # Right stick Y

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	Input.joy_connection_changed.connect(_on_joy_connection_changed)

func _process(_delta: float) -> void:
	if _input_disabled:
		move_direction = Vector2.ZERO
		aim_direction  = Vector2.ZERO
		return

	_update_device_detection()
	_update_movement()
	_update_aim()

func _update_device_detection() -> void:
	# Switch to keyboard if any keyboard input detected
	if Input.is_action_just_pressed("move_up") or \
	   Input.is_action_just_pressed("move_down") or \
	   Input.is_action_just_pressed("move_left") or \
	   Input.is_action_just_pressed("move_right"):
		using_controller = false

func _update_movement() -> void:
	move_direction = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if move_direction.length() < CONTROLLER_DEADZONE:
		move_direction = Vector2.ZERO
	else:
		move_direction = move_direction.normalized() * \
			((move_direction.length() - CONTROLLER_DEADZONE) / (1.0 - CONTROLLER_DEADZONE))

func _update_aim() -> void:
	if using_controller:
		# Right stick aim
		var rx := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
		var ry := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
		var stick := Vector2(rx, ry)
		if stick.length() > CONTROLLER_DEADZONE:
			aim_direction = stick.normalized()
	else:
		# Mouse aim — direction from player to mouse
		if GameManager.player_node != null:
			var mouse_pos := GameManager.player_node.get_global_mouse_position()
			var player_pos := GameManager.player_node.global_position
			var delta := mouse_pos - player_pos
			if delta.length() > 4.0:
				aim_direction = delta.normalized()

# ─── PUBLIC ACTIONS ──────────────────────────────────────────────────────────

func is_action_pressed(action: StringName) -> bool:
	if _input_disabled:
		return false
	return Input.is_action_pressed(action)

func is_action_just_pressed(action: StringName) -> bool:
	if _input_disabled:
		return false
	return Input.is_action_just_pressed(action)

func is_action_just_released(action: StringName) -> bool:
	if _input_disabled:
		return false
	return Input.is_action_just_released(action)

func disable_input() -> void:
	_input_disabled = true
	move_direction = Vector2.ZERO

func enable_input() -> void:
	_input_disabled = false

# ─── CALLBACKS ───────────────────────────────────────────────────────────────

func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if device == 0:
		using_controller = connected
		print("[InputManager] Controller %s" % ("connected" if connected else "disconnected"))
