## SkillNode.gd
## Individual skill tree node button.
## Visual state (locked/available/unlocked) is set by SkillTreeUI.
extends Button

@onready var icon_rect: TextureRect = $Icon
@onready var cost_label: Label      = $CostLabel

func set_skill_display(skill_data: Dictionary, unlocked: bool, can_unlock: bool) -> void:
	var icon_path: String = skill_data.get("icon", "")
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		icon_rect.texture = load(icon_path)

	cost_label.text = str(skill_data.get("cost", 1))

	if unlocked:
		modulate = Color(0.3, 1.0, 0.3)
		disabled = true
	elif can_unlock:
		modulate = Color(1.0, 1.0, 0.3)
		disabled = false
	else:
		modulate = Color(0.4, 0.4, 0.4)
		disabled = true

	tooltip_text = "%s\n%s\nCost: %d SP" % [
		skill_data.get("name", ""),
		skill_data.get("description", ""),
		skill_data.get("cost", 1)
	]
