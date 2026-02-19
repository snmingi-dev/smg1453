extends RefCounted
class_name ProjectIO


func build_payload(terrain_state: Dictionary, political_state: Dictionary, tool_dict: Dictionary, canvas: Dictionary, layers: Dictionary) -> Dictionary:
	var now: String = Time.get_datetime_string_from_system()
	var safe_canvas: Dictionary = canvas.duplicate(true)
	var safe_layers: Dictionary = layers.duplicate(true)
	var safe_tool: Dictionary = tool_dict.duplicate(true)
	var safe_terrain: Dictionary = terrain_state.duplicate(true)
	var safe_political: Dictionary = political_state.duplicate(true)

	return {
		"meta": {
			"version": 1,
			"name": "Fantasy Map Project",
			"created_at": now,
			"updated_at": now
		},
		"canvas": safe_canvas,
		"terrain": {
			"land_mask_chunks": safe_terrain.get("land_mask_chunks", {}),
			"tile_erase_settings": safe_terrain.get("tile_erase_settings", {}),
			"tool_config": safe_tool,
			"feature_state": safe_terrain.get("feature_state", {})
		},
		"political": safe_political,
		"countries": safe_political.get("countries", []),
		"regions": safe_political.get("regions", []),
		"layers": safe_layers
	}


func write_payload(path: String, payload: Dictionary) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return OK


func save_project(path: String, terrain, political, tool_config) -> Error:
	var terrain_state := {
		"land_mask_chunks": terrain.export_land_mask_chunks(1024),
		"tile_erase_settings": {
			"tile_size": tool_config.tile_size,
			"enabled": tool_config.tile_erase_enabled
		},
		"feature_state": terrain.serialize_state(false)
	}
	var political_state: Dictionary = political.serialize_state()
	var payload: Dictionary = build_payload(
		terrain_state,
		political_state,
		tool_config.to_dict(),
		{
			"width": terrain.map_size.x,
			"height": terrain.map_size.y,
			"tile_size": tool_config.tile_size
		},
		{
			"terrain_visible": terrain.visible,
			"political_visible": political.visible
		}
	)
	return write_payload(path, payload)


func load_project(path: String, terrain, political, tool_config) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return ERR_PARSE_ERROR
	var data: Dictionary = parsed

	var terrain_data: Dictionary = data.get("terrain", {})
	var land_chunks: Dictionary = terrain_data.get("land_mask_chunks", {})
	if not land_chunks.is_empty():
		terrain.import_land_mask_chunks(land_chunks)

	var feature_state: Dictionary = terrain_data.get("feature_state", {})
	if not feature_state.is_empty():
		terrain.deserialize_state(feature_state)

	var cfg: Dictionary = terrain_data.get("tool_config", {})
	var loaded_cfg = tool_config.get_script().from_dict(cfg)
	tool_config.brush_type = loaded_cfg.brush_type
	tool_config.size = loaded_cfg.size
	tool_config.noise_strength = loaded_cfg.noise_strength
	tool_config.tile_erase_enabled = loaded_cfg.tile_erase_enabled
	tool_config.tile_size = loaded_cfg.tile_size

	if data.has("political") and typeof(data.get("political")) == TYPE_DICTIONARY:
		political.deserialize_state(data.get("political", {}))
	else:
		var fallback_state := {
			"countries": data.get("countries", []),
			"regions": data.get("regions", []),
			"map_size": {"x": terrain.map_size.x, "y": terrain.map_size.y}
		}
		political.deserialize_state(fallback_state)

	var layers: Dictionary = data.get("layers", {})
	terrain.visible = bool(layers.get("terrain_visible", true))
	political.visible = bool(layers.get("political_visible", true))
	return OK
