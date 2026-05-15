## ShopUI.gd
## Merchant shop: buy/sell items, faction-adjusted prices.
##
extends Control

@onready var buy_list: ItemList      = $Panel/Split/BuyPanel/BuyList
@onready var sell_list: ItemList     = $Panel/Split/SellPanel/SellList
@ontml_ready var player_gold: Label  = $Panel/Header/GoldLabel
@onready var confirm_btn: Button     = $Panel/Footer/ConfirmBtn
@onready var cancel_btn: Button      = $Panel/Footer/CancelBtn
@onready var item_info: Label        = $Panel/Footer/InfoLabel
@onready var tab_bar: TabBar         = $Panel/TabBar

var merchant_id: StringName = &""
var _stock: Array = []
var _inventory: InventorySystem = null
var _faction_sys: FactionSystem = null
var _selected_buy_id: StringName  = &""
var _selected_sell_idx: int       = -1

const BUY_TAB  := 0
const SELL_TAB := 1

# ─── LIFECYCLE ───────────────────────────────────────────────────────────────

func _ready() -> void:
	hide()
	confirm_btn.pressed.connect(_on_confirm)
	cancel_btn.pressed.connect(_on_cancel)
	tab_bar.tab_changed.connect(_on_tab_changed)
	buy_list.item_selected.connect(_on_buy_selected)
	sell_list.item_selected.connect(_on_sell_selected)
	EventBus.gold_changed.connect(func(g): player_gold.text = "Gold: %d" % g)
	# Listen for shop open events
	EventBus.world_event_triggered.connect(_on_world_event)

func _on_world_event(event_id: StringName) -> void:
	if str(event_id).begins_with("open_shop:"):
		var mid := StringName(str(event_id).substr(10))
		open(mid)

# ─── OPEN / CLOSE ────────────────────────────────────────────────────────────

func open(p_merchant_id: StringName) -> void:
	merchant_id = p_merchant_id
	_inventory  = get_tree().get_first_node_in_group("inventory") as InventorySystem
	_faction_sys = get_tree().get_first_node_in_group("factions") as FactionSystem
	_load_stock()
	_refresh()
	show()
	GameManager.change_state(GameManager.GameState.PAUSED)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/shop_open.ogg")

func _on_cancel() -> void:
	hide()
	GameManager.change_state(GameManager.GameState.PLAYING)

# ─── STOCK ───────────────────────────────────────────────────────────────────

func _load_stock() -> void:
	var npc_data := DataManager.get_npc(merchant_id)
	_stock = npc_data.get("stock", [])
	# If no explicit stock, build a default general store
	if _stock.is_empty():
		_stock = [
			{ "id": "health_potion",  "qty": 10, "price_override": 0 },
			{ "id": "mana_potion",    "qty": 10, "price_override": 0 },
			{ "id": "iron_ingot",     "qty": 20, "price_override": 0 },
			{ "id": "wood_handle",    "qty": 20, "price_override": 0 },
			{ "id": "leather_armor",  "qty":  2, "price_override": 0 },
			{ "id": "iron_sword",     "qty":  2, "price_override": 0 },
		]

func _get_price_mult() -> float:
	if _faction_sys == null:
		return 1.0
	return _faction_sys.get_price_modifier(merchant_id)

# ─── REFRESH ─────────────────────────────────────────────────────────────────

func _refresh() -> void:
	player_gold.text = "Gold: %d" % (_inventory.gold if _inventory else 0)
	match tab_bar.current_tab:
		BUY_TAB:  _refresh_buy()
		SELL_TAB: _refresh_sell()

func _refresh_buy() -> void:
	buy_list.clear()
	var mult := _get_price_mult()
	for entry in _stock:
		var item_id := StringName(entry["id"])
		var item_data := DataManager.get_item(item_id)
		if item_data.is_empty():
			continue
		var base_price: int = entry.get("price_override", 0)
		if base_price == 0:
			base_price = item_data.get("buy_price", 10)
		var final_price := int(base_price * mult)
		var qty: int = entry.get("qty", 0)
		var text := "%s — %d gold (x%d)" % [item_data.get("name", str(item_id)), final_price, qty]
		buy_list.add_item(text)
		# Dim if can't afford
		if _inventory and _inventory.gold < final_price:
			buy_list.set_item_custom_fg_color(buy_list.item_count - 1, Color(0.5, 0.5, 0.5))

func _refresh_sell() -> void:
	sell_list.clear()
	if _inventory == null:
		return
	for entry in _inventory.items:
		var item_id: StringName = entry["id"]
		var item_data := DataManager.get_item(item_id)
		if item_data.is_empty():
			continue
		if item_data.get("sell_price", 0) <= 0:
			continue  # Unsellable items
		var sell_price := item_data.get("sell_price", 1)
		var text := "%s x%d — %d gold" % [
			item_data.get("name", str(item_id)), entry["qty"], sell_price * entry["qty"]]
		sell_list.add_item(text)

func _on_tab_changed(_tab: int) -> void:
	_selected_buy_id  = &""
	_selected_sell_idx = -1
	item_info.text = ""
	_refresh()

# ─── SELECTION ───────────────────────────────────────────────────────────────

func _on_buy_selected(idx: int) -> void:
	if idx >= _stock.size():
		return
	var entry: Dictionary = _stock[idx]
	_selected_buy_id = StringName(entry["id"])
	var item_data := DataManager.get_item(_selected_buy_id)
	var mult := _get_price_mult()
	var price := int(entry.get("price_override", item_data.get("buy_price", 10)) * mult)
	item_info.text = "%s — %s\nCost: %d gold" % [
		item_data.get("name", "?"),
		item_data.get("description", ""),
		price
	]

func _on_sell_selected(idx: int) -> void:
	_selected_sell_idx = idx
	if _inventory == null or idx >= _inventory.items.size():
		return
	var entry: Dictionary = _inventory.items[idx]
	var item_data := DataManager.get_item(entry["id"])
	var sell_price := item_data.get("sell_price", 1)
	item_info.text = "%s\nSell for: %d gold" % [item_data.get("name", "?"), sell_price]

# ─── TRANSACTIONS ────────────────────────────────────────────────────────────

func _on_confirm() -> void:
	match tab_bar.current_tab:
		BUY_TAB:  _buy_selected()
		SELL_TAB: _sell_selected()

func _buy_selected() -> void:
	if _selected_buy_id.is_empty() or _inventory == null:
		return
	var stock_entry: Dictionary = {}
	for entry in _stock:
		if StringName(entry["id"]) == _selected_buy_id:
			stock_entry = entry
			break
	if stock_entry.is_empty():
		return

	var item_data := DataManager.get_item(_selected_buy_id)
	var mult := _get_price_mult()
	var price := int(stock_entry.get("price_override", item_data.get("buy_price", 10)) * mult)

	if not _inventory.spend_gold(price):
		item_info.text = "Not enough gold!"
		return
	_inventory.add_item(_selected_buy_id, 1)
	stock_entry["qty"] = maxi(0, stock_entry.get("qty", 0) - 1)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/shop_buy.ogg")
	_refresh()

func _sell_selected() -> void:
	if _selected_sell_idx < 0 or _inventory == null:
		return
	if _selected_sell_idx >= _inventory.items.size():
		return
	var entry: Dictionary = _inventory.items[_selected_sell_idx]
	var item_id: StringName = entry["id"]
	var item_data := DataManager.get_item(item_id)
	var sell_price := item_data.get("sell_price", 1)
	_inventory.remove_item(item_id, 1)
	_inventory.add_gold(sell_price)
	AudioManager.play_sfx_ui("res://assets/audio/sfx/shop_sell.ogg")
	_selected_sell_idx = -1
	_refresh()
