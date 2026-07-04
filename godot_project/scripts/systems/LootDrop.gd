## LootDrop.gd
## A pickupable item dropped in the world by enemies or chests.
## Uses object pooling — implements on_acquire / on_release.
##
class_name LootDrop
extends Area2D

@onready var sprite: Sprite2D    = $Sprite2D
@onready var label: Label        = $Label
@onready var pickup_timer: Timer = $PickupDelay  # Short delay before can pick up

var item_id: StringName = &""
var quantity: int = 1
var _pickup_enabled: bool = false
var _bob_offset: float = 0.0

const BOB_SPEED := 2.0
const BOB_HEIGHT := 3.0

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	pickup_timer.timeout.connect(func(): _pickup_enabled = true)

# ─── POOL INTERFACE ──────────────────────────────────────────────────────────

func on_acquire() -> void:
	_pickup_enabled = false
	_bob_offset = randf() * TAU  # Randomise bob phase per drop
	pickup_timer.start(0.4)

func on_release() -> void:
	item_id  = &""
	quantity = 1
	_pickup_enabled = false
	sprite.texture = null
	label.text = ""

# ─── SETUP ───────────────────────────────────────────────────────────────────

func setup(p_item_id: StringName, p_quantity: int = 1) -> void:
	item_id  = p_item_id
	quantity = p_quantity

	var item_data := DataManager.get_item(item_id)
	label.text = item_data.get("name", str(item_id))

	var icon_path: String = item_data.get("icon", "")
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		sprite.texture = load(icon_path)

	# Tint by rarity
	var rarity: String = item_data.get("rarity", "common")
	sprite.modulate = _rarity_color(rarity)

	# Eject with a little random velocity arc
	var dir := Vector2.from_angle(randf() * TAU)
	var tween := create_tween()
	tween.tween_property(self, "global_position",
		global_position + dir * randf_range(12.0, 32.0), 0.3).set_trans(Tween.TRANS_QUAD)

func _rarity_color(rarity: String) -> Color:
	match rarity:
		"uncommon":  return Color(0.4, 1.0, 0.4)
		"rare":      return Color(0.4, 0.6, 1.0)
		"epic":      return Color(0.8, 0.4, 1.0)
		"legendary": return Color(1.0, 0.7, 0.1)
		_:           return Color.WHITE

# ─── MOVEMENT ────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_bob_offset += delta * BOB_SPEED
	sprite.position.y = sin(_bob_offset) * BOB_HEIGHT

# ─── PICKUP ──────────────────────────────────────────────────────────────────

func _on_body_entered(body: Node2D) -> void:
	if not _pickup_enabled:
		return
	if not body.is_in_group("player"):
		return
	var inventory := body.get_node_or_null("InventorySystem") as InventorySystem
	if inventory == null:
		return
	if inventory.add_item(item_id, quantity):
		EventBus.item_picked_up.emit(item_id, quantity)
		AudioManager.play_sfx("res://assets/audio/sfx/item_pickup.ogg",
			global_position, 0.1)
		ObjectPool.release(self)

# ─── CHUNK STATE (persist across chunk unloads) ───────────────────────────────

func save_chunk_state() -> Dictionary:
	return {
		"item_id":  str(item_id),
		"quantity": quantity,
		"position": { "x": global_position.x, "y": global_position.y },
	}

func load_chunk_state(data: Dictionary) -> void:
	setup(StringName(data["item_id"]), data.get("quantity", 1))
	global_position = Vector2(data["position"]["x"], data["position"]["y"])
