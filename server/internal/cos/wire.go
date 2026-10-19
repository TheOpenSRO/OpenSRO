package cos

import (
	"encoding/binary"
	"errors"
	"math"
)

// The retail COS messages (round 795; READ from both binaries, the tables
// in docs/protocol/pets.md, "Round 795"). Every integer little-endian; a
// string is a u16 length and its bytes.
const (
	OpCOSData       uint16 = 0x30C8 // the owner's COS data (server -> owner)
	OpCOSUpdate     uint16 = 0x30C9 // a COS's data changed (u32 uid, u8 type, ...)
	OpCOSOwnerState uint16 = 0x30CA // the owner's job / PvP state on its COS (area)
	OpItemState     uint16 = 0x3040 // one inventory item's fields changed (owner)
	OpCOSLevelUp    uint16 = 0x3054 // the level-up effect (u32 uid; area)
	OpCOSCommand    uint16 = 0x70C5 // client: u32 uid, u8 command, ...
	OpCOSCommandAck uint16 = 0xB0C5
	OpCOSTerminate  uint16 = 0x70C6 // client: u32 uid (rides and transports)
	OpCOSTermAck    uint16 = 0xB0C6
	OpCOSRide       uint16 = 0x70CB // client: u8 1 mount / 0 dismount, u32 uid
	OpCOSRideAck    uint16 = 0xB0CB // u8 1, u32 rider, u8 flag, u32 COS (area) | u8 2, u16 code
	OpCOSUnsummon   uint16 = 0x7116 // client: u32 uid (pets)
	OpCOSUnsumAck   uint16 = 0xB116
	OpCOSName       uint16 = 0x7117 // client: u32 uid, string name
	OpCOSNameAck    uint16 = 0xB117
	OpCOSSetting    uint16 = 0x7420 // client: u32 uid, u8 1 AI | 2 pickup, u32 value
	OpCOSSettingAck uint16 = 0xB420
)

// 0x30C9's types (c:FUN_008aa340, READ).
const (
	UpdateRemoved   = 1 // no payload: the COS left its owner
	UpdateInventory = 2 // u8 capacity, u8 n, n x (u8 slot, item record)
	UpdateExp       = 3 // i64 delta, u32 source uid
	UpdateHGP       = 4 // u16
	UpdateName      = 5 // string
	UpdateRef       = 7 // u32 new RefObjID (a growth pet's level-up row)
)

// The 0x70C5 commands (c:FUN_007a0980, c:FUN_009ebd10, READ).
const (
	CommandMove   = 1 // the destination body of 0x7021
	CommandAttack = 2 // u32 target uid
	CommandPick   = 8 // u32 item uid (the ability pet's own pick, s:CAIState_PICKITEM)
	CommandFollow = 9
)

// SpawnRecord is a CICCos spawn record, written as the client's CICCos slot
// 25 (c:0x9c60b0) reads it.
type SpawnRecord struct {
	RefID   uint32
	TypeID4 int
	UID     uint32
	Region  uint16
	X, Y, Z float32
	Angle   uint16
	// The mover: a COS walking to a point carries its destination (region
	// and three i16, region-local), else the angle again.
	HasDest             bool
	Running             bool
	DestRegion          uint16
	DestX, DestY, DestZ int16
	Life, Motion        byte
	Walk, Run           float32
	Name                string // a pet's name (TypeID4 3, 4)
	OwnerName           string // TypeID4 2..6
	OwnerJob            byte   // TypeID4 2..5; 4 is none
	OwnerPvP            byte   // TypeID4 2, 3, 5
	GuildID             uint32 // TypeID4 5
	OwnerUID            uint32 // every kind but the ride
}

func appendF32(out []byte, v float32) []byte {
	return binary.LittleEndian.AppendUint32(out, math.Float32bits(v))
}

func appendString(out []byte, s string) []byte {
	out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
}

// AppendSpawnRecord appends r in wire order:
//
//	u32 RefObjID                         FUN_008a6bd0
//	u32 uid, u16 region, f32 x y z, u16 angle    FUN_009c3a70
//	mover: u8 has-dest, u8 run flag, then u16 region + i16 x y z, or u8 0 + u16 angle
//	u8 life, u8 0, u8 motion, u8 0      0x9d1300
//	f32 walk, f32 run, f32 100, u8 0 buffs
//	u8 flags 0                           CICCos::vslot_034 (no NPC name or interactions)
//	[TypeID4 3, 4] string name
//	[2..6] string owner name   [2..5] u8 owner job   [2, 3, 5] u8 owner PvP
//	[5] u32 guild id           [not 1] u32 owner uid
func AppendSpawnRecord(out []byte, r SpawnRecord) []byte {
	out = binary.LittleEndian.AppendUint32(out, r.RefID)
	out = binary.LittleEndian.AppendUint32(out, r.UID)
	out = binary.LittleEndian.AppendUint16(out, r.Region)
	out = appendF32(out, r.X)
	out = appendF32(out, r.Y)
	out = appendF32(out, r.Z)
	out = binary.LittleEndian.AppendUint16(out, r.Angle)
	run := byte(0)
	if r.Running {
		run = 1
	}
	if r.HasDest {
		out = append(out, 1, run)
		out = binary.LittleEndian.AppendUint16(out, r.DestRegion)
		for _, v := range [3]int16{r.DestX, r.DestY, r.DestZ} {
			out = binary.LittleEndian.AppendUint16(out, uint16(v))
		}
	} else {
		out = append(out, 0, run, 0)
		out = binary.LittleEndian.AppendUint16(out, r.Angle)
	}
	out = append(out, r.Life, 0, r.Motion, 0)
	out = appendF32(out, r.Walk)
	out = appendF32(out, r.Run)
	out = appendF32(out, 100)
	out = append(out, 0) // buffs
	out = append(out, 0) // flags
	k := r.TypeID4
	if k == KindGrowth || k == KindAbility {
		out = appendString(out, r.Name)
	}
	if k >= KindTransport && k <= 6 {
		out = appendString(out, r.OwnerName)
	}
	if k >= KindTransport && k <= KindSoldier {
		out = append(out, r.OwnerJob)
	}
	if k == KindTransport || k == KindGrowth || k == KindSoldier {
		out = append(out, r.OwnerPvP)
	}
	if k == KindSoldier {
		out = binary.LittleEndian.AppendUint32(out, r.GuildID)
	}
	if k != KindRide {
		out = binary.LittleEndian.AppendUint32(out, r.OwnerUID)
	}
	return out
}

// Data is the owner's 0x30C8 (s:GObjPC::FUN_004fbae0 -> slot 294 mode 1;
// c:COSDataMgr::FUN_009a1900).
type Data struct {
	UID       uint32
	RefID     uint32
	TypeID4   int
	HP, MP    uint32
	Exp       uint64 // growth
	Level     uint8  // growth
	HGP       uint16 // growth
	PetOption uint32 // pets
	Name      string // pets
	InvSize   uint8
	// Items is the bag, each u8 slot then its item record (the caller's
	// AppendItemRecord); written only when InvSize is not 0.
	Items    []DataItem
	OwnerUID uint32 // pets and transports
	// ItemSlot is the summon item's inventory slot + 13 (pets).
	ItemSlot uint8
}

// DataItem is one bag slot of a 0x30C8 or a 0x30C9 type 2.
type DataItem struct {
	Slot   uint8
	Record []byte
}

// AppendData appends d's payload.
func AppendData(out []byte, d Data) []byte {
	out = binary.LittleEndian.AppendUint32(out, d.UID)
	out = binary.LittleEndian.AppendUint32(out, d.RefID)
	out = binary.LittleEndian.AppendUint32(out, d.HP)
	out = binary.LittleEndian.AppendUint32(out, d.MP)
	if d.TypeID4 == KindGrowth {
		out = binary.LittleEndian.AppendUint64(out, d.Exp)
		out = append(out, d.Level)
		out = binary.LittleEndian.AppendUint16(out, d.HGP)
	}
	if IsPetKind(d.TypeID4) {
		out = binary.LittleEndian.AppendUint32(out, d.PetOption)
		out = appendString(out, d.Name)
	}
	out = appendBag(out, d.InvSize, d.Items)
	if IsPetKind(d.TypeID4) || d.TypeID4 == KindTransport {
		out = binary.LittleEndian.AppendUint32(out, d.OwnerUID)
	}
	if IsPetKind(d.TypeID4) {
		out = append(out, d.ItemSlot)
	}
	return out
}

func appendBag(out []byte, size uint8, items []DataItem) []byte {
	out = append(out, size)
	if size == 0 {
		return out
	}
	out = append(out, byte(len(items)))
	for _, it := range items {
		out = append(out, it.Slot)
		out = append(out, it.Record...)
	}
	return out
}

// UpdateHead is 0x30C9's u32 uid and u8 type.
func UpdateHead(uid uint32, kind byte) []byte {
	return append(binary.LittleEndian.AppendUint32(nil, uid), kind)
}

// RemovedUpdate is 0x30C9 type 1.
func RemovedUpdate(uid uint32) []byte { return UpdateHead(uid, UpdateRemoved) }

// InventoryUpdate is 0x30C9 type 2.
func InventoryUpdate(uid uint32, size uint8, items []DataItem) []byte {
	return appendBag(UpdateHead(uid, UpdateInventory), size, items)
}

// ExpUpdate is 0x30C9 type 3: the delta and the kill's source uid.
func ExpUpdate(uid uint32, delta int64, source uint32) []byte {
	out := binary.LittleEndian.AppendUint64(UpdateHead(uid, UpdateExp), uint64(delta))
	return binary.LittleEndian.AppendUint32(out, source)
}

// HGPUpdate is 0x30C9 type 4.
func HGPUpdate(uid uint32, hgp int) []byte {
	return binary.LittleEndian.AppendUint16(UpdateHead(uid, UpdateHGP), uint16(hgp))
}

// NameUpdate is 0x30C9 type 5.
func NameUpdate(uid uint32, name string) []byte {
	return appendString(UpdateHead(uid, UpdateName), name)
}

// RefUpdate is 0x30C9 type 7.
func RefUpdate(uid, ref uint32) []byte {
	return binary.LittleEndian.AppendUint32(UpdateHead(uid, UpdateRef), ref)
}

// OwnerState is 0x30CA (s:GObjPC::FUN_004d1ea0): u32 uid, u8 mask, then
// the owner's job state (bit 0) and PvP state (bit 1).
func OwnerState(uid uint32, job, pvp byte) []byte {
	out := binary.LittleEndian.AppendUint32(nil, uid)
	return append(out, 3, job, pvp)
}

// The 0x3040 masks the COS uses (s:GObjPC::FUN_004efa00, READ).
const (
	ItemFieldCOSState = 0x40
	ItemFieldRentSecs = 0x80
)

// ItemStateField is 0x3040 {u8 slot + 13, u8 0x40, u8 state}.
func ItemStateField(slot int, state uint8) []byte {
	return []byte{byte(slot + 13), ItemFieldCOSState, state}
}

// ItemRentField is 0x3040 {u8 slot + 13, u8 0x80, u32 seconds left}.
func ItemRentField(slot int, secs uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{byte(slot + 13), ItemFieldRentSecs}, secs)
}

// ItemTail is a summon item's per-instance part of the item record
// (CGItemCOSSummoner::vslot_294 s:0x492d40; c:SOItem::FUN_008be4f0 after
// the RefItemID for a 3/2/1 item): u8 state; past state 1 the COS's u32
// RefObjID, then for a pet ref its name, an ability pet's u32 rent seconds,
// and u8 0 timed jobs (OURS: none modelled).
type ItemTail struct {
	State    uint8
	RefID    uint32
	TypeID4  int
	Name     string
	RentSecs uint32
}

// AppendItemTail appends t.
func AppendItemTail(out []byte, t ItemTail) []byte {
	out = append(out, t.State)
	if t.State == ItemStateNone {
		return out
	}
	out = binary.LittleEndian.AppendUint32(out, t.RefID)
	if IsPetKind(t.TypeID4) {
		out = appendString(out, t.Name)
		if t.TypeID4 == KindAbility {
			out = binary.LittleEndian.AppendUint32(out, t.RentSecs)
		}
		out = append(out, 0)
	}
	return out
}

// ReadItemTail reads AppendItemTail's bytes; kindOf answers a COS ref's
// TypeID4 (the client asks its characterdata, c:FUN_0069a420).
func ReadItemTail(b []byte, kindOf func(ref uint32) int) (ItemTail, []byte, error) {
	var t ItemTail
	if len(b) < 1 {
		return t, nil, errors.New("cos item: short")
	}
	t.State, b = b[0], b[1:]
	if t.State == ItemStateNone {
		return t, b, nil
	}
	if len(b) < 4 {
		return t, nil, errors.New("cos item: short ref")
	}
	t.RefID, b = binary.LittleEndian.Uint32(b), b[4:]
	t.TypeID4 = kindOf(t.RefID)
	if !IsPetKind(t.TypeID4) {
		return t, b, nil
	}
	if len(b) < 2 || len(b) < 2+int(binary.LittleEndian.Uint16(b)) {
		return t, nil, errors.New("cos item: short name")
	}
	n := int(binary.LittleEndian.Uint16(b))
	t.Name, b = string(b[2:2+n]), b[2+n:]
	if t.TypeID4 == KindAbility {
		if len(b) < 4 {
			return t, nil, errors.New("cos item: short rent")
		}
		t.RentSecs, b = binary.LittleEndian.Uint32(b), b[4:]
	}
	if len(b) < 1 {
		return t, nil, errors.New("cos item: short job count")
	}
	jobs := int(b[0])
	b = b[1:]
	for i := 0; i < jobs; i++ {
		if len(b) < 9 {
			return t, nil, errors.New("cos item: short job")
		}
		cat := b[0]
		b = b[9:]
		if cat == 5 {
			if len(b) < 5 {
				return t, nil, errors.New("cos item: short job data")
			}
			b = b[5:]
		}
	}
	return t, b, nil
}

// RideAck is the 0xB0CB success, broadcast: u8 1, u32 rider, u8 flag, u32
// COS (s:FUN_004ec640 / FUN_004ec750; c:FUN_008a7720).
func RideAck(rider uint32, mounted bool, cosUID uint32) []byte {
	out := binary.LittleEndian.AppendUint32([]byte{1}, rider)
	flag := byte(0)
	if mounted {
		flag = 1
	}
	out = append(out, flag)
	return binary.LittleEndian.AppendUint32(out, cosUID)
}

// Refusal is the two-field failure every COS reply uses (Msg_SendTwoFieldReply
// s:0x4e7250): u8 2, u16 code.
func Refusal(code uint16) []byte {
	return binary.LittleEndian.AppendUint16([]byte{2}, code)
}
