extends SceneTree

## Spawn-view proof (needs a real GL frame - run under Xvfb, NOT --headless):
##   xvfb-run -a -s "-screen 0 1280x800x24" \
##     ~/workspace/tools/godot/Godot_v4.7-stable_linux.x86_64 \
##     --path . --script tests/render_spawn_view.gd
##
## Feeds fake positional trackers so the XR controllers take the pose a
## standing player would have, then asserts the things the first headset
## run got wrong - none of which the logic tests could see:
## SECOND headset run lesson: the fake trackers must use the REAL runtime
## tracker names ("/user/hand/left", "/user/hand/right" - the OpenXR user
## paths, same as PVLDS). The first version of this test fed trackers
## named "left_hand"/"right_hand", matching the production bug exactly,
## so the harness glowed green while real Touch controllers stayed dead.
##   * the held ball is visible from spawn, in the throwing hand
##   * both controller representations exist and show while tracked
##   * the panel's UI quad sits on the PLAYER side of its backing plate
##     (the shipped bug: it was behind the plate - a giant dark slab)
##   * the off-hand ray physically collides with the panel area and the
##     beam + hit marker show while hovering
##   * a click pushed through the panel viewport really fires a button
## and saves the rendered frame to tests/spawn_view.png for eyeballs.

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


func feed_tracker(tracker_name: StringName, hand: int, grip_tf: Transform3D, aim_tf: Transform3D) -> void:
	var t := XRPositionalTracker.new()
	t.name = tracker_name
	t.set_tracker_hand(hand)
	t.set_tracker_type(XRServer.TRACKER_CONTROLLER)
	XRServer.add_tracker(t)
	t.set_pose(&"grip_pose", grip_tf, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	t.set_pose(&"aim_pose", aim_tf, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _init() -> void:
	_run()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var ps: PackedScene = load("res://main.tscn")
	main = ps.instantiate()
	root.add_child(main)
	await create_timer(0.4).timeout
	check(main != null, "main scene instantiated")

	# The ball is in the throwing hand from the very first frame.
	check(main.ball_in_hand_mesh.visible, "ball visible at spawn (before any grip input)")
	check(main.ball_in_hand_mesh.get_parent() == main.grip_ctrl["R"],
		"ball rides the throwing hand (R grip controller)")

	# Both controller representations exist and carry real geometry.
	for h: String in ["L", "R"]:
		var rep: Node3D = main.ctrl_rep[h]
		check(rep != null and rep.get_child_count() >= 3,
			"controller representation built for hand %s" % h)

	# The panel's viewport quad must be on the player side of the plate:
	# panel root -Z faces the player, so the quad's local z must be < 0.
	var quad_found: bool = false
	for child: Node in main.panel_root.get_children():
		var mi: MeshInstance3D = child as MeshInstance3D
		if mi != null and mi.mesh is QuadMesh:
			quad_found = true
			var local_z: float = main.panel_root.to_local(mi.global_position).z
			check(local_z < -0.02,
				"panel UI quad is on the player side of the backing plate (local z %.3f)" % local_z)
	check(quad_found, "panel viewport quad exists")

	# Pose the rig as a standing player: throwing hand low-right with the
	# ball, off hand raised and aiming at the panel.
	var panel_center: Vector3 = main.panel_root.global_position + Vector3(0.0, 0.04, 0.0)
	var r_grip := Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-20.0), deg_to_rad(-6.0), deg_to_rad(4.0))),
		Vector3(0.24, 1.03, -0.18))
	var l_grip := Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-12.0), deg_to_rad(4.0), deg_to_rad(-4.0))),
		Vector3(-0.30, 1.12, -0.28))
	var l_aim_pos := Vector3(-0.30, 1.13, -0.28)
	var l_aim := Transform3D(Basis.looking_at((panel_center - l_aim_pos).normalized(), Vector3.UP), l_aim_pos)
	var r_aim := Transform3D(Basis.looking_at(Vector3(0.0, -0.12, -1.0).normalized(), Vector3.UP),
		Vector3(0.24, 1.04, -0.18))
	feed_tracker(&"/user/hand/left", XRPositionalTracker.TRACKER_HAND_LEFT, l_grip, l_aim)
	feed_tracker(&"/user/hand/right", XRPositionalTracker.TRACKER_HAND_RIGHT, r_grip, r_aim)

	# Regression guard: production controllers must ask for the tracker
	# names the real OpenXR runtime registers (PVLDS parity). If anyone
	# "simplifies" these back to left_hand/right_hand, this fails here
	# instead of in Chris's headset.
	check(main.grip_ctrl["L"].tracker == &"/user/hand/left", "L grip controller bound to /user/hand/left")
	check(main.grip_ctrl["R"].tracker == &"/user/hand/right", "R grip controller bound to /user/hand/right")
	check(main.aim_ctrl["L"].tracker == &"/user/hand/left", "L aim controller bound to /user/hand/left")
	check(main.aim_ctrl["R"].tracker == &"/user/hand/right", "R aim controller bound to /user/hand/right")

	# Photo camera where the player's head is.
	var photo_cam := Camera3D.new()
	photo_cam.position = Vector3(0.0, 1.56, 0.42)
	main.add_child(photo_cam)
	photo_cam.look_at(Vector3(-0.26, 1.08, -1.2), Vector3.UP)
	photo_cam.current = true

	for i: int in 10:
		await physics_frame
	for i2: int in 4:
		await process_frame

	check(main.grip_ctrl["R"].get_is_active(), "fed tracker drives the R controller (active)")

	# The panel DEBUG block must be alive and reading the fed trackers:
	# on hardware this is the block that names the dead link in the chain.
	check(main.debug_label != null, "panel DEBUG block exists")
	check(main.debug_label.text.contains("DEBUG"), "DEBUG block is updating")
	check(main.debug_label.text.contains("FOUND"), "DEBUG block sees the fed trackers as FOUND")
	for h2: String in ["L", "R"]:
		var rep2: Node3D = main.ctrl_rep[h2]
		check(rep2.visible, "controller representation visible while tracked (%s)" % h2)
	check(main.ball_in_hand_mesh.visible, "ball still visible in hand after spawn frames")

	# The pointer: ray physically hits the panel, beam + marker are shown.
	var ray: RayCast3D = main.pointer_ray_by_hand["L"]
	check(ray.is_colliding() and ray.get_collider() == main.panel_area,
		"off-hand ray collides with the panel area")
	var beam: MeshInstance3D = main.pointer_beam["L"]
	var hitm: MeshInstance3D = main.pointer_hit["L"]
	check(beam.visible, "pointer beam visible while aiming")
	check(hitm.visible, "hit marker visible on the panel")

	# Render the frame and save it.
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	var out_path: String = ProjectSettings.globalize_path("res://tests/spawn_view.png")
	var err: Error = img.save_png(out_path)
	check(err == OK, "spawn view screenshot saved to tests/spawn_view.png")
	var distinct: Dictionary = {}
	var step: int = 8
	for x: int in range(0, img.get_width(), step):
		for y: int in range(0, img.get_height(), step):
			distinct[img.get_pixel(x, y).to_rgba32()] = true
	check(distinct.size() > 25, "rendered frame is a real scene, not a flat void (%d sampled colors)" % distinct.size())

	# A click pushed through the panel viewport really fires a button:
	# press the Posture button at its laid-out center and watch state flip.
	var before: String = main.posture
	var center: Vector2 = main.posture_btn.get_global_rect().get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = center
	main.panel_viewport.push_input(press)
	var release_ev := InputEventMouseButton.new()
	release_ev.button_index = MOUSE_BUTTON_LEFT
	release_ev.pressed = false
	release_ev.position = center
	main.panel_viewport.push_input(release_ev)
	await create_timer(0.3).timeout
	check(main.posture != before, "panel click works end-to-end (posture %s -> %s)" % [before, main.posture])

	print("---")
	if failures == 0:
		print("SPAWN VIEW: ALL %d CHECKS PASSED" % checks)
	else:
		print("SPAWN VIEW: %d of %d CHECKS FAILED" % [failures, checks])
	quit(1 if failures > 0 else 0)
