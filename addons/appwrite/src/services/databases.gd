class_name AppwriteDatabases
extends RefCounted

## The Databases service lets authenticated clients create and read documents
## they have permissions for (no API key needed).

var _client: AppwriteClient

func _init(client: AppwriteClient):
	_client = client


# -------------------------------------------------------------------------
# Databases
# -------------------------------------------------------------------------

func list_databases(queries: Array = []) -> Dictionary:
	var path := "/databases"
	path = _with_queries(path, queries)
	return await _client.call_api(HTTPClient.METHOD_GET, path)

func get_database(database_id: String) -> Dictionary:
	var path := "/databases/%s" % database_id
	return await _client.call_api(HTTPClient.METHOD_GET, path)


# -------------------------------------------------------------------------
# Tables (Appwrite Console terminology)
# Appwrite REST routes still use "/collections".
# -------------------------------------------------------------------------

func list_tables(database_id: String, queries: Array = []) -> Dictionary:
	var path := "/databases/%s/collections" % database_id
	path = _with_queries(path, queries)
	return await _client.call_api(HTTPClient.METHOD_GET, path)

func get_table(database_id: String, table_id: String) -> Dictionary:
	var path := "/databases/%s/collections/%s" % [database_id, table_id]
	return await _client.call_api(HTTPClient.METHOD_GET, path)


# -------------------------------------------------------------------------
# Documents
# -------------------------------------------------------------------------

## Create a document.
## - document_id: use "unique()" to let Appwrite generate.
## - data: Dictionary/Array is sent as JSON.
## - permissions: array of permission strings (optional). If omitted, collection defaults apply.
func create_document(
	database_id: String,
	table_id: String,
	document_id: String,
	data: Dictionary,
	permissions: Array[String] = []
) -> Dictionary:
	var path := "/databases/%s/collections/%s/documents" % [database_id, table_id]
	var payload: Dictionary = {
		"documentId": document_id,
		"data": data
	}
	if permissions.size() > 0:
		payload["permissions"] = permissions
	return await _client.call_api(HTTPClient.METHOD_POST, path, {}, payload)


## List documents the current user has access to.
## If queries are provided, Appwrite will apply them after permission checks.
func list_documents(database_id: String, table_id: String, queries: Array = []) -> Dictionary:
	var path := "/databases/%s/collections/%s/documents" % [database_id, table_id]
	if queries.is_empty():
		return await _client.call_api(HTTPClient.METHOD_GET, path)

	# Appwrite v1.8 query strings are JSON and must be URL-encoded.
	return await _client.call_api(HTTPClient.METHOD_GET, _with_queries_encoded(path, queries))


func get_document(database_id: String, table_id: String, document_id: String) -> Dictionary:
	var path := "/databases/%s/collections/%s/documents/%s" % [database_id, table_id, document_id]
	return await _client.call_api(HTTPClient.METHOD_GET, path)


func update_document(
	database_id: String,
	table_id: String,
	document_id: String,
	data: Dictionary,
	permissions: Array[String] = []
) -> Dictionary:
	var path := "/databases/%s/collections/%s/documents/%s" % [database_id, table_id, document_id]
	var payload: Dictionary = {
		"data": data
	}
	if permissions.size() > 0:
		payload["permissions"] = permissions
	return await _client.call_api(HTTPClient.METHOD_PATCH, path, {}, payload)


func delete_document(database_id: String, table_id: String, document_id: String) -> Dictionary:
	var path := "/databases/%s/collections/%s/documents/%s" % [database_id, table_id, document_id]
	return await _client.call_api(HTTPClient.METHOD_DELETE, path)


# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------


func _with_queries(path: String, queries: Array) -> String:
	if queries.is_empty():
		return path
	return _with_queries_encoded(path, queries)


func _with_queries_encoded(path: String, queries: Array) -> String:
	var sep := "?"
	var out := path
	for q in queries:
		out += "%squeries[]=%s" % [sep, str(q).uri_encode()]
		sep = "&"
	return out


func _is_query_syntax_error(resp: Dictionary) -> bool:
	if int(resp.get("status_code", 0)) != 400:
		return false
	var data: Variant = resp.get("data")
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var d := data as Dictionary
	var t := str(d.get("type", ""))
	if t != "general_query_invalid":
		return false
	var msg := str(d.get("message", ""))
	return msg.to_lower().find("syntax") != -1
