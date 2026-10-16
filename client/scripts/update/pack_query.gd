extends GatewayQuery
class_name PackQuery

## Asks a server which packs it needs (round 789, lane U; OURS,
## docs/protocol/asset_packs.md "Server packs"): one short-lived connection
## of its own (GatewayQuery, as ThemeQuery and the server list's status do),
## OpClientPacksRequest (0x0009, no payload) out, one OpClientPacks (0x000A,
## PackManifest) back, closed.
##
## A server from before round 789 does not know the request and sends
## nothing: the query gives up after TIMEOUT_MS and the client goes on with
## its own packs, as before. Every newer server answers, with or without
## packs, so only an old server costs the wait.

signal finished(manifest: PackManifest, why: String)

## OURS: a little longer than the theme's 1.5 s -- this one is asked when
## Connect is pressed, not at boot, and an answer that comes late means a
## login that goes out without the packs the server needs.
const TIMEOUT_MS := 2500

var result_manifest: PackManifest = null
var result_why := ""

func _init() -> void:
	timeout_ms = TIMEOUT_MS

func _request() -> PackedByteArray:
	return Packet.new(PackManifest.OP_REQUEST).encode()

func _read(buf: PackedByteArray) -> Dictionary:
	return parse_frames(buf)

## The FIRST frame: {"value": PackManifest} when it is a complete
## OpClientPacks (decoded, maybe with an error), {"error": why} when it is
## another opcode, {} to keep waiting.
static func parse_frames(buf: PackedByteArray) -> Dictionary:
	var frame := first_frame(buf)
	if frame.is_empty():
		return {}
	if int(frame["opcode"]) != PackManifest.OP_MANIFEST:
		return {"error": "the first frame is opcode 0x%04x, not the pack list" % int(frame["opcode"])}
	if not frame.has("payload"):
		return {}
	return {"value": PackManifest.decode(frame["payload"])}

func _answered(value, why: String) -> void:
	result_manifest = value as PackManifest
	result_why = why
	finished.emit(result_manifest, why)
