package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"math"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/berserk"
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
	// Heading is the character's heading (world.Entity.Heading), sent only
	// by EncodeEntered, after the rest of the snapshot, as retail's u16 wire
	// angle (round 637's review follow-up). Encode leaves it out: a snapshot
	// in a list (EnterWorldResult, ChangeZoneResult) is followed by more
	// fields, so a trailing value there would shift them for an older
	// client; OpEntityEntered is one snapshot, whose older decoders stop at
	// the gender and ignore what follows. HasHeading is false when the
	// payload had none.
	Heading    float64
	HasHeading bool
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

// EncodeEntered is the OpEntityEntered payload: the snapshot, then the
// heading as a u16 wire angle -- proto.EncodeMovementAngle of
// world.WireAngle(Heading), the client's FUN_009c40b0 adding pi/2 back.
// Retail's spawn carries the angle among its position fields (FUN_009c3a70);
// srrevamp's goes last so an older client, whose decode_entity_entered reads
// one snapshot and stops, is unaffected.
func (e *EntitySnapshot) EncodeEntered() []byte {
	out := e.Encode()
	angle := proto.EncodeMovementAngle(world.WireAngle(e.Heading))
	return append(out, byte(angle), byte(angle>>8))
}

// DecodeEntityEntered parses an OpEntityEntered payload: one snapshot and,
// from a server that sends it, the trailing wire angle, turned back into the
// client's heading (the wire angle plus pi/2, wrapped into [0, 2 pi)).
func DecodeEntityEntered(data []byte) (*EntitySnapshot, error) {
	snap, rest, err := decodeEntitySnapshot(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EntityEntered: %w", err)
	}
	if len(rest) >= 2 {
		wire := float64(binary.LittleEndian.Uint16(rest)) / 65535.0 * 2 * math.Pi
		snap.Heading = math.Mod(wire+math.Pi/2, 2*math.Pi)
		snap.HasHeading = true
	}
	return snap, nil
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
		// Sent in the arrival lists' headings tail (round 637's review
		// follow-up), not by Encode.
		Heading: e.Heading, HasHeading: true,
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
	// Restored says X/Y/Z are where the character last stood, read back from
	// its row under cmd/server's -persist-position (round 573), rather than
	// the zone's arrival point. It trails FrameRegion as ONE byte, 1, and is
	// sent only when true: every other payload is byte for byte what it was.
	// A client that honours it keeps the position; one that does not -- every
	// release before round 573, whose decoder returns after FrameRegion (or
	// after the entity list) without looking at what is left -- moves a
	// Jangan entry on to its own landing spot as it always has
	// (World3D._place_at_zone_spawn).
	Restored bool
	// Seated lists the characters in Others who are sitting or sitting down
	// (round 607; docs/protocol/opcodes/motion.md), so the client draws them
	// seated as it spawns them -- a separate 0x30bf after the list arrived
	// before the world scene or the new zone's bodies existed and was lost.
	// It trails Restored, which is then written even when false: one byte,
	// a u16 count and an i64 id per sitter. Sent only when someone sits, so
	// every other payload is byte for byte what it was, and an older client,
	// which stops at Restored, reads the same. OURS: what the retail spawn
	// packet carries for the motion state was not read.
	//
	// A TRAP FOR THE NEXT FIELD: the tail is found by bytes being left over
	// after Restored (and after ChangeZoneResult's frame). A field appended
	// after it must make Seated always written -- a zero count when nobody
	// sits -- exactly as Seated made Restored always written, or a decoder
	// reads the new field's bytes as a seated list.
	Seated []int64
	// Heading is the entering character's own heading, restored with its
	// position (character.HeadingStore; OURS); HasHeading marks a server that
	// sends one. It is the last field of the headings tail (encodeHeadings).
	Heading    float64
	HasHeading bool
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
	out = append(out, encodeStrings(r.FrameRegion)...)
	heads := r.HasHeading || anyHeading(r.Others)
	if r.Restored || len(r.Seated) > 0 || heads {
		b := byte(0)
		if r.Restored {
			b = 1
		}
		out = append(out, b)
	}
	if !heads {
		return append(out, encodeSeated(r.Seated)...)
	}
	out = append(out, encodeSeatedAlways(r.Seated)...)
	out = append(out, encodeHeadings(r.Others)...)
	return appendWireAngle(out, r.Heading)
}

// The headings tail (round 637's review follow-up): the Others' headings, so
// the players already standing where one arrives face the way they face. It
// trails Seated, which is then always written (a zero count when nobody
// sits), as the Seated field's own doc comment requires; an older decoder
// stops after the seated list and reads the same. A u16 count, equal to
// len(Others), and one u16 wire angle per other in list order (world.WireAngle
// through proto.EncodeMovementAngle, as OpEntityEntered's). Written only when
// a snapshot carries a heading (the server's always do), so a result built
// without one is byte for byte the older payload. EnterWorldResult adds the
// entering character's own wire angle after the list.
func anyHeading(others []EntitySnapshot) bool {
	for _, o := range others {
		if o.HasHeading {
			return true
		}
	}
	return false
}

func appendWireAngle(out []byte, heading float64) []byte {
	a := proto.EncodeMovementAngle(world.WireAngle(heading))
	return append(out, byte(a), byte(a>>8))
}

func encodeHeadings(others []EntitySnapshot) []byte {
	out := []byte{byte(len(others)), byte(len(others) >> 8)}
	for _, o := range others {
		out = appendWireAngle(out, o.Heading)
	}
	return out
}

// headingOfWire is the client's heading for a wire angle: the angle plus pi/2,
// wrapped into [0, 2 pi) (FUN_008a5640, FUN_009c40b0).
func headingOfWire(a uint16) float64 {
	return math.Mod(float64(a)/65535.0*2*math.Pi+math.Pi/2, 2*math.Pi)
}

// decodeHeadings reads the headings tail into others, and returns what
// follows it. Nothing left is an older server: the snapshots keep HasHeading
// false.
func decodeHeadings(rest []byte, others []EntitySnapshot) ([]byte, error) {
	if len(rest) == 0 {
		return rest, nil
	}
	if len(rest) < 2 {
		return nil, errors.New("truncated heading count")
	}
	n := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	if n != len(others) {
		return nil, fmt.Errorf("%d headings for %d others", n, len(others))
	}
	if len(rest) < 2*n {
		return nil, errors.New("truncated headings")
	}
	for i := range others {
		others[i].Heading = headingOfWire(binary.LittleEndian.Uint16(rest[2*i:]))
		others[i].HasHeading = true
	}
	return rest[2*n:], nil
}

// encodeSeatedAlways is encodeSeated with a zero count written too.
func encodeSeatedAlways(ids []int64) []byte {
	if len(ids) == 0 {
		return []byte{0, 0}
	}
	return encodeSeated(ids)
}

// encodeSeated is the Seated tail of EnterWorldResult and ChangeZoneResult:
// nothing when nobody sits, else a u16 count and an i64 id per sitter.
func encodeSeated(ids []int64) []byte {
	if len(ids) == 0 {
		return nil
	}
	out := []byte{byte(len(ids)), byte(len(ids) >> 8)}
	for _, id := range ids {
		out = append(out, encodeInt64(id)...)
	}
	return out
}

// decodeSeatedRest reads a Seated tail -- empty input is no sitters -- and
// returns what follows the list (the headings tail, round 637's review
// follow-up).
func decodeSeatedRest(rest []byte) ([]int64, []byte, error) {
	if len(rest) == 0 {
		return nil, rest, nil
	}
	if len(rest) < 2 {
		return nil, nil, errors.New("truncated seated count")
	}
	n := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	ids := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		id, after, err := decodeInt64(rest)
		if err != nil {
			return nil, nil, fmt.Errorf("seated %d: %w", i, err)
		}
		ids = append(ids, id)
		rest = after
	}
	return ids, rest, nil
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
	if r.FrameRegion, rest, err = decodeFrameRegion(rest); err != nil {
		return nil, fmt.Errorf("session: decoding EnterWorldResult: %w", err)
	}
	// Restored (round 573): one byte after the frame, absent -- false -- from
	// a server that did not restore the position or predates the field.
	r.Restored = len(rest) > 0 && rest[0] != 0
	if len(rest) > 1 {
		var after []byte
		if r.Seated, after, err = decodeSeatedRest(rest[1:]); err != nil {
			return nil, fmt.Errorf("session: decoding EnterWorldResult: %w", err)
		}
		// The headings tail (round 637's review follow-up), then the
		// entering character's own wire angle.
		if after, err = decodeHeadings(after, r.Others); err != nil {
			return nil, fmt.Errorf("session: decoding EnterWorldResult: %w", err)
		}
		if len(after) >= 2 {
			r.Heading = headingOfWire(binary.LittleEndian.Uint16(after))
			r.HasHeading = true
		}
	}
	return r, nil
}

// decodeFrameRegion reads the FrameRegion that trails an EnterWorldResult or
// a ChangeZoneResult (round 570): "" when nothing follows the entity list --
// an older server's payload -- and an error when the field is cut short. It
// returns what follows the field: an EnterWorldResult's Restored byte (round
// 573).
func decodeFrameRegion(rest []byte) (string, []byte, error) {
	if len(rest) == 0 {
		return "", rest, nil
	}
	fields, after, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return "", nil, fmt.Errorf("frame region: %w", err)
	}
	return fields[0], after, nil
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
	// Relocated (round 637's review follow-up) marks a position the client
	// put its character at rather than walked to -- a recovery from a gap,
	// the world entry's placement, a QA or GM relocation. It is a trailing
	// flags byte (bit 0), sent only when set: an older server's decoder reads
	// three floats and ignores it. A relocated move keeps the heading
	// (world.Hub.Move, not MoveFacing) and is relayed with the flag, so no
	// client turns the body toward it: the retail client places an object at
	// a message's source position (FUN_009e11e0) without aiming it.
	Relocated bool
}

func (r *MoveRequest) Encode() []byte {
	out := encodeFloat32(r.X)
	out = append(out, encodeFloat32(r.Y)...)
	out = append(out, encodeFloat32(r.Z)...)
	if r.Relocated {
		out = append(out, 1)
	}
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
	z, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding MoveRequest: z: %w", err)
	}
	return &MoveRequest{X: x, Y: y, Z: z, Relocated: len(rest) > 0 && rest[0]&1 != 0}, nil
}

// EntityMoved is the OpEntityMoved broadcast payload.
type EntityMoved struct {
	CharacterID int64
	X, Y, Z     float32
	// Relocated is MoveRequest.Relocated relayed: a trailing flags byte (bit
	// 0), sent only when set, which an older client (decode_entity_moved
	// reads 20 bytes) ignores.
	Relocated bool
}

func (r *EntityMoved) Encode() []byte {
	out := encodeInt64(r.CharacterID)
	out = append(out, encodeFloat32(r.X)...)
	out = append(out, encodeFloat32(r.Y)...)
	out = append(out, encodeFloat32(r.Z)...)
	if r.Relocated {
		out = append(out, 1)
	}
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
	z, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EntityMoved: %w", err)
	}
	return &EntityMoved{CharacterID: id, X: x, Y: y, Z: z, Relocated: len(rest) > 0 && rest[0]&1 != 0}, nil
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
	// Seated is EnterWorldResult.Seated's twin (round 607), trailing
	// FrameRegion: a u16 count and an i64 id per sitter, sent only when
	// someone sits.
	Seated []int64
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
	out = append(out, encodeStrings(r.FrameRegion)...)
	if !anyHeading(r.Others) {
		return append(out, encodeSeated(r.Seated)...)
	}
	// The headings tail (round 637's review follow-up; EnterWorldResult's
	// doc): Seated always written, then the Others' wire angles.
	out = append(out, encodeSeatedAlways(r.Seated)...)
	return append(out, encodeHeadings(r.Others)...)
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
	if r.FrameRegion, rest, err = decodeFrameRegion(rest); err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: %w", err)
	}
	var after []byte
	if r.Seated, after, err = decodeSeatedRest(rest); err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: %w", err)
	}
	if _, err = decodeHeadings(after, r.Others); err != nil {
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
	return WorldHandlerWithHook(chars, eq, hub, nil, nil)
}

// EnterHook runs when a character is about to enter the world, after it
// has been resolved to the session's account and before its snapshot is
// built -- so what it changes (a character dressed for the first time, say)
// is what everyone then sees. An error is logged by the caller, not sent:
// entering the world must not fail over a courtesy.
type EnterHook func(ctx context.Context, c *character.Character) error

// WorldHandlerWithHook is WorldHandler with an EnterHook, and the berserk
// tracker a zone change ends a running berserk in (endBerserk; nil leaves it).
func WorldHandlerWithHook(chars character.Store, eq equipment.Store, hub *world.Hub, onEnter EnterHook, zerk *berserk.Tracker) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpEnterWorld:
			return handleEnterWorld(ctx, sess, p, chars, eq, hub, onEnter)
		case OpMove:
			return handleMove(sess, p, hub, chars)
		case OpChangeZone:
			return handleChangeZone(ctx, sess, p, eq, chars, hub, zerk)
		default:
			return nil
		}
	}
}

// WorldDisconnectHandler returns a func suitable for gateway.Server's
// OnDisconnect hook: removes the disconnecting session from hub, saves where
// its character stood when it left -- the entity hub.Leave returns -- under
// -persist-position (round 573, position.go), and notifies whoever was left
// in its zone. chars may be nil (tests of other features): nothing is saved
// then.
func WorldDisconnectHandler(hub *world.Hub, chars character.Store) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		left, remaining, ok := hub.Leave(sess)
		if !ok {
			return
		}
		// A character may be in the world on a second session (a reconnect
		// before the old one's disconnect was seen): its state belongs to the
		// live session then, and this stale one's leaving must not clear it
		// (round 616's review, for the book; the 616-618 integration, for the
		// auto-attack run and the motion state, which are keyed by character
		// id the same way).
		_, stillLive := hub.EntityByCharacterID(left.CharacterID)
		if !stillLive {
			keepUp.Cancel(left.CharacterID)
			motions.clear(left.CharacterID)
		}
		// The book goes with the character (round 616): the object's
		// teardown clears its active-effect book (CGObjChar::vslot_214,
		// 0x4a72e0 -> FUN_0059c820(pc+0xa30), READ; that it runs on logout is
		// INFERRED). Retail restores some buffs on the next login (a record
		// with ctx+0xc bits 4 and 8 ends on its saved remaining time,
		// skill_params.md) -- not modelled, OPEN. Everyone left gets
		// OpEntityLeft below, which takes the owner's buffs with it.
		if !stillLive {
			buffBooks.EndAll(left.CharacterID)
			// A GM's /speed goes with the character (round 636's review, OURS):
			// the next login starts at its own speed, so a demotion (a server
			// restarted without the account in -gm-accounts) leaves nothing.
			buffBooks.SetGMSpeedFactor(left.CharacterID, 1)
		}
		// Nor may it save where the stale session last stood, or tell the
		// zone the character left: the live session's entity is still there,
		// and its own disconnect saves and announces it (the 616-618
		// integration review).
		if stillLive {
			return
		}
		savePosition(chars, sess, left)
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
	// world's under -single-frame, where Jangan's landing is (0, 0) as well --
	// unless -persist-position restores where the character last stood
	// (round 573, restoredArrival): its saved label, that label's bucket and
	// frame today, and the saved point named in that frame.
	zone := spawnZone
	bucket, pos, frame, _ := arrival(spawnZone)
	savedZone, savedBucket, savedPos, savedFrame, restored := restoredArrival(owned)
	if restored {
		zone, bucket, pos, frame = savedZone, savedBucket, savedPos, savedFrame
	}
	others := hub.Enter(sess, owned.ID, owned.Name, owned.Level, bucket, pos)
	// The heading comes back with a restored position (round 637's review
	// follow-up; character.HeadingStore, OURS): the zone sees the character
	// facing the way it left, and so does its own client (the result's own
	// wire angle). A fresh arrival faces 0.
	heading := restoredHeading(ctx, chars, owned.ID, restored)
	hub.SetHeading(sess, heading)
	rememberPlace(sess, zone, frame, time.Now())
	// Standing, with the regen timer at 0 elapsed: the engine's constructor
	// registers the timer and calls SetMotionState(STAND) (round 607,
	// motion.go).
	motions.enter(owned.ID, time.Now())

	otherSnapshots := make([]EntitySnapshot, len(others))
	for i, o := range others {
		otherSnapshots[i] = entitySnapshotFromWorld(ctx, eq, chars, o)
	}
	result := &EnterWorldResult{
		OK: true, Zone: zone,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		Gender:      owned.Gender,
		HP:          int32(owned.HP),
		MaxHP:       int32(owned.MaxHP()),
		Others:      otherSnapshots,
		FrameRegion: frame,
		Restored:    restored,
		Seated:      seatedAmong(others),
		Heading:     heading,
		HasHeading:  true,
	}
	if err := sess.Send(&proto.Packet{Opcode: OpEnterWorldResult, Data: result.Encode()}); err != nil {
		return err
	}

	// The entry faces the restored heading, or 0 on a fresh arrival.
	entered := &EntitySnapshot{
		CharacterID: owned.ID, Name: owned.Name,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		Equipped:   equippedItems(ctx, eq, owned.ID),
		Gender:     owned.Gender,
		Heading:    heading,
		HasHeading: true,
	}
	for _, other := range others {
		other.Session.Send(&proto.Packet{Opcode: OpEntityEntered, Data: entered.EncodeEntered()})
	}
	// The client's own character id (round 616, OpSelfID), after the
	// world-entry messages and before any buff that may name it.
	if err := sess.Send(&proto.Packet{Opcode: OpSelfID, Data: (&SelfID{CharacterID: owned.ID}).Encode()}); err != nil {
		return err
	}
	// The zone's active buffs, after the snapshots that name their owners
	// (round 616, buffs.go; OURS).
	if e, inWorld := hub.EntityBySession(sess.ID()); inWorld {
		sendBuffsInView(hub, e, time.Now())
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
func handleChangeZone(ctx context.Context, sess *gateway.Session, p *proto.Packet, eq equipment.Store, chars character.Store, hub *world.Hub, zerk *berserk.Tracker) error {
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
	_, err = warpTo(ctx, sess, eq, chars, hub, zerk, req.Zone, bucket, pos, frame)
	return err
}

// warpTo is a zone change's arrival, factored out of handleChangeZone in round
// 576 so a gate teleport (teleport.go) lands the same way: the character in
// the world on sess moves into hub bucket `bucket` at pos, under zone label
// `zone` and FrameRegion `frame`; the mover gets its OpChangeZoneResult (so
// its client reloads the zone behind the loading screen,
// World3D._on_change_zone_result), everyone left behind its OpEntityLeft, and
// everyone in the new bucket its OpEntityEntered at pos. moved is false when
// the session is not in the world: the mover is then sent the "not in the
// world" refusal, as handleChangeZone always did, and nothing moved.
func warpTo(ctx context.Context, sess *gateway.Session, eq equipment.Store, chars character.Store, hub *world.Hub, zerk *berserk.Tracker, zone, bucket string, pos world.Position, frame string) (moved bool, err error) {
	old, remainingOld, othersNew, ok := hub.ChangeZone(sess, bucket, pos)
	if !ok {
		return false, sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: (&ChangeZoneResult{Reason: "not in the world"}).Encode()})
	}
	keepUp.Cancel(old.CharacterID)
	// A character arrives standing (round 607, motion.go; ours: the retail
	// object's re-creation is inferred). The client drops its own sit on the
	// zone change too.
	motions.stand(old.CharacterID, time.Now())
	// A walled caster's landing is its client's to report (round 646,
	// walls.go noteWarpLanding): the root holds it where it lands.
	noteWarpLanding(old.CharacterID, time.Now())
	// The new label and frame are what a later save writes under, and the
	// arrival itself is saved at once under -persist-position (round 573).
	rememberPlace(sess, zone, frame, time.Now())
	arrived := old
	arrived.Zone, arrived.Pos = bucket, pos
	savePosition(chars, sess, arrived)

	otherSnapshots := make([]EntitySnapshot, len(othersNew))
	for i, o := range othersNew {
		otherSnapshots[i] = entitySnapshotFromWorld(ctx, eq, chars, o)
	}
	result := &ChangeZoneResult{
		OK: true, Zone: zone,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		Others:      otherSnapshots,
		FrameRegion: frame,
		Seated:      seatedAmong(othersNew),
	}
	if err := sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: result.Encode()}); err != nil {
		return true, err
	}

	leftMsg := &EntityLeft{CharacterID: old.CharacterID}
	for _, other := range remainingOld {
		other.Session.Send(&proto.Packet{Opcode: OpEntityLeft, Data: leftMsg.Encode()})
	}

	// The arrival faces the way the character last moved: the hub carries
	// the heading through the change (world.Hub.ChangeZone).
	entered := &EntitySnapshot{
		CharacterID: old.CharacterID, Name: old.Name,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		Equipped: equippedItems(ctx, eq, old.CharacterID),
		Gender:   genderOf(ctx, chars, old.CharacterID),
		Heading:  old.Heading, HasHeading: true,
	}
	for _, other := range othersNew {
		other.Session.Send(&proto.Packet{Opcode: OpEntityEntered, Data: entered.EncodeEntered()})
	}
	// A zone change keeps the book (OURS: whether retail's teleport keeps
	// buffs was not read); the new zone learns them, and the mover learns its
	// new neighbours' (round 616, buffs.go).
	arrived.Session = sess
	sendBuffsInView(hub, arrived, time.Now())
	// A running berserk ends with the zone change (endBerserk: the world
	// entry's body mode is READ, that a zone change is a re-entry INFERRED),
	// as the client's display does (FUN_00787860); the new zone and the mover
	// hear body mode 0.
	endBerserk(hub, zerk, old.CharacterID)
	return true, nil
}

func handleMove(sess *gateway.Session, p *proto.Packet, hub *world.Hub, chars character.Store) error {
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
	// A move in the sit/stand transition is refused, as the retail movement
	// handler refuses MOTIONSTATE_CHANGEMOTION (0x4b0f83); a move while
	// sitting is accepted and stands the character at once, as its
	// SetMotionState(WALK/RUN) does (round 607, motion.go). Neither the store
	// nor the zone hears a refused one, as for the dead.
	if e, inWorld := hub.EntityBySession(sess.ID()); inWorld {
		moved := motions.moved
		// Round 646, OURS: a rooted caster's warp landing is taken
		// (walls.go warpLandingAdmits); a walk is still dropped.
		if warpLandingAdmits(e.CharacterID, req.Relocated, time.Now()) {
			moved = motions.movedUnrooted
		}
		if accepted, _ := moved(e.CharacterID, time.Now()); !accepted {
			// Round 640, OURS: a move the wall's root dropped is answered
			// with the held position (walls.go rootedMoveAnswer).
			if wallRoots(e.CharacterID) {
				rootedMoveAnswer(sess, e)
			}
			return nil
		}
	}
	// A NaN or an infinity is no place (round 616's review): dropped, like a
	// malformed move.
	if !finitePosition(req.X, req.Y, req.Z) {
		return nil
	}
	pos := world.Position{X: float64(req.X), Y: float64(req.Y), Z: float64(req.Z)}
	// A walk turns the character to face the way it moved; a relocation keeps
	// its heading (round 637's review follow-up; world.Hub.MoveFacing).
	move := hub.MoveFacing
	if req.Relocated {
		move = hub.Move
	}
	entity, others, ok := move(sess, pos)
	if !ok {
		return nil // not in the world yet (no OpEnterWorld) -- ignore
	}
	// A move is the player's own cancel of a running auto-attack -- see
	// keepup.go for why this packet stands in for the retail client's.
	keepUp.Cancel(entity.CharacterID)
	// Under -persist-position the walk is saved at most once every
	// positionSaveInterval (round 573), so a crash loses little of it.
	savePositionEvery(chars, sess, entity, time.Now())

	msg := &EntityMoved{CharacterID: entity.CharacterID, X: req.X, Y: req.Y, Z: req.Z, Relocated: req.Relocated}
	for _, other := range others {
		other.Session.Send(&proto.Packet{Opcode: OpEntityMoved, Data: msg.Encode()})
	}
	return nil
}
