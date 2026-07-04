## CompanionSystem.gd
## Manages the active companion/pet: following, combat assist, abilities.
##
## DESIGN: The companion is its own CharacterBody2D scene, instantiated when
## joining the player. This script is the high-level manager on the Player node.
## The companion scene handles its own AI via CompanionAI.gd.
##
class_name CompanionSystem
extends Node

@export var companion_scenes: Dictionary = {
	&"fox":     "res://scenes/entities/companions/FoxCompanion.tscn",
	&"golem":   "res://scenes/entities/companions/GolemCompanion.tscn",
	&"sprite":  "res://scenes/entities/companions/SpriteCompanion.tscn",
}

var active_companion: Node = null
var active_companion_id: StringName = &""

func _ready() -> void:
	SaveManager.register_system(get_save_data, apply_save_data)

func summon(companion_id: StringName) -> bool:
	if active_companion != null:
		dismiss()
	if not companion_scenes.has(companion_id):
		push_warning("[CompanionSystem] Unknown companion: %s" % companion_id)
		return false
	var scene_path: String = companion_scenes[companion_id]
	if not ResourceLoader.exists(scene_path):
		return false
	var instance: Node = load(scene_path).instantiate()
	get_tree().current_scene.add_child(instance)
	if GameManager.player_node:
		instance.global_position = GameManager.player_node.global_position + Vector2(32, 0)
	active_companion    = instance
	active_companion_id = companion_id
	EventBus.companion_joined.emit(companion_id)
	return true

func dismiss() -> void:
	if active_companion == null:
		return
	var id := active_companion_id
	active_companion.queue_free()
	active_companion    = null
	active_companion_id = &""
	EventBus.companion_left.emit(id)

func use_companion_ability() -> void:
	if active_companion and active_companion.has_method("use_ability"):
		active_companion.use_ability()

func get_save_data() -> Dictionary:
	return { "companion": { "active": str(active_companion_id) } }

func apply_save_data(data: Dictionary) -> void:
	var id := StringName(data.get("companion", {}).get("active", ""))
	if not id.is_empty():
		call_deferred("summon", id)
