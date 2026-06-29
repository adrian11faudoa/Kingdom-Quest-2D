## Credits.gd
## Simple credits screen — scrolls content, back button returns to main menu.
extends Control

func _ready() -> void:
	var back_btn := $BackButton
	if back_btn:
		back_btn.pressed.connect(_on_back_pressed)

func _on_back_pressed() -> void:
	SceneTransition.go_to("res://scenes/ui/menus/MainMenu.tscn")

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_just_pressed(&"pause"):
		_on_back_pressed()
