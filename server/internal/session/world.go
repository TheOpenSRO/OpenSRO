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

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// World opcodes, our own protocol. OpEnterWorld requires a prior OpLogin;
// OpMove requires a prior successful OpEnterWorld on the same connection.
const (
	OpEnterWorld       uint16 = 0x0020 // client -> server
	OpEnterWorldResult uint16 = 0x0021 // server -> client
	OpMove             uint16 = 0x0022 // client -> server, no reply: since round 749 a stop, a placement, an older client's walk (destmove.go)
	OpEntityEntered    uint16 = 0x0023 // server -> client, broadcast
	OpEntityMoved      uint16 = 0x0024 // server -> client: not sent since round 749 (retail's 0xB021 / 0xB023 instead); the client still reads it
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
	// RefObjID is the body the character was made from (character.RefObjID,
	// one of the 52 creatable Figures) and Scale its scale byte (Height low
	// nibble, Volume high), so the client draws the character from its own
	// model rather than a body picked by Gender (round 689, charselect.md lane
	// W). Sent in trailing tails only -- after EncodeEntered's wire angle, and
	// in the results' models tail (encodeModels) -- so an older client, whose
	// decoders stop before them, reads what it always did. HasModel is false
	// when the payload had none (an older server): the client then keeps
	// drawing from Gender.
	RefObjID uint32
	Scale    uint8
	HasModel bool
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
// OpenSRO's goes last so an older client, whose decode_entity_entered reads
// one snapshot and stops, is unaffected.
//
// Round 689: then the model, a u32 RefObjID and the u8 scale byte, when the
// snapshot carries one. A client before round 689 stops after the angle
// (decode_entity_entered reads two bytes past the snapshot and returns), so
// they reach it unread.
func (e *EntitySnapshot) EncodeEntered() []byte {
	out := e.Encode()
	angle := proto.EncodeMovementAngle(world.WireAngle(e.Heading))
	out = append(out, byte(angle), byte(angle>>8))
	pluses := anyPlus(*e)
	if e.HasModel {
		out = appendModel(out, e.RefObjID, e.Scale)
	} else if pluses {
		// The pluses follow the model, which is then written: 0/0 is "no
		// model" to every decoder (decode_entity_entered's ref != 0).
		out = appendModel(out, 0, 0)
	}
	// Round 735: the pluses tail, last.
	if pluses {
		out = appendPluses(out, *e)
	}
	return out
}

// appendModel writes one model: a u32 RefObjID and the u8 scale byte.
func appendModel(out []byte, refObjID uint32, scale uint8) []byte {
	b := make([]byte, 5)
	binary.LittleEndian.PutUint32(b, refObjID)
	b[4] = scale
	return append(out, b...)
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
	// The model (round 689), from a server that sends it.
	// A 0 RefObjID is a model written only for the pluses after it.
	if len(rest) >= 2+5 {
		if ref := binary.LittleEndian.Uint32(rest[2:]); ref != 0 {
			snap.RefObjID, snap.Scale, snap.HasModel = ref, rest[6], true
		}
	}
	// The pluses (round 735), from a server that sends them.
	if len(rest) > 2+5 {
		if _, err := decodePluses(rest[7:], snap); err != nil {
			return nil, fmt.Errorf("session: decoding EntityEntered: %w", err)
		}
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
		out = append(out, EquippedSnapshot{Slot: int(it.Slot), ItemID: it.ItemID, Plus: it.EffectivePlus()})
	}
	return out
}

// The pluses tail (round 735; docs/protocol/weapon_glow.md lane B): each
// worn item's effective plus, so another player's weapon and shield glow at
// their level. Retail carries the byte after each item's RefItemID in the
// 0x3015 spawn (READ: the client's CICUser vslot 25, 0x9de2f0, reads u32
// RefItemID then, for equipment, a u8 plus; the server writes it with
// CInstanceItem::vslot_010 mode 2, 0x42e230, as OptLevel + the advanced
// elixir sum). OpenSRO's snapshot lists its items mid-payload, so the value
// rides a trailing block an older decoder stops before (OURS framing, retail
// content): a u8 count, then a u8 slot and a u8 plus per entry. It is the
// LAST field of each payload that carries it -- after OpEntityEntered's
// model, and after a result's models tail -- and written only when some
// snapshot holds a non-zero plus, so every other payload is byte for byte
// what it was. A slot with no entry is +0.
//
// THE TRAP, ONE FIELD ON: a field after this one must make it always written
// (a zero count), as this one makes the models tail written.

// anyPlus reports whether a worn item in snaps carries a plus.
func anyPlus(snaps ...EntitySnapshot) bool {
	for _, s := range snaps {
		for _, it := range s.Equipped {
			if it.Plus != 0 {
				return true
			}
		}
	}
	return false
}

// appendPluses writes one snapshot's pluses block: the items with a plus.
func appendPluses(out []byte, s EntitySnapshot) []byte {
	n := 0
	for _, it := range s.Equipped {
		if it.Plus != 0 {
			n++
		}
	}
	out = append(out, byte(n))
	for _, it := range s.Equipped {
		if it.Plus != 0 {
			out = append(out, byte(it.Slot), it.Plus)
		}
	}
	return out
}

// decodePluses reads one snapshot's pluses block onto its Equipped entries.
// An entry naming a slot the snapshot does not list is skipped.
func decodePluses(rest []byte, s *EntitySnapshot) ([]byte, error) {
	if len(rest) < 1 {
		return nil, errors.New("truncated plus count")
	}
	n := int(rest[0])
	rest = rest[1:]
	if len(rest) < 2*n {
		return nil, errors.New("truncated pluses")
	}
	for i := 0; i < n; i++ {
		slot, plus := int(rest[2*i]), rest[2*i+1]
		for k := range s.Equipped {
			if s.Equipped[k].Slot == slot {
				s.Equipped[k].Plus = plus
			}
		}
	}
	return rest[2*n:], nil
}

// encodePlusesList is a result's pluses tail: a u16 count, equal to
// len(others), and one block per other in list order.
func encodePlusesList(others []EntitySnapshot) []byte {
	out := []byte{byte(len(others)), byte(len(others) >> 8)}
	for _, o := range others {
		out = appendPluses(out, o)
	}
	return out
}

// decodePlusesList reads a result's pluses tail into others: nothing there
// is an older server.
func decodePlusesList(rest []byte, others []EntitySnapshot) ([]byte, error) {
	if len(rest) == 0 {
		return rest, nil
	}
	if len(rest) < 2 {
		return nil, errors.New("truncated pluses count")
	}
	n := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	if n != len(others) {
		return nil, fmt.Errorf("%d pluses blocks for %d others", n, len(others))
	}
	var err error
	for i := range others {
		if rest, err = decodePluses(rest, &others[i]); err != nil {
			return nil, fmt.Errorf("other %d: %w", i, err)
		}
	}
	return rest, nil
}

// bodyOf looks up characterID's Gender, RefObjID and scale byte in one
// chars.GetByID, live at broadcast time -- world.Entity doesn't carry them
// (that package deliberately only tracks position/presence, not character
// details -- same reasoning as equippedItems). On any lookup error it gives
// character.DefaultGender with that gender's legacy body (LegacyModelFor) at
// character.DefaultScale, the same honest-failure convention as
// equippedItems: never block a broadcast over this. (Round 689 folded the
// older genderOf into it.)
func bodyOf(ctx context.Context, chars character.Store, characterID int64) (gender string, refObjID uint32, scale uint8) {
	c, err := chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return character.DefaultGender, uint32(character.LegacyModelFor(character.DefaultGender)), character.DefaultScale
	}
	ref, sc := modelOf(c)
	return c.Gender, ref, sc
}

// modelOf is the wire model of a character row: its RefObjID and scale byte,
// or, for a row without a model (0 -- an older store), the body its Gender
// was migrated to (LegacyModelFor) at DefaultScale, as round 682's migration
// does. A scale outside a byte reads DefaultScale.
func modelOf(c *character.Character) (uint32, uint8) {
	ref, scale := c.RefObjID, c.Scale
	if ref <= 0 || ref > math.MaxUint32 {
		ref, scale = character.LegacyModelFor(c.Gender), character.DefaultScale
	}
	if scale < 0 || scale > 0xff {
		scale = character.DefaultScale
	}
	return uint32(ref), uint8(scale)
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
	// RefObjID and Scale are the entering character's own model (round 689;
	// EntitySnapshot.RefObjID's doc), and the Others' ride their snapshots.
	// They are the models tail (encodeModels), the LAST field: written after
	// the entering character's wire angle, which -- with Restored, Seated and
	// the headings tail before it -- is then always written, as the trap above
	// requires. An older client stops at the wire angle and never reads them.
	// HasModel marks a server that sends them; sent whenever it is set or any
	// Other carries a model, so a result built without one is byte for byte
	// the older payload.
	RefObjID uint32
	Scale    uint8
	HasModel bool
}

// anyModel reports whether a snapshot in others carries a model.
func anyModel(others []EntitySnapshot) bool {
	for _, o := range others {
		if o.HasModel {
			return true
		}
	}
	return false
}

// encodeModels is the models tail (round 689) of an EnterWorldResult (after
// its own model) and a ChangeZoneResult: a u16 count, equal to len(others),
// and one model -- u32 RefObjID, u8 scale -- per other in list order. A
// snapshot without one is written as 0/0, which the client reads as "no
// model, draw from Gender".
func encodeModels(others []EntitySnapshot) []byte {
	out := []byte{byte(len(others)), byte(len(others) >> 8)}
	for _, o := range others {
		if o.HasModel {
			out = appendModel(out, o.RefObjID, o.Scale)
		} else {
			out = appendModel(out, 0, 0)
		}
	}
	return out
}

// decodeModels reads the models tail into others: nothing there is an older
// server, and a 0 RefObjID is a snapshot sent without a model.
func decodeModels(rest []byte, others []EntitySnapshot) ([]byte, error) {
	if len(rest) == 0 {
		return rest, nil
	}
	if len(rest) < 2 {
		return nil, errors.New("truncated model count")
	}
	n := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	if n != len(others) {
		return nil, fmt.Errorf("%d models for %d others", n, len(others))
	}
	if len(rest) < 5*n {
		return nil, errors.New("truncated models")
	}
	for i := range others {
		ref := binary.LittleEndian.Uint32(rest[5*i:])
		if ref != 0 {
			others[i].RefObjID, others[i].Scale, others[i].HasModel = ref, rest[5*i+4], true
		}
	}
	return rest[5*n:], nil
}

func (r *EnterWorldResult) Encode() []byte {
	b, _ := r.EncodeFitting()
	return b
}

// EncodeFitting is Encode, and whether the pluses tail was left out because
// the payload with it would not fit one frame (proto.MaxPayload; round 735's
// review, finding 8). The tail is the only optional part, so it is the part
// dropped; the sender then tells the arriving client the pluses as retail
// 0x3038s (sendPlusesAsBroadcasts). A list too long without the tail was
// already too long before round 735 (about 255 others with full kits).
func (r *EnterWorldResult) EncodeFitting() ([]byte, bool) {
	full := r.encode(true)
	if len(full) <= proto.MaxPayload || !anyPlus(r.Others...) {
		return full, false
	}
	return r.encode(false), true
}

func (r *EnterWorldResult) encode(withPluses bool) []byte {
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
	// The pluses tail (round 735) follows the models tail, which it makes
	// written.
	pluses := withPluses && anyPlus(r.Others...)
	models := r.HasModel || anyModel(r.Others) || pluses
	if models && !r.HasHeading {
		// The trap above, enforced here (round 689's review): the models tail
		// follows the own wire angle, so a result with a model always carries
		// one -- r.Heading, which a decoder then reads back as a heading
		// (HasHeading true). Encoded from a copy; r is left as it was.
		withHeading := *r
		withHeading.HasHeading = true
		return withHeading.encode(withPluses)
	}
	heads := r.HasHeading || anyHeading(r.Others) || models
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
	out = appendWireAngle(out, r.Heading)
	if !models {
		return out
	}
	// The models tail (round 689): the entering character's own, then the
	// Others'. An own model of 0 is "none" (HasModel false).
	if r.HasModel {
		out = appendModel(out, r.RefObjID, r.Scale)
	} else {
		out = appendModel(out, 0, 0)
	}
	out = append(out, encodeModels(r.Others)...)
	if !pluses {
		return out
	}
	return append(out, encodePlusesList(r.Others)...)
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
			after = after[2:]
		}
		// The models tail (round 689): this character's own, then the
		// Others'. Nothing there is an older server.
		if len(after) > 0 {
			if len(after) < 5 {
				return nil, errors.New("session: decoding EnterWorldResult: truncated own model")
			}
			if ref := binary.LittleEndian.Uint32(after); ref != 0 {
				r.RefObjID, r.Scale, r.HasModel = ref, after[4], true
			}
			if after, err = decodeModels(after[5:], r.Others); err != nil {
				return nil, fmt.Errorf("session: decoding EnterWorldResult: %w", err)
			}
			// The pluses tail (round 735).
			if _, err = decodePlusesList(after, r.Others); err != nil {
				return nil, fmt.Errorf("session: decoding EnterWorldResult: %w", err)
			}
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
	// A dungeon's frame is its own label (round 773, dungeon.go).
	if _, ok := dungeonOf(zone); ok {
		return zone
	}
	rx, ry, ok := worldmap.FrameFor(zone)
	if !ok {
		return ""
	}
	return fmt.Sprintf("%d/%d", rx, ry)
}

// singleFrame is cmd/server's -single-frame (OPENSRO_SINGLE_FRAME), OFF by
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
	// A dungeon (round 773, dungeon.go): its own bucket and frame, at its
	// entry -- under -single-frame too, since it has no frame to share.
	if rid, ok := dungeonOf(zone); ok {
		if at, served := dungeonEntry(rid); served {
			return zone, at, zone, false
		}
		return zone, spawnPos, zone, false
	}
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
	// (world.MoveRelocate, not MoveWalk) and is relayed with the flag, so no
	// client turns the body toward it: the retail client places an object at
	// a message's source position (FUN_009e11e0) without aiming it.
	Relocated bool
	// Run (round 653) is set on a position sent while a heading run is in
	// effect -- the sky click (client SkyRun). The flags byte's bit 1 then
	// says retail's own HEADING FORM of 0x7021 follows
	// (docs/protocol/opcodes/movement.md; proto.Movement): kind 0, the
	// command byte (RunCommand, proto.MovementCommandForward from the sky
	// click) and the u16 wire angle (RunAngle). The framing -- a heading form
	// riding on a position -- is OURS: OpenSRO's movement is client-
	// authoritative positions, retail's is 0x7021 requests the server steps.
	Run        bool
	RunCommand byte
	RunAngle   uint16
	// Stopped (round 749, OURS) marks where the client's walk stopped short
	// of what the server was told by its 0x7021 -- a wall, an approach in
	// reach, a sit (destmove.go). Bit 2 of the flags byte (moveFlagStopped);
	// an older server reads a walked position.
	Stopped bool
}

// The trailing flags byte's bits (OURS framing).
const (
	moveFlagRelocated byte = 1
	moveFlagRun       byte = 2
)

// encodeMoveTail appends the flags byte and, for a run, the heading form --
// shared by MoveRequest and EntityMoved. Nothing is appended for a plain
// walked position, which is the three floats an older peer expects.
func encodeMoveTail(out []byte, relocated, run bool, command byte, angle uint16) []byte {
	var flags byte
	if relocated {
		flags |= moveFlagRelocated
	}
	if run {
		flags |= moveFlagRun
	}
	if flags == 0 {
		return out
	}
	out = append(out, flags)
	if run {
		// proto.Movement's heading form with no extra byte, the angle already
		// on the wire (the client computed it): kind, command, u16 LE.
		out = append(out, proto.MovementKindHeading, command, byte(angle), byte(angle>>8))
	}
	return out
}

// decodeMoveTail reads encodeMoveTail's bytes. A run flag whose heading form
// is short or not the heading kind is no run: the position still stands.
func decodeMoveTail(rest []byte) (relocated, run bool, command byte, angle uint16) {
	if len(rest) == 0 {
		return false, false, 0, 0
	}
	flags := rest[0]
	relocated = flags&moveFlagRelocated != 0
	if flags&moveFlagRun == 0 {
		return relocated, false, 0, 0
	}
	m, a, err := proto.DecodeMovement(rest[1:], false)
	if err != nil || m.Kind != proto.MovementKindHeading {
		return relocated, false, 0, 0
	}
	return relocated, true, m.HeadingByte, a
}

func (r *MoveRequest) Encode() []byte {
	out := encodeFloat32(r.X)
	out = append(out, encodeFloat32(r.Y)...)
	out = append(out, encodeFloat32(r.Z)...)
	n := len(out)
	out = encodeMoveTail(out, r.Relocated, r.Run, r.RunCommand, r.RunAngle)
	if r.Stopped {
		if len(out) == n {
			out = append(out, 0)
		}
		out[n] |= moveFlagStopped
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
	r := &MoveRequest{X: x, Y: y, Z: z}
	r.Relocated, r.Run, r.RunCommand, r.RunAngle = decodeMoveTail(rest)
	r.Stopped = len(rest) > 0 && rest[0]&moveFlagStopped != 0
	return r, nil
}

// EntityMoved is the OpEntityMoved broadcast payload.
type EntityMoved struct {
	CharacterID int64
	X, Y, Z     float32
	// Relocated is MoveRequest.Relocated relayed: a trailing flags byte (bit
	// 0), sent only when set, which an older client (decode_entity_moved
	// reads 20 bytes) ignores.
	Relocated bool
	// Run, RunCommand and RunAngle are MoveRequest's relayed (round 653):
	// the watcher's client faces the run's heading.
	Run        bool
	RunCommand byte
	RunAngle   uint16
}

func (r *EntityMoved) Encode() []byte {
	out := encodeInt64(r.CharacterID)
	out = append(out, encodeFloat32(r.X)...)
	out = append(out, encodeFloat32(r.Y)...)
	out = append(out, encodeFloat32(r.Z)...)
	return encodeMoveTail(out, r.Relocated, r.Run, r.RunCommand, r.RunAngle)
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
	m := &EntityMoved{CharacterID: id, X: x, Y: y, Z: z}
	m.Relocated, m.Run, m.RunCommand, m.RunAngle = decodeMoveTail(rest)
	return m, nil
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
	// Spot (round 764, OURS framing) is an optional point in the zone's
	// centre region, region-local (x, z in [0, RegionSpan)), where the
	// client will stand the player -- the zone box's `x/y@lx,lz` (the
	// developer panel's town buttons). Two trailing f32s, sent only when
	// set. The server lands the character there (handleChangeZone), so its
	// view window -- the group spawns its arrival is sent -- is centred on
	// where the client stands: before, it landed at the region's middle and
	// refused the client's placement 400-550 units away, and the client was
	// snapped back with part of the crowd missing meanwhile (r764.md).
	HasSpot      bool
	SpotX, SpotZ float32
}

func (r *ChangeZoneRequest) Encode() []byte {
	out := encodeStrings(r.Zone)
	if r.HasSpot {
		out = binary.LittleEndian.AppendUint32(out, math.Float32bits(r.SpotX))
		out = binary.LittleEndian.AppendUint32(out, math.Float32bits(r.SpotZ))
	}
	return out
}

func DecodeChangeZoneRequest(data []byte) (*ChangeZoneRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, err
	}
	req := &ChangeZoneRequest{Zone: fields[0]}
	switch len(rest) {
	case 0:
	case 8:
		req.HasSpot = true
		req.SpotX = math.Float32frombits(binary.LittleEndian.Uint32(rest))
		req.SpotZ = math.Float32frombits(binary.LittleEndian.Uint32(rest[4:]))
	default:
		return nil, fmt.Errorf("%d unexpected trailing byte(s) after the zone", len(rest))
	}
	return req, nil
}

// knownZoneSpots are the region-local points, per zone centre region, the
// client stands a zone change's arrival at (OURS, the client's choices):
// worldmap.LandingSpot's rows and the developer panel's town buttons
// (client/scripts/ui/debug_panel.gd TOWNS -- keep the two in step).
var knownZoneSpots = map[[2]int][][2]float64{
	{97, 168}:  {{969, 1369}},
	{102, 153}: {{957, 1508}},
	{92, 135}:  {{1138, 153}},
	{105, 79}:  {{950, 1070}},
	{106, 108}: {{270, 1421}},
	{90, 48}:   {{663, 526}},
}

// knownZoneSpot reports whether (x, z) is, within a unit, one of zone's known
// spots (knownZoneSpots or its LandingSpot).
func knownZoneSpot(zone string, x, z float64) bool {
	rx, ry, ok := worldmap.FrameFor(zone)
	if !ok {
		return false
	}
	pts := append([][2]float64(nil), knownZoneSpots[[2]int{rx, ry}]...)
	if sp, has := worldmap.LandingSpot[[2]int{rx, ry}]; has {
		pts = append(pts, sp)
	}
	for _, p := range pts {
		if math.Abs(p[0]-x) <= 1 && math.Abs(p[1]-z) <= 1 {
			return true
		}
	}
	return false
}

// zoneSpotGate is the GM gate GMCommandHandler was made with (nil: no GM).
var zoneSpotGate atomic.Pointer[gm.Gate]

func zoneSpotGM(username string) bool {
	g := zoneSpotGate.Load()
	return g != nil && username != "" && g.Allows(username)
}

// changeZoneLanding is where a zone change to req lands, given arrival's
// point `mid` (the zone's centre region's middle in the frame it is named
// in): the request's spot, when it names one inside the region, or else the
// zone's LandingSpot -- the point the client stands an arrival there
// (World3D's ZONE_SPAWN_LOCAL, worldmap.LandingSpot) -- or else mid.
//
// Round 764 (OURS): retail's server places the character and its client goes
// there; OpenSRO's client picks the spot for a zone change, so the server now
// lands it where the client will stand. Landing it at the middle, the
// arrival's view window was the middle's -- its group spawns sent for blocks
// the client did not stand among -- and the placement that followed was a
// second batch of group spawns seconds later (a block-line crossing), or,
// for a spot the server had not named, refused and corrected back to the
// middle (the user's v0.1.516 log: "MOVE correction: the server has this
// player at (0.00, 0.00, 0.00)").
//
// Round 764's review, F3: a spot is taken only from a GM's session, or when it
// is one the server knows the client stands players at -- a zone's
// LandingSpot or a developer panel town button's (knownZoneSpots) -- so the
// spot is no teleport to an arbitrary point. Any other spot is ignored and the
// zone lands as without one.
func changeZoneLanding(req *ChangeZoneRequest, mid world.Position, gm bool) world.Position {
	// A dungeon lands at its entry (arrival); a spot is region-local, which a
	// dungeon has none of (round 773).
	if _, ok := dungeonOf(req.Zone); ok {
		return mid
	}
	if req.HasSpot && (gm || knownZoneSpot(req.Zone, float64(req.SpotX), float64(req.SpotZ))) {
		x, z := float64(req.SpotX), float64(req.SpotZ)
		if !math.IsNaN(x) && !math.IsNaN(z) && x >= 0 && x < worldmap.RegionSpan && z >= 0 && z < worldmap.RegionSpan {
			// Landing is the middle in every frame, and ToWorld is a
			// translation: the spot is the middle plus its offset from it.
			mid.X += x - worldmap.RegionSpan/2
			mid.Z += worldmap.RegionSpan/2 - z
			return mid
		}
	}
	if x, z, ok := worldmap.LandingSpotFor(req.Zone, mid.X, mid.Z); ok {
		mid.X, mid.Z = x, z
	}
	return mid
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
	b, _ := r.EncodeFitting()
	return b
}

// EncodeFitting is EnterWorldResult.EncodeFitting's twin.
func (r *ChangeZoneResult) EncodeFitting() ([]byte, bool) {
	full := r.encode(true)
	if len(full) <= proto.MaxPayload || !anyPlus(r.Others...) {
		return full, false
	}
	return r.encode(false), true
}

func (r *ChangeZoneResult) encode(withPluses bool) []byte {
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
	pluses := withPluses && anyPlus(r.Others...)
	models := anyModel(r.Others) || pluses
	if !anyHeading(r.Others) && !models {
		return append(out, encodeSeated(r.Seated)...)
	}
	// The headings tail (round 637's review follow-up; EnterWorldResult's
	// doc): Seated always written, then the Others' wire angles.
	out = append(out, encodeSeatedAlways(r.Seated)...)
	out = append(out, encodeHeadings(r.Others)...)
	if !models {
		return out
	}
	// The models tail (round 689), after the headings, which it makes always
	// written: an older client stops at the headings.
	out = append(out, encodeModels(r.Others)...)
	if !pluses {
		return out
	}
	// The pluses tail (round 735), after the models, which it makes written.
	return append(out, encodePlusesList(r.Others)...)
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
	if after, err = decodeHeadings(after, r.Others); err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: %w", err)
	}
	if after, err = decodeModels(after, r.Others); err != nil {
		return nil, fmt.Errorf("session: decoding ChangeZoneResult: %w", err)
	}
	if _, err = decodePlusesList(after, r.Others); err != nil {
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
			return handleEnterWorld(ctx, sess, p, chars, eq, hub, onEnter, zerk)
		case OpStart:
			return handleStart(ctx, sess, p, chars, eq, hub, onEnter, zerk)
		case OpMove:
			return handleMove(sess, p, hub, chars)
		case proto.OpMovementRequest:
			// Round 749: retail's click move (destmove.go).
			return handleMovementRequest(sess, p, hub, chars)
		case OpMovementStopRequest:
			// Round 808: the arrow keys' stop and turn (destmove.go).
			return handleMovementStopRequest(sess, p, hub)
		case OpMovementTurnRequest:
			return handleMovementTurnRequest(sess, p, hub)
		case OpUnstuck:
			// Round 749's verification, FP6: the server's /unstuck (unstuck.go).
			return handleUnstuck(ctx, sess, hub, chars, eq, zerk)
		case OpChangeZone:
			return handleChangeZone(ctx, sess, p, eq, chars, hub, zerk)
		case OpReadyToPlay:
			// Round 786: the client's loading is done (arrival.go).
			return handleReadyToPlay(sess)
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
		if ok {
			forgetPlayerView(left.CharacterID, sess)
		}
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
			cancelActions(left.CharacterID)
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
			// And a pending warp landing (round 646's review), and the points
			// the server named for it (round 749).
			forgetWarpLanding(left.CharacterID)
			forgetArrival(left.CharacterID) // round 786, arrival.go
			forgetLandings(left.CharacterID)
			forgetWalkIn(hub, left.CharacterID)
			// The skill and quest runtimes' per-character state (round 785
			// review).
			forgetCharacterSkillState(left.CharacterID)
			// Round 821: its fellow guild members see it go offline.
			guildMemberPresence(context.Background(), left.CharacterID, false)
		}
		// Nor may it save where the stale session last stood, or tell the
		// zone the character left: the live session's entity is still there,
		// and its own disconnect saves and announces it (the 616-618
		// integration review).
		if stillLive {
			return
		}
		// A character leaving dead is saved at its return point (round 665,
		// savedPlace).
		savePosition(chars, sess, savedPlace(chars, sess, left))
		// The players in view drop it: retail's 0x3016 (round 737,
		// playerview.go; CMsgBlock slot 3 -> FUN_00534050), where OpenSRO
		// sent its own OpEntityLeft.
		departPlayer(hub, left, remaining)
		// Its COS leave with it, their state saved (round 795).
		cosOwnerLeft(left.CharacterID)
		// Round 838: its premium is saved and dropped (goldtime.go).
		goldTimeLeft(left.CharacterID)
		// Its job's runtime state (round 800): a pending suit change, the
		// battle state, the cached record.
		forgetJobMode(left.CharacterID)
		forgetJobRecord(left.CharacterID)
		forgetTradeScale(left.CharacterID)
		forgetLeftPlayer(hub, left.CharacterID)
	}
}

func handleEnterWorld(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, eq equipment.Store, hub *world.Hub, onEnter EnterHook, zerk *berserk.Tracker) error {
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
	owned := findOwned(list, req.CharacterName)
	if owned == nil {
		return sess.Send(&proto.Packet{
			Opcode: OpEnterWorldResult,
			Data:   (&EnterWorldResult{Reason: "no such character on this account"}).Encode(),
		})
	}
	// A character pending deletion does not enter (round 682): Start refuses
	// it with 0x402 (READ, handleStart), and this older path must not be the
	// way around that.
	if owned.Deleting() {
		return sess.Send(&proto.Packet{
			Opcode: OpEnterWorldResult,
			Data:   (&EnterWorldResult{Reason: "the character is pending deletion"}).Encode(),
		})
	}
	// Nor around a waiting rename (round 838, OURS, as handleStart).
	if startRefusalForService(ctx, chars, owned.ID) != 0 {
		return sess.Send(&proto.Packet{
			Opcode: OpEnterWorldResult,
			Data:   (&EnterWorldResult{Reason: "the character's name change is waiting"}).Encode(),
		})
	}
	return enterOwned(ctx, sess, owned, chars, eq, hub, onEnter, zerk)
}

// handleStart is 0x7001, Start (round 682; lobby.go): the name, checked as
// SR_ShardManager's FUN_0040e2c0 does (READ, charselect.md section 2
// "Start") -- not logged in 0x407; an empty name 0x402; (retail also refuses
// a quote or a forbidden word with 0x402: not applied, see below); not on
// the account 0x40b; pending
// deletion 0x402 -- then 0xB001 [1] and the existing enter-world path, whose
// OpEnterWorldResult follows (INFERRED: retail sends 0xB001 [1] once the game
// server accepts, then the character data; the OpEnterWorldResult stands in
// for that data until the world handoff is retail too). The "operation
// pending" refusal (0x40e) has nothing to guard here: one request is handled
// at a time on a session.
func handleStart(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, eq equipment.Store, hub *world.Hub, onEnter EnterHook, zerk *berserk.Tracker) error {
	refuse := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: OpStartResult, Data: (&StartResult{Code: code}).Encode()})
	}
	accountID, ok := AuthenticatedAccountID(sess)
	if !ok {
		return refuse(LobbyErrNoUser)
	}
	req, err := DecodeStartRequest(p.Data)
	// An empty name is refused (READ). The server's quote refusal is NOT
	// applied here (round 682's review, OURS): a name made before round 682
	// may hold a quote (names are grandfathered), and the name is only
	// matched against the account's own list below, never put into a query
	// unparameterised -- so refusing it would only lock such a character out.
	if err != nil || req.Name == "" {
		return refuse(LobbyErrRefused)
	}
	list, err := chars.ListByAccount(ctx, accountID)
	if err != nil {
		return refuse(LobbyErrRefused)
	}
	owned := findOwned(list, req.Name)
	if owned == nil {
		return refuse(LobbyErrNotOnAccount)
	}
	if owned.Deleting() {
		return refuse(LobbyErrRefused)
	}
	// Round 838 (servicescroll.go, OURS): a rename the Name Change Scroll
	// left waits for the select screen's new name.
	if code := startRefusalForService(ctx, chars, owned.ID); code != 0 {
		return refuse(code)
	}
	if err := sess.Send(&proto.Packet{Opcode: OpStartResult, Data: (&StartResult{OK: true}).Encode()}); err != nil {
		return err
	}
	return enterOwned(ctx, sess, owned, chars, eq, hub, onEnter, zerk)
}

// enterOwned puts owned, already resolved to the session's account, into the
// world: the shared tail of OpEnterWorld and Start.
func enterOwned(ctx context.Context, sess *gateway.Session, owned *character.Character, chars character.Store, eq equipment.Store, hub *world.Hub, onEnter EnterHook, zerk *berserk.Tracker) error {
	if onEnter != nil {
		if err := onEnter(ctx, owned); err != nil {
			log.Printf("session: enter hook for %q: %v", owned.Name, err)
		}
	}
	// Round 838 (servicescroll.go, OURS): the plate colours cached, and a
	// stat or skill reset a scroll left for this login run before the
	// character is placed.
	owned = serviceAtEntry(ctx, chars, owned)
	// The avatar inventory's integrity (round 789, avatar.go): a failing item
	// goes to the bag; with no room the entry is refused, as retail refuses
	// the login (CGObjPC::Create s:0x4e0dc0).
	if err := mendAvatarsAtEntry(ctx, owned); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEnterWorldResult, Data: (&EnterWorldResult{Reason: err.Error()}).Encode()})
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
	} else if startZone, startBucket, startPos, startFrame, ok := startArrival(owned); ok {
		// No saved position, and a start spawn from creation (round 682): the
		// race's READ spawn. Sent as Restored, so the client keeps the point
		// rather than moving it to the zone's own landing spot.
		zone, bucket, pos, frame, restored = startZone, startBucket, startPos, startFrame, true
	}
	// The client starts its NPC roster over at the result (round 708), so the
	// NPC window forgets what it sent this session and spawns it whole again
	// on its next tick, even when the character re-enters where it left.
	forgetNPCWindow(sess.ID())
	// Closed until the result is out (round 737's review, F3): nothing
	// about another player reaches the client before it, and arrivePlayer
	// spawns whoever is in view when it opens.
	closePlayerView(owned.ID, sess, viewDeps{ctx: ctx, hub: hub, eq: eq, chars: chars, zerk: zerk})
	invalidateLook(owned.ID) // what it wears is read afresh at each entry
	// Held out of the world until the client's loading-done report (round
	// 786, arrival.go): retail's PC enters its block only on the 0x3012.
	guard := arrivalGuardOn.Load()
	if guard {
		hub.EnterHeld(sess, owned.ID, owned.Name, owned.Level, bucket, pos)
	} else {
		hub.Enter(sess, owned.ID, owned.Name, owned.Level, bucket, pos)
	}
	// The arrival and the client's spawn spot there are points the server
	// named: the client's placement on its ground is taken there (round 749,
	// destmove.go relocationAdmits).
	noteArrivalLanding(owned.ID, zone, pos)
	noteWalkInArrival(hub, owned.ID, bucket, pos) // round 773, walkin.go
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

	// The players already here are not listed in the result any more (round
	// 737, crowd_scale.md C1): they follow it as retail's group spawns, one
	// group per block of the arrival's 3 x 3 window (arrivePlayer), however
	// many there are. The list in one frame refused the arriving session past
	// 166 full-kit players (round 736, MEASURED).
	result := &EnterWorldResult{
		OK: true, Zone: zone,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		Gender:      owned.Gender,
		HP:          int32(owned.HP),
		MaxHP:       int32(owned.MaxHP()),
		FrameRegion: frame,
		Restored:    restored,
		Heading:     heading,
		HasHeading:  true,
	}
	// The character's own model (round 689): the body it was made from.
	ownRef, ownScale := modelOf(owned)
	result.RefObjID, result.Scale, result.HasModel = ownRef, ownScale, true
	if enterWorldBeforeResultHook != nil {
		enterWorldBeforeResultHook(sess)
	}
	data, dropped := result.EncodeFitting()
	if err := sess.Send(&proto.Packet{Opcode: OpEnterWorldResult, Data: data}); err != nil {
		return err
	}
	if dropped {
		sendPlusesAsBroadcasts(sess, result.Others)
	}
	// The game clock (round 786, celestial.go): retail's EnterGame sends
	// 0x3020 right after the character data, once per entry (READ, 0x403237
	// -> 0x4e3eb0). The result stands in for the character data, so it
	// follows the result. A client older than round 786 has no handler for
	// it and logs it once as unhandled.
	if err := sendCelestialPosition(sess, owned.ID, time.Now()); err != nil {
		return err
	}
	// And again after the result (round 708's review, HIGH 1): the area of
	// interest ticks on its own goroutine, so a tick between hub.Enter above
	// and this Send could have sent the whole NPC window -- queued BEFORE the
	// result, which the client answers by clearing its roster. Forgetting
	// here makes the next tick send the window again, after the result; a
	// window a tick sends after the result is simply sent twice, and the
	// client keeps an identical record in place (World3D._on_npc_spawned).
	forgetNPCWindow(sess.ID())

	// The players in view (round 737, playerview.go): the arriving client
	// is sent theirs as group spawns, each followed by its buffs, and they
	// are sent its 0x3015 -- the record carries the heading, the model, the
	// worn items with their pluses, the motion and the body mode.
	// The item-started skill jobs (round 838, itemskill.go) put their buffs
	// back first, so the spawns below and the own buffs carry them.
	restoreSkillJobs(ctx, owned.ID, time.Now())
	arrived, inWorld := hub.EntityBySession(sess.ID())
	if inWorld && guard {
		holdArrival(viewDeps{ctx: ctx, hub: hub, eq: eq, chars: chars, zerk: zerk}, arrived, "enter world", nil)
	} else if inWorld {
		arrivePlayer(viewDeps{ctx: ctx, hub: hub, eq: eq, chars: chars, zerk: zerk}, arrived)
	}
	// The client's own character id (round 616, OpSelfID), after the
	// world-entry messages and before any buff that may name it.
	if err := sess.Send(&proto.Packet{Opcode: OpSelfID, Data: (&SelfID{CharacterID: owned.ID}).Encode()}); err != nil {
		return err
	}
	// Its own buffs (round 616, buffs.go; OURS) -- the others' came with
	// their spawns.
	if inWorld {
		sendOwnBuffs(arrived, time.Now())
	}
	// Its quest log and the quest NPCs' marks (round 785, quest.go): the
	// section retail carries in its character data.
	questAfterEnter(ctx, sess, owned)
	// The friend list and the log-on push (round 834, friend.go): retail's
	// 0x3305 follows the character data.
	friendAfterEnter(ctx, sess, owned)
	// The silk balances (round 837, mall.go): retail's 0x3153 when the
	// billing load completes after the placement.
	mallAfterEnter(ctx, sess)
	// Round 837 (OURS): an account's login notice (loginnotice.go).
	loginNoticeAfterEnter(sess)
	// Round 838 (OURS): its own plate colours and the resets' lines.
	serviceAfterEnter(sess, owned)
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
	// DESIGN, disclosed: OpenSRO's zone change is its own discrete warp with
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
	username, _ := AuthenticatedUsername(sess)
	pos = changeZoneLanding(req, pos, zoneSpotGM(username))
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
	return warpVia(ctx, sess, eq, chars, hub, zerk, zone, bucket, pos, frame, "zone change")
}

// warpVia is warpTo naming the path (round 786, arrival.go): with the
// arrival guard on, the character is filed held at its arrival -- in no
// window until its client's 0x3012 -- and its spawns both ways and the
// protection come with the release (holdArrival); off, it arrives at once
// as before.
func warpVia(ctx context.Context, sess *gateway.Session, eq equipment.Store, chars character.Store, hub *world.Hub, zerk *berserk.Tracker, zone, bucket string, pos world.Position, frame, via string) (moved bool, err error) {
	guard := arrivalGuardOn.Load()
	change := hub.ChangeZone
	if guard {
		change = hub.ChangeZoneHeld
	}
	old, remainingOld, _, ok := change(sess, bucket, pos)
	if !ok {
		return false, sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: (&ChangeZoneResult{Reason: "not in the world"}).Encode()})
	}
	// The old view goes with the old zone (round 737's review, F3): the
	// client starts over at its result, and arrivePlayer opens a new view on
	// the players in view then. Closed meanwhile, nothing about another
	// player is recorded in a view about to be thrown away.
	d := viewDeps{ctx: ctx, hub: hub, eq: eq, chars: chars, zerk: zerk}
	if !storeViewIfLive(hub, old.CharacterID, sess, closedView(sess, d)) {
		// A stale session of a reconnect (round 737's verification, N4): the
		// hub moved its entity, but the character is live on a newer
		// session, whose view, motion, berserk, saved place and watchers
		// this must not touch. Its own client hears its result.
		data, _ := (&ChangeZoneResult{
			OK: true, Zone: zone,
			X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
			FrameRegion: frame,
		}).EncodeFitting()
		return true, sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: data})
	}
	cancelActions(old.CharacterID)
	// Round 834: a warp closes the exchange 0x182b (s:FUN_004def00).
	exchangeEnd(old.CharacterID, ExchangeErrCancel)
	// A quest talk opened before the warp answers nothing after it (round
	// 785 review).
	forgetQuestTalk(sess.ID(), false)
	// A character arrives standing (round 607, motion.go; ours: the retail
	// object's re-creation is inferred). The client drops its own sit on the
	// zone change too.
	motions.stand(old.CharacterID, time.Now())
	// And runs again (round 781, OURS: motionTracker.runAgain).
	motions.runAgain(old.CharacterID)
	// A walled caster's landing is its client's to report (round 646,
	// walls.go noteWarpLanding): the root holds it where it lands.
	noteZoneWarpLanding(old.CharacterID, zone, pos, time.Now())
	noteArrivalLanding(old.CharacterID, zone, pos)       // round 749, destmove.go
	noteWalkInArrival(hub, old.CharacterID, bucket, pos) // round 773, walkin.go
	// The new label and frame are what a later save writes under, and the
	// arrival itself is saved at once under -persist-position (round 573).
	rememberPlace(sess, zone, frame, time.Now())
	arrived := old
	arrived.Zone, arrived.Pos = bucket, pos
	savePosition(chars, sess, arrived)

	// The players where it lands follow the result as group spawns (round
	// 737, arrivePlayer), not in its list.
	result := &ChangeZoneResult{
		OK: true, Zone: zone,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z),
		FrameRegion: frame,
	}
	if warpBeforeResultHook != nil {
		warpBeforeResultHook(sess)
	}
	data, _ := result.EncodeFitting()
	if err := sess.Send(&proto.Packet{Opcode: OpChangeZoneResult, Data: data}); err != nil {
		return true, err
	}

	// The window it left drops it (0x3016), even a window it lands in view
	// of again: it was taken out and put back, as retail's block removal and
	// insertion are, and its new spawn follows. Each client sent the 0x3016
	// hears the OURS zone notice (left) ahead of it, and only those.
	departPlayer(hub, old, world.WatchersOf(remainingOld))

	// The arrival faces the way the character last moved: the hub carries
	// the heading through the change (world.Hub.ChangeZone). A zone change
	// keeps the book (OURS: whether retail's teleport keeps buffs was not
	// read); the players in view learn the mover's with its spawn, and the
	// mover theirs with theirs (round 737).
	if now, ok := hub.EntityBySession(sess.ID()); ok {
		arrived = now
	}
	arrived.Session = sess
	// A running berserk ends with the zone change (endBerserk: the world
	// entry's body mode is READ, that a zone change is a re-entry INFERRED),
	// as the client's display does (FUN_00787860): the mover hears body mode
	// 0, and the players where it lands spawn it with 0 (round 737: before
	// the spawns, so their records carry it).
	endBerserk(hub, zerk, old.CharacterID)
	if guard {
		// Out of the world until its client's loading is done (round 786):
		// the spawns both ways and the protection follow the 0x3012.
		holdArrival(d, arrived, via, nil)
	} else {
		arrivePlayer(d, arrived)
	}
	sendOwnBuffs(arrived, time.Now())
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
		// A step from where the character fell, sent before the server
		// moved it home, is dropped (round 665's review, returnGuard).
		if returnGuardDrops(sess, e, float64(req.X), float64(req.Z), time.Now()) {
			return nil
		}
		moved := motions.moved
		// Round 646, OURS: a rooted caster's warp landing is taken
		// (walls.go warpLandingAdmits) -- once, at a point the server named;
		// a walk is still dropped.
		if warpLandingAdmits(e.CharacterID, req.Relocated, float64(req.X), float64(req.Z), time.Now()) {
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
	now := time.Now()
	// Round 749 (destmove.go): a walk is retail's 0x7021 now, and this
	// message carries only where a walk stopped short (the stop flag), a
	// placement (the relocated flag), or an older client's walked position.
	// Each is taken only within the server's own leg's reach, or at a point
	// the server named; one it does not take ends the leg where the server
	// has it, and the window -- the mover included -- is told so (0xB023).
	//
	// A relocation or a stop keeps the heading (round 637's review
	// follow-up: the client places an object without aiming it,
	// FUN_009e11e0); an older client's walked position faces the way it
	// moved, and its heading run the run's heading (round 653).
	kind, heading := world.MoveWalk, 0.0
	switch {
	case req.Relocated, req.Stopped:
		kind = world.MoveRelocate
	case req.Run:
		kind, heading = world.MoveHeading, world.HeadingFromWire(req.RunAngle)
	}
	// Round 749's review, F1: a claim, measured from the server's own anchor
	// with a clocked allowance (world.Hub.Claim, destmove.go claimBound).
	self, inWorld := hub.EntityBySession(sess.ID())
	if !inWorld {
		return nil
	}
	// Round 749's verification (minor): a character whose states stop a move,
	// or in an established trade, may not move by claims either (as by
	// 0x7021, destmove.go); its client is put back where the server has it.
	if !trustPositions.Load() && (!statusFX.characterCanMove(self.CharacterID) || tradeEstablishedOn(hub, self.CharacterID)) {
		correctMover(sess, hub)
		return nil
	}
	moved, admitted, ok := hub.Claim(sess, pos, kind, heading, claimBound(self.CharacterID, req.Relocated, now))
	if !ok {
		return nil // not in the world yet (no OpEnterWorld) -- ignore
	}
	traceMove("move: claim", "character", self.CharacterID, "stopped", req.Stopped, "relocated", req.Relocated,
		"x", pos.X, "y", pos.Y, "z", pos.Z, "taken", admitted, "server_x", moved.Entity.Pos.X, "server_z", moved.Entity.Pos.Z)
	if !admitted {
		correctMover(sess, hub)
		return nil
	}
	entity := moved.Entity
	motions.walking(entity.CharacterID, now)
	// An older client's walked position is the player's own move, and cancels
	// a running auto-attack as it did (keepup.go); a stop report or a
	// placement is not a move the player asked for.
	if !req.Relocated && !req.Stopped {
		moveCancelsActions(entity.CharacterID)
	}
	// Round 749: relayed as retail's 0xB023 (the stop/position message,
	// FUN_008a4f80, which snaps the body there and ends its turn) to the
	// players in view that hold the mover -- not to the mover, whose client
	// is already there. A block crossing spawns and despawns both ways, as
	// before (round 737, playerview.go).
	stopRelay(sess, moved, false)
	// A walk-in zone the reported walk crossed (round 773, walkin.go).
	walkInClaimed(hub, entity, req.Relocated)
	// Under -persist-position the walk is saved at most once every
	// positionSaveInterval (round 573), so a crash loses little of it --
	// after the relay (savePositionEvery).
	savePositionEvery(chars, sess, entity, now)
	return nil
}
