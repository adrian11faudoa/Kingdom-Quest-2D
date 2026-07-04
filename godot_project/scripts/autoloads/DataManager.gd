## DataManager.gd
## Loads, parses, and caches all JSON-driven game data at startup.
##
## DESIGN: Game content (items, enemies, quests) is defined in JSON, NOT in
## code. This means designers can add new content without touching GDScript,
## and modders can replace/extend data files without recompiling.
##
## All data is loaded once at startup and cached in dictionaries keyed by
## their "id" field. Access is O(1) via get_item(), get_enemy(), etc.
##
extends Node

# ─── CACHES ──────────────────────────────────────────────────────────────────

var items: Dictionary = {}         # item_id → item_data dict
var enemies: Dictionary = {}       # enemy_id → enemy_data dict
var quests: Dictionary = {}        # quest_id → quest_data dict
var skills: Dictionary = {}        # skill_id → skill_data dict
var recipes: Dictionary = {}       # recipe_id → recipe_data dict
var dialogue: Dictionary = {}      # dialogue_id → dialogue_data dict
var npcs: Dictionary = {}          # npc_id → npc_data dict

# ─── FILE PATHS ──────────────────────────────────────────────────────────────

const DATA_PATHS: Dictionary = {
	"items":    "res://assets/data/items/",
	"enemies":  "res://assets/data/enemies/",
	"quests":   "res://assets/data/quests/",
	"skills":   "res://assets/data/skills/",
	"recipes":  "res://assets/data/recipes/",
	"dialogue": "res://assets/data/dialogue/",
	"npcs":     "res://assets/data/npcs/",
}

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	_load_all_data()

func _load_all_data() -> void:
	items    = _load_directory("items")
	enemies  = _load_directory("enemies")
	quests   = _load_directory("quests")
	skills   = _load_directory("skills")
	recipes  = _load_directory("recipes")
	dialogue = _load_directory("dialogue")
	npcs     = _load_directory("npcs")
	print("[DataManager] Loaded: %d items, %d enemies, %d quests, %d skills" \
		% [items.size(), enemies.size(), quests.size(), skills.size()])

# ─── INTERNAL LOADER ─────────────────────────────────────────────────────────

func _load_directory(category: String) -> Dictionary:
	var result: Dictionary = {}
	var path: String = DATA_PATHS.get(category, "")
	if path.is_empty():
		push_error("[DataManager] Unknown category: %s" % category)
		return result

	var dir := DirAccess.open(path)
	if dir == null:
		push_warning("[DataManager] Directory not found: %s" % path)
		return result

	dir.list_dir_begin()
	var filename := dir.get_next()
	while filename != "":
		if filename.ends_with(".json"):
			var full_path := path + filename
			var data := _load_json(full_path)
			if data != null:
				# Support both single objects and arrays in one file
				if data is Array:
					for entry in data:
						if entry.has("id"):
							result[StringName(entry["id"])] = entry
				elif data is Dictionary and data.has("id"):
					result[StringName(data["id"])] = data
		filename = dir.get_next()
	dir.list_dir_end()
	return result

func _load_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[DataManager] Cannot open: %s" % path)
		return null
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()
	if err != OK:
		push_error("[DataManager] JSON parse error in %s: %s" % [path, json.get_error_message()])
		return null
	return json.data

# ─── PUBLIC ACCESSORS ────────────────────────────────────────────────────────

func get_item(id: StringName) -> Dictionary:
	if not items.has(id):
		push_warning("[DataManager] Item not found: %s" % id)
		return {}
	return items[id]

func get_enemy(id: StringName) -> Dictionary:
	if not enemies.has(id):
		push_warning("[DataManager] Enemy not found: %s" % id)
		return {}
	return enemies[id]

func get_quest(id: StringName) -> Dictionary:
	if not quests.has(id):
		push_warning("[DataManager] Quest not found: %s" % id)
		return {}
	return quests[id]

func get_skill(id: StringName) -> Dictionary:
	if not skills.has(id):
		push_warning("[DataManager] Skill not found: %s" % id)
		return {}
	return skills[id]

func get_recipe(id: StringName) -> Dictionary:
	if not recipes.has(id):
		push_warning("[DataManager] Recipe not found: %s" % id)
		return {}
	return recipes[id]

func get_dialogue(id: StringName) -> Dictionary:
	if not dialogue.has(id):
		push_warning("[DataManager] Dialogue not found: %s" % id)
		return {}
	return dialogue[id]

func get_npc(id: StringName) -> Dictionary:
	if not npcs.has(id):
		push_warning("[DataManager] NPC not found: %s" % id)
		return {}
	return npcs[id]

func get_items_by_tag(tag: String) -> Array:
	return items.values().filter(func(item): return tag in item.get("tags", []))

func get_items_by_rarity(rarity: String) -> Array:
	return items.values().filter(func(item): return item.get("rarity", "") == rarity)
