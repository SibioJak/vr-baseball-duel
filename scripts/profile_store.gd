class_name ProfileStore
extends RefCounted

## JSON persistence for the enrollment profile (user://duel_profile.json).
## Data is plain JSON-safe dictionaries (features as float arrays, motion
## samples as [t, px, py, pz, lx, ly, lz, ax, ay, az] rows).

static func save_profile(path: String, data: Dictionary) -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return true


static func load_profile(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		var d: Dictionary = parsed
		return d
	return {}


static func delete_profile(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
