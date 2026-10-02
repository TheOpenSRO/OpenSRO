extends GatewayQuery
class_name ServerStatus

## One server's status for the server list (round 679): the question, its
## answer, and how retail turns the answer into the list's word and colour.
##
## The wire (OURS): OpServerStatusRequest 0x0007 (no payload) on a
## connection of its own (GatewayQuery), answered by OpServerStatus 0x0008:
##   u8  version (1)
##   u16 current users   } retail's shard entry carries these two and the
##   u16 max users       } state byte, in this order (READ: the list code
##   u8  state           } reads +0x20, +0x22, +0x24 of the entry; 0 = Check)
## then the server ends the connection. Retail gets the same three numbers in
## its shard list (0x6101 -> 0xA101, from the one gateway); a client of this
## project can list several servers, so it asks each one.
##
## The words and colours (READ, FUN_00869cd0 0x86a703..0x86ac51):
##   state == 0                 "Check"      UIO_STT_SERVER_TEST     0xFFC0BDFF
##   r = current / max < lo     "Easy"       UIO_STT_EXCELLENT       0xFF6DFFEF
##   r < hi                     "Populated"  UIO_STT_CROWDEDNESS     0xFFFFDA49
##   r < 1.0                    "Crowded"    UIO_STT_SERVER_FULL     0xFFFFB541
##   otherwise                  "FULL"       UIO_STT_SERVER_MAX_FULL 0xFFFF5858
## lo and hi are not constants in the code: they are textuisystem's
## UIO_STT_SERVER_35 and UIO_STT_SERVER_75 times 0.01 (DAT_00e1b820), and
## the archive's English column holds 35 and 97 (MEASURED, the box's
## Media.pk2; the Korean column says 65 for the second). Retail compares in
## x87 floats; here the same test is made in integers, cur * 100 < pct * max,
## so 97/100 against 97 is Crowded exactly (round 679's review: a float32
## 0.97 put it in Populated). A max of 0: cur > 0 gives r = inf, FULL; 0/0 is
## NaN, whose unordered compare takes the `jp` branches to Crowded (READ in
## round 679's review).
## The vSRO client measured stores 5 into a flag (0x832a68) that turns FULL
## into a red "Crowded" (INFERRED a patch); this client shows retail's FULL.
##
## Not reachable (OURS): retail has one gateway, and when it cannot connect it
## says so in a message box, "Failed to connect to server."
## (UIO_MSG_ERROR_SEVER_CONNECT) -- there is no per-row state for it. A row
## here whose server does not answer shows UIO_STT_TEST, "Closed" -- a word
## the archive carries but the exe never names (READ, string scan) -- in the
## list's own default text colour 0xFFB4B4B4 (READ, FUN_008b2ba0(3, ...)).

##
## Round 681: a server whose config entry says `type: legacy` speaks the
## ORIGINAL gateway protocol and is asked the way retail asks
## (RetailGatewayClient: the handshake, 0x2001, 0x6100, then 0x6101 ->
## 0xA101), never with 0x0007; its answer is a list of shards, each banded by
## the same compare (band_for). `type: srrevamp` is the 0x0007 question above
## and never waits for a 0x5000.

signal finished(status: ServerStatus, why: String)

const TYPE_SRREVAMP := "srrevamp"
const TYPE_LEGACY := "legacy"
## OURS: the legacy exchange is about five round trips; all of it, every
## attempt included, inside this, which is under the 5 s refresh.
const LEGACY_TIMEOUT_MS := 4000
## OURS: a session given a checksum table that cannot be built is ended
## before it sends anything and tried again (37 of 255, MEASURED:
## RetailSecurity.UNKNOWN_CRC_INDICES); three tries fail together about 0.3 %
## of the time.
const LEGACY_ATTEMPTS := 3
## OURS: what one legacy attempt may read, and hold unread (two of the
## largest frames, RetailSecurity.MAX_FRAME).
const LEGACY_TOTAL_BYTES := 64 * 1024
const LEGACY_FRAME_BUFFER := 2 * RetailSecurity.MAX_FRAME

const OP_REQUEST := 0x0007
const OP_STATUS := 0x0008
const VERSION := 1
## OURS: a list of servers is asked in parallel; a dead one should not leave
## its row blank for long.
const TIMEOUT_MS := 2000
## READ: CPSTitle::FUN_00864840 re-asks every 5.0 s (0xe1b86c) while window
## 10, the server list, is visible (CPSTitle::vslot_012).
const REFRESH_S := 5.0

enum Band { PENDING, UNREACHABLE, CHECK, EASY, POPULATED, CROWDED, FULL }

## MEASURED fallbacks for the two thresholds when the text table is not
## there: the English column of the box's textuisystem (see above).
const LO_FALLBACK := 35
const HI_FALLBACK := 97

const BAND_KEYS := {
	Band.UNREACHABLE: "UIO_STT_TEST",
	Band.CHECK: "UIO_STT_SERVER_TEST",
	Band.EASY: "UIO_STT_EXCELLENT",
	Band.POPULATED: "UIO_STT_CROWDEDNESS",
	Band.CROWDED: "UIO_STT_SERVER_FULL",
	Band.FULL: "UIO_STT_SERVER_MAX_FULL",
}
## The English words, for a run without the text table (the archive's own,
## MEASURED).
const BAND_FALLBACK := {
	Band.PENDING: "",
	Band.UNREACHABLE: "Closed",
	Band.CHECK: "Check",
	Band.EASY: "Easy",
	Band.POPULATED: "Populated",
	Band.CROWDED: "Crowded",
	Band.FULL: "FULL",
}
const BAND_COLORS := {
	Band.PENDING: 0xFFB4B4B4,
	Band.UNREACHABLE: 0xFFB4B4B4,
	Band.CHECK: 0xFFC0BDFF,
	Band.EASY: 0xFF6DFFEF,
	Band.POPULATED: 0xFFFFDA49,
	Band.CROWDED: 0xFFFFB541,
	Band.FULL: 0xFFFF5858,
}

var current := 0
var capacity := 0
var state := 0
var answered_ok := false
## Round 681: srrevamp or legacy (ClientConfig.ServerEntry.type).
var server_type := TYPE_SRREVAMP
## Legacy: {"content_id", "version"} from Media.pk2 (RetailClientInfo), or
## {"error"} when they cannot be read.
var client_info := {}
## Legacy: the key exchange's private value for a test (-1 = random).
var private_x := -1
## Legacy: the shards the gateway listed ({id, name, current, capacity,
## state, farm}).
var shards: Array = []
var _conv: RetailGatewayClient = null

func _init() -> void:
	timeout_ms = TIMEOUT_MS

## Asks `entry`'s server the way its type says. `info` is the archive's
## content id and version (RetailClientInfo.from_media), used by legacy only.
func start_for(entry: ClientConfig.ServerEntry, info: Dictionary) -> void:
	server_type = entry.type
	client_info = info
	if server_type == TYPE_LEGACY:
		timeout_ms = LEGACY_TIMEOUT_MS
		max_attempts = LEGACY_ATTEMPTS
		max_total_bytes = LEGACY_TOTAL_BYTES
		max_frame_buffer = LEGACY_FRAME_BUFFER
		if not info.has("content_id"):
			_started_ms = Time.get_ticks_msec()
			_finish.call_deferred(null, "legacy: %s" % info.get("error", "no content id and version"))
			return
	start(entry.gateway_host, entry.gateway_port)

## READ (above): the band for an answer.
## `lo` and `hi` are whole percents (textuisystem's numbers).
static func band_for(cur: int, max_users: int, operating: int, lo: int, hi: int) -> int:
	if operating == 0:
		return Band.CHECK
	if max_users <= 0:
		return Band.FULL if cur > 0 else Band.CROWDED
	if cur * 100 < lo * max_users:
		return Band.EASY
	if cur * 100 < hi * max_users:
		return Band.POPULATED
	if cur < max_users:
		return Band.CROWDED
	return Band.FULL

## The thresholds as retail reads them: textuisystem's UIO_STT_SERVER_35 and
## UIO_STT_SERVER_75 times 0.01, each falling back (MEASURED values) when
## the table or the row is missing or not a number.
## Whole percents (x = lo, y = hi).
static func thresholds(text: UiTextTable) -> Vector2i:
	return Vector2i(_percent(text, "UIO_STT_SERVER_35", LO_FALLBACK), _percent(text, "UIO_STT_SERVER_75", HI_FALLBACK))

static func _percent(text: UiTextTable, key: String, fallback: int) -> int:
	if text == null or not text.has(key):
		return fallback
	var s := text.get_text(key, "").strip_edges()
	if not s.is_valid_int() or s.to_int() < 0 or s.to_int() > 1000:
		return fallback
	return s.to_int()

static func band_text(b: int, text: UiTextTable) -> String:
	var fallback: String = BAND_FALLBACK.get(b, "")
	if text != null and BAND_KEYS.has(b) and text.has(BAND_KEYS[b]):
		var t := text.get_text(BAND_KEYS[b], fallback)
		if t != "":
			return t
	return fallback

static func band_color(b: int) -> Color:
	return argb_color(int(BAND_COLORS.get(b, 0xFFB4B4B4)))

## A retail ARGB dword as a Color.
static func argb_color(argb: int) -> Color:
	return Color8((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF)

# --- The query ---------------------------------------------------------------

func _request() -> PackedByteArray:
	if server_type == TYPE_LEGACY:
		return PackedByteArray() # READ: a retail gateway speaks first (0x5000)
	return Packet.new(OP_REQUEST).encode()

func _on_reconnect() -> void:
	_conv = null

func _read(buf: PackedByteArray) -> Dictionary:
	if server_type == TYPE_LEGACY:
		return _read_legacy(buf)
	var r := parse_frames(buf)
	if r.has("status"):
		return {"value": r["status"]}
	return r

## The first frame: {"status": {current, capacity, state}} when it is a
## complete OpServerStatus, {"error"} when it is anything else, {} to wait.
static func parse_frames(buf: PackedByteArray) -> Dictionary:
	var frame := first_frame(buf)
	if frame.is_empty():
		return {}
	if int(frame["opcode"]) != OP_STATUS:
		return {"error": "the first frame is opcode 0x%04x, not a status" % int(frame["opcode"])}
	if not frame.has("payload"):
		return {}
	var p: PackedByteArray = frame["payload"]
	if p.size() < 6:
		return {"error": "status frame too short (%d bytes)" % p.size()}
	if p[0] != VERSION:
		return {"error": "status version %d, not %d" % [p[0], VERSION]}
	return {"status": {"current": p.decode_u16(1), "capacity": p.decode_u16(3), "state": p[5]}}

func _read_legacy(buf: PackedByteArray) -> Dictionary:
	if _conv == null:
		_conv = RetailGatewayClient.new(int(client_info["content_id"]), int(client_info["version"]), private_x)
	var r := _conv.feed(buf)
	var out := {"consumed": r["consumed"], "send": r["send"]}
	if r["error"] != "":
		out["retry" if r["retry"] else "error"] = "legacy: " + str(r["error"])
	elif _conv.done():
		out["value"] = {"shards": _conv.shards}
	return out

func _answered(value, why: String) -> void:
	if value is Dictionary and value.has("shards"):
		shards = value["shards"]
		answered_ok = true
	elif value is Dictionary:
		current = value["current"]
		capacity = value["capacity"]
		state = value["state"]
		answered_ok = true
	else:
		answered_ok = false
	finished.emit(self, why)

## A legacy shard's band (the same compare as retail's list).
static func shard_band(shard: Dictionary, t: Vector2i) -> int:
	return band_for(int(shard["current"]), int(shard["capacity"]), int(shard["state"]), t.x, t.y)

## The band for this query's outcome with the given thresholds (for a legacy
## server that answered: its first shard's, or UNREACHABLE when it listed
## none).
func band_with(t: Vector2i) -> int:
	if not is_done():
		return Band.PENDING
	if not answered_ok:
		return Band.UNREACHABLE
	if server_type == TYPE_LEGACY:
		return Band.UNREACHABLE if shards.is_empty() else shard_band(shards[0], t)
	return band_for(current, capacity, state, t.x, t.y)
