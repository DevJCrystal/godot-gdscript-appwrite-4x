extends Node

signal finished(result: Dictionary)

const _TESTS: Array[Dictionary] = [
	{"name": "Accounts", "scene": "res://tests/test_accounts.tscn"},
	{"name": "Databases", "scene": "res://tests/test_databases.tscn"},
	{"name": "Functions", "scene": "res://tests/test_functions.tscn"},
	{"name": "Queries", "scene": "res://tests/test_queries.tscn"},
	{"name": "Storage", "scene": "res://tests/test_storage.tscn"},
]

const _TEST_TIMEOUT_SECONDS := 60.0

var _current_done := false
var _current_payload: Variant = null


func _on_child_finished(result: Variant) -> void:
	_current_done = true
	_current_payload = result


func _ready() -> void:
	print("--- Starting Appwrite E2E Runner ---")
	var results: Array[Dictionary] = []
	var failed := false

	for t in _TESTS:
		var name := str(t.get("name", "<missing>"))
		var scene_path := str(t.get("scene", ""))
		print("\n=== Running: ", name, " ===")
		var res := await _run_test_scene(scene_path)
		res["name"] = name
		results.append(res)

		if bool(res.get("skipped", false)):
			print("↪ Skipped: ", name)
			continue
		if bool(res.get("ok", false)):
			print("✅ Passed: ", name)
			continue
		print("❌ Failed: ", name)
		print("Details: ", res)
		failed = true
		continue

	_print_summary(results)
	print("--- E2E Runner Finished ---")
	emit_signal("finished", {"ok": not failed, "results": results})


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


func _print_summary(results: Array[Dictionary]) -> void:
	var passed := 0
	var skipped := 0
	var failed := 0

	for r in results:
		if bool(r.get("skipped", false)):
			skipped += 1
		elif bool(r.get("ok", false)):
			passed += 1
		else:
			failed += 1

	print("\n--- Summary ---")
	print("Passed: ", passed, "  Skipped: ", skipped, "  Failed: ", failed)
	for r in results:
		var name := str(r.get("name", "<missing>"))
		if bool(r.get("skipped", false)):
			print("- ↪ ", name, " (skipped)")
		elif bool(r.get("ok", false)):
			print("- ✅ ", name)
		else:
			print("- ❌ ", name)
			print("  ", r)
