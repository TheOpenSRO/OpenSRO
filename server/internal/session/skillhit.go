package session

// A skill cast at monsters (round 785): every target the row's 'efr'
// collector names (skilltargets.go), every hit of the row's 'mc' count, each
// resolved as its own blow, and the retail action block (actionblock.go)
// that tells the clients all of it. performAttack (combat.go) is the plain
// swing's path; this is the same pipeline run per target and per hit, because
// Combat_ResolveDamage (0x58e5f0) runs its whole resolution inside `for each
// target { do { ... } while (hit < record[5]) }` (READ;
// docs/protocol/skill_attack.md has the hit's order and every term below).

import (
	"context"
	"math"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/buff"
	"github.com/OpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skillparam"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// skillBlowTerms are the cast's damage terms, resolved by the handler from
// the row exactly as before round 785.
type skillBlowTerms struct {
	damageBonus    int
	damagePercent  int
	masteryPercent int
	hits           int
	attackType     combat.AttackType
}

// skillTarget is one monster a cast strikes, the share of the blow it takes
// (the collector's per-entry byte, 100 for the primary) and its role (1: an
// imbue's extra target, whose physical half is zeroed, READ).
type skillTarget struct {
	ID    int64
	Share int
	Role  int
}

// targetOutcome is what one target took.
type targetOutcome struct {
	before   combat.Monster
	updated  combat.Monster
	died     bool
	blocked  bool // every hit blocked: no state lands (0x5906c0)
	drained  int  // what an 'lfst' row's hits heal its caster
	total    int
	watchers []world.Entity
	killHits []combat.Hit
	hits     []ActionHit
	ok       bool
}

// castContext is one cast's (or one periodic pulse's) resolution state.
type castContext struct {
	ctx      context.Context
	d        combatDeps
	casterID int64
	attacker world.Entity
	row      *refdata.Skill
	terms    skillBlowTerms
	level    int
	str, int int
	critBase int
	imbue    *imbueTerms
	kindIn   combat.KindInput
	now      time.Time
}

func newCastContext(ctx context.Context, d combatDeps, casterID int64, attacker world.Entity, row *refdata.Skill, terms skillBlowTerms) *castContext {
	c := &castContext{ctx: ctx, d: d, casterID: casterID, attacker: attacker, row: row, terms: terms, now: time.Now()}
	if ch, err := d.chars.GetByID(ctx, casterID); err == nil && ch != nil {
		c.level, c.str, c.int = ch.Level, ch.TotalStr(), ch.TotalInt()
	}
	if c.terms.hits < 1 {
		c.terms.hits = 1
	}
	// The critical exists for a physical blow only (att value[0] & 4; READ:
	// magic never crits): round(p12) + round(p12 x cr[1]/100) + cr[0], the
	// row's own 'cr' (a monster has no evade-critical: param 57 is not
	// published, combat.monsterEvasion).
	if c.terms.attackType.IsPhysical() || !c.terms.attackType.Known() {
		p12 := attackerCritical(ctx, casterID, d.eq, d.items)
		cr0, cr1 := 0, 0
		if row != nil && row.HasParams() {
			r := row.Runs()
			cr0, cr1 = int(r.Value("cr", 0)), int(r.Value("cr", 1))
		}
		c.critBase = combat.EvadedChance(p12+int(math.Round(float64(p12)*float64(cr1)/100))+cr0, monsterEvasion)
	}
	c.kindIn = combat.KindInput{AttackerIsPC: true}
	if _, t4, known := equippedWeaponType(ctx, casterID, d.eq, d.items); known {
		c.kindIn.WeaponTypeID4 = t4
	}
	c.imbue = imbueFor(ctx, d.skills, casterID, row)
	return c
}

// rowValue is the cast row's code value[i] (0 when absent).
func (c *castContext) rowValue(code string, i int) (int, bool) {
	if c.row == nil || !c.row.HasParams() {
		return 0, false
	}
	v, ok := c.row.Runs().Values(skillparam.Code(code))
	if !ok {
		return 0, false
	}
	if i < 0 || i >= len(v) {
		return 0, true
	}
	return int(v[i]), true
}

// strike resolves every hit of the cast on one target (READ, the order in
// docs/protocol/skill_attack.md "One hit"): critical, block, the damage with
// its terms, the area share, the imbue's add, the knockdown and knockback,
// the death bit; once the target fell (killed, knocked) the cast's later hits
// on it are void (kind 8, 0x5905ef).
func (c *castContext) strike(tg skillTarget) (targetOutcome, error) {
	d := c.d
	m, ok := d.monsters.Get(tg.ID)
	if !ok || m.HP <= 0 || m.Zone != c.attacker.Zone {
		return targetOutcome{}, nil
	}
	out := targetOutcome{before: m, blocked: true, ok: true}
	bonus := combat.SkillLevelPenalty(c.terms.damageBonus, c.level, m.Level)
	def, defPct := monsterDefence(m)
	// The monster's own block and parry through its debuffs (p10, p9 on its
	// book: Water Cancel's 'terd', ...).
	blockChance := combat.EvadedChance(monsterStat(m.ID, buff.ParamBlock, m.Block), playerEvadeBlock(c.ctx, c.casterID, d.eq))
	parry := float64(monsterStat(m.ID, buff.ParamParry, int(combat.MonsterRate(m.Level))))
	c.kindIn.TargetCodeName = m.CodeName
	perHitFixed, fixed := combat.FixedDamagePerHit(combat.SelectDamageKind(c.kindIn), m.CodeName)
	magical := c.terms.attackType.IsMagical() && !c.terms.attackType.IsPhysical()
	daPct, hasDa := c.rowValue("da", 0)
	atcaMask, hasAtca := c.rowValue("atca", 0)
	atcaPct, _ := c.rowValue("atca", 1)
	flags, recoverMs := knockFlags(m)
	cum, fell := 0, false
	for i := 0; i < c.terms.hits; i++ {
		h := ActionHit{Kind: HitKindDamage, Flags: HitFlagNormal}
		if fell {
			h.Kind, h.Flags = HitKindAbsorbed, 0 // the void hit
			out.hits = append(out.hits, h)
			continue
		}
		if c.d.zerk != nil && c.d.zerk.Active(c.casterID) {
			h.Flags |= 4 // the attacker in HWAN (body mode 1), READ
		}
		base, err := attackerDamageOf(c.ctx, c.casterID, c.str, c.int, d.eq, d.items, c.terms.attackType, c.level, m.Level, parry)
		if err != nil {
			return targetOutcome{}, err
		}
		base = combat.ApplyMasteryScale(base, c.terms.masteryPercent)
		blow := resolveBlow(base+bonus, defPct, def, c.critBase, blockChance, c.level, m.Level, c.casterID, m.ID)
		dmg := 0
		switch {
		case blow.Blocked:
			// A blocked hit jumps past the damage switch (0x58f0ef ->
			// 0x58f0fe, READ): kind 2, no damage, no state.
			h.Kind = HitKindBlocked
			h.Flags &^= HitFlagNormal
		case fixed:
			out.blocked = false
			dmg = perHitFixed
		default:
			out.blocked = false
			if tg.Role != 1 || magical {
				dmg = combat.ApplySkillPercent(blow.Damage, c.terms.damagePercent)
				// The attacker's damage percent and debuffed multiplier
				// (p128..131, p178/179), the target's multiplier (p174..177),
				// inside the mitigation's tail (READ 0x40e5a4, 0x40e75b).
				dmg = applyBuffDamage(c.casterID, magical, dmg)
				// A passive's variable on the row's getv key (passives.go).
				dmg = applyGetvDamage(c.casterID, c.row, dmg)
				dmg = applyMonsterTaken(m.ID, magical, dmg)
				if c.d.zerk != nil && c.terms.damagePercent != combat.SkillPercentZero {
					dmg = c.d.zerk.Boost(c.casterID, dmg)
				}
			}
			if blow.Critical {
				h.Flags = h.Flags&^HitFlagNormal | HitFlagCritical
			}
			// 'da' on a knocked-down target (READ 0x58f81a..0x58f8ca).
			if hasDa && knockedDown(m.ID, c.now) {
				dmg = dmg * daPct / 100
			}
			// The imbue's add (READ 0x58f28d..0x58f491).
			dmg += imbueHit(c.ctx, d, c.casterID, c.imbue, m, c.str, c.int, c.level)
			// 'atca' against a matching state (READ funcs_004.c:35017).
			if hasAtca && uint32(atcaMask)&statusFX.monsterMask(m.ID) != 0 {
				dmg = int(math.Round(float64(dmg) * (1 + float64(atcaPct)/100)))
			}
			dmg = areaShare(dmg, tg.Share)
			if dmg < 1 {
				dmg = 1 // the floor of a damaging row (READ)
			}
			// 'lfst', the HP drain, replaces the whole computation
			// (Formula_SkillDamageCappedByHP 0x40f750, READ).
			if d, ok := c.lfstDamage(m, cum, tg.Share); ok {
				dmg = d
				out.drained += d
			}
		}
		h.Damage = uint32(dmg)
		cum += dmg
		if h.Kind != HitKindBlocked && cum >= m.HP {
			h.Kind |= HitDied
			fell = true
		} else if h.Kind != HitKindBlocked && tg.Role == 0 {
			// Knockdown, then knockback (READ 0x58fef0..0x590350).
			if c.knock(&h, m, flags, recoverMs) {
				fell = true
			}
		}
		out.hits = append(out.hits, h)
	}
	out.total = cum
	return out, nil
}

// knock rolls the row's 'ko' then 'kb' on a target at pos and, on a hit,
// fills h's kind and position and holds the monster. It returns whether the
// target was knocked.
func (c *castContext) knock(h *ActionHit, m combat.Monster, flags, recoverMs int) bool {
	if ko0, ok := c.rowValue("ko", 0); ok && flags&1 != 0 && !knockedDown(m.ID, c.now) {
		ko1, _ := c.rowValue("ko", 1)
		if rollKnock(knockdownChance(ko0, ko1, m.Level), c.casterID, chanceKnockdown) {
			ms := recoverMs
			if c.row != nil {
				ms += c.row.ActionDurationMs
			}
			c.place(h, m, HitKindKnockdown, knockdownPush, knockState{until: c.now.Add(time.Duration(ms)*time.Millisecond + knockdownSlack), down: true})
			return true
		}
	}
	if kb0, ok := c.rowValue("kb", 0); ok && flags&2 != 0 {
		if rollKnock(kb0, c.casterID, chanceKnockback) {
			kb1, _ := c.rowValue("kb", 1)
			c.place(h, m, HitKindKnockback, float64(kb1), knockState{until: c.now.Add(knockbackHold)})
			return true
		}
	}
	return false
}

func (c *castContext) place(h *ActionHit, m combat.Monster, kind uint8, dist float64, k knockState) {
	dest := knockDestination(c.attacker.Pos, m, dist)
	landing, region, ix, iy, iz := truncatedLanding(m.Zone, dest)
	h.Kind = h.Kind&HitDied | kind
	h.Region, h.X, h.Y, h.Z = region, ix, iy, iz
	if _, _, _, ok := c.d.monsters.Place(m.ID, landing.X, landing.Z); ok {
		setKnock(m.ID, k)
	}
}

// apply lands each outcome's damage and states and files its target entry.
func (c *castContext) apply(outcomes []targetOutcome, action *ActionBlock) {
	d := c.d
	for i := range outcomes {
		o := &outcomes[i]
		var ok bool
		o.updated, o.died, ok, o.watchers, o.killHits = damageMonsterWatched(d.hub, d.monsters, o.before.ID, c.casterID, o.total)
		if !ok {
			o.ok = false
			continue
		}
		if o.died {
			noteMonsterKilled(d.hub, d.parties, o.killHits, o.updated)
		} else {
			noteStruck(d.monsters, o.before.ID, c.casterID)
			if !o.blocked {
				// Combat_ApplyStatusEffects runs inside the hit, so its bits
				// ride the hit record (hit+8, READ 0x58f72d); the imbue's own
				// states land too (its row, OR'd into the target entry).
				bits := statusFX.applyToMonster(d, c.casterID, c.row, o.before.ID, c.now)
				if c.imbue != nil {
					bits |= statusFX.applyToMonster(d, c.casterID, c.imbue.row, o.before.ID, c.now)
				}
				for j := range o.hits {
					if k := o.hits[j].Kind & 0x7f; k != HitKindBlocked && k != HitKindAbsorbed {
						o.hits[j].Status = bits
						break
					}
				}
			}
		}
		action.Targets = append(action.Targets, ActionTarget{UID: uint32(o.before.ID), Kind: ActionTargetMonster, Hits: o.hits})
	}
}

// performSkillAttack resolves a cast of castRow at the request's monster
// and its area, answers the caster with OpAttackResult (the action block
// attached), tells the zone, and pays the kills. report, when not nil,
// learns whether the primary was struck and whether it blocked every hit.
func performSkillAttack(ctx context.Context, d combatDeps, sess *gateway.Session, characterID int64,
	castRow *refdata.Skill, req *UseSkillRequest, terms skillBlowTerms, report *blowReport) error {
	chars, eq, items, hub, monsters, zerk := d.chars, d.eq, d.items, d.hub, d.monsters, d.zerk
	primaryID := req.TargetMonsterID
	refuse := func(msg string) error {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: msg, MonsterID: primaryID}).Encode()})
	}
	primary, ok := monsters.Get(primaryID)
	if !ok {
		return refuse("target not found")
	}
	attacker, ok := hub.EntityBySession(sess.ID())
	if !ok || attacker.Zone != primary.Zone {
		return refuse("target not found")
	}
	now := time.Now()
	playerHPNow := 0
	if ch, err := chars.GetByID(ctx, characterID); err == nil && ch != nil {
		playerHPNow = ch.HP
	}
	noteSkillDeps(d)

	action := &ActionBlock{Target: uint32(primaryID), TargetKind: ActionTargetMonster}
	// SPRINT ('tel3', round 785, skillmove.go): the caster is put beside the
	// target before the blow -- FUN_005862e0's tel3 branch builds the move in
	// the same context the blow resolves in, and EngageSkill applies it
	// (0x593540) before Skill_ApplyEffectsAndNotify.
	if limit, ok := sprintLimit(castRow); ok {
		dest := sprintDestination(attacker.Pos, world.Position{X: primary.X, Y: primary.Y, Z: primary.Z},
			float64(combat.PlayerBCRadius+primary.BCRadius), limit)
		landing, region, ix, iy, iz := truncatedLanding(attacker.Zone, dest)
		if moveBySkill(sess, hub, chars, req.SkillID, landing, now) {
			action.Flags |= ActionFlagMove
			action.MoveRegion, action.MoveX, action.MoveY, action.MoveZ = region, ix, iy, iz
			attacker.Pos = landing
		}
	}

	cc := newCastContext(ctx, d, characterID, attacker, castRow, terms)
	action.HitCount = uint8(cc.terms.hits)
	targets := collectSkillTargets(castRow, attacker, primary, monsters, equippedWeaponRange(ctx, characterID, eq, items))
	// The imbue's 'efr' collects again (role 1, READ 0x586b33..0x586b8f).
	if cc.imbue != nil {
		seen := map[int64]bool{}
		for _, t := range targets {
			seen[t.ID] = true
		}
		for _, t := range collectSkillTargets(cc.imbue.row, attacker, primary, monsters, 0)[1:] {
			if !seen[t.ID] {
				t.Role = 1
				targets = append(targets, t)
			}
		}
	}
	var outcomes []targetOutcome
	for _, tg := range targets {
		o, err := cc.strike(tg)
		if err != nil {
			return refuse("damage calculation failed")
		}
		if o.ok {
			outcomes = append(outcomes, o)
		}
	}
	if len(outcomes) == 0 {
		return refuse("target not found")
	}
	cc.apply(outcomes, action)
	if report != nil && outcomes[0].before.ID == primaryID {
		report.Landed, report.Blocked = true, outcomes[0].blocked
	}
	wearWeapon(ctx, eq, characterID, cc.terms.hits)
	addSkillHate(cc, outcomes)
	if drained := drainedBy(outcomes); drained > 0 {
		if e, ok := hub.EntityByCharacterID(characterID); ok {
			healCharacter(ctx, hub, chars, eq, items, d.skills, d.mp, e, drained, 0)
		}
	}

	// The caster's answer: the legacy single-target fields describe the
	// primary (the first outcome), the action block everything.
	first := outcomes[0]
	result := echoed(req, &AttackResult{MonsterID: first.before.ID, MonsterDamage: int32(first.total),
		MonsterRemainingHP: int32(first.updated.HP), MonsterDied: first.died, PlayerHP: int32(playerHPNow), Action: action})
	for _, h := range first.hits {
		if h.Flags&HitFlagCritical != 0 {
			result.PlayerCritical = true
		}
	}
	if zerk != nil {
		result.BerserkGauge = int32(zerk.Gauge(characterID))
		result.BerserkActive = zerk.Active(characterID)
	}
	levelUps, kills, err := payKills(ctx, d, characterID, outcomes, result)
	if err != nil {
		return err
	}
	// The primary's synchronous counter, as performAttack's legacy branch
	// (off under -monster-battle, where the AI tick strikes).
	var strike *MonsterAttacked
	if !first.died && first.ok && !monsterBattle.Load() && monsters.CounterattackReady(first.before.ID, time.Now()) && monsterMayAct(first.before.ID) {
		out, err := monsterStrike(ctx, strikeDeps{chars: chars, eq: eq, items: items, mp: d.mp, hub: hub, potions: d.potions}, first.updated, combat.MonsterSkill{}, characterID, cc.level)
		if err != nil {
			return err
		}
		if out.dropped {
			if hp, _, e := chars.ApplyDamage(ctx, characterID, 0); e == nil {
				result.PlayerHP = int32(hp)
			}
		} else {
			result.MonsterCritical = out.critical
			result.PlayerBlocked = out.blocked
			result.PlayerDamageTaken = int32(out.damage)
			result.PlayerDied = out.died
			result.PlayerHP = int32(out.hp)
			result.DeathExpLost = out.deathExpLost
			result.Wall = out.wall
			strike = out.message(first.before.ID, characterID)
		}
	}
	if err := sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: result.Encode()}); err != nil {
		return err
	}
	for _, lu := range levelUps {
		if err := sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: lu.Encode()}); err != nil {
			return err
		}
	}
	for _, k := range kills {
		if k.exp != nil {
			sendExpGainTo(sess, *k.exp)
		}
	}
	if err := announceOutcomes(ctx, d, sess, characterID, outcomes, kills, true); err != nil {
		return err
	}
	announceCastWith(hub, characterID, req, castRow, action)
	if strike != nil {
		var others []world.Entity
		for _, e := range first.watchers {
			if e.Session != nil && e.Session.ID() != sess.ID() {
				others = append(others, e)
			}
		}
		pushMonsterStrike(sess, others, strike)
		if strike.Wall.Broke {
			endBrokenWall(hub, characterID)
		}
		if strike.TargetDied {
			returnAfterKill(ctx, chars, eq, hub, characterID)
		}
	}
	return nil
}

// killPaid is one kill's payout, kept for the messages after the result.
type killPaid struct {
	id   int64
	gold int64
	exp  *charmsg.ExpGain
}

// payKills pays every kill of the cast (grantKill, as a blow's kill pays),
// summing what the caster's result reports.
func payKills(ctx context.Context, d combatDeps, characterID int64, outcomes []targetOutcome, result *AttackResult) ([]*LevelUp, []killPaid, error) {
	var levelUps []*LevelUp
	var kills []killPaid
	for _, o := range outcomes {
		if !o.died || !o.ok {
			continue
		}
		scratch := &AttackResult{}
		lu, gold, err := grantKill(ctx, d, characterID, o.before, scratch, o.killHits)
		if err != nil {
			return nil, nil, err
		}
		if result != nil {
			result.ExpGained += scratch.ExpGained
			result.SkillExpGained += scratch.SkillExpGained
			if scratch.PlayerHP != 0 {
				result.PlayerHP = scratch.PlayerHP
			}
			if d.zerk != nil {
				result.BerserkGauge = scratch.BerserkGauge
			}
		}
		if lu != nil {
			levelUps = append(levelUps, lu)
		}
		kills = append(kills, killPaid{id: o.before.ID, gold: gold, exp: scratch.expGain})
	}
	return levelUps, kills, nil
}

// announceOutcomes tells every target's watchers -- the caster's own
// session excepted when exclude is set (an OpAttackResult already told it) --
// its damage or its death. sess is the killer's (its quest credit).
func announceOutcomes(ctx context.Context, d combatDeps, sess *gateway.Session, characterID int64, outcomes []targetOutcome, kills []killPaid, exclude bool) error {
	for _, o := range outcomes {
		if !o.ok {
			continue
		}
		var others []world.Entity
		for _, e := range o.watchers {
			if e.Session != nil && (!exclude || sess == nil || e.Session.ID() != sess.ID()) {
				others = append(others, e)
			}
		}
		if o.died {
			var gold int64
			for _, k := range kills {
				if k.id == o.before.ID {
					gold = k.gold
				}
			}
			if err := announceKill(ctx, d, sess, others, characterID, o.before, gold, o.updated, o.killHits); err != nil {
				return err
			}
			continue
		}
		msg := &MonsterDamaged{MonsterID: o.before.ID, Damage: int32(o.total), RemainingHP: int32(o.updated.HP)}
		for _, e := range others {
			sendMonsterPush(e.Session, &proto.Packet{Opcode: OpMonsterDamaged, Data: msg.Encode()})
		}
	}
	return nil
}

// monsterDefence is a monster's flat and percent defence with its debuffs
// (params 5 and 7 on its own book, monsterbuffs.go) and bleeding's cut.
func monsterDefence(m combat.Monster) (flat, pct int) {
	flat = m.Defense - statusFX.monsterDefenceCut(m.ID)
	pct = m.DefensePercent
	all := monsterBooks.ParamTotals(m.ID)
	if t, ok := all[buff.ParamPhysDefFlat]; ok {
		flat = int(math.Round(t.Apply(float64(flat))))
	}
	if t, ok := all[buff.ParamPhysDefPct]; ok {
		pct = int(math.Round(t.Apply(float64(pct))))
	}
	return flat, pct
}

// applyMonsterTaken is the target's damage-taken multiplier, p174 (physical)
// or p176 (magical), its debuffs' 'odar' (READ: the defender's 174..177).
func applyMonsterTaken(id int64, magical bool, dmg int) int {
	p := buff.ParamDefenderMult
	if magical {
		p += 2
	}
	t, ok := monsterBooks.ParamTotals(id)[p]
	if !ok || dmg <= 0 {
		return dmg
	}
	out := int(float64(dmg) * t.Factor())
	if out < 1 {
		out = 1
	}
	return out
}

// lfstDamage is Formula_SkillDamageCappedByHP (0x40f750, READ): D =
// lfst[0] + the caster's getv BSHP variable (+ the 'mwhs' weapon term, OPEN:
// not added); when the target out-levels the caster D loses 2.5 % a level
// (0xb45e50), floored at trunc(D x 0.1); then trunc(share x D / 100), or
// what HP the target has left when D reaches it. The caster heals by it.
func (c *castContext) lfstDamage(m combat.Monster, taken, share int) (int, bool) {
	v, ok := c.rowValue("lfst", 0)
	if !ok {
		return 0, false
	}
	d0 := v + passiveVar(c.casterID, "BSHP")
	d := d0
	if diff := m.Level - c.level; diff > 0 {
		d = int(float64(d) * (1 - 2.5*float64(diff)/100))
		if floor := int(float64(d0) * 0.1); d < floor {
			d = floor
		}
	}
	left := m.HP - taken
	if d >= left {
		return max(left, 0), true
	}
	return d * share / 100, true
}

// drainedBy sums what a cast's 'lfst' hits took.
func drainedBy(outcomes []targetOutcome) int {
	n := 0
	for _, o := range outcomes {
		if o.ok {
			n += o.drained
		}
	}
	return n
}

// monsterStat is a monster's stat base through its book's entries.
func monsterStat(id int64, param int, base int) int {
	t, ok := monsterBooks.ParamTotals(id)[param]
	if !ok {
		return base
	}
	return int(math.Round(t.Apply(float64(base))))
}
