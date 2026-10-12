package session

// Chain skills, link by link (round 785). READ (the server's own
// CGCharAutoCommandActor skill tick, 0x4ae590; docs/protocol/skill_attack.md
// "Chains"): the client sends only the head; the server walks
// Basic_ChainCode itself and posts every link as its own action, which runs
// its own gate (mask 0x91: its cooldown, its costs), its own context builder
// -- its own 'att', 'mc', 'efr' and states -- and its own 0xB070 with a new
// cast id. The timing: a 500 ms budget B starts with the action; a link
// that is not the last waits its ActionDuration less what B still holds (B
// is spent first, what it absorbed is carried), and the next link is posted
// after max(CastingTime, that wait); the last link waits CastingTime +
// ActionDuration, plus the carry when it hands off, and its AutoAttackType
// alone decides the hand-off.
//
// The wire (OURS, the main agent's decision of round 785): every link after
// the head reaches the caster and its watchers as an OpSkillCast, the start
// and then the act, casterId the caster and skillId the link's, the act
// carrying the action block (actionblock.go). A client draws an OpSkillCast
// naming itself only when the skill is not the one it sent.

import (
	"context"
	"math"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// chainBudgetMs is the action's starting budget (0x4ac920 seeds +0x28 =
// 500, READ).
const chainBudgetMs = 500

// chainMaxLinks bounds a walk (OURS: no retail chain is longer than a few).
const chainMaxLinks = 16

// chainLinks is head's links in order (its ChainCode, theirs, ...), resolved
// through lookup; a link the table does not hold ends the walk.
func chainLinks(head *refdata.Skill, lookup func(int64) *refdata.Skill) []*refdata.Skill {
	var out []*refdata.Skill
	seen := map[int64]bool{head.ID: true}
	for code := head.BasicChainCode; code != 0 && len(out) < chainMaxLinks; {
		if seen[code] {
			break
		}
		seen[code] = true
		row := lookup(code)
		if row == nil {
			break
		}
		out = append(out, row)
		code = row.BasicChainCode
	}
	return out
}

// chainTiming is when each link posts, in ms after the head's post, and when
// the last link's hand-off fires (READ, 0x4aec2d..0x4aed02).
func chainTiming(rows []*refdata.Skill) (posts []int, handOff int) {
	budget, carry, t := chainBudgetMs, 0, 0
	for i, row := range rows {
		cast := row.PreparingTimeMs + row.CastingTimeMs
		if i == len(rows)-1 {
			return posts, t + cast + row.ActionDurationMs + carry
		}
		wait := row.ActionDurationMs
		switch {
		case budget > 0 && wait > budget:
			wait -= budget
			carry += budget
			budget = 0
		case budget > 0:
			budget -= wait
			wait = 0
		}
		if cast > wait {
			wait = cast
		}
		t += wait
		posts = append(posts, t)
	}
	return posts, t
}

// chainGen is each caster's chain generation: a new cast ends a chain still
// playing (OURS: retail queues the new action behind it, Push 0x4ad630;
// OpenSRO resolves every cast at once, so the older chain yields). The
// generations come from one process-wide sequence, so a caster's entry can
// be deleted (cancelChain) without a later chain reusing an old number.
var chainGen = struct {
	sync.Mutex
	seq uint64
	m   map[int64]uint64
}{m: map[int64]uint64{}}

func nextChain(casterID int64) uint64 {
	chainGen.Lock()
	defer chainGen.Unlock()
	chainGen.seq++
	chainGen.m[casterID] = chainGen.seq
	return chainGen.seq
}

// cancelChain ends the caster's chain, if one plays, and frees its entry.
func cancelChain(casterID int64) {
	chainGen.Lock()
	delete(chainGen.m, casterID)
	chainGen.Unlock()
}

func chainCurrent(casterID int64, gen uint64) bool {
	chainGen.Lock()
	defer chainGen.Unlock()
	g, ok := chainGen.m[casterID]
	return ok && g == gen
}

// forgetCharacterSkillState frees what the skill and quest runtimes keep per
// character once it has left the world (round 785 review: these maps only
// grew): its chain entry, its record rows, its passive set, a resurrection
// offer still waiting, and its cached quest log.
func forgetCharacterSkillState(characterID int64) {
	cancelChain(characterID)
	forgetRows(false, characterID)
	invalidatePassives(characterID)
	dropResurrectOffer(characterID)
	forgetQuestLog(characterID)
}

// cancelActions ends everything the server plays for the character on its
// own: the keep-up and a chain still posting links (round 785 review: the
// chain was cancelled only by a new cast). Every place the player's own
// action ends the keep-up -- a move, a sit, a new attack, death, a zone
// change, the logout -- calls this.
func cancelActions(characterID int64) {
	keepUp.Cancel(characterID)
	cancelChain(characterID)
}

// playChain schedules head's links against target. sess is the caster's.
func playChain(sess *gateway.Session, d combatDeps, casterID, target int64, head *refdata.Skill, links []*refdata.Skill) {
	gen := nextChain(casterID)
	if len(links) == 0 {
		return
	}
	rows := append([]*refdata.Skill{head}, links...)
	posts, handOff := chainTiming(rows)
	start := time.Now()
	started, _ := d.hub.EntityByCharacterID(casterID)
	for i, link := range links {
		i, link := i, link
		last := i == len(links)-1
		time.AfterFunc(time.Until(start.Add(time.Duration(posts[i])*time.Millisecond)), func() {
			if !chainCurrent(casterID, gen) {
				return
			}
			if !playLink(sess, d, casterID, target, link, started) {
				cancelChain(casterID) // the gate refused: the action ends (0x4aeb1c)
				return
			}
			if last && link.AutoAttackType == 1 {
				if m, ok := d.monsters.Get(target); ok && m.HP > 0 {
					armKeepUp(sess, d, casterID, target, time.Duration(handOff-posts[i])*time.Millisecond)
				}
			}
		})
	}
}

// chainLinkInReach is the reach test a link runs before its blow:
// skillInReach's approach band (combat.ApproachBand on the link's Range, or
// the weapon's) from where the caster stands now to where the monster is.
func chainLinkInReach(ctx context.Context, d combatDeps, casterID int64, caster world.Entity, m combat.Monster, link *refdata.Skill) bool {
	dist := math.Hypot(caster.Pos.X-m.X, caster.Pos.Z-m.Z)
	_, reach := combat.ApproachBand(combat.PlayerBCRadius, m.BCRadius,
		combat.EffectiveRange(link.Range, equippedWeaponRange(ctx, casterID, d.eq, d.items)))
	return combat.InReach(dist, reach)
}

// playLink resolves one link (its gate, its blow, its messages); false ends
// the chain.
func playLink(sess *gateway.Session, d combatDeps, casterID, target int64, link *refdata.Skill, started world.Entity) bool {
	ctx := context.Background()
	caster, ok := d.hub.EntityByCharacterID(casterID)
	if !ok || caster.Life != world.LifeAlive || caster.Zone != started.Zone || caster.Arrival != started.Arrival {
		return false
	}
	m, ok := d.monsters.Get(target)
	if !ok || m.HP <= 0 || m.Zone != caster.Zone {
		return false
	}
	// The link's reach (round 785 review): measured as the head's was
	// (skillInReach's band on the link's own range, the weapon's without
	// one). Out of reach the chain ends -- see chainLinkInReach.
	if !chainLinkInReach(ctx, d, casterID, caster, m, link) {
		return false
	}
	// The link's own gate (mask 0x91): its re-use timer, its costs. No link
	// costs anything (MEASURED); 97 carry a ReuseDelay of their own.
	now := time.Now()
	if link.ReuseDelayMs > 0 && d.skills != nil {
		if last, ever, err := d.skills.LastUsed(ctx, casterID, link.ID); err == nil && ever &&
			now.Before(last.Add(time.Duration(link.ReuseDelayMs)*time.Millisecond)) {
			return false
		}
		_ = d.skills.RecordUse(ctx, casterID, link.ID, now)
	}
	if refusal := skillCostRefusal(ctx, d.chars, d.mp, casterID, link.ConsumeHP, link.ConsumeMP); refusal != "" {
		return false
	}
	if link.ConsumeMP > 0 && d.mp != nil {
		if c, err := d.chars.GetByID(ctx, casterID); err == nil && c != nil {
			if _, ok := d.mp.Spend(casterID, c.MaxMP(), link.ConsumeMP); !ok {
				return false
			}
		}
	}
	flat, pct := skillDamageBonus(link)
	terms := skillBlowTerms{damageBonus: flat, damagePercent: pct, hits: link.HitsFor(),
		attackType: combat.AttackType(link.AttackType), masteryPercent: skillMasteryPercent(ctx, d.skills, casterID, link)}
	cc := newCastContext(ctx, d, casterID, caster, link, terms)
	action := &ActionBlock{Target: uint32(m.ID), TargetKind: ActionTargetMonster, HitCount: uint8(cc.terms.hits)}
	var outcomes []targetOutcome
	for _, tg := range collectSkillTargets(link, caster, m, d.monsters, equippedWeaponRange(ctx, casterID, d.eq, d.items)) {
		o, err := cc.strike(tg)
		if err != nil {
			return false
		}
		if o.ok {
			outcomes = append(outcomes, o)
		}
	}
	if len(outcomes) == 0 {
		return false
	}
	cc.apply(outcomes, action)
	wearWeapon(ctx, d.eq, casterID, cc.terms.hits)
	addSkillHate(cc, outcomes)
	levelUps, kills, err := payKills(ctx, d, casterID, outcomes, nil)
	if err != nil {
		return false
	}
	// The link's cast to the caster and its watchers: the start, then the
	// act with the block (OURS wire, the decision above).
	msg := SkillCast{CasterID: casterID, CasterKind: OwnerCharacter, SkillID: link.ID, CastID: nextCastID(),
		Phase: CastPhaseStart, TargetType: TargetEntity, TargetID: m.ID}
	view := zoneOf(d.hub, casterID)
	sendAboutOwner(view, casterID, OpSkillCast, msg.Encode())
	msg.Phase, msg.Action = CastPhaseAct, action
	sendAboutOwner(view, casterID, OpSkillCast, msg.Encode())
	if sess != nil {
		for _, lu := range levelUps {
			_ = sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: lu.Encode()})
		}
		for _, k := range kills {
			if k.exp != nil {
				sendExpGainTo(sess, *k.exp)
			}
		}
	}
	// The damage and the deaths to every watcher, the caster included: no
	// OpAttackResult answers a link.
	_ = announceOutcomes(ctx, d, sess, casterID, outcomes, kills, false)
	for _, o := range outcomes {
		if o.died && o.before.ID == target {
			return false // the chain's target fell: nothing left to strike
		}
	}
	return true
}
