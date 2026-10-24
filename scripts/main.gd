extends Node3D

## VR Baseball Duel — DE feel-test (NOT a game).
## Proves or kills three things, all judged in Chris's headset:
##  1) the classifier separates his enrolled fastball from his curveball,
##  2) the speed gun tracks effort honestly through calibration + boost,
##  3) from the batter's box, a fastball feels like its number and a
##     curveball breaks like a curveball (with delivery retiming applied).
## Everything visual is built in code so the scene file stays trivial.
## All math lives in ThrowFeatures / ProfileStore and is headless-tested.

const PROFILE_PATH: String = "user://duel_profile.json"
const PLATE_POS: Vector3 = Vector3(0.0, 0.0, -18.44) # 60.5 ft from the mound
const ZONE_HALF_W: float = 0.216 # 17 in wide zone
const BALL_R: float = 0.037

const PANEL_PX: Vector2i = Vector2i(1024, 880)
const PANEL_M: Vector2 = Vector2(1.20, 1.03)
const BOARD_PX: Vector2i = Vector2i(1024, 512)
const BOARD_M: Vector2 = Vector2(3.3, 1.65)

enum Mode { SETUP, FREE_THROW, WATCH }

# ---------------------------------------------------------------- state
var mode: int = Mode.SETUP
var xr_ok: bool = false

var throwing_hand: String = "R"
var posture: String = "STAND"
var calib_max: float = 0.0
var boost_mult: float = 1.0
var fast_anchor: float = 0.0
var med_anchor: float = 0.0
var templates: Dictionary = {} # pitch -> {"features": PackedFloat32Array, "spread": float}
var pitch_release_speed: Dictionary = {} # pitch -> raw m/s of a typical enrolled throw
var pitch_motions: Dictionary = {} # pitch -> Array of sample Dictionaries (t/p/lv/av)
var pitch_release_dir: Dictionary = {} # pitch -> Vector3 (origin space)
var pbs: Dictionary = {} # pitch -> best game mph

var enrolling: bool = false
var enroll_queue: Array = [] # step ids: calib, fb, cb, p3, gear_fast, gear_med
var enroll_idx: int = 0
var step_features: Array = []
var step_speeds: Array = []
var step_last_motion: Array = []
var separation_note: String = ""
var last_result: String = "No pitches yet."

var watch_selection: String = "MIX"
var rng := RandomNumberGenerator.new()

# ---------------------------------------------------------------- nodes
var origin: XROrigin3D
var cam: XRCamera3D
var hand_ctrl: Dictionary = {} # "L"/"R" -> the ONE XRController3D per hand (PVLDS shape)
var ball_in_hand_mesh: MeshInstance3D
var zone_frame: Node3D
var zone_bottom: float = 0.48
var zone_top: float = 1.06
var panel_root: Node3D
var panel_viewport: SubViewport
var panel_quad: MeshInstance3D
var panel_area: Area3D
var ctrl_rep: Dictionary = {} # "L"/"R" -> Node3D controller representation root
var pointer_ray_by_hand: Dictionary = {} # "L"/"R" -> RayCast3D on the aim controller
var pointer_beam: Dictionary = {} # "L"/"R" -> MeshInstance3D visible beam
var pointer_beam_mat: Dictionary = {} # "L"/"R" -> StandardMaterial3D
var pointer_hit: Dictionary = {} # "L"/"R" -> MeshInstance3D hit marker
var pointer_flash: float = 0.0
var board_viewport: SubViewport
var board_main: Label
var board_sub: Label
var ai_root: Node3D
var ai_arm: MeshInstance3D
var ai_ball: MeshInstance3D
var ai_mannequin: Node3D
var ui_click_player: AudioStreamPlayer
var release_player: AudioStreamPlayer

# panel widgets
var prompt_label: Label
var status_label: Label
var result_label: Label
var separation_label: Label
var hand_btn: Button
var posture_btn: Button
var begin_btn: Button
var skip_btn: Button
var watch_row: HBoxContainer
var boost_slider: HSlider
var boost_value_label: Label
var debug_label: Label
var debug_tick: int = 0

# ---------------------------------------------------------------- sampling
var holding: bool = false
var prev_grip: float = 0.0
var ring: Array = [] # recent samples while holding (Dictionary, ThrowFeatures format)
var prev_hand_pos: Vector3 = Vector3.ZERO
var prev_hand_basis: Basis = Basis.IDENTITY
var prev_sample_msec: int = 0
var smooth_lv: Vector3 = Vector3.ZERO
var smooth_av: Vector3 = Vector3.ZERO
var hand_was_tracked: bool = false

# ---------------------------------------------------------------- flights / ai
var flights: Array = [] # {node, points, elapsed, total, meta, announced}
var ai_play: Dictionary = {} # {samples, start, fired, pitch, mph, roll}
var pointer_down: bool = false


func _ready() -> void:
	rng.randomize()
	Engine.physics_ticks_per_second = 90
	_build_environment()
	_build_park()
	_build_rig()
	_build_board()
	_build_panel()
	_build_ai()
	_build_audio()
	_load_profile()
	_refresh_ui()
	_show_on_board("--", "VR BASEBALL DUEL - FEEL TEST")


func _mat(color: Color, emission: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	return m


func _box(parent: Node3D, pos: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = material
	parent.add_child(mi)
	return mi


func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.03, 0.06)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.42, 0.6)
	env.ambient_light_energy = 0.75
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, 28.0, 0.0)
	sun.light_energy = 0.85
	sun.shadow_enabled = false
	add_child(sun)


func _build_park() -> void:
	var park := Node3D.new()
	park.name = "Park"
	add_child(park)
	var grass := _mat(Color(0.05, 0.16, 0.07))
	var dirt := _mat(Color(0.32, 0.22, 0.13))
	var chalk := _mat(Color(0.9, 0.9, 0.9))
	_box(park, Vector3(0.0, -0.06, -9.2), Vector3(30.0, 0.12, 34.0), grass)
	# Mound: 18 ft diameter, 10 in high, centered on the origin.
	var mound_mesh := CylinderMesh.new()
	mound_mesh.top_radius = 2.74
	mound_mesh.bottom_radius = 2.74
	mound_mesh.height = 0.254
	var mound := MeshInstance3D.new()
	mound.mesh = mound_mesh
	mound.position = Vector3(0.0, 0.127, 0.0)
	mound.material_override = dirt
	park.add_child(mound)
	_box(park, Vector3(0.0, 0.26, 0.0), Vector3(0.61, 0.02, 0.15), _mat(Color(0.95, 0.95, 0.95)))
	# Home circle + plate.
	var circle_mesh := CylinderMesh.new()
	circle_mesh.top_radius = 1.9
	circle_mesh.bottom_radius = 1.9
	circle_mesh.height = 0.02
	var circle := MeshInstance3D.new()
	circle.mesh = circle_mesh
	circle.position = Vector3(PLATE_POS.x, 0.01, PLATE_POS.z)
	circle.material_override = dirt
	park.add_child(circle)
	_box(park, Vector3(PLATE_POS.x, 0.015, PLATE_POS.z), Vector3(0.43, 0.03, 0.43), chalk)
	# Batter's box lines (watch-mode anchor).
	_box(park, Vector3(0.85, 0.012, PLATE_POS.z), Vector3(0.9, 0.024, 1.2), _mat(Color(0.75, 0.75, 0.75)))
	# Backstop slab behind the plate.
	_box(park, Vector3(0.0, 1.6, PLATE_POS.z - 3.4), Vector3(7.0, 3.2, 0.15), _mat(Color(0.08, 0.09, 0.12)))
	# Distance markers down the right side of the lane.
	var marks: Array = [[3.05, "10 FT"], [6.10, "20 FT"], [9.14, "30 FT"], [12.19, "40 FT"], [15.24, "50 FT"]]
	for entry: Variant in marks:
		var pair: Array = entry
		var lbl := Label3D.new()
		lbl.text = String(pair[1])
		lbl.font_size = 64
		lbl.pixel_size = 0.004
		lbl.modulate = Color(0.8, 0.85, 0.9)
		lbl.position = Vector3(1.1, 0.05, -float(pair[0]))
		lbl.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		park.add_child(lbl)
	# Light towers (visual only).
	for sx: float in [-9.0, 9.0]:
		_box(park, Vector3(sx, 4.0, -20.5), Vector3(0.25, 8.0, 0.25), _mat(Color(0.15, 0.15, 0.18)))
		_box(park, Vector3(sx, 8.2, -20.5), Vector3(1.6, 0.7, 0.2), _mat(Color(1.0, 0.98, 0.9), 1.6))
	_build_zone()


func _build_zone() -> void:
	if zone_frame != null:
		zone_frame.queue_free()
	zone_frame = Node3D.new()
	zone_frame.name = "StrikeZone"
	add_child(zone_frame)
	if posture == "SIT":
		zone_bottom = 0.42
		zone_top = 0.96
	else:
		zone_bottom = 0.48
		zone_top = 1.06
	var frame_mat := _mat(Color(0.2, 0.95, 1.0), 0.9)
	var mid_y: float = (zone_bottom + zone_top) * 0.5
	var h: float = zone_top - zone_bottom
	var z: float = PLATE_POS.z
	_box(zone_frame, Vector3(-ZONE_HALF_W, mid_y, z), Vector3(0.02, h, 0.02), frame_mat)
	_box(zone_frame, Vector3(ZONE_HALF_W, mid_y, z), Vector3(0.02, h, 0.02), frame_mat)
	_box(zone_frame, Vector3(0.0, zone_top, z), Vector3(ZONE_HALF_W * 2.0, 0.02, 0.02), frame_mat)
	_box(zone_frame, Vector3(0.0, zone_bottom, z), Vector3(ZONE_HALF_W * 2.0, 0.02, 0.02), frame_mat)
	var fill_mesh := QuadMesh.new()
	fill_mesh.size = Vector2(ZONE_HALF_W * 2.0, h)
	var fill := MeshInstance3D.new()
	fill.mesh = fill_mesh
	fill.position = Vector3(0.0, mid_y, z)
	var fill_mat := StandardMaterial3D.new()
	fill_mat.albedo_color = Color(0.2, 0.9, 1.0, 0.10)
	fill_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill.material_override = fill_mat
	zone_frame.add_child(fill)


func _build_rig() -> void:
	origin = XROrigin3D.new()
	origin.name = "Origin"
	add_child(origin)
	cam = XRCamera3D.new()
	origin.add_child(cam)
	var xr_interface: XRInterface = XRServer.find_interface("OpenXR")
	if xr_interface != null and xr_interface.is_initialized():
		get_viewport().use_xr = true
		xr_ok = true
	else:
		var fallback := Camera3D.new()
		fallback.position = Vector3(0.0, 1.7, 2.4)
		add_child(fallback)
		fallback.look_at(Vector3(0.0, 1.0, PLATE_POS.z), Vector3.UP)
		fallback.current = true
	for hand: String in ["L", "R"]:
		# Rig binding, settled by FIELD EVIDENCE (fourth fix pass). The
		# headset DEBUG census - session FOCUSED, HMD tracking fine -
		# showed XRServer holding 19 trackers on this rig (Quest 3,
		# Virtual Desktop/VDXR, Godot 4.7), the hands registered as
		# plain "left_hand" / "right_hand" [CONTROLLER] with live data
		# ONLY on the "default" (and "palm_pose") poses. So: tracker =
		# "left_hand"/"right_hand", .pose never touched (class default
		# "default" - the pose that carries data). One node per hand,
		# everything (rep, pointer, held ball, throw sampling) derived
		# from that single node - that shape (pass 3) was right; only
		# the names were wrong. TWO wrong turns are on record; do not
		# repeat either: (1) pass 1 bound these same plain names but
		# set explicit grip_pose/aim_pose on split nodes - those poses
		# carry no data here, so the nodes never went active (this is
		# why run #1 had no controls despite correct names); (2)
		# passes 2-3 "fixed" the names to the OpenXR user paths
		# ("/user/hand/left|right", copied from PVLDS) - XRServer on
		# this rig registers NO trackers under those names, so every
		# lookup returned null. Trust the census, not analogies.
		var tracker_name: StringName = &"left_hand" if hand == "L" else &"right_hand"
		var c := XRController3D.new()
		c.tracker = tracker_name
		origin.add_child(c)
		hand_ctrl[hand] = c
		_build_controller_rep(c, hand)
		_build_pointer(c, hand)
	# The ball you hold in your throwing hand - visible from the first frame,
	# so the player's first sight in the scene is "I am holding a ball."
	var ball_mesh := SphereMesh.new()
	ball_mesh.radius = BALL_R
	ball_mesh.height = BALL_R * 2.0
	ball_in_hand_mesh = MeshInstance3D.new()
	ball_in_hand_mesh.mesh = ball_mesh
	ball_in_hand_mesh.material_override = _mat(Color(0.96, 0.96, 0.96))
	ball_in_hand_mesh.position = Vector3(0.0, 0.02, -0.04)
	ball_in_hand_mesh.visible = true
	_throw_hand_node().add_child(ball_in_hand_mesh)


func _hand_accent(hand: String) -> Color:
	return Color(0.25, 0.85, 1.0) if hand == "L" else Color(1.0, 0.55, 0.2)


# A controller representation you can actually SEE: chunky body, a glowing
# per-hand band (L cyan / R orange) and a letter tag. (The old build had a
# 1.6 cm grey dot - effectively invisible, which is why Chris saw no hands.)
func _build_controller_rep(ctrl: XRController3D, hand: String) -> void:
	var rep := Node3D.new()
	rep.name = "ControllerRep" + hand
	ctrl.add_child(rep)
	ctrl_rep[hand] = rep
	var accent: Color = _hand_accent(hand)
	var body := MeshInstance3D.new()
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.038, 0.026, 0.105)
	body.mesh = body_mesh
	body.material_override = _mat(Color(0.72, 0.74, 0.78))
	body.position = Vector3(0.0, -0.005, 0.005)
	body.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	rep.add_child(body)
	var band := MeshInstance3D.new()
	var band_mesh := BoxMesh.new()
	band_mesh.size = Vector3(0.040, 0.010, 0.024)
	band.mesh = band_mesh
	band.material_override = _mat(accent, 1.4)
	band.position = Vector3(0.0, 0.006, -0.018)
	band.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	rep.add_child(band)
	var tip := MeshInstance3D.new()
	var tip_mesh := SphereMesh.new()
	tip_mesh.radius = 0.011
	tip_mesh.height = 0.022
	tip.mesh = tip_mesh
	tip.material_override = _mat(accent, 1.1)
	tip.position = Vector3(0.0, 0.004, -0.048)
	rep.add_child(tip)
	var tag := Label3D.new()
	tag.text = hand
	tag.font_size = 64
	tag.pixel_size = 0.0009
	tag.modulate = accent
	tag.outline_size = 8
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.position = Vector3(0.0, 0.045, 0.0)
	rep.add_child(tag)


# The pointer lives on BOTH hand controllers from the start (the old build
# grew the ray lazily onto whichever hand was off-hand at first use, and a
# RayCast3D renders nothing - so the player saw no ray at all). The beam is
# a thin box stretched along the ray; the marker parks at the hit point.
# Aim = the controller node's own forward (-Z), exactly how PVLDS aims.
func _build_pointer(ctrl: XRController3D, hand: String) -> void:
	var ray := RayCast3D.new()
	ray.name = "PointerRay" + hand
	ray.target_position = Vector3(0.0, 0.0, -4.0)
	ray.collision_mask = 4
	# The panel target is an Area3D, and RayCast3D ignores areas unless
	# this is set - the shipped build never set it, so no click could
	# ever have registered even with a visible panel.
	ray.collide_with_areas = true
	ray.enabled = true
	ctrl.add_child(ray)
	pointer_ray_by_hand[hand] = ray
	var beam := MeshInstance3D.new()
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(0.0035, 0.0035, 1.0)
	beam.mesh = beam_mesh
	var bmat := StandardMaterial3D.new()
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.albedo_color = Color(1.0, 0.45, 0.4, 0.8)
	bmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam.material_override = bmat
	beam.position = Vector3(0.0, 0.0, -2.0)
	beam.scale = Vector3(1.0, 1.0, 4.0)
	beam.visible = false
	ctrl.add_child(beam)
	pointer_beam[hand] = beam
	pointer_beam_mat[hand] = bmat
	var hitm := MeshInstance3D.new()
	var hit_mesh := SphereMesh.new()
	hit_mesh.radius = 0.009
	hit_mesh.height = 0.018
	hitm.mesh = hit_mesh
	var hmat := StandardMaterial3D.new()
	hmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hmat.albedo_color = Color(1.0, 0.9, 0.3)
	hitm.material_override = hmat
	hitm.visible = false
	ctrl.add_child(hitm)
	pointer_hit[hand] = hitm


func _throw_hand_node() -> XRController3D:
	var c: XRController3D = hand_ctrl[throwing_hand]
	return c


func _input_float(ctrl: XRController3D, action: StringName) -> float:
	var v: Variant = ctrl.get_input(action)
	if v == null:
		return 0.0
	return float(v)


func _viewport_quad(vp: SubViewport, size_m: Vector2) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = size_m
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = vp.get_texture()
	mi.material_override = m
	return mi


func _build_board() -> void:
	board_viewport = SubViewport.new()
	board_viewport.size = BOARD_PX
	board_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(board_viewport)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_stylebox_override("panel", _style(Color(0.02, 0.03, 0.07)))
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	board_viewport.add_child(bg)
	bg.add_child(root)
	var title := Label.new()
	title.text = "SPEED GUN"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(0.55, 0.8, 1.0))
	root.add_child(title)
	board_main = Label.new()
	board_main.text = "--"
	board_main.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	board_main.add_theme_font_size_override("font_size", 210)
	board_main.add_theme_color_override("font_color", Color(1.0, 0.85, 0.25))
	root.add_child(board_main)
	var unit := Label.new()
	unit.text = "MPH"
	unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	unit.add_theme_font_size_override("font_size", 40)
	unit.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	root.add_child(unit)
	board_sub = Label.new()
	board_sub.text = ""
	board_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	board_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	board_sub.add_theme_font_size_override("font_size", 40)
	board_sub.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	root.add_child(board_sub)
	var holder := Node3D.new()
	holder.position = Vector3(0.0, 3.1, PLATE_POS.z - 3.3)
	add_child(holder)
	_box(holder, Vector3.ZERO, Vector3(BOARD_M.x + 0.15, BOARD_M.y + 0.15, 0.08), _mat(Color(0.05, 0.06, 0.09)))
	var quad := _viewport_quad(board_viewport, BOARD_M)
	quad.position = Vector3(0.0, 0.0, 0.06)
	holder.add_child(quad)


func _style(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(6)
	s.set_content_margin_all(10.0)
	return s


func _btn(text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 25)
	b.add_theme_stylebox_override("normal", _style(Color(0.10, 0.14, 0.22)))
	b.add_theme_stylebox_override("hover", _style(Color(0.16, 0.22, 0.34)))
	b.add_theme_stylebox_override("pressed", _style(Color(0.22, 0.32, 0.48)))
	b.pressed.connect(fn)
	return b


func _build_panel() -> void:
	panel_viewport = SubViewport.new()
	panel_viewport.size = PANEL_PX
	add_child(panel_viewport)
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_theme_stylebox_override("panel", _style(Color(0.03, 0.045, 0.08)))
	panel_viewport.add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	bg.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "VR BASEBALL DUEL - FEEL TEST"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0))
	vbox.add_child(title)

	prompt_label = Label.new()
	prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prompt_label.add_theme_font_size_override("font_size", 29)
	prompt_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.8))
	vbox.add_child(prompt_label)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_font_size_override("font_size", 21)
	status_label.add_theme_color_override("font_color", Color(0.75, 0.82, 0.9))
	vbox.add_child(status_label)

	var setup_row := HBoxContainer.new()
	setup_row.add_theme_constant_override("separation", 8)
	vbox.add_child(setup_row)
	hand_btn = _btn("Hand: RIGHT", _on_hand_toggle)
	setup_row.add_child(hand_btn)
	posture_btn = _btn("Posture: STANDING", _on_posture_toggle)
	setup_row.add_child(posture_btn)
	begin_btn = _btn("Begin enrollment", _on_begin)
	setup_row.add_child(begin_btn)
	skip_btn = _btn("Skip pitch", _on_skip)
	setup_row.add_child(skip_btn)

	var re_row := HBoxContainer.new()
	re_row.add_theme_constant_override("separation", 8)
	vbox.add_child(re_row)
	re_row.add_child(_btn("Re-enroll FB", func() -> void: _start_enrollment(["fb", "gear_fast", "gear_med"])))
	re_row.add_child(_btn("Re-enroll CB", func() -> void: _start_enrollment(["cb"])))
	re_row.add_child(_btn("Re-enroll 3rd", func() -> void: _start_enrollment(["p3"])))
	re_row.add_child(_btn("Erase profile", _on_wipe))

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 8)
	vbox.add_child(mode_row)
	mode_row.add_child(_btn("Go to MOUND (pitch)", func() -> void: _set_mode(Mode.FREE_THROW)))
	mode_row.add_child(_btn("Go to BOX (watch)", func() -> void: _set_mode(Mode.WATCH)))

	watch_row = HBoxContainer.new()
	watch_row.add_theme_constant_override("separation", 8)
	vbox.add_child(watch_row)
	watch_row.add_child(_btn("See: FB", func() -> void: _set_watch_selection("FB")))
	watch_row.add_child(_btn("See: CB", func() -> void: _set_watch_selection("CB")))
	watch_row.add_child(_btn("See: MIX", func() -> void: _set_watch_selection("MIX")))
	watch_row.add_child(_btn("THROW IT", _on_throw_it))

	var boost_row := HBoxContainer.new()
	boost_row.add_theme_constant_override("separation", 8)
	vbox.add_child(boost_row)
	var boost_lbl := Label.new()
	boost_lbl.text = "Boost"
	boost_lbl.add_theme_font_size_override("font_size", 23)
	boost_row.add_child(boost_lbl)
	boost_slider = HSlider.new()
	boost_slider.min_value = 0.8
	boost_slider.max_value = 1.2
	boost_slider.step = 0.01
	boost_slider.value = 1.0
	boost_slider.custom_minimum_size = Vector2(420.0, 0.0)
	boost_slider.value_changed.connect(_on_boost_changed)
	boost_row.add_child(boost_slider)
	boost_value_label = Label.new()
	boost_value_label.text = "1.00x"
	boost_value_label.add_theme_font_size_override("font_size", 23)
	boost_row.add_child(boost_value_label)

	result_label = Label.new()
	result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result_label.add_theme_font_size_override("font_size", 24)
	result_label.add_theme_color_override("font_color", Color(0.65, 1.0, 0.7))
	vbox.add_child(result_label)

	separation_label = Label.new()
	separation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	separation_label.add_theme_font_size_override("font_size", 21)
	separation_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.45))
	vbox.add_child(separation_label)

	var controls := Label.new()
	controls.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls.add_theme_font_size_override("font_size", 18)
	controls.add_theme_color_override("font_color", Color(0.55, 0.62, 0.72))
	controls.text = "CONTROLS - The ball is in your throwing hand (ORANGE band = right hand, CYAN band = left). Throwing hand: squeeze GRIP, throw, let go of GRIP at your release point - your ARM is the throw. Other hand: point the beam at this panel (red = aiming, green = on the panel, dot = where it lands) and pull TRIGGER to click buttons or drag the Boost slider. Quest system button (long-press): recenter. Nothing else is bound."
	vbox.add_child(controls)

	# DEBUG block (temporary): live XR chain state per hand, so a single
	# headset screenshot shows exactly which link is dead - tracker
	# registered? pose tracking? controller active? input values moving?
	debug_label = Label.new()
	debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	debug_label.add_theme_font_size_override("font_size", 17)
	debug_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	debug_label.text = "DEBUG: waiting for first update..."
	vbox.add_child(debug_label)

	panel_root = Node3D.new()
	add_child(panel_root)
	_box(panel_root, Vector3.ZERO, Vector3(PANEL_M.x + 0.06, PANEL_M.y + 0.06, 0.04), _mat(Color(0.06, 0.07, 0.1)))
	panel_quad = _viewport_quad(panel_viewport, PANEL_M)
	# The root's -Z faces the player (look_at), so the PLAYER side of the
	# backing plate is local -Z: the quad must sit at z = -0.03 with its
	# front turned toward the player (rotation.y = PI). The shipped build
	# had +0.03 - the plate (z -0.02..+0.02) hid the UI completely and all
	# Chris saw was a giant dark slab.
	# NOTE: the PI flip means the rendered texture's u axis runs OPPOSITE
	# to panel-local +X. Pointer picking therefore maps hits through
	# panel_quad's own transform (see _update_pointer) - never through
	# panel_root space, which mirrors the injected position (fifth pass).
	panel_quad.rotation.y = PI
	panel_quad.position = Vector3(0.0, 0.0, -0.03)
	panel_root.add_child(panel_quad)
	panel_area = Area3D.new()
	panel_area.collision_layer = 4
	panel_area.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(PANEL_M.x, PANEL_M.y, 0.06)
	shape.shape = box_shape
	panel_area.add_child(shape)
	panel_root.add_child(panel_area)
	_place_panel()


func _place_panel() -> void:
	# In front of the player at readable distance (~1.6 m), slightly left of
	# center so it never blocks the lane to the plate. The shipped build
	# parked it far left at (-1.08, 1.34, -1.3) - out of the natural view.
	var target: Vector3
	if mode == Mode.WATCH:
		panel_root.position = Vector3(-0.7, 1.35, PLATE_POS.z + 1.9)
		target = Vector3(0.9, 1.35, PLATE_POS.z + 0.45) # the player's head at the box
	else:
		panel_root.position = Vector3(-0.48, 1.32, -1.5)
		target = Vector3(0.0, 1.32, 0.0) # the player on the mound
	panel_root.look_at(target, Vector3.UP)


func _show_on_board(main_text: String, sub_text: String) -> void:
	board_main.text = main_text
	board_sub.text = sub_text
	board_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _set_mode(new_mode: int) -> void:
	if enrolling:
		enrolling = false
		enroll_queue.clear()
	mode = new_mode
	if mode == Mode.WATCH:
		origin.position = Vector3(0.95, 0.0, PLATE_POS.z + 0.45)
		origin.rotation = Vector3(0.0, PI, 0.0)
	else:
		origin.position = Vector3.ZERO
		origin.rotation = Vector3.ZERO
	if ai_mannequin != null:
		ai_mannequin.visible = mode == Mode.WATCH
	if ball_in_hand_mesh != null:
		ball_in_hand_mesh.visible = mode != Mode.WATCH
	_place_panel()
	_refresh_ui()


func _set_watch_selection(sel: String) -> void:
	watch_selection = sel
	_play_click()
	_refresh_ui()


func _refresh_ui() -> void:
	hand_btn.text = "Hand: " + ("RIGHT" if throwing_hand == "R" else "LEFT")
	posture_btn.text = "Posture: " + ("STANDING" if posture == "STAND" else "SITTING")
	boost_slider.set_value_no_signal(boost_mult)
	boost_value_label.text = "%.2fx" % boost_mult
	watch_row.visible = mode == Mode.WATCH
	skip_btn.visible = enrolling and enroll_idx < enroll_queue.size() and String(enroll_queue[enroll_idx]) == "p3"
	begin_btn.visible = not enrolling
	var enrolled: bool = templates.has("FB") and templates.has("CB")
	var status: String = ""
	if not xr_ok:
		status += "OpenXR NOT initialized - run from the Godot editor with your VR runtime live. "
	if calib_max > 0.01:
		status += "Calibrated: your 100%% arm = %.2f m/s -> 96 mph at 1.00x boost. " % calib_max
	if fast_anchor > 0.01:
		status += "Gears: FAST %.2f m/s, MEDIUM %.2f m/s. " % [fast_anchor, med_anchor]
	if enrolled:
		status += "Enrolled: " + ", ".join(templates.keys()) + ". "
	if not pbs.is_empty():
		var pb_parts: Array = []
		for k: String in pbs.keys():
			pb_parts.append("%s PB %d" % [k, int(round(float(pbs[k])))])
		status += " | ".join(pb_parts) + ". "
	status_label.text = status
	result_label.text = last_result
	separation_label.text = separation_note
	prompt_label.text = _current_prompt()


func _current_prompt() -> String:
	if enrolling and enroll_idx < enroll_queue.size():
		var step: String = enroll_queue[enroll_idx]
		var got: int = step_speeds.size()
		match step:
			"calib":
				return "CALIBRATION - Throw your hardest COMFORTABLE fastball (%d of 3). Hold GRIP to hold the ball, throw, release GRIP to let go." % [got + 1]
			"fb":
				return "Show me your FASTBALL motion (%d of 3)." % [got + 1]
			"cb":
				return "Show me your CURVEBALL motion (%d of 3)." % [got + 1]
			"p3":
				return "Optional: show me a THIRD pitch motion (%d of 3) - or press Skip pitch." % [got + 1]
			"gear_fast":
				return "Throw a FAST fastball (%d of 2) - your top gear, same motion." % [got + 1]
			"gear_med":
				return "Throw a MEDIUM fastball (%d of 2) - same motion, medium speed." % [got + 1]
	if mode == Mode.WATCH:
		return "FROM THE BOX - See: %s. Press THROW IT and watch it come in. The arm you see replays YOUR enrolled motion, retimed so its speed matches the number." % watch_selection
	if templates.has("FB"):
		return "FREE THROW - Grip, throw, release. The gun reads every pitch: type, confidence, velocity."
	return "Pick your throwing hand and posture, then press Begin enrollment. Your arm teaches the game your pitches."


# ---------------------------------------------------------------- enrollment control

func _on_hand_toggle() -> void:
	throwing_hand = "L" if throwing_hand == "R" else "R"
	# Re-parent the held-ball visual to the new throwing hand.
	var ball_parent: Node = ball_in_hand_mesh.get_parent()
	if ball_parent != null:
		ball_parent.remove_child(ball_in_hand_mesh)
	_throw_hand_node().add_child(ball_in_hand_mesh)
	_play_click()
	_refresh_ui()


func _on_posture_toggle() -> void:
	posture = "SIT" if posture == "STAND" else "STAND"
	_build_zone()
	_play_click()
	_refresh_ui()


func _on_boost_changed(value: float) -> void:
	boost_mult = value
	boost_value_label.text = "%.2fx" % boost_mult
	if calib_max > 0.01:
		_save_profile()


func _on_begin() -> void:
	_play_click()
	_start_enrollment(["calib", "fb", "cb", "p3", "gear_fast", "gear_med"])


func _on_skip() -> void:
	if enrolling and enroll_idx < enroll_queue.size() and String(enroll_queue[enroll_idx]) == "p3":
		_play_click()
		_advance_step()


func _on_wipe() -> void:
	ProfileStore.delete_profile(PROFILE_PATH)
	templates.clear()
	pitch_release_speed.clear()
	pitch_motions.clear()
	pitch_release_dir.clear()
	pbs.clear()
	calib_max = 0.0
	fast_anchor = 0.0
	med_anchor = 0.0
	separation_note = ""
	last_result = "Profile erased. Enroll again when ready."
	_play_click()
	_refresh_ui()


func _start_enrollment(steps: Array) -> void:
	mode = Mode.SETUP
	origin.position = Vector3.ZERO
	origin.rotation = Vector3.ZERO
	if ball_in_hand_mesh != null:
		ball_in_hand_mesh.visible = true
	if ai_mannequin != null:
		ai_mannequin.visible = false
	enroll_queue = steps.duplicate()
	enroll_idx = 0
	enrolling = true
	_reset_step()
	_place_panel()
	_refresh_ui()


func _reset_step() -> void:
	step_features.clear()
	step_speeds.clear()
	step_last_motion = []


func _step_target_count() -> int:
	if enroll_idx >= enroll_queue.size():
		return 0
	match String(enroll_queue[enroll_idx]):
		"calib", "fb", "cb", "p3":
			return 3
		"gear_fast", "gear_med":
			return 2
	return 3


func _advance_step() -> void:
	enroll_idx += 1
	_reset_step()
	if enroll_idx >= enroll_queue.size():
		enrolling = false
		_finish_enrollment()
	_refresh_ui()


func _finish_enrollment() -> void:
	_recompute_separation()
	_save_profile()
	if templates.has("FB") and templates.has("CB"):
		mode = Mode.FREE_THROW
		last_result = "Enrollment complete. Free throw - the gun is live."
	else:
		last_result = "Enrollment finished. (Fastball + curveball both enrolled = free throw unlocks.)"


func _recompute_separation() -> void:
	separation_note = ""
	if templates.size() < 2:
		return
	var rep: Dictionary = ThrowFeatures.separation_report(templates)
	for key: String in rep.keys():
		var entry: Dictionary = rep[key]
		if not bool(entry["ok"]):
			var names: PackedStringArray = key.split("|")
			separation_note = "WARNING: your %s and %s motions read very similar (distance %.2f, needs %.2f) - the game may mix them up. Re-enroll one with a more distinct motion." % [names[0], names[1], float(entry["distance"]), float(entry["required"])]
			return
	separation_note = "Separation check: your motions read distinct. Good."


# ---------------------------------------------------------------- sampling + throwing

func _physics_process(delta: float) -> void:
	_update_pointer(delta)
	debug_tick += 1
	if debug_tick % 9 == 0:
		_update_debug()
	# Controller representations show whenever their controller is tracked.
	for h: String in ["L", "R"]:
		var rep: Node3D = ctrl_rep[h]
		var hc: XRController3D = hand_ctrl[h]
		rep.visible = hc.get_is_active()
	if mode == Mode.WATCH:
		holding = false
		ball_in_hand_mesh.visible = false
		return
	var ctrl: XRController3D = _throw_hand_node()
	var grip: float = _input_float(ctrl, &"grip")
	var now_msec: int = Time.get_ticks_msec()
	var pos: Vector3 = ctrl.global_position
	var basis_now: Basis = ctrl.global_transform.basis
	if prev_sample_msec > 0 and now_msec > prev_sample_msec:
		var dt: float = float(now_msec - prev_sample_msec) / 1000.0
		var raw_lv: Vector3 = (pos - prev_hand_pos) / dt
		var q_prev: Quaternion = prev_hand_basis.get_rotation_quaternion()
		var q_now: Quaternion = basis_now.get_rotation_quaternion()
		var dq: Quaternion = q_now * q_prev.inverse()
		var av: Vector3 = Vector3.ZERO
		var angle: float = dq.get_angle()
		if angle > 0.00001 and angle < PI:
			av = dq.get_axis() * (angle / dt)
		# Light smoothing: raw 90 Hz finite differences are honest but jittery.
		smooth_lv = smooth_lv.lerp(raw_lv, 0.55)
		smooth_av = smooth_av.lerp(av, 0.55)
	prev_hand_pos = pos
	prev_hand_basis = basis_now
	prev_sample_msec = now_msec

	if grip > 0.7 and not holding:
		holding = true
		ring.clear()
		ball_in_hand_mesh.visible = true
	if holding:
		ring.append(ThrowFeatures.make_sample(float(now_msec) / 1000.0, pos, smooth_lv, smooth_av))
		while ring.size() > 120:
			ring.pop_front()
	if holding and prev_grip > 0.3 and grip <= 0.3:
		holding = false
		# The thrown ball flies as its own node; a fresh ball is in your
		# hand immediately, so the hand never reads as empty at rest.
		ball_in_hand_mesh.visible = true
		_finalize_throw()
	prev_grip = grip


func _finalize_throw() -> void:
	if ring.size() < 8:
		return
	# Trim the windup lead-in, keep a short tail before the delivery.
	var d0: int = ThrowFeatures.delivery_start_index(ring)
	var from: int = maxi(0, d0 - 12)
	var samples: Array = ring.slice(from)
	var release: Dictionary = samples[samples.size() - 1]
	var rel_lv: Vector3 = release["lv"]
	var rel_pos: Vector3 = release["p"]
	var speed: float = rel_lv.length()
	if speed < 1.5:
		last_result = "That throw was too soft to read (%.1f m/s). Throw it like you mean it." % speed
		_refresh_ui()
		return
	var to_plate: Vector3 = (PLATE_POS + Vector3(0.0, 0.9, 0.0) - rel_pos).normalized()
	if rel_lv.normalized().dot(to_plate) < 0.25:
		last_result = "That one wasn't toward the plate - not counted."
		_refresh_ui()
		return
	var features: PackedFloat32Array = ThrowFeatures.extract_features(samples)
	if enrolling:
		_enrollment_throw(features, speed, samples)
	else:
		_free_throw(features, speed, samples)
	_refresh_ui()


func _enrollment_throw(features: PackedFloat32Array, speed: float, samples: Array) -> void:
	var step: String = enroll_queue[enroll_idx]
	step_features.append(features)
	step_speeds.append(speed)
	step_last_motion = samples
	# An accepted throw always flies, in every mode - a pitch you throw but
	# cannot watch feels broken even when the counter ticks. Enrollment
	# flights are "quiet": no gun-board post, no PB, the panel counting text
	# below stays the feedback channel. (Sixth pass, Chris's field report.)
	_spawn_visual_flight(samples, features, _enrollment_flight_pitch(step))
	last_result = "Counted: %.2f m/s (%d mph raw)." % [speed, int(round(speed * ThrowFeatures.MPH_PER_MPS))]
	if step == "calib" and calib_max <= 0.01:
		last_result += " The ball still flies, but that is visual only - the gun stays dark until calibration lands."
	if step_speeds.size() < _step_target_count():
		return
	var avg_speed: float = 0.0
	for s: float in step_speeds:
		avg_speed += s
	avg_speed /= float(step_speeds.size())
	match step:
		"calib":
			calib_max = avg_speed
			last_result = "Calibration set: your 100%% arm is %.2f m/s. It will read as 96 mph at 1.00x boost." % calib_max
		"fb", "cb", "p3":
			var key: String = step.to_upper()
			templates[key] = ThrowFeatures.build_template(step_features)
			pitch_release_speed[key] = avg_speed
			pitch_motions[key] = samples
			var rel: Dictionary = samples[samples.size() - 1]
			var lv: Vector3 = rel["lv"]
			pitch_release_dir[key] = lv.normalized()
			last_result = "%s enrolled (avg %.2f m/s)." % [key, avg_speed]
			_recompute_separation()
		"gear_fast":
			fast_anchor = avg_speed
			last_result = "FAST gear anchored at %.2f m/s." % fast_anchor
		"gear_med":
			med_anchor = avg_speed
			last_result = "MEDIUM gear anchored at %.2f m/s." % med_anchor
	_advance_step()


## The flight character an enrollment step throws with: calibration and
## both velocity gears fly as fastballs, the curve step flies with the
## curve's break (from this throw's own roll feature, via spin_params).
func _enrollment_flight_pitch(step: String) -> String:
	match step:
		"cb":
			return "CB"
		"p3":
			return "P3"
	return "FB"


## Spawn a visible flight for a throw the classifier is not scoring:
## enrollment throws and pre-enrollment "just a throw" tosses. Speed uses
## the normal map when a calibration exists; before one lands, the anchor
## is the fastest accepted throw of the current step (or this throw), so
## the ball leaves at a believable pace and never looks lobbed. The flight
## is flagged "quiet" - _update_flights will not announce it on the gun
## board, record a PB, or overwrite the panel's result text.
func _spawn_visual_flight(samples: Array, features: PackedFloat32Array, pitch: String) -> void:
	var release: Dictionary = samples[samples.size() - 1]
	var rel_pos: Vector3 = release["p"]
	var rel_lv: Vector3 = release["lv"]
	var speed: float = rel_lv.length()
	var anchor: float = calib_max
	if anchor <= 0.01:
		anchor = speed
		for s: float in step_speeds:
			anchor = maxf(anchor, s)
	var mph: float = ThrowFeatures.map_velocity(speed, anchor, boost_mult)
	var spin: Dictionary = ThrowFeatures.spin_params(pitch, ThrowFeatures.roll01_from_features(features))
	_start_flight(rel_pos, rel_lv.normalized(), mph, pitch, spin["axis"], float(spin["rate"]), {
		"quiet": true, "watch": false,
	})


func _free_throw(features: PackedFloat32Array, speed: float, samples: Array) -> void:
	if not (templates.has("FB") and templates.has("CB")):
		# No templates yet: the throw still flies as an unclassified "just a
		# throw" at provisionally mapped speed - a new player who ignores the
		# panel and throws sees a ball go. Gun board stays dark (quiet).
		_spawn_visual_flight(samples, features, "FB")
		last_result = "Enroll a fastball and a curveball first - then the gun goes live."
		return
	# Sandbag guard (per spec): beating your calibrated max re-anchors it.
	if calib_max > 0.01 and speed > calib_max:
		calib_max = speed
		last_result = "New personal max - calibration re-anchored to %.2f m/s." % calib_max
	var verdict: Dictionary = ThrowFeatures.classify(features, templates)
	var pitch: String = verdict["pitch"]
	var confidence: float = verdict["confidence"]
	var mph: float = ThrowFeatures.map_velocity(speed, calib_max, boost_mult)
	var gear: String = ""
	if pitch == "FB":
		gear = ThrowFeatures.gear_for_speed(speed, fast_anchor, med_anchor)
	var release: Dictionary = samples[samples.size() - 1]
	var rel_pos: Vector3 = release["p"]
	var rel_lv: Vector3 = release["lv"]
	var spin: Dictionary = ThrowFeatures.spin_params(pitch, ThrowFeatures.roll01_from_features(features))
	var axis: Vector3 = spin["axis"]
	_start_flight(rel_pos, rel_lv.normalized(), mph, pitch, axis, float(spin["rate"]), {
		"confidence": confidence, "gear": gear, "watch": false,
	})
	release_player.play()


# ---------------------------------------------------------------- flight playback

func _start_flight(start: Vector3, dir: Vector3, mph: float, pitch: String, spin_axis: Vector3, spin_rate: float, meta: Dictionary) -> void:
	var speed_mps: float = mph / ThrowFeatures.MPH_PER_MPS
	var flight: Dictionary = ThrowFeatures.simulate_flight(start, dir * speed_mps, spin_axis, spin_rate)
	var points: PackedVector3Array = flight["points"]
	if points.size() < 2:
		return
	var mesh := SphereMesh.new()
	mesh.radius = BALL_R
	mesh.height = BALL_R * 2.0
	var ball := MeshInstance3D.new()
	ball.mesh = mesh
	ball.material_override = _mat(Color(0.96, 0.96, 0.96))
	ball.position = points[0]
	add_child(ball)
	var full_meta: Dictionary = meta.duplicate()
	full_meta["pitch"] = pitch
	full_meta["mph"] = mph
	full_meta["cross_pos"] = flight["cross_pos"]
	full_meta["crossed"] = flight["crossed"]
	flights.append({
		"node": ball, "points": points, "elapsed": 0.0,
		"total": float(flight["time"]), "meta": full_meta, "announced": false,
	})


func _process(delta: float) -> void:
	_update_flights(delta)
	_update_ai(delta)


func _update_flights(delta: float) -> void:
	for i: int in range(flights.size() - 1, -1, -1):
		var f: Dictionary = flights[i]
		f["elapsed"] = float(f["elapsed"]) + delta
		var elapsed: float = f["elapsed"]
		var points: PackedVector3Array = f["points"]
		var node: MeshInstance3D = f["node"]
		var step_f: float = elapsed / ThrowFeatures.SIM_DT
		var idx: int = clampi(int(step_f), 0, points.size() - 1)
		var frac: float = clampf(step_f - float(idx), 0.0, 1.0)
		if idx < points.size() - 1:
			node.position = points[idx].lerp(points[idx + 1], frac)
		else:
			node.position = points[idx]
		var meta: Dictionary = f["meta"]
		if not bool(f["announced"]) and node.position.z <= PLATE_POS.z + 0.05:
			f["announced"] = true
			# Quiet flights (enrollment / pre-enrollment) are visual only:
			# no gun-board post, no PB, no result-text overwrite.
			if not bool(meta.get("quiet", false)):
				_announce(meta)
		if elapsed > float(f["total"]) + 0.6:
			node.queue_free()
			flights.remove_at(i)


func _announce(meta: Dictionary) -> void:
	var pitch: String = meta["pitch"]
	var mph: float = meta["mph"]
	var crossed: bool = meta["crossed"]
	var cross_pos: Vector3 = meta["cross_pos"]
	var in_zone: bool = false
	if crossed:
		in_zone = absf(cross_pos.x) <= ZONE_HALF_W + BALL_R and cross_pos.y >= zone_bottom - BALL_R and cross_pos.y <= zone_top + BALL_R
	var call: String = "BALL"
	if in_zone:
		call = "STRIKE"
	elif not crossed:
		call = "NO PLATE"
	var is_pb: bool = false
	if not pbs.has(pitch) or mph > float(pbs[pitch]):
		pbs[pitch] = mph
		is_pb = true
		_save_profile()
	var sub: String = "%s - %s" % [_pitch_name(pitch), call]
	if not bool(meta.get("watch", false)):
		sub += " - %d%% sure" % int(round(float(meta.get("confidence", 0.0)) * 100.0))
		var gear: String = String(meta.get("gear", ""))
		if gear != "":
			sub += " - %s gear" % gear
	if is_pb:
		sub += " - NEW PB"
	_show_on_board(str(int(round(mph))), sub)
	last_result = "Gun: %s at %d mph - %s." % [_pitch_name(pitch), int(round(mph)), call]
	_refresh_ui()


func _pitch_name(pitch: String) -> String:
	match pitch:
		"FB":
			return "FASTBALL"
		"CB":
			return "CURVEBALL"
		"P3":
			return "THIRD PITCH"
	return pitch


# ---------------------------------------------------------------- watch mode (from the box)

func _build_ai() -> void:
	ai_root = Node3D.new()
	ai_root.name = "AIArm"
	add_child(ai_root)
	ai_mannequin = Node3D.new()
	ai_mannequin.visible = false
	ai_root.add_child(ai_mannequin)
	var torso_mesh := CapsuleMesh.new()
	torso_mesh.radius = 0.17
	torso_mesh.height = 0.95
	var torso := MeshInstance3D.new()
	torso.mesh = torso_mesh
	torso.position = Vector3(0.0, 1.05, 0.42)
	torso.material_override = _mat(Color(0.13, 0.14, 0.2))
	ai_mannequin.add_child(torso)
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.11
	head_mesh.height = 0.22
	var head := MeshInstance3D.new()
	head.mesh = head_mesh
	head.position = Vector3(0.0, 1.72, 0.42)
	head.material_override = _mat(Color(0.13, 0.14, 0.2))
	ai_mannequin.add_child(head)
	var arm_mesh := CapsuleMesh.new()
	arm_mesh.radius = 0.04
	arm_mesh.height = 0.55
	ai_arm = MeshInstance3D.new()
	ai_arm.mesh = arm_mesh
	ai_arm.material_override = _mat(Color(0.75, 0.6, 0.45))
	ai_arm.visible = false
	ai_root.add_child(ai_arm)
	var b_mesh := SphereMesh.new()
	b_mesh.radius = BALL_R
	b_mesh.height = BALL_R * 2.0
	ai_ball = MeshInstance3D.new()
	ai_ball.mesh = b_mesh
	ai_ball.material_override = _mat(Color(0.96, 0.96, 0.96))
	ai_ball.visible = false
	ai_root.add_child(ai_ball)


func _on_throw_it() -> void:
	if mode != Mode.WATCH or not ai_play.is_empty():
		return
	_play_click()
	var available: Array = []
	if templates.has("FB"):
		available.append("FB")
	if templates.has("CB"):
		available.append("CB")
	if templates.has("P3"):
		available.append("P3")
	if available.is_empty():
		available = ["FB", "CB"]
	var pitch: String = watch_selection
	if pitch == "MIX" or not available.has(pitch):
		pitch = String(available[rng.randi_range(0, available.size() - 1)])
	# Motion: the player's own enrolled motion if we have it, else synthetic.
	var motion: Array
	var release_dir: Vector3
	if pitch_motions.has(pitch):
		motion = pitch_motions[pitch]
		release_dir = pitch_release_dir[pitch]
	else:
		motion = _synthetic_motion(pitch == "CB", 8.0 if pitch == "FB" else 6.2)
		var last: Dictionary = motion[motion.size() - 1]
		var lv: Vector3 = last["lv"]
		release_dir = lv.normalized()
	# Game velocity: fastballs ride the FAST gear (75%) or MEDIUM (25%);
	# offspeed rides its enrolled speed ratio. No profile -> pro defaults.
	var mph: float
	if pitch == "FB":
		if fast_anchor > 0.01 and rng.randf() < 0.25:
			mph = ThrowFeatures.map_velocity(med_anchor, calib_max, boost_mult)
		elif pitch_release_speed.has("FB"):
			mph = ThrowFeatures.map_velocity(float(pitch_release_speed["FB"]), calib_max, boost_mult)
		else:
			mph = 96.0 * boost_mult
	elif pitch_release_speed.has(pitch):
		mph = ThrowFeatures.map_velocity(float(pitch_release_speed[pitch]), calib_max, boost_mult)
	else:
		mph = 76.0 * boost_mult
	# Peak arm speed of the recorded motion, for the retiming warp.
	var peak: float = 0.0
	for raw: Variant in motion:
		var s: Dictionary = raw
		var lv2: Vector3 = s["lv"]
		peak = maxf(peak, lv2.length())
	var warp: float = ThrowFeatures.compute_warp(peak, mph)
	var retimed: Array = ThrowFeatures.retime_samples(motion, warp)
	var rel: Dictionary = retimed[retimed.size() - 1]
	var rel_t: float = rel["t"]
	var first: Dictionary = retimed[0]
	# Normalize the replay clock so the first sample is t=0.
	var t_offset: float = first["t"]
	var norm: Array = []
	for raw2: Variant in retimed:
		var s2: Dictionary = raw2
		norm.append(ThrowFeatures.make_sample(float(s2["t"]) - t_offset, s2["p"], s2["lv"], s2["av"]))
	ai_play = {
		"samples": norm, "start": float(Time.get_ticks_msec()) / 1000.0,
		"release_t": rel_t - t_offset, "fired": false,
		"pitch": pitch, "mph": mph, "dir": release_dir,
		"roll": 0.35 if pitch == "FB" else 0.8,
	}
	ai_arm.visible = true
	ai_ball.visible = true
	last_result = "Incoming: watch the arm. (Warp x%.1f - delivery retimed to match %d mph.)" % [warp, int(round(mph))]
	_refresh_ui()


func _update_ai(_delta: float) -> void:
	if ai_play.is_empty():
		return
	var samples: Array = ai_play["samples"]
	var elapsed: float = float(Time.get_ticks_msec()) / 1000.0 - float(ai_play["start"])
	# Find the sample segment we are inside.
	var pos: Vector3 = Vector3.ZERO
	var done: bool = elapsed >= float(ai_play["release_t"])
	for i: int in samples.size():
		var s: Dictionary = samples[i]
		var t: float = s["t"]
		if t >= elapsed or i == samples.size() - 1:
			pos = s["p"]
			break
		var next: Dictionary = samples[i + 1]
		var nt: float = next["t"]
		if nt >= elapsed:
			var f: float = clampf((elapsed - t) / maxf(nt - t, 0.0001), 0.0, 1.0)
			var p0: Vector3 = s["p"]
			var p1: Vector3 = next["p"]
			pos = p0.lerp(p1, f)
			break
	ai_arm.position = pos + Vector3(0.0, -0.18, 0.0)
	ai_ball.position = pos
	if done and not bool(ai_play["fired"]):
		ai_play["fired"] = true
		var pitch: String = ai_play["pitch"]
		var spin: Dictionary = ThrowFeatures.spin_params(pitch, float(ai_play["roll"]))
		var axis: Vector3 = spin["axis"]
		_start_flight(pos, ai_play["dir"], float(ai_play["mph"]), pitch, axis, float(spin["rate"]), {"watch": true})
		release_player.play()
	if elapsed > float(ai_play["release_t"]) + 0.45:
		ai_arm.visible = false
		ai_ball.visible = false
		ai_play = {}


# Synthetic overhand motion (watch mode before any enrollment): positions on
# a windup->delivery path, velocities by finite difference, like the tests.
func _synthetic_motion(is_curve: bool, peak_speed: float) -> Array:
	var samples: Array = []
	var duration: float = 0.62
	var steps: int = int(duration * 90.0)
	var start := Vector3(0.28, 1.30, 0.77)
	var back := Vector3(0.32, 1.12, 1.08)
	var release := Vector3(0.18, 1.72, 0.12)
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


# ---------------------------------------------------------------- profile persistence

func _save_profile() -> void:
	if calib_max <= 0.01 and templates.is_empty():
		return
	var data: Dictionary = {
		"version": 1,
		"hand": throwing_hand,
		"posture": posture,
		"calib_max": calib_max,
		"boost": boost_mult,
		"fast_anchor": fast_anchor,
		"med_anchor": med_anchor,
		"pbs": pbs.duplicate(),
		"templates": {},
		"pitches": {},
	}
	var tpl_out: Dictionary = {}
	for pitch: String in templates.keys():
		var tpl: Dictionary = templates[pitch]
		var feats: PackedFloat32Array = tpl["features"]
		var arr: Array = []
		for v: float in feats:
			arr.append(v)
		tpl_out[pitch] = {"features": arr, "spread": float(tpl["spread"])}
	data["templates"] = tpl_out
	var pitch_out: Dictionary = {}
	for pitch2: String in pitch_motions.keys():
		var rows: Array = []
		var motion: Array = pitch_motions[pitch2]
		for raw: Variant in motion:
			var s: Dictionary = raw
			var p: Vector3 = s["p"]
			rows.append([float(s["t"]), p.x, p.y, p.z])
		var dir: Vector3 = pitch_release_dir.get(pitch2, Vector3(0.0, 0.0, -1.0))
		pitch_out[pitch2] = {
			"release_speed": float(pitch_release_speed.get(pitch2, 0.0)),
			"release_dir": [dir.x, dir.y, dir.z],
			"motion": rows,
		}
	data["pitches"] = pitch_out
	ProfileStore.save_profile(PROFILE_PATH, data)


func _load_profile() -> void:
	var data: Dictionary = ProfileStore.load_profile(PROFILE_PATH)
	if data.is_empty():
		return
	throwing_hand = String(data.get("hand", "R"))
	posture = String(data.get("posture", "STAND"))
	calib_max = float(data.get("calib_max", 0.0))
	boost_mult = clampf(float(data.get("boost", 1.0)), 0.8, 1.2)
	fast_anchor = float(data.get("fast_anchor", 0.0))
	med_anchor = float(data.get("med_anchor", 0.0))
	var saved_pbs: Variant = data.get("pbs", {})
	if saved_pbs is Dictionary:
		var sp: Dictionary = saved_pbs
		for k: String in sp.keys():
			pbs[k] = float(sp[k])
	var tpl_in: Variant = data.get("templates", {})
	if tpl_in is Dictionary:
		var td: Dictionary = tpl_in
		for pitch: String in td.keys():
			var entry: Dictionary = td[pitch]
			var farr: Array = entry.get("features", [])
			var feats := PackedFloat32Array()
			for v: Variant in farr:
				feats.append(float(v))
			if feats.size() == ThrowFeatures.FEATURE_COUNT:
				templates[pitch] = {"features": feats, "spread": float(entry.get("spread", 0.0))}
	var pitch_in: Variant = data.get("pitches", {})
	if pitch_in is Dictionary:
		var pd: Dictionary = pitch_in
		for pitch2: String in pd.keys():
			var entry2: Dictionary = pd[pitch2]
			pitch_release_speed[pitch2] = float(entry2.get("release_speed", 0.0))
			var darr: Array = entry2.get("release_dir", [0.0, 0.0, -1.0])
			if darr.size() == 3:
				pitch_release_dir[pitch2] = Vector3(float(darr[0]), float(darr[1]), float(darr[2]))
			var rows: Array = entry2.get("motion", [])
			pitch_motions[pitch2] = _motion_from_rows(rows)
	_build_zone()
	_recompute_separation()
	if templates.has("FB") and templates.has("CB"):
		mode = Mode.FREE_THROW
		last_result = "Profile loaded - free throw is live, or go to the box to watch."
	# Ball visual follows the loaded throwing hand.
	var ball_parent: Node = ball_in_hand_mesh.get_parent()
	if ball_parent != null:
		ball_parent.remove_child(ball_in_hand_mesh)
	_throw_hand_node().add_child(ball_in_hand_mesh)


# Rebuild full samples (with finite-difference velocities) from saved rows.
func _motion_from_rows(rows: Array) -> Array:
	var samples: Array = []
	var prev_pos: Vector3 = Vector3.ZERO
	var prev_t: float = 0.0
	for i: int in rows.size():
		var row: Array = rows[i]
		if row.size() < 4:
			continue
		var t: float = float(row[0])
		var p := Vector3(float(row[1]), float(row[2]), float(row[3]))
		var lv: Vector3 = Vector3.ZERO
		if i > 0 and t > prev_t:
			lv = (p - prev_pos) / (t - prev_t)
		samples.append(ThrowFeatures.make_sample(t, p, lv, Vector3.ZERO))
		prev_pos = p
		prev_t = t
	return samples


# ---------------------------------------------------------------- panel pointer + audio

func _off_hand() -> String:
	return "L" if throwing_hand == "R" else "R"


# DEBUG v2 (temporary): enumerate, don't assume. One line per hand for
# the duel's own chain, then a full census of EVERY tracker XRServer
# knows - key, type, which known poses carry live data. The second
# headset run showed NO-TRACKER for both hands in an app whose runtime
# demonstrably had the same hardware working in PVLDS; if hands are
# ever missing again, this census shows what the runtime DID register
# (head only? hands under unexpected names?) and ends name-guessing.
func _hand_tracker_name(hand: String) -> StringName:
	# Plain names, per the field census (see _build_rig): XRServer on
	# this rig registers the hands as "left_hand"/"right_hand", NOT
	# under the OpenXR user paths.
	return &"left_hand" if hand == "L" else &"right_hand"


# XRPositionalTracker cannot enumerate its own poses, so probe the
# pose names this project (and the class defaults) actually use.
func _live_pose_names(t: XRPositionalTracker) -> PackedStringArray:
	var live := PackedStringArray()
	for pose_name: StringName in [&"default", &"default_pose", &"grip_pose", &"aim_pose", &"palm_pose"]:
		var pose: XRPose = t.get_pose(pose_name)
		if pose != null and pose.has_tracking_data:
			live.append(String(pose_name))
	return live


func _tracker_type_text(t: XRPositionalTracker) -> String:
	match t.get_tracker_type():
		XRServer.TRACKER_HEAD:
			return "HEAD"
		XRServer.TRACKER_CONTROLLER:
			return "CONTROLLER"
		XRServer.TRACKER_BASESTATION:
			return "BASESTATION"
		XRServer.TRACKER_ANCHOR:
			return "ANCHOR"
	return "UNKNOWN(%d)" % t.get_tracker_type()


func _session_state_text() -> String:
	var iface: XRInterface = XRServer.find_interface("OpenXR")
	if iface == null:
		return "no-interface"
	if not iface.has_method("get_session_state"):
		return "n/a"
	var names: Array = ["UNKNOWN", "IDLE", "READY", "SYNCHRONIZED", "VISIBLE", "FOCUSED", "STOPPING", "LOSS_PENDING", "EXITING"]
	var idx: int = int(iface.get_session_state())
	if idx >= 0 and idx < names.size():
		return String(names[idx])
	return str(idx)


func _debug_hand_line(hand: String) -> String:
	var tname: StringName = _hand_tracker_name(hand)
	var ctrl: XRController3D = hand_ctrl[hand]
	var tracker: XRPositionalTracker = XRServer.get_tracker(tname)
	var found: String = "FOUND" if tracker != null else "MISSING"
	var live: PackedStringArray = _live_pose_names(tracker) if tracker != null else PackedStringArray()
	var pos: Vector3 = ctrl.global_position
	return "%s: tracker %s | poses: %s | active %s | pos (%.2f, %.2f, %.2f) | grip %.2f trig %.2f" % [
		hand, found, "none" if live.is_empty() else ",".join(live),
		str(ctrl.get_is_active()),
		pos.x, pos.y, pos.z,
		_input_float(ctrl, &"grip"), _input_float(ctrl, &"trigger")]


func _update_debug() -> void:
	if debug_label == null:
		return
	var lines := PackedStringArray()
	lines.append("DEBUG - xr_ok: %s | session: %s" % [str(xr_ok), _session_state_text()])
	lines.append(_debug_hand_line("L"))
	lines.append(_debug_hand_line("R"))
	var trackers: Dictionary = XRServer.get_trackers(XRServer.TRACKER_ANY)
	lines.append("XRServer trackers: %d registered" % trackers.size())
	for key: Variant in trackers.keys():
		var t: XRPositionalTracker = trackers[key] as XRPositionalTracker
		if t == null:
			lines.append("  %s: (not positional)" % String(key))
			continue
		var live: PackedStringArray = _live_pose_names(t)
		lines.append("  %s [%s] poses: %s" % [
			String(key), _tracker_type_text(t), "none" if live.is_empty() else ",".join(live)])
	debug_label.text = "\n".join(lines)


func _update_pointer(delta: float) -> void:
	var off_hand: String = _off_hand()
	var off_ctrl: XRController3D = hand_ctrl[off_hand]
	var ray: RayCast3D = pointer_ray_by_hand[off_hand]
	var beam: MeshInstance3D = pointer_beam[off_hand]
	var beam_mat: StandardMaterial3D = pointer_beam_mat[off_hand]
	var hitm: MeshInstance3D = pointer_hit[off_hand]
	# Only the off hand points at the panel; the throwing hand's beam is stowed.
	for h: String in ["L", "R"]:
		if h != off_hand:
			var other_beam: MeshInstance3D = pointer_beam[h]
			var other_hit: MeshInstance3D = pointer_hit[h]
			other_beam.visible = false
			other_hit.visible = false
	var active: bool = off_ctrl.get_is_active()
	var hovering: bool = false
	var ray_len: float = 4.0
	var trig: float = _input_float(off_ctrl, &"trigger")
	if active and ray.is_colliding() and ray.get_collider() == panel_area:
		hovering = true
		var hit: Vector3 = ray.get_collision_point()
		ray_len = off_ctrl.global_position.distance_to(hit)
		hitm.position = off_ctrl.to_local(hit)
		# Map the hit through the RENDERED QUAD's own space - the single
		# source of truth (mesh size read from the actual QuadMesh,
		# pixels from the actual SubViewport). The quad is rotated PI
		# about Y inside panel_root, so its texture u runs opposite to
		# panel-local +X; the old formula converted in panel_root space
		# and injected a MIRRORED position - point at a button and the
		# one to its right lit up (Chris's field report, fifth pass).
		# In quad-local space, +X is the texture's +u by the mesh's own
		# UV convention, whatever the panel's world pose is.
		var q_local: Vector3 = panel_quad.global_transform.affine_inverse() * hit
		var quad_size: Vector2 = (panel_quad.mesh as QuadMesh).size
		var u: float = clampf(q_local.x / quad_size.x + 0.5, 0.0, 1.0)
		var v: float = clampf(0.5 - q_local.y / quad_size.y, 0.0, 1.0)
		var vp_pos := Vector2(u * float(panel_viewport.size.x), v * float(panel_viewport.size.y))
		var motion_ev := InputEventMouseMotion.new()
		motion_ev.position = vp_pos
		panel_viewport.push_input(motion_ev)
		if trig > 0.75 and not pointer_down:
			pointer_down = true
			pointer_flash = 0.15
			var press := InputEventMouseButton.new()
			press.button_index = MOUSE_BUTTON_LEFT
			press.pressed = true
			press.position = vp_pos
			panel_viewport.push_input(press)
		elif trig <= 0.35 and pointer_down:
			pointer_down = false
			var release_ev := InputEventMouseButton.new()
			release_ev.button_index = MOUSE_BUTTON_LEFT
			release_ev.pressed = false
			release_ev.position = vp_pos
			panel_viewport.push_input(release_ev)
	elif pointer_down:
		pointer_down = false
	# Beam visuals: length to the hit (or full reach), red while aiming,
	# green on the panel, fat pale flash the moment a click lands.
	beam.visible = active
	hitm.visible = hovering
	beam.scale.z = ray_len
	beam.position.z = -ray_len * 0.5
	if pointer_flash > 0.0:
		pointer_flash = maxf(0.0, pointer_flash - delta)
		beam.scale.x = 2.4
		beam.scale.y = 2.4
		beam_mat.albedo_color = Color(1.0, 1.0, 0.65, 0.95)
	else:
		beam.scale.x = 1.0
		beam.scale.y = 1.0
		if hovering:
			beam_mat.albedo_color = Color(0.45, 1.0, 0.55, 0.9)
		else:
			beam_mat.albedo_color = Color(1.0, 0.45, 0.4, 0.8)


func _make_blip(freq: float, seconds: float, volume: float) -> AudioStreamWAV:
	var mix_rate: int = 22050
	var frames: int = int(seconds * float(mix_rate))
	var bytes := PackedByteArray()
	bytes.resize(frames * 2)
	for i: int in frames:
		var t: float = float(i) / float(mix_rate)
		var env: float = 1.0 - float(i) / float(frames)
		var sample: float = sin(TAU * freq * t) * env * volume
		var s16: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		bytes.encode_s16(i * 2, s16)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = mix_rate
	wav.data = bytes
	return wav


func _build_audio() -> void:
	# Two short generated blips, no loops anywhere - nothing can zombie.
	ui_click_player = AudioStreamPlayer.new()
	ui_click_player.stream = _make_blip(660.0, 0.06, 0.35)
	add_child(ui_click_player)
	release_player = AudioStreamPlayer.new()
	release_player.stream = _make_blip(190.0, 0.12, 0.4)
	add_child(release_player)


func _play_click() -> void:
	if ui_click_player != null:
		ui_click_player.play()


func _on_throw_it_pressed() -> void:
	_on_throw_it()
