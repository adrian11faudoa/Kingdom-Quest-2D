## WorldEventSystem.gd
## Triggers random world events: ambushes, wandering merchants, meteor showers, etc.
## Events fire based on time elapsed, region, and player level.
##
class_name WorldEventSystem
extends Node

# ─── EVENT DEFINITIONS ───────────────────────────────────────────────────────

const EVENTS: Array = [
	{
		"id":         "goblin_ambush",
		"name":       "Goblin Ambush!",
		"weight":     30,
		"min_level":  1,
		"regions":    ["overworld", "forest"],
		"type":       "spawn_enemies",
		"enemies":    [{ "id": "goblin", "count": 3 }, { "id": "goblin_archer", "count": 1 }],
		"cooldown":   300.0,
	},
	{
		"id":         "wandering_merchant",
		"name":       "Wandering Merchant",
		"weight":     15,
		"min_level":  1,
		"regions":    ["overworld"],
		"type":       "spawn_npc",
		"npc_id":     "wandering_merchant",
		"duration":   120.0,
		"cooldown":   600.0,
	},
	{
		"id":         "treasure_cache",
		"name":       "Hidden Treasure",
		"weight":     10,
		"min_level":  3,
		"regions":    ["overworld", "forest", "ruins"],
		"type":       "spawn_chest",
		"chest_rarity": "uncommon",
		"cooldown":   400.0,
	},
	{
		"id":         "meteor_shower",
		"name":       "Meteor Shower",
		"weight":     5,
		"min_level":  1,
		"regions":    ["overworld"],
		"type":       "visual_event",
		"duration":   30.0,
		"cooldown":   1200.0,
	},
	{
		"id":         "wolf_pack",
		"name":       "Wolf Pack Sighted!",
		"weight":     20,
		"min_level":  2,
		"regions":    ["forest", "overworld"],
		"type":       "spawn_enemies",
		"enemies":    [{ "id": "forest_wolf", "count": 4 }],
		"cooldown":   240.0,
	},
	{
		"id":         "ancient_spirit",
		"name":       "Ancient Spirit Appears",
		"weight":     8,
		"min_level":  5,
		"regions":    ["ruins", "cave_of_echoes"],
		"type":       "dialogue_event",
		"dialogue_id": "ancient_spirit_greeting",
		"cooldown":   900.0,
	},
]

# ─── STATE ───────────────────────────────────────────────────────────────────

var _event_timer: float     = 0.0
var _next_event_time: float = 60.0      # First event after 60 sec
var _event_cooldowns: Dictionary = {}   # event_id → remaining cooldown
var _current_region: StringName = &""

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	EventBus.player_entered_region.connect(_on_region_changed)

func _process(delta: float) -> void:
	if not GameManager.is_playing():
		return

	# Tick cooldowns
	for event_id in _event_cooldowns.keys():
		_event_cooldowns[event_id] -= delta
		if _event_cooldowns[event_id] <= 0.0:
			_event_cooldowns.erase(event_id)

	_event_timer += delta
	if _event_timer >= _next_event_time:
		_event_timer = 0.0
		_next_event_time = randf_range(90.0, 300.0)
		_try_fire_event()

func _on_region_changed(region_id: StringName) -> void:
	_current_region = region_id

# ─── EVENT SELECTION ─────────────────────────────────────────────────────────

func _try_fire_event() -> void:
	var player_level := 1
	if GameManager.player_node:
		var lvl := GameManager.player_node.get_node_or_null("LevelSystem") as LevelSystem
		if lvl:
			player_level = lvl.current_level

	var candidates: Array = []
	for event in EVENTS:
		if event["id"] in _event_cooldowns:
			continue
		if player_level < event.get("min_level", 1):
			continue
		var regions: Array = event.get("regions", [])
		if not regions.is_empty() and str(_current_region) not in regions:
			continue
		candidates.append(event)

	if candidates.is_empty():
		return

	# Weighted random selection
	var total_weight := 0
	for ev in candidates:
		total_weight += ev.get("weight", 10)
	var roll := randi() % total_weight
	var cumulative := 0
	var chosen: Dictionary = {}
	for ev in candidates:
		cumulative += ev.get("weight", 10)
		if roll < cumulative:
			chosen = ev
			break

	if not chosen.is_empty():
		_fire_event(chosen)

# ─── EVENT EXECUTION ─────────────────────────────────────────────────────────

func _fire_event(event: Dictionary) -> void:
	var event_id: String = event["id"]
	_event_cooldowns[event_id] = event.get("cooldown", 300.0)
	EventBus.world_event_triggered.emit(StringName(event_id))
	print("[WorldEvents] Firing event: %s" % event["name"])

	match event.get("type", ""):
		"spawn_enemies": _spawn_enemies(event)
		"spawn_npc":     _spawn_npc(event)
		"spawn_chest":   _spawn_chest(event)
		"visual_event":  _play_visual_event(event)
		"dialogue_event": _trigger_dialogue_event(event)

func _spawn_enemies(event: Dictionary) -> void:
	if GameManager.player_node == null:
		return
	var spawn_center := GameManager.player_node.global_position
	var enemy_scenes := {
		"goblin":        "res://scenes/entities/enemies/Goblin.tscn",
		"goblin_archer": "res://scenes/entities/enemies/GoblinArcher.tscn",
		"forest_wolf":   "res://scenes/entities/enemies/Wolf.tscn",
	}
	for entry in event.get("enemies", []):
		var enemy_id: String = entry["id"]
		var count: int = entry.get("count", 1)
		var scene_path: String = enemy_scenes.get(enemy_id, "")
		if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
			continue
		for i in count:
			var enemy: Node = load(scene_path).instantiate()
			get_tree().current_scene.add_child(enemy)
			# Spawn off-screen in a ring around the player
			var angle := randf() * TAU
			var dist := randf_range(200.0, 350.0)
			enemy.global_position = spawn_center + Vector2(cos(angle), sin(angle)) * dist

func _spawn_npc(event: Dictionary) -> void:
	# Spawn a temporary NPC (wandering merchant, etc.)
	var npc_id: String = event.get("npc_id", "")
	var scene_path := "res://scenes/entities/npcs/%s.tscn" % npc_id.capitalize()
	if not ResourceLoader.exists(scene_path):
		return
	var npc: Node = load(scene_path).instantiate()
	get_tree().current_scene.add_child(npc)
	if GameManager.player_node:
		npc.global_position = GameManager.player_node.global_position + Vector2(80, 0)
	var duration: float = event.get("duration", 120.0)
	get_tree().create_timer(duration).timeout.connect(npc.queue_free)

func _spawn_chest(event: Dictionary) -> void:
	if not ResourceLoader.exists("res://scenes/entities/world/Chest.tscn"):
		return
	var chest: Node = load("res://scenes/entities/world/Chest.tscn").instantiate()
	get_tree().current_scene.add_child(chest)
	if GameManager.player_node:
		var angle := randf() * TAU
		chest.global_position = GameManager.player_node.global_position + \
			Vector2(cos(angle), sin(angle)) * randf_range(100.0, 200.0)

func _play_visual_event(event: Dictionary) -> void:
	# Placeholder — trigger particle system, sky change, etc.
	pass

func _trigger_dialogue_event(event: Dictionary) -> void:
	var dialogue_id := StringName(event.get("dialogue_id", ""))
	if dialogue_id.is_empty():
		return
	var dialogue_sys := get_tree().get_first_node_in_group("dialogue_system") as DialogueSystem
	if dialogue_sys:
		dialogue_sys.start(dialogue_id)
