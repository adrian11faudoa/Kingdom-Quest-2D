## StatsComponent.gd
## Reusable component for health, mana, stamina, and derived combat stats.
##
## DESIGN: Composition over inheritance. Both Player and Enemy scenes
## contain a StatsComponent node. This avoids a deep inheritance chain
## and makes it easy to add stats to any entity (NPCs, bosses, companions).
##
## Any node that owns a StatsComponent gets:
##   - Health / Mana / Stamina with regeneration
##   - Damage application with mitigation
##   - Status effects
##   - Death detection
##
class_name StatsComponent
extends Node

# ─── EXPORTS (set per-entity in the Inspector or from data) ──────────────────

@export_group("Health")
@export var max_health: int    = 100
@export var health_regen: float = 0.0   # per second

@export_group("Mana")
@export var max_mana: int      = 50
@export var mana_regen: float  = 2.0   # per second

@export_group("Stamina")
@export var max_stamina: float = 100.0
@export var stamina_regen: float = 15.0  # per second
@export var stamina_regen_delay: float = 1.5  # seconds after use before regen

@export_group("Combat")
@export var base_attack: int   = 10
@export var base_defense: int  = 5
@export var base_speed: float  = 120.0
@export var crit_chance: float = 0.05   # 0.0–1.0
@export var crit_multiplier: float = 2.0

@export_group("XP")
@export var xp_reward: int = 0   # XP this entity gives when killed (0 = player)

# ─── RUNTIME STATE ───────────────────────────────────────────────────────────

var current_health: int = 0
var current_mana: int = 0
var current_stamina: float = 0.0
var is_dead: bool = false
var is_invincible: bool = false

var _stamina_regen_timer: float = 0.0

# Modifier stacks — additive bonuses from equipment, buffs, skills
var _attack_bonus: int   = 0
var _defense_bonus: int  = 0
var _speed_bonus: float  = 0.0

# Status effects: effect_id → { "duration": float, "stacks": int, "data": Dictionary }
var _status_effects: Dictionary = {}

# ─── SIGNALS ─────────────────────────────────────────────────────────────────

signal health_changed(current: int, maximum: int)
signal mana_changed(current: int, maximum: int)
signal stamina_changed(current: float, maximum: float)
signal died()
signal status_effect_added(effect_id: StringName)
signal status_effect_removed(effect_id: StringName)

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	current_health  = max_health
	current_mana    = max_mana
	current_stamina = max_stamina

func _process(delta: float) -> void:
	if is_dead:
		return
	_tick_regen(delta)
	_tick_status_effects(delta)

# ─── HEALTH ──────────────────────────────────────────────────────────────────

## Apply damage to this entity. Returns actual damage dealt.
func take_damage(raw_damage: int, damage_type: StringName = &"physical",
		source: Node = null, is_crit: bool = false) -> int:
	if is_dead or is_invincible:
		return 0

	var mitigated := _calculate_mitigation(raw_damage, damage_type)
	var final_damage := maxi(1, mitigated)  # Always deal at least 1

	current_health = maxi(0, current_health - final_damage)

	# Notify via signal and global bus
	health_changed.emit(current_health, max_health)
	EventBus.entity_damaged.emit(get_parent(), final_damage, damage_type, is_crit)

	if current_health <= 0:
		_die()

	return final_damage

func heal(amount: int) -> void:
	if is_dead:
		return
	current_health = mini(max_health, current_health + amount)
	health_changed.emit(current_health, max_health)
	EventBus.entity_healed.emit(get_parent(), amount)

func _calculate_mitigation(raw: int, damage_type: StringName) -> int:
	var defense := get_total_defense()
	match damage_type:
		&"physical":
			# Flat reduction formula — simple and predictable
			return maxi(0, raw - defense)
		&"magic":
			# Magic pierces half of defense
			return maxi(0, raw - defense / 2)
		&"true":
			# True damage bypasses all defense
			return raw
		_:
			return raw

func set_max_health(new_max: int, heal_difference: bool = false) -> void:
	var old_max := max_health
	max_health = maxi(1, new_max)
	if heal_difference and new_max > old_max:
		current_health += new_max - old_max
	current_health = mini(current_health, max_health)
	health_changed.emit(current_health, max_health)

# ─── MANA ────────────────────────────────────────────────────────────────────

func spend_mana(amount: int) -> bool:
	if current_mana < amount:
		return false
	current_mana -= amount
	mana_changed.emit(current_mana, max_mana)
	return true

func restore_mana(amount: int) -> void:
	current_mana = mini(max_mana, current_mana + amount)
	mana_changed.emit(current_mana, max_mana)

func has_mana(amount: int) -> bool:
	return current_mana >= amount

# ─── STAMINA ─────────────────────────────────────────────────────────────────

func spend_stamina(amount: float) -> bool:
	if current_stamina < amount:
		return false
	current_stamina -= amount
	_stamina_regen_timer = stamina_regen_delay
	stamina_changed.emit(current_stamina, max_stamina)
	return true

func has_stamina(amount: float) -> bool:
	return current_stamina >= amount

# ─── REGENERATION ────────────────────────────────────────────────────────────

func _tick_regen(delta: float) -> void:
	# Health regen
	if health_regen > 0.0 and current_health < max_health:
		current_health = mini(max_health, current_health + int(health_regen * delta))
		health_changed.emit(current_health, max_health)

	# Mana regen
	if mana_regen > 0.0 and current_mana < max_mana:
		current_mana = mini(max_mana, current_mana + int(mana_regen * delta))
		mana_changed.emit(current_mana, max_mana)

	# Stamina regen (delayed after use)
	if _stamina_regen_timer > 0.0:
		_stamina_regen_timer -= delta
	elif current_stamina < max_stamina:
		current_stamina = minf(max_stamina, current_stamina + stamina_regen * delta)
		stamina_changed.emit(current_stamina, max_stamina)

# ─── STATUS EFFECTS ──────────────────────────────────────────────────────────

func apply_status(effect_id: StringName, duration: float,
		stacks: int = 1, data: Dictionary = {}) -> void:
	if _status_effects.has(effect_id):
		# Refresh duration and add stacks (up to max)
		_status_effects[effect_id]["duration"] = maxf(
			_status_effects[effect_id]["duration"], duration)
		_status_effects[effect_id]["stacks"] = mini(
			_status_effects[effect_id]["stacks"] + stacks,
			data.get("max_stacks", 5))
	else:
		_status_effects[effect_id] = {
			"duration": duration,
			"stacks":   stacks,
			"data":     data,
			"tick_timer": data.get("tick_interval", 0.0)
		}
		status_effect_added.emit(effect_id)
		EventBus.status_effect_applied.emit(get_parent(), effect_id)

func remove_status(effect_id: StringName) -> void:
	if _status_effects.erase(effect_id):
		status_effect_removed.emit(effect_id)
		EventBus.status_effect_removed.emit(get_parent(), effect_id)

func has_status(effect_id: StringName) -> bool:
	return _status_effects.has(effect_id)

func _tick_status_effects(delta: float) -> void:
	var to_remove: Array[StringName] = []
	for effect_id in _status_effects:
		var effect: Dictionary = _status_effects[effect_id]
		effect["duration"] -= delta

		# Tick-based effects (poison, burn, etc.)
		if effect["data"].get("tick_damage", 0) > 0:
			effect["tick_timer"] -= delta
			if effect["tick_timer"] <= 0.0:
				effect["tick_timer"] = effect["data"].get("tick_interval", 1.0)
				take_damage(
					effect["data"]["tick_damage"] * effect["stacks"],
					effect["data"].get("damage_type", &"magic"))

		if effect["duration"] <= 0.0:
			to_remove.append(effect_id)

	for effect_id in to_remove:
		remove_status(effect_id)

# ─── DERIVED STATS ───────────────────────────────────────────────────────────

func get_total_attack() -> int:
	var mult := 1.0
	if has_status(&"strength_buff"):  mult += 0.3
	if has_status(&"weakness"):       mult -= 0.3
	return int((base_attack + _attack_bonus) * mult)

func get_total_defense() -> int:
	var mult := 1.0
	if has_status(&"shield_buff"):    mult += 0.5
	if has_status(&"vulnerable"):     mult -= 0.5
	return int((base_defense + _defense_bonus) * mult)

func get_total_speed() -> float:
	var mult := 1.0
	if has_status(&"haste"):   mult += 0.3
	if has_status(&"slow"):    mult -= 0.4
	if has_status(&"frozen"):  mult = 0.0
	return maxf(0.0, (base_speed + _speed_bonus) * mult)

func add_attack_bonus(amount: int)  -> void: _attack_bonus  += amount
func add_defense_bonus(amount: int) -> void: _defense_bonus += amount
func add_speed_bonus(amount: float) -> void: _speed_bonus   += amount

func roll_crit() -> bool:
	return randf() < crit_chance

# ─── DEATH ───────────────────────────────────────────────────────────────────

func _die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	EventBus.entity_died.emit(get_parent())

func revive(health_percent: float = 1.0) -> void:
	is_dead = false
	current_health = int(max_health * clampf(health_percent, 0.0, 1.0))
	current_mana   = max_mana
	_status_effects.clear()
	health_changed.emit(current_health, max_health)

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	return {
		"health":  current_health,
		"mana":    current_mana,
		"stamina": current_stamina,
	}

func apply_save_data(data: Dictionary) -> void:
	current_health  = data.get("health",  max_health)
	current_mana    = data.get("mana",    max_mana)
	current_stamina = data.get("stamina", max_stamina)
	health_changed.emit(current_health, max_health)
	mana_changed.emit(current_mana, max_mana)
	stamina_changed.emit(current_stamina, max_stamina)
