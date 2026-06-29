## EventBus.gd
## Central signal hub for decoupled, system-to-system communication.
##
## DESIGN PHILOSOPHY:
## Instead of hard-wiring references between systems (Player → QuestManager → UI),
## every system emits and receives events through this singleton. This means:
##   - Systems don't know each other exist (loose coupling)
##   - Adding a new listener never breaks existing code
##   - Easy to trace the flow of any game event for debugging
##   - Systems can be removed/replaced without cascading changes
##
## USAGE:
##   Emitting:  EventBus.player_died.emit()
##   Listening: EventBus.player_died.connect(_on_player_died)
##
extends Node

# ─── PLAYER SIGNALS ──────────────────────────────────────────────────────────
signal player_health_changed(current: int, maximum: int)
signal player_mana_changed(current: int, maximum: int)
signal player_stamina_changed(current: float, maximum: float)
signal player_xp_gained(amount: int, total: int)
signal player_leveled_up(new_level: int)
signal player_died()
signal player_respawned()
signal player_entered_region(region_id: StringName)
signal player_exited_region(region_id: StringName)

# ─── COMBAT SIGNALS ──────────────────────────────────────────────────────────
signal entity_damaged(entity: Node, damage: int, damage_type: StringName, is_critical: bool)
signal entity_healed(entity: Node, amount: int)
signal entity_died(entity: Node)
signal enemy_killed(enemy_id: StringName, position: Vector2)
signal status_effect_applied(entity: Node, effect_id: StringName)
signal status_effect_removed(entity: Node, effect_id: StringName)
signal combo_hit(combo_count: int)

# ─── QUEST SIGNALS ───────────────────────────────────────────────────────────
signal quest_started(quest_id: StringName)
signal quest_objective_updated(quest_id: StringName, objective_id: StringName, progress: int, target: int)
signal quest_completed(quest_id: StringName)
signal quest_failed(quest_id: StringName)

# ─── DIALOGUE SIGNALS ────────────────────────────────────────────────────────
signal dialogue_started(dialogue_id: StringName, speaker_name: String)
signal dialogue_line_shown(line: String, speaker: String)
signal dialogue_choice_presented(choices: Array)
signal dialogue_choice_selected(choice_index: int)
signal dialogue_ended()

# ─── INVENTORY / ITEM SIGNALS ────────────────────────────────────────────────
signal item_picked_up(item_id: StringName, quantity: int)
signal item_dropped(item_id: StringName, quantity: int)
signal item_equipped(item_id: StringName, slot: StringName)
signal item_unequipped(item_id: StringName, slot: StringName)
signal item_used(item_id: StringName)
signal inventory_changed()
signal gold_changed(new_amount: int)

# ─── CRAFTING SIGNALS ────────────────────────────────────────────────────────
signal item_crafted(item_id: StringName)
signal item_upgraded(item_id: StringName, new_tier: int)

# ─── WORLD SIGNALS ───────────────────────────────────────────────────────────
signal time_of_day_changed(hour: float)
signal day_started(day_number: int)
signal night_started(day_number: int)
signal weather_changed(weather_type: StringName)
signal region_loaded(region_id: StringName)
signal region_unloaded(region_id: StringName)
signal world_event_triggered(event_id: StringName)
signal chest_opened(chest_id: StringName)
signal secret_found(secret_id: StringName)

# ─── UI / SYSTEM SIGNALS ─────────────────────────────────────────────────────
signal game_paused()
signal game_resumed()
signal scene_transition_started(target_scene: String)
signal scene_transition_finished()
signal save_requested()
signal load_requested(slot: int)
signal save_completed(slot: int)
signal load_completed()
signal settings_changed(setting_key: StringName, value: Variant)

# ─── NPC / FACTION SIGNALS ───────────────────────────────────────────────────
signal reputation_changed(faction_id: StringName, new_value: int)
signal npc_schedule_changed(npc_id: StringName, activity: StringName)

# ─── COMPANION SIGNALS ───────────────────────────────────────────────────────
signal companion_joined(companion_id: StringName)
signal companion_left(companion_id: StringName)
signal companion_ability_used(companion_id: StringName, ability_id: StringName)

# ─── MINIGAME SIGNALS ────────────────────────────────────────────────────────
signal fishing_started()
signal fishing_catch(fish_id: StringName, rarity: StringName)
signal fishing_ended()
signal farming_crop_planted(crop_id: StringName, plot_id: int)
signal farming_crop_harvested(crop_id: StringName, plot_id: int, yield_amount: int)
