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
2. **Begin enrollment.** Follow the prompts, one throw at a time:
   - 3 hardest *comfortable* fastballs (calibration — your 100% becomes 96 mph),
   - 3 fastball motions,
   - 3 FAST fastballs and 3 MEDIUM fastballs (your velocity gears — each
     anchor is the **median** of its 3 throws, so one wild throw can't
     drag it the way an average can).
   A throw = hold **grip** to hold the ball, make your motion, **release grip**
   at your release point. The ball flies where your *arm* was throwing —
   direction is read from the peak-speed window of the delivery, not from
   the frame where the grip happened to let go.
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
- **Your arm**: the throw itself. Nothing else affects the pitch.
- **Other hand**: point the beam at the panel (red = aiming, green = on the
  panel, dot = hit point); **TRIGGER** clicks buttons and drags the Boost
  slider. The beam flashes on a click.
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
- Aim is still read from the hand (release intent, seventh pass). The
  session-1 throw data says that signal scatters ~12° from a full
  windup — the velocity direction sweeps 8–24° per 90 Hz frame near
  release — so the throw recorder (v2, tenth pass) now also logs the
  **head line** on every sample (`hp`/`hq`) plus per-throw head
  summaries (forward at release, over the delivery window, at peak
  hand speed, and window stability). Whether the eye line is the
  tighter signal gets judged on that data before any aim rebuild;
  nothing in-game reads the head fields yet.

## Verification (what the machine checked vs what it can't)

Headless, with the real Godot 4.7 binary:

- `tests/run_tests.gd` — 52 checks on the pure logic: classifier separates
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
  (the split gear pair 9.96/4.95/7.45 medians to exactly 7.45). All pass.
- `tests/smoke_main.gd` — 78 checks driving the real main scene: full
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
  exactly 7.45). All pass.
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
