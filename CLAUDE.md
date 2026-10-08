# UltraController — working rules

Universal first/third-person character controller for Godot 4.7.1 (GDScript, Forward+,
Jolt). Reusable addon in `addons/ultra_controller/`; demo + playground in `demo/`.
Plan: `C:\Users\Lappy\.claude\plans\using-the-model-and-mossy-haven.md` (M1–M8).

## Engine and tools
- Godot: `C:\Dev\Godot_v4.7.1-stable_win64.exe` (shared with Moonlit_Ridge, pinned). Always `--path .`.
- Blender 5.0 (`C:\Program Files\Blender Foundation\Blender 5.0`), MCP `mcp__blender__*`.
- **Verify on a fresh copy:** `bash tools/verify.sh m1 [--keep] [--tour]` → `C:\Dev\verify\ultra\`
  (its own `user://`; screenshots in `C:\Dev\verify\ultra\review\<suite>`). Never write to
  `C:\Dev\verify\review` — that is Moonlit Ridge's.
- Tests: `godot --headless --path . --fixed-fps 60 res://tests/test_runner.tscn -- --suite=m1`
  (scene runner, not `--script`, so autoloads work). Suites live in `tests/suites/<suite>_*.gd`.
- Capture tour: `godot --path . --resolution 1280x720 -- --tour=m1 --out=<dir>`.
- `bash tools/verify.sh m2` also runs real server+client processes over localhost ENet with
  `--lag/--jitter/--loss`; each client prints `NETREPORT` (corrections, queue depth) and fails
  the run past the limits. Launch presets: `-- --launch=01_host_client` or Project > Tools > Ultra.
- Regenerate after changing the importer / clips:
  1. delete `.godot/imported/mannequin.glb-*` then `--import` (a changed import *script* does not trigger reimport)
  2. `--script res://tools/build_animset.gd` (measures clips, writes mannequin_animset.tres)
  3. `--script res://tools/build_resources.gd` (input map seed, layer names, profiles, body profile)
     (only via `--script`: run through tool_runner it wiped mannequin_body_profile.tres' hitboxes
     and extra_libraries - check `git diff` on the body profile after any builder)
  4. `res://tools/tool_runner.tscn -- --tool=res://demo/maps/playground/build_playground.gd` (a Node tool: it needs the
     autoloads, so not `--script`)
  5. after a MODEL change: `blender --background --python tools/blender/ultra_blender.py --
     make-cuts` (dismemberment pieces, mannequin_cuts.glb), then `--import`

## Architecture (don't break these)
- **Input is data.** Actions live in Project Settings > Input Map (`uc_*`, seeded by
  `UltraInputDefaults.install_missing`, never overwriting). Code reads `UltraInput.action(&"jump")`.
  No `KEY_*`/`JOY_*` outside `addons/ultra_controller/input/` (verify.sh greps for it).
  Tunables: `ultra_controller/input/*`; per-player overrides + rebinds in `user://ultra_input.cfg`.
- **The motor is a pure step:** `UltraMotor.step(MotorState, InputFrame, dt)`. All sim state is in
  `MotorState` (copyable, codec'd); state handlers are stateless. Single-player, server, client
  prediction and replay all call the same function. Never read wall-clock or render state in it.
- InputFrame carries **absolute** quantized yaw/pitch (`quantize()` before use) so packet loss
  can't drift aim and the local sim matches the server bit-for-bit.
- **Root motion is baked** (`RootMotionCurve`, char space, -Z forward) and played by the motor;
  the AnimationTree's `root_motion_track` only strips it from the pose.
- Presentation is separate: `VisualRoot` (top_level, interpolation OFF) is placed every frame from
  the last two ticks + `visual_offset` (step pops, reconciliation smoothing).
- Nothing names a clip or bone in gameplay code: roles → clips via `AnimationSet`, model facts in
  `BodyProfile`. Swapping Mixamo/Blender clips = editing those resources.
- Skeleton is retargeted to `SkeletonProfileHumanoid` at import (`GeneralSkeleton`, bone names
  `Hips`, `LeftFoot`…). Model faces +Z; the body node is turned 180°.
- **No MultiplayerSpawner/MultiplayerSynchronizer** (4.7.1 GH-109864) — custom RPC tick system
  in the `UltraNet` autoload. Modes OFFLINE/HOST/CLIENT/DEDICATED all run `_server_step` or
  `_client_step`; single-player is OFFLINE (AUTHORITY_LOCAL, zero latency, same motor path).
- **State is quantized every tick** (`UltraCharacter.quantize_state`, on in sessions): server and
  client compute on identical bits, so a client rebased onto a snapshot re-predicts exactly.
- Clients send **every unacknowledged input** (≤60, 1 s: survives an OS stall) each tick; the server keeps an ordered queue,
  waits ≤10 ticks on a hole, never guesses inputs. Clock dilation keeps the queue ~2 deep.
- **ENet throttle is disabled** per peer (`_no_throttle`) — it silently dropped bursts of
  20 unreliable packets on localhost under CPU load.
- Moving platforms are `TickPlatform` (pose = f(tick)); the motor carries riders itself
  (`platform_floor_layers = 0`). Clients map their ticks to server ticks via `server_tick_offset`.
- Characters collide SOFTly by default (`MovementProfile.character_collision`): prediction against
  a remote player you see ~100 ms late can't be exact; soft separation keeps errors small.

- **Traversal is a motor transition hook** (`UltraTraversal.hook`): pure physics queries on the
  state, so client and server pick the same move. Scripted moves (MANTLE/VAULT/LEDGE_CLIMB) are
  `trav_from -> trav_to` over `trav_dur`; hang/ladder/rope keep their anchor in `trav_*` fields.
  Ropes are a pendulum in MotorState (`trav_from` = swing velocity); the verlet rope is cosmetic.
  Every rope swings and climbs (Kind is legacy): looking level, forward/back pumps; looking
  up/down > 25 deg, forward/back climbs toward the look (`UltraRope.climb_input`). The rope
  body collides (`test_move`): walls stop the swing, feet meeting the ground stand you up.
  Swing period from the centre of mass (gravity scaled by L / (grip + 1 m)). Swinging into a
  loose prop transfers momentum along the contact (profile.mass vs prop mass).
  The drawn rope (UltraRope, presentation) is a verlet chain at 120 Hz: taut from anchor to the
  climber's hands, free tail; floors are a height clamp inside the solve (+ static friction),
  walls a swept ray; characters (holder: a slim body capsule) and moving props push it;
  it sleeps when still. Ropes process after characters (process_priority 150).
- Two-handed states (`UltraActionLayer.TWO_HANDED`: climbing, hanging, ropes, swimming,
  crawling, rolling, down) stow the item in hand at once; it's drawn again afterwards.
  Hands/feet on rope, ledge, ladder are presentation (`UltraTraversalVisual`, IK priority 111 >
  equipment 110). `HandIKModifier` has 4 limbs (hands, then feet); `hand_basis(h, fingers, palm)`
  orients a hand (palm learned from the curled fingers). Ledge: palms over the lip. Ladder: the
  limb the clip brings near a rung snaps to it (`RUNG_HAND/RUNG_FOOT`, rungs `UltraLadder.FIRST_RUNG
  + i*RUNG_SPACING`). Swing-rope legs follow the rope's angle (kick out front / back).
- **Water is analytic** (`UltraWater.find/surface_y(tick)`): box volumes, level a function of the
  world tick (valves replicate `{from,to,t0,dur}`), so swimming predicts. SWIM floats the feet
  `float_depth` under the surface on a damped spring; DIVE uses a 0.8 m capsule and 3D aim
  movement; `breath` is in MotorState. Buoyancy for props runs wherever physics is
  authoritative (`UltraNet.mode != CLIENT`; tests run in NONE). Swim visuals (stroke lift,
  dive pitch) are presentation in `UltraCharacter._swim_visual`.
- **Damage is per region** (`UltraLimbs`: 14 regions - hands and feet APPENDED as 10-13 so old
  indices / dummy booth buttons hold; BELOW lists every region under one; arm() / leg() take the
  worst along the chain, so a lost hand moves the weapon, a lost foot forces a crawl). `limb_hp` (percent) and the `severed`
  mask live in MotorState, so injuries change movement predictably (`UltraInjury`: speed, no
  sprint/jump, forced crawl, no climbing, weapon hand). Only the authority changes them
  (`apply_damage`); remote players get 2-bit statuses in snapshots. Which limb a shot hit comes
  from region capsules (`UltraHitboxes.build`): from the live posed skeleton when there is one
  (`UltraCharacter.live_hitboxes`, captured at `skeleton_updated` in the character frame), else
  baked into the BodyProfile (`tools/make_hitboxes.gd`) for a headless server. Severed regions
  can't be hit. Shots test a wide `HitVolume` (HITBOX layer; lies along a downed body), then must
  pass through a limb capsule. The head capsule runs along the Head bone's own up axis.
- Thrown props (`UltraGrab.mark_thrown`, 2.5 s) hitting a character (authority, swept against
  the capsule each tick in `UltraGrab.impacts`): momentum m*|v_rel| >= 5 hurts (kind `impact`,
  no blood) and shoves; >= `MovementProfile.impact_knockdown` (40) knocks into RAGDOLL.
- Knock-down is a deterministic low capsule (RAGDOLL -> GET_UP states); the floppy body is a
  local `PhysicalBoneSimulator3D` (UltraRagdoll). An inactive simulator still writes the pose:
  keep `influence = 0` while it's off. Dismemberment scales the region's root bone to ~0 in the
  last modifier (`DismemberModifier`, must stay after the simulator), caps it, and spawns a gib
  skinned on the CPU from the region's triangles.
- **Jolt ignores PhysicalBone3D joint limits** (probed: setting them to 5 deg changes nothing).
  `UltraRagdoll._drive` enforces them (cones; knees/elbows never bend backwards about +X),
  caps joint speed (`max_joint_speed`) and adds muscle tone: bones are PD-driven toward the
  pose at the moment of the knock-down, blending to a brace pose (Death_A 3.3 s), fading from
  `tone_start` to `tone_down` (`tone_dead` when dead); damping rises once down so it settles.
  A damped pull keeps the body near the deterministic capsule for the first ~1.2 s.
- Get-up picks the clip from how the ragdoll lies: face up = LayToIdle (after holding its
  lying frame), face down = Mixamo GetUp_Prone 1.4-5.3 s (role `get_up_front`; fallback
  Death_A reversed). Clips are cut/held at runtime (`UltraAnimMirror.segment`). The body
  starts at the ragdoll's hips and yaw and eases onto the capsule. GET_UP_TIME 2.8. During
  GET_UP the neck/head are low-passed against the chest (`BodyDynamicsModifier.head_calm`):
  the prone clip, played 1.4x, whips the head.
- Climbing / hanging / ropes: looks go to the neck and head (`spine_aim_scale` 0.15, pitch
  <= 0.95 rad) so the chest and hands stay on the wall.
- First person while down (RAGDOLL/DEAD/GET_UP): the camera is the head's real eye pushed
  15 cm out of the face (swept clear of the floor), view pitch >= -50 deg and roll <= 25 deg
  (`_tame_view`: heading from the top of the head when looking straight down, roll measured
  around the view - measuring it against world up flipped +-90 deg face down). Getting up,
  the view follows the head loosely (rate-limited 90 deg/s) and hands back to your aim.
- Body materials dither away within 0.15-0.27 m of any camera (`_near_fade_mat`); the body and
  head meshes are both capped (`UltraMeshCap`, skin-coloured).
- Ground locomotion has two stances, blended by a Blend2 `stance` (+ `idle_stance` for idle):
  * Neutral (unarmed / pistol): `_build_neutral`, roles n_walk_f (Mixamo Standard Walk
    N_StdWalk2), n_walk_b (Walk_Backwards), n_side (UAL Strafe, other side mirrored), n_jog_f,
    n_sprint_f. Ring F/R/B/L + a forward walk->jog->sprint line; nearest direction + hips warp.
    Natural arm swing comes from the clips - the old "relax" Blend2 / arm_swing hack is gone.
  * Bladed (two-handed item whose clip turns the hips > BLADED_HIPS 0.4 rad): Mixamo Rifle
    8-Way pack R_* (roles e_walk_*/e_run_*/e_sprint_*; plant_phase 0). Walk/run clips are
    turned so their mean hips match the rifle_aim clip's hips (legs + torso agree, so
    item_hips_yaw twist ~0 = no sideways lean); sprints stay as authored. Idle plays the
    item's aim clip on the legs too. Nearest clip + hips warp (<= 22.5 deg), 6 deg hysteresis
    + inertial blend (mixing two neighbours shortened the stride: skating).
  Mixamo clips can carry a stance: check hip/shoulder facing + lean with
  `tools/measure_mixamo.gd` (writes the animset - back it up when only measuring). The rifle
  8-way legs looked crouched under an unarmed body; never use them for the neutral stance.
- `knock_down` / death set state.vel from the push (they run outside a motor step).
- Upper-body item clips can be mirrored at runtime (`UltraAnimMirror`; the skeleton is mirror
  symmetric). `BodyDynamicsModifier.item_hips_yaw` turns the spine by the item clip's own hips
  yaw so a mirrored clip isn't twisted by unmirrored legs.
- FP eye: follows the head's yaw only, never its pitch (pitch swung the eye out in front of the
  body exactly when looking down at it).
- Modified bone poses are only readable during `skeleton_updated` (tests: sample there).
- Gait: `MovementProfile.default_gait` WALK (default: full input = walk 1.35 m/s, Shift =
  sprint) or JOG. The blend space has a "walk_brisk" point (the walk cycle at 1.75x) so walk
  speeds never pull in the jog's 2.8 m stride. Hips warp toward travel from ~1.35 m/s.
- Backpedal diagonals: legs turn at most `back_warp_deg` (35) toward travel, the back +
  side-step clips blend the rest. With UAL clips the right side-step is a mirrored Strafe_Left
  (Strafe_Right skates); Mixamo side-steps aren't mirrored. back_mult 0.82, strafe 0.95.
- Stepping down a stair keeps you grounded (`UltraMotor._snap_down`, a ray under the capsule's
  centre; never on a TickPlatform - a raycast can see its pose a frame stale during replay);
  the fall clip waits 0.15 s of real air before showing.
- Hard landings (> hard_land_speed 15.5 m/s, ~8 m; the 6 m drop lands on its feet): falling,
  `UltraMotor.predict_impact` sweeps a sphere along the ballistic arc against the static world
  (a jump to the next platform lands on it - vertical rays saw the pit below and ragdolled
  platform jumps); {} for water / moving platforms. 0.6 s before a hard impact the body goes
  RAGDOLL keeping its speed (air drag 0.3 m/s2); rope catches are untouched. It lands with
  just its own momentum (an extra tumble boost / roll spin at touchdown read as a second shove:
  removed); the ragdoll's settle / tone / capsule-pull clocks start at touchdown (`_t`), not when
  it went limp (`_t_limp`). No landing roll (the user didn't want it): LAND keeps
  85 % speed.
- Edge balance (`UltraMotor.update_balance`, after every ground move): nothing under the
  capsule's middle within a step and a drop > `balance_drop` (0.45 m) below = perched on a
  lip. Walking out over the drop steps off (normal FALL); stepping back recovers; otherwise
  `MotorState.teeter` counts up and at `teeter_time` (0.7 s) you topple off (RAGDOLL, push
  toward the drop). The arms windmill meanwhile (role `teeter`, Lose_Balance 3.3-4.4 s,
  upper-body Blend2 "teeter" at the end of the root tree).
- Climbable walls (CLIMBABLE layer): walking into one starts WALL_CLIMB (jumping at it too).
- Menus work on a pad: ui_accept/ui_cancel get A/B (`UltraInputDefaults.UI_PAD_EVENTS`,
  merged by install_missing and at runtime by `UltraInput.ensure_ui_pad_events`); shared focus
  style `ui/menu_style.gd`; open menus join group `ultra_modal` (HUD ignores input). Re-enabling
  a LocalInputSource drops held inputs (A on Resume used to jump). Companion = F8 only (it was
  also D-pad Up, which spawned the "extra player" in split screen). Suite `ui` drives menus with
  simulated pad events.
- Limp: `UltraInjury.leg_damage` grades each leg 0 (>= 85 %) .. 1 (<= 25 % / crippled /
  severed); it drives the speed (graded to injured_leg_speed at 50 %) and the animation:
  a second ground blend space with Mixamo Injured_Walk / Injured_Walk_Back (roles
  limp_f/limp_b; mirrored per bad leg - the forward clip's bad leg is the left, the back
  clip's the right) mixed in by the damage.
- Holding: the prop follows `UltraGrab.hold_yaw` (aim when the body faces the aim, else the
  body's facing - third person). The hold spring damps against the holder's velocity and turn
  rate (it used to trail by speed * 2 zeta / omega). Team lift: a grip more than TEAM_REACH
  (0.3 m) from your hands for 0.25 s (after a 1 s grace) lets go.
- Ledge hang = BlendSpace1D braced idle (Braced_Catch last frame) / Shimmy_L (-1, moves to the
  character's left) / Shimmy_R (+1);
  ladder = Mixamo Ladder_Climb. `AnimDriver._refit` shifts a clip's Hips track so the mean hand
  position hits a target, and turns clips authored facing -Z (the ladder clip) round first.
- Roll (ROOT_MOTION) hands control back once 97% of its travel is done and there's input.
- Sprint is a toggle by default (`ultra_controller/input/toggle_sprint`), cleared by easing off
  forward. Respawn: `uc_respawn` (F9/Backspace), below `kill_height`, or 5 s dead
  (`UltraNet.respawn_character`). Pause menu has Main menu (reloads the scene with a meta flag).
- Pistol grip is fitted to the posed fingers (`UltraGripFit`, run by tools/build_items.gd);
  the reload plays as authored in third person; in first person both hands' clip motion is
  shifted out in front of the eye by IK (`_drive_reload`). Don't IK the gun to a fixed pose.
- Head stabiliser (`BodyDynamicsModifier.head_stabilize`): removes most of the clip's own fast
  head yaw swing (sprint: 48 deg -> 13); hip side-sway damped at speed. It turns AGAINST the
  deviation (it used to turn with it and doubled the whip; m1_blend.test_head_steady_when_sprinting).
- Water waves: `UltraWater.wave(p)` (shared clock `wave_time`, global shader uniform
  `ultra_wave_time`) move the surface mesh and float props (`set_meta("buoyancy", k)` tunes how
  deep a prop sits). Swimmers don't collide with loose props (prediction-safe).
- Body mesh holes (the neck opening left by the FP head split) are capped at runtime
  (`UltraMeshCap`). The FP eye is kept >= 13 cm above / 9 cm ahead of the Neck bone, so
  crouch and sprint look-downs never put the camera inside the shoulders.
- Animation flow (m1_blend.test_transitions_flow: head/chest/hips acceleration through a course
  of starts, stops, flips, crouch, turns, jumps and rifle changes; was 250-760 m/s^2, now ~20-80):
  * `InertialBlendModifier` (first modifier) = DEAD BLENDING (Holden 2023): trigger() (driver,
    unconditional) starts a blend from the pose ON SCREEN carried on along its own motion
    (velocity decaying, half-life 0.08 s, capped) crossfaded (smoothstep, `blend_time` 0.2 s)
    into whatever the tree shows; HOLD 2 frames first (the trigger comes a frame or two before
    the tree switches - mixing in the not-yet-switched pose leaked a 12 cm dip on a 2 m root
    jump). C1 at the switch; a re-trigger mid-blend starts again from what's on screen (the
    tree's own crossfade drops its old state when interrupted: quick inputs popped). The old
    jump-detecting inertializer restarted from rest - a velocity jump at every switch.
    `UltraBoneBlend` is the same for a modifier's own output on a mode switch (WeaponPose
    first <-> third person).
  * Weights that used to follow speed / flags instantly are springs (`_ease_w`, half-life
    0.09 s): idle<->move mixes, item / raise-lower / stance weights, the TP shouldered pose
    (`EquipmentVisual._tp_w`, `_tp_ads`). Gait position uses an eased speed (`_ease_speed`);
    stopping HOLDS the last direction (`_nw_hold`, `_bl_hold`) while the move weight fades.
    The bladed run->sprint blend is eased from the proper walk/run base point.
  * Sprint gun lowering is eased in the sim (`MotorState.gun_low`, codec'd): as a step, the
    free-aim zone snapped the gun (and the arms) down in one tick. The spine aim leaves the
    sprint lowering to the lowered pose.
  * Landing depth scales with the impact (`land/depth` Blend2 idle<->Jump_Land): a hop dips a
    little, a big drop squats (every hop used to sink ~45 cm, at 2.4x speed).
  * TP shouldered gun blends the GUN from where the clip's hand holds it to the shouldered
    pose and keeps both hands at weight 1 on it (switching hand targets snapped the hands).
- Running steadiness (m1_blend.test_sprint_sway): `BodyDynamicsModifier.torso_steady` (driver:
  item layer weight x speed) takes the hips' fast swing out at the Spine under a held item's
  static upper body (pistol sprint: head 33 cm / 42 deg roll -> ~10 cm / 4 deg); `head_level`
  levels upper chest (half), neck and head against their own low-passed up vector.
- `UltraArmClear` (after FootIK, before WeaponPose / HandIK): elbows, upper-arm middles,
  forearms and hands are kept outside a torso ellipse (chest 0.215 x 0.185 m, waist 0.165 x
  0.15, limb included; measured off the mesh) by turning the upper arm / forearm out (3 + 2
  passes, 25 deg each). Mixamo rifle reload: right upper arm 0.73 -> 0.92 (m4 test).
- Reloading holds a sprint to a jog (motor) instead of the sprint cancelling the reload (with
  the sprint toggle it was cancelled a tick after it started). TP shouldered pose lets go
  fast (6/s) for a reload. Only busy states (knock-down, climbing...) interrupt a reload.
- Running jump: `leap` role (Mixamo "Running Jump", J_Sprint_RM, segment 0.04-0.62, apex
  0.28) in loco node "air_run" when jumping faster than 3.2 m/s; its time is SEEKED from the
  vertical speed (take-off -> apex -> touchdown pose held). `run_jump` (UAL) is the VAULT clip.
- Water impact: entering deep water from JUMP / FALL faster than 8.5 m/s down or 11.5 m/s
  overall -> RAGDOLL in the water (UltraSwim.PLUNGE_*): the capsule floats on a spring at the
  surface with heavy drag, SWIM after STUN_TIME 1.3 s; the physics body gets buoyancy per bone
  (`UltraRagdoll._buoy`) and fades into the swim. `UltraCharacter.plunged(speed)` -> splash,
  camera jolt / daze, rumble. Pool rope swing: launch deck (x 33.5-39, 2.2 m) + swing rope at
  (41.6, 9, 83), marker `pool_swing`; tour water_review.
- Ragdoll lying: GET_UP only after the body has been still (grounded, < 0.2 m/s) for
  STILL_TIME 1 s (`MotorState.trav_t` counts it). No landing tumble boost / spin any more.
- Recoil: pistol gun 3.0 deg / view 3.4, rifle 1.8 / 1.35; visual kick (0, 0.5, 1.8).
- Sprint = Mixamo "Fast Run" (S_Fast, 5.53 m/s; planted toe 0.37 m/s at 6.2). Tried: Standard
  Sprint (1.2 m/s slip), Two Cycle Sprint (2-stride clip, 0.95-1.3 m/s slip even cut to one
  stride), Fast/Intent runs. `tours/sprint_review` films the cycle side on.
- Throwing a carried prop: upper-body one-shot "push" = UAL Push (arms out) held PUSH_HOLD
  0.3 s then faded; `_upper_lean` folds 85 % of the clip's hip lean into a Spine track (an
  upper-body layer rides on upright locomotion hips - a whole-body lean lifted the arms
  overhead; Push had no Spine track at all, rest-constant tracks are dropped at import).
  Library track paths differ: find bone tracks by subname (`_bone_track`).
- Aim: `InputFrame.aim_from` (camera position minus the sim eye, mm, <= 5 m; set by the camera
  rig) - shots start there (`UltraActionLayer.shot_origin`; a camera behind the body starts the
  ray level with the body), so crosshair, dot and bullet agree at close range / looking down.
  The HUD dot resolves the ray like a real shot (`UltraCombat.trace`: characters only through
  a limb - the wide HitVolume put the dot in the air in front of anyone close).
- Turn in place: the motor turns the body eased (`turn_in_place_rate` 180 deg/s, `_accel` 720,
  `MotorState.turn_v`, codec'd); the anim plays a Mixamo turn clip (roles stand/crouch/aim
  _turn_l/_r: T_StandL90/R90, T_CrouchB_L/R, T_RifleL90/R90) with the Hips' yaw stripped
  (`_turn_clip`, also its net drift) and its TIME driven from how far the body has turned
  (TimeSeek; `_turn_tabs` = turned-so-far per 1/60 s) - planted feet stay put at any speed.
  A raised firearm (`UltraMotor.gun_up`) faces the aim in any view and turns from 45 deg.
  T_CrouchL90/R90 (magic pack) throw an arm out: unused.
- FP gun: `_gun_motion` (step bob, look lag, sprint lowering) on the camera-anchored pose.
- Holding: two-handed props ride against the chest within reach; palms go flat on the side
  faces (`_hands_on_prop`, `UltraGrab.support/surface_point`, HandIK `open`). Fresh grabs get
  0.8 s to bring the prop in; the hold only breaks after 0.4 s out of reach.
- Free aim (Arma/Sandstorm): the gun points along aim + `MotorState.sway` (damped spring:
  turning lags it, gait bob / sprint lowering / breathing push it, ADS / crouch calm it,
  recoil kicks it; tunables on ItemDefinition). Deterministic in the action layer; shots go
  along `gun_dir()`. HUD: crosshair = look, dot = projected gun ray. A READY gun fires in any
  state except the two-handed (stowed) ones. Remote players' sway isn't in snapshots yet.
- Rifle ("Carbine", `rifle`): procedural model (`ultra_blender.py make-rifle`), slung on the
  UpperChest, AUTO fire, roles rifle_idle/aim/reload (the legs stand in the aim clip's stance;
  m4 test_rifle_stance_upright: lean < 14 deg).
- Shouldered guns (an `M_Stock` marker + two_handed): `WeaponPoseModifier` (after FootIK,
  before HandIK). FP: the gun is camera-placed, so the body comes to it - chest bladed
  `blade_deg` (35) off the gun, spine + clavicle turn the shoulder pocket onto the stock, neck
  brings the eye to the camera; the camera reads `pre_head` (the eye from before this pass),
  else the body chasing the gun would move the camera. ADS drops the FP eye by
  `ItemDefinition.fp_ads_eye` (cheek on the stock). TP (`from_body`): stock in the pocket,
  barrel along the free-aim dir, hands IK'd onto it, ADS turns the neck toward the sights.
  Reload / sprint fall back to the clips. Support hand: `support_fingers/palm` put it under the
  fore-end at M_SupportGrip, fingers closed (`HandIK.set_curl`) - on top (the fitted
  support_offset) it rose into the ADS sight picture. m4 test_fp_rifle_shouldered.
- HandIK finger lists are built into locals then stored (PackedInt32Array elements are values:
  appending through `_fingers[i]` silently did nothing, so `open` never worked before).
- Demo playground has infinite ammo (`UltraActionLayer.infinite_ammo`; `--limited-ammo` off).
- `teleport()` drops any traversal state (else a scripted move drags you back).
- FP eye is swept from the capsule axis (`CameraRig._fp_guard`): the head bone dips into ledges.
- Sprinting with a bladed (rifle) item = GTA V's arms-only carry filter: the legs, hips and
  head run the plain upright sprint (the bladed stance blend fades out with `sprint_carry`),
  Spine..UpperChest hold one frame of it (`carry_chest`: the shoulders' counter-rotation
  swung the held rifle 44 mm/frame), and only the arms (clavicles out, `carry_arms`) take
  one held frame of e_sprint_f (`SPRINT_CARRY_T` 0.225 s: port arms, rifle across the chest).
  The rifle clip's own torso leaned forward / sideways (the user: "unnatural"). First person
  follows the body then (no camera-placed gun). `build_items._carry_dir` measures the barrel
  on that composite pose (66 deg left, -8). torso_steady at a run: unarmed 0.45, one-handed
  item 0.72 (0.85 looked frozen), bladed 0.85.
- TP aim is closed-loop: `EquipmentVisual._aim_fix` measures the drawn barrel against the gun
  direction and turns the spine by the error (the pistol aim clip pointed ~20 deg left).
  m4 test_gun_points_at_aim covers both guns, both views, hip and ADS.
- Long running leaps: past the leap clip's touchdown pose the falling loop's arms come in at
  up to LEAP_ARMS 0.5 (air_run/arms, filtered to the arm bones).
- Stopping from a sprint decelerates at `sprint_stop_decel` (6.5 m/s2, easing to `decel` by
  jog speed): ~2 m of carry.
- During MANTLE / LEDGE_CLIMB / LEDGE_HANG / LADDER / WALL_CLIMB / ROPE the ground blend gets
  zero speed (the scripted move's velocity flashed running legs at the hand-back). VAULT keeps
  its run (momentum is kept).
- Ledge hang only where a hanging body fits (`UltraTraversal.room_to_hang`: nothing under the
  feet 2.06 m below the top); lower ledges are climbed straight up; shimmy stops where the
  ground comes up.
- Moving platforms: a rider is found with a short downward `test_move` (walking left no floor
  contact in the slide collisions - only standing still registered). Ledge scans record the
  top's TickPlatform; MANTLE / VAULT / LEDGE_CLIMB / LEDGE_HANG set platform_id and their
  trav_from / to / point / normal ride the platform (`UltraMotor._ride_platform`).
- Shotgun (`shotgun`, `ultra_blender.py make-shotgun`, built in tools/build_items.gd): the
  carbine's clips (idle/aim; reload role = rifle_idle), grip fit like the carbine, support hand
  on the "Pump" node (M_SupportGrip is its child, so the hand rides the pump). 9 pellets
  (`UltraActionLayer.pellet_dirs`, seeded per pellet), `UltraCombat.hitscan_pellets`: pellets
  summed per (character, region) into ONE hit of kind `buckshot` (severs any limb it destroys),
  plus `DamageInfo.shove` per character = knockback x pellets-that-hit / pellets x range
  falloff (full <= 3 m, ~0 by 20 m); >= `UltraCharacter.SHOVE_KNOCKDOWN` (3.5) knocks over
  (or flings the body if it dies), less rocks them back. Tube loaded a shell at a time
  (`reload_mode: shell`, `_reload_shells`: reload_start + one per shell_time, a trigger pull
  stops loading and fires). Presentation: pump racked pump_delay after the shot (shell ejected
  then), `_drive_shells` = left hand pouch <-> M_LoadPort on the sim clock (FP: the gun comes
  up rolled SHELL_ROLL, not shouldered). Stat `kick` scales the visual recoil; TP shoulders
  rock back with it. Tour `shotgun_review`.
- Bleeding out: a severed region bleeds `DamageProfile.bleed_rate[r]` hp/s (top of each cut
  chain; `UltraInjury.bleed_rate`, a pure function of `severed`), applied by the authority every
  BLEED_TICKS (6) - hp is quantized to 0.1 each tick, a per-tick drain rounded away. hp 0 ->
  apply_damage kind `bleed` (no blood / limb damage) -> DEAD. HUD health bar pulses.
- Blood (`UltraBlood`, a child of UltraEffects, presentation only): droplets (MultiMesh,
  ballistic + drag, raycast each frame) splat where they land - world Decals that merge and
  grow into pools (<= 1.6 m), or Decals on the nearest bone of a character they hit (rides the
  bone: blood stays on the body). `wound()` = entry spray + exit spatter + body splats;
  UltraBodyFX pumps stumps with the heart (weaker as hp drops), drips, pools under anyone lying
  in it and under a body shot dead.
- Crippled regions (limb hp 0, still on) seep `cripple_bleed_rate` (0.25 hp/s each) and drip.
  Bleeding is taken in whole 0.1 hp steps as `rate * tick / 6` crosses them (exact at any rate;
  hp is quantized to 0.1 every tick).
- Gibs come from the body AND head meshes (the head is its own mesh). Buckshot / blast through
  the head (`sever` event carries the hit kind) bursts it: `spawn_gib(head, dir, 9, 7.0)` - with
  a cut set the 9 closed Chunk_HEAD pieces, else triangles split round its middle with a flesh
  blob each - thrown out with a red mist. MAX_GIBS 32.
- A client's ticks predicted before its first ack ran on a guessed server clock
  (`server_tick_offset` 0): snapshots for them rebase silently (`NetPlayer.synced_from`), not
  counted as corrections. The `net platform` case spawns on the elevator at a random phase:
  those pre-sync predictions made it flaky (0.37 m "corrections" 2 runs in 4); after the sync
  riding predicts exactly (0 corrections, 10/10).
- A TickPlatform coming down on someone not riding it shoves them out from under it
  (`UltraMotor._out_from_under_platforms`): the elevator used to press a player standing in its
  shaft through the floor (the flaky `net platform` case: the server spawned the player while
  the elevator was up).
- Gun smoke: muzzle puff per shot (`UltraEffects.smoke`, stat `smoke` 0.1 pistol, 0.14 rifle,
  1.26 shotgun; it scales amount and thickness) and barrel wisps while hot (`EquipmentVisual._heat`). GPUParticles3D: CPUParticles3D
  with a colour ramp drew its newest particle as an opaque black quad.
- Spent cases: `UltraEffects.SHELLS` by stat `shell` (9mm / 556 / 12g red hull, brass head),
  thrown toward `EquipmentVisual.eject_side()` = the side the M_EjectPort marker is on (they went
  out of the far side through the gun before). m4 test_shells_eject_from_the_port.
- Shotgun cycle: recoil_gun 11 deg, view 14, kick 5; the pump waits 0.42 s for the gun to come
  back down (fire_interval 1.15).
- `UltraSpring.step` substeps (w*dt <= 0.35): a hitch frame (first shotgun blast compiling
  shaders) made the camera kick spring explode and whip the view 70 deg.
- Sprint carry dot: the rifle's `sprint_lower_deg` is the measured port-arms barrel (88.9 deg
  to the left, -13.5; `build_items._carry_dir`), so shots / the dot go where it points; an
  off-screen gun dot is pinned to the view's edge (`UltraHud.EDGE_INSET`).
- Armed turn in place: the feet hurry as the twist grows and the upper body is never more than
  `armed_max_twist` (55 deg) ahead of them (m4 test_armed_turn_keeps_feet_up).
- Ledge hang idle = the catch's last frame held (its looped 0.05 s tail snapped the body 2 cm
  every 0.55 s; m1_blend test_hang_still).
- Steadiness (`m4_gunplay.test_camera_and_gun_steady`, tour `jitter_review`): sample at
  `skeleton_updated` - sampling in `_process` mixes this frame's body placement with last
  frame's pose and invents jitter. Rules that came out of it: a released HandIK goal fades from
  its skeleton-space target (a stale world target dragged the hand back at a sprint); the
  support hand follows the gun hand's final pose (`HandIKModifier.follow_hand`, solved after
  it); its handguard slide (`_within_reach`) is solved exactly and eased, never stepped; the FP
  body's glue to the mouse yaw is eased (`_glue_w`), never switched; interpolated sim values
  keep their pre-tick value on the character (`prev_sway`) so 2-tick frames don't snap.
- **Knockout** is RAGDOLL + `MotorState.F_UNCONSCIOUS` (1<<6), `ko_t` (s left), `ko_count`
  (all codec'd; the flag reaches remote players in snapshots). Blunt kinds (`blunt`, `impact`):
  to the HEAD >= `DamageProfile.ko_head` (18, head mult `blunt_head_mult` 1.2, half limb
  damage) or any blunt hit >= `ko_heavy` (55) knocks out for clamp(5 + over*0.25, 5, 12) s,
  x(1 + 0.5*min(ko_count, 3)). RagdollState holds the body down while unconscious (limp tone,
  no get-up / water exit); HUD `_drive_blackout`; CameraRig concussion wobble on waking.
- **Melee** = `UltraActionLayer.Action.MELEE` (appended). Gun-butt: `B_MELEE` (`uc_melee`:
  B / middle mouse / D-pad Up) with a firearm up; melee weapons (`ItemDefinition.Kind.MELEE`) swing
  on attack. Swings come from item stat `"melee"` (array of {time, hit_from, reach, damage,
  kind, knockback, impulse}) or gun-butt defaults (`melee_swing`). `melee_combo` bits 0-5 =
  swing, 0x40 = this swing landed (action_t is quantized: a `t0 < hit_from <= t` crossing
  test missed), 0x80 = next queued (press after 45 %); `melee_seq` in snapshots.
  `UltraCombat.melee_sweep`: 5 rays (0, +-14, +-28 deg) to reach from the eye, lag
  compensated, characters first then the ray nearest the aim. `is_up()` = READY or MELEE.
  Strike animation (`AnimDriver.play_swing`): a swing names a clip role, a segment `seg`
  and the clip's `contact` time (hand-speed peak, `tools/measure_melee.gd`); the segment is
  time-scaled so contact lands on the sim's hit_from. Two layers fed the same seeked segment:
  `swing` (upper body, 60 % of the hip lean in the spine) and `swing_full` (whole body),
  full-body weight 1 standing -> 0 by 2.2 m/s (GTA/RDR play standing attacks full-body).
  `swing_w` fades the procedural aim / TP shouldered gun out meanwhile. Clips (Mixamo):
  bat = "Two Handed Club Combo Attack" + "Two Handed Weapon Stance" (M_Club2*), machete =
  "One Handed Sword Combo Attack" (M_SwordCombo) - each combo swing is the next segment of
  ONE combo clip, so a chained combo plays it straight through; gun-butt TP = "Advancing And
  Punching With Butt Of A Rifle" (M_RiflePunch, steps in 0.7 m and back) / "Overhand Strike
  With Pistol". First person firearms stay procedural (`EquipmentVisual.melee_offset`, timed
  off the sim's action_t; `AnimDriver.fp_gun` skips the clip). Item roles are global: each
  item names its own (bat_idle, bat_combo, butt_long...). The Mixamo axe pack is ONE-handed
  and "Smash With Back Of Rifle" holds the rifle like a staff (it twisted ours): unused.
  Net case `melee` (bot `butt`): stock to Dummy B's head, the client must see the knockout.
- **Breakables** (`UltraBreakable`, a child named "Breakable" of a RigidBody3D prop or a
  StaticBody3D pane): health from shots / blows (`UltraCombat.apply` forwards; glass x4,
  blunt x1.4) and knocks - a prop's own momentum change beyond gravity over `impact_min`
  (skipped while held / just thrown, armed after 1 s); glass breaks outright on a jolt over
  `impact_dv` (2.5 m/s); panes get a deep sensor (body > 2.5 m/s and > 6 kg m/s). The server
  sets `broken` (NetObject `net_state`), spills `drops`; everyone hides the body and throws
  local debris boxes cut from its mesh AABB (`ultra_debris`, <= 140, 9 s). Playground
  BREAKABLES (marker `breakables`): crates (health 75), barrels, bottles, a window.
- **Prone with a gun** (CRAWL state; firearms stay in hand, melee weapons / tools are put away):
  fire / reload lying still, no firing while crawling (> 0.25 m/s) or melee. Body pivots at
  `UltraMotor.PRONE_TURN_RATE` (110 deg/s). AnimDriver loco "prone" (when `prone_armed()`):
  Mixamo rifle prone set - BlendSpace2D idle / crawl fwd / back / roll right (left mirrored),
  nearest axis with hysteresis, plus a turn clip (right mirrored) when pivoting; the item
  layer swaps to PRONE_ROLES (idle/aim/fire/reload) and fades out while crawling. Roles
  prone_* and drop_hang live in mannequin_animset.tres (tree-build time: item-provided roles
  arrive after the tree is built). Unarmed prone keeps the old "crawl" node.
- **Climbing down** (`UltraTraversal._climb_down`, hook for IDLE/MOVE/LAND/CROUCH): probe
  `_down_edge` 0.18 m past the feet (no ground) + the wall face under the lip. Careful
  (walking, crouched, B_WALK, or crouch while teetering) -> ladder top (`_ladder_top`) =
  DOWN_LADDER, CLIMBABLE face = DOWN_WALL, a drop >= DROP_HANG_MIN (1.95 m) = DROP_HANG
  (all LEDGE_CLIMB state + trav_kind; the capsule waits at the end position, Mixamo
  "Standing Drop To Freehang" plays from standing - its root is on the floor below too;
  DROP_CLIP_FIT shifts its hips onto our hang; `camera_lift` eases the TP view down).
  Running (> 0.8 jog) off a 0.5-2.2 m drop: a hop (HOP_UP 2.2 m/s) shown with the leap clip.
  After a down move `F_AWAIT_NEUTRAL` (1<<7) ignores the stick on the hang / ladder / wall
  until it changes from what was held (trav_from = held move + yaw) - else holding forward
  climbed straight back out. Hang input is camera-relative (`ledge_hang_state._push`).
- Climb clips run at the speed actually moved (rope: trav_s change, hang: lateral pos change,
  wall: |vel| incl. sideways) - they used to play the input in place at a rope's / ledge's end.
- Leaving a rope at speed plays the running leap (`air_run`); slow, the jump clip.
- Mantle at a run carries 75 % of the run-in speed on (MANTLE trav_s); the anim gait spring
  restarts from the real speed after any traversal (it showed a stale sprint frame).
- Drawing a weapon blends into its ready state as it comes up (`UltraActionLayer.raised(s)`,
  0..1 over equip_time): body turns to the aim from 0.35, item pose / TP shouldered pose /
  FP camera-placed gun follow it (they used to switch on at READY: one pose, then another).
  `EquipmentVisual._aim_fix` is kept per item.
- Dropping: the item in hand drops at once (`UltraActionLayer.let_go` on the server; the HUD
  no longer holsters first - it raced the holster time), falling from the hands at the feet.
- Third person, sprinting faces the travel direction even with a gun up (it crab-sprinted);
  rifle sprint carry uses the plain sprint's hip warp (the bladed ring's tiny diagonal turn
  made angled sprints skate).
- Input: `melee` is in LocalInputSource.TRACKED (it never fired from real input); mouse buttons
  on hotbar next/prev cycle on the event (the wheel's press+release in one frame was never
  seen held); the click that captures the mouse isn't a shot; a pad Back toggles the
  inventory on release of a short press (hold = split-screen leave). Crouch is a toggle by
  default (`toggle_crouch`), double tap = prone.
- **Third person is first person seen from outside** (`EquipmentVisual.view_xf`): the
  first-person path (camera-placed gun, arms IK'd, WeaponPose FP mode, ADS, recoil, sway,
  procedural gun-butt, shell loading, the reload's hands moved out in front) runs for every
  view, posed from the first-person eye - the camera rig publishes it every frame in any view
  (`fp_view`); characters without a rig use a virtual eye (sim eye height along the aim,
  prone: the Head bone's clip pose). The neck isn't pulled to that eye in third person (only
  a real FP camera: it jolted the head, m1 transitions flow). Tour `fp_tp_compare` films
  both views from one outside camera. The FP gun weight `_fp_w` is linear: up at 5/s, down
  at 3/s (holstering jolted the head), 5/s into a sprint carry (a spring broke sprint sway).
  Reload hand shift: forward 0.24 + 0.18 to the gun side (crossing to the off side put the
  right upper arm through the chest); `ArmClearPost.hand_give` lets reloading hands give way.
- Muzzle effects use the gun's own frame (-Z = barrel) at the M_Muzzle marker: the marker's
  Blender basis sent the smoke back down the barrel.
- `ArmClearPost` (UltraArmClear `keep_hands`, after HandIK): an elbow the hand IK left inside
  the torso swings out round the shoulder->wrist line (hand untouched); m4 test_arms_clear
  covers reloads standing / walking / strafing / crouched / sprint-held.
- Third person faces the aim by default (`MovementProfile.tp_rotation` FACE_AIM; adventure.tres
  keeps FACE_MOVE): one set of movement animations for both views.
- Prone: weapons (guns + melee, `UltraActionLayer.prone_holdable`) stay in hand; a melee weapon
  strikes lying still, arms only (`swing_arms` layer). Getting down / up: Mixamo "Crouching
  To Laying Prone" / "Transition From Prone To Crouch" (roles prone_down / prone_up, loco
  nodes of the same name) over `UltraMotor.PRONE_TRANSITION` 0.8 s, during which the capsule
  height eases and you can't move (`prone_transitioning`). Hit while prone: "Rifle Prone Hit
  Reaction" (role prone_hit).
- Free hand (`EquipmentVisual._drive_free_hand`): a one-handed melee weapon - loose guard in
  front of the chest, counter-swinging against the weapon hand; a club with stat
  "two_hand_grip" (bat 0.1 m) - the other hand on the handle; a one-handed gun prone - braced
  on the ground. Never with a lost / crippled arm (UltraInjury.two_hands); the weapon hand
  then is the left (`item_left`: melee swing clips mirrored).
- Drop to hang: the body faces OUT over the drop while "Standing Drop To Freehang" plays (the
  clip turns round to the wall), then faces the wall for the hang (DROP_CLIP_FIT 0,-0.24,-0.37).
- Support-hand grip (tour `grip_review`, `--cam=left|right|below`, `--quick`; prints slide /
  jerk / finger depth per state): HandIK `set_wrap(hand, part, box, half)` - curled fingers
  bend joint by joint only until the rest of the finger (straight) touches the part's box
  (`_wrap_angle`); EquipmentVisual `_wrap_on` picks the thickest mesh at M_SupportGrip (not a
  groove ring) and clears wraps each frame. A fixed curl sank the index 23 mm into the
  handguard. Rifle fingers point across the fore-end (0.85, 0, -0.5), palm (0.35, 1, 0).
  `_within_reach` reads the shoulder from `HandIK.pre_shoulder` (the pose as it reached
  HandIK last frame, after the inertial blend): read in _process it jumped ~10 cm at a clip
  change and flicked the hand 2 cm along the handguard; the slide is a critically damped spring.
- Gun-butt (`EquipmentVisual.melee_offset`): long guns a horizontal butt stroke (cocked back,
  then the stock swung forward and across, muzzle out right); pistol whip butt-first. The
  shouldered body (WeaponPose) keeps only a quarter of the strike - chasing the stock threw
  the torso over.
- Magazine reload by hand (`mag_reload` / `_drive_mag_reload`): the gun stays shouldered (rolled
  22 deg to the off hand); the left hand takes the Magazine node (rides `_mag_hand`) down to a
  belt pouch and back, keyed off action_t / reload_commit; the reload clip isn't played.
- Melee stance: item stat `stance_yaw` turns the idle/aim clip's hips back toward the front
  (bat 60), `chest_yaw` its UpperChest (machete 18: the clip twists it 20 deg right).
  Tour `stance_probe` prints each bone's facing per item (unarmed = baseline).
- **MotorState flag bits**: 0-7 in motor_state.gd, 8 = UltraMotor.F_TURNING (motor.gd), 10
  F_BLOCKING, 11 F_HEART. Check BOTH files before taking a bit (a clash cleared the turn flag
  every tick: m4 armed-turn tests).
- Melee block (`MotorState.F_BLOCKING`, set by UltraActionLayer: melee weapon READY + secondary,
  standing / walking): a `DamageInfo.melee` hit from within `DamageProfile.block_arc_deg` (55)
  of the facing takes `block_mult` (0.2), region mult 1, no cut / knockout / knock-down; it's
  broadcast as kind `blocked` (sparks, the block's jolt clip block_one_hit / block_two_hit).
  The melee item's "aim" role is its block clip (bat: Mixamo Great Sword Blocking Idle B_Great,
  machete: Blocking An Attack With Axe B_Axe); stance_yaw / chest_yaw only touch the idle role.
- One-handed melee at rest: the empty arm is taken out of the upper-body Blend2's filter
  (`AnimDriver._free_side`, inertial trigger on the switch), so it hangs / swings with the legs;
  the free-hand guard IK only comes in with a swing. (BlendTree outputs can't feed two inputs.)
- Bat grip = the clip's own: the free hand where the stance / combo clip has it relative to the
  gun hand (read in _process = clip pose), knuckles pulled onto the handle (`_knuckle_local`);
  the bat sits 9 cm lower in the hand (build_items) so that fist lands on the tape, not past the
  knob. Built grips (mirrored / palm-opposite) never closed round the handle (tour bat_grip).
- Gun-butt (long gun) = a hook from the right: wound up stock OUT right / back, then hooked
  forward and in (`melee_offset`).
- Prone: melee weapons are held at the side on the plain crawl (prone_armed() = firearms only),
  no strikes lying down. Sideways = the prone turn clip in place, looped (`_prone_side_clip`;
  `_turn_clip(role, lying=true)` reads yaw off the hips' up axis - the pelvis faces the ground).
  The roll button rolls: ROOT_MOTION PR_RollR_RM (Mixamo "Rifle Prone Rolling Right" with root
  motion, `RootMotionCurve.rate` 1.6 - motor clock and a stretched clip), mirrored (rm_scale.x
  -1, yaw sign, `AnimDriver.rm_mirror`) pushing left; the weapon stays (`UltraActionLayer.stows`).
  Re-running the intake rewrites PR_RollR_RM.tres: put `rate = 1.6` back.
- rm_t is quantized to 1 ms: ROOT_MOTION ends at `length - 0.002` (it never reached 3.2666 s).
- Magazine reloads (rifle, pistol, prone too): the old magazine drops as a physics copy
  (`UltraEffects.drop_mag`, 30 s, <= 16), a fresh one from a pouch on the left hip (prone: under
  the chest); the hand holds magazines palm-in from the left side (palm-up twisted the wrist).
  The shotgun stays shouldered loading shells (rolled SHELL_ROLL 35 deg).
- Climb-down start / stairs (m10 test_edge_no_dip_or_pop, test_stairs_smooth): FootIK leaves a
  foot with no ground in reach as animated (it counted it as -max_pelvis_drop: hips sank 40 cm
  at every edge); a tick that moves the capsule > 1 m snaps the visual (no glide) and shifts the
  inertial blend's hips history (`InertialBlendModifier.shift`); drop_hang xfade 0. Stair steps
  glide both ways (`UltraMotor.last_step_down`) and the step goes into `_prev_pos` too (the
  offset was applied a tick before the interpolated position: a 14 cm dip per step up).
- Damage feedback (`UltraDamageScreen`, HUD child): one shader (tunnel vision / blur / dark),
  tunnel ONLY while bleeding (0.04 + 0.5 x hp lost, <= 0.55, a slight pulse), knocked out =
  double vision (two drifting copies), a little blurred and dim; dead =
  cut to black + recap (hits merged by who / weapon / region, limbs lost, blood lost per source
  from the replicated state). Controls in the HUD: set_anchors_AND_OFFSETS_preset (a plain
  anchors preset left them 0 x 0).
- Heart (`UltraHitboxes.heart`: upper torso capsule, 30 % up, 6 cm forward, 3.5 cm left): a
  bullet / buckshot / blade whose line passes within `heart_radius` (4.5 cm) -> F_HEART, bleeds
  `heart_bleed_rate` (12 hp/s), event `heart` (gush; the chest pumps every 0.42 s).
- Torso gore (buckshot / blast >= 30 to the torso, UltraBodyFX.torso_blast): skin chunks round
  the hit (`_collect_tris(.., near, radius)`), a crater (UltraWoundMesh.crater, sunk in), flesh /
  gut lumps; from the FRONT, `_spill_guts`: a belly wound on the Spine bone and two UltraGuts
  verlet chains - a loop held at both ends (anchor_b) sagging out and a dangling strand.
  Attachments: work offsets out from the bone's posed transform - a new BoneAttachment3D only
  takes its pose at the next skeleton update. Cleared on respawn (back from dead or hp jumping
  to full - NOT simply "hp is 100": that wiped gore on an undamaged body).
- **Dismemberment is pre-cut in Blender** (`blender --background --python
  tools/blender/ultra_blender.py -- make-cuts`, code in tools/blender/make_cuts.py; re-run after
  changing the model, then `--import`): from the imported glb + its Godot BoneMap (profile ->
  model bone names) it writes `mannequin_cuts.glb` (BodyProfile.cut_scene, imported with the
  same retarget settings, no import script / animations): `Seg_<REGION>` per region (planes at
  the joints - neck cut 45 % up the neck, CUT_AT - cutting only faces weighted to that limb),
  `Cap_<REGION>_stump` / `_end` (the cut's real boundary: rim = the skin's own vertices with
  their weights, fat band, meat dome in rings blending to the bone, broken bone(s) + marrow at
  the joint), `Chunk_HEAD_<k>` (9 Voronoi pieces, each closed: skin, skull, meat),
  `Seg_TORSO_OPEN` (belly opening between Spine and Chest, a fat/meat bowl inside),
  `Seg_WAIST_UP/DOWN` + `Cap_WAIST_up/down` (torso in two half way Spine -> Chest; each half
  re-weighted to its own side of the spine - shared waist weights stretched skin across the
  gap). Blender traps: weld the glTF's UV-seam split verts first (remove_doubles) or every cut
  has gaps; caps wind from the skin face next to each rim edge (per-edge guessing flipped half);
  bmesh v.index is stale after deletes (key by the vert).
  Runtime `UltraCutBody` (BodyFX.cuts): on the first sever / belly / halve it hides BodyMesh +
  HeadMesh and puts every piece under the skeleton (skin REBOUND to the body's bind poses by
  bone name - Blender re-derives arm / leg bone rests); severed pieces hidden, the stump shown;
  NOTHING is scaled (DismemberModifier stays 0 with a cut set). Seg_* get UltraMeshCap (not
  TORSO_OPEN: its skin edge round the cavity is a loop - capping sealed it with skin). Seg_HEAD
  takes head_mesh.layers (FP). Gibs = the chain's pieces + the top's `_end` cap, CPU-posed
  (`_collect_tris(mi, -1)`), one surface per material. Back to one piece on respawn.
  Without a cut_scene the old runtime path stays (DismemberModifier collapse, UltraWoundMesh.cap).
- **Torso in two**: ONLY a killing buckshot / blast to the torso >= `DamageProfile.halve_min`
  (90), flown <= `halve_range` (3 m, `DamageInfo.dist`: a load's nearest pellet) and striking
  the waist (`UltraCharacter._at_waist`: within `halve_reach` 13 cm of 72 % up the hips->chest
  capsule; a load's point = its pellets' average). Further off, a blast from the front opens
  the belly and the shove throws the body. -> authority event `halve` -> halves shown, 12 guts
  out of both ends; the hit's torso_blast is deferred to the frame's end and skipped once
  halved (its skin chunks / crater showed with the halves). `UltraRagdoll.split_waist` /
  `_rejoin` REBUILD every body and a NEW PhysicalBoneSimulator3D (`_make_bodies`): Jolt keeps
  a PhysicalBone3D's joint as first made whatever joint_type says, and bodies swapped into a
  simulator that had already run got NO joints - every later death of that character split
  it at the waist (m11 test_halved_body_is_whole_after_respawn). Bodies are made in the same
  order, transforms / velocities carried over; lower half keeps 15 % of the death push,
  upper 45 %. The cut set is loaded and capped at level load (`UltraCutBody.prewarm`; it was
  a ~50 ms hitch on the first halve).
- BodyFX reads bones from `_bone_world` (captured at skeleton_updated): outside it a ragdoll's
  bones read as the standing animation pose (blood spurted where the body used to stand).
- Guts collide with the body: `colliders` = `UltraBodyFX.body_capsules()` (posed torso / limb /
  head capsules, gone regions dropped, a halved torso as two); points but the `free_links` (3)
  next to an anchor are pushed out, back out the side they were on last tick (a body bending
  over a gut carried points past the axis and out the top).
  Guts are cheap: the tube is built as arrays (per-vertex ImmediateMesh calls cost ~0.7 ms a
  gut a frame), only capsules near the chain's bounding sphere are tested, and a gut that
  hasn't moved for 20 ticks sleeps until its anchor moves (3 mm; 1 cm after 2 s: a dead
  ragdoll shivers). m11 test_halving_is_cheap.
- Guts (UltraGuts): verlet chain drawn as ONE smooth tube (Catmull-Rom, ImmediateMesh in world
  space - its MeshInstance top_level at the origin, else it drew offset by the node's position),
  sections bulging / pinched, ends tapering into the wound; two loops + a hanging length.
- Melee animation: one-handed melee at rest takes ONLY the weapon arm from the item layer (the
  sword idle is a hunched crouch; filter toggled in AnimDriver, inertial trigger), no
  item_hips_yaw twist; a melee item's "aim" (block) is never its stance (item_hips_yaw / bladed
  idle legs read "low").
- Automatic recoil: `MotorState.burst` (codec'd, reset when the trigger's let go); the gun kick
  climbs to `recoil_climb` x by the 8th round, first round x1.25, sideways a seeded drift per
  burst; the view keeps 35 -> 60 % of each kick over a burst. Carbine recoil_gun 0.85,
  pitch 0.75, yaw 0.45, climb 1.7.
- Sounds (`UltraSfx`, child of UltraEffects): assets/audio/weapons made from
  assets/audio/source by `python tools/audio/prepare_sfx.py`. Variants are name_0, name_1 ...
  (a far render is name_far_k - it was written name_k_far and never found: distant shots were
  just the close one turned down). Far render: 4th-order low-pass ~650 Hz, rounded attack,
  squashed, slap-back echoes, long reverb. Carbine = the light machine gun recording (single
  shots at 17/21/25 s): rifle_fire_k whole, rifle_fire_auto_k (attack, 0.16 s) per round of a
  burst (the last one cut), rifle_fire_tail_k once the trigger's let go (AUTO_GAP 0.2 s).
  Close fades out 25..110 m, far in 20..80 m, late by the speed of sound. Fly-bys graded from
  "bullet close.wav": whiz_close (< 1.2 m) / whiz_mid (< 3) / whiz_far (< 6, dulled), each band
  also drawing on its neighbour's takes (all 13 used), item stat `whiz_db` (pistol -5,
  shotgun -3). The burst ring-out: -7 dB, smaller for a tap, level / pitch varied. Impacts,
  cases (random stretch of brass_shells.mp3), mag out / in / slide, shotgun shells and pump.
  Prefix = item stat "sfx" else its id.
- **Rounds fly** (`UltraBallistics`, authority, a node under the scene, physics priority 150):
  stats `muzzle_velocity` (pistol 360, carbine 880, buckshot 400 m/s) and `drag` (1/s: 0.6 /
  0.9 / 3.5); gravity; one lag-compensated segment per tick (`UltraNet.world.rewound`); hits
  through `UltraCombat.resolve_bullet` / `apply_pellets` (a load's pellets summed once all have
  landed). UltraEffects flies a matching round on every machine (`_fly`): tracer streak, the
  whiz where it actually passes the listener, the shooter's predicted impact on arrival.
  `hitscan` / `hitscan_pellets` stay as instant tools (tests). m11 test_bullet_flight_and_drop:
  pistol at 60 m ~0.18 s / 14 cm low, carbine 0.08 s / 2 cm.
- Shotgun at range: pattern 2.2 deg, opening by `pellet_bloom_deg` 2.2 past
  `pellet_bloom_from` 6 m; damage per pellet by distance flown, stat `falloff`
  [[5, 1], [12, 0.55], [25, 0.3], [45, 0.12]] (`UltraCombat.falloff`).
- **Animation stability rules** (m12_fuzz: a seeded bot hammering every control - flicks of up
  to 180 deg in 0-8 ticks, ADS / crouch / prone / sprint toggles, jumps, fire, reloads, slot
  switches, view toggles - checks core pops > 350 m/s^2 (outside clip allowances: jump /
  leap take-off, prone transitions), NaNs, camera off its aim, eye and gun-in-view jerk, with
  a probe before every modifier naming the stage a pop comes from; `-- --seed=N
  --fuzz-ticks=M`, env FUZZ_DBG=<tick> traces WeaponPose round a tick). Before: 37-64 pops of
  1000-2300 per 1800 frames; the FP eye jerked 2500-5000 m/s^2.
  * No raw discrete value into the pose: every input that can step goes through a follower
    (`UltraFollow`: speed + acceleration capped, sqrt braking, soft arrival - never stopped
    dead) or `_ease_w`, with hysteresis on thresholds. Angles are kept continuous through the
    back (unwrapped vs. the last value, re-wrapped past 200 deg) before any clamp: the spine /
    head aim (`AnimDriver._aim_yaw_off`, AIM_MAX_SPEED 7 rad/s, 60 rad/s^2), LookModifier,
    WeaponPose blade - wrapped to +-180 then clamped they flipped 160 deg in a frame.
  * Procedural passes that bend toward an outside target FOLLOW THE TARGET (in the skeleton's
    frame), never the bend: WeaponPose follows the gun heading / stock point / eye target and
    solves the bend afresh each frame, so it keeps steadying the chest through the gait
    (smoothing the bend itself let the rifle sprint's sway back in: m1 sprint_sway). Followers
    reset while the pass is off (stale, they raced 1.2 m to catch up). `_turn_toward` fades
    out for a target nearly behind (its axis flips). Lying prone the bend is scaled to 0.35;
    during prone_down / prone_up the camera-placed gun lets go (the clip carries it).
  * Headings read with atan2 off a bone axis fade out as the axis tips vertical (prone hips,
    a head looking straight down) - BodyDynamics item_hips_yaw and head stabiliser.
  * HandIK goal continuity (`_settle`): a goal whose target jumps (owner change, cancelled
    reload) is reached from where the hand was heading on a spring (half-life 0.06 s); moving
    targets are untouched; `allow_jump` lets the recoil kick through.
  * Visual yaw glue leads the sim toward the live mouse by GLUE_LEAD 0.08 rad at most (it glued
    the whole body to a flick for a frame, then slid back). The FP eye's placement round the
    neck (and the look-down shift / ADS eye drop) uses a followed yaw / pitch, not the raw
    mouse (a flick while prone teleported the eye 30-50 cm). The view direction stays raw.
  * The fire one-shot never moves the neck / head (filtered): auto fire shook the FP eye. All
    one-shots fade on ease curves; a reload start dead-blends.
  * Turn in place: each side's clip has its own weight (a direction flip fades one out as the
    other comes in - as one signed amount it cut from left to right). Prone pivot side eased.
  * Sim ADS is `MotorState.ads_w` (codec'd, 8/s): the free-aim zone / calm / inertia blend by
    it (as a step the zone tightened in a tick and threw the gun up to 4 deg). Presentation
    ADS (`EquipmentVisual.ads`, FOV, sensitivity) is a follower (a ramp reversed on spam).
  * Hitch-proof springs: UltraSpring caps dt at 0.1 s; the FootIK pelvis and driver lean
    springs are capped + substepped (the pelvis one went NaN below ~11 fps).
  * Camera: down view hands back fully once up (it lurched back to the head's view the frame
    GET_UP ended); `_tame_view` keeps heading / roll continuous for an inverted head.
  * The gun is posed from `fp_view` (the FP eye) in every view, never the camera mid-toggle.
    Remote players' guns redraw on `equipped` (snapshots carry no held_uid).
- Tours run in real time and frame grabs stall them: film fast moves in slow motion
  (`Engine.time_scale`, see melee_review); a tour "tap" is held for at least one tick.

## Godot 4.7 facts (probed)
- All IK nodes exist: TwoBoneIK3D, FABRIK3D, CCDIK3D, JacobianIK3D, SplineIK3D, ChainIK3D,
  LookAtModifier3D, AimModifier3D, CopyTransformModifier3D, BoneTwistDisperser3D,
  LimitAngularVelocityModifier3D, SpringBoneSimulator3D, PhysicalBoneSimulator3D.
- SkeletonModifier3D virtual: `_process_modification_with_delta(delta)`. **Modified poses are only
  readable at `Skeleton3D.skeleton_updated`** — reading bones in `_process` gives the pre-modifier
  pose (the FP camera and the foot-slide test both hook that signal).
- BlendSpace1D/2D have `sync_mode` (None, Independent, Cyclic Mutable, Cyclic Constant) — cyclic
  phase sync is built in. `add_blend_point(node, pos, -1, &"name")` — always name points.
- Import retarget keys (in `.import` `_subresources.nodes."PATH:Mannequin/Skeleton3D"`):
  `retarget/bone_map` (Resource path), `retarget/bone_renamer/*`, `retarget/rest_fixer/*`.
  `normalize_position_tracks` divides position tracks by hip height → `Skeleton3D.motion_scale`
  (0.9167 here); multiply root tracks back when baking.
- `animation/remove_immutable_tracks` must stay **false** (it drops held non-rest poses);
  `UltraImportTools.clean_tracks` removes only rest-constant + duplicate tracks.
- Jolt is the 3D engine (`physics/3d/physics_engine="Jolt Physics"`).
- Godot doesn't save a project setting equal to its initial value; read with a default.

## GDScript traps
- `:=` can't infer through untyped Array/Dictionary access — type it (`var x: bool = ...`).
- Lambdas capture locals **by value** — use a one-element Array to accumulate.
- `const` can't hold a class reference in a function (`const F := InputFrame` fails) — use `var`.
- A SceneTree script's members can't be named `root`.
- Const Dictionaries are read-only — duplicate before mutating.

## Assets
- `art_src/exported-model.glb`: original (ignored by Godot). `assets/characters/mannequin/mannequin.glb`:
  imported copy. Quaternius UAL 1+2 mannequin, 66 bones, 178 clips (+RESET), 12 `_RM` clips.
- Clips found beyond the obvious: OverhandThrow, Throw_Object, LayToIdle (get-up), Push,
  Kick_Breach, Consume, Chest_Open, Idle_Hurt, Tired_Hunched, Zombie_Walk.
- UAL Turn_* clips do not rotate (feet step in place) - superseded by the Mixamo turn clips.
- Measured authored speeds (m/s): walk 0.80, back 0.97, jog 4.83, sprint 7.12, crouch 0.59.
  Walk_Backwards' planted feet drift sideways in the source clip (foot lock in M3 fixes it).

## Animation expansion
- **Mixamo:** drop FBX into `intake/mixamo/` (`Name_loop.fbx` loops, `Name_RM.fbx` keeps root
  motion as a baked curve), then `bash tools/intake.sh` (or Project > Tools > Ultra > Process
  animation intake). Clips land in the `mixamo/` library; use them in AnimationSet roles as
  `"mixamo/Name"`. Bone map `bone_maps/mixamo_humanoid.tres`; fix_silhouette is off (T-pose rigs).
- **Blender:** `blender --background --python tools/blender/ultra_blender.py -- make-edit` gives
  `art_src/mannequin_edit.blend`; author actions, then `-- export-actions --blend art_src/mannequin_edit.blend --actions "A,B"`
  writes `intake/blender/*.glb` -> `blender/` library via the same intake. Also `mirror`,
  `make-pistol`, `mixamo-test` (a Mixamo-named FBX for testing without an account).
- **Mixamo packs**: `intake/mixamo/PACKS.md` (and `packs.json`) list every downloaded pack's clips by library name
  (`mixamo/<file without _loop>`) - build a controller "from pack X" by mapping roles to that list. 21 packs (zombie /
  creature, injured, drunk, rifle, shooter, pistol, axe, great sword, sword and shield, male locomotion, action adventure)
  under prefixes ZS ZN CR CN INJ DRK RFP RFL SHT SHB SHS PST AXE GSW SNS SNL SNP AAD LMM LOC LOB; a clip in several packs is
  imported once under the first pack's prefix (Rifle 8-Way = Pro Rifle = RFP_). Off-theme Quaternius clips (flying,
  dancing, farming, sitting, spells, bows, female gaits...) are `UltraImportTools.PURGED`: skipped by the mannequin import,
  `--script res://tools/purge_clips.gd` takes them out of a saved ual.res.
- Round-trip test (m1_import.test_intake_roundtrip): Blender path exact, Mixamo FBX path < 5 cm.
- Some Mixamo clips are authored facing away (Ladder_Climb: hips yaw 177 deg) or off the ground;
  `_refit` handles both. Slide_Start is a whole slide (down and up): only its first 0.4 s is used.
- Mixamo downloads: the export status is per character (one job at a time): run exports
  strictly one after another and only accept a link whose file name matches the clip; links
  expire in 5 min - export in groups of ~5 and fetch right away. Clip measuring helpers:
  tools/anim_measure.gd (used by build_animset.gd and measure_mixamo.gd).
- Mixamo names bones per character (`mixamorig:`, `mixamorig1:` ...): the intake detects the
  prefix and makes a matching bone map (`mixamo_humanoid_<prefix>.tres`). A clip that imports
  with 0 tracks means the bone map didn't match.
- Mixamo downloads (logged-in browser): the site's own API (`/api/v1/products?query=`,
  `/animations/export` + `/characters/<id>/monitor`) from the page's session; the S3 link
  lasts 5 min, fetch it with curl. Export FBX, no skin, 30 fps, not in-place.
- Tools that touch autoload-dependent scripts run through `res://tools/tool_runner.tscn -- --tool=...`
  (a `--script` SceneTree has no autoloads). Builders: build_items.gd, build_playground.gd, intake.gd.

## Zombies (Resident Evil-style enemies; plan: `C:\Users\Lappy\.claude\plans\eventual-snacking-comet.md`)
- **A zombie is an ordinary bot**: `UltraNet.spawn_bot("Z:<archetype>:<nn>", ...)` -> `main._make_character`
  dispatches on the `Z:` prefix to `ZombieFactory.make(np, visuals)` (demo/zombies/) -> a server-simulated
  UltraCharacter driven through its BotInputSource. Player ids are u8 and never reused: **pool, park,
  respawn in place** (`respawn_character` puts a bot back at its `home` meta), never spawn/despawn churn.
  `ZombieFactory.dress(c)` (main `_on_player_added`) applies the maimed spawn state (crawler: both thighs
  severed; limper: a ruined leg), tint and scale; NPCs get no starting kit. `ZombieArchetype.get_arch(&"walker")`
  is a code table: walker, shambler, limper, runner, brute, crawler (speeds, toughness, senses, attacks).
- **Visual tiers** (`BodyProfile.visual_tier`): FULL = the player's stack; **LITE** = `UltraLiteAnimDriver`
  (~15-node AnimationTree: idle/walk/run/limp ground blend, crawl <-> held lie pose, two get-ups, one-shots
  atk / emote / hit; FootIK only - no BodyDynamics / ArmClear / WeaponPose / HandIK / Look / inertial blend,
  no EquipmentVisual / TraversalVisual, no near-fade materials) + BodyFX + ragdoll. Missing roles fall back
  to idle. `BodyProfile.cap_meshes` off for Romero (eye / mouth loops would be fanned over); no Root bone on a
  Mixamo skeleton -> no `root_motion_track`. `MovementProfile.enable_traversal` (off for zombies) and
  `get_up_time` (4 s) are per profile; `DamageProfile.shove_knockdown` replaced the SHOVE_KNOCKDOWN const.
- **Assets**: `tools/blender/import_mixamo.py` (`import-mixamo`: Mixamo character FBX -> GLB, bones
  `mixamorig_*`, albedo + normal only, WebP, 2048) -> `assets/characters/zombie/zombie.glb` (+ `.import` with
  the Mixamo bone map, `character_post_import.gd`). Raw FBX stays in `art_src/zombie/` (gitignored, 110 MB).
  Clips: `intake/mixamo/Z_*.fbx` -> `mixamo.res`. Resources: `godot --headless --path . res://tools/tool_runner.tscn
  -- --tool=res://tools/build_zombie.gd` writes zombie_animset / body_profile (LITE, baked hit capsules, cut set) /
  movement / damage. Measured: Quaternius Zombie_Walk 1.12 m/s, Mixamo Z_Walk 0.36 (very slow), Z_Run 3.15,
  Injured_Walk 1.26, Z_Crawl 0.43 (hands). Strike clips + contact times: `ZombieArchetype.CLIPS`
  (`tools/measure_zombie.gd`). Zombie cut set: `blender --background --python tools/blender/ultra_blender.py --
  make-cuts --src assets/characters/zombie/zombie.glb --bone-map addons/ultra_controller/import/bone_maps/mixamo_humanoid.tres
  --out assets/characters/zombie/zombie_cuts.glb` (+ `zombie_cuts.glb.import`; textures shrunk to 8x8 in it:
  `UltraCutBody.activate` maps piece materials to the live body's BY NAME - Romero has two - cut materials
  Cut*; `make_cuts.py` keeps all the body's materials per piece, cut materials after them).
  Rebuild order after a model / clip change: import-mixamo -> `--import` -> make-cuts -> `--import` -> build_zombie.
- **Undead damage**: `zombie_damage.tres` - head `region_hp` 60 with region_mult 0.6 (two pistol / carbine
  headshots kill: the HEAD LIMB hp reaching 0 kills, not overall hp), torso mult 0.3 (~10 pistol / 12 carbine body
  shots), limbs 0.04-0.12, no bleeding (bleed / cripple / heart rates 0, `heart_radius` 0), no knockouts
  (ko_* 9999), crippled leg slowdown 0.55 (so `ZombieFactory` sets profile crawl speed = archetype crawl /
  0.55: every crawl is on ruined legs). `hp_mult` scales `region_hp` (brute 2.4), `shove_knockdown` 7 for it.
- **Cut in half and still alive**: `DamageProfile.halve_survives` (zombies) - a close (<= 3 m) buckshot / blast
  >= `halve_alive_min` 70 or a blade >= `halve_blade_min` 55 at the waist (`_at_waist`) -> `UltraCharacter._halve_alive`:
  `MotorState.F_HALVED` (flag bit 9; bits 0-7 motor_state.gd, 8 F_TURNING, 10/11 blocking / heart), both thigh
  chains severed (so crawling, no climbing, limb rules all follow), hp capped at `halved_hp_cap` 45, knock-down
  (normal ragdoll, NOT split: the hidden lower half just rides along), event `halve` with `alive = true`.
  Presentation (`UltraBodyFX._halve_alive_fx`): `UltraCutBody.Torso.UPPER` shows only `Seg_WAIST_UP + Cap_WAIST_up`
  + arms / head, the lower half (`Seg_WAIST_DOWN`, its cap, the visible leg pieces and stumps =
  `lower_half_parts()`) flies off as ONE gib, blood + guts hang from the upper end. Hit volume: the torso capsule
  starts at the waist (`UltraHitboxes.WAIST_T` 0.72; live and baked paths). Late joiners: `F_HALVED` up 0.5 s
  without the event -> silent UPPER. Respawn clears the flag; BodyFX's respawn path restores WHOLE.
  Tests: `z1_body` (lite build, speeds, crawler, limper, damage matrix, limbs, no bleeding, no KO, halve alive).
- **Health bars**: `UltraWorldBars` (addons/ui): ONE MultiMeshInstance3D, billboarded in `world_bar.gdshader`
  (per-instance custom data = fill, opacity); a character with meta `health_bar` (MODE_DAMAGED / MODE_ALWAYS)
  shows a bar for 4.5 s after its hp last changed (fades), the dead fade out. Reads replicated `state.hp`.
- Tours: `zombie_look` (archetypes, gaits, attack clips, hit, get-up), `zombie_gore` (gore_review on zombies),
  `crawl_review` (halve -> crawl -> claw -> headshot). The playground's sun renders the Romero albedo near
  black: `ZombieFactory.BRIGHTEN` 1.8 lifts every zombie material (then tinted per archetype).

## Mansion and AI navigation (zombie stage 2)
- **The mansion** (`--map=mansion`, `demo/maps/mansion.tscn` -> `Mansion`): a 56 x 40 m house built AT LOAD from
  `MansionLayout` (rooms / doors / stairs / packs as data: ground floor, upstairs with a ring gallery round the
  Great Hall's void, a basement under the east wing; ~58 doors incl. locked study / gun room and a barricaded
  closet) by `MansionBuilder` into a `BoxList` (box collection = collision + merged meshes per material + navmesh
  source geometry: ONE source of truth) - no saved scene, a few ms. Walls are centred on room edges and merged per
  line (`_resolve`), cut for doors (lintels above), gallery rooms have no walls (their neighbours' are), rails on the
  void / stairwell edges. `Mansion.marker("spawn")` (outside the front gate, facing north), `door(name)`, `room_at(p)`.
  Lights: ~80 omnis + two shadowed chandeliers + porch / path lamps + a dim moon; flat-colour materials.
- **Godot's box winding is CLOCKWISE seen from outside** (`BoxMesh.get_faces()` cross products point inward): render
  and `add_faces` triangles must wind that way (BoxList._append_box checks it) - the other way renders inside-out.
- **UltraNav** (addons/ai): one PRIVATE `NavigationServer3D` map (cell 0.1 - 0.25 closes a doorway -, cell height 0.05,
  radius 0.4, height 1.8, climb 0.35, slope 40; synchronous iterations so a changed cost shows on the next sync;
  `settle()` awaits it in tests), `query()` (shared result object) / `path()` / `snap()` / `crossings(result)` (the
  doors a path goes through, from `path_owner_ids` + `path_types`), `add_link` (owner = the door). Bake:
  `godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/bake_mansion_nav.gd` writes
  `demo/maps/mansion/mansion_nav.res` (`resource_name` = fingerprint of the nav geometry; the map warns and bakes at
  load when stale). ~0.7 s to bake, ~0.12 ms a path query.
- **Recast traps** (all hit here): a staircase of 0.174 m steps is not walkable (the ledge filter: two steps' climb
  ~ the 0.35 limit) -> stairs are `STAIR` boxes for collision / render only and the navmesh gets a smooth wedge
  (`BoxList.add_nav_wedge`, floor to floor); a box taller than the agent leaves its hollow inside walkable (only the
  surfaces are rasterised) -> tall props get a thin nav-only `PLUG` slab at 0.9 m; low props' tops are capped with a
  nav-only `PLUG` up to the ceiling (not in the hall: no ceiling over the void); a closed door is a `PLUG` in the
  doorway + a link across it (arches: nothing).
- **Doors** (`UltraDoor`, upgraded): `hp`, `barricaded`, `door_name`, `partner` (double doors move together),
  `is_blocked()`, `ai_open(from)`, `bash(amount, from)` (shakes; 0 hp -> `break_open`: planks fly, stays open, no
  collision), signals bashed / broke / `state_changed`; net state carries broken / hp / barricaded; `UltraDoor.all` is the
  registry. A link's cost follows its door (`Mansion.door_cost`): open or broken 0, shut 3, locked / barricaded 20 +
  hp / 10 (a detour of up to that many metres is preferred; a path that still crosses one means: bash it).
- Tests: `z2_nav` (build, every room reachable from the lawn, doors as crossings, stairs connect floors, nothing
  walkable over the void, a locked door reroutes then breaks, door rules, query cost). Tour `mansion_walk`.

## Zombie AI (zombie stage 3: demo/zombies/ + addons/ai/ultra_noise.gd)
- `ZombieDirector` (Node, server / offline only) owns every `ZombieBrain` (RefCounted); `add(character)` builds a brain
  from the zombie's archetype meta. It thinks brains when due (CHASE / ATTACK / door modes 0.1 s near prey, 0.2 far;
  INVESTIGATE 0.2; IDLE / WANDER 0.35 near, 1 s far; DORMANT 0.5 / 2 s; <= `max_thinks_per_frame` 12), samples players'
  footsteps at 5 Hz (`UltraNoise.step_loudness`: sprint 13, jog 9, walk 4.5, creep 1.5 m), passes `UltraNoise` events to
  zombies within loudness x hearing + 24 m, alerts pack-mates (<= 20 m become INVESTIGATE), caps door bashers at 2.
  The brain's per-tick part is only `drive()` (BotInputSource.driver): turn toward `want_yaw` at `arch.turn_rate`,
  walk when roughly facing it. Brain clock = physics frames / tick rate (deterministic under --fixed-fps).
- **Modes**: DORMANT, IDLE, WANDER (random point <= 6 m round home), INVESTIGATE (go to what it heard / last saw, look
  about, give up), CHASE (sees it -> its position, else last seen for `arch.memory` s, then investigate the spot),
  ATTACK (a swing: `play_attack` at once, contact 0.45 s later: the target must still be within reach x 1.2 + 0.2 and
  75 deg in front -> `DamageInfo` kind `claw`, melee true, shove 1.4), STAGGER (region-weighted damage >= 3 stops it
  0.35-1.2 s, cancels a swing), OPEN_DOOR / BASH_DOOR, DOWNED (ragdoll / get-up / KO), DEAD. Being shot by a player
  turns any non-busy zombie on its attacker.
- **Senses** (`ZombieSenses`, pure physics queries): sight = half-angle `sight_fov_deg` cone out to `sight_range` x
  target's motion (still 0.7, sprint 1.4) x stance (crouch 0.65, prone 0.4), `close_sense` 1.8 m from any side, two
  rays (chest, head) through WORLD_STATIC | WORLD_DYNAMIC (a shut door blocks); awareness meter 0 -> 1 (>= 0.35
  suspicious: investigate, 1: chase; fills 0.8-4/s by distance, empties 0.25/s). Hearing: carries loudness x `hearing`
  m, +6 m per floor between, +5 per upright wall (3 for a door panel; up to three; floors / ceilings aren't walls).
- **Noise sources** (authority only): gunshots at the muzzle (`UltraNoise.gun_noise`: item stat `noise`, else pistol
  35 / rifle 50 / shotgun 60), melee swings (7, 13 on a hit), a player opening a door 4, a bash 18, a door breaking 25.
- **Paths / doors**: `_goto` repaths <= every 0.3 s or when the goal moves 2 m; `_skip_passed` drops waypoints we are
  already beyond (a repath from just past a door's link start sent zombies back and forth). A link waypoint of a shut
  door within 1.25 m: free -> OPEN_DOOR (0.5 s, `ai_open`, 0.9 s for it to swing); locked / barricaded -> BASH_DOOR
  (swipe every 1.3 s, `bash(damage x 1.4)` at the contact). **Doors swing AWAY from whoever opens them** (the sign was
  inverted: a door swung into the zombie and pinned it against the wall). Stuck ladder (moved < 0.25 m in 1.4 s):
  repath, sidestep, back off 1 s, alternate sides.
- Debug: `ZombieDebug` (F10 / `--zdebug`; new default input action `zombie_debug`, `tools/install_input_defaults.gd`
  adds actions to project.godot headless): label (mode, awareness, archetype), path, goal, facing, a ring per noise.
- A brain's mode timer `_until` is reset by every `_enter`: the door interlude (OPEN_DOOR / BASH_DOOR) saves and restores it
  (`_resume_until`) - INVESTIGATE gives up at `_until + 20`, so with it at 0 a zombie that opened a door gave up on the spot once the
  game was 20 s old (z3 only saw it after z1 had burnt the clock: `--suite=z1,z3` runs suites in one process, as `all` does).
- Tests `z3_brain` (10): hearing through walls and floors, goes to look, sight cone / walls, chase + hurt, doors on the
  way, stairs, bashing a locked door, the racket draws company, shot staggers / wakes a dormant one, crawler. Tour
  `zombie_review`.

## Zombie sandbox, director and performance (zombie stages 4-5)
- **Sandbox** (`MansionSandbox`, demo/scenarios; created by main.gd for the mansion map, started on session start
  unless `--no-zombies`): `MansionLayout.PACKS` -> ~41 zombies placed at clear navmesh spots in their rooms, spawned
  2 per tick; "room" packs lie DORMANT and wake (INVESTIGATE the player) when a player enters one of their rooms,
  "noise" packs stand / wander and rely on senses; wave button in the foyer + F11 (`trigger_wave`: wakes everything
  within 70 m hunting - `max_awake` 24 holds - and RECYCLES corpses as fresh zombies at the gates, never spawning:
  player ids are u8 and never reused); reset button + F12 (doors repaired via `UltraDoor.reset`, zombies respawned
  at their `home_spawn` dormant, player healed, count 0); kills counted from `died`; pickups (ammo, medkits, the red
  key (study) on the dining table, the green key (gun room) upstairs in the master bedroom); `ZombieHud` top right.
- **Director**: attack tokens (`max_attackers` 4 swing at one target; the rest crowd round), `ring_dest` (a chaser
  between reach + 1.4 m and 7 m heads for its own free bearing round the target: the last step is straight in),
  `wake_near`, `recycle` / `revive` (respawn_character + dress(force) + brain.reset).
- **What a hunting horde costs** (the lesson of stage 5): the physics tick, not the drawing. One zombie's step
  (`UltraCharacter.simulate`) is ~0.25 ms (GDScript spread over ~15 motor calls: slide, floor ray, step-up test,
  separation query, transitions...), so 41 awake = ~10 ms a TICK; once a tick costs more than the 16.7 ms frame
  budget with the draw, Godot runs several ticks per frame and the frame time snowballs (131 ms with 24 hunters).
  `Engine.max_physics_steps_per_frame = 1` takes the snowball away for measuring: then frame times compare
  step by step (`demo/tours/perf_review.gd` does; 25 standing zombies in view with every effect on = 60 fps,
  the monitors `TIME_PROCESS` / `TIME_PHYSICS_PROCESS` include the wait for the swap and mean nothing here).
  `UltraProf` (`--prof`, scope timers: `var t := UltraProf.tick()` ... `UltraProf.add("name", t)`) found it; the
  horde / z5 tours print `UltraProf.report`. Never `git checkout` files that carry your real edits to drop
  temporary instrumentation: commit first.
- **Sim stride** (`UltraCharacter.sim_period`, set by the director when a brain thinks; `UltraNet._server_step` skips
  the ticks in between and the step's dt covers them): idle / dormant standing zombies every 4th tick; walking ones
  every 2nd from 3 m of every target, 3rd from 8 m, 4th from 20 m (`ZombieDirector.STRIDE_*`). Doors, attacks, falls,
  ragdoll, platforms and anything not grounded step every tick; damage / knock-down / a brain mode change put it
  back to 1. `UltraMotor.move` scales the slide velocity by dt x tick rate (move_and_slide covers one engine tick);
  the visual draws a stride over its own ticks (`UltraCharacter.stride_wait`, alpha = (waited + fraction) / stride),
  so strided zombies stay smooth, one stride late. `ZombieBrain.drive` turns by `sim_period` ticks of rate.
  NPC-only shortcuts (never for predicted players, whose motor must be a pure function of the state):
  `motor.cache_floor` (floor ray re-asked every 6 ticks / 0.5 m), `quantize_state` off (set in `ZombieFactory.dress`),
  `_update_platform` skips its test_move when no TickPlatform exists.
- **Presentation LOD** (windowed only, ZombieDirector `_lod_pass`, 3 brains a tick): tier 0 = in view (frustum + a clear
  ray to it) and < 16 m: injury modifier + shadow, hit capsules from the live skeleton (`live_hit_capture`; else the
  baked ones), foot IK < 7 m, animation every frame < 6 m and at 30 Hz beyond (tree on manual advance in
  `Director._process`); tier 1 = in view < 40 m: 15 Hz, no foot IK / injury modifier / shadow / live capsules;
  tier 2 = further or hidden: tree off, and hidden ones aren't drawn and their character / anim / BodyFX `_process`
  is off. A far SLEEPER is out of the simulation (`UltraCharacter.sim_skip`, honoured by `UltraNet._server_step`)
  beyond 38 m from every target and viewer. The mansion switches room lights off beyond ~24 m + range / 2 from the
  camera. Measured, windowed (RTX 3070 laptop, 1280x720, everything on): 41 zombies standing 110 -> 26 ms a frame;
  `horde_review` hunters 10-12: 83-99 -> 25-27 ms, 22 hunters round the player 131 -> 48 ms (21 fps; the stress
  case is a wave of 41 in the hall). Headless `--suite=z5`: 41 awake = 14.6 ms a frame.
- Tests `z4_pack` (6): the house fills, a pack wakes with its room, a wave recycles corpses without new ids,
  <= 4 swing at once, 41 hunters for a minute stay sane, reset restores. Tour `horde_review`, `perf_review`.

## Levels and the main menu
- `main.gd` `LEVELS` (key, title, blurb, scene): playground, mansion. The main menu's Level section (toggle buttons, pad-linked
  above "Single player") calls `main.set_level(key)`, which swaps the map behind the menu (`_load_level`: the old map and the
  mansion's sandbox leave the tree FIRST - `remove_child` then `queue_free` - because a mansion tears its navigation down on
  exit and that must not land after the next level's setup). Not while a session runs. `--map=<key>` picks the start level; the
  last one is kept in `Engine` meta `ultra_level` so Pause > Main menu (scene reload) reopens on it.
- Every way to play starts in the picked level: single, split 2 / 4, host, join, host + test client (`--map=<level>` added to the
  launched client), and launcher presets (`UltraLauncher.launch(preset, "", extra)`: `extra` goes to every instance that doesn't
  set that option). Joining: the host's `UltraNet.session_info_provider` (main: `{level}`) is sent with the hello reply, ahead of the
  spawns; a client on another level gets `session_info_received`, loads the host's level and joins again once (`_rejoin_on`).
  verify.sh net case `level` (client without `--map` joins a `--map=mansion` server; `--expect-level`, `--allow-dropped` for the
  server's probe connection).
- Tests: `ui_menus.test_main_menu_level_select_with_pad`, `test_every_way_to_play_starts_in_the_zombie_mansion` (single / split 2 / 4:
  everyone at the gate, zombies in, a HUD each, level kept after Main menu).
- `--suite=a,b` runs several suites in ONE process (as `all` does): order effects only show that way.

## Sinew (Euphoria-style active-physics bodies; plan: `sinew/PLAN.md`)
- **Changing a gait reference clip (walk / run / sprint / back / strafe): read `sinew/ANIMATION_GUIDE.md` first** -
  what a reference clip must be, the swap checklist, the clip audit (`addons/sinew/clip_audit.json`), every clip
  lesson so far. Add new ones there.
- **Never edits the UltraController.** Sinew is its own module: `sinew/` (engine-agnostic C++17 core on
  Box3D, no engine types in its headers; `capi/sinew.h` flat C API for other engines), `bindings/godot/`
  (godot-cpp 4.5 GDExtension -> `addons/sinew/bin/libsinew.<platform>.<target>.<arch>`), `addons/sinew/`
  (GDScript side: `SinewCharacter extends UltraCharacter`). Nothing under `addons/ultra_controller/` changes
  for it. `sinew/` and `bindings/` carry `.gdignore` (godot-cpp ships a test project).
- **Physics = Box3D** (Erin Catto, MIT, alpha), submodule `sinew/extern/box3d` pinned to a known-good commit;
  every Box3D call is behind `sinew::PhysicsWorld` (src/physics_world.cpp). Defaults: 8 substeps, joint
  constraint 120 Hz (Box3D clamps a joint's stiffness to a quarter of the substep rate: at its 4 / 60 Hz a
  flung limb's joint opened 13 mm; now <= 2.6 mm at 20-34 rad/s, cone overshoot 0 / 4 deg).
- **Builds:** CI (`.github/workflows/sinew.yml`) tests the core, builds Windows (MSVC) + Linux (Ubuntu 22.04)
  template_debug / template_release and COMMITS the binaries to `addons/sinew/bin/` ([skip ci]); pull to get
  them. Local: `git submodule update --init`, then core `cmake -S sinew -B build/sinew && cmake --build
  build/sinew && ctest --test-dir build/sinew`; extension `cmake -S bindings/godot -B build/godot
  -DGODOTCPP_TARGET=template_debug && cmake --build build/godot --config Release`. Box3D links the MSVC
  runtime statically: every target must too (`CMAKE_MSVC_RUNTIME_LIBRARY` set in both CMakeLists -
  godot-cpp sets it on its own target only; the binding's objects came out /MD and the link failed).
  Each build job uploads ONLY its own platform's files (`libsinew.<platform>.*`): uploading `bin/*.dll`
  from the Linux runner carried the stale committed DLLs, the commit job's merge let them win, and
  Windows players got the S3 DLL with the S5 scripts ("Nonexistent function character_muscle_effort").
  CI job logs are on a host this cloud session can't reach: failing build lines are echoed as
  annotations (`gh api repos/<owner>/<repo>/check-runs/<job id>/annotations`).
- **Main menu Character section** (`demo/characters/character_models.gd` = `CharacterModels`): Controller
  (UltraController | Sinew) and Model (Mannequin | Zombie) toggle rows between the levels and Play
  (`main.set_controller` / `set_model`, `--controller=` / `--model=`, kept in Engine meta `ultra_controller`
  / `ultra_model` across Pause > Main menu; refused mid-session). The Controller pick goes for the yard dummies and the
  companion too (Sinew dummies can be pushed / shot with balls; `--plain-bots` keeps them plain); the Model pick
  is players only; zombies stay plain. The zombie MODEL for a player = Romero's mesh, cut set and
  hit capsules on the mannequin's FULL animation set (same humanoid skeleton); the zombie NPC profile is LITE.
- Tests: `sinew_tests` (doctest, core), suite `s0` (extension loads + simulates, Single player plays the pick,
  zombie model walks on the full stack), `ui_menus.test_main_menu_character_select_with_pad`. A GDScript parse
  error does NOT fail the runner (the test still prints ok): grep the output for `SCRIPT ERROR` (CI does).
- **The body (S2)**: `SinewCharacter._build_visual` swaps the UltraRagdoll for `SinewRagdoll extends
  UltraRagdoll` (same interface: active, getup_front / yaw, split_waist, hips_offset), a Sinew character in
  `SinewWorld` (one per scene tree, `acquire` / `release`, joins the root DEFERRED - a body asks while its
  character is being set up; steps at physics priority 120, after the motor ticks; mirrors the level's
  WORLD_STATIC | WORLD_DYNAMIC colliders: static ones static, scripted / animatable / rigid ones as kinematic
  proxies). `SinewPoseModifier` sits where the PhysicalBoneSimulator3D was (before Dismember): records the
  animated pose (targets), writes the physics pose by `blend`, interpolated between ticks. The capsule
  (RAGDOLL / GET_UP / DEAD) stays the gameplay truth. Headless (no visuals) there is no Sinew body.
- **Rig**: 19 parts (pelvis, spine, chest, upper chest, head on the neck bone, clavicles, arms, forearms,
  hands, thighs, shins, feet), de Leva masses (clavicles 2.5 % each: lighter ones under stiff springs made
  the arm sway), ball joints (cone centred off the rest bone for shoulders / hips) + hinges for knees /
  elbows. Arms don't collide with their own torso / hips / thighs (torso capsules are wider than a slim body).
- **Muscles** = Box3D motor joints (angular spring + torque cap) re-aimed each tick. Rules learnt:
  * Box3D normalises a spring by the two bodies' own inertia: scale hertz and damping by
    sqrt(subtree inertia / part inertia about the pivot) (`Character::load_scale`, cap 6) - else the spine
    swayed after a shove and a clavicle let the arm sway 12 cm - and only as far as the muscle works
    (scaled by tone: stiff springs with tiny caps on a lying body chattered).
  * A spring "off" (cap or hertz 0) keeps warm-starting its last impulse forever (a released root drive
    floated the body up): Sinew never sets 0, it uses a 1e-6 cap (`OFF_CAP`).
  * Targets set from a moving pose are led by the spring's lag (2 zeta / omega, <= 0.12 s, 0.6 rad); the
    target's motion is used once (a downed body kept leading its last walking target: feet buzzed).
  * Gravity compensation is a torque pair out of the same strength; off once down (it pressed the standing
    pose into the floor). Box3D's continuous collision stops each part at its own time of impact: joints
    are projected back after every step (`Character::post_step`).
- **Powered (S3, default)**: standing, the pelvis and legs follow the animation KINEMATICALLY (physical legs
  scraped the floor; they come with the balancer) and the upper body is muscled physics tracking it at
  `powered_stiffness` 1.6 - the skeleton shows the physics (standing within ~5 cm;
  walking 11 cm). A hit (`SinewCharacter.react_to_hit`, every machine) pushes the struck part
  (0.5 N s / damage, <= 35) and slackens its limb to 25 % tone, back over 0.4 s. Knocked down: legs to 15 %
  of the down tone at once (else it stood like a statue), spine 50 %; damping rises as it settles.
  The body SNAPS onto the animated pose for 0.25 s after powering on (the tree may not have posed the
  skeleton yet: arms crept down from a T-pose) and when the animated hips jump > 0.5 m in a tick (a
  teleport left the upper body up to 1.2 m behind). Kinematic standing (`powered = false`) is suite s2's mode.
- **Limbs + procedural control (S4)**: core `Limbs` (sinew/limbs.hpp: arm L/R, leg L/R, spine, neck - state:
  attached, health = weakest tone, end position / velocity, contacts, reach) and effectors solved into ONE-TICK
  muscle targets (`Character::set_effector`, mixed with the animated target by weight, dropped after pre_step):
  `reach` (two-bone IK: hinge angle found by sampling + bisection, upper bone = least turn from its animated
  orientation so the elbow keeps the clip's side; the wrist aims short of the point by the hand, 3 passes),
  `place_foot` (keeps the foot's animated world orientation - read it BEFORE setting the bones' effectors),
  `look`, `lean`. Probes (`sinew::probes`): ground_below, edge_ahead, wall_within, impact_eta - character parts
  carry collision category 2 and queries mask it out. Contacts: `PhysicsWorld::contacts` (Box3D contact data;
  NOTE kinematic vs static makes no contacts: powered standing feet don't "touch" until the legs are physical).
  Godot: `SinewRagdoll.reach / look_toward / place_foot / lean / set_part_target` queue requests applied after
  the animated targets in sinew_pre_step (call every physics frame), `limb_state(Limb.X)`, `part_contacts(name)`;
  `world.physics.ground_below / edge_ahead / wall_within / impact_eta`.
- **Balance (S5)**: core `Balancer` (sinew/balance.hpp), physical legs, no external help but an optional
  documented `upright_assist` (0.3: a capped implicit spring on the pelvis' ORIENTATION only - position is
  the legs' job). Lessons:
  * Explicit virtual-model torques (Jacobian transpose up the legs) oscillated +-1600 N m tick to tick on
    the light pelvis: every controller is an IMPLICIT muscle target instead (SIMBICON): stance hip target =
    pelvis_target^-1 * thigh(live) (holds the pelvis), ankle target = (tilt * shin(live))^-1 * foot(live)
    (tilt = PD on COM error, rad; RELATIVE to the live shin - an upright "neutral" shin made a stride's two
    legs fight and launched the body), stance hips / ankles stiffness x6 (`Character::set_part_stiffness`),
    their gravity compensation off (`set_part_gravity_compensation`: the ground carries a standing leg).
  * Feet are BOXES (`PartDef.box`, heel to toe tip, sole on model y 0): a capsule foot rolls.
  * Support = the planted soles' corners (contact points flicker); planted = touched within 4 ticks, sole up
    (cos > 0.6) and ankle low. On one foot the ankle brakes over THAT foot. Steps go to the capture point
    PREDICTED at touchdown (LIPM: grows as e^(t/Tc) from the stance foot); a sideways fall steps the foot on
    that side; 0.12 s of double support between steps; closing steps (feet back side by side) only after a
    recovery and only after the weight has shifted onto the other foot (lifting with the COM between the
    feet = falling: the mannequin's idle stance is 40 cm wide).
  * Known: recoveries from 40-120 N s can dance many steps (it leans on its heels and keeps stepping back);
    30 N s forward slides the feet ~20 cm. Core: stands 10 s, 30 N s no step, 60 / 100 N s stepped, 250 falls.
  Godot stagger window (`SinewRagdoll.start_stagger`): a body / head / leg hit >= `stagger_min_impulse`
  10 N s on a standing powered body -> legs dynamic + balancer; steady 0.4 s or `stagger_max_time` -> legs
  kinematic, gliding back onto the animation over 0.3 s (offline: the capsule teleports to where the body
  stepped first); fallen or careering > 0.9 m off the capsule -> offline `knock_down(com velocity)`, legs
  stay physical into the fall. A torso hit slackens only the torso, to `torso_relax_tone` 0.6 (all of the
  upper body at 0.25 folded it over). `balance_settings` passes any BalanceSettings field by name.
- **Physics shows per part** (`SinewRagdoll.part_w` / `_update_parts`, GTA IV's way): powered, the body
  plays the animation EXACTLY (this frame's pose, the IK included: hands on the gun, feet planted) and
  turns physical only where something happens - standing still with empty hands the upper body (its idle
  life); a hit: the struck chain for `hit_window` 0.9 s (arm hit = that arm from the shoulder; body / head =
  the whole upper body); a stagger: everything; procedural control (`reach` etc.) its limb while driven.
  Running / armed / carrying / traversal = animation. Weights ease in 0.15 s, out 0.3 s while the part is
  still physical, then it goes kinematic. SinewPoseModifier writes EVERY part (an animated child under a
  physical parent is set to its animated global pose). Before this the whole upper body was always physics
  AFTER the IK passes: arms trailed at a run and the hands slid off the guns.
- **Own animation driver (S6a)**: `SinewCharacter._build_visual` is a full override (no super): `SinewAnimDriver
  extends UltraAnimDriver` (the type `anim` is declared as) plays the referenced clips AS THEY ARE - no
  InertialBlend / BodyDynamics / FootIK / ArmClear / WeaponPose / HandIK / Look (skeleton passes: Injury,
  Sinew, Dismember), no TraversalHands. One tree: state machine over the motor states (ground = BlendSpace2D
  x right / y forward, 1 walk 2 run 3 sprint, rate = speed / authored; crouch / prone / swim idle<->go; air,
  land, hang, ladder, wall, rope, slide; timed climb_up / vault / rm / get-ups), upper-body item layer (the
  held item's anim_roles idle / aim clip), swing + hit one-shots. `hand_ik` stays null (the equipment then
  leaves the hands to the clip); the equipment's prop-carrying path calls hand IK unguarded, so
  SinewCharacter lends it an INACTIVE `prop_hand_ik` only while `state.held_id != 0`. Member names must
  not clash with UltraAnimDriver's (`_swing_left`, `_drive_ground`... are taken: parse error).
  Clip references: `SinewAnimationSet extends AnimationSet` (`overrides` role -> "library/clip" over `base`
  = the body profile's set; `resolved()` gives each character its own copy - items write roles into it);
  default `addons/sinew/sinew_animset.tres` (empty = clips as imported), `SinewCharacter.sinew_anim_set`
  per character; `gait_walk / run / sprint` name the reference cycles for the gait (S6c).
- **Gait (S6b, core `sinew/gait.hpp`)**: procedural walking / running. One phase for both feet (left 0,
  right 0.5); a foot swings when its phase >= duty (walk 0.62 = double support, run 0.36 = flight), cadence
  1.35 + 0.42 x speed steps/s (<= 3.3). A planted foot is LOCKED (planted slide 0 mm by construction); a
  swinging foot heads for the hip's place at touchdown + half the stance travel, on the ground under it
  (probes), over a sin arc. Starting off, the foot that's behind (or furthest off its spot) lifts AT ONCE
  (from phase 0 the first foot stayed down 0.9 m and the pelvis sank to reach it). Standing still it keeps
  stepping until both feet are home (`home_tolerance` 0.1 m) and lined up with the facing
  (`turn_tolerance` 0.55 rad): stopping and turning on the spot step. Pelvis: bob / sway / run crouch, and
  DROPS until the hips reach both ankles (`max_reach`). Body from `GaitCycle`s (local rotations sampled per
  phase, phase 0 = left contact, blended by speed) or, without cycles, procedural (arms down from the rest
  T + swing against the legs, spine counter-twist, lean at a run). Legs: `two_bone_ik` (factored out of
  Limbs: works on a pose) onto the ankles; feet flat with the yaw they were put down with.
- **Gait in the game (S6c)**: `SinewRagdoll.gait` (on) - `_setup_gait` (after every `_make_character`) gives
  the core gait the cycles `SinewGaitCycles.build` samples off SinewAnimationSet.gait_walk / run / sprint
  (24 phases from the clip's `plant_phase` = left contact: each part's rotation in its parent PART's frame,
  the pelvis in model = skeleton space, position tracks x `motion_scale`) and the idle clip's first frame.
  `_update_gait` (each Sinew tick, IDLE / MOVE / TURN_IN_PLACE / LAND on the ground) feeds the root
  (`Basis(UP, body_yaw)` at state.pos x visual_root->skeleton) and state.vel; SinewPoseModifier blends the
  interpolated gait pose into the recorded animated pose DOWN THE CHAIN in local space (blending world
  poses left the clip's arms floating 9 cm off the gait's pelvis), weights `gait_w` (0.2 s) x `gait_part_w`:
  pelvis + legs 1; the upper body 0 standing / with an item / during a one-shot (`SinewAnimDriver.upper_busy`:
  a hit flinch, a swing - the gait hid the hit clip), up to 1 by 0.6 m/s. That pose is what shows and what
  the body tracks / kinematic parts follow. Foot roll (core): heel strike toes-up (`toe_up` 0.22, fading at a
  run), heel rising round the ball before push-off (`heel_rise` 0.6) - without it the planted ankle pinned
  flat couldn't span a stride and the pelvis sank into lunges; `ankle()` = drawn (rolling), `plant()` =
  where it was put down (locked). Step length <= `step_max_walk` 0.62 / `step_max_run` 1.15 x leg length
  (cadence rises for short legs, up to 5 steps/s). Measuring a planted foot: the smaller of the ankle's and
  the toe's frame-to-frame move (one of them is the pivot). Tour `sinew_gait_review` (side on).
- **8-way gait + momentum** (core `Gait`, sinew/src/gait.cpp; tests `gait: 8-way`, `gait: reversing`,
  `gait: momentum` measured against plain forward walking, with velocities ramped like fps.tres:
  accel 11, brake 20 m/s2 - a velocity step is not what the game does):
  * Hip warp: the legs walk in a frame turned toward the travel (0.5 x the angle, <= 0.7 rad; backing
    diagonals toward the backward direction, hysteresis at the side), pelvis 80 % of it, the spine turns
    it back (chest keeps facing). A pure side-shuffle at 1.4 m/s with uncrossed feet can't keep up.
  * Step length per direction (back 0.72, side 0.5 of forward; cadence rises); no crossing: a foothold
    keeps `stance_gap` 13 cm sideways (legs' frame) from the other foot.
  * A swinging foot lands only when ITS swing is through (the cycle wraps; progress from the phase it
    lifted at) - a duty change while braking from a run dropped a mid-swing foot 1.5 m ahead.
  * A standing foot left stretched behind the motion hurries the cycle (<= 2.5x, eased 20/s; full
    hurry with both feet down) - never a jump in phase: that snapped the other foot's roll. A planted
    foot's roll changes <= `roll_rate` 6 rad/s; the swinging foot is drawn rolled into the heel strike.
  * Swing footholds follow a change of motion at <= `retarget_speed` 6 m/s.
  * Momentum lean: a damped spring (2.2 Hz, zeta 0.55) toward 0.3 x a/g, <= 0.25 rad, <= 2.5 rad/s;
    pelvis tips 35 %, spine the rest, arms trail 0.7 x; no pelvis shift (the braking foot is already ahead).
  * SinewRagdoll: the upper body goes physical only after `calm_delay` 0.35 s still (a reversal passing
    zero speed made it physical while the pelvis swung round: it folded over).
  * s7 slide = smallest move of heel, ankle and toe (a heel-strike pivot isn't a slide).
  Tour `sinew_8way_review` (facing fixed: 8 directions, reversals).
- **Physical motion (S7a)** (`SinewCharacter.physical_motion`, on; OFFLINE / NONE only - networked play keeps the
  predicting motor): the motor still says what you want (`target_ground_speed` along the stick), but on the
  ground (IDLE / MOVE / TURN_IN_PLACE, no platform) the capsule moves at `Gait::drive` - the centre of mass an
  inverted pendulum (omega = sqrt(g / pelvis height)) over the centre of pressure, which can only be inside the
  planted soles (heel up: the balls; toes up: the heels; in flight: nothing), aiming for the command in
  `drive_tau` 0.2 s, push <= `friction` 0.6 g (0.8 outran the legs: planted feet ended out of reach). After
  the motor's step, `_drive_motion` moves the capsule by (drive - motor) THROUGH `motor.move` (step-up / snap /
  pushes; a bare slide left the floor on stairs) and sets body.velocity, so the motor carries on from it.
  Footholds brake / catch: hip at touchdown + command x half the stance + (velocity - command - trim) x
  `capture_gain` 1.5 / omega, never behind the hip along the way it's going (accelerating, the upright legs
  couldn't reach), <= `land_max` x leg. A speed trim (integral, only near the command with a foot down -
  else it wound up and overshot 45 %) removes the steady offset of the asymmetric sole. `motion_command` goes
  to the gait; the upper body turns animated on the WISH (a slow start left it physical while the arm swing
  came in: a hand whipped 14 m/s). Walk: 90 % speed ~0.65 s, stop ~0.4 m; run 3.5 -> stop 1.9 m / 5 steps.
  Tests: core `gait drive`, suite s9.
- **Knees and flow** (user: straight knees, bobbing): `max_reach` 0.95; the body lowers with speed (`knee_bend`
  2.5 / 8 / 11 cm walk / run / sprint); the clips' pelvis bob kept at `cycle_bob` 0.6; the drop a stretched
  PLANTED leg needs is eased (in 0.15, out 0.06 m/s, the rest beyond `drop_slack` at once); a swinging foot out
  of reach is pulled into it (a run's trailing foot dragged the hips 30 cm down). Hips: walk 2 cm / 0.25 m/s,
  run 2.8 cm (were 6 cm / 0.86 m/s) - core test `gait: flow`. Side steps `step_side` 0.65 of a forward one.
- **Running feet + leg effort**: at a run the foot lands on the forefoot and stays on the ball
  (`forefoot_run` 0.25 / `forefoot_sprint` 0.4 rad heel up; a flat planted foot pinned the ankle low and the
  hips dipped every stride - run hips 2.65 cm / 0.25 m/s). `Gait::leg_effort()` (binding
  `character_gait_leg_effort`) estimates each animated leg muscle's effort (torque / rig strength): a
  planted leg's share of the weight (split by distance to the COM) as a ground force from the centre of
  pressure (clamped onto that sole) toward the COM, against each joint's lever arm, plus the leg's own
  segments; the debug view uses it for kinematic legs. The debug view draws from the POSED skeleton at
  `skeleton_updated` (the kinematic bodies follow a tick or two late: at a sprint the shapes trailed 0.5 m).
- **Pushes, stumbles, trips, test balls (S7b)**: a push on a Sinew body goes into its physical motion
  (`SinewCharacter.receive_push`: tap 1.2 .. full 4.5 m/s): the gait's capture footholds stumble it out
  (a tap ~0.9 m / 2-3 steps); `Gait::capture_margin` (a step's reach minus the capture offset) negative for
  0.5 .. 0.25 s (sooner the further gone) trips it (knock_down with its speed). The pusher's arms are Sinew
  `reach` effectors (in to the chest while charging, out at the target's chest) - the Push clip threw them up.
  Ball launcher (`demo/items/ball_launcher_item.tres`, Sinew players' kit): the shot is a dud, `SinewBall`
  is a Box3D body (`PhysicsWorld::add_ball`: 2 kg, 20 m/s, bullet, restitution 0.35, gone after 2.5 s); a
  body on its path within 0.15 s is woken whole (`SinewRagdoll.brace` = the stagger mode; `SinewRagdoll.all`
  registry) so the CONTACT decides the reaction (no scripted shares). Staggering, the capsule follows the
  body's COM through `motor.move` (it waited behind and the 0.9 m "careering" rule floored a body that was
  stepping fine) and the animation stands still (a walk cycle moving with the capsule made the muscles kick
  the legs: a feedback loop that launched it). Known: the balancer drifts sideways ~1 m recovering from a
  straight chest hit.
- **Unarmed push** (test tool, `SinewCharacter.push` / `can_push`): empty hands (no prop held,
  nothing equipped, on the ground) + the throw button (`uc_throw`, the one that throws a held box):
  a tap shoves the character in front 3 m/s (rocks it back ~20 cm), holding charges to 5 m/s over
  0.8 s (past `shove_knockdown` 3.5: knocked over); loose props get the same dv x mass (<= 80 kg).
  A 0-damage `impact` DamageInfo with `shove`, applied PUSH_CONTACT 0.18 s after the release by the
  authority; arms = SinewAnimDriver `play_push` (UAL Push, upper-body one-shot). Suite s8.
- **Gait matched to the clips** (tour `sinew_gait_compare` + `tools/sinew/gait_compare.py`: orthographic side
  view locked to the character, `--gaitcmp=clip|gait --pace=walk|jog|sprint --no-kit`, frames counted in physics
  ticks under `--fixed-fps 60`; the script finds strides by the left ankle's forward maxima in both runs, prints
  per-phase knee / hip / ankle / toe / foot pitch / pelvis / arm and writes `<pace>_strip.png` (clip over gait) and
  `<pace>_overlay.png` (clip red, gait cyan)). Lessons:
  * The reference cycles are the Mixamo walk / run / sprint (`sinew_animset.tres` overrides walk_f =
    N_StdWalk2 1.45 m/s, jog_f = U_Run_F 3.63, sprint_f = S_Fast 5.53 - near the motor's 1.35 / 3.6 / 6.2); the
    UAL Walk / Jog / Sprint are stylised (the jog: 1.7 steps/s, 2.8 m steps, 75 % flight). U_Run_F holds its
    left hand up by the face: `gait_run_upper` [walk, sprint, sprint] gives the run cycle the average upper body
    of those (same heel-strike phase), legs + pelvis its own. `Mixamo_Jog` is the UAL jog round-tripped (unused).
  * Cycles are sampled from the left heel strike (ankle furthest ahead of the hips: `contact_phase`; the
    animset's plant_phase is the TOE going down, a quarter stride later on a walk), then the core rotates each
    cycle to the first sample the left foot is down after its longest time in the air (phase 0 = touchdown).
  * `ClipLegs` (per clip): stride = authored speed x length (authored = the grounded toes' speed in skeleton
    space; measured against the hips it reads 10-20 % low at a run - the hips surge - so the measurement only
    overrides a clip that is > 30 % off), duty, landing point, per-phase ankle lift, forward path (`fwd`, share
    of the stride) and foot pitch. Pitch is atan2(up, along the motion) - signed: a sprint's push-off tips the
    foot past vertical (150 deg), an unsigned measure read 56. The stance roll may go as fast as the clip's.
  * The swing follows the clip's ankle path RELATIVE TO THE HIPS (`path_at`: hip ground + fwd(p) x 2 x step),
    joined to where it lifted and bent onto the foothold (`lift_off`, `end_off`); the drawn ankle is the path
    (rolled for the heel strike only over the last quarter). A smoothstep from lift to foothold arrived early and
    waited with the leg locked straight (knee 11 vs the clip's 40).
  * On a clip's legs the pelvis drops all the way a planted leg needs (no `drop_slack`): a sprint push-off's
    heel rise left the ankle 6 cm short and the toe slid 31 mm a frame.
  * Starting off: `push_accel` 2.5 m/s2 - a planted leg pushes off beyond the pendulum's tip (to 90 % of a walk
    in 0.47 s, was 1.05).
  Result (worst per-phase |gait - clip|): walk knee 22 deg, ankle 4 cm, pitch 4 deg, pelvis 0.5 cm; run knee 39,
  ankle 6 cm, pelvis 1 cm; sprint knee 50 (the early-swing fold - one tick of presentation interpolation at
  4.2 steps/s), ankle 12 cm, pelvis 3 cm; stride and cadence equal at all three.
- **Directional cycles (strafe / back)**: `SinewAnimationSet.gait_back / gait_left / gait_right` (walk_b,
  strafe_l = Mixamo Strafe_Walk_L, strafe_r) join the forward walk / run / sprint; the core finds each clip's way of
  travel from its grounded feet's slide (`ClipLegs.angle`: back -180, right -91, left +90) and `cycle_weights(speed,
  theta)` blends the two clips either side of the travel round the compass (forward = the speed blend), a directional
  one fading out from 1.3 to 2.2 x its own speed (running sideways = the forward run, warped). Their own hip twist
  comes with them (warp only for the forward share, `dirw`). Paths are 2D per foot: along the travel (`fwd`, share of
  stride) and across it (`across`, m) from the hips' centre, plus the foot's facing (`yaw`, relative to the slowest
  forward clip's: the drawn foot is that yaw on its rest orientation) - a crossover strafe's feet cross and close.
  Per-foot touchdown offset (`foot_off`) and duty (`duty_f`): a side step isn't symmetric. A stance = the LONGEST run
  of down samples (`stance_run`): a crossover's swinging foot passes low under the body and read as a touchdown. No
  "never across the other foot" rule on a clip's own path. Strafe: hip 4 deg, knee 19, pelvis 1.6 cm off the clip.
  `SinewAnimDriver` walk point per direction (walk_b / strafe speeds; against the forward walk a strafe sat between
  strafe and idle and slid). Compare tour `--dir=left|right|back` films from the front for sideways, at the clip's
  own speed. Pitch is measured along the foot's own facing.
- **Turning on the spot / pivot starts** (tour `sinew_turn_review` + `tools/sinew/turn_report.py`: feet distance as
  ankle->toe segments, crossings, torso lag, settle time; a "turn 150 + go" segment): the torso leads -
  `SinewRagdoll.torso_twist` (aim off the hips, unwrapped, clamped 80 deg, damped spring 14 rad/s capped 7 rad/s)
  spread by `SinewPoseModifier` (Spine 0.15, Chest 0.15, UpperChest 0.2, Neck/head 0.5) over whatever pose shows;
  standing, the hips sit `pelvis_follow` 0.5 of the way from the feet's facing to the body's (`Gait::pelvis_turn`).
  Turning steps (`turn_step_yaw`): the foot on the turn's side opens up to `step_turn` 75 deg past the other, the
  other only CLOSES to it (overtaking left the first toed in: the feet met in a V); spots round the body's centre in
  that facing; quicker steps the more there is to turn (`turn_cadence`); a swinging ankle keeps `foot_clear` 16 cm
  from the standing foot's heel..ball segment. Setting off sideways of the feet, the near foot goes first.
  Pivot start (`SinewCharacter._pivot`, third person, offline physical motion, no gun up): the body's facing turns at
  <= `pivot_rate` 400 deg/s eased (the motor snaps it 900 deg/s when moving - it moves along the aim, never the
  facing, so this is presentation), and while it's > 20..90 deg from where it's going the push-off is held to 15 %:
  turn 150 + go = the turn plays over 0.4 s while the speed builds 0.08 -> 0.97 m/s; under `pivot_speed` 0.7 m/s with
  the facing > 0.6 rad off the feet the steps are pivot steps.
- **Stagger fixes**: the gait's last pose stays the target through a stagger (`_gait_frozen`; fading to the clip's
  flat-ground pose lifted the hips' target 14 cm on uneven ground). Standing ankles are torque-capped
  (`Character::set_part_torque_cap`, `BalanceSettings.ankle_cap` 0.75 x weight share x sole lever): the uncapped
  ankle strategy rose a body 15 cm onto tiptoe after a ball on the forearm; s5's hard hit now recovers in 0.45 s,
  no step.
- **Repair pass after the user's test** (tour `sinew_moves_review` + `tools/sinew/moves_report.py [--strips]`: idle
  unarmed / pistol / rifle each next to its "(clip)" twin with the gait off, walk from behind, four diagonals, sprint
  start / turn / 180 flick, walk + sprint reversals, stairs up / down; legs as capsules -> gap / overlap ticks, splay,
  leg speed, steps, hips drop, sink into the ground calibrated by the idle clip):
  * Standing = the clip's stance: the clip's foot transforms go in as the gait's home spots + foot yaws
    (`GaitInput.home_feet`, `SinewRagdoll._clip_feet`, not in the first 0.25 s powered: the tree may not have posed);
    `_turn` / `pelvis_turn` are relative to those yaws; settled on level ground (`_clip_feet_on_ground`) the legs'
    gait weight eases to 0 - the clip itself shows. After `reset` (spawn / teleport) the feet are put straight
    down on the first home given (`_fresh`), never stepped out to it.
  * Directions: the NEAREST directional clip (hysteresis `pick_hysteresis`, `side_bias`: side clips only near pure
    sideways) + residual warp - blending two clips' 2D paths crossed the legs on diagonals; each foot latches the
    clip it lifted with (`_foot_cl`) and its own way of travel (`Foot::path_dir`, turning <= `path_turn_rate`).
    The swing leg is pushed clear of the standing one as capsules (`leg_clear`).
  * Pace = speed + accel x `pace_lead` (a sprint start took full sprint strides round a still body); footholds
    capped at `brake_reach` 0.3 m off the natural one on voluntary changes, the full capture catch only for
    `disturb()` (pushes): reversals lunged 0.64 m. Swing clears the ground under the toes (`swing_clear`, stairs).
  * Pelvis drop: a planted foot beyond 0.98 of the leg is skipped (backing off a ledge sank the hips to 17 cm,
    it steps instead); at a run (> 2 m/s) a planted foot the hips would sink more than `run_drop_max` 6 cm for
    lifts early (`Foot::overreach`) - sinking for the sprint's trailing foot dipped the hips 35-45 cm in five
    ticks. On clip legs the drop changes <= `drop_snap_rate` 1 + `drop_snap_speed` 3 x speed m/s; `max_drop`
    0.35; `drop_fall_clip` 0.4 m/s (hips stayed 30 cm low at the foot of the stairs).
  * A clip's `across` foot offsets are off ITS way of travel (`ClipLegs.angle`, the blend's main clip's), turned
    toward the real travel by <= `across_warp` 1 rad: a foot that lifted standing (forward clip) and was sent
    back-right landed on the wrong side. Feet keep `stance_gap` to their own side on every clip but a side
    step's (braking a sideways walk put the trailing foot 30 cm across behind the leading one).
  * Teleports: the gait resets on any root jump > `teleport_dist` 0.6 m (it only did past 2.5 m: the old
    footholds stepped across); `SinewCharacter.teleport` clears the physical motion (`_motion_vel` walked the
    body on after a respawn).
  * Third person at speed the facing follows the travel and turns slower (`PIVOT_SPRINT_SHARE`): a sprint can't
    spin round on the spot.
- **Ground fit, foot pivots, crossovers** (second user test; tour segments ramps 20 / 30 up + down, strafe L -> back,
  pistol strafe R -> back-left, "chaos walk / sprint" = a seeded stick changing every 0.25-0.7 s; report columns sink
  (heel / ankle / toe tip probed from above) and pivot):
  * `Gait::fit_ground` at every landing: heel / ankle / ball / toe tip + sole sides probed; on one plane (a ramp)
    the foot lies on it (`Foot::ground` tilt, drawn as pitch * tilt * yaw * rest, the roll pivots tilted too) up to
    `ground_tilt_max`; a step edge under the sole slides the foothold along its facing in 2 cm steps (<=
    `tread_fit` 0.25 m) onto one tread, else ankle + ball on the top with the heel / toe tip out over the edge,
    else level on the highest point - never inside a riser.
  * `ground_y` probes from no lower than the body's height: callers pass flattened points (height 0) and a probe
    from 0.6 m above that missed any higher ground (feet came down inside the block at a ramp's top).
  * Stance pivot: a planted foot swivels on its ball (heel when backing) toward the stance facing (standing) or
    its touchdown facing off the legs' frame (moving), <= `pivot_rate` 4 rad/s, <= `pivot_max` 0.6 rad from where
    it landed, with a 0.03 rad dead band (the idle clip's sway kept it swivelling). A pivoted foot may sit
    `pivot_slack` off its standing spot: a 40 deg turn on the spot is a pivot, no step. `feet_home()` (both feet
    within 6 cm / 7 deg of their spots) decides when the standing legs hand back to the clip. Slides are
    measured at the ankle, ball and heel (`plant_ball` / `plant_heel`): the pivot point stays put.
  * A foot that lifted with a crossover side-step clip takes the current clip when the travel turns > 0.8 rad
    away from it (strafing then backing, it landed crossed: thighs through each other); crossover steps land
    >= `cross_sep` 22 cm in front of / behind the other foot; feet keep their sides on every other clip.
- **CI builds only on main** (`.github/workflows/sinew.yml` push branches [main] + workflow_dispatch): every push to
  a working branch cost a full Windows + Linux build and used up the private repo's Actions minutes ("recent
  account payments have failed or your spending limit needs to be increased" = out of minutes). Working
  branches test with a local build; merges get the committed binaries.
- **Moves suite + clip audit** (`tests/suites/s10_sinew_moves.gd`, ~20 s headless, in CI): the moves tour's segments
  (`demo/tours/sinew_moves_segments.gd`, shared with `sinew_moves_review`; "@ramp:<a>:up|down" starts at the slope's
  foot / top edge - the old ramp segments walked flat ground) measured by `SinewMoveMetrics`
  (addons/sinew/sinew_move_metrics.gd: legs as capsules -> gap / overlap ticks, hips drop, sole sink per point calibrated
  on the idle clip, leg speed, air) and held to LIMITS per kind; `KNOWN` holds open problems at today's numbers.
  `S10_DUMP=<label>` prints a segment frame by frame (feet in the body frame, planted flags, gait ankle, sinks).
  `test_clip_audit`: `Gait::clip_report` (binding `character_gait_clip_report`) per reference cycle -> `SinewClipAudit`
  rules + diff against `addons/sinew/clip_audit.json`; `CLIP_AUDIT_WRITE=1` rewrites it after a deliberate change.
- **Direction changes / ramps (this round's lessons)**:
  * `Foot::wrapped`: a foot held up past the cycle's wrap (MIN_SWING_TICKS 4, the uncross hold) lands at the next
    chance. Without it `p >= f.p` held for a WHOLE extra cycle - the foot "in the air" at its target, no support for
    the drive: a walk from standing went 0.87 m in 1.5 s (s0 / s6 caught it; s10 had been tuned on top of the bug).
  * `ground_y` first probes from as high as walkable ground can be (root + d x tan(ground_tilt_max) + 0.35): from
    0.6 m over the body a ray up a 30 deg ramp started INSIDE the slab and read the floor under it (9 cm sink).
  * A swinging foot's drawn toe tip / heel are kept out of the ground (a toe pitched down behind dragged through a
    downhill ramp).
  * Walking, a planted foot the hips would sink > `walk_drop_max` 0.1 m for lifts (overreach) - only with the other
    foot down (else a hop); a cap on the drop alone left the leg short of its foot (a sprint foot slid 40 mm/frame).
  * On a side clip the trailing foot hurries from `side_reach_strafe` 0.2 m out (chaos walk: no overlap, hips 39 ->
    20 cm). A crossover swing (`Foot::side_lift`) that would land crossed once the side step isn't settled waits up to
    UNCROSS_HOLD_TICKS 8, then comes down on its own side. The swing leg push is capped at `leg_push_max` 0.25 m a
    tick (it pushed 0.6 m round the other leg in one tick: 36 m/s).
  * Tried and dropped: far foot first on a strafe start, a quick first step, "never step back from the lift" for side
    steps, a fore/aft detour for a side-changing swing, capping the moving pelvis drop, a sideways acceleration cap
    on the drive (1.6 m/s2: the strafe-left sag 15 -> 13 cm, but backing out of it the legs crossed again).
- **Debug view** (`SinewDebugDraw`, one per SinewRagdoll; action `sinew_debug` = K in project.godot (input as
  data; every F-key is taken), main menu "Show Sinew muscles", `--sinew-debug`): parts as their shapes
  coloured by muscle effort (`Character::muscle_effort` = |Box3D motor torque| / strength; red at 60 %),
  grey = kinematic (animated), dark = cut; bones; COM, capture point, support polygon; label (mode, hardest
  muscle). Cycles off / overlay (no depth test) / x-ray (skeleton meshes hidden). Tour `sinew_debug_review`.
  A new class_name needs `godot --headless --import` before a tour can use it (global class cache).
- Tests: core `sinew_tests` (40; gait: standing, walking, stopping, running, turning, stairs), suites s0 / s2 (kinematic) / s3 (powered: tracking, walking, hit,
  knock-down, death, sever, zombie) / s4 (reach, look, contacts, probes) / s3 also: animated when running / armed, a hit on the gun arm / s5 (stagger recovers, a blow it
  can't take knocks it down, light hits don't stagger) / s6 (no IK on the skeleton, clips play, references
  re-point, a gun still shows) / s7 (gait: cycles, planted feet while walking / sprinting, stairs, off).
  Tours `sinew_review`, `sinew_debug_review`, `sinew_gait_review`.

## Marksman (third controller: Sinew body + rifle / pistol packs; plan `addons/marksman/README.md`)
- `MarksmanCharacter extends SinewCharacter` (addons/marksman/), key `marksman` in `CharacterModels`. Never edits the
  UltraController; Sinew gets only additive hooks (`_new_anim_driver / _new_equipment / _new_ragdoll /
  _default_anim_set`, `SinewRagdoll._gait_states / _gait_upper_weight`) - s0-s10 must stay green.
- **Stance sets** (V1): `MarksmanStanceSet` groups = core gait groups (unarmed / rifle / pistol x stand / crouch;
  prone = clip 8-way). Tables in `tools/marksman/build_stance_sets.gd` -> `addons/marksman/marksman_animset.tres`;
  `MarksmanStance.of_item` (firearm with `fp_ads_eye` = rifle, else pistol; `stats.stance` overrides);
  `MarksmanRagdoll._sync_group` switches over 0.35 s. Read `sinew/ANIMATION_GUIDE.md` "Stance sets" before
  changing a clip. Suite g1 (8 ways x stance x posture, prone sweep, clip audit `addons/marksman/clip_audit.json`,
  draw mid-walk). Tour `marksman_moves_review` (`--only=<stance>`, `--postures=`) + `tools/marksman/contact_sheet.py`.
- A BlendTree node that only names a chain's end must be a pass-through TimeScale: a Blend2 with an input left
  unconnected outputs nothing (crouched still showed the standing pose).
- g1 planted slide = s7's measure plus the BALL (sole under the toe joint): the Toes bone is ~2.6 cm over the sole
  and swings round the ball at push-off (read as 8-10 mm "slides").
- **Feet pivot, never twist** (user: "we can pivot on the spot on the foot if needed, like real life"; read
  `sinew/ANIMATION_GUIDE.md` "Feet pivot, never twist"): g1 `test_feet_pivot_not_twist` (planted foot turning with
  neither ball nor heel held = twist <= 4 deg/frame; swinging foot <= 12 deg/frame; yaw off the foot's SIDEWAYS axis).
  Sinew: `SinewRagdoll.guard_clip_feet` (pose modifier, every frame) - the clip's legs are watched from where they
  stood, the gait re-seated on them (`character_gait_reseat_feet`, feet only), and takes the legs back at once if
  they move (an armed body snapping to the aim, a stance cross-fade); `moved()` resets the gait on the next update.
  Core: `yaw_quat` off the sideways axis, a start at the first foot's own duty, no fresh lift past phase 0.9
  (`LATE_LIFT`), swing phase offset latched (`Foot::off`), swing yaw rate-limited (`swing_turn_rate` 12 / 30 at a
  run, lands facing the way it faces), foothold kept `land_clear` 11 cm off the standing foot. s10 KNOWN: sprint
  flick 180 (legs cross in the air, -3..-11 cm).
- **Hips never jump** (g1, <= 4 cm a frame off the body; were 6-9): `Gait::set_pelvis_offset` (SinewRagdoll feeds the
  clip's hips while the clip holds the legs; eases away 0.25 s after), heel strikes lowered into through the swing,
  drop released at 0.6 + 1.2 x speed m/s, the cycle pose's share at low speed eased (`_step_w`). s10 KNOWN: chaos
  sprint (thigh roots brush < 1 cm).
- **Gun pass (V2)** (`MarksmanGunPass`, a `SinewPoseModifier.passes` entry: procedural passes on `anim_pose` after the
  gait + torso twist, before physics - Sinew's hook, empty for Sinew): aims at where `gun_ray()` meets the world (60 m
  else). Shouldered guns (two-handed + `M_Stock`: rifle, shotgun) are placed gun-first - stock in the right shoulder's
  pocket (`POCKET` off the RightUpperArm joint in the chest's frame), barrel onto the aim point, no cant - and the gun
  hand IK'd onto its grip (the RFP clips' hands held THEIR rifle across the chest, stock past the left shoulder); held-
  out guns (pistol) turn the barrel by spine (<= 0.6 rad) -> gun arm -> wrist (iterated: a close aim point moves with
  each turn). Support hand by two-bone IK on `support_offset` (else the clip's own hand relative to the gun). Weight =
  raised x (1 - gun_low), eased. The rifle stance plays its aim clip (r_aim / rc_aim) when the gun is up. Suite g2
  (barrel <= 1 deg standing / 2 moving, support hand <= 1.5 cm, stock in the pocket <= 3 cm, arms animated), tour
  `marksman_aim_review` (red = barrel line, green = aim ray).
- **Motion matching** (the user's go after a spike; `MarksmanCharacter.motion_matching`, main menu "Marksman: motion
  matching" / `--mm`, Engine meta `marksman_mm`): standing legs are matched clips, the gait stands by. `MarksmanMMDatabase`
  (clips are IN PLACE: ground velocity = the planted foot's slide; per-clip floor = the soles' 5th percentile; features feet
  pos/vel, hips vel, trajectory pos/vel at 0.33/0.67/1 s), `MarksmanMotionMatcher` (SETS per stance - unarmed: Idle_A,
  N_StdWalk2, U_Walk_R + mirrored, Walk_Backwards, U_Run_*, S_Fast; rifle: RFP 8-way walk/run/sprint; picked by their own
  leg gap: U_Walk_L -6 cm, Strafe_Walk_* cross; trajectory = the motor's accelerate_ground run forward; search every 0.1 s
  or on a stick change; the query's pose part uses the BODY's velocity - else an idle playing while the body sets off asks
  for more idle), dead-blended switches (the base `inertial` member, first modifier), rate warp 0.5-1.35. Clip node must
  be a plain AnimationNodeAnimation (a custom timeline froze shorter clips on their last frame). `MarksmanMMPass` (first
  SinewPoseModifier pass): clip floor, direction warp (<= 50 deg, spine turns it back), ground fit (below), foot locks
  (release 0.15 m; a lock pulled out waits for the next plant). Suites `mm` (gait vs MM table), `gm`.
- **Hits and pushes with MM**: a push (`receive_push`) hands the legs to the gait's catching steps (`MarksmanRagdoll.
  stumble_start`; back to MM once caught 0.25 s), trips via Sinew's rule; staggers freeze the matched pose (no search) and
  the pass only lets the feet go. Hits are felt: light ones push the feet (`hit_push_per_impulse`), a leg hit >= 6 N s is
  taken IN the leg (stagger first, the leg knocked and weak: tone 0.7 -> 0.15, 0.5 -> 1.2 s by impulse). Balancer (core):
  steps from ONE planted foot (it waited for both: mid-stride takeovers toppled), seeds contacts for soles already on the
  ground at takeover (`seed_contact`), and a standing leg holds only as well as its tone (`leg_tone`: stance stiffness and
  ankle cap scale with it). Standing still that's the balancer's stagger. MOVING (> 0.8 m/s) a leg hit / staggering blow
  is a stumble the way it's going (`_stumble_hit`: receive_push = the gait's catch steps with the momentum + a lurch along
  the travel, `moving_hit_per_impulse` 0.11 x (1 + 0.4 x speed), x0.4 if the struck leg was swinging (MM contact), <= 4.5
  m/s; the leg still weakened) - the balancer stagger froze the animation in place (the user: "stays in that pose").
  The lurch is NOT scaled by speed and the push's chest jolt is skipped (`_quiet_push`: the shot already struck the part);
  the run command sags only by severity (`MarksmanCharacter.moving_stumble_sag` 0.7 via Sinew's additive
  `_stumble_command_share` hook - Sinew's own rule asks for NOTHING right after a push, so every sprinter tripped);
  a powered knock-down adds only the velocity the body doesn't already have (`MarksmanRagdoll.start`: Sinew added the
  run on top of the moving body - a sprinter shot in the leg flew at 15-21 m/s). gm test_shot_while_sprinting: hips
  <= run + 2.3 m/s; graze runs on, 60 dmg trips 1 in 4.
- **Unarmed arms per clip** (`MarksmanMotionMatcher.CLIP_ARMS`): the U_* walk strafes / runs hold both hands up at the
  chest (0.6 m over the hips); their legs play under borrowed arms (N_StdWalk2 for the strafe walks, LMM_StandardRun for
  the runs) on the mm node's filtered `carms` layer, seeked in step (each clip's left footfall = `left_down` /
  `arms_left_down`, MarksmanMMDatabase._lowest_t). gm test_unarmed_arms_hang_every_way.
- **Rope swing**: the hands on the rope (the climb clip), the legs pump the swing (`MarksmanRopePass`, a pose pass: out
  along the rope's angle 0.25 s ahead, x1.2, -0.55 .. 0.95 rad, like UltraTraversalVisual._rope_legs). A physical hanging
  body was tried and dropped (the user: "looks terrible"). Letting go: `MarksmanCharacter._sync_visual` eases the
  UltraController's rope tilt / 16 cm offset out over 0.3 s (it stood the skeleton up in ONE frame, 1.1 m) and the rope
  node's cross-fades are 0.5 s (the arms came off the grip 17 cm a frame). gm test_rope_legs_pump_the_swing (shown bones
  in the skeleton frame at skeleton_updated), tour `marksman_rope_review`.
- **Limp in every direction**: `MarksmanMMPass._limp` - while the hurt leg carries the weight the trunk leans out over it
  (`LIMP_LEAN` 0.26 rad x damage) and the hips dip (5 cm), the swinging bad knee is straightened by 55 % x damage - on top
  of the forward / back limp clips, alone sideways (no sideways limp clips: a hurt strafe was a slow plain walk). The
  limp CLIP layer only shows a moving limp clip going the walk's way (the matcher's injured idle under a strafe was 19 cm of
  lurch at 70 %). gm test_limp_in_stages: forward 6.7 / 13.3 / 31 cm at 70 / 55 / 25 %, strafe 7.8 / 8.3 / 14.7.
- **Pistol at the hip** (`MarksmanGunPass._hold_out`): placed gun-first - the gun hand at `PISTOL_HIP` (0.13 right, 0.22
  down, 0.45 ahead of the eye along the view), barrel onto the aim point, arm by IK. The PST clips hold it up in front of
  the face: in first person it covered the view (17-19 deg above the centre; now 7-9 below). g3 test_hip_gun_clears_the_view.
- **Foot IK (ground fit)**: each foot onto the ground under its ankle / ball (higher of the two), followed (rise 3.5, fall
  2 m/s); hips down only as far as a leg can't reach (`REACH` 0.97); planted soles tilt to the surface (<= 28 deg). Leg IK
  swings the knee WITH the leg onto the new hip->foot line, plus the thigh's forward only when the knee is nearly straight
  (a fixed forward pull crossed the rifle stance's out-turned knees; the old offset against a far-moved line flipped knees).
- **Ledges**: climb-downs only crouched (or crouch pressed) - `_traversal_hook` vetoes the down moves standing (restores the
  state copy); standing at a lip a planted foot's ball is drawn back onto solid ground (the lock follows it); the tick the
  capsule leaves the ground from a ground state over a drop >= `ledge_height` (0.6 m; lower = a plain step down, and
  the lip rule uses it too, measured from the foot's own ground, only for a body standing still), Sinew takes the body (`over_edge` -> stagger, kept
  powered in the air by Sinew's additive `_powered_in_air` hook) - it lands and recovers or falls. ONLY AN ACCIDENT
  (user): going off with the stick and the motion within 90 deg of the facing is on purpose - a plain drop
  (`_walking_off`); backing / side-stepping / shoved / drifting off is Sinew's, tipped INTO the drop (`over_edge(dir)`:
  `over_edge_tip` 1.1 m/s, pelvis 40 %). Taken over in the air, the balancer gets the STANDING target height
  (`_standing_target`): measured in the air (COM 1.9 m over the floor below) every landing "sank" and went down.
- **Jumps / landings**: `MarksmanCharacter.landing` = `motor.predict_impact` each falling tick; the air node blends the
  legs (filtered) to Jump_Land's first frame (legs long, feet down; the air clip tucks them 40 cm up) over the last 0.4 s
  (`legs_ready`); the land node squats by impact (`depth`: idle <-> Jump_Land, 2 .. 10 m/s); under MM a landing faster
  than 1.2 m/s along the ground stays matched (runs on). Landing >= `land_brace_speed` 7 m/s (a hop is ~5.6): the body is
  powered 0.1 s before touchdown (`land_brace`, once: re-arming it reset the pose every tick) with the fall's velocity,
  the upper body physical for `land_window` 0.8 s at tone 0.75 .. 0.4 (it carries on into the stop, the muscles catch it),
  legs on the clip; >= `land_stagger_speed` 11.5 (~4 m) the balancer has the legs (may go down). A 2 m jump down lands on
  its feet; the motor's hard landing (> 15.5) stays the limp ragdoll. gm test_jumps_and_landings.
- **Gaps**: `MarksmanCharacter._cross_gaps` scans ahead along the travel; a gap (ground back within 0.25 m) no wider than the
  span (0.9 m walking .. 1.8 m sprinting) is crossed held at the edges' height; the fit pass keeps feet level over it and
  lands planted feet on the nearer edge. Playground: GAP WALK (0.4 / 0.7 / 1.0 / 1.4 m, marker `gap_walk`), SPRINT TRACK
  (a `Sprinter` dummy: `UltraDummyPost.sprint_loop`, steered corner to corner), animation gallery square grid + floor sized
  to every clip at load (suite `pg`).
- **Firing / reloading (V4, MarksmanGunPass)**: the shot through the body - the base `_recoil` spring (the fire event's
  kick, gun frame, m) rocks the spine back (`ROCK` 2.4 rad/m, <= 0.25) BEFORE the gun is placed, then pushes the gun back
  and flips the muzzle up round the hand (`FLIP` 1.8 rad/m, <= 0.22), arms by IK (rifle 2.6 cm / 1.7 deg / chest 0.7 cm,
  shotgun 13 cm / 8.8 / 3.4). Reloads keep the gun in the hands (`raised()` is 0 while RELOADING: it used to drop to the
  stance clip and the magazine just blinked): `_reload_pose` brings it in and rolls it to the left hand (long 22 deg,
  pistol 32 + to the middle), `_reload_hand` = UltraEquipmentVisual's magazine / shell paths on the sim clock (action_t,
  reload_commit, shell_time) for the LEFT ARM'S IK in the pass (Marksman has no hand IK: the base paths never ran);
  the magazine node is placed through the base's `_mag_hand` / `_mag_hidden`; `_left_hand(fingers, palm, contact)`
  builds any left-hand grip. Suite g4 (CI): kick + recovery, reloads by hand (magazine 56-74 cm off the gun in the
  hand, support back on after), lean, wall tuck. Tests give reserve ammo (no playground infinite ammo without main).
- **Lean (V4b)**: `MarksmanGunPass._lean` bends Spine / Chest / UpperChest about the VIEW's way (a bladed rifle stance
  turns the chest 35 deg: about the body's forward it was lopsided) until the eye is `LEAN_OUT` 0.28 m out (bend, measure,
  correct once); unarmed too. MarksmanEye zeroes the camera rig's own lean offset (it came on top). Shots follow through
  aim_from (with a rifle up the head - the camera - sits 24 cm right of the capsule, over the stock).
- **Wall tuck (V4b)**: `MarksmanCharacter.tuck_distance` (sim: a ray from the shoulder along gun_dir for `gun_reach` -
  stat "tuck_length", long 0.75 / else 0.45 m) - `simulate` strips B_PRIMARY from a COPY of the input when tucked
  (deterministic, the UltraController has no fire hook); the pass raises the muzzle 55 / 40 deg round the hand and draws
  it in by how far the gun would go into the wall (full at 25 cm), ADS off meanwhile.
- **Turning on the spot (MM)**: per-stance turn clips (`MarksmanAnimDriver.MK_TURNS`: unarmed / pistol T_StandL90 / R90,
  crouched T_CrouchB, rifle stance RFP_Turn90 / CrouchingTurn90, one-handed melee AXE_StandingTurn, limping the INJ
  turns mirrored per bad leg), registered as roles, in place (UltraAnimDriver._turn_clip) on the mm node's filtered
  (legs + hips) Blend3 `turn`, SEEKED by how far the body has turned since the feet were left (`_mk_feet_yaw`, start at
  0.35 rad; chained at once past a clip's 90; stopped, the clip plays on so the feet catch up). Foot locks
  (MarksmanMMPass._foot): off while a turn steps (a turn clip's foot is "down" by its ankle height), on at the shown
  feet as it fades (release 0.45 m), an idle's feet always planted, and a foot waiting for a lift re-locks once its
  release glide is done on an idle (the pistol idle never lifts: its feet stayed unlocked and turned with the body).
  Released feet going > 6 cm are stepped on an arc, not slid. gm test_turning_on_the_spot_steps (skating 0-2 cm, was
  0.75-1 m). A gait handover for turns was tried first (Sinew's turn steps): 0.13-0.31 m of skating, dropped for clips.
- **Side run**: sprint held with the stick sideways / back (standing) = the jog gait that tick (`MarksmanCharacter.
  side_run_wanted` - simulate sets `profile.default_gait` around super.simulate, the matcher's prediction too): ~3.4 m/s
  on the run strafes (pistol set + U_Run_L / R). gm test_side_run.
- **Long guns at the hip**: the stock >= `HIP_LONG` (0.10 m right, 0.07 below) off the EYE along the view (the user:
  "on the right a bit more"; standing the rifle clip leaned the head over the stock: off the pocket it sat mid-view);
  ADS works from there. g3: rifle / shotgun middle 16-25 deg right.
- **Get-ups** (MarksmanRagdoll._decide_getup / MarksmanAnimDriver._go): face up / down by the BELLY (pelvis + chest; the
  chest alone at -0.2 sent side-lying bodies into the face-up clip: they rolled over); `GETUPS` up = LayToIdle, down =
  GetUp_Prone 1.4-5.3 / StandUp_Stomach 3.0-8.2 (only the rise, over get_up_time), picked by hash; yaw corrected by each
  clip's lying head heading. GetUp_Back / GetUp_Stomach end turned 50-57 deg, ZN_ZombieStandUp rolls over: unused.
  Single player the character TAKES the clip's facing at the get-up (`_face_getup`: body_yaw = getup_yaw, ragdoll_yaw
  0 - it eased back to the old facing over the clip: the body pivoted on the ground) and the aim eases round by the same
  angle (`MarksmanCharacter.aim_turn_left`, 2.8 rad/s; mouse input on top). gm test_get_up_the_way_it_lies.
- **Limp clips**: + INJ_InjuredRunBackwards (mirrored like the walk back); INJ_InjuredWalk / WalkBackwards are the same as
  Injured_Walk / _Back; no injured strafes exist (sideways = the procedural limp).
- Ball launcher from a Marksman: gm test_ball_launcher_works (fires, knocks the target, not the shooter).
- **Gore under Sinew**: a cut-off part is physics in Sinew (it drops), but the SKELETON keeps its bone on its parent as
  animated (`SinewRagdoll.part_cut`, `SinewPoseModifier`): the gore system hides it and throws its own gib. Posed on the
  falling piece, the stump's rim (skinned partly to the cut bone) stretched across the body (78 cm; s2
  test_a_cut_limb_leaves_the_sinew_body). Tour `gore_review --controller=marksman --mm` vs `--controller=ultra`.
- Lean with the head up at the hip: `_head_up_at_hip` fades out with the lean and `_lean_settle` (after the gun is placed)
  bends the rest so the eye ends LEAN_OUT from where it stands at the hip (`_hip_shift`, measured unleaned).
- Godot's `Quaternion.get_axis()` / `Vector3.slerp` on near-parallel vectors give a non-unit axis ("The axis ... must be
  normalized" floods): normalise the axis / lerp + normalize (MarksmanMMPass._ground_fit).
- **Hold breath (V4b)**: sprint held while aiming down sights, standing still (Sandstorm's way; no new input) =
  `MarksmanCharacter.holding_breath`: the free-aim offset (state.sway / sway_v) settles toward the aim (`HOLD_CALM` 16/s,
  not on a tick with fire_cd running: the kick stays) for `HOLD_TIME` 5 s, drawn from the SWIMMING breath
  (MotorState.breath: the HUD's breath bar shows it; floor 5 % - at 0 the motor drowns you); run out ->
  `F_BREATH_OUT` (1 << 12): a tremor off the sway clock until half the breath is back. Sim, so in replays too.
  g4 test_hold_breath: ADS 0.063 deg -> held 0.017, out of breath 0.63, back after ~2 s.
- **Empty reloads (V4b)**: a magazine reload begun on an empty magazine sets `F_EMPTY_RELOAD` (1 << 13) and runs slower
  UP TO the commit only (`empty_stretch` = (commit + EMPTY_RACK 0.6) / commit; UltraActionLayer._reload finds the commit
  by `action_t - dt < commit` - slowed past it, it fired every tick); on its real clock MarksmanGunPass plays the swap,
  then `_rack`: the left hand over the ChargingHandle (carbine) / Slide (pistol), pulled back RACK_PULL 7 cm along the
  gun, let go (slide sound), back on the grip; the round counts after. g4 test_empty_reload_racks (+0.6 s, filled once).
  Marksman's flag bits: 12, 13 (MotorState flags are a u16: 14, 15 left).
- **Freelook (V4b)**: `marksman_freelook` (H - Alt is walk) held in first person: `MarksmanFreelook` (made by
  MarksmanEye, physics priority -100 = before UltraNet samples the input, process 99 = before the rig) holds the input
  source's live aim still and takes the mouse's turn into `offset` (<= 1.3 / 0.7 rad); MarksmanEye turns the CAMERA by it
  (fp_view - the gun's - keeps the aim), the gun pass turns the neck (the head's part) last (`_look_about`); let go, it
  eases back (9/s). Presentation only: shots never move. g4 test_freelook_turns_the_head_not_the_aim. Tour
  `marksman_gunfeel_review` (empty reloads close up, freelook; tours wait on physics ticks - frame grabs under xvfb are
  slow and a wall-clock tour shot everything in 30 frames).
- **Hits with a gun up (V5)**: whatever holds the gun stays animated (`MarksmanRagdoll.armed_hold`: gun pass weight > 0.5):
  Sinew's additive `_part_wants_physics(i, want)` hook keeps the arm parts kinematic even through a stagger, and
  `_hit_chain` drops them. A body / head hit: spine / neck / head physical, the arms RIDE on the chest
  (`MarksmanGunPass._carry_arms`: shown chest x animated chest^-1 x animated arm) - the gun rocks off the aim ~25 deg and
  is back in 0.4 s. An arm hit is a sprung kick in the gun pass (`arm_hit`: the gun arm's moves the gun along the hit and
  turns it KICK_TURN rad/m - ~9 deg at 25 points, back in 0.2 s; the support arm's knocks the hand off the grip, x3, up to
  SUPPORT_KICK_MAX). A physical arm was tried: switched on it sagged ~free fall (23 cm in 0.18 s whatever the push or
  tone) and kept a ~12 deg wrist error while physical: the barrel stayed 10-14 deg off for a second.
  After physics, Sinew's additive `SinewPoseModifier.post_passes` hook (empty for Sinew) runs `MarksmanGunPass.apply_post`:
  the support hand two-bone IK'd onto the gun AS SHOWN; knocked further than LET_GO 14 cm it lets go (grip_w eases to
  0), takes hold again within REGRIP 7 cm over 0.18 s. Hits in tests need `react_to_hit` called by hand (UltraEffects
  calls it on every machine; a test scene has none). Suite g5 (CI).
- **Arms out of the body** (the user: "we don't really want the arms to clip into the body"): (1) every arm IK in the gun
  pass puts the elbow down and OUT (`_elbow_hint` in `_two_bone`: chest frame, gun arm ELBOW_OUT_GUN 1.3, support 0.7,
  ELBOW_KEEP 0.1 of the clip's own side) - the RFP clips hold their rifle across the chest and kept, the gun arm's elbow
  pointed in across the belly; (2) last in `apply_post` (after physics + the support hand) `MarksmanArmClear`:
  UltraArmClear's torso ellipse + keep-hands swing round the shoulder -> wrist line (hands stay on the gun) - a kicked gun
  drove the forearm 7-8 cm in; (3) the pistol stays 13 cm right of the eye (18 cost the barrel 0.45 deg aiming low crouched: g2).
  g6 (CI): elbow / forearm / hand depth <= 2 cm, the upper arm no deeper than its own shoulder (the ellipse is wider than
  the body at the shoulders: the joint reads 2-6 cm "in" in every pose, unarmed idle too), elbow_out >= 1.15. Tour
  `marksman_gunfeel_review -- --arms` films pistol / rifle hip + ADS from above, the side and the front.
  Racking an empty long gun, the gun comes out off the shoulder (`RACK_OUT` 14 cm forward, `_rack_w` eased round the
  rack): shouldered, the charging handle sat in front of the chest and the left hand went 7.9 cm into it.
  (`UltraItems.give(c, id, n)` gives n ROUNDS - one by default: give tests a reserve, a lone suite has no infinite ammo.)
