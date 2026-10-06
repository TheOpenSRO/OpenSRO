package session

import (
	"context"
	"log"
	"sort"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// A player's spawn record as OpenSRO fills it (round 737; the layout is
// pcspawn's, READ from both binaries, docs/protocol/pc_spawn.md). The fields
// OpenSRO models carry their real values; the ones it does not are written
// as a plain character's, and say so.

// pcSpawnType is the byte after a 0x3015's record (the client's FUN_009c2180
// stores it at +0xf4). READ: the walk step's block crossing passes 4
// (0x485b36 turns the step's 0 into 4, handed to CMsgBlock slot 2 and on to
// FUN_00533f70); that the stack slot is that argument is INFERRED (round
// 737's RE). The value the world entry and a zone change pass is OPEN; 4 is
// sent for them too (OURS). OpenSRO's client does not read it.
const pcSpawnType byte = 4

// pcGroupChunkRetail is how many body bytes retail's 0x3019 carries (READ,
// round 737: the message buffer's capacity 0x1000 (0x471500 / 0x471580), less
// its 6-byte header and the 0x2209 {u32, u16} envelope to a player, less the
// 0x20 FUN_00430a20 keeps back -- 4096 - 12 - 32 = 4052).
const pcGroupChunkRetail = 4096 - 12 - 0x20

// pcInventorySize is the record's _CHAR.InventorySize: the bag OpenSRO gives
// a character nobody sized (inventory.DefaultBagSlots, OURS) plus the 13
// equipment slots the engine counts in it. The client reads it and drops it;
// it must not be 0 (pcspawn.Append).
const pcInventorySize = inventory.DefaultBagSlots + inventory.EquipSlotsInEngineSize

// pcAvatarSize is the avatar storage's size (INFERRED 5, the RE's reading of
// the five avatar slots); OpenSRO has no avatars, so no items follow.
const pcAvatarSize = 5

// PlayerWalkSpeed is a player character's walk speed, param 23: characterdata
// column 46, 16 on all 52 creatable bodies (MEASURED, round 737's RE; column
// 47's 50 is PlayerRunSpeed).
const PlayerWalkSpeed = 16

// pcParam140 is param 140 (READ: GObjPC_InitStats 0x4e3200 sets it from the
// double at 0xb45e10, 100.0).
const pcParam140 = 100

// bodyModeBerserk is the body mode a berserk character's record carries: the
// value OpenSRO's 0x30bf kind 4 broadcasts (round 651, broadcastBodyMode,
// READ from the client's handler).
const bodyModeBerserk byte = 1

// spawnItemRefs is the item table the record asks of the slot-8 item's type
// (the job state) and of an item's plus byte. nil (tests, a server with no
// item data): every worn item is equipment and none is a job suit.
var spawnItemRefs atomic.Pointer[itemLookupBox]

type itemLookupBox struct{ ItemLookup }

// SetSpawnItemRefs installs the item table the spawn record reads (cmd/server).
func SetSpawnItemRefs(items ItemLookup) {
	if items == nil {
		spawnItemRefs.Store(nil)
		return
	}
	spawnItemRefs.Store(&itemLookupBox{items})
}

// jobStateOf is the job state the client will take from the worn items: the
// slot-8 item's TypeID4 when it is a job suit (TypeID 3/1/7/1..3), else
// pcspawn.JobStateNone (READ: the server's 0x4e124e and the client's
// 0x9db8b0 agree).
func jobStateOf(ctx context.Context, slot8 int64) byte {
	box := spawnItemRefs.Load()
	if slot8 == 0 || box == nil {
		return pcspawn.JobStateNone
	}
	it, err := box.GetItem(ctx, slot8)
	if err != nil || it == nil {
		return pcspawn.JobStateNone
	}
	if it.TypeID1 == 3 && it.TypeID2 == 1 && it.TypeID3 == 7 && it.TypeID4 >= 1 && it.TypeID4 <= 3 {
		return byte(it.TypeID4)
	}
	return pcspawn.JobStateNone
}

// playerRecord is e's spawn record now: e as the hub has it (position,
// heading, life), its body and worn items from the stores, its motion and
// body mode and run speed from their books.
func playerRecord(d viewDeps, e world.Entity, now time.Time) []byte {
	ctx := d.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	r := pcspawn.Record{
		HwanLevel: 0, PVPCape: 0, AutoInvestExp: 0, // OURS: none modelled
		InventorySize: pcInventorySize,
		AvatarSize:    pcAvatarSize,
		UID:           uint32(e.CharacterID), // the low 32 bits of the character id, as every retail message OpenSRO sends (round 710)
		Y:             float32(e.Pos.Y),
		Angle:         proto.EncodeMovementAngle(world.WireAngle(e.Heading)),
		RunFlag:       1, // INFERRED: the mover's constructor default
		Life:          byte(e.Life),
		Motion:        motions.state(e.CharacterID, now),
		Walk:          PlayerWalkSpeed,
		Run:           float32(buffBooks.RunSpeed(e.CharacterID)),
		Param140:      pcParam140,
		Name:          e.Name,
		Team:          pcspawn.TeamNone,
	}
	if r.Life == 0 {
		r.Life = byte(world.LifeAlive)
	}
	// A character sitting down (the 1.5 s CHANGEMOTION that lands on SIT) is
	// written as SIT, as the arrival list's Seated counted it since round
	// 607: the sit's own broadcast went out before this viewer held the body,
	// and nothing else would tell it (OURS: the engine writes chardata[2] as
	// it is, 0x12, and what its client does with a 0x12 spawn was not read).
	if motions.sittingOrSittingDown(e.CharacterID, now) {
		r.Motion = MotionSit
	}
	if d.zerk != nil && d.zerk.Active(e.CharacterID) {
		r.BodyMode = bodyModeBerserk
	}
	if d.chars != nil {
		_, r.RefObjID, r.Scale = bodyOf(ctx, d.chars, e.CharacterID)
	} else {
		r.RefObjID, r.Scale = uint32(character.LegacyModelFor(character.DefaultGender)), character.DefaultScale
	}
	// The frame's region and the local position in it (worldmap.FromWorld,
	// as teleport's reach and the party record do). A zone with no frame --
	// none OpenSRO serves -- sends region 0 and the frame coordinates (OURS).
	if fx, fy, ok := entityFrame(e.Zone); ok {
		rx, ry, lx, lz := worldmap.FromWorld(e.Pos.X, e.Pos.Z, fx, fy)
		r.Region = uint16(worldmap.RegionID(rx, ry))
		r.X, r.Z = float32(lx), float32(lz)
	} else {
		r.X, r.Z = float32(e.Pos.X), float32(e.Pos.Z)
	}
	// Equip slots 0..8, ascending (CGPCInventoryOP slot 29): every item
	// there is equipment (TypeID 3/1, the equip rule), so each carries its
	// plus; the accessories (9..12) are not in the record.
	worn := equippedItems(ctx, d.eq, e.CharacterID)
	sort.Slice(worn, func(i, j int) bool { return worn[i].Slot < worn[j].Slot })
	var slot8 int64
	for _, it := range worn {
		if it.Slot < 0 || equipment.Slot(it.Slot) > equipment.SlotJobSuit || it.ItemID <= 0 {
			continue
		}
		r.Items = append(r.Items, pcspawn.Item{RefItemID: uint32(it.ItemID), Plus: it.Plus, HasPlus: true})
		if equipment.Slot(it.Slot) == equipment.SlotJobSuit {
			slot8 = it.ItemID
		}
	}
	r.JobState = jobStateOf(ctx, slot8)
	out, err := pcspawn.Append(nil, r)
	if err != nil {
		// Unreachable with the values above; logged rather than sent short.
		log.Printf("session: spawn record of %q: %v", e.Name, err)
		return nil
	}
	return out
}
