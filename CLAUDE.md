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
- **Damage is per region** (`UltraLimbs`: 10 regions). `limb_hp` (percent) and the `severed`
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
  RAGDOLL keeping its speed (air drag 0.3 m/s2); rope catches are untouched. At touchdown 20 %
  of the landing speed (<= 3.5 m/s) goes into the slide along the travel
  (`ragdoll_state.TUMBLE_*`) and the physics body gets a forward roll (`UltraRagdoll._tumble`,
  only if land_impact >= 6); its settle / tone / capsule-pull clocks start at touchdown (`_t`),
  not when it went limp (`_t_limp`). No landing roll (the user didn't want it): LAND keeps
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
