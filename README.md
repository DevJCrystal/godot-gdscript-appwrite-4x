# Appwrite SDK for Godot 4.5+ (GDScript)

An Appwrite Cloud client SDK for Godot 4.5+ written in GDScript.

- Endpoint: supports Appwrite Cloud region endpoints like `https://nyc.cloud.appwrite.io/v1`
- Auth: client-safe session auth via cookies (no embedded API key)
- Services implemented so far: **Account**, **Databases**, **Functions**, **Storage**, **Realtime**

## Install

### Option A: Use as a Godot plugin (recommended)

1. Copy the `addons/appwrite` folder into your Godot project.
2. In Godot: `Project` → `Project Settings` → `Plugins` → enable **Appwrite SDK**.

Enabling the plugin registers an autoload singleton named `Appwrite`.

### Option B: Git submodule

From your Godot project root:

```bash
git submodule add https://github.com/DevJCrystal/godot-gdscript-appwrite-4x.git addons/appwrite_sdk
```

Then copy (or symlink) `addons/appwrite_sdk/addons/appwrite` into your project’s `addons/`.

## Configuration

This project uses environment variables loaded from a local `.env` file.

- Copy `.env.example` → `.env`
- Fill in the values

Important:
- `.env` is ignored by git on purpose (it contains secrets).

### Minimal `.env` (just to connect)

If you only want the client to initialize and make basic requests:

- `APPWRITE_PROJECT_ID`
- `APPWRITE_ENDPOINT`

Optional (only if you’re developing against a self-signed instance):

- `APPWRITE_SELF_SIGNED=true`

### Tests / realtime `.env` (end-to-end)

If you want to run the included test scenes and realtime examples, you’ll typically also set:

- `APPWRITE_DATABASE_ID`, `APPWRITE_TABLE_ID`
- `APPWRITE_STORAGE_BUCKET_ID` (storage tests)
- `APPWRITE_FUNCTION_ID` (functions tests)
- `APPWRITE_TEST_EMAIL`, `APPWRITE_TEST_PASSWORD` (most tests + database realtime)

Useful debug toggles while iterating:

- `APPWRITE_DEBUG_PERSIST_SESSION=true`
- `APPWRITE_DEBUG_HTTP=true`
- `APPWRITE_DEBUG_REALTIME=true`

## Quick start

Once the plugin is enabled, you can call:

```gdscript
var res: Dictionary = await Appwrite.account.get_current()
print(res.get("status_code"), res.get("data"))
```

## Service examples

All service calls return a `Dictionary` with:

- `status_code` (int): HTTP status code (or `0` for local/network failures)
- `data` (Variant): decoded JSON response (usually a Dictionary)
- sometimes `body_bytes` for binary downloads (see Storage)

If you want a consistent pattern for handling responses, this small helper keeps example code tidy:

```gdscript
func _require_ok(resp: Dictionary, ok_codes: Array[int] = [200, 201, 204]) -> bool:
	var code := int(resp.get("status_code", 0))
	if ok_codes.has(code):
		return true

	# status_code == 0 means the request failed locally (DNS/TLS/timeout/etc).
	push_error("Appwrite request failed (%d): %s" % [code, str(resp.get("data"))])
	return false
```

### Account (login + current user)

```gdscript
# Login (creates a cookie session)
var login := await Appwrite.account.create_email_session(
	OS.get_environment("APPWRITE_TEST_EMAIL"),
	OS.get_environment("APPWRITE_TEST_PASSWORD")
)

if not _require_ok(login, [201]):
	return

# Fetch current user
var me := await Appwrite.account.get_current()
print("me status=", me.get("status_code"))
print("me data=", me.get("data"))

# Logout (optional)
# await Appwrite.account.delete_session("current")
```

### Databases (list + create + update + queries)

```gdscript
var db_id := OS.get_environment("APPWRITE_DATABASE_ID")
var table_id := OS.get_environment("APPWRITE_TABLE_ID")

# List the latest 10 documents ordered by bestScore
var list := await Appwrite.databases.list_documents(db_id, table_id, [
	Query.order_desc("bestScore"),
	Query.limit(10)
])
print("list status=", list.get("status_code"))

# Create a document (documentId can be "unique()")
var created := await Appwrite.databases.create_document(
	db_id,
	table_id,
	"unique()",
	{
		"bestScore": 123,
		"note": "hello from godot"
	}
)
print("create status=", created.get("status_code"))

# Update a document
var doc_id := str(created.get("data", {}).get("$id", ""))
if not doc_id.is_empty():
	var updated := await Appwrite.databases.update_document(
		db_id,
		table_id,
		doc_id,
		{"bestScore": 200}
	)
	print("update status=", updated.get("status_code"))

# Filter example: only docs where userId equals a value
# var filtered := await Appwrite.databases.list_documents(db_id, table_id, [
# 	Query.equal("userId", "some-user-id")
# ])
```

### Storage (upload + download + delete)

```gdscript
var bucket_id := OS.get_environment("APPWRITE_STORAGE_BUCKET_ID")

# Upload a file from disk (fileId can be "unique()")
var upload := await Appwrite.storage.create_file(
	bucket_id,
	"unique()",
	"res://icon.svg"
)
print("upload status=", upload.get("status_code"))

var file_id := str(upload.get("data", {}).get("$id", ""))
if not file_id.is_empty():
	# Download raw bytes
	var dl := await Appwrite.storage.download_file(bucket_id, file_id)
	var bytes := dl.get("body_bytes", PackedByteArray()) as PackedByteArray
	print("download status=", dl.get("status_code"), " bytes=", bytes.size())

	# Delete
	var del := await Appwrite.storage.delete_file(bucket_id, file_id)
	print("delete status=", del.get("status_code"))
```

### Functions (execute + wait for completion)

```gdscript
var function_id := OS.get_environment("APPWRITE_FUNCTION_ID")

# Trigger an execution (body can be a Dictionary; it will be JSON-stringified)
var exec := await Appwrite.functions.create_execution(function_id, {
	"hello": "world",
	"time": Time.get_unix_time_from_system()
})

if int(exec.get("status_code", 0)) != 201:
	push_error("Execution create failed: %s" % [str(exec.get("data"))])
	return

var execution_id := str(exec.get("data", {}).get("$id", ""))

# Wait for it to reach completed/failed/canceled
var final := await Appwrite.functions.wait_for_execution(function_id, execution_id, 60_000)
print("final status=", final.get("status_code"))
print("execution=", final.get("data"))
```

### Realtime (subscribe to document events)

```gdscript
var db_id := OS.get_environment("APPWRITE_DATABASE_ID")
var table_id := OS.get_environment("APPWRITE_TABLE_ID")

# This channel receives create/update/delete events for documents in the collection.
var channel := "databases.%s.collections.%s.documents" % [db_id, table_id]

# If your collection requires auth, login first (see Account example).
var sub_id := Appwrite.realtime.subscribe([channel], func (msg: Dictionary) -> void:
	# Typical event payload:
	# { events:[], channels:[], timestamp:"...", payload:{...}, type:"event" }
	var payload: Variant = msg.get("payload")
	print("realtime events=", msg.get("events"))
	print("payload=", payload)
)

# Later, unsubscribe when you no longer need updates.
# Appwrite.realtime.unsubscribe(sub_id)

# Only call this if you want to explicitly tear down the socket (e.g. app quit).
# In most games you keep the connection open and just subscribe/unsubscribe.
# Appwrite.realtime.disconnect_now()
```

## Current progress

### ✅ Accounts

Implemented in `addons/appwrite/src/services/account.gd`.

- Create users
- Create email sessions
- Get current account (`get_current()`)
- Logout / delete session
- Cookie-based session persistence (captures `Set-Cookie`, sends `Cookie`)

Notes:
- Method name avoids Godot’s built-in `Object.get()` collision (uses `get_current()` / `get_account()` naming).

### ✅ Databases (Tables)

Implemented in `addons/appwrite/src/services/databases.gd`.

- “Table” terminology in the public API (Appwrite REST still uses `/collections/...`)
- Create / list / get / delete documents
- Query filtering via `queries[]`

Important query detail (Appwrite v1.8+):
- Queries must be JSON-encoded strings (same as Appwrite Web SDK `Query.toString()`), and URL-encoded when sent.
- This is handled by `addons/appwrite/src/query.gd` + the Databases service.

### ✅ Functions

Implemented in `addons/appwrite/src/services/functions.gd`.

- Create function executions
- Poll/wait for execution to reach a terminal status (`wait_for_execution()`)
- Returns execution output (`responseStatusCode`, `responseBody`) when available

### ✅ Storage

Implemented in `addons/appwrite/src/services/storage.gd`.

- List buckets / get bucket
- List files / get file metadata
- Upload file (multipart) from bytes or from disk
- Download file bytes (`body_bytes`)
- Delete files

### ✅ Realtime

Implemented in `addons/appwrite/src/services/realtime.gd`.

- WebSocket-based subscriptions (`Appwrite.realtime.subscribe([...], callback)`)
- Session auth via the same cookie jar used for REST calls
- Automatically reconnects when the subscribed channel set changes

Example:

```gdscript
var channel := "databases.%s.collections.%s.documents" % [db_id, table_id]
var sub_id := Appwrite.realtime.subscribe([channel], func (msg: Dictionary) -> void:
	print(msg)
)

# Later:
Appwrite.realtime.unsubscribe(sub_id)

# Only call this if you want to explicitly tear down the socket (e.g. app quit).
# In most games you keep the connection open and just subscribe/unsubscribe
# when the player joins/leaves a match.
# Appwrite.realtime.disconnect_now()
```

## Tests / Debug scenes

This repo includes Godot scenes under `tests/` that run end-to-end flows.

- `tests/test_accounts.tscn`: account flows
- `tests/test_databases.tscn`: document CRUD
- `tests/test_functions.tscn`: function execution + wait
- `tests/test_storage.tscn`: upload/download/delete against a bucket
- `tests/test_queries.tscn`: query diagnostics (baseline list + filtered list)
- `tests/test_e2e.tscn`: end-to-end test
- `tests/test_ui.tscn`: simple UI runner (buttons + results log)
- `tests/test_realtime_player_docs.tscn`: live top-5 leaderboard UI (read-only)

## Examples

- `examples/realtime_monitor.tscn`: subscribes to a collection channel and prints every realtime message.

Env vars:

- Either set `APPWRITE_REALTIME_CHANNEL` to a full channel string, OR set `APPWRITE_DATABASE_ID` + `APPWRITE_TABLE_ID`.
- If the channel requires auth (common for databases), also set `APPWRITE_TEST_EMAIL` + `APPWRITE_TEST_PASSWORD`.

Useful env flags:

- `APPWRITE_DEBUG_PERSIST_SESSION=true` keeps a cookie jar on disk to reduce repeated logins.
- `APPWRITE_DEBUG_HTTP=true` prints request details from the client.
- `APPWRITE_DEBUG_REALTIME=true` prints realtime WebSocket state + frames.
- `APPWRITE_TEST_PRINT_DOCS_JSON=true` prints full document JSON in the query test.

## Security / design constraints

- No API keys are embedded in the client.
- Privileged operations should be done via Appwrite **Functions**.
- If `APPWRITE_KEY` is present in your `.env`, it is ignored unless you also set `APPWRITE_ENABLE_API_KEY=true`.