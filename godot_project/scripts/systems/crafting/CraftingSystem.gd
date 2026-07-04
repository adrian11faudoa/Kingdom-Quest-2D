## CraftingSystem.gd
## Recipe-based crafting with multiple workbench types and item upgrades.
##
## RECIPE JSON FORMAT:
## {
##   "id": "iron_sword",
##   "workbench": "forge",
##   "result_item": "iron_sword",
##   "result_qty": 1,
##   "ingredients": [
##     { "id": "iron_ingot", "qty": 3 },
##     { "id": "wood_handle", "qty": 1 }
##   ],
##   "required_level": 5,
##   "unlock_condition": ""
## }
##
class_name CraftingSystem
extends Node

enum Workbench { HAND, FORGE, ALCHEMY, ENCHANTING, COOKING }

var _inventory: InventorySystem = null

func _ready() -> void:
	await get_parent().ready
	_inventory = get_parent().get_node_or_null("InventorySystem")

# ─── CRAFTING ────────────────────────────────────────────────────────────────

func can_craft(recipe_id: StringName) -> bool:
	var recipe := DataManager.get_recipe(recipe_id)
	if recipe.is_empty():
		return false
	if _inventory == null:
		return false

	# Check level requirement
	var level_sys: LevelSystem = GameManager.player_node.get_node_or_null("LevelSystem") if GameManager.player_node else null
	if level_sys and level_sys.current_level < recipe.get("required_level", 1):
		return false

	# Check all ingredients
	for ingredient in recipe.get("ingredients", []):
		if not _inventory.has_item(StringName(ingredient["id"]), ingredient.get("qty", 1)):
			return false

	return true

func craft(recipe_id: StringName, workbench: Workbench = Workbench.HAND) -> bool:
	var recipe := DataManager.get_recipe(recipe_id)
	if recipe.is_empty():
		return false

	# Verify workbench type matches
	var required_bench: String = recipe.get("workbench", "hand")
	if required_bench != _workbench_name(workbench):
		push_warning("[Crafting] Wrong workbench for %s (need %s)" % [recipe_id, required_bench])
		return false

	if not can_craft(recipe_id):
		return false

	# Consume ingredients
	for ingredient in recipe.get("ingredients", []):
		_inventory.remove_item(StringName(ingredient["id"]), ingredient.get("qty", 1))

	# Add result
	var result_id := StringName(recipe.get("result_item", ""))
	var result_qty: int = recipe.get("result_qty", 1)
	_inventory.add_item(result_id, result_qty)

	EventBus.item_crafted.emit(result_id)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/craft_success.ogg")
	print("[Crafting] Crafted: %s x%d" % [result_id, result_qty])
	return true

# ─── UPGRADES ────────────────────────────────────────────────────────────────
## Upgrade an equipped item to the next tier. Consumes upgrade materials.

func upgrade_item(item_id: StringName) -> bool:
	var item_data := DataManager.get_item(item_id)
	if item_data.is_empty():
		return false

	var upgrade_to := StringName(item_data.get("upgrade_to", ""))
	if upgrade_to.is_empty():
		push_warning("[Crafting] %s has no upgrade path" % item_id)
		return false

	var upgrade_cost: Array = item_data.get("upgrade_cost", [])
	for cost_entry in upgrade_cost:
		if not _inventory.has_item(StringName(cost_entry["id"]), cost_entry["qty"]):
			return false

	for cost_entry in upgrade_cost:
		_inventory.remove_item(StringName(cost_entry["id"]), cost_entry["qty"])

	# Swap item in inventory
	_inventory.remove_item(item_id, 1)
	_inventory.add_item(upgrade_to, 1)

	# If it was equipped, re-equip the upgraded version
	for slot in _inventory.equipped:
		if _inventory.equipped[slot] == item_id:
			_inventory.unequip_slot(slot)
			_inventory.equip_item(upgrade_to)
			break

	EventBus.item_upgraded.emit(upgrade_to, item_data.get("tier", 1) + 1)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/upgrade_success.ogg")
	return true

# ─── QUERIES ─────────────────────────────────────────────────────────────────

func get_available_recipes(workbench: Workbench) -> Array:
	var bench_name := _workbench_name(workbench)
	var available: Array = []
	for recipe_id in DataManager.recipes:
		var recipe := DataManager.get_recipe(recipe_id)
		if recipe.get("workbench", "hand") == bench_name:
			available.append({
				"id":         recipe_id,
				"can_craft":  can_craft(recipe_id),
				"recipe":     recipe,
			})
	return available

func get_missing_ingredients(recipe_id: StringName) -> Array:
	var recipe := DataManager.get_recipe(recipe_id)
	var missing: Array = []
	for ingredient in recipe.get("ingredients", []):
		var id := StringName(ingredient["id"])
		var needed: int = ingredient.get("qty", 1)
		var have: int = _inventory.count_item(id) if _inventory else 0
		if have < needed:
			missing.append({ "id": id, "have": have, "need": needed })
	return missing

func _workbench_name(w: Workbench) -> String:
	match w:
		Workbench.FORGE:      return "forge"
		Workbench.ALCHEMY:    return "alchemy"
		Workbench.ENCHANTING: return "enchanting"
		Workbench.COOKING:    return "cooking"
		_:                    return "hand"
