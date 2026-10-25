extends SceneTree

## Thirteenth pass: the aim SOLVER, tested at the field cases that
## broke it. Session 4 (throws-4.jsonl #47-59) proved the defect in
## the field: solve_aim_dir ran exactly 2 iterations, recovered from a
## dirt landing with a flat +1.0 m raise, and _compute_aim accepted
## any crossing without checking the solver's error.
##   - Throw #51: aim (-0.007, -0.326), 79.44 mph from
##     (0.174, 1.729, -0.848) - the old solver's cross was
##     (-0.007, 0.753), an error of 1.079 m (it read as a strike; it
##     was the solver missing its own aim by a metre, high).
##   - Throws #50/#57/#59: leaked aim points at y -2.08 / -2.20 /
##     -2.70 - both old iterations landed in the dirt, _compute_aim
##     returned {} and the throws fell back to the raw hand-intent
##     path (NO PLATE), though their head targets were ordinary.
## On the pre-fix code the field-case checks below FAIL (that is the
## negative control); on the fixed solver every case crosses within
## 0.05 m of the CLAMPED aim point (aim y is clamped to >= 0.0 - a
## pitch cannot cross the plate below ground). Run:
##   godot --headless --path . --script tests/solver_aim.gd

var failures: int = 0
var checks: int = 0


func check(cond: bool, name: String) -> void:
	checks += 1
	if cond:
		print("PASS  ", name)
	else:
		failures += 1
		print("FAIL  ", name)


func fb_spin() -> Dictionary:
	return ThrowFeatures.spin_params("FB", 0.5)


## One field case: solve and grade against the clamped target.
func field_case(label: String, start: Vector3, mph: float, aim_pt: Vector3) -> void:
	var spin: Dictionary = fb_spin()
	var solved: Dictionary = ThrowFeatures.solve_aim_dir(
		start, mph / ThrowFeatures.MPH_PER_MPS, spin["axis"], float(spin["rate"]), aim_pt)
	var clamped := Vector3(aim_pt.x, maxf(aim_pt.y, 0.0), aim_pt.z)
	check(bool(solved["crossed"]), "%s: solver crosses the plate" % label)
	var err: float = float(solved["error_m"])
	check(err >= 0.0 and err <= 0.05,
		"%s: solver error %.3f m (<= 0.05) against the clamped aim" % [label, err])
	var cross: Vector3 = solved["cross_pos"]
	var cross_err: float = Vector2(cross.x - clamped.x, cross.y - clamped.y).length()
	check(cross_err <= 0.05,
		"%s: achieved cross (%.3f, %.3f) within 0.05 m of clamped aim (%.3f, %.3f)" % [
			label, cross.x, cross.y, clamped.x, clamped.y])


func _init() -> void:
	_run()


func _run() -> void:
	# --- the field cases, exactly as recorded ----------------------
	# #51: the aim the recorder wrote (pre-clamp), its start and pace.
	field_case("#51", Vector3(0.174, 1.729, -0.848), 79.44,
		Vector3(-0.007, -0.326, ThrowFeatures.PLATE_Z))
	# #50 / #57 / #59: the leaked aim points that never crossed.
	field_case("#50", Vector3(0.202, 1.717, -0.825), 81.67,
		Vector3(0.16, -2.08, ThrowFeatures.PLATE_Z))
	field_case("#57", Vector3(0.266, 1.623, -0.889), 64.87,
		Vector3(1.22, -2.20, ThrowFeatures.PLATE_Z))
	field_case("#59", Vector3(0.245, 1.643, -0.856), 39.24,
		Vector3(0.89, -2.70, ThrowFeatures.PLATE_Z))

	# --- verification grid ------------------------------------------
	var spin2: Dictionary = fb_spin()
	var grid_start := Vector3(0.25, 1.80, -0.60)
	var grid_max_err: float = 0.0
	var grid_all_crossed: bool = true
	var grid_cases: int = 0
	for gx: float in [-0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5]:
		for gy: float in [0.0, 0.45, 0.9, 1.35, 1.8]:
			for gmph: float in [39.0, 49.0, 65.0, 82.0, 96.0]:
				grid_cases += 1
				var gs: Dictionary = ThrowFeatures.solve_aim_dir(
					grid_start, gmph / ThrowFeatures.MPH_PER_MPS,
					spin2["axis"], float(spin2["rate"]),
					Vector3(gx, gy, ThrowFeatures.PLATE_Z))
				if not bool(gs["crossed"]):
					grid_all_crossed = false
				else:
					grid_max_err = maxf(grid_max_err, float(gs["error_m"]))
	print("INFO  grid: %d cases, max solver error %.4f m" % [grid_cases, grid_max_err])
	check(grid_all_crossed, "grid: every case crosses")
	check(grid_max_err <= 0.05, "grid: max solver error %.4f m (<= 0.05)" % grid_max_err)

	# --- determinism --------------------------------------------------
	var spin3: Dictionary = fb_spin()
	var d1: Dictionary = ThrowFeatures.solve_aim_dir(
		Vector3(0.174, 1.729, -0.848), 79.44 / ThrowFeatures.MPH_PER_MPS,
		spin3["axis"], float(spin3["rate"]), Vector3(-0.007, -0.326, ThrowFeatures.PLATE_Z))
	var d2: Dictionary = ThrowFeatures.solve_aim_dir(
		Vector3(0.174, 1.729, -0.848), 79.44 / ThrowFeatures.MPH_PER_MPS,
		spin3["axis"], float(spin3["rate"]), Vector3(-0.007, -0.326, ThrowFeatures.PLATE_Z))
	var dir1: Vector3 = d1["dir"]
	var dir2: Vector3 = d2["dir"]
	check(dir1.distance_to(dir2) < 0.000001 and float(d1["error_m"]) == float(d2["error_m"]),
		"solver is deterministic (same inputs, same answer)")

	# --- _compute_aim end to end: a #50-shaped throw ------------------
	# Head worn looking at an ordinary target while the hand intent
	# ray dives (the #50 shape: intent cross near y -10). The leaked
	# aim sits below ground; pre-fix, _compute_aim returned {} here.
	var ps: PackedScene = load("res://main.tscn")
	var main: Node = ps.instantiate()
	root.add_child(main)
	await create_timer(0.2).timeout
	main._on_wipe()
	main.scatter_k = 0.25
	main.gaze_correction = Quaternion.IDENTITY
	var head_pos := Vector3(0.10, 1.69, -0.03)
	var look_target := Vector3(1.15, 0.59, ThrowFeatures.PLATE_Z)
	var look_dir: Vector3 = (look_target - head_pos).normalized()
	var look_q: Quaternion = Basis.looking_at(look_dir, Vector3.UP).get_rotation_quaternion()
	var rel_pos := Vector3(0.202, 1.717, -0.825)
	var intent_dir := Vector3(-0.14, -0.55, -0.82).normalized()
	var samples: Array = []
	for i: int in 12:
		var smp: Dictionary = ThrowFeatures.make_sample(
			float(i) / 90.0, rel_pos, intent_dir * (4.0 + 0.4 * float(i)), Vector3.ZERO)
		smp["hp"] = head_pos
		smp["hq"] = look_q
		samples.append(smp)
	var spin4: Dictionary = fb_spin()
	var aim: Dictionary = main._compute_aim(samples, rel_pos, 81.67, spin4["axis"], float(spin4["rate"]))
	check(not aim.is_empty(), "_compute_aim: a head target survives a below-ground leaked aim (no abandonment)")
	var pub: Dictionary = aim.get("public", {})
	var ac_v: Variant = pub.get("aim_cross", null)
	if ac_v is Vector3:
		var ac: Vector3 = ac_v
		check(ac.y >= 0.0, "_compute_aim: leaked aim clamped to the reachable band (aim y %.3f)" % ac.y)
		var sol_err_v: Variant = pub.get("solver_error_m", null)
		check(sol_err_v is float or sol_err_v is int,
			"_compute_aim: public block carries solver_error_m")
		if sol_err_v is float or sol_err_v is int:
			check(float(sol_err_v) <= 0.05,
				"_compute_aim: solver_error_m %.3f (<= 0.05)" % float(sol_err_v))
		var dir_v: Variant = aim.get("dir", null)
		if dir_v is Vector3:
			var dv: Vector3 = dir_v
			var flown: Dictionary = ThrowFeatures.simulate_flight(
				rel_pos, dv * (81.67 / ThrowFeatures.MPH_PER_MPS), spin4["axis"], float(spin4["rate"]))
			var fcross: Vector3 = flown["cross_pos"]
			check(bool(flown["crossed"]) and Vector2(fcross.x - ac.x, fcross.y - ac.y).length() <= 0.05,
				"_compute_aim: the returned direction's flight crosses within 0.05 m of the aim")
		else:
			check(false, "_compute_aim: aim carried a direction")
	else:
		check(false, "_compute_aim: public block carried an aim cross")
	main._on_wipe()

	print("---")
	if failures == 0:
		print("SOLVER AIM: ALL %d CHECKS PASSED" % checks)
	else:
		print("SOLVER AIM: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
