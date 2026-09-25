package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"sync/atomic"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// World opcodes, our own protocol. OpEnterWorld requires a prior OpLogin;
// OpMove requires a prior successful OpEnterWorld on the same connection.
const (
	OpEnterWorld       uint16 = 0x0020 // client -> server
	OpEnterWorldResult uint16 = 0x0021 // server -> client
	OpMove             uint16 = 0x0022 // client -> server, no reply
	OpEntityEntered    uint16 = 0x0023 // server -> client, broadcast
	OpEntityMoved      uint16 = 0x0024 // server -> client, broadcast
	OpEntityLeft       uint16 = 0x0025 // server -> client, broadcast
	OpChangeZone       uint16 = 0x0026 // client -> server
	OpChangeZoneResult uint16 = 0x0027 // server -> client
)

// spawnZone/spawnPos are the single fixed starting point every character
// enters at. Placeholder until real map data exists — see
// docs/protocol/db_schema.md's note that map/zone data hasn't been pulled
// apart yet.
const spawnZone = "jangan"

var spawnPos = world.Position{X: 0, Y: 0, Z: 0}

// EntitySnapshot describes one character's presence in the world: who they
// are, where they are, what they have equipped, and their Gender (one of
// character.GenderChinaMan/GenderChinaWoman), which picks the body the
// client draws them with.
//
// Equipped is every wearable slot the character has something in, with the
// item id, queried live from the equipment store at broadcast time (see
// equippedItems) so it always reflects the character's actual state. The
// item id is what the client needs: its own item table names the model
// each item is worn as, so "slot 1 holds item 4842" is enough to draw a
// Cotton Suit rather than a suit of the client's choosing -- which is what
// the earlier per-slot bitmask plus has-weapon/has-shield booleans left it
// doing.
type EntitySnapshot struct {
	CharacterID int64
	Name        string
	X, Y, Z     float32
	// Equipped lists what is worn, in slot order. Nil and empty are the
	// same thing on the wire.
	Equipped []EquippedSnapshot
	Gender   string
}

// EquippedIn reports the item id in slot, or 0 if nothing is worn there.
func (e *EntitySnapshot) EquippedIn(slot equipment.Slot) int64 {
	for _, it := range e.Equipped {
		if equipment.Slot(it.Slot) == slot {
			return it.ItemID
		}
	}
	return 0
}

func (e *EntitySnapshot) Encode() []byte {
	out := encodeInt64(e.CharacterID)
	out = append(out, encodeStrings(e.Name)...)
	out = append(out, encodeFloat32(e.X)...)
	out = append(out, encodeFloat32(e.Y)...)
	out = append(out, encodeFloat32(e.Z)...)
	// One byte of count, then a slot byte and an item id per entry.
	out = append(out, byte(len(e.Equipped)))
	for _, it := range e.Equipped {
		out = append(out, byte(it.Slot))
		out = append(out, encodeInt64(it.ItemID)...)
	}
	out = append(out, encodeStrings(e.Gender)...)
	return out
}

// decodeEntitySnapshot parses one EntitySnapshot from the front of data,
// returning it along with whatever bytes remain.
func decodeEntitySnapshot(data []byte) (*EntitySnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("character id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("name: %w", err)
	}
	x, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("x: %w", err)
	}
	y, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("y: %w", err)
	}
	z, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("z: %w", err)
	}
	if len(rest) < 1 {
		return nil, nil, fmt.Errorf("equipped count: %w", errors.New("truncated"))
	}
	count := int(rest[0])
	rest = rest[1:]
	var equipped []EquippedSnapshot
	for i := 0; i < count; i++ {
		if len(rest) < 1 {
			return nil, nil, fmt.Errorf("equipped[%d] slot: %w", i, errors.New("truncated"))
		}
		slot := int(rest[0])
		rest = rest[1:]
		itemID, after, err := decodeInt64(rest)
		if err != nil {
			return nil, nil, fmt.Errorf("equipped[%d] item id: %w", i, err)
		}
		rest = after
		equipped = append(equipped, EquippedSnapshot{Slot: slot, ItemID: itemID})
	}

	genderFields, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("gender: %w", err)
	}

	return &EntitySnapshot{CharacterID: id, Name: names[0], X: x, Y: y, Z: z, Equipped: equipped, Gender: genderFields[0]}, rest, nil
}

// equippedItems reports every wearable slot characterID has something in,
// with the item id, in one equipment-store lookup. eq may be nil (some
// handler chains -- tests exercising features unrelated to equipment --
// wire up WorldHandler without an equipment store), in which case this
// reports nothing worn rather than requiring every caller to carry one
// around. Errors are treated the same way: an equipment lookup failure
// should not block someone from entering the world or moving, and
// reporting nothing worn is the honest failure mode -- it never claims a
// piece that could not be confirmed.
func equippedItems(ctx context.Context, eq equipment.Store, characterID int64) []EquippedSnapshot {
	if eq == nil {
		return nil
	}
	items, err := eq.Get(ctx, characterID)
	if err != nil {
		return nil
	}
	var out []EquippedSnapshot
	for _, it := range items {
		out = append(out, EquippedSnapshot{Slot: int(it.Slot), ItemID: it.ItemID})
	}
	return out
}

// genderOf looks up characterID's real Gender via chars.GetByID, live at
// broadcast time -- world.Entity doesn't carry it (that package deliberately
// only tracks position/presence, not character details -- same reasoning
// as equippedSlots not living in world.Entity either). Falls back to
// character.DefaultGender on any lookup error, the same honest-failure
// convention as equippedSlots: never block a broadcast over this, and
// never guess at a value that couldn't be confirmed.
func genderOf(ctx context.Context, chars character.Store, characterID int64) string {
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return character.DefaultGender
	}
	return c.Gender
}

func entitySnapshotFromWorld(ctx context.Context, eq equipment.Store, chars character.Store, e world.Entity) EntitySnapshot {
	return EntitySnapshot{
		CharacterID: e.CharacterID,
		Name:        e.Name,
		X:           float32(e.Pos.X), Y: float32(e.Pos.Y), Z: float32(e.Pos.Z),
		Equipped: equippedItems(ctx, eq, e.CharacterID),
		Gender:   genderOf(ctx, chars, e.CharacterID),
	}
}

// EnterWorldRequest is the OpEnterWorld payload.
type EnterWorldRequest struct {
	CharacterName string
}

func (r *EnterWorldRequest) Encode() []byte { return encodeStrings(r.CharacterName) }

func DecodeEnterWorldRequest(data []byte) (*EnterWorldRequest, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, err
	}
	return &EnterWorldRequest{CharacterName: fields[0]}, nil
}

// EnterWorldResult is the OpEnterWorldResult payload. On failure, only
// OK/Reason are meaningful -- Zone/position/Gender/Others/FrameRegion aren't
// encoded.
// Gender is the entering character's own real Gender (see
// character.GenderChinaMan/GenderChinaWoman) -- the client needs this to
// build its *own* real assembled character; Others already carries each
// other player's Gender via EntitySnapshot.
type EnterWorldResult struct {
	OK      bool
	Reason  string
	Zone    string
	X, Y, Z float32
	Gender  string
	// HP and MaxHP let the client draw a real health bar from the moment it
	// enters the world. Combat already reports PlayerHP on every attack, so
	// this is the missing initial value rather than a new channel.
	HP     int32
	MaxHP  int32
	Others []EntitySnapshot
	// FrameRegion is the region X/Y/Z are relative to, "x/y" (round 570; see
	// frameFor, and arrival for -single-frame's "97/168", round 571), or ""
	// when the zone has none. It trails Others, where an
	// older client stops reading -- WorldNet.decode_enter_world_result
	// returns after the entity list without looking at what is left, the
	// same way StorageListResult's trailing capacity reaches older clients
	// -- and an older server's payload, which ends at Others, decodes it as
	// "".
	FrameRegion string
}

func (r *EnterWorldResult) Encode() []byte {
	out := encodeOKReason(r.OK, r.Reason)
	if !r.OK {
		return out
	}
	out = append(out, encodeStrings(r.Zone)...)
	out = append(out, encodeFloat32(r.X)...)
	out = append(out, encodeFloat32(r.Y)...)
	out = append(out, encodeFloat32(r.Z)...)
	out = append(out, encodeStrings(r.Gender)...)
	vitals := make([]byte, 8)
	binary.LittleEndian.PutUint32(vitals[0:4], uint32(r.HP))
	binary.LittleEndian.PutUint32(vitals[4:8], uint32(r.MaxHP))
	out = append(out, vitals...)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Others)))
	out = append(out, countBuf...)
	for _, o := range r.Others {
		out = append(out, o.Encode()...)
	}
	return append(out, encodeStrings(r.FrameRegion)...)
}

func DecodeEnterWorldResult(data []byte) (*EnterWorldResult, error) {
	// Can't use decodeOKReason here: it requires nothing follow the Reason
	// field, but this payload has Zone/position/Others after it when
	// OK=true. Decode the OK byte and Reason field manually instead,
	// keeping whatever's left for the rest of the fields.
	if len(data) < 1 {
		return nil, errors.New("session: decoding EnterWorldResult: empty payload")
	}
	ok := data[0] != 0
	reasonFields, rest, err := decodeStringsPrefix(data[1:], 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EnterWorldResult: reason: %w", err)
	}
	r := &EnterWorldResult{OK: ok, Reason: reasonFields[0]}
	if !ok {
		return r, nil
	}

	zoneFields, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EnterWorldResult: zone: %w", err)
	}
	r.Zone = zoneFields[0]

	r.X, rest, err = decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EnterWorldResult: x: %w", err)
	}
	r.Y, rest, err = decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EnterWorldResult: y: %w", err)
	}
	r.Z, rest, err = decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EnterWorldResult: z: %w", err)
	}

	genderFields, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EnterWorldResult: gender: %w", err)
	}
	r.Gender = genderFields[0]

	if len(rest) < 8 {
		return nil, errors.New("session: decoding EnterWorldResult: truncated vitals")
	}
	r.HP = int32(binary.LittleEndian.Uint32(rest[0:4]))
	r.MaxHP = int32(binary.LittleEndian.Uint32(rest[4:8]))
	rest = rest[8:]

	if len(rest) < 2 {
		return nil, errors.New("session: decoding EnterWorldResult: truncated entity count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *EntitySnapshot
		snap, rest, err = decodeEntitySnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding EnterWorldResult: entity %d: %w", i, err)
		}
		r.Others = append(r.Others, *snap)
	}
	if r.FrameRegion, err = decodeFrameRegion(rest); err != nil {
		return nil, fmt.Errorf("session: decoding EnterWorldResult: %w", err)
	}
	return r, nil
}

// decodeFrameRegion reads the FrameRegion that trails an EnterWorldResult or
// a ChangeZoneResult (round 570): "" when nothing follows the entity list --
// an older server's payload -- and an error when the field is cut short.
func decodeFrameRegion(rest []byte) (string, error) {
	if len(rest) == 0 {
		return "", nil
	}
	fields, _, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return "", fmt.Errorf("frame region: %w", err)
	}
	return fields[0], nil
}

// frameFor is the FrameRegion a result names for zone with -single-frame off:
// worldmap.FrameFor's region as "x/y", or "" for a label with none (the
// client then keeps its own reading of the label, as every client did before
// round 570). For every label it is the zone's own centre -- the region the
// client builds its grid around, whose middle is spawnPos -- so it names the
// frame the coordinates were already in rather than changing it. arrival
// names worldmap.WorldOrigin instead when the flag is on.
func frameFor(zone string) string {
	rx, ry, ok := worldmap.FrameFor(zone)
	if !ok {
		return ""
	}
	return fmt.Sprintf("%d/%d", rx, ry)
}

// singleFrame is cmd/server's -single-frame (SRREVAMP_SINGLE_FRAME), OFF by
// default (round 571): every zone with a frame in ONE world frame, centred on
// worldmap.WorldOrigin (Jangan's 97/168), and in ONE hub bucket,
// worldmap.WorldBucket, where every roster monster is kept too -- so a player
// who walks from Jangan toward Donwhang stays in the coordinates and the
// broadcasts of everyone else and reaches Donwhang's monsters. OWN DESIGN,
// disclosed (worldmap.WorldOrigin). An atomic, like the monster flags: set on
// the boot goroutine before the gateway serves, read by every handler.
var singleFrame atomic.Bool

// SetSingleFrame turns the one world frame on or off. cmd/server calls it once
// at boot, before the roster spawns (its monsters' zone and coordinates read
// it through ZoneBucket and SingleFrame) and before the gateway serves. Off,
// every zone keeps its own frame and bucket and the wire is what it was.
func SetSingleFrame(on bool) { singleFrame.Store(on) }

// SingleFrame reports whether -single-frame is on, for cmd/server's roster:
// its placements are converted into worldmap.WorldOrigin's frame when it is.
func SingleFrame() bool { return singleFrame.Load() }

// ZoneBucket is the world hub's zone -- the bucket an entity is kept and
// broadcast in (world.Entity.Zone) -- for something in zone label `zone`:
// the label itself, as it has always been, or worldmap.WorldBucket for every
// label worldmap.FrameFor knows (the named towns and any "x/y" region) while
// -single-frame is on. A label with no frame ("Jangan", a typo) keeps its own
// bucket with the flag on too: the client builds such a label in its own
// frame (FrameRegion ""), so its coordinates cannot share the world's. That
// includes a label spelled like the bucket itself, "world": it then lands in
// the world's bucket at spawnPos, which is Jangan's middle in the one frame
// (worldmap.Landing of "jangan") -- a real place in it, harmless.
func ZoneBucket(zone string) string {
	if singleFrame.Load() {
		if _, _, ok := worldmap.FrameFor(zone); ok {
			return worldmap.WorldBucket
		}
	}
	return zone
}

// arrival is where a character entering the world or changing zone to zone
// is kept, where it stands and which frame the result names:
//
//   - -single-frame off, or a label with no frame: the zone's own bucket,
//     spawnPos and frameFor(zone) -- the wire as it was.
//   - -single-frame on and a label with a frame: worldmap.WorldBucket,
//     worldmap.Landing(zone) in worldmap.WorldOrigin's frame -- the middle of
//     the zone's centre region, the same place spawnPos is in the zone's own
//     frame, named in the world's (a Donwhang arrival stands at
//     ToWorld(102, 153, 960, 960, 97, 168)) -- and FrameRegion "97/168". The
//     client builds the zone's grid around its centre in that frame (round
//     570's _load_region_neighborhood), so the landing is inside the grid,
//     not at the frame region's middle; y stays spawnPos's 0, and the client
//     snaps it onto the ground (the heights under the one frame are round
//     571's table). oneWorld is then true.
func arrival(zone string) (bucket string, pos world.Position, frame string, oneWorld bool) {
	if singleFrame.Load() {
		if x, z, ok := worldmap.Landing(zone, worldmap.WorldOrigin[0], worldmap.WorldOrigin[1]); ok {
			frame = fmt.Sprintf("%d/%d", worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
			return ZoneBucket(zone), world.Position{X: x, Y: spawnPos.Y, Z: z}, frame, true
		}
	}
	return zone, spawnPos, frameFor(zone), false
}

// MoveRequest is the OpMove payload: a new position, no reply expected.
type MoveRequest struct {
	X, Y, Z float32
}

func (r *MoveRequest) Encode() []byte {
	out := encodeFloat32(r.X)
	out = append(out, encodeFloat32(r.Y)...)
	out = append(out, encodeFloat32(r.Z)...)
	return out
}

func DecodeMoveRequest(data []byte) (*MoveRequest, error) {
	x, rest, err := decodeFloat32(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding MoveRequest: x: %w", err)
	}
	y, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding MoveRequest: y: %w", err)
	}
	z, _, err := decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding MoveRequest: z: %w", err)
	}
	return &MoveRequest{X: x, Y: y, Z: z}, nil
}

// EntityMoved is the OpEntityMoved broadcast payload.
type EntityMoved struct {
	CharacterID int64
	X, Y, Z     float32
}

func (r *EntityMoved) Encode() []byte {
	out := encodeInt64(r.CharacterID)
	out = append(out, encodeFloat32(r.X)...)
	out = append(out, encodeFloat32(r.Y)...)
	out = append(out, encodeFloat32(r.Z)...)
	return out
}

func DecodeEntityMoved(data []byte) (*EntityMoved, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EntityMoved: %w", err)
	}
	x, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EntityMoved: %w", err)
	}
	y, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EntityMoved: %w", err)
	}
	z, _, err := decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EntityMoved: %w", err)
	}
	return &EntityMoved{CharacterID: id, X: x, Y: y, Z: z}, nil
}

// ChangeZoneRequest is the OpChangeZone payload: a target zone identifier,
// no reply-carrying name field needed since the session already identifies
// exactly one in-world character (same minimalism as MoveRequest). Zone is
// an opaque string as far as the server's concerned -- see spawnZone's doc
// comment and docs/protocol/MAPO_FORMAT.md/MAPM_FORMAT.md: real Map.pk2
// region files are keyed by an (x, y) folder/filename pair (e.g. "100/100",
// "102/101"), so a client pointed at real map data is expected to pass a
// zone string shaped that way, but the server itself never parses Map.pk2
// and has no way to validate a zone actually exists -- it only tracks who's
// in which zone label, the same as it always has.
type ChangeZoneRequest struct {
	Zone string
}

func (r *ChangeZoneRequest) Encode() []byte { return encodeStrings(r.Zone) }

func DecodeChangeZoneRequest(data []byte) (*ChangeZoneRequest, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, err
	}
	return &ChangeZoneRequest{Zone: fields[0]}, nil
}

// ChangeZoneResult is the OpChangeZoneResult payload, direct ack to whoever
// requested the zone change. On failure only OK/Reason are meaningful.
// A zone change is a discrete warp to a fixed point: spawnPos, the middle of
// the new zone's centre region, with -single-frame off, and the same place in
// the one world frame with it on (FrameRegion below). Others mirrors
// EnterWorldResult's own field: the mover
// needs a fresh "who's already here" snapshot of the new zone, the same as
// entering the world the first time -- their own client has no other way to
// learn who else is present (broadcasts only reach everyone *else*).
//
// FrameRegion (round 570) is the region X/Y/Z are relative to, trailing
// Others exactly as EnterWorldResult's does. Position is in that frame: with
// -single-frame off every zone's frame is its own centre, so spawnPos is the
// centre region's middle. With it on (round 571) the frame is
// worldmap.WorldOrigin for every zone with a frame, and the position is the
// same place named in it, worldmap.Landing -- inside the zone's centre region,
// because the client builds its grid around the centre and (0, 0, 0) would be
// the FRAME region's middle, off that grid (arrival).
type ChangeZoneResult struct {
	OK          bool
	Reason      string
	Zone        string
	X, Y, Z     float32
	Others      []EntitySnapshot
	FrameRegion string
}

func (r *ChangeZoneResult) Encode() []byte {
	out := encodeOKReason(r.OK, r.Reason)
	if !r.OK {
		return out
	}
	out = append(out, encodeStrings(r.Zone)...)
	out = append(out, encodeFloat32(r.X)...)
	out = append(out, encodeFloat32(r.Y)...)
	out = append(out, encodeFloat32(r.Z)...)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Others)))
	out = append(out, countBuf...)
	for _, o := range r.Others {
		out = append(out, o.Encode()...)
	}
	return append(out, encodeStrings(r.FrameRegion)...)
}

func DecodeChangeZoneResult(data []byte) (*ChangeZoneResult, error) {
	if len(data) < 1 {
		return nil, errors.New("session: decoding ChangeZoneResult: empty payload")
	}
	ok := data[0] != 0
	reasonFields, rest, err := decodeStringsPrefix(data[1:], 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: reason: %w", err)
	}
	r := &ChangeZoneResult{OK: ok, Reason: reasonFields[0]}
	if !ok {
		return r, nil
	}

	zoneFields, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: zone: %w", err)
	}
	r.Zone = zoneFields[0]

	r.X, rest, err = decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: x: %w", err)
	}
	r.Y, rest, err = decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: y: %w", err)
	}
	r.Z, rest, err = decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: z: %w", err)
	}

	if len(rest) < 2 {
		return nil, errors.New("session: decoding ChangeZoneResult: truncated entity count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *EntitySnapshot
		snap, rest, err = decodeEntitySnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding ChangeZoneResult: entity %d: %w", i, err)
		}
		r.Others = append(r.Others, *snap)
	}
	if r.FrameRegion, err = decodeFrameRegion(rest); err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: %w", err)
	}
	return r, nil
}

// EntityLeft is the OpEntityLeft broadcast payload.
type EntityLeft struct {
	CharacterID int64
}

func (r *EntityLeft) Encode() []byte { return encodeInt64(r.CharacterID) }

func DecodeEntityLeft(data []byte) (*EntityLeft, error) {
	id, _, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EntityLeft: %w", err)
	}
	return &EntityLeft{CharacterID: id}, nil
}

// WorldHandler returns a gateway.Handler implementing OpEnterWorld and
// OpMove against chars (to resolve character ownership) and hub (world
// state + broadcast fan-out).
func WorldHandler(chars character.Store, eq equipment.Store, hub *world.Hub) gateway.Handler {
	return WorldHandlerWithHook(chars, eq, hub, nil)
}

// EnterHook runs when a character is about to enter the world, after it
// has been resolved to the session's account and before its snapshot is
// built -- so what it changes (a character dressed for the first time, say)
// is what everyone then sees. An error is logged by the caller, not sent:
// entering the world must not fail over a courtesy.
type EnterHook func(ctx context.Context, c *character.Character) error

// WorldHandlerWithHook is WorldHandler with an EnterHook.
func WorldHandlerWithHook(chars character.Store, eq equipment.Store, hub *world.Hub, onEnter EnterHook) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpEnterWorld:
			return handleEnterWorld(ctx, sess, p, chars, eq, hub, onEnter)
		case OpMove:
			return handleMove(sess, p, hub)
		case OpChangeZone:
			return handleChangeZone(ctx, sess, p, eq, chars, hub)
		default:
			return nil
		}
	}
}

// WorldDisconnectHandler returns a func suitable for gateway.Server's
// OnDisconnect hook: removes the disconnecting session from hub and
// notifies whoever was left in its zone.
func WorldDisconnectHandler(hub *world.Hub) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		left, remaining, ok := hub.Leave(sess)
		if !ok {
			return
		}
		keepUp.Cancel(left.CharacterID)
		msg := &EntityLeft{CharacterID: left.CharacterID}
		for _, other := range remaining {
			other.Session.Send(&proto.Packet{Opcode: OpEntityLeft, Data: msg.Encode()})
		}
	}
}

func handleEnterWorld(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, eq equipment.Store, hub *world.Hub, onEnter EnterHook) error {
	accountID, ok := AuthenticatedAccountID(sess)
	if !ok {
		return sess.Send(&proto.Packet{
			Opcode: OpEnterWorldResult,
			Data:   (&EnterWorldResult{Reason: errNotAuthenticated}).Encode(),
		})
	}

	req, err := DecodeEnterWorldRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{
			Opcode: OpEnterWorldResult,
			Data:   (&EnterWorldResult{Reason: "malformed request"}).Encode(),
		})
	}

	list, err := chars.ListByAccount(ctx, accountID)
	if err != nil {
		return sess.Send(&proto.Packet{
			Opcode: OpEnterWorldResult,
			Data:   (&EnterWorldResult{Reason: "lookup failed"}).Encode(),
		})
	}
	var owned *character.Character
	for _, c := range list {
		if c.Name == req.CharacterName {
			owned = c
			break
		}
	}
	if owned == nil {
		return sess.Send(&proto.Packet{
			Opcode: OpEnterWorldResult,
			Data:   (&EnterWorldResult{Reason: "no such character on this account"}).Encode(),
		})
	}
	if onEnter != nil {
		if err := onEnter(ctx, owned); err != nil {
			log.Printf("session: enter hook for %q: %v", owned.Name, err)
		}
	}
	// A character logged out dead enters alive at character.RespawnFraction
	// (round 549). The FRACTION is the load path's own rule -- GObjPC::
	// FUN_004e1120 restores a stored zero pool to MaxHP x 0.4 (the `fmul
	// QWORD ds:0xb460f0` at 0x4e1141 RespawnFraction cites) -- and a stored
	// zero is what -player-dead-state leaves on a logout while dead. The rule
	// is the load path's whatever the flag says, so it is applied with the
	// flag on or off: a character dead when the flag is turned off (or across
	// a crash between a blow and the respawn) must not enter alive at 0 HP,
	// where regen gives nothing. The flag-off server never stores a zero
	// otherwise (the kill respawns at once), so its wire is unchanged.
	// Reviving at entry rather than keeping the character dead across
	// sessions is the disclosed stand-in.
	if owned.HP <= 0 {
		if err := chars.RespawnHP(ctx, owned.ID); err != nil {
			log.Printf("session: reviving %q on entry: %v", owned.Name, err)
		} else if reborn, err := chars.GetByID(ctx, owned.ID); err == nil && reborn != nil {
			owned = reborn
		}
	}

	// The level rides the entity (world.Entity.Level, round 555) so the monster
	// AI's link and swings read it there instead of from the store. The bucket,
	// the position and the frame are arrival's: spawnZone's own, or the one
	// world's under -single-frame, where Jangan's landing is (0, 0) as well.
	bucket, pos, frame, _ := arrival(spawnZone)
	others := hub.Enter(sess, owned.ID, owned.Name, owned.Level, bucket, pos)

	otherSnapshots := make([]EntitySnapshot, len(others))
	for i, o := range others {
		otherSnapshots[i] = entitySnapshotFromWorld(ctx, eq, chars, o)
	}
	result := &EnterWorldResult{
		OK: true, Zone: spawnZone,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		Gender:      owned.Gender,
		HP:          int32(owned.HP),
		MaxHP:       int32(owned.MaxHP()),
		Others:      otherSnapshots,
		FrameRegion: frame,
	}
	if err := sess.Send(&proto.Packet{Opcode: OpEnterWorldResult, Data: result.Encode()}); err != nil {
		return err
	}

	entered := &EntitySnapshot{
		CharacterID: owned.ID, Name: owned.Name,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		Equipped: equippedItems(ctx, eq, owned.ID),
		Gender:   owned.Gender,
	}
	for _, other := range others {
		other.Session.Send(&proto.Packet{Opcode: OpEntityEntered, Data: entered.Encode()})
	}
	return nil
}

// handleChangeZone implements OpChangeZone: a discrete warp for the
// character already in the world on sess to a new zone label, at the same
// fixed spawnPos every OpEnterWorld uses (see ChangeZoneResult's doc
// comment) -- or, under -single-frame, at the zone's landing in the one
// world frame (arrival).
//
// Under -single-frame every label with a frame shares one bucket, so the
// label names no place a character is "already in": the character may have
// walked from Jangan to Donwhang without its label changing. A change to
// such a label is then always a warp to that town's landing, never refused
// as "already in that zone", and hub.ChangeZone re-enters the same bucket --
// everyone else in the world gets the mover's OpEntityLeft and then its
// OpEntityEntered at the landing (a flicker, recorded in round 571, not a
// bug). A label with no frame keeps the old rule.
func handleChangeZone(ctx context.Context, sess *gateway.Session, p *proto.Packet, eq equipment.Store, chars character.Store, hub *world.Hub) error {
	req, err := DecodeChangeZoneRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: (&ChangeZoneResult{Reason: "malformed request"}).Encode()})
	}
	if req.Zone == "" {
		return sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: (&ChangeZoneResult{Reason: "zone required"}).Encode()})
	}

	current, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: (&ChangeZoneResult{Reason: "not in the world"}).Encode()})
	}
	// A dead character does not change zone (round 549, deadstate.go). OWN
	// DESIGN, disclosed: srrevamp's zone change is its own discrete warp with
	// no retail message to read a life-state test from, and round 548's
	// client keeps its dead state across a ChangeZoneResult -- so a warp
	// would put a held die pose at the new zone's spawn. Refusing keeps the
	// two in step until the revive.
	if current.Life == world.LifeDead {
		return sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: (&ChangeZoneResult{Reason: deadRefusal}).Encode()})
	}
	bucket, pos, frame, oneWorld := arrival(req.Zone)
	if !oneWorld && req.Zone == current.Zone {
		return sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: (&ChangeZoneResult{Reason: "already in that zone"}).Encode()})
	}

	old, remainingOld, othersNew, ok := hub.ChangeZone(sess, bucket, pos)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: (&ChangeZoneResult{Reason: "not in the world"}).Encode()})
	}
	keepUp.Cancel(old.CharacterID)

	otherSnapshots := make([]EntitySnapshot, len(othersNew))
	for i, o := range othersNew {
		otherSnapshots[i] = entitySnapshotFromWorld(ctx, eq, chars, o)
	}
	result := &ChangeZoneResult{
		OK: true, Zone: req.Zone,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		Others:      otherSnapshots,
		FrameRegion: frame,
	}
	if err := sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: result.Encode()}); err != nil {
		return err
	}

	leftMsg := &EntityLeft{CharacterID: old.CharacterID}
	for _, other := range remainingOld {
		other.Session.Send(&proto.Packet{Opcode: OpEntityLeft, Data: leftMsg.Encode()})
	}

	entered := &EntitySnapshot{
		CharacterID: old.CharacterID, Name: old.Name,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		Equipped: equippedItems(ctx, eq, old.CharacterID),
		Gender:   genderOf(ctx, chars, old.CharacterID),
	}
	for _, other := range othersNew {
		other.Session.Send(&proto.Packet{Opcode: OpEntityEntered, Data: entered.Encode()})
	}
	return nil
}

func handleMove(sess *gateway.Session, p *proto.Packet, hub *world.Hub) error {
	req, err := DecodeMoveRequest(p.Data)
	if err != nil {
		return nil // malformed move: drop it, don't kill the connection
	}

	// A dead character's position is neither stored nor relayed (round 549,
	// deadstate.go): the body lies where the killing blow found it until the
	// revive. Round 548's client stops sending its own moves while dead; this
	// holds for an older client, whose walk would otherwise carry a dead
	// character across the zone for everyone else.
	if deadBySession(hub, sess) {
		return nil
	}
	pos := world.Position{X: float64(req.X), Y: float64(req.Y), Z: float64(req.Z)}
	entity, others, ok := hub.Move(sess, pos)
	if !ok {
		return nil // not in the world yet (no OpEnterWorld) -- ignore
	}
	// A move is the player's own cancel of a running auto-attack -- see
	// keepup.go for why this packet stands in for the retail client's.
	keepUp.Cancel(entity.CharacterID)

	msg := &EntityMoved{CharacterID: entity.CharacterID, X: req.X, Y: req.Y, Z: req.Z}
	for _, other := range others {
		other.Session.Send(&proto.Packet{Opcode: OpEntityMoved, Data: msg.Encode()})
	}
	return nil
}
