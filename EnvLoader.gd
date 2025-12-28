class_name EnvLoader
extends RefCounted

static func _is_sensitive_key(key: String) -> bool:
	var k := key.to_upper()
	return k.find("PASSWORD") != -1 \
		or k.find("SECRET") != -1 \
		or k.find("TOKEN") != -1 \
		or k == "APPWRITE_KEY" \
		or k.ends_with("_KEY")

static func load_env(path: String = "res://.env") -> void:
	if not FileAccess.file_exists(path):
		printerr("EnvLoader: .env file not found at ", path)
		return

	var file = FileAccess.open(path, FileAccess.READ)
	
	while not file.eof_reached():
		var line = file.get_line().strip_edges()
		
		# Skip empty lines or comments
		if line.is_empty() or line.begins_with("#"):
			continue
			
		var parts = line.split("=", true, 1) # Split only on the first '='
		if parts.size() == 2:
			var key = parts[0].strip_edges()
			var value = parts[1].strip_edges()
			
			# Remove quotes if present
			if value.begins_with('"') and value.ends_with('"'):
				value = value.substr(1, value.length() - 2)
				
			# Inject into Godot's environment map
			OS.set_environment(key, value)
			if _is_sensitive_key(key):
				print("EnvLoader: Loaded ", key, " (redacted)")
			else:
				print("EnvLoader: Loaded ", key)
