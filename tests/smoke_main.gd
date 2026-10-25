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

	# Pre-enrollment throw: no templates yet, but the ball must still fly
	# ("just a throw") and the gun board stays dark for it.
	var stray_motion: Array = make_motion(7.5, false)
	var stray_feats: PackedFloat32Array = ThrowFeatures.extract_features(stray_motion)
	main._free_throw(stray_feats, 7.5, stray_motion)
	check(main.flights.size() == 1, "pre-enrollment throw produced a flight")
	check(main.last_result.begins_with("Enroll a fastball"), "pre-enrollment throw explained on the panel")
	for f: Dictionary in main.flights:
		(f["node"] as Node).queue_free()
	main.flights.clear()

	# Gaze dwell (eleventh pass): capture is by head stillness alone -
	# a wandering head must NEVER capture, a still one captures each
	# target in turn and the step fits the correction by itself.
	main._start_enrollment(["gaze"])
	check(main.gaze_root.visible, "gaze targets show on the gaze step")
	for wi: int in 30:
		var yaw: float = deg_to_rad(3.0) if wi % 2 == 0 else deg_to_rad(-3.0)
		main.cam.transform = Transform3D(Basis.from_euler(Vector3(0.0, yaw, 0.0)), Vector3.ZERO)
		main._update_gaze(0.1)
	check(main.gaze_idx == 0, "gaze dwell does NOT capture a wandering head (idx %d)" % main.gaze_idx)
	main.cam.transform = Transform3D.IDENTITY
	for si: int in 40:
		main._update_gaze(0.1)
	check(main.gaze_idx >= 5, "gaze dwell captures all five targets on a still head")
	check(main.gaze_calibrated, "gaze step fitted + stored the correction")
	check(not main.enrolling, "gaze-only enrollment completes after the fifth capture")
	check(not main.gaze_root.visible, "gaze targets hide when the gaze step ends")

	# CB cue flow (seventh pass): the cue picker and the ghost arm exist
	# only on the curveball step; the picked picture is stored with the
	# CB template. Drive a CB-only enrollment first.
	main._start_enrollment(["cb"])
	check(main.cue_row.visible, "cue picker shows on the CB step")
	check(main.ghost_root.visible, "ghost arm demos on the CB step")
	check(main.prompt_label.text.contains("DOORKNOB"), "CB prompt names the default cue (doorknob)")
	main._set_cb_cue("shade")
	check(main.cb_cue == "shade", "cue picker switches the cue")
	feed(main, true, 6.3, 3)
	check(String(main.templates["CB"].get("cue", "")) == "shade", "chosen cue stored with the CB template")
	check(not main.ghost_root.visible, "ghost arm hides when the CB step ends")
	check(not main.cue_row.visible, "cue picker hides when the CB step ends")

	# FB-only default flow (ninth pass, Chris: fastball only until it
	# works). Begin enrollment runs calib/fb/gears - no CB, no third
	# pitch - and the gun goes live on fastballs alone: full flight,
	# announcement, PBs, WITHOUT the classifier. The recorder flags
	# these verdicts fb_only so they are never read as classifications.
	main._on_wipe()
	main._on_begin()
	check(main.enroll_queue.size() == 5 and String(main.enroll_queue[0]) == "gaze"
		and String(main.enroll_queue[1]) == "calib"
		and String(main.enroll_queue[2]) == "fb"
		and not main.enroll_queue.has("cb") and not main.enroll_queue.has("p3"),
		"default enrollment is gaze + fastball-only (gaze, calib, fb, gears)")
	# The still headless camera captures the gaze step by dwell.
	for gi: int in 40:
		main._update_gaze(0.1)
	check(main.gaze_calibrated and String(main.enroll_queue[main.enroll_idx]) == "calib",
		"gaze step completes by dwell and hands off to calibration")
	feed(main, false, 8.0, 3) # calib
	feed(main, false, 8.1, 3) # fb
	feed(main, false, 8.05, 3) # gear fast (3 throws, median anchor - tenth pass)
	feed(main, false, 6.9, 3) # gear medium
	check(not main.enrolling, "FB-only enrollment completed")
	check(main.templates.has("FB") and not main.templates.has("CB"),
		"FB enrolled, CB not (FB-only state)")
	check(main.mode == 1, "FB-only enrollment lands in FREE_THROW (mode=%d)" % main.mode)
	check(main.last_result.contains("live on fastballs"),
		"finish text says the gun is live on fastballs (%s)" % main.last_result)
	check(main.separation_note == "", "no separation warning in FB-only state")
	check(main.prompt_label.text.contains("live on fastballs"),
		"free-throw prompt says the gun is live on fastballs")
	var fbo_motion: Array = make_motion(7.9, false)
	var fbo_feats: PackedFloat32Array = ThrowFeatures.extract_features(fbo_motion)
	var fbo_before: int = main.flights.size()
	var fbo_v: Variant = main._free_throw(fbo_feats, 7.9, fbo_motion)
	var fbo: Dictionary = fbo_v if fbo_v is Dictionary else {}
	check(bool(fbo.get("fb_only", false)) and not bool(fbo.get("classified", true)),
		"FB-only free throw is FB by mode, not classified")
	check(main.flights.size() == fbo_before + 1, "FB-only free throw produced a flight")
	await create_timer(1.6).timeout
	check(main.last_result.begins_with("Gun:") and main.last_result.contains("FASTBALL"),
		"gun announced the FB-only pitch (%s)" % main.last_result)
	check(not main.board_sub.text.contains("sure"),
		"gun board shows no confidence for an FB-only throw (%s)" % main.board_sub.text)
	check(main.pbs.has("FB"), "FB-only throw recorded a personal best")
	# Recorder: the FB-only verdict lands flagged, via _finalize_throw.
	main._on_clear_throw_log()
	main.ring = make_motion(7.9, false).duplicate()
	main._finalize_throw()
	check(main.throws_recorded == 1, "fb-only recorder: throw appended")
	var fbo_lines: Array = FileAccess.get_file_as_string("user://throws.jsonl").split("\n", false)
	var fbo_parsed: Variant = JSON.parse_string(fbo_lines[0]) if fbo_lines.size() == 1 else null
	if fbo_parsed is Dictionary:
		var fbo_rec: Dictionary = fbo_parsed
		var fbo_verdict: Variant = fbo_rec.get("verdict")
		check(fbo_verdict is Dictionary and bool((fbo_verdict as Dictionary).get("fb_only", false)),
			"fb-only recorder: verdict flagged fb_only")
		check(fbo_verdict is Dictionary and String((fbo_verdict as Dictionary).get("pitch", "")) == "FB"
			and (fbo_verdict as Dictionary).get("confidence") == null,
			"fb-only recorder: pitch FB, confidence null (no classifier ran)")
		check(String(fbo_rec.get("mode", "")) == "free", "fb-only recorder: mode reads free")
	else:
		check(false, "fb-only recorder: record parses as JSON")
	main._on_clear_throw_log()
	# The parked CB machinery still works after all that: Re-enroll CB
	# reaches the cue step and completes.
	main._start_enrollment(["cb"])
	check(main.cue_row.visible and main.ghost_root.visible,
		"Re-enroll CB still reaches the cue step after the FB-only flow")
	feed(main, true, 6.3, 3)
	check(main.templates.has("CB"), "CB enrolls on demand (machinery intact, parked)")

	# Enrollment, driven exactly as grip throws would drive it.
	main._start_enrollment(["calib", "fb", "cb", "p3", "gear_fast", "gear_med"])
	feed(main, false, 8.0, 3) # calib
	check(absf(main.calib_max - 8.0) < 0.01, "calibration stored (%.2f)" % main.calib_max)
	feed(main, false, 8.1, 3) # fb
	feed(main, true, 6.3, 3) # cb
	check(main.templates.has("FB") and main.templates.has("CB"), "FB + CB templates enrolled")
	main._on_skip() # optional third pitch skipped
	feed(main, false, 8.05, 3) # gear fast (3 throws, median anchor - tenth pass)
	feed(main, false, 6.9, 3) # gear medium
	check(not main.enrolling, "enrollment completed")
	check(main.flights.size() >= 10,
		"enrollment throws all flew (quiet) - %d in the air" % main.flights.size())
	check(main.fast_anchor > 7.9 and main.med_anchor > 6.7 and main.med_anchor < main.fast_anchor,
		"gears anchored (FAST %.2f / MED %.2f)" % [main.fast_anchor, main.med_anchor])
	check(main.mode == 2 or main.mode == 1, "mode left SETUP after enrollment (mode=%d)" % main.mode)
	check(FileAccess.file_exists("user://duel_profile.json"), "profile file written")

	# Free throw: classified, flown, announced.
	var fb_motion: Array = make_motion(7.9, false)
	var fb_feats: PackedFloat32Array = ThrowFeatures.extract_features(fb_motion)
	var flights_before: int = main.flights.size()
	main._free_throw(fb_feats, 7.9, fb_motion)
	check(main.flights.size() == flights_before + 1, "free throw produced a flight")
	await create_timer(1.6).timeout
	check(main.last_result.begins_with("Gun:"), "gun announced the pitch (%s)" % main.last_result)
	check(main.pbs.has("FB"), "personal best recorded")

	# Throw recorder (eighth pass): every attempt through _finalize_throw
	# lands in user://throws.jsonl - accepted with verdict, rejected with
	# reason - and Clear truncates.
	main._on_clear_throw_log()
	check(main.throws_recorded == 0, "recorder: clear resets the count")
	var rec_motion: Array = make_motion(7.9, false)
	main.ring = rec_motion.duplicate()
	main._finalize_throw()
	check(main.throws_recorded == 1, "recorder: accepted free throw appended a record")
	var log_lines: Array = FileAccess.get_file_as_string("user://throws.jsonl").split("\n", false)
	check(log_lines.size() == 1, "recorder: one JSONL line on disk")
	var parsed: Variant = JSON.parse_string(log_lines[0]) if log_lines.size() == 1 else null
	check(parsed is Dictionary, "recorder: record parses as JSON")
	if parsed is Dictionary:
		var rec: Dictionary = parsed
		var rec_samples: Variant = rec.get("samples")
		check(rec_samples is Array and (rec_samples as Array).size() >= 20,
			"recorder: trimmed samples embedded (%s)" % (str((rec_samples as Array).size()) if rec_samples is Array else "none"))
		var rec_feats: Variant = rec.get("features")
		check(rec_feats is Dictionary and (rec_feats as Dictionary).size() == 15,
			"recorder: 15 labeled features")
		var rec_intent: Variant = rec.get("intent_dir")
		var rec_frame: Variant = rec.get("release_frame_dir")
		check(rec_intent is Array and (rec_intent as Array).size() == 3
			and rec_frame is Array and (rec_frame as Array).size() == 3,
			"recorder: intent + release-frame directions both kept")
		var rec_verdict: Variant = rec.get("verdict")
		check(rec_verdict is Dictionary and String((rec_verdict as Dictionary).get("pitch", "")) == "FB",
			"recorder: verdict recorded (FB)")
		check(rec_verdict is Dictionary and (rec_verdict as Dictionary).has("call")
			and (rec_verdict as Dictionary).has("plate_cross"),
			"recorder: plate crossing + call recorded")
		check(String(rec.get("outcome", "")) == "accepted", "recorder: outcome accepted")
		check(rec.get("head_fwd_release") == null and rec.get("head_stability_deg") == null,
			"recorder v2: a throw without head data records null head fields, no crash")
		check(int(rec.get("v", 0)) == 3 and rec.get("aim_cross") == null and rec.get("target_cross") == null,
			"recorder v3: a no-head throw flew the old intent path (aim fields null)")
	var soft: Array = []
	for si: int in 20:
		soft.append(ThrowFeatures.make_sample(float(si) / 90.0, Vector3(0.2, 1.4, 0.3), Vector3(0.0, 0.0, -0.5), Vector3.ZERO))
	main.ring = soft
	main._finalize_throw()
	check(main.throws_recorded == 2, "recorder: rejected throw appended too")
	var log_lines2: Array = FileAccess.get_file_as_string("user://throws.jsonl").split("\n", false)
	var parsed2: Variant = JSON.parse_string(log_lines2[log_lines2.size() - 1]) if not log_lines2.is_empty() else null
	check(parsed2 is Dictionary and String((parsed2 as Dictionary).get("outcome", "")) == "rejected"
		and String((parsed2 as Dictionary).get("reason", "")) == "too_soft",
		"recorder: rejection carries its reason (too_soft)")
	main._on_clear_throw_log()
	check(main.throws_recorded == 0 and FileAccess.get_file_as_string("user://throws.jsonl").strip_edges() == "",
		"recorder: clear truncates the log")
	main.ring = rec_motion.duplicate()
	main._finalize_throw()
	check(main.throws_recorded == 1, "recorder: recording resumes after clear")

	# Recorder v2 (tenth pass): the head line rides in the ring. A throw
	# whose samples carry a fixed head pose must land in the log with
	# per-sample hp/hq AND the four precomputed head summaries.
	main._on_clear_throw_log()
	var head_motion: Array = make_motion(7.9, false)
	# Mild, plate-looking head pose: the eleventh-pass aim solver must
	# succeed on this throw so the record carries its aim crosses.
	var head_q := Quaternion.from_euler(Vector3(0.03, -0.04, 0.0))
	for raw_h: Variant in head_motion:
		var hs: Dictionary = raw_h
		hs["hp"] = Vector3(0.05, 1.68, 0.4)
		hs["hq"] = head_q
	main.ring = head_motion.duplicate()
	main._finalize_throw()
	check(main.throws_recorded == 1, "recorder v2: head throw appended")
	var h_lines: Array = FileAccess.get_file_as_string("user://throws.jsonl").split("\n", false)
	var h_parsed: Variant = JSON.parse_string(h_lines[0]) if h_lines.size() == 1 else null
	check(h_parsed is Dictionary and int((h_parsed as Dictionary).get("v", 0)) == 3,
		"recorder v3: record version is 3")
	if h_parsed is Dictionary:
		var h_rec: Dictionary = h_parsed
		var h_samples: Variant = h_rec.get("samples")
		var h_first: Variant = null
		if h_samples is Array and not (h_samples as Array).is_empty():
			h_first = (h_samples as Array)[0]
		check(h_first is Dictionary and (h_first as Dictionary).get("hp") is Array
			and ((h_first as Dictionary)["hp"] as Array).size() == 3
			and (h_first as Dictionary).get("hq") is Array
			and ((h_first as Dictionary)["hq"] as Array).size() == 4,
			"recorder v2: samples carry hp[3] + hq[4]")
		var h_rel_f: Variant = h_rec.get("head_fwd_release")
		var expect_f: Vector3 = (head_q * Vector3(0.0, 0.0, -1.0)).normalized()
		var got_f := Vector3.ZERO
		if h_rel_f is Array and (h_rel_f as Array).size() == 3:
			var h_rel_a: Array = h_rel_f
			got_f = Vector3(float(h_rel_a[0]), float(h_rel_a[1]), float(h_rel_a[2]))
		check(h_rel_f is Array and got_f.angle_to(expect_f) < 0.01,
			"recorder v2: head_fwd_release matches the worn head pose")
		check(h_rec.get("head_fwd_window") is Array and h_rec.get("head_fwd_at_peak") is Array,
			"recorder v2: head_fwd_window + head_fwd_at_peak present")
		check(absf(float(h_rec.get("head_stability_deg", -1.0))) < 0.5,
			"recorder v2: a still head reads ~0 deg stability (got %s)" % str(h_rec.get("head_stability_deg")))
		check(h_rec.get("target_cross") is Array and h_rec.get("aim_cross") is Array
			and h_rec.get("head_cross_raw") is Array,
			"recorder v3: head-data throw carries target / aim / raw head crosses")
		check(absf(float(h_rec.get("scatter_k", -1.0)) - main.scatter_k) < 0.001
			and h_rec.get("gaze_calibrated") is bool,
			"recorder v3: scatter k + gaze flag recorded (k=%s)" % str(h_rec.get("scatter_k")))
	else:
		check(false, "recorder v2: head record parses as JSON")

	# Calibration session lock (tenth pass): a free throw over the
	# calibrated max must NOT move this session's gun. It notes the max
	# on the panel, flags the record, stores it pending - and the
	# pending max merges into calib_max at the next enrollment start.
	main._on_clear_throw_log()
	main.calib_max = 5.0
	var lock_motion: Array = make_motion(7.9, false)
	var lock_feats: PackedFloat32Array = ThrowFeatures.extract_features(lock_motion)
	var lock_v: Variant = main._free_throw(lock_feats, 7.9, lock_motion)
	var lock_o: Dictionary = lock_v if lock_v is Dictionary else {}
	check(absf(main.calib_max - 5.0) < 0.001,
		"calib lock: over-max free throw leaves calib_max at 5.00 (got %.2f)" % main.calib_max)
	check(bool(lock_o.get("over_calib_max", false)), "calib lock: outcome flags over_calib_max")
	check(absf(main.pending_calib_max - 7.9) < 0.001,
		"calib lock: pending max stored (%.2f)" % main.pending_calib_max)
	check(main.last_result.contains("applies next enrollment"),
		"calib lock: panel notes the pending max (%s)" % main.last_result)
	main.ring = lock_motion.duplicate()
	main._finalize_throw()
	var lock_lines: Array = FileAccess.get_file_as_string("user://throws.jsonl").split("\n", false)
	var lock_parsed: Variant = JSON.parse_string(lock_lines[lock_lines.size() - 1]) if not lock_lines.is_empty() else null
	check(lock_parsed is Dictionary and bool((lock_parsed as Dictionary).get("over_calib_max", false)),
		"calib lock: throw record flags over_calib_max")
	main._start_enrollment(["calib"])
	check(absf(main.calib_max - 7.9) < 0.001 and main.pending_calib_max <= 0.001,
		"calib lock: pending max merges into calib_max at enrollment start (%.2f)" % main.calib_max)

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
	check(String(main.templates["CB"].get("cue", "")) == "shade", "profile reload restores the CB cue on the template")
	check(main.cb_cue == "shade", "profile reload restores the cue picker selection")

	# Gear anchors (tenth pass): the step takes 3 throws and settles on
	# their MEDIAN. Feed the split pair from Chris's field session
	# (9.96 + 4.95 - the throws that averaged into mush) plus a middle
	# throw: the step must NOT complete at 2, and the anchor must be
	# the middle value exactly, not any mean (mean of 3 = 7.4533,
	# mean of the old 2 = 7.455 - both outside the tolerance).
	main._start_enrollment(["gear_fast"])
	main.fast_anchor = 0.0
	var gear_motion: Array = make_motion(8.0, false)
	var gear_feats: PackedFloat32Array = ThrowFeatures.extract_features(gear_motion)
	main._enrollment_throw(gear_feats, 9.96, gear_motion)
	main._enrollment_throw(gear_feats, 4.95, gear_motion)
	check(main.enrolling and main.fast_anchor <= 0.001,
		"gear step does not complete at 2 throws anymore")
	main._enrollment_throw(gear_feats, 7.45, gear_motion)
	check(absf(main.fast_anchor - 7.45) < 0.002,
		"gear anchor is the MEDIAN of 3 (got %.3f)" % main.fast_anchor)

	# Profile v2 -> v3 (eleventh pass): the v3 bump adds gaze + scatter
	# and changes NO feature vector, so v2 templates must LOAD (not
	# drop), gaze starts uncalibrated, and the panel suggests Re-gaze.
	var v2_feats: Array = []
	for v2i: int in 15:
		v2_feats.append(0.05 * float(v2i))
	var v2_data: Dictionary = {
		"version": 2, "hand": "R", "posture": "STAND",
		"calib_max": 7.7, "boost": 1.0, "fast_anchor": 7.6, "med_anchor": 6.6,
		"pbs": {}, "templates": {"FB": {"features": v2_feats, "spread": 0.3}}, "pitches": {},
	}
	check(ProfileStore.save_profile("user://duel_profile.json", v2_data), "v2 profile written for the v3 upgrade test")
	main.templates.clear()
	main.gaze_calibrated = false
	main._load_profile()
	check(main.templates.has("FB"), "v2 templates SURVIVE the v3 bump (no vector change)")
	check(not main.gaze_calibrated, "v2 profile loads with gaze uncalibrated (uncorrected aim)")
	check(main.last_result.contains("Re-gaze"), "v2 load suggests Re-gaze (%s)" % main.last_result)
	# Scatter persists through a save/load round-trip at v3.
	main.scatter_k = 0.4
	main._save_profile()
	main.scatter_k = 0.25
	main._load_profile()
	check(absf(main.scatter_k - 0.4) < 0.001, "scatter k persists in the v3 profile (%.2f)" % main.scatter_k)

	# Profile v1 -> v2 upgrade (seventh pass): the v1 file's templates
	# hold 12-feature vectors the v2 classifier must NOT silently read.
	# Graceful path: templates dropped with a panel explanation, the
	# calibration scalars carry over.
	var v1_feats: Array = []
	for vi: int in 12:
		v1_feats.append(0.1 * float(vi))
	var v1_data: Dictionary = {
		"version": 1, "hand": "R", "posture": "STAND",
		"calib_max": 7.7, "boost": 1.0, "fast_anchor": 7.6, "med_anchor": 6.6,
		"pbs": {}, "templates": {"FB": {"features": v1_feats, "spread": 0.3}}, "pitches": {},
	}
	check(ProfileStore.save_profile("user://duel_profile.json", v1_data), "v1 profile written for the upgrade test")
	main.templates.clear()
	main.calib_max = 0.0
	main._load_profile()
	check(main.templates.is_empty(), "v1 templates are dropped, not misread by the v2 classifier")
	check(absf(main.calib_max - 7.7) < 0.01, "v1 calibration carries over (%.2f)" % main.calib_max)
	check(main.last_result.contains("Re-enroll"), "panel explains the upgrade and the re-enroll")
	main._on_wipe()
	check(main.templates.is_empty() and not FileAccess.file_exists("user://duel_profile.json"),
		"wipe clears templates and deletes the profile file (no test data leaks into Chris's first run)")
	print("---")
	if failures == 0:
		print("SMOKE: ALL %d CHECKS PASSED" % checks)
	else:
		print("SMOKE: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
