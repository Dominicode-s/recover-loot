extends Node

# Recover Loot: pure autoload, no script overrides
# Saves inventory + equipment on death, spawns as Pickups on return.

var gameData = preload("res://Resources/GameData.tres")

const STASH_PATH = "user://RecoverLoot.cfg"
const MARKER_PATH = "user://RecoverLootMarker.tres"
const MCM_MOD_ID = "RecoverLoot"
const MCM_FILE_PATH = "user://ModConfigs/recover-loot"
const LOCAL_CFG_PATH = "user://RecoverLoot_settings.cfg"

var cfg_enabled: bool = true
var cfg_show_hint: bool = true

var _prev_dead: bool = false
var _prev_menu: bool = true
var _prev_on_map: bool = false
var _stash_checked: bool = false
var _spawn_timer: float = -1.0
var _mcm_helpers = null

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_mcm_helpers = _try_load_mcm()
	if _mcm_helpers:
		_register_mcm()
	else:
		_load_local_config()
	_ensure_marker()

func _process(delta):
	# New game: .tres marker gets wiped by FormatSave
	if _prev_menu and not gameData.menu:
		if not FileAccess.file_exists(MARKER_PATH):
			_delete_stash()
			_ensure_marker()
	_prev_menu = gameData.menu

	if not cfg_enabled:
		_prev_dead = gameData.isDead
		return

	# Deferred to avoid death-frame issues
	if gameData.isDead and not _prev_dead:
		if not gameData.permadeath and not gameData.tutorial:
			call_deferred("_capture_stash")
	_prev_dead = gameData.isDead

	var on_map = _is_on_map()

	if on_map and not _prev_on_map:
		_stash_checked = false
		if _has_stash():
			_spawn_timer = 1.5
	_prev_on_map = on_map

	if _spawn_timer > 0 and on_map:
		_spawn_timer -= delta
		if _spawn_timer <= 0 and not _stash_checked:
			_stash_checked = true
			_try_spawn_stash()

	if not on_map:
		_stash_checked = false
		_spawn_timer = -1.0

func _is_on_map() -> bool:
	var tree = get_tree()
	if tree == null:
		return false
	var scene = tree.current_scene
	if not is_instance_valid(scene):
		return false
	# Use absolute path from our autoload (always in tree)
	var map_node = get_node_or_null("/root/Map")
	return map_node != null and not gameData.isDead


# Capture
func _capture_stash():
	var interface = _get_interface()
	if not is_instance_valid(interface):
		return

	var cfg = ConfigFile.new()

	cfg.set_value("stash", "map", gameData.currentMap)
	cfg.set_value("stash", "pos_x", gameData.playerPosition.x)
	cfg.set_value("stash", "pos_y", gameData.playerPosition.y)
	cfg.set_value("stash", "pos_z", gameData.playerPosition.z)

	var idx = 0

	var inv_grid = interface.get("inventoryGrid")
	if is_instance_valid(inv_grid):
		for item in inv_grid.get_children():
			if not is_instance_valid(item):
				continue
			var sd = item.get("slotData") if "slotData" in item else null
			if sd != null and sd.itemData != null:
				_serialize_slot(cfg, "item_%d" % idx, sd)
				idx += 1

	var equip = interface.get("equipment")
	if is_instance_valid(equip):
		for slot_node in equip.get_children():
			if not is_instance_valid(slot_node):
				continue
			if slot_node.get_child_count() == 0:
				continue
			var item = slot_node.get_child(0)
			if not is_instance_valid(item):
				continue
			var sd = item.get("slotData") if "slotData" in item else null
			if sd != null and sd.itemData != null:
				_serialize_slot(cfg, "item_%d" % idx, sd)
				idx += 1

	cfg.set_value("stash", "item_count", idx)

	if idx == 0:
		return

	var err = cfg.save(STASH_PATH)
	if err == OK:
		print("[RecoverLoot] Stashed %d items on %s" % [idx, gameData.currentMap])


# Spawn
func _has_stash() -> bool:
	return FileAccess.file_exists(STASH_PATH)

func _try_spawn_stash():
	var cfg = ConfigFile.new()
	if cfg.load(STASH_PATH) != OK:
		return

	var stash_map = cfg.get_value("stash", "map", "")
	if stash_map != gameData.currentMap:
		if cfg_show_hint and stash_map != "":
			print("[RecoverLoot] Your death stash is on %s" % stash_map)
		return

	var map_node = get_node_or_null("/root/Map")
	if map_node == null:
		_stash_checked = false
		_spawn_timer = 0.5
		return

	var pos = Vector3(
		cfg.get_value("stash", "pos_x", 0.0),
		cfg.get_value("stash", "pos_y", 0.0),
		cfg.get_value("stash", "pos_z", 0.0)
	)

	var item_count = cfg.get_value("stash", "item_count", 0)
	var spawned = 0

	for i in range(item_count):
		var section = "item_%d" % i
		if not cfg.has_section(section):
			continue

		var file = cfg.get_value(section, "file", "")
		if file == "":
			continue

		var item_scene = Database.get(file)
		if item_scene == null:
			# Fallback for modded items: derive scene path from resource_path
			var res_path = cfg.get_value(section, "resource_path", "")
			var scene_path = res_path.replace(".tres", ".tscn")
			if scene_path != "" and ResourceLoader.exists(scene_path):
				item_scene = load(scene_path)
		if item_scene == null:
			# Cash System integration: uses runtime-generated scene via Engine meta
			var cash_mod = Engine.get_meta("CashMain", null)
			if cash_mod and file == "Cash" and cash_mod.cash_pickup_scene:
				item_scene = cash_mod.cash_pickup_scene
		if item_scene == null:
			print("[RecoverLoot] Unknown item '%s', skipped" % file)
			continue

		var pickup = item_scene.instantiate()
		map_node.add_child(pickup)

		# Spread items in a tight circle with vertical stacking for indoor safety
		var angle = (float(spawned) / max(item_count, 1)) * TAU
		var ring = int(spawned / 8)
		var radius = 0.3 + ring * 0.25
		var offset = Vector3(
			cos(angle) * radius + randf_range(-0.05, 0.05),
			0.5 + ring * 0.4,
			sin(angle) * radius + randf_range(-0.05, 0.05)
		)
		pickup.global_position = pos + offset

		_deserialize_to_pickup(cfg, section, pickup)

		if pickup.has_method("UpdateAttachments"):
			pickup.UpdateAttachments()
		if pickup.has_method("Unfreeze"):
			pickup.Unfreeze()

		spawned += 1

	_delete_stash()

	if spawned > 0 and cfg_show_hint:
		print("[RecoverLoot] %d items spawned at your death location" % spawned)


# Serialization
func _serialize_slot(cfg: ConfigFile, section: String, slot):
	if slot == null or slot.itemData == null:
		return
	cfg.set_value(section, "file", slot.itemData.file)
	cfg.set_value(section, "resource_path", slot.itemData.resource_path)
	cfg.set_value(section, "condition", slot.get("condition") if "condition" in slot else 100)
	cfg.set_value(section, "amount", slot.get("amount") if "amount" in slot else 0)
	cfg.set_value(section, "position", slot.get("position") if "position" in slot else 0)
	cfg.set_value(section, "mode", slot.get("mode") if "mode" in slot else 1)
	cfg.set_value(section, "zoom", slot.get("zoom") if "zoom" in slot else 1)
	cfg.set_value(section, "chamber", slot.get("chamber") if "chamber" in slot else false)
	cfg.set_value(section, "casing", slot.get("casing") if "casing" in slot else false)
	cfg.set_value(section, "state", slot.get("state") if "state" in slot else "")

	var nested_files: Array = []
	var nested_paths: Array = []
	var nested = slot.get("nested") if "nested" in slot else []
	if nested != null:
		for item_data in nested:
			if item_data != null and "file" in item_data:
				nested_files.append(item_data.file)
				nested_paths.append(item_data.resource_path if "resource_path" in item_data else "")
	cfg.set_value(section, "nested", nested_files)
	cfg.set_value(section, "nested_paths", nested_paths)

func _deserialize_to_pickup(cfg: ConfigFile, section: String, pickup):
	var slot = pickup.slotData
	if slot == null:
		return

	slot.condition = cfg.get_value(section, "condition", 100)
	slot.amount = cfg.get_value(section, "amount", 0)
	slot.position = cfg.get_value(section, "position", 0)
	slot.mode = cfg.get_value(section, "mode", 1)
	slot.zoom = cfg.get_value(section, "zoom", 1)
	slot.chamber = cfg.get_value(section, "chamber", false)
	slot.casing = cfg.get_value(section, "casing", false)
	slot.state = cfg.get_value(section, "state", "")

	var nested_files = cfg.get_value(section, "nested", [])
	var nested_paths = cfg.get_value(section, "nested_paths", [])
	slot.nested.clear()
	for j in range(nested_files.size()):
		var fallback_path = nested_paths[j] if j < nested_paths.size() else ""
		var item_data = _load_item_data(nested_files[j], fallback_path)
		if item_data:
			slot.nested.append(item_data)

func _load_item_data(file_name: String, fallback_res_path: String = ""):
	var scene = Database.get(file_name)
	if scene == null and fallback_res_path != "":
		if ResourceLoader.exists(fallback_res_path):
			return load(fallback_res_path)
		var scene_path = fallback_res_path.replace(".tres", ".tscn")
		if ResourceLoader.exists(scene_path):
			scene = load(scene_path)
	if scene == null:
		return null
	var tres_path = scene.resource_path.replace(".tscn", ".tres")
	if ResourceLoader.exists(tres_path):
		return load(tres_path)
	return null


# Stash file
func _delete_stash():
	if FileAccess.file_exists(STASH_PATH):
		DirAccess.remove_absolute(STASH_PATH)

func _ensure_marker():
	if not FileAccess.file_exists(MARKER_PATH):
		var res = Resource.new()
		ResourceSaver.save(res, MARKER_PATH)

func _get_interface():
	# Autoload is always under /root, so use absolute path directly
	return get_node_or_null("/root/Map/Core/UI/Interface")


# MCM
func _try_load_mcm():
	if ResourceLoader.exists("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"):
		return load("res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres")
	return null

func _mcm_val(config: ConfigFile, section: String, key: String, fallback):
	var entry = config.get_value(section, key, null)
	if entry == null or not entry is Dictionary:
		return fallback
	return entry.get("value", fallback)

func _register_mcm():
	var config = ConfigFile.new()

	config.set_value("Bool", "cfg_enabled", {
		"name" = "Enable Mod",
		"tooltip" = "Toggle Recover Loot on or off",
		"default" = true, "value" = true,
		"menu_pos" = 1
	})

	config.set_value("Bool", "cfg_show_hint", {
		"name" = "Show Hint Messages",
		"tooltip" = "Print a message when entering a map with a death stash",
		"default" = true, "value" = true,
		"menu_pos" = 2
	})

	if not FileAccess.file_exists(MCM_FILE_PATH + "/config.ini"):
		DirAccess.open("user://").make_dir_recursive(MCM_FILE_PATH)
		config.save(MCM_FILE_PATH + "/config.ini")
	else:
		_mcm_helpers.CheckConfigurationHasUpdated(MCM_MOD_ID, config, MCM_FILE_PATH + "/config.ini")
		config.load(MCM_FILE_PATH + "/config.ini")

	_apply_config(config)

	_mcm_helpers.RegisterConfiguration(
		MCM_MOD_ID,
		"Recover Loot",
		MCM_FILE_PATH,
		"Recover your inventory from your last death location",
		{"config.ini" = _on_mcm_save}
	)

func _on_mcm_save(config: ConfigFile):
	_apply_config(config)

func _apply_config(config: ConfigFile):
	cfg_enabled = _mcm_val(config, "Bool", "cfg_enabled", true)
	cfg_show_hint = _mcm_val(config, "Bool", "cfg_show_hint", true)

func _load_local_config():
	var cfg = ConfigFile.new()
	if cfg.load(LOCAL_CFG_PATH) == OK:
		cfg_enabled = cfg.get_value("config", "enabled", true)
		cfg_show_hint = cfg.get_value("config", "show_hint", true)
	_save_local_config()

func _save_local_config():
	var cfg = ConfigFile.new()
	cfg.set_value("config", "enabled", cfg_enabled)
	cfg.set_value("config", "show_hint", cfg_show_hint)
	cfg.save(LOCAL_CFG_PATH)
