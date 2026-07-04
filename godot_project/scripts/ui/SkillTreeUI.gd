## SkillTreeUI.gd
## Visual skill tree interface — node graph with connection lines.
## Each skill is a button; prerequisites drawn as lines between them.
##
extends Control

@onready var skill_container: Control  = $Panel/SkillContainer
@onready var points_label: Label       = $Panel/Header/PointsLabel
@onready var desc_label: Label         = $Panel/Footer/DescLabel
@onready var unlock_btn: Button        = $Panel/Footer/UnlockBtn
@onready var tab_bar: TabBar           = $Panel/TabBar

const SKILL_BTN_SCENE := "res://scenes/ui/menus/SkillNode.tscn"

## Skill node positions in the UI (override per category)
## Maps skill_id → Vector2(x, y) in local UI coords
const SKILL_POSITIONS: Dictionary = {
	# Combat column
	"blade_mastery_1": Vector2(80, 60),
	"blade_mastery_2": Vector2(80, 140),
	"critical_eye_1":  Vector2(180, 200),
	"berserker":       Vector2(130, 280),
	# Defense column
	"iron_body_1":    Vector2(300, 60),
	"iron_body_2":    Vector2(300, 140),
	# Survival
	"vitality_1":     Vector2(420, 60),
	# Agility
	"swift_feet_1":   Vector2(540, 60),
	"dodge_master":   Vector2(540, 140),
	# Magic
	"arcane_aptitude_1": Vector2(660, 60),
}

var _skill_tree: SkillTree = null
var _skill_buttons: Dictionary = {}   # skill_id → Button
var _selected_skill_id: StringName = &""

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	hide()
	unlock_btn.pressed.connect(_on_unlock_pressed)
	tab_bar.tab_changed.connect(_on_tab_changed)

func _input(event: InputEvent) -> void:
	if visible and event.is_action_just_pressed(&"open_inventory"):
		close()

# ─── OPEN / CLOSE ────────────────────────────────────────────────────────────

func open() -> void:
	_find_skill_tree()
	_rebuild_tree()
	show()
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_open.ogg")

func close() -> void:
	hide()
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_close.ogg")

func _find_skill_tree() -> void:
	if GameManager.player_node:
		_skill_tree = GameManager.player_node.get_node_or_null("SkillTree") as SkillTree

# ─── BUILD ───────────────────────────────────────────────────────────────────

func _rebuild_tree() -> void:
	for btn in _skill_buttons.values():
		btn.queue_free()
	_skill_buttons.clear()
	skill_container.queue_redraw()

	_update_points_label()
	var category := _get_current_category()

	for skill_id in DataManager.skills:
		var skill := DataManager.get_skill(skill_id)
		if skill.get("category", "") != category:
			continue
		if not SKILL_POSITIONS.has(str(skill_id)):
			continue

		var btn := _make_skill_button(skill_id, skill)
		_skill_buttons[skill_id] = btn

func _make_skill_button(skill_id: StringName, skill: Dictionary) -> Button:
	var btn: Button
	if ResourceLoader.exists(SKILL_BTN_SCENE):
		btn = load(SKILL_BTN_SCENE).instantiate()
	else:
		btn = Button.new()
		btn.custom_minimum_size = Vector2(48, 48)

	btn.name = str(skill_id)
	btn.tooltip_text = skill.get("name", str(skill_id))

	var pos: Vector2 = SKILL_POSITIONS.get(str(skill_id), Vector2.ZERO)
	btn.position = pos
	skill_container.add_child(btn)

	_update_button_state(btn, skill_id)
	btn.pressed.connect(func(): _on_skill_selected(skill_id))
	return btn

func _update_button_state(btn: Button, skill_id: StringName) -> void:
	if _skill_tree == null:
		return
	var unlocked := _skill_tree.has_skill(skill_id)
	var can_unlock := _skill_tree.can_unlock(skill_id)

	if unlocked:
		btn.modulate = Color(0.3, 1.0, 0.3)   # Green = unlocked
	elif can_unlock:
		btn.modulate = Color(1.0, 1.0, 0.3)   # Yellow = available
	else:
		btn.modulate = Color(0.4, 0.4, 0.4)   # Grey = locked

func _on_tab_changed(_tab: int) -> void:
	_rebuild_tree()

func _get_current_category() -> String:
	match tab_bar.current_tab:
		0: return "combat"
		1: return "defense"
		2: return "agility"
		3: return "magic"
		4: return "survival"
	return "combat"

# ─── DRAW CONNECTIONS ────────────────────────────────────────────────────────

## Called by Control's _draw — override the container's draw
func _draw_connections() -> void:
	for skill_id in _skill_buttons:
		var skill := DataManager.get_skill(skill_id)
		for prereq_str in skill.get("prerequisites", []):
			var prereq_id := StringName(prereq_str)
			if not _skill_buttons.has(prereq_id):
				continue
			var from_pos: Vector2 = SKILL_POSITIONS.get(str(prereq_id), Vector2.ZERO) + Vector2(24, 24)
			var to_pos: Vector2   = SKILL_POSITIONS.get(str(skill_id),  Vector2.ZERO) + Vector2(24, 24)
			var color := Color(0.3, 1.0, 0.3, 0.6) \
				if (_skill_tree and _skill_tree.has_skill(prereq_id)) \
				else Color(0.4, 0.4, 0.4, 0.5)
			skill_container.draw_line(from_pos, to_pos, color, 2.0)

# ─── SELECTION ───────────────────────────────────────────────────────────────

func _on_skill_selected(skill_id: StringName) -> void:
	_selected_skill_id = skill_id
	var skill := DataManager.get_skill(skill_id)
	desc_label.text = "[%s]\n%s\nCost: %d SP" % [
		skill.get("name", str(skill_id)),
		skill.get("description", ""),
		skill.get("cost", 1)
	]
	if _skill_tree:
		unlock_btn.disabled = not _skill_tree.can_unlock(skill_id) or \
			_skill_tree.has_skill(skill_id)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_click.ogg")

func _on_unlock_pressed() -> void:
	if _selected_skill_id.is_empty() or _skill_tree == null:
		return
	if _skill_tree.unlock_skill(_selected_skill_id):
		_rebuild_tree()
		_update_points_label()
		AudioManager.play_sfx_ui("res://assets/audio/sfx/skill_unlock.ogg")

func _update_points_label() -> void:
	if _skill_tree:
		var level_sys := GameManager.player_node.get_node_or_null("LevelSystem") as LevelSystem
		if level_sys:
			points_label.text = "Skill Points: %d" % level_sys.skill_points
