package session

// Support casts on characters (round 785): the heals a row's 'efr'
// spreads (the party heal, the chain heal), the cures, and the
// resurrection. READ from SR_GameServer.exe (Skill_ApplyEffectsAndNotify
// 0x593f50 and its callees); docs/protocol/skill_support.md.

import (
	"context"
	"math"
	"math/rand"
	"sort"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/buff"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/statuseffect"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// charTarget is one character a support cast lands on, with its share.
type charTarget struct {
	e     world.Entity
	share int
}

// supportTargets is the cast's character vector: the named target (or the
// caster) first, then what the row's 'efr' collector adds over characters
// (READ, docs/protocol/skill_targets.md): kind 5 the caster's party within
// v2 (3-D, no radius terms; the caster when v5 & 1), kind 6 a chain from the
// primary (the party when v5 is 4 or 5, else the PCs v5's bits allow), kinds
// 1/2 the PCs within casterBC + v2 + tBC of the caster / the primary. dead
// lets the dead in (a 'resu' row's party collector, READ).
func supportTargets(hub *world.Hub, parties *party.Hub, row *refdata.Skill, caster world.Entity, named *world.Entity, dead bool) []charTarget {
	var out []charTarget
	primary := caster
	if named != nil {
		primary = *named
	}
	v, ok := efrRun(row)
	if !ok {
		if named != nil {
			return []charTarget{{e: *named, share: 100}}
		}
		return []charTarget{{e: caster, share: 100}}
	}
	kind, radius, maxN, falloff, flags := int(v[1]), float64(v[2]), int(v[3]), int(v[4]), uint32(v[5])
	if kind != 5 && kind != 6 && (flags == 4 || flags == 5) {
		kind = 5
	}
	alive := func(e world.Entity) bool {
		return e.Life == world.LifeAlive || (dead && e.Life == world.LifeDead)
	}
	inParty := map[int64]bool{}
	if parties != nil {
		if p, in := parties.Get(caster.CharacterID); in {
			for _, m := range p.Members {
				inParty[m.CharacterID] = true
			}
		}
	}
	allowed := func(e world.Entity) bool {
		if e.CharacterID == caster.CharacterID {
			return flags&efrSelf != 0
		}
		if inParty[e.CharacterID] {
			return flags&efrParty != 0
		}
		return flags&efrOthers != 0
	}
	var cands []world.Entity
	for _, e := range hub.EntitiesInZone(caster.Zone) {
		if !alive(e) || e.CharacterID == primary.CharacterID {
			continue
		}
		switch {
		case kind == 5 || (kind == 6 && (flags == 4 || flags == 5)):
			if e.CharacterID == caster.CharacterID {
				if flags&efrSelf == 0 {
					continue
				}
			} else if !inParty[e.CharacterID] {
				continue
			}
		default:
			if !allowed(e) {
				continue
			}
		}
		cands = append(cands, e)
	}
	sort.Slice(cands, func(i, j int) bool {
		di, dj := dist3(cands[i].Pos, primary.Pos), dist3(cands[j].Pos, primary.Pos)
		if di != dj {
			return di < dj
		}
		return cands[i].CharacterID < cands[j].CharacterID
	})
	if named != nil || kind != 5 || flags&efrSelf != 0 {
		out = append(out, charTarget{e: primary, share: 100})
	}
	full := func() bool { return maxN != 0 && len(out) >= maxN }
	shares := newEfrShares(falloff)
	bc := float64(combat.PlayerBCRadius)
	switch kind {
	case 5:
		// No cap and no falloff (0x58bef0, READ).
		for _, e := range cands {
			if dist3(e.Pos, caster.Pos) <= radius {
				out = append(out, charTarget{e: e, share: 100})
			}
		}
	case 6:
		r := math.Min(radius*float64(maxN+1), efrChainCap)
		var pool []world.Entity
		for _, e := range cands {
			if dist3(e.Pos, caster.Pos) <= r {
				pool = append(pool, e)
			}
		}
		for n := 0; n < maxN-1 && len(pool) > 0; n++ {
			best, bestD := -1, 10000.0
			for i, e := range pool {
				if d := dist3(e.Pos, primary.Pos); d <= radius && d < bestD {
					best, bestD = i, d
				}
			}
			if best < 0 {
				break
			}
			out = append(out, charTarget{e: pool[best], share: shares.take()})
			pool = append(pool[:best], pool[best+1:]...)
		}
	case 1, 2:
		centre := caster.Pos
		if kind == 2 {
			centre = primary.Pos
		}
		for _, e := range cands {
			if full() {
				break
			}
			if dist3(e.Pos, centre) <= bc+radius+bc {
				out = append(out, charTarget{e: e, share: shares.take()})
			}
		}
	}
	return out
}

// healAmounts is one target's heal from a row's 'heal' (heal.md's flat form
// with the percent terms, FUN_005a0850 / 0x59431b..0x594438, READ): v0 +
// trunc(MaxHP x v1/100) and v2 + trunc(MaxMP x v3/100), a chain's v0 and v2
// scaled by the target's share, then x (1 + p170/100) and (1 + p171/100).
func healAmounts(ctx context.Context, d combatDeps, row *refdata.Skill, t charTarget, chain bool) (hp, mp int) {
	c, err := d.chars.GetByID(ctx, t.e.CharacterID)
	if err != nil || c == nil {
		return 0, 0
	}
	r := row.Runs()
	v := func(i int) int { return int(r.Value("heal", i)) }
	v0, v2 := v(0), v(2)
	if chain && t.share < 100 {
		v0 = int(math.Round(float64(v0) * float64(t.share) / 100))
		v2 = int(math.Round(float64(v2) * float64(t.share) / 100))
	}
	hp = v0 + c.MaxHP()*v(1)/100
	mp = v2 + c.MaxMP()*v(3)/100
	if tot, ok := buffTotal(c.ID, buff.ParamHealHP); ok {
		hp = int(float64(hp) * (1 + tot.Apply(0)/100))
	}
	if tot, ok := buffTotal(c.ID, buff.ParamHealMP); ok {
		mp = int(float64(mp) * (1 + tot.Apply(0)/100))
	}
	return hp, mp
}

// applySupport runs a support cast's effects on its characters: the 'efr'
// heal of an action-kind-0 row (rows without 'efr' keep the single-target
// heal columns, round 503 / 622), and the cures. It returns the caster's HP
// when the cast healed it (-1 otherwise).
func applySupport(ctx context.Context, d combatDeps, characterID int64, row *refdata.Skill, named *world.Entity) int {
	if row == nil || !row.HasParams() {
		return -1
	}
	r := row.Runs()
	caster, ok := d.hub.EntityByCharacterID(characterID)
	if !ok {
		return -1
	}
	_, hasEfr := efrRun(row)
	heals := row.ActionKind == 0 && r.Has("heal") && hasEfr && !r.Has("resu")
	cure, cures := cureRuleOf(row)
	if !heals && !cures {
		return -1
	}
	targets := supportTargets(d.hub, d.parties, row, caster, named, false)
	casterHP := -1
	chain := false
	if v, ok := efrRun(row); ok && v[1] == 6 {
		chain = true
	}
	for _, t := range targets {
		if heals {
			hp, mp := healAmounts(ctx, d, row, t, chain)
			if got := healCharacter(ctx, d.hub, d.chars, d.eq, d.items, d.skills, d.mp, t.e, hp, mp); got >= 0 && t.e.CharacterID == characterID {
				casterHP = got
			}
		}
		if cures {
			statusFX.cureCharacter(d.hub, t.e.CharacterID, cure)
		}
	}
	return casterHP
}

// cureRuleOf is a row's 'curl'/'curt'/'rcur' runs.
func cureRuleOf(row *refdata.Skill) (statuseffect.CureRule, bool) {
	if row == nil || !row.HasParams() {
		return statuseffect.CureRule{}, false
	}
	r := row.Runs()
	var c statuseffect.CureRule
	if v, ok := r.Values("curl"); ok && len(v) >= 3 {
		c.HasCurl, c.CurlMask, c.CurlChance, c.CurlLevel = true, uint32(v[0]), uint32(v[1]), uint32(v[2])
	}
	if v, ok := r.Values("curt"); ok && len(v) >= 2 {
		c.HasCurt, c.CurtMask, c.CurtStrength = true, uint32(v[0]), uint32(v[1])
	}
	if v, ok := r.Values("rcur"); ok && len(v) >= 1 {
		c.Rcur = int(v[0])
	}
	return c, c.HasCurl || c.HasCurt
}

// cureCharacter applies a cure to a character's states and tells its view
// when the mask changed (0x4a5c60 notifies, INFERRED the state broadcast).
func (s *statusRuntime) cureCharacter(hub *world.Hub, id int64, rule statuseffect.CureRule) {
	s.mu.Lock()
	h := s.pcs[id]
	if h == nil {
		s.mu.Unlock()
		return
	}
	before := h.Mask()
	h.Cure(rule, s.ms(time.Now()), func(chance int) bool {
		damageRollMu.Lock()
		defer damageRollMu.Unlock()
		return combat.RollChance(chance, damageRollNG)
	}, func(c []int) {
		damageRollMu.Lock()
		defer damageRollMu.Unlock()
		// A nil source is the tests' fixed dice (combat.RollChance's own
		// convention): the candidates keep their slot order.
		if damageRollNG == nil {
			return
		}
		rand.New(rand.NewSource(damageRollNG.Int63())).Shuffle(len(c), func(i, j int) { c[i], c[j] = c[j], c[i] })
	})
	msg := &ObjectStatus{OwnerKind: OwnerCharacter, OwnerID: id, Mask: h.Mask(), Levels: h.Levels()}
	s.mu.Unlock()
	if msg.Mask != before {
		broadcastStatus(hub, "", msg)
	}
}

// rowHasResu reports whether a row resurrects ('resu', +0x330).
func rowHasResu(row *refdata.Skill) bool {
	return row != nil && row.HasParams() && row.Runs().Has("resu")
}

// THE RESURRECTION (READ 0x5946c1..0x5949b8; trs_wait_response 0x46c8e0 /
// 0x46cb30): a dead PC of level <= resu[0] is OFFERED a revive -- 0x3080
// {u8 kind (4, or 8 when the row has 'rmut'), u32 the caster's uid} -- and
// on its "yes" (a non-zero u8 on 0x3080, while it is still dead) it is
// revived where it lies with hp = v0 + trunc(MaxHP x v1/100), mp = v2 +
// trunc(MaxMP x v3/100) (the row's 'heal'), and ceil(the EXP its death took x
// resu[1]/100) back (OPEN: OpenSRO keeps no per-death EXP record; not
// returned). The offer waits 30 s (the transaction's timeout, party
// invitations' 0xb45b48, INFERRED the same box).
//
// Round 785 review: an offer lives until its answer, its 30 s, the target's
// revive by any path, or its logout -- whichever comes first -- and an
// expired one is absent. The 0x3080 answer is the party invitation's first
// (handlePartyAnswer; the client ignores kinds 4/8, so a leftover offer must
// never take an answer meant for an invitation).

// resurrectOfferTimeout is how long an offer waits for its answer.
const resurrectOfferTimeout = 30 * time.Second

type resurrectOffer struct {
	casterID int64
	row      *refdata.Skill
	expires  time.Time
	seq      uint64
}

var resurrectOffers = struct {
	sync.Mutex
	seq uint64
	m   map[int64]resurrectOffer
}{m: map[int64]resurrectOffer{}}

// dropResurrectOffer forgets the offer pending for characterID, if any (its
// revive by another path, its logout).
func dropResurrectOffer(characterID int64) {
	resurrectOffers.Lock()
	delete(resurrectOffers.m, characterID)
	resurrectOffers.Unlock()
}

// offerResurrection sends target the offer; false when the row's level cap
// refuses the target.
func offerResurrection(ctx context.Context, d combatDeps, casterID int64, row *refdata.Skill, target world.Entity) bool {
	c, err := d.chars.GetByID(ctx, target.CharacterID)
	if err != nil || c == nil || target.Session == nil {
		return false
	}
	if cap := int(row.Runs().Value("resu", 0)); cap > 0 && c.Level > cap {
		return false
	}
	kind := byte(4)
	if row.Runs().Has("rmut") {
		kind = 8
	}
	resurrectOffers.Lock()
	resurrectOffers.seq++
	seq, id := resurrectOffers.seq, target.CharacterID
	resurrectOffers.m[id] = resurrectOffer{casterID: casterID, row: row, expires: time.Now().Add(resurrectOfferTimeout), seq: seq}
	resurrectOffers.Unlock()
	// The timeout frees the entry (a newer offer is left alone).
	time.AfterFunc(resurrectOfferTimeout, func() {
		resurrectOffers.Lock()
		if o, ok := resurrectOffers.m[id]; ok && o.seq == seq {
			delete(resurrectOffers.m, id)
		}
		resurrectOffers.Unlock()
	})
	data := []byte{kind, byte(casterID), byte(casterID >> 8), byte(casterID >> 16), byte(casterID >> 24)}
	_ = target.Session.Send(&proto.Packet{Opcode: party.OpInvitation, Data: data})
	return true
}

// takeResurrection answers a pending offer to the session's character: it
// reports whether there was one (the 0x3080 answer belongs to it). An
// expired offer is no offer (round 785 review). A "yes" revives.
func takeResurrection(ctx context.Context, sess *gateway.Session, characterID int64, accept bool) bool {
	resurrectOffers.Lock()
	o, ok := resurrectOffers.m[characterID]
	if ok {
		delete(resurrectOffers.m, characterID)
	}
	resurrectOffers.Unlock()
	if !ok || time.Now().After(o.expires) {
		return false
	}
	if !accept {
		return true
	}
	d, have := skillDeps()
	if !have {
		return true
	}
	c, mpNow, err := reviveWith(ctx, d.chars, d.mp, d.hub, characterID, false)
	if err != nil || c == nil {
		return true
	}
	// The row's own amounts on top of Revive(1)'s, through ApplyHPMPDelta
	// (flag 8, READ); the pools clamp at their maxima.
	r := o.row.Runs()
	v := func(i int) int { return int(r.Value("heal", i)) }
	if hp := v(0) + c.MaxHP()*v(1)/100; hp > 0 {
		if h, err := d.chars.Heal(ctx, characterID, hp, c.MaxHP()); err == nil {
			c.HP = h
		}
	}
	if mp := v(2) + c.MaxMP()*v(3)/100; mp > 0 && d.mp != nil {
		mpNow = d.mp.Restore(characterID, c.MaxMP(), mp)
	}
	_ = sendRevived(ctx, sess, c, mpNow, RegenDeps{Equipment: d.eq, Items: d.items, Skills: d.skills, Mana: d.mp})
	return true
}
