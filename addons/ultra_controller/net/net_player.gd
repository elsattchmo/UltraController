class_name NetPlayer
extends RefCounted
## One player in a session (a peer can own several: split-screen).

enum Role {
	AUTHORITY_LOCAL,    ## simulated here, input from this machine (single-player, host's own)
	AUTHORITY_REMOTE,   ## simulated here (server), input arrives from a client
	PREDICTED,          ## client-side: our own player, predicted and reconciled
	INTERPOLATED,       ## client-side: somebody else's player, shown from snapshots
}

const HISTORY := 128

var id: int = 0
var peer_id: int = 1
var local_index: int = 0          ## index among the owning peer's local players
var display_name := ""
## Server-side AI player (companion, scenario bot): simulated like a local authority player
## but never given a camera or local input.
var is_bot := false
var role: int = Role.AUTHORITY_LOCAL
var character: UltraCharacter

# --- server side (AUTHORITY_*)
var queue: Array[InputFrame] = []
var last_received_tick: int = -1
var last_processed_tick: int = -1
var last_processed_server_tick: int = 0
var last_input := InputFrame.new()
var misses: int = 0
var gap_wait: int = 0
var processed: int = 0

# --- client side (PREDICTED)
var client_tick: int = 0
var last_acked: int = -1
## server_tick - client_tick for our frames (moving platforms need the server's clock).
var server_tick_offset: int = 0
## Client: the first of our ticks predicted with the server's clock known (set at the first ack).
var synced_from: int = -1
var input_history: Array = []      ## [InputFrame] ring by tick % HISTORY
var state_history: Array = []      ## [MotorState] after simulating that tick
var server_queue_depth: int = 0
var corrections: int = 0
var correction_sum: float = 0.0
var correction_max: float = 0.0
var last_correction: float = 0.0

# --- client side (INTERPOLATED)
var snaps: Array = []              ## [{tick, pos, vel, yaw, pitch, state...}] ascending


func _init() -> void:
	input_history.resize(HISTORY)
	state_history.resize(HISTORY)


func is_local() -> bool:
	return not is_bot and (role == Role.AUTHORITY_LOCAL or role == Role.PREDICTED)


func record(tick: int, input: InputFrame, after: MotorState) -> void:
	input_history[tick % HISTORY] = input
	state_history[tick % HISTORY] = after


func history_input(tick: int) -> InputFrame:
	var f: InputFrame = input_history[tick % HISTORY]
	return f if f and f.tick == tick else null


func history_state(tick: int) -> MotorState:
	return state_history[tick % HISTORY]
