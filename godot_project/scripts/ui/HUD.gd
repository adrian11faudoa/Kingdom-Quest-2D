## HUD.gd
## Main heads-up display: vitals bars, hotbar, minimap, notifications.
## Connects to EventBus — never polls player directly.
##
extends CanvasLayer

# ─── NODE REFS ───────────────────────────────────────────────────────────────

@onready var health_bar: ProgressBar    = $Vitals/HealthBar
@onready var mana_bar: ProgressBar      = $Vitals/ManaBar
@onready var stamina_bar: ProgressBar   = $Vitals/StaminaBar
@onready var xp_bar: ProgressBar        = $XPBar
@onready var level_label: Label         = $LevelLabel
@onready var gold_label: Label          = $GoldLabel
@onready var hotbar: HBoxContainer      = $Hotbar
@onready var minimap: SubViewportContainer = $Minimap
@onready var notification_container: VBoxContainer = $Notifications
@onready var compass: TextureRect       = $Compass
@onready var time_label: Label          = $TimeLabel
@onready var boss_bar_container: Control = $BossBar
@onready var boss_health_bar: ProgressBar = $BossBar/BossHealthBar
@onready var boss_name_label: Label     = $BossBar/BossNameLabel

const NOTIF_SCENE := "res://scenes/ui/hud/Notification.tscn"
const BAR_SMOOTH_SPEED := 8.0

# Smoothed bar targets for animation
var _target_health_ratio: float  = 1.0
var _target_mana_ratio: float    = 1.0
var _target_stamina_ratio: float = 1.0

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	_connect_events()
	boss_bar_container.hide()

func _connect_events() -> void:
	EventBus.player_health_changed.connect(_on_health_changed)
	EventBus.player_mana_changed.connect(_on_mana_changed)
	EventBus.player_stamina_changed.connect(_on_stamina_changed)
	EventBus.player_xp_gained.connect(_on_xp_gained)
	EventBus.player_leveled_up.connect(_on_level_up)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.inventory_changed.connect(_on_inventory_changed)
	EventBus.item_picked_up.connect(_on_item_picked_up)
	EventBus.quest_started.connect(_on_quest_started)
	EventBus.quest_completed.connect(_on_quest_completed)
	EventBus.quest_objective_updated.connect(_on_objective_updated)
	EventBus.combo_hit.connect(_on_combo_hit)
	EventBus.time_of_day_changed.connect(_on_time_changed)

func _process(delta: float) -> void:
	_smooth_bars(delta)

# ─── VITAL BARS ──────────────────────────────────────────────────────────────

func _on_health_changed(current: int, maximum: int) -> void:
	_target_health_ratio = float(current) / float(maximum)
	health_bar.max_value = maximum
	# Show flash effect when low
	if _target_health_ratio < 0.25:
		_pulse_bar(health_bar, Color(1.0, 0.2, 0.2))

func _on_mana_changed(current: int, maximum: int) -> void:
	_target_mana_ratio = float(current) / float(maximum)
	mana_bar.max_value = maximum

func _on_stamina_changed(current: float, maximum: float) -> void:
	_target_stamina_ratio = current / maximum
	stamina_bar.max_value = maximum

func _smooth_bars(delta: float) -> void:
	health_bar.value  = lerpf(health_bar.value,
		_target_health_ratio  * health_bar.max_value,  BAR_SMOOTH_SPEED * delta)
	mana_bar.value    = lerpf(mana_bar.value,
		_target_mana_ratio    * mana_bar.max_value,    BAR_SMOOTH_SPEED * delta)
	stamina_bar.value = lerpf(stamina_bar.value,
		_target_stamina_ratio * stamina_bar.max_value, BAR_SMOOTH_SPEED * delta)

func _pulse_bar(bar: ProgressBar, color: Color) -> void:
	var tween := create_tween().set_loops(2)
	tween.tween_property(bar, "modulate", color, 0.15)
	tween.tween_property(bar, "modulate", Color.WHITE, 0.15)

# ─── XP & LEVEL ──────────────────────────────────────────────────────────────

func _on_xp_gained(amount: int, _total: int) -> void:
	_show_notification("+%d XP" % amount, Color(0.8, 1.0, 0.3))

func _on_level_up(new_level: int) -> void:
	level_label.text = "Lv.%d" % new_level
	_show_notification("LEVEL UP! → %d" % new_level, Color(1.0, 0.9, 0.0), 3.0)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/level_up.ogg")

# ─── GOLD ────────────────────────────────────────────────────────────────────

func _on_gold_changed(amount: int) -> void:
	gold_label.text = "%d" % amount

# ─── HOTBAR ──────────────────────────────────────────────────────────────────

func _on_inventory_changed() -> void:
	_refresh_hotbar()

func _refresh_hotbar() -> void:
	var inventory := get_tree().get_first_node_in_group("inventory") as InventorySystem
	if inventory == null:
		return
	for i in hotbar.get_child_count():
		var slot := hotbar.get_child(i)
		var item_id: StringName = inventory.hotbar[i] if i < inventory.hotbar.size() else &""
		if slot.has_method("set_item"):
			slot.set_item(item_id)

func _on_item_picked_up(item_id: StringName, quantity: int) -> void:
	var item_data := DataManager.get_item(item_id)
	var name_str: String = item_data.get("name", str(item_id))
	_show_notification("Got: %s x%d" % [name_str, quantity], Color.WHITE, 2.0)

# ─── NOTIFICATIONS ───────────────────────────────────────────────────────────

func _show_notification(text: String, color: Color = Color.WHITE, duration: float = 2.5) -> void:
	if not ResourceLoader.exists(NOTIF_SCENE):
		return
	var notif: Label = load(NOTIF_SCENE).instantiate()
	notification_container.add_child(notif)
	if notif.has_method("show_text"):
		notif.show_text(text, color, duration)

func _on_quest_started(quest_id: StringName) -> void:
	var quest_data := DataManager.get_quest(quest_id)
	_show_notification("Quest Started: " + quest_data.get("title", str(quest_id)),
		Color(0.4, 0.8, 1.0), 3.0)

func _on_quest_completed(quest_id: StringName) -> void:
	var quest_data := DataManager.get_quest(quest_id)
	_show_notification("Quest Complete: " + quest_data.get("title", str(quest_id)),
		Color(0.3, 1.0, 0.4), 4.0)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/quest_complete.ogg")

func _on_objective_updated(quest_id: StringName, _obj_id: StringName,
		progress: int, target: int) -> void:
	var quest_data := DataManager.get_quest(quest_id)
	var title := quest_data.get("title", str(quest_id))
	_show_notification("%s: %d/%d" % [title, progress, target], Color(0.9, 0.9, 0.9), 2.0)

# ─── COMBO ───────────────────────────────────────────────────────────────────

@onready var combo_label: Label = $ComboLabel

func _on_combo_hit(count: int) -> void:
	if combo_label:
		combo_label.text = "%d HIT COMBO!" % count
		combo_label.modulate.a = 1.0
		var tween := create_tween()
		tween.tween_interval(0.8)
		tween.tween_property(combo_label, "modulate:a", 0.0, 0.4)

# ─── TIME ────────────────────────────────────────────────────────────────────

func _on_time_changed(hour: float) -> void:
	var day_night := get_tree().get_first_node_in_group("daynight") as DayNightSystem
	if day_night and time_label:
		time_label.text = day_night.get_time_string()

# ─── BOSS BAR ────────────────────────────────────────────────────────────────

func show_boss_bar(boss_name: String, max_hp: int) -> void:
	boss_bar_container.show()
	boss_name_label.text  = boss_name
	boss_health_bar.max_value = max_hp
	boss_health_bar.value = max_hp

func update_boss_bar(current_hp: int) -> void:
	boss_health_bar.value = current_hp

func hide_boss_bar() -> void:
	var tween := create_tween()
	tween.tween_property(boss_bar_container, "modulate:a", 0.0, 1.0)
	tween.tween_callback(boss_bar_container.hide)
