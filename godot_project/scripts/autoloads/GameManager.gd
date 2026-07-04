## GameManager.gd
## Central authority for game state, flow control, and high-level coordination.
##
## DESIGN: Kept deliberately lean. Only data that MUST be globally accessible
## lives here. Systems that can be self-contained stay in their own scenes.
## This avoids "god object" anti-patterns common in game codebases.
##
extends Node

# ─── ENUMS ───────────────────────────────────────────────────────────────────

enum GameState {
	BOOT,
	MAIN_MENU,
	LOADING,
	PLAYING,
	PAUSED,
	DIALOGUE,
	CUTSCENE,
	GAME_OVER,
	CREDITS
}

enum Difficulty {
	STORY,
	NORMAL,
	HARD,
	NIGHTMARE
}

# ─── STATE ───────────────────────────────────────────────────────────────────

var current_state: GameState = GameState.BOOT
var previous_state: GameState = GameState.BOOT
var difficulty: Difficulty = Difficulty.NORMAL

# Runtime references — set when scenes are loaded, not stored as paths
var player_node: Node = null
var current_region_id: StringName = &""
var current_scene_path: String = ""

# Session stats (not saved, just for this play session)
var session_kills: int = 0
var session_start_time: float = 0.0

# ─── DIFFICULTY MODIFIERS ────────────────────────────────────────────────────
## Centralise difficulty scaling so every system reads from one place.

const DIFFICULTY_MODIFIERS: Dictionary = {
	Difficulty.STORY:     { "damage_taken": 0.5,  "damage_dealt": 1.5,  "xp_mult": 1.2 },
	Difficulty.NORMAL:    { "damage_taken": 1.0,  "damage_dealt": 1.0,  "xp_mult": 1.0 },
	Difficulty.HARD:      { "damage_taken": 1.5,  "damage_dealt": 0.8,  "xp_mult": 1.3 },
	Difficulty.NIGHTMARE: { "damage_taken": 2.0,  "damage_dealt": 0.6,  "xp_mult": 1.5 },
}

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	session_start_time = Time.get_ticks_msec() / 1000.0
	EventBus.player_died.connect(_on_player_died)
	EventBus.game_paused.connect(_on_game_paused)
	EventBus.game_resumed.connect(_on_game_resumed)

# ─── STATE MACHINE ───────────────────────────────────────────────────────────

func change_state(new_state: GameState) -> void:
	if new_state == current_state:
		return
	previous_state = current_state
	current_state = new_state
	_on_state_changed(previous_state, current_state)

func _on_state_changed(from: GameState, to: GameState) -> void:
	match to:
		GameState.PAUSED:
			get_tree().paused = true
		GameState.PLAYING:
			get_tree().paused = false
		GameState.GAME_OVER:
			get_tree().paused = true
		GameState.DIALOGUE:
			# Don't fully pause — let animations continue, freeze player input only
			pass

# ─── DIFFICULTY ──────────────────────────────────────────────────────────────

func get_difficulty_modifier(key: String) -> float:
	return DIFFICULTY_MODIFIERS[difficulty].get(key, 1.0)

func set_difficulty(new_difficulty: Difficulty) -> void:
	difficulty = new_difficulty

# ─── CALLBACKS ───────────────────────────────────────────────────────────────

func _on_player_died() -> void:
	change_state(GameState.GAME_OVER)

func _on_game_paused() -> void:
	if current_state == GameState.PLAYING:
		change_state(GameState.PAUSED)

func _on_game_resumed() -> void:
	if current_state == GameState.PAUSED:
		change_state(GameState.PLAYING)

# ─── HELPERS ─────────────────────────────────────────────────────────────────

func is_playing() -> bool:
	return current_state == GameState.PLAYING

func get_session_time() -> float:
	return (Time.get_ticks_msec() / 1000.0) - session_start_time
