package session

import (
	"context"
	"fmt"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// The berserk potion (round 632): TypeID 3/3/1/8. In Media.pk2's itemdata
// these are ITEM_ETC_SECOND_HWAN (23937, "Hwan regeneration fill" -- the fill
// an Energy of life scroll hands out), ITEM_ETC_E080723_HWAN_POTION (24331),
// ITEM_EVENT_HWAN_POTION (24993) and ITEM_EVENT_RENT_HWAN_POTION (33884),
// all "Berserker Regeneration Potion", ITEM_ETC_GNGWC_WHAN (22936, "Berserk
// Regeneration Potion") and two quest items (5921, 10491). Their tooltip says
// what the engine does: "Fills berserk gage to 100%. Cannot be used during
// berserk mode." (SN_ITEM_ETC_E080723_HWAN_POTION_TT_DESC).
//
// READ, CGItemExpendable slot 308 (0x0049b710), TypeID3 1 / TypeID4 8
// (srv.asm 0x49b9a4..0x49b9e9):
//
//	call [vtable+0x100]      ; IGObj::GetBodyMode
//	cmp al,1 ; jne 0x49b9c9
//	mov WORD [result],0x18ce ; berserk on: refused, the potion is kept
//	0x49b9c9: push 0 ; mov esi,0x5 ; call 0x4e4d00   ; AddHwanCount(+5)
//	mov WORD [result],0x1    ; used
//
// So the branch skips the per-kind potion lock (FUN_004eb410 is only asked
// for the other recovery kinds) and never looks at the orb count: at five
// orbs AddHwanCount clamps to five and the potion is still spent. The only
// reuse delay is the row's COOLTIME descriptor, which Item_HandleUseItem
// (0x00510980) checks with ItemCooldowns::IsReady before DoJob (0x185b) and
// arms with ItemCooldowns::Arm after a success -- the same generic path every
// cooltime item takes (round 263). From the rows: 23937 carries
// "COOLTIME:0x000000C9" with 1200000 ms (20 minutes, group 0xC9, which
// the Energy of life scrolls 23944-23947 also carry), 22936
// "COOLTIME:0x00000000" with 180000 ms (3 minutes, group 0), and the others
// none.
//
// OURS (the user's request, 2026-09-28): a GM account's berserk potion
// consults and arms no reuse delay, so berserk can be tested back to back.
// It applies only to this item kind; every other cooltime item keeps its
// delay for a GM too.
//
// 0x18ce has no case in the client's error-message switch
// (docs/protocol/error_codes.md), so the wording below is srrevamp's own,
// taken from the tooltip's "Cannot be used during berserk mode".
const berserkPotionRefusal = "that cannot be used during berserk mode"

// isBerserkPotion reports whether slot 308 sends the item to AddHwanCount:
// TypeID 3/3 (CGItemExpendable), TypeID3 1, TypeID4 8.
func isBerserkPotion(it *refdata.Item) bool {
	return it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == recoveryFamily && it.TypeID4 == berserkPotionKind
}

// useBerserkPotion is the use of a 3/3/1/8 item, in the engine's order: the
// cooltime gate (Item_HandleUseItem), the berserk refusal (slot 308), the
// spend, AddHwanCount(+5), the cooltime arm. isGM skips the cooltime (OURS).
func useBerserkPotion(ctx context.Context, sess *gateway.Session, fail func(string) error,
	chars character.Store, inv inventory.Store, zerk *berserk.Tracker, isGM bool,
	characterID int64, it *refdata.Item, held inventory.Slot, have int) error {
	if zerk == nil {
		return fail("that cannot be used")
	}
	now := useItemClock()
	cooltime := it.CooltimeMs > 0 && !isGM
	if cooltime && !itemCooldowns.Ready(characterID, it.CooltimeGroup, now) {
		return fail("wait for the reuse delay")
	}
	owned, err := chars.GetByID(ctx, characterID)
	if err != nil || owned == nil {
		return fail("lookup failed")
	}
	zerk.EnsureSeeded(characterID, owned.HwanCount)
	if zerk.Active(characterID) {
		return fail(berserkPotionRefusal)
	}
	// Spent before the orbs land, as the recovery potion is (round 511): a
	// removal that fails must not fill the gauge.
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		return fail("using failed")
	}
	zerk.Add(characterID, berserk.PotionCharges)
	if err := chars.SetHwanCount(ctx, characterID, zerk.Charges(characterID)); err != nil {
		return fmt.Errorf("useitem: persisting berserk potion: %w", err)
	}
	if cooltime {
		itemCooldowns.Arm(characterID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, now)
	}
	// MaxHP/MaxMP 0: the pools are untouched, and the client leaves its bars
	// alone (World3D._on_use_item_result).
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{
		Remaining:     int32(have - 1),
		HasBerserk:    true,
		BerserkGauge:  int32(zerk.Gauge(characterID)),
		BerserkActive: zerk.Active(characterID),
	}).Encode()})
}
