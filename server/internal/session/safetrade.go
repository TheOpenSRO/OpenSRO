package session

import (
	"context"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/jobs"
	"github.com/OpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Safe trade (round 802; docs/protocol/jobs.md "Safe trade"). A trader's
// 1-star caravan of normal goods is safe from player thieves (0x3024,
// jobs.AttackCode) while his _CharTrijobSafeTrade Status is 1. READ:
//
//   - granted when a trader closes a specialty trader's dialog (EndInteraction
//     s:0x510833 with INTERACTMODE 5 or 6 at an NPC with 0xc -> s:0x60e800 /
//     s:0x60e890, jobs.SafeTrade.Decide), with the counted option one of
//     TRADE_SAFETY_NUM grants a server-local day (the count reset at the
//     first specialty-NPC select of a new day, s:0x60e690);
//   - lost when the scale leaves 1 (s:0x5237b0), at the sale of his own
//     goods (s:0x4c8e20), at the pick of a bargain good (s:0x5261ef), at the
//     suit's removal (s:0x4f0dd4);
//   - told by 0x34D5 {u8 status, u8 code[, u8 count, u8 num]} (s:0x51a960):
//     {1, 0x50, count, num} granted, {0, 0x41} the day's limit, {0, 0x40}
//     lost or not eligible; at login {1, 0x51, count, num} or {0, 0x40}
//     (CGObjPC::vslot_391 s:0x4e0020).
//
// OURS, disclosed: the select reply's own safe-trade tail (option, num,
// count after the interaction ids, s:0x52b040) is not sent -- the client
// reads the counts from 0x34D5.
const OpSafeTrade uint16 = 0x34D5

// The shard's _RefShardContentConfig (MEASURED): TRADE_SAFETY_OPTION 0,
// TRADE_SAFETY_NUM 8.
const (
	defaultSafeTradeOption = jobs.SafeTradeCounted
	defaultSafeTradeNum    = 8
)

func safeTradeConfig() (option, num int) {
	d := specialtyNow().d
	option, num = d.SafeOption, d.SafeNum
	if num == 0 && option == 0 && !d.SafeSet {
		return defaultSafeTradeOption, defaultSafeTradeNum
	}
	return option, num
}

// sendSafeTrade sends 0x34D5.
func sendSafeTrade(sess *gateway.Session, status bool, code byte, count, num int) {
	if sess == nil {
		return
	}
	out := []byte{0, code}
	if status {
		out[0] = 1
	}
	if code == jobs.SafeGranted || code == jobs.SafeAtLogin {
		out = append(out, byte(count), byte(num))
	}
	_ = sess.Send(&proto.Packet{Opcode: OpSafeTrade, Data: out})
}

// updateSafeTrade runs f on characterID's trader record under its lock and
// saves a change. It reports whether the record is a trader's.
func updateSafeTrade(ctx context.Context, characterID int64, f func(s *jobs.SafeTrade) bool) (jobs.SafeTrade, bool) {
	d := jobDepsNow()
	if d.store == nil {
		return jobs.SafeTrade{}, false
	}
	lk := jobLock(characterID)
	lk.Lock()
	defer lk.Unlock()
	rec := jobRecord(ctx, characterID)
	if rec.Kind != jobs.KindTrader {
		return rec.Safe, false
	}
	if f(&rec.Safe) {
		if err := saveJobRecord(ctx, d, rec); err != nil {
			d.logger.Warn("jobs: saving safe trade failed", "character", characterID, "err", err)
		}
	}
	return rec.Safe, true
}

// safeTradeOnSelect is s:0x60e690 at a select of an NPC with 0xc: a new
// day resets the count.
func safeTradeOnSelect(ctx context.Context, characterID int64, ids []byte) {
	if !npcHas(ids, npctalk.IDSpecial) {
		return
	}
	option, _ := safeTradeConfig()
	updateSafeTrade(ctx, characterID, func(s *jobs.SafeTrade) bool { return s.DailyReset(time.Now(), option) })
}

// safeTradeOnEnd is EndInteraction's grant (s:0x510833): a trader closing
// a dialog (mode 5 or 6) at an NPC with 0xc.
func safeTradeOnEnd(ctx context.Context, sess *gateway.Session, hub *world.Hub, npcUID uint32, mode byte) {
	if mode != 5 && mode != 6 || hub == nil {
		return
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok || jobStateNow(ctx, e.CharacterID) != jobs.StateTrader {
		return
	}
	pl, found := npcInZone(npcUID, e.Zone)
	if !found || !npcHas(pl.npc.Interact, npctalk.IDSpecial) {
		return
	}
	option, num := safeTradeConfig()
	special := transportHoldsBargainGoods(ctx, e.CharacterID)
	scale := tradeScaleOf(ctx, e.CharacterID, e.Level)
	var code byte
	s, trader := updateSafeTrade(ctx, e.CharacterID, func(s *jobs.SafeTrade) bool {
		code = s.Decide(special, scale, option, num)
		return true
	})
	if trader {
		sendSafeTrade(sess, s.Status, code, s.Count, num)
	}
}

// safeTradeLose clears a trader's Status (the loss triggers) and tells him
// when it was set.
func safeTradeLose(ctx context.Context, characterID int64) {
	was := false
	_, trader := updateSafeTrade(ctx, characterID, func(s *jobs.SafeTrade) bool {
		was = s.Status
		s.Status = false
		return was
	})
	if trader && was {
		if e, ok := cosOwnerEntity(characterID); ok {
			sendSafeTrade(e.Session, false, jobs.SafeLost, 0, 0)
		}
	}
}

// safeTradeAtLogin is vslot_391's report (s:0x4e0020).
func safeTradeAtLogin(ctx context.Context, sess *gateway.Session, characterID int64) {
	if jobDepsNow().store == nil {
		return
	}
	rec := jobRecord(ctx, characterID)
	if rec.Kind != jobs.KindTrader {
		return
	}
	_, num := safeTradeConfig()
	if rec.Safe.Status {
		sendSafeTrade(sess, true, jobs.SafeAtLogin, rec.Safe.Count, num)
	} else {
		sendSafeTrade(sess, false, jobs.SafeLost, 0, 0)
	}
}

// transportHoldsBargainGoods is PC slot 188 -> COS s:0x4d2820: a transport
// holds a 3/3/8/2 good (the TID word 0x146c).
func transportHoldsBargainGoods(ctx context.Context, characterID int64) bool {
	o := ownTransport(characterID)
	if o == nil {
		return false
	}
	_, _, slots := transportBag(ctx, o)
	items := cosWorld.depsNow().items
	for _, sl := range slots {
		if it, err := items.GetItem(ctx, sl.ItemID); err == nil && isSpecialtyItem(it) && it.TypeID4 == 2 {
			return true
		}
	}
	return false
}
