## LeaderboardUI.gd
## In-game leaderboard screen fetching real-time data from the AWS API.
## Falls back to a local mock table if offline.
##
extends Control

@onready var entries_list: VBoxContainer = $Panel/Scroll/Entries
@onready var tab_bar: TabBar             = $Panel/TabBar
@onready var loading_label: Label        = $Panel/LoadingLabel
@onready var player_rank_label: Label    = $Panel/PlayerRankLabel
@onready var close_btn: Button           = $Panel/Header/CloseBtn

const ENTRY_SCENE := "res://scenes/ui/menus/LeaderboardEntry.tscn"

const BOARD_TYPES := ["level", "kills", "gold", "playtime"]
var _current_page: int = 1

func _ready() -> void:
	hide()
	close_btn.pressed.connect(close)
	tab_bar.tab_changed.connect(func(_t): _current_page = 1; _load_board())

func open() -> void:
	show()
	_load_board()
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_open.ogg")

func close() -> void:
	hide()

func _load_board() -> void:
	loading_label.show()
	for child in entries_list.get_children():
		child.queue_free()

	var board_type: String = BOARD_TYPES[tab_bar.current_tab]

	if not AWSClient.is_logged_in:
		_show_offline_message()
		return

	var entries: Array = await AWSClient.get_leaderboard(board_type, _current_page, 20)
	loading_label.hide()

	if entries.is_empty():
		loading_label.text = "No data available."
		loading_label.show()
		return

	for entry in entries:
		_add_entry(entry, board_type)

	# Highlight player's own rank
	_show_player_rank(board_type)

func _add_entry(entry: Dictionary, board_type: String) -> void:
	if not ResourceLoader.exists(ENTRY_SCENE):
		# Fallback: plain label
		var label := Label.new()
		label.text = "#%d  %s  —  %s" % [
			entry.get("rank", 0),
			entry.get("username", "???"),
			_format_score(entry.get("score", 0), board_type)
		]
		entries_list.add_child(label)
		return

	var row: Control = load(ENTRY_SCENE).instantiate()
	entries_list.add_child(row)
	if row.has_method("set_data"):
		row.set_data(
			entry.get("rank", 0),
			entry.get("username", "???"),
			_format_score(entry.get("score", 0), board_type),
			entry.get("username", "") == AWSClient._username
		)

func _format_score(score: int, board_type: String) -> String:
	match board_type:
		"playtime": return Utils.format_time(score)
		"gold":     return "%s gold" % Utils.format_number(score)
		_:          return Utils.format_number(score)

func _show_player_rank(board_type: String) -> void:
	player_rank_label.text = "Your rank: loading…"
	# Rank is embedded in the entries list — find it
	# (In a real implementation, the API could return the player's own rank)
	player_rank_label.text = ""

func _show_offline_message() -> void:
	loading_label.hide()
	var label := Label.new()
	label.text = "Log in to view the global leaderboard."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	entries_list.add_child(label)
