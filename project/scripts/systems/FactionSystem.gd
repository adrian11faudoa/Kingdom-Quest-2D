## FactionSystem.gd
## Tracks player reputation with named factions.
## Reputation affects NPC behaviour, prices, and quest availability.
##
class_name FactionSystem
extends Node

enum Standing { HOSTILE = -2, UNFRIENDLY = -1, NEUTRAL = 0, FRIENDLY = 1, HONORED = 2, EXALTED = 3 }

const MAX_REP := 1000
const MIN_REP := -1000

## Thresholds for each standing tier
const STANDING_THRESHOLDS: Dictionary = {
	Standing.HOSTILE:    -500,
	Standing.UNFRIENDLY: -100,
	Standing.NEUTRAL:       0,
	Standing.FRIENDLY:    100,
	Standing.HONORED:     500,
	Standing.EXALTED:     900,
}

## faction_id → reputation value (-1000 to 1000)
var reputations: Dictionary = {}

func _ready() -> void:
	SaveManager.register_system(get_save_data, apply_save_data)
	_init_default_factions()

func _init_default_factions() -> void:
	for faction in ["villagers", "merchants_guild", "rangers", "mages_order",
					"thieves_guild", "dark_cult", "forest_spirits", "dwarven_clans"]:
		reputations[StringName(faction)] = 0

func change_reputation(faction_id: StringName, delta: int) -> void:
	var current: int = reputations.get(faction_id, 0)
	reputations[faction_id] = clampi(current + delta, MIN_REP, MAX_REP)
	EventBus.reputation_changed.emit(faction_id, reputations[faction_id])

func get_reputation(faction_id: StringName) -> int:
	return reputations.get(faction_id, 0)

func get_standing(faction_id: StringName) -> Standing:
	var rep := get_reputation(faction_id)
	var best := Standing.HOSTILE
	for standing in STANDING_THRESHOLDS:
		if rep >= STANDING_THRESHOLDS[standing]:
			best = standing
	return best

func get_price_modifier(faction_id: StringName) -> float:
	## Friendly factions give discounts, hostile charge more
	match get_standing(faction_id):
		Standing.EXALTED:    return 0.75
		Standing.HONORED:    return 0.85
		Standing.FRIENDLY:   return 0.95
		Standing.NEUTRAL:    return 1.00
		Standing.UNFRIENDLY: return 1.15
		Standing.HOSTILE:    return 1.30
	return 1.0

func get_save_data() -> Dictionary:
	var serialised := {}
	for k in reputations:
		serialised[str(k)] = reputations[k]
	return { "factions": serialised }

func apply_save_data(data: Dictionary) -> void:
	for k in data.get("factions", {}):
		reputations[StringName(k)] = data["factions"][k]
