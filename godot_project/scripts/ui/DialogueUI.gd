## DialogueUI.gd
## Renders dialogue lines with typewriter effect, NPC portraits, choices.
## Listens to DialogueSystem signals — never touches game logic.
##
extends CanvasLayer

@onready var container: Control       = $DialogueBox
@onready var portrait: TextureRect    = $DialogueBox/Portrait
@onready var speaker_label: Label     = $DialogueBox/SpeakerName
@onready var text_label: RichTextLabel = $DialogueBox/Text
@onready var choices_container: VBoxContainer = $DialogueBox/Choices
@onready var continue_indicator: Control = $DialogueBox/ContinueArrow

const TYPEWRITER_SPEED := 0.03  # seconds per character
const CHOICE_BTN_SCENE := "res://scenes/ui/dialogue/ChoiceButton.tscn"

var _dialogue_system: DialogueSystem = null
var _full_text: String = ""
var _is_typing: bool = false
var _tween: Tween = null

func _ready() -> void:
	container.hide()
	_find_dialogue_system()

func _find_dialogue_system() -> void:
	await get_tree().process_frame
	_dialogue_system = get_tree().get_first_node_in_group("dialogue_system") as DialogueSystem
	if _dialogue_system:
		_dialogue_system.dialogue_line_ready.connect(_on_line_ready)
		_dialogue_system.choices_ready.connect(_on_choices_ready)
		_dialogue_system.dialogue_finished.connect(_on_finished)

func _unhandled_input(event: InputEvent) -> void:
	if not container.visible:
		return
	if event.is_action_just_pressed(&"interact"):
		if _is_typing:
			_finish_type_immediately()
		# Advance handled by DialogueSystem via EventBus
		get_viewport().set_input_as_handled()

# ─── LINE DISPLAY ────────────────────────────────────────────────────────────

func _on_line_ready(speaker: String, text: String, portrait_path: String) -> void:
	container.show()
	continue_indicator.hide()
	_clear_choices()

	speaker_label.text = speaker

	if not portrait_path.is_empty() and ResourceLoader.exists(portrait_path):
		portrait.texture = load(portrait_path)
		portrait.show()
	else:
		portrait.hide()

	_start_typewriter(text)

func _start_typewriter(text: String) -> void:
	_full_text  = text
	_is_typing  = true
	text_label.text = ""

	if _tween:
		_tween.kill()

	_tween = create_tween()
	for i in text.length():
		_tween.tween_callback(func(): text_label.text += text[i])
		_tween.tween_interval(TYPEWRITER_SPEED)
	_tween.tween_callback(_on_typewriter_done)

func _on_typewriter_done() -> void:
	_is_typing = false
	continue_indicator.show()

func _finish_type_immediately() -> void:
	if _tween:
		_tween.kill()
	text_label.text = _full_text
	_is_typing = false
	continue_indicator.show()

# ─── CHOICES ─────────────────────────────────────────────────────────────────

func _on_choices_ready(choices: Array) -> void:
	_clear_choices()
	continue_indicator.hide()
	if not ResourceLoader.exists(CHOICE_BTN_SCENE):
		_build_text_choices(choices)
		return
	for i in choices.size():
		var btn: Button = load(CHOICE_BTN_SCENE).instantiate()
		choices_container.add_child(btn)
		btn.text = choices[i].get("text", "...")
		var idx := i
		btn.pressed.connect(func():
			AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_click.ogg")
			if _dialogue_system:
				_dialogue_system.select_choice(idx)
			_clear_choices()
		)

func _build_text_choices(choices: Array) -> void:
	for i in choices.size():
		var label := RichTextLabel.new()
		label.text = "%d. %s" % [i + 1, choices[i].get("text", "")]
		choices_container.add_child(label)

func _clear_choices() -> void:
	for child in choices_container.get_children():
		child.queue_free()

# ─── CLOSE ───────────────────────────────────────────────────────────────────

func _on_finished() -> void:
	if _tween:
		_tween.kill()
	_clear_choices()
	var tween := create_tween()
	tween.tween_property(container, "modulate:a", 0.0, 0.3)
	tween.tween_callback(func():
		container.hide()
		container.modulate.a = 1.0
	)
