// Package pcspawn is retail's spawn record for a player character (round
// 737, docs/protocol/crowd_scale.md C1): the body of a 0x3015 single spawn
// (then the spawn-type byte) and of a group spawn's 0x3019 data (no trailing
// byte, npcspawn.GroupFrames), as SR_GameServer.exe writes it for a CGObjPC
// (CGObjPC::vslot_294 0x4e5a10, mode 2) and sro_client.exe reads it for a
// CICUser (FUN_008a6bd0, then CICUser slot 25 GlobalDataManager::FUN_009de2f0
// and its readers, vtable 0xde2e7c). Every field, width and condition is READ
// from both binaries; docs/protocol/pc_spawn.md has the table with the
// addresses. What OpenSRO puts IN a field it does not model is labelled
// where it is filled (session/pcrecord.go).
package pcspawn

import (
	"encoding/binary"
	"fmt"
	"math"
)

// JobStateNone is the job state of a character wearing no job suit in equip
// slot 8 (READ: the server's 0x4e124e sets 4 by default, 1/2/3 from the
// slot-8 suit's predicates; the client the same from the suit's TypeID
// 3/1/7/1..3). The name is the character name only in this state, and the
// guild block is written only in it.
const JobStateNone byte = 4

// TeamNone is the last byte for world 1 (READ: GObjPC::FUN_00645b70 writes
// 0xff when the world id is 1, after FUN_00669f00 found no entry).
const TeamNone byte = 0xff

// Item is one worn item of the record's equipment list.
type Item struct {
	RefItemID uint32
	// Plus is the effective plus (OptLevel + advanced elixir), written only
	// when HasPlus: an item of TypeID 3/1 (CInstanceItem::vslot_010 mode 2,
	// 0x42e230; the client's same type-word test at 0x9de350).
	Plus    uint8
	HasPlus bool
}

// Record is one player's spawn record.
type Record struct {
	RefObjID uint32
	// Scale is _CHAR.Scale: Height in the low nibble, Volume in the high.
	Scale         uint8
	HwanLevel     uint8
	PVPCape       uint8
	AutoInvestExp uint8
	// InventorySize is _CHAR.InventorySize (the client reads and drops it).
	// The count byte after it is written only when it is non-zero while the
	// client always reads it, so it must never be 0 (Append refuses 0).
	InventorySize uint8
	// Items is what equip slots 0..8 hold, ascending, empty slots skipped
	// (CGPCInventoryOP slot 29 0x4ba720).
	Items []Item
	// AvatarSize is the avatar storage's size; no avatar items follow
	// (OpenSRO has no avatar slots).
	AvatarSize uint8

	UID     uint32
	Region  uint16
	X, Y, Z float32 // local to Region
	Angle   uint16
	// RunFlag is the mover's +0x155 (the motion setter's 2 + (it != 0)).
	RunFlag byte
	// The stance bytes, chardata[0..3]: the life state, an unread byte, the
	// motion state (0 STAND, 2 WALK, 3 RUN, 4 SIT) and the body mode.
	Life, Stance1, Motion, BodyMode byte
	// Params 23, 24 and 140.
	Walk, Run, Param140 float32

	Name                string
	JobType, JobLevel   byte
	PVPState, RideState byte
	BattleState         byte
	TeleportState       byte
	InteractMode        byte
	TradeRank           byte
	GuildName           string
	// JobState is the job state the slot-8 suit gives; the guild block is
	// written only for JobStateNone. 0, the zero value, is no job state the
	// engine has and is written as JobStateNone (round 737's review).
	JobState byte
	Timer    byte
	Team     byte
}

// Append appends r's bytes in wire order. It refuses what the reader could
// not take back: an inventory size of 0, a ride state of 1 (the ridden
// object's id is not modelled), an interact mode of 4 (the stall block is
// not modelled), more than 255 items.
func Append(out []byte, r Record) ([]byte, error) {
	if r.InventorySize == 0 || r.AvatarSize == 0 {
		return out, fmt.Errorf("pcspawn: a storage size of 0 drops the count byte the client reads")
	}
	if len(r.Items) > 255 {
		return out, fmt.Errorf("pcspawn: %d items", len(r.Items))
	}
	if r.RideState == 1 {
		return out, fmt.Errorf("pcspawn: ride state 1 needs the ridden object's id")
	}
	if r.InteractMode == 4 {
		return out, fmt.Errorf("pcspawn: interact mode 4 needs the stall block")
	}
	// CInstancePC::vslot_010 0x8412b0 mode 2; the client's 0x8a6bd0 and slot
	// 22 0x9dbc30.
	out = binary.LittleEndian.AppendUint32(out, r.RefObjID)
	out = append(out, r.Scale, r.HwanLevel, r.PVPCape, r.AutoInvestExp)
	// GStorage::FUN_004b8ad0 twice: the inventory's equipment, the avatars.
	out = append(out, r.InventorySize, byte(len(r.Items)))
	for _, it := range r.Items {
		out = binary.LittleEndian.AppendUint32(out, it.RefItemID)
		if it.HasPlus {
			out = append(out, it.Plus)
		}
	}
	out = append(out, r.AvatarSize, 0)
	// The mask flag (GObjPC::FUN_004dd6b0): none.
	out = append(out, 0)
	// CGObjMobile::vslot_293 0x48b630: the unique id, the position, the
	// mover with no destination (0x48be00), then CGObjChar 0x4a9b70's stance
	// bytes, speeds and buffs (none: OpenSRO's buffs follow as their own
	// messages).
	out = binary.LittleEndian.AppendUint32(out, r.UID)
	out = binary.LittleEndian.AppendUint16(out, r.Region)
	out = appendF32(out, r.X)
	out = appendF32(out, r.Y)
	out = appendF32(out, r.Z)
	out = binary.LittleEndian.AppendUint16(out, r.Angle)
	out = append(out, 0, r.RunFlag, 0)
	out = binary.LittleEndian.AppendUint16(out, r.Angle)
	out = append(out, r.Life, r.Stance1, r.Motion, r.BodyMode)
	out = appendF32(out, r.Walk)
	out = appendF32(out, r.Run)
	out = appendF32(out, r.Param140)
	out = append(out, 0)
	// CGObjPC::vslot_293 0x4e5b00 mode 2.
	out = appendString(out, r.Name)
	out = append(out, r.JobType, r.JobLevel, r.PVPState, r.RideState, r.BattleState)
	out = append(out, r.TeleportState, r.InteractMode, r.TradeRank)
	out = appendString(out, r.GuildName)
	if r.JobState == JobStateNone || r.JobState == 0 {
		// The guild block (0x4e5d3b..0x4e5eb3): guild id, member nickname,
		// three u32, the "no membership" byte, the fortress role. OpenSRO
		// writes the no-guild form.
		out = binary.LittleEndian.AppendUint32(out, 0)
		out = appendString(out, "")
		out = binary.LittleEndian.AppendUint32(out, 0)
		out = binary.LittleEndian.AppendUint32(out, 0)
		out = binary.LittleEndian.AppendUint32(out, 0)
		out = append(out, 0, 0)
	}
	out = append(out, r.Timer, r.Team)
	return out, nil
}

func appendF32(out []byte, v float32) []byte {
	return binary.LittleEndian.AppendUint32(out, math.Float32bits(v))
}

func appendString(out []byte, s string) []byte {
	out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
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
		r.err = fmt.Errorf("pcspawn: record cut short (%d byte(s) wanted, %d left)", n, len(r.b))
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
func (r *reader) str() string  { return string(r.take(int(r.u16()))) }

// Types answers what the client's own item table says of a RefItemID, which
// is what its reader decides two things by: whether a plus byte follows an
// equipment-list item (TypeID 3/1), and the job state (the visual-slot-8
// suit's TypeID4 when it is 3/1/7/1..3, else JobStateNone; the client's
// slot 25 -> 0x9db8b0). nil answers "equipment, no suit" for every item.
type Types interface {
	HasPlus(refItemID uint32) bool
	JobState(items []Item) byte
}

// Decode reads one record from b as the client does, returning it and the
// bytes after it. The forms OpenSRO never writes -- avatar items, a mask, a
// destination, buffs, a ride, a stall -- are refused.
func Decode(b []byte, types Types) (Record, []byte, error) {
	r := &reader{b: b}
	var d Record
	d.RefObjID = r.u32()
	d.Scale, d.HwanLevel, d.PVPCape, d.AutoInvestExp = r.u8(), r.u8(), r.u8(), r.u8()
	d.InventorySize = r.u8()
	n := int(r.u8())
	for i := 0; i < n && r.err == nil; i++ {
		it := Item{RefItemID: r.u32()}
		if types == nil || types.HasPlus(it.RefItemID) {
			it.Plus, it.HasPlus = r.u8(), true
		}
		d.Items = append(d.Items, it)
	}
	d.AvatarSize = r.u8()
	if r.u8() != 0 && r.err == nil {
		return d, nil, fmt.Errorf("pcspawn: avatar items are not OpenSRO's")
	}
	if r.u8() != 0 && r.err == nil {
		return d, nil, fmt.Errorf("pcspawn: a mask is not OpenSRO's")
	}
	d.UID = r.u32()
	d.Region = r.u16()
	d.X, d.Y, d.Z = r.f32(), r.f32(), r.f32()
	d.Angle = r.u16()
	if r.u8() != 0 && r.err == nil {
		return d, nil, fmt.Errorf("pcspawn: a destination form is not OpenSRO's")
	}
	d.RunFlag = r.u8()
	r.u8()
	if a := r.u16(); a != d.Angle && r.err == nil {
		return d, nil, fmt.Errorf("pcspawn: mover angle %d, position angle %d", a, d.Angle)
	}
	d.Life, d.Stance1, d.Motion, d.BodyMode = r.u8(), r.u8(), r.u8(), r.u8()
	d.Walk, d.Run, d.Param140 = r.f32(), r.f32(), r.f32()
	if r.u8() != 0 && r.err == nil {
		return d, nil, fmt.Errorf("pcspawn: buffs are not OpenSRO's")
	}
	d.Name = r.str()
	d.JobType, d.JobLevel, d.PVPState, d.RideState, d.BattleState = r.u8(), r.u8(), r.u8(), r.u8(), r.u8()
	if d.RideState == 1 && r.err == nil {
		return d, nil, fmt.Errorf("pcspawn: a ride is not OpenSRO's")
	}
	d.TeleportState, d.InteractMode, d.TradeRank = r.u8(), r.u8(), r.u8()
	d.GuildName = r.str()
	d.JobState = JobStateNone
	if types != nil {
		d.JobState = types.JobState(d.Items)
	}
	if d.JobState == JobStateNone {
		if r.u32() != 0 || r.str() != "" || r.u32() != 0 || r.u32() != 0 || r.u32() != 0 || r.u8() != 0 || r.u8() != 0 {
			if r.err == nil {
				return d, nil, fmt.Errorf("pcspawn: a guild is not OpenSRO's")
			}
		}
	}
	if d.InteractMode == 4 && r.err == nil {
		return d, nil, fmt.Errorf("pcspawn: a stall is not OpenSRO's")
	}
	d.Timer, d.Team = r.u8(), r.u8()
	if r.err != nil {
		return d, nil, r.err
	}
	return d, r.b, nil
}
