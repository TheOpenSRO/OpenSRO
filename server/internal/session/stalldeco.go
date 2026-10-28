package session

// The stall decorations (round 838): ITEM_MALL_BOOTH_MOB_MANGYANG,
// _BIGEYEGHOST, _EARTHGHOST and ITEM_MALL_BOOTH_SPECIAL_MONSTER_01, TypeID
// 3/3/3/4 -- "When this item is used, the stall will display the decoration
// permanently." READ in SR_GameServer unless marked:
//
//   - The use: CGItemExpendable::vslot_307 (0x49b9f0, DoJob's TypeID3 3
//     branch) case 4 (0x49c0bd..0x49c0e5) calls GObjPC::FUN_004a3f10 with the
//     item's RefObjID; it stores it as the character's _STATICAVATAR.Param1
//     (character.StallDecorationStore) and answers 1, or 2 when the DB
//     update cannot be queued. Nothing else is checked: a stall open or not,
//     the same decoration again -- the new one replaces the old. DoJob then
//     spends the item (LAB_0049af45). No packet but the use's answer.
//   - What a stall shows: FUN_004f0f00 answers the BFI1 override (pc+0x21d4)
//     when set, else Param1. The stall's open broadcast 0x30B8 {u32 owner, u16
//     len + title, u32 decoration} (FUN_004723c0) and a stalling player's
//     spawn record (0x4e5ee0..0x4e5f54: the title, then the u32) carry it; the
//     client draws the decoration item's own .bsr (AssocFileObj128) as the
//     booth, or its race's default stall for 0 (c:0x9dd040; the client's
//     StallBooth).
//   - The BFI1 override ("[BFI1:ITEM_MALL_BOOTH_MOB_MANGYANG,A,2419200]" in
//     the premium packages): the composite use queues a type-5 timed job
//     ('BFI1', the booth's RefObjID) for its seconds; the stall's open asks
//     "Establish as an avatar stall?" (UIIT_MSG_PREMIUM_AVATAR_SHOP_USE) and
//     Yes sends 0x7160 {u32, u32 booth}, whose handler (FUN_00511730 ->
//     FUN_00654790) sets pc+0x21d4 to the booth; closing the stall
//     (FUN_00472cf0) clears it. Not spent, not broadcast, Param1 untouched.
//
// OPEN, the gap: OpenSRO has no player stall (no 0x70B1 open, no 0x30B8, no
// stall window), so nothing yet shows the decoration in the world; the state
// is kept for the stall to read (StallDecorationOf), and the client's model
// choice is built (StallBooth). The BFI1 grant is kept in memory until its
// time runs out (GrantStallDecoration); with no stall there is no open to
// apply it at, so StallDecorationOf answers it directly while it lasts
// (OURS).

import (
	"context"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// stallDecorationKind is DoJob's TypeID3 3 case 4.
const stallDecorationKind = 4

// isStallDecoration reports a 3/3/3/4 row.
func isStallDecoration(it *refdata.Item) bool {
	return isScroll(it, stallDecorationKind)
}

// stallGrant is one BFI1 grant: the booth and when it ends.
type stallGrant struct {
	refObjID int
	until    time.Time
}

// stallGrants are the BFI1 grants in force, by character.
var stallGrants = struct {
	sync.Mutex
	m map[int64]stallGrant
}{m: map[int64]stallGrant{}}

// stallClock is the grants' clock; a test may replace it.
var stallClock = time.Now

// GrantStallDecoration is the BFI1 entry's grant (round 838, for the premium
// packages' composite use): characterID's stall shows the booth refObjID
// until `until`, over its own decoration, without touching it. A later grant
// replaces an earlier one; a zero refObjID or a past `until` withdraws it.
func GrantStallDecoration(characterID int64, refObjID int, until time.Time) {
	stallGrants.Lock()
	defer stallGrants.Unlock()
	if refObjID == 0 || !until.After(stallClock()) {
		delete(stallGrants.m, characterID)
		return
	}
	stallGrants.m[characterID] = stallGrant{refObjID: refObjID, until: until}
}

// StallDecorationOf is FUN_004f0f00: the booth characterID's stall shows --
// a BFI1 grant still in force, else the decoration item last used, else 0
// (the race's default stall).
func StallDecorationOf(ctx context.Context, chars character.Store, characterID int64) int {
	stallGrants.Lock()
	g, ok := stallGrants.m[characterID]
	if ok && !g.until.After(stallClock()) {
		delete(stallGrants.m, characterID)
		ok = false
	}
	stallGrants.Unlock()
	if ok {
		return g.refObjID
	}
	if ds, isDS := chars.(character.StallDecorationStore); isDS {
		if v, err := ds.StallDecoration(ctx, characterID); err == nil {
			return v
		}
	}
	return 0
}

// useStallDecoration is case 4: the decoration stored, the item spent.
func useStallDecoration(ctx context.Context, sess *gateway.Session, chars character.Store, inv inventory.Store,
	characterID int64, it *refdata.Item, held inventory.Slot, have int) error {
	refuse := func(reason string) error {
		// FUN_004a3f10's 0 is the use's 2, which category 1 shows nothing
		// for; the words are OpenSRO's.
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: reason, Code: ScrollErrUnknownOption}).Encode()})
	}
	ds, ok := chars.(character.StallDecorationStore)
	if !ok {
		return refuse("the stall decoration cannot be kept here")
	}
	old, err := ds.StallDecoration(ctx, characterID)
	if err != nil {
		return refuse("using failed")
	}
	if err := ds.SetStallDecoration(ctx, characterID, int(it.ID)); err != nil {
		return refuse("using failed")
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		// FUN_004a3f10 puts the old Param1 back when its update fails; the
		// item kept, the decoration is too.
		_ = ds.SetStallDecoration(ctx, characterID, old)
		return refuse("using failed")
	}
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{
		Remaining: int32(have - 1), ItemID: uint32(it.ID),
	}).Encode()})
}
