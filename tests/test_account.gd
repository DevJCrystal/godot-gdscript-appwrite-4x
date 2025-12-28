extends Node

const Helpers := preload("res://tests/test_helpers.gd")

func _ready():
	print("--- Starting Appwrite Account Test ---")
	randomize()

	# Only clear cookies if explicitly requested (or if persistence is disabled).
	if Helpers.should_clear_cookies() and Appwrite.has_method("clear_cookies"):
		Appwrite.clear_cookies()

	# Prefer reusing a stable test account if provided.
	var auth_email := OS.get_environment("APPWRITE_TEST_EMAIL").strip_edges()
	var auth_password := OS.get_environment("APPWRITE_TEST_PASSWORD").strip_edges()
	var use_existing := not auth_email.is_empty() and not auth_password.is_empty()

	if use_existing:
		print("Checking for existing session...")
		var auth := await Helpers.ensure_logged_in()
		if not bool(auth.get("ok", false)):
			print("❌ FAILED auth.")
			print("Status Code: ", auth.get("status_code", 0))
			print("Error: ", auth.get("error", {}))
			print("--- Test Finished ---")
			return
		var me_resp: Dictionary = auth.get("me", {})
		var me_data: Variant = me_resp.get("data")
		var me: Dictionary = me_data if typeof(me_data) == TYPE_DICTIONARY else {}
		print("✅ Authenticated.")
		print("Reused session: ", auth.get("reused", false))
		print("Me ID: ", me.get("$id", "<missing>"))
		print("Me Email: ", me.get("email", "<missing>"))

		if Helpers.should_logout():
			print("Logging out (delete current session)...")
			var logout_resp: Dictionary = await Appwrite.account.delete_session("current")
			if int(logout_resp.get("status_code", 0)) != 204:
				print("❌ FAILED logging out.")
				print("Status Code: ", logout_resp.get("status_code", 0))
				print("Error Message: ", logout_resp.get("data", {}))
				print("--- Test Finished ---")
				return
			print("✅ SUCCESS! Logged out.")

			print("Verifying session is gone (/account should be 401)...")
			var me_after_logout: Dictionary = await Appwrite.account.get_current()
			if int(me_after_logout.get("status_code", 0)) == 401:
				print("✅ SUCCESS! Unauthorized after logout.")
			else:
				print("⚠️ Unexpected status after logout.")
				print("Status Code: ", me_after_logout.get("status_code", 0))
				print("Response: ", me_after_logout.get("data", {}))

		print("--- Test Finished ---")
		return

	# Fallback: Create a random user (original behavior).
	var random_id = randi() % 10000
	var email = "test_user_%d@example.com" % random_id
	var password = "password123"
	print("Attempting to create user: " + email)
	# Create user. "unique()" tells Appwrite to auto-generate the user ID.
	var response: Dictionary = await Appwrite.account.create("unique()", email, password)
	
	# Validate
	if int(response.get("status_code", 0)) != 201:
		print("❌ FAILED creating user.")
		print("Status Code: ", response.get("status_code", 0))
		print("Error Message: ", response.get("data", {}))
		print("--- Test Finished ---")
		return

	print("✅ SUCCESS! User created.")
	var created_data: Variant = response.get("data")
	var created: Dictionary = created_data if typeof(created_data) == TYPE_DICTIONARY else {}
	print("User ID: ", created.get("$id", "<missing>"))
	print("Name: ", created.get("name", ""))
	print("Registration: ", created.get("registration", ""))

	# Login (creates a session cookie)
	print("Attempting login (create email session)...")
	var session_response: Dictionary = await Appwrite.account.create_email_session(email, password)
	if int(session_response.get("status_code", 0)) != 201:
		print("❌ FAILED creating session.")
		print("Status Code: ", session_response.get("status_code", 0))
		print("Error Message: ", session_response.get("data", {}))
		print("--- Test Finished ---")
		return
	print("✅ SUCCESS! Session created.")
	var sess_data: Variant = session_response.get("data")
	var sess: Dictionary = sess_data if typeof(sess_data) == TYPE_DICTIONARY else {}
	print("Session ID: ", sess.get("$id", "<missing>"))

	# Verify session by fetching the current account
	print("Fetching current account (/account)...")
	var me_response: Dictionary = await Appwrite.account.get_account()
	if int(me_response.get("status_code", 0)) != 200:
		print("❌ FAILED fetching current account.")
		print("Status Code: ", me_response.get("status_code", 0))
		print("Error Message: ", me_response.get("data", {}))
		print("--- Test Finished ---")
		return
	print("✅ SUCCESS! Current account returned.")
	var me_data2: Variant = me_response.get("data")
	var me2: Dictionary = me_data2 if typeof(me_data2) == TYPE_DICTIONARY else {}
	print("Me ID: ", me2.get("$id", "<missing>"))
	print("Me Email: ", me2.get("email", "<missing>"))

	# Optional: logout + verify session removal
	if Helpers.should_logout():
		print("Logging out (delete current session)...")
		var logout_response: Dictionary = await Appwrite.account.delete_session("current")
		if int(logout_response.get("status_code", 0)) != 204:
			print("❌ FAILED logging out.")
			print("Status Code: ", logout_response.get("status_code", 0))
			print("Error Message: ", logout_response.get("data", {}))
			print("--- Test Finished ---")
			return
		print("✅ SUCCESS! Logged out.")

		# Verify that /account now returns 401 unauthorized.
		print("Verifying session is gone (/account should be 401)...")
		var me_after_logout: Dictionary = await Appwrite.account.get_account()
		if int(me_after_logout.get("status_code", 0)) == 401:
			print("✅ SUCCESS! Unauthorized after logout.")
		else:
			print("⚠️ Unexpected status after logout.")
			print("Status Code: ", me_after_logout.get("status_code", 0))
			print("Response: ", me_after_logout.get("data", {}))

	print("--- Test Finished ---")
