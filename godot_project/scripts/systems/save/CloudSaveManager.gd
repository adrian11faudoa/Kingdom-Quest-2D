## CloudSaveManager.gd
## Bridges local SaveManager with AWS cloud saves (AWSClient).
## Handles conflict resolution when cloud and local saves diverge.
## Attach to the same scene as SaveManager, or use as an autoload extension.
##
extends Node

enum SaveLocation { LOCAL_ONLY, CLOUD_ONLY, BOTH }
enum ConflictResolution { USE_CLOUD, USE_LOCAL, USE_NEWER }

@export var auto_cloud_sync: bool         = true
@export var conflict_strategy: ConflictResolution = ConflictResolution.USE_NEWER

# ─── SIGNALS ─────────────────────────────────────────────────────────────────

signal cloud_sync_started()
signal cloud_sync_completed(success: bool)
signal conflict_detected(local_time: int, cloud_time: int)

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	# Listen for save completions to optionally mirror to cloud
	EventBus.save_completed.connect(_on_local_save_completed)
	EventBus.load_completed.connect(_on_local_load_completed)

# ─── SAVE ─────────────────────────────────────────────────────────────────────

func save_to_cloud(slot: int = 1) -> void:
	if not AWSClient.is_logged_in:
		push_warning("[CloudSave] Not logged in — skipping cloud save")
		return

	cloud_sync_started.emit()

	# First ensure local save is up to date
	SaveManager.save_game(slot)
	await get_tree().create_timer(0.1).timeout

	# Read the local save file
	var path := SaveManager._get_slot_path(slot)
	var file  := FileAccess.open(path, FileAccess.READ)
	if file == null:
		cloud_sync_completed.emit(false)
		return

	var json  := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		cloud_sync_completed.emit(false)
		return
	file.close()

	var save_data: Dictionary = json.data
	# Add cloud metadata
	save_data["cloud_meta"] = {
		"uploaded_at": Time.get_unix_time_from_system(),
		"game_version": ProjectSettings.get_setting("application/config/version", "0.1.0"),
	}

	await AWSClient.upload_save(slot, save_data)
	cloud_sync_completed.emit(true)
	print("[CloudSave] Uploaded slot %d to cloud" % slot)

# ─── LOAD ─────────────────────────────────────────────────────────────────────

func load_from_cloud(slot: int = 1) -> bool:
	if not AWSClient.is_logged_in:
		push_warning("[CloudSave] Not logged in — falling back to local save")
		return SaveManager.load_game(slot)

	cloud_sync_started.emit()

	# Get cloud save
	var cloud_data := await AWSClient.download_save(slot)
	if cloud_data.is_empty():
		push_warning("[CloudSave] No cloud save found for slot %d" % slot)
		cloud_sync_completed.emit(false)
		return SaveManager.load_game(slot)

	# Compare timestamps
	var cloud_time: int = cloud_data.get("cloud_meta", {}).get("uploaded_at", 0)
	var local_time: int = SaveManager.get_slot_info(slot).get("timestamp", 0)

	var use_cloud := _resolve_conflict(local_time, cloud_time)

	if use_cloud:
		# Write cloud data to local slot, then load
		_write_cloud_to_local(slot, cloud_data)

	var success := SaveManager.load_game(slot)
	cloud_sync_completed.emit(success)
	return success

func _resolve_conflict(local_time: int, cloud_time: int) -> bool:
	"""Returns true if we should use the cloud save."""
	if local_time == 0:
		return true   # No local save — use cloud
	if cloud_time == 0:
		return false  # No cloud save — use local

	match conflict_strategy:
		ConflictResolution.USE_CLOUD:
			return true
		ConflictResolution.USE_LOCAL:
			return false
		ConflictResolution.USE_NEWER:
			if abs(cloud_time - local_time) > 60:  # Only flag if >1 min difference
				conflict_detected.emit(local_time, cloud_time)
			return cloud_time >= local_time
	return cloud_time >= local_time

func _write_cloud_to_local(slot: int, data: Dictionary) -> void:
	var path := SaveManager._get_slot_path(slot)
	var file  := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
		print("[CloudSave] Wrote cloud save to local slot %d" % slot)

# ─── AUTO SYNC CALLBACKS ──────────────────────────────────────────────────────

func _on_local_save_completed(slot: int) -> void:
	if auto_cloud_sync and slot != 0:  # Don't cloud-sync auto-saves
		call_deferred("save_to_cloud", slot)

func _on_local_load_completed() -> void:
	pass  # Track successful loads for analytics

# ─── CONFLICT RESOLUTION UI ──────────────────────────────────────────────────

## Call this from your Load Game UI to show a conflict dialog.
## Returns true if player chose cloud, false if local.
func prompt_conflict_resolution(local_time: int, cloud_time: int) -> bool:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Save Conflict Detected"
	dialog.dialog_text = (
		"Your local save and cloud save differ.\n\n" +
		"Local save:  %s\n" % Time.get_datetime_string_from_unix_time(local_time) +
		"Cloud save:  %s\n\n" % Time.get_datetime_string_from_unix_time(cloud_time) +
		"Which save would you like to use?"
	)
	dialog.ok_button_text     = "Use Cloud"
	dialog.cancel_button_text = "Use Local"
	get_tree().root.add_child(dialog)
	dialog.popup_centered()

	var chose_cloud := false
	dialog.confirmed.connect(func(): chose_cloud = true)
	await dialog.visibility_changed
	dialog.queue_free()
	return chose_cloud
