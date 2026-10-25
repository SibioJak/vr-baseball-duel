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

## Eleventh pass: PROFILE_VERSION 3 - the profile gains the gaze
## correction (quaternion), the scatter factor k, and a gaze-calibrated
## flag. NO feature-vector change: v2 templates (15 features) stay
## valid and load unchanged; only pre-v2 (12-feature) profiles drop
## their templates, as before.
const PROFILE_VERSION: int = 3
const FEATURE_COUNT: int = 15
# Human-readable name per feature index, in vector order. Doubles as
# documentation and as the key set for labeled feature dumps (the
# eighth-pass throw recorder writes features under these names so a
# recorded throw can be replayed/analyzed offline without this file).
const FEATURE_NAMES: Array[String] = [
	"release_speed_mps", # 0
	"release_height_m", # 1
	"release_dir_x", "release_dir_y", "release_dir_z", # 2-4
	"peak_angular_speed_rad_s", # 5
	"release_angvel_dir_x", "release_angvel_dir_y", "release_angvel_dir_z", # 6-8
	"late_angvel_x", "late_angvel_y", "late_angvel_z", # 9-11 (rad/s / 10)
	"roll_total_rad", # 12 total forearm roll across the delivery
	"roll_peak_rate_rad_s", # 13
	"roll_orient_change_rad", # 14 hand orientation change, start -> release
]
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


## [peak_idx, lo, hi]: the delivery window - the peak-speed sample and
## the CONTIGUOUS run of samples at >= INTENT_MIN_FRAC of peak bracketing
## it. One definition, shared by release_intent_dir and head_summary, so
## "the delivery window" means the same samples everywhere it is read.
static func intent_window(samples: Array) -> Array:
	if samples.is_empty():
		return [0, 0, -1]
	var peak: float = 0.0
	var peak_idx: int = 0
	for i: int in samples.size():
		var s: Dictionary = samples[i]
		var lv: Vector3 = s["lv"]
		if lv.length() > peak:
			peak = lv.length()
			peak_idx = i
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
	return [peak_idx, lo, hi]


static func release_intent_dir(samples: Array) -> Vector3:
	if samples.is_empty():
		return Vector3(0.0, 0.0, -1.0)
	var win: Array = intent_window(samples)
	var peak_idx: int = int(win[0])
	var peak_s: Dictionary = samples[peak_idx]
	var peak_lv: Vector3 = peak_s["lv"]
	if peak_lv.length() < 0.01:
		return Vector3(0.0, 0.0, -1.0)
	var lo: int = int(win[1])
	var hi: int = int(win[2])
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


## Head-line summary (tenth pass, recorder v2). Session-1 data killed
## aim-from-hand-velocity: the velocity direction sweeps 8-24 deg per
## 90 Hz frame near release, so intent directions scattered 12.3 deg on
## average. The candidate replacement signal is the HEAD line - a real
## pitcher locks his eyes on the target before the windup and never
## moves them. Samples may carry the head's world orientation under
## "hq" (Quaternion, written by main.gd's sampler alongside the hand
## sample); this reads it back as forward (-Z) directions:
##   release:  head forward at the release (last) sample,
##   window:   normalized mean head forward over the SAME delivery
##             window release intent uses (intent_window),
##   at_peak:  head forward at the peak hand-speed sample,
##   stability_deg: max angular deviation (deg) of any in-window head
##             forward from the window mean - how still the head was
##             while the arm was at its fastest.
## No head data (synthetic feeds, v1-era samples) -> has_head false and
## zeroed fields; callers record nulls, never a fabricated direction.
static func head_forward(q: Quaternion) -> Vector3:
	return (q * Vector3(0.0, 0.0, -1.0)).normalized()


static func head_summary(samples: Array) -> Dictionary:
	var out: Dictionary = {
		"has_head": false, "release": Vector3.ZERO, "window": Vector3.ZERO,
		"at_peak": Vector3.ZERO, "stability_deg": -1.0, "pos": Vector3.ZERO,
	}
	if samples.is_empty():
		return out
	var last: Dictionary = samples[samples.size() - 1]
	if not last.has("hq"):
		return out
	var win: Array = intent_window(samples)
	var peak_idx: int = int(win[0])
	var lo: int = int(win[1])
	var hi: int = int(win[2])
	var acc := Vector3.ZERO
	var pos_acc := Vector3.ZERO
	var pos_count: int = 0
	var win_fwds: Array = []
	for i: int in range(lo, hi + 1):
		var s: Dictionary = samples[i]
		var q_v: Variant = s.get("hq", null)
		if q_v is Quaternion:
			var q: Quaternion = q_v
			var f: Vector3 = head_forward(q)
			win_fwds.append(f)
			acc += f
		var hp_v: Variant = s.get("hp", null)
		if hp_v is Vector3:
			var hp: Vector3 = hp_v
			pos_acc += hp
			pos_count += 1
	if win_fwds.is_empty() or acc.length() < 0.0001:
		return out
	if pos_count > 0:
		out["pos"] = pos_acc / float(pos_count)
	var mean_dir: Vector3 = acc.normalized()
	var stability: float = 0.0
	for raw: Variant in win_fwds:
		var f2: Vector3 = raw
		stability = maxf(stability, rad_to_deg(mean_dir.angle_to(f2)))
	var rel_q_v: Variant = last.get("hq", null)
	if rel_q_v is Quaternion:
		var rel_q: Quaternion = rel_q_v
		out["release"] = head_forward(rel_q)
	out["window"] = mean_dir
	var peak_s: Dictionary = samples[peak_idx]
	var peak_q_v: Variant = peak_s.get("hq", null)
	if peak_q_v is Quaternion:
		var peak_q: Quaternion = peak_q_v
		out["at_peak"] = head_forward(peak_q)
	out["stability_deg"] = stability
	out["has_head"] = true
	return out


## Feature vector as a name -> value Dictionary (FEATURE_NAMES keys),
## for logs/records that must stay readable without this source file.
static func labeled_features(f: PackedFloat32Array) -> Dictionary:
	var out: Dictionary = {}
	for i: int in FEATURE_COUNT:
		out[FEATURE_NAMES[i]] = f[i] if i < f.size() else 0.0
	return out


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


## Median of a small list of measured speeds. Gear anchors (tenth pass)
## settle on the median of 3 throws: the old mean of 2 let one wild
## throw drag the anchor - Chris's MEDIUM anchor came out as the mean of
## 9.96 and 4.95, two different efforts averaged into mush. Even counts
## fall back to the mean of the middle pair.
static func median_of(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted_vals: Array = []
	for v: Variant in values:
		sorted_vals.append(float(v))
	sorted_vals.sort()
	var mid: int = sorted_vals.size() / 2
	if sorted_vals.size() % 2 == 1:
		return float(sorted_vals[mid])
	return (float(sorted_vals[mid - 1]) + float(sorted_vals[mid])) * 0.5


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


## ------------------------------------------------------------------
## Head-line aim (eleventh pass, Chris's approved rebuild - designed
## from his sessions 1-2 data: hand-velocity intent scattered 12-18
## deg across throws, the head line 2.8 deg with 0.2 deg within-throw
## stability). The model: the TARGET comes from the (gaze-corrected)
## head ray, the arm keeps velocity, and a scaled share of the hand's
## angular error survives as execution scatter:
##   A = T + (I - T) * k        (plate-plane crosses, k = scatter)
## T = corrected head-ray cross, I = intent-ray cross. The flight is
## then aimed at A with gravity drop solved against the real sim.

## Straight-line cross of the plate plane (z = PLATE_Z) for a ray.
## Returns {"crossed": bool, "cross": Vector3 (z = PLATE_Z when crossed)}.
static func plate_cross(origin: Vector3, dir: Vector3) -> Dictionary:
	if dir.length() < 0.0001 or dir.z > -0.0001:
		return {"crossed": false, "cross": origin}
	var t: float = (PLATE_Z - origin.z) / dir.z
	if t <= 0.0:
		return {"crossed": false, "cross": origin}
	return {"crossed": true, "cross": origin + dir * t}


## The aim cross: target T with a k-share of the hand's miss (I - T)
## leaking through. k = 0 flies exactly to the look; k = 1 is the old
## hand-aim cross. Pure lerp in plate space.
static func aim_cross(target: Vector3, intent_cross: Vector3, k: float) -> Vector3:
	return target + (intent_cross - target) * k


## Inlier bound for the robust gaze fit: captures of ONE rigid bias
## agree with each other to ~a degree (head stability measured 0.2 deg
## mean in the field), while a capture taken looking somewhere else
## sits tens of degrees away. 3 deg is far above honest scatter and
## far below a wrong look.
const GAZE_FIT_INLIER_DEG: float = 3.0


## Fit ONE gaze correction from dwell captures. Each capture pairs the
## head ray the player actually wore while looking at a known target:
##   {"head_pos": Vector3, "head_fwd": Vector3, "target": Vector3}
## Method: per capture, the delta quaternion rotating the measured
## forward onto the desired head_pos->target direction; the correction
## is the sign-aligned average of those deltas (component mean,
## renormalized). Chosen over a plate-space offset because a rotation
## is what the error physically is - the headset's forward and the
## player's eye line differ by a fixed rotation of the head, not by a
## translation at one distance - and a single rigid bias (the synthetic
## test case, and approximately Chris's measured +5/+4 deg) fits to
## ~zero residual.
##
## ROBUST (twelfth pass): the dwell certifies any STILL head - there
## is deliberately no proximity gate - so a capture can pair a target
## with a look that was never at it (the classic case: the step starts
## the instant Re-gaze is pressed ON THE PANEL, and the first dwell
## fires while the player is still reading the prompt). A plain mean
## let one such capture drag the correction ~35 deg off; Chris's
## session 3 wore a correction rotated 4.5 deg the WRONG way and
## every pitch landed ~1.4 m right of his raw look. The fit is now
## two-stage: the consensus is the MEDOID delta (the one closest to
## all the others), captures further than GAZE_FIT_INLIER_DEG from it
## are DROPPED, and the average is taken over the survivors. If fewer
## than 3 captures agree, the fit REFUSES (count 0) - the looks never
## agreed, so there is no honest correction to apply. Returns the
## correction, the mean angular residual AFTER fitting over the used
## captures (fit_error_deg), the mean raw error over the used
## captures, the largest used single-capture delta (max_delta_deg -
## the sanity bound main.gd reports when it exceeds 12 deg), how many
## captures were used (count) and how many were dropped (dropped).
static func gaze_correction_fit(captures: Array) -> Dictionary:
	var out: Dictionary = {
		"correction": Quaternion.IDENTITY, "fit_error_deg": -1.0,
		"raw_error_deg": -1.0, "max_delta_deg": 0.0, "count": 0,
		"dropped": 0,
	}
	var deltas: Array = []
	var pairs: Array = []
	for raw: Variant in captures:
		var c: Dictionary = raw
		var hp_v: Variant = c.get("head_pos", null)
		var hf_v: Variant = c.get("head_fwd", null)
		var tg_v: Variant = c.get("target", null)
		if not (hp_v is Vector3 and hf_v is Vector3 and tg_v is Vector3):
			continue
		var hp: Vector3 = hp_v
		var hf: Vector3 = hf_v
		var tg: Vector3 = tg_v
		if hf.length() < 0.01:
			continue
		var desired: Vector3 = tg - hp
		if desired.length() < 0.01:
			continue
		desired = desired.normalized()
		var fwd: Vector3 = hf.normalized()
		deltas.append(Quaternion(fwd, desired))
		pairs.append([fwd, desired])
	var n: int = deltas.size()
	if n == 0:
		return out
	# Consensus: the medoid delta.
	var medoid: int = 0
	var best_total: float = INF
	for i: int in n:
		var qi: Quaternion = deltas[i]
		var tot: float = 0.0
		for j: int in n:
			if i != j:
				tot += rad_to_deg(qi.angle_to(deltas[j]))
		if tot < best_total:
			best_total = tot
			medoid = i
	var ref_q: Quaternion = deltas[medoid]
	var used: Array = []
	for i2: int in n:
		if rad_to_deg(ref_q.angle_to(deltas[i2])) <= GAZE_FIT_INLIER_DEG:
			used.append(i2)
	out["dropped"] = n - used.size()
	if used.size() < mini(3, n):
		return out
	var sx: float = 0.0
	var sy: float = 0.0
	var sz: float = 0.0
	var sw: float = 0.0
	var raw_sum: float = 0.0
	var max_delta: float = 0.0
	for iu: Variant in used:
		var idx: int = iu
		var delta: Quaternion = deltas[idx]
		var dot: float = delta.x * ref_q.x + delta.y * ref_q.y + delta.z * ref_q.z + delta.w * ref_q.w
		if dot < 0.0:
			delta = Quaternion(-delta.x, -delta.y, -delta.z, -delta.w)
		sx += delta.x
		sy += delta.y
		sz += delta.z
		sw += delta.w
		var pr: Array = pairs[idx]
		var ang: float = rad_to_deg((pr[0] as Vector3).angle_to(pr[1] as Vector3))
		raw_sum += ang
		max_delta = maxf(max_delta, ang)
	var correction := Quaternion(sx, sy, sz, sw)
	if correction.length() < 0.0001:
		correction = Quaternion.IDENTITY
	else:
		correction = correction.normalized()
	var fit_sum: float = 0.0
	for iu2: Variant in used:
		var pr2: Array = pairs[iu2]
		fit_sum += rad_to_deg((correction * (pr2[0] as Vector3)).angle_to(pr2[1] as Vector3))
	out["correction"] = correction
	out["fit_error_deg"] = fit_sum / float(used.size())
	out["raw_error_deg"] = raw_sum / float(used.size())
	out["max_delta_deg"] = max_delta
	out["count"] = used.size()
	return out


## Solve the launch direction whose SIMULATED flight crosses the plate
## plane at `target` (a plate-plane point, z = PLATE_Z), for a ball
## leaving `start` at `speed_mps` with the given spin. Start from the
## direction at the target raised by the no-Magnus gravity drop for the
## flight time, simulate, then ONE refinement: shift the aim point by
## the full cross error (vertical AND lateral - the curve's Magnus
## drift is lateral too) and re-derive. Returns the final direction,
## the achieved cross, and the miss distance. Deterministic: same
## inputs, same answer, so tests can pin the accuracy.
static func solve_aim_dir(start: Vector3, speed_mps: float, spin_axis: Vector3, spin_rate: float, target: Vector3) -> Dictionary:
	var out: Dictionary = {
		"dir": Vector3(0.0, 0.0, -1.0), "cross_pos": start,
		"crossed": false, "error_m": -1.0,
	}
	if speed_mps < 0.5:
		return out
	var dz: float = maxf(start.z - target.z, 1.0)
	var t_est: float = dz / speed_mps
	var aim_point: Vector3 = target + Vector3(0.0, 0.5 * GRAVITY * t_est * t_est, 0.0)
	var best_dir: Vector3 = Vector3(0.0, 0.0, -1.0)
	var best_cross: Vector3 = start
	var best_crossed: bool = false
	var best_err: float = -1.0
	for iteration: int in 2:
		var to_aim: Vector3 = aim_point - start
		if to_aim.length() < 0.01:
			break
		var dir: Vector3 = to_aim.normalized()
		var flight: Dictionary = simulate_flight(start, dir * speed_mps, spin_axis, spin_rate)
		var crossed: bool = bool(flight["crossed"])
		var cross: Vector3 = flight["cross_pos"]
		var err: float = Vector2(target.x - cross.x, target.y - cross.y).length()
		best_dir = dir
		best_cross = cross
		best_crossed = crossed
		best_err = err
		if iteration == 0:
			if crossed:
				aim_point += Vector3(target.x - cross.x, target.y - cross.y, 0.0)
			else:
				# Ball landed short of the plane (in the dirt): raise the
				# aim and let the refinement iteration try again.
				aim_point += Vector3(0.0, 1.0, 0.0)
	out["dir"] = best_dir
	out["cross_pos"] = best_cross
	out["crossed"] = best_crossed
	out["error_m"] = best_err
	return out


static func roll01_from_features(features: PackedFloat32Array) -> float:
	return clampf((features[5] - 4.0) / 14.0, 0.0, 1.0)
