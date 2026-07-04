## LevelSystem.gd
## Handles XP accumulation, leveling up, and stat growth.
##
## DESIGN: Attached to Player as a child component. Decoupled from StatsComponent
## so leveling logic stays isolated. Uses exponential XP curve configurable
## from one constant — easy to balance without touching code.
##
class_name LevelSystem
extends Node

# ─── CONFIG ──────────────────────────────────────────────────────────────────

## XP needed for level N = BASE * (GROWTH ^ (N-1))
const BASE_XP   := 100
const GROWTH     := 1.35
const MAX_LEVEL  := 50

## Stat gains per level
const HP_PER_LEVEL      := 8
const MANA_PER_LEVEL    := 5
const ATTACK_PER_LEVEL  := 2
const DEFENSE_PER_LEVEL := 1

# ─── STATE ───────────────────────────────────────────────────────────────────

var current_level: int = 1
var current_xp: int    = 0
var skill_points: int  = 0

@onready var stats: StatsComponent = get_parent().get_node("StatsComponent")

# ─── SIGNALS ─────────────────────────────────────────────────────────────────

signal level_up(new_level: int, skill_points_gained: int)
signal xp_gained(amount: int, total: int, next_level_xp: int)

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	EventBus.enemy_killed.connect(_on_enemy_killed)

func _on_enemy_killed(enemy_id: StringName, _position: Vector2) -> void:
	var enemy_data := DataManager.get_enemy(enemy_id)
	if enemy_data.is_empty():
		return
	var base_xp: int = enemy_data.get("xp_reward", 0)
	# Apply XP multiplier from difficulty
	var xp := int(base_xp * GameManager.get_difficulty_modifier("xp_mult"))
	if xp > 0:
		add_xp(xp)

# ─── XP & LEVELING ───────────────────────────────────────────────────────────

func add_xp(amount: int) -> void:
	if current_level >= MAX_LEVEL:
		return
	current_xp += amount
	EventBus.player_xp_gained.emit(amount, current_xp)
	xp_gained.emit(amount, current_xp, xp_for_next_level())

	while current_xp >= xp_for_next_level() and current_level < MAX_LEVEL:
		current_xp -= xp_for_next_level()
		_do_level_up()

func _do_level_up() -> void:
	current_level += 1
	skill_points  += 1

	# Apply stat growth to StatsComponent
	if stats:
		stats.set_max_health(stats.max_health + HP_PER_LEVEL, true)
		stats.max_mana    += MANA_PER_LEVEL
		stats.base_attack += ATTACK_PER_LEVEL
		stats.base_defense += DEFENSE_PER_LEVEL

	level_up.emit(current_level, skill_points)
	EventBus.player_leveled_up.emit(current_level)
	print("[LevelSystem] Level up! Now level %d" % current_level)

func xp_for_next_level() -> int:
	return int(BASE_XP * pow(GROWTH, current_level - 1))

func xp_progress_ratio() -> float:
	return float(current_xp) / float(xp_for_next_level())

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	return {
		"level_system": {
			"level":        current_level,
			"xp":           current_xp,
			"skill_points": skill_points,
		}
	}

func apply_save_data(data: Dictionary) -> void:
	var d: Dictionary = data.get("level_system", {})
	current_level = d.get("level",        1)
	current_xp    = d.get("xp",           0)
	skill_points  = d.get("skill_points", 0)
