class_name MansionLayout
extends RefCounted
## The mansion as data: rooms, doors, stairs, holes in the floors, light and prop kinds, zombie
## packs and markers. MansionBuilder turns it into boxes (BoxList), nodes, a navmesh and nav links.
##
## Coordinates: metres, X east, Z south (the front lawn is at z > 40, the player starts there looking
## north). The building is 56 x 40: a west wing (x 0..16), the central block (16..40: back hall, the
## double-height Great Hall, foyer, vestibule) and the east wing (40..56). Floors: -1 basement
## (floor y -3.4, under the east wing), 0 ground (y 0), 1 upstairs (y 3.65). Walls are centred on the
## rooms' edges; a wall shared by two rooms is built once.

const W_IN := 0.25                 ## interior wall thickness
const W_OUT := 0.35                ## exterior
const SLAB := 0.25
const HEIGHT := 3.4                ## clear height of a storey (floor top to the next slab's underside)
const FLOOR_Y := {-1: -3.4, 0: 0.0, 1: 3.65}
const HEIGHT_OF := {-1: 3.15, 0: 3.4, 1: 3.4}
const TALL := 7.05                 ## the Great Hall: ground floor top to the roof's underside
const DOOR_H := 2.15
const ARCH_H := 2.7
const STEPS_UP := 21               ## a storey of stairs (3.65 m: 0.174 rise)
const RUN := 0.28
const FOOTPRINT := Rect2(0, 0, 56, 40)

## name, floor, x0, z0, x1, z1, kind (floor + prop + light type), tall (double height)
const ROOMS := [
	# --- ground: west wing
	["library", 0, 0, 0, 8, 13, "library"], ["music", 0, 0, 13, 8, 25, "music"], ["w_store", 0, 0, 25, 8, 30, "store"],
	["study", 0, 0, 30, 8, 40, "study"], ["w_corr", 0, 8, 0, 10, 40, "corridor"], ["parlor", 0, 10, 0, 16, 10, "parlor"],
	["salon", 0, 10, 10, 16, 22, "parlor"], ["cloak", 0, 10, 22, 16, 29, "store"], ["w_lobby", 0, 10, 29, 16, 40, "lobby"],
	# --- ground: central block
	["back_hall", 0, 16, 0, 40, 6, "corridor"], ["hall", 0, 16, 6, 40, 28, "hall", true], ["foyer", 0, 16, 28, 40, 35, "foyer"],
	["coat_w", 0, 16, 35, 24, 40, "store"], ["vest", 0, 24, 35, 32, 40, "vest"], ["coat_e", 0, 32, 35, 40, 40, "store"],
	# --- ground: east wing
	["dining", 0, 40, 0, 56, 14, "dining"], ["serv", 0, 40, 14, 42, 28, "corridor"], ["kitchen", 0, 42, 14, 50, 28, "kitchen"],
	["pantry", 0, 50, 14, 56, 24, "pantry"], ["gunroom", 0, 50, 24, 56, 28, "store"], ["conserv", 0, 40, 28, 56, 40, "conservatory"],
	# --- upstairs: west wing
	["br1", 1, 0, 0, 8, 13, "bedroom"], ["br2", 1, 0, 13, 8, 25, "bedroom"], ["bath_w", 1, 0, 25, 8, 31, "bath"],
	["br3", 1, 0, 31, 8, 40, "bedroom"], ["w2_corr", 1, 8, 0, 10, 40, "corridor"], ["br4", 1, 10, 0, 16, 12, "bedroom"],
	["br5", 1, 10, 12, 16, 24, "bedroom"], ["linen", 1, 10, 24, 16, 30, "store"], ["landing_w", 1, 10, 30, 16, 40, "lobby"],
	# --- upstairs: central block (the hall's ring gallery)
	["back_up", 1, 16, 0, 40, 6, "corridor"], ["gallery_n", 1, 16, 6, 40, 9, "gallery"], ["gallery_w", 1, 16, 9, 19, 25, "gallery"],
	["gallery_e", 1, 37, 9, 40, 25, "gallery"], ["gallery_s", 1, 16, 25, 40, 28, "gallery"], ["loft", 1, 16, 28, 40, 35, "library"],
	["front_bed", 1, 16, 35, 40, 40, "bedroom"],
	# --- upstairs: east wing
	["master", 1, 40, 0, 56, 16, "bedroom"], ["guest", 1, 40, 16, 50, 28, "bedroom"], ["closet_b", 1, 50, 16, 56, 22, "store"],
	["e_back", 1, 50, 22, 56, 28, "bedroom"], ["sunroom", 1, 40, 28, 56, 40, "conservatory"],
	# --- basement (under the east wing)
	["gen", -1, 40, 0, 56, 14, "boiler"], ["boiler", -1, 40, 14, 50, 28, "boiler"], ["cellar", -1, 50, 14, 56, 28, "cellar"],
]

## Doors: name, floor, axis ("x": the wall runs along z at x = at; "z": along x at z = at), at, centre
## along the wall, width, kind (single | double | arch), state (closed | open | locked | barricaded),
## key id (locked only). A door's swing is decided when it opens (away from whoever opens it).
const DOORS := [
	# --- ground: west wing
	["d_lib_corr", 0, "x", 8, 6.5, 1.1, "single", "closed"], ["d_music_corr", 0, "x", 8, 19, 1.1, "single", "closed"],
	["d_wstore_corr", 0, "x", 8, 27.5, 0.9, "single", "closed"], ["d_study_corr", 0, "x", 8, 35, 1.1, "single", "locked", "red"],
	["d_parlor_corr", 0, "x", 10, 5, 1.1, "single", "closed"], ["d_salon_corr", 0, "x", 10, 16, 1.1, "single", "closed"],
	["d_cloak_corr", 0, "x", 10, 25.5, 0.9, "single", "closed"], ["d_lobby_corr", 0, "x", 10, 34.5, 1.1, "single", "closed"],
	["d_parlor_salon", 0, "z", 10, 13, 1.1, "single", "closed"], ["d_salon_cloak", 0, "z", 22, 13, 0.9, "single", "closed"],
	["d_cloak_lobby", 0, "z", 29, 13, 0.9, "single", "closed"], ["d_lib_music", 0, "z", 13, 4, 1.1, "single", "closed"],
	["d_parlor_back", 0, "x", 16, 3, 1.1, "single", "closed"], ["d_salon_hall", 0, "x", 16, 16, 1.1, "single", "closed"],
	["d_lobby_foyer", 0, "x", 16, 31.5, 1.1, "single", "closed"],
	# --- ground: central block
	["d_front", 0, "z", 40, 28, 2.4, "double", "closed"], ["d_vest_foyer", 0, "z", 35, 28, 2.0, "double", "closed"],
	["a_foyer_hall", 0, "z", 28, 28, 4.0, "arch", "open"], ["d_coatw_foyer", 0, "z", 35, 20, 0.9, "single", "closed"],
	["d_coate_foyer", 0, "z", 35, 36, 0.9, "single", "closed"], ["d_hall_back_w", 0, "z", 6, 22, 1.3, "single", "closed"],
	["d_hall_back_e", 0, "z", 6, 34, 1.3, "single", "closed"], ["d_back_dining", 0, "x", 40, 3, 1.3, "single", "closed"],
	["d_hall_serv", 0, "x", 40, 20, 1.1, "single", "closed"], ["d_hall_dining", 0, "x", 40, 10, 2.0, "double", "closed"],
	["d_foyer_conserv", 0, "x", 40, 31.5, 1.3, "single", "closed"],
	# --- ground: east wing
	["d_serv_dining", 0, "z", 14, 41, 1.0, "single", "closed"], ["d_serv_kitchen", 0, "x", 42, 20, 1.0, "single", "closed"],
	["d_kitchen_pantry", 0, "x", 50, 19, 1.0, "single", "closed"], ["d_kitchen_gun", 0, "x", 50, 26, 0.9, "single", "locked", "green"],
	["d_serv_conserv", 0, "z", 28, 41, 1.0, "single", "closed"], ["d_garden", 0, "z", 40, 48, 1.3, "single", "closed"],
	# --- upstairs: west wing
	["u_br1_corr", 1, "x", 8, 6, 1.0, "single", "closed"], ["u_br2_corr", 1, "x", 8, 19, 1.0, "single", "closed"],
	["u_bath_corr", 1, "x", 8, 28, 0.9, "single", "closed"], ["u_br3_corr", 1, "x", 8, 35, 1.0, "single", "closed"],
	["u_br4_corr", 1, "x", 10, 5, 1.0, "single", "closed"], ["u_br5_corr", 1, "x", 10, 18, 1.0, "single", "closed"],
	["u_linen_corr", 1, "x", 10, 27, 0.9, "single", "closed"], ["u_landing_corr", 1, "x", 10, 35, 1.1, "single", "closed"],
	["u_br4_gal", 1, "x", 16, 10.5, 1.0, "single", "closed"], ["u_br5_gal", 1, "x", 16, 18, 1.1, "single", "closed"],
	["u_br4_back", 1, "x", 16, 3, 1.0, "single", "closed"], ["u_landing_loft", 1, "x", 16, 32, 1.0, "single", "closed"],
	# --- upstairs: central block
	["u_gal_back", 1, "z", 6, 28, 1.3, "single", "closed"], ["u_gal_loft_w", 1, "z", 28, 24, 1.3, "single", "closed"],
	["u_gal_loft_e", 1, "z", 28, 32, 1.3, "single", "closed"], ["u_loft_front", 1, "z", 35, 28, 1.6, "double", "closed"],
	# --- upstairs: east wing
	["u_back_master", 1, "x", 40, 3, 1.1, "single", "closed"], ["u_gal_master", 1, "x", 40, 11, 1.3, "single", "closed"],
	["u_gal_guest", 1, "x", 40, 21, 1.1, "single", "closed"], ["u_guest_closet", 1, "x", 50, 19, 0.9, "single", "barricaded"],
	["u_guest_eback", 1, "x", 50, 25, 1.0, "single", "closed"], ["u_guest_sun", 1, "z", 28, 45, 1.1, "single", "closed"],
	["u_loft_sun", 1, "x", 40, 31.5, 1.1, "single", "closed"],
	# --- basement
	["b_boiler_gen", -1, "z", 14, 45, 1.3, "single", "closed"], ["b_cellar_gen", -1, "z", 14, 53, 1.1, "single", "closed"],
	["b_boiler_cellar", -1, "x", 50, 24, 1.3, "single", "closed"],
]

## Straight flights. from = (x, z) of the bottom step's front edge, dir = the way up (unit axis vector
## in x, z), width across it; y0 -> y1 over `steps` steps of RUN. `hole` = the floor opening above it
## (floor index of the slab cut, rect x0, z0, x1, z1) - none for the grand flights (the hall is open).
const STAIRS := [
	# the Great Hall's two flights, rising north along the side walls to landings on the gallery
	{"n": "grand_w", "from": [20.3, 24.0], "dir": [0, -1], "w": 2.6, "y0": 0.0, "y1": 3.65, "steps": 21},
	{"n": "grand_e", "from": [35.7, 24.0], "dir": [0, -1], "w": 2.6, "y0": 0.0, "y1": 3.65, "steps": 21},
	# the west back stair: ground lobby -> upstairs landing, rising north
	{"n": "back_w", "from": [11.0, 36.4], "dir": [0, -1], "w": 1.4, "y0": 0.0, "y1": 3.65, "steps": 21, "hole": [1, 10.3, 30.4, 11.7, 36.4]},
	# down to the cellar from the pantry, descending south along the east wall
	{"n": "cellar", "from": [54.9, 21.6], "dir": [0, -1], "w": 1.4, "y0": -3.4, "y1": 0.0, "steps": 20, "hole": [0, 54.2, 16.0, 55.6, 21.6]},
]
## Landings that continue the grand flights onto the gallery (floor 1): x0, z0, x1, z1.
const LANDINGS := [[19.0, 15.0, 21.6, 18.4], [34.4, 15.0, 37.0, 18.4]]
## The Great Hall's void above the ground floor: no floor between the gallery's inner edge.
const VOID := Rect2(19, 9, 18, 16)

## Room kind -> [floor material, prop plan]. Materials are named; MansionBuilder maps them.
const FLOOR_MAT := {
	"library": "floor_wood", "music": "floor_wood", "store": "floor_plank", "study": "floor_wood", "corridor": "floor_runner",
	"parlor": "floor_wood", "lobby": "floor_tile", "hall": "floor_marble", "foyer": "floor_marble", "vest": "floor_marble",
	"dining": "floor_wood", "kitchen": "floor_tile", "pantry": "floor_plank", "conservatory": "floor_tile", "bedroom": "floor_carpet",
	"bath": "floor_tile", "gallery": "floor_wood", "boiler": "floor_stone", "cellar": "floor_stone",
}

## Zombie packs: name, [room names to spread them over], count, archetype mix {id: weight}, wake
## ("room": wakes when a player enters one of its rooms or any pack-mate is alerted; "noise": only by
## sound / sight; "wave": only with the wave button). `dormant` = start lying down.
const PACKS := [
	{"n": "hall", "rooms": ["hall"], "count": 4, "mix": {"walker": 3, "shambler": 1}, "wake": "noise"},
	{"n": "library", "rooms": ["library", "music"], "count": 3, "mix": {"walker": 2, "limper": 1}, "wake": "room"},
	{"n": "dining", "rooms": ["dining"], "count": 4, "mix": {"walker": 3, "limper": 1}, "wake": "room"},
	{"n": "kitchen", "rooms": ["kitchen", "serv"], "count": 3, "mix": {"walker": 2, "brute": 1}, "wake": "noise"},
	{"n": "parlor", "rooms": ["parlor", "salon"], "count": 3, "mix": {"walker": 2, "shambler": 1}, "wake": "room"},
	{"n": "conserv", "rooms": ["conserv"], "count": 3, "mix": {"walker": 2, "runner": 1}, "wake": "noise"},
	{"n": "boiler", "rooms": ["boiler", "gen", "cellar"], "count": 4, "mix": {"walker": 2, "crawler": 2}, "wake": "room"},
	{"n": "master", "rooms": ["master", "guest"], "count": 4, "mix": {"walker": 2, "runner": 1, "limper": 1}, "wake": "room"},
	{"n": "closet", "rooms": ["closet_b"], "count": 3, "mix": {"crawler": 3}, "wake": "noise"},
	{"n": "bedrooms", "rooms": ["br1", "br2", "br4", "br5"], "count": 4, "mix": {"walker": 3, "brute": 1}, "wake": "room"},
	{"n": "gallery", "rooms": ["gallery_n", "gallery_w", "gallery_e", "gallery_s"], "count": 3, "mix": {"walker": 2, "shambler": 1}, "wake": "noise"},
	{"n": "lawn", "rooms": [], "count": 3, "mix": {"walker": 2, "shambler": 1}, "wake": "noise", "at": [[20, 54], [36, 56], [28, 60]]},
]


# ------------------------------------------------------------------ queries

static func room(room_name: String) -> Array:
	for r: Array in ROOMS:
		if r[0] == room_name:
			return r
	return []


static func rect_of(r: Array) -> Rect2:
	return Rect2(float(r[2]), float(r[3]), float(r[4]) - float(r[2]), float(r[5]) - float(r[3]))


static func is_tall(r: Array) -> bool:
	return r.size() > 7 and bool(r[7])


static func floor_y(f: int) -> float:
	return float(FLOOR_Y[f])


## The room (name) whose rectangle holds `p` (x, z) on floor `f`, or "".
static func room_at(p: Vector2, f: int) -> String:
	for r: Array in ROOMS:
		if int(r[1]) == f and rect_of(r).has_point(p):
			return String(r[0])
	return ""


## The floor index a world y belongs to (nearest floor below it).
static func floor_of(y: float) -> int:
	if y < -1.6:
		return -1
	if y > 1.9:
		return 1
	return 0


## Rect `r` minus the rects `holes` (each overlapping part removed): the pieces, as Rect2s.
static func subtract(r: Rect2, holes: Array) -> Array[Rect2]:
	var out: Array[Rect2] = [r]
	for h: Rect2 in holes:
		var next: Array[Rect2] = []
		for p in out:
			if not p.intersects(h):
				next.append(p)
				continue
			var cut := p.intersection(h)
			# left, right, above, below the cut (full height strips left / right, then the middle ones)
			if cut.position.x > p.position.x + 0.001:
				next.append(Rect2(p.position.x, p.position.y, cut.position.x - p.position.x, p.size.y))
			if cut.end.x < p.end.x - 0.001:
				next.append(Rect2(cut.end.x, p.position.y, p.end.x - cut.end.x, p.size.y))
			if cut.position.y > p.position.y + 0.001:
				next.append(Rect2(cut.position.x, p.position.y, cut.size.x, cut.position.y - p.position.y))
			if cut.end.y < p.end.y - 0.001:
				next.append(Rect2(cut.position.x, cut.end.y, cut.size.x, p.end.y - cut.end.y))
		out = next
	return out
