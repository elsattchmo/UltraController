class_name UltraLocalPlayers
extends Node
## Local players on this machine: input devices, camera rigs, HUD layers and split-screen.
##
## One local player renders straight to the window. Two or more get SubViewport panes that
## share the main World3D (vertical or horizontal split for two, quadrants for 3-4). Each
## pane hides only its own player's head. Keyboard+mouse belong to one player; pads are
## claimed per player. While `join_enabled`, pressing Join (Start / Enter) on an unclaimed
## device adds a player; holding Leave (Back) for a second removes one.

signal layout_changed(count: int)

@export var max_players := 4
@export var horizontal_two_player := false
@export var join_enabled := false
## Per-player UI: Callable(character) -> Node (a CanvasLayer), put in that player's pane.
var hud_factory: Callable
## Crosshair / prompt / ammo / hotbar / inventory. Turn off to bring your own UI.
@export var use_builtin_hud := true

var slots: Array[Dictionary] = []    ## {index, devices, rig, pane, viewport, hud, player}
var _root_ui: Control
var _leave_hold := {}


func _ready() -> void:
	_root_ui = Control.new()
	_root_ui.name = "SplitScreen"
	_root_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var layer := CanvasLayer.new()
	layer.layer = -1
	layer.name = "PaneLayer"
	add_child(layer)
	layer.add_child(_root_ui)
	get_viewport().size_changed.connect(_layout)
	UltraNet.local_input_factory = create_input
	UltraNet.player_added.connect(_on_player_added)
	UltraNet.player_removed.connect(_on_player_removed)


## Reserve device claims for the next local players before the session starts.
## Empty `devices` = this player accepts every device (single-player default).
func reserve(devices_per_player: Array) -> void:
	slots.clear()
	for i in devices_per_player.size():
		slots.append({"index": i, "devices": PackedStringArray(devices_per_player[i])})


func _slot(i: int) -> Dictionary:
	while slots.size() <= i:
		slots.append({"index": slots.size(), "devices": PackedStringArray()})
	return slots[i]


func create_input(local_index: int) -> InputSource:
	var src := LocalInputSource.new()
	var s := _slot(local_index)
	src.claimed_devices = s.devices
	return src


func local_count() -> int:
	var n := 0
	for s in slots:
		if s.has("player"):
			n += 1
	return n


func _on_player_added(p: NetPlayer) -> void:
	if not p.is_local():
		p.character.set_view_index(-1)
		return
	var s := _slot(p.local_index)
	s.player = p
	var rig := UltraCameraRig.new()
	rig.name = "CameraRig_%d" % p.local_index
	rig.view_index = p.local_index
	s.rig = rig
	add_child(rig)
	rig.attach(p.character)
	# What's under the crosshair -> prompt + InputFrame.target_id; hotbar knows the inventory.
	var scanner := UltraInteractionScanner.new()
	scanner.name = "Scanner_%d" % p.local_index
	scanner.character = p.character
	scanner.camera = rig.camera
	add_child(scanner)
	s.scanner = scanner
	var src := p.character.input_source as LocalInputSource
	if src:
		src.target_provider = scanner.target_id
		var inv := p.character.inventory
		src.slot_filled = func(i: int) -> bool: return inv.get_slot(i) != null
	if use_builtin_hud:
		var hud := UltraHUD.new()
		hud.name = "HUD_%d" % p.local_index
		hud.character = p.character
		hud.scanner = scanner
		s.builtin_hud = hud
		add_child(hud)
	if hud_factory.is_valid():
		var hud: Node = hud_factory.call(p.character)
		s.hud = hud
		add_child(hud)
	_rebuild()


func _on_player_removed(p: NetPlayer) -> void:
	for s in slots:
		if s.get("player") == p:
			for k in ["rig", "hud", "pane", "scanner", "builtin_hud"]:
				if s.has(k) and is_instance_valid(s[k]):
					(s[k] as Node).queue_free()
			for k in ["player", "rig", "hud", "pane", "viewport", "scanner", "builtin_hud"]:
				s.erase(k)
	_rebuild.call_deferred()


## Put each active rig either in the window (1 player) or in its own SubViewport pane.
func _rebuild() -> void:
	var active: Array[Dictionary] = []
	for s in slots:
		if s.has("player") and is_instance_valid(s.get("rig")):
			active.append(s)
	var split := active.size() > 1
	for s in active:
		var rig: UltraCameraRig = s.rig
		var hud: Node = s.get("hud")
		var bhud: Node = s.get("builtin_hud")
		if split and not s.has("pane"):
			var pane := SubViewportContainer.new()
			pane.stretch = true
			pane.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var vp := SubViewport.new()
			vp.world_3d = get_viewport().world_3d
			vp.audio_listener_enable_3d = s.index == 0
			vp.handle_input_locally = false
			pane.add_child(vp)
			_root_ui.add_child(pane)
			rig.reparent(vp, false)
			if hud:
				hud.reparent(vp, false)
			if bhud:
				bhud.reparent(vp, false)
			s.pane = pane
			s.viewport = vp
		elif not split and s.has("pane"):
			rig.reparent(self, false)
			if hud:
				hud.reparent(self, false)
			if bhud:
				bhud.reparent(self, false)
			(s.pane as Node).queue_free()
			s.erase("pane")
			s.erase("viewport")
		if rig.camera:
			rig.camera.current = true
	_layout()
	layout_changed.emit(active.size())


func _layout() -> void:
	var panes: Array[Control] = []
	for s in slots:
		if s.has("pane") and is_instance_valid(s.pane):
			panes.append(s.pane)
	var size := get_viewport().get_visible_rect().size
	var n := panes.size()
	for i in n:
		var r := Rect2(Vector2.ZERO, size)
		if n == 2:
			if horizontal_two_player:
				r = Rect2(0, i * size.y * 0.5, size.x, size.y * 0.5)
			else:
				r = Rect2(i * size.x * 0.5, 0, size.x * 0.5, size.y)
		elif n >= 3:
			r = Rect2((i % 2) * size.x * 0.5, (i / 2) * size.y * 0.5, size.x * 0.5, size.y * 0.5)
		panes[i].position = r.position
		panes[i].size = r.size


# ------------------------------------------------------------------ hot join / leave

func _claimed(device: String) -> bool:
	for s in slots:
		if s.has("player") and (s.devices as PackedStringArray).has(device):
			return true
	return false


func _input(event: InputEvent) -> void:
	if not join_enabled or not UltraNet.is_active():
		return
	var dev := UltraInput.device_of(event)
	if dev == "":
		return
	if event.is_action_pressed(UltraInput.action(&"join")) and not _claimed(dev) and local_count() < max_players:
		# First player was "any device": pin them to what they actually use before splitting.
		for s in slots:
			if s.has("player") and (s.devices as PackedStringArray).is_empty():
				var src := (s.player as NetPlayer).character.input_source as LocalInputSource
				var own := src.active_device if src else "kbm"
				if own == dev:
					return
				s.devices = PackedStringArray([own])
				if src:
					src.claimed_devices = s.devices
		var idx := local_count()
		_slot(idx).devices = PackedStringArray([dev])
		UltraNet.add_local_player()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not join_enabled:
		return
	for s in slots:
		if not s.has("player") or s.index == 0:
			continue
		var src := (s.player as NetPlayer).character.input_source as LocalInputSource
		if src == null:
			continue
		var held := src.pressed(&"leave") and src.active_device.begins_with("joy")
		_leave_hold[s.index] = (_leave_hold.get(s.index, 0.0) + delta) if held else 0.0
		if _leave_hold[s.index] > 1.0:
			_leave_hold[s.index] = 0.0
			UltraNet.remove_local_player(s.index)
