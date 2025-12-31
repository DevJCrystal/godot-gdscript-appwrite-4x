class_name AppwriteRealtime
extends Node

signal connected
signal disconnected(code: int, reason: String)
signal message_received(message: Dictionary)

var _client: AppwriteClient
var _ws: WebSocketPeer = null
var _was_open := false

var _debug := false

# subscription_id -> { "channels": Array[String], "callback": Callable }
var _subscriptions: Dictionary = {}
var _next_subscription_id := 1

var _desired_channels: Array[String] = []
var _pending_reconnect := false

var _auth_sent := false
var _last_ping_ms := 0
var _last_ready_state := -1

func _init(client: AppwriteClient) -> void:
	_client = client

func set_debug(enabled: bool) -> AppwriteRealtime:
	_debug = enabled
	return self

func subscribe(channels: Array[String], callback: Callable = Callable()) -> int:
	var normalized := _normalize_channels(channels)
	if normalized.is_empty():
		push_warning("AppwriteRealtime.subscribe: channels is empty")
		return -1

	var id := _next_subscription_id
	_next_subscription_id += 1

	_subscriptions[id] = {
		"channels": normalized,
		"callback": callback
	}

	_schedule_reconnect()
	return id

func unsubscribe(subscription_id: int) -> void:
	if _subscriptions.has(subscription_id):
		_subscriptions.erase(subscription_id)
		_schedule_reconnect()

func clear_subscriptions() -> void:
	_subscriptions.clear()
	_schedule_reconnect()

func connect_now() -> void:
	# Connect with whatever channels are currently subscribed.
	_schedule_reconnect(true)

func disconnect_now() -> void:
	_pending_reconnect = false
	_desired_channels = []
	_auth_sent = false
	_close_socket()

func get_connected() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN

func _process(_delta: float) -> void:
	if _ws == null:
		# If subscriptions changed while disconnected, reconnect.
		if _pending_reconnect:
			_pending_reconnect = false
			_connect_for_desired_channels()
		return

	_ws.poll()

	var state := _ws.get_ready_state()
	if _debug and state != _last_ready_state:
		_last_ready_state = state
		print("AppwriteRealtime: ws state=", state)
	if state == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			if _debug:
				print("AppwriteRealtime: connected")
			emit_signal("connected")
			_last_ping_ms = Time.get_ticks_msec()
			# Do not proactively authenticate on raw WS open.
			# Appwrite expects authentication (if needed) after its protocol "connected" frame.

		# Appwrite Web SDK sends a JSON ping every 20s: {type:"ping"}
		# (in addition to any TCP/WebSocket keepalives).
		var now_ms := Time.get_ticks_msec()
		if now_ms - _last_ping_ms >= 20_000:
			var err_ping := _ws.send_text('{"type":"ping"}')
			if _debug:
				print("AppwriteRealtime: sent ping err=", err_ping)
			_last_ping_ms = now_ms

		while _ws.get_available_packet_count() > 0:
			var packet := _ws.get_packet()
			var text := packet.get_string_from_utf8()
			var msg := _parse_json_dict(text)
			_handle_message(msg)

	elif state == WebSocketPeer.STATE_CLOSED:
		var code := _ws.get_close_code()
		var reason := _ws.get_close_reason()
		if _debug:
			print("AppwriteRealtime: closed code=", code, " reason=", reason)

		var should_emit := _was_open
		_ws = null
		_was_open = false
		_auth_sent = false
		_last_ready_state = -1

		if should_emit:
			emit_signal("disconnected", code, reason)

		# If we closed due to a subscription change, reconnect.
		if _pending_reconnect:
			_pending_reconnect = false
			_connect_for_desired_channels()

	# else CONNECTING/CLOSING: do nothing


func _dispatch(message: Dictionary) -> void:
	# Appwrite realtime messages generally include: {events:[], channels:[], timestamp:"...", payload:{...}}
	var msg_channels: Array[String] = []
	var raw_channels: Variant = message.get("channels", [])
	if typeof(raw_channels) == TYPE_ARRAY:
		for c in raw_channels:
			msg_channels.append(str(c))

	for id in _subscriptions.keys():
		var sub: Variant = _subscriptions[id]
		if typeof(sub) != TYPE_DICTIONARY:
			continue
		var s := sub as Dictionary
		var sub_channels: Array[String] = s.get("channels", [])
		if not _intersects(sub_channels, msg_channels):
			continue

		var cb: Callable = s.get("callback", Callable())
		if cb.is_valid():
			cb.call(message)


func _schedule_reconnect(force: bool = false) -> void:
	_desired_channels = _compute_desired_channels()

	# If no channels, just disconnect.
	if _desired_channels.is_empty():
		disconnect_now()
		return

	# If already connected for the same channels, nothing to do.
	if not force and _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		# We don't know which channels the server has without protocol support,
		# so we simply reconnect whenever the subscription set changes.
		pass

	_pending_reconnect = true
	# Closing triggers reconnect in _process().
	if _ws != null:
		_close_socket()


func _connect_for_desired_channels() -> void:
	if _desired_channels.is_empty():
		return

	var url := _build_realtime_url(_desired_channels)
	if url.is_empty():
		push_warning("AppwriteRealtime: missing endpoint/project id; cannot connect")
		return

	var headers := _build_ws_headers()
	var tls := _build_tls_options(url)

	_ws = WebSocketPeer.new()
	_was_open = false
	_auth_sent = false
	# Keep the connection alive on servers that expect periodic pings.
	_ws.heartbeat_interval = 25.0
	_ws.handshake_headers = headers

	if _debug:
		print("AppwriteRealtime: connecting url=", url)
		print("AppwriteRealtime: headers=", headers)

	# Godot 4.x: set `handshake_headers` first, then call connect_to_url(url, tls_options).
	var err := _ws.connect_to_url(url, tls)
	if err != OK:
		_ws = null
		push_warning("AppwriteRealtime: connect_to_url failed (error %d)" % err)


func _close_socket() -> void:
	if _ws == null:
		return
	# 1000 = normal closure
	_ws.close(1000, "client_disconnect")


func _build_realtime_url(channels: Array[String]) -> String:
	var endpoint := str(_client._endpoint)
	if endpoint.is_empty():
		return ""
	var project := str(_client._project_id)
	if project.is_empty():
		return ""

	var base := endpoint
	if base.begins_with("https://"):
		base = "wss://" + base.substr("https://".length())
	elif base.begins_with("http://"):
		base = "ws://" + base.substr("http://".length())

	var url := base + "/realtime?project=" + project.uri_encode()
	# Match Web SDK behavior: URLSearchParams encodes `channels[]` as `channels%5B%5D`.
	for ch in channels:
		url += "&channels%5B%5D=" + str(ch).uri_encode()
	return url


func _build_ws_headers() -> PackedStringArray:
	var out := PackedStringArray()

	# Appwrite may validate WebSocket Origin against Project Platforms.
	# For native clients (Godot), it's usually safest to omit Origin entirely.
	# If you need it, set APPWRITE_REALTIME_ORIGIN (e.g. "https://your-game.example").
	var origin := OS.get_environment("APPWRITE_REALTIME_ORIGIN").strip_edges()
	if not origin.is_empty():
		out.append("Origin: " + origin)

	# Project header is harmless even though project is also in query.
	var project := str(_client._project_id)
	if not project.is_empty():
		out.append("X-Appwrite-Project: " + project)

	# API key support (opt-in via client).
	var api_key := str(_client._api_key)
	if not api_key.is_empty():
		out.append("X-Appwrite-Key: " + api_key)

	# Response format header keeps server consistent with the REST calls.
	if _client._headers.has("X-Appwrite-Response-Format"):
		out.append("X-Appwrite-Response-Format: " + str(_client._headers["X-Appwrite-Response-Format"]))

	# Session auth via cookie jar.
	var cookie := ""
	if _client.has_method("_build_cookie_header"):
		cookie = str(_client._build_cookie_header())
	if not cookie.is_empty():
		out.append("Cookie: " + cookie)

	return out


func _handle_message(msg: Dictionary) -> void:
	# Appwrite realtime frames are wrapped:
	#   { type: "connected"|"event"|"error"|"pong"|..., data: ... }
	# Events you care about are under `data` when type == "event".
	if _debug:
		print("AppwriteRealtime: message=", msg)

	var t := str(msg.get("type", ""))
	if t.is_empty():
		# Some setups may send raw event objects.
		emit_signal("message_received", msg)
		_dispatch(msg)
		return

	match t:
		"connected":
			emit_signal("message_received", msg)
			_try_send_authentication(msg)
			return
		"event":
			var data: Variant = msg.get("data")
			if typeof(data) == TYPE_DICTIONARY:
				var event_msg := (data as Dictionary).duplicate()
				event_msg["type"] = "event"
				emit_signal("message_received", event_msg)
				_dispatch(event_msg)
			else:
				emit_signal("message_received", msg)
			return
		"pong":
			emit_signal("message_received", msg)
			return
		"error":
			if _debug:
				push_warning("AppwriteRealtime: server error frame: %s" % [str(msg)])
			emit_signal("message_received", msg)
			return
		_:
			emit_signal("message_received", msg)
			return


func _try_send_authentication(connected_msg: Dictionary) -> void:
	# Mirrors Appwrite Web SDK behavior: on "connected", if server didn't attach a user,
	# send {type:"authentication", data:{session:"..."}} using cookie a_session_<projectId>.
	if _auth_sent:
		return
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	# Only authenticate in response to the Appwrite protocol "connected" frame.
	if connected_msg.is_empty():
		return

	var project := str(_client._project_id)
	if project.is_empty():
		return

	# Only send auth if server says user is missing.
	var data: Variant = connected_msg.get("data")
	if typeof(data) == TYPE_DICTIONARY:
		var d := data as Dictionary
		if d.get("user") != null:
			return

	var cookie_name := "a_session_%s" % project
	var session := ""
	if typeof(_client._cookie_jar) == TYPE_DICTIONARY and _client._cookie_jar.has(cookie_name):
		session = str(_client._cookie_jar[cookie_name])
	if session.is_empty():
		var legacy := cookie_name + "_legacy"
		if typeof(_client._cookie_jar) == TYPE_DICTIONARY and _client._cookie_jar.has(legacy):
			session = str(_client._cookie_jar[legacy])

	if session.is_empty():
		# Guest mode.
		return

	var payload := {
		"type": "authentication",
		"data": {
			"session": session
		}
	}
	var err := _ws.send_text(JSON.stringify(payload))
	if _debug:
		print("AppwriteRealtime: sent authentication err=", err)
	_auth_sent = (err == OK)


func _build_tls_options(url: String) -> TLSOptions:
	if not url.begins_with("wss://"):
		return null

	# Use the same trusted CA behavior as HTTP.
	var host := ""
	if _client.has_method("_extract_hostname"):
		# Convert to https for the parser.
		var https_url := "https://" + url.substr("wss://".length())
		host = str(_client._extract_hostname(https_url))

	if bool(_client._self_signed):
		return TLSOptions.client_unsafe(_client._trusted_ca_chain)

	if host.is_empty():
		return TLSOptions.client(_client._trusted_ca_chain)
	return TLSOptions.client(_client._trusted_ca_chain, host)


func _compute_desired_channels() -> Array[String]:
	var set := {}
	for id in _subscriptions.keys():
		var sub: Variant = _subscriptions[id]
		if typeof(sub) != TYPE_DICTIONARY:
			continue
		var channels: Array[String] = (sub as Dictionary).get("channels", [])
		for ch in channels:
			var c := str(ch)
			if not c.is_empty():
				set[c] = true

	var out: Array[String] = []
	for k in set.keys():
		out.append(str(k))
	out.sort()
	return out


func _normalize_channels(channels: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for ch in channels:
		var c := str(ch).strip_edges()
		if c.is_empty():
			continue
		out.append(c)
	# Remove dups
	var set := {}
	for c in out:
		set[c] = true
	out = []
	for k in set.keys():
		out.append(str(k))
	out.sort()
	return out


func _intersects(a: Array[String], b: Array[String]) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	var set := {}
	for x in a:
		set[str(x)] = true
	for y in b:
		if set.has(str(y)):
			return true
	return false


func _parse_json_dict(text: String) -> Dictionary:
	if text.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"raw": text}
	if typeof(json.data) == TYPE_DICTIONARY:
		return json.data as Dictionary
	return {"data": json.data}
