package session

import (
	"context"
	"fmt"
	"math"
	"sync"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/rates"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The monster's death distributor (round 712, party lane S2): who a kill pays
// and how much, as CGObjMob::vslot_399 (0x4c44a0) decides it. READ, GS;
// docs/protocol/party_rules.md "Kill EXP and SP":
//
//  1. The damage list is grouped. A player in a party whose flags have bit 0
//     (Exp Auto Share) is grouped by party; every other player (no party, or
//     an Exp Free-For-All party) is his own group. A group sums its damage and
//     keeps its single biggest hitter.
//  2. The group with the most damage, and its biggest hitter, is the KILL
//     CREDIT.
//  3. Each exp-share group gets the party share (FUN_005bca60): its members
//     alive, in the world and within 1000 units horizontally of the kill
//     credit -- which may belong to another group -- split the group's whole
//     damage by level, with the 10 %/20 % per-member bonus. Every other group
//     gets the individual award (FUN_004c4820): its one player, for his own
//     damage, with the Free-For-All 3 % per member.
//  4. The count of eligible members the share path writes is what the death
//     command arms the nest with (CAIState slot 7, FUN_00558f20); a
//     free-for-all kill leaves it at 0 (0x529e0a). With several exp-share
//     groups the last one written wins.
//
// Group order: the engine walks its own map, whose order is OPEN. OURS: groups
// in first-hit order (the same order UniqueKiller uses), so ties keep the
// first group met and the last exp-share group in that order sets the count.

// killAward is one receiver's award: the damage it is for (the receiver's own
// in an individual award, the whole group's in a party share) and the
// multiplier vslot_420 applies.
type killAward struct {
	characterID int64
	damage      int
	multiplier  float64
	// expShareParty is the receiver's party bit 0, the level-gap bonus's gate
	// (leveldata.ExpDiffScale); inParty picks ExpRatioParty (pc[0x72e]).
	expShareParty bool
	inParty       bool
}

// killPlan is what a death pays: the kill credit, the awards and the arming
// count.
type killPlan struct {
	credit   int64
	awards   []killAward
	armCount int
}

// killGroup is one group of vslot_399's map.
type killGroup struct {
	key        int64 // the party id, or -characterID for a player alone
	party      *party.Party
	solo       int64
	soloDamage int
	total      int
	best       int64
	bestDamage int
}

// planKill is vslot_399's plan for monster m from its damage list. hits are
// the attackers still in the world (presentHits). countryOf answers a
// character's Country (0 China, anything else counts as "other") for the
// party bonus; nil counts everyone as China -- enough for the arming count,
// which does not depend on it.
func planKill(hub *world.Hub, parties *party.Hub, m combat.Monster, hits []combat.Hit, countryOf func(int64) int) killPlan {
	var plan killPlan
	if hub == nil {
		return plan
	}
	var order []*killGroup
	byKey := map[int64]*killGroup{}
	for _, h := range hits {
		if h.AttackerID == 0 || h.Damage <= 0 {
			continue
		}
		key := -h.AttackerID
		var pt *party.Party
		if parties != nil {
			if p, in := parties.Get(h.AttackerID); in && p != nil && p.Flags.ExpShare() {
				key, pt = int64(p.ID), p
			}
		}
		g, seen := byKey[key]
		if !seen {
			g = &killGroup{key: key, party: pt}
			if pt == nil {
				g.solo = h.AttackerID
			}
			byKey[key] = g
			order = append(order, g)
		}
		g.total += h.Damage
		if pt == nil {
			g.soloDamage += h.Damage
		}
		if h.Damage > g.bestDamage {
			g.best, g.bestDamage = h.AttackerID, h.Damage
		}
	}
	var top *killGroup
	for _, g := range order {
		if top == nil || g.total > top.total {
			top = g
		}
	}
	if top == nil {
		return plan
	}
	plan.credit = top.best

	// The reference point of every party share: the kill credit's position,
	// or the victim's when the credit cannot be found (ECX at 0x4c4775).
	refZone, refX, refZ := m.Zone, m.X, m.Z
	if e, ok := hub.EntityByCharacterID(plan.credit); ok {
		refZone, refX, refZ = e.Zone, e.Pos.X, e.Pos.Z
	}

	for _, g := range order {
		if g.party == nil {
			plan.awards = append(plan.awards, soloAward(hub, parties, m, g.solo, g.soloDamage))
			continue
		}
		awards := partyShare(hub, m, g.party, g.total, refZone, refX, refZ, countryOf)
		plan.armCount = len(awards)
		plan.awards = append(plan.awards, awards...)
	}
	return plan
}

// soloAward is FUN_004c4820 for one player (READ, 0x4c4820-0x4c48c8): his own
// damage, 1 + (n-1)*0.03 in a party (n = every member), halved for a party
// monster below his level.
func soloAward(hub *world.Hub, parties *party.Hub, m combat.Monster, id int64, damage int) killAward {
	a := killAward{characterID: id, damage: damage}
	members := 0
	if parties != nil {
		if p, in := parties.Get(id); in && p != nil {
			members = len(p.Members)
			a.inParty = true
			a.expShareParty = p.Flags.ExpShare()
		}
	}
	below := false
	if e, ok := hub.EntityByCharacterID(id); ok && m.Party && m.Level < e.Level {
		below = true
	}
	a.multiplier = leveldata.FreeForAllMultiplier(members, below)
	return a
}

// partyShare is FUN_005bca60 (READ, 0x5bca60-0x5bcf2c): the members eligible
// -- in the world, alive, in the reference's world and within 1000 units of it
// on the ground plane -- split the group's damage by level.
//
// "In the same world" is the engine's world id (slot 5); OpenSRO has one world
// and keeps characters in zone buckets, so a member counts in the reference's
// zone (OURS, the approximation partyMembersNear and the aggro link already
// make). The engine's delta helper (0x430ad0) zeroes y and adds 1920 per
// region step, which OpenSRO's world coordinates already are, and answers
// 1e38 across the field/dungeon boundary, which a different zone stands for.
func partyShare(hub *world.Hub, m combat.Monster, p *party.Party, damage int, refZone string, refX, refZ float64, countryOf func(int64) int) []killAward {
	var ids []int64
	var levels []int
	chinese, others := 0, 0
	for _, mem := range p.Members {
		e, ok := hub.EntityByCharacterID(mem.CharacterID)
		if !ok || e.Life == world.LifeDead || e.Zone != refZone {
			continue
		}
		if math.Hypot(e.Pos.X-refX, e.Pos.Z-refZ) > leveldata.PartyShareRange {
			continue
		}
		ids = append(ids, mem.CharacterID)
		levels = append(levels, e.Level)
		if countryOf != nil && countryOf(mem.CharacterID) != character.RaceChina {
			others++
		} else {
			chinese++
		}
	}
	if len(ids) == 0 {
		return nil
	}
	bonus := leveldata.PartyShareBonus(chinese, others)
	penalty := leveldata.PartySharePenalty(m.Party, m.Level, levels)
	mults := leveldata.PartyShareMultipliers(levels, bonus, penalty)
	out := make([]killAward, len(ids))
	for i, id := range ids {
		out[i] = killAward{characterID: id, damage: damage, multiplier: mults[i], expShareParty: true, inParty: true}
	}
	return out
}

// killPayout is what one award paid.
type killPayout struct {
	exp, sp  int64
	expAdded int64 // what the character's EXP actually rose by (the level cap)
	levelUp  *LevelUp
	hp       int // the refilled HP after a level-up
}

// expLocks serialises one character's experience read-modify-write: a party
// share pays a member from whichever goroutine killed the monster, so two
// members' kills can pay a third at once.
var expLocks sync.Map // int64 -> *sync.Mutex

func lockExp(characterID int64) func() {
	v, _ := expLocks.LoadOrStore(characterID, &sync.Mutex{})
	mu := v.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}

// payKill executes a plan: each award is computed by the two contributor
// formulas, multiplied (vslot_420), given the rate bonus and applied as
// GainExpAndLevel does. It returns each receiver's payout.
func payKill(ctx context.Context, d combatDeps, m combat.Monster, plan killPlan) (map[int64]killPayout, error) {
	out := make(map[int64]killPayout, len(plan.awards))
	for _, a := range plan.awards {
		p, err := payAward(ctx, d, m, a)
		if err != nil {
			return out, err
		}
		prev := out[a.characterID]
		p.exp += prev.exp
		p.sp += prev.sp
		p.expAdded += prev.expAdded
		if p.levelUp == nil {
			p.levelUp, p.hp = prev.levelUp, prev.hp
		}
		out[a.characterID] = p
	}
	return out, nil
}

// payAward pays one award.
func payAward(ctx context.Context, d combatDeps, m combat.Monster, a killAward) (killPayout, error) {
	var out killPayout
	unlock := lockExp(a.characterID)
	defer unlock()
	char, err := d.chars.GetByID(ctx, a.characterID)
	if err != nil {
		return out, fmt.Errorf("combat: reading character for exp: %w", err)
	}
	exp, sp := killReward(ctx, d, m, a, char)
	exp, sp = leveldata.ApplyRewardMultiplier(exp, sp, a.multiplier)
	exp, sp = leveldata.ApplyRateBonus(exp, sp, rates.Current().ExpFor(a.inParty))
	out.exp, out.sp = exp, sp

	// GainExpAndLevel (slot 92): the skill experience, then the experience.
	if d.skills != nil && sp > 0 {
		if _, _, err := d.skills.AddSkillExp(ctx, a.characterID, sp); err != nil {
			return out, fmt.Errorf("combat: granting skill experience: %w", err)
		}
	}
	newLevel, newExp, gained := levelTable.Advance(char.Level, char.Exp, exp)
	out.expAdded = expAdded(levelTable, char.Level, char.Exp, newLevel, newExp)
	newStatPoints := char.StatPoints + gained*leveldata.StatPointsPerLevel
	newStr := char.Str + gained*character.StatGrowthPerLevel
	newInt := char.Int + gained*character.StatGrowthPerLevel
	if err := d.chars.SetLeveling(ctx, a.characterID, newLevel, newExp, newStatPoints, newStr, newInt); err != nil {
		return out, fmt.Errorf("combat: applying experience: %w", err)
	}
	if gained > 0 {
		if d.hub != nil {
			d.hub.SetLevel(a.characterID, newLevel)
		}
		if err := d.chars.ResetHP(ctx, a.characterID); err != nil {
			return out, fmt.Errorf("combat: refilling hp on level up: %w", err)
		}
		out.hp = character.MaxHPFor(newStr, newLevel)
		if d.mp != nil {
			d.mp.Refill(a.characterID, character.MaxMPFor(newInt, newLevel))
		}
		out.levelUp = &LevelUp{NewLevel: int32(newLevel), StatPoints: int32(newStatPoints)}
	}
	return out, nil
}

// killReward is the two contributor formulas for one award, before the
// multiplier (Formula_ExpRewardForContributor 0x410110, FUN_004106b0).
func killReward(ctx context.Context, d combatDeps, m combat.Monster, a killAward, char *character.Character) (exp, sp int64) {
	base, ok := levelTable.KillBase(char.Level, m.Level)
	if !ok {
		// A level table without this level's unit: the disclosed
		// toughness-derived ExpReward, as before round 712.
		base = m.ExpReward
	}
	best := bestMastery(ctx, d, a.characterID)
	unit, _ := levelTable.ExpUnit(char.Level)
	in := leveldata.RewardInput{
		Base:            base,
		MonsterFactor:   leveldata.MonsterExpFactor(m.Party, m.Rarity),
		Share:           leveldata.ContributorShare(a.damage, m.MaxHP),
		ReceiverLevel:   char.Level,
		VictimLevel:     m.Level,
		ExpShareParty:   a.expShareParty,
		Europe:          character.RaceOf(char.Gender) == character.RaceEurope,
		ExpLag:          1,
		SPLag:           1,
		ExpUnitReceiver: unit,
	}
	if best >= 0 {
		in.ExpLag = leveldata.MasteryExpScale(char.Level, best)
		in.SPLag = leveldata.MasterySPScale(char.Level, best)
	}
	return leveldata.ContributorExp(in), leveldata.ContributorSP(in)
}

// bestMastery is the character's highest mastery level, the reference of both
// mastery-lag scales; -1 when it cannot be read, which leaves both at 1.0 --
// the engine always has the number, so a missing one is OpenSRO's problem and
// should not cost a player 90 % of a kill (applyMasteryExpScale's rule).
func bestMastery(ctx context.Context, d combatDeps, characterID int64) int {
	if d.skills == nil {
		return -1
	}
	levels, err := d.skills.MasteryLevels(ctx, characterID)
	if err != nil {
		return -1
	}
	best := 0
	for _, lvl := range levels {
		if lvl > best {
			best = lvl
		}
	}
	return best
}

// countryOfStore answers a character's Country from its row, China when the
// row cannot be read.
func countryOfStore(ctx context.Context, chars character.Store) func(int64) int {
	return func(id int64) int {
		if chars == nil {
			return character.RaceChina
		}
		c, err := chars.GetByID(ctx, id)
		if err != nil {
			return character.RaceChina
		}
		return character.RaceOf(c.Gender)
	}
}

// distributeKill pays monster m's death to everyone its damage list earns a
// share (round 712). The killer's own payout is returned for its
// OpAttackResult; every other receiver whose share crossed a level is sent
// OpLevelUp here.
//
// GAP, not OURS: a receiver other than the killer is told nothing of the EXP
// and SP it gained. Retail tells every receiver with 0x3056
// (Client_ApplyExpAndLevelUp, docs/protocol/payload_layouts.tsv), which
// neither side of OpenSRO speaks yet; the row is updated and the next
// character load shows it.
func distributeKill(ctx context.Context, d combatDeps, killer int64, m combat.Monster, hits []combat.Hit) (killPayout, error) {
	plan := planKill(d.hub, d.parties, m, presentHits(d.hub, hits), countryOfStore(ctx, d.chars))
	paid, err := payKill(ctx, d, m, plan)
	if err != nil {
		return killPayout{}, err
	}
	for id, p := range paid {
		if id == killer || p.levelUp == nil {
			continue
		}
		if e, ok := entityOf(d.hub, id); ok && e.Session != nil {
			e.Session.Send(&proto.Packet{Opcode: OpLevelUp, Data: p.levelUp.Encode()})
		}
	}
	return paid[killer], nil
}
