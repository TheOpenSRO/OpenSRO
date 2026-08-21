package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
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
)

// spawnZone/spawnPos are the single fixed starting point every character
// enters at. Placeholder until real map data exists — see
// docs/protocol/db_schema.md's note that map/zone data hasn't been pulled
// apart yet.
const spawnZone = "jangan"

var spawnPos = world.Position{X: 0, Y: 0, Z: 0}

// EntitySnapshot describes one character's presence in the world: who they
// are, where they are, whether they have real armor/weapon equipped
// (queried live from the equipment store at broadcast time -- see
// equippedSlots -- so it always reflects the character's actual current
// equip state, not a value cached when they entered the world), and their
// real Gender (one of character.GenderChinaMan/GenderChinaWoman -- see
// character.go), which picks which real body/skeleton assets the client
// renders them with.
type EntitySnapshot struct {
	CharacterID int64
	Name        string
	X, Y, Z     float32
	HasArmor    bool
	HasWeapon   bool
	Gender      string
}

func (e *EntitySnapshot) Encode() []byte {
	out := encodeInt64(e.CharacterID)
	out = append(out, encodeStrings(e.Name)...)
	out = append(out, encodeFloat32(e.X)...)
	out = append(out, encodeFloat32(e.Y)...)
	out = append(out, encodeFloat32(e.Z)...)
	if e.HasArmor {
		out = append(out, 1)
	} else {
		out = append(out, 0)
	}
	if e.HasWeapon {
		out = append(out, 1)
	} else {
		out = append(out, 0)
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
		return nil, nil, fmt.Errorf("has_armor: %w", errors.New("truncated"))
	}
	hasArmor := rest[0] != 0
	rest = rest[1:]

	if len(rest) < 1 {
		return nil, nil, fmt.Errorf("has_weapon: %w", errors.New("truncated"))
	}
	hasWeapon := rest[0] != 0
	rest = rest[1:]

	genderFields, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("gender: %w", err)
	}

	return &EntitySnapshot{CharacterID: id, Name: names[0], X: x, Y: y, Z: z, HasArmor: hasArmor, HasWeapon: hasWeapon, Gender: genderFields[0]}, rest, nil
}

// hasArmorEquipped reports whether characterID currently has anything
// equipped in equipment.SlotArmor. eq may be nil (some handler chains --
// tests exercising features unrelated to armor -- wire up WorldHandler
// without an equipment store), in which case this always reports false
// rather than requiring every caller to carry one around. Errors are
// treated the same as "not equipped" -- an equipment lookup failure
// shouldn't block someone from entering the world or moving, and
// defaulting to no armor is the more honest failure mode (never claims
// equipment that couldn't be confirmed).
// equippedSlots reports whether characterID currently has anything
// equipped in equipment.SlotArmor and equipment.SlotWeapon, in one real
// equipment-store lookup rather than querying twice. eq may be nil (some
// handler chains -- tests exercising features unrelated to equipment --
// wire up WorldHandler without an equipment store), in which case this
// always reports false for both rather than requiring every caller to
// carry one around. Errors are treated the same as "not equipped" -- an
// equipment lookup failure shouldn't block someone from entering the
// world or moving, and defaulting to unequipped is the more honest
// failure mode (never claims equipment that couldn't be confirmed).
func equippedSlots(ctx context.Context, eq equipment.Store, characterID int64) (hasArmor, hasWeapon bool) {
	if eq == nil {
		return false, false
	}
	items, err := eq.Get(ctx, characterID)
	if err != nil {
		return false, false
	}
	for _, it := range items {
		switch it.Slot {
		case equipment.SlotArmor:
			hasArmor = true
		case equipment.SlotWeapon:
			hasWeapon = true
		}
	}
	return hasArmor, hasWeapon
}

// genderOf looks up characterID's real Gender via chars.GetByID, live at
// broadcast time -- world.Entity doesn't carry it (that package deliberately
// only tracks position/presence, not character details -- same reasoning
// as hasArmorEquipped not living in world.Entity either). Falls back to
// character.DefaultGender on any lookup error, the same honest-failure
// convention as hasArmorEquipped: never block a broadcast over this, and
// never guess at a value that couldn't be confirmed.
func genderOf(ctx context.Context, chars character.Store, characterID int64) string {
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return character.DefaultGender
	}
	return c.Gender
}

func entitySnapshotFromWorld(ctx context.Context, eq equipment.Store, chars character.Store, e world.Entity) EntitySnapshot {
	hasArmor, hasWeapon := equippedSlots(ctx, eq, e.CharacterID)
	return EntitySnapshot{
		CharacterID: e.CharacterID,
		Name:        e.Name,
		X:           float32(e.Pos.X), Y: float32(e.Pos.Y), Z: float32(e.Pos.Z),
		HasArmor:  hasArmor,
		HasWeapon: hasWeapon,
		Gender:    genderOf(ctx, chars, e.CharacterID),
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
// OK/Reason are meaningful -- Zone/position/Gender/Others aren't encoded.
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
	Others  []EntitySnapshot
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
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Others)))
	out = append(out, countBuf...)
	for _, o := range r.Others {
		out = append(out, o.Encode()...)
	}
	return out
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
	return r, nil
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
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpEnterWorld:
			return handleEnterWorld(ctx, sess, p, chars, eq, hub)
		case OpMove:
			return handleMove(sess, p, hub)
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
		msg := &EntityLeft{CharacterID: left.CharacterID}
		for _, other := range remaining {
			other.Session.Send(&proto.Packet{Opcode: OpEntityLeft, Data: msg.Encode()})
		}
	}
}

func handleEnterWorld(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, eq equipment.Store, hub *world.Hub) error {
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

	others := hub.Enter(sess, owned.ID, owned.Name, spawnZone, spawnPos)

	otherSnapshots := make([]EntitySnapshot, len(others))
	for i, o := range others {
		otherSnapshots[i] = entitySnapshotFromWorld(ctx, eq, chars, o)
	}
	result := &EnterWorldResult{
		OK: true, Zone: spawnZone,
		X: float32(spawnPos.X), Y: float32(spawnPos.Y), Z: float32(spawnPos.Z),
		Gender: owned.Gender,
		Others: otherSnapshots,
	}
	if err := sess.Send(&proto.Packet{Opcode: OpEnterWorldResult, Data: result.Encode()}); err != nil {
		return err
	}

	ownHasArmor, ownHasWeapon := equippedSlots(ctx, eq, owned.ID)
	entered := &EntitySnapshot{
		CharacterID: owned.ID, Name: owned.Name,
		X: float32(spawnPos.X), Y: float32(spawnPos.Y), Z: float32(spawnPos.Z),
		HasArmor:  ownHasArmor,
		HasWeapon: ownHasWeapon,
		Gender:    owned.Gender,
	}
	for _, other := range others {
		other.Session.Send(&proto.Packet{Opcode: OpEntityEntered, Data: entered.Encode()})
	}
	return nil
}

func handleMove(sess *gateway.Session, p *proto.Packet, hub *world.Hub) error {
	req, err := DecodeMoveRequest(p.Data)
	if err != nil {
		return nil // malformed move: drop it, don't kill the connection
	}

	pos := world.Position{X: float64(req.X), Y: float64(req.Y), Z: float64(req.Z)}
	entity, others, ok := hub.Move(sess, pos)
	if !ok {
		return nil // not in the world yet (no OpEnterWorld) -- ignore
	}

	msg := &EntityMoved{CharacterID: entity.CharacterID, X: req.X, Y: req.Y, Z: req.Z}
	for _, other := range others {
		other.Session.Send(&proto.Packet{Opcode: OpEntityMoved, Data: msg.Encode()})
	}
	return nil
}
