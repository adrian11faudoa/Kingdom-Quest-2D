## InventorySystem.gd
## Complete inventory: item stacks, equipment slots, loot drops, gold.
##
## DESIGN: Items are stored as { item_id, quantity } dictionaries.
## The actual item data lives in DataManager. This means the inventory
## stores minimal state (just IDs and counts) which is perfect for saves.
##
## Equipment uses named slots: head, chest, legs, feet, weapon, offhand, ring, amulet.
## Equipping/unequipping fires EventBus signals so UI updates automatically.
##
class_name InventorySystem
extends Node

# ─── CONFIG ──────────────────────────────────────────────────────────────────

const MAX_STACK   := 99
const MAX_SLOTS   := 40
const GOLD_ITEM_ID := &"gold"

# ─── STATE ───────────────────────────────────────────────────────────────────

## Array of { "id": StringName, "qty": int } — max MAX_SLOTS entries
var items: Array = []
var gold: int = 0

## Equipment slots: slot_name → item_id (or empty StringName)
var equipped: Dictionary = {
	&"weapon":  &"",
	&"offhand": &"",
	&"head":    &"",
	&"chest":   &"",
	&"legs":    &"",
	&"feet":    &"",
	&"ring":    &"",
	&"amulet":  &"",
}

# Shortcut hotbar: 0–3 → item_id
var hotbar: Array[StringName] = [&"", &"", &"", &""]

# Reference to player stats for equip bonuses
var _stats: StatsComponent = null

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	EventBus.item_picked_up.connect(_on_item_picked_up)
	await get_parent().ready
	_stats = get_parent().get_node_or_null("StatsComponent")
	SaveManager.register_system(get_save_data, apply_save_data)

# ─── ITEM OPERATIONS ─────────────────────────────────────────────────────────

## Add items to inventory. Returns true if fully added, false if inventory full.
func add_item(item_id: StringName, quantity: int = 1) -> bool:
	if item_id == GOLD_ITEM_ID:
		add_gold(quantity)
		return true

	var item_data := DataManager.get_item(item_id)
	if item_data.is_empty():
		push_warning("[Inventory] Unknown item: %s" % item_id)
		return false

	var remaining := quantity
	var is_stackable: bool = item_data.get("stackable", true)

	if is_stackable:
		# Try to add to existing stacks first
		for slot in items:
			if slot["id"] == item_id and slot["qty"] < MAX_STACK:
				var space := MAX_STACK - slot["qty"]
				var to_add := mini(remaining, space)
				slot["qty"] += to_add
				remaining -= to_add
				if remaining <= 0:
					break

	# Fill new slots for remainder
	while remaining > 0:
		if items.size() >= MAX_SLOTS:
			EventBus.item_picked_up.emit(item_id, quantity - remaining)
			EventBus.inventory_changed.emit()
			return false  # Inventory full
		var to_add := mini(remaining, MAX_STACK if is_stackable else 1)
		items.append({ "id": item_id, "qty": to_add })
		remaining -= to_add

	EventBus.inventory_changed.emit()
	return true

func remove_item(item_id: StringName, quantity: int = 1) -> bool:
	if not has_item(item_id, quantity):
		return false
	var remaining := quantity
	var to_remove_indices: Array[int] = []

	for i in items.size():
		if items[i]["id"] == item_id:
			var available: int = items[i]["qty"]
			if available <= remaining:
				remaining -= available
				to_remove_indices.append(i)
			else:
				items[i]["qty"] -= remaining
				remaining = 0
				break

	# Remove in reverse to preserve indices
	to_remove_indices.reverse()
	for i in to_remove_indices:
		items.remove_at(i)

	EventBus.inventory_changed.emit()
	return true

func has_item(item_id: StringName, quantity: int = 1) -> bool:
	var count := count_item(item_id)
	return count >= quantity

func count_item(item_id: StringName) -> int:
	var total := 0
	for slot in items:
		if slot["id"] == item_id:
			total += slot["qty"]
	return total

# ─── GOLD ────────────────────────────────────────────────────────────────────

func add_gold(amount: int) -> void:
	gold += amount
	EventBus.gold_changed.emit(gold)

func spend_gold(amount: int) -> bool:
	if gold < amount:
		return false
	gold -= amount
	EventBus.gold_changed.emit(gold)
	return true

func can_afford(amount: int) -> bool:
	return gold >= amount

# ─── EQUIPMENT ───────────────────────────────────────────────────────────────

func equip_item(item_id: StringName) -> bool:
	var item_data := DataManager.get_item(item_id)
	if item_data.is_empty():
		return false

	var slot: StringName = item_data.get("slot", &"")
	if slot.is_empty() or not equipped.has(slot):
		push_warning("[Inventory] Item %s has no valid slot" % item_id)
		return false

	# Unequip current item in that slot first
	var current: StringName = equipped[slot]
	if not current.is_empty():
		unequip_slot(slot)

	equipped[slot] = item_id
	_apply_equip_bonuses(item_data, true)
	EventBus.item_equipped.emit(item_id, slot)
	return true

func unequip_slot(slot: StringName) -> void:
	var item_id: StringName = equipped.get(slot, &"")
	if item_id.is_empty():
		return
	var item_data := DataManager.get_item(item_id)
	if not item_data.is_empty():
		_apply_equip_bonuses(item_data, false)
	equipped[slot] = &""
	EventBus.item_unequipped.emit(item_id, slot)

func get_equipped(slot: StringName) -> StringName:
	return equipped.get(slot, &"")

func _apply_equip_bonuses(item_data: Dictionary, equipping: bool) -> void:
	if _stats == null:
		return
	var sign := 1 if equipping else -1
	_stats.add_attack_bonus(item_data.get("attack_bonus", 0) * sign)
	_stats.add_defense_bonus(item_data.get("defense_bonus", 0) * sign)
	_stats.add_speed_bonus(item_data.get("speed_bonus", 0.0) * sign)
	# Max health bonus requires special handling
	var hp_bonus: int = item_data.get("health_bonus", 0) * sign
	if hp_bonus != 0:
		_stats.set_max_health(_stats.max_health + hp_bonus)

# ─── USE ITEM ────────────────────────────────────────────────────────────────

func use_item(item_id: StringName) -> bool:
	if not has_item(item_id):
		return false

	var item_data := DataManager.get_item(item_id)
	if item_data.is_empty() or not item_data.get("usable", false):
		return false

	var use_type: String = item_data.get("use_type", "")
	match use_type:
		"heal":
			var amount: int = item_data.get("heal_amount", 0)
			if _stats:
				_stats.heal(amount)
		"restore_mana":
			var amount: int = item_data.get("mana_amount", 0)
			if _stats:
				_stats.restore_mana(amount)
		"restore_stamina":
			var amount: float = item_data.get("stamina_amount", 0.0)
			if _stats:
				_stats.current_stamina = minf(_stats.max_stamina, _stats.current_stamina + amount)
		"buff":
			var effect_id: StringName = item_data.get("effect_id", &"")
			var duration: float = item_data.get("duration", 30.0)
			if _stats and not effect_id.is_empty():
				_stats.apply_status(effect_id, duration)
		_:
			return false

	remove_item(item_id, 1)
	EventBus.item_used.emit(item_id)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/use_item.ogg")
	return true

# ─── HOTBAR ──────────────────────────────────────────────────────────────────

func set_hotbar(slot: int, item_id: StringName) -> void:
	if slot < 0 or slot >= hotbar.size():
		return
	hotbar[slot] = item_id

func use_hotbar(slot: int) -> bool:
	if slot < 0 or slot >= hotbar.size():
		return false
	var item_id: StringName = hotbar[slot]
	if item_id.is_empty():
		return false
	return use_item(item_id)

# ─── LOOT TABLES ─────────────────────────────────────────────────────────────

## Roll a loot table and add results to inventory (or drop at position).
## loot_table: [{ "item_id": id, "weight": int, "min": int, "max": int }]
static func roll_loot(loot_table: Array) -> Array:
	var results: Array = []
	for entry in loot_table:
		var weight: int = entry.get("weight", 100)
		if randi() % 100 < weight:
			var qty := randi_range(entry.get("min", 1), entry.get("max", 1))
			results.append({ "id": StringName(entry["item_id"]), "qty": qty })
	return results

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	# Serialise equipped — convert StringNames to strings
	var eq_serialised := {}
	for slot in equipped:
		eq_serialised[str(slot)] = str(equipped[slot])

	var item_serialised := []
	for slot in items:
		item_serialised.append({ "id": str(slot["id"]), "qty": slot["qty"] })

	return {
		"inventory": {
			"items":    item_serialised,
			"gold":     gold,
			"equipped": eq_serialised,
			"hotbar":   hotbar.map(func(s): return str(s)),
		}
	}

func apply_save_data(data: Dictionary) -> void:
	var d: Dictionary = data.get("inventory", {})
	gold = d.get("gold", 0)

	items.clear()
	for slot in d.get("items", []):
		items.append({ "id": StringName(slot["id"]), "qty": slot["qty"] })

	var eq_data: Dictionary = d.get("equipped", {})
	for slot_str in eq_data:
		var slot := StringName(slot_str)
		var item_id := StringName(eq_data[slot_str])
		if equipped.has(slot):
			equipped[slot] = item_id
			if not item_id.is_empty():
				var item_data := DataManager.get_item(item_id)
				_apply_equip_bonuses(item_data, true)

	var hb: Array = d.get("hotbar", [])
	for i in mini(hb.size(), hotbar.size()):
		hotbar[i] = StringName(hb[i])

	EventBus.inventory_changed.emit()
	EventBus.gold_changed.emit(gold)
