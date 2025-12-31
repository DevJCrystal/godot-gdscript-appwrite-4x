class_name AppwriteClient
extends Node

# Services
var account: AppwriteAccount
var functions: AppwriteFunctions
var databases: AppwriteDatabases
var storage: AppwriteStorage
var realtime: AppwriteRealtime

## Appwrite client: configuration + HTTP wrapper.

# Configuration
var _project_id: String = ""
var _endpoint: String = "https://cloud.appwrite.io/v1"
var _api_key: String = ""
var _self_signed: bool = false

var _debug_http: bool = false
var _trusted_ca_chain: X509Certificate = null
var _cookie_jar: Dictionary = {}
var _persist_session: bool = false

# Default Headers
var _headers: Dictionary = {
	"Content-Type": "application/json",
	"X-Appwrite-Response-Format": "1.8.0"
}

func _ready():
	# Load .env (optional)
	EnvLoader.load_env("res://.env")
	
	# Read environment variables
	var env_endpoint = OS.get_environment("APPWRITE_ENDPOINT")
	var env_project = OS.get_environment("APPWRITE_PROJECT_ID")
	var env_key = OS.get_environment("APPWRITE_KEY")
	var env_enable_key = OS.get_environment("APPWRITE_ENABLE_API_KEY")
	var env_self_signed = OS.get_environment("APPWRITE_SELF_SIGNED")
	var env_persist_session = OS.get_environment("APPWRITE_DEBUG_PERSIST_SESSION")
	var env_debug_http = OS.get_environment("APPWRITE_DEBUG_HTTP")

	# Apply overrides (if set)
	if not env_endpoint.is_empty():
		set_endpoint(env_endpoint.strip_edges())
		
	if not env_project.is_empty():
		set_project(env_project.strip_edges())

	# API keys are intentionally opt-in (client-safe by default).
	# If you really want to use X-Appwrite-Key (server-side tooling), set:
	#   APPWRITE_ENABLE_API_KEY=true
	var clean_enable_key := env_enable_key.strip_edges().to_lower()
	var enable_key := clean_enable_key == "true" or clean_enable_key == "1" or clean_enable_key == "yes" or clean_enable_key == "y"
	if enable_key and not env_key.is_empty():
		set_key(env_key.strip_edges())

	# Parse APPWRITE_SELF_SIGNED as a bool ("true"/"1")
	var clean_signed = env_self_signed.strip_edges().to_lower()
	if clean_signed == "true" or clean_signed == "1":
		set_self_signed(true)
	else:
		set_self_signed(false)

	# Optional: Persist session cookies between runs for debugging.
	# This reduces repeated logins (and rate limiting) while iterating.
	var clean_persist = env_persist_session.strip_edges().to_lower()
	_persist_session = clean_persist == "true" or clean_persist == "1"
	var clean_debug = env_debug_http.strip_edges().to_lower()
	_debug_http = clean_debug == "true" or clean_debug == "1"
	
	# Log effective configuration (useful while wiring up env vars)
	print("--- DEBUG CONFIGURATION ---")
	print("Endpoint (Applied): ", _endpoint)
	print("Project ID (Applied): ", _project_id)
	print("Self Signed Mode: ", _self_signed)
	print("Persist Session: ", _persist_session)
	print("Debug HTTP: ", _debug_http)
	if enable_key and not _api_key.is_empty():
		print("API Key: enabled (X-Appwrite-Key will be sent)")
	elif not env_key.is_empty():
		print("API Key: present but ignored (set APPWRITE_ENABLE_API_KEY=true to enable)")
	else:
		print("API Key: disabled")
	print("---------------------------")

	# Ensure HTTPS can validate certificates on platforms where Godot
	# doesn't automatically use the OS trust store.
	_ensure_trusted_ca_configured()

	# Load a persisted cookie jar (if enabled) before any API calls.
	_load_persisted_cookies()
	
	# Initialize services
	account = AppwriteAccount.new(self)
	functions = AppwriteFunctions.new(self)
	databases = AppwriteDatabases.new(self)
	storage = AppwriteStorage.new(self)

	# Realtime is a Node (WebSocket poll loop), so keep it as a child.
	realtime = AppwriteRealtime.new(self)
	add_child(realtime)


func _ensure_trusted_ca_configured() -> void:
	# Only relevant for strict TLS.
	if _self_signed:
		return

	# Load trusted system CAs into an X509Certificate and use it for TLSOptions.
	# This is more reliable than relying on ProjectSettings in runtime.
	if OS.has_method("get_system_ca_certificates"):
		var pem_bundle: String = OS.get_system_ca_certificates()
		if not pem_bundle.is_empty():
			var ca := X509Certificate.new()
			var err := ca.load_from_string(pem_bundle)
			if err == OK:
				_trusted_ca_chain = ca
			else:
				_trusted_ca_chain = null
				push_warning("Appwrite: Failed to parse system CA bundle (error %d)." % err)
		else:
			push_warning("Appwrite: OS returned empty CA bundle; HTTPS may fail.")
	else:
		push_warning("Appwrite: OS.get_system_ca_certificates() not available; HTTPS may fail.")

# -------------------------------------------------------------------------
# Configuration Methods
# -------------------------------------------------------------------------

func set_project(id: String) -> AppwriteClient:
	_project_id = id
	_headers["X-Appwrite-Project"] = _project_id
	return self

func set_endpoint(url: String) -> AppwriteClient:
	_endpoint = url
	return self

func set_key(key: String) -> AppwriteClient:
	_api_key = key
	_headers["X-Appwrite-Key"] = _api_key
	return self

func set_self_signed(status: bool) -> AppwriteClient:
	_self_signed = status
	return self

# -------------------------------------------------------------------------
# Request Handling
# -------------------------------------------------------------------------

## Generic method to make an HTTP request to the Appwrite API.
## Returns a Dictionary with "status_code" (int) and "data" (Variant).
func call_api(method: HTTPClient.Method, path: String, headers: Dictionary = {}, body: Variant = null) -> Dictionary:
	# Create a one-off HTTPRequest for this call
	var http = HTTPRequest.new()
	add_child(http)
	
	# Wait for the node to be ready in the scene tree
	await get_tree().process_frame
	
	# Merge default headers with request-specific headers
	var request_headers = _headers.duplicate()
	for key in headers:
		request_headers[key] = headers[key]

	# Automatically attach cookies (sessions) unless the caller explicitly overrides.
	if not request_headers.has("Cookie"):
		var cookie_header := _build_cookie_header()
		if not cookie_header.is_empty():
			request_headers["Cookie"] = cookie_header
	
	# Convert dictionary to PackedStringArray for Godot's HTTPRequest
	var header_array = PackedStringArray()
	for key in request_headers:
		header_array.append(key + ": " + request_headers[key])

	# Request body
	var json_body := ""
	var raw_body: PackedByteArray = PackedByteArray()
	var use_raw_body := false
	if body != null:
		if typeof(body) == TYPE_PACKED_BYTE_ARRAY:
			use_raw_body = true
			raw_body = body as PackedByteArray
		else:
			json_body = JSON.stringify(body)

	# Full URL
	var full_url := _endpoint + path
	# TLS/SNI: Appwrite Cloud endpoints sit behind a CDN and require SNI to route to
	# the correct certificate. `common_name_override` makes TLS validation use the
	# expected hostname (and triggers SNI in Godot).
	if full_url.begins_with("https://"):
		var host_for_tls := _extract_hostname(full_url)
		if _self_signed:
			http.set_tls_options(TLSOptions.client_unsafe(_trusted_ca_chain))
		else:
			if host_for_tls.is_empty():
				http.set_tls_options(TLSOptions.client(_trusted_ca_chain))
			else:
				http.set_tls_options(TLSOptions.client(_trusted_ca_chain, host_for_tls))
	
	if _debug_http:
		print("DEBUG: Making request to: ", full_url)
		if full_url.begins_with("https://"):
			print("DEBUG: TLS host override: ", _extract_hostname(full_url))
		print("DEBUG: Headers: ", header_array)
		if use_raw_body:
			print("DEBUG: Body bytes=", raw_body.size())
		else:
			print("DEBUG: Body: ", json_body)
	
	var error := OK
	if use_raw_body:
		error = http.request_raw(full_url, header_array, method, raw_body)
	else:
		error = http.request(full_url, header_array, method, json_body)
	
	if error != OK:
		http.queue_free()
		return {"status_code": 0, "data": "Internal Error: HTTP Request failed to start."}
	# Await response
	# response is [result, response_code, headers, body]
	var response = await http.request_completed
	
	var result = response[0]
	var response_code = response[1]
	var response_headers = response[2]
	var response_body = response[3]

	# Update cookie jar from response headers (even for non-2xx responses).
	_update_cookie_jar_from_headers(response_headers)
	_save_persisted_cookies()
	
	# Check if the request completed successfully
	if result != HTTPRequest.RESULT_SUCCESS:
		var error_messages = {
			HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: "Chunked body size mismatch",
			HTTPRequest.RESULT_CANT_CONNECT: "Can't connect to host",
			HTTPRequest.RESULT_CANT_RESOLVE: "Can't resolve hostname",
			HTTPRequest.RESULT_CONNECTION_ERROR: "Connection error",
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: "TLS handshake error",
			HTTPRequest.RESULT_NO_RESPONSE: "No response from server",
			HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: "Body size limit exceeded",
			HTTPRequest.RESULT_REQUEST_FAILED: "Request failed",
			HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: "Download file can't open",
			HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: "Download file write error",
			HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: "Redirect limit reached",
			HTTPRequest.RESULT_TIMEOUT: "Request timeout"
		}
		var error_msg = error_messages.get(result, "Unknown error (code: %d)" % result)
		http.queue_free()
		return {"status_code": 0, "data": error_msg}
	
	# Parse result
	var result_data: Variant = null
	var content_type := _get_header_value(response_headers, "content-type")
	var is_json := _is_json_content_type(content_type)
	var is_text := _is_text_content_type(content_type)

	# If server didn't provide content-type, keep the old behavior and attempt JSON parse.
	if content_type.is_empty() or is_json:
		var json = JSON.new()
		var parse_result = json.parse(response_body.get_string_from_utf8())
		if parse_result == OK:
			result_data = json.data
		else:
			# Fallback if response isn't JSON (e.g. empty 204 response)
			result_data = response_body.get_string_from_utf8()
	elif is_text:
		result_data = response_body.get_string_from_utf8()
	else:
		# Binary payload (downloads). Callers should use `body_bytes`.
		result_data = ""
	
	# Clean up the node
	http.queue_free()
	
	return {
		"status_code": response_code,
		"headers": response_headers,
		"body_bytes": response_body,
		"data": result_data
	}


func clear_cookies() -> void:
	_cookie_jar.clear()
	_clear_persisted_cookies()


func _cookie_storage_path() -> String:
	# Keep it stable across runs but distinct per project + endpoint host.
	var host := _extract_hostname(_endpoint)
	if host.is_empty():
		host = "unknown_host"
	var proj := _project_id
	if proj.is_empty():
		proj = "unknown_project"
	# Sanitize for filename.
	var safe_host := host.replace(".", "_").replace(":", "_")
	var safe_proj := proj.replace(".", "_").replace(":", "_")
	return "user://appwrite_cookies_%s_%s.json" % [safe_proj, safe_host]


func _load_persisted_cookies() -> void:
	if not _persist_session:
		return
	var path := _cookie_storage_path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	if typeof(json.data) != TYPE_DICTIONARY:
		return
	_cookie_jar = json.data


func _save_persisted_cookies() -> void:
	if not _persist_session:
		return
	# If jar is empty, don't create/overwrite the file.
	if _cookie_jar.is_empty():
		return
	var path := _cookie_storage_path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_cookie_jar))


func _clear_persisted_cookies() -> void:
	if not _persist_session:
		return
	var path := _cookie_storage_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _build_cookie_header() -> String:
	if _cookie_jar.is_empty():
		return ""
	var parts: Array[String] = []
	for name in _cookie_jar.keys():
		var value = str(_cookie_jar[name])
		if not name.is_empty() and not value.is_empty():
			parts.append("%s=%s" % [name, value])
	return "; ".join(parts)


func _update_cookie_jar_from_headers(response_headers: PackedStringArray) -> void:
	# Godot returns raw header lines, e.g. "Set-Cookie: a=b; Path=/; HttpOnly".
	# We only store cookie name/value pairs.
	for header_line in response_headers:
		var line := str(header_line)
		if not line.to_lower().begins_with("set-cookie:"):
			continue
		var value_part := line.substr(line.find(":") + 1).strip_edges()
		if value_part.is_empty():
			continue
		# First segment is "name=value".
		var first_segment := value_part.split(";", false, 1)[0].strip_edges()
		var eq_idx := first_segment.find("=")
		if eq_idx <= 0:
			continue
		var cookie_name := first_segment.substr(0, eq_idx).strip_edges()
		var cookie_value := first_segment.substr(eq_idx + 1).strip_edges()
		if cookie_name.is_empty():
			continue
		# If server clears cookie, remove it.
		var lower := value_part.to_lower()
		var should_remove := cookie_value.is_empty() or lower.find("max-age=0") != -1 or lower.find("expires=thu, 01 jan 1970") != -1
		if should_remove:
			_cookie_jar.erase(cookie_name)
		else:
			_cookie_jar[cookie_name] = cookie_value


func _extract_hostname(url: String) -> String:
	# Minimal URL hostname parser.
	# Examples:
	# - https://nyc.cloud.appwrite.io/v1 -> nyc.cloud.appwrite.io
	# - http://localhost:8080/v1 -> localhost
	var start := url.find("://")
	if start == -1:
		return ""
	start += 3
	var end := url.find("/", start)
	var authority := url.substr(start, (end - start) if end != -1 else (url.length() - start))
	if authority.is_empty():
		return ""
	# Strip userinfo if present
	var at_idx := authority.rfind("@")
	if at_idx != -1:
		authority = authority.substr(at_idx + 1)
	# Strip port if present (ignore IPv6 for now)
	var colon_idx := authority.find(":")
	if colon_idx != -1:
		return authority.substr(0, colon_idx)
	return authority


func _get_header_value(headers: PackedStringArray, name_lower: String) -> String:
	# Headers arrive as raw lines, e.g. "Content-Type: application/json".
	# Returns the first matching value, lower/upper case-insensitive.
	for header_line in headers:
		var line := str(header_line)
		var idx := line.find(":")
		if idx <= 0:
			continue
		var key := line.substr(0, idx).strip_edges().to_lower()
		if key != name_lower:
			continue
		return line.substr(idx + 1).strip_edges()
	return ""


func _is_json_content_type(content_type: String) -> bool:
	if content_type.is_empty():
		return false
	var ct := content_type.to_lower()
	if ct.find("application/json") != -1 or ct.find("text/json") != -1:
		return true
	# e.g. application/problem+json
	return ct.find("+json") != -1


func _is_text_content_type(content_type: String) -> bool:
	if content_type.is_empty():
		return false
	var ct := content_type.to_lower()
	return ct.begins_with("text/")
