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
	// AvatarSize is the avatar storage's size (5, READ s:0x4e1340), and
	// Avatars what it holds, in storage order (round 789): each u32
	// RefItemID and u8 plus, no slot byte (READ s:0x4ba720 mode 2). The
	// client reads the plus only for a 3/1/13 or 3/1/14 ref (c:0x9de3e2), so
	// nothing else may be put here; every Avatars entry is written with its
	// plus.
	AvatarSize uint8
	Avatars    []Item

	UID     uint32
	Region  uint16
	X, Y, Z float32 // local to Region
	Angle   uint16
	// RunFlag is the mover's +0x155 (the motion setter's 2 + (it != 0)).
	RunFlag byte
	// The mover (0x48be00, READ; round 749): a character walking to a point
	// carries its destination -- has-destination 1, then the run flag, the
	// destination's region and three i16 region-local coordinates -- so a
	// client that spawns it mid-walk walks it on (FUN_009ca320 aims a body
	// that spawned moving). Otherwise has-destination 0, the run flag, the
	// mover's command byte (+0x168: 1 while a heading run steps) and its
	// angle (+0x164).
	// MoveAngle is written only with a non-zero MoveCommand; a still
	// character's mover angle is its Angle.
	HasDest             bool
	DestRegion          uint16
	DestX, DestY, DestZ int16
	// DungeonX, DungeonY, DungeonZ are the destination in a dungeon (round
	// 773): DestRegion with bit 15, then three i32 of dungeon space -- the
	// 0x48bad0 serialiser's dungeon branch (proto.Movement).
	DungeonX, DungeonY, DungeonZ int32
	MoveCommand                  byte
	MoveAngle                    uint16
	// The stance bytes, chardata[0..3]: the life state, an unread byte, the
	// motion state (0 STAND, 2 WALK, 3 RUN, 4 SIT) and the body mode.
	Life, Stance1, Motion, BodyMode byte
	// Params 23, 24 and 140.
	Walk, Run, Param140 float32

	Name                string
	JobType, JobLevel   byte
	PVPState, RideState byte
	BattleState         byte
	// MountUID is the ridden COS's unique id, written after the battle byte
	// when RideState is 1 (round 795, READ s:0x4e5c04..0x4e5c86, c:0x9dde69
	// ..0x9ddeba: the u32 follows the battle byte, not the ride byte).
	MountUID      uint32
	TeleportState byte
	InteractMode  byte
	TradeRank     byte
	GuildName     string
	// GuildID and Nickname are the guild block's first two fields (round 814,
	// READ s:0x4e5d3b..0x4e5eb3 / c:0x9ddfbe..0x9de08c): the guild's id (0
	// for none) and the member's grant name, which the client keeps at
	// CICUser+0x7c8 and shows as `[Guild * Nickname]`
	// (docs/protocol/guild_plate.md). The block's three u32 are the guild's
	// crest revision (round 824: CrestRev; the client's GlobalDataManager::
	// FUN_009ddc40 hands it to the crest cache 0x9a4780), the union id and
	// the union's crest revision; then FUN_005cffe0's byte and the fortress
	// role. The union fields, the byte and the role are written 0: OpenSRO
	// has no unions or fortress roles (OPEN).
	GuildID  uint32
	Nickname string
	CrestRev uint32
	// JobState is the job state the slot-8 suit gives; the guild block is
	// written only for JobStateNone. 0, the zero value, is no job state the
	// engine has and is written as JobStateNone (round 737's review).
	JobState byte
	Timer    byte
	Team     byte
}

// Append appends r's bytes in wire order. It refuses what the reader could
// not take back: an inventory size of 0, a ride state of 1 with no ridden
// object's id, an interact mode of 4 (the stall block is not modelled), more
// than 255 items.
func Append(out []byte, r Record) ([]byte, error) {
	if r.InventorySize == 0 || r.AvatarSize == 0 {
		return out, fmt.Errorf("pcspawn: a storage size of 0 drops the count byte the client reads")
	}
	if len(r.Items) > 255 {
		return out, fmt.Errorf("pcspawn: %d items", len(r.Items))
	}
	if len(r.Avatars) > int(r.AvatarSize) {
		return out, fmt.Errorf("pcspawn: %d avatars in a storage of %d", len(r.Avatars), r.AvatarSize)
	}
	if r.RideState == 1 && r.MountUID == 0 {
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
	out = AppendAvatarBlock(out, r.AvatarSize, r.Avatars)
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
	if r.HasDest {
		// 0x48be00's destination branch: the 0x48bad0 serialiser's region
		// and i16 x, y, z (the client's 0x8a5640(.., 1) reads them).
		out = append(out, 1, r.RunFlag)
		out = binary.LittleEndian.AppendUint16(out, r.DestRegion)
		if r.DestRegion&0x8000 != 0 {
			for _, v := range [3]int32{r.DungeonX, r.DungeonY, r.DungeonZ} {
				out = binary.LittleEndian.AppendUint32(out, uint32(v))
			}
		} else {
			for _, v := range [3]int16{r.DestX, r.DestY, r.DestZ} {
				out = binary.LittleEndian.AppendUint16(out, uint16(v))
			}
		}
	} else {
		angle := r.Angle
		if r.MoveCommand != 0 {
			angle = r.MoveAngle
		}
		out = append(out, 0, r.RunFlag, r.MoveCommand)
		out = binary.LittleEndian.AppendUint16(out, angle)
	}
	out = append(out, r.Life, r.Stance1, r.Motion, r.BodyMode)
	out = appendF32(out, r.Walk)
	out = appendF32(out, r.Run)
	out = appendF32(out, r.Param140)
	out = append(out, 0)
	// CGObjPC::vslot_293 0x4e5b00 mode 2.
	out = appendString(out, r.Name)
	out = append(out, r.JobType, r.JobLevel, r.PVPState, r.RideState, r.BattleState)
	if r.RideState == 1 {
		out = binary.LittleEndian.AppendUint32(out, r.MountUID)
	}
	out = append(out, r.TeleportState, r.InteractMode, r.TradeRank)
	out = appendString(out, r.GuildName)
	if r.JobState == JobStateNone || r.JobState == 0 {
		// The guild block (0x4e5d3b..0x4e5eb3): guild id, member nickname,
		// three u32, FUN_005cffe0's byte, the fortress role (round 814: the
		// id and the grant name; the rest 0, OPEN).
		out = binary.LittleEndian.AppendUint32(out, r.GuildID)
		out = appendString(out, r.Nickname)
		out = binary.LittleEndian.AppendUint32(out, r.CrestRev)
		out = binary.LittleEndian.AppendUint32(out, 0)
		out = binary.LittleEndian.AppendUint32(out, 0)
		out = append(out, 0, 0)
	}
	out = append(out, r.Timer, r.Team)
	return out, nil
}

// AppendAvatarBlock appends the record's avatar block (READ s:0x4ba720 mode
// 2, the client's c:0x9de3e2): u8 size, u8 count, count x (u32 RefItemID, u8
// plus). Every item is written with its plus: only 3/1/13 and 3/1/14 belong
// here, and the client reads the plus for exactly those.
func AppendAvatarBlock(out []byte, size uint8, items []Item) []byte {
	out = append(out, size, byte(len(items)))
	for _, it := range items {
		out = binary.LittleEndian.AppendUint32(out, it.RefItemID)
		out = append(out, it.Plus)
	}
	return out
}

// ReadAvatarBlock reads one avatar block, returning the bytes after it.
func ReadAvatarBlock(b []byte) (uint8, []Item, []byte, error) {
	r := &reader{b: b}
	size, items := r.avatarBlock()
	return size, items, r.b, r.err
}

func (r *reader) avatarBlock() (uint8, []Item) {
	size := r.u8()
	n := int(r.u8())
	var items []Item
	for i := 0; i < n && r.err == nil; i++ {
		// OpenSRO writes only 3/1/13 and 3/1/14 here, each read with its
		// plus as the client reads them (round 789).
		items = append(items, Item{RefItemID: r.u32(), Plus: r.u8(), HasPlus: true})
	}
	return size, items
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
// bytes after it. The forms OpenSRO never writes -- a mask, buffs, a ride, a
// stall -- are refused.
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
	d.AvatarSize, d.Avatars = r.avatarBlock()
	if r.u8() != 0 && r.err == nil {
		return d, nil, fmt.Errorf("pcspawn: a mask is not OpenSRO's")
	}
	d.UID = r.u32()
	d.Region = r.u16()
	d.X, d.Y, d.Z = r.f32(), r.f32(), r.f32()
	d.Angle = r.u16()
	d.HasDest = r.u8() != 0
	d.RunFlag = r.u8()
	if d.HasDest {
		d.DestRegion = r.u16()
		if d.DestRegion&0x8000 != 0 {
			d.DungeonX, d.DungeonY, d.DungeonZ = int32(r.u32()), int32(r.u32()), int32(r.u32())
		} else {
			d.DestX, d.DestY, d.DestZ = int16(r.u16()), int16(r.u16()), int16(r.u16())
		}
	} else {
		d.MoveCommand = r.u8()
		a := r.u16()
		if d.MoveCommand != 0 {
			d.MoveAngle = a
		} else if a != d.Angle && r.err == nil {
			return d, nil, fmt.Errorf("pcspawn: mover angle %d, position angle %d", a, d.Angle)
		}
	}
	d.Life, d.Stance1, d.Motion, d.BodyMode = r.u8(), r.u8(), r.u8(), r.u8()
	d.Walk, d.Run, d.Param140 = r.f32(), r.f32(), r.f32()
	if r.u8() != 0 && r.err == nil {
		return d, nil, fmt.Errorf("pcspawn: buffs are not OpenSRO's")
	}
	d.Name = r.str()
	d.JobType, d.JobLevel, d.PVPState, d.RideState, d.BattleState = r.u8(), r.u8(), r.u8(), r.u8(), r.u8()
	if d.RideState == 1 {
		d.MountUID = r.u32()
	}
	d.TeleportState, d.InteractMode, d.TradeRank = r.u8(), r.u8(), r.u8()
	d.GuildName = r.str()
	d.JobState = JobStateNone
	if types != nil {
		d.JobState = types.JobState(d.Items)
	}
	if d.JobState == JobStateNone {
		d.GuildID = r.u32()
		d.Nickname = r.str()
		d.CrestRev = r.u32()
		if r.u32() != 0 || r.u32() != 0 || r.u8() != 0 || r.u8() != 0 {
			if r.err == nil {
				return d, nil, fmt.Errorf("pcspawn: unions and fortress roles are not OpenSRO's")
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
