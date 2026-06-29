## WorldMapUI.gd
## Full-screen world map with discovered regions, fast travel, and markers.
## Regions become visible only after the player has visited them (fog of war).
##
extends Control

@onready var map_image: TextureRect      = $MapContainer/MapImage
@onready var region_markers: Control     = $MapContainer/RegionMarkers
@onready var player_marker: Control      = $MapContainer/PlayerMarker
@onready var region_info: Label          = $InfoPanel/RegionName
@onready var region_desc: Label          = $InfoPanel/RegionDesc
@onready var fast_travel_btn: Button     = $InfoPanel/FastTravelBtn
@onready var close_btn: Button           = $CloseBtn

## Pixel coordinates on the map image for each region
const REGION_COORDS: Dictionary = {
	&"starting_village": Vector2(256, 300),
	&"forest":           Vector2(400, 220),
	&"cave_of_echoes":   Vector2(450, 400),
	&"ruins":            Vector2(520, 280),
	&"desert":           Vector2(100, 380),
	&"snow_biome":       Vector2(300, 100),
	&"swamp":            Vector2(200, 450),
	&"village_east":     Vector2(380, 340),
}

## Which regions the player has discovered
var discovered_regions: Array[StringName] = []
## Which regions have fast travel unlocked (visited their waystone)
var fast_travel_unlocked: Array[StringName] = []

var _selected_region: StringName = &""

func _ready() -> void:
	hide()
	close_btn.pressed.connect(close)
	fast_travel_btn.pressed.connect(_on_fast_travel)
	fast_travel_btn.hide()
	EventBus.player_entered_region.connect(_on_region_discovered)

func _input(event: InputEvent) -> void:
	if visible and event.is_action_just_pressed(&"open_map"):
		close()

func open() -> void:
	_rebuild_markers()
	_update_player_marker()
	show()
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_open.ogg")

func close() -> void:
	hide()
	AudioManager.play_sfx_ui("res://assets/audio/sfx/ui_close.ogg")

func _on_region_discovered(region_id: StringName) -> void:
	if region_id not in discovered_regions:
		discovered_regions.append(region_id)

func unlock_fast_travel(region_id: StringName) -> void:
	if region_id not in fast_travel_unlocked:
		fast_travel_unlocked.append(region_id)

# ─── MARKERS ─────────────────────────────────────────────────────────────────

func _rebuild_markers() -> void:
	for child in region_markers.get_children():
		child.queue_free()

	for region_id in discovered_regions:
		if not REGION_COORDS.has(region_id):
			continue
		var marker := _make_marker(region_id)
		region_markers.add_child(marker)

func _make_marker(region_id: StringName) -> Control:
	var btn := Button.new()
	btn.name = str(region_id)
	btn.text = "●"
	btn.position = REGION_COORDS[region_id] - Vector2(8, 8)
	btn.custom_minimum_size = Vector2(16, 16)
	btn.flat = true

	# Fast travel nodes are highlighted differently
	if region_id in fast_travel_unlocked:
		btn.add_theme_color_override("font_color", Color(0.3, 1.0, 0.4))
	else:
		btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))

	btn.pressed.connect(func(): _on_marker_clicked(region_id))
	return btn

func _update_player_marker() -> void:
	if GameManager.player_node == null or player_marker == null:
		return
	# Map world position to map image pixel
	# This requires knowing the world bounds and map image size
	# Placeholder: centre the player dot on the last known region
	var region := GameManager.current_region_id
	if REGION_COORDS.has(region):
		player_marker.position = REGION_COORDS[region]

func _on_marker_clicked(region_id: StringName) -> void:
	_selected_region = region_id
	region_info.text = _get_region_name(region_id)
	region_desc.text = _get_region_desc(region_id)

	fast_travel_btn.visible = region_id in fast_travel_unlocked and \
		region_id != GameManager.current_region_id

# ─── FAST TRAVEL ─────────────────────────────────────────────────────────────

func _on_fast_travel() -> void:
	if _selected_region.is_empty():
		return
	var scene_path := "res://scenes/world/regions/%s.tscn" % \
		_to_scene_name(_selected_region)
	if not ResourceLoader.exists(scene_path):
		push_warning("[WorldMap] No scene for region: %s" % _selected_region)
		return
	close()
	SceneTransition.go_to(scene_path)

# ─── HELPERS ─────────────────────────────────────────────────────────────────

func _get_region_name(region_id: StringName) -> String:
	var names := {
		&"starting_village": "Ashvale Village",
		&"forest":           "Verdant Forest",
		&"cave_of_echoes":   "Cave of Echoes",
		&"ruins":            "Ancient Ruins",
		&"desert":           "Sunscorch Desert",
		&"snow_biome":       "Frostpeak Mountains",
		&"swamp":            "Murkveil Swamp",
	}
	return names.get(region_id, Utils.title_case(str(region_id).replace("_", " ")))

func _get_region_desc(region_id: StringName) -> String:
	var descs := {
		&"starting_village": "A quiet village nestled in the valley. Your adventure begins here.",
		&"forest":           "Ancient trees tower overhead. Goblins lurk in the shadows.",
		&"cave_of_echoes":   "A labyrinthine cavern. Strange sounds carry through the dark.",
		&"ruins":            "Crumbled stone from a forgotten age. Treasure waits within.",
		&"desert":           "Scorching sands stretch to the horizon. The heat is relentless.",
		&"snow_biome":       "Ice-capped peaks and howling winds. Few survive here.",
		&"swamp":            "Murky water hides unknown dangers. Move carefully.",
	}
	return descs.get(region_id, "An unexplored region.")

func _to_scene_name(region_id: StringName) -> String:
	return str(region_id).split("_").map(func(w): return w.capitalize()).reduce(
		func(a, b): return a + b)

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	return {
		"world_map": {
			"discovered":    discovered_regions.map(func(r): return str(r)),
			"fast_travel":   fast_travel_unlocked.map(func(r): return str(r)),
		}
	}

func apply_save_data(data: Dictionary) -> void:
	var d: Dictionary = data.get("world_map", {})
	discovered_regions   = d.get("discovered",  []).map(func(r): return StringName(r))
	fast_travel_unlocked = d.get("fast_travel", []).map(func(r): return StringName(r))
