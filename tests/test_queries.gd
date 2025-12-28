extends Node

const Helpers := preload("res://tests/test_helpers.gd")

func _env_bool(name: String, default_value: bool = false) -> bool:
	var raw := OS.get_environment(name).strip_edges().to_lower()
	if raw.is_empty():
		return default_value
	return raw == "true" or raw == "1" or raw == "yes" or raw == "y"


func _print_docs_summary(label: String, docs_arr: Array) -> void:
	print(label, " count=", docs_arr.size())
	for d in docs_arr:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var doc := d as Dictionary
		var id_str := str(doc.get("$id", ""))
		var testing_str := str(doc.get("testing", ""))
		if testing_str.is_empty():
			print("- ", id_str)
		else:
			print("- ", id_str, " testing=", testing_str)


signal finished(result: Dictionary)

func _finish(ok: bool, skipped: bool = false, details: Dictionary = {}) -> void:
	var out := details.duplicate()
	out["name"] = "Queries"
	out["ok"] = ok
	out["skipped"] = skipped
	emit_signal("finished", out)

func _ready():
	print("--- Starting Appwrite Queries Test ---")
	randomize()

	var database_id := OS.get_environment("APPWRITE_DATABASE_ID").strip_edges()
	var table_id := OS.get_environment("APPWRITE_TABLE_ID").strip_edges()
	if database_id.is_empty() or table_id.is_empty():
		print("⚠️ Skipping: APPWRITE_DATABASE_ID / APPWRITE_TABLE_ID not set.")
		print("--- Test Finished ---")
		_finish(true, true, {"reason": "Missing APPWRITE_DATABASE_ID / APPWRITE_TABLE_ID"})
		return

	# Login (reuse session if available)
	var auth := await Helpers.ensure_logged_in()
	if not bool(auth.get("ok", false)):
		print("❌ FAILED auth.")
		print("Status Code: ", auth.get("status_code", 0))
		print("Error: ", auth.get("error", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": auth.get("error", {})})
		return
	print("✅ Authenticated. Reused session=", auth.get("reused", false))
	var print_docs_json: bool = _env_bool("APPWRITE_TEST_PRINT_DOCS_JSON", false)

	# Baseline: list documents without any queries
	print("--- 0) list_documents() with NO queries ---")
	var baseline: Dictionary = await Appwrite.databases.list_documents(database_id, table_id)
	print("Status: ", baseline.get("status_code", 0))
	var ok := true
	if int(baseline.get("status_code", 0)) == 200:
		var baseline_data: Variant = baseline.get("data")
		var baseline_dict: Dictionary = baseline_data if typeof(baseline_data) == TYPE_DICTIONARY else {}
		var total: Variant = baseline_dict.get("total", "<missing>")
		var docs_v: Variant = baseline_dict.get("documents")
		var count: int = 0
		var docs_arr: Array = []
		if typeof(docs_v) == TYPE_ARRAY:
			docs_arr = docs_v as Array
			count = docs_arr.size()
		var total_str: String = str(total)
		if typeof(total) == TYPE_FLOAT or typeof(total) == TYPE_INT:
			total_str = str(int(total))
		print("Total=", total_str, " returned=", count)
		_print_docs_summary("Docs (baseline):", docs_arr)
		if print_docs_json:
			print("Docs (baseline JSON):")
			print(JSON.stringify(docs_arr, "  "))
	else:
		print("Error: ", baseline.get("data", {}))
		ok = false

	# Create a marker document so we can query for it.
	var doc_marker := "QueryTest %d" % (randi() % 1000000)
	print("Creating marker document... marker=", doc_marker)
	var created: Dictionary = await Appwrite.databases.create_document(database_id, table_id, "unique()", {"testing": doc_marker}, [])
	if int(created.get("status_code", 0)) != 201:
		print("❌ FAILED create document.")
		print("Status Code: ", created.get("status_code", 0))
		print("Error: ", created.get("data", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": created.get("data", {})})
		return
	var created_data: Variant = created.get("data")
	var created_dict: Dictionary = created_data if typeof(created_data) == TYPE_DICTIONARY else {}
	var doc_id := str(created_dict.get("$id", ""))
	print("✅ Created: ", doc_id)

	var base_path := "/databases/%s/collections/%s/documents" % [database_id, table_id]
	var q: String = Query.equal("testing", [doc_marker])
	print("Query JSON (unencoded): ", q)

	# Filtered list via SDK wrapper (URL-encodes JSON queries[])
	print("--- 1) list_documents() with query ---")
	var filtered: Dictionary = await Appwrite.databases.list_documents(database_id, table_id, [q, Query.limit(10)])
	print("Status: ", filtered.get("status_code", 0))
	if int(filtered.get("status_code", 0)) != 200:
		print("Error: ", filtered.get("data", {}))
		ok = false
	else:
		var f_data: Variant = filtered.get("data")
		var f_dict: Dictionary = f_data if typeof(f_data) == TYPE_DICTIONARY else {}
		var f_total: Variant = f_dict.get("total", "<missing>")
		var f_total_str: String = str(f_total)
		if typeof(f_total) == TYPE_FLOAT or typeof(f_total) == TYPE_INT:
			f_total_str = str(int(f_total))
		var f_docs_v: Variant = f_dict.get("documents")
		var f_docs_arr: Array = []
		if typeof(f_docs_v) == TYPE_ARRAY:
			f_docs_arr = f_docs_v as Array
		print("Total=", f_total_str, " returned=", f_docs_arr.size())
		_print_docs_summary("Docs (filtered):", f_docs_arr)

		var found := false
		for d in f_docs_arr:
			if typeof(d) != TYPE_DICTIONARY:
				continue
			var doc := d as Dictionary
			if str(doc.get("$id", "")) == doc_id:
				found = true
				break
		if found:
			print("✅ Query matched marker doc.")
		else:
			print("❌ Query did not match marker doc (unexpected).")
		ok = ok and found
		if print_docs_json:
			print("Docs (filtered JSON):")
			print(JSON.stringify(f_docs_arr, "  "))

	# Cleanup
	print("Cleaning up marker document...")
	var deleted: Dictionary = await Appwrite.databases.delete_document(database_id, table_id, doc_id)
	print("Delete status: ", deleted.get("status_code", 0))
	if int(deleted.get("status_code", 0)) != 204:
		ok = false

	print("--- Queries Test Finished ---")
	_finish(ok)
