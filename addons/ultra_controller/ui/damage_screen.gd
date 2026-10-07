class_name UltraDamageScreen
extends Control
## Damage feedback over a player's view (a child of the HUD, one per pane):
##   - tunnel vision while bleeding / badly hurt - the edges dark, grey and blurred, closing in
##     as health drops, beating with the pulse;
##   - knocked out: blurred and dark (going under fast, coming round slowly, the blur last);
##   - killed: a quick cut to black, then how you died - every hit taken (who, with what,
##     where), limbs lost, blood lost and from where - until you respawn.
## Everything here is presentation: it reads the character's (replicated) state and the
## broadcast "hit" / "sever" / "heart" events.

const SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float tunnel = 0.0;      // 0..1 vision closing in
uniform float blur = 0.0;        // 0..1 whole-view blur
uniform float dark = 0.0;        // 0..1 darkening
uniform float double_v = 0.0;    // 0..1 double vision (knocked out / coming round)
uniform float aspect = 1.777;
uniform vec3 tint = vec3(0.25, 0.0, 0.0);
void fragment() {
	vec2 d = (UV - 0.5) * vec2(aspect, 1.0);
	float r = length(d) / (0.5 * aspect);              // 0 centre .. ~1 at the side edges
	float edge = smoothstep(0.88 - tunnel * 0.5, 1.15 - tunnel * 0.38, r) * clamp(tunnel * 1.5, 0.0, 1.0);
	float lod = blur * 5.0 + edge * 3.5;
	vec3 c = textureLod(screen_tex, SCREEN_UV, lod).rgb;
	// Double vision: a second image drifting off the first, the two never quite meeting.
	if (double_v > 0.001) {
		vec2 off = vec2(sin(TIME * 0.9) * 0.022 + 0.012, sin(TIME * 0.63 + 1.3) * 0.010) * double_v;
		vec3 c2 = textureLod(screen_tex, SCREEN_UV + off, lod + 0.6).rgb;
		vec3 c0 = textureLod(screen_tex, SCREEN_UV - off * 0.35, lod).rgb;
		c = mix(c0, c2, 0.45 * double_v);
	}
	float g = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(g), clamp(edge * 0.6 + tunnel * 0.15, 0.0, 1.0));
	c = mix(c, tint, edge * 0.25);
	c *= 1.0 - edge * 0.7;
	c *= 1.0 - dark;
	COLOR = vec4(c, 1.0);
}
"""

var character: UltraCharacter
var _fx: ColorRect
var _mat: ShaderMaterial
var _death: ColorRect
var _title: Label
var _recap: Label
var _ko := 0.0                    ## 0..1 knocked out (dark)
var _ko_blur := 0.0
var _tunnel := 0.0
var _death_a := 0.0
var _death_t := 0.0
var _died_at := -1.0                 ## game clock (s) at the death: the recap is about that moment, whenever it's read
var _pulse := 0.0
var _was_dead := false
## The damage log (since the last respawn): {t, attacker, weapon, region, amount, kind}.
var hits: Array[Dictionary] = []
var bled := {}                    ## source name -> hp lost bleeding
var lost: Array[String] = []      ## regions severed
var _heart := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx = ColorRect.new()
	_fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_fx.material = _mat
	_fx.visible = false
	add_child(_fx)
	_death = ColorRect.new()
	_death.color = Color.BLACK
	_death.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death.visible = false
	add_child(_death)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death.add_child(box)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 46)
	_title.add_theme_color_override("font_color", Color(0.85, 0.12, 0.1))
	box.add_child(_title)
	_recap = Label.new()
	_recap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recap.add_theme_font_size_override("font_size", 20)
	_recap.add_theme_color_override("font_color", Color(0.86, 0.84, 0.8))
	box.add_child(_recap)


func _enter_tree() -> void:
	for e in _events():
		UltraNet.world.off_event(e[0], e[1])
		UltraNet.world.on_event(e[0], e[1])


func _exit_tree() -> void:
	for e in _events():
		UltraNet.world.off_event(e[0], e[1])


func _events() -> Array:
	return [[&"hit", _on_hit], [&"sever", _on_sever], [&"heart", _on_heart]]


func _mine(id: int) -> bool:
	return character != null and is_instance_valid(character) and character.net_id == id


## 0..1 how dark a knockout has it (the HUD's blackout()).
func ko_amount() -> float:
	return _ko


func tunnel_amount() -> float:
	return _tunnel


func death_shown() -> float:
	return _death_a


func _process(delta: float) -> void:
	if character == null or not is_instance_valid(character):
		return
	var s := character.state
	var dp := character.damage_profile
	var dead := s.state == MotorState.Id.DEAD
	if _was_dead and not dead:
		_reset()                          # respawned
	if not _was_dead and dead:
		_death_t = 0.0
		_died_at = _clock()
		_recap.text = recap_text()
		_title.text = "YOU DIED"
	_was_dead = dead
	# Bleeding: hp per source (pure function of the replicated state, like UltraInjury.bleed_rate).
	var bleed := 0.0
	if not dead and dp and dp.limb_damage:
		bleed = UltraInjury.bleed_rate(s, dp)
		_track_bleed(s, dp, delta)
	# Knocked out: dark fast, back slowly; the blur clears last.
	var out := s.has(MotorState.F_UNCONSCIOUS)
	_ko = move_toward(_ko, 1.0 if out else 0.0, delta * (3.0 if out else 0.7))
	_ko_blur = move_toward(_ko_blur, 1.0 if out else 0.0, delta * (3.0 if out else 0.35))
	# Tunnel vision: only bleeding out, closing in (gently) as health goes.
	var hp := clampf(s.hp / 100.0, 0.0, 1.0)
	var want := 0.0
	if bleed > 0.0:
		want = clampf(0.04 + (1.0 - hp) * 0.5, 0.0, 0.55)
	if dead:
		want = 0.0
	_tunnel = move_toward(_tunnel, want, delta * 0.8)
	# The pulse: faster as health drops (and harder bleeding).
	_pulse += delta * lerpf(1.1, 2.4, 1.0 - hp) * TAU
	var beat := pow(maxf(sin(_pulse), 0.0), 6.0) * (0.07 if bleed > 0.0 else 0.0)
	var tun := clampf(_tunnel + beat * _tunnel, 0.0, 1.0)
	var show := tun > 0.002 or _ko > 0.002 or _ko_blur > 0.002
	_fx.visible = show
	if show:
		_mat.set_shader_parameter("tunnel", tun)
		# Knocked out: seeing double, a little blurred and dim (not black); coming round the dimness
		# goes first, the double image last.
		_mat.set_shader_parameter("blur", smoothstep(0.0, 1.0, _ko_blur) * 0.35)
		_mat.set_shader_parameter("dark", smoothstep(0.0, 1.0, _ko) * 0.5)
		_mat.set_shader_parameter("double_v", smoothstep(0.0, 1.0, _ko_blur))
		_mat.set_shader_parameter("aspect", size.x / maxf(size.y, 1.0))
	# Death: cut to black in a blink, then the recap fades in.
	_death_t += delta
	_death_a = move_toward(_death_a, 1.0 if dead else 0.0, delta * (9.0 if dead else 2.5))
	_death.visible = _death_a > 0.001
	_death.modulate.a = _death_a
	var text_a := smoothstep(0.35, 0.9, _death_t) if dead else _death_a
	_title.modulate.a = text_a
	_recap.modulate.a = text_a
	_death.move_to_front()


func _reset() -> void:
	hits.clear()
	_died_at = -1.0
	bled.clear()
	lost.clear()
	_heart = false
	_tunnel = 0.0


func _on_hit(target_id: int, _pos: Vector3, _dir: Vector3, amount: float, attacker_id: int, region := -1, kind := &"bullet") -> void:
	if not _mine(target_id) or kind == &"bleed":
		return
	hits.append({"t": _clock(), "attacker": _who(attacker_id), "weapon": _weapon(attacker_id, kind),
		"region": region, "amount": amount, "kind": kind})


func _on_sever(target_id: int, mask: int, _dir := Vector3.ZERO, _point := Vector3.ZERO, _kind := &"") -> void:
	if not _mine(target_id):
		return
	for r in UltraLimbs.COUNT:
		if mask & (1 << r):
			lost.append(UltraLimbs.NAMES[r])


func _on_heart(target_id: int, _point := Vector3.ZERO, _dir := Vector3.ZERO) -> void:
	if _mine(target_id):
		_heart = true


func _who(id: int) -> String:
	if id == 0:
		return ""
	if _mine(id):
		return "yourself"
	var c := UltraNet.world.character(id)
	return String(c.name) if c else "someone"


func _weapon(id: int, kind: StringName) -> String:
	var c := UltraNet.world.character(id)
	var d: ItemDefinition = c.held_def() if c else null
	match kind:
		&"impact":
			return "a thrown object"
		&"drown":
			return "drowning"
		&"fall":
			return "a fall"
	if d:
		return d.display_name if kind != &"blunt" or d.kind == ItemDefinition.Kind.MELEE else d.display_name + " (butt)"
	return String(kind)


func _track_bleed(s: MotorState, dp: DamageProfile, delta: float) -> void:
	if _heart or s.has(MotorState.F_HEART):
		_add_bled("the heart", dp.heart_bleed_rate * delta)
	for r in UltraLimbs.COUNT:
		if (s.severed >> r) & 1:
			var top := true
			for up: int in UltraLimbs.BELOW:
				if r in UltraLimbs.BELOW[up] and (s.severed >> up) & 1:
					top = false
			if top and r < dp.bleed_rate.size() and dp.bleed_rate[r] > 0.0:
				_add_bled("the " + UltraLimbs.NAMES[r] + " stump", dp.bleed_rate[r] * delta)
		elif UltraLimbs.status(s, r) == UltraLimbs.Status.CRIPPLED:
			_add_bled("the " + UltraLimbs.NAMES[r], dp.cripple_bleed_rate * delta)


func _add_bled(src: String, hp: float) -> void:
	bled[src] = float(bled.get(src, 0.0)) + hp


## Game time (physics ticks): the same on a slow and a fast machine.
func _clock() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)


## How you died, as lines: the cause, then the hits (merged by who / what / where), limbs lost,
## blood lost by source.
func recap_text() -> String:
	var lines: Array[String] = []
	var last: Dictionary = hits[-1] if not hits.is_empty() else {}
	var total_bled := 0.0
	var worst_src := ""
	for k: String in bled:
		total_bled += float(bled[k])
		if worst_src == "" or float(bled[k]) > float(bled[worst_src]):
			worst_src = k
	var at := _died_at if _died_at >= 0.0 else _clock()
	var recent := not last.is_empty() and at - float(last.t) < 0.6
	if recent and last.kind != &"drown":
		var where := " to the " + UltraLimbs.NAMES[int(last.region)] if int(last.region) >= 0 else ""
		var by := " by " + String(last.attacker) if String(last.attacker) != "" else ""
		lines.append("Killed%s - %s%s" % [by, last.weapon, where])
	elif recent:
		lines.append("Drowned")
	elif total_bled > 0.0:
		lines.append("Bled out - from %s" % worst_src)
	else:
		lines.append("Died")
	lines.append("")
	# Hits taken, merged.
	var merged := {}
	var order: Array[String] = []
	for h in hits:
		var key := "%s|%s|%d|%s" % [h.attacker, h.weapon, int(h.region), h.kind]
		if not merged.has(key):
			merged[key] = {"n": 0, "dmg": 0.0, "h": h}
			order.append(key)
		merged[key].n += 1
		merged[key].dmg += float(h.amount)
	if not order.is_empty():
		lines.append("Hits taken")
		for key in order:
			var m: Dictionary = merged[key]
			var h: Dictionary = m.h
			var where := UltraLimbs.NAMES[int(h.region)] if int(h.region) >= 0 else "body"
			var by := String(h.attacker) if String(h.attacker) != "" else "?"
			var times := " x%d" % int(m.n) if int(m.n) > 1 else ""
			var blocked := " (blocked)" if h.kind == &"blocked" else ""
			lines.append("%s%s - %s, %s%s  (%d dmg)" % [where, times, by, h.weapon, blocked, int(round(float(m.dmg)))])
	if not lost.is_empty():
		lines.append("")
		lines.append("Lost: " + ", ".join(lost))
	if total_bled > 0.5:
		lines.append("")
		var parts: Array[String] = []
		for k: String in bled:
			if float(bled[k]) >= 0.5:
				parts.append("%s %d" % [k, int(round(float(bled[k])))])
		lines.append("Blood lost: %d hp (%s)" % [int(round(total_bled)), ", ".join(parts)])
	lines.append("")
	lines.append("Respawn: %s" % _respawn_hint())
	return "\n".join(lines)


func _respawn_hint() -> String:
	var a := InputMap.action_get_events(&"uc_respawn") if InputMap.has_action(&"uc_respawn") else []
	var keys: Array[String] = []
	for e: InputEvent in a:
		keys.append(e.as_text().replace(" - Physical", "").replace(" (Physical)", ""))
	return " / ".join(keys) if not keys.is_empty() else "wait"
