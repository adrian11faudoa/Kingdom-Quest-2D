## MountSystem.gd
## Manages player mounting/dismounting rideable creatures.
## When mounted: speed bonus, different animations, some abilities disabled.
##
class_name MountSystem
extends Node

const MOUNT_SCENES: Dictionary = {
	&"horse":   "res://scenes/entities/companions/HorseMount.tscn",
	&"elk":     "res://scenes/entities/companions/ElkMount.tscn",
}

const MOUNT_SPEED_BONUS := 80.0  # Added to player base speed
const MOUNT_STAMINA_DRAIN := 0.0  # Mounts don't drain stamina to run

var is_mounted: bool = false
var current_mount_id: StringName = &""
var _mount_node: Node = null
var _player: Node = null

# ─── SIGNALS ─────────────────────────────────────────────────────────────────
signal mounted(mount_id: StringName)
signal dismounted()

func _ready() -> void:
	_player = get_parent()
	SaveManager.register_system(get_save_data, apply_save_data)

# ─── MOUNT / DISMOUNT ────────────────────────────────────────────────────────

func mount(mount_id: StringName) -> bool:
	if is_mounted:
		return false
	if not MOUNT_SCENES.has(mount_id):
		return false

	var scene_path: String = MOUNT_SCENES[mount_id]
	if not ResourceLoader.exists(scene_path):
		return false

	# Spawn mount and attach to player
	_mount_node = load(scene_path).instantiate()
	get_tree().current_scene.add_child(_mount_node)
	_mount_node.global_position = _player.global_position

	is_mounted         = true
	current_mount_id   = mount_id

	# Apply speed bonus to player stats
	var stats: StatsComponent = _player.get_node_or_null("StatsComponent")
	if stats:
		stats.add_speed_bonus(MOUNT_SPEED_BONUS)

	# Disable dodge (can't roll while mounted)
	if _player.has_method("set_can_dodge"):
		_player.set_can_dodge(false)

	mounted.emit(mount_id)
	AudioManager.play_sfx("res://assets/audio/sfx/mount.ogg",
		_player.global_position)
	print("[MountSystem] Mounted: %s" % mount_id)
	return true

func dismount() -> void:
	if not is_mounted:
		return

	# Remove speed bonus
	var stats: StatsComponent = _player.get_node_or_null("StatsComponent")
	if stats:
		stats.add_speed_bonus(-MOUNT_SPEED_BONUS)

	if _player.has_method("set_can_dodge"):
		_player.set_can_dodge(true)

	if _mount_node and is_instance_valid(_mount_node):
		# Drop mount nearby
		_mount_node.global_position = _player.global_position + Vector2(40, 0)

	is_mounted       = false
	current_mount_id = &""
	_mount_node      = null

	dismounted.emit()
	AudioManager.play_sfx("res://assets/audio/sfx/dismount.ogg",
		_player.global_position)

func toggle_mount(mount_id: StringName) -> void:
	if is_mounted:
		dismount()
	else:
		mount(mount_id)

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	return {
		"mount": {
			"is_mounted": is_mounted,
			"mount_id":   str(current_mount_id),
		}
	}

func apply_save_data(data: Dictionary) -> void:
	var d: Dictionary = data.get("mount", {})
	if d.get("is_mounted", false):
		call_deferred("mount", StringName(d.get("mount_id", "")))
