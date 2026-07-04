## Minimap.gd
## Real-time minimap with fog of war, player dot, enemy dots, and icons.
##
## DESIGN: The minimap uses a SubViewport that renders a top-down camera
## view of the world. A CanvasLayer mask adds fog of war (unexplored = dark).
## Enemy/NPC dots are drawn procedurally as 2px squares.
##
## For performance: the fog-of-war texture is a low-res Image (128×128)
## updated only when the player enters a new chunk — not every frame.
##
class_name Minimap
extends Control

# ─── CONFIG ──────────────────────────────────────────────────────────────────

@export var minimap_scale: float = 0.08     # World units → minimap pixels
@export var minimap_radius: int  = 64       # Visible radius in pixels
@export var fog_resolution: int  = 128      # Fog texture resolution

# ─── NODES ───────────────────────────────────────────────────────────────────

@onready var viewport_container: SubViewportContainer = $ViewportContainer
@onready var viewport: SubViewport                    = $ViewportContainer/SubViewport
@onready var minimap_camera: Camera2D                 = $ViewportContainer/SubViewport/MinimapCamera
@onready var dot_canvas: Control                      = $DotCanvas
@onready var fog_overlay: TextureRect                 = $FogOverlay
@onready var player_icon: TextureRect                 = $PlayerIcon

# ─── FOG OF WAR ──────────────────────────────────────────────────────────────

var _fog_image: Image
var _fog_texture: ImageTexture
var _explored_cells: Dictionary = {}     # chunk_coord → true

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	_init_fog()
	EventBus.player_entered_region.connect(_on_region_entered)

func _process(delta: float) -> void:
	if GameManager.player_node == null:
		return
	_update_camera()
	_update_dots()

# ─── CAMERA FOLLOW ───────────────────────────────────────────────────────────

func _update_camera() -> void:
	minimap_camera.global_position = GameManager.player_node.global_position
	minimap_camera.zoom = Vector2(minimap_scale, minimap_scale)

# ─── ENTITY DOTS ─────────────────────────────────────────────────────────────

func _update_dots() -> void:
	if not dot_canvas.is_visible_in_tree():
		return
	dot_canvas.queue_redraw()

func _draw_dots() -> void:
	if GameManager.player_node == null:
		return
	var center := dot_canvas.size / 2.0

	# Draw enemy dots (red)
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy):
			continue
		var offset := (enemy.global_position - GameManager.player_node.global_position) * minimap_scale
		if offset.length() <= minimap_radius:
			dot_canvas.draw_circle(center + offset, 2.0, Color(1.0, 0.2, 0.2))

	# Draw NPC dots (yellow)
	for npc in get_tree().get_nodes_in_group("npcs"):
		if not is_instance_valid(npc):
			continue
		var offset := (npc.global_position - GameManager.player_node.global_position) * minimap_scale
		if offset.length() <= minimap_radius:
			dot_canvas.draw_circle(center + offset, 2.0, Color(1.0, 0.9, 0.2))

	# Draw companion dot (cyan)
	for companion in get_tree().get_nodes_in_group("companions"):
		if not is_instance_valid(companion):
			continue
		var offset := (companion.global_position - GameManager.player_node.global_position) * minimap_scale
		if offset.length() <= minimap_radius:
			dot_canvas.draw_circle(center + offset, 2.0, Color(0.2, 1.0, 1.0))

# ─── FOG OF WAR ──────────────────────────────────────────────────────────────

func _init_fog() -> void:
	_fog_image = Image.create(fog_resolution, fog_resolution, false, Image.FORMAT_RGBA8)
	_fog_image.fill(Color(0.0, 0.0, 0.0, 0.85))  # Start fully fogged
	_fog_texture = ImageTexture.create_from_image(_fog_image)
	if fog_overlay:
		fog_overlay.texture = _fog_texture

func _on_region_entered(region_id: StringName) -> void:
	_reveal_area(GameManager.player_node.global_position if GameManager.player_node else Vector2.ZERO)

func _reveal_area(world_pos: Vector2) -> void:
	# Convert world position to fog texture coordinates
	var fog_center := Vector2(fog_resolution, fog_resolution) / 2.0
	var tex_pos := fog_center + world_pos * minimap_scale * (fog_resolution / (minimap_radius * 2.0))
	# Clear a circular area
	var reveal_radius := int(fog_resolution * 0.12)
	for x in range(-reveal_radius, reveal_radius + 1):
		for y in range(-reveal_radius, reveal_radius + 1):
			if x * x + y * y <= reveal_radius * reveal_radius:
				var px := int(tex_pos.x) + x
				var py := int(tex_pos.y) + y
				if px >= 0 and px < fog_resolution and py >= 0 and py < fog_resolution:
					_fog_image.set_pixel(px, py, Color(0.0, 0.0, 0.0, 0.0))
	_fog_texture.update(_fog_image)

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	## Convert fog image to base64 to persist explored areas
	var bytes := _fog_image.save_png_to_buffer()
	return { "minimap": { "fog": Marshalls.raw_to_base64(bytes) } }

func apply_save_data(data: Dictionary) -> void:
	var fog_b64: String = data.get("minimap", {}).get("fog", "")
	if fog_b64.is_empty():
		return
	var bytes := Marshalls.base64_to_raw(fog_b64)
	_fog_image = Image.new()
	if _fog_image.load_png_from_buffer(bytes) == OK:
		_fog_texture.update(_fog_image)
