extends RefCounted
class_name TerrainToolConfig

const BRUSH_CIRCLE := "circle"
const BRUSH_TEXTURE := "texture"
const BRUSH_NOISE := "noise"

var brush_type: String = BRUSH_CIRCLE
var size: int = 26
var noise_strength: float = 1.0
var tile_erase_enabled: bool = false
var tile_size: int = 64


func duplicate_config():
	var c = get_script().new()
	c.brush_type = brush_type
	c.size = size
	c.noise_strength = noise_strength
	c.tile_erase_enabled = tile_erase_enabled
	c.tile_size = tile_size
	return c


func to_dict() -> Dictionary:
	return {
		"brush_type": brush_type,
		"size": size,
		"noise_strength": noise_strength,
		"tile_erase_enabled": tile_erase_enabled,
		"tile_size": tile_size
	}


static func from_dict(data: Dictionary):
	var c = load("res://scripts/models/terrain_tool_config.gd").new()
	c.brush_type = str(data.get("brush_type", BRUSH_CIRCLE))
	c.size = int(data.get("size", 26))
	c.noise_strength = clampf(float(data.get("noise_strength", 1.0)), 0.0, 1.0)
	c.tile_erase_enabled = bool(data.get("tile_erase_enabled", false))
	c.tile_size = max(int(data.get("tile_size", 64)), 16)
	return c
