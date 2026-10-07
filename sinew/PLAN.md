# Sinew — a modular Euphoria-style active-physics character engine

## Context
UltraController's bodies are animated, and the ragdoll only takes over once a character is
already down. `UltraRagdoll` is a local `PhysicalBoneSimulator3D`: it drives toward fixed poses
(the pose at knock-down and a Death_A brace pose), never toward live animation. It enforces
joint limits by hand because Jolt ignores them, keeps the bodies of severed limbs, and has no
balance, stepping or behaviours. Hit reactions are an upper-body one-shot plus flinch springs.

The goal is GTA IV's euphoria (NaturalMotion): a physical body with muscles that tracks
animation when it can and fights to stay up when it can't. It should stagger, step, brace,
protect its head, grab its wounds, windmill at edges, writhe and crawl after losing limbs. It
must work on our own models, carry the existing dismemberment and damage, run in Godot first,
and be portable to other engines.

**Hard rules from the user**
- The existing player controller is untouched: `UltraCharacter`, motor, states, AnimDriver,
  modifiers, ragdoll, BodyFX, CutBody, UltraNet. Sinew lives in its own module with its own
  test character.
- Existing code is only *read* and reused: assets, the bone maps, the `*_cuts.glb` piece sets,
  `DamageInfo` and `UltraLimbs` enums, the test harness.
- The only edits outside the new module are additive and in the demo shell, not the
  controller:
  - a character picker in `demo/main.gd` and `demo/ui/main_menu.gd`;
  - `CLAUDE.md` notes.
- Single player first. Split screen and networking come later.

## Architecture: three layers, one portable core
```
sinew/                      engine-agnostic C++17 core (no Godot types), CMake, doctest
  core/physics/             Box3D wrapper (bodies, joints, muscles-as-motors, world mirror)
  extern/box3d/             Box3D submodule (MIT), pinned commit
  core/rig/                 rig description, humanoid builder, mass tables, capsule fitting
  core/control/             muscles (stable PD), gravity/inverse-dynamics feed-forward, IK effectors
  core/balance/             COM, support polygon, capture point, step planner
  core/behaviours/          behaviour framework + euphoria behaviour set
  core/perception/          contact sensing, environment probes, impact prediction
  capi/sinew.h              flat C API (handles + POD structs): Unity P/Invoke / Unreal / others
  tests/                    doctest unit + scenario tests, benchmarks (run headless, no engine)
bindings/godot/             godot-cpp GDExtension -> addons/sinew/bin/
addons/sinew/               GDScript side: nodes, rig resources, editor tool, debug draw
addons/sinew/sinew_character.gd  SinewCharacter (extends UltraCharacter, no edits to it)
```

### Language and physics: C++17 core on Box3D (evaluated and chosen)
- **C++17 core.** It is the most portable choice: a GDExtension for Godot, a C API for Unity's
  P/Invoke, native for Unreal. GDScript is too slow to run muscles with substeps across 20+
  characters.
- **Physics is Box3D** (Erin Catto, MIT, C). It is vendored as a git submodule pinned to a
  known-good commit, because Box3D is still an alpha. I checked it before choosing it:
  - Cloned at commit `Tree perf (#179)`, built with gcc 13, and all of its unit tests pass.
  - Its spherical joint has a **cone limit plus twist limits**, a **spring to a target
    rotation** (in hertz and damping ratio, mass-normalised, clamped for stability), and a
    **motor with a max torque**.
  - Its revolute joint has limits, a spring to a target angle, and a motor.
  - The solver is soft-step with substeps, which is stable with stiff springs and is the same
    approach as Box2D v3.
  - It has capsule, hull, mesh, heightfield and compound shapes, and sensors.
  - It is **cross-platform deterministic** by design, and its determinism test is falling
    ragdolls.
  - It has recording and replay, which we will use for regression tests, and it is
    multithreaded through task callbacks.
  - Unity, Unreal and Godot bindings already exist, which shows it ports.
- **Why not Jolt (Godot's physics):** this repo already probed that Jolt ignores
  `PhysicalBone3D` joint limits. Every engine's joints also differ. With Box3D inside the core,
  one rig behaves the same in every engine.
- **Muscles on Box3D.** Each joint is a velocity-servo PD: the motor's target velocity is the
  pose error over a time constant and its max torque is the muscle's strength (as Jolt's
  `DriveToPoseUsingMotors` does).
  - The spring to the target rotation adds passive compliance.
  - Strength, stiffness and damping are set per joint each tick. Weakening, relaxing and
    injuries are all parameter changes.
  - Gravity compensation and feed-forward torques are computed by Sinew from the rig
    (Jacobian-transpose over each joint's subtree mass) and applied with `b3Body_ApplyTorque`.
- **Known risks and mitigations.**
  - A maximal-coordinate solver can stretch joints under extreme loads. Mitigations: 4-8
    substeps, minimum part masses (hand and torso ratio ≤ 1:12), inertia scaling on small
    parts, and tests that fail if any joint separates by more than 5 mm.
  - Alpha API churn: pin the commit; Sinew wraps all Box3D calls in one `physics/` module.
  - If a blocker shows up in S1, the fallback is our own reduced-coordinate solver behind the
    same `physics/` interface.
- **Self-collision** uses Box3D filters (adjacent parts excluded). **Topology changes:**
  severing destroys the joint, so the subtree becomes a free body group, and mass, COM and
  limbs update. There is no rebuild quirk.
- **Budget:** ≤ 0.15 ms per 20-body character per 60 Hz tick, with Box3D's own threads.
- **World mirror** (`sinew::WorldMirror`, filled by each engine binding):
  - The host's static colliders are copied into the Sinew Box3D world (box, sphere, capsule,
    convex, concave mesh, heightmap) at level load and whenever they change. The mansion's
    BoxList and the playground's statics are mostly boxes.
  - Host dynamic bodies (props, doors, platforms) become kinematic Box3D proxies following the
    host every tick.
  - Contact impulses on proxies are handed back so the host can push the prop
    (`apply_impulse`).
  - Bullets and gameplay raycasts keep using the host: Sinew parts publish hitbox proxies.

### Control layers (mirrors NaturalMotion's structure)
1. **Muscles.** Every joint has a target rotation, stiffness, damping and strength (a torque
   cap). Its health scales its strength.
   - Target sources: the animation pose, procedural control, or a per-limb weighted blend of
     both.
   - Gravity compensation plus inverse-dynamics feed-forward lets low-stiffness ("relaxed")
     bodies still follow animation. This gives the "true body movement" look instead of a
     stiff servo.
2. **Limbs (limb awareness).** Each `Limb` covers an arm, leg, spine or neck. It knows its
   root and end-effector state, contacts, health and attached/severed status, and its reach
   envelope.
   - Effectors: reach a hand to a world point, plant or place a foot, lean the spine, look
     with the head (analytic two-bone IK and spine distribution in the core).
3. **Balance.** COM and COM velocity, a support polygon from the feet in contact, and the
   instantaneous capture point.
   - Ankle, hip and step strategies; the step planner times and places steps and IKs the
     swing leg.
   - Gives up when the capture point is out of reach (that becomes a fall).
   - No hand-of-god upright torque, except an optional, documented `assist` parameter
     (default 0).
4. **Behaviours.** Modules with start/stop/parameter messages, a priority, and a request for
   limbs with weights. An arbiter blends their limb outputs, as euphoria's NM messages did.
   - Set A: `BodyBalance`, `Stagger`, `ShotReaction` (flinch toward the shot, reach for the
     wound, stagger by impulse), `BraceForImpact`/`CatchFall` (arms out, knees soften, roll),
     `ProtectHead`, `ArmsWindmill` + `Teeter` (edges), `HighFall` (windmill, pedal, brace),
     `Stumble`, `RollDownStairs`, `Writhe`, `InjuredOnGround`, `Crawl` (any surviving limbs),
     `Dying`, `Relax`.
   - Set B (later): `Grab` (ledges, rails, other characters), `Yanked`, `Electrocute`,
     `PointGun`, `BalancerCollisionReaction`, `Flinch`.
5. **Perception.**
   - Contact events per part.
   - Probes: ground ahead and below, walls within reach, edges to grab, stairs.
   - Impact prediction from the ballistic path, which feeds brace timing.

### Character modes (per character, with seamless transitions; always on near the camera)
- `ANIMATED`: animation drives the skeleton. The physical body follows kinematically so hits
  register on it. This is the cheapest mode.
- `POWERED`: physics tracks the animation through the muscles and the balancer is on. Pushes
  and shots perturb the body for real and it recovers. It is used near the camera or player.
- `ACTIVE`: behaviours own the body (falls, writhing, crawling).
- `GET_UP`: the lying pose is matched against get-up clip frames (orientation, limb
  configuration), and the closest clip and frame start. Physics blends into it, then hands
  back to `ANIMATED`/`POWERED`.
- Physics LOD drops distant characters to `ANIMATED`, or puts them to sleep.

### Rigs: putting our models on it
- **Humanoid auto-builder.** It takes a skeleton retargeted to `SkeletonProfileHumanoid`
  (the repo's import already does this for the mannequin, Mixamo and UE through
  `addons/ultra_controller/import/bone_maps/*`). It produces:
  - capsules fitted to the mesh vertices weighted to each bone;
  - de Leva segment-mass fractions scaled to the total mass;
  - default joint limits and strengths;
  - Limb and region tags.
- **Region mapping.** The builder reads the region tables in
  `addons/ultra_controller/damage/limbs.gd` (`UltraLimbs.BONES`/`BELOW`). This lets the
  14 damage regions map onto sinew parts.
- **Data.** The result is a `SinewRig` resource, editable in the inspector, plus an
  editor-tool button ("Build Sinew rig" from a character scene). The rig serializes to JSON
  for other engines.
- **First rigs:** `mannequin.glb` (Quaternius) and `zombie.glb` (Mixamo Romero).

### Damage and dismemberment
- Per-part muscle health weakens the joints below a wound. Behaviours read limb health:
  - a limp from a weak leg;
  - a dropped arm that can't brace;
  - a shot leg buckles into a stagger.
- `sever(region)` splits the articulation at the region's root joint and returns the free
  piece (a physical gib that keeps its muscles twitching briefly).
  - The body's mass, COM, support set and limb availability update.
  - Behaviours adapt: one leg gone means it falls and crawls with its arms; both legs gone
    means it crawls and drags itself by its arms; one arm gone means it braces with the other
    side; `halve` splits at the waist and the upper half crawls.
- **Visuals** reuse the existing pre-cut piece files (`assets/characters/*/…_cuts.glb`:
  `Seg_*`, `Cap_*`, `Chunk_HEAD_*`). `UltraCutBody` takes an `UltraCharacter`, so a small
  `SinewCutBody` in `addons/sinew/` follows its logic: rebind pieces by bone name, show
  stumps. `cut_body.gd` itself is left alone.
- Damage input is the existing `DamageInfo` class, used read-only (kind, region, dir, point,
  shove, dist).

### Godot binding
- `SinewWorld` is a Node with one per scene: it owns the core world, steps at the physics
  tick and does the host queries.
- `SinewBody` is a `SkeletonModifier3D` placed last in its skeleton's modifier stack:
  - its input is the animated pose;
  - its output is the physics pose, blended by mode;
  - it maintains hitbox proxy shapes (an Area/hitbox layer) for raycasts.
- Signals: `contact`, `limb_severed`, `fell`, `settled`, `behaviour_started/ended`.
- GDScript API: `send(behaviour, params)`, `apply_hit(DamageInfo)`, `set_mode()`,
  `sever(region)`.

## Testing in the existing levels, with a character picker in the main menu (single player)
- **Test scene:** the existing playground and mansion. The dummy yard, range, stairs, ledges,
  water, props and zombies already cover the test cases. No new level.
- **New character, a subclass and not an edit:**
  `addons/sinew/sinew_character.gd`, `class_name SinewCharacter extends UltraCharacter`.
  - It inherits movement, weapons, input, net and the HUD unchanged.
  - After the base builds its visuals, it removes the `UltraRagdoll` node it was given and
    puts a `SinewBody` last in the skeleton's modifier stack.
  - It overrides `react_to_hit` and listens to the existing `hit`/`sever`/`halve` events.
  - `ultra_character.gd` itself is never edited. Its `ragdoll` member is left null-safe; if
    some base code path needs it, S2 adds a no-op stand-in.
  - **Physics vs gameplay state:** stage 1 keeps the motor's deterministic capsule (RAGDOLL /
    GET_UP / DEAD states). Sinew is the body you see, and it stays near the capsule.
  - **Single-player only, later:** a `physics_drives_capsule` option lets the Sinew body's
    balance decide falls and recoveries; the capsule then follows the pelvis.
- **Main menu "Character" section.** It sits next to the existing "Level" toggles and uses
  the same pattern: lists in `demo/main.gd` and `_build_characters` in
  `demo/ui/main_menu.gd`. It has two rows of toggles:
  - **Controller:** "UltraController (current)" (the default, identical to today) or
    "Sinew".
  - **Model:** "Mannequin" or "Zombie (Romero)". Later imports register here as a
    `{key, title, body_profile, sinew_rig}` entry.
  - `main._make_character` builds the chosen class with the chosen BodyProfile for local
    players only. Dummies and zombies stay as they are; a toggle for them is a later
    option.
  - The choices are kept in `Engine` meta, like `ultra_level`, so Pause > Main menu keeps them.
    `--controller=sinew --model=zombie` does the same for tours and tests.
  - Single player first. Split screen comes next, with one choice per player.
  - Playing UltraController as the zombie model needs a FULL-tier body profile for the zombie.
    If that turns out to need controller changes, the zombie model is offered with Sinew
    only.
- **Sinew console** (F1, any level):
  - pick a character and a behaviour and fire it with parameters;
  - muscle, strength and balancer sliders;
  - slow-mo and pause/step;
  - draw COM, support polygon, capture point, contacts, muscle targets and limb health;
  - record/replay.
- Split screen and networking are a later stage. The plan for networking is that the
  deterministic gameplay state stays authoritative, and Sinew reactions are presentation
  triggered by the replicated hit, sever and halve events.

## Milestones (each ends green on its tests and committed)
1. **S0 scaffold:**
   - CMake core, doctest, the Box3D submodule, and a godot-cpp GDExtension that loads in
     4.7.1.
   - A C API stub.
   - GitHub Actions builds the Windows (MSVC) and Linux binaries on every push and **commits
     them to `addons/sinew/bin/`**, so you just pull and run Godot.
   - The menu's Controller and Model picker, with `SinewCharacter` (a plain ragdoll stand-in
     at this stage) spawning in the playground.
2. **S1 physics core on Box3D:**
   - Box3D wrapper, ragdoll from a rig, cone/twist and hinge limits, motor-PD muscles with
     torque caps, gravity compensation, self-collision filter, world mirror;
   - tests: joint separation < 5 mm under hard impacts, limits never exceeded by > 2°,
     bit-identical replays, a muscled standing pose held without balance help, sever
     mid-sim;
   - a benchmark of 30 characters.
3. **S2 rigs and Godot binding:** humanoid builder, `SinewRig`, `SinewBody` modifier, hitbox
   proxies. Playing as Sinew with either model, you fall and ragdoll on Box3D in the
   playground.
4. **S3 animation tracking:** POWERED mode with feed-forward, per-limb masks, and get-up pose
   matching. Tracking error tests while walking or running.
5. **S4 limbs and perception:** IK effectors, probes, contact awareness.
6. **S5 balance:** capture-point balancer and stepping, Stagger, Stumble, Teeter. Push tests
   check that a push up to X N·s is recovered within N steps and a bigger push falls.
7. **S6 behaviours:** framework and Set A, each with a scenario test (for example: shot in
   the thigh while walking leads to a stagger, the hand reaches the wound, and it recovers or
   falls).
8. **S7 damage and dismemberment:** muscle health, sever and halve, adapted behaviours
   (crawls), the `SinewCutBody` visuals.
9. **S8 tooling:** console, debug draw, record/replay, capture tours
   (`--tour=sinew_*` with `--controller=sinew --model=mannequin`).
10. **Later, on request:** zombie integration (as a new archetype path, opt-in), LOD and
    performance, split screen, networking, Set B, and Unity/Unreal sample bindings.

## Files (new unless noted)
- `sinew/core/**`, `sinew/capi/sinew.h`, `sinew/tests/**`, `sinew/CMakeLists.txt`
- `bindings/godot/` (godot-cpp submodule pinned to the 4.7 API, `src/*.cpp`), output
  `addons/sinew/bin/` and `addons/sinew/sinew.gdextension`
- `addons/sinew/` GDScript: `sinew_rig_builder.gd`, `sinew_cut_body.gd`, `debug_draw.gd`,
  `plugin.cfg`
- `addons/sinew/sinew_character.gd` (SinewCharacter extends UltraCharacter), `sinew_console.gd`
- `demo/tours/sinew_*.gd`
- `tests/suites/s*_sinew_*.gd` (Godot-side suites using the existing runner)
- `.github/workflows/sinew.yml`
- **Edited (additive only):** `demo/main.gd` (`CONTROLLERS`/`MODELS`, `set_controller`/`set_model`, the
  `_make_character` branch for local players, `--controller`/`--model`); `demo/ui/main_menu.gd` (`_build_characters`, like
  `_build_levels`); `CLAUDE.md` (a Sinew section)

## Verification
- **Core:** `cmake -B build sinew && cmake --build build && ctest` runs headless in the cloud
  and in CI. It covers physics invariants, determinism, balance push tests, behaviour
  scenarios and the benchmark.
- **Godot:** `godot --headless --path . --fixed-fps 60 res://tests/test_runner.tscn --
  --suite=s1,s2,...` (the existing runner). It checks:
  - the menu's Character picker selects Sinew and Single player spawns it, with a new `ui`
    test modelled on `test_main_menu_level_select_with_pad`;
  - a Sinew player stands in POWERED;
  - shots stagger;
  - sever leads to a crawl;
  - get-up hands back without pops (reusing m12's acceleration-pop measure on the Sinew
    output stage).
- **Regression:** the existing suites (`--suite=all`) must stay green, which proves the player
  controller is untouched. `git diff --stat` must show no changes under
  `addons/ultra_controller/`.
- **Visual:** capture tours (`--tour=sinew_push|sinew_shot|sinew_fall|sinew_sever`) for you
  to review. Play it yourself through Main menu → Controller "Sinew" + Model → Level
  Playground → Single player.
- **Godot in CI:** the workflow also downloads Godot 4.7.1 (Linux headless) and runs the
  Sinew suites and `--suite=all` against the fresh binaries. I'll try the same in this cloud
  container; if the download is blocked, CI is where the Godot tests run.
