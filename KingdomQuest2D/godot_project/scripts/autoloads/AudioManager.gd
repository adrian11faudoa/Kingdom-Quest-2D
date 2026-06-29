## AudioManager.gd
## Centralised audio: music zone management, dynamic combat layers, SFX.
##
## DESIGN: Music is layered. Each zone has a "peace" track and a "combat" track.
## When combat starts, we crossfade to the combat layer and back when it ends.
## SFX uses a pool of AudioStreamPlayer2D nodes to avoid clipping.
##
extends Node

# ─── SETTINGS ────────────────────────────────────────────────────────────────

var master_volume: float  = 1.0
var music_volume: float   = 0.8
var sfx_volume: float     = 1.0
var ambient_volume: float = 0.6

const MUSIC_FADE_TIME   := 1.5   # seconds to crossfade music
const SFX_POOL_SIZE     := 16    # simultaneous SFX voices
const AMBIENT_POOL_SIZE := 4

# ─── INTERNAL STATE ──────────────────────────────────────────────────────────

var _music_player_a: AudioStreamPlayer        # Active music player (ping-pong swap)
var _music_player_b: AudioStreamPlayer        # Crossfade target
var _ambient_players: Array[AudioStreamPlayer] = []
var _sfx_pool: Array[AudioStreamPlayer2D] = []
var _current_zone_id: StringName = &""
var _combat_enemies_nearby: int = 0
var _is_combat: bool = false
var _tween: Tween = null

# Zone → {peace: path, combat: path, ambient: [paths]}
var _zone_music: Dictionary = {}

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	_build_players()
	EventBus.player_entered_region.connect(_on_region_changed)
	EventBus.entity_died.connect(_on_entity_died)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	_load_zone_config()

func _build_players() -> void:
	_music_player_a = _make_music_player("MusicA")
	_music_player_b = _make_music_player("MusicB")
	_music_player_b.volume_db = -80.0

	for i in SFX_POOL_SIZE:
		var p := AudioStreamPlayer2D.new()
		p.name = "SFX_%02d" % i
		p.bus = &"SFX"
		add_child(p)
		_sfx_pool.append(p)

	for i in AMBIENT_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.name = "Ambient_%02d" % i
		p.bus = &"Ambient"
		add_child(p)
		_ambient_players.append(p)

func _make_music_player(p_name: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = p_name
	p.bus = &"Music"
	add_child(p)
	return p

func _load_zone_config() -> void:
	# Default zone configs — extend via DataManager or JSON
	_zone_music = {
		&"overworld":  { "peace": "res://assets/audio/music/overworld_peace.ogg",  "combat": "res://assets/audio/music/overworld_combat.ogg"  },
		&"forest":     { "peace": "res://assets/audio/music/forest_peace.ogg",     "combat": "res://assets/audio/music/forest_combat.ogg"     },
		&"dungeon":    { "peace": "res://assets/audio/music/dungeon_peace.ogg",     "combat": "res://assets/audio/music/dungeon_combat.ogg"    },
		&"village":    { "peace": "res://assets/audio/music/village_peace.ogg",     "combat": ""                                               },
		&"boss":       { "peace": "res://assets/audio/music/boss_intro.ogg",        "combat": "res://assets/audio/music/boss_battle.ogg"       },
	}

# ─── MUSIC ZONE CONTROL ──────────────────────────────────────────────────────

func _on_region_changed(region_id: StringName) -> void:
	if region_id == _current_zone_id:
		return
	_current_zone_id = region_id
	var track := _get_zone_track()
	if track.is_empty():
		return
	_crossfade_to(track)

func _on_entity_died(entity: Node) -> void:
	# Count enemies to determine if combat should end
	if entity.is_in_group("enemies"):
		_combat_enemies_nearby = maxi(0, _combat_enemies_nearby - 1)
		if _combat_enemies_nearby == 0:
			_set_combat(false)

func _on_enemy_killed(_id: StringName, _pos: Vector2) -> void:
	pass  # Handled by entity_died

func notify_enemy_nearby(in_range: bool) -> void:
	_combat_enemies_nearby += 1 if in_range else -1
	_combat_enemies_nearby = maxi(0, _combat_enemies_nearby)
	_set_combat(_combat_enemies_nearby > 0)

func _set_combat(combat: bool) -> void:
	if combat == _is_combat:
		return
	_is_combat = combat
	var track := _get_zone_track()
	if not track.is_empty():
		_crossfade_to(track)

func _get_zone_track() -> String:
	var zone := _zone_music.get(_current_zone_id, {})
	if zone.is_empty():
		return ""
	if _is_combat:
		return zone.get("combat", zone.get("peace", ""))
	return zone.get("peace", "")

func _crossfade_to(path: String) -> void:
	if not ResourceLoader.exists(path):
		return
	if _tween:
		_tween.kill()

	# Swap A↔B
	var fade_out := _music_player_a
	var fade_in  := _music_player_b

	fade_in.stream = load(path)
	fade_in.volume_db = -80.0
	fade_in.play()

	_tween = create_tween().set_parallel()
	_tween.tween_property(fade_out, "volume_db", -80.0, MUSIC_FADE_TIME)
	_tween.tween_property(fade_in,  "volume_db", linear_to_db(music_volume), MUSIC_FADE_TIME)
	_tween.finished.connect(func():
		fade_out.stop()
		# Swap references
		_music_player_a = fade_in
		_music_player_b = fade_out
	)

# ─── SFX PLAYBACK ────────────────────────────────────────────────────────────

## Play a one-shot SFX at a world position.
func play_sfx(path: String, world_position: Vector2, pitch_variance: float = 0.0) -> void:
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	var player := _get_free_sfx_player()
	if player == null:
		return
	player.stream = load(path)
	player.global_position = world_position
	player.pitch_scale = 1.0 + randf_range(-pitch_variance, pitch_variance)
	player.volume_db = linear_to_db(sfx_volume)
	player.play()

## Play a UI or non-positional SFX.
func play_sfx_ui(path: String) -> void:
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	var player := AudioStreamPlayer.new()
	player.stream = load(path)
	player.bus = &"SFX"
	player.volume_db = linear_to_db(sfx_volume)
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)

func _get_free_sfx_player() -> AudioStreamPlayer2D:
	for p in _sfx_pool:
		if not p.playing:
			return p
	return null  # All voices busy

# ─── VOLUME CONTROL ──────────────────────────────────────────────────────────

func set_music_volume(vol: float) -> void:
	music_volume = clampf(vol, 0.0, 1.0)
	if _music_player_a and _music_player_a.playing:
		_music_player_a.volume_db = linear_to_db(music_volume)

func set_sfx_volume(vol: float) -> void:
	sfx_volume = clampf(vol, 0.0, 1.0)

func set_ambient_volume(vol: float) -> void:
	ambient_volume = clampf(vol, 0.0, 1.0)
	for p in _ambient_players:
		p.volume_db = linear_to_db(ambient_volume)
