# Third controller "Marksman": full locomotion, rifle and pistol packs, then everything else

## Context

**The ask.** The user wants the downloaded Mixamo packs used: Pro Rifle (RFP_), Shooter (SHT_ / SHB_) and Pistol (PST_). They picked a **new third controller** that folds in what we've learned, rather than extending Sinew or the UltraController.

Requirements:
- Full **8-way locomotion first**: standing, crouched and prone, for unarmed, rifle and pistol.
- **Body-true first person**: one body for both views, the camera at the head's eye, the gun where the hands hold it.
- **One-handed holding with either hand**, when the other arm is injured or lost, or the other hand is busy.
- A clear policy for which parts of the upper body are simulated.
- In a later stage, **every other animation** the other controllers have: unarmed actions, push, pickup / carry / throw, rope, climb down, mantle, shimmy, and so on.

**What exists today (audited).**
- **No gun-pack clip is wired to any role yet.** The packs are imported into `mixamo.res` and listed in `intake/mixamo/PACKS.md`. None of them has root motion.
- **The packs' coverage:**
  - RFP: walk, run, sprint and crouch-walk in 8 directions; Turn90 left / right and crouching Turn90; idle, idle aiming, crouch idle and crouch idle aiming; jumps; 6 deaths.
  - SHB / SHT: fire, reload, strafes, starts and stops, a hit reaction, a grenade toss.
  - PST: walk / run forward, backward and strafe (two variants), arcs, idle, kneeling idle, stand-to-kneel and kneel-to-stand, jumps. There is no pistol fire, reload, sprint or diagonals.
- **Sinew has no gun support.** The gun rides the clip's hand: there is no support hand, aim, fire / reload animation or first-person handling.
- **Sinew's coverage gaps against the UltraController:**
  - jump start, heavy land, running leap;
  - turn in place, the 8-way sets, limp;
  - drop to hang, shimmy;
  - prone transitions, directions, fire and reload;
  - teeter, throw;
  - working fire / reload / throw events;
  - three bugs: the root-motion path misses `mixamo/` clips and mirroring, the crawl rate is pinned, and prone idle is the rifle clip even unarmed.
- **Rebuild trap.** 23 animset roles exist only in `mannequin_animset.tres`, not in `tools/build_animset.gd`. They are `prone_*`, `drop_hang`, `block_*`, `swim_*`, `hang_idle` and `shimmy_*`, and a rebuild would delete them.

## Architecture

`MarksmanCharacter extends SinewCharacter` lives in **`addons/marksman/`**. The name is a placeholder, easy to rename. It is registered as key `"marksman"` in `demo/characters/character_models.gd` (`CONTROLLERS` + `make()`); the menu row builds itself from that list.

**Reused unchanged:**
- From UltraCharacter: motor, net, items, UltraActionLayer firing, damage.
- From SinewCharacter: physical motion, pivot, push, hit reactions, teleport.
- From Sinew: SinewWorld, the core gait, balance and stagger.
- The camera rig, which already places the first-person eye from the posed Head bone.

`addons/ultra_controller/` is never edited.

**Additive changes to Sinew** (its default behaviour stays bit-identical; s0–s10 must keep passing):
- `SinewCharacter._build_visual`: factory hooks `_new_anim_driver()`, `_new_equipment()`, `_new_ragdoll()` and `_default_anim_set()`.
- `SinewPoseModifier.passes`: procedural passes on `anim_pose`, after the gait blend and twist, before the physics blend. Aim and IK done there are what shows **and** what the muscles track (a TwoBoneIK3D outside it would fight the gait / twist).
- `SinewRagdoll` hooks:
  - `_part_wants_physics(i, calm)` (the simulation policy);
  - `_gait_upper_weight(speed)`;
  - `_gait_cycle_sets()`;
  - a CROUCH gait mode (crouched cycles, lower pelvis).
- `SinewGaitCycles.build(drv, parts, aset)` takes any set.
- **Core gait:** `GaitCycle.group` + `Gait::set_group(g, blend_s)`.
  - `cycle_weights` / `pick_direction` work within the active group.
  - Directions gather several speeds (walk / run / sprint each way, not just the slowest).
  - A stance change takes effect per foot (a swing in the air finishes on its latched clip), with the base pose and pelvis cross-faded.
  - Binding: a `group` key per cycle, plus `character_gait_set_group`.
  - With one group the arithmetic is unchanged, which protects s7 / s10 and `clip_audit.json`.

**Marksman owns:**

| File | Purpose |
|---|---|
| `marksman_character.gd` | factories, stance switching, a first-person camera profile with no head low-pass |
| `marksman_anim_driver.gd` (extends SinewAnimDriver) | 8-way locomotion per stance and posture; separately filtered spine, left-arm and right-arm layers (mirrored sources for a left-hand gun); fire / reload / equip one-shots |
| `marksman_stance_set.gd` + `stances/{unarmed,rifle,pistol}.tres` | per stance and posture: idle / aim, 8-way walk / run / sprint, crouch 8-way, prone set, turns. Written by `tools/marksman/build_stance_sets.gd`, which measures authored speeds from the grounded toes with `tools/anim_measure.gd` |
| `marksman_ragdoll.gd` | simulation policy, stance group switch, reach effectors |
| `marksman_hands.gd` | gun hand and hand claims, a pure function of MotorState (every machine agrees) |
| `marksman_gun_pass.gd` | aim, eye, ADS, two-hand support IK, one-hand pose, recoil. An analytic two-bone solver on `anim_pose`, elbow pole from the clip's elbow side |
| `marksman_equipment.gd` (extends UltraEquipmentVisual) | the camera, HUD and effects look up `Equipment` by type, so it must stay one. `_process` is the base's (it already picks the hand from `UltraInjury.weapon_hand`); `_drive_hands` keeps only the ADS / recoil followers (no ADS with a long gun in one hand), `mag_reload` places the magazine for either hand; `_aim_body` does nothing. Attach, holster, slide, pump, smoke, muzzle and eject are reused |

**Simulation policy.** Whatever holds the gun is kinematic: physical arms after IK let the hands slide off the guns, one of Sinew's lessons. Physics switches whole subtrees only.

| Situation | Spine / neck | Gun arm | Support arm | Legs |
|---|---|---|---|---|
| Unarmed idle (calm 0.35 s) | physical | physical | physical | clip feet |
| Unarmed moving | animated | animated | animated | gait |
| Armed idle / aim / moving | clip + aim pass (`state.sway` breathes it) | kinematic | kinematic, IK on the grip | stance gait |
| Firing | recoil spring through the gun pass (chest pitch, clavicle, wrist) | follows | IK follows | kinematic |
| Torso hit | physical 0.9 s at tone 0.6, tracking the aimed pose | physical + `reach` to its aimed hand | physical + `reach` to the grip; lets go above 8 cm, re-grips | stagger at ≥ 10 N s |
| Gun-arm hit | kinematic | physical at 25 % tone | IK released → physical → re-grip | kinematic |
| One-handed, other arm crippled / lost | aim | one-hand pose | physical at injury tone (severed: gone) | kinematic |
| One-handed, other hand busy | aim | one-hand pose | owned by the task (clip / `reach`) | kinematic |

While a gun is up, the aim pass owns the spine's yaw (`torso_twist` is held at 0).

## Stages

Each stage is merged on its own, with its tests in CI. Suites are `tests/suites/g<n>_marksman.gd`, added to `sinew.yml`.

### V0 – Registration and factories
- The Sinew hook refactor; Marksman behaves exactly like Sinew.
- Tests:
  - g0: spawn and walk;
  - the menu test sees 3 toggles;
  - s0–s10 pass unchanged.

### V1 – Full 8-way locomotion: standing, crouched and prone, for every stance

**Core:** stance groups, multi-speed directions, and the CROUCH gait mode with its doctests.
- A single group gives an identical clip report.
- A group switch mid-stride moves no planted foot.
- A back run picks the back-run clip.

**Clip sets:**
- **Standing:**
  - Unarmed: N_StdWalk2, U_Run_F, S_Fast, Walk_Backwards and the Strafe_Walk clips (today's), plus LMM run strafes and back runs where the audit says they fit.
  - Rifle: RFP walk / run / sprint, 8-way.
  - Pistol: PST walk / run forward, back and strafe. Diagonals come from the gait's nearest clip + warp, and the sprint is the unarmed sprint legs under the pistol upper body.
- **Crouched:**
  - Rifle: RFP crouch-walk 8-way, crouch idle / aiming, crouch turns.
  - Unarmed: Crouch_Walk + AAD crouched sneaking left / right, plus the nearest clip + warp for back and diagonals.
  - Pistol: the unarmed crouch legs + PistolKneelingIdle standing.
- **Prone:** stays clip-driven (crawling is not bipedal, so no gait), as an 8-way BlendSpace2D.
  - Forward / back: PR_Fwd / PR_Back, and Crawl unarmed.
  - Sideways: PR_RollR mirrored, or the in-place turn clip looped (UltraController's trick).
  - Pivot: PR_TurnL mirrored.
  - Down / up transitions: PR_FromCrouch / PR_ToCrouch.
  - Also fixes Sinew's crawl rate and unarmed prone idle.
- **Turn in place:** RFP Turn90 left / right per stance (crouched too), unarmed T_StandL90 / R90.

**Switching:** drawing or holstering switches the stance group, idle frame and pelvis over about 0.35 s. Standing, the feet take one or two settle steps into the new stance.

**Tests:**
- g1 clip audit per stance and posture, with baselines in `addons/marksman/clip_audit_<stance>.json` and rules against the motor's stance speeds.
- s10's segments rerun for each of the unarmed / rifle / pistol stances, standing and crouched, through `SinewMoveMetrics`, with no leg overlap and limits on hips sag and sinking.
- A prone 8-way sweep: per direction, the clip plays and the body moves that way.
- A draw while walking: pelvis within 3 cm per tick, no planted foot slides more than 5 mm.

The ANIMATION_GUIDE gains a section on stance sets.

### V2 – Holding and aiming two-handed guns
- The `passes` hook and the gun pass: aim at the `gun_ray` hit point, and the support hand on `M_SupportGrip` by IK.
- The policy hooks.
- Tests:
  - barrel to aim within 1° standing, 2° walking, 3° running, in every posture;
  - support hand within 1.5 cm of the grip;
  - kinematic hand parts equal the shown bones.

### V3 – Body-true first person + ADS
- Camera at the head's eye; ADS by bringing the cheek and eye to the sights through the body.
- Tests:
  - camera within 1 mm of the eye;
  - in ADS, the sights on the view ray within 0.3°;
  - muzzle visible at the hip;
  - eye outside the body capsules.
- Tour `marksman_fp_review`.

### V4 – Fire, reload, equip / holster
- Recoil spring.
- Reloads: Rifle_Reload / SHB_Reloading time-scaled to `reload_commit`; UAL Pistol_Reload.
- SHB_FiringRifle for automatic fire.
- Equip / holster blend into the stance switch.
- Tests:
  - barrel recovers within 0.5° in 0.3 s;
  - muzzle on the barrel axis;
  - `upper_busy` during a reload.

### V4b – Gunplay feel: Insurgency: Sandstorm

The target is the user's reference, Sandstorm.

**Reused from the UltraController's simulation** (deterministic, already networked):
- free-aim zone and `MotorState.sway` (turn lag, gait bob, breathing; ADS / crouch calm it);
- `ads_w`;
- the `burst` recoil climb with seeded sideways drift;
- `gun_dir()` shots.

Marksman makes all of it **visible through the body**: the gun pass drives the arms, chest and head from sway and recoil, so first person and third person show the same thing.

**What Marksman adds, all presentation unless noted:**

- **Free aim on screen.**
  - The gun wanders inside the zone and the view leads it.
  - The HUD dot is optional (Sandstorm hardcore: none).
  - ADS brings the sights onto the gun's line, not the view: aiming is the sight picture.
- **Weight and inertia.** Rifle heavier than pistol (ItemDefinition stats), via:
  - sway amplitude;
  - turn lag;
  - ADS time and movement slowdown, through the existing stats.
- **Recoil you see and feel.**
  - Per shot: a body kick through the recoil spring (chest pitch, shoulder push, muzzle rise).
  - A view kick that partly recovers.
  - Pattern climb over a burst (sim).
  - Physical settle: the gun-arm muscles relax briefly so the recovery comes from the body.
- **Gun lowers near walls.** A ray along the barrel from the shoulder; within the gun's length the gun tucks up / in, and firing is blocked while it's tucked.
  - That rule must live in the sim to stay deterministic: a Marksman-side check in the action path, a query on the state.
- **Lean left / right.**
  - New input actions `marksman_lean_l` / `_r`, defined in `project.godot` (input as data).
  - The gun pass bends the spine, which moves the eye. Shots follow automatically through `InputFrame.aim_from` (camera minus the sim eye), so lean stays consistent online too.
- **Sprint carry and stance feel.**
  - Gun lowered while sprinting (port arms for the rifle, the pistol lowered); a short "ready" delay back to aim.
  - Crouch / prone steady the sway (sim calm factors).
- **Reloads.**
  - Tactical vs empty (the round in the chamber): a longer empty reload with the charging handle / slide.
  - The magazine visibly comes out and goes in; the old magazine drops.
- **Hold breath while in ADS** (a key): sway calmed for a few seconds, then shakier.
  - This needs the sim: it's sway. It goes in as a Marksman action-layer hook if the UltraController's sway exposes one; otherwise presentation only, with the shot still along `gun_dir`. Decide when building.
- **Freelook** (hold a key): the head turns without the gun.
  - The camera looks from the head while the aim stays; `aim_from` keeps shots honest.

**Tests (g4b):**
- sway amplitude ordered: ADS + crouch < ADS < hip, and prone the smallest;
- recoil climb over a burst and recovery within limits;
- the gun tucks within 0.2 s near a wall and won't fire;
- a lean moves the eye 25-35 cm and the shot origin follows;
- freelook leaves the shot direction unchanged.

**Tour:** `marksman_gunfeel_review`: hip fire, ADS, bursts, leans, wall tuck, sprint to aim, reloads.

### V5 – Hits under the policy
- Tests:
  - support hand back on the grip within 1 s;
  - a gun-arm hit lets go then re-grips;
  - no part faster than 25 m/s;
  - SHB_HitReaction / prone hit;
  - s3 and s5 still pass.

### V6 – One-handed, either hand (done)
- The hand comes from the sim: `UltraInjury.weapon_hand` / `two_hands` (an arm crippled or lost, hand included). Hand
  claims (props, doors, an off-hand item) were left out: carrying a prop already puts the gun away.
- The equipment re-attaches the gun to `LeftHandAttach` with a mirrored grip (base behaviour); `MarksmanGunPass` works on
  `side` (`_gpart`), mirroring its right-side constants. The clips are not mirrored: the hold is procedural.
  - pistol: out along the aim on the one arm (`PISTOL_ONE` off the eye);
  - long gun: stock braced under the arm (`ARMPIT`, kept outside the torso), barrel on the aim, no ADS.
- The other arm hangs: MarksmanRagdoll makes a crippled arm's upper arm / forearm / hand physical at `LIMP_TONE` in every
  state, and the gun pass poses it hanging at the side (`HANG`) as the soft muscles' target.
- One-handed reload (slower: `reload_mult` 1.8x): the gun is pinned against the body (`_pin_xf`: a long gun under the
  arm, barrel down-forward; a pistol tucked at the chest's side; placed on the shown chest after the physics,
  `_place_pinned`) while the hand swaps the magazine from the pouch on its own hip (racks an empty gun) or ferries shells.
- Switching hands mid-hold blends the pose from the last one shown over 0.3 s.
- Suite g7: holds both ways (barrel, limp arm, stock under the arm, nothing in the body), a lost hand, reloads both
  ways, a mid-hold switch, replication agreement.

### V7 – Everything else: parity with the other controllers (done)
- **Movement nodes** (`MarksmanAnimDriver._add_parity_nodes`, the UltraController's builders - inherited): running
  leap (`air_run`, seeked by vertical speed), fall, heavy landing, slide start, drop to hang (`drop_hang`), the ledge
  hang's shimmy blend, ladder refit, dive, prone down / up (PR_FromCrouch / PR_ToCrouch). `_parity_wanted` maps the
  motor states as the UltraController does.
- **No pops**: every loco change dead-blends (`MarksmanInertial`; not out of a rope / slide / drop to hang), root jumps
  (a drop's 2 m, a ladder grab's 0.48 m) shift the blend and drop the stale physics picture, the drop's end turns the
  blend with the root. Suite g9: every course plays its node, nothing over 25 m/s (strikes 40).
- **Actions**: melee weapon swings and the throw (Sinew's driver ignored item events); **weapon melee is new**
  (`STRIKES`: the rifle punch / pistol whip clips timed to the sim's hit, the gun placed from both of the clip's hands);
  hands on a carried prop (`MarksmanGunPass._carry_hands`, suite g11).
- Not needed under Marksman: teeter (edges are Sinew's), the procedural first-person gun-butt (the body's eye sees the
  clip). Left: injured idle, grenade toss.

### V8 – Docs and wrap-up
- CLAUDE.md section (kept up per change), ANIMATION_GUIDE updates, known issues (below).

## Known issues
- The unarmed back walk (UAL Walk_Backwards) drifts its planted feet ~6 mm a frame under motion matching (g10 KNOWN).
- Crouched backward / left under motion matching: the clips roll on the balls of the feet, so g10 can't measure slide.
- Aiming down the sights leaning right, the eye gets 19 cm out against 29 leaning left (the stock sits on the right).
- The matcher's turn clip leans the chest back 20-30 deg on a fast turn with the pistol up.

## Risks
- **Binaries build only on main.** V1's core and binding changes must merge before its GDScript can rely on them. Guard with `class_has_method` and fall back to a single group.
- **Equipment `_process` copy can drift** from the UltraController. A test checks the attach hand and the holster.
- **Aim pass ↔ eye feedback.** Aim at the hit point; compute the eye inside the pass.
- **RFP legs read crouched under an unarmed body.** They are only used in the rifle stance.
- **Pistol pack gaps** (no sprint, no diagonals, no fire / reload) are filled with the fallbacks above.
- **Physics only on closed subtrees.**
- **Physical motion is offline only.** The hand choice uses replicated state only.

## Verification (per stage)
- Core: `cmake --build build/sinew && ./build/sinew/sinew_tests`.
- Local extension build (delete the .so to force a relink).
- `godot --headless --path . --fixed-fps 60 res://tests/test_runner.tscn -- --suite=s0,s2,s3,s4,s5,s6,s7,s8,s9,s10,g0..gN,ui`: all green, `SCRIPT ERROR` grepped.
- Stage tours for a visual check (`marksman_*_review`, moves tour per stance).
- Commit, push, PR, merge. CI on main builds the binaries and runs the suites.
- Report to the user with numbers and strips after each stage.
