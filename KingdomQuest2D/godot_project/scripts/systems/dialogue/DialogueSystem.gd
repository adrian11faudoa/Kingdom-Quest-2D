## DialogueSystem.gd
## Branching dialogue with NPC portraits, choices, and quest integration.
##
## DIALOGUE JSON FORMAT:
## {
##   "id": "elder_mira_intro",
##   "nodes": {
##     "start": {
##       "speaker": "Elder Mira",
##       "portrait": "res://assets/art/characters/npcs/mira_portrait.png",
##       "text": "Ah, a traveller! We have urgent need of your skills.",
##       "next": "ask_help"
##     },
##     "ask_help": {
##       "speaker": "Elder Mira",
##       "text": "Will you help us deal with the goblin raids?",
##       "choices": [
##         { "text": "Of course, I'll help.", "next": "accept", "action": "start_quest:main_01_goblin_threat" },
##         { "text": "What's in it for me?",  "next": "negotiate" },
##         { "text": "I can't help right now.", "next": "refuse" }
##       ]
##     },
##     "accept": { "speaker": "Elder Mira", "text": "Bless you!", "next": null }
##   }
## }
##
class_name DialogueSystem
extends Node

# ─── STATE ───────────────────────────────────────────────────────────────────

var is_active: bool = false
var _current_dialogue_id: StringName = &""
var _current_node_id: String = ""
var _current_data: Dictionary = {}
var _last_speaker_id: String = ""

# UI references (set by DialogueUI)
var _ui: Node = null

# ─── SIGNALS ─────────────────────────────────────────────────────────────────

signal dialogue_line_ready(speaker: String, text: String, portrait_path: String)
signal choices_ready(choices: Array)
signal dialogue_finished()

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("dialogue_system")

func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if event.is_action_just_pressed(&"interact"):
		advance()
		get_viewport().set_input_as_handled()

# ─── CONTROL ─────────────────────────────────────────────────────────────────

func start(dialogue_id: StringName, speaker_id: String = "") -> void:
	var data := DataManager.get_dialogue(dialogue_id)
	if data.is_empty():
		push_warning("[DialogueSystem] No dialogue: %s" % dialogue_id)
		return

	is_active = true
	_current_dialogue_id = dialogue_id
	_current_data = data
	_last_speaker_id = speaker_id

	GameManager.change_state(GameManager.GameState.DIALOGUE)
	InputManager.disable_input()
	EventBus.dialogue_started.emit(dialogue_id, data.get("nodes", {}).get("start", {}).get("speaker", ""))

	_show_node("start")

func _show_node(node_id: String) -> void:
	_current_node_id = node_id
	var nodes: Dictionary = _current_data.get("nodes", {})
	if not nodes.has(node_id):
		_finish()
		return

	var node: Dictionary = nodes[node_id]
	var speaker: String  = node.get("speaker", "")
	var text: String     = node.get("text", "")
	var portrait: String = node.get("portrait", "")

	EventBus.dialogue_line_shown.emit(text, speaker)
	dialogue_line_ready.emit(speaker, text, portrait)

	# If this node has choices, wait for player selection
	var choices: Array = node.get("choices", [])
	if not choices.is_empty():
		EventBus.dialogue_choice_presented.emit(choices)
		choices_ready.emit(choices)

func advance() -> void:
	if not is_active:
		return
	var nodes: Dictionary = _current_data.get("nodes", {})
	var node: Dictionary  = nodes.get(_current_node_id, {})

	# Don't auto-advance if waiting for a choice
	if not node.get("choices", []).is_empty():
		return

	var next: Variant = node.get("next", null)
	if next == null:
		_finish()
	else:
		_show_node(str(next))

func select_choice(choice_index: int) -> void:
	var nodes: Dictionary = _current_data.get("nodes", {})
	var node: Dictionary  = nodes.get(_current_node_id, {})
	var choices: Array    = node.get("choices", [])

	if choice_index < 0 or choice_index >= choices.size():
		return

	var choice: Dictionary = choices[choice_index]
	EventBus.dialogue_choice_selected.emit(choice_index)

	# Process action if any
	var action: String = choice.get("action", "")
	if not action.is_empty():
		_process_action(action)

	var next: Variant = choice.get("next", null)
	if next == null:
		_finish()
	else:
		_show_node(str(next))

func _finish() -> void:
	is_active = false
	GameManager.change_state(GameManager.GameState.PLAYING)
	InputManager.enable_input()
	EventBus.dialogue_ended.emit()
	dialogue_finished.emit()

# ─── ACTION PROCESSING ───────────────────────────────────────────────────────
## Actions in dialogue strings: "start_quest:quest_id", "give_item:item_id:qty"

func _process_action(action: String) -> void:
	var parts := action.split(":")
	if parts.is_empty():
		return

	match parts[0]:
		"start_quest":
			if parts.size() >= 2:
				var quest_sys := get_tree().get_first_node_in_group("quest_system")
				if quest_sys:
					quest_sys.start_quest(StringName(parts[1]))

		"give_item":
			if parts.size() >= 2:
				var qty := int(parts[2]) if parts.size() >= 3 else 1
				var inventory := get_tree().get_first_node_in_group("inventory")
				if inventory:
					inventory.add_item(StringName(parts[1]), qty)

		"give_gold":
			if parts.size() >= 2:
				var inventory := get_tree().get_first_node_in_group("inventory")
				if inventory:
					inventory.add_gold(int(parts[1]))

		"open_shop":
			if parts.size() >= 2:
				EventBus.world_event_triggered.emit(StringName("open_shop:" + parts[1]))

		"set_flag":
			if parts.size() >= 2:
				GameManager.set_meta(parts[1], true)

		_:
			push_warning("[DialogueSystem] Unknown action: %s" % action)

# ─── QUERY ───────────────────────────────────────────────────────────────────

func get_last_speaker() -> String:
	return _last_speaker_id
