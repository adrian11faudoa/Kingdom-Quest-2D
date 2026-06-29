## ItemSlot.gd
## A single slot in the inventory grid.
## Displays item icon, quantity, and rarity colour bar.
## Emits "clicked" signal when pressed.
##
extends Button

signal clicked

@onready var icon:       TextureRect = $Icon
@onready var qty_label:  Label       = $QtyLabel
@onready var rarity_bar: ColorRect   = $RarityBar

var _item_id: StringName = &""

func _ready() -> void:
	pressed.connect(func(): clicked.emit())

## Called by InventoryUI when rebuilding the grid.
func set_item_data(item_data: Dictionary, quantity: int) -> void:
	if item_data.is_empty():
		clear()
		return

	_item_id = StringName(item_data.get("id", ""))

	# Icon
	var icon_path: String = item_data.get("icon", "")
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		icon.texture = load(icon_path)
	else:
		icon.texture = null

	# Quantity
	qty_label.text = str(quantity) if quantity > 1 else ""

	# Rarity colour bar along bottom edge
	var rarity: String = item_data.get("rarity", "common")
	rarity_bar.color = Utils.rarity_color(rarity)

	# Tooltip
	tooltip_text = "%s\n%s" % [
		item_data.get("name", str(_item_id)),
		item_data.get("description", "")
	]

func clear() -> void:
	_item_id      = &""
	icon.texture  = null
	qty_label.text = ""
	rarity_bar.color = Color(1, 1, 1, 0)
	tooltip_text  = ""

func get_item_id() -> StringName:
	return _item_id
