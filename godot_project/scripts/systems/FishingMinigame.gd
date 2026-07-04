## FishingMinigame.gd
## Classic action fishing: cast → wait → react → reel in.
## Three-phase: CASTING, WAITING, REELING.
##
class_name FishingMinigame
extends Node

enum Phase { IDLE, CASTING, WAITING, BITING, REELING, DONE }

signal fish_caught(fish_id: StringName, rarity: StringName)
signal fish_escaped()
signal minigame_ended()

## Reeling mini-game: player must hold a moving indicator in a target zone.
@export var reel_duration: float = 4.0
@export var bite_window: float   = 0.8    # seconds to react to bite
@export var min_wait: float      = 2.0
@export var max_wait: float      = 12.0

var phase: Phase = Phase.IDLE
var _indicator_pos: float  = 0.5   # 0.0–1.0
var _target_zone_pos: float = 0.5
var _target_zone_size: float = 0.2
var _reel_timer: float = 0.0
var _fish_tension: float = 0.0
var _fish_id: StringName = &""

# ─── FISH TABLES ─────────────────────────────────────────────────────────────

## Region → list of { id, weight, rarity }
const FISH_TABLES: Dictionary = {
	&"default": [
		{ "id": &"common_carp",   "weight": 60, "rarity": &"common"   },
		{ "id": &"silver_trout",  "weight": 25, "rarity": &"uncommon" },
		{ "id": &"golden_bass",   "weight": 10, "rarity": &"rare"     },
		{ "id": &"shadow_eel",    "weight":  4, "rarity": &"epic"     },
		{ "id": &"dragon_fang_fish","weight":1, "rarity": &"legendary"},
	],
}

# ─── CONTROL ─────────────────────────────────────────────────────────────────

func start_fishing(region: StringName = &"default") -> void:
	if phase != Phase.IDLE:
		return
	InputManager.disable_input()
	phase = Phase.CASTING
	EventBus.fishing_started.emit()
	_cast(region)

func _cast(region: StringName) -> void:
	phase = Phase.CASTING
	await get_tree().create_timer(0.5).timeout
	phase = Phase.WAITING
	var wait_time := randf_range(min_wait, max_wait)
	await get_tree().create_timer(wait_time).timeout
	if phase == Phase.WAITING:
		_fish_id = _roll_fish(region)
		_start_bite()

func _start_bite() -> void:
	phase = Phase.BITING
	# Player must press interact within bite_window
	AudioManager.play_sfx_ui("res://assets/audio/sfx/fishing_bite.ogg")
	await get_tree().create_timer(bite_window).timeout
	if phase == Phase.BITING:
		# Missed! Fish got away
		_end_fishing(false)

func _start_reeling() -> void:
	phase = Phase.REELING
	_reel_timer = reel_duration
	_indicator_pos   = 0.5
	_target_zone_pos = randf_range(0.15, 0.85)
	_fish_tension    = 0.0
	AudioManager.play_sfx_ui("res://assets/audio/sfx/fishing_reel.ogg")

func _process(delta: float) -> void:
	if phase != Phase.REELING:
		return
	_reel_timer -= delta

	# Fish pulls indicator randomly
	_indicator_pos += (randf() - 0.6) * delta * 1.5
	_indicator_pos  = clampf(_indicator_pos, 0.0, 1.0)

	# Player holds interact to pull indicator toward target
	if InputManager.is_action_pressed(&"interact"):
		_indicator_pos = move_toward(_indicator_pos, _target_zone_pos, delta * 0.6)

	# Tension: fish escapes if indicator leaves zone too long
	var in_zone := absf(_indicator_pos - _target_zone_pos) < _target_zone_size * 0.5
	if in_zone:
		_fish_tension = maxf(0.0, _fish_tension - delta * 0.4)
	else:
		_fish_tension += delta * 0.5

	if _fish_tension >= 1.0 or _reel_timer <= 0.0:
		var success := _fish_tension < 1.0
		_end_fishing(success)

func handle_input_bite() -> void:
	if phase == Phase.BITING:
		_start_reeling()

func _end_fishing(success: bool) -> void:
	phase = Phase.DONE
	InputManager.enable_input()
	if success:
		var rarity := _get_rarity(_fish_id)
		EventBus.fishing_catch.emit(_fish_id, rarity)
		fish_caught.emit(_fish_id, rarity)
		# Add to player inventory
		var inventory := get_tree().get_first_node_in_group("inventory") as InventorySystem
		if inventory:
			inventory.add_item(_fish_id, 1)
		AudioManager.play_sfx_ui("res://assets/audio/sfx/fishing_success.ogg")
	else:
		fish_escaped.emit()
		AudioManager.play_sfx_ui("res://assets/audio/sfx/fishing_fail.ogg")

	EventBus.fishing_ended.emit()
	minigame_ended.emit()
	await get_tree().create_timer(0.5).timeout
	phase = Phase.IDLE

# ─── HELPERS ─────────────────────────────────────────────────────────────────

func _roll_fish(region: StringName) -> StringName:
	var table: Array = FISH_TABLES.get(region, FISH_TABLES[&"default"])
	var total_weight := 0
	for entry in table:
		total_weight += entry["weight"]
	var roll := randi() % total_weight
	var cumulative := 0
	for entry in table:
		cumulative += entry["weight"]
		if roll < cumulative:
			return entry["id"]
	return table[0]["id"]

func _get_rarity(fish_id: StringName) -> StringName:
	for region_table in FISH_TABLES.values():
		for entry in region_table:
			if entry["id"] == fish_id:
				return entry["rarity"]
	return &"common"
