package session

import (
	"context"
	"encoding/binary"
	"fmt"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Using a consumable. Until now potions dropped, stacked in the bag and did
// nothing at all -- the one thing a potion is for was missing.
const (
	// MOVED from 0x0080/0x0081 on 2026-09-20. Those were already
	// OpPartyCreate/OpPartyCreateResult, taken a month earlier, and this pair
	// collided with them.
	//
	// gateway.Chain offers a packet to EVERY handler, and each one decides by
	// opcode whether it is theirs -- so a use-item request was processed twice:
	// UseItemHandler consumed the berry and replied success, and the party
	// handler then failed to read a party-create payload out of the same bytes
	// and replied "malformed request". Both replies carried 0x0081, so the
	// client displayed both: "it used the berry from my inventory but it took a
	// second and it still said malformed request" (playtest 2026-09-20).
	//
	// Use-item moves because it is the newcomer -- party has held 0x0080 since
	// 2026-08-19 and use-item took it on 2026-09-14.
	OpUseItem       uint16 = 0x008a // client -> server
	OpUseItemResult uint16 = 0x008b // server -> client
)

// UseItemRequest asks to consume one of whatever is in an inventory slot.
type UseItemRequest struct {
	CharacterName string
	InventorySlot int32
}

func (r *UseItemRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(int64(r.InventorySlot))...)
}

func DecodeUseItemRequest(data []byte) (*UseItemRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseItemRequest: %w", err)
	}
	slot, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseItemRequest: slot: %w", err)
	}
	return &UseItemRequest{CharacterName: fields[0], InventorySlot: int32(slot)}, nil
}

// UseItemResult reports what the item did. HP/MP are the values *after* the
// item was used, so the client can redraw both bars without asking again.
type UseItemResult struct {
	Error      string
	HP         int32
	MaxHP      int32
	MP         int32
	MaxMP      int32
	RestoredHP int32
	RestoredMP int32
	Remaining  int32 // how many of the stack are left
}

func (r *UseItemResult) Encode() []byte {
	out := encodeStrings(r.Error)
	buf := make([]byte, 28)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.HP))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.MaxHP))
	binary.LittleEndian.PutUint32(buf[8:12], uint32(r.MP))
	binary.LittleEndian.PutUint32(buf[12:16], uint32(r.MaxMP))
	binary.LittleEndian.PutUint32(buf[16:20], uint32(r.RestoredHP))
	binary.LittleEndian.PutUint32(buf[20:24], uint32(r.RestoredMP))
	binary.LittleEndian.PutUint32(buf[24:28], uint32(r.Remaining))
	return append(out, buf...)
}

func DecodeUseItemResult(data []byte) (*UseItemResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseItemResult: %w", err)
	}
	r := &UseItemResult{Error: fields[0]}
	if len(rest) >= 28 {
		r.HP = int32(binary.LittleEndian.Uint32(rest[0:4]))
		r.MaxHP = int32(binary.LittleEndian.Uint32(rest[4:8]))
		r.MP = int32(binary.LittleEndian.Uint32(rest[8:12]))
		r.MaxMP = int32(binary.LittleEndian.Uint32(rest[12:16]))
		r.RestoredHP = int32(binary.LittleEndian.Uint32(rest[16:20]))
		r.RestoredMP = int32(binary.LittleEndian.Uint32(rest[20:24]))
		r.Remaining = int32(binary.LittleEndian.Uint32(rest[24:28]))
	}
	return r, nil
}

// UseItemHandler consumes one item from a bag slot and applies what it
// restores.
//
// The amounts are REAL: refdata.Item.RestoreHP/RestoreMP come from the item
// table's own Param block, where each value sits beside its own label ("HP..."
// at col 118, "MP..." at 122), so an HP_POTION_01 gives back 120 health and
// the large one 370. The percentage variants are honoured too, against the
// maximum, and an item carrying both gets both.
//
// APPLIED UNMODIFIED, and that is confirmed rather than assumed (2026-09-15).
// The engine does not hand a recovery straight to the pool: GObjPC::FUN_004a86a0
// scales the HP amount by ParamKeeper param 143 and the MP amount by 144 --
// `MOV EAX,0x8f` and `MOV EAX,0x90` into EvaluateParam, both read off the
// character's own keeper at +0x1ec -- before passing them to the adjust that
// writes the pool.
//
// Both are structurally ZERO. Neither has a SetParam site anywhere in the
// binary and neither is the target of a derived bind, so the scaling is a no-op
// for every character and the raw restore amount is what lands. (The probe was
// checked against param 0x22, which it does find, so the absence is a result
// and not a broken search.) A recovery-effectiveness stat exists in the engine;
// nothing in this build ever gives a character one.
//
// An item whose CanUse bit is clear (refdata.Item.CanUse, itemdata column 24)
// is refused first, as the engine refuses it with 0x183e CANNOT_BE_USED before
// it reads the item's type or its reuse delay (round 489). That bit is set on
// every HP/MP potion and clear on elixirs, alchemy stones, materials and all
// equipment but 28 cash-shop avatars -- rows whose Param block can still read
// as an HP/MP amount.
//
// An item that restores nothing is refused rather than silently eaten -- the
// bag is full of equipment and quest items that have no use yet, and quietly
// destroying one would be the worst possible answer.
func UseItemHandler(chars character.Store, inv inventory.Store, items combat.ItemLookup, mp *mana.Tracker) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpUseItem {
			return nil
		}
		fail := func(reason string) error {
			return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: reason}).Encode()})
		}
		req, err := DecodeUseItemRequest(p.Data)
		if err != nil {
			return fail("malformed request")
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return fail(errStr)
		}
		if inv == nil || items == nil {
			return fail("cannot use items")
		}

		slots, err := inv.List(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		var itemID int64 = -1
		var have int
		for _, sl := range slots {
			if sl.Index == int(req.InventorySlot) {
				itemID, have = sl.ItemID, sl.Quantity
				break
			}
		}
		if itemID < 0 || have < 1 {
			return fail("nothing there")
		}
		it, err := items.GetItem(ctx, itemID)
		if err != nil || it == nil {
			return fail("nothing known about that item")
		}
		// The item's own CanUse bit, the engine's first question about the
		// item (round 489): Item_HandleUseItem (0x00510980) calls vtable slot
		// 0xe0 -- IGObj::CanUse, CGObj::CanUse 0x00483ee0 on every CGItem*
		// class, flags bit 8 of the ref row -- and a zero answers 0x183e
		// UIIT_MSG_STRGERR_CANNOT_BE_USED before the TID match and the
		// cooldown are consulted.
		if !it.CanUse {
			return fail("that item cannot be used")
		}
		if it.RestoreHP <= 0 && it.RestoreMP <= 0 && it.RestoreHPPct <= 0 && it.RestoreMPPct <= 0 {
			return fail("that cannot be used")
		}
		// The reuse delay, the engine's way (round 263): only an item whose
		// row carries a COOLTIME descriptor has one, the timer belongs to the
		// item's cooltime GROUP, and a use inside it is refused with
		// WAIT_FOR_REUSE_DELAY (0x185b). A plain HP/MP potion carries none.
		if it.CooltimeMs > 0 && !itemCooldowns.Ready(characterID, it.CooltimeGroup, time.Now()) {
			return fail("wait for the reuse delay")
		}

		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		maxHP := owned.MaxHP()
		maxMP := owned.MaxMP()

		// Health first. Healing is capped at the missing amount so the
		// reported "restored" figure is what the player actually got, not
		// what the label promises.
		healHP := it.RestoreHP + maxHP*it.RestoreHPPct/100
		missingHP := maxHP - owned.HP
		if missingHP < 0 {
			missingHP = 0
		}
		if healHP > missingHP {
			healHP = missingHP
		}
		newHP := owned.HP
		if healHP > 0 {
			newHP, err = chars.Heal(ctx, characterID, healHP, maxHP)
			if err != nil {
				return fail("healing failed")
			}
		}

		healMP := it.RestoreMP + maxMP*it.RestoreMPPct/100
		newMP := maxMP
		if mp != nil {
			cur := mp.Current(characterID, maxMP)
			missingMP := maxMP - cur
			if healMP > missingMP {
				healMP = missingMP
			}
			if healMP < 0 {
				healMP = 0
			}
			mp.Restore(characterID, maxMP, healMP)
			newMP = cur + healMP
		} else {
			healMP = 0
		}

		// Nothing to gain is not a reason to spend the potion.
		if healHP <= 0 && healMP <= 0 {
			return fail("no need for that right now")
		}

		if err := inv.RemoveItem(ctx, characterID, int(req.InventorySlot), 1); err != nil {
			return fail("using failed")
		}
		remaining := have - 1
		// Armed after the use succeeds, as Item_HandleUseItem does (its
		// 0x64c320 call sits behind the success reply). In memory only: the
		// engine persists a delay of five minutes or more across a relog,
		// srrevamp does not yet -- disclosed.
		if it.CooltimeMs > 0 {
			itemCooldowns.Arm(characterID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, time.Now())
		}

		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{
			HP: int32(newHP), MaxHP: int32(maxHP),
			MP: int32(newMP), MaxMP: int32(maxMP),
			RestoredHP: int32(healHP), RestoredMP: int32(healMP),
			Remaining: int32(remaining),
		}).Encode()})
	}
}
