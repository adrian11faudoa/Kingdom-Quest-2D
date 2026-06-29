## NPCController.gd
## NPC with daily schedules, dialogue, and optional merchant behaviour.
##
## NPCs follow a schedule: at certain hours they walk to preset positions.
## They can trigger dialogue and open shops.
##
class_name NPCController
extends CharacterBody2D

@export var npc_id: StringName = &""
@export var dialogue_id: StringName = &""
@export var is_merchant: bool = false
@export var merchant_id: StringName = &""

## Schedule entries: [{ "hour": 8.0, "position": Vector2(0,0), "animation": "idle" }]
@export var schedule: Array = []

@onready var sprite: AnimatedSprite2D     = $AnimatedSprite2D
@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D
@onready var interact_label: Label        = $InteractLabel

var _current_schedule_target: Vector2 = Vector2.ZERO
var _is_moving: bool = false
var _npc_data: Dictionary = {}

func _ready() -> void:
	add_to_group("npcs")
	_npc_data = DataManager.get_npc(npc_id)
	if interact_label:
		interact_label.hide()
	EventBus.time_of_day_changed.connect(_on_time_changed)

func _physics_process(delta: float) -> void:
	if _is_moving:
		_move_to_target(delta)

func _on_time_changed(hour: float) -> void:
	_check_schedule(hour)

func _check_schedule(hour: float) -> void:
	if schedule.is_empty():
		return
	# Find the most recent schedule entry
	var best: Dictionary = {}
	for entry in schedule:
		if entry.get("hour", 0.0) <= hour:
			best = entry
	if best.is_empty():
		return
	var target_pos: Vector2 = best.get("position", global_position)
	if global_position.distance_to(target_pos) > 8.0:
		_current_schedule_target = target_pos
		_is_moving = true
		var anim: String = best.get("animation", "walk")
		sprite.play(anim)

func _move_to_target(delta: float) -> void:
	nav_agent.target_position = _current_schedule_target
	if nav_agent.is_navigation_finished():
		_is_moving = false
		sprite.play("idle")
		return
	var next := nav_agent.get_next_path_position()
	var dir := (next - global_position).normalized()
	velocity = dir * 60.0
	move_and_slide()
	sprite.flip_h = dir.x < 0

# ─── INTERACTION ─────────────────────────────────────────────────────────────

func interact(player: Node) -> void:
	if is_merchant:
		_open_shop()
	elif not dialogue_id.is_empty():
		var dialogue_sys := get_tree().get_first_node_in_group("dialogue_system") as DialogueSystem
		if dialogue_sys:
			dialogue_sys.start(dialogue_id, str(npc_id))

func _open_shop() -> void:
	EventBus.world_event_triggered.emit(StringName("open_shop:" + str(merchant_id)))

func show_interact_prompt() -> void:
	if interact_label:
		interact_label.text = "[E] Talk"
		interact_label.show()

func hide_interact_prompt() -> void:
	if interact_label:
		interact_label.hide()
