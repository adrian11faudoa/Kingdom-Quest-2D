## MainMenu.gd
## Main menu: new game, load game (slot picker), credits, quit.
##
extends Control

@onready var menu_panel: Control     = $MenuPanel
@onready var new_game_btn: Button    = $MenuPanel/VBox/NewGameBtn
@onready var load_game_btn: Button   = $MenuPanel/VBox/LoadGameBtn
@onready var settings_btn: Button    = $MenuPanel/VBox/SettingsBtn
@onready var credits_btn: Button     = $MenuPanel/VBox/CreditsBtn
@onready var quit_btn: Button        = $MenuPanel/VBox/QuitBtn
@onready var slot_panel: Control     = $SlotPanel
@onready var settings_panel: Control = $SettingsPanel
@onready var version_label: Label    = $VersionLabel
@onready var logo: TextureRect       = $Logo

const FIRST_SCENE := "res://scenes/world/regions/StartingVillage.tscn"

func _ready() -> void:
	GameManager.change_state(GameManager.GameState.MAIN_MENU)
	version_label.text = "v%s" % ProjectSettings.get_setting("application/config/version", "0.1")

	new_game_btn.pressed.connect(_on_new_game)
	load_game_btn.pressed.connect(_on_load_game)
	settings_btn.pressed.connect(_on_settings)
	credits_btn.pressed.connect(_on_credits)
	quit_btn.pressed.connect(_on_quit)

	# Animate logo in
	if logo:
		logo.modulate.a = 0.0
		var tween := create_tween()
		tween.tween_property(logo, "modulate:a", 1.0, 1.2)

	# Check for existing saves and enable load button
	load_game_btn.disabled = not _any_save_exists()

func _on_new_game() -> void:
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_confirm.ogg")
	# If saves exist, confirm before overwriting
	SceneTransition.go_to(FIRST_SCENE)

func _on_load_game() -> void:
	menu_panel.hide()
	slot_panel.show()
	_populate_slots()

func _populate_slots() -> void:
	for i in range(1, SaveManager.SAVE_SLOTS + 1):
		var btn := slot_panel.get_node_or_null("Slot%d" % i) as Button
		if btn == null:
			continue
		if SaveManager.has_save(i):
			var info := SaveManager.get_slot_info(i)
			var ts: int = info.get("timestamp", 0)
			var dt := Time.get_datetime_string_from_unix_time(ts)
			btn.text = "Slot %d  –  %s\nDay %d" % [i, dt.substr(0, 16),
				info.get("play_time", 0)]
			btn.disabled = false
		else:
			btn.text = "Slot %d  –  Empty" % i
			btn.disabled = true
		var slot_idx := i
		btn.pressed.connect(func(): _load_slot(slot_idx), CONNECT_ONE_SHOT)

func _load_slot(slot: int) -> void:
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_confirm.ogg")
	# Load save data then transition to world
	if SaveManager.load_game(slot):
		SceneTransition.go_to(FIRST_SCENE)

func _on_settings() -> void:
	menu_panel.hide()
	settings_panel.show()

func _on_credits() -> void:
	SceneTransition.go_to("res://scenes/ui/menus/Credits.tscn")

func _on_quit() -> void:
	get_tree().quit()

func _any_save_exists() -> bool:
	for i in range(1, SaveManager.SAVE_SLOTS + 1):
		if SaveManager.has_save(i):
			return true
	return false
