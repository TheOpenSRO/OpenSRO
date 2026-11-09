package session

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 864: the resurrection scroll as a premium's free fill (the 100 %
// resurrection scroll a Premium Gold Time grants once a day).
//
// READ, SR_GameServer.exe:
//
//   - CUsedItemLimit::vslot_007 (s:0x654080), the fill's use: a dead user
//     (life state 2, vtable +0xf8) is refused 0x1889 unless the fill row is
//     3/3/13/6 (TypeID3 13, TID & 0xf800 == 0x3000); the 3/3/13/6 branch
//     (s:0x6542d4) calls FUN_0049ff20(Param3 (ref+0x2e0), Param2 (+0x2c0)),
//     and on 1 the job's count goes down by one (FUN_006538d0(1, n - 1)): the
//     grant is NOT ended at 0.
//   - FUN_0049ff20 (s:0x49ff20..0x4a00b0), the scroll's own effect (also
//     UseByKind case 6): a user whose life state is not 2 is refused 0x1887
//     (UIIT_MSG_STRGERR_ONLY_THE_DEAD_CAN_USE_RESURRECT_SCROLL). Otherwise
//     lost = |pc+0x1ce0| (the last death's EXP loss), GObjPC::Revive(1)
//     (0x4df290: life state 1, one HP), then f = Param3 / 100.0 (0xb45af0 =
//     100.0), halved (0xb45c50 = 0.5) when the byte at (pc+0x30)+0xc is 2,
//     and n = lost x f rounded UP (a fraction above 0xb45c84 = 1e-6 adds 1);
//     n > 0 goes back through vtable +0x170 (0, n, ...), the EXP add. Then
//     HP and MP: Param2 / 100.0 of GetMaxHP (+0x110) and GetMaxMP (+0x114),
//     each truncated (0x9fbb40), ADDED through ApplyHPMPDelta(pc, hp, mp, 8)
//     (0x4a86a0).
//   - The item rows (MEASURED, the shard's _RefObjItem): every 3/3/13/6 has
//     Param2 100 and Param3 the EXP share -- 100 (the 100 % scrolls), 60, or
//     0 (ITEM_MALL_RESURRECTION_SCROLL).
//
// READ, sro_client.exe: the composite window's button (c:0x7afddf..0x7b035d)
// tests a 3/3/13/6 fill against the player's alive bit (DAT_00eef5ec+0x65c &
// 1) first: alive, it posts itself 0xB04C {2, 0x1887} -- the line "Can use it
// only in the state of death." (MEASURED) -- sends nothing and leaves the
// window open. So the server's 0x1887 is only reached by a client that skips
// the test.
//
// OURS / not modelled: the halving under (pc+0x30)+0xc == 2 (the byte was not
// identified; INFERRED a world kind); the revive's protection and berserk end
// are GObjPC::Revive's (ReviveHandler's in place); the answer is OpenSRO's
// OpReviveResult and stats push, as every revive's.

// lastDeathLoss is pc+0x1ce0 (round 864): the EXP the character's last death
// took, by character. A resurrection scroll gives back its share. Set at each
// death that takes EXP (monsterStrike's penalty), kept until the next.
var lastDeathLoss sync.Map // int64 -> int64

func noteDeathLoss(characterID, loss int64) {
	if loss < 0 {
		loss = 0
	}
	lastDeathLoss.Store(characterID, loss)
}

func deathLossOf(characterID int64) int64 {
	if v, ok := lastDeathLoss.Load(characterID); ok {
		return v.(int64)
	}
	return 0
}

// resurrectionOnlyDeadRefusal is 0x1887's text (MEASURED, the line the
// original client shows for UIIT_MSG_STRGERR_ONLY_THE_DEAD_CAN_USE_RESURRECT_SCROLL).
const resurrectionOnlyDeadRefusal = "Can use it only in the state of death."

// isResurrectionScroll is the 3/3/13/6 test (TypeID3 13, TID & 0xf800 ==
// 0x3000).
func isResurrectionScroll(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 13 && it.TypeID4 == 6
}

// resurrectionExp is n: the share of the last death's loss a scroll with
// this Param3 gives back, rounded up.
func resurrectionExp(lost int64, expPct int) int64 {
	if lost < 0 {
		lost = -lost
	}
	if lost == 0 || expPct <= 0 {
		return 0
	}
	f := float32(float64(expPct) / 100.0)
	v := float32(lost) * f
	n := int64(v)
	if float64(v)-float64(n) > 1e-6 {
		n++
	}
	return n
}

// resurrectionPools is the HP and MP the scroll ADDS: trunc(max x Param2 /
// 100), each.
func resurrectionPools(maxHP, maxMP, pct int) (hp, mp int) {
	if pct <= 0 {
		return 0, 0
	}
	f := float32(float64(pct) / 100.0)
	return int(math.Trunc(float64(float32(maxHP) * f))), int(math.Trunc(float64(float32(maxMP) * f)))
}

// reviveByScroll is FUN_0049ff20 on a dead character: the life state first
// (under the kill lock, as every revive), Revive(1)'s one HP plus the scroll's
// share of the maximum, the MP added, the EXP given back. It returns the
// character as it stands, its MP and the EXP given back.
func reviveByScroll(ctx context.Context, chars character.Store, deps RegenDeps, hub *world.Hub, characterID int64, hpPct, expPct int) (*character.Character, int, int64, error) {
	if hub == nil {
		return nil, 0, 0, errNotDead
	}
	// Round 873: the hub the character is in, whichever world.
	hub = hubOfChar(hub, characterID)
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok || e.Life != world.LifeDead {
		return nil, 0, 0, errNotDead
	}
	l := killLock(characterID)
	l.Lock()
	defer l.Unlock()
	if !hub.SetLifeState(characterID, world.LifeDead, world.LifeAlive, time.Time{}) {
		return nil, 0, 0, errNotDead
	}
	dropResurrectOffer(characterID)
	stillDead := func(err error) (*character.Character, int, int64, error) {
		hub.SetLifeState(characterID, world.LifeAlive, world.LifeDead, e.DiedAt)
		return nil, 0, 0, fmt.Errorf("session: scroll revive of %d: %w", characterID, err)
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return stillDead(err)
	}
	addHP, addMP := resurrectionPools(c.MaxHP(), c.MaxMP(), hpPct)
	hp, err := chars.Heal(ctx, characterID, 1+addHP, c.MaxHP())
	if err != nil {
		return stillDead(err)
	}
	c.HP = hp
	metrics.PlayerRevive()
	motions.stand(characterID, time.Now())
	mpNow := 0
	if deps.Mana != nil {
		mpNow = deps.Mana.Restore(characterID, c.MaxMP(), addMP)
	}
	back := resurrectionExp(deathLossOf(characterID), expPct)
	if back > 0 {
		unlock := character.LockLeveling(characterID)
		if fresh, err := chars.GetByID(ctx, characterID); err == nil {
			c.Level, c.Exp, c.StatPoints, c.Str, c.Int = fresh.Level, fresh.Exp, fresh.StatPoints, fresh.Str, fresh.Int
		}
		if err := chars.SetLeveling(ctx, characterID, c.Level, c.Exp+back, c.StatPoints, c.Str, c.Int); err != nil {
			back = 0
		} else {
			c.Exp += back
		}
		unlock()
	}
	// Round 865: a guardian's honor buffs come back with it (academylive.go).
	academyRevived(ctx, characterID)
	return c, mpNow, back, nil
}

// resurrectDeps are what a resurrection fill's answer needs (the stats push,
// the mana tracker, the berserk end): cmd/server sets them with the revive's.
var resurrectDeps struct {
	mu   sync.Mutex
	deps RegenDeps
}

// SetResurrectDeps names the deps a resurrection fill revives with (round
// 864): the same RegenDeps ReviveHandler gets.
func SetResurrectDeps(d RegenDeps) {
	resurrectDeps.mu.Lock()
	defer resurrectDeps.mu.Unlock()
	resurrectDeps.deps = d
}

func resurrectDepsNow() RegenDeps {
	resurrectDeps.mu.Lock()
	defer resurrectDeps.mu.Unlock()
	return resurrectDeps.deps
}

// useResurrectionFill spends one use of a resurrection scroll's grant g: the
// owner must be dead (0x1887 otherwise), is revived where it lies with the
// scroll's pools and EXP, and the count goes down by one (the grant stays at
// 0). The answer: the composite result, the revive's own, the state.
func useResurrectionFill(ctx context.Context, sess *gateway.Session, chars character.Store, hub *world.Hub, keeper *CompositeKeeper,
	characterID int64, fill *refdata.Item, g *compositeGrant, req *CompositeUseRequest, fail func(string, int64) error) error {
	// Round 869: the session's own world (gameworlds.go).
	hub = hub.For(sess)
	if !deadBySession(hub, sess) {
		return fail(resurrectionOnlyDeadRefusal, req.ItemID)
	}
	deps := resurrectDepsNow()
	c, mpNow, back, err := reviveByScroll(ctx, chars, deps, hub, characterID, fill.RestoreHPPct, fill.RestoreMP)
	if errors.Is(err, errNotDead) {
		return fail(resurrectionOnlyDeadRefusal, req.ItemID)
	}
	if err != nil {
		return fail("using failed", req.ItemID)
	}
	keeper.setRemaining(characterID, req.ItemID, g.remaining-1)
	// GObjPC::Revive's SetBodyMode(2, ...): the berserk ends and the
	// protection starts (ReviveHandler's in-place revive).
	endBerserk(hub, deps.Berserk, characterID)
	if arrivalGuardOn.Load() && !arrivalHeld(characterID) {
		startProtection(hub, characterID, sess, "resurrection scroll")
	}
	slog.Info("composite: resurrection fill", "character_id", characterID, "item", fill.ID, "hp", c.HP, "mp", mpNow,
		"exp_back", back, "hp_pct", fill.RestoreHPPct, "exp_pct", fill.RestoreMP, "left", g.remaining-1)
	if err := sess.Send(&proto.Packet{Opcode: OpCompositeUseResult, Data: (&CompositeUseResult{
		ItemID: req.ItemID, Remaining: int32(g.remaining - 1)}).Encode()}); err != nil {
		return err
	}
	if err := sendRevived(ctx, sess, c, mpNow, deps); err != nil {
		return err
	}
	zerk := deps.Berserk
	if zerk == nil {
		return nil
	}
	return sendCompositeState(sess, keeper, zerk, characterID, useItemClock())
}

// resurrectionScrollAt reports whether the bag slot of characterID holds a
// resurrection scroll (round 873): the one item a dead user may use.
func resurrectionScrollAt(ctx context.Context, inv inventory.Store, items ItemLookup, characterID int64, slot int) bool {
	if inv == nil || items == nil {
		return false
	}
	slots, err := inv.List(ctx, characterID)
	if err != nil {
		return false
	}
	for _, sl := range slots {
		if sl.Index == slot && sl.Quantity > 0 {
			it, err := items.GetItem(ctx, sl.ItemID)
			return err == nil && isResurrectionScroll(it)
		}
	}
	return false
}

// useResurrectionScroll is a resurrection scroll used from the bag (round
// 873; UseByKind case 6 -> FUN_0049ff20, READ in this file's header): the user
// must be dead (0x1887 otherwise), is revived where it lies -- in whatever
// world it lies in -- with the row's pools (Param2 % of each maximum) and its
// share (Param3 %) of the EXP the death took, and one scroll is spent. The
// answer: the use's result, then the revive's, as the composite fill's.
// MEASURED (a 100 % scroll used dead inside a Forgotten World layer): the
// character comes back on its spot in the layer, alive, at full HP and MP,
// with the lost EXP back, protected for 6 s, and the item's effect is shown.
func useResurrectionScroll(ctx context.Context, sess *gateway.Session, fail func(string) error, inv inventory.Store,
	chars character.Store, hub *world.Hub, characterID int64, it *refdata.Item, held inventory.Slot, have int) error {
	hub = hub.For(sess)
	if !deadBySession(hub, sess) {
		return fail(resurrectionOnlyDeadRefusal)
	}
	now := useItemClock()
	if it.CooltimeMs > 0 && !itemCooldowns.ReadyItem(characterID, it.ID, it.CooltimeGroup, now) {
		return fail(reuseDelayRefusal)
	}
	deps := resurrectDepsNow()
	c, mpNow, back, err := reviveByScroll(ctx, chars, deps, hub, characterID, it.RestoreHPPct, it.RestoreMP)
	if errors.Is(err, errNotDead) {
		return fail(resurrectionOnlyDeadRefusal)
	}
	if err != nil {
		return fail("using failed")
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		slog.Error("resurrection scroll: revived, but the scroll was not spent", "character_id", characterID, "item", it.ID, "err", err)
	}
	if it.CooltimeMs > 0 {
		itemCooldowns.ArmItem(characterID, it.ID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, now)
	}
	endBerserk(hub, deps.Berserk, characterID)
	if arrivalGuardOn.Load() && !arrivalHeld(characterID) {
		startProtection(hub, characterID, sess, "resurrection scroll")
	}
	slog.Info("resurrection scroll", "character_id", characterID, "item", it.ID, "hp", c.HP, "mp", mpNow,
		"exp_back", back, "hp_pct", it.RestoreHPPct, "exp_pct", it.RestoreMP, "left", have-1)
	if err := sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(have - 1)}).Encode()}); err != nil {
		return err
	}
	return sendRevived(ctx, sess, c, mpNow, deps)
}
