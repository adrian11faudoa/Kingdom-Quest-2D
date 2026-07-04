## DayNightSystem.gd
## Full day/night cycle with dynamic lighting, and pluggable weather.
##
## DESIGN: Time advances at a configurable rate. The system drives a
## CanvasModulate node to tint the entire world, and updates a
## DirectionalLight2D for sun/moon position. Weather is a separate
## state machine that can be layered on top.
##
class_name DayNightSystem
extends Node

# ─── CONFIG ──────────────────────────────────────────────────────────────────

## Real seconds per in-game hour
@export var seconds_per_hour: float = 60.0
@export var start_hour: float = 8.0

# ─── NODE REFS (set in scene inspector) ──────────────────────────────────────

@export var world_modulate: CanvasModulate = null
@export var sun_light: DirectionalLight2D  = null
@export var weather_particles: GPUParticles2D = null

# ─── TIME STATE ──────────────────────────────────────────────────────────────

var current_hour: float = 0.0       # 0.0 – 24.0
var current_day: int    = 1
var _time_accumulator: float = 0.0

# ─── COLOUR CURVE ────────────────────────────────────────────────────────────
## Define sky colour at key hours. Lerped between them.
const SKY_COLOURS: Array = [
	{ "hour":  0.0, "color": Color(0.04, 0.04, 0.12) },  # Midnight
	{ "hour":  5.0, "color": Color(0.10, 0.08, 0.18) },  # Pre-dawn
	{ "hour":  6.5, "color": Color(0.95, 0.55, 0.30) },  # Sunrise
	{ "hour":  8.0, "color": Color(1.00, 1.00, 1.00) },  # Morning
	{ "hour": 12.0, "color": Color(1.00, 1.00, 1.00) },  # Noon
	{ "hour": 17.0, "color": Color(1.00, 0.95, 0.85) },  # Afternoon
	{ "hour": 19.5, "color": Color(0.95, 0.60, 0.25) },  # Sunset
	{ "hour": 21.0, "color": Color(0.10, 0.10, 0.22) },  # Dusk
	{ "hour": 24.0, "color": Color(0.04, 0.04, 0.12) },  # Midnight (loop)
]

# ─── WEATHER STATE ───────────────────────────────────────────────────────────

enum Weather { CLEAR, CLOUDY, RAIN, STORM, SNOW, FOG }

var current_weather: Weather = Weather.CLEAR
var _weather_timer: float = 0.0
var _next_weather_change: float = 300.0  # seconds

const WEATHER_TRANSITIONS: Dictionary = {
	Weather.CLEAR:  [Weather.CLOUDY],
	Weather.CLOUDY: [Weather.CLEAR, Weather.RAIN, Weather.FOG],
	Weather.RAIN:   [Weather.CLOUDY, Weather.STORM, Weather.CLEAR],
	Weather.STORM:  [Weather.RAIN, Weather.CLOUDY],
	Weather.SNOW:   [Weather.CLEAR, Weather.CLOUDY],
	Weather.FOG:    [Weather.CLEAR, Weather.CLOUDY],
}

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	current_hour = start_hour
	SaveManager.register_system(get_save_data, apply_save_data)
	_apply_time()

func _process(delta: float) -> void:
	_tick_time(delta)
	_tick_weather(delta)

# ─── TIME ────────────────────────────────────────────────────────────────────

func _tick_time(delta: float) -> void:
	_time_accumulator += delta
	if _time_accumulator >= seconds_per_hour / 3600.0:  # Per game-second
		_time_accumulator = 0.0

	# Advance hour proportionally
	current_hour += delta / seconds_per_hour
	if current_hour >= 24.0:
		current_hour -= 24.0
		current_day += 1
		EventBus.day_started.emit(current_day)

	# Emit daily events
	if absf(current_hour - 6.0) < (delta / seconds_per_hour):
		EventBus.day_started.emit(current_day)

	if absf(current_hour - 21.0) < (delta / seconds_per_hour):
		EventBus.night_started.emit(current_day)

	EventBus.time_of_day_changed.emit(current_hour)
	_apply_time()

func _apply_time() -> void:
	if world_modulate:
		world_modulate.color = _sample_sky_colour(current_hour)

	if sun_light:
		# Rotate sun: 0° at noon, -90° at sunset, 90° at sunrise
		var sun_angle := (current_hour - 12.0) * 7.5  # 7.5° per hour
		sun_light.rotation_degrees = sun_angle
		sun_light.enabled = current_hour > 6.0 and current_hour < 20.0

func _sample_sky_colour(hour: float) -> Color:
	var prev: Dictionary = SKY_COLOURS[0]
	var next_col: Dictionary = SKY_COLOURS[SKY_COLOURS.size() - 1]

	for i in range(1, SKY_COLOURS.size()):
		if SKY_COLOURS[i]["hour"] >= hour:
			prev    = SKY_COLOURS[i - 1]
			next_col = SKY_COLOURS[i]
			break

	var t := inverse_lerp(prev["hour"], next_col["hour"], hour)
	return prev["color"].lerp(next_col["color"], t)

func is_daytime() -> bool:
	return current_hour >= 6.0 and current_hour < 20.0

func is_nighttime() -> bool:
	return not is_daytime()

func get_time_string() -> String:
	var h := int(current_hour)
	var m := int((current_hour - h) * 60)
	var suffix := "AM" if h < 12 else "PM"
	h = h % 12
	if h == 0: h = 12
	return "%d:%02d %s" % [h, m, suffix]

# ─── WEATHER ─────────────────────────────────────────────────────────────────

func _tick_weather(delta: float) -> void:
	_weather_timer += delta
	if _weather_timer >= _next_weather_change:
		_weather_timer = 0.0
		_next_weather_change = randf_range(120.0, 600.0)
		_change_weather()

func _change_weather() -> void:
	var options: Array = WEATHER_TRANSITIONS.get(current_weather, [Weather.CLEAR])
	var new_weather: Weather = options[randi() % options.size()]
	set_weather(new_weather)

func set_weather(w: Weather) -> void:
	current_weather = w
	_apply_weather()
	EventBus.weather_changed.emit(_weather_name(w))
	print("[DayNight] Weather: %s" % _weather_name(w))

func _apply_weather() -> void:
	if weather_particles == null:
		return
	match current_weather:
		Weather.CLEAR:
			weather_particles.emitting = false
		Weather.RAIN:
			weather_particles.emitting = true
			# Set rain particle material/parameters here
		Weather.STORM:
			weather_particles.emitting = true
		Weather.SNOW:
			weather_particles.emitting = true
		_:
			weather_particles.emitting = false

func _weather_name(w: Weather) -> StringName:
	match w:
		Weather.CLEAR:  return &"clear"
		Weather.CLOUDY: return &"cloudy"
		Weather.RAIN:   return &"rain"
		Weather.STORM:  return &"storm"
		Weather.SNOW:   return &"snow"
		Weather.FOG:    return &"fog"
	return &"clear"

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	return {
		"time": {
			"hour":    current_hour,
			"day":     current_day,
			"weather": int(current_weather),
		}
	}

func apply_save_data(data: Dictionary) -> void:
	var d: Dictionary = data.get("time", {})
	current_hour    = d.get("hour",    8.0)
	current_day     = d.get("day",     1)
	current_weather = d.get("weather", Weather.CLEAR) as Weather
	_apply_time()
	_apply_weather()
