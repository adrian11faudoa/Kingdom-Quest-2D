## InventoryUI.gd
## Inventory screen: item grid, equipment panel, item details, tooltips.
## Reads from InventorySystem, never modifies it directly — uses its API.
##
extends Control

# ─── NODE REFS ───────────────────────────────────────────────────────────────

@onready var item_grid: GridContainer  = $Panel/Split/Left/ScrollContainer/ItemGrid
@onready var equip_panel: Control      = $Panel/Split/Right/EquipPanel
@onready var detail_panel: Control     = $Panel/Split/Right/DetailPanel
@onready var item_name_label: Label    = $Panel/Split/Right/DetailPanel/Name
@onready var item_desc_label: Label    = $Panel/Split/Right/DetailPanel/Description
@onready var item_stats_label: Label   = $Panel/Split/Right/DetailPanel/Stats
@onready var equip_btn: Button         = $Panel/Split/Right/DetailPanel/EquipBtn
@onready var use_btn: Button           = $Panel/Split/Right/DetailPanel/UseBtn
@onready var drop_btn: Button          = $Panel/Split/Right/DetailPanel/DropBtn
@onready var gold_label: Label         = $Panel/GoldLabel
@onready var weight_label: Label       = $Panel/WeightLabel

const SLOT_SCENE := "res://scenes/ui/hud/ItemSlot.tscn"

var _inventory: InventorySystem = null
var _selected_index: int = -1
var _slot_nodes: Array[Node] = []

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	hide()
	_connect_events()
	equip_btn.pressed.connect(_on_equip_pressed)
	use_btn.pressed.connect(_on_use_pressed)
	drop_btn.pressed.connect(_on_drop_pressed)

func _connect_events() -> void:
	EventBus.inventory_changed.connect(_refresh)
	EventBus.gold_changed.connect(func(g): gold_label.text = "Gold: %d" % g)

func _input(event: InputEvent) -> void:
	if visible and event.is_action_just_pressed(&"open_inventory"):
		close()
		get_viewport().set_input_as_handled()

# ─── OPEN / CLOSE ────────────────────────────────────────────────────────────

func open() -> void:
	_find_inventory()
	if _inventory == null:
		return
	_refresh()
	show()
	GameManager.change_state(GameManager.GameState.PAUSED)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_open.ogg")

func close() -> void:
	hide()
	detail_panel.hide()
	_selected_index = -1
	if GameManager.current_state == GameManager.GameState.PAUSED:
		GameManager.change_state(GameManager.GameState.PLAYING)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_close.ogg")

func _find_inventory() -> void:
	if _inventory != null:
		return
	_inventory = get_tree().get_first_node_in_group("inventory") as InventorySystem

# ─── REFRESH ─────────────────────────────────────────────────────────────────

func _refresh() -> void:
	if not visible or _inventory == null:
		return
	_rebuild_grid()
	_refresh_equip_panel()
	gold_label.text = "Gold: %d" % _inventory.gold

func _rebuild_grid() -> void:
	# Clear existing slots
	for node in _slot_nodes:
		node.queue_free()
	_slot_nodes.clear()

	if not ResourceLoader.exists(SLOT_SCENE):
		return

	for i in _inventory.items.size():
		var slot: Node = load(SLOT_SCENE).instantiate()
		item_grid.add_child(slot)
		_slot_nodes.append(slot)

		var entry: Dictionary = _inventory.items[i]
		var item_data := DataManager.get_item(entry["id"])
		if slot.has_method("set_item_data"):
			slot.set_item_data(item_data, entry["qty"])

		# Capture index for closure
		var idx := i
		if slot.has_signal("clicked"):
			slot.clicked.connect(func(): _on_slot_clicked(idx))

func _refresh_equip_panel() -> void:
	for slot_name in _inventory.equipped:
		var slot_node := equip_panel.get_node_or_null(str(slot_name))
		if slot_node and slot_node.has_method("set_item_id"):
			slot_node.set_item_id(_inventory.equipped[slot_name])

# ─── SELECTION & DETAILS ─────────────────────────────────────────────────────

func _on_slot_clicked(index: int) -> void:
	_selected_index = index
	if index < 0 or index >= _inventory.items.size():
		detail_panel.hide()
		return
	var entry: Dictionary = _inventory.items[index]
	var item_data := DataManager.get_item(entry["id"])
	_show_item_details(item_data, entry["qty"])
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_click.ogg")

func _show_item_details(item_data: Dictionary, qty: int) -> void:
	detail_panel.show()
	item_name_label.text = item_data.get("name", "Unknown")
	item_desc_label.text = item_data.get("description", "")

	# Build stats string
	var stats_text := ""
	if item_data.get("attack_bonus", 0) != 0:
		stats_text += "ATK +%d\n" % item_data["attack_bonus"]
	if item_data.get("defense_bonus", 0) != 0:
		stats_text += "DEF +%d\n" % item_data["defense_bonus"]
	if item_data.get("health_bonus", 0) != 0:
		stats_text += "HP +%d\n" % item_data["health_bonus"]
	if qty > 1:
		stats_text += "Qty: %d" % qty
	item_stats_label.text = stats_text

	# Show relevant action buttons
	equip_btn.visible = not item_data.get("slot", "").is_empty()
	use_btn.visible   = item_data.get("usable", false)
	drop_btn.visible  = item_data.get("droppable", true)

	# Rarity colour
	var rarity: String = item_data.get("rarity", "common")
	item_name_label.add_theme_color_override("font_color", _rarity_color(rarity))

func _rarity_color(rarity: String) -> Color:
	match rarity:
		"uncommon":  return Color(0.3, 0.9, 0.3)
		"rare":      return Color(0.3, 0.5, 1.0)
		"epic":      return Color(0.7, 0.3, 1.0)
		"legendary": return Color(1.0, 0.6, 0.1)
		_:           return Color.WHITE

# ─── ACTIONS ─────────────────────────────────────────────────────────────────

func _on_equip_pressed() -> void:
	if _selected_index < 0 or _inventory == null:
		return
	var item_id: StringName = _inventory.items[_selected_index]["id"]
	_inventory.equip_item(item_id)
	_refresh()

func _on_use_pressed() -> void:
	if _selected_index < 0 or _inventory == null:
		return
	var item_id: StringName = _inventory.items[_selected_index]["id"]
	_inventory.use_item(item_id)
	_refresh()

func _on_drop_pressed() -> void:
	if _selected_index < 0 or _inventory == null:
		return
	var item_id: StringName = _inventory.items[_selected_index]["id"]
	_inventory.remove_item(item_id, 1)
	EventBus.item_dropped.emit(item_id, 1)
	_selected_index = -1
	detail_panel.hide()
	_refresh()
