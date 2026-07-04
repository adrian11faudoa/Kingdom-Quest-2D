## Chest.gd
## Openable treasure chest. Spawns loot, can be locked, persists open state.
##
class_name Chest
extends Area2D

@export var chest_id: StringName = &""
@export var loot_table: Array = []   # Override per chest; else use data file
@export var is_locked: bool  = false
@export var key_item_id: StringName = &""

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var prompt_label: Label      = $PromptLabel

var _is_open: bool = false
var _player_nearby: bool = false

func _ready() -> void:
	add_to_group("interactables")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	prompt_label.hide()

func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group("player") and not _is_open:
		_player_nearby = true
		prompt_label.text = "[E] Open" if not is_locked else "[E] Unlock"
		prompt_label.show()

func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group("player"):
		_player_nearby = false
		prompt_label.hide()

func _unhandled_input(event: InputEvent) -> void:
	if _player_nearby and not _is_open and \
	   event.is_action_just_pressed(&"interact"):
		interact(GameManager.player_node)
		get_viewport().set_input_as_handled()

func interact(player: Node) -> void:
	if _is_open:
		return
	if is_locked:
		var inventory := player.get_node_or_null("InventorySystem") as InventorySystem
		if inventory == null or not inventory.has_item(key_item_id):
			# Play locked sound
			AudioManager.play_sfx("res://assets/audio/sfx/chest_locked.ogg",
				global_position)
			return
		inventory.remove_item(key_item_id, 1)
		is_locked = false

	_open(player)

func _open(player: Node) -> void:
	_is_open = true
	prompt_label.hide()
	sprite.play("open")
	AudioManager.play_sfx("res://assets/audio/sfx/chest_open.ogg", global_position)

	# Build loot table from data if not set inline
	var table := loot_table
	if table.is_empty() and not chest_id.is_empty():
		var chest_data := DataManager.get_item(chest_id)
		table = chest_data.get("loot_table", [])

	# Roll and spawn loot
	var drops := InventorySystem.roll_loot(table)
	for drop_entry in drops:
		var loot: LootDrop = ObjectPool.acquire("loot_drop", get_parent()) as LootDrop
		if loot:
			loot.global_position = global_position
			loot.setup(drop_entry["id"], drop_entry["qty"])

	EventBus.chest_opened.emit(chest_id)

# ─── CHUNK STATE ─────────────────────────────────────────────────────────────

func save_chunk_state() -> Dictionary:
	return { "open": _is_open }

func load_chunk_state(data: Dictionary) -> void:
	if data.get("open", false):
		_is_open = true
		sprite.play("open_idle")
