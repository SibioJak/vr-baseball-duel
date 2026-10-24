class_name ThrowFeatures
extends RefCounted

## Pure, headless-testable math for the duel feel-test. No scene nodes here:
## feature extraction from recorded throw samples, template building,
## nearest-centroid classification, velocity calibration mapping,
## delivery retiming (the slow-arm/98-mph oddity fix), and pitch flight
## integration (drag + Magnus). A "sample" is a Dictionary:
##   { "t": float seconds, "p": Vector3 world pos,
##     "lv": Vector3 world linear velocity m/s,
##     "av": Vector3 world angular velocity rad/s,
##     "q": Quaternion world orientation of the controller }
##
## Seventh pass (feel-fix): features 12-14 are FOREARM ROLL - total twist
## about the throw axis across the delivery window, peak twist rate, and
## the hand's orientation change from delivery start to release. Chris's
## field verdict: a curveball must BE a wrist twist, separable from a
## fastball at identical arm speed - speed alone can't be the difference.
## The feature vector grew 12 -> 15, so the profile format bumped to
## PROFILE_VERSION 2 (see main.gd's load path for the graceful upgrade).

const PROFILE_VERSION: int = 2
const FEATURE_COUNT: int = 15
# Per-feature distance scales (units of "typical meaningful difference").
const FEATURE_SCALES: Array[float] = [
	3.0, # 0 release speed m/s
	0.5, # 1 release height m
	1.0, 1.0, 1.0, # 2-4 release direction (unit)
	6.0, # 5 peak angular speed rad/s
	1.0, 1.0, 1.0, # 6-8 angular velocity at release (unit)
	1.0, 1.0, 1.0, # 9-11 mean angular velocity, final 150 ms (rad/s / 10)
	0.8, # 12 total forearm roll across the delivery (rad) - first-class
	6.0, # 13 peak roll rate (rad/s) - first-class
	0.8, # 14 hand orientation change, delivery start -> release (rad)
]
# A pair of templates whose total-roll centroids differ by less than this
# has no twist gap - if such a pair also fails separation, the missing
# piece is the twist, and the panel warning says exactly that.
const ROLL_GAP_MIN: float = 0.75
# Two pitch templates count as "too close" when their centroid distance is
# below SEPARATION_OK * max(combined spread, 0.4). Tunable heuristic.
const SEPARATION_OK: float = 1.15

const MPH_PER_MPS: float = 2.23694
const PRO_ANCHOR_MPH: float = 96.0 # personal 100% calibration maps here
const MIN_GAME_MPH: float = 30.0
const MAX_GAME_MPH: float = 108.0

const GRAVITY: float = 9.8
const DRAG_K: float = 0.0045 # ~real baseball: 96 mph loses ~8 mph over the flight
# Magnus accel = MAGNUS_K * spin(rad/s) * |axis x v|. Spin rates are TRUE
# rad/s (1800-2450 rpm class, see spin_params), so this lumped coefficient
# (absorbing ball mass/radius/air density/Cl) is small. Measured with
# these constants (headless, tests/run_tests.gd asserts them): a 96 mph
# fastball drops 0.81 m vs its no-gravity straight line (gravity alone
# would drop it 1.03 m over the 0.458 s flight; backspin lift eats the
# rest), and a 76 mph curve breaks 0.36 m off a same-speed fastball,
# 0.35 m of it downward. Break must READ in a feel test (Chris: the
# first build flew "like darts").
const MAGNUS_K: float = 0.000165
const SIM_DT: float = 1.0 / 240.0

const PLATE_Z: float = -18.44 # 60.5 ft mound-to-plate, plate on -Z


static func make_sample(t: float, p: Vector3, lv: Vector3, av: Vector3) -> Dictionary:
	return {"t": t, "p": p, "lv": lv, "av": av, "q": Quaternion.IDENTITY}


static func make_sample_q(t: float, p: Vector3, lv: Vector3, av: Vector3, q: Quaternion) -> Dictionary:
	return {"t": t, "p": p, "lv": lv, "av": av, "q": q}


static func _sample_quat(s: Dictionary) -> Quaternion:
	var v: Variant = s.get("q", Quaternion.IDENTITY)
	if v is Quaternion:
		var q: Quaternion = v
		return q
	return Quaternion.IDENTITY


## Forearm-roll metrics over the delivery window (delivery start ->
## release), all measured about the throw axis A = the release velocity
## direction. The forearm at release points roughly along the throw, so
## twist about A is the readable component of the wrist's rotation - and
## it is self-consistent: a player's templates and throws are all read
## through the same axis, so the classifier compares like with like.
##   total:      summed signed twist (rad). For each step, dq = q_i *
##               q_{i-1}^-1 (world frame); its twist about A is
##               2*atan2(dq.xyz . A, dq.w) (swing-twist decomposition).
##   peak_rate:  max |twist step| / dt (rad/s).
##   orient:     signed angle (rad) between the controller's local -Y
##               ("palm side") at window start and at release, each
##               projected onto the plane perpendicular to A.
## Samples without orientation (identity q) read as zero roll - honest:
## no twist was measured, none is claimed.
static func roll_metrics(samples: Array) -> Dictionary:
	var out: Dictionary = {"total": 0.0, "peak_rate": 0.0, "orient": 0.0}
	if samples.size() < 2:
		return out
	var last: Dictionary = samples[samples.size() - 1]
	var rel_lv: Vector3 = last["lv"]
	if rel_lv.length() < 0.01:
		return out
	var axis: Vector3 = rel_lv.normalized()
	var d0: int = delivery_start_index(samples)
	var total: float = 0.0
	var peak_rate: float = 0.0
	var first: Dictionary = samples[d0]
	var q_prev: Quaternion = _sample_quat(first)
	var t_prev: float = float(first["t"])
	for i: int in range(d0 + 1, samples.size()):
		var s: Dictionary = samples[i]
		var q: Quaternion = _sample_quat(s)
		var dq: Quaternion = q * q_prev.inverse()
		var twist: float = 2.0 * atan2(dq.x * axis.x + dq.y * axis.y + dq.z * axis.z, dq.w)
		total += twist
		var t_now: float = float(s["t"])
		var dt: float = t_now - t_prev
		if dt > 0.0001:
			peak_rate = maxf(peak_rate, absf(twist) / dt)
		q_prev = q
		t_prev = t_now
	# Orientation change of the palm-side reference vector.
	var ref := Vector3(0.0, -1.0, 0.0)
	var s_first: Dictionary = samples[d0]
	var s_last: Dictionary = samples[samples.size() - 1]
	var r0: Vector3 = _sample_quat(s_first) * ref
	var r1: Vector3 = _sample_quat(s_last) * ref
	var p0: Vector3 = r0 - axis * r0.dot(axis)
	var p1: Vector3 = r1 - axis * r1.dot(axis)
	var orient: float = 0.0
	if p0.length() > 0.1 and p1.length() > 0.1:
		orient = atan2(axis.dot(p0.cross(p1)), p0.dot(p1))
	out["total"] = total
	out["peak_rate"] = peak_rate
	out["orient"] = orient
	return out


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
	var roll: Dictionary = roll_metrics(samples)
	feats[12] = float(roll["total"])
	feats[13] = float(roll["peak_rate"])
	feats[14] = float(roll["orient"])
	return feats


## Release-intent direction (seventh pass): where the ARM was throwing,
## not where the grip button happened to let go. The button's release
## frame is a follow-through frame - the hand has already started to
## turn and slow - so the old code took the flight direction from that
## one frame and aim felt like darts. Instead: find peak hand speed,
## take the CONTIGUOUS window of samples at >= INTENT_MIN_FRAC of peak
## bracketing it (at 90 Hz that is roughly 60-110 ms - the honest part
## of the delivery), and average the velocity vectors weighted by
## speed^2 (the fastest samples dominate, as they should - they are
## the throw). Speed magnitude is deliberately NOT read here; callers
## keep using the release sample's speed, unchanged.
const INTENT_MIN_FRAC: float = 0.75


static func release_intent_dir(samples: Array) -> Vector3:
	if samples.is_empty():
		return Vector3(0.0, 0.0, -1.0)
	var peak: float = 0.0
	var peak_idx: int = 0
	for i: int in samples.size():
		var s: Dictionary = samples[i]
		var lv: Vector3 = s["lv"]
		if lv.length() > peak:
			peak = lv.length()
			peak_idx = i
	if peak < 0.01:
		return Vector3(0.0, 0.0, -1.0)
	var thresh: float = peak * INTENT_MIN_FRAC
	var lo: int = peak_idx
	while lo > 0:
		var s_lo: Dictionary = samples[lo - 1]
		var lv_lo: Vector3 = s_lo["lv"]
		if lv_lo.length() < thresh:
			break
		lo -= 1
	var hi: int = peak_idx
	while hi < samples.size() - 1:
		var s_hi: Dictionary = samples[hi + 1]
		var lv_hi: Vector3 = s_hi["lv"]
		if lv_hi.length() < thresh:
			break
		hi += 1
	var acc := Vector3.ZERO
	for i2: int in range(lo, hi + 1):
		var s2: Dictionary = samples[i2]
		var v: Vector3 = s2["lv"]
		var sp: float = v.length()
		if sp > 0.01:
			acc += (v / sp) * sp * sp
	if acc.length() < 0.0001:
		var s_last: Dictionary = samples[samples.size() - 1]
		var lv_last: Vector3 = s_last["lv"]
		if lv_last.length() > 0.01:
			return lv_last.normalized()
		return Vector3(0.0, 0.0, -1.0)
	return acc.normalized()


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
			report[a_name + "|" + b_name] = {
				"distance": d, "required": required, "ok": d >= required,
				# "roll_gap": the pair has no twist difference to separate
				# on - named so the panel warning can say the twist isn't
				# reading instead of a generic "too similar".
				"roll_gap": absf(fa[12] - fb[12]) < ROLL_GAP_MIN,
				"roll_delta": absf(fa[12] - fb[12]),
			}
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


## Spin for a pitch class. Rates are TRUE ball spin in rad/s, in the
## real 1800-2400 rpm band (rad/s = rpm * TAU / 60): a four-seamer lives
## ~1900-2200 rpm, a curve ~1950-2400. roll01 (0..1) comes from the
## thrower's own wrist action, so movement is earned by THAT throw, not
## canned - more twist, more spin, more break.
static func spin_params(pitch: String, roll01: float) -> Dictionary:
	match pitch:
		"FB":
			return {"axis": Vector3(1.0, 0.0, 0.0), "rate": 185.0 + 25.0 * roll01}
		"CB":
			var axis := Vector3(-0.92, 0.2 + 0.3 * roll01, 0.0).normalized()
			return {"axis": axis, "rate": 215.0 + 50.0 * roll01}
		_:
			return {"axis": Vector3(0.3, 0.25, -0.9).normalized(), "rate": 195.0 + 35.0 * roll01}


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
