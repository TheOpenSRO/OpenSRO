package session

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// The items that act on a pet (round 795; CGItemExpendable::
// SetEngagedCOSforOpenMarket s:0x49d240 and vslot_328 s:0x49d8f0, READ):
//
//	3/3/1/4, /5, /7  a COS HP potion          + u32 the COS's uid
//	3/3/1/9          the HGP potion (food)    + u32 the COS's uid
//	3/3/2/7          a pet's cure             + u32 the COS's uid
//	3/3/1/6          the revival              + u8 the dead pet's item slot
//	3/3/13/12        the rental clock         + u8 the ability pet's item slot
//
// Retail's 0x704C carries the extra after the slot and type word. OpenSRO's
// use request carries it as Option UseOptionCOSTarget and the u32 Target
// (OURS: the uid, or the item's bag index for the two slot forms).

// UseOptionCOSTarget marks a use request whose Target names a pet (OURS).
const UseOptionCOSTarget byte = 0xC5

// isCOSConsumable reports an item of the table above.
func isCOSConsumable(it *refdata.Item) bool {
	if it == nil || it.TypeID1 != 3 || it.TypeID2 != 3 {
		return false
	}
	switch {
	case it.TypeID3 == 1 && (it.TypeID4 == 4 || it.TypeID4 == 5 || it.TypeID4 == 6 || it.TypeID4 == 7 || it.TypeID4 == 9):
		return true
	case it.TypeID3 == 2 && it.TypeID4 == 7:
		return true
	case it.TypeID3 == 13 && it.TypeID4 == 12:
		return true
	}
	return false
}

// useCOSConsumable is one of them.
func useCOSConsumable(ctx context.Context, sess *gateway.Session, inv inventory.Store, chars character.Store, characterID int64,
	it *refdata.Item, held inventory.Slot, have int, req *UseItemRequest, locks *itemCooldownTracker) error {
	d := cosWorld.depsNow()
	if !d.enabled {
		return cosRefusal(sess, cos.ErrCannotBeUsed, "no COS table on this server")
	}
	if req.Option != UseOptionCOSTarget {
		return cosRefusal(sess, cos.ErrPetCantUseItem, "no pet named")
	}
	spend := func() error {
		if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
			return cosRefusal(sess, cos.ErrCannotBeUsed, "the item could not be used")
		}
		return sendUseOK(sess, have-1, it.ID)
	}
	// A COS HP potion's reuse lock (round 805; slot 327, s:0x49d240, READ):
	// FUN_004eb410 is asked first -- TypeID4 4, 5, 7 hold the PC's bits 8,
	// 0x10, 0x20 -- and a held bit answers WAIT_FOR_REUSE_DELAY (0x185b) with
	// the item kept. The heal below arms it for 1.1 s (FUN_004e0ab0, the
	// float 0xb461b8 at s:0x49d4e7).
	reuseBit, hpPotion := cosPotionReuseBit(it)
	now := useItemClock()
	if hpPotion && locks != nil && !locks.Ready(characterID, reuseBit, now) {
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: reuseDelayRefusal}).Encode()})
	}
	slotForm := (it.TypeID3 == 1 && it.TypeID4 == 6) || (it.TypeID3 == 13 && it.TypeID4 == 12)
	if slotForm {
		return useOnPetItem(ctx, sess, inv, characterID, it, int(req.Target), spend)
	}
	o := cosWorld.get(req.Target)
	if o == nil || o.owner != characterID {
		return cosRefusal(sess, cos.ErrNotYourCOS, "not your pet")
	}
	cosWorld.mu.Lock()
	kind, dead := o.kind, o.dead
	cosWorld.mu.Unlock()
	if dead {
		return cosRefusal(sess, cos.ErrPetCantUseItem, "the pet is dead")
	}
	switch {
	case it.TypeID3 == 1 && it.TypeID4 == 9:
		// The HGP potion: a growth pet's, refused at 99 % (0x18b3).
		if kind != cos.KindGrowth {
			return cosRefusal(sess, 3, "only a growth pet eats")
		}
		cosWorld.mu.Lock()
		if o.rec.HGP*100/cos.HGPFull >= cos.HGPFeedRefusePercent {
			cosWorld.mu.Unlock()
			return cosRefusal(sess, cos.ErrHGPFull, "the pet is full")
		}
		o.rec.HGP = cos.FeedAmount(o.rec.HGP, int(int32(it.Param1)))
		hgp := o.rec.HGP
		cosWorld.mu.Unlock()
		if err := spend(); err != nil {
			return err
		}
		cosSave(ctx, o)
		sendToCOSOwner(o, cos.OpCOSUpdate, cos.HGPUpdate(o.uid, hgp))
		return nil
	case it.TypeID3 == 2:
		// The cure: a growth pet's abnormal states (none are modelled on a
		// COS, OURS) -- the item is spent all the same.
		if kind == cos.KindAbility || kind == cos.KindSoldier {
			return cosRefusal(sess, 3, "that pet cannot use it")
		}
		return spend()
	default:
		// A COS HP potion: the user's own potion formula, landing on the COS
		// (FUN_0049aa70 with the user's level and strength).
		if kind == cos.KindAbility || kind == cos.KindSoldier {
			return cosRefusal(sess, 3, "that pet cannot use it")
		}
		c, err := chars.GetByID(ctx, characterID)
		if err != nil || c == nil {
			return cosRefusal(sess, cos.ErrCannotBeUsed, "lookup failed")
		}
		bonus := character.BonusOf(characterID)
		maxHP := character.MaxHPFor(c.Str+bonus.Str, c.Level) + bonus.HP
		hp, _ := potionRestore(it.RestoreHP, it.RestoreHPPct, it.RestoreMP, it.RestoreMPPct, c.Level, c.Str+bonus.Str, c.Int+bonus.Int, maxHP, 0)
		if hp < 1 {
			// FUN_0049aa70 came out below 1: result 2, nothing spent.
			return cosRefusal(sess, 2, "that cannot be used")
		}
		cosWorld.mu.Lock()
		o.rec.HP = min(o.row.MaxHP, o.rec.HP+hp)
		hpNow := o.rec.HP
		cosWorld.mu.Unlock()
		if err := spend(); err != nil {
			return err
		}
		if hpPotion && locks != nil {
			locks.Arm(characterID, reuseBit, cosPotionReuseDelay, now)
		}
		sendCOSHP(o, hpNow)
		return nil
	}
}

// cosPotionReuseDelay is the COS HP potion's lock (the float 0xb461b8, 1.1).
const cosPotionReuseDelay = 1100 * time.Millisecond

// cosPotionReuseBit is FUN_004eb410's bit for a COS HP potion (TypeID3 1,
// TypeID4 4 -> 8, 5 -> 0x10, 7 -> 0x20; the jump table at 0x4eb574); ok is
// false for any other pet consumable, which has no lock.
func cosPotionReuseBit(it *refdata.Item) (bit uint32, ok bool) {
	if it == nil || it.TypeID3 != 1 {
		return 0, false
	}
	switch it.TypeID4 {
	case 4:
		return 8, true
	case 5:
		return 0x10, true
	case 7:
		return 0x20, true
	}
	return 0, false
}

// useOnPetItem is the revival or the clock, used on a pet's item in bag
// slot (an index).
func useOnPetItem(ctx context.Context, sess *gateway.Session, inv inventory.Store, characterID int64, it *refdata.Item,
	slot int, spend func() error) error {
	d := cosWorld.depsNow()
	slots, err := inv.List(ctx, characterID)
	if err != nil {
		return cosRefusal(sess, cos.ErrCannotBeUsed, "lookup failed")
	}
	var target *inventory.Slot
	for i := range slots {
		if slots[i].Index == slot {
			target = &slots[i]
		}
	}
	if target == nil || target.Durability <= 0 {
		return cosRefusal(sess, 3, "no pet there")
	}
	ref, err := d.items.GetItem(ctx, target.ItemID)
	if err != nil || ref == nil || !cos.IsPetItem(ref.TypeID1, ref.TypeID2, ref.TypeID3, ref.TypeID4) {
		return cosRefusal(sess, 3, "no pet there")
	}
	rec, err := d.store.Get(ctx, int64(target.Durability))
	if err != nil {
		return cosRefusal(sess, 3, "no pet there")
	}
	now := time.Now()
	if it.TypeID3 == 1 {
		// The revival (s:0x49d240 case 6): a dead pet alive again with its
		// row's HP, and HGP 3000 when it was below it.
		if rec.Alive() {
			return cosRefusal(sess, 3, "the pet is not dead")
		}
		row, ok := cosRow(rec.RefCharID)
		if !ok {
			return cosRefusal(sess, 3, "the pet's row is unknown")
		}
		rec.State ^= cos.StateAlive
		rec.HP = row.MaxHP
		if rec.HGP < cos.HGPRevived {
			rec.HGP = cos.HGPRevived
		}
	} else {
		// The clock (vslot_328 s:0x49d8f0): an ability pet's rent from the
		// later of its end and now, Param1 minutes on; alive again.
		row, ok := cosRow(rec.RefCharID)
		if !ok || row.TypeID4 != cos.KindAbility {
			return cosRefusal(sess, cos.ErrExtensionNotAbility, "only an ability pet's rent runs")
		}
		base := rec.RentEnd
		if base.Before(now) {
			base = now
		}
		rec.RentEnd = base.Add(time.Duration(int32(it.Param1)) * time.Minute)
		rec.State |= cos.StateAlive
	}
	if err := d.store.Save(ctx, rec); err != nil {
		return cosRefusal(sess, cos.ErrCannotBeUsed, "the pet could not be saved")
	}
	if err := spend(); err != nil {
		return err
	}
	if it.TypeID3 == 1 {
		sendItemState(sess, slot, cos.ItemStateStored)
	} else {
		_ = sess.Send(&proto.Packet{Opcode: cos.OpItemState, Data: cos.ItemRentField(slot, cos.RentSecondsLeft(rec.RentEnd, now))})
		sendItemState(sess, slot, cos.ItemState(true, rec.State))
	}
	return nil
}
