## QuestJournalUI.gd
## Quest journal: tabs for active/completed, objectives list, rewards preview.
##
extends Control

@onready var tab_bar: TabBar          = $Panel/TabBar
@onready var quest_list: ItemList     = $Panel/Split/QuestList
@onready var title_label: Label       = $Panel/Split/Detail/Title
@onready var desc_label: Label        = $Panel/Split/Detail/Description
@onready var objectives_list: VBoxContainer = $Panel/Split/Detail/Objectives
@onready var rewards_label: Label     = $Panel/Split/Detail/Rewards
@onready var track_btn: Button        = $Panel/Split/Detail/TrackBtn

var _quest_system: QuestSystem = null
var _displayed_quests: Array   = []
var _selected_quest_id: StringName = &""

func _ready() -> void:
	hide()
	tab_bar.tab_changed.connect(_on_tab_changed)
	track_btn.pressed.connect(_on_track_pressed)
	EventBus.quest_started.connect(func(_id): _refresh())
	EventBus.quest_completed.connect(func(_id): _refresh())
	EventBus.quest_objective_updated.connect(func(_q, _o, _p, _t): _refresh_objectives())

func _input(event: InputEvent) -> void:
	if visible and event.is_action_just_pressed(&"open_journal"):
		close()
		get_viewport().set_input_as_handled()

func open() -> void:
	_find_quest_system()
	_refresh()
	show()
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_open.ogg")

func close() -> void:
	hide()
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_close.ogg")

func _find_quest_system() -> void:
	if _quest_system != null:
		return
	_quest_system = get_tree().get_first_node_in_group("quest_system") as QuestSystem

func _on_tab_changed(_tab: int) -> void:
	_refresh()

func _refresh() -> void:
	if not visible or _quest_system == null:
		return
	quest_list.clear()
	_displayed_quests.clear()

	var quests: Array
	if tab_bar.current_tab == 0:
		quests = _quest_system.get_active_quests()
	else:
		quests = _quest_system.get_completed_quests()

	for quest_id in quests:
		var data := DataManager.get_quest(quest_id)
		quest_list.add_item(data.get("title", str(quest_id)))
		_displayed_quests.append(quest_id)

	# Auto-select first
	if not _displayed_quests.is_empty():
		quest_list.select(0)
		_show_quest_detail(_displayed_quests[0])

	quest_list.item_selected.connect(_on_quest_selected, CONNECT_ONE_SHOT)

func _on_quest_selected(index: int) -> void:
	if index < _displayed_quests.size():
		_selected_quest_id = _displayed_quests[index]
		_show_quest_detail(_selected_quest_id)
	await get_tree().process_frame
	quest_list.item_selected.connect(_on_quest_selected, CONNECT_ONE_SHOT)

func _show_quest_detail(quest_id: StringName) -> void:
	var data := DataManager.get_quest(quest_id)
	title_label.text = data.get("title", "???")
	desc_label.text  = data.get("description", "")
	_refresh_objectives()

	# Rewards
	var rewards: Dictionary = data.get("rewards", {})
	var reward_text := ""
	if rewards.get("xp",   0) > 0: reward_text += "XP: %d  " % rewards["xp"]
	if rewards.get("gold", 0) > 0: reward_text += "Gold: %d  " % rewards["gold"]
	for item in rewards.get("items", []):
		reward_text += "%s x%d  " % [item["id"], item.get("qty",1)]
	rewards_label.text = reward_text

func _refresh_objectives() -> void:
	if _selected_quest_id.is_empty() or _quest_system == null:
		return
	for child in objectives_list.get_children():
		child.queue_free()
	var data := DataManager.get_quest(_selected_quest_id)
	for obj in data.get("objectives", []):
		var progress := _quest_system.get_quest_progress(_selected_quest_id, obj["id"])
		var target: int = obj.get("count", 1)
		var done := progress >= target
		var label := Label.new()
		var prefix := "[X] " if done else "[ ] "
		label.text = prefix + obj.get("description", obj["id"])
		if target > 1:
			label.text += " (%d/%d)" % [progress, target]
		label.add_theme_color_override("font_color",
			Color(0.5, 1.0, 0.5) if done else Color.WHITE)
		objectives_list.add_child(label)

func _on_track_pressed() -> void:
	# TODO: highlight tracked quest objective on minimap
	pass
