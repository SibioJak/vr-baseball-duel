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
	check(main.enroll_queue.size() == 4 and String(main.enroll_queue[0]) == "calib"
		and String(main.enroll_queue[1]) == "fb"
		and not main.enroll_queue.has("cb") and not main.enroll_queue.has("p3"),
		"default enrollment is fastball-only (calib, fb, gears)")
	feed(main, false, 8.0, 3) # calib
	feed(main, false, 8.1, 3) # fb
	feed(main, false, 8.05, 2) # gear fast
	feed(main, false, 6.9, 2) # gear medium
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
	feed(main, false, 8.05, 2) # gear fast
	feed(main, false, 6.9, 2) # gear medium
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
