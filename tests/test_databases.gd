extends Node

const Helpers := preload("res://tests/test_helpers.gd")

signal finished(result: Dictionary)

func _finish(ok: bool, skipped: bool = false, details: Dictionary = {}) -> void:
	var out := details.duplicate()
	out["name"] = "Databases"
	out["ok"] = ok
	out["skipped"] = skipped
	emit_signal("finished", out)

func _ready():
	print("--- Starting Appwrite Databases Test ---")
	
	var database_id := OS.get_environment("APPWRITE_DATABASE_ID").strip_edges()
	var table_id := OS.get_environment("APPWRITE_TABLE_ID").strip_edges()
	if database_id.is_empty() or table_id.is_empty():
		print("⚠️ Skipping: APPWRITE_DATABASE_ID / APPWRITE_TABLE_ID not set.")
		print("Add them to .env to run this test.")
		print("--- Test Finished ---")
		_finish(true, true, {"reason": "Missing APPWRITE_DATABASE_ID / APPWRITE_TABLE_ID"})
		return

	# Auth: required unless your collection allows guests.
	var auth_email := OS.get_environment("APPWRITE_TEST_EMAIL").strip_edges()
	var auth_password := OS.get_environment("APPWRITE_TEST_PASSWORD").strip_edges()
	if auth_email.is_empty() or auth_password.is_empty():
		print("⚠️ Skipping: APPWRITE_TEST_EMAIL / APPWRITE_TEST_PASSWORD not set.")
		print("This test needs a user to login so it can create/list documents via permissions.")
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
		print("Status Code: ", auth.get("status_code", 0))
		print("Error: ", auth.get("error", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": auth.get("error", {})})
		return
	print("✅ Authenticated. Reused session=", auth.get("reused", false))
	var me_resp: Dictionary = auth.get("me", {})
	var me_data: Variant = me_resp.get("data")
	var me: Dictionary = me_data if typeof(me_data) == TYPE_DICTIONARY else {}
	var my_user_id := str(me.get("$id", ""))
	print("Me ID: ", my_user_id)

	# Create a document owned by this user.
	# NOTE: Permission string format depends on your Appwrite version/settings.
	# If your collection has "Document Security" enabled and defaults configured,
	# you can leave permissions empty and rely on collection rules.
	var permissions: Array[String] = []
	# Common format in Appwrite REST: role strings like "user:<id>" inside permission calls.
	# Some setups accept raw permission strings like 'read("user:<id>")'.
	# We'll try leaving permissions empty by default.

	print("Creating document...")
	randomize()
	var doc_data := {
		"testing": "Test Doc %d" % (randi() % 1000000)
	}
	var created = await Appwrite.databases.create_document(database_id, table_id, "unique()", doc_data, permissions)
	if int(created.get("status_code", 0)) != 201:
		print("❌ FAILED create document.")
		print("Status Code: ", created.get("status_code", 0))
		print("Error: ", created.get("data", {}))
		print("Hint: check collection permissions / document security / attribute schema.")
		print("--- Test Finished ---")
		_finish(false, false, {"error": created.get("data", {})})
		return
	var created_data: Variant = created.get("data")
	var created_dict: Dictionary = created_data if typeof(created_data) == TYPE_DICTIONARY else {}
	var doc_id := str(created_dict.get("$id", ""))
	print("✅ Document created: ", doc_id)

	print("Listing accessible documents...")
	var listed = await Appwrite.databases.list_documents(database_id, table_id)
	if int(listed.get("status_code", 0)) != 200:
		print("❌ FAILED list documents.")
		print("Status Code: ", listed.get("status_code", 0))
		print("Error: ", listed.get("data", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": listed.get("data", {})})
		return
	var listed_data: Variant = listed.get("data")
	var listed_dict: Dictionary = listed_data if typeof(listed_data) == TYPE_DICTIONARY else {}
	var total := int(listed_dict.get("total", -1))
	print("✅ List returned. total=", total)

	print("Getting created document...")
	var got = await Appwrite.databases.get_document(database_id, table_id, doc_id)
	if int(got.get("status_code", 0)) != 200:
		print("❌ FAILED get document.")
		print("Status Code: ", got.get("status_code", 0))
		print("Error: ", got.get("data", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": got.get("data", {})})
		return
	var got_data: Variant = got.get("data")
	var got_dict: Dictionary = got_data if typeof(got_data) == TYPE_DICTIONARY else {}
	print("✅ Got document. testing=", got_dict.get("testing", ""))
	
	#await get_tree().create_timer(5.0).timeout
	
	print("Deleting created document...")
	var deleted = await Appwrite.databases.delete_document(database_id, table_id, doc_id)
	if int(deleted.get("status_code", 0)) != 204:
		print("❌ FAILED delete document.")
		print("Status Code: ", deleted.get("status_code", 0))
		print("Error: ", deleted.get("data", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": deleted.get("data", {})})
		return
	print("✅ Deleted.")

	print("--- Test Finished ---")
	_finish(true)
