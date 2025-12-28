class_name AppwriteStorage
extends RefCounted

## The Storage service lets authenticated clients read/write files they have
## permissions for (no API key needed).
##
## Endpoints (REST): /storage/buckets/{bucketId}/files

var _client: AppwriteClient

func _init(client: AppwriteClient):
	_client = client


# -------------------------------------------------------------------------
# Buckets
# -------------------------------------------------------------------------

func list_buckets(queries: Array = []) -> Dictionary:
	var path := "/storage/buckets"
	path = _with_queries(path, queries)
	return await _client.call_api(HTTPClient.METHOD_GET, path)


func get_bucket(bucket_id: String) -> Dictionary:
	var path := "/storage/buckets/%s" % bucket_id
	return await _client.call_api(HTTPClient.METHOD_GET, path)


# -------------------------------------------------------------------------
# Files
# -------------------------------------------------------------------------

func list_files(bucket_id: String, queries: Array = []) -> Dictionary:
	var path := "/storage/buckets/%s/files" % bucket_id
	path = _with_queries(path, queries)
	return await _client.call_api(HTTPClient.METHOD_GET, path)


func get_file(bucket_id: String, file_id: String) -> Dictionary:
	var path := "/storage/buckets/%s/files/%s" % [bucket_id, file_id]
	return await _client.call_api(HTTPClient.METHOD_GET, path)


func delete_file(bucket_id: String, file_id: String) -> Dictionary:
	var path := "/storage/buckets/%s/files/%s" % [bucket_id, file_id]
	return await _client.call_api(HTTPClient.METHOD_DELETE, path)


## Download file contents.
## Raw bytes are in `body_bytes`.
func download_file(bucket_id: String, file_id: String) -> Dictionary:
	var path := "/storage/buckets/%s/files/%s/download" % [bucket_id, file_id]
	return await _client.call_api(HTTPClient.METHOD_GET, path)


## Upload a file from disk.
func create_file(
	bucket_id: String,
	file_id: String,
	file_path: String,
	permissions: Array[String] = []
) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {"status_code": 0, "data": "File not found: %s" % file_path}

	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return {"status_code": 0, "data": "Failed to open file: %s" % file_path}

	var bytes := f.get_buffer(f.get_length())
	var filename := file_path.get_file()
	return await create_file_from_bytes(bucket_id, file_id, filename, bytes, permissions)


## Upload a file from bytes.
## - file_id: use "unique()" to let Appwrite generate.
## - filename: used as the multipart filename.
func create_file_from_bytes(
	bucket_id: String,
	file_id: String,
	filename: String,
	bytes: PackedByteArray,
	permissions: Array[String] = []
) -> Dictionary:
	var path := "/storage/buckets/%s/files" % bucket_id

	var boundary := _multipart_boundary()
	var body := _multipart_build(boundary, file_id, filename, bytes, permissions)
	var headers := {
		"Content-Type": "multipart/form-data; boundary=%s" % boundary
	}

	return await _client.call_api(HTTPClient.METHOD_POST, path, headers, body)


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


func _multipart_boundary() -> String:
	# Good enough entropy for request-local boundaries.
	return "----GodotAppwriteBoundary%s" % str(Time.get_ticks_usec())


func _multipart_build(
	boundary: String,
	file_id: String,
	filename: String,
	file_bytes: PackedByteArray,
	permissions: Array[String]
) -> PackedByteArray:
	var out := PackedByteArray()

	# Field: fileId
	out.append_array(_utf8("--%s\r\n" % boundary))
	out.append_array(_utf8("Content-Disposition: form-data; name=\"fileId\"\r\n\r\n"))
	out.append_array(_utf8(file_id))
	out.append_array(_utf8("\r\n"))

	# Fields: permissions[]
	for p in permissions:
		out.append_array(_utf8("--%s\r\n" % boundary))
		out.append_array(_utf8("Content-Disposition: form-data; name=\"permissions[]\"\r\n\r\n"))
		out.append_array(_utf8(str(p)))
		out.append_array(_utf8("\r\n"))

	# Field: file
	out.append_array(_utf8("--%s\r\n" % boundary))
	out.append_array(_utf8("Content-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n" % _escape_filename(filename)))
	out.append_array(_utf8("Content-Type: application/octet-stream\r\n\r\n"))
	out.append_array(file_bytes)
	out.append_array(_utf8("\r\n"))

	# Final boundary
	out.append_array(_utf8("--%s--\r\n" % boundary))
	return out


func _utf8(s: String) -> PackedByteArray:
	return s.to_utf8_buffer()


func _escape_filename(name: String) -> String:
	# Very small sanitization to avoid breaking the header.
	return name.replace("\"", "")
