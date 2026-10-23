package session

// A devil's spirit's awakening and the Nasrun extension (round 789), on
// OpenSRO's use-item request (OpUseItem 0x008a). READ: the awakening is
// CGItemEquip::vslot_325 (s:0x498060), the extension
// CGItemExpendable::UseByKind case 0x10 (s:0x49c2b0); which use path reaches
// vslot 325 is OPEN (AVATAR_RESEARCH.md 7.2) -- OURS: using the devil's
// spirit in the bag, the only use a CanUse 3/1/14 row (column 24, MEASURED 1
// on all 26) has here. Its expiry is kept where retail keeps it, the
// instance's Data word (OpenSRO's Durability; internal/avatar).

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// The awakening's and the extension's codes (READ).
const (
	SpiritErrAlreadyAwake  uint16 = 2      // vslot_325: the expiry is already set
	ExtensionErrSlot       uint16 = 0x1882 // the target outside 13..111
	ExtensionErrTarget     uint16 = 3      // no item there, or not a devil's spirit
	ExtensionErrNotAwake   uint16 = 0x18f8 // UIIT_MSG_NASRUN_EXTENSION_ITEM_USE_AFTER_AWAKE
	nasrunExtensionTypeID4        = 16
)

// useItemClockAvatar is the awakening's clock; a test replaces it.
var useItemClockAvatar = time.Now

// isNasrunExtension is 3/3/13/16 (MEASURED: ITEM_MALL_NASRUN_EXTENSION and
// its event and rental copies; Param1 2,419,200 s).
func isNasrunExtension(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == 3 && it.TypeID2 == 3 && it.TypeID3 == 13 && it.TypeID4 == nasrunExtensionTypeID4
}

func sendUseResult(sess *gateway.Session, r *UseItemResult) error {
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: r.Encode()})
}

// useDevilSpirit awakens the devil's spirit in held: expiry = now + Param1
// seconds; one already awake is refused 2 and kept as it is. The item is not
// spent.
func useDevilSpirit(ctx context.Context, sess *gateway.Session, inv inventory.Store, characterID int64, held inventory.Slot, it *refdata.Item) error {
	data, ok := avatar.Awaken(held.Durability, it.Param1, useItemClockAvatar())
	if !ok {
		return sendUseResult(sess, &UseItemResult{Error: "the devil's spirit is already awake", Code: SpiritErrAlreadyAwake, Remaining: int32(held.Quantity)})
	}
	inst := held.Instance()
	inst.Durability = data
	if err := inv.SetInstance(ctx, characterID, held.Index, inst); err != nil {
		return sendUseResult(sess, &UseItemResult{Error: "using failed", Remaining: int32(held.Quantity)})
	}
	return sendUseResult(sess, &UseItemResult{Remaining: int32(held.Quantity), ItemID: uint32(it.ID)})
}

// useNasrunExtension moves the expiry of the devil's spirit at the target
// slot (req.Option, the wire slot: bag index + 13; OURS, the byte retail's
// request carries after the item's slot) by the extension's Param1, and
// spends one extension. The 0x3078 retail then sends (three fields) is OPEN
// and not sent.
func useNasrunExtension(ctx context.Context, sess *gateway.Session, inv inventory.Store, items ItemLookup, characterID int64, held inventory.Slot, have int, it *refdata.Item, target byte) error {
	refuse := func(code uint16, why string) error {
		return sendUseResult(sess, &UseItemResult{Error: why, Code: code, Remaining: int32(have)})
	}
	if target < AlchemyFirstBagSlot || target > AlchemyLastBagSlot {
		return refuse(ExtensionErrSlot, "choose the devil's spirit to extend")
	}
	idx := int(target) - AlchemyFirstBagSlot
	var code uint16
	err := txn.For(inv).Run(ctx, func(ctx context.Context) error {
		code = 0
		bag, err := inv.List(ctx, characterID)
		if err != nil {
			return err
		}
		var sp *inventory.Slot
		for i := range bag {
			if bag[i].Index == idx {
				sp = &bag[i]
			}
		}
		if sp == nil {
			code = ExtensionErrTarget
			return nil
		}
		spIt, err := items.GetItem(ctx, sp.ItemID)
		if err != nil || !avatar.IsDevilSpirit(spIt) {
			code = ExtensionErrTarget
			return nil
		}
		data, ok := avatar.Extend(sp.Durability, it.Param1, useItemClockAvatar())
		if !ok {
			code = ExtensionErrNotAwake
			return nil
		}
		inst := sp.Instance()
		inst.Durability = data
		if err := inv.SetInstance(ctx, characterID, idx, inst); err != nil {
			return err
		}
		return inv.RemoveItem(ctx, characterID, held.Index, 1)
	})
	switch {
	case err != nil:
		return refuse(0, "using failed")
	case code == ExtensionErrTarget:
		return refuse(code, "that is not a devil's spirit")
	case code == ExtensionErrNotAwake:
		return refuse(code, "the devil's spirit must be awakened first")
	}
	return sendUseResult(sess, &UseItemResult{Remaining: int32(have - 1), ItemID: uint32(it.ID)})
}
