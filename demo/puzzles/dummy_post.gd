class_name UltraDummyPost
extends Node3D
## A practice dummy: the server keeps a bot standing (or pacing) here, stands it back up 4 s
## after it dies, and everyone sees each limb's state above it. With `booth`, a row of buttons
## next to it hurts, cripples or cuts off a chosen limb, knocks it down, or heals it.

const R := UltraLimbs.Region
const ACTIONS := [
	["Hurt\nL leg", "hurt", R.THIGH_L], ["Cripple\nR leg", "cripple", R.SHIN_R],
	["Cripple\nL arm", "cripple", R.ARM_L], ["Cripple\nR arm", "cripple", R.FOREARM_R],
	["Cut off\nR arm", "sever", R.ARM_R], ["Cut off\nL leg", "sever", R.THIGH_L],
	["Knock\ndown", "knock", -1], ["Heal", "heal", -1],
]

## Tests switch this off so the playground's dummies don't wander into other checks.
static var auto_spawn := true

@export var dummy_name := "Dummy"
@export var booth := false
## Walk back and forth over this many metres (0 = stand still): shows limps and dangling arms.
@export var pace := 0.0
## Sprint round a square of this side (m), corner to corner, from the post forward then right (0 = off): a moving
## target - balls, shots and shoves on a body at full speed.
@export var sprint_loop := 0.0
var _corner := 1

var bot_id := 0
var _dead_t := 0.0
var _label: Label3D


func _ready() -> void:
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 40
	_label.outline_size = 8
	_label.position = Vector3(0, 2.35, 0)
	add_child(_label)
	if find_child("NetObject", false, false) == null:
		var o := NetObject.new()
		o.name = "NetObject"
		add_child(o)
	if booth:
		for i in ACTIONS.size():
			var b := UltraSwitch.new()
			b.name = "Button%d" % i
			b.kind = UltraSwitch.Kind.BUTTON
			b.label = ACTIONS[i][0]
			b.prompt = ACTIONS[i][0].replace("\n", " ")
			b.position = Vector3(1.6 + (3 - i % 4) * 0.8, 1.35 - (i / 4) * 0.6, 0)
			b.rotation_degrees.y = 180.0              # face the way the dummy faces
			add_child(b)
			b.changed.connect(func(on: bool) -> void:
				if on:
					_act(i))


func _physics_process(delta: float) -> void:
	if not UltraNet.is_server() or UltraNet.mode == UltraNet.Mode.NONE:
		return
	var p: NetPlayer = UltraNet.players.get(bot_id)
	# Ids restart at 1 with every session: after a restart without a scene reload our old id
	# can belong to a player or another post's dummy. Only our own bot counts.
	if p and (not p.is_bot or p.display_name != dummy_name):
		p = null
	if p == null or not is_instance_valid(p.character):
		if auto_spawn:
			_spawn()
		return
	var c := p.character
	if c.state.state == MotorState.Id.DEAD:
		_dead_t += delta
		if _dead_t > 4.0:
			_dead_t = 0.0
			c.respawn(global_transform)
	else:
		_dead_t = 0.0


func _spawn() -> void:
	var p := UltraNet.spawn_bot(dummy_name, global_transform)
	if p == null:
		return
	bot_id = p.id
	var src := p.character.input_source as BotInputSource
	src.loop = true
	if sprint_loop > 0.0:
		src.body = p.character
		src.driver = _sprint_drive
	elif pace > 0.0:
		var n := int(pace / 1.0 * 60.0)
		src.set_steps([{"ticks": n, "move": Vector2(0, 0.45)}, {"ticks": 40, "yaw_rate": PI / (40.0 / 60.0)}])
	else:
		src.set_steps([{"ticks": 600}])
	var o := find_child("NetObject", false, false) as NetObject
	if o:
		o.mark_dirty()


## The sprinter's stick: flat out toward the next corner of the square, turning onto the one after from 3 m out
## (rounded corners at speed). Steered from where it is, so it never drifts off the loop.
func _sprint_drive(_tick: int, src: BotInputSource) -> InputFrame:
	var f := InputFrame.new()
	var c := src.body as UltraCharacter
	if c == null:
		return f
	var fwd := -global_basis.z
	var right := global_basis.x
	var corners := [global_position, global_position + fwd * sprint_loop, global_position + (fwd + right) * sprint_loop,
			global_position + right * sprint_loop]
	var to: Vector3 = (corners[_corner] as Vector3) - c.global_position
	to.y = 0.0
	if to.length() < 3.0:
		_corner = (_corner + 1) % corners.size()
		to = (corners[_corner] as Vector3) - c.global_position
		to.y = 0.0
	f.yaw = atan2(-to.x, -to.z)
	f.move = Vector2(0, 1)
	f.buttons = InputFrame.B_SPRINT
	return f


func _process(_delta: float) -> void:
	var c := UltraNet.world.character(bot_id) if bot_id != 0 else null
	if c == null:
		_label.text = dummy_name
		return
	_label.text = "%s  %d hp\n%s" % [dummy_name, int(c.state.hp), UltraLimbs.describe(c.state)]
	_label.modulate = Color(1, 0.5, 0.45) if c.state.state == MotorState.Id.DEAD else Color.WHITE


## Server: a booth button was pressed.
func _act(i: int) -> void:
	var c := UltraNet.world.character(bot_id)
	if c == null or not c.is_authority():
		return
	var kind: String = ACTIONS[i][1]
	var region: int = ACTIONS[i][2]
	var d := UltraCombat.DamageInfo.new()
	d.region = region
	d.point = c.state.pos + Vector3.UP
	d.dir = global_basis.x
	# Just enough to do it, so the dummy lives to show the result.
	var left := c.state.limb_hp[region] / 100.0 * c.damage_profile.region_hp[region] if region >= 0 else 0.0
	match kind:
		"hurt":
			d.amount = maxf(left - c.damage_profile.region_hp[region] * 0.4, 1.0)
			c.apply_damage(d)
		"cripple":
			d.amount = left + 1.0
			c.apply_damage(d)
		"sever":
			d.amount = left + 1.0
			d.kind = &"blade"
			c.apply_damage(d)
		"knock":
			c.knock_down(global_basis.x * 4.0 + Vector3.UP * 2.0)
		"heal":
			c.respawn(global_transform)


func get_net_state() -> Dictionary:
	return {"bot": bot_id}


func set_net_state(d: Dictionary) -> void:
	bot_id = int(d.get("bot", bot_id))
