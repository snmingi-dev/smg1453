extends Node2D
class_name PoliticalLayer

const AUTO_COUNTRY_COLORS := [
	"#2E86DE",
	"#E74C3C",
	"#27AE60",
	"#8E44AD",
	"#16A085",
	"#D35400",
	"#C0392B",
	"#1ABC9C",
	"#9B59B6",
	"#2980B9",
	"#F39C12",
	"#2ECC71"
]
const DEFAULT_BORDER_COLOR := "#183047"
const DEFAULT_REGION_LINE_COLOR := "#2b4f6a"
const MIN_REGION_AREA := 48.0
const MAX_REGION_OVERLAP_RATIO := 0.35

var countries: Array = []
var regions: Array = []
var selected_country_id: String = ""

var _country_seq: int = 0
var _region_seq: int = 0

var _preview_points: PackedVector2Array = PackedVector2Array()

var map_size: Vector2i = Vector2i(1920, 1080)
var cell_size: int = 4
var grid_size: Vector2i = Vector2i.ZERO
var owner_grid: PackedInt32Array = PackedInt32Array()

var _fill_image: Image
var _fill_texture: ImageTexture
var _fill_sprite: Sprite2D

var _country_to_slot: Dictionary = {}
var _slot_to_country: Dictionary = {}
var _country_cell_count: Dictionary = {}
var _country_sum_pos: Dictionary = {}

var _active_paint_country_id: String = ""
var _new_country_creation_armed: bool = false
var _country_anchor_cache: Dictionary = {}
var _country_anchor_dirty: Dictionary = {}
var _vector_border_paths_by_country: Dictionary = {}
var _vector_border_dirty: bool = true
var _runtime_border_smoothing_iterations: int = 1
var _runtime_border_line_width: float = 2.2
var _runtime_rebuild_deferred: bool = false


func _ready() -> void:
	configure_map(map_size, cell_size)


func configure_map(new_map_size: Vector2i, new_cell_size: int = 4) -> void:
	map_size = new_map_size
	cell_size = max(2, new_cell_size)
	grid_size = Vector2i(
		int(ceil(float(map_size.x) / float(cell_size))),
		int(ceil(float(map_size.y) / float(cell_size)))
	)
	owner_grid = PackedInt32Array()
	owner_grid.resize(grid_size.x * grid_size.y)
	for i in range(owner_grid.size()):
		owner_grid[i] = 0

	_fill_image = Image.create(grid_size.x, grid_size.y, false, Image.FORMAT_RGBA8)
	_fill_image.fill(Color(0, 0, 0, 0))
	_fill_texture = ImageTexture.create_from_image(_fill_image)

	if is_instance_valid(_fill_sprite):
		_fill_sprite.queue_free()
	_fill_sprite = Sprite2D.new()
	_fill_sprite.centered = false
	_fill_sprite.texture = _fill_texture
	_fill_sprite.scale = Vector2(float(cell_size), float(cell_size))
	_fill_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_fill_sprite.z_index = -8
	add_child(_fill_sprite)

	_country_to_slot.clear()
	_slot_to_country.clear()
	_country_cell_count.clear()
	_country_sum_pos.clear()
	_country_anchor_cache.clear()
	_country_anchor_dirty.clear()
	_vector_border_paths_by_country.clear()
	_active_paint_country_id = ""
	_new_country_creation_armed = false
	_vector_border_dirty = true
	queue_redraw()


func _draw() -> void:
	for country_data in countries:
		var country: Dictionary = country_data
		var cid: String = str(country.get("id", ""))
		var line_hex: String = str(country.get("style", {}).get("line", DEFAULT_BORDER_COLOR))
		var border_color: Color = Color(line_hex)
		border_color.a = 1.0
		var paths: Array = _vector_border_paths_by_country.get(cid, [])
		for path_data in paths:
			var path: PackedVector2Array = path_data
			if path.size() >= 2:
				_draw_country_border_path(path, border_color)

	for country_data in countries:
		var country: Dictionary = country_data
		_draw_country_label(country)

	for region_data in regions:
		var region: Dictionary = region_data
		var rpoly: PackedVector2Array = region.get("polygon", PackedVector2Array())
		if rpoly.size() < 3:
			continue
		var rline_hex: String = str(region.get("style", {}).get("line", "#2b4f6a"))
		draw_polyline(_closed_polyline(rpoly), Color(rline_hex), 1.4, true)

	if _preview_points.size() >= 2:
		var preview_color: Color = Color("#84D7FF")
		draw_polyline(_preview_points, preview_color, 2.2, true)
		draw_circle(_preview_points[_preview_points.size() - 1], 2.4, preview_color)


func set_stroke_preview(stroke_points: Array[Vector2], cursor_world: Vector2, _is_country: bool) -> void:
	if stroke_points.is_empty():
		clear_stroke_preview()
		return
	var points: Array[Vector2] = stroke_points.duplicate()
	if points[points.size() - 1].distance_to(cursor_world) > 0.6:
		points.append(cursor_world)
	_preview_points = PackedVector2Array(points)
	queue_redraw()


func _draw_country_border_path(path: PackedVector2Array, border_color: Color) -> void:
	var base_w: float = max(1.0, _runtime_border_line_width)
	var outer_w: float = max(base_w + 0.6, base_w * 1.52)
	var outer_color: Color = border_color.lerp(Color(0.93, 0.96, 1.0, 1.0), 0.36)
	outer_color.a = 0.32
	draw_polyline(path, outer_color, outer_w, true)
	draw_polyline(path, border_color, base_w, true)


func clear_stroke_preview() -> void:
	if _preview_points.is_empty():
		return
	_preview_points = PackedVector2Array()
	queue_redraw()


func arm_new_country_creation() -> void:
	_new_country_creation_armed = true


func disarm_new_country_creation() -> void:
	_new_country_creation_armed = false


func begin_country_paint(start_world: Vector2, terrain_layer, can_create_new: bool, preferred_color: Color = Color(0, 0, 0, 0)) -> Dictionary:
	_active_paint_country_id = ""
	var on_land: bool = true
	if terrain_layer != null:
		on_land = terrain_layer.is_point_on_land(start_world)
	if not on_land:
		return {
			"ok": false,
			"message": "육지에서 국가 칠하기를 시작하세요.",
			"country_id": "",
			"created": false,
			"consumed_arm": false
		}

	var existing_id: String = _country_at_world(start_world)
	if not existing_id.is_empty():
		_active_paint_country_id = existing_id
		selected_country_id = existing_id
		return {
			"ok": true,
			"message": "",
			"country_id": existing_id,
			"created": false,
			"consumed_arm": false
		}

	var allow_create: bool = can_create_new or _new_country_creation_armed
	if not allow_create:
		return {
			"ok": false,
			"message": "새 국가 생성 버튼을 먼저 누르세요.",
			"country_id": "",
			"created": false,
			"consumed_arm": false
		}

	var new_color: Color = _next_country_color()
	if preferred_color.a > 0.0:
		new_color = preferred_color
	var created_id: String = _create_country(new_color)
	_active_paint_country_id = created_id
	selected_country_id = created_id
	var consumed_arm: bool = _new_country_creation_armed
	if consumed_arm:
		disarm_new_country_creation()
	return {
		"ok": true,
		"message": "",
		"country_id": created_id,
		"created": true,
		"consumed_arm": consumed_arm
	}


func end_country_paint() -> void:
	_active_paint_country_id = ""
	if _vector_border_dirty:
		rebuild_vector_borders()
	queue_redraw()


func paint_country_segment(a: Vector2, b: Vector2, terrain_layer, brush_radius: float) -> Dictionary:
	if _active_paint_country_id.is_empty():
		return {"changed": false, "country_id": "", "message": "활성 국가가 없습니다."}

	var slot: int = int(_country_to_slot.get(_active_paint_country_id, 0))
	if slot <= 0:
		return {"changed": false, "country_id": _active_paint_country_id, "message": "국가 슬롯을 찾을 수 없습니다."}

	var spacing: float = max(1.0, brush_radius * 0.28)
	var seg_len: float = a.distance_to(b)
	var steps: int = max(1, int(ceil(seg_len / spacing)))
	var changed: bool = false

	for s in range(steps + 1):
		var t: float = float(s) / float(steps)
		var p: Vector2 = a.lerp(b, t)
		if _paint_country_stamp(p, brush_radius, slot, terrain_layer):
			changed = true

	if changed:
		_fill_texture.update(_fill_image)
		_vector_border_dirty = true
		queue_redraw()
	return {"changed": changed, "country_id": _active_paint_country_id, "message": ""}


func rebuild_vector_borders() -> void:
	var segments_by_country: Dictionary = _extract_country_border_segments()
	var out: Dictionary = {}
	for cid_data in segments_by_country.keys():
		var cid: String = str(cid_data)
		var segments: Array = segments_by_country[cid]
		var cell_paths: Array = _link_segments_to_paths(segments)
		var world_paths: Array = []
		for p_data in cell_paths:
			var p: Array = p_data
			var wp: PackedVector2Array = _to_world_path(p)
			if wp.size() >= 3:
				for _i in range(_runtime_border_smoothing_iterations):
					wp = _chaikin_closed_once(wp)
			if wp.size() >= 2:
				world_paths.append(wp)
		out[cid] = world_paths
	_vector_border_paths_by_country = out
	_vector_border_dirty = false


func get_vector_border_paths() -> Array:
	var out: Array = []
	for cid_data in _vector_border_paths_by_country.keys():
		var cid: String = str(cid_data)
		out.append({
			"country_id": cid,
			"paths": _vector_border_paths_by_country[cid]
		})
	return out


func set_runtime_quality(profile: Dictionary) -> void:
	var changed: bool = false
	var smooth: int = clampi(int(profile.get("border_smoothing_iterations", _runtime_border_smoothing_iterations)), 0, 3)
	var width: float = max(1.8, float(profile.get("border_line_width", _runtime_border_line_width)))
	var rebuild_deferred: bool = bool(profile.get("rebuild_deferred", _runtime_rebuild_deferred))

	if _runtime_border_smoothing_iterations != smooth:
		_runtime_border_smoothing_iterations = smooth
		_vector_border_dirty = true
		changed = true
	if absf(_runtime_border_line_width - width) > 0.01:
		_runtime_border_line_width = width
		changed = true
	if _runtime_rebuild_deferred != rebuild_deferred:
		_runtime_rebuild_deferred = rebuild_deferred
		changed = true
	if changed:
		if _vector_border_dirty and not _runtime_rebuild_deferred:
			rebuild_vector_borders()
		queue_redraw()


func get_runtime_stats() -> Dictionary:
	var path_count: int = 0
	for cid_data in _vector_border_paths_by_country.keys():
		var cid: String = str(cid_data)
		var entry = _vector_border_paths_by_country.get(cid, [])
		if typeof(entry) == TYPE_ARRAY:
			path_count += (entry as Array).size()
	return {
		"border_path_count": path_count,
		"country_count": countries.size()
	}


func select_country_at(world_pos: Vector2) -> String:
	var by_cell: String = _country_at_world(world_pos)
	if not by_cell.is_empty():
		selected_country_id = by_cell
		return by_cell

	for i in range(countries.size() - 1, -1, -1):
		var country: Dictionary = countries[i]
		var poly: PackedVector2Array = country.get("border_polygon", PackedVector2Array())
		if poly.size() >= 3 and Geometry2D.is_point_in_polygon(world_pos, poly):
			selected_country_id = str(country.get("id", ""))
			return selected_country_id
	return ""


func create_country_from_stroke(stroke_points: Array[Vector2], terrain_layer, fill_color: Color) -> Dictionary:
	if stroke_points.size() < 1:
		return {"ok": false, "message": "그릴 경로가 없습니다."}
	var begin_result: Dictionary = begin_country_paint(stroke_points[0], terrain_layer, true, fill_color)
	if not bool(begin_result.get("ok", false)):
		return {"ok": false, "message": str(begin_result.get("message", "국가 생성 실패"))}
	var changed_any: bool = false
	for i in range(stroke_points.size() - 1):
		var res: Dictionary = paint_country_segment(stroke_points[i], stroke_points[i + 1], terrain_layer, 20.0)
		changed_any = changed_any or bool(res.get("changed", false))
	end_country_paint()
	if not changed_any:
		return {"ok": false, "message": "육지 위를 칠해 국가를 만들어주세요."}
	return {"ok": true, "created": selected_country_id}


func create_region_from_stroke(stroke_points: Array[Vector2], _terrain_layer) -> Dictionary:
	if selected_country_id.is_empty():
		return {"ok": false, "message": "먼저 국가를 선택하세요."}
	if stroke_points.size() < 3:
		return {"ok": false, "message": "지역 경계선 점이 부족합니다."}

	if _vector_border_dirty:
		rebuild_vector_borders()

	var stroke_poly: PackedVector2Array = _stroke_to_polygon(stroke_points)
	if stroke_poly.size() < 3:
		return {"ok": false, "message": "유효한 지역 경계선을 그려주세요."}
	var stroke_area: float = _polygon_area_abs(stroke_poly)
	if stroke_area < MIN_REGION_AREA:
		return {"ok": false, "message": "그린 영역이 너무 작습니다."}

	var country_paths: Array = _country_polygon_paths(selected_country_id)
	if country_paths.is_empty():
		return {"ok": false, "message": "선택한 국가 경계를 찾을 수 없습니다."}

	var clipped_poly: PackedVector2Array = _largest_intersection_polygon(stroke_poly, country_paths)
	if clipped_poly.size() < 3:
		return {"ok": false, "message": "선택한 국가 내부에서 지역 경계를 그려주세요."}
	if _polygon_area_abs(clipped_poly) < MIN_REGION_AREA:
		return {"ok": false, "message": "국가 내부 유효 영역이 너무 작습니다."}

	var overlap_ratio: float = _max_region_overlap_ratio(selected_country_id, clipped_poly)
	if overlap_ratio > MAX_REGION_OVERLAP_RATIO:
		return {"ok": false, "message": "기존 지역과 너무 많이 겹칩니다. 다른 경계를 그려주세요."}

	_region_seq += 1
	var region_id: String = "region_%03d" % _region_seq
	var region := {
		"id": region_id,
		"name": "지역 %d" % _region_seq,
		"country_id": selected_country_id,
		"style": {
			"line": DEFAULT_REGION_LINE_COLOR
		},
		"polygon": clipped_poly
	}
	regions.append(region)
	_append_region_id_to_country(selected_country_id, region_id)
	queue_redraw()
	return {"ok": true, "created": region_id}


func _stroke_to_polygon(stroke_points: Array[Vector2]) -> PackedVector2Array:
	var cleaned: Array[Vector2] = []
	var min_dist: float = max(1.0, float(cell_size) * 0.35)
	for p in stroke_points:
		if cleaned.is_empty() or cleaned[cleaned.size() - 1].distance_to(p) >= min_dist:
			cleaned.append(p)
	if cleaned.size() >= 2 and cleaned[0].distance_to(cleaned[cleaned.size() - 1]) < min_dist:
		cleaned.remove_at(cleaned.size() - 1)
	return _normalize_polygon(PackedVector2Array(cleaned))


func _normalize_polygon(poly: PackedVector2Array) -> PackedVector2Array:
	var out_points: Array[Vector2] = []
	for p in poly:
		out_points.append(p)
	if out_points.size() >= 2 and out_points[0].distance_to(out_points[out_points.size() - 1]) < 0.01:
		out_points.remove_at(out_points.size() - 1)

	var dedup: Array[Vector2] = []
	for p in out_points:
		if dedup.is_empty() or dedup[dedup.size() - 1].distance_to(p) > 0.01:
			dedup.append(p)
	if dedup.size() >= 2 and dedup[0].distance_to(dedup[dedup.size() - 1]) < 0.01:
		dedup.remove_at(dedup.size() - 1)
	return PackedVector2Array(dedup)


func _country_polygon_paths(country_id: String) -> Array:
	var out: Array = []
	var paths: Array = _vector_border_paths_by_country.get(country_id, [])
	for path_data in paths:
		var path_poly: PackedVector2Array = PackedVector2Array(path_data)
		var normalized: PackedVector2Array = _normalize_polygon(path_poly)
		if normalized.size() >= 3:
			out.append(normalized)

	if not out.is_empty():
		return out

	var country: Dictionary = _find_country(country_id)
	if country.is_empty():
		return out
	var legacy_poly: PackedVector2Array = _normalize_polygon(country.get("border_polygon", PackedVector2Array()))
	if legacy_poly.size() >= 3:
		out.append(legacy_poly)
	return out


func _largest_intersection_polygon(subject: PackedVector2Array, clips: Array) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_area: float = 0.0
	for clip_data in clips:
		var clip_poly: PackedVector2Array = _normalize_polygon(PackedVector2Array(clip_data))
		if clip_poly.size() < 3:
			continue
		var intersections: Array = Geometry2D.intersect_polygons(subject, clip_poly)
		for part_data in intersections:
			var poly: PackedVector2Array = _normalize_polygon(PackedVector2Array(part_data))
			if poly.size() < 3:
				continue
			var area: float = _polygon_area_abs(poly)
			if area > best_area:
				best_area = area
				best = poly
	return best


func _max_region_overlap_ratio(country_id: String, candidate_poly: PackedVector2Array) -> float:
	var candidate_area: float = _polygon_area_abs(candidate_poly)
	if candidate_area <= 0.0:
		return 0.0

	var max_ratio: float = 0.0
	for region_data in regions:
		var region: Dictionary = region_data
		if str(region.get("country_id", "")) != country_id:
			continue
		var existing_poly: PackedVector2Array = _normalize_polygon(region.get("polygon", PackedVector2Array()))
		if existing_poly.size() < 3:
			continue
		var intersects: Array = Geometry2D.intersect_polygons(candidate_poly, existing_poly)
		var overlap_area: float = 0.0
		for part_data in intersects:
			overlap_area += _polygon_area_abs(_normalize_polygon(PackedVector2Array(part_data)))
		var ratio: float = overlap_area / candidate_area
		if ratio > max_ratio:
			max_ratio = ratio
	return max_ratio


func _polygon_area_abs(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var acc: float = 0.0
	for i in range(poly.size()):
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % poly.size()]
		acc += (a.x * b.y) - (b.x * a.y)
	return absf(acc) * 0.5


func _append_region_id_to_country(country_id: String, region_id: String) -> void:
	for country_data in countries:
		var country: Dictionary = country_data
		if str(country.get("id", "")) != country_id:
			continue
		var ids: Array = _safe_region_ids(country.get("region_ids", []))
		if ids.find(region_id) == -1:
			ids.append(region_id)
			country["region_ids"] = ids
		return


func _safe_region_ids(value) -> Array:
	if typeof(value) == TYPE_ARRAY:
		return (value as Array).duplicate()
	return []


func _infer_region_seq(input: Array) -> int:
	var max_seq: int = input.size()
	for region_data in input:
		var region: Dictionary = region_data
		var rid: String = str(region.get("id", ""))
		if not rid.begins_with("region_"):
			continue
		if rid.length() <= 7:
			continue
		var suffix: String = rid.substr(7, rid.length() - 7)
		if not suffix.is_valid_int():
			continue
		max_seq = max(max_seq, int(suffix))
	return max_seq


func set_country_color(country_id: String, fill_color: Color) -> bool:
	for c in countries:
		if str(c.get("id", "")) != country_id:
			continue
		c["style"]["fill"] = _color_hex(fill_color)
		c["style"]["line"] = _color_hex(_compute_border_color(fill_color))
		_recolor_country_cells(country_id)
		_fill_texture.update(_fill_image)
		queue_redraw()
		return true
	return false


func set_country_name(country_id: String, new_name: String) -> bool:
	var cleaned: String = new_name.strip_edges()
	if cleaned.is_empty():
		return false
	for c in countries:
		if str(c.get("id", "")) != country_id:
			continue
		c["name"] = cleaned
		queue_redraw()
		return true
	return false


func get_country_name(country_id: String) -> String:
	for c_data in countries:
		var c: Dictionary = c_data
		if str(c.get("id", "")) == country_id:
			return str(c.get("name", country_id))
	return country_id


func get_country_info(country_id: String) -> Dictionary:
	var c: Dictionary = _find_country(country_id)
	if c.is_empty():
		return {}
	return {
		"id": country_id,
		"name": str(c.get("name", country_id)),
		"fill": str(c.get("style", {}).get("fill", "#ffffff")),
		"cells": int(_country_cell_count.get(country_id, 0))
	}


func _next_country_color() -> Color:
	var idx: int = _country_seq - 1
	if idx >= 0 and idx < AUTO_COUNTRY_COLORS.size():
		return Color(AUTO_COUNTRY_COLORS[idx])
	var hue: float = fposmod(float(_country_seq) * 0.61803398875, 1.0)
	return Color.from_hsv(hue, 0.68, 0.90, 1.0)


func serialize_state() -> Dictionary:
	return {
		"countries": _serialize_countries(countries),
		"regions": _serialize_regions(regions),
		"selected_country_id": selected_country_id,
		"country_seq": _country_seq,
		"region_seq": _region_seq,
		"map_size": {"x": map_size.x, "y": map_size.y},
		"cell_size": cell_size,
		"owner_grid": Array(owner_grid)
	}


func deserialize_state(data: Dictionary) -> void:
	countries = _deserialize_countries(data.get("countries", []))
	regions = _deserialize_regions(data.get("regions", []))
	selected_country_id = str(data.get("selected_country_id", ""))
	_country_seq = int(data.get("country_seq", countries.size()))
	var loaded_region_seq: int = int(data.get("region_seq", 0))
	_region_seq = max(loaded_region_seq, _infer_region_seq(regions))

	var ms_data: Dictionary = data.get("map_size", {"x": map_size.x, "y": map_size.y})
	var mx: int = int(ms_data.get("x", map_size.x))
	var my: int = int(ms_data.get("y", map_size.y))
	configure_map(Vector2i(mx, my), int(data.get("cell_size", cell_size)))

	var raw_grid: Array = data.get("owner_grid", [])
	if not raw_grid.is_empty() and raw_grid.size() == owner_grid.size():
		for i in range(owner_grid.size()):
			owner_grid[i] = int(raw_grid[i])
		_rebuild_slot_maps_and_stats()
		_rebuild_fill_from_grid()
	else:
		_rasterize_legacy_polygons_into_grid()

	if not selected_country_id.is_empty() and _find_country(selected_country_id).is_empty():
		selected_country_id = ""
	if selected_country_id.is_empty() and countries.size() > 0:
		selected_country_id = str(countries[0].get("id", ""))
	_mark_all_country_anchors_dirty()
	_fill_texture.update(_fill_image)
	_vector_border_dirty = true
	rebuild_vector_borders()
	queue_redraw()


func capture_runtime_state() -> Dictionary:
	return {
		"countries": countries.duplicate(true),
		"regions": regions.duplicate(true),
		"selected_country_id": selected_country_id,
		"country_seq": _country_seq,
		"region_seq": _region_seq,
		"map_size": map_size,
		"cell_size": cell_size,
		"owner_grid": owner_grid.duplicate()
	}


func restore_runtime_state(data: Dictionary) -> void:
	countries = data.get("countries", []).duplicate(true)
	regions = data.get("regions", []).duplicate(true)
	selected_country_id = str(data.get("selected_country_id", ""))
	_country_seq = int(data.get("country_seq", countries.size()))
	var loaded_region_seq: int = int(data.get("region_seq", 0))
	_region_seq = max(loaded_region_seq, _infer_region_seq(regions))
	configure_map(data.get("map_size", map_size), int(data.get("cell_size", cell_size)))
	owner_grid = data.get("owner_grid", owner_grid).duplicate()
	if owner_grid.size() != grid_size.x * grid_size.y:
		owner_grid.resize(grid_size.x * grid_size.y)
		for i in range(owner_grid.size()):
			owner_grid[i] = 0
		_rasterize_legacy_polygons_into_grid()
	else:
		_rebuild_slot_maps_and_stats()
		_rebuild_fill_from_grid()
	_mark_all_country_anchors_dirty()
	_fill_texture.update(_fill_image)
	_vector_border_dirty = true
	rebuild_vector_borders()
	queue_redraw()


func _create_country(fill_color: Color) -> String:
	_country_seq += 1
	var country_id: String = "country_%03d" % _country_seq
	var line_color: Color = _compute_border_color(fill_color)
	var country := {
		"id": country_id,
		"name": "국가 %d" % _country_seq,
		"border_polygon": PackedVector2Array(),
		"style": {
			"fill": _color_hex(fill_color),
			"line": _color_hex(line_color),
			"label": "#f5f0e8"
		},
		"region_ids": []
	}
	countries.append(country)
	var slot: int = countries.size()
	_country_to_slot[country_id] = slot
	_slot_to_country[slot] = country_id
	_country_cell_count[country_id] = 0
	_country_sum_pos[country_id] = Vector2.ZERO
	_mark_anchor_dirty(country_id)
	return country_id


func _country_at_world(world_pos: Vector2) -> String:
	var c: Vector2i = _world_to_cell(world_pos)
	if not _is_cell_in_range(c):
		return ""
	var slot: int = int(owner_grid[c.y * grid_size.x + c.x])
	if slot > 0 and _slot_to_country.has(slot):
		return str(_slot_to_country[slot])
	return ""


func _paint_country_stamp(center_world: Vector2, brush_radius: float, slot: int, terrain_layer) -> bool:
	var center_cell: Vector2i = _world_to_cell(center_world)
	var cell_rad: int = int(ceil(brush_radius / float(cell_size))) + 1
	var min_cx: int = max(0, center_cell.x - cell_rad)
	var min_cy: int = max(0, center_cell.y - cell_rad)
	var max_cx: int = min(grid_size.x - 1, center_cell.x + cell_rad)
	var max_cy: int = min(grid_size.y - 1, center_cell.y + cell_rad)

	var changed: bool = false
	for cy in range(min_cy, max_cy + 1):
		for cx in range(min_cx, max_cx + 1):
			var world_center := _cell_center_world(cx, cy)
			if world_center.distance_to(center_world) > brush_radius:
				continue
			if terrain_layer != null and not terrain_layer.is_point_on_land(world_center):
				continue
			var idx: int = cy * grid_size.x + cx
			var prev_slot: int = int(owner_grid[idx])
			if prev_slot == slot:
				continue
			owner_grid[idx] = slot
			_update_country_stats_for_cell(prev_slot, cx, cy, -1)
			_update_country_stats_for_cell(slot, cx, cy, +1)
			_set_fill_pixel_by_slot(cx, cy, slot)
			changed = true
	return changed


func _update_country_stats_for_cell(slot: int, cx: int, cy: int, delta: int) -> void:
	if slot <= 0:
		return
	if not _slot_to_country.has(slot):
		return
	var cid: String = str(_slot_to_country[slot])
	var count: int = int(_country_cell_count.get(cid, 0))
	var sum_pos: Vector2 = _country_sum_pos.get(cid, Vector2.ZERO)
	var wp: Vector2 = _cell_center_world(cx, cy)
	count += delta
	sum_pos += wp * float(delta)
	if count <= 0:
		_country_cell_count[cid] = 0
		_country_sum_pos[cid] = Vector2.ZERO
	else:
		_country_cell_count[cid] = count
		_country_sum_pos[cid] = sum_pos
	_mark_anchor_dirty(cid)


func _set_fill_pixel_by_slot(cx: int, cy: int, slot: int) -> void:
	if slot <= 0 or not _slot_to_country.has(slot):
		_fill_image.set_pixel(cx, cy, Color(0, 0, 0, 0))
		return
	var cid: String = str(_slot_to_country[slot])
	var col := Color(str(_find_country(cid).get("style", {}).get("fill", "#888888")))
	col.a = 1.0
	_fill_image.set_pixel(cx, cy, col)


func _draw_country_label(country: Dictionary) -> void:
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return
	var cid: String = str(country.get("id", ""))
	var count: int = int(_country_cell_count.get(cid, 0))
	if count <= 0:
		return
	var label: String = str(country.get("name", ""))
	if label.is_empty():
		return
	var pos: Vector2 = _country_label_anchor(cid)
	var label_hex: String = str(country.get("style", {}).get("label", "#f5f0e8"))
	var font_size: int = 16
	var text_size: Vector2 = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var baseline_y: float = pos.y - (text_size.y * 0.5) + font.get_ascent(font_size)
	var draw_pos := Vector2(pos.x - (text_size.x * 0.5), baseline_y)
	draw_string(font, draw_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(label_hex))


func _country_label_anchor(country_id: String) -> Vector2:
	if bool(_country_anchor_dirty.get(country_id, true)) and country_id == _active_paint_country_id:
		var live_count: int = int(_country_cell_count.get(country_id, 0))
		if live_count > 0:
			return _country_sum_pos.get(country_id, Vector2.ZERO) / float(live_count)
	if _country_anchor_cache.has(country_id) and not bool(_country_anchor_dirty.get(country_id, true)):
		return _country_anchor_cache[country_id]
	var computed: Vector2 = _compute_country_label_anchor(country_id)
	_country_anchor_cache[country_id] = computed
	_country_anchor_dirty[country_id] = false
	return computed


func _compute_country_label_anchor(country_id: String) -> Vector2:
	var count: int = int(_country_cell_count.get(country_id, 0))
	if count <= 0:
		return Vector2.ZERO
	var slot: int = int(_country_to_slot.get(country_id, 0))
	if slot <= 0:
		return Vector2.ZERO

	var sum_pos: Vector2 = _country_sum_pos.get(country_id, Vector2.ZERO)
	var avg: Vector2 = sum_pos / float(count)

	var cells: Array[Vector2i] = []
	var min_x: int = grid_size.x
	var min_y: int = grid_size.y
	var max_x: int = -1
	var max_y: int = -1
	for i in range(owner_grid.size()):
		if int(owner_grid[i]) != slot:
			continue
		var cx: int = i % grid_size.x
		var cy: int = int(i / grid_size.x)
		cells.append(Vector2i(cx, cy))
		min_x = min(min_x, cx)
		min_y = min(min_y, cy)
		max_x = max(max_x, cx)
		max_y = max(max_y, cy)

	if cells.is_empty():
		return avg

	var w: int = max_x - min_x + 1
	var h: int = max_y - min_y + 1
	var mask := PackedByteArray()
	mask.resize(w * h)
	for i in range(mask.size()):
		mask[i] = 0

	for cell in cells:
		var lx: int = cell.x - min_x
		var ly: int = cell.y - min_y
		mask[ly * w + lx] = 1

	var dist := PackedInt32Array()
	dist.resize(w * h)
	for i in range(dist.size()):
		dist[i] = -1

	var queue: Array[Vector2i] = []
	var head: int = 0
	for cell in cells:
		var lx: int = cell.x - min_x
		var ly: int = cell.y - min_y
		if _is_local_boundary(mask, w, h, lx, ly):
			dist[ly * w + lx] = 0
			queue.append(Vector2i(lx, ly))

	if queue.is_empty():
		return _nearest_country_cell_to_point(cells, avg)

	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		var cur_idx: int = cur.y * w + cur.x
		var next_dist: int = dist[cur_idx] + 1
		for d in dirs:
			var nx: int = cur.x + d.x
			var ny: int = cur.y + d.y
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var nidx: int = ny * w + nx
			if mask[nidx] == 0 or dist[nidx] >= 0:
				continue
			dist[nidx] = next_dist
			queue.append(Vector2i(nx, ny))

	var best_world: Vector2 = _nearest_country_cell_to_point(cells, avg)
	var best_dist: int = -1
	var best_cost: float = INF
	for cell in cells:
		var lx: int = cell.x - min_x
		var ly: int = cell.y - min_y
		var d: int = dist[ly * w + lx]
		if d < 0:
			d = 0
		var wp: Vector2 = _cell_center_world(cell.x, cell.y)
		var cost: float = wp.distance_to(avg)
		if d > best_dist or (d == best_dist and cost < best_cost):
			best_dist = d
			best_cost = cost
			best_world = wp
	return best_world


func _is_local_boundary(mask: PackedByteArray, w: int, h: int, lx: int, ly: int) -> bool:
	if lx < 0 or ly < 0 or lx >= w or ly >= h:
		return true
	if mask[ly * w + lx] == 0:
		return false
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for d in dirs:
		var nx: int = lx + d.x
		var ny: int = ly + d.y
		if nx < 0 or ny < 0 or nx >= w or ny >= h:
			return true
		if mask[ny * w + nx] == 0:
			return true
	return false


func _nearest_country_cell_to_point(cells: Array[Vector2i], target_world: Vector2) -> Vector2:
	var best: Vector2 = _cell_center_world(cells[0].x, cells[0].y)
	var best_d: float = best.distance_to(target_world)
	for cell in cells:
		var wp: Vector2 = _cell_center_world(cell.x, cell.y)
		var d: float = wp.distance_to(target_world)
		if d < best_d:
			best_d = d
			best = wp
	return best


func _mark_anchor_dirty(country_id: String) -> void:
	if country_id.is_empty():
		return
	_country_anchor_dirty[country_id] = true


func _mark_all_country_anchors_dirty() -> void:
	for c_data in countries:
		var c: Dictionary = c_data
		var cid: String = str(c.get("id", ""))
		if not cid.is_empty():
			_country_anchor_dirty[cid] = true


func _recolor_country_cells(country_id: String) -> void:
	var slot: int = int(_country_to_slot.get(country_id, 0))
	if slot <= 0:
		return
	for i in range(owner_grid.size()):
		if int(owner_grid[i]) != slot:
			continue
		var cx: int = i % grid_size.x
		var cy: int = int(i / grid_size.x)
		_set_fill_pixel_by_slot(cx, cy, slot)


func _rebuild_slot_maps_and_stats() -> void:
	_country_to_slot.clear()
	_slot_to_country.clear()
	_country_cell_count.clear()
	_country_sum_pos.clear()
	_country_anchor_cache.clear()
	_country_anchor_dirty.clear()

	var slot: int = 1
	for c_data in countries:
		var c: Dictionary = c_data
		var cid: String = str(c.get("id", ""))
		if cid.is_empty():
			continue
		_country_to_slot[cid] = slot
		_slot_to_country[slot] = cid
		_country_cell_count[cid] = 0
		_country_sum_pos[cid] = Vector2.ZERO
		_country_anchor_dirty[cid] = true
		slot += 1

	for i in range(owner_grid.size()):
		var s: int = int(owner_grid[i])
		if s <= 0 or not _slot_to_country.has(s):
			owner_grid[i] = 0
			continue
		var cid: String = str(_slot_to_country[s])
		var cx: int = i % grid_size.x
		var cy: int = int(i / grid_size.x)
		var p: Vector2 = _cell_center_world(cx, cy)
		_country_cell_count[cid] = int(_country_cell_count.get(cid, 0)) + 1
		_country_sum_pos[cid] = _country_sum_pos.get(cid, Vector2.ZERO) + p


func _rebuild_fill_from_grid() -> void:
	_fill_image.fill(Color(0, 0, 0, 0))
	for i in range(owner_grid.size()):
		var slot: int = int(owner_grid[i])
		if slot <= 0 or not _slot_to_country.has(slot):
			continue
		var cx: int = i % grid_size.x
		var cy: int = int(i / grid_size.x)
		_set_fill_pixel_by_slot(cx, cy, slot)


func _slot_at_cell(cx: int, cy: int) -> int:
	if cx < 0 or cy < 0 or cx >= grid_size.x or cy >= grid_size.y:
		return 0
	return int(owner_grid[cy * grid_size.x + cx])


func _extract_country_border_segments() -> Dictionary:
	var by_country: Dictionary = {}
	for cy in range(grid_size.y):
		for cx in range(grid_size.x):
			var slot: int = _slot_at_cell(cx, cy)
			if slot <= 0 or not _slot_to_country.has(slot):
				continue
			var cid: String = str(_slot_to_country[slot])
			if _slot_at_cell(cx - 1, cy) != slot:
				_push_segment(by_country, cid, Vector2i(cx, cy + 1), Vector2i(cx, cy))
			if _slot_at_cell(cx + 1, cy) != slot:
				_push_segment(by_country, cid, Vector2i(cx + 1, cy), Vector2i(cx + 1, cy + 1))
			if _slot_at_cell(cx, cy - 1) != slot:
				_push_segment(by_country, cid, Vector2i(cx, cy), Vector2i(cx + 1, cy))
			if _slot_at_cell(cx, cy + 1) != slot:
				_push_segment(by_country, cid, Vector2i(cx + 1, cy + 1), Vector2i(cx, cy + 1))
	return by_country


func _push_segment(container: Dictionary, country_id: String, a: Vector2i, b: Vector2i) -> void:
	if not container.has(country_id):
		container[country_id] = []
	var arr: Array = container[country_id]
	arr.append({"a": a, "b": b})
	container[country_id] = arr


func _v2i_key(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]


func _find_next_segment_idx(start_map: Dictionary, used: Array, point: Vector2i) -> int:
	var key: String = _v2i_key(point)
	if not start_map.has(key):
		return -1
	var candidates: Array = start_map[key]
	for idx_data in candidates:
		var idx: int = int(idx_data)
		if not bool(used[idx]):
			return idx
	return -1


func _link_segments_to_paths(segments: Array) -> Array:
	var starts: Array[Vector2i] = []
	var ends: Array[Vector2i] = []
	var start_map: Dictionary = {}

	for i in range(segments.size()):
		var seg: Dictionary = segments[i]
		var a: Vector2i = seg.get("a", Vector2i.ZERO)
		var b: Vector2i = seg.get("b", Vector2i.ZERO)
		starts.append(a)
		ends.append(b)
		var key: String = _v2i_key(a)
		if not start_map.has(key):
			start_map[key] = []
		var arr: Array = start_map[key]
		arr.append(i)
		start_map[key] = arr

	var used: Array = []
	used.resize(starts.size())
	for i in range(used.size()):
		used[i] = false

	var paths: Array = []
	var remaining: int = starts.size()
	while remaining > 0:
		var seed_idx: int = -1
		for i in range(used.size()):
			if not bool(used[i]):
				seed_idx = i
				break
		if seed_idx < 0:
			break

		used[seed_idx] = true
		remaining -= 1
		var path: Array[Vector2i] = [starts[seed_idx], ends[seed_idx]]
		var cur: Vector2i = ends[seed_idx]
		var guard: int = starts.size() + 8
		while guard > 0:
			guard -= 1
			if cur == path[0]:
				break
			var next_idx: int = _find_next_segment_idx(start_map, used, cur)
			if next_idx < 0:
				break
			used[next_idx] = true
			remaining -= 1
			cur = ends[next_idx]
			path.append(cur)
		paths.append(path)
	return paths


func _to_world_path(cell_path: Array) -> PackedVector2Array:
	var wp := PackedVector2Array()
	for p_data in cell_path:
		var p: Vector2i = p_data
		wp.append(Vector2(float(p.x * cell_size), float(p.y * cell_size)))
	if wp.size() >= 2 and wp[0] != wp[wp.size() - 1]:
		wp.append(wp[0])
	return wp


func _chaikin_closed_once(path: PackedVector2Array) -> PackedVector2Array:
	if path.size() < 4:
		return path
	var base: Array[Vector2] = []
	for i in range(path.size()):
		if i == path.size() - 1 and path[i] == path[0]:
			continue
		base.append(path[i])
	if base.size() < 3:
		return path

	var out := PackedVector2Array()
	for i in range(base.size()):
		var p0: Vector2 = base[i]
		var p1: Vector2 = base[(i + 1) % base.size()]
		out.append(p0.lerp(p1, 0.25))
		out.append(p0.lerp(p1, 0.75))
	if out.size() >= 2:
		out.append(out[0])
	return out


func _rasterize_legacy_polygons_into_grid() -> void:
	_rebuild_slot_maps_and_stats()
	for i in range(owner_grid.size()):
		owner_grid[i] = 0
	for c_data in countries:
		var c: Dictionary = c_data
		var cid: String = str(c.get("id", ""))
		var poly: PackedVector2Array = c.get("border_polygon", PackedVector2Array())
		if cid.is_empty() or poly.size() < 3:
			continue
		var slot: int = int(_country_to_slot.get(cid, 0))
		if slot <= 0:
			continue
		for cy in range(grid_size.y):
			for cx in range(grid_size.x):
				var p: Vector2 = _cell_center_world(cx, cy)
				if Geometry2D.is_point_in_polygon(p, poly):
					owner_grid[cy * grid_size.x + cx] = slot
	_rebuild_slot_maps_and_stats()
	_rebuild_fill_from_grid()
	_vector_border_dirty = true


func _cell_center_world(cx: int, cy: int) -> Vector2:
	return Vector2((float(cx) + 0.5) * float(cell_size), (float(cy) + 0.5) * float(cell_size))


func _world_to_cell(world_pos: Vector2) -> Vector2i:
	return Vector2i(
		clampi(int(floor(world_pos.x / float(cell_size))), 0, max(grid_size.x - 1, 0)),
		clampi(int(floor(world_pos.y / float(cell_size))), 0, max(grid_size.y - 1, 0))
	)


func _is_cell_in_range(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < grid_size.x and c.y < grid_size.y


func _color_hex(c: Color) -> String:
	return "#%s" % c.to_html(false)


func _compute_border_color(fill_color: Color) -> Color:
	var luma: float = (fill_color.r * 0.299) + (fill_color.g * 0.587) + (fill_color.b * 0.114)
	if luma > 0.58:
		return fill_color.darkened(0.55)
	return fill_color.lightened(0.45)


func _find_country(country_id: String) -> Dictionary:
	for c in countries:
		if str(c.get("id", "")) == country_id:
			return c
	return {}


func _closed_polyline(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(poly)
	if out.size() >= 1:
		out.append(out[0])
	return out


func _serialize_countries(input: Array) -> Array:
	var out: Array = []
	for country_data in input:
		var country: Dictionary = country_data
		var poly_json: Array = []
		for p in country.get("border_polygon", PackedVector2Array()):
			poly_json.append({"x": p.x, "y": p.y})
		out.append({
			"id": country.get("id", ""),
			"name": country.get("name", ""),
			"style": country.get("style", {}),
			"region_ids": country.get("region_ids", []),
			"border_polygon": poly_json
		})
	return out


func _deserialize_countries(input: Array) -> Array:
	var out: Array = []
	for country_data in input:
		var country: Dictionary = country_data
		var poly := PackedVector2Array()
		for p_data in country.get("border_polygon", []):
			var p: Dictionary = p_data
			poly.append(Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0))))
		out.append({
			"id": country.get("id", ""),
			"name": country.get("name", ""),
			"style": country.get("style", {"fill": "#cc9966", "line": "#774c2e", "label": "#f5f0e8"}),
			"region_ids": country.get("region_ids", []),
			"border_polygon": poly
		})
	return out


func _serialize_regions(input: Array) -> Array:
	var out: Array = []
	for region_data in input:
		var region: Dictionary = region_data
		var poly_json: Array = []
		for p in region.get("polygon", PackedVector2Array()):
			poly_json.append({"x": p.x, "y": p.y})
		out.append({
			"id": region.get("id", ""),
			"name": region.get("name", ""),
			"country_id": region.get("country_id", ""),
			"style": region.get("style", {}),
			"polygon": poly_json
		})
	return out


func _deserialize_regions(input: Array) -> Array:
	var out: Array = []
	for region_data in input:
		var region: Dictionary = region_data
		var poly := PackedVector2Array()
		for p_data in region.get("polygon", []):
			var p: Dictionary = p_data
			poly.append(Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0))))
		out.append({
			"id": region.get("id", ""),
			"name": region.get("name", ""),
			"country_id": region.get("country_id", ""),
			"style": region.get("style", {"line": "#2b4f6a"}),
			"polygon": poly
		})
	return out
