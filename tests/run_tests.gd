extends SceneTree

## Headless tests for the duel feel-test's pure logic (ThrowFeatures +
## ProfileStore). Run:
##   godot --headless --path . --script tests/run_tests.gd
## Exit code 0 = all pass. These verify MATH, not headset feel.

var failures: int = 0
var checks: int = 0


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


# Synthetic throwing motion at 90 Hz. lv is derived from positions by finite
# difference, exactly as the live sampler does; av is scripted per pitch:
# a curveball has a late, x-dominant wrist-roll signature a fastball lacks.
func make_motion(rng: RandomNumberGenerator, peak_speed: float, is_curve: bool, jitter: float) -> Array:
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
			var e: float = u2 * u2 * (3.0 - 2.0 * u2)
			pos = back.lerp(release, e)
		pos += Vector3(rng.randf_range(-jitter, jitter), rng.randf_range(-jitter, jitter), rng.randf_range(-jitter, jitter))
		positions.append(pos)
	for i2: int in steps + 1:
		var s2: float = float(i2) / float(steps)
		var t: float = s2 * duration
		var lv: Vector3 = Vector3.ZERO
		if i2 > 0:
			var prev: Vector3 = positions[i2 - 1]
			var cur: Vector3 = positions[i2]
			lv = (cur - prev) / (duration / float(steps))
		# Scale delivery speed so release lands near peak_speed.
		var av: Vector3
		if is_curve:
			var ramp: float = clampf((s2 - 0.6) / 0.4, 0.0, 1.0)
			av = Vector3(3.0 + 12.5 * ramp, 0.5 + 1.5 * ramp, 0.3)
		else:
			av = Vector3(2.0 + 3.0 * s2, 0.5, 0.3)
		samples.append(ThrowFeatures.make_sample(t, positions[i2], lv, av))
	# Normalize: rescale lv so the release speed equals peak_speed.
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


func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	# --- Templates + classification -------------------------------------
	var fb_feats: Array = []
	var cb_feats: Array = []
	for n: int in 3:
		fb_feats.append(ThrowFeatures.extract_features(make_motion(rng, 8.2, false, 0.01)))
		cb_feats.append(ThrowFeatures.extract_features(make_motion(rng, 6.4, true, 0.01)))
	var templates: Dictionary = {
		"FB": ThrowFeatures.build_template(fb_feats),
		"CB": ThrowFeatures.build_template(cb_feats),
	}
	var fresh_fb: PackedFloat32Array = ThrowFeatures.extract_features(make_motion(rng, 8.0, false, 0.015))
	var fresh_cb: PackedFloat32Array = ThrowFeatures.extract_features(make_motion(rng, 6.6, true, 0.015))
	var c1: Dictionary = ThrowFeatures.classify(fresh_fb, templates)
	var c2: Dictionary = ThrowFeatures.classify(fresh_cb, templates)
	check(String(c1["pitch"]) == "FB", "classifier calls a fresh fastball FB (got %s)" % String(c1["pitch"]))
	check(String(c2["pitch"]) == "CB", "classifier calls a fresh curveball CB (got %s)" % String(c2["pitch"]))
	check(float(c1["confidence"]) > 0.2, "fastball confidence is meaningful (%.2f)" % float(c1["confidence"]))

	# --- Separation / confusability -------------------------------------
	var rep: Dictionary = ThrowFeatures.separation_report(templates)
	var pair: Dictionary = rep["FB|CB"]
	check(bool(pair["ok"]), "distinct FB/CB templates pass separation (d=%.2f req=%.2f)" % [float(pair["distance"]), float(pair["required"])])
	var mush_feats: Array = []
	for n2: int in 3:
		mush_feats.append(ThrowFeatures.extract_features(make_motion(rng, 8.1, false, 0.004)))
	var mush_templates: Dictionary = {"FB": templates["FB"], "CB": ThrowFeatures.build_template(mush_feats)}
	var rep2: Dictionary = ThrowFeatures.separation_report(mush_templates)
	var pair2: Dictionary = rep2["FB|CB"]
	check(not bool(pair2["ok"]), "near-identical templates FAIL separation and must warn (d=%.2f req=%.2f)" % [float(pair2["distance"]), float(pair2["required"])])

	# --- Velocity mapping ------------------------------------------------
	check(absf(ThrowFeatures.map_velocity(8.0, 8.0, 1.0) - 96.0) < 0.01, "calibration max maps to 96 mph")
	check(absf(ThrowFeatures.map_velocity(4.0, 8.0, 1.0) - 48.0) < 0.01, "half effort maps to 48 mph (ordering preserved)")
	check(absf(ThrowFeatures.map_velocity(8.0, 8.0, 1.2) - 108.0) < 0.01, "boost +20% clamps at 108 mph ceiling")
	check(ThrowFeatures.map_velocity(2.0, 8.0, 1.0) >= 30.0, "velocity floor clamps at 30 mph")

	# --- Gears ------------------------------------------------------------
	check(ThrowFeatures.gear_for_speed(7.95, 8.0, 6.8) == "FAST", "throw at fast anchor reads FAST gear")
	check(ThrowFeatures.gear_for_speed(6.7, 8.0, 6.8) == "MEDIUM", "throw at medium anchor reads MEDIUM gear")
	check(ThrowFeatures.gear_for_speed(5.0, 8.0, 6.8) == "", "throw far from both anchors reads no gear")

	# --- Retiming (slow-arm oddity) ---------------------------------------
	check(absf(ThrowFeatures.compute_warp(4.0, 96.0) - 2.4) < 0.01, "slow arm (4 m/s) at 96 mph warps 2.4x")
	check(absf(ThrowFeatures.compute_warp(12.0, 96.0) - 1.0) < 0.01, "fast arm needs no warp (clamped at 1.0)")
	check(absf(ThrowFeatures.compute_warp(2.0, 96.0) - 3.0) < 0.01, "warp bounded at 3.0x, never absurd")
	var motion: Array = make_motion(rng, 8.0, false, 0.0)
	var d0: int = ThrowFeatures.delivery_start_index(motion)
	check(d0 > 0 and d0 < motion.size() - 2, "delivery start found inside the motion (%d of %d)" % [d0, motion.size()])
	var retimed: Array = ThrowFeatures.retime_samples(motion, 2.0)
	check(retimed.size() == motion.size(), "retiming keeps every sample")
	var orig_first: Dictionary = motion[d0]
	var orig_last: Dictionary = motion[motion.size() - 1]
	var new_first: Dictionary = retimed[d0]
	var new_last: Dictionary = retimed[retimed.size() - 1]
	var orig_delivery: float = float(orig_last["t"]) - float(orig_first["t"])
	var new_delivery: float = float(new_last["t"]) - float(new_first["t"])
	check(absf(new_delivery - orig_delivery / 2.0) < 0.01, "delivery phase compresses by the warp factor (%.3fs -> %.3fs)" % [orig_delivery, new_delivery])
	var orig_pos: Vector3 = orig_last["p"]
	var new_pos: Vector3 = new_last["p"]
	check(orig_pos.distance_to(new_pos) < 0.0001, "retiming preserves the release position")

	# --- Flight ------------------------------------------------------------
	var fb_spin: Dictionary = ThrowFeatures.spin_params("FB", 0.2)
	var fb_axis: Vector3 = fb_spin["axis"]
	var fb_flight: Dictionary = ThrowFeatures.simulate_flight(
		Vector3(0.18, 1.72, -0.30),
		Vector3(0.0, -0.015, -1.0).normalized() * (96.0 / ThrowFeatures.MPH_PER_MPS),
		fb_axis, float(fb_spin["rate"]))
	check(bool(fb_flight["crossed"]), "96 mph fastball reaches the plate")
	check(float(fb_flight["time"]) > 0.36 and float(fb_flight["time"]) < 0.55,
		"fastball flight time is realistic (%.3fs)" % float(fb_flight["time"]))
	var fb_cross: Vector3 = fb_flight["cross_pos"]
	check(fb_cross.y > 0.2 and fb_cross.y < 1.8, "fastball crosses in a sane zone band (y=%.2f)" % fb_cross.y)

	var slow_speed: float = 34.0
	var fb_slow: Dictionary = ThrowFeatures.simulate_flight(
		Vector3(0.18, 1.72, -0.30),
		Vector3(0.0, -0.015, -1.0).normalized() * slow_speed,
		fb_axis, float(fb_spin["rate"]))
	var cb_spin: Dictionary = ThrowFeatures.spin_params("CB", 0.8)
	var cb_axis: Vector3 = cb_spin["axis"]
	var cb_flight: Dictionary = ThrowFeatures.simulate_flight(
		Vector3(0.18, 1.72, -0.30),
		Vector3(0.0, -0.015, -1.0).normalized() * slow_speed,
		cb_axis, float(cb_spin["rate"]))
	var fb_slow_cross: Vector3 = fb_slow["cross_pos"]
	var cb_cross: Vector3 = cb_flight["cross_pos"]
	check(cb_cross.y < fb_slow_cross.y - 0.25,
		"curveball breaks: crosses %.2fm lower than a same-speed fastball (%.2f vs %.2f)" % [fb_slow_cross.y - cb_cross.y, cb_cross.y, fb_slow_cross.y])

	# --- Profile store ------------------------------------------------------
	var path: String = "user://test_profile.json"
	var data: Dictionary = {"hand": "R", "vals": [1.5, 2.5, 3.5]}
	check(ProfileStore.save_profile(path, data), "profile saves")
	var loaded: Dictionary = ProfileStore.load_profile(path)
	check(String(loaded.get("hand", "")) == "R", "profile round-trips hand")
	var vals: Array = loaded.get("vals", [])
	check(vals.size() == 3 and absf(float(vals[1]) - 2.5) < 0.001, "profile round-trips float arrays")
	ProfileStore.delete_profile(path)
	check(ProfileStore.load_profile(path).is_empty(), "profile deletes")

	print("---")
	if failures == 0:
		print("ALL %d CHECKS PASSED" % checks)
	else:
		print("%d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
