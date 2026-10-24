extends SceneTree

## Runtime smoke test for the main scene (no headset): instances main.tscn,
## drives enrollment programmatically with synthetic throws, fires a free
## throw, switches to watch mode, throws an AI pitch, and round-trips the
## profile. Run:
##   godot --headless --path . --script tests/smoke_main.gd
## Verifies wiring and state flow ONLY - feel is judged in the headset.

var failures: int = 0
var checks: int = 0
var main: Node


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


func make_motion(peak_speed: float, is_curve: bool) -> Array:
	var samples: Array = []
	var duration: float = 0.62
	var steps: int = int(duration * 90.0)
	var start := Vector3(0.28, 1.30, 0.35)
	var back := Vector3(0.32, 1.12, 0.66)
	var release := Vector3(0.18, 1.72, -0.30)
	var positions: Array = []
	for i: int in steps + 1:
		var s: float = float(i) / float(steps)
		var pos: Vector3
		if s < 0.55:
			var u: float = s / 0.55
			pos = start.lerp(back, u * u)
		else:
			var u2: float = (s - 0.55) / 0.45
			pos = back.lerp(release, u2 * u2 * (3.0 - 2.0 * u2))
		positions.append(pos)
	for i2: int in steps + 1:
		var s2: float = float(i2) / float(steps)
		var lv: Vector3 = Vector3.ZERO
		if i2 > 0:
			var prev: Vector3 = positions[i2 - 1]
			var cur: Vector3 = positions[i2]
			lv = (cur - prev) / (duration / float(steps))
		var av: Vector3
		if is_curve:
			var ramp: float = clampf((s2 - 0.6) / 0.4, 0.0, 1.0)
			av = Vector3(3.0 + 12.5 * ramp, 0.5 + 1.5 * ramp, 0.3)
		else:
			av = Vector3(2.0 + 3.0 * s2, 0.5, 0.3)
		samples.append(ThrowFeatures.make_sample(s2 * duration, positions[i2], lv, av))
	var rel: Dictionary = samples[samples.size() - 1]
	var rel_lv: Vector3 = rel["lv"]
	var cur_speed: float = rel_lv.length()
	if cur_speed > 0.01:
		var k: float = peak_speed / cur_speed
		for raw: Variant in samples:
			var smp: Dictionary = raw
			var v: Vector3 = smp["lv"]
			smp["lv"] = v * k
	return samples


func feed(main_node: Node, is_curve: bool, speed: float, count: int) -> void:
	for n: int in count:
		var motion: Array = make_motion(speed, is_curve)
		var feats: PackedFloat32Array = ThrowFeatures.extract_features(motion)
		main_node._enrollment_throw(feats, speed, motion)


func _init() -> void:
	_run()


func _run() -> void:
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	root.add_child(main)
	await create_timer(0.2).timeout
	check(main != null, "main scene instantiated")

	# Enrollment, driven exactly as grip throws would drive it.
	main._start_enrollment(["calib", "fb", "cb", "p3", "gear_fast", "gear_med"])
	feed(main, false, 8.0, 3) # calib
	check(absf(main.calib_max - 8.0) < 0.01, "calibration stored (%.2f)" % main.calib_max)
	feed(main, false, 8.1, 3) # fb
	feed(main, true, 6.3, 3) # cb
	check(main.templates.has("FB") and main.templates.has("CB"), "FB + CB templates enrolled")
	main._on_skip() # optional third pitch skipped
	feed(main, false, 8.05, 2) # gear fast
	feed(main, false, 6.9, 2) # gear medium
	check(not main.enrolling, "enrollment completed")
	check(main.fast_anchor > 7.9 and main.med_anchor > 6.7 and main.med_anchor < main.fast_anchor,
		"gears anchored (FAST %.2f / MED %.2f)" % [main.fast_anchor, main.med_anchor])
	check(main.mode == 2 or main.mode == 1, "mode left SETUP after enrollment (mode=%d)" % main.mode)
	check(FileAccess.file_exists("user://duel_profile.json"), "profile file written")

	# Free throw: classified, flown, announced.
	var fb_motion: Array = make_motion(7.9, false)
	var fb_feats: PackedFloat32Array = ThrowFeatures.extract_features(fb_motion)
	main._free_throw(fb_feats, 7.9, fb_motion)
	check(main.flights.size() == 1, "free throw produced a flight")
	await create_timer(1.6).timeout
	check(main.last_result.begins_with("Gun:"), "gun announced the pitch (%s)" % main.last_result)
	check(main.pbs.has("FB"), "personal best recorded")

	# Watch mode: AI replays the enrolled motion, retimed.
	main._set_mode(2) # Mode.WATCH
	main._on_throw_it()
	check(not main.ai_play.is_empty(), "watch throw started (ai_play live)")
	await create_timer(1.8).timeout
	check(main.ai_play.is_empty(), "watch throw completed")
	check(main.last_result.begins_with("Gun:"), "watch pitch announced by the gun (%s)" % main.last_result)

	# Profile round-trip: clear memory only, reload from the file on disk.
	main.templates.clear()
	main._load_profile()
	check(main.templates.has("FB") and main.templates.has("CB"), "profile reload restores templates")
	main._on_wipe()
	check(main.templates.is_empty() and not FileAccess.file_exists("user://duel_profile.json"),
		"wipe clears templates and deletes the profile file (no test data leaks into Chris's first run)")
	print("---")
	if failures == 0:
		print("SMOKE: ALL %d CHECKS PASSED" % checks)
	else:
		print("SMOKE: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
