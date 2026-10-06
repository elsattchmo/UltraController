class_name ZombieArchetype
extends Resource
## One kind of zombie: the numbers that differ between a shambler and a runner. Everything else
## (the body, the clips, the damage rules) is shared - see ZombieFactory. Archetypes are plain
## code (`ZombieArchetype.get_arch(&"walker")`), not .tres files: they are a table of tuning.

@export var id: StringName = &"walker"
## Ground speeds (m/s). `run_speed` > 0 sprints (the runner); a crawler uses `crawl_speed`.
@export var walk_speed := 1.0
@export var run_speed := 0.0
@export var crawl_speed := 0.45
## The role of the walking clip (AnimationSet): "walk_f" Quaternius zombie walk, "shamble" Mixamo Romero walk.
@export var gait_role: StringName = &"walk_f"
## Toughness: scales the region hit points (more hits to cripple / kill) ...
@export var hp_mult := 1.0
## ... and how hard a shotgun blast has to shove to knock it over (m/s).
@export var shove_knockdown := 3.5
## Spawns with a leg crippled (-1 left, +1 right): the limp gait.
@export var bad_leg := 0
## Spawns without legs (both thighs severed): crawls.
@export var legs_gone := false
## Body tint over the skin and body scale (presentation only).
@export var tint := Color.WHITE
@export var body_scale := 1.0

@export_group("Senses")
@export var sight_range := 20.0
@export var sight_fov_deg := 60.0
@export var close_sense := 1.8
## Multiplies the loudness of every noise it hears (a crawler is deafer, a runner sharper).
@export var hearing := 1.0
## Seconds it chases the last place it saw you before giving up.
@export var memory := 6.0

@export_group("Attack")
@export var reach := 1.2
@export var damage := 12.0
@export var interval := 1.6
## Clip roles the swings pick from (AnimationSet): "atk_swipe", "atk_overhead", "atk_punch", "atk_jab".
@export var attacks: Array = [&"atk_swipe", &"atk_overhead"]


## Strike clips (AnimationSet roles): the part of the clip played [from, to] and the time in the
## clip the hand lands (measured: tools/measure_zombie.gd - the hand's peak forward reach).
const CLIPS := {
	&"atk_swipe": {"seg": Vector2(0.5, 1.9), "contact": 1.1},
	&"atk_overhead": {"seg": Vector2(0.6, 2.4), "contact": 1.55},
	&"atk_punch": {"seg": Vector2(0.7, 2.2), "contact": 1.35},
	&"atk_jab": {"seg": Vector2(0.2, 1.0), "contact": 0.65},
}

static var _table := {}


static func get_arch(arch_id: StringName) -> ZombieArchetype:
	if _table.is_empty():
		_build()
	return _table.get(arch_id, _table[&"walker"])


static func ids() -> Array:
	if _table.is_empty():
		_build()
	return _table.keys()


static func _make(arch_id: StringName, props: Dictionary) -> void:
	var a := ZombieArchetype.new()
	a.id = arch_id
	for k: String in props:
		a.set(k, props[k])
	_table[arch_id] = a


static func _build() -> void:
	_make(&"walker", {"walk_speed": 1.05, "tint": Color(0.86, 0.9, 0.84)})
	# The slow stalker: Mixamo's Romero walk (a 0.36 m/s cycle) sped up a little.
	_make(&"shambler", {"walk_speed": 0.55, "gait_role": &"shamble", "tint": Color(0.8, 0.84, 0.78), "memory": 9.0, "sight_range": 16.0})
	# One leg already ruined: the limp.
	_make(&"limper", {"walk_speed": 0.9, "bad_leg": 1, "tint": Color(0.82, 0.8, 0.74)})
	# Rare and fast; sees well, hits a little lighter.
	_make(&"runner", {"walk_speed": 1.3, "run_speed": 3.0, "tint": Color(0.92, 0.82, 0.8), "sight_range": 26.0, "sight_fov_deg": 70.0, "hearing": 1.2, "damage": 9.0, "interval": 1.2, "attacks": [&"atk_jab", &"atk_swipe"]})
	# Big and hard to put down or knock over.
	_make(&"brute", {"walk_speed": 0.75, "hp_mult": 2.4, "shove_knockdown": 7.0, "body_scale": 1.12, "tint": Color(0.74, 0.74, 0.7), "damage": 22.0, "interval": 2.0, "reach": 1.35, "attacks": [&"atk_overhead", &"atk_punch"]})
	# No legs: drags itself along on its arms.
	_make(&"crawler", {"legs_gone": true, "crawl_speed": 0.45, "tint": Color(0.84, 0.8, 0.76), "sight_fov_deg": 50.0, "hearing": 0.8, "reach": 1.0, "attacks": [&"atk_swipe"]})
