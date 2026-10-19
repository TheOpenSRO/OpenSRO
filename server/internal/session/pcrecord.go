package session

import (
	"context"
	"log"
	"reflect"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/avatar"
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

// pcAvatarSize is the avatar storage's size (READ s:0x4e1340: created with
// size 5; round 789). Its items follow it (lookOf, avatarSpawnItems).
const pcAvatarSize = avatar.Slots

// PlayerWalkSpeed is a player character's walk speed, param 23: characterdata
// column 46, 16 on all 52 creatable bodies (MEASURED, round 737's RE; column
// 47's 50 is PlayerRunSpeed).
const PlayerWalkSpeed = 16

// pcParam140 is param 140 (READ: GObjPC_InitStats 0x4e3200 sets it from the
// double at 0xb45e10, 100.0).
const pcParam140 = 100

// runFlagOf is the record's run flag for characterID: 0 while the action
// window's Walk is in effect (round 781, motionTracker.walkingMode), else 1.
func runFlagOf(characterID int64) byte {
	if motions.walkingMode(characterID) {
		return 0
	}
	return 1
}

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
	} else {
		spawnItemRefs.Store(&itemLookupBox{items})
	}
	// The cached looks were read through the old table: the epoch moves
	// after the new table is in, so a read under the new epoch reads it.
	lookEpoch.Add(1)
	looks.Range(func(k, _ any) bool { looks.Delete(k); return true })
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

// itemHasPlus reports whether the record carries a plus byte after itemID:
// only for TypeID 3/1 (READ: the server's CInstanceItem::vslot_010 0x42e230
// mode 2 writes it only then, and the client reads it only when the type word
// passes (w&2)==0 && (w&0x1c)==0xc && (w&0x60)==0x20, 0x9de370..0x9de385).
// Equip slot 7 also holds ammunition, TypeID 3/3/4, which carries none
// (round 737's review, F1). An item the table does not know is taken as
// equipment, as OpenSRO's client takes it (UserSpawnNet.Types.has_plus).
func itemHasPlus(ctx context.Context, itemID int64) bool {
	box := spawnItemRefs.Load()
	if box == nil {
		return true
	}
	it, err := box.GetItem(ctx, itemID)
	if err != nil || it == nil {
		return true
	}
	return it.TypeID1 == 3 && it.TypeID2 == 1
}

// look is the part of a spawn record that only an equipment change or a new
// character changes: the body, the worn items and the job state their slot-8
// suit gives.
type look struct {
	ref      uint32
	scale    uint8
	items    []pcspawn.Item
	jobState byte
	// avatars is the avatar block (round 789): the worn avatars and devil's
	// spirit in storage order, each with its plus.
	avatars []pcspawn.Item
}

// lookEntry is a cached look, the stores it was read from, and the
// character's look generation and the item-table epoch when the read began.
type lookEntry struct {
	eq    equipment.Store
	chars character.Store
	look  look
	gen   uint64
	epoch uint64
}

// looks caches each character's look (round 737's review, F8): an arrival in
// a crowd builds a record per player in view, and each read two stores --
// two queries each with the SQL stores. Invalidated by every change of what
// is worn (broadcastWorn / broadcastUnworn, the equip, unequip and the GM's
// worn-plus paths), by a world entry and by a leave; an entry read from other
// stores than the caller's is read again.
var looks sync.Map // int64 -> lookEntry

// lookGens numbers each character's look invalidations, and lookEpoch the
// item table's (SetSpawnItemRefs): a read that began before an invalidation
// may finish after it and store what it read, so an entry is served only
// while both numbers are still the ones it was read under (round 737's
// verification, N2). A character's counter is kept after it leaves -- a
// counter dropped and made again would start at 0, and an entry stored by a
// read begun before the drop could then match it.
var (
	lookGens  sync.Map // int64 -> *atomic.Uint64
	lookEpoch atomic.Uint64
)

func lookGen(characterID int64) *atomic.Uint64 {
	if g, ok := lookGens.Load(characterID); ok {
		return g.(*atomic.Uint64)
	}
	g, _ := lookGens.LoadOrStore(characterID, new(atomic.Uint64))
	return g.(*atomic.Uint64)
}

// invalidateLook drops characterID's cached look, and any a read already
// under way would store.
func invalidateLook(characterID int64) {
	lookGen(characterID).Add(1)
	looks.Delete(characterID)
}

// sameStore reports whether a and b are the same store value, and false for
// a store type == cannot compare (a struct holding a map, say): such a store
// is never served from the cache.
func sameStore(a, b any) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	ta := reflect.TypeOf(a)
	if ta != reflect.TypeOf(b) || !ta.Comparable() {
		return false
	}
	return a == b
}

// lookOf is characterID's look, from the cache or read now.
func lookOf(ctx context.Context, d viewDeps, characterID int64) look {
	gen, epoch := lookGen(characterID).Load(), lookEpoch.Load()
	if v, ok := looks.Load(characterID); ok {
		if le := v.(lookEntry); le.gen == gen && le.epoch == epoch && sameStore(le.eq, d.eq) && sameStore(le.chars, d.chars) {
			return le.look
		}
	}
	var lk look
	if d.chars != nil {
		_, lk.ref, lk.scale = bodyOf(ctx, d.chars, characterID)
	} else {
		lk.ref, lk.scale = uint32(character.LegacyModelFor(character.DefaultGender)), character.DefaultScale
	}
	// Equip slots 0..8, ascending (CGPCInventoryOP slot 29); the
	// accessories (9..12) are not in the record.
	worn := equippedItems(ctx, d.eq, characterID)
	sort.Slice(worn, func(i, j int) bool { return worn[i].Slot < worn[j].Slot })
	var slot8 int64
	for _, it := range worn {
		if it.Slot < 0 || equipment.Slot(it.Slot) > equipment.SlotJobSuit || it.ItemID <= 0 {
			continue
		}
		item := pcspawn.Item{RefItemID: uint32(it.ItemID)}
		if itemHasPlus(ctx, it.ItemID) {
			item.Plus, item.HasPlus = it.Plus, true
		}
		lk.items = append(lk.items, item)
		if equipment.Slot(it.Slot) == equipment.SlotJobSuit {
			slot8 = it.ItemID
		}
	}
	lk.jobState = jobStateOf(ctx, slot8)
	for _, a := range avatarSpawnItems(ctx, characterID) {
		lk.avatars = append(lk.avatars, pcspawn.Item{RefItemID: a.ref, Plus: a.plus, HasPlus: true})
	}
	if lookGen(characterID).Load() == gen && lookEpoch.Load() == epoch {
		looks.Store(characterID, lookEntry{eq: d.eq, chars: d.chars, look: lk, gen: gen, epoch: epoch})
	}
	return lk
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
		RunFlag:       runFlagOf(e.CharacterID), // 1 the mover's constructor default (INFERRED); 0 after a Walk (round 781)
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
	// A rider (round 795): ride state 1, its COS's uid after the battle
	// byte, and the COS's speeds (s:0x4aa410).
	if o := riderMount(e.CharacterID); o != nil {
		r.RideState, r.MountUID = 1, o.uid
		r.Walk, r.Run = float32(o.row.WalkSpeed), float32(o.row.RunSpeed)
	}
	// A character on a leg (round 749): the record carries the mover's
	// destination, or the heading run's command and angle, and the motion
	// state the accepted move set -- RUN, 2 + (+0x155 != 0) with the run flag
	// 1 (READ, 0x4b11b6) -- so the viewer's client walks it on.
	if m := e.Move; m != nil {
		r.Motion = MotionRun
		if r.RunFlag == 0 {
			r.Motion = MotionWalk // 2 + (+0x155 != 0) with the flag cleared (round 781)
		}
		if m.Heading {
			r.MoveCommand, r.MoveAngle = m.Command, m.WireAngle
		} else {
			region, lx, lz := regionLocalOf(e.Zone, m.Dest)
			r.HasDest, r.DestRegion = true, region
			if region&proto.MovementRegionWorldBit != 0 {
				// A dungeon's (round 773): three i32 of dungeon space.
				r.DungeonX, r.DungeonY, r.DungeonZ = int32(lx), int32(m.Dest.Y), int32(lz)
			} else {
				r.DestX, r.DestY, r.DestZ = int16(lx), int16(m.Dest.Y), int16(lz)
			}
		}
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
	// Round 786: the arrival's protection is body mode 2 in the record, the
	// live chardata[3] the engine's record writer reads (0x4a9b70): a player
	// who comes into view during it is spawned untouchable.
	if protectedNow(e.CharacterID, now) {
		r.BodyMode = bodyModeInvincible
	}
	// A scroll's cast (round 779, scroll.go): field 26, the teleport state
	// (slot 72, chardata +0x10), its value while it works.
	r.TeleportState = scrollStateOf(e.CharacterID)
	lk := lookOf(ctx, d, e.CharacterID)
	r.RefObjID, r.Scale, r.Items, r.JobState = lk.ref, lk.scale, lk.items, lk.jobState
	r.Avatars = lk.avatars
	// The frame's region and the local position in it (worldmap.FromWorld,
	// as teleport's reach and the party record do). A zone with no frame --
	// none OpenSRO serves -- sends region 0 and the frame coordinates (OURS).
	if _, ok := dungeonOf(e.Zone); ok {
		// A dungeon's rid and dungeon-space x, z (round 773).
		region, lx, lz := regionLocalOf(e.Zone, e.Pos)
		r.Region, r.X, r.Z = region, float32(lx), float32(lz)
	} else if fx, fy, ok := entityFrame(e.Zone); ok {
		rx, ry, lx, lz := worldmap.FromWorld(e.Pos.X, e.Pos.Z, fx, fy)
		r.Region = uint16(worldmap.RegionID(rx, ry))
		r.X, r.Z = float32(lx), float32(lz)
	} else {
		r.X, r.Z = float32(e.Pos.X), float32(e.Pos.Z)
	}
	out, err := pcspawn.Append(nil, r)
	if err != nil {
		// Unreachable with the values above; logged rather than sent short.
		log.Printf("session: spawn record of %q: %v", e.Name, err)
		return nil
	}
	return out
}
