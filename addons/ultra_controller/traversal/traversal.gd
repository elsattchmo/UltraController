class_name UltraTraversal
extends RefCounted
## Traversal decisions: pure physics queries on the simulated state, run by the motor as a
## transition hook on the client (prediction) and the server alike.
##
##   h = ledge top above the feet
##   h <= step height            -> the step solver handles it
##   0.45..1.5  standable top    -> MANTLE  (ClimbUp clip's root path, warped to the ledge)
##   0.6..1.35  thin, running    -> VAULT   (bezier over the top, momentum kept)
##   1.5..2.35  (or caught in the air) -> LEDGE_HANG (shimmy, climb up, drop)
## plus ladders / pipes (UltraLadder), climbable walls (CLIMBABLE layer) and ropes (UltraRope).

enum Move { NONE, MANTLE, VAULT, LEDGE_CLIMB }

const HANG_DROP := 2.06           ## feet below the ledge top while hanging (Ledge_Hang hands)
const HANG_BACK := 0.33           ## capsule centre out from the wall face while hanging
const REACH_AIR := 2.35           ## hands can catch a ledge this far above the feet
const WALL_PROBE := 0.85

class Ledge:
	var top := Vector3.ZERO       ## point on the top surface just behind the edge
	var edge := Vector3.ZERO      ## edge point at top height on the wall face
	var normal := Vector3.ZERO    ## wall normal (horizontal, pointing at us)
	var height := 0.0
	var standable := false
	var crouch_only := false
	var thin := false
	var climbable := false        ## the wall is on the CLIMBABLE layer


static func scan(m: UltraMotor, feet: Vector3, dir: Vector3, max_h := 2.4, reach := WALL_PROBE) -> Ledge:
	var space := m.body.get_world_3d().direct_space_state
	var excl: Array[RID] = [m.body.get_rid()]
	var mask := UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC | UltraLayers.CLIMBABLE
	dir = Vector3(dir.x, 0, dir.z).normalized()
	if dir == Vector3.ZERO:
		return null
	# 1) wall in front, lowest hit among a few heights
	var wall: Dictionary = {}
	for h: float in [0.35, 0.75, 1.15, 1.55, 1.95]:
		if h > max_h:
			break
		var from := feet + Vector3.UP * h
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * reach, mask, excl)
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and absf((hit.normal as Vector3).y) < 0.35:
			wall = hit
			break
	if wall.is_empty():
		return null
	var n := Vector3((wall.normal as Vector3).x, 0, (wall.normal as Vector3).z).normalized()
	if n.dot(-dir) < cos(deg_to_rad(40.0)):
		return null
	# 2) top surface just behind the wall face
	var wp: Vector3 = wall.position
	var probe := Vector3(wp.x, feet.y + max_h + 0.25, wp.z) - n * 0.18
	var qd := PhysicsRayQueryParameters3D.create(probe, Vector3(probe.x, feet.y + 0.05, probe.z), mask, excl)
	var top := space.intersect_ray(qd)
	if top.is_empty() or (top.normal as Vector3).y < 0.7:
		return null
	# Something above the start of the probe (a ceiling, a taller wall): not a ledge.
	var qa := PhysicsRayQueryParameters3D.create(Vector3(wp.x, (top.position as Vector3).y + 0.05, wp.z) + n * 0.05, probe, mask, excl)
	if not space.intersect_ray(qa).is_empty():
		return null
	var l := Ledge.new()
	l.top = top.position
	l.normal = n
	l.height = l.top.y - feet.y
	l.edge = Vector3(wp.x, l.top.y, wp.z)
	l.climbable = wall.collider is CollisionObject3D and ((wall.collider as CollisionObject3D).collision_layer & UltraLayers.CLIMBABLE) != 0
	if l.height <= m.profile.step_height + 0.02 or l.height > max_h:
		return null
	# 3) room to stand (or crouch) on top
	var r := m.profile.radius
	for spec: Array in [[m.profile.stand_height, "stand"], [m.profile.crouch_height, "crouch"]]:
		var cap := CapsuleShape3D.new()
		cap.radius = r
		cap.height = spec[0]
		var qs := PhysicsShapeQueryParameters3D.new()
		qs.shape = cap
		qs.collision_mask = mask
		qs.exclude = excl
		qs.transform = Transform3D(Basis(), l.top - n * (r + 0.12) + Vector3.UP * (float(spec[0]) * 0.5 + 0.06))
		if space.intersect_shape(qs, 1).is_empty():
			l.standable = spec[1] == "stand"
			l.crouch_only = spec[1] == "crouch"
			break
	# 4) thin obstacle? (vault): the surface drops away within ~0.9 m
	var far := l.top - n * 0.95
	var qv := PhysicsRayQueryParameters3D.create(far + Vector3.UP * 0.1, far + Vector3.DOWN * 0.6, mask, excl)
	var fh := space.intersect_ray(qv)
	l.thin = fh.is_empty() or (fh.position as Vector3).y < l.top.y - 0.45
	return l


## Motor transition hook (registered in UltraMotor). Returns a state id or -1.
static func hook(m: UltraMotor, s: MotorState, i: InputFrame) -> int:
	var Id := MotorState.Id
	if s.held_id != 0 or s.equipped != 0 and s.action == UltraActionLayer.Action.RELOADING:
		return -1
	var fwd := Vector3(-sin(s.body_yaw), 0, -cos(s.body_yaw))
	var wish := i.move_world(i.yaw)
	var dir := wish.normalized() if wish.length() > 0.2 else fwd
	var forward := i.move.y > 0.3
	var jump := UltraMotor.pressed_edge(s, i, InputFrame.B_JUMP)
	match s.state:
		Id.IDLE, Id.MOVE, Id.LAND:
			var lad := UltraLadder.find_enterable(s.pos, dir, i.move.y)
			if lad:
				return _enter_ladder(m, s, lad)
			if jump and (forward or s.state == Id.IDLE):
				# Running? Look further ahead so a vault / mantle can start from a stride away.
				var reach := WALL_PROBE + m.horizontal(s.vel).length() * 0.18
				var l := scan(m, s.pos, dir, 2.4, reach)
				if l:
					if l.climbable and l.height > 1.5:
						return _enter_wall(m, s, l)
					var speed := m.horizontal(s.vel).length()
					if l.thin and l.height >= 0.6 and l.height <= 1.35 and speed > m.profile.walk_speed * 1.6:
						return _start_move(m, s, Move.VAULT, l)
					if l.height <= 1.4 and (l.standable or l.crouch_only):
						return _start_move(m, s, Move.MANTLE, l)
					if l.height <= REACH_AIR:
						return _hang(m, s, l)
		Id.SWIM:
			# Out of the water: up a ladder, or over an edge that's not far above the surface.
			var lad3 := UltraLadder.find_enterable(s.pos, dir, i.move.y)
			if lad3 and forward:
				return _enter_ladder(m, s, lad3)
			if jump or forward:
				var l3 := scan(m, s.pos, dir, 2.4)
				var above := l3.top.y - m.water_surface if l3 else 0.0
				if l3 and (l3.standable or l3.crouch_only) and above > -0.05 and above < 0.9 and (jump or above < 0.45):
					return _start_move(m, s, Move.MANTLE, l3)
		Id.JUMP, Id.FALL:
			var rope := UltraRope.find_catch(s.pos)
			if rope and not (s.prev_state == Id.ROPE and s.state_time < 0.5):
				return _enter_rope(m, s, rope)
			var lad2 := UltraLadder.find_enterable(s.pos, dir, 1.0 if forward else 0.0)
			if lad2 and forward:
				return _enter_ladder(m, s, lad2)
			if (forward or i.has(InputFrame.B_JUMP)) and s.vel.y < 3.0 and not (s.prev_state == Id.LEDGE_HANG and s.state_time < 0.45):
				var l2 := scan(m, s.pos, dir, REACH_AIR)
				if l2 and l2.height >= 0.9:
					if l2.height <= 1.2 and (l2.standable or l2.crouch_only):
						return _start_move(m, s, Move.MANTLE, l2)
					return _hang(m, s, l2)
	return -1


static func _face(s: MotorState, n: Vector3) -> void:
	s.body_yaw = atan2(n.x, n.z)          # facing -n


static func _start_move(m: UltraMotor, s: MotorState, kind: int, l: Ledge) -> int:
	s.trav_kind = kind
	s.trav_from = s.pos
	s.trav_t = 0.0
	s.trav_normal = l.normal
	s.trav_point = l.edge
	_face(s, l.normal)
	match kind:
		Move.VAULT:
			var depth := 0.9
			s.trav_to = Vector3(l.top.x, s.pos.y, l.top.z) - l.normal * (depth + 0.4)
			var speed := maxf(m.horizontal(s.vel).length(), m.profile.jog_speed)
			s.trav_dur = clampf(s.trav_from.distance_to(s.trav_to) / speed, 0.38, 0.7)
			s.trav_s = speed
			return MotorState.Id.VAULT
		_:
			s.trav_to = l.top - l.normal * (m.profile.radius + 0.12)
			s.trav_dur = 0.6 * clampf(sqrt(maxf(l.height, 0.3) / 0.9), 0.6, 1.3)
			if l.crouch_only:
				s.stance = MotorState.Stance.CROUCH
			return MotorState.Id.MANTLE


static func _hang(m: UltraMotor, s: MotorState, l: Ledge) -> int:
	s.trav_point = l.edge
	s.trav_normal = l.normal
	s.trav_s = 1.0 if (l.standable or l.crouch_only) else 0.0     # can climb up from here?
	_face(s, l.normal)
	return MotorState.Id.LEDGE_HANG


static func _enter_ladder(m: UltraMotor, s: MotorState, lad: UltraLadder) -> int:
	s.trav_id = lad.ladder_id
	s.trav_s = clampf(lad.height_of(s.pos), 0.0, lad.height)
	s.trav_normal = lad.normal()
	_face(s, lad.normal())
	return MotorState.Id.LADDER


static func _enter_wall(m: UltraMotor, s: MotorState, l: Ledge) -> int:
	s.trav_normal = l.normal
	_face(s, l.normal)
	return MotorState.Id.WALL_CLIMB


static func _enter_rope(m: UltraMotor, s: MotorState, rope: UltraRope) -> int:
	s.trav_id = rope.rope_id
	s.trav_point = rope.anchor()
	var hands := s.pos + Vector3.UP * 2.0
	s.trav_s = clampf(rope.anchor().y - hands.y, 0.4, rope.length - 0.3)
	s.trav_from = s.vel                    # swing velocity lives here while on a rope
	return MotorState.Id.ROPE


## Start the climb-up from a hang / ladder top: same scripted move as a mantle.
static func start_climb_up(m: UltraMotor, s: MotorState, to: Vector3, n: Vector3) -> int:
	s.trav_kind = Move.LEDGE_CLIMB
	s.trav_from = s.pos
	s.trav_to = to
	s.trav_t = 0.0
	s.trav_dur = 0.75
	s.trav_normal = n
	_face(s, n)
	return MotorState.Id.LEDGE_CLIMB
