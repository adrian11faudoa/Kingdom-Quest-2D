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

## SettingsUI.gd (inner logic — lives in SettingsPanel child)
## Volume sliders, resolution, controls remapping.
class_name SettingsPanel
extends Control

@onready var music_slider: HSlider   = $VBox/MusicSlider
@onready var sfx_slider: HSlider     = $VBox/SFXSlider
@onready var ambient_slider: HSlider = $VBox/AmbientSlider
@onready var fullscreen_btn: CheckButton = $VBox/FullscreenBtn
@onready var pixel_snap_btn: CheckButton = $VBox/PixelSnapBtn

func _ready() -> void:
	_load_settings()
	music_slider.value_changed.connect(func(v):
		AudioManager.set_music_volume(v)
		EventBus.settings_changed.emit(&"music_volume", v))
	sfx_slider.value_changed.connect(func(v):
		AudioManager.set_sfx_volume(v)
		EventBus.settings_changed.emit(&"sfx_volume", v))
	ambient_slider.value_changed.connect(func(v):
		AudioManager.set_ambient_volume(v))
	fullscreen_btn.toggled.connect(func(on):
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_FULLSCREEN if on \
			else DisplayServer.WINDOW_MODE_WINDOWED))

func _load_settings() -> void:
	music_slider.value   = AudioManager.music_volume
	sfx_slider.value     = AudioManager.sfx_volume
	ambient_slider.value = AudioManager.ambient_volume
	fullscreen_btn.button_pressed = \
		DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "music",   AudioManager.music_volume)
	cfg.set_value("audio", "sfx",     AudioManager.sfx_volume)
	cfg.set_value("audio", "ambient", AudioManager.ambient_volume)
	cfg.save("user://settings.cfg")

func load_settings_from_file() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") != OK:
		return
	AudioManager.set_music_volume(cfg.get_value("audio", "music",   0.8))
	AudioManager.set_sfx_volume(cfg.get_value("audio", "sfx",     1.0))
	AudioManager.set_ambient_volume(cfg.get_value("audio", "ambient", 0.6))
