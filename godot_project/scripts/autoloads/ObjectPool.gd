## ObjectPool.gd
## Generic object pooling system for performance-critical spawning.
##
## DESIGN: Instantiating scenes is expensive (GC pressure, node tree inserts).
## Pooling pre-allocates N instances of a scene and recycles them.
## Used for: arrows, magic projectiles, damage numbers, hit particles.
##
## USAGE:
##   var arrow = ObjectPool.acquire("arrow")
##   arrow.global_position = spawn_pos
##   # ... when done:
##   ObjectPool.release(arrow)
##
extends Node

# ─── POOL STORAGE ────────────────────────────────────────────────────────────

## pool_id → { "scene": PackedScene, "available": Array, "all": Array }
var _pools: Dictionary = {}

## Scenes to pre-warm at startup
const PRELOAD_CONFIG: Dictionary = {
	"arrow":          ["res://scenes/entities/projectiles/Arrow.tscn",     20],
	"magic_bolt":     ["res://scenes/entities/projectiles/MagicBolt.tscn", 15],
	"damage_number":  ["res://scenes/ui/hud/DamageNumber.tscn",            30],
	"hit_particle":   ["res://scenes/systems/HitParticle.tscn",            25],
	"loot_drop":      ["res://scenes/entities/world/LootDrop.tscn",        20],
]

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	# Pre-warm pools on a deferred call so all scenes are loaded first
	call_deferred("_prewarm_all")

func _prewarm_all() -> void:
	for pool_id in PRELOAD_CONFIG:
		var cfg: Array = PRELOAD_CONFIG[pool_id]
		var scene_path: String = cfg[0]
		var initial_count: int = cfg[1]
		if ResourceLoader.exists(scene_path):
			var scene: PackedScene = load(scene_path)
			_register_pool(pool_id, scene, initial_count)

# ─── POOL MANAGEMENT ─────────────────────────────────────────────────────────

func _register_pool(pool_id: String, scene: PackedScene, initial_count: int) -> void:
	_pools[pool_id] = {
		"scene":     scene,
		"available": [],
		"all":       []
	}
	for i in initial_count:
		_create_instance(pool_id)

func _create_instance(pool_id: String) -> Node:
	var pool: Dictionary = _pools[pool_id]
	var instance: Node = pool["scene"].instantiate()
	# Tag the instance so it knows its pool
	instance.set_meta("pool_id", pool_id)
	instance.set_meta("pooled", true)
	# Keep in scene tree but hidden — avoids repeated add/remove
	add_child(instance)
	instance.hide()
	pool["all"].append(instance)
	pool["available"].append(instance)
	return instance

# ─── PUBLIC API ──────────────────────────────────────────────────────────────

## Acquire an instance from the pool. Creates a new one if pool is exhausted.
func acquire(pool_id: String, parent: Node = null) -> Node:
	if not _pools.has(pool_id):
		push_error("[ObjectPool] Unknown pool: '%s'" % pool_id)
		return null

	var pool: Dictionary = _pools[pool_id]
	var instance: Node

	if pool["available"].is_empty():
		# Pool exhausted — grow it
		instance = _create_instance(pool_id)
		pool["available"].erase(instance)  # _create_instance appends to available, pop it
	else:
		instance = pool["available"].pop_back()

	# Reparent if requested (for correct transform space)
	if parent != null and instance.get_parent() != parent:
		instance.reparent(parent, false)

	instance.show()
	# Call poolable interface if implemented
	if instance.has_method("on_acquire"):
		instance.on_acquire()

	return instance

## Return an instance to its pool for reuse.
func release(instance: Node) -> void:
	if not instance.get_meta("pooled", false):
		push_warning("[ObjectPool] Releasing non-pooled node: %s" % instance.name)
		instance.queue_free()
		return

	var pool_id: String = instance.get_meta("pool_id", "")
	if pool_id.is_empty() or not _pools.has(pool_id):
		instance.queue_free()
		return

	# Call poolable interface if implemented
	if instance.has_method("on_release"):
		instance.on_release()

	instance.hide()

	# Reparent back to pool manager
	if instance.get_parent() != self:
		instance.reparent(self, false)

	_pools[pool_id]["available"].append(instance)

## Release after a delay (useful for particles/effects with a fixed lifetime).
func release_after(instance: Node, delay: float) -> void:
	get_tree().create_timer(delay, false).timeout.connect(func(): release(instance))

func get_pool_stats() -> Dictionary:
	var stats: Dictionary = {}
	for pool_id in _pools:
		var pool: Dictionary = _pools[pool_id]
		stats[pool_id] = {
			"total":     pool["all"].size(),
			"available": pool["available"].size(),
			"in_use":    pool["all"].size() - pool["available"].size()
		}
	return stats
