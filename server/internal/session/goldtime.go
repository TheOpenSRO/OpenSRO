package session

import (
	"context"
	"encoding/binary"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The premium "Gold Time" (round 838): a 3/3/13/4 row such as
// ITEM_PRE_GOLTAM_4W (9278), started by its own use (UseByKind 0x49c2b0
// case 4) or by a composite's [UIU1:<it>] (the mall's Premium GoldTime PLUS,
// 35567). A type-3 timed job, CTJ_PremiumKeeper (vtable 0xb04fbc, start
// vslot_012 0x6524b0, Tick 0x6529d0). READ, SR_GameServer.exe:
//
//   - One at a time: any running type-3 job refuses 0x1894 (FUN_0049a400 /
//     FUN_00656570 match the type only; 0x49c642..0x49c6c2, and the
//     composite's pre-check 0x49f44a..0x49f47d). Nothing is extended. The
//     direct use also refuses 0x1894 when the character's fatigue factor is
//     not 1.0 (PC+0x2280, the Vietnam play-time rule) -- OpenSRO has no
//     fatigue, so the factor is always 1.0.
//
//   - The row's Params: P1 the period, days = P1 / 86400 (0x652761, 28 for
//     2,419,200); P2 param 0x101, the death EXP loss reduced by P2 % for the
//     whole period (0x652573; read on the three death paths 0x4e68dd,
//     0x4e6b7e, 0x4e6e6c); P3 the daily gold time in ms (0x652794: 10,800,000
//     = 3 h); P4 param 0x100, +P4 % EXP; P5 param 0x102, +P5 % SP. The award
//     (CGObjPC::vslot_420 0x4ea6a0, 0x4ea6f3..0x4ea93a) adds
//     trunc(E * (p256 - p186) / 100.0) of the award E after its multiplier,
//     beside the rate term -- as the growth pet's p186 (petgrowth.go).
//
//   - The days roll every 86,400 s of the job's own day clock (Tick
//     0x652aac): with two or more days left a day is taken, the old "today"
//     becomes "previous day" and today is P3 again -- unused time carries one
//     day; on the last day days go to 0, previous day = today, today = 0, and
//     0x101 is removed. The gold time drains only while the owner is in the
//     battle state (keeper slot 0x3c = chardata +0xd, vslot_015 0x6537a0) and
//     the job is not paused, the previous day's first; with both at 0 params
//     0x100 / 0x102 go. The job ends when days and both halves are 0.
//
//   - The stored words (round 839; the _TIMEDJOB row through
//     CInstanceTimedJob's getters 0x70..0x80 = fields +0x28..+0x38, the
//     column order _ADDTIMEDJOB's format string gives at s:0x650980):
//     TimeToKeep = into << 8 | days (into: the seconds into the job's day,
//     advanced only by the keeper's Tick, so only while the owner is in the
//     world); Data1 = the start, __time32 (set once, 0x6524b0's first-start
//     branch); Data2 = prev << 16 | today; Data3 = extra days; Data4 = the
//     paused flag. The creator (UseByKind case 4, s:0x49c69d..0x49c6b4) passes
//     TimeToKeep = P1 and every Data word 0; the first start turns TimeToKeep
//     into P1 / 86400 days.
//
//   - At a load (vslot_012's second branch, s:0x6525bf..0x6526fe) the day
//     clock catches up with the wall clock:
//
//     R = (Data3 + 1) * 86400 + P1 - (now - Data1)   the time left by the clock
//     T = (days + 1) * 86400 - into                  the time left by the words
//     R <= 0: TimeToKeep = 0, Data2 = 0 -- no 0x3206 at the load; the first
//     Tick ends the job (the 0x66 log, the end form) and reaps it
//     T >= R and T - R > 0: into += T - R, then one roll per whole 86,400
//     in into (the same roll as the Tick's, without its 0x101
//     removal), into keeps the rest
//     else:   nothing (the words are ahead of the clock)
//
//     then 0x3206 goes out. So the days an owner was away (and a server
//     restart's downtime) are consumed, rolled on the job's own boundaries
//     (start + k days, not midnight); the "+1" is the carry day after the
//     period (P1 + 1 day after the start every half is 0). Data3 is the only
//     way to lengthen a running job: no server code writes it (the keeper's
//     vslot_012, Tick and pause FUN_00653560 never call the +0x40 setter;
//     the only type-3 creator passes 0), so it is an operator's column.
//
//   - The pause: the client's 0x34BF {u8 3, u8 wantPaused} (FUN_0051a840 ->
//     FUN_00653560). No gold time left answers code 0, a return scroll
//     working 0x18fc, a resume in the battle state 0x18fb, each as 0x3206
//     {3, 2, u16 code, u32 ref}; a request for the state it is in is a kick
//     (FUN_004df050(4); OURS: ignored). A pause takes effect after 20 s of
//     ticks (0xb45b20) and removes 0x100 / 0x102; a resume on the next tick.
//
//   - The wire, 0x3206 {u8 3, u8 1, u32 ref, u32 the period's seconds left
//     (days * 86400 - seconds into the day), u32 prev << 16 | today, u8
//     paused}, sent at the start, every 600 s (0xb46198), at a day roll and a
//     pause or resume; the end {3, 1, ref, 0, 0}. The client
//     (NetProcessInNavAndSkill 0x8a5360) shows it on CIFMagicStateBoard.
//
// OURS: the job is kept in timedjob.Store (retail's _TIMEDJOB) and ticks
// while its owner is in the world; the row keeps retail's words (V1 =
// TimeToKeep, V2 = Data2, V3 = Data4, Start = Data1). Data3 is not kept
// (always 0: nothing in the engine sets it). A round-838 row (V1 = days,
// V4 = its old roll count) loads as into 0, which catches up to the same
// day; its V4 is ignored. A crash loses the gold time drained since the
// last save (every 60 s, OURS; when retail writes its instance words back is
// not read). OpenSRO has no death
// EXP loss for a player, so P2 is carried and read by nothing (disclosed).
// The growth pet's share of the owner's EXP % (FUN_004fcb00's param_4,
// flag-gated) is not modelled.
const (
	OpGoldTime      uint16 = 0x3206 // server -> client: the premium's state
	OpGoldTimePause uint16 = 0x34BF // client -> server: pause or resume

	goldTimeJobType          byte   = 3
	goldTimeSubState         byte   = 1
	goldTimeSubRefusal       byte   = 2
	goldTimeErrNoTime        uint16 = 0
	goldTimeErrResume        uint16 = 0x18fb // UIIT_STT_GOLDTIME_PAUSE_ERROR: a resume in battle
	goldTimeErrScroll        uint16 = 0x18fc // a return scroll is working
	goldTimeDaySeconds              = 86400
	goldTimePauseDelay              = 20 * time.Second
	goldTimePushPeriod              = 600 * time.Second
	goldTimeSavePeriod              = 60 * time.Second
	goldTimeDurationJobInUse        = 0x1894
)

// isPremiumTime reports a 3/3/13/4 row (FUN_004929c0: 3/3/13 and TID &
// 0xf800 == 0x2000).
func isPremiumTime(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 13 && it.TypeID4 == 4
}

// goldTime is one character's running premium.
type goldTime struct {
	charID  int64
	refID   int64
	started time.Time // Data1
	// into is the seconds into the job's day (TimeToKeep >> 8), advanced by
	// the tick while the owner is in the world and by the load's catch-up.
	into   int
	days   int // the period's days left (TimeToKeep & 0xff)
	today  int // seconds
	prev   int // seconds carried from the day before
	paused bool
	// extDays is Data3, the extra days in the load's clock term (always 0
	// here: nothing sets it, see above).
	extDays int
	// period is the row's P1 in seconds (the load's clock term).
	period int64
	// pauseAt is a pending pause's moment; resume a pending resume.
	pauseAt time.Time
	resume  bool
	// The row's params.
	daily, expPct, spPct, lossPct int
	lastPush, lastSave            time.Time
	// lastTick is the moment into was last advanced to.
	lastTick time.Time
}

func (g *goldTime) left() int { return g.today + g.prev }

// bonusOn is whether params 0x100 / 0x102 are applied now.
func (g *goldTime) bonusOn() bool { return !g.paused && g.left() > 0 }

// periodLeft is the 0x3206 period word: days * 86400 - into, 0 on the last
// day (the start and the load s:0x6527f0, the Tick's 600 s push).
func (g *goldTime) periodLeft() uint32 {
	if g.days == 0 {
		return 0
	}
	v := g.days*goldTimeDaySeconds - g.into
	if v < 0 {
		v = 0
	}
	return uint32(v)
}

// rollOnce is one day roll (the Tick s:0x652aac, the load s:0x652690).
func (g *goldTime) rollOnce() {
	if g.days >= 2 {
		g.days--
		g.prev, g.today = g.today, g.daily
		return
	}
	g.days = 0
	g.prev, g.today = g.today, 0
}

// advance is the Tick's day clock: the whole seconds since lastTick go into
// into, and a day rolls when into passes 86,399 (0x1517f). It reports
// whether a day rolled.
func (g *goldTime) advance(now time.Time) bool {
	if g.lastTick.IsZero() {
		g.lastTick = now
		return false
	}
	secs := int(now.Sub(g.lastTick) / time.Second)
	if secs <= 0 {
		return false
	}
	g.lastTick = g.lastTick.Add(time.Duration(secs) * time.Second)
	g.into += secs
	rolled := false
	for g.into >= goldTimeDaySeconds {
		g.into -= goldTimeDaySeconds
		g.rollOnce()
		rolled = true
	}
	return rolled
}

// catchUp is the load's resync with the wall clock (vslot_012
// s:0x6525bf..0x6526fe). It reports false when the period is over (R <= 0):
// the words are then zeroed, so the first tick ends the job.
func (g *goldTime) catchUp(now time.Time) bool {
	r := int64(g.extDays+1)*goldTimeDaySeconds + g.period - (now.Unix() - g.started.Unix())
	if r <= 0 {
		g.days, g.into, g.prev, g.today = 0, 0, 0, 0
		return false
	}
	t := int64(g.days+1)*goldTimeDaySeconds - int64(g.into)
	if t >= r {
		if delta := t - r; delta > 0 {
			g.into += int(delta)
			for g.into >= goldTimeDaySeconds {
				g.into -= goldTimeDaySeconds
				g.rollOnce()
			}
		}
	}
	return true
}

func (g *goldTime) ended() bool { return g.days == 0 && g.today == 0 && g.prev == 0 }

// drain spends one second of gold time, the previous day's first.
func (g *goldTime) drain() {
	if g.prev > 0 {
		g.prev--
		return
	}
	if g.today > 0 {
		g.today--
	}
}

type goldTimeDeps struct {
	store timedjob.Store
	items ItemLookup
	hub   *world.Hub
}

// goldTimes is the process's running premiums, by character.
var goldTimes = struct {
	mu   sync.Mutex
	m    map[int64]*goldTime
	deps atomic.Pointer[goldTimeDeps]
}{m: map[int64]*goldTime{}}

// StartGoldTime wires the premium's store and starts its one-second tick
// (CTimedJobManagerForPC's sweep, once a second).
func StartGoldTime(ctx context.Context, store timedjob.Store, items ItemLookup, hub *world.Hub) {
	goldTimes.deps.Store(&goldTimeDeps{store: store, items: items, hub: hub})
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				goldTimeTick(useItemClock())
			}
		}
	}()
}

func goldTimeDepsNow() *goldTimeDeps { return goldTimes.deps.Load() }

// goldTimeOf is characterID's running premium (a copy), if any.
func goldTimeOf(characterID int64) (goldTime, bool) {
	goldTimes.mu.Lock()
	defer goldTimes.mu.Unlock()
	g, ok := goldTimes.m[characterID]
	if !ok {
		return goldTime{}, false
	}
	return *g, true
}

// goldTimeRunning reports a running type-3 job (FUN_0049a400).
func goldTimeRunning(characterID int64) bool {
	_, ok := goldTimeOf(characterID)
	return ok
}

// goldTimeBonus is the award's +EXP and +SP percent now (params 0x100 and
// 0x102).
func goldTimeBonus(characterID int64) (expPct, spPct int) {
	g, ok := goldTimeOf(characterID)
	if !ok || !g.bonusOn() {
		return 0, 0
	}
	return g.expPct, g.spPct
}

// goldTimeAward adds the premium's share of an award (exp, sp after the
// multiplier) computed before the rate term: trunc(x * pct / 100.0).
func goldTimeAward(characterID int64, exp, sp int64) (int64, int64) {
	ep, spp := goldTimeBonus(characterID)
	return petExpBonus(exp, ep), petExpBonus(sp, spp)
}

// startGoldTime begins the premium row it for characterID (the UIU1 branch
// and case 4); the caller has checked none runs.
func startGoldTime(ctx context.Context, sess *gateway.Session, characterID int64, it *refdata.Item, now time.Time) {
	g := &goldTime{charID: characterID, refID: it.ID, started: now, period: int64(it.Param1), lastTick: now,
		days: int(int64(it.Param1)/goldTimeDaySeconds) & 0xff, daily: int(it.ReinforceRate2/1000) & 0xffff,
		lossPct: int(int32(it.ReinforceRate1)), expPct: int(int32(it.ReinforceRate3)), spPct: int(int32(it.Param5)),
		lastPush: now, lastSave: now}
	g.today = g.daily
	goldTimes.mu.Lock()
	goldTimes.m[characterID] = g
	cp := *g
	goldTimes.mu.Unlock()
	saveGoldTime(ctx, cp)
	sendGoldTimeState(sess, cp, now)
	slog.Info("gold time: started", "character", characterID, "item", it.ID, "days", cp.days, "daily_s", cp.daily,
		"exp_pct", cp.expPct, "sp_pct", cp.spPct, "death_loss_pct", cp.lossPct)
}

// The params of a 3/3/13/4 row as refdata.Item carries them: Param2 is
// ReinforceRate1, Param3 ReinforceRate2, Param4 ReinforceRate3, Param5 Param5
// (refdata/item.go's export, the same columns the UIU1 3/3/3/10 branch reads).

func saveGoldTime(ctx context.Context, g goldTime) {
	d := goldTimeDepsNow()
	if d == nil || d.store == nil {
		return
	}
	paused := int64(0)
	if g.paused {
		paused = 1
	}
	if err := d.store.Put(ctx, timedjob.Job{CharID: g.charID, Type: timedjob.TypePremium, Ref: g.refID, Key: g.refID,
		Start: g.started, V1: int64(g.into)<<8 | int64(g.days), V2: int64(g.prev)<<16 | int64(g.today), V3: paused}); err != nil {
		slog.Warn("gold time: saving", "character", g.charID, "err", err)
	}
}

// goldTimeArrived loads a premium kept for the arriving character (catching
// up the days it was away, vslot_012) and tells its client; one already running is told
// again.
func goldTimeArrived(ctx context.Context, arrived world.Entity) {
	d := goldTimeDepsNow()
	if d == nil {
		return
	}
	now := useItemClock()
	goldTimes.mu.Lock()
	g, ok := goldTimes.m[arrived.CharacterID]
	var cp goldTime
	if ok {
		cp = *g
	}
	goldTimes.mu.Unlock()
	if !ok && d.store != nil {
		jobs, err := d.store.List(ctx, arrived.CharacterID)
		if err != nil {
			return
		}
		for _, j := range jobs {
			if j.Type != timedjob.TypePremium {
				continue
			}
			it, err := d.items.GetItem(ctx, j.Ref)
			if err != nil || it == nil || !isPremiumTime(it) {
				continue
			}
			ng := &goldTime{charID: arrived.CharacterID, refID: j.Ref, started: j.Start,
				into: int(j.V1 >> 8), days: int(j.V1 & 0xff),
				prev: int(j.V2 >> 16), today: int(j.V2 & 0xffff), paused: j.V3 != 0, period: int64(it.Param1),
				daily: int(it.ReinforceRate2/1000) & 0xffff, lossPct: int(int32(it.ReinforceRate1)),
				expPct: int(int32(it.ReinforceRate3)), spPct: int(int32(it.Param5)), lastPush: now, lastSave: now,
				lastTick: now}
			// vslot_012's load: the days away are rolled; an expired period
			// is zeroed and not told -- the first tick ends it with the end
			// form (s:0x652615..0x65262c, then the Tick's days-0 branch).
			live := ng.catchUp(now)
			goldTimes.mu.Lock()
			goldTimes.m[arrived.CharacterID] = ng
			cp = *ng
			goldTimes.mu.Unlock()
			saveGoldTime(ctx, cp)
			ok = live
			break
		}
	}
	switch {
	case !ok:
	case cp.periodLeft() == 0 && cp.left() == 0:
		// vslot_012's short form when the period word and Data2 are both 0
		// (s:0x65285b..0x6528e4): the end layout {3, 1, ref, 0, 0}; the first
		// tick then reaps the job.
		sendGoldTimeEnd(arrived.Session, cp.refID)
	default:
		sendGoldTimeState(arrived.Session, cp, now)
	}
}

// goldTimeLeft saves and drops a leaving character's premium.
func goldTimeLeft(characterID int64) {
	goldTimes.mu.Lock()
	g, ok := goldTimes.m[characterID]
	var cp goldTime
	if ok {
		cp = *g
		delete(goldTimes.m, characterID)
	}
	goldTimes.mu.Unlock()
	if ok {
		saveGoldTime(context.Background(), cp)
	}
}

// goldTimeTick is one second of every running premium whose owner is in the
// world (Tick 0x6529d0).
func goldTimeTick(now time.Time) {
	d := goldTimeDepsNow()
	if d == nil || d.hub == nil {
		return
	}
	type out struct {
		g     goldTime
		sess  *gateway.Session
		push  bool
		save  bool
		ended bool
	}
	var outs []out
	goldTimes.mu.Lock()
	for id, g := range goldTimes.m {
		e, online := d.hub.EntityByCharacterID(id)
		if !online {
			continue
		}
		o := out{sess: e.Session}
		if g.advance(now) {
			o.push, o.save = true, true
		}
		switch {
		case g.resume:
			g.resume, g.paused = false, false
			o.push, o.save = true, true
		case !g.pauseAt.IsZero() && !now.Before(g.pauseAt):
			g.pauseAt, g.paused = time.Time{}, true
			o.push, o.save = true, true
		}
		if !g.paused && g.left() > 0 && inBattle(id, now) {
			g.drain()
			if g.left() == 0 {
				o.push = true
			}
		}
		if g.ended() {
			o.ended = true
			delete(goldTimes.m, id)
		} else {
			if now.Sub(g.lastPush) >= goldTimePushPeriod {
				o.push = true
			}
			if now.Sub(g.lastSave) >= goldTimeSavePeriod {
				o.save = true
			}
			if o.push {
				g.lastPush = now
			}
			if o.save {
				g.lastSave = now
			}
		}
		o.g = *g
		if o.push || o.save || o.ended {
			outs = append(outs, o)
		}
	}
	goldTimes.mu.Unlock()
	for _, o := range outs {
		if o.ended {
			if d.store != nil {
				_ = d.store.Delete(context.Background(), o.g.charID, timedjob.TypePremium, "", o.g.refID)
			}
			sendGoldTimeEnd(o.sess, o.g.refID)
			slog.Info("gold time: ended", "character", o.g.charID, "item", o.g.refID)
			continue
		}
		if o.save {
			saveGoldTime(context.Background(), o.g)
		}
		if o.push {
			sendGoldTimeState(o.sess, o.g, now)
		}
	}
}

// GoldTimeState is 0x3206's sub-1 body.
type GoldTimeState struct {
	RefID      uint32
	PeriodLeft uint32
	Prev       uint16
	Today      uint16
	Paused     bool
	End        bool // the end form: zeros and no paused byte
}

func (s *GoldTimeState) Encode() []byte {
	out := []byte{goldTimeJobType, goldTimeSubState}
	out = binary.LittleEndian.AppendUint32(out, s.RefID)
	if s.End {
		return append(out, 0, 0, 0, 0, 0, 0, 0, 0)
	}
	out = binary.LittleEndian.AppendUint32(out, s.PeriodLeft)
	out = binary.LittleEndian.AppendUint32(out, uint32(s.Prev)<<16|uint32(s.Today))
	if s.Paused {
		return append(out, 1)
	}
	return append(out, 0)
}

func sendGoldTimeState(sess *gateway.Session, g goldTime, now time.Time) {
	if sess == nil {
		return
	}
	_ = sess.Send(&proto.Packet{Opcode: OpGoldTime, Data: (&GoldTimeState{RefID: uint32(g.refID), PeriodLeft: g.periodLeft(),
		Prev: uint16(g.prev), Today: uint16(g.today), Paused: g.paused}).Encode()})
}

func sendGoldTimeEnd(sess *gateway.Session, refID int64) {
	if sess == nil {
		return
	}
	_ = sess.Send(&proto.Packet{Opcode: OpGoldTime, Data: (&GoldTimeState{RefID: uint32(refID), End: true}).Encode()})
}

func sendGoldTimeRefusal(sess *gateway.Session, code uint16, refID int64) error {
	out := []byte{goldTimeJobType, goldTimeSubRefusal}
	out = binary.LittleEndian.AppendUint16(out, code)
	out = binary.LittleEndian.AppendUint32(out, uint32(refID))
	return sess.Send(&proto.Packet{Opcode: OpGoldTime, Data: out})
}

// GoldTimePauseHandler serves 0x34BF (FUN_0051a840 -> FUN_00653560).
func GoldTimePauseHandler(hub *world.Hub, scrolls *ScrollCaster) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpGoldTimePause || hub == nil {
			return nil
		}
		if len(p.Data) < 2 || p.Data[0] != goldTimeJobType {
			return nil
		}
		want := p.Data[1] != 0
		e, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return nil
		}
		now := useItemClock()
		goldTimes.mu.Lock()
		g, ok := goldTimes.m[e.CharacterID]
		if !ok {
			goldTimes.mu.Unlock()
			return nil
		}
		ref := g.refID
		pending := !g.pauseAt.IsZero() || g.resume
		var code uint16
		refused := false
		switch {
		case g.left() == 0:
			code, refused = goldTimeErrNoTime, true
		case scrolls != nil && scrolls.Casting(e.CharacterID):
			code, refused = goldTimeErrScroll, true
		case !want && inBattle(e.CharacterID, now):
			code, refused = goldTimeErrResume, true
		case want == g.paused || pending:
			// The state it is already in (retail kicks, FUN_004df050(4)).
			goldTimes.mu.Unlock()
			return nil
		case want:
			g.pauseAt = now.Add(goldTimePauseDelay)
		default:
			g.resume = true
		}
		goldTimes.mu.Unlock()
		if refused {
			return sendGoldTimeRefusal(sess, code, ref)
		}
		slog.Info("gold time: pause request", "character", e.CharacterID, "pause", want)
		return nil
	}
}

// usePremiumTime is a 3/3/13/4 item's own use (UseByKind case 4): one
// premium at a time (0x1894); the fatigue test always passes (OURS, above).
func usePremiumTime(ctx context.Context, sess *gateway.Session, fail func(string) error, inv interface {
	RemoveItem(ctx context.Context, characterID int64, index, qty int) error
}, characterID int64, it *refdata.Item, held int, have int) error {
	if goldTimeRunning(characterID) {
		return sendUseResult(sess, &UseItemResult{Error: compositeOverlapRefusal, Code: goldTimeDurationJobInUse, Remaining: int32(have)})
	}
	if goldTimeDepsNow() == nil {
		return fail("that cannot be used")
	}
	if err := inv.RemoveItem(ctx, characterID, held, 1); err != nil {
		return fail("using failed")
	}
	now := useItemClock()
	startGoldTime(ctx, sess, characterID, it, now)
	return sendUseResult(sess, &UseItemResult{Remaining: int32(have - 1), ItemID: uint32(it.ID)})
}
