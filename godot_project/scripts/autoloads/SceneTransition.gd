## SceneTransition.gd
## Handles scene changes with fade transitions and loading screens.
##
## DESIGN: All scene changes go through this singleton. Never call
## get_tree().change_scene_to_file() directly from game code.
## This ensures: consistent transitions, proper cleanup, loading feedback.
##
extends Node

signal transition_completed

const FADE_TIME := 0.4

var _is_transitioning: bool = false
var _fade_rect: ColorRect = null
var _tween: Tween = null

func _ready() -> void:
	_build_overlay()
	EventBus.scene_transition_started.connect(_on_transition_requested)

func _build_overlay() -> void:
	_fade_rect = ColorRect.new()
	_fade_rect.color = Color(0.0, 0.0, 0.0, 0.0)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade_rect.z_index = 100
	add_child(_fade_rect)

func _on_transition_requested(target_scene: String) -> void:
	go_to(target_scene)

## Transition to a new scene path with an optional data payload passed
## to the new scene's _receive_transition_data(data) method.
func go_to(scene_path: String, data: Dictionary = {}) -> void:
	if _is_transitioning:
		return
	_is_transitioning = true
	EventBus.scene_transition_started.emit(scene_path)

	await _fade_to_black()
	await get_tree().create_timer(0.05).timeout  # small buffer for GC

	var err := get_tree().change_scene_to_file(scene_path)
	if err != OK:
		push_error("[SceneTransition] Failed to load: %s" % scene_path)
		await _fade_to_clear()
		_is_transitioning = false
		return

	await get_tree().process_frame
	await get_tree().process_frame

	# Pass data payload to the new root scene if it supports it
	if not data.is_empty():
		var new_scene := get_tree().current_scene
		if new_scene and new_scene.has_method("_receive_transition_data"):
			new_scene._receive_transition_data(data)

	await _fade_to_clear()
	_is_transitioning = false
	EventBus.scene_transition_finished.emit()
	transition_completed.emit()

func _fade_to_black() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_fade_rect, "color:a", 1.0, FADE_TIME)
	await _tween.finished

func _fade_to_clear() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_fade_rect, "color:a", 0.0, FADE_TIME)
	await _tween.finished
