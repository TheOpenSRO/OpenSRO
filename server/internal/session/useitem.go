package session

import (
	"context"
	"encoding/binary"
	"fmt"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
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

// The item kinds whose use restores the USER's own HP/MP (round 491). The
// engine picks an item's use by its TID, never by whether its Param block
// happens to hold numbers:
//
//   - FUN_00489de0, the object factory, builds a CGItemExpendable for
//     TypeID1 3 / TypeID2 3 (`param_1 >> 2 & 7` == 3, `param_1 >> 5 & 3` == 3);
//     equipment and pet summoners are other classes with other DoJobs.
//   - CGItemExpendable::DoJob (0x0049aca0, vtable 0x00aeb2b4 slot 306, the
//     `+0x4c8` call Item_HandleUseItem makes) switches on TypeID3
//     (`TID >> 7 & 0xf`). Case 1 sends TypeID4 4/5/6/7/9 to slot 327
//     (0x0049d240) and 10 to slot 330 (0x0049cc80); every other TypeID4 goes
//     to slot 308 (0x0049b710).
//   - Slot 308 under TypeID3 1: TypeID4 8 is GObjPC::AddHwanCount (the berserk
//     potion); any other reads the amounts through GObjPC::FUN_0049aa70 --
//     Param1 (+0x2a0) HP, Param2 (+0x2c0) HP %, Param3 (+0x2e0) MP, Param4
//     (+0x300) MP %, the exporter's columns 118/120/122/124 -- and applies them
//     to the owner PC (0x49b90c..0x49b946).
//   - Slot 327 applies 4/5/7's amounts to a PET the packet names (its owner
//     must be the user), revives a pet (6) or feeds one (9); slot 330 repairs a
//     siege structure (10). None of them touches the user's pool.
//
// So the user's HP/MP comes back only from 3/3/1/x with x outside
// {4,5,6,7,8,9,10}; in real itemdata that is the 58 rows of TypeID4 1 (HP), 2
// (MP) and 3 (both). Among the DIRECT pool writes an item use makes (the item
// paths among GObjPC::ApplyHPMPDelta's call sites), the one other is the
// resurrection kind 3/3/13/6 (UseByKind 0x0049c2b0 case 6 -> FUN_0049ff20),
// which refuses a user whose life state is not 2 with 0x1887
// UIIT_MSG_STRGERR_ONLY_THE_DEAD_CAN_USE_RESURRECT_SCROLL and fills HP/MP only
// as part of reviving a dead one (GObjPC::Revive) -- a use srrevamp does not
// model. That census is scoped to direct writes: UseByKind's cases 1..3 cast
// the skill whose id is the row's Param1 (+0x2a0, looked up by FUN_0046c1f0,
// applied by FUN_0059b8d0), and a pool write such a skill makes was not
// traced. The gate is unaffected -- on those rows Param1 is a skill id, not a
// restore amount.
const (
	// recoveryFamily is TypeID3 1 under TypeItem/TypeExpendable: DoJob's case
	// 1 (0x0049aca0).
	recoveryFamily = 1
	// berserkPotionKind is TypeID4 8 under recoveryFamily: slot 308's
	// `bVar3 != 8` test (0x0049b89a `cmp al,0x8`) sends it to AddHwanCount.
	berserkPotionKind = 8
)

// restoresUserPool reports whether the engine's use dispatch sends an item of
// this kind to the user's own HP/MP recovery (see recoveryFamily).
func restoresUserPool(it *refdata.Item) bool {
	if it.TypeID1 != equipment.TypeItem || it.TypeID2 != equipment.TypeExpendable || it.TypeID3 != recoveryFamily {
		return false
	}
	switch it.TypeID4 {
	case 4, 5, 6, 7, 9: // DoJob case 1 -> slot 327 (0x0049d240): a pet's HP/MP, revival, feed
		return false
	case 10: // DoJob case 1 -> slot 330 (0x0049cc80): siege structure repair
		return false
	case berserkPotionKind: // slot 308 -> GObjPC::AddHwanCount
		return false
	}
	return true
}

// UseItemHandler consumes one item from a bag slot and applies what it
// restores.
//
// The amounts are REAL: refdata.Item.RestoreHP/RestoreMP come from the item
// table's own Param block, where each value sits beside its own label ("HP..."
// at col 118, "MP..." at 122), so an HP_POTION_01 carries 120 health and the
// large one 370. They are restore amounts ONLY on the recovery kinds above:
// the exporter emits columns 118..124 for every row, and on a return scroll
// (30000), a cure pill or a storage expansion (its slot increment, round 270)
// the same columns hold something else. The percentage variants are honoured
// too, against the maximum.
//
// Round 491 found the amount is NOT applied as the engine applies it, and
// this is a DISCLOSED GAP, not a grounding: GObjPC::FUN_0049aa70
// (0x49ab63..0x49ac37) scales an absolute amount before it lands --
// HP = Param1 * 1.02^(Level-1) * (1 + GetParam(1)/416), MP the same with
// Param3 and GetParam(2) (params 0/1/2 are Level/Str/Int; 1.02 at .rdata
// 0xb45ea0, 416.0 at 0xb45e98) -- and reads the percentage pair only when
// both absolute amounts are zero. srrevamp applies the raw amounts and adds
// both pairs; no real recovery row carries both, so only the scaling differs.
//
// The later step is a no-op ONLY while neither panic nor combustion is on the
// character, and srrevamp does not model it -- a second DISCLOSED GAP.
// GObjPC::FUN_004a86a0 (ApplyHPMPDelta) multiplies the HP amount by
// (1 - param143/100) and the MP amount by (1 - param144/100) before the adjust
// that writes the pool (`MOV EAX,0x8f` / `MOV EAX,0x90` into
// ParamKeeper_GetParamChecked 0x4b3740 on the keeper at +0x1ec, then 0x4a86c9
// `fdiv` by the 100.0 at .rdata 0xb45af0, `fld1`, `fsubrp` (DE E1: 1 - p/100),
// `fimul` the amount). The 2026-09-15 finding that "neither has a SetParam
// site anywhere in the binary" was wrong: AbnormalState_Panic_Apply21
// (0x4a5320) writes param 143 (0x4a5418 `mov edi,0x8f`; 0x4a541d
// `call 0x4b3510` ParamKeeper_SetParam) and AbnormalState_Combustion_Apply22
// (0x4a54a0) writes 144 (0x4a5598 `mov edi,0x90`; 0x4a559d), each from the
// effect's +0x34 value, while the state is on -- recorded since round 248 in
// docs/protocol/status_effects.md (bits 21/22) and
// docs/protocol/param_writers.md. So a panic (combustion) effect cuts a
// potion's HP (MP) by its percentage, and srrevamp heals the full amount
// regardless.
//
// An item whose CanUse bit is clear (refdata.Item.CanUse, itemdata column 24)
// is refused before its type or reuse delay is read, as the engine refuses it
// with 0x183e CANNOT_BE_USED before the TID match and the cooldown (round 489;
// the engine's rental-expiry 0x183d and life-state 0x1889 checks come earlier
// still). That bit is set on
// every HP/MP potion and clear on elixirs, alchemy stones, materials and all
// equipment but 28 cash-shop avatars -- rows whose Param block can still read
// as an HP/MP amount.
//
// An item that restores nothing is refused rather than silently eaten -- the
// bag is full of equipment and quest items that have no use yet, and quietly
// destroying one would be the worst possible answer. That includes every
// CanUse item that is not a recovery kind (round 491): a return scroll, a cure
// pill, a pet potion, a berserk potion, a resurrection scroll, a storage
// expansion. The engine USES those -- each has its own DoJob branch -- and
// srrevamp models none of their effects, so it refuses them with the
// restores-nothing reason and keeps the item. That refusal is srrevamp's
// DISCLOSED GAP, not an engine refusal.
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
		// The item's own CanUse bit (round 489): Item_HandleUseItem
		// (0x00510980) -- after the empty-slot (0x1809), rental-expiry
		// (FUN_00492680, 0x183d) and life-state (0x1889) checks, which
		// srrevamp does not model here (round 490) -- calls vtable slot
		// 0xe0 -- IGObj::CanUse, CGObj::CanUse 0x00483ee0 on every CGItem*
		// class, flags bit 8 of the ref row -- and a zero answers 0x183e
		// UIIT_MSG_STRGERR_CANNOT_BE_USED before the TID match and the
		// cooldown are consulted.
		if !it.CanUse {
			return fail("that item cannot be used")
		}
		// Only a recovery kind's Param block is a restore amount (round 491,
		// restoresUserPool); any other kind's effect is not modelled.
		if !restoresUserPool(it) {
			return fail("that cannot be used")
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
