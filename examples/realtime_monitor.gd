extends Node

const Helpers := preload("res://tests/test_helpers.gd")

# A tiny “watch a collection in realtime” scene.
# Use either:
# - APPWRITE_REALTIME_CHANNEL (full channel string), OR
# - APPWRITE_DATABASE_ID + APPWRITE_TABLE_ID (collection)

var _sub_id: int = -1
var _realtime: AppwriteRealtime = null

func _ready() -> void:
	print("--- Realtime Monitor ---")

	# Optional auth (recommended for DB realtime).
	var auth_email := OS.get_environment("APPWRITE_TEST_EMAIL").strip_edges()
	var auth_password := OS.get_environment("APPWRITE_TEST_PASSWORD").strip_edges()
	if not auth_email.is_empty() and not auth_password.is_empty():
		print("Authenticating (reuse session if available)...")
		var auth := await Helpers.ensure_logged_in()
		if not bool(auth.get("ok", false)):
			printerr("Auth failed: ", auth.get("error", {}))
		else:
			print("✅ Authenticated. Reused session=", auth.get("reused", false))
	else:
		print("No APPWRITE_TEST_EMAIL/PASSWORD set; attempting realtime without login.")

	_realtime = Appwrite.get("realtime") as AppwriteRealtime
	if _realtime == null:
		printerr("Appwrite.realtime is not available. Is the plugin enabled?")
		return

	# Listen to everything (handy while diagnosing).
	if _realtime.has_signal("connected"):
		_realtime.connect("connected", Callable(self, "_on_connected"))
	if _realtime.has_signal("disconnected"):
		_realtime.connect("disconnected", Callable(self, "_on_disconnected"))

	var channel := _compute_channel()
	if channel.is_empty():
		printerr("Missing channel configuration.")
		printerr("Set APPWRITE_REALTIME_CHANNEL=... OR APPWRITE_DATABASE_ID + APPWRITE_TABLE_ID")
		return

	print("Subscribing to: ", channel)
	_sub_id = _realtime.subscribe([channel], Callable(self, "_on_message"))
	if _sub_id < 0:
		printerr("Subscribe failed")	
		return

	print("Waiting for events... (make changes in Appwrite Console to see messages)")


func _exit_tree() -> void:
	if _sub_id >= 0 and _realtime != null:
		_realtime.unsubscribe(_sub_id)
		# Do not force a global disconnect here.
		# In a real game you may have multiple subscriptions (lobby, match, chat).
		# If this was the last subscription, the realtime service will close on its own.


func _on_connected() -> void:
	print("Realtime connected")


func _on_disconnected(code: int, reason: String) -> void:
	print("Realtime disconnected code=", code, " reason=", reason)


func _on_message(msg: Dictionary) -> void:
	# Typical Appwrite message keys: events, channels, timestamp, payload
	var events: Array[String] = []
	var raw_events: Variant = msg.get("events", [])
	if typeof(raw_events) == TYPE_ARRAY:
		for e in raw_events:
			events.append(str(e))

	var channels: Array[String] = []
	var raw_channels: Variant = msg.get("channels", [])
	if typeof(raw_channels) == TYPE_ARRAY:
		for c in raw_channels:
			channels.append(str(c))

	var payload: Variant = msg.get("payload")
	var payload_keys: Array[String] = []
	if typeof(payload) == TYPE_DICTIONARY:
		for k in (payload as Dictionary).keys():
			payload_keys.append(str(k))
		payload_keys.sort()

	print("Realtime events=", events)
	print("Realtime channels=", channels)
	if not payload_keys.is_empty():
		print("Payload keys=", payload_keys)
	else:
		print("Realtime message: ", msg)


func _compute_channel() -> String:
	var explicit := OS.get_environment("APPWRITE_REALTIME_CHANNEL").strip_edges()
	if not explicit.is_empty():
		return explicit

	var database_id := OS.get_environment("APPWRITE_DATABASE_ID").strip_edges()
	var table_id := OS.get_environment("APPWRITE_TABLE_ID").strip_edges()
	if database_id.is_empty() or table_id.is_empty():
		return ""

	return "databases.%s.collections.%s.documents" % [database_id, table_id]
