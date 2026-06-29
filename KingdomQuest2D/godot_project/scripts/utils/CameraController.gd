## CameraController.gd
## Smooth follow camera with screen shake, zoom, and room-transition locking.
##
## DESIGN: Attached to the Camera2D node inside Player.tscn's CameraArm.
## All external systems call shake() / zoom_to() — they never touch Camera2D directly.
## Screen shake uses a noise offset (more organic than simple random displacement).
##
class_name CameraController
extends Camera2D

# ─── CONFIG ──────────────────────────────────────────────────────────────────

@export var follow_speed: float    = 8.0    # Lerp factor for smooth follow
@export var default_zoom: Vector2  = Vector2(2.0, 2.0)  # Pixel art 2× zoom
@export var zoom_speed: float      = 5.0

# ─── SHAKE STATE ─────────────────────────────────────────────────────────────

var _shake_intensity: float = 0.0
var _shake_duration: float  = 0.0
var _shake_elapsed: float   = 0.0
var _shake_noise: FastNoiseLite

# ─── ZOOM STATE ──────────────────────────────────────────────────────────────

var _target_zoom: Vector2 = Vector2(2.0, 2.0)

# ─── LIMITS ──────────────────────────────────────────────────────────────────

var _use_limits: bool = false
var _limit_rect: Rect2 = Rect2()

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	zoom = default_zoom
	_target_zoom = default_zoom

	_shake_noise = FastNoiseLite.new()
	_shake_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_shake_noise.seed = randi()
	_shake_noise.frequency = 0.3

	# Connect to relevant events
	EventBus.player_died.connect(func(): zoom_to(Vector2(1.8, 1.8)))
	EventBus.player_leveled_up.connect(func(_lv): _pulse_zoom())

func _process(delta: float) -> void:
	_update_zoom(delta)
	_update_shake(delta)

# ─── SMOOTH FOLLOW ───────────────────────────────────────────────────────────
## The CameraArm node moves with the player; Camera2D follows it smoothly.
## This is handled by the CameraArm's script or the player's _physics_process.
## If standalone follow is needed:

func follow_target(target: Node2D, delta: float) -> void:
	if target == null:
		return
	global_position = global_position.lerp(target.global_position, follow_speed * delta)

# ─── SCREEN SHAKE ────────────────────────────────────────────────────────────

## Call from any script: CameraController.shake(8.0, 0.3)
func shake(intensity: float, duration: float) -> void:
	_shake_intensity = intensity
	_shake_duration  = duration
	_shake_elapsed   = 0.0

func _update_shake(delta: float) -> void:
	if _shake_elapsed >= _shake_duration:
		offset = Vector2.ZERO
		return
	_shake_elapsed += delta
	var t := _shake_elapsed * 30.0
	var decay := 1.0 - (_shake_elapsed / _shake_duration)
	offset = Vector2(
		_shake_noise.get_noise_2d(t, 0.0),
		_shake_noise.get_noise_2d(0.0, t)
	) * _shake_intensity * decay

# ─── ZOOM ────────────────────────────────────────────────────────────────────

func zoom_to(new_zoom: Vector2, instant: bool = false) -> void:
	_target_zoom = new_zoom
	if instant:
		zoom = new_zoom

func reset_zoom() -> void:
	_target_zoom = default_zoom

func _update_zoom(delta: float) -> void:
	zoom = zoom.lerp(_target_zoom, zoom_speed * delta)

func _pulse_zoom() -> void:
	var original := _target_zoom
	zoom_to(original * 0.9)
	await get_tree().create_timer(0.2).timeout
	zoom_to(original)

# ─── ROOM LIMITS ─────────────────────────────────────────────────────────────

## Call this when entering a bounded area (dungeon room, village bounds)
func set_limits(rect: Rect2) -> void:
	_use_limits = true
	_limit_rect = rect
	limit_left   = int(rect.position.x)
	limit_top    = int(rect.position.y)
	limit_right  = int(rect.end.x)
	limit_bottom = int(rect.end.y)

func clear_limits() -> void:
	_use_limits = false
	limit_left   = -10000000
	limit_top    = -10000000
	limit_right  =  10000000
	limit_bottom =  10000000

# ─── CONVENIENCE STATIC ──────────────────────────────────────────────────────

static func get_camera() -> CameraController:
	if GameManager.player_node == null:
		return null
	return GameManager.player_node.get_node_or_null("CameraArm/Camera2D") as CameraController
