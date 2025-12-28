extends Node

const Helpers := preload("res://tests/test_helpers.gd")

signal finished(result: Dictionary)

func _finish(ok: bool, skipped: bool = false, details: Dictionary = {}) -> void:
	var out := details.duplicate()
	out["name"] = "Storage"
	out["ok"] = ok
	out["skipped"] = skipped
	emit_signal("finished", out)

func _ready():
	print("--- Starting Appwrite Storage Test ---")

	var bucket_id := OS.get_environment("APPWRITE_STORAGE_BUCKET_ID").strip_edges()
	if bucket_id.is_empty():
		print("⚠️ Skipping: APPWRITE_STORAGE_BUCKET_ID not set.")
		print("For your testing bucket, set: APPWRITE_STORAGE_BUCKET_ID=6951a2db0036a2a07615")
		print("--- Test Finished ---")
		_finish(true, true, {"reason": "APPWRITE_STORAGE_BUCKET_ID not set"})
		return

	# Auth (recommended): required unless your bucket allows guests.
	var auth := await Helpers.ensure_logged_in()
	if not bool(auth.get("ok", false)):
		print("❌ FAILED auth.")
		print("Status Code: ", auth.get("status_code", 0))
		print("Error: ", auth.get("error", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": auth.get("error", {})})
		return
	print("✅ Authenticated. Reused session=", auth.get("reused", false))

	print("Listing files...")
	var baseline: Dictionary = await Appwrite.storage.list_files(bucket_id, [Query.limit(10)])
	if int(baseline.get("status_code", 0)) != 200:
		print("❌ FAILED list files.")
		print("Status Code: ", baseline.get("status_code", 0))
		print("Error: ", baseline.get("data", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": baseline.get("data", {})})
		return

	# Upload a tiny text file (from bytes)
	var marker := "hello_from_godot_%d" % (randi() % 1000000)
	var content := (marker + "\n").to_utf8_buffer()
	var ok := true
	print("Uploading file...")
	var created: Dictionary = await Appwrite.storage.create_file_from_bytes(bucket_id, "unique()", "hello.txt", content, [])
	if int(created.get("status_code", 0)) != 201:
		print("❌ FAILED upload.")
		print("Status Code: ", created.get("status_code", 0))
		print("Error: ", created.get("data", {}))
		print("Hint: check bucket permissions (create/read/delete) for this user.")
		print("--- Test Finished ---")
		_finish(false, false, {"error": created.get("data", {})})
		return

	var created_data: Variant = created.get("data")
	var created_dict: Dictionary = created_data if typeof(created_data) == TYPE_DICTIONARY else {}
	var file_id := str(created_dict.get("$id", ""))
	print("✅ Uploaded. file_id=", file_id)

	print("Getting file metadata...")
	var meta: Dictionary = await Appwrite.storage.get_file(bucket_id, file_id)
	if int(meta.get("status_code", 0)) != 200:
		print("❌ FAILED get file.")
		print("Status Code: ", meta.get("status_code", 0))
		print("Error: ", meta.get("data", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": meta.get("data", {})})
		return

	print("Downloading file...")
	var dl: Dictionary = await Appwrite.storage.download_file(bucket_id, file_id)
	if int(dl.get("status_code", 0)) != 200:
		print("❌ FAILED download.")
		print("Status Code: ", dl.get("status_code", 0))
		print("Error: ", dl.get("data", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": dl.get("data", {})})
		return

	var body_bytes: Variant = dl.get("body_bytes")
	var body: PackedByteArray = body_bytes if typeof(body_bytes) == TYPE_PACKED_BYTE_ARRAY else PackedByteArray()
	var text := body.get_string_from_utf8()
	if text.find(marker) != -1:
		print("✅ Download verified.")
	else:
		print("⚠️ Download did not match marker.")
		ok = false
		
	#await get_tree().create_timer(5.0).timeout

	print("Deleting file...")
	var deleted: Dictionary = await Appwrite.storage.delete_file(bucket_id, file_id)
	if int(deleted.get("status_code", 0)) != 204:
		print("❌ FAILED delete.")
		print("Status Code: ", deleted.get("status_code", 0))
		print("Error: ", deleted.get("data", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": deleted.get("data", {})})
		return
	print("✅ Deleted.")

	print("--- Test Finished ---")
	_finish(ok)
