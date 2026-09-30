package statuseffect

// Holder is one object's states: the engine's fixed array of 32 records, one
// per applier slot (pc+0xc, stride 0x70). A new state in a slot REPLACES the
// one there -- every block fetches its record with 0x5aa450(cl = slot), the
// slot's own record, and fills it -- so a state never stacks with itself.
// READ (the record fetch at 0x590813/0x590948/0x591093/0x592075, one literal
// slot per block). Not safe for concurrent use; the owner locks.
type Holder struct {
	recs [32]*Record
	// thawUntilMs is when a freeze that has ended lets go of the motion
	// state (FreezeThawMs); thawing says one is pending.
	thawUntilMs uint32
	thawing     bool
}

// ResolveAll resolves every run of a skill against a target and returns the
// records that landed, in block order. The row's 'puls' becomes bleeding's
// tick interval.
func ResolveAll(runs []Run, t Target, nowMs uint32, roll Roller) []Record {
	puls, hasPuls := PulsMs(runs)
	var out []Record
	for _, r := range runs {
		rec, ok := Resolve(r, t, nowMs, roll)
		if !ok {
			continue
		}
		if rec.Slot == SlotBleeding && hasPuls {
			rec.TickIntervalMs = puls
		}
		out = append(out, rec)
	}
	return out
}

// Put lands a record, replacing whatever held its slot.
func (h *Holder) Put(r Record) {
	if r.Slot < 0 || r.Slot > 31 {
		return
	}
	rec := r
	h.recs[r.Slot] = &rec
}

// EndAll ends every state at once (a death, a respawn) and reports whether any
// was on.
func (h *Holder) EndAll() bool {
	any := false
	for i := range h.recs {
		if h.recs[i] != nil {
			any = true
			h.recs[i] = nil
		}
	}
	return any
}

// Holds reports whether a slot's state is on.
func (h *Holder) Holds(slot int) bool {
	return slot >= 0 && slot < 32 && h.recs[slot] != nil
}

// Get returns a slot's record.
func (h *Holder) Get(slot int) (Record, bool) {
	if !h.Holds(slot) {
		return Record{}, false
	}
	return *h.recs[slot], true
}

// Empty reports whether no state is on.
func (h *Holder) Empty() bool { return h.Mask() == 0 }

// Idle reports whether the holder has nothing left to do at nowMs: no state,
// and no freeze thawing.
func (h *Holder) Idle(nowMs uint32) bool { return h.Empty() && !h.Thawing(nowMs) }

// Mask is the owner mask the client draws: the OR of MaskForSlot over every
// active slot (AbnormalState_DeactivateSlotAndRebuildMask 0x4a5660). READ.
func (h *Holder) Mask() uint32 {
	var m uint32
	for i, r := range h.recs {
		if r != nil {
			m |= MaskForSlot(i)
		}
	}
	return m
}

// Levels is the level byte of every set bit of Mask that LevelBits names, in
// bit order -- the bytes 0x3057 carries after the mask.
func (h *Holder) Levels() []byte {
	var out []byte
	m := h.Mask()
	for bit := 0; bit < 32; bit++ {
		b := uint32(1) << uint(bit)
		if m&b == 0 || LevelBits&b == 0 {
			continue
		}
		lvl := 0
		if r := h.recs[SlotForBit(bit)]; r != nil {
			lvl = r.Level
		}
		out = append(out, byte(lvl))
	}
	return out
}

// Tick is one damage tick a state dealt.
type Tick struct {
	Code   string
	Damage int
	// Source is what the applier makes of record+0x4c for this tick (see
	// SourceRule); SourceID names the caster whatever the rule.
	Source          SourceRule
	SourceID        int64
	SourceIsMonster bool
	// NeverKills marks poison: its damage is min(value, HP-1) against the HP
	// the owner has when the tick is dealt.
	NeverKills bool
}

// Credited reports whether the tick names its source when it deals damage
// that is fatal (fatal) or not.
func (t Tick) Credited(fatal bool) bool {
	return t.Source == SourceKept || (t.Source == SourceIfFatal && fatal)
}

// SourceRule is the three damage appliers' verdict on the caster (READ,
// round 659's review: burn 0x4a46f0, poison 0x4a4940, bleeding 0x4a4cc0,
// each the same shape). The applier resolves record+0x4c (0x485d90) and,
// while the record's latch +0x6c is clear:
//
//   - no such object: the damage is dealt with no source;
//   - an object whose life state (vslot 0xf8, CGObj::GetLifeState 0x485ee0)
//     is neither 2 DEAD nor 3 GONE: the damage is dealt WITH it, every tick,
//     poison included -- so a living caster is booked every tick;
//   - dead or gone: the latch is set, for good.
//
// Latched, burn and bleeding keep the source only for a fatal tick (`if
// damage < curHP: source = nil`), and poison drops it always.
type SourceRule int

const (
	// SourceNone: the tick names nobody.
	SourceNone SourceRule = iota
	// SourceKept: the tick names its caster, fatal or not.
	SourceKept
	// SourceIfFatal: the tick names its caster only if it kills.
	SourceIfFatal
)

// CasterState is what 0x485d90 and GetLifeState answer for a record's
// caster.
type CasterState int

const (
	CasterGone  CasterState = iota // no such object any more
	CasterAlive                    // life state neither 2 nor 3
	CasterDead                     // life state 2 or 3
)

// CasterLookup answers for a record's caster.
type CasterLookup func(sourceID int64, isMonster bool) CasterState

// Step is one pass of AbnormalState_UpdateOwnerClear (0x4a4390) at nowMs over
// an owner whose current HP is curHP: an expired state is removed FIRST (the
// engine's order -- no last tick for it), then each live one is given its
// mode-1 tick. It returns the damage ticks, in slot order, and whether the
// mask changed. The damage is not applied here; each tick is computed against
// curHP less the ticks before it in this pass. caster may be nil (every
// caster gone).
func (h *Holder) Step(nowMs uint32, curHP int, caster CasterLookup) (ticks []Tick, changed bool) {
	hp := curHP
	for i, r := range h.recs {
		if r == nil {
			continue
		}
		if Expired(nowMs, r.StartMs, r.DurationMs) {
			if i == SlotFreeze {
				// Freeze's removal leaves the motion state FROZEN for 1.5 s
				// (AbnormalState_Apply00 mode 2: vslot 0x55c(10, 0, 1.5), the
				// float at 0xb45c10) -- READ; CanActAt holds it.
				h.thawUntilMs, h.thawing = nowMs+FreezeThawMs, true
			}
			h.recs[i] = nil
			changed = true
			continue
		}
		t, ok := r.tick(nowMs, hp, caster)
		if !ok {
			continue
		}
		ticks = append(ticks, t)
		hp -= t.Damage
	}
	return ticks, changed
}

// FreezeThawMs is how long a freeze's FROZEN motion state outlasts it.
const FreezeThawMs = 1500

// source is the applier's verdict (SourceRule) for this tick, latching the
// record when its caster is dead or gone from the living.
func (r *Record) source(caster CasterLookup, poison bool) SourceRule {
	if !r.latched {
		st := CasterGone
		if caster != nil && r.SourceID != 0 {
			st = caster(r.SourceID, r.SourceIsMonster)
		}
		switch st {
		case CasterGone:
			return SourceNone
		case CasterAlive:
			return SourceKept
		}
		r.latched = true
	}
	if poison {
		return SourceNone
	}
	return SourceIfFatal
}

// tick is the slot's mode-1 applier for the three damaging states.
func (r *Record) tick(nowMs uint32, curHP int, caster CasterLookup) (Tick, bool) {
	switch r.Slot {
	case SlotPoison:
		// AbnormalState_Apply04 (0x4a4940): `GetTickCount() - +0x68 < 0x7d1`
		// returns, so it fires once 2001 ms have passed; min(value, HP-1).
		if nowMs-r.LastTickMs < TickIntervalMs {
			return Tick{}, false
		}
		r.LastTickMs = nowMs
		d := PoisonTickDamage(r.TickValue, curHP)
		if d <= 0 {
			return Tick{}, false
		}
		return Tick{Code: r.Code, Damage: d, NeverKills: true, Source: r.source(caster, true), SourceID: r.SourceID, SourceIsMonster: r.SourceIsMonster}, true
	case SlotBurn:
		// AbnormalState_Apply02 (0x4a46f0): the same 2001 ms. Param 8 is 0
		// on everything srrevamp spawns, and the factor is the 1.0 the block
		// writes. READ.
		if nowMs-r.LastTickMs < TickIntervalMs {
			return Tick{}, false
		}
		r.LastTickMs = nowMs
		d := BurnTickDamage(r.TickValue, 0, 1.0)
		if d <= 0 {
			return Tick{}, false
		}
		return Tick{Code: r.Code, Damage: d, Source: r.source(caster, false), SourceID: r.SourceID, SourceIsMonster: r.SourceIsMonster}, true
	case SlotBleeding:
		// AbnormalState_Apply11 (0x4a4cc0): `GetTickCount() - +0x68 <= +0x10`
		// returns -- strictly MORE than the interval must pass -- then
		// value[3]. READ.
		iv := r.TickIntervalMs
		if iv <= 0 {
			iv = DefaultTickIntervalMs
		}
		if nowMs-r.LastTickMs <= uint32(iv) {
			return Tick{}, false
		}
		r.LastTickMs = nowMs
		if r.TickValue <= 0 {
			return Tick{}, false
		}
		return Tick{Code: r.Code, Damage: r.TickValue, Source: r.source(caster, false), SourceID: r.SourceID, SourceIsMonster: r.SourceIsMonster}, true
	}
	return Tick{}, false
}

// SpeedPercent is the owner's movement speed as a percent of normal: 50 under
// frostbite, else 75 under slow ('blunting'), else 100. READ: frostbite's
// applier (0x4a45d0) writes params 23 and 24 (walk and run speed) as 50.0 in
// the scale slot of the abnormal context (`push 5; push 3`, the float at
// 0xb4603c) and 100.0 (0xb45e10) back on removal; slow's (0x4a4a90) writes
// 75.0 (0xb45de0) only while the mask has no frostbite bit (`test byte
// [owner+4],2`), and its tick re-applies it once frostbite has let go of the
// params (the owner byte 1 test). Both also write param 140 (200.0 and 125.0,
// 0xb45d68 / 0xb461a8) in the plain slot: unnamed, not modelled (OPEN).
func (h *Holder) SpeedPercent() int {
	switch {
	case h.Holds(SlotFrostbite):
		return 50
	case h.Holds(8):
		return 75
	}
	return 100
}

// The states that stop an owner, by slot.
const (
	SlotSleep = 6
	SlotRoot  = 7
	SlotSlow  = 8
	SlotFear  = 9
	SlotStun  = 14
)

// CanMove reports whether the owner may start a move. READ: the movement
// handler (GObjPC::FUN_004b0ea0, slot 377 of every mobile class, monsters
// included) refuses a move while the abnormal mask has any of 0xc1 --
// freeze, sleep, root -- or 0x4000, stun (`test al,0xc1` 0x4b0fa6, `test
// eax,0x4000` 0x4b0fae).
func (h *Holder) CanMove() bool {
	return h.Mask()&(0xc1|0x4000) == 0
}

// CanAct reports whether the owner may start an attack. READ, the applying
// half: freeze, stun and sleep each call vslot 0x570 on apply
// (GObjPC::FUN_004aa340: stop the move, cancel the running action through the
// action queue at +0xa30) and set the motion state through vslot 0x55c
// (GObjPC::FUN_004a9d00) to 10 FROZEN, 9 STUN and 0x13 respectively
// (AbnormalState_Apply00/14/06, 0x4a4570/0x4a4ec0/0x4a49f0), putting it back
// to 0 STAND on removal. INFERRED: that the monster starts no new attack
// while it holds one of those motion states -- the refusing test in the
// monster's attack path is not read.
func (h *Holder) CanAct() bool {
	return !h.Holds(SlotFreeze) && !h.Holds(SlotStun) && !h.Holds(SlotSleep)
}

// CanActAt is CanAct at nowMs, holding a thawing freeze's FROZEN motion state
// for FreezeThawMs after the freeze has gone (the mask no longer shows it).
func (h *Holder) CanActAt(nowMs uint32) bool {
	if h.thawing && int32(nowMs-h.thawUntilMs) < 0 {
		return false
	}
	return h.CanAct()
}

// Thawing reports whether a freeze that has ended still holds its owner at
// nowMs.
func (h *Holder) Thawing(nowMs uint32) bool {
	return h.thawing && int32(nowMs-h.thawUntilMs) < 0
}

// DefenceCut is the flat defence bleeding takes off (params 5 and 6,
// `-(float)record+0x40` in the abnormal context, 0x4a4cc0 mode 0). READ.
func (h *Holder) DefenceCut() int {
	if r := h.recs[SlotBleeding]; r != nil {
		return r.DefenceCut
	}
	return 0
}
