## SkillTree.gd
## Node-based skill tree with prerequisites and passive/active skills.
##
## SKILL JSON FORMAT:
## {
##   "id": "blade_mastery",
##   "name": "Blade Mastery",
##   "description": "Increases sword damage by 15%.",
##   "category": "combat",
##   "tier": 1,
##   "cost": 1,
##   "prerequisites": [],
##   "effect": { "type": "stat_bonus", "stat": "attack_percent", "value": 0.15 },
##   "icon": "res://assets/art/ui/icons/skills/blade_mastery.png"
## }
##
class_name SkillTree
extends Node

var unlocked_skills: Array[StringName] = []
var _stats: StatsComponent = null
var _level_system: LevelSystem = null

func _ready() -> void:
	await get_parent().ready
	_stats       = get_parent().get_node_or_null("StatsComponent")
	_level_system = get_parent().get_node_or_null("LevelSystem")
	SaveManager.register_system(get_save_data, apply_save_data)

# ─── UNLOCK ──────────────────────────────────────────────────────────────────

func can_unlock(skill_id: StringName) -> bool:
	if has_skill(skill_id):
		return false
	var skill := DataManager.get_skill(skill_id)
	if skill.is_empty():
		return false

	# Check skill points
	var cost: int = skill.get("cost", 1)
	if _level_system == null or _level_system.skill_points < cost:
		return false

	# Check prerequisites
	for prereq in skill.get("prerequisites", []):
		if not has_skill(StringName(prereq)):
			return false

	return true

func unlock_skill(skill_id: StringName) -> bool:
	if not can_unlock(skill_id):
		return false

	var skill := DataManager.get_skill(skill_id)
	var cost: int = skill.get("cost", 1)
	_level_system.skill_points -= cost
	unlocked_skills.append(skill_id)
	_apply_skill_effect(skill, true)
	print("[SkillTree] Unlocked: %s" % skill_id)
	return true

func has_skill(skill_id: StringName) -> bool:
	return skill_id in unlocked_skills

# ─── EFFECTS ─────────────────────────────────────────────────────────────────

func _apply_skill_effect(skill: Dictionary, apply: bool) -> void:
	if _stats == null:
		return
	var effect: Dictionary = skill.get("effect", {})
	var sign := 1 if apply else -1

	match effect.get("type", ""):
		"stat_bonus":
			match effect.get("stat", ""):
				"attack":
					_stats.add_attack_bonus(int(effect.get("value", 0)) * sign)
				"defense":
					_stats.add_defense_bonus(int(effect.get("value", 0)) * sign)
				"speed":
					_stats.add_speed_bonus(float(effect.get("value", 0.0)) * sign)
				"max_health":
					_stats.set_max_health(_stats.max_health + int(effect.get("value", 0)) * sign)
				"max_mana":
					_stats.max_mana += int(effect.get("value", 0)) * sign
				"crit_chance":
					_stats.crit_chance += float(effect.get("value", 0.0)) * sign
				"crit_mult":
					_stats.crit_multiplier += float(effect.get("value", 0.0)) * sign
		"attack_percent":
			# Applied multiplicatively at attack calculation time — store flag
			pass
		"unlock_ability":
			# Grants access to a new move or spell
			pass

# ─── QUERY ───────────────────────────────────────────────────────────────────

func get_skills_by_category(category: String) -> Array:
	var result: Array = []
	for skill_id in DataManager.skills:
		var skill := DataManager.get_skill(skill_id)
		if skill.get("category", "") == category:
			result.append({
				"id":       skill_id,
				"skill":    skill,
				"unlocked": has_skill(skill_id),
				"can_unlock": can_unlock(skill_id),
			})
	return result

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	return { "skills": { "unlocked": unlocked_skills.map(func(s): return str(s)) } }

func apply_save_data(data: Dictionary) -> void:
	unlocked_skills.clear()
	for sid in data.get("skills", {}).get("unlocked", []):
		var skill_id := StringName(sid)
		unlocked_skills.append(skill_id)
		var skill := DataManager.get_skill(skill_id)
		if not skill.is_empty():
			_apply_skill_effect(skill, true)
