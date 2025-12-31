extends Control

const Helpers := preload("res://tests/test_helpers.gd")

# Live leaderboard (read-only):
# - Loads the table once on connect.
# - Subscribes to realtime and re-renders on updates.
# - Highlights the current player's document (doc $id == user $id).

var _realtime: AppwriteRealtime = null
var _sub_id: int = -1

var _database_id := ""
var _table_id := ""

var _player_doc_id := ""

var _docs_by_id: Dictionary = {} # String -> Dictionary

var _score_field := "bestScore"

var _title_label: Label
var _row_labels: Array[Label] = []
const _TOP_N := 5


func _ready() -> void:
	_build_ui()

	_database_id = OS.get_environment("APPWRITE_DATABASE_ID").strip_edges()
	_table_id = OS.get_environment("APPWRITE_TABLE_ID").strip_edges()

	if _database_id.is_empty() or _table_id.is_empty():
		_set_status("Missing APPWRITE_DATABASE_ID / APPWRITE_TABLE_ID")
		return

	# Auth is required for most database realtime channels.
	var auth_email := OS.get_environment("APPWRITE_TEST_EMAIL").strip_edges()
	var auth_password := OS.get_environment("APPWRITE_TEST_PASSWORD").strip_edges()
	if auth_email.is_empty() or auth_password.is_empty():
		_set_status("Missing APPWRITE_TEST_EMAIL / APPWRITE_TEST_PASSWORD")
		return

	print("--- Starting Realtime Player Docs Test (Top 5) ---")
	print("DB=", _database_id, " Table=", _table_id)
	print("Tracking field=", _score_field)

	print("Authenticating (reuse session if available)...")
	var auth := await Helpers.ensure_logged_in()
	if not bool(auth.get("ok", false)):
		printerr("Auth failed: ", auth.get("error", {}))
		_set_status("Auth failed")
		return

	var me_resp: Dictionary = auth.get("me", {})
	var me_data: Variant = me_resp.get("data")
	var me: Dictionary = me_data if typeof(me_data) == TYPE_DICTIONARY else {}
	_player_doc_id = str(me.get("$id", ""))
	if _player_doc_id.is_empty():
		_set_status("Could not determine user $id")
		return

	_realtime = Appwrite.get("realtime") as AppwriteRealtime
	if _realtime == null:
		_set_status("Appwrite.realtime not available")
		return

	# Optional realtime debug logging.
	var rt_debug := OS.get_environment("APPWRITE_DEBUG_REALTIME").strip_edges().to_lower()
	if rt_debug == "true" or rt_debug == "1" or rt_debug == "yes" or rt_debug == "y":
		_realtime.set_debug(true)

	# Load documents on connect (ordered by bestScore).
	await _load_all_documents()
	_render_leaderboard()

	# Subscribe to the collection and filter events down to the two doc IDs.
	var channel := "databases.%s.collections.%s.documents" % [_database_id, _table_id]
	_sub_id = _realtime.subscribe([channel], Callable(self, "_on_realtime_event"))
	if _sub_id < 0:
		_set_status("Subscribe failed")
		return

	print("Subscribed. Player doc=", _player_doc_id)


func _exit_tree() -> void:
	if _realtime != null and _sub_id >= 0:
		_realtime.unsubscribe(_sub_id)
		_sub_id = -1


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.offset_left = 24
	root.offset_top = 24
	root.offset_right = -24
	root.offset_bottom = -24
	add_child(root)

	_title_label = Label.new()
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title_label.text = "Top %d (by %s)" % [_TOP_N, _score_field]
	root.add_child(_title_label)

	_row_labels = []
	for i in range(_TOP_N):
		var l := Label.new()
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.text = "%d) -" % (i + 1)
		root.add_child(l)
		_row_labels.append(l)


func _set_status(text: String) -> void:
	if _title_label != null:
		_title_label.text = text
	# Clear rows so it's obvious we're not showing a real leaderboard yet.
	for i in range(_row_labels.size()):
		var l: Label = _row_labels[i]
		l.text = "%d) -" % (i + 1)


func _load_all_documents() -> void:
	_docs_by_id = {}

	# Ask server to sort by score so we can reliably display the leaderboard.
	var resp := await Appwrite.databases.list_documents(
		_database_id,
		_table_id,
		[Query.order_desc(_score_field), Query.limit(100)]
	)
	if int(resp.get("status_code", 0)) != 200:
		printerr("List documents failed: ", resp.get("data", {}))
		return

	var data: Variant = resp.get("data")
	var d: Dictionary = data if typeof(data) == TYPE_DICTIONARY else {}

	# Appwrite returns {documents:[...]} for collections. Keep a fallback for other shapes.
	var raw_list: Variant = d.get("documents", null)
	if raw_list == null:
		raw_list = d.get("rows", null)
	if raw_list == null:
		raw_list = d.get("data", null)

	var docs: Array = []
	if typeof(raw_list) == TYPE_ARRAY:
		docs = raw_list as Array
	elif typeof(data) == TYPE_ARRAY:
		docs = data as Array

	for item in docs:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var doc := item as Dictionary
		var id := str(doc.get("$id", ""))
		if id.is_empty():
			continue
		_docs_by_id[id] = doc

	# Ensure player's document is present even if it isn't in the top results.
	if not _player_doc_id.is_empty() and not _docs_by_id.has(_player_doc_id):
		var me_doc := await Appwrite.databases.get_document(_database_id, _table_id, _player_doc_id)
		if int(me_doc.get("status_code", 0)) == 200:
			var md: Variant = me_doc.get("data")
			if typeof(md) == TYPE_DICTIONARY:
				_docs_by_id[_player_doc_id] = md as Dictionary

	print("Loaded docs count=", _docs_by_id.size(), " player=", _player_doc_id)


func _render_leaderboard() -> void:
	if _row_labels.is_empty():
		return

	# Build sortable list of docs.
	var entries: Array[Dictionary] = []
	for id in _docs_by_id.keys():
		var v: Variant = _docs_by_id[id]
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var doc := v as Dictionary
		var doc_id := str(doc.get("$id", id))
		var score := _coerce_score(doc.get(_score_field))
		entries.append({"id": doc_id, "score": score})

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)

	for i in range(_TOP_N):
		var label: Label = _row_labels[i]
		if i >= entries.size():
			label.text = "%d) -" % (i + 1)
			continue
		var e := entries[i]
		var id := str(e.get("id", ""))
		var score_str := _score_to_string(e.get("score"))
		var is_you := (not _player_doc_id.is_empty() and id == _player_doc_id)
		label.text = "%d) %s%s  bestScore=%s" % [i + 1, ("YOU → " if is_you else ""), id, score_str]


func _coerce_score(v: Variant) -> float:
	if v == null:
		return -INF
	match typeof(v):
		TYPE_FLOAT:
			return float(v)
		TYPE_INT:
			return float(int(v))
		TYPE_STRING:
			var s := str(v)
			return float(s) if s.is_valid_float() else -INF
		_:
			return -INF


func _score_to_string(v: Variant) -> String:
	if v == null:
		return "null"
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return str(v)
	return str(v)


func _on_realtime_event(msg: Dictionary) -> void:
	# Cache every doc update, then re-render top 5.
	var payload: Variant = msg.get("payload")
	if typeof(payload) != TYPE_DICTIONARY:
		return
	var doc := payload as Dictionary
	var id := str(doc.get("$id", ""))
	if id.is_empty():
		return

	_docs_by_id[id] = doc
	_render_leaderboard()
