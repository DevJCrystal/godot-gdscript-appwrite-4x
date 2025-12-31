extends Node

const Helpers := preload("res://tests/test_helpers.gd")

signal finished(result: Dictionary)

const _WAIT_SECONDS_DEFAULT := 10.0
const _CONNECT_WAIT_SECONDS_DEFAULT := 5.0

var _received := false
var _last_message: Dictionary = {}

func _finish(ok: bool, skipped: bool = false, details: Dictionary = {}) -> void:
	var out := details.duplicate()
	out["name"] = "Realtime"
	out["ok"] = ok
	out["skipped"] = skipped
	emit_signal("finished", out)


func _on_realtime_message(msg: Dictionary) -> void:
	_received = true
	_last_message = msg
	var events: Array[String] = []
	var raw_events: Variant = msg.get("events", [])
	if typeof(raw_events) == TYPE_ARRAY:
		for e in raw_events:
			events.append(str(e))
	print("Realtime event received. events=", events, " msg=", msg)
	# Note: by default this test ends as soon as the first event is received.
	# To keep the socket open for the full timeout (to observe stability), set:
	#   APPWRITE_REALTIME_WAIT_FULL=true


func _on_rt_connected() -> void:
	print("Realtime connected")


func _on_rt_disconnected(code: int, reason: String) -> void:
	print("Realtime disconnected code=", code, " reason=", reason)


func _on_rt_any_message(msg: Dictionary) -> void:
	# Appwrite may send messages with no channels (e.g. error/connected frames).
	# Printing these helps diagnose auth/permission issues.
	var has_channels := false
	var raw_channels: Variant = msg.get("channels", null)
	if typeof(raw_channels) == TYPE_ARRAY:
		has_channels = (raw_channels as Array).size() > 0
	if not has_channels:
		print("Realtime (non-channel) message: ", msg)


func _ready() -> void:
	print("--- Starting Appwrite Realtime Test ---")

	# Optional test tuning via env vars (useful for debugging socket stability).
	# - APPWRITE_REALTIME_WAIT_SECONDS=30
	# - APPWRITE_REALTIME_CONNECT_WAIT_SECONDS=10
	var wait_seconds := float(OS.get_environment("APPWRITE_REALTIME_WAIT_SECONDS").strip_edges())
	if wait_seconds <= 0.0:
		wait_seconds = _WAIT_SECONDS_DEFAULT
	var connect_wait_seconds := float(OS.get_environment("APPWRITE_REALTIME_CONNECT_WAIT_SECONDS").strip_edges())
	if connect_wait_seconds <= 0.0:
		connect_wait_seconds = _CONNECT_WAIT_SECONDS_DEFAULT

	var database_id := OS.get_environment("APPWRITE_DATABASE_ID").strip_edges()
	var table_id := OS.get_environment("APPWRITE_TABLE_ID").strip_edges()
	if database_id.is_empty() or table_id.is_empty():
		print("⚠️ Skipping: APPWRITE_DATABASE_ID / APPWRITE_TABLE_ID not set.")
		print("--- Test Finished ---")
		_finish(true, true, {"reason": "Missing APPWRITE_DATABASE_ID / APPWRITE_TABLE_ID"})
		return

	# Auth is required for most database realtime channels.
	var auth_email := OS.get_environment("APPWRITE_TEST_EMAIL").strip_edges()
	var auth_password := OS.get_environment("APPWRITE_TEST_PASSWORD").strip_edges()
	if auth_email.is_empty() or auth_password.is_empty():
		print("⚠️ Skipping: APPWRITE_TEST_EMAIL / APPWRITE_TEST_PASSWORD not set.")
		print("--- Test Finished ---")
		_finish(true, true, {"reason": "Missing APPWRITE_TEST_EMAIL / APPWRITE_TEST_PASSWORD"})
		return

	# Only clear cookies if explicitly requested (or if persistence is disabled).
	if Helpers.should_clear_cookies() and Appwrite.has_method("clear_cookies"):
		Appwrite.clear_cookies()

	print("Authenticating (reuse session if available)...")
	var auth := await Helpers.ensure_logged_in()
	if not bool(auth.get("ok", false)):
		print("❌ FAILED auth.")
		print("Error: ", auth.get("error", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": auth.get("error", {})})
		return
	print("✅ Authenticated. Reused session=", auth.get("reused", false))

	# Pull the logged-in user's ID so we can satisfy required schema fields.
	var me_resp: Dictionary = auth.get("me", {})
	var me_data: Variant = me_resp.get("data")
	var me: Dictionary = me_data if typeof(me_data) == TYPE_DICTIONARY else {}
	var my_user_id := str(me.get("$id", ""))
	if my_user_id.is_empty():
		print("❌ Could not determine logged-in user id.")
		print("--- Test Finished ---")
		_finish(false, false, {"error": "Missing user id from /account"})
		return

	var realtime: AppwriteRealtime = Appwrite.get("realtime") as AppwriteRealtime
	if realtime == null:
		print("❌ Realtime service not available (Appwrite.realtime is null).")
		print("--- Test Finished ---")
		_finish(false, false, {"error": "Realtime not wired"})
		return

	# Optional realtime debug logging.
	var rt_debug := OS.get_environment("APPWRITE_DEBUG_REALTIME").strip_edges().to_lower()
	if rt_debug == "true" or rt_debug == "1" or rt_debug == "yes" or rt_debug == "y":
		realtime.set_debug(true)

	# Helpful connection logs while debugging.
	if not realtime.is_connected("connected", Callable(self, "_on_rt_connected")):
		realtime.connect("connected", Callable(self, "_on_rt_connected"))
	if not realtime.is_connected("disconnected", Callable(self, "_on_rt_disconnected")):
		realtime.connect("disconnected", Callable(self, "_on_rt_disconnected"))
	if not realtime.is_connected("message_received", Callable(self, "_on_rt_any_message")):
		realtime.connect("message_received", Callable(self, "_on_rt_any_message"))

	# Subscribe to document events for this collection.
	# Channel format (Appwrite): databases.{databaseId}.collections.{collectionId}.documents
	var channel := "databases.%s.collections.%s.documents" % [database_id, table_id]
	print("Subscribing to channel: ", channel)

	_received = false
	_last_message = {}
	var sub_id: int = realtime.subscribe([channel], Callable(self, "_on_realtime_message"))
	if sub_id < 0:
		print("❌ Failed to subscribe.")
		print("--- Test Finished ---")
		_finish(false, false, {"error": "Subscribe failed"})
		return

	# Wait for the websocket to actually open before triggering events.
	var connect_deadline_ms := Time.get_ticks_msec() + int(connect_wait_seconds * 1000.0)
	while not realtime.get_connected() and Time.get_ticks_msec() < connect_deadline_ms:
		await get_tree().process_frame
	if not realtime.get_connected():
		print("❌ Realtime did not connect within timeout.")
		realtime.unsubscribe(sub_id)
		realtime.disconnect_now()
		print("--- Test Finished ---")
		_finish(false, false, {"error": "Realtime connect timeout", "timeout_seconds": connect_wait_seconds})
		return

	print("Creating document to trigger realtime...")
	randomize()
	var doc_data := {
		"userId": my_user_id
	}
	var created := await Appwrite.databases.create_document(database_id, table_id, "unique()", doc_data)
	if int(created.get("status_code", 0)) != 201:
		print("❌ FAILED create document.")
		print("Status Code: ", created.get("status_code", 0))
		print("Error: ", created.get("data", {}))
		realtime.unsubscribe(sub_id)
		print("--- Test Finished ---")
		_finish(false, false, {"error": created.get("data", {})})
		return

	var created_data: Variant = created.get("data")
	var created_dict: Dictionary = created_data if typeof(created_data) == TYPE_DICTIONARY else {}
	var doc_id := str(created_dict.get("$id", ""))
	print("✅ Document created: ", doc_id)

	var wait_full_raw := OS.get_environment("APPWRITE_REALTIME_WAIT_FULL").strip_edges().to_lower()
	var wait_full := wait_full_raw == "true" or wait_full_raw == "1" or wait_full_raw == "yes" or wait_full_raw == "y"
	print("Waiting up to ", wait_seconds, "s for realtime event... (wait_full=", wait_full, ")")
	var start_ms := Time.get_ticks_msec()
	while ((not _received) or wait_full) and (Time.get_ticks_msec() - start_ms) < int(wait_seconds * 1000.0):
		await get_tree().process_frame

	realtime.unsubscribe(sub_id)
	# Keep connection alive if other subs exist; for the test, disconnect.
	realtime.disconnect_now()

	# Cleanup document.
	if not doc_id.is_empty():
		await Appwrite.databases.delete_document(database_id, table_id, doc_id)

	if not _received:
		print("⚠️ No realtime message received within timeout.")
		print("--- Test Finished ---")
		_finish(false, false, {"error": "No realtime event received", "timeout_seconds": wait_seconds})
		return

	print("--- Test Finished ---")
	_finish(true, false, {"last_message": _last_message})
