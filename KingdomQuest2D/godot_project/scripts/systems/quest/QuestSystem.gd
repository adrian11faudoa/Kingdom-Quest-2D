## QuestSystem.gd
## Full quest system: tracking, objectives, rewards, journal.
##
## DESIGN: Quest data lives in JSON (res://assets/data/quests/).
## Runtime state (active, completed, progress) lives here.
## QuestSystem listens to EventBus signals to auto-update objectives —
## quest scripts never need to reach into each other.
##
## QUEST JSON FORMAT:
## {
##   "id": "main_01_goblin_threat",
##   "title": "The Goblin Threat",
##   "description": "Goblins have been raiding the village...",
##   "category": "main",  // main, side, hidden
##   "giver_npc": "elder_mira",
##   "objectives": [
##     { "id": "kill_goblins", "type": "kill", "target": "goblin", "count": 5, "description": "Kill 5 goblins" },
##     { "id": "return_to_mira", "type": "talk", "target": "elder_mira", "description": "Return to Elder Mira" }
##   ],
##   "rewards": { "xp": 200, "gold": 50, "items": [{ "id": "iron_sword", "qty": 1 }] },
##   "prerequisites": [],
##   "next_quest": "main_02_goblin_king"
## }
##
class_name QuestSystem
extends Node

# ─── RUNTIME STATE ───────────────────────────────────────────────────────────

## quest_id → { "status": String, "progress": { obj_id: int } }
var quest_states: Dictionary = {}

enum QuestStatus { AVAILABLE, ACTIVE, COMPLETED, FAILED }

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	_connect_objective_listeners()
	SaveManager.register_system(get_save_data, apply_save_data)

func _connect_objective_listeners() -> void:
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.item_picked_up.connect(_on_item_collected)
	EventBus.dialogue_ended.connect(_on_dialogue_ended)
	EventBus.chest_opened.connect(_on_chest_opened)

# ─── QUEST CONTROL ───────────────────────────────────────────────────────────

func start_quest(quest_id: StringName) -> bool:
	if is_quest_active(quest_id) or is_quest_completed(quest_id):
		return false

	var data := DataManager.get_quest(quest_id)
	if data.is_empty():
		push_warning("[QuestSystem] Unknown quest: %s" % quest_id)
		return false

	# Check prerequisites
	for prereq in data.get("prerequisites", []):
		if not is_quest_completed(StringName(prereq)):
			return false

	# Initialise objective progress
	var progress: Dictionary = {}
	for obj in data.get("objectives", []):
		progress[obj["id"]] = 0

	quest_states[quest_id] = {
		"status":   "active",
		"progress": progress
	}

	EventBus.quest_started.emit(quest_id)
	print("[QuestSystem] Started: %s" % quest_id)
	return true

func complete_quest(quest_id: StringName) -> void:
	if not is_quest_active(quest_id):
		return

	quest_states[quest_id]["status"] = "completed"
	_grant_rewards(quest_id)
	EventBus.quest_completed.emit(quest_id)
	print("[QuestSystem] Completed: %s" % quest_id)

	# Auto-start next quest if defined
	var data := DataManager.get_quest(quest_id)
	var next: String = data.get("next_quest", "")
	if not next.is_empty():
		start_quest(StringName(next))

func fail_quest(quest_id: StringName) -> void:
	if not is_quest_active(quest_id):
		return
	quest_states[quest_id]["status"] = "failed"
	EventBus.quest_failed.emit(quest_id)

func abandon_quest(quest_id: StringName) -> void:
	quest_states.erase(quest_id)

# ─── OBJECTIVE UPDATES ───────────────────────────────────────────────────────

func update_objective(quest_id: StringName, objective_id: String, delta: int = 1) -> void:
	if not is_quest_active(quest_id):
		return
	var progress: Dictionary = quest_states[quest_id]["progress"]
	if not progress.has(objective_id):
		return

	var data := DataManager.get_quest(quest_id)
	var obj_data := _find_objective(data, objective_id)
	if obj_data.is_empty():
		return

	var target_count: int = obj_data.get("count", 1)
	progress[objective_id] = mini(progress[objective_id] + delta, target_count)

	EventBus.quest_objective_updated.emit(quest_id, objective_id,
		progress[objective_id], target_count)

	if _all_objectives_complete(quest_id, data):
		complete_quest(quest_id)

func _find_objective(quest_data: Dictionary, obj_id: String) -> Dictionary:
	for obj in quest_data.get("objectives", []):
		if obj["id"] == obj_id:
			return obj
	return {}

func _all_objectives_complete(quest_id: StringName, data: Dictionary) -> bool:
	var progress: Dictionary = quest_states[quest_id]["progress"]
	for obj in data.get("objectives", []):
		var count: int = obj.get("count", 1)
		if progress.get(obj["id"], 0) < count:
			return false
	return true

# ─── AUTOMATIC OBJECTIVE LISTENERS ───────────────────────────────────────────

func _on_enemy_killed(enemy_id: StringName, _pos: Vector2) -> void:
	for quest_id in quest_states:
		if not is_quest_active(StringName(quest_id)):
			continue
		var data := DataManager.get_quest(StringName(quest_id))
		for obj in data.get("objectives", []):
			if obj.get("type") == "kill" and obj.get("target") == str(enemy_id):
				update_objective(StringName(quest_id), obj["id"])

func _on_item_collected(item_id: StringName, qty: int) -> void:
	for quest_id in quest_states:
		if not is_quest_active(StringName(quest_id)):
			continue
		var data := DataManager.get_quest(StringName(quest_id))
		for obj in data.get("objectives", []):
			if obj.get("type") == "collect" and obj.get("target") == str(item_id):
				update_objective(StringName(quest_id), obj["id"], qty)

func _on_dialogue_ended() -> void:
	# The dialogue system sets the last speaker via DialogueSystem.last_speaker_id
	var speaker := ""
	var dialogue_sys := get_tree().get_first_node_in_group("dialogue_system")
	if dialogue_sys and dialogue_sys.has_method("get_last_speaker"):
		speaker = dialogue_sys.get_last_speaker()

	for quest_id in quest_states:
		if not is_quest_active(StringName(quest_id)):
			continue
		var data := DataManager.get_quest(StringName(quest_id))
		for obj in data.get("objectives", []):
			if obj.get("type") == "talk" and obj.get("target") == speaker:
				update_objective(StringName(quest_id), obj["id"])

func _on_chest_opened(chest_id: StringName) -> void:
	for quest_id in quest_states:
		if not is_quest_active(StringName(quest_id)):
			continue
		var data := DataManager.get_quest(StringName(quest_id))
		for obj in data.get("objectives", []):
			if obj.get("type") == "open_chest" and obj.get("target") == str(chest_id):
				update_objective(StringName(quest_id), obj["id"])

# ─── REWARDS ─────────────────────────────────────────────────────────────────

func _grant_rewards(quest_id: StringName) -> void:
	var data := DataManager.get_quest(quest_id)
	var rewards: Dictionary = data.get("rewards", {})
	var inventory := get_tree().get_first_node_in_group("inventory")

	if rewards.has("xp") and GameManager.player_node:
		var level_sys: LevelSystem = GameManager.player_node.get_node_or_null("LevelSystem")
		if level_sys:
			level_sys.add_xp(rewards["xp"])

	if rewards.has("gold") and inventory:
		inventory.add_gold(rewards["gold"])

	if rewards.has("items") and inventory:
		for item in rewards["items"]:
			inventory.add_item(StringName(item["id"]), item.get("qty", 1))

# ─── QUERY API ───────────────────────────────────────────────────────────────

func is_quest_active(quest_id: StringName) -> bool:
	return quest_states.get(quest_id, {}).get("status", "") == "active"

func is_quest_completed(quest_id: StringName) -> bool:
	return quest_states.get(quest_id, {}).get("status", "") == "completed"

func get_active_quests() -> Array:
	return quest_states.keys().filter(func(qid): return is_quest_active(StringName(qid)))

func get_completed_quests() -> Array:
	return quest_states.keys().filter(func(qid): return is_quest_completed(StringName(qid)))

func get_quest_progress(quest_id: StringName, objective_id: String) -> int:
	return quest_states.get(quest_id, {}).get("progress", {}).get(objective_id, 0)

func get_available_quests() -> Array:
	## Returns all quests from DataManager whose prerequisites are met and not started.
	var available: Array = []
	for quest_id in DataManager.quests:
		if quest_states.has(quest_id):
			continue  # Already started or done
		var data := DataManager.get_quest(quest_id)
		var prereqs_met := true
		for prereq in data.get("prerequisites", []):
			if not is_quest_completed(StringName(prereq)):
				prereqs_met = false
				break
		if prereqs_met:
			available.append(quest_id)
	return available

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	return { "quests": quest_states }

func apply_save_data(data: Dictionary) -> void:
	quest_states = data.get("quests", {})
	# Convert string keys back to StringNames
	var converted: Dictionary = {}
	for k in quest_states:
		converted[StringName(k)] = quest_states[k]
	quest_states = converted
