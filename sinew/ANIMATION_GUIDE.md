# Sinew animation guide

Sinew's gait doesn't play its walk / run / sprint / strafe clips. It **reads its legs from them**: stride,
cadence, duty, each foot's path and roll, and the pelvis bob. It then steps the feet itself on the real ground.
So swapping one of those clips changes how every Sinew character walks, often in ways a quick look won't show.
This file holds what we've learned about which clips work, the checklist for changing one, and the tools that
check it. **Add to it whenever a clip change teaches something.**

## The reference clips

`addons/sinew/sinew_animset.tres` (a `SinewAnimationSet`) maps each role to a clip (`overrides`, else the body
profile's own set). It also names the roles the gait reads:

| Gait input | Role | Clip now | Authored speed | Stands in for |
|---|---|---|---|---|
| `gait_walk` | `walk_f` | `mixamo/N_StdWalk2` | 1.45 m/s | motor walk 1.35 |
| `gait_run` | `jog_f` | `mixamo/U_Run_F` | 3.63 m/s | motor jog 3.6 |
| `gait_sprint` | `sprint_f` | `mixamo/S_Fast` | 5.53 m/s | motor sprint 6.2 |
| `gait_back` | `walk_b` | `Walk_Backwards` (UAL) | 0.97 m/s | backing |
| `gait_left` / `gait_right` | `strafe_l` / `strafe_r` | `mixamo/Strafe_Walk_L` / `_R` | 1.6 m/s | side steps |
| `gait_run_upper` | `walk_f, sprint_f, sprint_f` | - | - | the run cycle's upper body (U_Run_F holds a hand by its face) |

The idle clip's first frame is the standing pose. Standing, the feet go to the clip's own foot spots.

## What a reference clip must be

- **A real cycle.** One stride (two steps) per loop, cadence 1-5.5 steps/s, feet down 20-80 % of it.
  - UAL's Walk / Jog / Sprint are stylised: the jog is 1.7 steps/s with 2.8 m steps and 75 % flight.
- **Near the motor's speed** (within ~35 %). The gait stretches a clip to the speed the body really moves.
  - Too slow a walk turns into lunges. The UAL Walk is 0.80 m/s against the motor's 1.35.
- **Feet that don't skate.** The planted feet must move at the authored speed (true speed vs authored within 35 %).
- **No crossover on forward clips.** A walk whose feet cross the midline is a catwalk: the legs pass through
  each other.
  - A sprint lands on one line and may cross a little (S_Fast: −8 cm). The gait keeps those feet apart.
  - Only side steps may cross freely.
- **Upright, neutral stance.** The Mixamo rifle 8-way legs look crouched under an unarmed body. Check hip /
  shoulder facing and lean (`tools/measure_mixamo.gd`).
- **Root motion in the clip, not in place.** Export Mixamo "not in-place". The stride is measured from the
  planted feet.

## Swapping a clip: checklist

1. Import it (`intake/mixamo/`, `bash tools/intake.sh`) and point the role at it in
   `addons/sinew/sinew_animset.tres`.
2. Run the audit and the moves suite:
   `godot --headless --path . --fixed-fps 60 res://tests/test_runner.tscn -- --suite=s10`.
   - `test_clip_audit` prints what the gait read off every reference clip. It fails on a broken rule (below)
     and lists every difference from `addons/sinew/clip_audit.json`.
   - The two moves tests run every segment of `demo/tours/sinew_moves_segments.gd` (walks, diagonals,
     reversals, sprints, stairs, ramps, strafes, a seeded direction chaos) and hold each to limits.
     - legs never through each other (thigh / shin / foot capsules)
     - hips don't sag
     - soles don't sink into ramps / stairs
     - no leg flicked faster than 25-30 m/s
3. Look at it: `sinew_gait_compare` (gait vs the clip, side on, per-phase numbers via
   `tools/sinew/gait_compare.py`) and `sinew_moves_review` (every segment filmed, `tools/sinew/moves_report.py`).
4. If the changes are what you meant: `CLIP_AUDIT_WRITE=1 ... --suite=s10` writes the new baseline. Commit it
   with the clip change, and add what you learned to this file.

The suites `s7` (planted feet, stairs) and `s9` (physical motion) must still pass. CI runs `s10` on every
merge to main.

## Audit rules (`SinewClipAudit.rules`)

- Cadence 1-5.5 steps/s.
- Duty 0.2-0.8.
- True speed within 35 % of authored.
- No crossover except side steps, or runs (> 3 m/s) by up to 12 cm.
- Feet never more than 65 cm apart.
- The back clip travels backwards, the left clip leftwards.
- The forward clips, slowest first, are within 35 % of the motor's walk / jog / sprint.

Swapping the walk for the UAL Walk fails the speed rule: "0.80 m/s against the motor's walk 1.35 - the gait
would stretch it 69 %".

## Lessons so far

**Clips**
- The Mixamo walk / run / sprint match the motor; the UAL Walk / Jog / Sprint are stylised. `Mixamo_Jog` is
  the UAL jog round-tripped (unused).
- U_Run_F holds its left hand up by the face. Its upper body comes from the walk / sprint (`gait_run_upper`).
- `plant_phase` in the animset is the toe going down, a quarter stride after the heel strike. The gait finds
  its own contact phase (the ankle furthest ahead of the hips).
- Some Mixamo clips are authored facing away (Ladder_Climb) or off the ground. `AnimDriver._refit` handles both.
- The Mixamo strafes are crossover side steps. Their feet come within 1 cm and cross over.
- **Strafe_Walk_L is not a mirror of Strafe_Walk_R.** Strafing left from standing sags the hips ~15 cm,
  strafing right 8 (still open, held in s10's `KNOWN`).
- N_StdWalk2's measured duty is 0.48, so even a straight walk has a tick or two per step with neither foot
  down (the `air` column).

**Measuring**
- Sample the shown pose at `Skeleton3D.skeleton_updated` only.
- Stride = authored speed × length. Measured against the hips a run reads 10-20 % low, because the hips surge.
- Foot pitch is signed (a sprint's push-off goes past vertical).
- A foot's facing only means something while it's on the ground.

**Gait rules a clip change can upset**
- The side rule: feet keep their own sides, no closer than the clip's own narrowest spacing (`width_min`).
  - A crossover only when the travel has been steadily sideways for 0.3 s.
- A crossover swing still in the air when the stick turns waits up to 8 ticks for its foothold to uncross.
  If it can't, it comes down on its own side.
- The pelvis drops to reach a planted foot. Moving, a foot that would need more than 10 cm (walk) / 6 cm (run)
  of drop lifts instead, but only with the other foot down at a walk.
- On a side clip the trailing foot hurries from 20 cm out to the side of its hip (35 cm otherwise).

## Known open problems

- Strafing left from standing, and backing straight out of it: hips sag 15-17 cm (`KNOWN` in s10).
- Stair treads shorter than the foot leave a toe or heel in a riser (stairs sink limit 20 cm).
- Hips "drop" on a steep ramp down is mostly the measure: hips are measured over the lower toe, which is
  20+ cm downhill.
