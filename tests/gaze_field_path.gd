extends SceneTree

## Twelfth pass: END-TO-END gaze test through the FULL field path.
## Pass 11's gaze test (run_tests.gd) fitted and applied in one frame
## in memory and passed - but Chris's field session (throws-3.jsonl)
## came back with every pitch ~1.4 m right of target: the fitted
## correction's effect arrived INVERTED somewhere along the real route
## (real dwell capture -> fit -> profile save -> fresh load -> real
## _compute_aim). This test walks exactly that route wearing a
## synthetic head with Chris's measured bias (headset forward sits
## +5 deg yaw / +4 deg pitch off his eye line) and asserts the
## corrected target lands on zone center. Run:
##   godot --headless --path . --script tests/gaze_field_path.gd
## It prints the decomposition (raw cross, in-memory-corrected cross,
## loaded-corrected target) so a failure names its own layer.

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


## Same motion generator shape as smoke_main.gd (kept local so this
## file runs standalone).
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


func _init() -> void:
	_run()


func _run() -> void:
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	root.add_child(main)
	await create_timer(0.2).timeout
	check(main != null, "main scene instantiated")

	main._on_wipe()
	# The field condition at Re-gaze / enrollment time: a profile with
	# calibration already exists, so _finish_gaze's _save_profile()
	# actually writes (its guard skips a virgin profile).
	main.calib_max = 7.7

	var head_pos := Vector3(0.05, 1.68, 0.35)
	var center := Vector3(0.0, (main.zone_bottom + main.zone_top) * 0.5, ThrowFeatures.PLATE_Z)
	# The worn bias: reported head forward = bias * eye line, with the
	# bias Chris's sessions measured (right + up). Godot euler is
	# (pitch, yaw, roll); +pitch tilts the forward up, -yaw turns it
	# toward +X (right, plate space).
	var bias_q := Quaternion.from_euler(Vector3(deg_to_rad(4.0), deg_to_rad(-5.0), 0.0))

	# Basis-vs-quaternion consistency (the capture path reads
	# -basis.z; the apply path reads q * (0,0,-1) off the SAME basis).
	# Print the angle between the two readings of one worn pose.
	var probe_fwd: Vector3 = (bias_q * (center - head_pos).normalized()).normalized()
	var probe_basis := Basis.looking_at(probe_fwd, Vector3.UP)
	var via_basis: Vector3 = (-probe_basis.z).normalized()
	var via_quat: Vector3 = (probe_basis.get_rotation_quaternion() * Vector3(0.0, 0.0, -1.0)).normalized()
	print("INFO  -basis.z vs q*(0,0,-1) on one worn pose: %.4f deg apart" % rad_to_deg(via_basis.angle_to(via_quat)))

	# --- phase 1: REAL dwell capture -> REAL fit -> REAL save ---
	main._start_enrollment(["gaze"])
	check(main.gaze_targets.size() == 5, "gaze step lit five targets")
	var worn_fwds: Array = []
	for ti: int in 5:
		var idx_before: int = main.gaze_idx
		var target: Vector3 = main.gaze_targets[idx_before]
		var eye_dir: Vector3 = (target - head_pos).normalized()
		var worn: Vector3 = (bias_q * eye_dir).normalized()
		worn_fwds.append(worn)
		main.cam.transform = Transform3D(Basis.looking_at(worn, Vector3.UP), head_pos)
		var guard: int = 0
		while main.gaze_idx == idx_before and guard < 80:
			main._update_gaze(0.1)
			guard += 1
		check(main.gaze_idx == idx_before + 1, "real dwell captured target %d" % (idx_before + 1))
	check(main.gaze_calibrated, "gaze fit stored the correction")
	check(not main.enrolling, "gaze-only enrollment completed")
	for ci: int in main.gaze_captures.size():
		var cap: Dictionary = main.gaze_captures[ci]
		var cap_fwd: Vector3 = cap["head_fwd"]
		var cap_pos: Vector3 = cap["head_pos"]
		var wf: Vector3 = worn_fwds[ci]
		print("INFO  capture %d: worn-vs-recorded fwd %.3f deg, pos err %.3f m, target %s" % [
			ci, rad_to_deg(cap_fwd.angle_to(wf)), cap_pos.distance_to(head_pos), str(cap["target"])])
	check(FileAccess.file_exists("user://duel_profile.json"), "profile file written by the gaze save")
	var in_mem_q: Quaternion = main.gaze_correction
	print("INFO  fitted correction: %.2f deg total (panel offset %.1f, fit err %.2f)" % [
		rad_to_deg(Quaternion.IDENTITY.angle_to(in_mem_q)), main.gaze_offset_deg, main.gaze_fit_error_deg])

	# --- phase 2: fresh state -> REAL load -> REAL _compute_aim ---
	main.gaze_correction = Quaternion.IDENTITY
	main.gaze_calibrated = false
	main.gaze_offset_deg = 0.0
	main.gaze_fit_error_deg = -1.0
	main._load_profile()
	check(main.gaze_calibrated, "loaded profile restores gaze_calibrated")
	var ser_err: float = rad_to_deg(in_mem_q.angle_to(main.gaze_correction))
	check(ser_err < 0.1, "correction survives save/load (%.3f deg)" % ser_err)

	# Synthetic throw: the player looks at zone center wearing the
	# same bias; head samples ride the motion exactly as the sampler
	# writes them (hp = head pos, hq = worn orientation).
	var throw_samples: Array = make_motion(8.0)
	var eye_center: Vector3 = (center - head_pos).normalized()
	var worn_center: Vector3 = (bias_q * eye_center).normalized()
	var worn_q: Quaternion = Basis.looking_at(worn_center, Vector3.UP).get_rotation_quaternion()
	for raw_s: Variant in throw_samples:
		var smp2: Dictionary = raw_s
		smp2["hp"] = head_pos
		smp2["hq"] = worn_q
	var rel: Dictionary = throw_samples[throw_samples.size() - 1]
	var rel_pos: Vector3 = rel["p"]
	var spin: Dictionary = ThrowFeatures.spin_params("FB", 0.5)
	var aim: Dictionary = main._compute_aim(throw_samples, rel_pos, 90.0, spin["axis"], float(spin["rate"]))
	check(not aim.is_empty(), "_compute_aim produced a head-line aim")
	var pub: Dictionary = aim.get("public", {})
	var raw_cross: Variant = pub.get("head_cross_raw", null)
	var target_cross: Variant = pub.get("target_cross", null)
	print("INFO  bias signature worn: raw cross should sit right/up of center")
	if raw_cross is Vector3:
		var rc: Vector3 = raw_cross
		print("INFO  raw head cross: (%.2f, %.2f) vs center (%.2f, %.2f)" % [rc.x, rc.y, center.x, center.y])
		check(rc.x - center.x > 0.6, "raw cross carries the worn right bias (dx %.2f m)" % (rc.x - center.x))
	if target_cross is Vector3:
		var tc: Vector3 = target_cross
		var err: float = Vector2(tc.x - center.x, tc.y - center.y).length()
		print("INFO  LOADED-corrected target: (%.2f, %.2f) - error %.2f m" % [tc.x, tc.y, err])
		check(err <= 0.15, "E2E: corrected target within 0.15 m of zone center (err %.2f m)" % err)
	else:
		check(false, "E2E: aim carried a target cross")
	# Bisect aid: the same throw corrected by the IN-MEMORY fit.
	var saved_q: Quaternion = main.gaze_correction
	main.gaze_correction = in_mem_q
	var aim2: Dictionary = main._compute_aim(throw_samples, rel_pos, 90.0, spin["axis"], float(spin["rate"]))
	main.gaze_correction = saved_q
	var pub2: Dictionary = aim2.get("public", {})
	var tc2_v: Variant = pub2.get("target_cross", null)
	if tc2_v is Vector3:
		var tc2: Vector3 = tc2_v
		var err2: float = Vector2(tc2.x - center.x, tc2.y - center.y).length()
		print("INFO  IN-MEMORY-corrected target: (%.2f, %.2f) - error %.2f m" % [tc2.x, tc2.y, err2])
	else:
		print("INFO  in-memory _compute_aim returned no target")

	# --- phase 3 (twelfth pass): ONE poisoned capture ----------------
	# The dwell certifies any STILL head - there is no proximity gate,
	# by design (a large-bias player is who the step exists for). But
	# the natural way to run this step is: press Re-gaze ON THE PANEL,
	# read the prompt, THEN turn to the plate. If the head holds still
	# on the panel for the first target's dwell, that capture pairs a
	# panel forward (~40 deg off-axis) with the center target, and a
	# plain mean over the five deltas lets it drag the correction
	# sideways - Chris's session 3: every pitch ~1.4 m right of his
	# raw look. Drive exactly that: target 1 captured looking at the
	# panel (perfectly still), targets 2-5 honest.
	main._on_wipe()
	main.calib_max = 7.7
	var panel_pos := Vector3(-1.0, 1.32, -1.50)
	var panel_eye: Vector3 = (panel_pos - head_pos).normalized()
	var panel_worn: Vector3 = (bias_q * panel_eye).normalized()
	main._start_enrollment(["gaze"])
	for ti2: int in 5:
		var idx_b: int = main.gaze_idx
		var tgt2: Vector3 = main.gaze_targets[idx_b]
		var look: Vector3 = (bias_q * (tgt2 - head_pos).normalized()).normalized()
		if idx_b == 0:
			look = panel_worn
		main.cam.transform = Transform3D(Basis.looking_at(look, Vector3.UP), head_pos)
		var guard2: int = 0
		while main.gaze_idx == idx_b and guard2 < 80:
			main._update_gaze(0.1)
			guard2 += 1
		check(main.gaze_idx == idx_b + 1, "phase 3: dwell captured target %d" % (idx_b + 1))
	check(main.gaze_calibrated, "phase 3: gaze calibrated despite one panel-look capture")
	var dropped_v: Variant = main.get("gaze_dropped_count")
	main.gaze_correction = Quaternion.IDENTITY
	main.gaze_calibrated = false
	main._load_profile()
	var aim3: Dictionary = main._compute_aim(throw_samples, rel_pos, 90.0, spin["axis"], float(spin["rate"]))
	var pub3: Dictionary = aim3.get("public", {})
	var tc3_v: Variant = pub3.get("target_cross", null)
	if tc3_v is Vector3:
		var tc3: Vector3 = tc3_v
		var err3: float = Vector2(tc3.x - center.x, tc3.y - center.y).length()
		print("INFO  phase 3 target after poisoned calibration: (%.2f, %.2f) - error %.2f m" % [tc3.x, tc3.y, err3])
		check(err3 <= 0.15, "phase 3: E2E target within 0.15 m despite the panel-look capture (err %.2f m)" % err3)
	else:
		check(false, "phase 3: aim carried a target cross")
	check(dropped_v is int and int(dropped_v) == 1,
		"phase 3: robust fit dropped the poisoned capture (dropped=%s)" % str(dropped_v))
	check(main.gaze_fit_error_deg >= 0.0 and main.gaze_fit_error_deg < 1.0,
		"phase 3: post-drop fit residual is honest (%.2f deg)" % main.gaze_fit_error_deg)

	# --- phase 4 (twelfth pass): the correction is IN the record -----
	# Session 3's miss could not be decomposed from the log alone
	# because the fitted correction was never recorded. Throw once
	# through _finalize_throw and read the record's state snapshot.
	main._on_clear_throw_log()
	main.ring = throw_samples.duplicate()
	main._finalize_throw()
	var p4_lines: Array = FileAccess.get_file_as_string("user://throws.jsonl").split("\n", false)
	var p4_parsed: Variant = JSON.parse_string(p4_lines[p4_lines.size() - 1]) if not p4_lines.is_empty() else null
	check(p4_parsed is Dictionary, "phase 4: record parses")
	if p4_parsed is Dictionary:
		var p4_rec: Dictionary = p4_parsed
		var p4_state: Variant = p4_rec.get("state")
		check(p4_state is Dictionary and (p4_state as Dictionary).get("gaze_correction_quat") is Array
			and ((p4_state as Dictionary)["gaze_correction_quat"] as Array).size() == 4,
			"phase 4: state snapshot carries gaze_correction_quat[4]")
		check(p4_state is Dictionary and (p4_state as Dictionary).get("gaze_offset_deg") != null
			and (p4_state as Dictionary).get("gaze_fit_residual_deg") != null,
			"phase 4: state snapshot carries gaze offset + fit residual")

	main._on_wipe()
	print("---")
	if failures == 0:
		print("GAZE FIELD PATH: ALL %d CHECKS PASSED" % checks)
	else:
		print("GAZE FIELD PATH: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
