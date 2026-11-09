package session

import (
	"context"
	"fmt"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/statuseffect"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The cure pills (round 786): TypeID 3/3/2/x, read in SR_GameServer.exe
// (docs/protocol/cure_pills.md has the census and every address).
//
// CGItemExpendable::DoJob (0x49aca0) case 2 sends TypeID4 7 -- the pets'
// pills, ITEM_COS_P_CURE_ALL_* -- to slot 327 (0x51c, the pet path) and every
// other TypeID4 to slot 308 (0x4d0, 0x49b710), the same slot a recovery
// potion takes. Slot 308's TypeID3-2 branch (0x49b765..0x49b897):
//
//  1. the kind's reuse lock, GObjPC::FUN_004eb410 (0x49b779): TypeID3 2 maps
//     TypeID4 1 to bit 0x100 and every other kind to 0x40 (0x4eb49b..0x4eb4ab
//     `sub al,1; neg al; sbb eax,eax; and eax,0xffffff40; add eax,0x100`),
//     and answers whether that bit is clear in the BYTE at [pc+0x30]+8
//     (0x4eb42b `movzx edx,BYTE PTR [ecx+0x8]`). A zero answer is 0x185b and
//     the pill is kept. Bit 0x100 is outside that byte, so the kind-1 pill's
//     lock never refuses (READ; the engine's own quirk): its reuse is the
//     row's COOLTIME descriptor, which Item_HandleUseItem asks before DoJob.
//  2. TypeID4 1 -- the purification pills, ITEM_ETC_CURE_RANDOM_* (and the
//     quest's ITEM_QNO_TQ_MAGICPOWDER_3_02): FUN_004a56c0(holder, 0, 0,
//     curl = {Param1, Param3, Param2}, rcur = {1}) (0x49b7f4..0x49b85d) --
//     ONE random state among the held ones Param1's mask names, ended at
//     chance Param3, divided by (level - Param2) above the level cap Param2.
//     The lock's delay is the float32 20.1 at 0xb461b4 (0x49b862).
//  3. any other TypeID4 -- the universal pills, ITEM_ETC_CURE_ALL_*
//     (TypeID4 6): FUN_0049ac50 copies Param1..6 (+0x2a0..+0x340) and
//     FUN_004a56c0(holder, that block, 0, 0, 0) winds each held elemental
//     state (slots 0..5) back by its own Param x the slot's unit (statuseffect
//     CureRule.Elem). The lock's delay is the float32 1.1 at 0xb461b8
//     (0x49b7dd).
//  4. FUN_004e0ab0 arms the lock (0x49b884) and the answer is 1 whatever was
//     cured (0x49b88c): DoJob then spends the pill, so a pill taken with
//     nothing to cure is used up, as a potion at full HP is.
//
// OPEN, refused with the restores-nothing reason as before: the pets' pills
// (slot 327; OpenSRO has no pet states) and the mall's cure bags
// ITEM_MALL_CURE_SUPERSET_*_BAG (TypeID4 8, every Param -1) -- DoJob would
// send them to slot 308's universal branch, but whether Item_HandleUseItem
// opens a bag before DoJob was not read.
const (
	// cureTypeID3 is TypeID3 2 under TypeItem/TypeExpendable: DoJob's case 2.
	cureTypeID3 = 2
	// curePetKind is TypeID4 7, DoJob's `(tid & 0xf800) == 0x3800` test.
	curePetKind = 7
	// cureBagKind is TypeID4 8, the mall's cure bags (OPEN, see above).
	cureBagKind = 8
	// curePurificationKind is TypeID4 1, slot 308's `cmp al,1` (0x49b798).
	curePurificationKind = 1

	// cureLockPurification / cureLockUniversal are FUN_004eb410's bits.
	cureLockPurification uint32 = 0x100
	cureLockUniversal    uint32 = 0x40
	// cureLockGateMask is the byte the gate reads (0x4eb42b movzx BYTE).
	cureLockGateMask uint32 = 0xff

	// cureDelayPurification is the float32 20.1 at .rdata 0xb461b4 (bytes
	// 33 33 a1 41; 20.1000004 s).
	cureDelayPurification = 20100 * time.Millisecond
	// cureDelayUniversal is the float32 1.1 at .rdata 0xb461b8 (the absolute
	// potion's China delay, potionReuseAbsoluteChina).
	cureDelayUniversal = 1100 * time.Millisecond
)

// isCurePill reports whether slot 308 cures with this item (TypeID 3/3/2,
// TypeID4 neither the pets' 7 nor the OPEN bag 8).
func isCurePill(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == cureTypeID3 && it.TypeID4 != curePetKind && it.TypeID4 != cureBagKind
}

// curePillRule is slot 308's call for the pill: the rule FUN_004a56c0 runs,
// the lock bit FUN_004eb410 gives it and the delay FUN_004e0ab0 arms.
func curePillRule(it *refdata.Item) (rule statuseffect.CureRule, lockBit uint32, delay time.Duration) {
	if it.TypeID4 == curePurificationKind {
		return statuseffect.CureRule{
			HasCurl:    true,
			CurlMask:   uint32(it.RestoreHP),    // Param1 (+0x2a0)
			CurlChance: uint32(it.RestoreMP),    // Param3 (+0x2e0)
			CurlLevel:  uint32(it.RestoreHPPct), // Param2 (+0x2c0)
			Rcur:       1,
		}, cureLockPurification, cureDelayPurification
	}
	return statuseffect.CureRule{
		HasElem: true,
		Elem: [6]uint32{
			uint32(it.RestoreHP), uint32(it.RestoreHPPct), uint32(it.RestoreMP),
			uint32(it.RestoreMPPct), it.Param5, it.Param6,
		},
	}, cureLockUniversal, cureDelayUniversal
}

// useCurePill runs a cure pill for characterID out of bag slot held: the
// item cooltime (Item_HandleUseItem, before DoJob), the kind lock, the spend,
// the cure on the character's states (statusFX.cureCharacter, which tells
// the view when the mask changed: the client clears the icons and the look
// from that OpObjectStatus), the lock and the cooltime armed, and the reply
// with the stack left. MaxHP 0 tells the client to leave its bars alone.
func useCurePill(ctx context.Context, sess *gateway.Session, fail func(string) error, inv inventory.Store,
	hub *world.Hub, locks *itemCooldownTracker, characterID int64, it *refdata.Item, held inventory.Slot, have int, now time.Time) error {
	// Round 869: the session's own world (gameworlds.go).
	hub = hub.For(sess)
	if it.CooltimeMs > 0 && !itemCooldowns.ReadyItem(characterID, it.ID, it.CooltimeGroup, now) {
		return fail(reuseDelayRefusal)
	}
	rule, bit, delay := curePillRule(it)
	if gate := bit & cureLockGateMask; gate != 0 && !locks.Ready(characterID, gate, now) {
		return fail(reuseDelayRefusal)
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		return fail("using failed")
	}
	before := statusFX.characterMask(characterID)
	statusFX.cureCharacter(hub, characterID, rule)
	after := statusFX.characterMask(characterID)
	if it.CooltimeMs > 0 {
		itemCooldowns.ArmItem(characterID, it.ID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, now)
	}
	locks.Arm(characterID, bit, delay, now)
	statusFX.tracef("status: character %d took cure pill %d (%s): mask %#x -> %#x", characterID, it.ID, it.CodeName, before, after)
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(have - 1)}).Encode()})
}

// characterMask is a character's abnormal-state mask now (0 with no states).
func (s *statusRuntime) characterMask(id int64) uint32 {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h := s.pcs[id]; h != nil {
		return h.Mask()
	}
	return 0
}

// gmAfflict is /afflict's hook (round 786, OURS: a test tool): one status run
// landed on the character without a roll, as applyToCharacter lands a
// monster's, and the view told. deps are the stores the status pass reads a
// character's life and deals its ticks through (applyToCharacter binds a
// monster's; with none bound yet the pass would take the character for gone
// and drop its states).
type gmAfflict struct {
	hub  *world.Hub
	deps strikeDeps
}

func (g gmAfflict) Afflict(characterID int64, code string, values []int) (uint32, error) {
	now := statusFX.ms(time.Now())
	recs := statuseffect.ResolveAll([]statuseffect.Run{{Code: code, Values: values}}, statuseffect.Target{}, now,
		func(int, int) bool { return true })
	if len(recs) == 0 {
		return 0, fmt.Errorf("%q with %v lands no state", code, values)
	}
	statusFX.mu.Lock()
	if statusFX.sdeps.chars == nil {
		statusFX.sdeps = g.deps
	}
	h := statusFX.pcs[characterID]
	if h == nil {
		h = &statuseffect.Holder{}
		statusFX.pcs[characterID] = h
	}
	for _, r := range recs {
		h.Put(r)
	}
	msg := &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: characterID, Mask: h.Mask(), Levels: h.Levels()}
	statusFX.mu.Unlock()
	broadcastStatus(g.hub, "", msg)
	return msg.Mask, nil
}
