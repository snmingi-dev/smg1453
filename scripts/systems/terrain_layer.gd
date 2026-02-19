extends Node2D
class_name TerrainLayer

const LAND_COLOR := Color("#8B5A2B")
const WATER_COLOR := Color("#264865")
const COAST_COLOR := Color("#F0D8A8")
const MOUNTAIN_COLOR := Color("#5F5448")
const RIVER_COLOR := Color("#4BA1DE")
const LAND_THRESHOLD := 0.5

var map_size: Vector2i = Vector2i(1920, 1080)
var tile_size: int = 64

var land_mask: Image
var land_bits: PackedByteArray
var display_image: Image

var mountain_strokes: Array = []
var river_strokes: Array = []

var _chunk_size_px: int = 256
var _chunks_root: Node2D
var _chunk_textures: Dictionary = {}
var _chunk_images: Dictionary = {}
var _noise := FastNoiseLite.new()
var _brush_preview_visible: bool = false
var _brush_preview_pos: Vector2 = Vector2.ZERO
var _brush_preview_radius: float = 12.0
var _brush_preview_is_erase: bool = false
var _brush_preview_type: String = "circle"
var _brush_preview_noise_amount: float = 1.0
var _runtime_mountain_detail: bool = true
var _runtime_river_detail: bool = true
var _runtime_brush_preview_detail: String = "full"
var _runtime_noise_complexity: String = "high"
var _flat_paint_mode: bool = true
var _active_chunks_estimate: int = 0
var _pending_land_dirty: Rect2i = Rect2i()
var _has_pending_land_dirty: bool = false
var _overlay_detail_enabled: bool = true
var _overlay_detail_tick: float = 0.0
var _last_cam_for_detail: Vector2 = Vector2(INF, INF)
var _last_zoom_for_detail: float = INF

const DETAIL_RECHECK_SEC := 0.10
const DETAIL_MOVE_THRESHOLD := 34.0
const CULL_REDRAW_MOVE_EPS := 1.5
const CULL_REDRAW_ZOOM_EPS := 0.01
const COAST_LAND_BLEND_STRENGTH := 0.44
const COAST_WATER_BLEND_STRENGTH := 0.66


func _ready() -> void:
	_noise.seed = 1337
	_noise.frequency = 0.04
	_noise.fractal_octaves = 3
	_init_images(map_size)
	_build_chunk_renderers()
	set_process(true)


func _process(_delta: float) -> void:
	_update_overlay_detail_state(_delta)
	flush_pending_updates()


func _draw() -> void:
	var cam := get_viewport().get_camera_2d()
	var zoom_lod: float = 1.0
	if cam != null:
		zoom_lod = max(cam.zoom.x, cam.zoom.y)
	_active_chunks_estimate = _estimate_active_chunks(cam)
	var view_rect: Rect2 = _camera_world_rect(cam)

	var mountain_step: int = 1
	if zoom_lod >= 4.0:
		mountain_step = 4
	elif zoom_lod >= 2.8:
		mountain_step = 3
	elif zoom_lod >= 1.8:
		mountain_step = 2
	if not _runtime_mountain_detail:
		mountain_step = max(mountain_step, 3)
	if not _overlay_detail_enabled:
		mountain_step = max(mountain_step, 4)

	var draw_mountain_inner: bool = _runtime_mountain_detail and _overlay_detail_enabled and zoom_lod < 2.4
	var draw_mountain_relief: bool = _runtime_mountain_detail and _overlay_detail_enabled and zoom_lod < 1.4
	var draw_river_inner: bool = _runtime_river_detail and _overlay_detail_enabled and zoom_lod < 2.2
	var mountain_highlight := Color(
		minf(1.0, MOUNTAIN_COLOR.r + 0.16),
		minf(1.0, MOUNTAIN_COLOR.g + 0.14),
		minf(1.0, MOUNTAIN_COLOR.b + 0.12),
		0.42
	)
	var mountain_shadow := Color(
		maxf(0.0, MOUNTAIN_COLOR.r - 0.24),
		maxf(0.0, MOUNTAIN_COLOR.g - 0.22),
		maxf(0.0, MOUNTAIN_COLOR.b - 0.20),
		0.28
	)
	var river_width_scale: float = 1.0
	if zoom_lod >= 3.0:
		river_width_scale = 0.78
	elif zoom_lod >= 1.8:
		river_width_scale = 0.9
	elif zoom_lod < 0.9:
		river_width_scale = 1.08
	var river_bank_color := Color(RIVER_COLOR.r * 0.7, RIVER_COLOR.g * 0.76, RIVER_COLOR.b * 0.85, 0.26)
	var river_core_color := Color(minf(1.0, RIVER_COLOR.r + 0.18), minf(1.0, RIVER_COLOR.g + 0.12), minf(1.0, RIVER_COLOR.b + 0.08), 0.42)

	for si in range(mountain_strokes.size()):
		var stroke: Dictionary = mountain_strokes[si]
		var points: Array = stroke.get("points", [])
		if points.is_empty():
			continue
		var size: float = stroke.get("size", 18.0)
		var dirs: PackedVector2Array = _mountain_dirs_from_stroke(stroke, points)
		var stroke_bounds: Rect2 = _mountain_bounds(stroke, points, size)
		mountain_strokes[si] = stroke
		if not view_rect.intersects(stroke_bounds, true):
			continue
		for i in range(0, points.size(), mountain_step):
			var pt: Vector2 = points[i]
			var dir: Vector2 = Vector2.RIGHT
			if not dirs.is_empty():
				dir = dirs[min(i, dirs.size() - 1)]
			var normal := Vector2(-dir.y, dir.x)
			draw_circle(pt, size * 0.48, MOUNTAIN_COLOR)
			if draw_mountain_inner:
				draw_circle(pt + normal * (-size * 0.12) - dir * (size * 0.08), size * 0.22, mountain_highlight)
				if draw_mountain_relief:
					draw_circle(pt + normal * (size * 0.14) + dir * (size * 0.10), size * 0.17, mountain_shadow)
					draw_line(
						pt - dir * (size * 0.16) + normal * (size * 0.02),
						pt + dir * (size * 0.16) + normal * (size * 0.02),
						Color(mountain_shadow.r, mountain_shadow.g, mountain_shadow.b, 0.33),
						maxf(1.0, size * 0.08)
					)

	for ri in range(river_strokes.size()):
		var river: Dictionary = river_strokes[ri]
		var points: PackedVector2Array = _river_points_for_draw(river, zoom_lod)
		if points.size() < 2:
			continue
		var width: float = river.get("width", 6.0)
		var flow_to_end: bool = bool(river.get("flow_to_end", true))
		if not bool(river.get("sea_clamped", false)):
			points = _clip_river_points_to_land(points, width, 4.0, false)
			if points.size() < 2:
				continue
		var bounds_width: float = max(1.0, width * river_width_scale * 1.45)
		var river_bounds: Rect2 = _stroke_bounds_from_packed(points, max(2.0, bounds_width * 0.95))
		river["bounds"] = _bounds_dict_from_rect(river_bounds)
		river_strokes[ri] = river
		if not view_rect.intersects(river_bounds, true):
			continue
		_draw_river_stylized(points, width, river_width_scale, flow_to_end, draw_river_inner, zoom_lod, river_bank_color, river_core_color)

	if _brush_preview_visible:
		var fill_col: Color = Color("#E99A74") if _brush_preview_is_erase else Color("#F2C578")
		fill_col.a = 0.16
		var line_col: Color = Color("#FF7C5C") if _brush_preview_is_erase else Color("#FFE8A9")
		draw_circle(_brush_preview_pos, _brush_preview_radius, fill_col)
		draw_arc(_brush_preview_pos, _brush_preview_radius, 0.0, TAU, 48, line_col, 1.8, true)
		var preview_full: bool = _runtime_brush_preview_detail == "full"
		if preview_full and _brush_preview_type == "texture":
			var dots: int = 28
			for i in range(dots):
				var ang: float = (TAU * float(i)) / float(dots)
				var dir := Vector2(cos(ang), sin(ang))
				var jitter: float = 0.45 + ((_noise.get_noise_2d(_brush_preview_pos.x * 0.09 + float(i) * 1.7, _brush_preview_pos.y * 0.09 - float(i) * 1.3) + 1.0) * 0.26)
				var p := _brush_preview_pos + dir * (_brush_preview_radius * jitter)
				draw_circle(p, 1.0, Color(line_col, 0.82))
			draw_arc(_brush_preview_pos, _brush_preview_radius * 0.9, 0.0, TAU, 36, Color(line_col, 0.5), 1.0, true)
		elif preview_full and _brush_preview_type == "noise":
			var jag: PackedVector2Array = PackedVector2Array()
			var samples: int = 24
			for i in range(samples + 1):
				var ang: float = (TAU * float(i)) / float(samples)
				var dir := Vector2(cos(ang), sin(ang))
				var n: float = _noise.get_noise_2d(
					_brush_preview_pos.x * 0.07 + dir.x * 11.0 + float(i) * 0.73,
					_brush_preview_pos.y * 0.07 + dir.y * 11.0 - float(i) * 0.41
				)
				var noisy_rr: float = 0.76 + ((n + 1.0) * 0.16)
				var rr: float = _brush_preview_radius * lerpf(1.0, noisy_rr, _brush_preview_noise_amount)
				jag.append(_brush_preview_pos + dir * rr)
			draw_polyline(jag, Color(line_col, 0.95), 1.5, true)
		draw_line(
			_brush_preview_pos + Vector2(-_brush_preview_radius * 0.25, 0),
			_brush_preview_pos + Vector2(_brush_preview_radius * 0.25, 0),
			line_col,
			1.2
		)
		draw_line(
			_brush_preview_pos + Vector2(0, -_brush_preview_radius * 0.25),
			_brush_preview_pos + Vector2(0, _brush_preview_radius * 0.25),
			line_col,
			1.2
		)

	draw_rect(Rect2(Vector2.ZERO, map_size), Color.WHITE, false, 2.0)


func _init_images(size_px: Vector2i) -> void:
	map_size = size_px
	land_mask = Image.create(map_size.x, map_size.y, false, Image.FORMAT_R8)
	land_mask.fill(Color(0, 0, 0, 1))
	land_bits = PackedByteArray()
	land_bits.resize(map_size.x * map_size.y)
	land_bits.fill(0)

	display_image = Image.create(map_size.x, map_size.y, false, Image.FORMAT_RGBA8)
	display_image.fill(WATER_COLOR)


func set_brush_preview(world_pos: Vector2, radius: float, visible: bool, is_erase: bool = false, brush_type: String = "circle", noise_amount: float = 1.0) -> void:
	var clamped_pos := Vector2(
		clampf(world_pos.x, 0.0, float(map_size.x - 1)),
		clampf(world_pos.y, 0.0, float(map_size.y - 1))
	)
	var clamped_radius: float = max(2.0, radius)
	var clamped_noise: float = clampf(noise_amount, 0.0, 1.0)
	var changed: bool = false
	if _brush_preview_visible != visible:
		_brush_preview_visible = visible
		changed = true
	if _brush_preview_pos.distance_to(clamped_pos) > 0.1:
		_brush_preview_pos = clamped_pos
		changed = true
	if absf(_brush_preview_radius - clamped_radius) > 0.1:
		_brush_preview_radius = clamped_radius
		changed = true
	if _brush_preview_is_erase != is_erase:
		_brush_preview_is_erase = is_erase
		changed = true
	if _brush_preview_type != brush_type:
		_brush_preview_type = brush_type
		changed = true
	if absf(_brush_preview_noise_amount - clamped_noise) > 0.001:
		_brush_preview_noise_amount = clamped_noise
		changed = true
	if changed:
		queue_redraw()


func set_runtime_quality(profile: Dictionary) -> void:
	var changed: bool = false
	var mountain_detail: bool = bool(profile.get("mountain_detail", _runtime_mountain_detail))
	var river_detail: bool = bool(profile.get("river_detail", _runtime_river_detail))
	var preview_detail: String = str(profile.get("brush_preview_detail", _runtime_brush_preview_detail))
	var noise_complexity: String = str(profile.get("noise_complexity", _runtime_noise_complexity))
	var flat_paint_mode: bool = bool(profile.get("flat_paint_mode", _flat_paint_mode))
	if preview_detail != "full" and preview_detail != "simple":
		preview_detail = "full"
	if noise_complexity != "high" and noise_complexity != "medium" and noise_complexity != "low":
		noise_complexity = "high"

	if _runtime_mountain_detail != mountain_detail:
		_runtime_mountain_detail = mountain_detail
		changed = true
	if _runtime_river_detail != river_detail:
		_runtime_river_detail = river_detail
		changed = true
	if _runtime_brush_preview_detail != preview_detail:
		_runtime_brush_preview_detail = preview_detail
		changed = true
	if _runtime_noise_complexity != noise_complexity:
		_runtime_noise_complexity = noise_complexity
		changed = true
	if _flat_paint_mode != flat_paint_mode:
		_flat_paint_mode = flat_paint_mode
		changed = true
	if changed:
		queue_redraw()


func get_runtime_stats() -> Dictionary:
	return {
		"active_chunks": _active_chunks_estimate,
		"map_size": {"x": map_size.x, "y": map_size.y},
		"chunk_size": _chunk_size_px
	}


func apply_land_stroke(stroke_points: Array[Vector2], add_land: bool, config) -> Array[Vector2i]:
	if stroke_points.size() < 1:
		return []

	var points := stroke_points.duplicate()
	var btype: String = str(config.brush_type)
	var noise_amount: float = _noise_amount_from_config(config)
	var effective_type: String = btype
	if _flat_paint_mode and (btype == "texture" or btype == "noise"):
		effective_type = "circle"

	var radius := float(config.size)
	var spacing: float = max(1.0, radius * 0.22)
	match effective_type:
		"texture":
			spacing = max(1.0, radius * 0.16)
		"noise":
			spacing = max(1.0, radius * 0.18)
	match _runtime_noise_complexity:
		"medium":
			spacing *= 1.8
		"low":
			spacing *= 2.4
	var dirty := Rect2i(stroke_points[0].floor(), Vector2i.ONE)

	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var seg_len := a.distance_to(b)
		var steps: int = max(1, int(ceil(seg_len / spacing)))
		for s in range(steps + 1):
			var t := float(s) / float(steps)
			var p := a.lerp(b, t)
			if effective_type == "texture" or effective_type == "noise":
				var jitter_src := Vector2(float(i) * 17.0 + float(s) * 3.1, float(i) * 9.0 - float(s) * 5.7)
				var jx: float = (_noise.get_noise_2d(jitter_src.x + 101.0, jitter_src.y - 77.0))
				var jy: float = (_noise.get_noise_2d(jitter_src.x - 211.0, jitter_src.y + 19.0))
				var jitter_amp: float = radius * (0.11 if effective_type == "texture" else lerpf(0.0, 0.18, noise_amount))
				if _runtime_noise_complexity == "medium":
					jitter_amp *= 0.82
				elif _runtime_noise_complexity == "low":
					jitter_amp *= 0.62
				p += Vector2(jx, jy) * jitter_amp
			var stamp_rect := _stamp_land(p, add_land, config, effective_type)
			dirty = dirty.merge(stamp_rect)

	_queue_land_refresh(dirty)
	return _rect_to_tiles(dirty, config.tile_size)


func apply_mountain_stroke(stroke_points: Array[Vector2], config) -> Array[Vector2i]:
	if stroke_points.is_empty():
		return []
	var points := _resample_path(stroke_points, max(4.0, config.size * 0.35))
	var size: float = float(config.size)
	var bounds: Rect2 = _stroke_bounds_from_array(points, max(2.0, size * 0.52))
	var dirs: PackedVector2Array = _build_mountain_dirs(points)
	var entry := {
		"points": points,
		"dirs": dirs,
		"size": size,
		"bounds": _bounds_dict_from_rect(bounds),
		"brush_type": config.brush_type
	}
	mountain_strokes.append(entry)
	queue_redraw()
	return _rect_to_tiles(_points_to_rect(points).grow(int(config.size)), config.tile_size)


func apply_river_stroke(stroke_points: Array[Vector2], config) -> Array[Vector2i]:
	if stroke_points.size() < 2:
		return []
	var width: float = max(2.0, float(config.size) * 0.35)
	var resample_step: float = clampf(width * 0.92, 5.0, 10.0)
	var even_points: Array[Vector2] = _resample_path(stroke_points, resample_step)
	var smooth_points := PackedVector2Array(_chaikin_with_corner_preserve(even_points, 70, 25.0))
	var simplify_dist: float = clampf(width * 0.28, 0.9, 2.2)
	var points: PackedVector2Array = _simplify_river_polyline(smooth_points, simplify_dist, 7.0)
	if points.size() < 2:
		points = smooth_points
	points = _clip_river_points_to_land(points, width, 2.0, true)
	if points.size() < 2:
		return []
	var lod: Dictionary = _build_river_lods(points)
	var bounds: Rect2 = _stroke_bounds_from_packed(points, max(2.0, width * 0.95))
	var flow_to_end: bool = _infer_flow_to_end(points)
	var entry := {
		"points": points,
		"points_lod1": lod.get("lod1", PackedVector2Array()),
		"points_lod2": lod.get("lod2", PackedVector2Array()),
		"width": width,
		"bounds": _bounds_dict_from_rect(bounds),
		"flow_to_end": flow_to_end,
		"sea_clamped": true,
		"auto_generated": false
	}
	river_strokes.append(entry)
	queue_redraw()
	return _rect_to_tiles(_points_to_rect(Array(points)).grow(int(config.size)), config.tile_size)


func bake_river_network(bake_cfg: Dictionary) -> Dictionary:
	flush_pending_updates()
	if map_size.x <= 0 or map_size.y <= 0:
		return {"ok": false, "message": "맵 크기가 유효하지 않습니다."}

	var target_resolution: int = max(128, int(bake_cfg.get("target_resolution", 768)))
	var density_pct: float = clampf(float(bake_cfg.get("source_density_pct", 12.0)), 1.0, 100.0)
	var inland_pct: float = clampf(float(bake_cfg.get("inland_pct", 42.0)), 0.0, 100.0)
	var noise_pct: float = clampf(float(bake_cfg.get("noise_pct", 28.0)), 0.0, 100.0)
	var merge_pct: float = clampf(float(bake_cfg.get("merge_pct", 62.0)), 0.0, 100.0)
	var preserve_existing: bool = bool(bake_cfg.get("preserve_existing", true))
	var delta_split: bool = bool(bake_cfg.get("delta_split", false))

	var max_dim: int = max(map_size.x, map_size.y)
	var cell_px: int = max(2, int(ceil(float(max_dim) / float(target_resolution))))
	var cols: int = int(ceil(float(map_size.x) / float(cell_px)))
	var rows: int = int(ceil(float(map_size.y) / float(cell_px)))
	var n: int = cols * rows
	if n <= 0:
		return {"ok": false, "message": "수계 베이크 그리드 생성 실패"}

	var rng := RandomNumberGenerator.new()
	rng.seed = int(Time.get_ticks_usec())

	var land := PackedByteArray()
	land.resize(n)
	land.fill(0)
	var dist := PackedInt32Array()
	dist.resize(n)
	for i in range(n):
		dist[i] = 1_000_000

	var land_count: int = 0
	for cy in range(rows):
		for cx in range(cols):
			var key: int = cy * cols + cx
			var wx: int = min(map_size.x - 1, cx * cell_px + int(cell_px * 0.5))
			var wy: int = min(map_size.y - 1, cy * cell_px + int(cell_px * 0.5))
			if _is_land_at(wx, wy):
				land[key] = 1
				land_count += 1

	if land_count <= 0:
		return {"ok": false, "message": "육지가 없어 강을 생성할 수 없습니다."}

	var queue: Array = []
	var q_head: int = 0
	for cy in range(rows):
		for cx in range(cols):
			var k: int = cy * cols + cx
			if land[k] != 1:
				continue
			if _is_grid_coast_cell(cx, cy, cols, rows, land):
				dist[k] = 0
				queue.append(k)

	while q_head < queue.size():
		var cur: int = int(queue[q_head])
		q_head += 1
		var cx: int = cur % cols
		var cy: int = int(cur / cols)
		var nd: int = dist[cur] + 1
		for d in _grid_neighbors8():
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if nx < 0 or ny < 0 or nx >= cols or ny >= rows:
				continue
			var nk: int = ny * cols + nx
			if land[nk] != 1:
				continue
			if nd < dist[nk]:
				dist[nk] = nd
				queue.append(nk)

	var max_dist: int = 0
	for i in range(n):
		if land[i] == 1 and dist[i] < 1_000_000:
			max_dist = max(max_dist, dist[i])
	if max_dist <= 2:
		return {"ok": false, "message": "내륙 깊이가 부족해 자동 수계 생성이 어렵습니다."}

	var min_source_dist: int = int(round((inland_pct / 100.0) * float(max_dist)))
	min_source_dist = clampi(min_source_dist, 2, max_dist)

	var candidates: Array = []
	for i in range(n):
		if land[i] == 1 and dist[i] >= min_source_dist and dist[i] < 1_000_000:
			candidates.append(i)
	if candidates.is_empty():
		return {"ok": false, "message": "후보 수원이 없습니다. 내륙 시작점을 낮춰보세요."}

	var preserved_manual: int = 0
	var removed_auto: int = 0
	var removed_manual: int = 0
	var removed_total: int = 0
	var base_rivers: Array = []
	if preserve_existing:
		for river_data in river_strokes:
			var river: Dictionary = river_data
			if bool(river.get("auto_generated", false)):
				removed_auto += 1
				removed_total += 1
				continue
			preserved_manual += 1
			base_rivers.append(river)
	else:
		for river_data in river_strokes:
			var river: Dictionary = river_data
			if bool(river.get("auto_generated", false)):
				removed_auto += 1
			else:
				removed_manual += 1
			removed_total += 1

	var working_rivers: Array = base_rivers.duplicate(true)

	var channel_cells: Dictionary = {}
	for river_data in working_rivers:
		var river: Dictionary = river_data
		var pts: PackedVector2Array = river.get("points", PackedVector2Array())
		for k in _rasterize_river_cells(pts, cell_px, cols, rows):
			channel_cells[k] = true

	var shuffled: Array = _shuffled_keys(candidates, rng)
	var source_count: int = int(round(float(shuffled.size()) * (density_pct / 100.0)))
	var max_sources: int = max(24, int(round(float(max(cols, rows)) * 0.5)))
	source_count = clampi(source_count, 1, min(shuffled.size(), max_sources))

	var merge_radius: int = clampi(int(round(lerpf(1.0, 6.0, merge_pct / 100.0))), 1, 6)
	var noise_amp: float = (noise_pct / 100.0) * 0.45
	var max_steps: int = max(40, int(round(float(max(cols, rows)) * 1.8)))
	var generated: int = 0

	for si in range(source_count):
		var source_key: int = int(shuffled[si])
		if channel_cells.has(source_key):
			continue
		var path_keys: Array = _trace_river_path(source_key, cols, rows, land, dist, channel_cells, merge_radius, noise_amp, max_steps, rng)
		if path_keys.size() < 4:
			continue

		var world_points := PackedVector2Array()
		for key in path_keys:
			var k: int = int(key)
			var px: int = (k % cols) * cell_px + int(cell_px * 0.5)
			var py: int = int(k / cols) * cell_px + int(cell_px * 0.5)
			world_points.append(_clamp_point(Vector2(px, py)))

		var width: float = lerpf(2.2, 6.8, clampf(float(dist[source_key]) / float(max_dist), 0.0, 1.0))
		width += rng.randf_range(-0.25, 0.25)
		width = clampf(width, 1.8, 8.0)
		var entry: Dictionary = _build_baked_river_entry(world_points, width)
		if bool(entry.get("ok", false)):
			var river_entry: Dictionary = entry.get("river", {})
			working_rivers.append(river_entry)
			for k in _rasterize_river_cells(river_entry.get("points", PackedVector2Array()), cell_px, cols, rows):
				channel_cells[k] = true
			generated += 1
			if delta_split:
				for branch in _build_delta_branches(river_entry, rng):
					working_rivers.append(branch)
					for bk in _rasterize_river_cells(branch.get("points", PackedVector2Array()), cell_px, cols, rows):
						channel_cells[bk] = true
					generated += 1

	if generated <= 0:
		return {
			"ok": false,
			"message": "생성된 강이 없습니다. 생성 밀도/내륙 시작점을 조정해보세요.",
			"generated": 0,
			"total": river_strokes.size(),
			"preserved_manual": preserved_manual,
			"removed_auto": removed_auto,
			"removed_manual": removed_manual,
			"removed_total": removed_total
		}

	river_strokes = working_rivers
	_ensure_stroke_bounds_cache()
	queue_redraw()
	return {
		"ok": true,
		"generated": generated,
		"total": river_strokes.size(),
		"preserved_manual": preserved_manual,
		"removed_auto": removed_auto,
		"removed_manual": removed_manual,
		"removed_total": removed_total,
		"message": "강 자동 생성 완료"
	}


func erase_tiles(tiles: Array[Vector2i], tile_size_px: int) -> Array[Vector2i]:
	var touched: Dictionary = {}
	var dirty := Rect2i()
	var has_dirty: bool = false
	for tile in tiles:
		var rx := tile.x * tile_size_px
		var ry := tile.y * tile_size_px
		var rect := Rect2i(rx, ry, tile_size_px, tile_size_px).intersection(Rect2i(Vector2i.ZERO, map_size))
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		land_mask.fill_rect(rect, Color(0, 0, 0, 1))
		for y in range(rect.position.y, rect.end.y):
			var row: int = y * map_size.x
			for x in range(rect.position.x, rect.end.x):
				land_bits[row + x] = 0
		if has_dirty:
			dirty = dirty.merge(rect)
		else:
			dirty = rect
			has_dirty = true
		touched[tile] = true
	if has_dirty:
		_update_display_rect(dirty.grow(1))
	_mountains_filter_by_tiles(tiles, tile_size_px)
	_rivers_filter_by_tiles(tiles, tile_size_px)
	queue_redraw()
	var out: Array[Vector2i] = []
	for t in touched.keys():
		out.append(t as Vector2i)
	return out


func get_tile_from_world(world_pos: Vector2, tile_size_px: int) -> Vector2i:
	var p := _clamp_point(world_pos)
	return Vector2i(int(p.x) / tile_size_px, int(p.y) / tile_size_px)


func is_point_on_land(world_pos: Vector2) -> bool:
	var p: Vector2 = _clamp_point(world_pos)
	return _is_land_at(int(round(p.x)), int(round(p.y)))


func polygon_land_ratio(poly: PackedVector2Array, sample_step: int = 6) -> float:
	if poly.size() < 3:
		return 0.0
	var bounds: Rect2i = _poly_bounds(poly)
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return 0.0
	var step: int = max(1, sample_step)
	var land_count: int = 0
	var all_count: int = 0
	for y in range(bounds.position.y, bounds.end.y, step):
		for x in range(bounds.position.x, bounds.end.x, step):
			var p := Vector2(x + 0.5, y + 0.5)
			if not Geometry2D.is_point_in_polygon(p, poly):
				continue
			all_count += 1
			if _is_land_at(x, y):
				land_count += 1
	if all_count <= 0:
		return 0.0
	return float(land_count) / float(all_count)


func is_point_near_coast(world_pos: Vector2, radius: int = 12) -> bool:
	var p: Vector2 = _clamp_point(world_pos)
	var cx: int = int(round(p.x))
	var cy: int = int(round(p.y))
	var min_x: int = max(0, cx - radius)
	var min_y: int = max(0, cy - radius)
	var max_x: int = min(map_size.x - 1, cx + radius)
	var max_y: int = min(map_size.y - 1, cy + radius)
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			if _is_coast_pixel(x, y):
				return true
	return false


func find_coast_path(start_world: Vector2, end_world: Vector2, margin: int = 320) -> Array[Vector2]:
	var start: Vector2 = _clamp_point(start_world)
	var finish: Vector2 = _clamp_point(end_world)
	var min_x: int = max(0, int(min(start.x, finish.x)) - margin)
	var min_y: int = max(0, int(min(start.y, finish.y)) - margin)
	var max_x: int = min(map_size.x - 1, int(max(start.x, finish.x)) + margin)
	var max_y: int = min(map_size.y - 1, int(max(start.y, finish.y)) + margin)
	var rect := Rect2i(min_x, min_y, max(1, max_x - min_x + 1), max(1, max_y - min_y + 1))
	var coast_bits: PackedByteArray = _build_coast_bitmap(rect)
	var local_start: Vector2i = _nearest_coast_local(start, rect, coast_bits, 32)
	var local_end: Vector2i = _nearest_coast_local(finish, rect, coast_bits, 32)
	if local_start.x < 0 or local_end.x < 0:
		return []
	var local_path: Array[Vector2i] = _bfs_local_coast_path(local_start, local_end, rect.size, coast_bits)
	if local_path.is_empty():
		return []
	var world_path: Array[Vector2] = []
	for lp in local_path:
		world_path.append(Vector2(lp.x + rect.position.x, lp.y + rect.position.y))
	return _thin_path(world_path, 2)


func capture_runtime_state() -> Dictionary:
	flush_pending_updates()
	return {
		"map_size": map_size,
		"tile_size": tile_size,
		"land_mask": land_mask.duplicate(),
		"mountain_strokes": mountain_strokes.duplicate(true),
		"river_strokes": river_strokes.duplicate(true)
	}


func restore_runtime_state(state: Dictionary) -> void:
	var saved_size: Vector2i = state.get("map_size", map_size)
	if saved_size != map_size:
		_init_images(saved_size)
		_build_chunk_renderers()

	tile_size = int(state.get("tile_size", tile_size))
	var mask: Image = state.get("land_mask", null)
	if mask != null:
		land_mask = mask.duplicate()
	_sync_land_bits_from_mask()

	mountain_strokes = state.get("mountain_strokes", []).duplicate(true)
	river_strokes = state.get("river_strokes", []).duplicate(true)
	_ensure_stroke_bounds_cache()
	_rebuild_display()
	queue_redraw()


func serialize_state(include_land_mask: bool = true) -> Dictionary:
	flush_pending_updates()
	var out := {
		"map_width": map_size.x,
		"map_height": map_size.y,
		"tile_size": tile_size,
		"mountain_strokes": mountain_strokes.duplicate(true),
		"river_strokes": _serialize_rivers()
	}
	if include_land_mask:
		out["land_mask_png"] = Marshalls.raw_to_base64(land_mask.save_png_to_buffer())
	return out


func deserialize_state(data: Dictionary) -> void:
	var width := int(data.get("map_width", map_size.x))
	var height := int(data.get("map_height", map_size.y))
	if width != map_size.x or height != map_size.y:
		_init_images(Vector2i(width, height))
		_build_chunk_renderers()

	tile_size = int(data.get("tile_size", tile_size))
	var encoded := str(data.get("land_mask_png", ""))
	if not encoded.is_empty():
		var raw := Marshalls.base64_to_raw(encoded)
		var img := Image.new()
		if img.load_png_from_buffer(raw) == OK:
			land_mask = img
			_sync_land_bits_from_mask()
			_rebuild_display()

	mountain_strokes = data.get("mountain_strokes", []).duplicate(true)
	river_strokes = _deserialize_rivers(data.get("river_strokes", []))
	_ensure_stroke_bounds_cache()
	queue_redraw()


func export_land_mask_chunks(chunk_size: int = 256) -> Dictionary:
	flush_pending_updates()
	var chunks := {}
	var grid_x := int(ceil(float(map_size.x) / float(chunk_size)))
	var grid_y := int(ceil(float(map_size.y) / float(chunk_size)))

	for cy in range(grid_y):
		for cx in range(grid_x):
			var src := Rect2i(cx * chunk_size, cy * chunk_size, min(chunk_size, map_size.x - cx * chunk_size), min(chunk_size, map_size.y - cy * chunk_size))
			if src.size.x <= 0 or src.size.y <= 0:
				continue
			var chunk := Image.create(src.size.x, src.size.y, false, Image.FORMAT_R8)
			chunk.blit_rect(land_mask, src, Vector2i.ZERO)
			chunks["%d_%d" % [cx, cy]] = Marshalls.raw_to_base64(chunk.save_png_to_buffer())

	return {
		"chunk_size": chunk_size,
		"map_width": map_size.x,
		"map_height": map_size.y,
		"chunks": chunks
	}


func import_land_mask_chunks(data: Dictionary) -> void:
	var chunk_size := int(data.get("chunk_size", 256))
	var width := int(data.get("map_width", map_size.x))
	var height := int(data.get("map_height", map_size.y))
	_init_images(Vector2i(width, height))
	_build_chunk_renderers()

	var chunks: Dictionary = data.get("chunks", {})
	for key in chunks.keys():
		var parts := str(key).split("_")
		if parts.size() != 2:
			continue
		var cx := int(parts[0])
		var cy := int(parts[1])
		var raw := Marshalls.base64_to_raw(str(chunks[key]))
		var chunk := Image.new()
		if chunk.load_png_from_buffer(raw) != OK:
			continue
		var dst := Vector2i(cx * chunk_size, cy * chunk_size)
		var src := Rect2i(Vector2i.ZERO, chunk.get_size())
		land_mask.blit_rect(chunk, src, dst)

	_sync_land_bits_from_mask()
	_rebuild_display()
	queue_redraw()


func _grid_neighbors4() -> Array:
	return [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


func _grid_neighbors8() -> Array:
	return [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1),
		Vector2i(1, 1),
		Vector2i(1, -1),
		Vector2i(-1, 1),
		Vector2i(-1, -1)
	]


func _is_grid_coast_cell(cx: int, cy: int, cols: int, rows: int, land: PackedByteArray) -> bool:
	var key: int = cy * cols + cx
	if land[key] != 1:
		return false
	for d in _grid_neighbors8():
		var nx: int = cx + d.x
		var ny: int = cy + d.y
		if nx < 0 or ny < 0 or nx >= cols or ny >= rows:
			return true
		if land[ny * cols + nx] != 1:
			return true
	return false


func _shuffled_keys(input_keys: Array, rng: RandomNumberGenerator) -> Array:
	var out: Array = input_keys.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out


func _trace_river_path(source_key: int, cols: int, rows: int, land: PackedByteArray, dist: PackedInt32Array, channel_cells: Dictionary, merge_radius: int, noise_amp: float, max_steps: int, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	var visited: Dictionary = {}
	var current: int = source_key
	for _step in range(max_steps):
		if visited.has(current):
			break
		visited[current] = true
		out.append(current)
		if channel_cells.has(current) and current != source_key and out.size() >= 3:
			break
		if dist[current] <= 1:
			break
		var merged_key: int = _find_near_channel_key(current, cols, rows, channel_cells, merge_radius)
		if merged_key >= 0 and merged_key != current and out.size() >= 3:
			_append_grid_line_connection(out, current, merged_key, cols, rows)
			break
		var next_key: int = _pick_next_river_cell(current, cols, rows, land, dist, noise_amp, rng)
		if next_key < 0:
			break
		current = next_key
	return out


func _pick_next_river_cell(current: int, cols: int, rows: int, land: PackedByteArray, dist: PackedInt32Array, noise_amp: float, rng: RandomNumberGenerator) -> int:
	var cx: int = current % cols
	var cy: int = int(current / cols)
	var current_dist: int = dist[current]
	var best_key: int = -1
	var best_score: float = INF
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			if ox == 0 and oy == 0:
				continue
			var nx: int = cx + ox
			var ny: int = cy + oy
			if nx < 0 or ny < 0 or nx >= cols or ny >= rows:
				continue
			var nk: int = ny * cols + nx
			if land[nk] != 1:
				continue
			if dist[nk] >= current_dist:
				continue
			var score: float = float(dist[nk])
			if noise_amp > 0.001:
				score += rng.randf_range(-noise_amp, noise_amp)
			if score < best_score:
				best_score = score
				best_key = nk
	if best_key < 0:
		return -1
	return best_key


func _append_grid_line_connection(path: Array, from_key: int, to_key: int, cols: int, rows: int) -> void:
	var fx: int = from_key % cols
	var fy: int = int(from_key / cols)
	var tx: int = to_key % cols
	var ty: int = int(to_key / cols)
	var x: int = fx
	var y: int = fy
	var dx: int = abs(tx - fx)
	var sx: int = 1 if fx < tx else -1
	var dy: int = -abs(ty - fy)
	var sy: int = 1 if fy < ty else -1
	var err: int = dx + dy

	while true:
		if x >= 0 and y >= 0 and x < cols and y < rows:
			var key: int = y * cols + x
			if path.is_empty() or int(path[path.size() - 1]) != key:
				path.append(key)
		if x == tx and y == ty:
			break
		var e2: int = err * 2
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy


func _find_near_channel_key(center_key: int, cols: int, rows: int, channel_cells: Dictionary, radius: int) -> int:
	if channel_cells.has(center_key):
		return center_key
	var cx: int = center_key % cols
	var cy: int = int(center_key / cols)
	for r in range(1, radius + 1):
		var min_x: int = max(0, cx - r)
		var min_y: int = max(0, cy - r)
		var max_x: int = min(cols - 1, cx + r)
		var max_y: int = min(rows - 1, cy + r)
		for y in range(min_y, max_y + 1):
			for x in range(min_x, max_x + 1):
				var k: int = y * cols + x
				if channel_cells.has(k):
					return k
	return -1


func _rasterize_river_cells(points: PackedVector2Array, cell_px: int, cols: int, rows: int) -> Array:
	var out: Array = []
	if points.size() < 1:
		return out
	var seen: Dictionary = {}
	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var seg_len: float = a.distance_to(b)
		var steps: int = max(1, int(ceil(seg_len / max(1.0, float(cell_px) * 0.6))))
		for s in range(steps + 1):
			var p: Vector2 = a.lerp(b, float(s) / float(steps))
			var cx: int = clampi(int(floor(p.x / float(cell_px))), 0, cols - 1)
			var cy: int = clampi(int(floor(p.y / float(cell_px))), 0, rows - 1)
			var key: int = cy * cols + cx
			if not seen.has(key):
				seen[key] = true
				out.append(key)
	if points.size() == 1:
		var p0: Vector2 = points[0]
		var cx0: int = clampi(int(floor(p0.x / float(cell_px))), 0, cols - 1)
		var cy0: int = clampi(int(floor(p0.y / float(cell_px))), 0, rows - 1)
		var k0: int = cy0 * cols + cx0
		if not seen.has(k0):
			out.append(k0)
	return out


func _build_baked_river_entry(raw_points: PackedVector2Array, width: float) -> Dictionary:
	if raw_points.size() < 2:
		return {"ok": false}
	var resample_step: float = clampf(width * 0.92, 4.0, 10.0)
	var source_points: Array[Vector2] = []
	for p in raw_points:
		source_points.append(p)
	var even_points: Array[Vector2] = _resample_path(source_points, resample_step)
	var smooth_points := PackedVector2Array(_chaikin_with_corner_preserve(even_points, 62, 25.0))
	var simplify_dist: float = clampf(width * 0.32, 0.8, 2.6)
	var points: PackedVector2Array = _simplify_river_polyline(smooth_points, simplify_dist, 7.0)
	if points.size() < 2:
		points = smooth_points
	points = _clip_river_points_to_land(points, width, 2.0, true)
	if points.size() < 2:
		return {"ok": false}
	var lod: Dictionary = _build_river_lods(points)
	var bounds: Rect2 = _stroke_bounds_from_packed(points, max(2.0, width * 0.95))
	var flow_to_end: bool = _infer_flow_to_end(points)
	return {
		"ok": true,
		"river": {
			"points": points,
			"points_lod1": lod.get("lod1", PackedVector2Array()),
			"points_lod2": lod.get("lod2", PackedVector2Array()),
			"width": width,
			"bounds": _bounds_dict_from_rect(bounds),
			"flow_to_end": flow_to_end,
			"sea_clamped": true,
			"auto_generated": true
		}
	}


func _build_delta_branches(river: Dictionary, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	var points: PackedVector2Array = river.get("points", PackedVector2Array())
	if points.size() < 4:
		return out
	if not is_point_near_coast(points[points.size() - 1], 18):
		return out
	if rng.randf() > 0.36:
		return out

	var split_origin: Vector2 = _polyline_point_at_ratio(points, 0.82)
	var mouth: Vector2 = points[points.size() - 1]
	var dir: Vector2 = (mouth - split_origin)
	if dir.length_squared() <= 0.0001:
		return out
	dir = dir.normalized()
	var normal := Vector2(-dir.y, dir.x)
	var main_width: float = float(river.get("width", 4.0))
	var branch_len: float = max(12.0, main_width * 6.0)
	for side in [-1.0, 1.0]:
		var spread: float = rng.randf_range(0.55, 1.0)
		var p0: Vector2 = split_origin
		var p1: Vector2 = _clamp_point(split_origin + dir * (branch_len * 0.65) + normal * (side * branch_len * 0.45 * spread))
		var p2: Vector2 = _clamp_point(mouth + normal * (side * branch_len * 0.75 * spread))
		var branch_points := PackedVector2Array([p0, p1, p2])
		var built: Dictionary = _build_baked_river_entry(branch_points, max(1.4, main_width * 0.56))
		if bool(built.get("ok", false)):
			out.append(built.get("river", {}))
	return out


func _polyline_point_at_ratio(points: PackedVector2Array, ratio: float) -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	if points.size() == 1:
		return points[0]
	var t: float = clampf(ratio, 0.0, 1.0)
	var total_len: float = 0.0
	for i in range(points.size() - 1):
		total_len += points[i].distance_to(points[i + 1])
	if total_len <= 0.001:
		return points[points.size() - 1]
	var target: float = total_len * t
	var acc: float = 0.0
	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var seg: float = a.distance_to(b)
		if acc + seg >= target:
			var local_t: float = (target - acc) / max(seg, 0.001)
			return a.lerp(b, local_t)
		acc += seg
	return points[points.size() - 1]


func _stamp_land(center: Vector2, add_land: bool, config, brush_type_override: String = "") -> Rect2i:
	var radius: float = max(1.0, float(config.size))
	var btype: String = brush_type_override if not brush_type_override.is_empty() else str(config.brush_type)
	var noise_amount: float = _noise_amount_from_config(config)
	var extent_mul: float = 1.0
	if btype == "texture":
		extent_mul = 1.22
	elif btype == "noise":
		extent_mul = lerpf(1.0, 1.35, noise_amount)
	var max_r: float = radius * extent_mul
	var min_x: int = max(0, int(floor(center.x - max_r)))
	var min_y: int = max(0, int(floor(center.y - max_r)))
	var max_x: int = min(map_size.x - 1, int(ceil(center.x + max_r)))
	var max_y: int = min(map_size.y - 1, int(ceil(center.y + max_r)))
	var max_r_sq: float = max_r * max_r
	var new_bit: int = 1 if add_land else 0

	for y in range(min_y, max_y + 1):
		var dy: float = float(y) - center.y
		var row: int = y * map_size.x
		for x in range(min_x, max_x + 1):
			var dx: float = float(x) - center.x
			var dist_sq: float = dx * dx + dy * dy
			if dist_sq > max_r_sq:
				continue
			if btype != "circle":
				var dist: float = sqrt(dist_sq)
				if not _brush_mask_pass(x, y, center, radius, dist, btype, noise_amount):
					continue
			var idx: int = row + x
			if land_bits[idx] == new_bit:
				continue
			land_bits[idx] = new_bit

	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


func _brush_mask_pass(x: int, y: int, center: Vector2, radius: float, dist: float, brush_type: String, noise_amount: float = 1.0) -> bool:
	var d01: float = dist / max(1.0, radius)
	var complexity: String = _runtime_noise_complexity
	match brush_type:
		"texture":
			if complexity == "low":
				return d01 <= 1.0
			if complexity == "medium":
				var medium_noise: float = _noise.get_noise_2d(float(x) * 0.42 + 33.0, float(y) * 0.42 - 21.0)
				var medium_gate: float = 0.9 + medium_noise * 0.16
				return d01 <= medium_gate
			var cell_seed: Vector2 = Vector2(floor(center.x * 0.07), floor(center.y * 0.07))
			var ang_noise: float = _noise.get_noise_2d(cell_seed.x + 41.0, cell_seed.y - 23.0)
			var angle: float = ang_noise * PI
			var lx: float = float(x) - center.x
			var ly: float = float(y) - center.y
			var rx: float = lx * cos(angle) - ly * sin(angle)
			var ry: float = lx * sin(angle) + ly * cos(angle)
			var fiber: float = _noise.get_noise_2d((rx + center.x * 0.2) * 0.18, (ry - center.y * 0.17) * 0.35)
			var pores: float = _noise.get_noise_2d(float(x) * 1.55 + 87.0, float(y) * 1.55 - 121.0)
			var fringe: float = _noise.get_noise_2d(float(x) * 0.41 - 13.0, float(y) * 0.41 + 29.0)
			if d01 < 0.58:
				return pores > -0.92
			var edge_gate: float = 0.86 + fringe * 0.26 + fiber * 0.18
			if d01 > edge_gate:
				return false
			return pores > -0.18
		"noise":
			if noise_amount <= 0.01:
				return d01 <= 1.0
			if complexity == "low":
				var low_noise: float = _noise.get_noise_2d(float(x) * 0.2 + 17.0, float(y) * 0.2 - 9.0)
				var low_allow: float = lerpf(1.0, 0.85 + low_noise * 0.24, noise_amount)
				return d01 <= low_allow
			if complexity == "medium":
				var med_macro: float = _noise.get_noise_2d(float(x) * 0.22 + 27.0, float(y) * 0.22 - 47.0)
				var med_micro: float = _noise.get_noise_2d(float(x) * 0.8 - 67.0, float(y) * 0.8 + 53.0)
				var med_allow: float = 0.8 + med_macro * 0.35 + med_micro * 0.1
				return d01 <= lerpf(1.0, med_allow, noise_amount)
			var macro: float = _noise.get_noise_2d(float(x) * 0.18 + 33.0, float(y) * 0.18 - 57.0)
			var micro: float = _noise.get_noise_2d(float(x) * 0.95 - 219.0, float(y) * 0.95 + 147.0)
			var grit: float = _noise.get_noise_2d(float(x) * 2.1 + 411.0, float(y) * 2.1 - 305.0)
			var allowed: float = 0.78 + macro * 0.42 + micro * 0.16
			var blend_allowed: float = lerpf(1.0, allowed, noise_amount)
			if d01 > blend_allowed:
				return false
			if d01 < lerpf(0.98, 0.34, noise_amount):
				return true
			return grit > lerpf(-1.0, -0.22, noise_amount)
		_:
			return true


func _noise_amount_from_config(config) -> float:
	if config == null:
		return 1.0
	var value = config.get("noise_strength")
	if value == null:
		return 1.0
	return clampf(float(value), 0.0, 1.0)


func _update_display_rect(rect: Rect2i) -> void:
	var bounds := rect.intersection(Rect2i(Vector2i.ZERO, map_size))
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return
	for y in range(bounds.position.y, bounds.end.y):
		var row: int = y * map_size.x
		for x in range(bounds.position.x, bounds.end.x):
			var is_land: bool = land_bits[row + x] == 1
			land_mask.set_pixel(x, y, Color(1.0 if is_land else 0.0, 0, 0, 1))
			var color: Color = LAND_COLOR if is_land else WATER_COLOR
			if not _flat_paint_mode:
				if _is_coast_pixel(x, y):
					color = _coast_smoothed_color(x, y, is_land)
			display_image.set_pixel(x, y, color)
	_refresh_chunks_in_rect(bounds)


func _rebuild_display() -> void:
	display_image.fill(WATER_COLOR)
	_update_display_rect(Rect2i(Vector2i.ZERO, map_size))


func _build_chunk_renderers() -> void:
	if is_instance_valid(_chunks_root):
		_chunks_root.queue_free()
	_chunks_root = Node2D.new()
	_chunks_root.z_index = -20
	_chunks_root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_chunks_root)

	_chunk_images.clear()
	_chunk_textures.clear()

	var cols: int = int(ceil(float(map_size.x) / float(_chunk_size_px)))
	var rows: int = int(ceil(float(map_size.y) / float(_chunk_size_px)))

	for cy in range(rows):
		for cx in range(cols):
			var chunk_pos := Vector2i(cx * _chunk_size_px, cy * _chunk_size_px)
			var chunk_size := Vector2i(
				min(_chunk_size_px, map_size.x - chunk_pos.x),
				min(_chunk_size_px, map_size.y - chunk_pos.y)
			)
			if chunk_size.x <= 0 or chunk_size.y <= 0:
				continue
			var key := Vector2i(cx, cy)
			var cimg := Image.create(chunk_size.x, chunk_size.y, false, Image.FORMAT_RGBA8)
			cimg.fill(WATER_COLOR)
			var ctex := ImageTexture.create_from_image(cimg)
			var spr := Sprite2D.new()
			spr.centered = false
			spr.texture = ctex
			spr.position = Vector2(float(chunk_pos.x), float(chunk_pos.y))
			_chunks_root.add_child(spr)
			_chunk_images[key] = cimg
			_chunk_textures[key] = ctex

	_refresh_chunks_in_rect(Rect2i(Vector2i.ZERO, map_size))


func _refresh_chunks_in_rect(rect: Rect2i) -> void:
	if not is_instance_valid(_chunks_root):
		return
	var bounds := rect.intersection(Rect2i(Vector2i.ZERO, map_size))
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return

	var start_cx: int = int(floor(float(bounds.position.x) / float(_chunk_size_px)))
	var start_cy: int = int(floor(float(bounds.position.y) / float(_chunk_size_px)))
	var end_cx: int = int(floor(float(bounds.end.x - 1) / float(_chunk_size_px)))
	var end_cy: int = int(floor(float(bounds.end.y - 1) / float(_chunk_size_px)))

	for cy in range(start_cy, end_cy + 1):
		for cx in range(start_cx, end_cx + 1):
			var key := Vector2i(cx, cy)
			if not _chunk_images.has(key) or not _chunk_textures.has(key):
				continue
			var chunk_pos := Vector2i(cx * _chunk_size_px, cy * _chunk_size_px)
			var cimg: Image = _chunk_images[key]
			var src_full := Rect2i(chunk_pos, cimg.get_size())
			var src := src_full.intersection(bounds)
			if src.size.x <= 0 or src.size.y <= 0:
				continue
			var dst := src.position - chunk_pos
			cimg.blit_rect(display_image, src, dst)
			var ctex: ImageTexture = _chunk_textures[key]
			ctex.update(cimg)


func _sync_land_bits_from_mask() -> void:
	land_bits.resize(map_size.x * map_size.y)
	for y in range(map_size.y):
		var row: int = y * map_size.x
		for x in range(map_size.x):
			var v: float = land_mask.get_pixel(x, y).r
			land_bits[row + x] = 1 if v >= LAND_THRESHOLD else 0


func _poly_bounds(poly: PackedVector2Array) -> Rect2i:
	if poly.size() < 1:
		return Rect2i()
	var min_x: float = INF
	var min_y: float = INF
	var max_x: float = -INF
	var max_y: float = -INF
	for p in poly:
		min_x = min(min_x, p.x)
		min_y = min(min_y, p.y)
		max_x = max(max_x, p.x)
		max_y = max(max_y, p.y)
	var x0: int = clampi(int(floor(min_x)), 0, map_size.x - 1)
	var y0: int = clampi(int(floor(min_y)), 0, map_size.y - 1)
	var x1: int = clampi(int(ceil(max_x)), 0, map_size.x - 1)
	var y1: int = clampi(int(ceil(max_y)), 0, map_size.y - 1)
	return Rect2i(x0, y0, max(1, x1 - x0 + 1), max(1, y1 - y0 + 1))


func _is_land_at(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= map_size.x or y >= map_size.y:
		return false
	var idx: int = y * map_size.x + x
	if idx < 0 or idx >= land_bits.size():
		return land_mask.get_pixel(x, y).r >= LAND_THRESHOLD
	return land_bits[idx] == 1


func _is_coast_pixel(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= map_size.x or y >= map_size.y:
		return false
	var idx: int = y * map_size.x + x
	var center_land: bool = land_bits[idx] == 1
	if x > 0 and ((land_bits[idx - 1] == 1) != center_land):
		return true
	if x < map_size.x - 1 and ((land_bits[idx + 1] == 1) != center_land):
		return true
	if y > 0 and ((land_bits[idx - map_size.x] == 1) != center_land):
		return true
	if y < map_size.y - 1 and ((land_bits[idx + map_size.x] == 1) != center_land):
		return true
	return false


func _coast_smoothed_color(x: int, y: int, is_land: bool) -> Color:
	var land_neighbors: int = _count_land_neighbors_8(x, y)
	var ratio: float = float(land_neighbors) / 8.0
	if is_land:
		var blend_land: float = clampf((1.0 - ratio) * COAST_LAND_BLEND_STRENGTH, 0.0, 1.0)
		return LAND_COLOR.lerp(COAST_COLOR, blend_land)
	var blend_water: float = clampf(ratio * COAST_WATER_BLEND_STRENGTH, 0.0, 1.0)
	return WATER_COLOR.lerp(COAST_COLOR, blend_water)


func _count_land_neighbors_8(x: int, y: int) -> int:
	var count: int = 0
	for oy in range(-1, 2):
		var sy: int = y + oy
		if sy < 0 or sy >= map_size.y:
			continue
		for ox in range(-1, 2):
			if ox == 0 and oy == 0:
				continue
			var sx: int = x + ox
			if sx < 0 or sx >= map_size.x:
				continue
			if land_bits[sy * map_size.x + sx] == 1:
				count += 1
	return count


func _build_coast_bitmap(rect: Rect2i) -> PackedByteArray:
	var bits := PackedByteArray()
	bits.resize(rect.size.x * rect.size.y)
	for ly in range(rect.size.y):
		for lx in range(rect.size.x):
			var wx: int = rect.position.x + lx
			var wy: int = rect.position.y + ly
			var idx: int = ly * rect.size.x + lx
			bits[idx] = 1 if _is_coast_pixel(wx, wy) else 0
	return bits


func _nearest_coast_local(world_p: Vector2, rect: Rect2i, coast_bits: PackedByteArray, max_radius: int) -> Vector2i:
	var local_center := Vector2i(
		clampi(int(round(world_p.x)) - rect.position.x, 0, rect.size.x - 1),
		clampi(int(round(world_p.y)) - rect.position.y, 0, rect.size.y - 1)
	)
	for r in range(max_radius + 1):
		var min_x: int = max(0, local_center.x - r)
		var min_y: int = max(0, local_center.y - r)
		var max_x: int = min(rect.size.x - 1, local_center.x + r)
		var max_y: int = min(rect.size.y - 1, local_center.y + r)
		for y in range(min_y, max_y + 1):
			for x in range(min_x, max_x + 1):
				var idx: int = y * rect.size.x + x
				if coast_bits[idx] == 1:
					return Vector2i(x, y)
	return Vector2i(-1, -1)


func _bfs_local_coast_path(start_local: Vector2i, end_local: Vector2i, size: Vector2i, coast_bits: PackedByteArray) -> Array[Vector2i]:
	var w: int = size.x
	var h: int = size.y
	var queue: Array[Vector2i] = [start_local]
	var head: int = 0
	var visited: Dictionary = {}
	var prev: Dictionary = {}
	var start_key: int = start_local.y * w + start_local.x
	var end_key: int = end_local.y * w + end_local.x
	visited[start_key] = true

	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)
	]

	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		var cur_key: int = cur.y * w + cur.x
		if cur_key == end_key:
			break
		for d in dirs:
			var nx: int = cur.x + d.x
			var ny: int = cur.y + d.y
			if nx < 0 or ny < 0 or nx >= w or ny >= h:
				continue
			var next_key: int = ny * w + nx
			if visited.has(next_key):
				continue
			if coast_bits[next_key] != 1:
				continue
			visited[next_key] = true
			prev[next_key] = cur_key
			queue.append(Vector2i(nx, ny))

	if not visited.has(end_key):
		return []

	var rev: Array[Vector2i] = []
	var k: int = end_key
	while true:
		var px: int = k % w
		var py: int = int(k / w)
		rev.append(Vector2i(px, py))
		if k == start_key:
			break
		k = int(prev.get(k, start_key))

	rev.reverse()
	return rev


func _thin_path(path: Array[Vector2], step: int) -> Array[Vector2]:
	if path.size() <= 2:
		return path
	var out: Array[Vector2] = [path[0]]
	for i in range(1, path.size() - 1):
		if i % step == 0:
			out.append(path[i])
	out.append(path[path.size() - 1])
	return out


func _clamp_point(p: Vector2) -> Vector2:
	return Vector2(clampf(p.x, 0.0, float(map_size.x - 1)), clampf(p.y, 0.0, float(map_size.y - 1)))


func _points_to_rect(points: Array) -> Rect2i:
	if points.is_empty():
		return Rect2i()
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for p in points:
		var v: Vector2 = p
		min_x = min(min_x, v.x)
		min_y = min(min_y, v.y)
		max_x = max(max_x, v.x)
		max_y = max(max_y, v.y)
	return Rect2i(int(floor(min_x)), int(floor(min_y)), int(ceil(max_x - min_x)) + 1, int(ceil(max_y - min_y)) + 1)


func _rect_to_tiles(rect: Rect2i, tile_size_px: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if rect.size.x <= 0 or rect.size.y <= 0:
		return out
	var start_x := int(floor(float(rect.position.x) / float(tile_size_px)))
	var start_y := int(floor(float(rect.position.y) / float(tile_size_px)))
	var end_x := int(floor(float(rect.end.x - 1) / float(tile_size_px)))
	var end_y := int(floor(float(rect.end.y - 1) / float(tile_size_px)))
	for ty in range(start_y, end_y + 1):
		for tx in range(start_x, end_x + 1):
			out.append(Vector2i(tx, ty))
	return out


func _resample_path(points: Array[Vector2], step: float) -> Array[Vector2]:
	if points.size() <= 1:
		return points.duplicate()
	var out: Array[Vector2] = [points[0]]
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var seg := a.distance_to(b)
		var count: int = max(1, int(ceil(seg / step)))
		for s in range(1, count + 1):
			out.append(a.lerp(b, float(s) / float(count)))
	return out


func _simplify_river_polyline(points: PackedVector2Array, min_dist: float, min_turn_deg: float = 7.0) -> PackedVector2Array:
	if points.size() <= 2:
		return points

	var out := PackedVector2Array()
	out.append(points[0])
	var min_step: float = maxf(0.25, min_dist)

	for i in range(1, points.size() - 1):
		var prev_kept: Vector2 = out[out.size() - 1]
		var curr: Vector2 = points[i]
		var nxt: Vector2 = points[i + 1]

		if prev_kept.distance_to(curr) < min_step:
			continue

		var v1: Vector2 = curr - prev_kept
		var v2: Vector2 = nxt - curr
		if v1.length_squared() > 0.0001 and v2.length_squared() > 0.0001:
			var d: float = clampf(v1.normalized().dot(v2.normalized()), -1.0, 1.0)
			var turn_deg: float = rad_to_deg(acos(d))
			if turn_deg < min_turn_deg and curr.distance_to(nxt) < (min_step * 1.4):
				continue

		out.append(curr)

	if out[out.size() - 1].distance_to(points[points.size() - 1]) > 0.01:
		out.append(points[points.size() - 1])
	return out


func _chaikin_with_corner_preserve(points: Array[Vector2], strength: int, corner_threshold_deg: float) -> Array[Vector2]:
	if points.size() < 3:
		return points.duplicate()
	var iterations := int(round((float(strength) / 100.0) * 3.0))
	iterations = clampi(iterations, 0, 3)
	if iterations == 0:
		return points.duplicate()

	var preserve: Dictionary = {}
	for i in range(1, points.size() - 1):
		var v1 := (points[i - 1] - points[i]).normalized()
		var v2 := (points[i + 1] - points[i]).normalized()
		var angle := rad_to_deg(acos(clampf(v1.dot(v2), -1.0, 1.0)))
		if angle <= corner_threshold_deg:
			preserve[i] = true

	var current := points.duplicate()
	for _iter in range(iterations):
		var next: Array[Vector2] = [current[0]]
		for i in range(current.size() - 1):
			var p0: Vector2 = current[i]
			var p1: Vector2 = current[i + 1]
			if preserve.has(i) or preserve.has(i + 1):
				next.append(p1)
				continue
			var q: Vector2 = p0.lerp(p1, 0.25)
			var r: Vector2 = p0.lerp(p1, 0.75)
			next.append(q)
			next.append(r)
		current = next

	return current


func _update_overlay_detail_state(delta: float) -> void:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		if not _overlay_detail_enabled:
			_overlay_detail_enabled = true
			queue_redraw()
		_last_cam_for_detail = Vector2(INF, INF)
		_last_zoom_for_detail = INF
		_overlay_detail_tick = 0.0
		return

	var cam_pos: Vector2 = cam.global_position
	var cam_zoom: float = maxf(cam.zoom.x, cam.zoom.y)
	if _last_cam_for_detail.x == INF or _last_zoom_for_detail == INF:
		_last_cam_for_detail = cam_pos
		_last_zoom_for_detail = cam_zoom
		return

	var moved_px: float = cam_pos.distance_to(_last_cam_for_detail)
	var zoom_delta: float = absf(cam_zoom - _last_zoom_for_detail)
	var camera_changed: bool = moved_px >= CULL_REDRAW_MOVE_EPS or zoom_delta >= CULL_REDRAW_ZOOM_EPS
	if camera_changed:
		queue_redraw()

	var under_motion: bool = moved_px >= DETAIL_MOVE_THRESHOLD or zoom_delta >= 0.06
	if under_motion:
		_overlay_detail_tick = 0.0
		if _overlay_detail_enabled:
			_overlay_detail_enabled = false
			queue_redraw()
	else:
		_overlay_detail_tick += maxf(0.0, delta)
		if not _overlay_detail_enabled and _overlay_detail_tick >= DETAIL_RECHECK_SEC:
			_overlay_detail_enabled = true
			queue_redraw()

	_last_cam_for_detail = cam_pos
	_last_zoom_for_detail = cam_zoom


func _build_mountain_dirs(points: Array[Vector2]) -> PackedVector2Array:
	var out := PackedVector2Array()
	if points.size() < 2:
		return out
	for i in range(points.size()):
		var prev: Vector2 = points[max(i - 1, 0)]
		var nxt: Vector2 = points[min(i + 1, points.size() - 1)]
		var dir: Vector2 = nxt - prev
		if dir.length_squared() <= 0.0001:
			dir = Vector2.RIGHT
		else:
			dir = dir.normalized()
		out.append(dir)
	return out


func _mountain_dirs_from_stroke(stroke: Dictionary, points: Array) -> PackedVector2Array:
	var cached: PackedVector2Array = stroke.get("dirs", PackedVector2Array())
	if cached.size() == points.size() and cached.size() > 0:
		return cached
	var dirs: PackedVector2Array = _build_mountain_dirs(points)
	stroke["dirs"] = dirs
	return dirs


func _build_river_lods(points: PackedVector2Array) -> Dictionary:
	return {
		"lod1": _decimate_packed(points, 2),
		"lod2": _decimate_packed(points, 4)
	}


func _ensure_river_lod_cache(river: Dictionary, base_points: PackedVector2Array) -> void:
	if base_points.size() < 2:
		river["points_lod1"] = PackedVector2Array()
		river["points_lod2"] = PackedVector2Array()
		return
	var lod1: PackedVector2Array = river.get("points_lod1", PackedVector2Array())
	var lod2: PackedVector2Array = river.get("points_lod2", PackedVector2Array())
	if lod1.size() >= 2 and lod2.size() >= 2:
		return
	var lod: Dictionary = _build_river_lods(base_points)
	if lod1.size() < 2:
		river["points_lod1"] = lod.get("lod1", PackedVector2Array())
	if lod2.size() < 2:
		river["points_lod2"] = lod.get("lod2", PackedVector2Array())


func _river_points_for_draw(river: Dictionary, zoom_lod: float) -> PackedVector2Array:
	var base_points: PackedVector2Array = river.get("points", PackedVector2Array())
	if base_points.size() < 2:
		return base_points
	_ensure_river_lod_cache(river, base_points)
	var lod1: PackedVector2Array = river.get("points_lod1", PackedVector2Array())
	var lod2: PackedVector2Array = river.get("points_lod2", PackedVector2Array())
	if not _overlay_detail_enabled:
		return lod2 if lod2.size() >= 2 else base_points
	if _runtime_river_detail:
		if zoom_lod < 1.15:
			return base_points
		if zoom_lod < 2.2:
			return lod1 if lod1.size() >= 2 else base_points
		return lod2 if lod2.size() >= 2 else base_points
	if zoom_lod < 1.6:
		return lod1 if lod1.size() >= 2 else base_points
	return lod2 if lod2.size() >= 2 else base_points


func _decimate_packed(points: PackedVector2Array, step: int) -> PackedVector2Array:
	if points.size() <= 2:
		return points
	var real_step: int = max(step, 1)
	var out := PackedVector2Array()
	out.append(points[0])
	for i in range(real_step, points.size() - 1, real_step):
		out.append(points[i])
	out.append(points[points.size() - 1])
	return out


func _packed_points_to_dicts(points: PackedVector2Array) -> Array:
	var out: Array = []
	for p in points:
		out.append({"x": p.x, "y": p.y})
	return out


func _dict_points_to_packed(input: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in input:
		out.append(Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0))))
	return out


func _draw_river_stylized(points: PackedVector2Array, base_width: float, width_scale: float, flow_to_end: bool, draw_inner: bool, zoom_lod: float, bank_color: Color, core_color: Color) -> void:
	if points.size() < 2:
		return

	var oriented: PackedVector2Array = points
	if not flow_to_end:
		oriented = _reverse_packed(points)

	var seg_count: int = oriented.size() - 1
	if seg_count < 1:
		return

	var start_w: float = max(0.8, base_width * width_scale * 0.56)
	var end_w: float = max(start_w + 0.4, base_width * width_scale * 1.34)

	for i in range(seg_count):
		var a: Vector2 = oriented[i]
		var b: Vector2 = oriented[i + 1]
		var t: float = (float(i) + 0.5) / float(seg_count)
		var w: float = lerpf(start_w, end_w, pow(t, 0.9))
		if draw_inner:
			if zoom_lod < 1.7:
				draw_line(a, b, bank_color, w * 1.28, true)
		draw_line(a, b, RIVER_COLOR, w, true)
		if draw_inner:
			draw_line(a, b, core_color, max(1.0, w * 0.42), true)

	var mouth: Vector2 = oriented[oriented.size() - 1]
	var mouth_radius: int = max(6, int(round(end_w * 1.2)))
	if is_point_near_coast(mouth, mouth_radius):
		draw_circle(mouth, end_w * 0.64, Color(bank_color.r, bank_color.g, bank_color.b, 0.24))
		if draw_inner:
			draw_circle(mouth, max(1.0, end_w * 0.32), Color(core_color.r, core_color.g, core_color.b, 0.35))


func _reverse_packed(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(points.size() - 1, -1, -1):
		out.append(points[i])
	return out


func _infer_flow_to_end(points: PackedVector2Array) -> bool:
	if points.size() < 2:
		return true
	var start: Vector2 = _clamp_point(points[0])
	var finish: Vector2 = _clamp_point(points[points.size() - 1])
	var start_score: int = _coast_proximity_score(start)
	var end_score: int = _coast_proximity_score(finish)
	if end_score > start_score:
		return true
	if start_score > end_score:
		return false
	return true


func _coast_proximity_score(p: Vector2) -> int:
	var score: int = 0
	if is_point_near_coast(p, 10):
		score += 4
	if is_point_near_coast(p, 24):
		score += 3
	if is_point_near_coast(p, 48):
		score += 2
	if is_point_near_coast(p, 84):
		score += 1
	return score


func _clip_river_points_to_land(points: PackedVector2Array, width: float, sample_step: float = 2.0, use_coast_hint: bool = false) -> PackedVector2Array:
	var out := PackedVector2Array()
	if points.size() < 2:
		return out

	var first: Vector2 = _clamp_point(points[0])
	if not _point_on_land_fast(first):
		return out
	out = _append_unique_packed_point(out, first)

	var pullback_px: float = max(1.0, width * 0.5)
	var step_px: float = maxf(1.0, sample_step)

	for i in range(points.size() - 1):
		var a: Vector2 = _clamp_point(points[i])
		var b: Vector2 = _clamp_point(points[i + 1])
		var seg_len: float = a.distance_to(b)
		if seg_len <= 0.001:
			continue

		var steps: int = max(1, int(ceil(seg_len / step_px)))
		var prev_t: float = 0.0
		var prev_land: bool = _point_on_land_fast(a)

		if not prev_land:
			break

		for s in range(1, steps + 1):
			var t: float = float(s) / float(steps)
			var p: Vector2 = a.lerp(b, t)
			var on_land: bool = _point_on_land_fast(p)
			if prev_land and not on_land:
				var coast_t: float = _refine_land_to_sea_transition_t(a, b, prev_t, t)
				var end_t: float = _pullback_land_t(a, b, coast_t, pullback_px)
				if use_coast_hint:
					end_t = _coast_hint_adjust_t(a, b, end_t, coast_t, max(2, int(round(pullback_px))))
				out = _append_unique_packed_point(out, _clamp_point(a.lerp(b, end_t)))
				return out
			prev_t = t
			prev_land = on_land

		if _point_on_land_fast(b):
			out = _append_unique_packed_point(out, b)
		else:
			var coast_t_full: float = _refine_land_to_sea_transition_t(a, b, 0.0, 1.0)
			var end_t_full: float = _pullback_land_t(a, b, coast_t_full, pullback_px)
			if use_coast_hint:
				end_t_full = _coast_hint_adjust_t(a, b, end_t_full, coast_t_full, max(2, int(round(pullback_px))))
			out = _append_unique_packed_point(out, _clamp_point(a.lerp(b, end_t_full)))
			return out

	return out


func _point_on_land_fast(p: Vector2) -> bool:
	var cx: int = clampi(int(round(p.x)), 0, map_size.x - 1)
	var cy: int = clampi(int(round(p.y)), 0, map_size.y - 1)
	return _is_land_at(cx, cy)


func _append_unique_packed_point(points: PackedVector2Array, p: Vector2, min_dist: float = 0.2) -> PackedVector2Array:
	if points.is_empty() or points[points.size() - 1].distance_to(p) > min_dist:
		points.append(p)
	return points


func _refine_land_to_sea_transition_t(a: Vector2, b: Vector2, land_t: float, sea_t: float) -> float:
	var left: float = clampf(land_t, 0.0, 1.0)
	var right: float = clampf(sea_t, 0.0, 1.0)
	if right < left:
		var tmp: float = left
		left = right
		right = tmp
	for _iter in range(12):
		var mid: float = (left + right) * 0.5
		if _point_on_land_fast(a.lerp(b, mid)):
			left = mid
		else:
			right = mid
	return left


func _pullback_land_t(a: Vector2, b: Vector2, coast_t: float, pullback_px: float) -> float:
	var seg_len: float = a.distance_to(b)
	if seg_len <= 0.001:
		return clampf(coast_t, 0.0, 1.0)
	var t: float = clampf(coast_t - (pullback_px / seg_len), 0.0, 1.0)
	var step_t: float = clampf(1.0 / seg_len, 0.002, 0.12)
	for _iter in range(24):
		if _point_on_land_fast(a.lerp(b, t)):
			break
		t = max(0.0, t - step_t)
	return t


func _coast_hint_adjust_t(a: Vector2, b: Vector2, base_t: float, coast_t: float, coast_radius: int) -> float:
	var clamped_base: float = clampf(base_t, 0.0, 1.0)
	var best_t: float = clamped_base
	var best_pt: Vector2 = _clamp_point(a.lerp(b, clamped_base))
	if is_point_near_coast(best_pt, coast_radius):
		return clamped_base

	for i in range(1, 9):
		var probe_t: float = lerpf(clamped_base, clampf(coast_t, 0.0, 1.0), float(i) / 8.0)
		var probe_pt: Vector2 = _clamp_point(a.lerp(b, probe_t))
		if _point_on_land_fast(probe_pt):
			best_t = probe_t
			best_pt = probe_pt
		if _point_on_land_fast(probe_pt) and is_point_near_coast(probe_pt, coast_radius):
			return probe_t

	if _point_on_land_fast(best_pt):
		return best_t
	return clamped_base


func _mountains_filter_by_tiles(tiles: Array[Vector2i], tile_size_px: int) -> void:
	var tile_set: Dictionary = {}
	for t in tiles:
		tile_set[t] = true
	var keep: Array = []
	for stroke in mountain_strokes:
		var points: Array = stroke.get("points", [])
		var covered := false
		for p in points:
			var t := Vector2i(int((p as Vector2).x) / tile_size_px, int((p as Vector2).y) / tile_size_px)
			if tile_set.has(t):
				covered = true
				break
		if not covered:
			keep.append(stroke)
	mountain_strokes = keep


func _rivers_filter_by_tiles(tiles: Array[Vector2i], tile_size_px: int) -> void:
	var tile_set: Dictionary = {}
	for t in tiles:
		tile_set[t] = true
	var keep: Array = []
	for river in river_strokes:
		var points: PackedVector2Array = river.get("points", PackedVector2Array())
		var covered := false
		for p in points:
			var t := Vector2i(int(p.x) / tile_size_px, int(p.y) / tile_size_px)
			if tile_set.has(t):
				covered = true
				break
		if not covered:
			keep.append(river)
	river_strokes = keep


func _serialize_rivers() -> Array:
	var out: Array = []
	for river in river_strokes:
		var points: PackedVector2Array = river.get("points", PackedVector2Array())
		var point_dicts: Array = _packed_points_to_dicts(points)
		var lod1_dicts: Array = _packed_points_to_dicts(river.get("points_lod1", PackedVector2Array()))
		var lod2_dicts: Array = _packed_points_to_dicts(river.get("points_lod2", PackedVector2Array()))
		var bounds_dict: Dictionary = river.get("bounds", {})
		out.append({
			"points": point_dicts,
			"points_lod1": lod1_dicts,
			"points_lod2": lod2_dicts,
			"width": river.get("width", 6.0),
			"bounds": bounds_dict,
			"flow_to_end": bool(river.get("flow_to_end", true)),
			"sea_clamped": bool(river.get("sea_clamped", false)),
			"auto_generated": bool(river.get("auto_generated", false))
		})
	return out


func _deserialize_rivers(input: Array) -> Array:
	var out: Array = []
	for river in input:
		var points: PackedVector2Array = _dict_points_to_packed(river.get("points", []))
		var lod1: PackedVector2Array = _dict_points_to_packed(river.get("points_lod1", []))
		var lod2: PackedVector2Array = _dict_points_to_packed(river.get("points_lod2", []))
		out.append({
			"points": points,
			"points_lod1": lod1,
			"points_lod2": lod2,
			"width": float(river.get("width", 6.0)),
			"bounds": river.get("bounds", {}),
			"flow_to_end": bool(river.get("flow_to_end", true)),
			"sea_clamped": bool(river.get("sea_clamped", false)),
			"auto_generated": bool(river.get("auto_generated", false))
		})
	return out


func _ensure_stroke_bounds_cache() -> void:
	for i in range(mountain_strokes.size()):
		var stroke: Dictionary = mountain_strokes[i]
		var points: Array = stroke.get("points", [])
		if points.is_empty():
			continue
		var size: float = float(stroke.get("size", 18.0))
		_mountain_dirs_from_stroke(stroke, points)
		_mountain_bounds(stroke, points, size)
		mountain_strokes[i] = stroke

	for i in range(river_strokes.size()):
		var river: Dictionary = river_strokes[i]
		var points: PackedVector2Array = river.get("points", PackedVector2Array())
		if points.size() < 2:
			continue
		if not river.has("auto_generated"):
			river["auto_generated"] = false
		if not river.has("flow_to_end"):
			river["flow_to_end"] = _infer_flow_to_end(points)
		if not bool(river.get("sea_clamped", false)):
			var width_for_clip: float = float(river.get("width", 6.0))
			var clipped: PackedVector2Array = _clip_river_points_to_land(points, width_for_clip, 2.5, true)
			if clipped.size() >= 2:
				river["points"] = clipped
				var lod_from_clip: Dictionary = _build_river_lods(clipped)
				river["points_lod1"] = lod_from_clip.get("lod1", PackedVector2Array())
				river["points_lod2"] = lod_from_clip.get("lod2", PackedVector2Array())
				river["flow_to_end"] = _infer_flow_to_end(clipped)
				river["sea_clamped"] = true
				points = clipped
			else:
				river["points"] = PackedVector2Array()
				river["points_lod1"] = PackedVector2Array()
				river["points_lod2"] = PackedVector2Array()
				river["sea_clamped"] = true
				river_strokes[i] = river
				continue
		_ensure_river_lod_cache(river, points)
		var width: float = float(river.get("width", 6.0))
		_river_bounds(river, points, width)
		river_strokes[i] = river


func _camera_world_rect(cam: Camera2D) -> Rect2:
	if cam == null:
		return Rect2(Vector2.ZERO, Vector2(map_size.x, map_size.y))
	var vp_size: Vector2 = get_viewport_rect().size
	var world_size: Vector2 = vp_size * cam.zoom
	var top_left: Vector2 = cam.global_position - world_size * 0.5
	return Rect2(top_left, world_size).grow(96.0)


func _stroke_bounds_from_array(points: Array, pad: float = 0.0) -> Rect2:
	if points.is_empty():
		return Rect2()
	var min_x: float = INF
	var min_y: float = INF
	var max_x: float = -INF
	var max_y: float = -INF
	for p_data in points:
		var p: Vector2 = p_data
		min_x = minf(min_x, p.x)
		min_y = minf(min_y, p.y)
		max_x = maxf(max_x, p.x)
		max_y = maxf(max_y, p.y)
	return Rect2(
		Vector2(min_x - pad, min_y - pad),
		Vector2(max(1.0, max_x - min_x + pad * 2.0), max(1.0, max_y - min_y + pad * 2.0))
	)


func _stroke_bounds_from_packed(points: PackedVector2Array, pad: float = 0.0) -> Rect2:
	if points.size() < 1:
		return Rect2()
	var min_x: float = INF
	var min_y: float = INF
	var max_x: float = -INF
	var max_y: float = -INF
	for p in points:
		min_x = minf(min_x, p.x)
		min_y = minf(min_y, p.y)
		max_x = maxf(max_x, p.x)
		max_y = maxf(max_y, p.y)
	return Rect2(
		Vector2(min_x - pad, min_y - pad),
		Vector2(max(1.0, max_x - min_x + pad * 2.0), max(1.0, max_y - min_y + pad * 2.0))
	)


func _bounds_dict_from_rect(rect: Rect2) -> Dictionary:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return {}
	return {
		"x": rect.position.x,
		"y": rect.position.y,
		"w": rect.size.x,
		"h": rect.size.y
	}


func _bounds_rect_from_dict(value, fallback: Rect2 = Rect2()) -> Rect2:
	if typeof(value) != TYPE_DICTIONARY:
		return fallback
	var data: Dictionary = value
	var w: float = float(data.get("w", 0.0))
	var h: float = float(data.get("h", 0.0))
	if w <= 0.0 or h <= 0.0:
		return fallback
	return Rect2(Vector2(float(data.get("x", 0.0)), float(data.get("y", 0.0))), Vector2(w, h))


func _mountain_bounds(stroke: Dictionary, points: Array, size: float) -> Rect2:
	var cached: Rect2 = _bounds_rect_from_dict(stroke.get("bounds", {}))
	if cached.size.x > 0.0 and cached.size.y > 0.0:
		return cached
	var computed: Rect2 = _stroke_bounds_from_array(points, max(2.0, size * 0.52))
	if computed.size.x > 0.0 and computed.size.y > 0.0:
		stroke["bounds"] = _bounds_dict_from_rect(computed)
	return computed


func _river_bounds(river: Dictionary, points: PackedVector2Array, width: float) -> Rect2:
	var cached: Rect2 = _bounds_rect_from_dict(river.get("bounds", {}))
	if cached.size.x > 0.0 and cached.size.y > 0.0:
		return cached
	var computed: Rect2 = _stroke_bounds_from_packed(points, max(2.0, width * 0.95))
	if computed.size.x > 0.0 and computed.size.y > 0.0:
		river["bounds"] = _bounds_dict_from_rect(computed)
	return computed


func _estimate_active_chunks(cam: Camera2D) -> int:
	if cam == null:
		return _chunk_images.size()
	var vp_size: Vector2 = get_viewport_rect().size
	var world_size: Vector2 = vp_size * cam.zoom
	var min_x: int = clampi(int(floor(cam.global_position.x - world_size.x * 0.5)), 0, map_size.x - 1)
	var min_y: int = clampi(int(floor(cam.global_position.y - world_size.y * 0.5)), 0, map_size.y - 1)
	var max_x: int = clampi(int(ceil(cam.global_position.x + world_size.x * 0.5)), 0, map_size.x - 1)
	var max_y: int = clampi(int(ceil(cam.global_position.y + world_size.y * 0.5)), 0, map_size.y - 1)
	if max_x < min_x or max_y < min_y:
		return 0
	var start_cx: int = int(floor(float(min_x) / float(_chunk_size_px)))
	var start_cy: int = int(floor(float(min_y) / float(_chunk_size_px)))
	var end_cx: int = int(floor(float(max_x) / float(_chunk_size_px)))
	var end_cy: int = int(floor(float(max_y) / float(_chunk_size_px)))
	var cols: int = max(0, end_cx - start_cx + 1)
	var rows: int = max(0, end_cy - start_cy + 1)
	return cols * rows


func _queue_land_refresh(rect: Rect2i) -> void:
	var bounds := rect.intersection(Rect2i(Vector2i.ZERO, map_size))
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return
	if _has_pending_land_dirty:
		_pending_land_dirty = _pending_land_dirty.merge(bounds)
	else:
		_pending_land_dirty = bounds
		_has_pending_land_dirty = true


func flush_pending_updates() -> void:
	if not _has_pending_land_dirty:
		return
	var dirty: Rect2i = _pending_land_dirty
	_pending_land_dirty = Rect2i()
	_has_pending_land_dirty = false
	_update_display_rect(dirty.grow(2))
	queue_redraw()
