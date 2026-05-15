## Utils.gd
## Static utility functions and math helpers used across the project.
## No state — pure functions only.
##
class_name Utils
extends Object

# ─── MATH ────────────────────────────────────────────────────────────────────

## Return the 8-directional unit vector closest to the given angle
static func angle_to_dir8(angle_rad: float) -> Vector2:
	var snap := snappedf(angle_rad, PI / 4.0)
	return Vector2.from_angle(snap).normalized()

## Exponential decay lerp — framerate-independent smooth interpolation
## Use instead of lerp(a, b, speed * delta) which frame-depends
static func smooth(current: float, target: float, decay: float, delta: float) -> float:
	return target + (current - target) * exp(-decay * delta)

static func smooth_v2(current: Vector2, target: Vector2, decay: float, delta: float) -> Vector2:
	return Vector2(
		smooth(current.x, target.x, decay, delta),
		smooth(current.y, target.y, decay, delta)
	)

## Map value from one range to another
static func remap(value: float, from_min: float, from_max: float,
		to_min: float, to_max: float) -> float:
	return to_min + (value - from_min) / (from_max - from_min) * (to_max - to_min)

## Return a random element from an array
static func random_element(arr: Array) -> Variant:
	if arr.is_empty():
		return null
	return arr[randi() % arr.size()]

## Weighted random pick — items: [{ "item": x, "weight": n }]
static func weighted_random(items: Array) -> Variant:
	var total := 0
	for entry in items:
		total += entry.get("weight", 1)
	var roll := randi() % total
	var cumulative := 0
	for entry in items:
		cumulative += entry.get("weight", 1)
		if roll < cumulative:
			return entry.get("item", null)
	return null

# ─── GEOMETRY ────────────────────────────────────────────────────────────────

## Return a random point inside a circle
static func random_in_circle(center: Vector2, radius: float) -> Vector2:
	var angle := randf() * TAU
	var r := sqrt(randf()) * radius
	return center + Vector2(cos(angle), sin(angle)) * r

## Return a random point on the edge of a circle (for off-screen spawns)
static func random_on_ring(center: Vector2, min_r: float, max_r: float) -> Vector2:
	var angle := randf() * TAU
	var r := randf_range(min_r, max_r)
	return center + Vector2(cos(angle), sin(angle)) * r

## Rect2 from center + half-size
static func rect_from_center(center: Vector2, half_size: Vector2) -> Rect2:
	return Rect2(center - half_size, half_size * 2.0)

# ─── STRING ──────────────────────────────────────────────────────────────────

## Capitalise every word: "iron sword" → "Iron Sword"
static func title_case(s: String) -> String:
	return " ".join(s.split(" ").map(func(w: String) -> String:
		return w.capitalize()))

## Format seconds as "1h 23m 45s"
static func format_time(total_seconds: float) -> String:
	var h := int(total_seconds) / 3600
	var m := (int(total_seconds) % 3600) / 60
	var s := int(total_seconds) % 60
	if h > 0:
		return "%dh %02dm %02ds" % [h, m, s]
	elif m > 0:
		return "%dm %02ds" % [m, s]
	return "%ds" % s

## Format large numbers: 1500 → "1.5k"
static func format_number(n: int) -> String:
	if n >= 1_000_000:
		return "%.1fM" % (n / 1_000_000.0)
	elif n >= 1_000:
		return "%.1fk" % (n / 1_000.0)
	return str(n)

# ─── NODE ────────────────────────────────────────────────────────────────────

## Find the nearest node in a group to a given world position
static func nearest_in_group(tree: SceneTree, group: String,
		world_pos: Vector2) -> Node:
	var nodes := tree.get_nodes_in_group(group)
	var best: Node = null
	var best_dist := INF
	for node in nodes:
		if node is Node2D:
			var d := world_pos.distance_to((node as Node2D).global_position)
			if d < best_dist:
				best_dist = d
				best = node
	return best

## Safely get a typed component from a node
static func get_component(node: Node, type: Script) -> Node:
	for child in node.get_children():
		if child.get_script() == type:
			return child
	return null

# ─── COLOUR ──────────────────────────────────────────────────────────────────

static func rarity_color(rarity: String) -> Color:
	match rarity:
		"uncommon":  return Color(0.30, 0.90, 0.30)
		"rare":      return Color(0.30, 0.50, 1.00)
		"epic":      return Color(0.70, 0.30, 1.00)
		"legendary": return Color(1.00, 0.60, 0.10)
		"mythic":    return Color(1.00, 0.20, 0.20)
	return Color.WHITE  # common
