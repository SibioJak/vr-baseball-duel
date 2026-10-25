# VR Baseball Duel — DE Feel Test

A feel test, not a game. It exists to prove or kill the duel's core theory —
**your own enrolled motions, pro output** — before anything is built around it.

You teach the game *your* fastball and *your* curveball motions, calibrate
your arm, and then throw: the game classifies each throw against your own
templates, reads its velocity through calibration + boost, and posts it on a
stadium speed gun. Then you step into the batter's box and watch your own
pitches come back at you — with the delivery retimed so the arm speed
plausibly matches the number on the gun (the slow-arm/98-mph oddity fix).

## Run it (PCVR, from the editor)

1. Pull this repo on your PC.
2. Open Godot 4.7, import the project (select `project.godot` in this folder).
3. Start Virtual Desktop on the Quest 3 and connect to your PC (your usual
   PVLDS routine — SteamVR/OpenXR runtime live).
4. Press F5 in Godot.
5. You spawn on the mound **holding a ball** in your throwing hand (orange
   band = right controller, cyan = left). The panel floats in front of you,
   slightly left. Point your other hand's beam at it — red while aiming,
   green when it's on the panel, with a dot where it lands — and pull the
   trigger to click.

If OpenXR isn't live, the panel says so and you get a flat desktop camera —
that's the failure mode, not the test.

## What to do in the headset

1. Pick throwing hand + posture (sitting or standing) on the panel.
2. **Begin enrollment.** Follow the prompts:
   - **Gaze calibration (eleventh pass, first step):** five targets light
     one at a time on the strike-zone frame — center, then the corners.
     Look at the lit target and hold your gaze; it captures by itself
     when your head is still (no buttons). From the five looks the game
     fits the fixed rotation between the headset's forward and *your*
     eye line, and every later pitch aims with the corrected line.
     The fit is robust (twelfth pass): a look that doesn't match the
     others — say the first dwell fires while you're still reading
     this panel — is left out and the panel says so; if the looks
     never agree, the step refuses rather than applying a bad
     correction. **Re-gaze** (in the re-enroll row) re-runs just
     this step.
   - 3 hardest *comfortable* fastballs (calibration — your 100% becomes 96 mph),
   - 3 fastball motions,
   - 3 FAST fastballs and 3 MEDIUM fastballs (your velocity gears — each
     anchor is the **median** of its 3 throws, so one wild throw can't
     drag it the way an average can).
   A throw = hold **grip** to hold the ball, make your motion, **release grip**
   at your release point. **Aim is your eye line, not your hand**
   (eleventh pass — two sessions of throw-log data retired hand-velocity
   aim: it scattered 12–18° across throws while the head line scattered
   2.8°). The pitch targets where your corrected gaze crosses the plate;
   a share of your hand's miss leaks in, scaled by the **Scatter slider**
   (0.00–0.60, default 0.25, next to Boost) — a clean delivery flies true
   to your look, a sloppy one leaks. The launch is drop-compensated
   against the flight sim, so the ball crosses where it was aimed. If a
   throw somehow carries no head data, it falls back to the old
   peak-speed-window arm direction, unchanged.
   - **Fastball only, for now (ninth pass):** enrollment is the fastball
     and its gears, and free throw treats every throw as a fastball — the
     classifier isn't consulted until a curveball exists. The curveball
     machinery is built and parked, not removed: **Re-enroll CB** still
     runs its step, which is different when you get there — before you
     throw, pick a *picture* — **Turn the doorknob**, **Pull the shade
     down**, or **Karate chop** — and a translucent ghost arm in front of
     you demos that motion on a loop. The game reads the *twist itself*
     (forearm roll is a first-class classifier feature), so a curveball
     that's just a slower fastball gets called out by name: the
     separation warning will tell you the twist isn't reading.
3. Once a curveball is enrolled alongside the fastball, if the two motions
   read too similar the panel warns you in plain words and offers re-enroll
   buttons. It never silently accepts a mushy pair.
4. **Free throw** on the mound: with only a fastball enrolled, every throw
   is a fastball — geared (FAST/MEDIUM), flown, and posted on the gun board
   with its strike/ball call and your PBs. With a curveball enrolled too,
   each throw is classified (type + confidence) as before.
   **Calibration is session-locked:** if you beat your calibrated max in
   free throw, the gun does *not* re-anchor mid-session (an earlier build
   did, and the mph scale moved between throws). The panel notes the new
   personal max, the throw record flags it, and it merges into your
   calibration at the next enrollment.
5. **Go to BOX (watch)**: pick FB / CB / MIX, press THROW IT. The AI arm
   replays *your enrolled motion*, retimed (delivery phase time-warped,
   bounded 1.0–3.0x) so visible arm speed matches the pitch's game velocity.
   Windup and style stay yours; only the whip is sped up.

Enrollment persists (`user://duel_profile.json`) — re-tests skip setup.
"Erase profile" wipes it.

## Controls (complete list — also on the in-world panel)

- **Throwing hand GRIP**: squeeze to start the throw; release at your
  release point to throw. A ball is in your hand from spawn — the squeeze
  starts the measured throw, it doesn't summon the ball.
- **Your arm**: the throw itself — it sets the velocity (and, scaled by
  the Scatter slider, the leak). **Your eyes**: the aim — look at your
  spot through the delivery.
- **Other hand**: point the beam at the panel (red = aiming, green = on the
  panel, dot = hit point); **TRIGGER** clicks buttons and drags the Boost
  and Scatter sliders. The beam flashes on a click.
- **Your gaze (enrollment)**: look at each lit target and hold still —
  gaze calibration captures by dwell, no buttons.
- **Quest system button (long-press)**: recenter (OS-level, not bound by the game).
- Nothing else is bound. There is no keyboard/mouse control in the headset.

## What you're judging (the three verdict surfaces)

**Current scope (ninth pass): fastball only.** The live surfaces are #2 and
the fastball half of #3 — the gun's honesty on fastballs (velocity, gears,
flight, aim) from a full pitching motion. Surface #1 and the curveball come
back when a curveball is enrolled.

1. **Classifier separation** — does it tell your fastball from your curveball
   at game speed, and does the confidence % look honest (including on a
   deliberate in-between throw)?
2. **Honest velocity** — harder throw, bigger number, boost on or off; your
   MEDIUM gear reads as your medium; 100% effort reads ~96.
3. **From the box** — does the fastball *feel* like its number, does the
   curveball *break like a curveball*, and does the retimed arm read as
   natural or as a new weirdness?

## Deliberately NOT in this build

Multiplayer, ABS challenges, practice targets, kid modes, fielding,
batting/swinging, innings/score/game structure, art polish beyond legibility,
sound beyond two tiny UI blips (no loops — nothing can play after close).

## Known simplifications (honest list)

- Hand velocity/angular velocity come from controller world-transform finite
  differences at 90 Hz with light smoothing — not raw IMU. Enough to separate
  *your own* motions; that is the design bet being tested.
- Grip is binary hold/release (grip button), not finger tracking — per spec,
  literal seam-reading is impossible on stock Quest 3 controllers.
- The optional third pitch can't be named in-headset (no keyboard); it's
  stored and shown as "THIRD PITCH".
- Strike zone heights are fixed per posture (standing 0.48–1.06 m, sitting
  0.42–0.96 m), not measured from your body.
- Magnus/drag constants are tuned so break *reads*; flight time for 96 mph
  measured 0.458 s headlessly vs ~0.43 s real — close, slightly floaty.
  Ball spin is modeled at true scale (fastball ~1815–2010 rpm, curve
  ~2050–2435 rpm); measured headlessly, the 96 mph fastball drops 0.81 m
  against its no-gravity line and the curve breaks 0.36 m off a
  same-speed fastball.
- Forearm roll is measured about the throw axis (release velocity
  direction) from controller orientation — a consistent proxy for the
  forearm's long axis at release, not a skeletal measurement. Templates
  and throws are read through the same proxy, so the comparison is fair.
- Profiles saved before the roll upgrade (format v1) load with their
  calibration, gears and PBs intact, but their pitch templates are
  dropped with a panel explanation — v1 measured 12 features, the
  classifier now reads 15, and old templates would silently misread.
- Aim was read from the hand through the tenth pass; the session data
  retired it (hand intent scattered 12.3° in session 1 and 18.0° in
  session 2, while the head line scattered 2.8° with 0.2° in-delivery
  stability). The eleventh pass rebuilt aim on the head line (see
  "What to do in the headset"); the throw recorder is now v3 and logs
  the aim decomposition per throw (raw head cross, corrected target,
  final aim cross, scatter k, gaze flag) beside the achieved cross.
  Hand aim survives only as the fallback for a throw with no head
  data — and as the leak the Scatter slider meters.

## Verification (what the machine checked vs what it can't)

Headless, with the real Godot 4.7 binary:

- `tests/run_tests.gd` — 68 checks on the pure logic: classifier separates
  synthetic FB/CB and rejects a mushy pair, velocity mapping/gears, warp
  bounds and delivery compression, flight times, curveball crosses 0.82 m
  below a same-speed fastball, profile round-trip. The seventh-pass
  checks are the decisive ones: two arsenals at *identical* speed and
  identical scripted angular velocity, differing only in written wrist
  twist, classify FB vs CB correctly (roll reads 2.39 rad for a 2.4 rad
  twist; a no-twist throw at curveball speed does *not* read CB); a
  no-twist pair fails separation with the roll gap named; release intent
  stays on the peak-speed direction (0.0°) while the skewed final frame
  sits 38° away; flight geometry asserts fastball drop ≥ 0.80 m (0.81)
  and curveball total break ≥ 0.35 m (0.36). The tenth-pass logic
  checks cover the head-line summary (a still head reads release =
  window = peak forwards at 0.0° stability; a turning head reads real
  instability; headless samples report no head data) and the median
  (the split gear pair 9.96/4.95/7.45 medians to exactly 7.45). The
  eleventh-pass logic checks cover the aim model: plate-cross geometry;
  scatter (k=0 → aim cross is the target exactly; k=0.25 → a quarter of
  the way from T to I); the gaze fit (a head worn with a constant
  +5°/+4° bias through the five targets fits to ~0.0° residual, and a
  corrected center look lands within 0.15 m of zone center); and the
  drop-compensated launch solve (the simulated ball crosses within
  0.10 m of the aim point at 96 mph and at 65 mph). All pass.
- `tests/smoke_main.gd` — 93 checks driving the real main scene: full
  enrollment flow, free throw classified and announced ("FASTBALL at 95 mph"),
  watch-mode curveball announced, profile save/reload/wipe — plus the
  cue flow (picker + ghost show only on the CB step, the chosen picture
  is stored with the template and survives a reload), the v1→v2
  profile upgrade (templates dropped with an explanation, calibration
  carried over), and the eighth-pass throw recorder (an accepted free
  throw through `_finalize_throw` appends a parseable JSONL record with
  samples, 15 labeled features, both release directions and the
  verdict; a too-soft rejection appends its reason; Clear truncates).
  The tenth-pass smoke checks cover recorder v2 (a head-carrying throw
  lands with per-sample `hp`/`hq` and head summaries matching the worn
  pose; a headless throw records nulls), the calibration session lock
  (an over-max free throw leaves `calib_max` untouched, flags its
  record and the panel note, stores the pending max, and the pending
  max merges at the next enrollment start), and the gear median (the
  step refuses to complete at 2 throws; 9.96/4.95/7.45 anchors at
  exactly 7.45). The eleventh-pass smoke checks cover the gaze step
  (a wandering head never captures; a still head captures all five
  targets by dwell, fits the correction, and hands off to calibration
  in the default flow), recorder v3 (a head-carrying throw records
  target/aim/raw crosses with the live scatter k; a no-head throw
  records null aim fields), and the v2→v3 profile upgrade (templates
  SURVIVE — no vector changed — gaze loads uncalibrated with a Re-gaze
  suggestion; scatter round-trips). All pass.
- `tests/gaze_field_path.gd` — 27 checks (twelfth pass): the gaze
  pipeline end to end through the REAL field path — real dwell
  captures on a synthetic biased head, profile save, fresh load, real
  `_compute_aim`. Phase 3 is the session-3 reproduction: one capture
  taken looking at the PANEL (the step starts the instant Re-gaze is
  pressed there) among four honest ones. On the pre-fix plain-mean
  fit it landed the corrected target 1.96 m off zone center; the
  robust fit (medoid consensus, mismatched captures dropped, refusal
  when fewer than 3 agree) drops the bad look and lands at 0.00 m.
  Phase 4 pins the recorder diagnostics: every throw record's state
  snapshot now carries `gaze_correction_quat`, `gaze_offset_deg` and
  `gaze_fit_residual_deg`, so a field miss decomposes from the log
  alone. Session 3's field miss is what this pass fixed: the applied
  correction was a constant rotation +1.45 m right of the raw look —
  a fit poisoned by a mismatched capture, certified without ever
  checking that the captures agreed with each other.
- `tests/render_spawn_view.gd` — 44 checks: renders an actual frame of
  the spawn view (Xvfb + GL) with the rig posed as a player stands, and
  saves it to `tests/spawn_view.png`: panel in front with legible UI
  text, ball in the throwing hand, both controller representations
  visible, off-hand beam landing on the panel. It also asserts the
  pointer ray physically hits the panel's collision area, that aim and
  clicks through the production picking path land on the pointed-at
  button (not a neighbor), and that the cue ghost + picker appear on
  the CB step. This test exists because the first headset run found a
  panel whose UI quad sat *behind* its backing plate (a dark slab, no
  ball, no visible hands/ray) while every logic check passed.
- Clean `--import` and a brief headless run with zero script errors (OpenXR
  loader errors on this VM are expected — it has no VR runtime).

**Not verified by any machine: everything that happens in the headset.**
Tracking quality, throw feel, panel readability, retiming naturalness — those
are Chris's verdicts, per the three surfaces above.
