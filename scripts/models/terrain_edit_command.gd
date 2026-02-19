extends RefCounted
class_name TerrainEditCommand

var op: String = ""
var stroke_points: Array[Vector2] = []
var affected_tiles: Array[Vector2i] = []
var before_snapshot_id: int = -1
var after_snapshot_id: int = -1


func to_dict() -> Dictionary:
	var points_json: Array = []
	for p in stroke_points:
		points_json.append({"x": p.x, "y": p.y})

	var tiles_json: Array = []
	for t in affected_tiles:
		tiles_json.append({"x": t.x, "y": t.y})

	return {
		"op": op,
		"stroke_points": points_json,
		"affected_tiles": tiles_json,
		"before_snapshot_id": before_snapshot_id,
		"after_snapshot_id": after_snapshot_id
	}


static func from_dict(data: Dictionary):
	var cmd = load("res://scripts/models/terrain_edit_command.gd").new()
	cmd.op = str(data.get("op", ""))
	cmd.before_snapshot_id = int(data.get("before_snapshot_id", -1))
	cmd.after_snapshot_id = int(data.get("after_snapshot_id", -1))

	for p in data.get("stroke_points", []):
		cmd.stroke_points.append(Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0))))

	for t in data.get("affected_tiles", []):
		cmd.affected_tiles.append(Vector2i(int(t.get("x", 0)), int(t.get("y", 0))))

	return cmd
