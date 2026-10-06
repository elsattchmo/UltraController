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
  4. `--script res://demo/maps/playground/build_playground.gd`

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
  * `InertialBlendModifier` (first modifier): trigger() opens a 4-frame WINDOW in which a jump
    in the incoming pose is looked for (trigger() from _process lands a frame before the tree
    changes the pose); never detects on its own - fast motion inside a clip (roll, jump) is
    real. Restart: offset to where the output was heading, decaying from REST on a critically
    damped spring (half-life 0.11 s). Giving the offset the old velocity ADDED it to the new
    clip's motion (legs flung twice as far in a roll) - don't. No end-of-stack smoothing pass:
    it fought the IK (feet through floors, hands off rungs).
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
  the head (`sever` event carries the hit kind) bursts it: `spawn_gib(head, dir, 9, 7.0)` splits
  its triangles into chunks round its middle (Fibonacci directions), each with a flesh blob,
  thrown out with a red mist. MAX_GIBS 32.
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
- Stumps / cut ends (UltraWoundMesh.stump): ragged domed meat (cellular-noise albedo + normal
  map, wet), a thin skin / fat rim, bone(s) out of it with marrow (2 for forearm / shin), torn
  flaps - on the body (`_make_cap`) and on the part that flew off (`spawn_gib` -> `_make_gib`).
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
