extends Node

signal finished(result: Dictionary)

func _finish(ok: bool, skipped: bool = false, details: Dictionary = {}) -> void:
	var out := details.duplicate()
	out["name"] = "Functions"
	out["ok"] = ok
	out["skipped"] = skipped
	emit_signal("finished", out)

func _ready():
	print("--- Starting Appwrite Functions Test ---")
	
	var function_id := OS.get_environment("APPWRITE_FUNCTION_ID").strip_edges()
	if function_id.is_empty():
		print("⚠️ Skipping: APPWRITE_FUNCTION_ID is not set.")
		print("Set it in your .env, e.g.: APPWRITE_FUNCTION_ID=yourFunctionId")
		print("--- Test Finished ---")
		_finish(true, true, {"reason": "APPWRITE_FUNCTION_ID not set"})
		return

	# Optional: authenticate first (useful if your function execute permissions are for logged-in users only).
	var auth_email := OS.get_environment("APPWRITE_TEST_EMAIL").strip_edges()
	var auth_password := OS.get_environment("APPWRITE_TEST_PASSWORD").strip_edges()
	if not auth_email.is_empty() and not auth_password.is_empty():
		# Reuse any existing persisted/in-memory session first to avoid rate limits.
		var me: Dictionary = await Appwrite.account.get_current()
		if int(me.get("status_code", 0)) == 200:
			print("✅ Reusing existing session (already logged in).")
		else:
			print("Logging in with APPWRITE_TEST_EMAIL...")
			var login_resp: Dictionary = await Appwrite.account.create_email_session(auth_email, auth_password)
			if int(login_resp.get("status_code", 0)) != 201:
				print("❌ FAILED login.")
				print("Status Code: ", login_resp.get("status_code", 0))
				print("Error: ", login_resp.get("data", {}))
				print("--- Test Finished ---")
				_finish(false, false, {"error": login_resp.get("data", {})})
				return
			print("✅ Logged in.")
	else:
		print("No APPWRITE_TEST_EMAIL/PASSWORD provided; executing function without login.")

	print("Executing function: ", function_id)
	var payload := {
		"hello": "from_godot",
		"timestamp": Time.get_datetime_string_from_system(true)
	}
	var exec_resp: Dictionary = await Appwrite.functions.create_execution(function_id, payload)
	if int(exec_resp.get("status_code", 0)) != 201:
		print("❌ FAILED creating execution.")
		print("Status Code: ", exec_resp.get("status_code", 0))
		print("Error: ", exec_resp.get("data", {}))
		print("--- Test Finished ---")
		_finish(false, false, {"error": exec_resp.get("data", {})})
		return

	print("✅ Execution created.")
	var created_data: Variant = exec_resp.get("data")
	var created_dict: Dictionary = created_data if typeof(created_data) == TYPE_DICTIONARY else {}
	var execution_id := str(created_dict.get("$id", ""))
	print("Execution ID: ", execution_id)
	print("Status: ", created_dict.get("status", "<missing>"))

	# Appwrite may return immediately and finish the execution shortly after.
	# Poll until terminal status so we can reliably read responseBody.
	var final_resp: Dictionary = exec_resp
	if not execution_id.is_empty():
		var status := str(created_dict.get("status", ""))
		if status != "completed" and status != "failed" and status != "canceled":
			print("Waiting for execution to complete...")
			final_resp = await Appwrite.functions.wait_for_execution(function_id, execution_id)
			if final_resp.get("timeout", false):
				print("⚠️ Timed out waiting for execution; showing last known state.")

	var raw_data: Variant = final_resp.get("data")
	var data: Dictionary = raw_data if typeof(raw_data) == TYPE_DICTIONARY else {}
	print("Final Status: ", data.get("status", "<missing>"))
	print("Response Status Code: ", data.get("responseStatusCode", "<missing>"))
	print("Response Body: ", data.get("responseBody", ""))
	print("Errors: ", data.get("errors", ""))

	print("--- Test Finished ---")
	_finish(true)
