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
