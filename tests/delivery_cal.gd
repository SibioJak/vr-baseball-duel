extends SceneTree

## Fourteenth pass: DELIVERY CALIBRATION. The standing Re-gaze fit is
## unstable per session (fitted corrections 0.26 / 7.61 / 8.44 deg in
## sessions 4-6) and the delivery itself carries an offset the stance
## never shows. The fix measures the offset where it lives: press
## "Delivery cal", throw free throws aimed at the middle of the
## pitch box; the component-wise MEDIAN of their gaze-corrected
## targets becomes the delivery anchor, and every later target is
## shifted by -(anchor - zone centre), with the centre recomputed
## from the CURRENT posture's zone values at aim time. Runtime only:
## a fresh launch starts uncalibrated, so a stale anchor from another
## session's headset seating can never silently apply.
##
## Fifteenth pass: the capture set is FIVE counted throws, not three
## (a 3-throw median is one real throw's value, noise included - the
## session-7 anchor overshot y by 0.44 m), and the prompt asks for
## pitches thrown like his real ones, not "EASY" ones (an easy
## overhand capture set measures a different motion than his angled
## game-effort slot). Negative controls: against the PRE-pass-14 code
## this suite fails outright (no delivery state, no button, no
## gaze_cross, gaze target unshifted); against the PASS-14 code it
## fails the size checks by name - the panel says "of 3" and the
## anchor activates after the 3rd counted throw.
##
## Run: godot --headless --path . --script tests/delivery_cal.gd

var failures: int = 0
var checks: int = 0
var main: Node

const HEAD_POS := Vector3(0.05, 1.68, 0.35)
const TOL: float = 0.03


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


## Same motion generator as smoke_main.gd (kept local so this file
## runs standalone).
func make_motion(peak_speed: float) -> Array:
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
		var lv: Vector3 = Vector3.ZERO
		if i2 > 0:
			var prev: Vector3 = positions[i2 - 1]
			var cur: Vector3 = positions[i2]
			lv = (cur - prev) / (duration / float(steps))
		samples.append(ThrowFeatures.make_sample(float(i2) / 90.0, positions[i2], lv, Vector3(2.0, 0.5, 0.3)))
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


## Stamp a constant head pose onto the motion: head at HEAD_POS,
## looking exactly at `target` on the plate plane, so with an
## identity gaze correction the gaze cross IS `target`.
func with_head(samples: Array, target: Vector3) -> Array:
	var dir: Vector3 = (target - HEAD_POS).normalized()
	var q: Quaternion = Basis.looking_at(dir, Vector3.UP).get_rotation_quaternion()
	for raw: Variant in samples:
		var s: Dictionary = raw
		s["hp"] = HEAD_POS
		s["hq"] = q
	return samples


func arr3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() == 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3(999.0, 999.0, 999.0)


func last_record() -> Dictionary:
	var lines: Array = FileAccess.get_file_as_string("user://throws.jsonl").split("\n", false)
	if lines.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(lines[lines.size() - 1])
	if parsed is Dictionary:
		return parsed
	return {}


func throw_at(target: Vector3, speed: float = 8.0) -> Dictionary:
	main.ring = with_head(make_motion(speed), target).duplicate()
	main._finalize_throw()
	return last_record()


func find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for child: Node in node.get_children():
		var hit: Button = find_button(child, text)
		if hit != null:
			return hit
	return null


func aim_pub(samples: Array, rel_pos: Vector3) -> Dictionary:
	var spin: Dictionary = ThrowFeatures.spin_params("FB", 0.5)
	var aim: Dictionary = main._compute_aim(samples, rel_pos, 90.0, spin["axis"], float(spin["rate"]))
	return aim.get("public", {})


func _init() -> void:
	_run()


func _run() -> void:
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	root.add_child(main)
	await create_timer(0.2).timeout
	check(main != null, "main scene instantiated")

	# --- fresh launch: no delivery calibration may pre-exist -------
	check(main.get("delivery_active") == false,
		"fresh launch: delivery_active is false (got %s)" % str(main.get("delivery_active")))
	check(main.get("delivery_capturing") == false,
		"fresh launch: not capturing")
	check(main.status_label.text.contains("Delivery: not calibrated this session"),
		"fresh launch: panel status says delivery is not calibrated this session")

	# Baseline state shared by the sections below: wiped profile,
	# identity gaze correction, a real FB template, sane calibration.
	main._on_wipe()
	main.calib_max = 7.7
	main.gaze_correction = Quaternion.IDENTITY
	main.gaze_calibrated = true
	var feats: Array = []
	for n: int in 3:
		feats.append(ThrowFeatures.extract_features(make_motion(8.0)))
	main.templates = {"FB": ThrowFeatures.build_template(feats)}

	# --- offset math at _compute_aim level ---------------------------
	# Anchor straight from the spec's numbers: capture targets
	# centred (0.80, 1.10), standing zone centre (0, 0.77) -> offset
	# (0.80, 0.33); a throw with that same gaze target must be
	# applied to (0.00, 0.77) exactly.
	main.set("delivery_anchor", Vector3(0.80, 1.10, ThrowFeatures.PLATE_Z))
	main.set("delivery_active", true)
	main.set("delivery_capturing", false)
	var samples_b: Array = with_head(make_motion(8.0), Vector3(0.80, 1.10, ThrowFeatures.PLATE_Z))
	var rel_b: Dictionary = samples_b[samples_b.size() - 1]
	var pub_b: Dictionary = aim_pub(samples_b, rel_b["p"])
	var gaze_b: Vector3 = arr3(pub_b.get("gaze_cross", null)) if pub_b.get("gaze_cross") is Array else Vector3(999, 999, 999)
	# gaze_cross rides as a Vector3 in the public block, not JSON.
	if pub_b.get("gaze_cross") is Vector3:
		gaze_b = pub_b["gaze_cross"]
	check(gaze_b.distance_to(Vector3(0.80, 1.10, ThrowFeatures.PLATE_Z)) < TOL,
		"offset math: public block carries the pre-offset gaze_cross (%.2f, %.2f)" % [gaze_b.x, gaze_b.y])
	var tgt_b: Vector3 = pub_b.get("target_cross", Vector3(999, 999, 999))
	check(tgt_b.distance_to(Vector3(0.00, 0.77, ThrowFeatures.PLATE_Z)) < TOL,
		"offset math: gaze target (0.80, 1.10) is applied to zone centre (0.00, 0.77) (got %.2f, %.2f)" % [tgt_b.x, tgt_b.y])
	check(float(pub_b.get("solver_error_m", 9.0)) <= 0.05,
		"offset math: solver error stays small (%.3f m)" % float(pub_b.get("solver_error_m", 9.0)))

	# Posture: same anchor, sitting zone (centre y 0.69) - the y
	# offset is recomputed against the CURRENT centre at aim time,
	# so the applied target must land on (0.00, 0.69).
	main._on_posture_toggle()
	check(main.zone_bottom < 0.45, "posture: sitting zone values live (%.2f-%.2f)" % [main.zone_bottom, main.zone_top])
	var pub_p: Dictionary = aim_pub(samples_b, rel_b["p"])
	var tgt_p: Vector3 = pub_p.get("target_cross", Vector3(999, 999, 999))
	check(tgt_p.distance_to(Vector3(0.00, 0.69, ThrowFeatures.PLATE_Z)) < TOL,
		"posture: applied target recomputed vs sitting centre (got %.2f, %.2f)" % [tgt_p.x, tgt_p.y])
	main._on_posture_toggle()

	# Turn delivery back off for the full-path section.
	main.set("delivery_active", false)
	main.set("delivery_capturing", false)

	# --- full path: button -> 5 capture throws -> corrected --------
	if not main.has_method("_on_delivery_cal"):
		check(false, "delivery cal: panel handler exists")
	else:
		main._on_clear_throw_log()
		var btn: Button = find_button(main.panel_viewport, "Delivery cal")
		check(btn != null, "delivery cal: a 'Delivery cal' button sits on the panel")
		if btn != null:
			btn.pressed.emit()
		check(main.get("delivery_capturing") == true, "delivery cal: pressing the button starts a capture set")
		check(main.prompt_label.text.contains("Delivery calibration: throw 1 of 5"),
			"delivery cal: panel prompts throw 1 of 5 (prompt: %s)" % main.prompt_label.text)
		check(main.prompt_label.text.contains("like your real pitches")
			and not main.prompt_label.text.contains("EASY"),
			"delivery cal: prompt asks for real pitches, not EASY ones (prompt: %s)" % main.prompt_label.text)

		# A throw with NO head data must not count and must not end
		# the capture; its record is not a delivery-cal record.
		main.ring = make_motion(8.0).duplicate()
		main._finalize_throw()
		var tgt_arr_v: Variant = main.get("delivery_targets")
		check(tgt_arr_v is Array and (tgt_arr_v as Array).is_empty(),
			"delivery cal: a headless throw does not count toward the 5")
		check(main.get("delivery_capturing") == true, "delivery cal: capture continues after a headless throw")
		var headless_rec: Dictionary = last_record()
		check(headless_rec.get("delivery_cal") != true and headless_rec.get("gaze_cross") == null,
			"delivery cal: headless record carries no delivery_cal flag and no gaze_cross")

		# The median-of-5 robustness set: four throws around (0.8,
		# 1.1) and one wild (2.50, 2.00). Component medians: xs sort
		# 0.75, 0.80, 0.85, 0.90, 2.50 -> 0.85 (throw 2's x); ys sort
		# 1.00, 1.05, 1.10, 1.15, 2.00 -> 1.10 (throw 1's y) - so the
		# anchor (0.85, 1.10) is no single throw's pair, the wild
		# throw cannot drag it, and it is NOT the mean (1.16, 1.26).
		var cap_targets: Array = [
			Vector3(0.80, 1.10, ThrowFeatures.PLATE_Z),
			Vector3(0.85, 1.05, ThrowFeatures.PLATE_Z),
			Vector3(0.75, 1.15, ThrowFeatures.PLATE_Z),
			Vector3(0.90, 1.00, ThrowFeatures.PLATE_Z),
			Vector3(2.50, 2.00, ThrowFeatures.PLATE_Z),
		]
		for ci: int in cap_targets.size():
			var want: Vector3 = cap_targets[ci]
			var rec: Dictionary = throw_at(want)
			check(rec.get("delivery_cal") == true,
				"delivery cal: capture throw %d is flagged delivery_cal in its record" % (ci + 1))
			var rec_gaze: Vector3 = arr3(rec.get("gaze_cross"))
			check(rec_gaze.distance_to(want) < TOL,
				"delivery cal: capture throw %d's gaze_cross recovers its target (%.2f, %.2f)" % [ci + 1, rec_gaze.x, rec_gaze.y])
			check(arr3(rec.get("target_cross")).distance_to(rec_gaze) < TOL,
				"delivery cal: during capture no offset is applied (target == gaze_cross)")
			if ci == 0:
				check(main.prompt_label.text.contains("throw 2 of 5"),
					"delivery cal: panel prompts throw 2 of 5 after the first counted throw")
			if ci == 2:
				# THE pass-15 negative control by name: three counted
				# throws must NOT complete the set any more (in the
				# pass-14 code the calibration activates right here).
				check(main.get("delivery_capturing") == true,
					"delivery cal (pass 15): capture is still running after 3 counted throws")
				check(main.get("delivery_active") == false,
					"delivery cal (pass 15): anchor is NOT yet active after 3 counted throws")
		check(main.get("delivery_capturing") == false, "delivery cal: capture ends after the 5th counted throw")
		check(main.get("delivery_active") == true, "delivery cal: calibration activates on completion")
		var anchor: Vector3 = main.get("delivery_anchor")
		check(absf(anchor.x - 0.85) < TOL,
			"delivery cal: anchor x is the component median 0.85 (got %.2f)" % anchor.x)
		check(absf(anchor.y - 1.10) < TOL,
			"delivery cal: anchor y is the component median 1.10 (got %.2f)" % anchor.y)
		check(anchor.distance_to(Vector3(0.85, 1.10, ThrowFeatures.PLATE_Z)) < TOL,
			"delivery cal: anchor is the component median (0.85, 1.10), not the mean (got %.2f, %.2f)" % [anchor.x, anchor.y])
		var anchor_is_a_throw: bool = false
		for raw_cap: Variant in cap_targets:
			var cap_pt: Vector3 = raw_cap
			if absf(anchor.x - cap_pt.x) < TOL and absf(anchor.y - cap_pt.y) < TOL:
				anchor_is_a_throw = true
		check(not anchor_is_a_throw,
			"delivery cal: anchor pair is no single capture throw's pair (components come from different throws)")
		check(main.last_result.contains("Delivery calibrated")
			and main.last_result.contains("right") and main.last_result.contains("high")
			and main.last_result.contains("corrected"),
			"delivery cal: completion feedback names the offset in plain words (%s)" % main.last_result)
		check(main.status_label.text.contains("Delivery calibrated"),
			"delivery cal: panel status shows the calibrated state")
		var st3: Dictionary = last_record().get("state", {})
		check(arr3(st3.get("delivery_anchor")).distance_to(Vector3(0.85, 1.10, ThrowFeatures.PLATE_Z)) < TOL,
			"delivery cal: record state snapshot carries the anchor")
		check(st3.get("delivery_active") == true
			and absf(float(st3.get("delivery_offset_x", 999.0)) - 0.85) < TOL
			and absf(float(st3.get("delivery_offset_y", 999.0)) - 0.33) < TOL,
			"delivery cal: record state carries delivery_active + offsets (x %s, y %s)" % [str(st3.get("delivery_offset_x")), str(st3.get("delivery_offset_y"))])

		# A free throw wearing the anchor's own gaze target must now
		# land its APPLIED target on zone centre, solver intact.
		var rec4: Dictionary = throw_at(Vector3(0.85, 1.10, ThrowFeatures.PLATE_Z))
		check(arr3(rec4.get("gaze_cross")).distance_to(Vector3(0.85, 1.10, ThrowFeatures.PLATE_Z)) < TOL,
			"delivery cal: post-calibration record keeps the pre-offset gaze_cross")
		check(arr3(rec4.get("target_cross")).distance_to(Vector3(0.00, 0.77, ThrowFeatures.PLATE_Z)) < TOL,
			"delivery cal: post-calibration applied target is zone centre (got %.2f, %.2f)" % [arr3(rec4.get("target_cross")).x, arr3(rec4.get("target_cross")).y])
		check(float(rec4.get("solver_error_m", 9.0)) <= 0.021,
			"delivery cal: solver_error_m still <= 0.02 through the corrected path (%.3f)" % float(rec4.get("solver_error_m", 9.0)))
		check(rec4.get("delivery_cal") != true,
			"delivery cal: a normal free throw after calibration is not flagged delivery_cal")

		# Re-pressing starts a FRESH set: while it runs, the old
		# anchor must not shift capture throws, must not be replaced
		# early (a 3-throw-old habit), and completing the 5-throw
		# set replaces the anchor.
		btn = find_button(main.panel_viewport, "Delivery cal")
		if btn != null:
			btn.pressed.emit()
		var rec5: Dictionary = throw_at(Vector3(0.85, 1.10, ThrowFeatures.PLATE_Z))
		check(arr3(rec5.get("target_cross")).distance_to(arr3(rec5.get("gaze_cross"))) < TOL,
			"delivery cal: during a re-capture the old offset is not applied")
		throw_at(Vector3(0.10, 0.80, ThrowFeatures.PLATE_Z))
		throw_at(Vector3(0.10, 0.80, ThrowFeatures.PLATE_Z))
		var anchor_mid: Vector3 = main.get("delivery_anchor")
		check(anchor_mid.distance_to(Vector3(0.85, 1.10, ThrowFeatures.PLATE_Z)) < TOL,
			"delivery cal (pass 15): 3 re-capture throws do not yet replace the anchor (still %.2f, %.2f)" % [anchor_mid.x, anchor_mid.y])
		throw_at(Vector3(0.10, 0.80, ThrowFeatures.PLATE_Z))
		throw_at(Vector3(0.10, 0.80, ThrowFeatures.PLATE_Z))
		var anchor2: Vector3 = main.get("delivery_anchor")
		check(main.get("delivery_active") == true
			and anchor2.distance_to(Vector3(0.10, 0.80, ThrowFeatures.PLATE_Z)) < TOL,
			"delivery cal: completing a fresh 5-throw set replaces the anchor (got %.2f, %.2f)" % [anchor2.x, anchor2.y])

	main._on_wipe()
	print("---")
	if failures == 0:
		print("DELIVERY CAL: ALL %d CHECKS PASSED" % checks)
	else:
		print("DELIVERY CAL: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
