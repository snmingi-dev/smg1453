extends RefCounted
class_name AsyncProjectSaver

const ProjectIOClass = preload("res://scripts/systems/project_io.gd")

var _thread: Thread = Thread.new()
var _mutex: Mutex = Mutex.new()
var _running: bool = false
var _pending: bool = false
var _pending_path: String = ""
var _pending_payload: Dictionary = {}
var _pending_revision: int = -1
var _status: String = "idle"
var _result_ready: bool = false
var _last_result: Dictionary = {}


func _init() -> void:
	_running = true
	var err: int = _thread.start(Callable(self, "_worker_loop"))
	if err != OK:
		_running = false
		_status = "error"
		_result_ready = true
		_last_result = {
			"ok": false,
			"revision": -1,
			"path": "",
			"error_code": err
		}


func submit(path: String, payload: Dictionary, revision: int) -> void:
	_mutex.lock()
	if not _running:
		_status = "error"
		_result_ready = true
		_last_result = {
			"ok": false,
			"revision": revision,
			"path": path,
			"error_code": ERR_UNAVAILABLE
		}
		_mutex.unlock()
		return
	_pending = true
	_pending_path = path
	_pending_payload = payload.duplicate(true)
	_pending_revision = revision
	if _status == "idle" or _status == "saved":
		_status = "queued"
	_mutex.unlock()


func poll_result() -> Dictionary:
	_mutex.lock()
	var out: Dictionary = {}
	if _result_ready:
		out = _last_result.duplicate(true)
		_result_ready = false
	_mutex.unlock()
	return out


func get_status() -> String:
	_mutex.lock()
	var s: String = _status
	_mutex.unlock()
	return s


func is_busy() -> bool:
	_mutex.lock()
	var busy: bool = _pending or _status == "queued" or _status == "saving"
	_mutex.unlock()
	return busy


func shutdown() -> void:
	_mutex.lock()
	_running = false
	_mutex.unlock()
	if _thread.is_started():
		_thread.wait_to_finish()


func _worker_loop() -> void:
	var io = ProjectIOClass.new()
	while true:
		var has_work: bool = false
		var path: String = ""
		var payload: Dictionary = {}
		var revision: int = -1

		_mutex.lock()
		if not _running:
			_mutex.unlock()
			break
		if _pending:
			has_work = true
			path = _pending_path
			payload = _pending_payload
			revision = _pending_revision
			_pending = false
			_status = "saving"
		_mutex.unlock()

		if not has_work:
			OS.delay_msec(16)
			continue

		var err: int = io.write_payload(path, payload)

		_mutex.lock()
		if err == OK:
			_status = "saved"
		else:
			_status = "error"
		_last_result = {
			"ok": err == OK,
			"revision": revision,
			"path": path,
			"error_code": err
		}
		_result_ready = true
		_mutex.unlock()
