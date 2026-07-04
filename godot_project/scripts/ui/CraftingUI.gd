## CraftingUI.gd
## Crafting workbench interface: recipe list, ingredient check, craft button.
## Opened when player interacts with a Forge, Alchemy Table, etc.
##
extends Control

@onready var recipe_list: ItemList      = $Panel/Split/RecipeList
@onready var result_label: Label        = $Panel/Split/Detail/ResultLabel
@onready var ingredients_box: VBoxContainer = $Panel/Split/Detail/Ingredients
@onready var craft_btn: Button          = $Panel/Split/Detail/CraftBtn
@onready var workbench_label: Label     = $Panel/Header/WorkbenchLabel
@onready var close_btn: Button          = $Panel/Header/CloseBtn

var _crafting: CraftingSystem = null
var _inventory: InventorySystem = null
var _current_workbench: CraftingSystem.Workbench = CraftingSystem.Workbench.HAND
var _recipes: Array = []
var _selected_recipe_id: StringName = &""

func _ready() -> void:
	hide()
	craft_btn.pressed.connect(_on_craft)
	close_btn.pressed.connect(close)
	recipe_list.item_selected.connect(_on_recipe_selected)

func open(workbench: CraftingSystem.Workbench) -> void:
	_current_workbench = workbench
	_find_systems()
	workbench_label.text = _workbench_display_name(workbench)
	_refresh_recipes()
	show()
	GameManager.change_state(GameManager.GameState.PAUSED)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_open.ogg")

func close() -> void:
	hide()
	GameManager.change_state(GameManager.GameState.PLAYING)

func _find_systems() -> void:
	if GameManager.player_node == null:
		return
	_crafting  = GameManager.player_node.get_node_or_null("CraftingSystem") as CraftingSystem
	_inventory = GameManager.player_node.get_node_or_null("InventorySystem") as InventorySystem

func _refresh_recipes() -> void:
	recipe_list.clear()
	_recipes.clear()
	if _crafting == null:
		return
	_recipes = _crafting.get_available_recipes(_current_workbench)
	for entry in _recipes:
		var recipe: Dictionary = entry["recipe"]
		var item_data := DataManager.get_item(StringName(recipe.get("result_item", "")))
		var name_str: String = item_data.get("name", recipe.get("result_item", "?"))
		recipe_list.add_item(name_str)
		if not entry["can_craft"]:
			recipe_list.set_item_custom_fg_color(recipe_list.item_count - 1,
				Color(0.5, 0.5, 0.5))

func _on_recipe_selected(idx: int) -> void:
	if idx >= _recipes.size():
		return
	var entry: Dictionary = _recipes[idx]
	_selected_recipe_id = entry["id"]
	var recipe: Dictionary = entry["recipe"]

	var item_data := DataManager.get_item(StringName(recipe.get("result_item", "")))
	result_label.text = "Result: %s x%d" % [
		item_data.get("name", "?"), recipe.get("result_qty", 1)]

	# Show ingredients with have/need counts
	for child in ingredients_box.get_children():
		child.queue_free()
	for ingredient in recipe.get("ingredients", []):
		var ing_id := StringName(ingredient["id"])
		var need: int = ingredient.get("qty", 1)
		var have: int = _inventory.count_item(ing_id) if _inventory else 0
		var ing_data := DataManager.get_item(ing_id)
		var label := Label.new()
		label.text = "%s: %d/%d" % [ing_data.get("name", str(ing_id)), have, need]
		label.add_theme_color_override("font_color",
			Color(0.4, 1.0, 0.4) if have >= need else Color(1.0, 0.4, 0.4))
		ingredients_box.add_child(label)

	craft_btn.disabled = not entry["can_craft"]

func _on_craft() -> void:
	if _selected_recipe_id.is_empty() or _crafting == null:
		return
	if _crafting.craft(_selected_recipe_id, _current_workbench):
		_refresh_recipes()
		# Re-select same recipe
		for i in _recipes.size():
			if _recipes[i]["id"] == _selected_recipe_id:
				recipe_list.select(i)
				_on_recipe_selected(i)
				break

func _workbench_display_name(wb: CraftingSystem.Workbench) -> String:
	match wb:
		CraftingSystem.Workbench.FORGE:      return "🔥 Forge"
		CraftingSystem.Workbench.ALCHEMY:    return "⚗ Alchemy Table"
		CraftingSystem.Workbench.ENCHANTING: return "✨ Enchanting Table"
		CraftingSystem.Workbench.COOKING:    return "🍳 Cooking Fire"
		_:                                   return "✋ Crafting"
