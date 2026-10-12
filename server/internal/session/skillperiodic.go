package session

// Periodic records (round 785): a timed record whose row carries 'puls'
// (+0x384 value[0], the interval in ms) acts every interval while it runs
// (SkillAction_Buff's sub-state 2, 0x5830b0, READ; the decompiled lines
// ~845 and ~1095..1165 of the RE box's sab.c):
//
//   - a HEAL OVER TIME (a row with 'heal' and no 'eshp'): FUN_005a09f0
//     computes the amounts once at the engage -- hp = v0 + trunc(MaxHP x
//     v1/100), mp = v2 + trunc(MaxMP x v3/100), each scaled by the owner's
//     p170/p171, plus the 'mwhh'/'mwmh' terms -- and every interval
//     ApplyHPMPDelta(owner, hp, mp, 0x40) heals the owner;
//   - a LINKED BLOW (a row with 'lnks' and 'att' -- the Warlock's damage
//     over time): every interval the caster's link resolves a full blow of
//     the row's 'att' and 'mc' on the linked object, its states rolled again
//     (Combat_ResolveDamage, FUN_0059b220, Combat_ApplyActionEffects); the
//     link ends when 'lnks' value[1] is set and the caster is farther.
//
// The first act comes one interval after the engage (INFERRED: the record's
// clock is stamped at the engage and the test is `now - stamp >= puls`).

import (
	"context"
	"math"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/buff"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The stores a periodic act resolves through: the latest cast's (each
// passes the process's one set, so the latest is the first).
var periodicDeps atomic.Pointer[combatDeps]

func noteSkillDeps(d combatDeps) {
	if d.monsters == nil || d.hub == nil || d.chars == nil {
		return
	}
	periodicDeps.Store(&d)
}

func skillDeps() (combatDeps, bool) {
	p := periodicDeps.Load()
	if p == nil {
		return combatDeps{}, false
	}
	return *p, true
}

// pulsMs is the row's 'puls' value[0], 0 without one.
func pulsMs(ref *refdata.Skill) int {
	if ref == nil || !ref.HasParams() {
		return 0
	}
	return int(ref.Runs().Value("puls", 0))
}

// startPeriodic schedules a record's periodic acts, when its row has any.
func startPeriodic(monster bool, ownerID, casterID int64, ref *refdata.Skill, rec buff.Record, now time.Time) {
	interval := pulsMs(ref)
	if interval <= 0 || !rec.Timed() || ref == nil || !ref.HasParams() {
		return
	}
	r := ref.Runs()
	switch {
	case !monster && r.Has("heal") && !r.Has("eshp"):
		hp, mp := hotAmounts(ownerID, casterID, ref)
		if hp <= 0 && mp <= 0 {
			return
		}
		schedulePeriodic(monster, ownerID, rec.Token, interval, func(d combatDeps) bool {
			return hotTick(d, ownerID, hp, mp)
		})
	case monster && r.Has("lnks") && r.Has("att"):
		reach := float64(r.Value("lnks", 1))
		token := rec.Token
		schedulePeriodic(monster, ownerID, rec.Token, interval, func(d combatDeps) bool {
			return linkedBlowTick(d, casterID, ownerID, token, ref, reach)
		})
	}
}

// schedulePeriodic runs act every interval while the record lives.
func schedulePeriodic(monster bool, ownerID int64, token uint32, interval int, act func(combatDeps) bool) {
	var tick func()
	tick = func() {
		active := buffBooks.Active
		if monster {
			active = monsterBooks.Active
		}
		alive := false
		for _, r := range active(ownerID) {
			if r.Token == token && !r.Expired(time.Now()) {
				alive = true
			}
		}
		if !alive {
			return
		}
		d, ok := skillDeps()
		if ok && !act(d) {
			return
		}
		time.AfterFunc(time.Duration(interval)*time.Millisecond, tick)
	}
	time.AfterFunc(time.Duration(interval)*time.Millisecond, tick)
}

// hotAmounts is FUN_005a09f0's computation (READ): v0 + trunc(MaxHP x
// v1/100), v2 + trunc(MaxMP x v3/100), scaled by the owner's p170/p171
// ('rhru'). The 'mwhh'/'mwmh' weapon terms are OPEN (not added).
func hotAmounts(ownerID, casterID int64, ref *refdata.Skill) (hp, mp int) {
	d, ok := skillDeps()
	if !ok {
		return 0, 0
	}
	c, err := d.chars.GetByID(context.Background(), ownerID)
	if err != nil || c == nil {
		return 0, 0
	}
	r := ref.Runs()
	v := func(i int) int { return int(r.Value("heal", i)) }
	hp = v(0) + c.MaxHP()*v(1)/100
	mp = v(2) + c.MaxMP()*v(3)/100
	if t, ok := buffTotal(ownerID, buff.ParamHealHP); ok {
		hp = int(float64(hp) * (1 + t.Apply(0)/100))
	}
	if t, ok := buffTotal(ownerID, buff.ParamHealMP); ok {
		mp = int(float64(mp) * (1 + t.Apply(0)/100))
	}
	return hp, mp
}

// hotTick heals the owner once; false ends the schedule (the owner is gone).
func hotTick(d combatDeps, ownerID int64, hp, mp int) bool {
	e, ok := d.hub.EntityByCharacterID(ownerID)
	if !ok {
		return false
	}
	healCharacter(context.Background(), d.hub, d.chars, d.eq, d.items, d.skills, d.mp, e, hp, mp)
	return true
}

// linkedBlowTick is one pulse of a linked blow from casterID to monster
// ownerID, the record token's; false ends the schedule.
func linkedBlowTick(d combatDeps, casterID, monsterID int64, token uint32, ref *refdata.Skill, reach float64) bool {
	ctx := context.Background()
	m, ok := d.monsters.Get(monsterID)
	if !ok || m.HP <= 0 {
		return false
	}
	caster, in := d.hub.EntityByCharacterID(casterID)
	if !in || caster.Zone != m.Zone || caster.Life != world.LifeAlive {
		endMonsterRecord(d, m, token)
		return false
	}
	if reach > 0 && math.Hypot(caster.Pos.X-m.X, caster.Pos.Z-m.Z) > reach {
		endMonsterRecord(d, m, token)
		return false
	}
	flat, pct := skillDamageBonus(ref)
	terms := skillBlowTerms{damageBonus: flat, damagePercent: pct, hits: ref.HitsFor(),
		attackType: combat.AttackType(ref.AttackType), masteryPercent: skillMasteryPercent(ctx, d.skills, casterID, ref)}
	cc := newCastContext(ctx, d, casterID, caster, ref, terms)
	o, err := cc.strike(skillTarget{ID: m.ID, Share: 100})
	if err != nil || !o.ok {
		return false
	}
	action := &ActionBlock{Target: uint32(m.ID), TargetKind: ActionTargetMonster, HitCount: uint8(cc.terms.hits)}
	outcomes := []targetOutcome{o}
	cc.apply(outcomes, action)
	addSkillHate(cc, outcomes)
	sess := caster.Session
	levelUps, kills, err := payKills(ctx, d, casterID, outcomes, nil)
	if err != nil {
		return false
	}
	// The pulse's blow to the zone, the caster included (no request answers
	// it): OpSkillCast's act with the action block.
	msg := SkillCast{CasterID: casterID, CasterKind: OwnerCharacter, SkillID: ref.ID, CastID: nextCastID(),
		Phase: CastPhaseAct, TargetType: TargetEntity, TargetID: m.ID, Action: action}
	p := &proto.Packet{Opcode: OpSkillCast, Data: msg.Encode()}
	for _, e := range outcomes[0].watchers {
		if e.Session != nil {
			sendMonsterPush(e.Session, p)
		}
	}
	// A pulse's kill levels its caster as a link's does (round 785 review:
	// the level-ups were dropped): OpLevelUp, then the 0x3056.
	if sess != nil {
		for _, lu := range levelUps {
			_ = sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: lu.Encode()})
		}
	}
	for _, k := range kills {
		if k.exp != nil && sess != nil {
			sendExpGainTo(sess, *k.exp)
		}
	}
	_ = announceOutcomes(ctx, d, sess, casterID, outcomes, kills, false)
	return !outcomes[0].died
}

// endMonsterRecord ends m's record of token: the one link that broke
// (round 785 review: matching the skill id ended every caster's record of
// that skill on m).
func endMonsterRecord(d combatDeps, m combat.Monster, token uint32) {
	ended, _ := monsterBooks.EndToken(m.ID, token)
	if len(ended) > 0 {
		pushMonsterBuffEnd(d, m, ended)
	}
}
