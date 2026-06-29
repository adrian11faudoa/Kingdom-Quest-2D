## LootTableComponent.gd
## Attached to enemies/chests. Rolls and spawns loot when triggered.
## Reads loot table from DataManager (via parent's enemy_id) or inline export.
##
class_name LootTableComponent
extends Node

## Override inline loot table — if empty, uses enemy data from DataManager
@export var loot_table_override: Array = []
## Radius around drop point to scatter loot
@export var scatter_radius: float = 24.0

func spawn_loot(world_position: Vector2) -> void:
	var table := _get_table()
	if table.is_empty():
		return

	var drops := InventorySystem.roll_loot(table)
	for drop_entry in drops:
		var loot: Node = ObjectPool.acquire("loot_drop")
		if loot == null:
			continue

		# Reparent to scene root for correct world-space position
		var scene_root := get_tree().current_scene
		if loot.get_parent() != scene_root:
			loot.reparent(scene_root, false)

		var scatter := Utils.random_in_circle(world_position, scatter_radius)
		loot.global_position = scatter

		if loot.has_method("setup"):
			loot.setup(drop_entry["id"], drop_entry["qty"])

func _get_table() -> Array:
	if not loot_table_override.is_empty():
		return loot_table_override

	# Try to read from parent enemy's DataManager entry
	var parent := get_parent()
	if parent.has_method("get") and parent.get("enemy_id") != null:
		var enemy_data := DataManager.get_enemy(parent.enemy_id)
		return enemy_data.get("loot_table", [])

	return []
