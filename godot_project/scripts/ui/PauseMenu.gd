## PauseMenu.gd
## Pause menu with resume, settings, save, and quit.
##
extends CanvasLayer

@onready var panel: Control         = $Panel
@onready var resume_btn: Button     = $Panel/VBox/ResumeBtn
@onready var inventory_btn: Button  = $Panel/VBox/InventoryBtn
@onready var settings_btn: Button   = $Panel/VBox/SettingsBtn
@onready var save_btn: Button       = $Panel/VBox/SaveBtn
@onready var main_menu_btn: Button  = $Panel/VBox/MainMenuBtn
@onready var settings_panel: Control = $SettingsPanel

func _ready() -> void:
	hide()
	resume_btn.pressed.connect(_on_resume)
	inventory_btn.pressed.connect(_on_inventory)
	settings_btn.pressed.connect(_on_settings)
	save_btn.pressed.connect(_on_save)
	main_menu_btn.pressed.connect(_on_main_menu)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_just_pressed(&"pause"):
		if visible:
			_on_resume()
		elif GameManager.is_playing():
			_open()
		get_viewport().set_input_as_handled()

func _open() -> void:
	show()
	panel.show()
	settings_panel.hide()
	EventBus.game_paused.emit()
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_open.ogg")

func _on_resume() -> void:
	hide()
	EventBus.game_resumed.emit()
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_close.ogg")

func _on_inventory() -> void:
	hide()
	# Signal to open inventory from game world
	EventBus.world_event_triggered.emit(&"open_inventory")

func _on_settings() -> void:
	panel.hide()
	settings_panel.show()

func _on_save() -> void:
	SaveManager.save_game(1)
	var notif := $SaveNotification
	if notif:
		notif.show()
		await get_tree().create_timer(2.0).timeout
		notif.hide()

func _on_main_menu() -> void:
	EventBus.game_resumed.emit()   # Unpause before transition
	SceneTransition.go_to("res://scenes/ui/menus/MainMenu.tscn")

# ──────────────────────────────────────────────────────────────────────────────

