extends Node3D
## Counterweight lift: a basket on one side, a platform on the other. The platform rises with
## the weight in the basket (rigid bodies by mass) minus half the weight standing on the
## platform. Server-authoritative; height replicates as object state.

@export var rise := 5.0
@export var counterweight_kg := 45.0

var height := 0.0
var _platform: AnimatableBody3D
var _basket: Area3D
var _deck: Area3D
var _sent := 0.0


func _ready() -> void:
	_platform = $Platform
	_basket = $Basket
	_deck = $Platform/Deck
	var o := NetObject.new()
	o.name = "NetObject"
	add_child(o)


func _physics_process(delta: float) -> void:
	if UltraNet.is_server():
		var kg := 0.0
		for b in _basket.get_overlapping_bodies():
			if b is RigidBody3D:
				kg += (b as RigidBody3D).mass
		var rider := 0.0
		for b in _deck.get_overlapping_bodies():
			if b is UltraCharacter:
				rider += (b as UltraCharacter).profile.mass
		var want := clampf((kg - rider * 0.5) / counterweight_kg, 0.0, 1.0) * rise
		height = move_toward(height, want, delta * 0.8)
		if absf(height - _sent) > 0.05:
			_sent = height
			(find_child("NetObject", false, false) as NetObject).mark_dirty()
	_platform.position.y = lerpf(_platform.position.y, height, 1.0 - exp(-10.0 * delta))
	$Basket.position.y = rise - _platform.position.y * 0.9


func get_net_state() -> Dictionary:
	return {"h": height}


func set_net_state(d: Dictionary) -> void:
	height = float(d.get("h", height))
