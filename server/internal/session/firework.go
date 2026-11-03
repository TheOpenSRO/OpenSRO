package session

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// The fireworks (round 860): ITEM_ETC_FIREWORK_* , TypeID 3/3/6/1 -- ten rows
// in the archive's itemdata (MEASURED: BOOMB_R/G/B/V, SPIN, SPRAY, CHAINBOMB,
// STAR_SHOWER, CROSS_STAR, TADPOLE). Before this round OpenSRO refused them
// ("that cannot be used"), so no client ever saw one.
//
// READ, SR_GameServer.exe. Item_HandleUseItem (s:0x510980) calls the item's
// vtable slot 0x4c8 (s:0x510f55 `mov edx,[edx+0x4c8]`, called at s:0x510f68), which for every
// CGItemExpendable is CGItemExpendable::DoJob (s:0x49aca0; its vtable at
// s:0xaeb2b4, slot 306 at s:0xaeb77c). DoJob switches on TypeID3 through the
// byte table at s:0x49af98: TypeID3 6 is case 3, s:0x49ae83:
//
//   - TypeID4 2 (ITEM_FORT_SHOCK_BOMB, the fortress war's bomb) goes to the
//     item's slot 0x524, the fortress use -- not modelled here (no fortress
//     war), so that one stays refused;
//   - any other TypeID4 tests the owner's byte [owner+0x30]+0x11 against 1
//     (s:0x49aea2, the same test UseByKind opens with: 0x186b
//     CANT_OPERATE_REQUESTED_JOB_DURING_LOGOUT otherwise -- OpenSRO has no
//     logout state, as useExpansion records) and answers 1 with nothing else
//     done (s:0x49aeb5 `mov [esp+0x1c],ebx` with ebx 1);
//   - then DoJob's common tail (s:0x49af45) takes one from the stack.
//
// So the server's whole part is: accept, spend one, reply 0xB04C, and -- as
// for every accepted use -- send 0x305C {uid, ref} to the 3 x 3
// (useitem_effect.go). The show is the client's (its CIParticleObj, c:0x9c5340
// / 0x9c5460; client/scripts/effects/firework.gd). The handler's generic
// reuse delay (ItemCooldowns, s:0x510d78 `cmp [edi+0x524],0`, only for a row with a COOLTIME
// descriptor at ref+0x524) applies as to any item; MEASURED: no firework row
// carries one, so there is none.
const fireworkTypeID3 = 6

// fireworkShockBomb is TypeID4 2 under 3/3/6: the fortress bomb DoJob hands
// to slot 0x524 (READ, s:0x49ae94 `sub eax,0x2 ; je`).
const fireworkShockBomb = 2

// isFirework reports a firework: 3/3/6 and not the fortress bomb.
func isFirework(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == fireworkTypeID3 && it.TypeID4 != fireworkShockBomb
}

// useFirework runs DoJob's TypeID3 6 case for characterID's firework in held:
// the reuse delay a COOLTIME row would have, then one taken from the stack
// and the success reply. The 0x305C follows from announceUses.
func useFirework(ctx context.Context, sess *gateway.Session, fail func(string) error, inv inventory.Store,
	characterID int64, it *refdata.Item, held inventory.Slot, have int, now time.Time) error {
	if it.CooltimeMs > 0 && !itemCooldowns.ReadyItem(characterID, it.ID, it.CooltimeGroup, now) {
		return fail(reuseDelayRefusal)
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		return fail("using failed")
	}
	if it.CooltimeMs > 0 {
		itemCooldowns.ArmItem(characterID, it.ID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, now)
	}
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(have - 1)}).Encode()})
}
