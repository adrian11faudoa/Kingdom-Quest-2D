## FarmingSystem.gd
## Grid-based farming: till soil, plant seeds, water, harvest.
## Integrates with DayNightSystem for crop growth ticks.
##
class_name FarmingSystem
extends Node

enum PlotState { EMPTY, TILLED, SEEDED, WATERED, READY }

## Per-plot data
## plot_id → { "state": PlotState, "crop_id": StringName,
##             "growth": float, "watered_today": bool }
var plots: Dictionary = {}

const GROWTH_PER_DAY_WATERED   := 0.34   # ~3 days to grow if watered daily
const GROWTH_PER_DAY_UNWATERED := 0.10

func _ready() -> void:
	EventBus.day_started.connect(_on_day_started)
	SaveManager.register_system(get_save_data, apply_save_data)

# ─── ACTIONS ─────────────────────────────────────────────────────────────────

func till_plot(plot_id: int) -> bool:
	var plot := _get_or_create_plot(plot_id)
	if plot["state"] != PlotState.EMPTY:
		return false
	plot["state"] = PlotState.TILLED
	AudioManager.play_sfx_ui("res://assets/audio/sfx/farming_till.ogg")
	return true

func plant_seed(plot_id: int, crop_id: StringName) -> bool:
	var plot := _get_or_create_plot(plot_id)
	if plot["state"] != PlotState.TILLED:
		return false
	# Check inventory for seed
	var inventory := get_tree().get_first_node_in_group("inventory") as InventorySystem
	var seed_id := StringName(str(crop_id) + "_seed")
	if inventory == null or not inventory.has_item(seed_id):
		return false
	inventory.remove_item(seed_id, 1)
	plot["state"]   = PlotState.SEEDED
	plot["crop_id"] = crop_id
	plot["growth"]  = 0.0
	EventBus.farming_crop_planted.emit(crop_id, plot_id)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/farming_plant.ogg")
	return true

func water_plot(plot_id: int) -> bool:
	var plot := _get_or_create_plot(plot_id)
	if plot["state"] not in [PlotState.SEEDED, PlotState.WATERED]:
		return false
	plot["state"]         = PlotState.WATERED
	plot["watered_today"] = true
	AudioManager.play_sfx_ui("res://assets/audio/sfx/farming_water.ogg")
	return true

func harvest(plot_id: int) -> bool:
	var plot := _get_or_create_plot(plot_id)
	if plot["state"] != PlotState.READY:
		return false
	var crop_id: StringName = plot["crop_id"]
	var crop_data := DataManager.get_item(crop_id)
	var yield_amt := randi_range(
		crop_data.get("yield_min", 1),
		crop_data.get("yield_max", 3))
	var inventory := get_tree().get_first_node_in_group("inventory") as InventorySystem
	if inventory:
		inventory.add_item(crop_id, yield_amt)
	EventBus.farming_crop_harvested.emit(crop_id, plot_id, yield_amt)
	# Reset plot to tilled
	plot["state"]    = PlotState.TILLED
	plot["crop_id"]  = &""
	plot["growth"]   = 0.0
	AudioManager.play_sfx_ui("res://assets/audio/sfx/farming_harvest.ogg")
	return true

# ─── GROWTH TICK ─────────────────────────────────────────────────────────────

func _on_day_started(_day: int) -> void:
	for plot_id in plots:
		var plot: Dictionary = plots[plot_id]
		if plot["state"] not in [PlotState.SEEDED, PlotState.WATERED]:
			continue
		var growth_rate := GROWTH_PER_DAY_WATERED if plot["watered_today"] \
						  else GROWTH_PER_DAY_UNWATERED
		plot["growth"] = minf(1.0, plot["growth"] + growth_rate)
		if plot["growth"] >= 1.0:
			plot["state"] = PlotState.READY
		# Reset daily watering
		plot["watered_today"] = false
		if plot["state"] == PlotState.WATERED:
			plot["state"] = PlotState.SEEDED

# ─── QUERY ───────────────────────────────────────────────────────────────────

func get_plot(plot_id: int) -> Dictionary:
	return plots.get(plot_id, {})

func _get_or_create_plot(plot_id: int) -> Dictionary:
	if not plots.has(plot_id):
		plots[plot_id] = {
			"state":        PlotState.EMPTY,
			"crop_id":      &"",
			"growth":       0.0,
			"watered_today": false
		}
	return plots[plot_id]

# ─── SAVE / LOAD ─────────────────────────────────────────────────────────────

func get_save_data() -> Dictionary:
	var serialised := {}
	for k in plots:
		var plot: Dictionary = plots[k]
		serialised[str(k)] = {
			"state":         int(plot["state"]),
			"crop_id":       str(plot["crop_id"]),
			"growth":        plot["growth"],
			"watered_today": plot["watered_today"],
		}
	return { "farming": serialised }

func apply_save_data(data: Dictionary) -> void:
	plots.clear()
	for k in data.get("farming", {}):
		var d: Dictionary = data["farming"][k]
		plots[int(k)] = {
			"state":         d.get("state", PlotState.EMPTY) as PlotState,
			"crop_id":       StringName(d.get("crop_id", "")),
			"growth":        d.get("growth", 0.0),
			"watered_today": d.get("watered_today", false),
		}
