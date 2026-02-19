extends Node2D

const TerrainLayerClass = preload("res://scripts/systems/terrain_layer.gd")
const PoliticalLayerClass = preload("res://scripts/systems/political_layer.gd")
const ProjectIOClass = preload("res://scripts/systems/project_io.gd")
const AsyncProjectSaverClass = preload("res://scripts/systems/async_project_saver.gd")
const TerrainToolConfigClass = preload("res://scripts/models/terrain_tool_config.gd")
const TerrainEditCommandClass = preload("res://scripts/models/terrain_edit_command.gd")
const CommandStackClass = preload("res://scripts/systems/command_stack.gd")

const TOOL_IDS := [
	"paint_land",
	"erase_land",
	"paint_mountain",
	"paint_river",
	"erase_tile",
	"draw_country",
	"draw_region",
	"select_country"
]

const TOOL_LABELS := [
	"땅 그리기",
	"땅 지우기",
	"산 그리기",
	"강 그리기",
	"타일 지우기",
	"국가 칠하기",
	"지역 경계선 그리기",
	"국가 선택"
]
const REGION_TOOL_ENABLED := true

const PROJECT_PATH := "user://fantasy_map_project.json"
const MAX_SNAPSHOTS := 24
const COUNTRY_CELL_SIZE := 4
const COUNTRY_CONFIRM_TIMEOUT_SEC := 1.2
var current_project_path: String = PROJECT_PATH
var save_dialog: FileDialog
var open_dialog: FileDialog
var export_dialog: FileDialog
var autosave_timer: Timer
var autosave_toggle: CheckBox
var recent_store_path: String = "user://recent.json"
var export_scale: float = 1.0
var export_transparent: bool = true
var export_include_terrain: bool = true
var export_include_political: bool = true

var terrain
var political
var project_io
var tool_config
var command_stack

var camera: Camera2D
var ui_panel: PanelContainer
var status_label: Label
var country_select: OptionButton
var country_name_edit: LineEdit
var country_color_picker: ColorPickerButton
var country_name_dialog: AcceptDialog
var country_name_dialog_input: LineEdit
var pending_country_id_for_naming: String = ""
var country_info_panel: PanelContainer
var country_info_label: Label
var country_rename_button: Button
var country_create_button: Button
var country_confirm_bar: PanelContainer
var country_confirm_label: Label
var country_confirm_ok_button: Button
var country_confirm_cancel_button: Button
var pending_country_timer: Timer
var tool_select: OptionButton
var brush_select: OptionButton
var size_slider: HSlider
var size_percent_label: Label
var noise_strength_slider: HSlider
var noise_strength_percent_label: Label
var noise_strength_row: Control
var tile_drag_toggle: CheckBox
var perf_mode_toggle: CheckBox
var quality_preset_select: OptionButton
var paint_like_toggle: CheckBox
var perf_hud_label: Label
var river_bake_density_slider: HSlider
var river_bake_density_percent_label: Label
var river_bake_inland_slider: HSlider
var river_bake_inland_percent_label: Label
var river_bake_noise_slider: HSlider
var river_bake_noise_percent_label: Label
var river_bake_merge_slider: HSlider
var river_bake_merge_percent_label: Label
var river_bake_delta_toggle: CheckBox
var river_bake_preserve_toggle: CheckBox
var river_bake_button: Button

var active_tool: String = "paint_land"
var stroke_points: Array[Vector2] = []
var painting: bool = false
var is_brush_dragging: bool = false
var tile_dragging: bool = false
var tile_drag_set: Dictionary = {}
var hovered_tile: Vector2i = Vector2i(-9999, -9999)
var is_panning: bool = false
var live_land_before_snapshot: int = -1
var live_land_touched_tiles: Dictionary = {}
var live_country_before_snapshot: int = -1
var live_country_changed: bool = false
var live_country_arm_before: bool = false
var new_country_arm: bool = false
var _last_runtime_profile_key: String = ""
var pending_country_confirm: bool = false
var pending_country_before_snapshot: int = -1
var pending_country_stroke_points: Array[Vector2] = []
var pending_country_arm_before: bool = false

var snapshot_seq: int = 0
var snapshots: Dictionary = {}
var snapshot_order: Array[int] = []
var async_saver
var save_inflight: bool = false
var save_requested_revision: int = 0
var last_saved_revision: int = 0
var content_revision: int = 0
var performance_mode_enabled: bool = false
var quality_preset: String = "balanced"
var paint_like_mode_enabled: bool = false
var save_status_text: String = "Idle"
var save_error_code: int = OK


func _ready() -> void:
	terrain = TerrainLayerClass.new()
	terrain.map_size = _default_canvas_size_from_project()
	political = PoliticalLayerClass.new()
	project_io = ProjectIOClass.new()
	async_saver = AsyncProjectSaverClass.new()
	tool_config = TerrainToolConfigClass.new()
	command_stack = CommandStackClass.new()

	add_child(terrain)
	add_child(political)
	political.configure_map(terrain.map_size, COUNTRY_CELL_SIZE)

	camera = Camera2D.new()
	camera.position = Vector2(terrain.map_size.x * 0.5, terrain.map_size.y * 0.5)
	camera.zoom = Vector2.ONE
	camera.enabled = true
	add_child(camera)

	_build_ui()
	_apply_runtime_profile()
	_refresh_country_dropdown()
	_capture_snapshot()
	content_revision = 1
	last_saved_revision = 1
	save_requested_revision = 1
	save_status_text = "OK"
	_set_status("준비 완료. 좌클릭 편집, 휠 확대/축소, 우클릭 드래그 이동")
	set_process_unhandled_input(true)
	set_process(true)


func _default_canvas_size_from_project() -> Vector2i:
	var vw: int = int(ProjectSettings.get_setting("display/window/size/viewport_width", 1920))
	var vh: int = int(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	vw = max(640, vw)
	vh = max(360, vh)
	return Vector2i(vw, vh)


func _draw() -> void:
	if active_tool == "erase_tile":
		var rect := Rect2(
			Vector2(hovered_tile.x * tool_config.tile_size, hovered_tile.y * tool_config.tile_size),
			Vector2(tool_config.tile_size, tool_config.tile_size)
		)
		draw_rect(rect, Color(1, 0.4, 0.2, 0.22), true)
		draw_rect(rect, Color(1, 0.7, 0.5, 0.9), false, 2.0)
		for tile_key in tile_drag_set.keys():
			var tile: Vector2i = tile_key as Vector2i
			var sel_rect := Rect2(
				Vector2(tile.x * tool_config.tile_size, tile.y * tool_config.tile_size),
				Vector2(tool_config.tile_size, tool_config.tile_size)
			)
			draw_rect(sel_rect, Color(1, 0.2, 0.2, 0.28), true)


func _process(_delta: float) -> void:
	_poll_async_save_result()
	_apply_runtime_profile()
	_update_perf_hud()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if async_saver != null:
			async_saver.shutdown()

func _unhandled_input(event: InputEvent) -> void:
	if _handle_camera_input(event):
		return

	if event is InputEventMouseButton:
		var wheel_event: InputEventMouseButton = event
		if wheel_event.button_index == MOUSE_BUTTON_WHEEL_UP and wheel_event.pressed:
			camera.zoom *= Vector2(0.9, 0.9)
			camera.zoom.x = clampf(camera.zoom.x, 0.2, 6.0)
			camera.zoom.y = clampf(camera.zoom.y, 0.2, 6.0)
			_apply_runtime_profile()
			return
		if wheel_event.button_index == MOUSE_BUTTON_WHEEL_DOWN and wheel_event.pressed:
			camera.zoom *= Vector2(1.1, 1.1)
			camera.zoom.x = clampf(camera.zoom.x, 0.2, 6.0)
			camera.zoom.y = clampf(camera.zoom.y, 0.2, 6.0)
			_apply_runtime_profile()
			return

	if pending_country_confirm:
		if event is InputEventKey and event.pressed and not event.echo:
			var pending_key: InputEventKey = event
			if pending_key.keycode == KEY_ENTER or pending_key.keycode == KEY_KP_ENTER:
				_confirm_pending_country_stroke()
				return
			if pending_key.keycode == KEY_ESCAPE:
				_cancel_pending_country_stroke()
				return
			if pending_key.ctrl_pressed and (pending_key.keycode == KEY_Z or pending_key.keycode == KEY_Y):
				_set_status("확정 대기 중입니다. Enter=확정, Esc=취소")
				return
		if event is InputEventMouseButton:
			var pending_mb: InputEventMouseButton = event
			if pending_mb.button_index == MOUSE_BUTTON_LEFT and pending_mb.pressed:
				_set_status("이전 국가 칠하기를 먼저 확정/취소하세요.")
		return

	if event is InputEventMouseMotion:
		var world: Vector2 = get_global_mouse_position()
		hovered_tile = terrain.get_tile_from_world(world, tool_config.tile_size)
		_update_brush_preview(world)
		if painting:
			var added_point: bool = _add_stroke_point(world)
			if _is_live_land_tool(active_tool) and added_point and stroke_points.size() >= 2:
				var a: Vector2 = stroke_points[stroke_points.size() - 2]
				var b: Vector2 = stroke_points[stroke_points.size() - 1]
				_apply_live_land_segment(a, b)
			if active_tool == "draw_country" and added_point and stroke_points.size() >= 2:
				var ca: Vector2 = stroke_points[stroke_points.size() - 2]
				var cb: Vector2 = stroke_points[stroke_points.size() - 1]
				_apply_live_country_segment(ca, cb)
			if active_tool == "draw_region":
				political.set_stroke_preview(stroke_points, world, false)
		if tile_dragging and tool_config.tile_erase_enabled:
			tile_drag_set[hovered_tile] = true
		if active_tool == "erase_tile" or tile_dragging or painting:
			queue_redraw()
		return

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_on_left_pressed()
			else:
				_on_left_released()
			return

	if event is InputEventKey and event.pressed and not event.echo:
		var k: InputEventKey = event
		if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
			return
		if k.ctrl_pressed and k.keycode == KEY_Z:
			_undo()
			return
		if k.ctrl_pressed and k.keycode == KEY_Y:
			_redo()
			return
		if k.keycode == KEY_ESCAPE:
			_cancel_current_stroke()
			return


func _cancel_current_stroke() -> void:
	if pending_country_confirm:
		_cancel_pending_country_stroke()
		return
	if painting and _is_live_land_tool(active_tool):
		_rollback_live_land_stroke()
	if painting and active_tool == "draw_country":
		_rollback_live_country_stroke()
	painting = false
	is_brush_dragging = false
	stroke_points.clear()
	political.clear_stroke_preview()
	tile_dragging = false
	tile_drag_set.clear()
	queue_redraw()
	_set_status("현재 드로잉 취소")


func _handle_camera_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			is_panning = mb.pressed
			return true
	if event is InputEventMouseMotion and is_panning:
		var mm: InputEventMouseMotion = event
		camera.position -= mm.relative * camera.zoom
		return true
	return false


func _on_left_pressed() -> void:
	if _is_pointer_on_ui():
		return
	var world: Vector2 = get_global_mouse_position()
	_update_brush_preview(world)
	if active_tool == "draw_region" and not REGION_TOOL_ENABLED:
		_set_status("지역 경계선 그리기는 현재 비활성화되어 있습니다.")
		return

	match active_tool:
		"paint_land", "erase_land", "paint_mountain", "paint_river", "draw_region":
			painting = true
			is_brush_dragging = active_tool != "draw_region"
			stroke_points.clear()
			stroke_points.append(world)
			if _is_live_land_tool(active_tool):
				_begin_live_land_stroke()
				_apply_live_land_segment(world, world)
			if active_tool == "draw_region":
				political.set_stroke_preview(stroke_points, world, false)
		"draw_country":
			painting = true
			is_brush_dragging = true
			stroke_points.clear()
			stroke_points.append(world)
			if not _begin_live_country_stroke(world):
				painting = false
				stroke_points.clear()
				return
			_apply_live_country_segment(world, world)
		"erase_tile":
			hovered_tile = terrain.get_tile_from_world(world, tool_config.tile_size)
			if tool_config.tile_erase_enabled:
				tile_dragging = true
				tile_drag_set.clear()
				tile_drag_set[hovered_tile] = true
			else:
				var one_tile: Array[Vector2i] = [hovered_tile]
				_commit_erase_tiles(one_tile)
		"select_country":
			var selected_id: String = political.select_country_at(world)
			if selected_id.is_empty():
				political.selected_country_id = ""
				_apply_selected_country_color_to_picker()
				_refresh_country_info_panel()
				_set_status("선택된 국가가 없습니다.")
			else:
				_set_status("국가 선택: %s" % _country_name_by_id(selected_id))
				_apply_selected_country_color_to_picker()
				_refresh_country_info_panel()
			_refresh_country_dropdown()


func _on_left_released() -> void:
	if painting:
		match active_tool:
			"draw_country":
				_finalize_live_country_stroke()
			"draw_region":
				_commit_region_stroke()
			"paint_land", "erase_land":
				_finalize_live_land_stroke()
			_:
				_commit_paint_stroke()
		painting = false
		is_brush_dragging = false
		stroke_points.clear()
		political.clear_stroke_preview()

	if tile_dragging:
		var tiles: Array[Vector2i] = []
		for t in tile_drag_set.keys():
			tiles.append(t as Vector2i)
		_commit_erase_tiles(tiles)
		tile_dragging = false
		tile_drag_set.clear()

	queue_redraw()


func _add_stroke_point(world: Vector2) -> bool:
	if stroke_points.is_empty():
		stroke_points.append(world)
		return true
	var min_dist: float = 2.0 if (active_tool == "draw_country" or active_tool == "draw_region") else max(1.0, float(tool_config.size) * 0.25)
	if stroke_points[stroke_points.size() - 1].distance_to(world) >= min_dist:
		stroke_points.append(world)
		return true
	return false


func _is_live_land_tool(tool_id: String) -> bool:
	return tool_id == "paint_land" or tool_id == "erase_land"


func _is_brush_preview_tool(tool_id: String) -> bool:
	return tool_id == "paint_land" or tool_id == "erase_land" or tool_id == "paint_mountain" or tool_id == "paint_river" or tool_id == "draw_country"


func _update_brush_preview(world: Vector2) -> void:
	if not is_instance_valid(terrain):
		return
	if _is_brush_preview_tool(active_tool):
		var erase_mode: bool = active_tool == "erase_land"
		terrain.set_brush_preview(world, float(tool_config.size), true, erase_mode, tool_config.brush_type, float(tool_config.noise_strength))
	else:
		terrain.set_brush_preview(world, float(tool_config.size), false, false, tool_config.brush_type, float(tool_config.noise_strength))


func _begin_live_land_stroke() -> void:
	var before: int = _latest_snapshot_id()
	if before < 0:
		before = _capture_snapshot()
	live_land_before_snapshot = before
	live_land_touched_tiles.clear()


func _begin_live_country_stroke(start_world: Vector2) -> bool:
	var before: int = _latest_snapshot_id()
	if before < 0:
		before = _capture_snapshot()
	live_country_before_snapshot = before
	live_country_changed = false
	live_country_arm_before = new_country_arm
	var result: Dictionary = political.begin_country_paint(start_world, terrain, new_country_arm)
	if not bool(result.get("ok", false)):
		live_country_before_snapshot = -1
		live_country_changed = false
		_set_status(str(result.get("message", "국가 칠하기를 시작할 수 없습니다.")))
		return false
	if bool(result.get("consumed_arm", false)):
		new_country_arm = false
		political.disarm_new_country_creation()
		_sync_country_create_button()
	if bool(result.get("created", false)):
		_refresh_country_dropdown()
		_apply_selected_country_color_to_picker()
	_refresh_country_info_panel()
	return true


func _apply_live_land_segment(a: Vector2, b: Vector2) -> void:
	var add_land: bool = active_tool == "paint_land"
	var seg: Array[Vector2] = [a, b]
	var touched: Array[Vector2i] = terrain.apply_land_stroke(seg, add_land, tool_config)
	for t in touched:
		live_land_touched_tiles[t] = true


func _apply_live_country_segment(a: Vector2, b: Vector2) -> void:
	var result: Dictionary = political.paint_country_segment(a, b, terrain, float(tool_config.size))
	if bool(result.get("changed", false)):
		live_country_changed = true
		_apply_selected_country_color_to_picker()
		_refresh_country_info_panel()


func _finalize_live_land_stroke() -> void:
	if live_land_before_snapshot < 0:
		return
	if live_land_touched_tiles.is_empty():
		_reset_live_land_tracking()
		return
	var after: int = _capture_snapshot()
	var cmd = TerrainEditCommandClass.new()
	cmd.op = active_tool
	cmd.stroke_points = stroke_points.duplicate()
	var touched: Array[Vector2i] = []
	for key in live_land_touched_tiles.keys():
		touched.append(key as Vector2i)
	cmd.affected_tiles = touched
	cmd.before_snapshot_id = live_land_before_snapshot
	cmd.after_snapshot_id = after
	command_stack.push(cmd)
	_mark_content_changed()
	_set_status("적용 완료: %s" % _tool_name_kr(active_tool))
	_reset_live_land_tracking()


func _rollback_live_land_stroke() -> void:
	if live_land_before_snapshot >= 0:
		_restore_snapshot(live_land_before_snapshot)
	_reset_live_land_tracking()


func _reset_live_land_tracking() -> void:
	live_land_before_snapshot = -1
	live_land_touched_tiles.clear()


func _finalize_live_country_stroke() -> void:
	if live_country_before_snapshot < 0:
		return
	political.end_country_paint()
	if not live_country_changed:
		_reset_live_country_tracking()
		_set_status("국가 칠하기 변경 사항이 없습니다.")
		return
	_enter_pending_country_confirm(stroke_points.duplicate(), live_country_before_snapshot, live_country_arm_before)
	_reset_live_country_tracking()


func _rollback_live_country_stroke() -> void:
	if live_country_before_snapshot >= 0:
		_restore_snapshot(live_country_before_snapshot)
	new_country_arm = live_country_arm_before
	if new_country_arm:
		political.arm_new_country_creation()
	else:
		political.disarm_new_country_creation()
	_sync_country_create_button()
	political.end_country_paint()
	_reset_live_country_tracking()


func _reset_live_country_tracking() -> void:
	live_country_before_snapshot = -1
	live_country_changed = false
	live_country_arm_before = new_country_arm


func _on_country_create_pressed() -> void:
	if pending_country_confirm:
		_set_status("확정 대기 중입니다. Enter=확정, Esc=취소")
		return
	new_country_arm = not new_country_arm
	if new_country_arm:
		political.arm_new_country_creation()
		_set_status("새 국가 생성 대기: 다음 유효 국가 칠하기 1회")
	else:
		political.disarm_new_country_creation()
		_set_status("새 국가 생성 대기 해제")
	_sync_country_create_button()


func _sync_country_create_button() -> void:
	if not is_instance_valid(country_create_button):
		return
	if new_country_arm:
		country_create_button.text = "새 국가 생성: 대기중"
	else:
		country_create_button.text = "새 국가 생성"


func _enter_pending_country_confirm(stroke: Array[Vector2], before_snapshot_id: int, arm_before: bool) -> void:
	pending_country_confirm = true
	pending_country_before_snapshot = before_snapshot_id
	pending_country_stroke_points = stroke.duplicate()
	pending_country_arm_before = arm_before
	_show_country_confirm_bar(true)
	if is_instance_valid(pending_country_timer):
		pending_country_timer.start(COUNTRY_CONFIRM_TIMEOUT_SEC)
	_set_status("국가 칠하기 검토: Enter=확정, Esc=취소 (1.2초 후 자동 취소)")


func _confirm_pending_country_stroke() -> void:
	if not pending_country_confirm:
		return
	var after: int = _capture_snapshot()
	var cmd = TerrainEditCommandClass.new()
	cmd.op = "draw_country"
	cmd.stroke_points = pending_country_stroke_points.duplicate()
	cmd.before_snapshot_id = pending_country_before_snapshot
	cmd.after_snapshot_id = after
	command_stack.push(cmd)
	_mark_content_changed()
	_clear_pending_country_confirm_state()
	_refresh_country_dropdown()
	_apply_selected_country_color_to_picker()
	_refresh_country_info_panel()
	_set_status("국가 칠하기 확정: %s" % _country_name_by_id(str(political.selected_country_id)))


func _cancel_pending_country_stroke() -> void:
	if not pending_country_confirm:
		return
	if pending_country_before_snapshot >= 0:
		_restore_snapshot(pending_country_before_snapshot)
	new_country_arm = pending_country_arm_before
	if new_country_arm:
		political.arm_new_country_creation()
	else:
		political.disarm_new_country_creation()
	_clear_pending_country_confirm_state()
	_set_status("국가 칠하기 취소")


func _on_pending_country_timeout() -> void:
	if pending_country_confirm:
		_cancel_pending_country_stroke()


func _clear_pending_country_confirm_state() -> void:
	pending_country_confirm = false
	pending_country_before_snapshot = -1
	pending_country_stroke_points.clear()
	pending_country_arm_before = false
	_show_country_confirm_bar(false)
	if is_instance_valid(pending_country_timer):
		pending_country_timer.stop()
	_sync_country_create_button()
	_refresh_country_info_panel()


func _show_country_confirm_bar(visible: bool) -> void:
	if is_instance_valid(country_confirm_bar):
		country_confirm_bar.visible = visible
	if is_instance_valid(country_confirm_ok_button):
		country_confirm_ok_button.disabled = not visible
	if is_instance_valid(country_confirm_cancel_button):
		country_confirm_cancel_button.disabled = not visible
	if is_instance_valid(tool_select):
		tool_select.disabled = visible
	if is_instance_valid(brush_select):
		brush_select.disabled = visible
	if is_instance_valid(size_slider):
		size_slider.mouse_filter = Control.MOUSE_FILTER_IGNORE if visible else Control.MOUSE_FILTER_STOP
	if is_instance_valid(tile_drag_toggle):
		tile_drag_toggle.disabled = visible
	if is_instance_valid(perf_mode_toggle):
		perf_mode_toggle.disabled = visible
	if is_instance_valid(quality_preset_select):
		quality_preset_select.disabled = visible
	if is_instance_valid(paint_like_toggle):
		paint_like_toggle.disabled = visible
	if is_instance_valid(country_color_picker):
		country_color_picker.disabled = visible
	if is_instance_valid(country_name_edit):
		country_name_edit.editable = (not visible) and not str(political.selected_country_id).is_empty()
	if is_instance_valid(country_rename_button):
		country_rename_button.disabled = visible or str(political.selected_country_id).is_empty()
	if is_instance_valid(country_create_button):
		country_create_button.disabled = visible
	if is_instance_valid(river_bake_button):
		river_bake_button.disabled = visible
	if is_instance_valid(river_bake_delta_toggle):
		river_bake_delta_toggle.disabled = visible
	if is_instance_valid(river_bake_preserve_toggle):
		river_bake_preserve_toggle.disabled = visible
	if is_instance_valid(river_bake_density_slider):
		river_bake_density_slider.mouse_filter = Control.MOUSE_FILTER_IGNORE if visible else Control.MOUSE_FILTER_STOP
	if is_instance_valid(river_bake_inland_slider):
		river_bake_inland_slider.mouse_filter = Control.MOUSE_FILTER_IGNORE if visible else Control.MOUSE_FILTER_STOP
	if is_instance_valid(river_bake_noise_slider):
		river_bake_noise_slider.mouse_filter = Control.MOUSE_FILTER_IGNORE if visible else Control.MOUSE_FILTER_STOP
	if is_instance_valid(river_bake_merge_slider):
		river_bake_merge_slider.mouse_filter = Control.MOUSE_FILTER_IGNORE if visible else Control.MOUSE_FILTER_STOP


func _commit_paint_stroke() -> void:
	if stroke_points.size() < 1:
		return
	var before: int = _latest_snapshot_id()
	if before < 0:
		before = _capture_snapshot()
	var touched_tiles: Array[Vector2i] = []

	match active_tool:
		"paint_land":
			touched_tiles = terrain.apply_land_stroke(stroke_points, true, tool_config)
		"erase_land":
			touched_tiles = terrain.apply_land_stroke(stroke_points, false, tool_config)
		"paint_mountain":
			touched_tiles = terrain.apply_mountain_stroke(stroke_points, tool_config)
		"paint_river":
			touched_tiles = terrain.apply_river_stroke(stroke_points, tool_config)

	var after: int = _capture_snapshot()
	var cmd = TerrainEditCommandClass.new()
	cmd.op = active_tool
	cmd.stroke_points = stroke_points.duplicate()
	cmd.affected_tiles = touched_tiles
	cmd.before_snapshot_id = before
	cmd.after_snapshot_id = after
	command_stack.push(cmd)
	_mark_content_changed()
	_set_status("적용 완료: %s" % _tool_name_kr(active_tool))


func _commit_region_stroke() -> void:
	if not REGION_TOOL_ENABLED:
		_set_status("지역 경계선 그리기는 현재 비활성화되어 있습니다.")
		return
	if stroke_points.size() < 3:
		_set_status("지역 경계선 점이 부족합니다.")
		return
	var before: int = _latest_snapshot_id()
	if before < 0:
		before = _capture_snapshot()
	var result: Dictionary = political.create_region_from_stroke(stroke_points, terrain)
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "지역 생성 실패")))
		return
	var after: int = _capture_snapshot()
	var cmd = TerrainEditCommandClass.new()
	cmd.op = "draw_region"
	cmd.stroke_points = stroke_points.duplicate()
	cmd.before_snapshot_id = before
	cmd.after_snapshot_id = after
	command_stack.push(cmd)
	_mark_content_changed()
	_refresh_country_dropdown()
	_set_status("지역 생성 완료: %s" % str(result.get("created", "")))


func _commit_erase_tiles(tiles: Array[Vector2i]) -> void:
	if tiles.is_empty():
		return
	var before: int = _latest_snapshot_id()
	if before < 0:
		before = _capture_snapshot()
	var touched: Array[Vector2i] = terrain.erase_tiles(tiles, tool_config.tile_size)
	var after: int = _capture_snapshot()
	var cmd = TerrainEditCommandClass.new()
	cmd.op = "erase_tile"
	cmd.affected_tiles = touched
	cmd.before_snapshot_id = before
	cmd.after_snapshot_id = after
	command_stack.push(cmd)
	_mark_content_changed()
	_set_status("타일 %d개 삭제" % touched.size())


func _undo() -> void:
	if pending_country_confirm:
		_set_status("확정 대기 중에는 되돌리기를 사용할 수 없습니다. Enter=확정, Esc=취소")
		return
	var cmd = command_stack.undo()
	if cmd == null:
		_set_status("되돌릴 작업이 없습니다.")
		return
	_restore_snapshot(int(cmd.before_snapshot_id))
	_mark_content_changed()
	_set_status("되돌리기: %s" % _tool_name_kr(str(cmd.op)))


func _redo() -> void:
	if pending_country_confirm:
		_set_status("확정 대기 중에는 다시실행을 사용할 수 없습니다. Enter=확정, Esc=취소")
		return
	var cmd = command_stack.redo()
	if cmd == null:
		_set_status("다시 실행할 작업이 없습니다.")
		return
	_restore_snapshot(int(cmd.after_snapshot_id))
	_mark_content_changed()
	_set_status("다시 실행: %s" % _tool_name_kr(str(cmd.op)))


func _capture_snapshot() -> int:
	snapshot_seq += 1
	var id: int = snapshot_seq
	snapshots[id] = {
		"terrain": terrain.capture_runtime_state(),
		"political": political.capture_runtime_state(),
		"tool": tool_config.to_dict()
	}
	snapshot_order.append(id)
	while snapshot_order.size() > MAX_SNAPSHOTS:
		var old_id: int = int(snapshot_order.pop_front())
		snapshots.erase(old_id)
	return id


func _restore_snapshot(id: int) -> void:
	if not snapshots.has(id):
		return
	var data: Dictionary = snapshots[id]
	terrain.restore_runtime_state(data.get("terrain", {}))
	political.restore_runtime_state(data.get("political", {}))
	var cfg = TerrainToolConfigClass.from_dict(data.get("tool", {}))
	tool_config = cfg
	_sync_tool_controls()
	_refresh_country_dropdown()
	_apply_selected_country_color_to_picker()
	_sync_country_name_editor()
	_sync_country_create_button()
	_refresh_country_info_panel()


func _latest_snapshot_id() -> int:
	if snapshot_order.is_empty():
		return -1
	return int(snapshot_order[snapshot_order.size() - 1])


func _is_pointer_on_ui() -> bool:
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	if is_instance_valid(ui_panel) and ui_panel.get_global_rect().has_point(mouse_pos):
		return true
	if is_instance_valid(country_info_panel) and country_info_panel.get_global_rect().has_point(mouse_pos):
		return true
	if is_instance_valid(country_confirm_bar) and country_confirm_bar.visible and country_confirm_bar.get_global_rect().has_point(mouse_pos):
		return true
	return false


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	ui_panel = PanelContainer.new()
	ui_panel.position = Vector2(18, 18)
	ui_panel.size = Vector2(400, 1060)
	canvas.add_child(ui_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	ui_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "판타지 지도 편집기"
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	tool_select = OptionButton.new()
	for i in range(TOOL_IDS.size()):
		var tool_id: String = str(TOOL_IDS[i])
		if tool_id == "draw_region" and not REGION_TOOL_ENABLED:
			continue
		tool_select.add_item(TOOL_LABELS[i])
		var item_index: int = tool_select.get_item_count() - 1
		tool_select.set_item_metadata(item_index, tool_id)
	tool_select.item_selected.connect(_on_tool_selected)
	vbox.add_child(_labeled("도구", tool_select))

	brush_select = OptionButton.new()
	brush_select.add_item("원형")
	brush_select.set_item_metadata(0, "circle")
	brush_select.add_item("텍스처")
	brush_select.set_item_metadata(1, "texture")
	brush_select.add_item("노이즈")
	brush_select.set_item_metadata(2, "noise")
	brush_select.item_selected.connect(_on_brush_selected)
	vbox.add_child(_labeled("브러시", brush_select))

	size_slider = _slider(2, 96, tool_config.size, 1)

	size_slider.value_changed.connect(func(v: float) -> void:
		tool_config.size = int(v)
		_sync_size_slider_percent_label()
		_update_brush_preview(get_global_mouse_position())
	)

	var size_row := HBoxContainer.new()
	size_row.add_child(size_slider)
	size_percent_label = Label.new()
	size_percent_label.custom_minimum_size = Vector2(44, 0)
	size_row.add_child(size_percent_label)
	vbox.add_child(_labeled("크기", size_row))
	_sync_size_slider_percent_label()

	noise_strength_slider = _slider(0, 100, int(round(float(tool_config.noise_strength) * 100.0)), 1)
	noise_strength_slider.value_changed.connect(func(v: float) -> void:
		tool_config.noise_strength = clampf(v / 100.0, 0.0, 1.0)
		_sync_noise_strength_percent_label()
		_update_brush_preview(get_global_mouse_position())
	)
	var noise_strength_row_inner := HBoxContainer.new()
	noise_strength_row_inner.add_child(noise_strength_slider)
	noise_strength_percent_label = Label.new()
	noise_strength_percent_label.custom_minimum_size = Vector2(44, 0)
	noise_strength_row_inner.add_child(noise_strength_percent_label)
	noise_strength_row = _labeled("노이즈 강도", noise_strength_row_inner)
	vbox.add_child(noise_strength_row)
	_sync_noise_strength_ui()

	tile_drag_toggle = CheckBox.new()
	tile_drag_toggle.text = "드래그 다중 타일 지우기"
	tile_drag_toggle.button_pressed = tool_config.tile_erase_enabled
	tile_drag_toggle.toggled.connect(func(on: bool) -> void: tool_config.tile_erase_enabled = on)
	vbox.add_child(tile_drag_toggle)

	perf_mode_toggle = CheckBox.new()
	perf_mode_toggle.text = "성능 모드"
	perf_mode_toggle.button_pressed = performance_mode_enabled
	perf_mode_toggle.toggled.connect(func(on: bool) -> void:
		performance_mode_enabled = on
		_apply_runtime_profile()
		_set_status("성능 모드: %s" % ("ON" if on else "OFF"))
	)
	vbox.add_child(perf_mode_toggle)

	quality_preset_select = OptionButton.new()
	quality_preset_select.add_item("고품질")
	quality_preset_select.set_item_metadata(0, "quality")
	quality_preset_select.add_item("균형")
	quality_preset_select.set_item_metadata(1, "balanced")
	quality_preset_select.add_item("속도우선")
	quality_preset_select.set_item_metadata(2, "speed")
	quality_preset_select.select(1)
	quality_preset_select.item_selected.connect(func(index: int) -> void:
		quality_preset = str(quality_preset_select.get_item_metadata(index))
		_apply_runtime_profile()
		_set_status("품질 프리셋: %s" % quality_preset)
	)
	vbox.add_child(_labeled("품질 프리셋", quality_preset_select))

	paint_like_toggle = CheckBox.new()
	paint_like_toggle.text = "그림판 모드(초경량)"
	paint_like_toggle.button_pressed = paint_like_mode_enabled
	paint_like_toggle.toggled.connect(func(on: bool) -> void:
		paint_like_mode_enabled = on
		_apply_runtime_profile()
		_set_status("그림판 모드: %s" % ("ON" if on else "OFF"))
	)
	vbox.add_child(paint_like_toggle)

	river_bake_density_slider = _slider(1, 100, 12, 1)
	river_bake_density_slider.value_changed.connect(func(_v: float) -> void:
		_sync_river_bake_percent_labels()
	)
	var river_density_row := HBoxContainer.new()
	river_density_row.add_child(river_bake_density_slider)
	river_bake_density_percent_label = Label.new()
	river_bake_density_percent_label.custom_minimum_size = Vector2(44, 0)
	river_density_row.add_child(river_bake_density_percent_label)
	vbox.add_child(_labeled("강 생성 밀도", river_density_row))

	river_bake_inland_slider = _slider(0, 100, 42, 1)
	river_bake_inland_slider.value_changed.connect(func(_v: float) -> void:
		_sync_river_bake_percent_labels()
	)
	var river_inland_row := HBoxContainer.new()
	river_inland_row.add_child(river_bake_inland_slider)
	river_bake_inland_percent_label = Label.new()
	river_bake_inland_percent_label.custom_minimum_size = Vector2(44, 0)
	river_inland_row.add_child(river_bake_inland_percent_label)
	vbox.add_child(_labeled("내륙 시작점", river_inland_row))

	river_bake_noise_slider = _slider(0, 100, 28, 1)
	river_bake_noise_slider.value_changed.connect(func(_v: float) -> void:
		_sync_river_bake_percent_labels()
	)
	var river_noise_row := HBoxContainer.new()
	river_noise_row.add_child(river_bake_noise_slider)
	river_bake_noise_percent_label = Label.new()
	river_bake_noise_percent_label.custom_minimum_size = Vector2(44, 0)
	river_noise_row.add_child(river_bake_noise_percent_label)
	vbox.add_child(_labeled("유로 변형", river_noise_row))

	river_bake_merge_slider = _slider(0, 100, 62, 1)
	river_bake_merge_slider.value_changed.connect(func(_v: float) -> void:
		_sync_river_bake_percent_labels()
	)
	var river_merge_row := HBoxContainer.new()
	river_merge_row.add_child(river_bake_merge_slider)
	river_bake_merge_percent_label = Label.new()
	river_bake_merge_percent_label.custom_minimum_size = Vector2(44, 0)
	river_merge_row.add_child(river_bake_merge_percent_label)
	vbox.add_child(_labeled("합류 강제", river_merge_row))

	river_bake_preserve_toggle = CheckBox.new()
	river_bake_preserve_toggle.text = "기존 수동 강 보호(자동강 갱신)"
	river_bake_preserve_toggle.button_pressed = true
	vbox.add_child(river_bake_preserve_toggle)

	river_bake_delta_toggle = CheckBox.new()
	river_bake_delta_toggle.text = "하구 델타 분기 허용"
	river_bake_delta_toggle.button_pressed = false
	vbox.add_child(river_bake_delta_toggle)

	river_bake_button = Button.new()
	river_bake_button.text = "강 자동 생성"
	river_bake_button.pressed.connect(_on_bake_rivers_pressed)
	vbox.add_child(river_bake_button)
	_sync_river_bake_percent_labels()

	country_color_picker = ColorPickerButton.new()
	country_color_picker.color = Color("#2E86DE")
	country_color_picker.custom_minimum_size = Vector2(42, 42)
	country_color_picker.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	country_color_picker.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	country_color_picker.color_changed.connect(_on_country_color_changed)
	var country_color_row := HBoxContainer.new()
	country_color_row.add_child(country_color_picker)
	vbox.add_child(_labeled("국가 색상", country_color_row))

	country_create_button = Button.new()
	country_create_button.pressed.connect(_on_country_create_pressed)
	vbox.add_child(country_create_button)
	_sync_country_create_button()

	var row2 := HBoxContainer.new()
	var undo_btn := Button.new()
	undo_btn.text = "되돌리기"
	undo_btn.pressed.connect(_undo)
	row2.add_child(undo_btn)
	var redo_btn := Button.new()
	redo_btn.text = "다시실행"
	redo_btn.pressed.connect(_redo)
	row2.add_child(redo_btn)
	vbox.add_child(row2)

	var row3 := HBoxContainer.new()
	var save_btn := Button.new()
	save_btn.text = "저장…"
	save_btn.pressed.connect(_on_save_clicked)
	row3.add_child(save_btn)
	var load_btn := Button.new()
	load_btn.text = "불러오기…"
	load_btn.pressed.connect(_on_open_clicked)
	row3.add_child(load_btn)
	vbox.add_child(row3)

	var help := RichTextLabel.new()
	help.fit_content = true
	help.scroll_active = false
	help.bbcode_enabled = true
	var help_text: String = "[b]사용 방법[/b]\n- 새 국가는 [새 국가 생성] 버튼을 누른 뒤 육지에서 1회만 생성됩니다.\n- 기존 국가는 그 국가 위에서 [국가 칠하기]로 확장합니다.\n- 스트로크 후 Enter=확정, Esc=취소(1.2초 내 미확정 시 자동 취소).\n- 바다에는 국가 색칠이 적용되지 않습니다."
	if not REGION_TOOL_ENABLED:
		help_text += "\n- [지역 경계선 그리기] 기능은 현재 비활성화 상태입니다."
	help.text = help_text
	vbox.add_child(help)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(320, 120)
	vbox.add_child(_labeled("상태", status_label))
	# Autosave UI and Export UI (injected)
	var autosave_row := HBoxContainer.new()
	autosave_toggle = CheckBox.new()
	autosave_toggle.text = "자동저장(120초)"
	autosave_toggle.toggled.connect(_on_autosave_toggled)
	autosave_row.add_child(autosave_toggle)
	vbox.add_child(autosave_row)

	var export_row := HBoxContainer.new()
	var export_btn := Button.new()
	export_btn.text = "내보내기…"
	export_btn.pressed.connect(_on_export_clicked)
	export_row.add_child(export_btn)
	var scale_lbl := Label.new()
	scale_lbl.text = "배율"
	export_row.add_child(scale_lbl)
	var scale_spin := SpinBox.new()
	scale_spin.min_value = 0.25
	scale_spin.max_value = 8.0
	scale_spin.step = 0.25
	scale_spin.value = 1.0
	scale_spin.value_changed.connect(func(v: float) -> void: export_scale = v)
	export_row.add_child(scale_spin)
	vbox.add_child(_labeled("PNG 내보내기", export_row))

	var export_opts := HBoxContainer.new()
	var chk_trans := CheckBox.new()
	chk_trans.text = "투명 배경"
	chk_trans.button_pressed = true
	chk_trans.toggled.connect(func(on: bool) -> void: export_transparent = on)
	export_opts.add_child(chk_trans)
	var chk_terr := CheckBox.new()
	chk_terr.text = "지형 포함"
	chk_terr.button_pressed = true
	chk_terr.toggled.connect(func(on: bool) -> void: export_include_terrain = on)
	export_opts.add_child(chk_terr)
	var chk_pol := CheckBox.new()
	chk_pol.text = "정치 포함"
	chk_pol.button_pressed = true
	chk_pol.toggled.connect(func(on: bool) -> void: export_include_political = on)
	export_opts.add_child(chk_pol)
	vbox.add_child(export_opts)

	# Init dialogs and autosave timer
	save_dialog = FileDialog.new()
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	save_dialog.title = "프로젝트 저장"
	save_dialog.add_filter("*.json ; JSON Project")
	save_dialog.file_selected.connect(_on_save_path_picked)
	canvas.add_child(save_dialog)

	open_dialog = FileDialog.new()
	open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	open_dialog.title = "프로젝트 열기"
	open_dialog.add_filter("*.json ; JSON Project")
	open_dialog.file_selected.connect(_on_open_path_picked)
	canvas.add_child(open_dialog)

	export_dialog = FileDialog.new()
	export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	export_dialog.title = "PNG 내보내기"
	export_dialog.add_filter("*.png ; PNG Image")
	export_dialog.file_selected.connect(_on_export_path_picked)
	canvas.add_child(export_dialog)

	autosave_timer = Timer.new()
	autosave_timer.wait_time = 120.0
	autosave_timer.one_shot = false
	autosave_timer.timeout.connect(_on_autosave_timeout)
	canvas.add_child(autosave_timer)

	pending_country_timer = Timer.new()
	pending_country_timer.wait_time = COUNTRY_CONFIRM_TIMEOUT_SEC
	pending_country_timer.one_shot = true
	pending_country_timer.timeout.connect(_on_pending_country_timeout)
	canvas.add_child(pending_country_timer)

	country_info_panel = PanelContainer.new()
	country_info_panel.anchor_left = 0.5
	country_info_panel.anchor_right = 0.5
	country_info_panel.anchor_top = 1.0
	country_info_panel.anchor_bottom = 1.0
	country_info_panel.offset_left = -260.0
	country_info_panel.offset_right = 260.0
	country_info_panel.offset_top = -72.0
	country_info_panel.offset_bottom = -18.0
	canvas.add_child(country_info_panel)

	var info_margin := MarginContainer.new()
	info_margin.add_theme_constant_override("margin_left", 12)
	info_margin.add_theme_constant_override("margin_top", 8)
	info_margin.add_theme_constant_override("margin_right", 12)
	info_margin.add_theme_constant_override("margin_bottom", 8)
	country_info_panel.add_child(info_margin)

	var info_vbox := VBoxContainer.new()
	info_vbox.add_theme_constant_override("separation", 6)
	info_margin.add_child(info_vbox)

	country_info_label = Label.new()
	country_info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	country_info_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	country_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_vbox.add_child(country_info_label)

	var info_actions := HBoxContainer.new()
	info_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	info_actions.add_theme_constant_override("separation", 8)
	info_vbox.add_child(info_actions)

	country_name_edit = LineEdit.new()
	country_name_edit.placeholder_text = "선택 국가 이름 변경"
	country_name_edit.custom_minimum_size = Vector2(220, 0)
	country_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	country_name_edit.text_submitted.connect(_on_country_name_submitted)
	info_actions.add_child(country_name_edit)

	country_rename_button = Button.new()
	country_rename_button.text = "국명 변경"
	country_rename_button.pressed.connect(_on_rename_country_pressed)
	info_actions.add_child(country_rename_button)

	country_confirm_bar = PanelContainer.new()
	country_confirm_bar.anchor_left = 0.5
	country_confirm_bar.anchor_right = 0.5
	country_confirm_bar.anchor_top = 1.0
	country_confirm_bar.anchor_bottom = 1.0
	country_confirm_bar.offset_left = -240.0
	country_confirm_bar.offset_right = 240.0
	country_confirm_bar.offset_top = -126.0
	country_confirm_bar.offset_bottom = -82.0
	canvas.add_child(country_confirm_bar)

	var confirm_margin := MarginContainer.new()
	confirm_margin.add_theme_constant_override("margin_left", 10)
	confirm_margin.add_theme_constant_override("margin_top", 8)
	confirm_margin.add_theme_constant_override("margin_right", 10)
	confirm_margin.add_theme_constant_override("margin_bottom", 8)
	country_confirm_bar.add_child(confirm_margin)

	var confirm_row := HBoxContainer.new()
	confirm_row.alignment = BoxContainer.ALIGNMENT_CENTER
	confirm_row.add_theme_constant_override("separation", 8)
	confirm_margin.add_child(confirm_row)

	country_confirm_label = Label.new()
	country_confirm_label.text = "국가 칠하기 확정 대기"
	confirm_row.add_child(country_confirm_label)

	country_confirm_ok_button = Button.new()
	country_confirm_ok_button.text = "확정"
	country_confirm_ok_button.pressed.connect(_confirm_pending_country_stroke)
	confirm_row.add_child(country_confirm_ok_button)

	country_confirm_cancel_button = Button.new()
	country_confirm_cancel_button.text = "취소"
	country_confirm_cancel_button.pressed.connect(_cancel_pending_country_stroke)
	confirm_row.add_child(country_confirm_cancel_button)

	_show_country_confirm_bar(false)

	perf_hud_label = Label.new()
	perf_hud_label.anchor_left = 0.0
	perf_hud_label.anchor_right = 0.0
	perf_hud_label.anchor_top = 1.0
	perf_hud_label.anchor_bottom = 1.0
	perf_hud_label.offset_left = 18.0
	perf_hud_label.offset_right = 540.0
	perf_hud_label.offset_top = -30.0
	perf_hud_label.offset_bottom = -8.0
	canvas.add_child(perf_hud_label)

	_refresh_country_info_panel()


func _build_name_dialog(parent_canvas: CanvasLayer) -> void:
	country_name_dialog = AcceptDialog.new()
	country_name_dialog.title = "국가 이름 지정"
	country_name_dialog.dialog_text = "새 국가 이름을 입력하세요."
	country_name_dialog.confirmed.connect(_on_country_name_dialog_confirmed)
	parent_canvas.add_child(country_name_dialog)

	country_name_dialog_input = LineEdit.new()
	country_name_dialog_input.placeholder_text = "예: 알테아 왕국"
	country_name_dialog_input.text_submitted.connect(_on_country_name_dialog_text_submitted)
	country_name_dialog.add_child(country_name_dialog_input)


func _slider(min_v: float, max_v: float, value: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.value = value
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


func _labeled(text: String, child: Control) -> Control:
	var wrap := VBoxContainer.new()
	var l := Label.new()
	l.text = text
	wrap.add_child(l)
	wrap.add_child(child)
	return wrap


func _on_tool_selected(index: int) -> void:
	if pending_country_confirm:
		_set_status("확정 대기 중에는 도구를 변경할 수 없습니다.")
		return
	active_tool = str(tool_select.get_item_metadata(index))
	if active_tool == "draw_region" and not REGION_TOOL_ENABLED:
		active_tool = "paint_land"
		tool_select.select(0)
		political.clear_stroke_preview()
		_update_brush_preview(get_global_mouse_position())
		_set_status("지역 경계선 그리기는 현재 비활성화되어 있습니다.")
		queue_redraw()
		return
	if active_tool != "draw_region":
		political.clear_stroke_preview()
	_update_brush_preview(get_global_mouse_position())
	_set_status("도구 선택: %s" % _tool_name_kr(active_tool))
	queue_redraw()


func _on_brush_selected(index: int) -> void:
	tool_config.brush_type = str(brush_select.get_item_metadata(index))
	_sync_noise_strength_ui()
	_update_brush_preview(get_global_mouse_position())
	_set_status("브러시 선택: %s" % tool_config.brush_type)


func _sync_noise_strength_ui() -> void:
	if is_instance_valid(noise_strength_row):
		noise_strength_row.visible = tool_config.brush_type == "noise"
	if is_instance_valid(noise_strength_slider):
		var target: float = clampf(float(tool_config.noise_strength), 0.0, 1.0) * 100.0
		if absf(noise_strength_slider.value - target) > 0.1:
			noise_strength_slider.value = target
	_sync_noise_strength_percent_label()


func _sync_size_slider_percent_label() -> void:
	if not is_instance_valid(size_slider) or not is_instance_valid(size_percent_label):
		return
	var percent: int = _slider_percent(size_slider, size_slider.value)
	size_percent_label.text = "%d%%" % percent


func _sync_noise_strength_percent_label() -> void:
	if not is_instance_valid(noise_strength_slider) or not is_instance_valid(noise_strength_percent_label):
		return
	var percent: int = int(round(noise_strength_slider.value))
	noise_strength_percent_label.text = "%d%%" % clampi(percent, 0, 100)


func _slider_percent(slider: HSlider, value: float) -> int:
	var denom: float = max(0.001, slider.max_value - slider.min_value)
	var ratio: float = (value - slider.min_value) / denom
	return clampi(int(round(ratio * 100.0)), 0, 100)


func _sync_river_bake_percent_labels() -> void:
	if is_instance_valid(river_bake_density_percent_label) and is_instance_valid(river_bake_density_slider):
		river_bake_density_percent_label.text = "%d%%" % int(round(river_bake_density_slider.value))
	if is_instance_valid(river_bake_inland_percent_label) and is_instance_valid(river_bake_inland_slider):
		river_bake_inland_percent_label.text = "%d%%" % int(round(river_bake_inland_slider.value))
	if is_instance_valid(river_bake_noise_percent_label) and is_instance_valid(river_bake_noise_slider):
		river_bake_noise_percent_label.text = "%d%%" % int(round(river_bake_noise_slider.value))
	if is_instance_valid(river_bake_merge_percent_label) and is_instance_valid(river_bake_merge_slider):
		river_bake_merge_percent_label.text = "%d%%" % int(round(river_bake_merge_slider.value))


func _on_bake_rivers_pressed() -> void:
	if pending_country_confirm:
		_set_status("확정 대기 중에는 강 자동 생성을 실행할 수 없습니다.")
		return
	var before: int = _latest_snapshot_id()
	if before < 0:
		before = _capture_snapshot()
	var result: Dictionary = terrain.bake_river_network({
		"target_resolution": 768,
		"source_density_pct": int(round(river_bake_density_slider.value)) if is_instance_valid(river_bake_density_slider) else 12,
		"inland_pct": int(round(river_bake_inland_slider.value)) if is_instance_valid(river_bake_inland_slider) else 42,
		"noise_pct": int(round(river_bake_noise_slider.value)) if is_instance_valid(river_bake_noise_slider) else 28,
		"merge_pct": int(round(river_bake_merge_slider.value)) if is_instance_valid(river_bake_merge_slider) else 62,
		"preserve_existing": river_bake_preserve_toggle.button_pressed if is_instance_valid(river_bake_preserve_toggle) else true,
		"delta_split": river_bake_delta_toggle.button_pressed if is_instance_valid(river_bake_delta_toggle) else false
	})
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("message", "강 자동 생성 실패")))
		return
	var generated: int = int(result.get("generated", 0))
	var preserved_manual: int = int(result.get("preserved_manual", 0))
	var removed_auto: int = int(result.get("removed_auto", 0))
	if generated <= 0:
		_set_status(str(result.get("message", "생성된 강이 없습니다. 밀도/내륙 비율을 조정해보세요.")))
		return
	var after: int = _capture_snapshot()
	var cmd = TerrainEditCommandClass.new()
	cmd.op = "generate_rivers"
	cmd.before_snapshot_id = before
	cmd.after_snapshot_id = after
	command_stack.push(cmd)
	_mark_content_changed()
	_set_status("강 자동 생성 완료: 신규 %d개 / 자동강 교체 %d개 / 수동강 보호 %d개 / 총 %d개" % [generated, removed_auto, preserved_manual, int(result.get("total", generated))])


func _on_country_selected(index: int) -> void:
	if index < 0:
		return
	var id: String = str(country_select.get_item_metadata(index))
	var name: String = country_select.get_item_text(index)
	political.selected_country_id = id
	_apply_selected_country_color_to_picker()
	_sync_country_name_editor()
	_refresh_country_info_panel()
	_set_status("국가 선택: %s" % name)


func _on_country_color_changed(new_color: Color) -> void:
	if pending_country_confirm:
		_set_status("확정 대기 중에는 국가 색상을 변경할 수 없습니다.")
		return
	var selected_id: String = str(political.selected_country_id)
	if selected_id.is_empty():
		return
	var before: int = _latest_snapshot_id()
	if before < 0:
		before = _capture_snapshot()
	var changed: bool = political.set_country_color(selected_id, new_color)
	if not changed:
		return
	var after: int = _capture_snapshot()
	var cmd = TerrainEditCommandClass.new()
	cmd.op = "country_color"
	cmd.before_snapshot_id = before
	cmd.after_snapshot_id = after
	command_stack.push(cmd)
	_mark_content_changed()
	_refresh_country_info_panel()
	_set_status("국가 색상 변경 완료")


func _on_rename_country_pressed() -> void:
	if pending_country_confirm:
		_set_status("확정 대기 중에는 국가 이름을 변경할 수 없습니다.")
		return
	var selected_id: String = str(political.selected_country_id)
	if selected_id.is_empty():
		_set_status("먼저 국가를 선택하세요.")
		return
	var new_name: String = country_name_edit.text.strip_edges()
	if new_name.is_empty():
		_set_status("국가 이름이 비어 있습니다.")
		return
	_apply_country_name_change(selected_id, new_name)


func _on_country_name_submitted(new_text: String) -> void:
	if pending_country_confirm:
		_set_status("확정 대기 중에는 국가 이름을 변경할 수 없습니다.")
		return
	var selected_id: String = str(political.selected_country_id)
	if selected_id.is_empty():
		return
	_apply_country_name_change(selected_id, new_text.strip_edges())


func _open_country_name_dialog(country_id: String) -> void:
	pending_country_id_for_naming = country_id
	country_name_dialog_input.text = _country_name_by_id(country_id)
	country_name_dialog.popup_centered(Vector2i(360, 120))
	country_name_dialog_input.grab_focus()
	country_name_dialog_input.select_all()


func _on_country_name_dialog_confirmed() -> void:
	var cid: String = pending_country_id_for_naming
	if cid.is_empty():
		return
	var new_name: String = country_name_dialog_input.text.strip_edges()
	pending_country_id_for_naming = ""
	if new_name.is_empty():
		return
	_apply_country_name_change(cid, new_name)


func _on_country_name_dialog_text_submitted(new_text: String) -> void:
	country_name_dialog.hide()
	var cid: String = pending_country_id_for_naming
	pending_country_id_for_naming = ""
	var cleaned: String = new_text.strip_edges()
	if cid.is_empty() or cleaned.is_empty():
		return
	_apply_country_name_change(cid, cleaned)


func _apply_country_name_change(country_id: String, new_name: String) -> void:
	var cleaned: String = new_name.strip_edges()
	if cleaned.is_empty():
		return
	var before: int = _latest_snapshot_id()
	if before < 0:
		before = _capture_snapshot()
	var changed: bool = political.set_country_name(country_id, cleaned)
	if not changed:
		_set_status("국가 이름 변경 실패")
		return
	var after: int = _capture_snapshot()
	var cmd = TerrainEditCommandClass.new()
	cmd.op = "country_rename"
	cmd.before_snapshot_id = before
	cmd.after_snapshot_id = after
	command_stack.push(cmd)
	_mark_content_changed()
	political.selected_country_id = country_id
	_refresh_country_dropdown()
	_sync_country_name_editor()
	_refresh_country_info_panel()
	_set_status("국가 이름 변경 완료: %s" % cleaned)


func _refresh_country_dropdown() -> void:
	if is_instance_valid(country_select):
		country_select.clear()
		for i in range(political.countries.size()):
			var c: Dictionary = political.countries[i]
			var id: String = str(c.get("id", ""))
			var name: String = str(c.get("name", id))
			country_select.add_item(name)
			country_select.set_item_metadata(i, id)
			if id == str(political.selected_country_id):
				country_select.select(i)
	_sync_country_name_editor()
	_refresh_country_info_panel()


func _sync_country_name_editor() -> void:
	if not is_instance_valid(country_name_edit):
		return
	var selected_id: String = str(political.selected_country_id)
	if selected_id.is_empty():
		country_name_edit.text = ""
		return
	country_name_edit.text = _country_name_by_id(selected_id)


func _apply_selected_country_color_to_picker() -> void:
	if not is_instance_valid(country_color_picker):
		return
	var cid: String = str(political.selected_country_id)
	if cid.is_empty():
		country_color_picker.color = Color("#2E86DE")
		return
	country_color_picker.color = _country_fill_color_by_id(cid)


func _country_fill_color_by_id(country_id: String) -> Color:
	for c_data in political.countries:
		var c: Dictionary = c_data
		if str(c.get("id", "")) == country_id:
			var fill_hex: String = str(c.get("style", {}).get("fill", "#C38B5E"))
			return Color(fill_hex)
	return Color("#2E86DE")


func _refresh_country_info_panel() -> void:
	if not is_instance_valid(country_info_label):
		return
	var arm_text: String = "ON" if new_country_arm else "OFF"
	var cid: String = str(political.selected_country_id)
	if cid.is_empty():
		country_info_label.text = "국가 정보: 선택된 국가 없음 | 새 국가 대기: %s" % arm_text
		if is_instance_valid(country_name_edit):
			country_name_edit.editable = false
			country_name_edit.text = ""
		if is_instance_valid(country_rename_button):
			country_rename_button.disabled = true
		return
	var info: Dictionary = political.get_country_info(cid)
	if info.is_empty():
		country_info_label.text = "국가 정보: 선택된 국가 없음 | 새 국가 대기: %s" % arm_text
		if is_instance_valid(country_name_edit):
			country_name_edit.editable = false
			country_name_edit.text = ""
		if is_instance_valid(country_rename_button):
			country_rename_button.disabled = true
		return
	var n: String = str(info.get("name", cid))
	var c_hex: String = str(info.get("fill", "#ffffff"))
	var cells: int = int(info.get("cells", 0))
	country_info_label.text = "국가: %s | 색상: %s | 면적 셀: %d | 새 국가 대기: %s" % [n, c_hex, cells, arm_text]
	if is_instance_valid(country_name_edit):
		country_name_edit.editable = not pending_country_confirm
		if country_name_edit.text.strip_edges().is_empty() or country_name_edit.text != n:
			country_name_edit.text = n
	if is_instance_valid(country_rename_button):
		country_rename_button.disabled = pending_country_confirm


func _set_status(text: String) -> void:
	if is_instance_valid(status_label):
		status_label.text = text
	_refresh_country_info_panel()


func _mark_content_changed() -> void:
	content_revision += 1


func _quality_profile(name: String) -> Dictionary:
	match name:
		"quality":
			return {
				"terrain": {
					"mountain_detail": true,
					"river_detail": true,
					"brush_preview_detail": "full",
					"noise_complexity": "high"
				},
				"political": {
					"border_smoothing_iterations": 3,
					"border_line_width": 2.2,
					"rebuild_deferred": false
				}
			}
		"speed":
			return {
				"terrain": {
					"mountain_detail": false,
					"river_detail": false,
					"brush_preview_detail": "simple",
					"noise_complexity": "low"
				},
				"political": {
					"border_smoothing_iterations": 0,
					"border_line_width": 1.6,
					"rebuild_deferred": true
				}
			}
		_:
			return {
				"terrain": {
					"mountain_detail": true,
					"river_detail": false,
					"brush_preview_detail": "full",
					"noise_complexity": "medium"
				},
				"political": {
					"border_smoothing_iterations": 2,
					"border_line_width": 2.0,
					"rebuild_deferred": true
				}
			}


func _compute_runtime_profile() -> Dictionary:
	var effective: String = quality_preset
	var zoom_level: float = 1.0
	if is_instance_valid(camera):
		zoom_level = max(camera.zoom.x, camera.zoom.y)
	var under_load: bool = zoom_level >= 1.8 or painting or is_brush_dragging
	if performance_mode_enabled and under_load and effective == "quality":
		effective = "balanced"
	return _quality_profile(effective)


func _apply_runtime_profile() -> void:
	if not is_instance_valid(terrain) or not is_instance_valid(political):
		return
	var profile: Dictionary = _compute_runtime_profile()
	var terrain_profile: Dictionary = profile.get("terrain", {}).duplicate(true)
	terrain_profile["flat_paint_mode"] = paint_like_mode_enabled
	var political_profile: Dictionary = profile.get("political", {}).duplicate(true)
	var key: String = _runtime_profile_cache_key(terrain_profile, political_profile)
	if key == _last_runtime_profile_key:
		return
	_last_runtime_profile_key = key
	terrain.set_runtime_quality(terrain_profile)
	political.set_runtime_quality(political_profile)


func _runtime_profile_cache_key(terrain_profile: Dictionary, political_profile: Dictionary) -> String:
	var parts: Array[String] = []
	parts.append("tm=%d" % int(bool(terrain_profile.get("mountain_detail", true))))
	parts.append("tr=%d" % int(bool(terrain_profile.get("river_detail", true))))
	parts.append("tp=%s" % str(terrain_profile.get("brush_preview_detail", "full")))
	parts.append("tn=%s" % str(terrain_profile.get("noise_complexity", "high")))
	parts.append("tf=%d" % int(bool(terrain_profile.get("flat_paint_mode", false))))
	parts.append("pb=%d" % int(political_profile.get("border_smoothing_iterations", 1)))
	parts.append("pw=%.3f" % float(political_profile.get("border_line_width", 2.0)))
	parts.append("pd=%d" % int(bool(political_profile.get("rebuild_deferred", true))))
	return "|".join(PackedStringArray(parts))


func _queue_async_save(path: String, force: bool = false) -> void:
	if path.is_empty() or async_saver == null:
		return
	if pending_country_confirm and not force:
		return
	var target_revision: int = content_revision
	if (not force) and target_revision == last_saved_revision:
		return
	if save_inflight and (not force) and target_revision == save_requested_revision:
		return

	var terrain_state := {
		"land_mask_chunks": terrain.export_land_mask_chunks(1024),
		"tile_erase_settings": {
			"tile_size": tool_config.tile_size,
			"enabled": tool_config.tile_erase_enabled
		},
		"feature_state": terrain.serialize_state(false)
	}
	var political_state: Dictionary = political.serialize_state()
	var payload: Dictionary = project_io.build_payload(
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
	save_requested_revision = target_revision
	save_status_text = "Saving"
	save_error_code = OK
	save_inflight = true
	async_saver.submit(path, payload, target_revision)


func _poll_async_save_result() -> void:
	if async_saver == null:
		return
	var result: Dictionary = async_saver.poll_result()
	if not result.is_empty():
		if bool(result.get("ok", false)):
			last_saved_revision = max(last_saved_revision, int(result.get("revision", last_saved_revision)))
			save_status_text = "OK"
			save_error_code = OK
			var done_path: String = str(result.get("path", current_project_path))
			_add_recent_file(done_path)
			_set_status("저장 완료: %s" % done_path)
		else:
			save_status_text = "Fail"
			save_error_code = int(result.get("error_code", ERR_CANT_CREATE))
			_set_status("저장 실패: 오류 %d" % save_error_code)
	save_inflight = async_saver.is_busy()


func _update_perf_hud() -> void:
	if not is_instance_valid(perf_hud_label):
		return
	var fps: int = Engine.get_frames_per_second()
	var terrain_stats: Dictionary = terrain.get_runtime_stats() if is_instance_valid(terrain) else {}
	var active_chunks: int = int(terrain_stats.get("active_chunks", 0))
	var save_label: String = save_status_text
	if save_inflight:
		save_label = "Saving"
	elif save_status_text == "Fail":
		save_label = "Fail(%d)" % save_error_code
	perf_hud_label.text = "FPS: %d | 활성 청크: %d | Save: %s" % [fps, active_chunks, save_label]


func _save_project() -> void:
	_queue_async_save(current_project_path, true)
	_set_status("저장 요청: %s" % current_project_path)


func _load_project() -> void:
	var err: int = project_io.load_project(current_project_path, terrain, political, tool_config)
	if err == OK:
		_clear_pending_country_confirm_state()
		new_country_arm = false
		political.disarm_new_country_creation()
		command_stack.clear()
		snapshots.clear()
		snapshot_order.clear()
		snapshot_seq = 0
		_last_runtime_profile_key = ""
		_capture_snapshot()
		_sync_tool_controls()
		_refresh_country_dropdown()
		_apply_selected_country_color_to_picker()
		_sync_country_name_editor()
		_sync_country_create_button()
		_refresh_country_info_panel()
		content_revision += 1
		last_saved_revision = content_revision
		save_requested_revision = content_revision
		save_status_text = "OK"
		save_error_code = OK
		_set_status("불러오기 완료: %s" % PROJECT_PATH)
	else:
		_set_status("불러오기 실패: 오류 %d" % err)


func _sync_tool_controls() -> void:
	for i in range(brush_select.get_item_count()):
		if str(brush_select.get_item_metadata(i)) == tool_config.brush_type:
			brush_select.select(i)
			break
	size_slider.value = tool_config.size
	_sync_size_slider_percent_label()
	_sync_noise_strength_ui()
	tile_drag_toggle.button_pressed = tool_config.tile_erase_enabled
	if is_instance_valid(perf_mode_toggle):
		perf_mode_toggle.button_pressed = performance_mode_enabled
	if is_instance_valid(quality_preset_select):
		for i in range(quality_preset_select.get_item_count()):
			if str(quality_preset_select.get_item_metadata(i)) == quality_preset:
				quality_preset_select.select(i)
				break
	if is_instance_valid(paint_like_toggle):
		paint_like_toggle.button_pressed = paint_like_mode_enabled
	_apply_runtime_profile()
	_update_brush_preview(get_global_mouse_position())


func _tool_name_kr(tool_id: String) -> String:
	match tool_id:
		"paint_land":
			return "땅 그리기"
		"erase_land":
			return "땅 지우기"
		"paint_mountain":
			return "산 그리기"
		"paint_river":
			return "강 그리기"
		"erase_tile":
			return "타일 지우기"
		"draw_country":
			return "국가 칠하기"
		"draw_region":
			return "지역 경계선 그리기"
		"select_country":
			return "국가 선택"
		"country_color":
			return "국가 색상 변경"
		"country_rename":
			return "국가 이름 변경"
		"generate_rivers":
			return "강 자동 생성"
		_:
			return tool_id


func _country_name_by_id(country_id: String) -> String:
	if country_id.is_empty():
		return ""
	return political.get_country_name(country_id)

# ===== Added: File save/open/export handlers, autosave, recent list =====
func _on_save_clicked() -> void:
	if is_instance_valid(save_dialog):
		save_dialog.current_file = "fantasy_map_project.json"
		save_dialog.popup_centered(Vector2i(760, 540))
	else:
		_do_save_to(current_project_path)

func _on_open_clicked() -> void:
	if is_instance_valid(open_dialog):
		open_dialog.popup_centered(Vector2i(760, 540))

func _on_save_path_picked(path: String) -> void:
	var p := path
	if not p.ends_with(".json"):
		p += ".json"
	current_project_path = p
	_do_save_to(current_project_path)

func _on_open_path_picked(path: String) -> void:
	current_project_path = path
	var err: int = project_io.load_project(current_project_path, terrain, political, tool_config)
	if err == OK:
		_clear_pending_country_confirm_state()
		new_country_arm = false
		political.disarm_new_country_creation()
		command_stack.clear()
		snapshots.clear()
		snapshot_order.clear()
		snapshot_seq = 0
		_capture_snapshot()
		_sync_tool_controls()
		_refresh_country_dropdown()
		_apply_selected_country_color_to_picker()
		_sync_country_name_editor()
		_sync_country_create_button()
		_refresh_country_info_panel()
		content_revision += 1
		last_saved_revision = content_revision
		save_requested_revision = content_revision
		save_status_text = "OK"
		save_error_code = OK
		_add_recent_file(current_project_path)
		_set_status("불러오기 완료: %s" % current_project_path)
	else:
		_set_status("불러오기 실패: 오류 %d" % err)

func _do_save_to(path: String, force: bool = true) -> void:
	_queue_async_save(path, force)
	_set_status("저장 요청: %s" % path)

func _on_autosave_toggled(on: bool) -> void:
	if on:
		if is_instance_valid(autosave_timer):
			autosave_timer.start()
		_set_status("자동저장 시작(120초)")
	else:
		if is_instance_valid(autosave_timer):
			autosave_timer.stop()
		_set_status("자동저장 중지")

func _on_autosave_timeout() -> void:
	if current_project_path.is_empty():
		return
	if pending_country_confirm:
		return
	if content_revision == last_saved_revision:
		return
	_queue_async_save(current_project_path, false)

func _recent_list_path() -> String:
	return recent_store_path

func _load_recent_list() -> Array:
	var p := _recent_list_path()
	var arr: Array = []
	if FileAccess.file_exists(p):
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			if typeof(parsed) == TYPE_ARRAY:
				arr = parsed
			f.close()
	return arr

func _save_recent_list(arr: Array) -> void:
	var f := FileAccess.open(_recent_list_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(arr, "\t"))
	f.close()

func _add_recent_file(path: String) -> void:
	var arr: Array = _load_recent_list()
	var cleaned: String = path
	var filtered: Array = []
	for it in arr:
		if str(it) != cleaned:
			filtered.append(it)
	filtered.push_front(cleaned)
	while filtered.size() > 5:
		filtered.pop_back()
	_save_recent_list(filtered)

func _on_export_clicked() -> void:
	if is_instance_valid(export_dialog):
		export_dialog.current_file = "map.png"
		export_dialog.popup_centered(Vector2i(760, 540))

func _on_export_path_picked(path: String) -> void:
	var p := path
	if not p.ends_with(".png"):
		p += ".png"
	var prev_ui := ui_panel.visible
	var prev_t: bool = terrain.visible
	var prev_p: bool = political.visible
	ui_panel.visible = false
	terrain.visible = export_include_terrain
	political.visible = export_include_political
	await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	ui_panel.visible = prev_ui
	terrain.visible = prev_t
	political.visible = prev_p
	if export_scale > 0.0 and absf(export_scale - 1.0) > 0.001:
		var w := int(img.get_width() * export_scale)
		var h := int(img.get_height() * export_scale)
		img.resize(max(w,1), max(h,1), Image.INTERPOLATE_LANCZOS)
	if not export_transparent:
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var c: Color = img.get_pixel(x, y)
				c.a = 1.0
				img.set_pixel(x, y, c)
	var err := img.save_png(p)
	if err == OK:
		_set_status("PNG 내보내기 완료: %s" % p)
	else:
		_set_status("PNG 내보내기 실패: 오류 %d" % err)


