package session

import (
	"context"
	"math"
	"math/rand"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Calling a COS out and putting it away (round 795; docs/protocol/pets.md,
// "Round 795": the checks in order, the messages in order). OpenSRO's client
// asks with its own use-item message (OpUseItem), so the reply is
// OpUseItemResult where retail's is 0xB04C; everything after it is retail's.
//
// Not modelled, and so not refused (OURS, disclosed): the quest block, the
// teleport state, the PvP cape change, the murderer state. A transport needs
// a trader's or thief's suit (0x1849, round 800) and is refused in the
// battle state (0x1878) and to a thief in a town (0x1895, round 801).

// The transport summon's own refusals (round 801, READ vslot_307).
const (
	cosErrSummonInBattle   = 0x1878 // COS_CAN_NOT_CREATE_BATTLE
	cosErrRobberCartInTown = 0x1895 // ROBBER_CANT_SUMMON_CART_IN_TOWN
)

// cosRefusal answers a use with the engine's code.
func cosRefusal(sess *gateway.Session, code uint16, text string) error {
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: text, Code: code}).Encode()})
}

// cosRefusalText is the line OpenSRO's server logs and an older client shows
// beside the code (the client draws the code's own text).
func cosRefusalText(code int) string {
	switch code {
	case cos.ErrHigherLevelRequired:
		return "a higher level is required to use this item"
	case cos.ErrPetTooHighLevel:
		return "the pet's level is higher than yours"
	case cos.ErrDuplicatePetType:
		return "a pet of that type is already summoned"
	case cos.ErrMultipleCOS:
		return "another vehicle is already summoned"
	case cos.ErrCannotActivateCart:
		return "a transport needs a trader's or thief's suit"
	case cos.ErrCOSNotSummonable:
		return "the pet cannot be summoned"
	case cos.ErrCOSDungeon:
		return "a vehicle cannot be summoned here"
	case cos.ErrRecallTooFar:
		return "the pet is too far away"
	case cos.ErrRecallRidden:
		return "the pet is being ridden"
	}
	return "that cannot be used"
}

// isCOSItem reports an item the COS runtime takes.
func isCOSItem(it *refdata.Item) bool {
	return it != nil && (cos.IsPetItem(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4) ||
		cos.IsRideScroll(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4))
}

// checkCanSummon is GObjPC::CheckCanSummonCOS (s:0x4fcef0, READ) by the
// row's TypeID4, for owner with level.
func checkCanSummon(owner int64, typeID4, level, rowLevel int) int {
	out := cosWorld.owned(owner)
	switch typeID4 {
	case cos.KindRide, cos.KindTransport:
		for _, o := range out {
			if o.ridden || o.kind == cos.KindRide || o.kind == cos.KindTransport {
				return cos.ErrMultipleCOS
			}
		}
		if typeID4 == cos.KindTransport {
			// The owner's job state must be 1 (trader) or 2 (thief): a hunter
			// or anyone out of a suit is refused (READ s:0x4fcef0; round 800,
			// jobsuit.go).
			if js := jobStateNow(context.Background(), owner); js != 1 && js != 2 {
				return cos.ErrCannotActivateCart
			}
		}
	case cos.KindGrowth, cos.KindAbility:
		if code := cos.CheckSummon(cos.SummonRequest{OwnerLevel: level, ItemRequiredLevel: rowLevel, HasOwner: true}); code != 0 {
			return code
		}
		// One per TID word: every growth row shares one, every ability row
		// another (MEASURED), so one growth and one ability pet at most.
		for _, o := range out {
			if o.kind == typeID4 {
				return cos.ErrDuplicatePetType
			}
		}
	}
	return 0
}

// useCOSItem is a pet item's or a ride scroll's use (UseItemHandler).
func useCOSItem(ctx context.Context, sess *gateway.Session, inv inventory.Store, characterID int64, it *refdata.Item,
	held inventory.Slot, have int) error {
	d := cosWorld.depsNow()
	if !d.enabled {
		return cosRefusal(sess, cos.ErrCannotBeUsed, "no COS table on this server")
	}
	owner, ok := cosOwnerEntity(characterID)
	if !ok || owner.Session != sess {
		return cosRefusal(sess, cos.ErrCannotBeUsed, "not in the world")
	}
	level := cosOwnerLevel(ctx, d.chars, characterID)
	now := time.Now()
	if cos.IsRideScroll(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4) {
		return useRideScroll(ctx, sess, d, inv, owner, level, it, held, have, now)
	}
	// CGItemCOSSummoner::CheckCanUse (s:0x493100): the floor of 5 first.
	if level < cos.MinOwnerLevel {
		return cosRefusal(sess, cos.ErrHigherLevelRequired, cosRefusalText(cos.ErrHigherLevelRequired))
	}
	if motions.sittingOrSittingDown(characterID, now) {
		return cosRefusal(sess, cos.ErrRideGeneric, "not while sitting")
	}
	inst := held.Instance()
	if inst.Durability <= 0 {
		// Never summoned: the row the item names (Desc128_1).
		row, ok := cosRowByCode(it.Desc1)
		if !ok {
			return cosRefusal(sess, cos.ErrRideGeneric, "the item names no COS")
		}
		if level < row.Level {
			return cosRefusal(sess, cos.ErrPetTooHighLevel, cosRefusalText(cos.ErrPetTooHighLevel))
		}
		if code := checkCanSummon(characterID, row.TypeID4, level, row.Level); code != 0 {
			return cosRefusal(sess, uint16(code), cosRefusalText(code))
		}
		rec := cos.Record{RefCharID: row.ID, HP: row.MaxHP, Level: row.Level, HGP: cos.HGPFull,
			State: cos.StateAlive | cos.StateSummoned, PetOption: cos.PetOption(row.TypeID4)}
		if row.TypeID4 == cos.KindAbility {
			rec.InvSize = cos.AbilityPetSlots
			rec.RentEnd = cos.RentEnd(now, int64(int32(it.Param1)))
		}
		id, err := d.store.Create(ctx, rec)
		if err != nil {
			d.logger.Warn("cos: creating a pet", "character", characterID, "err", err)
			return cosRefusal(sess, cos.ErrCannotBeUsed, "the pet could not be made")
		}
		rec.ID = id
		if err := inv.SetDurability(ctx, characterID, held.Index, int(id)); err != nil {
			d.logger.Warn("cos: linking a pet to its item", "character", characterID, "err", err)
		}
		if err := sendUseOK(sess, have, it.ID); err != nil {
			return err
		}
		// A new pet: the item's state goes first (FUN_004fb2c0, READ).
		sendItemState(sess, held.Index, cos.ItemStateSummoned)
		spawnCOS(owner, rec, row, it.ID, held.Index, cosSpawnTypeSummoned, now)
		return nil
	}
	rec, err := d.store.Get(ctx, int64(inst.Durability))
	if err != nil {
		return cosRefusal(sess, cos.ErrCOSNotSummonable, cosRefusalText(cos.ErrCOSNotSummonable))
	}
	if o := cosWorld.byRecord(rec.ID); o != nil {
		// Out: the use recalls it (CGObjPC::vslot_330 s:0x4e8fc0).
		cosWorld.mu.Lock()
		ridden, pos := o.ridden, o.at(now)
		cosWorld.mu.Unlock()
		if ridden {
			return cosRefusal(sess, cos.ErrRecallRidden, cosRefusalText(cos.ErrRecallRidden))
		}
		if cosDistance(pos, owner.Pos) >= cos.RecallRange {
			return cosRefusal(sess, cos.ErrRecallTooFar, cosRefusalText(cos.ErrRecallTooFar))
		}
		if err := sendUseOK(sess, have, it.ID); err != nil {
			return err
		}
		releaseCOS(ctx, o, releaseStore)
		return nil
	}
	if !rec.Alive() {
		return cosRefusal(sess, cos.ErrCOSNotSummonable, cosRefusalText(cos.ErrCOSNotSummonable))
	}
	if level < rec.Level {
		return cosRefusal(sess, cos.ErrPetTooHighLevel, cosRefusalText(cos.ErrPetTooHighLevel))
	}
	row, ok := cosRow(rec.RefCharID)
	if !ok {
		return cosRefusal(sess, cos.ErrRideGeneric, "the pet's row is not in the COS table")
	}
	if row.TypeID4 == cos.KindAbility && cos.RentSecondsLeft(rec.RentEnd, now) < 1 {
		return cosRefusal(sess, cos.ErrCOSNotSummonable, cosRefusalText(cos.ErrCOSNotSummonable))
	}
	if code := checkCanSummon(characterID, row.TypeID4, level, row.Level); code != 0 {
		return cosRefusal(sess, uint16(code), cosRefusalText(code))
	}
	rec.State |= cos.StateSummoned
	if err := d.store.Save(ctx, rec); err != nil {
		d.logger.Warn("cos: saving a summon", "cos", rec.ID, "err", err)
	}
	if err := sendUseOK(sess, have, it.ID); err != nil {
		return err
	}
	o := spawnCOS(owner, rec, row, it.ID, held.Index, cosSpawnTypeSummoned, now)
	// An existing pet: the item's state after its 0x30C8 (FUN_004fb490).
	_ = o
	sendItemState(sess, held.Index, cos.ItemStateSummoned)
	return nil
}

// sendUseOK is the use's success: the item is kept (a pet item's DoJob
// forces the count to 1, s:0x493070) or one is spent (a scroll).
func sendUseOK(sess *gateway.Session, remaining int, itemID int64) error {
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(remaining), ItemID: uint32(itemID)}).Encode()})
}

// sendItemState is 0x3040 {slot+13, 0x40, state} to the item's owner.
func sendItemState(sess *gateway.Session, slot int, state uint8) {
	if sess != nil && slot >= 0 {
		_ = sess.Send(&proto.Packet{Opcode: cos.OpItemState, Data: cos.ItemStateField(slot, state)})
	}
}

// useRideScroll is a ride or transport scroll's use
// (CGItemExpendable::vslot_307 case 2, s:0x49b9f0).
func useRideScroll(ctx context.Context, sess *gateway.Session, d cosDeps, inv inventory.Store, owner world.Entity, level int,
	it *refdata.Item, held inventory.Slot, have int, now time.Time) error {
	if motions.sittingOrSittingDown(owner.CharacterID, now) {
		return cosRefusal(sess, cos.ErrRideGeneric, "not while sitting")
	}
	code, ok := cos.RideRow(it.Desc1, it.Desc2, level)
	if !ok {
		return cosRefusal(sess, cos.ErrRideGeneric, "the scroll names no vehicle for your level")
	}
	row, ok := cosRowByCode(code)
	if !ok {
		return cosRefusal(sess, cos.ErrRideGeneric, "the scroll names no vehicle for your level")
	}
	if _, in := dungeonOf(owner.Zone); in {
		return cosRefusal(sess, cos.ErrCOSDungeon, cosRefusalText(cos.ErrCOSDungeon))
	}
	if c := checkCanSummon(owner.CharacterID, row.TypeID4, level, row.Level); c != 0 {
		return cosRefusal(sess, uint16(c), cosRefusalText(c))
	}
	if row.TypeID4 == cos.KindTransport {
		// CGItemExpendable::vslot_307 case 2 (round 801): a transport is not
		// called in the battle state (0x1878, chardata +0xd), nor by a
		// thief in a town (0x1895, the region's IsBattleField 0,
		// s:0x49bd8a).
		if inBattle(owner.CharacterID, now) {
			return cosRefusal(sess, cosErrSummonInBattle, "not in battle")
		}
		if jobStateNow(ctx, owner.CharacterID) == byte(jobs.KindThief) && safeRegions.Load() != nil && inTownAt(owner) {
			return cosRefusal(sess, cosErrRobberCartInTown, "a thief cannot call a transport in a town")
		}
	}
	rec := cos.Record{OwnerCharID: owner.CharacterID, RefCharID: row.ID, HP: row.MaxHP, Level: row.Level,
		HGP: cos.HGPFull, State: cos.StateAlive | cos.StateSummoned}
	id, err := d.store.Create(ctx, rec)
	if err != nil {
		d.logger.Warn("cos: creating a vehicle", "character", owner.CharacterID, "err", err)
		return cosRefusal(sess, cos.ErrCannotBeUsed, "the vehicle could not be made")
	}
	rec.ID = id
	// The scroll is spent (DoJob returns the count less one).
	if err := inv.RemoveItem(ctx, owner.CharacterID, held.Index, 1); err != nil {
		_ = d.store.Delete(ctx, id)
		return cosRefusal(sess, cos.ErrCannotBeUsed, "the scroll could not be used")
	}
	if err := sendUseOK(sess, have-1, it.ID); err != nil {
		return err
	}
	o := spawnCOS(owner, rec, row, 0, -1, cosSpawnTypeSummoned, now)
	// Every ride and transport row can be ridden (col 66, MEASURED): the
	// owner mounts at once when nothing refuses (s:0x4fb3cc..0x4fb3f0).
	mountCOS(ctx, sess, owner.CharacterID, o, true)
	return nil
}

// cosPetSpread is the radius a pet hatches within around its owner (the
// 20.0 FUN_004fbae0 passes for pets and soldiers, s:0xb45b20; a ride or
// transport 0: at the owner). That it is a spread is INFERRED.
const cosPetSpread = 20.0

// cosSpawnPoint is where a COS of kind comes into the world for an owner at
// pos: a pet within cosPetSpread of the owner, a ride or transport on the
// owner (s:0x4fbae0's hatch spread, 20.0 for pets and 0 for the others;
// INFERRED that the argument is the spread). A summon and an owner's
// arrival (a teleport, a zone change: the COS left with the owner and is
// spawned again, round 796 -- it stood on the owner before) both use it.
func cosSpawnPoint(pos world.Position, kind int) world.Position {
	if !cos.IsPetKind(kind) {
		return pos
	}
	a := rand.Float64() * 2 * math.Pi
	r := cosPetSpread * math.Sqrt(rand.Float64())
	pos.X += r * math.Cos(a)
	pos.Z += r * math.Sin(a)
	return pos
}

// spawnCOS puts a COS in the world beside owner, tells every client that
// holds the owner (0x3015), tells the owner its data (0x30C8), and for a
// growth pet or a transport the owner's state (0x30CA).
func spawnCOS(owner world.Entity, rec cos.Record, row species.Row, itemID int64, itemSlot int, spawnType byte, now time.Time) *cosObj {
	o := &cosObj{owner: owner.CharacterID, rec: rec, row: row, kind: row.TypeID4, itemID: itemID,
		zone: owner.Zone, pos: owner.Pos, heading: owner.Heading, regenAt: now.Add(cos.RegenPeriod),
		rentAt: now.Add(cos.RentCheckPeriod), lastTick: now}
	o.pos = cosSpawnPoint(owner.Pos, o.kind)
	if o.kind == cos.KindTransport {
		// The transport's bag (round 801): its storage is made as it comes
		// out (CGObjCOS vslot_349 s:0x4d1bd0 -> FUN_004d1a50), sized by the
		// owner's level; the store's capacity reads the record's.
		if size := transportBagSize(row, owner.Level); size != o.rec.InvSize {
			o.rec.InvSize = size
			if d := cosWorld.depsNow(); d.store != nil {
				_ = d.store.Save(context.Background(), o.rec)
			}
		}
	}
	cosWorld.add(o)
	cosAnnounce(o, spawnType)
	sendCOSData(o, itemSlot)
	if o.kind == cos.KindGrowth || o.kind == cos.KindTransport {
		sendAboutCOS(o, cos.OpCOSOwnerState, cos.OwnerState(o.uid, jobStateNow(context.Background(), owner.CharacterID), 0))
	}
	// A transport registered with goods registers its owner's caravan
	// (s:0x4fa839..0x4fa861, round 804's caravan.go).
	if o.kind == cos.KindTransport && caravanRT.Load() != nil {
		ctx := context.Background()
		if haveTradeItem(ctx, owner.CharacterID) {
			registerCaravan(ctx, owner.CharacterID, "a transport with goods came out")
		}
	}
	return o
}

// sendCOSData is the owner's 0x30C8 for o.
func sendCOSData(o *cosObj, itemSlot int) {
	ctx := context.Background()
	cosWorld.mu.Lock()
	dd := cos.Data{UID: o.uid, RefID: uint32(o.row.ID), TypeID4: o.kind, HP: uint32(max(0, o.rec.HP)),
		MP: uint32(max(0, o.rec.MP)), Exp: uint64(max(0, o.rec.Exp)), Level: uint8(o.rec.Level),
		HGP: uint16(o.rec.HGP), PetOption: o.rec.PetOption, Name: o.rec.Name, InvSize: uint8(o.rec.InvSize),
		OwnerUID: uint32(o.owner)}
	recID := o.rec.ID
	cosWorld.mu.Unlock()
	if itemSlot >= 0 {
		dd.ItemSlot = uint8(itemSlot + 13)
	}
	if dd.InvSize > 0 {
		dd.Items = cosBagItems(ctx, recID)
	}
	sendToCOSOwner(o, cos.OpCOSData, cos.AppendData(nil, dd))
}

// cosBagItems is a COS bag's slots as 0x30C8 / 0x30C9 type 2 carry them.
func cosBagItems(ctx context.Context, cosID int64) []cos.DataItem {
	d := cosWorld.depsNow()
	if d.bags == nil {
		return nil
	}
	slots, err := d.bags.List(ctx, cosID)
	if err != nil {
		return nil
	}
	now := time.Now()
	var out []cos.DataItem
	for _, sl := range slots {
		ii := ItemInfo{RefItemID: uint32(sl.ItemID), OptLevel: sl.OptLevel, Variance: sl.Variance,
			MagParams: sl.MagParams, AdvElixir: sl.AdvElixir}
		if it, err := d.items.GetItem(ctx, sl.ItemID); err == nil && it != nil {
			if tail := retailItemTail(ctx, it, sl, now); tail != nil {
				ii.Tail = tail
			} else if info, ok := itemInfoFor(ctx, d.items, sl.Index, sl.ItemID, sl.Instance()); ok {
				ii = info
			}
		}
		out = append(out, cos.DataItem{Slot: uint8(sl.Index), Record: AppendItemRecord(nil, ii)})
	}
	return out
}

// How a COS leaves its owner (FUN_004fa8b0's kinds, READ).
type releaseKind int

const (
	// releaseStore: a pet put back in its item (unsummon, recall): alive,
	// not summoned; the item's state 3.
	releaseStore releaseKind = iota
	// releaseDelete: a ride or transport done with (dismounted, terminated,
	// killed, sold): its record deleted; the item's state 1.
	releaseDelete
	// releaseDead: a pet killed: neither alive nor summoned; the item's
	// state 4. Its body lies until the corpse is cleared (cosai.go).
	releaseDead
	// releaseLeave: the owner leaves the world: the COS goes with it and
	// keeps its summoned flag, so it comes back at the next entry
	// (FUN_004fa1f0 / FUN_004fa430, READ; OURS for a ride, whose fate on a
	// normal logout is OPEN).
	releaseLeave
)

// releaseCOS takes o out of the world and settles its record.
func releaseCOS(ctx context.Context, o *cosObj, kind releaseKind) {
	d := cosWorld.depsNow()
	cosWorld.mu.Lock()
	ridden := o.ridden
	cosWorld.mu.Unlock()
	if ridden {
		dismountCOS(o.owner, o, true)
	}
	if kind != releaseLeave {
		sendToCOSOwner(o, cos.OpCOSUpdate, cos.RemovedUpdate(o.uid))
		cosVanish(o)
	}
	if !cosWorld.remove(o) {
		return
	}
	cosWorld.mu.Lock()
	rec := o.rec
	cosWorld.mu.Unlock()
	state := uint8(cos.ItemStateStored)
	switch kind {
	case releaseStore:
		rec.State &^= cos.StateSummoned
	case releaseDelete:
		state = cos.ItemStateNone
	case releaseDead:
		rec.State = 0
		state = cos.ItemStateDead
	}
	if kind == releaseDelete && o.kind == cos.KindTransport {
		clearTransportBag(ctx, o)
		refreshTradeScale(ctx, o.owner)
	}
	if d.store != nil {
		if kind == releaseDelete {
			_ = d.store.Delete(ctx, rec.ID)
		} else if err := d.store.Save(ctx, rec); err != nil {
			d.logger.Warn("cos: saving a release", "cos", rec.ID, "err", err)
		}
	}
	if kind != releaseLeave && o.itemID != 0 {
		if slot, ok := cosItemSlot(ctx, o.owner, rec.ID); ok {
			if e, ok := cosOwnerEntity(o.owner); ok {
				sendItemState(e.Session, slot, state)
			}
		}
	}
}

// cosItemSlot is the bag slot of owner's item linked to COS record id.
func cosItemSlot(ctx context.Context, owner, id int64) (int, bool) {
	d := cosWorld.depsNow()
	if d.inv == nil {
		return -1, false
	}
	slots, err := d.inv.List(ctx, owner)
	if err != nil {
		return -1, false
	}
	for _, sl := range slots {
		if int64(sl.Durability) == id && sl.Durability > 0 {
			if it, err := d.items.GetItem(ctx, sl.ItemID); err == nil && it != nil &&
				cos.IsPetItem(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4) {
				return sl.Index, true
			}
		}
	}
	return -1, false
}

// cosArrived is an owner's arrival (a world entry, a zone change): its COS
// come with it. Those still in the registry (a zone change keeps them) are
// moved beside it; at a world entry the summoned ones are brought back from
// the records (FUN_004fa430, READ): the pets whose items say so, then the
// rides and transports, a ride remounted. Each one's 0x30C8 goes to the
// owner; the clients that come to hold the owner get its COS with it.
func cosArrived(ctx context.Context, arrived world.Entity) {
	if ctx == nil {
		ctx = context.Background()
	}
	d := cosWorld.depsNow()
	if !d.enabled {
		return
	}
	now := time.Now()
	if out := cosWorld.owned(arrived.CharacterID); len(out) > 0 {
		for _, o := range out {
			cosWorld.mu.Lock()
			o.zone, o.pos, o.heading, o.moving = arrived.Zone, cosSpawnPoint(arrived.Pos, o.kind), arrived.Heading, false
			itemID, recID := o.itemID, o.rec.ID
			cosWorld.mu.Unlock()
			sendToCOSOwner(o, npcspawn.OpSingleSpawn, append(cosWorld.spawnRecord(o, now), cosSpawnTypeKnown))
			slot := -1
			if itemID != 0 {
				slot, _ = cosItemSlot(ctx, arrived.CharacterID, recID)
			}
			sendCOSData(o, slot)
		}
		bumpPlayerState(arrived.CharacterID)
		refreshTradeScale(ctx, arrived.CharacterID)
		return
	}
	// The pets the bag's items hold out.
	if d.inv != nil {
		slots, _ := d.inv.List(ctx, arrived.CharacterID)
		for _, sl := range slots {
			if sl.Durability <= 0 {
				continue
			}
			it, err := d.items.GetItem(ctx, sl.ItemID)
			if err != nil || it == nil || !cos.IsPetItem(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4) {
				continue
			}
			rec, err := d.store.Get(ctx, int64(sl.Durability))
			if err != nil || !rec.Alive() || !rec.Summoned() {
				continue
			}
			row, ok := cosRow(rec.RefCharID)
			if !ok {
				continue
			}
			spawnCOS(arrived, rec, row, it.ID, sl.Index, cosSpawnTypeKnown, now)
		}
	}
	rides, _ := d.store.SummonedRides(ctx, arrived.CharacterID)
	for _, rec := range rides {
		row, ok := cosRow(rec.RefCharID)
		if !ok {
			continue
		}
		o := spawnCOS(arrived, rec, row, 0, -1, cosSpawnTypeKnown, now)
		if o.kind == cos.KindRide && cosWorld.ridden(arrived.CharacterID) == nil {
			mountCOS(ctx, arrived.Session, arrived.CharacterID, o, true)
		}
	}
	// A transport brought back with its goods: its scale (0x30E8).
	refreshTradeScale(ctx, arrived.CharacterID)
}

// cosOwnerLeft is an owner leaving the world (a logout, a disconnect): its
// COS leave with it, their state saved. The clients that held the owner
// were sent their despawns with the owner's (departPlayer).
func cosOwnerLeft(characterID int64) {
	ctx := context.Background()
	for _, o := range cosWorld.owned(characterID) {
		cosWorld.mu.Lock()
		o.ridden = false
		cosWorld.mu.Unlock()
		releaseCOS(ctx, o, releaseLeave)
	}
	forgetRider(characterID)
}
