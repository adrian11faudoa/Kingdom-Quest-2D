## WorldStreamer.gd
## Streams world chunks in/out based on player position.
##
## DESIGN: The world is divided into rectangular chunks. Only chunks within
## LOAD_RADIUS of the player are active (visible + processing).
## Chunks outside UNLOAD_RADIUS are freed. This enables large open worlds
## without loading all tile data at once.
##
## Each chunk is a separate scene file: "res://scenes/world/chunks/chunk_X_Y.tscn"
## Chunk scenes contain: TileMapLayer, enemies, props, interactables.
##
## For performance: chunks at RENDER_RADIUS are visible but physics-disabled.
## Chunks at LOAD_RADIUS have full physics. Beyond: unloaded.
##
class_name WorldStreamer
extends Node

# ─── CONFIG ──────────────────────────────────────────────────────────────────

@export var chunk_size: Vector2i = Vector2i(32, 32)   # In tiles
@export var tile_size: int = 16                        # pixels per tile

@export var load_radius: int   = 3  # Chunks with full simulation
@export var render_radius: int = 4  # Chunks that are visible only

const CHUNKS_DIR := "res://scenes/world/chunks/"

# ─── STATE ───────────────────────────────────────────────────────────────────

## chunk_coord (Vector2i) → { "scene": Node, "state": String }
var _loaded_chunks: Dictionary = {}
var _player_chunk: Vector2i = Vector2i(-9999, -9999)
var _load_thread: Thread = null
var _pending_loads: Array[Vector2i] = []

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	set_process(true)

func _process(_delta: float) -> void:
	if GameManager.player_node == null:
		return
	var player_pos := GameManager.player_node.global_position
	var current_chunk := world_to_chunk(player_pos)

	if current_chunk != _player_chunk:
		_player_chunk = current_chunk
		_update_chunks()

	_emit_region_events(player_pos)

# ─── CHUNK COORDINATE MATH ───────────────────────────────────────────────────

func world_to_chunk(world_pos: Vector2) -> Vector2i:
	var chunk_world_size := Vector2(chunk_size) * tile_size
	return Vector2i(
		floori(world_pos.x / chunk_world_size.x),
		floori(world_pos.y / chunk_world_size.y)
	)

func chunk_to_world_origin(chunk_coord: Vector2i) -> Vector2:
	return Vector2(chunk_coord) * Vector2(chunk_size) * tile_size

# ─── CHUNK MANAGEMENT ────────────────────────────────────────────────────────

func _update_chunks() -> void:
	var needed: Dictionary = {}

	# Determine which chunks should be loaded
	for x in range(-load_radius, load_radius + 1):
		for y in range(-load_radius, load_radius + 1):
			var coord := _player_chunk + Vector2i(x, y)
			var dist := maxi(absi(x), absi(y))
			needed[coord] = dist <= render_radius  # true=full, false=render-only

	# Load/activate needed chunks
	for coord in needed:
		var full_active: bool = needed[coord]
		if not _loaded_chunks.has(coord):
			_load_chunk(coord, full_active)
		else:
			_set_chunk_active(_loaded_chunks[coord]["scene"], full_active)

	# Unload chunks outside radius
	var to_unload: Array[Vector2i] = []
	for coord in _loaded_chunks:
		if not needed.has(coord):
			to_unload.append(coord)
	for coord in to_unload:
		_unload_chunk(coord)

func _load_chunk(coord: Vector2i, full_active: bool) -> void:
	var path := CHUNKS_DIR + "chunk_%d_%d.tscn" % [coord.x, coord.y]
	if not ResourceLoader.exists(path):
		# No chunk file — this area is empty (ocean, void, etc.)
		return

	# Use ResourceLoader threaded background loading for seamless streaming
	ResourceLoader.load_threaded_request(path)
	# For simplicity in this version, use synchronous loading on first load
	# In production, use ResourceLoader.load_threaded_get() on a timer
	var scene: PackedScene = ResourceLoader.load(path)
	if scene == null:
		return

	var instance: Node = scene.instantiate()
	instance.name = "Chunk_%d_%d" % [coord.x, coord.y]
	instance.position = chunk_to_world_origin(coord)
	get_parent().add_child(instance)

	_set_chunk_active(instance, full_active)

	_loaded_chunks[coord] = {
		"scene": instance,
		"state": "full" if full_active else "render"
	}

	EventBus.region_loaded.emit(StringName("chunk_%d_%d" % [coord.x, coord.y]))

func _unload_chunk(coord: Vector2i) -> void:
	if not _loaded_chunks.has(coord):
		return
	var chunk_data: Dictionary = _loaded_chunks[coord]
	var scene: Node = chunk_data["scene"]

	# Persist any runtime state (opened chests, killed enemies, etc.)
	_save_chunk_state(coord, scene)

	scene.queue_free()
	_loaded_chunks.erase(coord)
	EventBus.region_unloaded.emit(StringName("chunk_%d_%d" % [coord.x, coord.y]))

func _set_chunk_active(scene: Node, full: bool) -> void:
	if not is_instance_valid(scene):
		return
	scene.set_process(full)
	scene.set_physics_process(full)
	scene.visible = true

	# Disable/enable enemy and NPC processing based on distance
	for child in scene.get_children():
		if child.is_in_group("enemies") or child.is_in_group("npcs"):
			child.set_process(full)
			child.set_physics_process(full)

# ─── CHUNK STATE PERSISTENCE ─────────────────────────────────────────────────

## Stores per-chunk state so it survives unloading (e.g. chest opened = stays open)
var _chunk_states: Dictionary = {}  # coord_str → arbitrary data dict

func _save_chunk_state(coord: Vector2i, scene: Node) -> void:
	var state: Dictionary = {}
	var key := "%d_%d" % [coord.x, coord.y]

	# Each persistable node implements save_chunk_state() → Dictionary
	for child in scene.get_descendants_recursive() if scene.has_method("get_descendants_recursive") else scene.get_children():
		if child.has_method("save_chunk_state"):
			state[child.name] = child.save_chunk_state()

	if not state.is_empty():
		_chunk_states[key] = state

func _restore_chunk_state(coord: Vector2i, scene: Node) -> void:
	var key := "%d_%d" % [coord.x, coord.y]
	if not _chunk_states.has(key):
		return
	var state: Dictionary = _chunk_states[key]
	for child in scene.get_children():
		if child.name in state and child.has_method("load_chunk_state"):
			child.load_chunk_state(state[child.name])

# ─── REGION EVENTS ───────────────────────────────────────────────────────────

var _last_region: StringName = &""

func _emit_region_events(player_pos: Vector2) -> void:
	# Simple region detection based on chunk coordinate mapping
	# In practice you'd have a lookup table for named regions
	var region := _get_region_for_chunk(_player_chunk)
	if region != _last_region:
		if not _last_region.is_empty():
			EventBus.player_exited_region.emit(_last_region)
		_last_region = region
		if not region.is_empty():
			EventBus.player_entered_region.emit(region)

func _get_region_for_chunk(chunk: Vector2i) -> StringName:
	## Map chunk coordinates to named regions — extend this table
	if chunk.x >= -2 and chunk.x <= 2 and chunk.y >= -2 and chunk.y <= 2:
		return &"starting_village"
	if chunk.x >= 3 and chunk.y >= -1:
		return &"forest"
	if chunk.x <= -3:
		return &"desert"
	if chunk.y <= -3:
		return &"snow_biome"
	if chunk.y >= 3:
		return &"swamp"
	return &"overworld"

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	return { "world": { "chunk_states": _chunk_states } }

func apply_save_data(data: Dictionary) -> void:
	_chunk_states = data.get("world", {}).get("chunk_states", {})
