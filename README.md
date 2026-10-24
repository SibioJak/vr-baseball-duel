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
   - 3 fastball motions, 3 curveball motions, an optional third pitch (skippable),
   - 2 FAST fastballs and 2 MEDIUM fastballs (your velocity gears).
   A throw = hold **grip** to hold the ball, make your motion, **release grip**
   at your release point.
3. If your fastball and curveball motions read too similar, the panel warns
   you in plain words and offers re-enroll buttons. It never silently accepts
   a mushy pair.
4. **Free throw** on the mound: every throw is classified (type + confidence),
   geared (FAST/MEDIUM), flown with movement from *your* wrist action, and
   posted on the gun board with its strike/ball call and your PBs.
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

## Verification (what the machine checked vs what it can't)

Headless, with the real Godot 4.7 binary:

- `tests/run_tests.gd` — 28 checks on the pure logic: classifier separates
  synthetic FB/CB and rejects a mushy pair, velocity mapping/gears, warp
  bounds and delivery compression, flight times, curveball crosses 0.82 m
  below a same-speed fastball, profile round-trip. All pass.
- `tests/smoke_main.gd` — 15 checks driving the real main scene: full
  enrollment flow, free throw classified and announced ("FASTBALL at 95 mph"),
  watch-mode curveball announced, profile save/reload/wipe. All pass.
- `tests/render_spawn_view.gd` — renders an actual frame of the spawn view
  (Xvfb + GL) with the rig posed as a player stands, and saves it to
  `tests/spawn_view.png`: panel in front with legible UI text, ball in the
  throwing hand, both controller representations visible, off-hand beam
  landing on the panel. It also asserts the pointer ray physically hits
  the panel's collision area and that a click pushed through the panel
  viewport really fires a panel button. This test exists because the first
  headset run found a panel whose UI quad sat *behind* its backing plate
  (a dark slab, no ball, no visible hands/ray) while every logic check
  passed.
- Clean `--import` and a brief headless run with zero script errors (OpenXR
  loader errors on this VM are expected — it has no VR runtime).

**Not verified by any machine: everything that happens in the headset.**
Tracking quality, throw feel, panel readability, retiming naturalness — those
are Chris's verdicts, per the three surfaces above.
