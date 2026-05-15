## SaveManager.gd
## Handles serialisation, encryption-optional saves, and multiple save slots.
##
## DESIGN: Every major system implements save_data() → Dictionary and
## load_data(data: Dictionary). SaveManager orchestrates them all.
## This keeps save logic inside each system (single responsibility)
## while providing a central coordinator.
##
## Save format: JSON (human-readable, moddable). Could swap to binary later.
##
extends Node

# ─── CONSTANTS ───────────────────────────────────────────────────────────────

const SAVE_DIR      := "user://saves/"
const SAVE_SLOTS    := 5
const SAVE_VERSION  := 3  # Increment on breaking schema changes
const AUTO_SAVE_INTERVAL := 300.0  # seconds

# ─── STATE ───────────────────────────────────────────────────────────────────

var _auto_save_timer: float = 0.0
var _is_saving: bool = false
var _save_callbacks: Array[Callable] = []   # Systems that want to contribute save data
var _load_callbacks: Array[Callable] = []   # Systems that want to receive loaded data

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	_ensure_save_directory()
	EventBus.save_requested.connect(func(): save_game(0))

func _process(delta: float) -> void:
	if not GameManager.is_playing():
		return
	_auto_save_timer += delta
	if _auto_save_timer >= AUTO_SAVE_INTERVAL:
		_auto_save_timer = 0.0
		save_game(0, true)  # slot 0 = auto-save

# ─── REGISTRATION ────────────────────────────────────────────────────────────
## Systems call this in their _ready() to participate in save/load.
## save_fn: Callable() → Dictionary
## load_fn: Callable(Dictionary) → void

func register_system(save_fn: Callable, load_fn: Callable) -> void:
	_save_callbacks.append(save_fn)
	_load_callbacks.append(load_fn)

# ─── SAVE ─────────────────────────────────────────────────────────────────────

func save_game(slot: int, is_auto: bool = false) -> void:
	if _is_saving:
		return
	_is_saving = true

	var save_data := _collect_all_data()
	save_data["meta"] = {
		"version":    SAVE_VERSION,
		"slot":       slot,
		"is_auto":    is_auto,
		"timestamp":  Time.get_unix_time_from_system(),
		"play_time":  GameManager.get_session_time(),
		"difficulty": GameManager.difficulty,
	}

	var path := _get_slot_path(slot)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[SaveManager] Cannot write to: %s" % path)
		_is_saving = false
		return

	file.store_string(JSON.stringify(save_data, "\t"))
	file.close()
	_is_saving = false

	EventBus.save_completed.emit(slot)
	if not is_auto:
		print("[SaveManager] Game saved to slot %d" % slot)

func _collect_all_data() -> Dictionary:
	var data: Dictionary = {}
	for callback in _save_callbacks:
		var system_data: Dictionary = callback.call()
		# Merge using the key provided by the system
		data.merge(system_data)
	return data

# ─── LOAD ─────────────────────────────────────────────────────────────────────

func load_game(slot: int) -> bool:
	var path := _get_slot_path(slot)
	if not FileAccess.file_exists(path):
		push_warning("[SaveManager] No save in slot %d" % slot)
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[SaveManager] Cannot read: %s" % path)
		return false

	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	file.close()

	if err != OK:
		push_error("[SaveManager] Corrupt save in slot %d" % slot)
		return false

	var save_data: Dictionary = json.data
	var version: int = save_data.get("meta", {}).get("version", 0)
	if version < SAVE_VERSION:
		save_data = _migrate(save_data, version)

	# Distribute data to all registered systems
	for callback in _load_callbacks:
		callback.call(save_data)

	EventBus.load_completed.emit()
	print("[SaveManager] Game loaded from slot %d" % slot)
	return true

# ─── SLOT INFO ───────────────────────────────────────────────────────────────

func get_slot_info(slot: int) -> Dictionary:
	var path := _get_slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		return {}
	file.close()

	var data: Dictionary = json.data
	return data.get("meta", {})

func has_save(slot: int) -> bool:
	return FileAccess.file_exists(_get_slot_path(slot))

func delete_save(slot: int) -> void:
	var path := _get_slot_path(slot)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

# ─── MIGRATION ───────────────────────────────────────────────────────────────
## When save format changes, migrate old saves forward.
## Always keep old migration paths so old saves still load.

func _migrate(data: Dictionary, from_version: int) -> Dictionary:
	push_warning("[SaveManager] Migrating save from version %d to %d" % [from_version, SAVE_VERSION])
	# Add migration steps here as schema evolves
	# if from_version < 2: data = _migrate_v1_to_v2(data)
	# if from_version < 3: data = _migrate_v2_to_v3(data)
	return data

# ─── HELPERS ─────────────────────────────────────────────────────────────────

func _get_slot_path(slot: int) -> String:
	if slot == 0:
		return SAVE_DIR + "autosave.json"
	return SAVE_DIR + "save_%02d.json" % slot

func _ensure_save_directory() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)
