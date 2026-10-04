extends RefCounted
## Runs TrackAnalyzer.analyze_file on a worker Thread.
##
##   var job = AnalysisJob.new()
##   job.finished.connect(func(result): if result.has("analysis"): source = TrackSource.new(result.analysis))
##   job.start(path)
##   # ...main thread keeps rendering; `finished` is emitted on the main thread
##   # (call_deferred). Or poll: if job.is_done(): var result = job.take_result()
## Always keep a reference to the job until it finishes.

const TrackAnalyzer := preload("res://analysis/track_analyzer.gd")

signal finished(result: Dictionary)

var path: String = ""
var _thread: Thread
var _result: Dictionary = {}
var _done: bool = false
var _mutex := Mutex.new()

func start(file_path: String, use_cache: bool = true) -> bool:
	if _thread != null:
		return false
	path = file_path
	_thread = Thread.new()
	return _thread.start(_run.bind(file_path, use_cache), Thread.PRIORITY_LOW) == OK

func _run(file_path: String, use_cache: bool) -> void:
	var r: Dictionary = TrackAnalyzer.analyze_file(file_path, use_cache)
	_mutex.lock()
	_result = r
	_done = true
	_mutex.unlock()
	call_deferred("_emit_finished")

func _emit_finished() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	finished.emit(_result)

func is_done() -> bool:
	_mutex.lock()
	var d := _done
	_mutex.unlock()
	return d

## Blocks until done; returns {analysis, cached} or {error}.
func take_result() -> Dictionary:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	return _result
