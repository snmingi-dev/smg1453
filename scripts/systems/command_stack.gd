extends RefCounted
class_name CommandStack

const MAX_HISTORY := 300

var _undo: Array = []
var _redo: Array = []


func clear() -> void:
	_undo.clear()
	_redo.clear()


func push(cmd) -> void:
	_undo.append(cmd)
	_redo.clear()
	if _undo.size() > MAX_HISTORY:
		_undo.remove_at(0)


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo():
	if _undo.is_empty():
		return null
	var cmd = _undo.pop_back()
	_redo.append(cmd)
	return cmd


func redo():
	if _redo.is_empty():
		return null
	var cmd = _redo.pop_back()
	_undo.append(cmd)
	return cmd
