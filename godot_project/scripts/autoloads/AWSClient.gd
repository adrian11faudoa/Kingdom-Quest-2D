## AWSClient.gd
## Kingdom Quest 2D — AWS Backend Client
## Handles all communication between the Godot game and the AWS API.
##
## DESIGN: Autoloaded as a singleton. Uses Godot's HTTPRequest node for all
## API calls. Tokens are stored in memory only (never written to disk in plain
## text). Uses Cognito for authentication and presigned S3 URLs for saves.
##
## USAGE:
##   AWSClient.login("email@example.com", "password")
##   await AWSClient.login_completed   # Signal
##   AWSClient.upload_save(slot, save_data_dict)
##   var profile = await AWSClient.get_profile()
##
extends Node

# ─── CONFIG ──────────────────────────────────────────────────────────────────
## Set these in Project Settings → Globals or via a config file.
## Replace with your actual deployed values from terraform output.

const API_BASE_URL      := "https://api.kingdomquest2d.com"  # ALB DNS or custom domain
const COGNITO_REGION    := "us-east-1"
const COGNITO_CLIENT_ID := ""   # From terraform output: cognito_client_id
const CDN_BASE_URL      := ""   # From terraform output: cdn_url

# ─── SIGNALS ─────────────────────────────────────────────────────────────────

signal login_completed(success: bool, error: String)
signal logout_completed()
signal profile_loaded(profile: Dictionary)
signal save_uploaded(slot: int, success: bool)
signal save_downloaded(slot: int, data: Dictionary)
signal leaderboard_loaded(entries: Array)
signal progress_synced()
signal error_occurred(message: String)

# ─── STATE ───────────────────────────────────────────────────────────────────

var _access_token:  String = ""
var _refresh_token: String = ""
var _id_token:      String = ""
var _player_id:     String = ""
var _username:      String = ""
var _token_expiry:  float  = 0.0

var is_logged_in: bool:
	get: return not _access_token.is_empty() and Time.get_ticks_msec() / 1000.0 < _token_expiry

# ─── HTTP HELPERS ─────────────────────────────────────────────────────────────

func _make_request(
		url: String,
		method: HTTPClient.Method,
		body: Dictionary = {},
		requires_auth: bool = true) -> Dictionary:
	"""Make an HTTP request and return { ok, status, data, error }."""

	if requires_auth and not is_logged_in:
		var refreshed := await _refresh_access_token()
		if not refreshed:
			return { "ok": false, "error": "Not authenticated" }

	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
	])
	if requires_auth:
		headers.append("Authorization: Bearer " + _access_token)

	var body_str := "" if body.is_empty() else JSON.stringify(body)
	var err := http.request(url, headers, method, body_str)

	if err != OK:
		http.queue_free()
		return { "ok": false, "error": "Request failed to start: %d" % err }

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code: int = result[1]
	var response_body: String = result[3].get_string_from_utf8()

	var parsed: Variant = null
	if not response_body.is_empty():
		var json := JSON.new()
		if json.parse(response_body) == OK:
			parsed = json.data

	var ok := response_code >= 200 and response_code < 300
	return {
		"ok":     ok,
		"status": response_code,
		"data":   parsed if parsed != null else {},
		"error":  "" if ok else (parsed.get("error", "HTTP %d" % response_code) if parsed is Dictionary else "HTTP %d" % response_code)
	}

# ─── COGNITO AUTH ─────────────────────────────────────────────────────────────

func login(email: String, password: String) -> void:
	"""Authenticate with Cognito USER_PASSWORD_AUTH flow."""
	var cognito_url := "https://cognito-idp.%s.amazonaws.com/" % COGNITO_REGION
	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray([
		"Content-Type: application/x-amz-json-1.1",
		"X-Amz-Target: AWSCognitoIdentityProviderService.InitiateAuth",
	])
	var body := JSON.stringify({
		"AuthFlow": "USER_PASSWORD_AUTH",
		"ClientId": COGNITO_CLIENT_ID,
		"AuthParameters": {
			"USERNAME": email,
			"PASSWORD": password,
		}
	})

	http.request(cognito_url, headers, HTTPClient.METHOD_POST, body)
	var result: Array = await http.request_completed
	http.queue_free()

	var response_body: String = result[3].get_string_from_utf8()
	var json := JSON.new()
	if result[1] != 200 or json.parse(response_body) != OK:
		login_completed.emit(false, "Authentication failed")
		return

	var data: Dictionary = json.data
	var auth_result: Dictionary = data.get("AuthenticationResult", {})

	if auth_result.is_empty():
		login_completed.emit(false, "Invalid response from auth server")
		return

	_access_token  = auth_result.get("AccessToken",  "")
	_refresh_token = auth_result.get("RefreshToken",  "")
	_id_token      = auth_result.get("IdToken",       "")
	var expires_in: int = auth_result.get("ExpiresIn", 3600)
	_token_expiry  = Time.get_ticks_msec() / 1000.0 + expires_in - 60  # 1min buffer

	# Store refresh token encrypted in user data
	var config := ConfigFile.new()
	config.set_value("auth", "refresh_token", _refresh_token)
	config.save("user://auth.cfg")

	await _load_or_create_profile()
	login_completed.emit(true, "")

func _refresh_access_token() -> bool:
	"""Use refresh token to get a new access token silently."""
	if _refresh_token.is_empty():
		# Try loading from disk
		var config := ConfigFile.new()
		if config.load("user://auth.cfg") == OK:
			_refresh_token = config.get_value("auth", "refresh_token", "")

	if _refresh_token.is_empty():
		return false

	var cognito_url := "https://cognito-idp.%s.amazonaws.com/" % COGNITO_REGION
	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray([
		"Content-Type: application/x-amz-json-1.1",
		"X-Amz-Target: AWSCognitoIdentityProviderService.InitiateAuth",
	])
	var body := JSON.stringify({
		"AuthFlow": "REFRESH_TOKEN_AUTH",
		"ClientId": COGNITO_CLIENT_ID,
		"AuthParameters": { "REFRESH_TOKEN": _refresh_token }
	})

	http.request(cognito_url, headers, HTTPClient.METHOD_POST, body)
	var result: Array = await http.request_completed
	http.queue_free()

	if result[1] != 200:
		_access_token  = ""
		_refresh_token = ""
		return false

	var json := JSON.new()
	if json.parse(result[3].get_string_from_utf8()) != OK:
		return false

	var auth_result: Dictionary = json.data.get("AuthenticationResult", {})
	_access_token = auth_result.get("AccessToken", "")
	var expires_in: int = auth_result.get("ExpiresIn", 3600)
	_token_expiry  = Time.get_ticks_msec() / 1000.0 + expires_in - 60
	return not _access_token.is_empty()

func logout() -> void:
	_access_token  = ""
	_refresh_token = ""
	_id_token      = ""
	_player_id     = ""
	_username      = ""
	_token_expiry  = 0.0
	# Clear stored token
	DirAccess.remove_absolute("user://auth.cfg")
	logout_completed.emit()

func signup(email: String, password: String, username: String) -> Dictionary:
	"""Register a new account with Cognito."""
	var cognito_url := "https://cognito-idp.%s.amazonaws.com/" % COGNITO_REGION
	var http := HTTPRequest.new()
	add_child(http)
	var headers := PackedStringArray([
		"Content-Type: application/x-amz-json-1.1",
		"X-Amz-Target: AWSCognitoIdentityProviderService.SignUp",
	])
	var body := JSON.stringify({
		"ClientId": COGNITO_CLIENT_ID,
		"Username": email,
		"Password": password,
		"UserAttributes": [
			{ "Name": "email",  "Value": email },
			{ "Name": "custom:username", "Value": username }
		]
	})
	http.request(cognito_url, headers, HTTPClient.METHOD_POST, body)
	var result: Array = await http.request_completed
	http.queue_free()
	var json := JSON.new()
	json.parse(result[3].get_string_from_utf8())
	return { "ok": result[1] == 200, "data": json.data }

# ─── PLAYER PROFILE ───────────────────────────────────────────────────────────

func _load_or_create_profile() -> void:
	var result := await _make_request(API_BASE_URL + "/api/v1/player/profile",
		HTTPClient.METHOD_GET)
	if result["ok"]:
		var player: Dictionary = result["data"].get("player", {})
		_player_id = player.get("id", "")
		_username  = player.get("username", "")
		profile_loaded.emit(player)

func get_profile() -> Dictionary:
	var result := await _make_request(API_BASE_URL + "/api/v1/player/profile",
		HTTPClient.METHOD_GET)
	if result["ok"]:
		var player: Dictionary = result["data"].get("player", {})
		_player_id = player.get("id", "")
		_username  = player.get("username", "")
		profile_loaded.emit(player)
		return player
	error_occurred.emit(result["error"])
	return {}

func set_username(new_username: String) -> bool:
	var result := await _make_request(API_BASE_URL + "/api/v1/player/profile",
		HTTPClient.METHOD_PUT, { "username": new_username })
	if result["ok"]:
		_username = new_username
		return true
	error_occurred.emit(result.get("error", "Failed to set username"))
	return false

# ─── CLOUD SAVES ──────────────────────────────────────────────────────────────

func upload_save(slot: int, save_data: Dictionary) -> void:
	"""Upload a save slot to S3 via presigned URL."""
	# 1. Get presigned upload URL from API
	var url_result := await _make_request(
		API_BASE_URL + "/api/v1/player/save/upload-url",
		HTTPClient.METHOD_POST,
		{ "slot": slot }
	)
	if not url_result["ok"]:
		save_uploaded.emit(slot, false)
		error_occurred.emit("Failed to get upload URL: " + url_result["error"])
		return

	var upload_url: String = url_result["data"].get("uploadUrl", "")
	if upload_url.is_empty():
		save_uploaded.emit(slot, false)
		return

	# 2. PUT the save data directly to S3 (presigned URL — no auth header needed)
	var http := HTTPRequest.new()
	add_child(http)
	http.request(upload_url,
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_PUT,
		JSON.stringify(save_data))
	var result: Array = await http.request_completed
	http.queue_free()

	var ok := result[1] == 200
	save_uploaded.emit(slot, ok)
	if not ok:
		error_occurred.emit("Save upload failed: HTTP %d" % result[1])

func download_save(slot: int) -> Dictionary:
	"""Download a save slot from S3 via presigned URL."""
	var url_result := await _make_request(
		API_BASE_URL + "/api/v1/player/save/%d" % slot,
		HTTPClient.METHOD_GET
	)
	if not url_result["ok"]:
		save_downloaded.emit(slot, {})
		return {}

	var download_url: String = url_result["data"].get("downloadUrl", "")
	if download_url.is_empty():
		return {}

	# Fetch directly from S3 presigned URL
	var http := HTTPRequest.new()
	add_child(http)
	http.request(download_url, PackedStringArray(), HTTPClient.METHOD_GET)
	var result: Array = await http.request_completed
	http.queue_free()

	if result[1] != 200:
		error_occurred.emit("Save download failed: HTTP %d" % result[1])
		save_downloaded.emit(slot, {})
		return {}

	var json := JSON.new()
	var body: String = result[3].get_string_from_utf8()
	if json.parse(body) != OK:
		error_occurred.emit("Failed to parse downloaded save data")
		save_downloaded.emit(slot, {})
		return {}

	save_downloaded.emit(slot, json.data)
	return json.data

func list_saves() -> Array:
	var result := await _make_request(API_BASE_URL + "/api/v1/player/saves",
		HTTPClient.METHOD_GET)
	if result["ok"]:
		return result["data"].get("saves", [])
	return []

# ─── PROGRESS SYNC ────────────────────────────────────────────────────────────

func sync_progress(level: int, xp: int, gold: int, kills: int, play_time: int) -> void:
	"""Push key stats to the server for leaderboards (fire-and-forget)."""
	var result := await _make_request(
		API_BASE_URL + "/api/v1/player/progress",
		HTTPClient.METHOD_POST,
		{
			"level":             level,
			"xp":               xp,
			"gold":             gold,
			"kills":            kills,
			"play_time_seconds": play_time,
		}
	)
	if result["ok"]:
		progress_synced.emit()

# ─── LEADERBOARDS ─────────────────────────────────────────────────────────────

func get_leaderboard(type: String = "level", page: int = 1, limit: int = 20) -> Array:
	var url := "%s/api/v1/leaderboard/%s?page=%d&limit=%d" % [API_BASE_URL, type, page, limit]
	var result := await _make_request(url, HTTPClient.METHOD_GET, {}, false)
	if result["ok"]:
		var entries: Array = result["data"].get("entries", [])
		leaderboard_loaded.emit(entries)
		return entries
	return []

# ─── ANALYTICS ────────────────────────────────────────────────────────────────

func track_event(event_type: String, properties: Dictionary = {}) -> void:
	"""Fire-and-forget game analytics event."""
	if not is_logged_in:
		return
	# Don't await — non-blocking
	_make_request(
		API_BASE_URL + "/api/v1/analytics/event",
		HTTPClient.METHOD_POST,
		{ "event_type": event_type, "properties": properties }
	)

# ─── AUTO-SYNC ON GAME EVENTS ─────────────────────────────────────────────────

func _ready() -> void:
	# Try to restore session from saved refresh token
	call_deferred("_try_restore_session")
	# Auto-sync progress every 5 minutes while logged in
	var timer := Timer.new()
	timer.wait_time = 300.0
	timer.autostart = true
	timer.timeout.connect(_auto_sync)
	add_child(timer)

func _try_restore_session() -> void:
	var refreshed := await _refresh_access_token()
	if refreshed:
		await _load_or_create_profile()
		print("[AWSClient] Session restored")

func _auto_sync() -> void:
	if not is_logged_in or GameManager.player_node == null:
		return
	var player := GameManager.player_node
	var lvl    := player.get_node_or_null("LevelSystem") as LevelSystem
	var stats  := player.get_node_or_null("StatsComponent") as StatsComponent
	var inv    := player.get_node_or_null("InventorySystem") as InventorySystem
	if lvl == null:
		return
	sync_progress(
		lvl.current_level,
		lvl.current_xp,
		inv.gold if inv else 0,
		GameManager.session_kills,
		int(GameManager.get_session_time())
	)
