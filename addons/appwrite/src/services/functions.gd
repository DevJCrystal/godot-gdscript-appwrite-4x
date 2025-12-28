class_name AppwriteFunctions
extends RefCounted

## The Functions service lets you execute Appwrite Functions from a client.
## This is the recommended way to do privileged operations without embedding an API key.

var _client: AppwriteClient

func _init(client: AppwriteClient):
	_client = client


## Create a function execution.
##
## Parameters map to Appwrite's REST API:
## POST /functions/{functionId}/executions
##
## - function_id: Function ID
## - body: Arbitrary payload (String/Dictionary/etc). If Dictionary/Array, it's JSON encoded.
## - async_execution: If true, server queues execution.
## - path/method/headers: Optional HTTP request override (for functions that act as HTTP handlers).
func create_execution(
	function_id: String,
	body: Variant = null,
	async_execution: bool = false,
	path: String = "",
	method: String = "",
	headers: Dictionary = {}
) -> Dictionary:
	var api_path := "/functions/%s/executions" % function_id

	var payload: Dictionary = {
		"async": async_execution
	}

	if body != null:
		if typeof(body) == TYPE_STRING:
			payload["body"] = body
		else:
			payload["body"] = JSON.stringify(body)

	if not path.is_empty():
		payload["path"] = path
	if not method.is_empty():
		payload["method"] = method
	if not headers.is_empty():
		payload["headers"] = headers

	return await _client.call_api(HTTPClient.METHOD_POST, api_path, {}, payload)


## Get a single execution.
func get_execution(function_id: String, execution_id: String) -> Dictionary:
	var api_path := "/functions/%s/executions/%s" % [function_id, execution_id]
	return await _client.call_api(HTTPClient.METHOD_GET, api_path)


## List executions for a function.
func list_executions(function_id: String, queries: Array = []) -> Dictionary:
	var api_path := "/functions/%s/executions" % function_id
	api_path = _with_queries(api_path, queries)
	return await _client.call_api(HTTPClient.METHOD_GET, api_path)


## Poll an execution until it reaches a terminal state.
##
## Returns the final `get_execution()` response (status_code 200 on success).
## If the timeout is hit, returns the latest response with `timeout=true`.
func wait_for_execution(
	function_id: String,
	execution_id: String,
	timeout_ms: int = 60_000,
	poll_interval_ms: int = 400
) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + maxi(timeout_ms, 0)
	var last_resp: Dictionary = {}

	while true:
		last_resp = await get_execution(function_id, execution_id)
		if last_resp.get("status_code", 0) != 200:
			return last_resp

		var status := str(last_resp.get("data", {}).get("status", ""))
		if status == "completed" or status == "failed" or status == "canceled":
			return last_resp

		if timeout_ms >= 0 and Time.get_ticks_msec() >= deadline:
			last_resp["timeout"] = true
			return last_resp

		# Yield before polling again.
		await _client.get_tree().create_timer(float(poll_interval_ms) / 1000.0).timeout

	# Unreachable, but keeps the parser happy.
	return last_resp


func _with_queries(path: String, queries: Array) -> String:
	if queries.is_empty():
		return path
	var sep := "?"
	var out := path
	for q in queries:
		out += "%squeries[]=%s" % [sep, str(q).uri_encode()]
		sep = "&"
	return out
