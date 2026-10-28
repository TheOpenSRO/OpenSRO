package session

// Ammunition (round 838): the arrows and bolts worn in slot 7, spent by the
// bow and crossbow casts that carry the `cnsm` param. READ from
// SR_GameServer.exe unless a line says otherwise:
//
//   - The worn stack. The ammunition is worn whole (equipment.Equipped.
//     Quantity), and every helper reads equip slot 7 only: 0x4ec220 the item,
//     0x4ec250 its count (item vslot +0x4e8, GetCount).
//   - The gate. Skill_CheckUseConditions (0x58d8f0) row 0x20 (0x58e32d..
//     0x58e3c5), for a PC whose row carries `cnsm` (CRefSkill +0x2a0, three
//     words: TypeID3, TypeID4, count): the slot-7 item must be there, its
//     TypeID3 cnsm[0], its TypeID4 cnsm[1] when that is not 0, and its count
//     above 0 -- never compared with what the cast will spend -- else 0x300e.
//     The callers that pass bit 0x20: the 0x7074 accept (mask 0x37, so a
//     cast is refused before it is queued) and Tick_Attack's phase 0 (0x64)
//     and phase 1 (0x24, every keep-up swing; a refusal ends the attack).
//     Tick_UseSkill's 0x17/0x91 do not, so a chain's link is not gated before
//     its spend.
//   - The spend. Skill_BuildUseContext_A (0x5857b0, ActionKind 1: every one
//     of the 386 `cnsm` rows) spends once a cast -- not per target, not per
//     landed hit, a miss spends too -- after Combat_ResolveDamage and before
//     EngageSkill: n = cnsm[2] x the `mc` hit count (1 without one), cut to 1
//     when the stack holds exactly 1, the count becoming max(0, count - n)
//     (ConsumeAmmo 0x4ec290). Slot 7 empty or wrong at that moment: 0x300e,
//     no blow, no cost.
//   - The count. 0x3201 {u16 newCount}, to the caster only, before the
//     cast's own result (0x585b62..0x585b9d). The client sets the slot-7
//     item's count and clears the slot at 0 (c:0x882280, 0x6ab830, 0x6ae4e0).
//   - The reload. At 0 AutoReloadMagazine (0x4ec340): the LOWEST bag slot
//     whose item matches TypeID1..4 (CGStorage::FindItemHasSameTID 0x4ba130;
//     the cash bit is not compared, so the mall's quiver refills an ordinary
//     arrow and back -- MEASURED from the flags) is moved whole into slot 7;
//     none found, the slot-7 item is deleted (DelItem_EXT, op 0x0F).
//
// OURS, disclosed:
//
//   - The refusal is OpAttackResult's text, the client's own line for 0x300e
//     by the caster's race (c:0x7b98ce: UIIT_SKILL_USE_FAIL_RUNOUT_AMMO
//     "Insufficient arrows." for a Chinese, _VOLT "Insufficient bolts." for a
//     European).
//   - The reload's and the deletion's answer is the worn list and the bag list
//     (sendWornList, the bag's list reply), not retail's 0xB034 forms.
//   - OpenSRO takes a cast's HP/MP before its blows are resolved, so a cast
//     whose ammunition ran out between the gate and the spend has paid them;
//     retail's EngageSkill would not have. The gate makes that a race between
//     two of the caster's own casts.

import (
	"context"
	"encoding/binary"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// OpAmmoCount is retail's 0x3201: the worn ammunition's count after a spend,
// {u16 newCount}, to the caster only (READ 0x585b62; the client's handler
// c:0x882280).
const OpAmmoCount uint16 = 0x3201

// The 0x300e refusal's two lines (c:0x7b98ce, by the caster's race; READ).
const (
	ammoRefusalArrows = "Insufficient arrows."
	ammoRefusalBolts  = "Insufficient bolts."
)

// ammoNeed is the row's `cnsm` run: the TypeID3 and TypeID4 the cast wants
// in slot 7 and how many a hit spends. ok false for a row that spends none.
func ammoNeed(row *refdata.Skill) (tid3, tid4, perHit int, ok bool) {
	if row == nil || !row.HasParams() {
		return 0, 0, 0, false
	}
	v, found := row.Runs().Values("cnsm")
	if !found || len(v) < 3 {
		return 0, 0, 0, false
	}
	return int(v[0]), int(v[1]), int(v[2]), true
}

// ammoSpend is what one cast of row takes: cnsm[2] x its hit count.
func ammoSpend(row *refdata.Skill) int {
	_, _, perHit, ok := ammoNeed(row)
	if !ok {
		return 0
	}
	return max(1, perHit) * row.HitsFor()
}

// wornAmmo is the slot-7 item when it is ammunition of row's kind: TypeID
// 3/3/cnsm[0] and, when cnsm[1] is not 0, TypeID4 cnsm[1].
func wornAmmo(ctx context.Context, eq equipment.Store, items ItemLookup, characterID int64, row *refdata.Skill) (equipment.Equipped, *refdata.Item, bool) {
	tid3, tid4, _, ok := ammoNeed(row)
	if !ok || eq == nil || items == nil {
		return equipment.Equipped{}, nil, false
	}
	worn, err := eq.Get(ctx, characterID)
	if err != nil {
		return equipment.Equipped{}, nil, false
	}
	for _, e := range worn {
		if e.Slot != equipment.SlotShield {
			continue
		}
		it, err := items.GetItem(ctx, e.ItemID)
		if err != nil || it == nil || it.TypeID1 != 3 || it.TypeID2 != 3 || it.TypeID3 != tid3 || (tid4 != 0 && it.TypeID4 != tid4) {
			return equipment.Equipped{}, nil, false
		}
		return e, it, true
	}
	return equipment.Equipped{}, nil, false
}

// ammoRefusalText is the 0x300e line for characterID's race.
func ammoRefusalText(ctx context.Context, chars character.Store, characterID int64) string {
	if chars != nil {
		if c, err := chars.GetByID(ctx, characterID); err == nil && characterCountry(c) == equipment.CountryEurope {
			return ammoRefusalBolts
		}
	}
	return ammoRefusalArrows
}

// ammoRefusal is the gate's row 0x20: "" when row spends no ammunition or
// slot 7 holds some of its kind with a count above 0, else the refusal line.
func ammoRefusal(ctx context.Context, chars character.Store, eq equipment.Store, items ItemLookup, characterID int64, row *refdata.Skill) string {
	if _, _, _, ok := ammoNeed(row); !ok {
		return ""
	}
	if e, _, ok := wornAmmo(ctx, eq, items, characterID, row); ok && e.Count() > 0 {
		return ""
	}
	return ammoRefusalText(ctx, chars, characterID)
}

// spendAmmo is the cast's spend (Skill_BuildUseContext_A): row's cnsm[2] x
// hits from slot 7, the 0x3201 count to the caster, and at 0 the reload or
// the deletion, with the worn and bag lists sent after it. It returns the
// refusal line when slot 7 holds none of the row's kind (no blow then), ""
// otherwise -- also for a row that spends nothing.
func spendAmmo(ctx context.Context, sess *gateway.Session, chars character.Store, eq equipment.Store, inv inventory.Store, items ItemLookup, characterID int64, row *refdata.Skill) string {
	n := ammoSpend(row)
	if n == 0 {
		return ""
	}
	worn, it, ok := wornAmmo(ctx, eq, items, characterID, row)
	ammo, canSpend := eq.(equipment.AmmoStore)
	if !ok || !canSpend || worn.Count() <= 0 {
		return ammoRefusalText(ctx, chars, characterID)
	}
	left, err := ammo.SpendWorn(ctx, characterID, equipment.SlotShield, n)
	if err != nil {
		return ammoRefusalText(ctx, chars, characterID)
	}
	if sess != nil {
		_ = sess.Send(&proto.Packet{Opcode: OpAmmoCount, Data: binary.LittleEndian.AppendUint16(nil, uint16(left))})
	}
	if left > 0 {
		return ""
	}
	reloadAmmo(ctx, sess, ammo, eq, inv, items, characterID, it)
	return ""
}

// reloadAmmo is AutoReloadMagazine (0x4ec340): the spent slot-7 item gives
// way to the lowest bag stack of the same TypeID1..4, moved whole, or is
// deleted when the bag holds none. The client hears both lists.
func reloadAmmo(ctx context.Context, sess *gateway.Session, ammo equipment.AmmoStore, eq equipment.Store, inv inventory.Store,
	items ItemLookup, characterID int64, spent *refdata.Item) {
	if err := ammo.DiscardWorn(ctx, characterID, equipment.SlotShield); err != nil {
		slog.Error("ammunition: clearing the spent stack failed", "character_id", characterID, "error", err)
	}
	if inv != nil && spent != nil {
		if slots, err := inv.List(ctx, characterID); err == nil {
			best := -1
			for _, sl := range slots {
				if sl.Quantity < 1 || (best >= 0 && sl.Index >= best) {
					continue
				}
				it, err := items.GetItem(ctx, sl.ItemID)
				if err != nil || it == nil || it.TypeID1 != spent.TypeID1 || it.TypeID2 != spent.TypeID2 ||
					it.TypeID3 != spent.TypeID3 || it.TypeID4 != spent.TypeID4 {
					continue
				}
				best = sl.Index
			}
			if best >= 0 {
				if err := eq.Equip(ctx, characterID, equipment.SlotShield, best); err != nil {
					slog.Error("ammunition: the reload failed", "character_id", characterID, "bag_slot", best, "error", err)
				}
			}
		}
	}
	if sess == nil {
		return
	}
	_ = sendWornList(ctx, sess, eq, items, characterID)
	if inv != nil {
		if slots, err := inv.List(ctx, characterID); err == nil {
			_ = sess.Send(&proto.Packet{Opcode: OpInventoryListResult, Data: bagListResult(ctx, inv, characterID, slots, items).Encode()})
		}
	}
}
