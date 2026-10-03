// Package npcspawn is how the server places the world's NPCs and tells a
// client about them, the way SR_GameServer.exe does (round 708): every NPC is
// an object the server spawns at its nest's position, facing its nest's
// direction, and a client learns of it only from the spawn messages -- the
// group spawn 0x3017 / 0x3019 / 0x3018 when the NPC's message block comes
// into the player's 3 x 3 window, the group despawn (the same three opcodes,
// type 2) when it goes out, and the single spawn 0x3015 / despawn 0x3016 for
// an object appearing in or leaving a block the player already holds.
//
// Everything on the wire is READ from both binaries (docs/protocol/
// npc_spawn.md has the addresses and the byte table). What is not READ is
// labelled where it is used.
package npcspawn

import (
	"encoding/binary"
	"fmt"
	"math"
)

// The retail opcodes (READ: the client's handler table, docs/protocol/
// broadcast_join.tsv; the server's senders FUN_00533f70 (0x3015),
// FUN_00534050 (0x3016) and FUN_00533e70 (0x3017, 0x3019, 0x3018: `push
// 0x3017` at 0x533ede, `push 0x3019` at 0x533f23, `push 0x3018` at 0x533f3e).
const (
	OpSingleSpawn   uint16 = 0x3015
	OpSingleDespawn uint16 = 0x3016
	OpGroupBegin    uint16 = 0x3017
	OpGroupEnd      uint16 = 0x3018
	OpGroupData     uint16 = 0x3019
)

// The group's type byte (READ: the client's FUN_008a6d20 takes 1 as a list of
// spawn records and 2 as a list of ids to despawn, and asserts on 0
// "byListSub"; the server's FUN_00533e70 takes the same 1 / 2).
const (
	GroupSpawn   byte = 1
	GroupDespawn byte = 2
)

// OpNpcFacingUnknown is OpenSRO's own extension (OURS, docs/protocol/
// PROTOCOL_DECISION.md's superset): u16 n, then n u32 unique ids, the NPCs
// about to be spawned whose angle is NOT their nest's -- an npcpos row with
// no nest row in the server's database, or a server with no database at all.
// Retail has no such case (every retail NPC hatches from a nest), so the
// record's angle field carries 0 for them and this message tells OpenSRO's
// client to face them by its own stand-in (NpcFacing) instead. A retail
// client never sees it unless it is sent, and it ignores unknown opcodes the
// way any client would not -- so the server sends it only ahead of a group
// that holds such an NPC. 0x00B6 was free in server/ and client/scripts/net
// (grep, 2026-10-03).
const OpNpcFacingUnknown uint16 = 0x00b6

// Interaction flag bits of the record's last block (READ: CGObjNPC::
// vslot_294 0x4c3cb0 writes the byte at +0x1cac; CGObjNPC::SetCharName
// 0x4c3f20 sets bit 0 and CGObjNPC::AddAvailableInteraction 0x4c3f50 bit 1;
// the client's reader ICharactor::FUN_009d15a0 0x9d15a0 also knows bit 2,
// which no CGObjNPC writer sets).
const (
	FlagName         byte = 1
	FlagInteractions byte = 2
)

// The stance block's values for a town NPC (docs/protocol/npc_spawn.md, "The
// stance block"):
//   - LifeAlive: CGObj::EnterWorld 0x485360 calls slot 226 (0x482420), which
//     is SetLifeState(1) (READ);
//   - the motion byte: CGObjChar::Create 0x4a6f40 stores 0xff and then calls
//     SetMotionState (0x4a9d00) with 0, which keeps 0 unless a status says
//     otherwise (FUN_004aab60) (READ);
//   - the second byte and the body mode are 0: no writer on an NPC's path was
//     found (INFERRED);
//   - the speeds are params 23, 24 and 140 (CGObjChar slot 293 0x4a9b70); an
//     NPC's stat initialisers (slots 0x574/0x580 of CGObjNPC's vtable) are
//     0x677a00, `return 1`, so the params keep the registry's defaults, 0, 0
//     and 100 (docs/protocol/param_registry.md) -- READ, with the param
//     writer map's own caveat that unresolved call sites exist (INFERRED that
//     none writes them for an NPC).
const (
	LifeAlive      byte    = 1
	NPCWalkSpeed   float32 = 0
	NPCRunSpeed    float32 = 0
	NPCParam140    float32 = 100
	movementNoDest byte    = 0
	// movementType is CGObjMobile::vslot_000's (0x48b450) +0x155 = 1; the
	// byte after it, +0x168, is 0 there too (READ).
	movementType byte = 1
)

// Record is one spawn record of a CICNPC as the server writes it and the
// client reads it.
type Record struct {
	RefID    uint32
	UID      uint32
	Region   uint16
	X, Y, Z  float32 // local to Region
	Angle    uint16  // 65535 to a turn (docs/protocol/opcodes/movement.md)
	Flags    byte
	Name     string // only with FlagName
	Interact []byte // only with FlagInteractions
}

// AppendRecord appends r's bytes, in the order SR_GameServer.exe writes them
// (CGObjNPC::vslot_294 0x4c3cb0, flag 2) and sro_client.exe reads them
// (FUN_008a6bd0 then CICNPC::vslot_025 0x9d46c0):
//
//	u32 RefObjID                      FUN_008a6bd0's first read
//	u32 unique id                     CGObjMobile slot 293 -> 0x484fb0 (+8)
//	u16 region, f32 x, y, z, u16 angle  0x487ce0 -> 0x488050; client 0x9c3a70
//	u8 0, u8 1, u8 0, u16 angle       movement, 0x48be00; client 0x8a5640(.., 1)
//	u8 1, u8 0, u8 0, u8 0            the stance bytes, 0x4a9b70; client 0x9d1300
//	f32 0, f32 0, f32 100             params 23, 24, 140
//	u8 0                              buffs (FUN_0059cdc0's count)
//	u8 flags [u16 n, name] [u8 n, n x u8 interaction]  0x4c3cb0 / 0x9d15a0
func AppendRecord(out []byte, r Record) []byte {
	out = binary.LittleEndian.AppendUint32(out, r.RefID)
	out = binary.LittleEndian.AppendUint32(out, r.UID)
	out = binary.LittleEndian.AppendUint16(out, r.Region)
	out = appendF32(out, r.X)
	out = appendF32(out, r.Y)
	out = appendF32(out, r.Z)
	out = binary.LittleEndian.AppendUint16(out, r.Angle)
	// The mover's block: no destination, so the angle again -- +0x164, which
	// CGObjMobile's SetHeading (0x48ba10) writes while +0x154 is 0.
	out = append(out, movementNoDest, movementType, 0)
	out = binary.LittleEndian.AppendUint16(out, r.Angle)
	out = append(out, LifeAlive, 0, 0, 0)
	out = appendF32(out, NPCWalkSpeed)
	out = appendF32(out, NPCRunSpeed)
	out = appendF32(out, NPCParam140)
	out = append(out, 0) // no buffs
	out = append(out, r.Flags)
	if r.Flags&FlagName != 0 {
		out = binary.LittleEndian.AppendUint16(out, uint16(len(r.Name)))
		out = append(out, r.Name...)
	}
	if r.Flags&FlagInteractions != 0 {
		out = append(out, byte(len(r.Interact)))
		out = append(out, r.Interact...)
	}
	return out
}

func appendF32(out []byte, v float32) []byte {
	return binary.LittleEndian.AppendUint32(out, math.Float32bits(v))
}

// SingleSpawn is the 0x3015 payload: one record, then the byte the client's
// vslot 0x68 (FUN_009c2180) reads to +0xf4 -- the type FUN_00533f70 is handed
// by the block (CMsgBlock slot 2's fourth argument). OpenSRO's NPCs are all in
// the world before any player, so a player always meets them in a group spawn
// and the server never sends this for them; it is here, with its decoder, so
// both sides hold the layout.
func SingleSpawn(r Record, spawnType byte) []byte {
	return append(AppendRecord(nil, r), spawnType)
}

// SingleDespawn is the 0x3016 payload: the unique id (FUN_00534050; the
// client's FUN_008a6cc0).
func SingleDespawn(uid uint32) []byte {
	return binary.LittleEndian.AppendUint32(nil, uid)
}

// GroupFrames is one group message as the server sends it (FUN_00533e70): a
// 0x3017 carrying the type and the count, the body in 0x3019 frames of at
// most chunk bytes, and an empty 0x3018. The client (0x3017 FUN_008ac0e0,
// 0x3019 FUN_008ac170, 0x3018 FUN_008ac3d0) puts the type, the count and the
// bodies back into one buffer and reads it as FUN_008a6d20 does. Retail
// sizes a data frame to what is left of its message buffer less 0x20
// (FUN_00430a20); chunk is OpenSRO's (OURS).
type GroupFrame struct {
	Opcode uint16
	Data   []byte
}

func GroupFrames(kind byte, count int, body []byte, chunk int) ([]GroupFrame, error) {
	if count < 0 || count > 0xffff {
		return nil, fmt.Errorf("npcspawn: a group of %d objects does not fit the u16 count", count)
	}
	if chunk <= 0 {
		return nil, fmt.Errorf("npcspawn: chunk %d", chunk)
	}
	begin := []byte{kind, byte(count), byte(count >> 8)}
	frames := []GroupFrame{{Opcode: OpGroupBegin, Data: begin}}
	for len(body) > 0 {
		n := min(chunk, len(body))
		frames = append(frames, GroupFrame{Opcode: OpGroupData, Data: body[:n:n]})
		body = body[n:]
	}
	return append(frames, GroupFrame{Opcode: OpGroupEnd}), nil
}

// SpawnGroup is the group spawn of records.
func SpawnGroup(records []Record, chunk int) ([]GroupFrame, error) {
	var body []byte
	for _, r := range records {
		body = AppendRecord(body, r)
	}
	return GroupFrames(GroupSpawn, len(records), body, chunk)
}

// DespawnGroup is the group despawn of uids (FUN_00533b90 writes each
// object's +8, the unique id, as a u32).
func DespawnGroup(uids []uint32, chunk int) ([]GroupFrame, error) {
	body := make([]byte, 0, 4*len(uids))
	for _, u := range uids {
		body = binary.LittleEndian.AppendUint32(body, u)
	}
	return GroupFrames(GroupDespawn, len(uids), body, chunk)
}

// FacingUnknown is the OpNpcFacingUnknown payload.
func FacingUnknown(uids []uint32) []byte {
	out := binary.LittleEndian.AppendUint16(nil, uint16(len(uids)))
	for _, u := range uids {
		out = binary.LittleEndian.AppendUint32(out, u)
	}
	return out
}

// ---- decoding, as the client reads it (tests and tools) ----

type reader struct {
	b   []byte
	err error
}

func (r *reader) take(n int) []byte {
	if r.err != nil {
		return nil
	}
	if len(r.b) < n {
		r.err = fmt.Errorf("npcspawn: record cut short (%d byte(s) wanted, %d left)", n, len(r.b))
		return nil
	}
	v := r.b[:n]
	r.b = r.b[n:]
	return v
}
func (r *reader) u8() byte {
	if v := r.take(1); v != nil {
		return v[0]
	}
	return 0
}
func (r *reader) u16() uint16 {
	if v := r.take(2); v != nil {
		return binary.LittleEndian.Uint16(v)
	}
	return 0
}
func (r *reader) u32() uint32 {
	if v := r.take(4); v != nil {
		return binary.LittleEndian.Uint32(v)
	}
	return 0
}
func (r *reader) f32() float32 { return math.Float32frombits(r.u32()) }

// Decoded is a record read back the way the client's readers take it,
// including the fields the server writes as constants.
type Decoded struct {
	Record
	MoveHasDest, MoveType, MoveSource byte
	MoveAngle                         uint16
	Life, Second, Motion, BodyMode    byte
	Walk, Run, Param140               float32
	Buffs                             byte
}

// DecodeRecord reads one record from b, returning it and the bytes after it.
// It follows the client's reading: the movement block's destination form
// (FUN_008a5640 with a region word, short or long coordinates) and buffs are
// refused, since an NPC record never carries them.
func DecodeRecord(b []byte) (Decoded, []byte, error) {
	r := &reader{b: b}
	var d Decoded
	d.RefID = r.u32()
	d.UID = r.u32()
	d.Region = r.u16()
	d.X, d.Y, d.Z = r.f32(), r.f32(), r.f32()
	d.Angle = r.u16()
	d.MoveHasDest = r.u8()
	d.MoveType = r.u8()
	if r.err == nil && d.MoveHasDest != 0 {
		return d, nil, fmt.Errorf("npcspawn: a moving record (destination form) is not an NPC's")
	}
	d.MoveSource = r.u8()
	d.MoveAngle = r.u16()
	d.Life, d.Second, d.Motion, d.BodyMode = r.u8(), r.u8(), r.u8(), r.u8()
	d.Walk, d.Run, d.Param140 = r.f32(), r.f32(), r.f32()
	d.Buffs = r.u8()
	if r.err == nil && d.Buffs != 0 {
		return d, nil, fmt.Errorf("npcspawn: a record with %d buff(s) is not an NPC's", d.Buffs)
	}
	d.Flags = r.u8()
	if d.Flags&FlagName != 0 {
		n := int(r.u16())
		d.Name = string(r.take(n))
	}
	if d.Flags&FlagInteractions != 0 {
		n := int(r.u8())
		d.Interact = append([]byte(nil), r.take(n)...)
	}
	if d.Flags&4 != 0 {
		r.take(5) // the client's bit 2: u8 + u32 (ICharactor::FUN_009d15a0)
	}
	if r.err != nil {
		return d, nil, r.err
	}
	return d, r.b, nil
}

// DecodeGroup reassembles a group's frames as the client does and returns its
// type and either the records (spawn) or the ids (despawn).
func DecodeGroup(frames []GroupFrame) (kind byte, records []Decoded, uids []uint32, err error) {
	if len(frames) < 2 || frames[0].Opcode != OpGroupBegin || frames[len(frames)-1].Opcode != OpGroupEnd {
		return 0, nil, nil, fmt.Errorf("npcspawn: not a 0x3017 .. 0x3018 group")
	}
	var buf []byte
	buf = append(buf, frames[0].Data...)
	for _, f := range frames[1 : len(frames)-1] {
		if f.Opcode != OpGroupData {
			return 0, nil, nil, fmt.Errorf("npcspawn: %#04x inside a group", f.Opcode)
		}
		buf = append(buf, f.Data...)
	}
	r := &reader{b: buf}
	kind = r.u8()
	n := int(r.u16())
	if r.err != nil {
		return 0, nil, nil, r.err
	}
	rest := r.b
	switch kind {
	case GroupSpawn:
		for i := 0; i < n; i++ {
			var d Decoded
			d, rest, err = DecodeRecord(rest)
			if err != nil {
				return kind, nil, nil, err
			}
			records = append(records, d)
		}
	case GroupDespawn:
		rr := &reader{b: rest}
		for i := 0; i < n; i++ {
			uids = append(uids, rr.u32())
		}
		if rr.err != nil {
			return kind, nil, nil, rr.err
		}
		rest = rr.b
	default:
		return kind, nil, nil, fmt.Errorf("npcspawn: group type %d", kind)
	}
	if len(rest) != 0 {
		return kind, records, uids, fmt.Errorf("npcspawn: %d byte(s) left after the group", len(rest))
	}
	return kind, records, uids, nil
}
