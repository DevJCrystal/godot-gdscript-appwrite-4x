extends Control

# Minimal UI harness to run the existing test scenes and display results.

const _TESTS: Array[Dictionary] = [
	{"name": "Accounts", "scene": "res://tests/test_accounts.tscn"},
	{"name": "Databases", "scene": "res://tests/test_databases.tscn"},
	{"name": "Functions", "scene": "res://tests/test_functions.tscn"},
	{"name": "Realtime (Leaderboard)", "scene": "res://tests/test_realtime_player_docs.tscn"},
	{"name": "Queries", "scene": "res://tests/test_queries.tscn"},
	{"name": "Storage", "scene": "res://tests/test_storage.tscn"},
	{"name": "E2E (All)", "scene": "res://tests/test_e2e.tscn"},
]

const _TEST_TIMEOUT_SECONDS := 60.0

@onready var _status_label: Label = %StatusLabel
@onready var _log: RichTextLabel = %Log
@onready var _run_all: Button = %RunAllButton
@onready var _clear: Button = %ClearButton
@onready var _buttons_root: VBoxContainer = %ButtonsRoot

var _running := false
var _current_done := false
var _current_payload: Variant = null


func _ready() -> void:
	_status("Ready")
	_log.text = ""
	_clear.pressed.connect(_on_clear_pressed)
	_run_all.pressed.connect(_on_run_all_pressed)
	_build_test_buttons()


func _build_test_buttons() -> void:
	# Remove any existing test buttons.
	for c in _buttons_root.get_children():
		if c == _run_all or c == _clear:
			continue
		c.queue_free()

	# Insert buttons after Run/Clear.
	for t in _TESTS:
		var b := Button.new()
		b.text = "Run: %s" % str(t.get("name", "<missing>"))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_buttons_root.add_child(b)
		b.pressed.connect(func() -> void:
			await _run_single(t)
		)


func _on_clear_pressed() -> void:
	_log.text = ""
	_status("Ready")


func _on_run_all_pressed() -> void:
	await _run_all_tests()


func _set_running(value: bool) -> void:
	_running = value
	_run_all.disabled = value
	_clear.disabled = value
	for c in _buttons_root.get_children():
		if c is Button:
			(c as Button).disabled = value
	# Re-enable Clear while running? Keep it disabled to avoid state confusion.
	_clear.disabled = value


func _status(text: String) -> void:
	_status_label.text = "Status: %s" % text


func _log_line(text: String) -> void:
	_log.append_text(text + "\n")
	_log.scroll_to_line(_log.get_line_count())


func _run_all_tests() -> void:
	if _running:
		return
	_set_running(true)
	_log_line("--- Running all tests ---")
	var results: Array[Dictionary] = []
	var failed := false

	for t in _TESTS:
		# Skip the E2E scene during run-all to avoid double-running.
		if str(t.get("scene", "")) == "res://tests/test_e2e.tscn":
			continue
		var res := await _run_single(t)
		results.append(res)
		if not bool(res.get("skipped", false)) and not bool(res.get("ok", false)):
			failed = true

	_log_line("\n--- Summary ---")
	for r in results:
		var name := str(r.get("name", "<missing>"))
		if bool(r.get("skipped", false)):
			_log_line("- ↪ %s (skipped)" % name)
		elif bool(r.get("ok", false)):
			_log_line("- ✅ %s" % name)
		else:
			_log_line("- ❌ %s" % name)

	_status("Done (%s)" % ("fail" if failed else "pass"))
	_set_running(false)


func _run_single(t: Dictionary) -> Dictionary:
	if _running:
		# Allow single runs when idle only.
		return {"ok": false, "skipped": false, "error": "Runner busy"}

	_set_running(true)
	var name := str(t.get("name", "<missing>"))
	var scene_path := str(t.get("scene", ""))
	_status("Running %s" % name)
	_log_line("\n=== %s ===" % name)

	var res := await _run_test_scene(scene_path)
	res["name"] = name

	if bool(res.get("skipped", false)):
		_log_line("↪ Skipped")
	elif bool(res.get("ok", false)):
		_log_line("✅ Passed")
	else:
		_log_line("❌ Failed")
		_log_line("Details: %s" % JSON.stringify(res))

	_status("Ready")
	_set_running(false)
	return res


func _on_child_finished(result: Variant) -> void:
	_current_done = true
	_current_payload = result


func _run_test_scene(scene_path: String) -> Dictionary:
	if scene_path.is_empty():
		return {"ok": false, "skipped": false, "error": "Missing scene path"}

	var packed: PackedScene = load(scene_path)
	if packed == null:
		return {"ok": false, "skipped": false, "error": "Could not load scene", "scene": scene_path}

	var node := packed.instantiate()
	if not node.has_signal("finished"):
		node.queue_free()
		return {"ok": false, "skipped": false, "error": "Test scene has no 'finished' signal", "scene": scene_path}

	_current_done = false
	_current_payload = null
	var connect_err := node.connect("finished", Callable(self, "_on_child_finished"))
	if connect_err != OK:
		node.queue_free()
		return {"ok": false, "skipped": false, "error": "Failed to connect to finished signal", "connect_error": connect_err, "scene": scene_path}

	add_child(node)

	var start_ms := Time.get_ticks_msec()
	var timeout_ms := int(_TEST_TIMEOUT_SECONDS * 1000.0)
	while not _current_done and (Time.get_ticks_msec() - start_ms) < timeout_ms:
		await get_tree().process_frame

	if not _current_done:
		node.queue_free()
		await get_tree().process_frame
		return {"ok": false, "skipped": false, "error": "Test timed out", "timeout_seconds": _TEST_TIMEOUT_SECONDS, "scene": scene_path}

	node.queue_free()
	await get_tree().process_frame

	if typeof(_current_payload) == TYPE_DICTIONARY:
		return _current_payload as Dictionary
	return {"ok": false, "skipped": false, "error": "Invalid finished payload", "scene": scene_path}
