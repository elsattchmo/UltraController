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
  Hands on rope/ledge are presentation (`UltraTraversalVisual`, IK priority 111 > equipment 110).
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
  from region capsules baked into the BodyProfile (`tools/make_hitboxes.gd`) - no skeleton on the
  server. Shots test a wide `HitVolume` (HITBOX layer), then must pass through a limb capsule.
- Knock-down is a deterministic low capsule (RAGDOLL -> GET_UP states); the floppy body is a
  local `PhysicalBoneSimulator3D` (UltraRagdoll). An inactive simulator still writes the pose:
  keep `influence = 0` while it's off. Dismemberment scales the region's root bone to ~0 in the
  last modifier (`DismemberModifier`, must stay after the simulator), caps it, and spawns a gib
  skinned on the CPU from the region's triangles.
- Upper-body item clips can be mirrored at runtime (`UltraAnimMirror`; the skeleton is mirror
  symmetric). `BodyDynamicsModifier.item_hips_yaw` turns the spine by the item clip's own hips
  yaw so a mirrored clip isn't twisted by unmirrored legs.
- FP eye: follows the head's yaw only, never its pitch (pitch swung the eye out in front of the
  body exactly when looking down at it).
- Modified bone poses are only readable during `skeleton_updated` (tests: sample there).
- Gait: `MovementProfile.default_gait` WALK (default: full input = walk 1.35 m/s, Shift =
  sprint) or JOG. The blend space has a "walk_brisk" point (the walk cycle at 1.75x) so walk
  speeds never pull in the jog's 2.8 m stride. Hips warp toward travel from ~1.35 m/s.
- Stepping down a stair keeps you grounded (`UltraMotor._snap_down`, a ray under the capsule's
  centre); the fall clip waits 0.15 s of real air before showing.
- Hard landings (> hard_land_speed) crumple into RAGDOLL and get up; Land_Three_Point is unused.
- Pistol grip is fitted to the posed fingers (`UltraGripFit`, run by tools/build_items.gd);
  the reload plays as authored in third person; in first person both hands' clip motion is
  shifted out in front of the eye by IK (`_drive_reload`). Don't IK the gun to a fixed pose.
- Head stabiliser (`BodyDynamicsModifier.head_stabilize`): removes most of the clip's own fast
  head yaw swing (jog/sprint whip the head ~30-50 deg); hip side-sway damped at speed.
- Water waves: `UltraWater.wave(p)` (shared clock `wave_time`, global shader uniform
  `ultra_wave_time`) move the surface mesh and float props (`set_meta("buoyancy", k)` tunes how
  deep a prop sits). Swimmers don't collide with loose props (prediction-safe).
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
- Turn_* clips do not rotate (feet step in place); the motor turns the body procedurally.
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
- Tools that touch autoload-dependent scripts run through `res://tools/tool_runner.tscn -- --tool=...`
  (a `--script` SceneTree has no autoloads). Builders: build_items.gd, build_playground.gd, intake.gd.
