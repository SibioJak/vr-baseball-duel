class_name ThrowFeatures
extends RefCounted

## Pure, headless-testable math for the duel feel-test. No scene nodes here:
## feature extraction from recorded throw samples, template building,
## nearest-centroid classification, velocity calibration mapping,
## delivery retiming (the slow-arm/98-mph oddity fix), and pitch flight
## integration (drag + Magnus). A "sample" is a Dictionary:
##   { "t": float seconds, "p": Vector3 world pos,
##     "lv": Vector3 world linear velocity m/s,
##     "av": Vector3 world angular velocity rad/s }

const FEATURE_COUNT: int = 12
# Per-feature distance scales (units of "typical meaningful difference").
const FEATURE_SCALES: Array[float] = [
	3.0, # 0 release speed m/s
	0.5, # 1 release height m
	1.0, 1.0, 1.0, # 2-4 release direction (unit)
	6.0, # 5 peak angular speed rad/s
	1.0, 1.0, 1.0, # 6-8 angular velocity at release (unit)
	1.0, 1.0, 1.0, # 9-11 mean angular velocity, final 150 ms (rad/s / 10)
]
# Two pitch templates count as "too close" when their centroid distance is
# below SEPARATION_OK * max(combined spread, 0.4). Tunable heuristic.
const SEPARATION_OK: float = 1.15

const MPH_PER_MPS: float = 2.23694
const PRO_ANCHOR_MPH: float = 96.0 # personal 100% calibration maps here
const MIN_GAME_MPH: float = 30.0
const MAX_GAME_MPH: float = 108.0

const GRAVITY: float = 9.8
const DRAG_K: float = 0.0045 # ~real baseball: 96 mph loses ~8 mph over the flight
const MAGNUS_K: float = 0.0026 # slightly hot on purpose: break must READ in a feel test
const SIM_DT: float = 1.0 / 240.0

const PLATE_Z: float = -18.44 # 60.5 ft mound-to-plate, plate on -Z


static func make_sample(t: float, p: Vector3, lv: Vector3, av: Vector3) -> Dictionary:
	return {"t": t, "p": p, "lv": lv, "av": av}


static func extract_features(samples: Array) -> PackedFloat32Array:
	var feats := PackedFloat32Array()
	feats.resize(FEATURE_COUNT)
	if samples.is_empty():
		return feats
	var release: Dictionary = samples[samples.size() - 1]
	var rel_lv: Vector3 = release["lv"]
	var rel_av: Vector3 = release["av"]
	var rel_p: Vector3 = release["p"]
	var rel_t: float = release["t"]
	var speed: float = rel_lv.length()
	var dir: Vector3 = Vector3(0.0, 0.0, -1.0)
	if speed > 0.01:
		dir = rel_lv / speed
	var peak_ang: float = 0.0
	var late_av_sum: Vector3 = Vector3.ZERO
	var late_count: int = 0
	for raw: Variant in samples:
		var s: Dictionary = raw
		var av: Vector3 = s["av"]
		peak_ang = maxf(peak_ang, av.length())
		var st: float = s["t"]
		if st >= rel_t - 0.15:
			late_av_sum += av
			late_count += 1
	var late_av: Vector3 = Vector3.ZERO
	if late_count > 0:
		late_av = late_av_sum / float(late_count)
	var av_dir: Vector3 = Vector3.ZERO
	if rel_av.length() > 0.001:
		av_dir = rel_av.normalized()
	feats[0] = speed
	feats[1] = rel_p.y
	feats[2] = dir.x
	feats[3] = dir.y
	feats[4] = dir.z
	feats[5] = peak_ang
	feats[6] = av_dir.x
	feats[7] = av_dir.y
	feats[8] = av_dir.z
	feats[9] = late_av.x / 10.0
	feats[10] = late_av.y / 10.0
	feats[11] = late_av.z / 10.0
	return feats


static func feature_distance(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var sum: float = 0.0
	for i: int in FEATURE_COUNT:
		var d: float = (a[i] - b[i]) / FEATURE_SCALES[i]
		sum += d * d
	return sqrt(sum)


static func build_template(sample_features: Array) -> Dictionary:
	var centroid := PackedFloat32Array()
	centroid.resize(FEATURE_COUNT)
	var n: int = sample_features.size()
	if n == 0:
		return {"features": centroid, "spread": 0.0}
	for raw: Variant in sample_features:
		var f: PackedFloat32Array = raw
		for i: int in FEATURE_COUNT:
			centroid[i] += f[i]
	for i: int in FEATURE_COUNT:
		centroid[i] /= float(n)
	var spread_sum: float = 0.0
	for raw2: Variant in sample_features:
		var f2: PackedFloat32Array = raw2
		spread_sum += feature_distance(f2, centroid)
	return {"features": centroid, "spread": spread_sum / float(n)}


static func classify(features: PackedFloat32Array, templates: Dictionary) -> Dictionary:
	var best_pitch: String = ""
	var best_d: float = INF
	var second_d: float = INF
	var distances: Dictionary = {}
	for pitch: String in templates.keys():
		var tpl: Dictionary = templates[pitch]
		var tf: PackedFloat32Array = tpl["features"]
		var d: float = feature_distance(features, tf)
		distances[pitch] = d
		if d < best_d:
			second_d = best_d
			best_d = d
			best_pitch = pitch
		elif d < second_d:
			second_d = d
	if best_pitch == "":
		return {"pitch": "", "confidence": 0.0, "distances": distances}
	var confidence: float
	if second_d == INF:
		confidence = clampf(1.0 - best_d / 3.0, 0.05, 0.95)
	else:
		confidence = clampf((second_d - best_d) / maxf(second_d + best_d, 0.0001), 0.0, 1.0)
	return {"pitch": best_pitch, "confidence": confidence, "distances": distances}


static func separation_report(templates: Dictionary) -> Dictionary:
	var report: Dictionary = {}
	var names: Array = templates.keys()
	for i: int in names.size():
		for j: int in range(i + 1, names.size()):
			var a_name: String = names[i]
			var b_name: String = names[j]
			var ta: Dictionary = templates[a_name]
			var tb: Dictionary = templates[b_name]
			var fa: PackedFloat32Array = ta["features"]
			var fb: PackedFloat32Array = tb["features"]
			var d: float = feature_distance(fa, fb)
			var spread_sum: float = float(ta["spread"]) + float(tb["spread"])
			var required: float = SEPARATION_OK * maxf(spread_sum, 0.4)
			report[a_name + "|" + b_name] = {"distance": d, "required": required, "ok": d >= required}
	return report


## Game velocity (mph) from a measured raw release speed (m/s).
## Personal 100% (calibration max) maps to the pro anchor; boost multiplies,
## never flattens: velocity ordering is always preserved.
static func map_velocity(raw_speed: float, calib_max: float, boost_mult: float) -> float:
	if calib_max <= 0.01:
		return clampf(raw_speed * MPH_PER_MPS, MIN_GAME_MPH, MAX_GAME_MPH)
	var mph: float = PRO_ANCHOR_MPH * (raw_speed / calib_max) * boost_mult
	return clampf(mph, MIN_GAME_MPH, MAX_GAME_MPH)


static func gear_for_speed(raw_speed: float, fast_anchor: float, med_anchor: float) -> String:
	if fast_anchor <= 0.01 or med_anchor <= 0.01:
		return ""
	var d_fast: float = absf(raw_speed - fast_anchor) / fast_anchor
	var d_med: float = absf(raw_speed - med_anchor) / med_anchor
	if d_med <= 0.10 and d_med <= d_fast:
		return "MEDIUM"
	if d_fast <= 0.10:
		return "FAST"
	return ""


## Index where the delivery phase starts: walk back from peak hand speed
## while speed stays above 30% of peak. Windup before this is never warped.
static func delivery_start_index(samples: Array) -> int:
	if samples.is_empty():
		return 0
	var peak: float = 0.0
	var peak_idx: int = 0
	for i: int in samples.size():
		var s: Dictionary = samples[i]
		var lv: Vector3 = s["lv"]
		if lv.length() > peak:
			peak = lv.length()
			peak_idx = i
	var idx: int = peak_idx
	while idx > 0:
		var s2: Dictionary = samples[idx - 1]
		var lv2: Vector3 = s2["lv"]
		if lv2.length() < peak * 0.3:
			break
		idx -= 1
	return idx


## Warp factor for a rendered pitcher: how much the delivery phase must be
## time-compressed so visible hand speed plausibly matches game mph.
## 0.10 m/s of visible hand speed per game mph (96 mph -> 9.6 m/s hand).
## Bounded [1.0, 3.0]: the default picture never goes absurd.
static func compute_warp(recorded_peak_speed: float, game_mph: float) -> float:
	var target_peak: float = game_mph * 0.10
	if recorded_peak_speed <= 0.1:
		return 1.0
	return clampf(target_peak / recorded_peak_speed, 1.0, 3.0)


static func retime_samples(samples: Array, warp_k: float) -> Array:
	var out: Array = []
	if samples.is_empty():
		return out
	var d0: int = delivery_start_index(samples)
	var t0: float = 0.0
	if d0 < samples.size():
		var sd: Dictionary = samples[d0]
		t0 = sd["t"]
	for i: int in samples.size():
		var s: Dictionary = samples[i]
		var t: float = s["t"]
		var new_t: float = t
		if i > d0 and warp_k > 0.001:
			new_t = t0 + (t - t0) / warp_k
		out.append(make_sample(new_t, s["p"], s["lv"], s["av"]))
	return out


## Spin for a pitch class. roll01 (0..1) comes from the thrower's own wrist
## action, so movement is earned by THAT throw, not canned.
static func spin_params(pitch: String, roll01: float) -> Dictionary:
	match pitch:
		"FB":
			return {"axis": Vector3(1.0, 0.0, 0.0), "rate": 30.0 + 6.0 * roll01}
		"CB":
			var axis := Vector3(-0.85, 0.2 + 0.3 * roll01, 0.0).normalized()
			return {"axis": axis, "rate": 24.0 + 14.0 * roll01}
		_:
			return {"axis": Vector3(0.3, 0.25, -0.9).normalized(), "rate": 22.0 + 8.0 * roll01}


## Full flight, stepped at SIM_DT. Returns time, crossing point at the plate
## plane (z = target_z), and the point list for playback.
static func simulate_flight(start: Vector3, vel: Vector3, spin_axis: Vector3, spin_rate: float, target_z: float = PLATE_Z) -> Dictionary:
	var pos: Vector3 = start
	var v: Vector3 = vel
	var points := PackedVector3Array()
	points.append(pos)
	var t: float = 0.0
	var cross_pos: Vector3 = pos
	var crossed: bool = false
	var prev: Vector3 = pos
	while t < 3.0:
		prev = pos
		var accel: Vector3 = Vector3(0.0, -GRAVITY, 0.0)
		accel -= DRAG_K * v.length() * v
		accel += MAGNUS_K * spin_rate * spin_axis.cross(v)
		v += accel * SIM_DT
		pos += v * SIM_DT
		t += SIM_DT
		points.append(pos)
		if not crossed and prev.z > target_z and pos.z <= target_z:
			var frac: float = (prev.z - target_z) / maxf(prev.z - pos.z, 0.000001)
			cross_pos = prev.lerp(pos, frac)
			crossed = true
			# Fly a little past the plate, then stop: playback ends at the mitt.
			if pos.z < target_z - 0.6:
				break
		if crossed and pos.z < target_z - 0.6:
			break
		if pos.y < 0.0 and t > 0.05:
			break
	return {"time": t, "cross_pos": cross_pos, "crossed": crossed, "points": points}


static func roll01_from_features(features: PackedFloat32Array) -> float:
	return clampf((features[5] - 4.0) / 14.0, 0.0, 1.0)
