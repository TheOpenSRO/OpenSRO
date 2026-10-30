package session

import (
	"context"
	"encoding/binary"
	"math"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Job PvP (round 802; docs/protocol/jobs.md "Job PvP"). A player in a job
// suit attacks an opposed player -- a trader or hunter a thief, a thief a
// trader or hunter -- or that player's COS (the transport): the plain attack
// and the single-target offensive skills. READ in SR_GameServer.exe for the
// rules (CGObjPC::vslot_394, the caravan rule, the death cause, the job
// death and the kill credit; jobs/pvp.go has each); the blow is the cast's
// own pipeline with the defender's side a player's (its armour, parry, block
// and evasions) or a COS's (its row's defence), as the engine's
// Combat_ResolveDamage takes any object.
//
// The target kinds on OpenSRO's attack and skill requests (OURS wire):
//
//	OpAttack     {..., i64 target, [u8 kind]}  kind 3 a character, 4 a COS uid
//	OpUseSkill   targetType 3 names a character for a hostile row; a COS
//	             uid (>= 0x7e000000) under targetType 1 names a COS
//	OpPlayerStruck 0x0118 (the zone, the attacker too: his target
//	             window's HP; OURS): u32 attacker, u8 kind (0 character,
//	             2 COS), u32 target, i32 damage, u8 flags (1 crit, 2 blocked,
//	             4 died), i32 hp, i32 max hp; the struck character's own
//	             copy adds i64 the character exp its death cost
//
// OURS, disclosed: a hostile skill strikes its primary target only (an area
// row's other targets, players or monsters, are not collected against a
// player); knockdown, knockback, the imbue's add, 'da' / 'atca' and the
// skill's states do not apply to a player or a COS; the swing repeats on the
// base attack's re-use delay while the target is alive and in reach (the
// engine's keep-up, as for a monster); no PK system exists, so a pair that
// is not job-opposed is refused (jobs.AttackCode).

// OpPlayerStruck is the zone's news of a blow on a player or a COS.
const OpPlayerStruck uint16 = 0x0118

// The request's target kinds.
const (
	PvPTargetCharacter byte = 3
	PvPTargetCOS       byte = 4
)

// pvpTarget is a resolved player-side target: a character, or a COS with
// its owner.
type pvpTarget struct {
	kind  byte
	uid   uint32
	char  int64        // the character struck (0 for a COS)
	owner world.Entity // the character, or the COS's owner
	cos   *cosObj
}

// resolvePvPTarget finds the target of kind and id in the attacker's zone.
func resolvePvPTarget(hub *world.Hub, attacker world.Entity, kind byte, id int64) (pvpTarget, bool) {
	switch kind {
	case PvPTargetCharacter:
		e, ok := hub.EntityByCharacterID(id)
		if !ok || e.Zone != attacker.Zone {
			return pvpTarget{}, false
		}
		return pvpTarget{kind: kind, uid: uint32(id), char: id, owner: e}, true
	case PvPTargetCOS:
		o := cosWorld.get(uint32(id))
		if o == nil {
			return pvpTarget{}, false
		}
		cosWorld.mu.Lock()
		owner, zone, dead := o.owner, o.zone, o.dead
		cosWorld.mu.Unlock()
		if dead || zone != attacker.Zone {
			return pvpTarget{}, false
		}
		e, ok := hub.EntityByCharacterID(owner)
		if !ok {
			return pvpTarget{}, false
		}
		return pvpTarget{kind: kind, uid: uint32(id), owner: e, cos: o}, true
	}
	return pvpTarget{}, false
}

// isCOSUID reports an id in the COS uid range (cosUIDBase).
func isCOSUID(id int64) bool { return id >= int64(cosUIDBase) && id < npcUIDFloor }

// npcUIDFloor is where the NPCs' uids begin (npcspawn.UIDBase).
const npcUIDFloor = 0x7f000000

// pvpFighter is the job rules' view of a character.
func pvpFighter(ctx context.Context, d combatDeps, e world.Entity) jobs.Fighter {
	f := jobs.Fighter{Job: jobStateNow(ctx, e.CharacterID), Level: e.Level}
	f.InTown = safeRegions.Load() != nil && inTownAt(e)
	if d.parties != nil {
		if p, ok := d.parties.Get(e.CharacterID); ok && p != nil {
			f.PartyID = int64(p.ID)
		}
	}
	if f.Job == jobs.StateTrader {
		f.TradeGoods = haveTradeItem(ctx, e.CharacterID)
		f.TradeScale = lastTradeScale(e.CharacterID)
		f.SafeTrade = jobRecord(ctx, e.CharacterID).Safe.Status
	}
	return f
}

// pvpRefusal is vslot_394 for attacker against t: 0 to strike.
func pvpRefusal(ctx context.Context, d combatDeps, attacker world.Entity, t pvpTarget) uint16 {
	if t.owner.Life == world.LifeDead && t.cos == nil {
		return jobs.ErrWrongTarget
	}
	if attackerUntouchable(d.hub, t.owner.CharacterID) {
		return untouchableCode
	}
	own := t.owner.CharacterID == attacker.CharacterID
	// Round 844 (lane V): two guilds at war fight (guildwar.go).
	return jobs.AttackCode(pvpFighter(ctx, d, attacker), pvpFighter(ctx, d, t.owner), own, false,
		!own && guildsHostile(ctx, attacker.CharacterID, t.owner.CharacterID))
}

// untouchableCode is 0x3020 (s:0x5291d0's body-mode test).
const untouchableCode uint16 = 0x3020

// pvpRefusalText is the code's client key: the client resolves a result's
// "UIIT_" error through its text table (OURS: OpAttackResult has no code
// field). READ: the category-4 switch c:0x7b8b40 (table c:0x7bb868).
func pvpRefusalText(code uint16) string {
	switch code {
	case jobs.ErrWrongTarget:
		return "UIIT_SKILL_USE_FAIL_WRONGTARGET"
	case jobs.ErrNoBattleField:
		return "UIIT_MSG_SKILL_USE_FAIL_ITS_NOT_A_BATTLE_FIELD"
	case jobs.ErrPartyMember:
		return "UIIT_MSG_SKILL_USE_FAIL_CANT_ATTACK_PARTY_MEMBER"
	case jobs.ErrCaravanLevel1:
		return "UIIT_MSG_SKILL_USE_FAIL_CANT_ATTACK_CARAVAN_LEVEL1"
	case jobs.ErrPKProhibited:
		return "UIIT_MSG_SKILL_USE_FAIL_PK_PROHIBITED_IN_THIS_SERVER"
	case jobs.ErrYourLevelLow:
		return "UIIT_MSG_SKILL_USE_FAIL_YOUR_LEVEL_TOO_LOW_TO_PK"
	case jobs.ErrTargetLevelLow:
		return "UIIT_MSG_SKILL_USE_FAIL_TARGET_LEVEL_TOO_LOW_TO_PK"
	case untouchableCode:
		return untouchableRefusal
	case jobs.SilentRefusal:
		return ""
	}
	return invalidTargetRefusal
}

// pvpTargetPos is where t stands now.
func pvpTargetPos(t pvpTarget, now time.Time) world.Position {
	if t.cos != nil {
		cosWorld.mu.Lock()
		defer cosWorld.mu.Unlock()
		return t.cos.at(now)
	}
	pos := t.owner.Pos
	if t.owner.Move != nil {
		if p, _ := t.owner.Move.At(now); p != (world.Position{}) {
			pos = p
		}
	}
	return pos
}

// pvpInReach is characterInReach against the target's spot (a COS's own
// body radius, col 50).
func pvpInReach(ctx context.Context, d combatDeps, attacker world.Entity, t pvpTarget, skillRange int) bool {
	tp := pvpTargetPos(t, time.Now())
	dist := math.Hypot(attacker.Pos.X-tp.X, attacker.Pos.Z-tp.Z)
	tbc := combat.PlayerBCRadius
	if t.cos != nil {
		cosWorld.mu.Lock()
		tbc = t.cos.row.BCRadius
		cosWorld.mu.Unlock()
	}
	_, reach := combat.ApproachBand(combat.PlayerBCRadius, tbc,
		combat.EffectiveRange(skillRange, equippedWeaponRange(ctx, attacker.CharacterID, d.eq, d.items)))
	return combat.InReach(dist, reach)
}

// pvpHit is one hit of a blow on a player-side target.
type pvpHit struct {
	damage   int
	critical bool
	blocked  bool
}

// pvpStrike resolves every hit of a cast (or a swing: row the base attack)
// on t, the defender's side a player's or a COS's. READ: the order of
// castContext.strike (critical, block, the damage with its terms, the
// share); the rest is OURS (the package comment).
func pvpStrike(ctx context.Context, d combatDeps, attacker world.Entity, row *refdata.Skill, terms skillBlowTerms, t pvpTarget) ([]pvpHit, error) {
	c := newCastContext(ctx, d, attacker.CharacterID, attacker, row, terms)
	magical := terms.attackType.IsMagical() && !terms.attackType.IsPhysical()
	defLevel, def, block, parry := 0, 0, 0, 0.0
	defPct := 0.0
	critEvade := 0.0
	if t.cos != nil {
		cosWorld.mu.Lock()
		r := t.cos.row
		cosWorld.mu.Unlock()
		defLevel, def, defPct, block = r.Level, r.Defense(), float64(r.Level), r.Block()
		parry = float64(combat.MonsterRate(r.Level))
		critEvade = monsterEvasion
	} else {
		defLevel = t.owner.Level
		var err error
		if magical {
			def, err = defenderMagArmor(ctx, t.char, d.eq, d.items)
		} else {
			def, err = defenderArmor(ctx, t.char, d.eq, d.items)
		}
		if err != nil {
			return nil, err
		}
		defPct = playerMitigationPercent(ctx, t.char, d.eq, d.items, magical)
		block = defenderBlock(ctx, t.char, d.eq, d.items)
		parry, _ = defenderParryRate(ctx, t.char, d.eq, d.items)
		critEvade = playerEvadeCrit(ctx, t.char, d.eq)
	}
	critChance := 0
	if terms.attackType.IsPhysical() || !terms.attackType.Known() {
		p12 := attackerCritical(ctx, attacker.CharacterID, d.eq, d.items)
		cr0, cr1 := 0, 0
		if row != nil && row.HasParams() {
			r := row.Runs()
			cr0, cr1 = int(r.Value("cr", 0)), int(r.Value("cr", 1))
		}
		critChance = combat.EvadedChance(p12+int(math.Round(float64(p12)*float64(cr1)/100))+cr0, critEvade)
	}
	blockChance := combat.EvadedChance(block, playerEvadeBlock(ctx, attacker.CharacterID, d.eq))
	bonus := combat.SkillLevelPenalty(terms.damageBonus, c.level, defLevel)
	defenderID := t.char
	if t.cos != nil {
		defenderID = int64(t.uid)
	}
	var out []pvpHit
	for i := 0; i < c.terms.hits; i++ {
		base, err := attackerDamageOf(ctx, attacker.CharacterID, c.str, c.int, d.eq, d.items, terms.attackType, c.level, defLevel, parry)
		if err != nil {
			return nil, err
		}
		base = combat.ApplyMasteryScale(base, terms.masteryPercent)
		blow := resolveBlow(base+bonus, defPct, def, critChance, blockChance, c.level, defLevel, attacker.CharacterID, defenderID)
		h := pvpHit{critical: blow.Critical, blocked: blow.Blocked}
		if !blow.Blocked {
			dmg := combat.ApplySkillPercent(blow.Damage, terms.damagePercent)
			dmg = applyBuffDamage(attacker.CharacterID, magical, dmg)
			dmg = applyGetvDamage(attacker.CharacterID, row, dmg)
			// A player defender's damage-taken multiplier (round 838,
			// applyPlayerTaken), where skillhit.go applies a monster's.
			if t.cos == nil {
				dmg = applyPlayerTaken(t.char, magical, dmg)
			}
			if d.zerk != nil && terms.damagePercent != combat.SkillPercentZero {
				dmg = d.zerk.Boost(attacker.CharacterID, dmg)
			}
			if dmg < 1 {
				dmg = 1
			}
			h.damage = dmg
		}
		out = append(out, h)
	}
	return out, nil
}

// defenderMagArmor is defenderArmor's magical half (the items' MagDefense
// and their white groups, the buffs' param 6 not modelled: OURS).
func defenderMagArmor(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) (int, error) {
	return defenderDefence(ctx, characterID, eq, items, func(it *refdata.Item) (float64, float64, float64) {
		return it.MagDefenseMin, it.MagDefenseMax, it.PlusIncMagDef
	}, durability.ArmourMagDefenseGroup, durability.ShieldMagDefenseGroup)
}

// pvpOutcome is what a blow did.
type pvpOutcome struct {
	total    int
	hp       int
	maxHP    int
	died     bool
	critical bool
	blocked  bool
	expLost  int64 // a character victim's death penalty
}

// pvpApply lands hits on t, tells the zone and settles a death.
func pvpApply(ctx context.Context, d combatDeps, attacker world.Entity, t pvpTarget, hits []pvpHit) pvpOutcome {
	var out pvpOutcome
	out.blocked = true
	for _, h := range hits {
		out.total += h.damage
		out.critical = out.critical || h.critical
		out.blocked = out.blocked && h.blocked
	}
	now := time.Now()
	// Both sides enter the battle state (round 800, jobsuit.go).
	markBattle(d.hub, attacker.CharacterID, now)
	markBattle(d.hub, t.owner.CharacterID, now)
	if t.cos != nil {
		cosWorld.mu.Lock()
		before := t.cos.rec.HP
		out.maxHP = t.cos.row.MaxHP
		cosWorld.mu.Unlock()
		if out.total > 0 {
			cosTakeDamageBy(t.cos, out.total, attacker.CharacterID)
		}
		out.hp = before - out.total
		if out.hp <= 0 {
			out.hp, out.died = 0, true
			// A transport killed by an opposed player is a job kill of its
			// owner for the job exp (INFERRED: the kill credit's victim is
			// the COS's owner, s:0x4e1f60; the character bonus needs a PC
			// victim).
			jobKillCredit(ctx, d, attacker, t.owner, false)
			// Round 844 (lane V): a hostile member's COS is a war kill at
			// its own level (s:0x5c721x; "or [%s]'s belonging").
			if guildsHostile(ctx, attacker.CharacterID, t.owner.CharacterID) {
				cosWorld.mu.Lock()
				lvl := t.cos.rec.Level
				if lvl <= 0 {
					lvl = t.cos.row.Level
				}
				cosWorld.mu.Unlock()
				guildWarKill(ctx, attacker, t.owner, lvl, true)
			}
		}
	} else {
		hp, _, err := d.chars.ApplyDamage(ctx, t.char, out.total)
		if err == nil {
			out.hp = hp
		}
		if c, err := d.chars.GetByID(ctx, t.char); err == nil && c != nil {
			out.maxHP = c.MaxHP()
		}
		standOnHit(d.hub, t.char, out.total)
		if hp == 0 && out.total > 0 {
			sd := strikeDeps{chars: d.chars, eq: d.eq, items: d.items, mp: d.mp, hub: d.hub, potions: d.potions}
			killerSuit := jobStateNow(ctx, attacker.CharacterID) != jobs.StateNone
			job := jobs.JobDeathByPlayer(killerSuit, jobStateNow(ctx, attacker.CharacterID), jobStateNow(ctx, t.char))
			// Round 844 (lane V): cause 5, a war death (guildwar.go).
			war := !job && guildsHostile(ctx, attacker.CharacterID, t.char)
			setDeathCause(t.char, deathCause{job: job, killerLevel: attacker.Level, byPlayer: true, war: war})
			res, err := finishKill(ctx, sd, t.char, monsterStrikeOutcome{hp: 0})
			if err == nil && res.died {
				out.died = true
				out.expLost = res.deathExpLost
				// Left dead at 0, or (-player-dead-state off) respawned: the
				// HP the push reports either way (MonsterStrikes.leaves_dead).
				out.hp = res.hp
				if job {
					jobKillCredit(ctx, d, attacker, t.owner, true)
				}
				if war {
					guildWarKill(ctx, attacker, t.owner, t.owner.Level, false)
				}
			}
		}
	}
	var flags byte
	if out.critical {
		flags |= 1
	}
	if out.blocked {
		flags |= 2
	}
	if out.died {
		flags |= 4
	}
	kind := byte(0)
	if t.cos != nil {
		kind = 2
	}
	msg := binary.LittleEndian.AppendUint32(nil, uint32(attacker.CharacterID))
	msg = append(msg, kind)
	msg = binary.LittleEndian.AppendUint32(msg, t.uid)
	msg = binary.LittleEndian.AppendUint32(msg, uint32(int32(out.total)))
	msg = append(msg, flags)
	msg = binary.LittleEndian.AppendUint32(msg, uint32(int32(out.hp)))
	msg = binary.LittleEndian.AppendUint32(msg, uint32(int32(out.maxHP)))
	pkt := &proto.Packet{Opcode: OpPlayerStruck, Data: msg}
	for _, e := range d.hub.EntitiesInZone(attacker.Zone) {
		if e.Session == nil {
			continue
		}
		if t.cos == nil && e.CharacterID == t.char {
			own := binary.LittleEndian.AppendUint64(append([]byte(nil), msg...), uint64(out.expLost))
			e.Session.Send(&proto.Packet{Opcode: OpPlayerStruck, Data: own})
			continue
		}
		e.Session.Send(pkt)
	}
	// Flag off, a kill respawned the victim: to the return point, after the
	// push (returnAfterKill, as a monster's kill does).
	if out.died && t.cos == nil {
		returnAfterKill(ctx, d.chars, d.eq, d.hub, t.char)
	}
	return out
}

// pvpResult is the attacker's OpAttackResult for a blow on t.
func pvpResult(t pvpTarget, o pvpOutcome, playerHP int, hits int, row *refdata.Skill) *AttackResult {
	kind := ActionTargetCharacter
	ttype := TargetCharacter
	if t.cos != nil {
		ttype = PvPTargetCOS
	}
	action := &ActionBlock{Target: t.uid, TargetKind: kind, HitCount: uint8(hits)}
	return &AttackResult{MonsterID: int64(t.uid), MonsterDamage: int32(o.total), MonsterRemainingHP: int32(o.hp),
		MonsterDied: o.died, PlayerCritical: o.critical, PlayerHP: int32(playerHP), Action: action,
		TargetType: ttype, HasTargetType: true}
}

// handlePvPAttack is OpAttack at a character or a COS.
func handlePvPAttack(ctx context.Context, sess *gateway.Session, d combatDeps, characterID int64, kind byte, id int64) error {
	refuse := func(text string) error {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: text, MonsterID: id,
			TargetType: kind, HasTargetType: true}).Encode()})
	}
	attacker, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return refuse(notInWorldRefusal)
	}
	t, ok := resolvePvPTarget(d.hub, attacker, kind, id)
	if !ok {
		return refuse("target not found")
	}
	if code := pvpRefusal(ctx, d, attacker, t); code != 0 {
		pvpKeepUp.cancel(characterID)
		return refuse(pvpRefusalText(code))
	}
	// The ammunition (round 838, ammo.go): Tick_Attack's phase 0 gate.
	if base, ok := baseAttackOf(ctx, characterID, d.eq, d.items); ok {
		if r := ammoRefusal(ctx, d.chars, d.eq, d.items, characterID, base); r != "" {
			pvpKeepUp.cancel(characterID)
			return refuse(r)
		}
	}
	if !pvpInReach(ctx, d, attacker, t, 0) {
		return refuse(refusedTooFar)
	}
	if wait := swingWait(ctx, characterID, d.eq, d.items, d.skills, time.Now()); wait > 0 {
		pvpKeepUp.arm(sess, d, characterID, kind, id, wait)
		return nil
	}
	return pvpSwing(ctx, sess, d, characterID, attacker, t)
}

// pvpSwing is one plain swing at t, answered and repeated.
func pvpSwing(ctx context.Context, sess *gateway.Session, d combatDeps, characterID int64, attacker world.Entity, t pvpTarget) error {
	sw := plainSwingOf(ctx, characterID, d.eq, d.items)
	row, _ := baseAttackOf(ctx, characterID, d.eq, d.items)
	hits, err := pvpStrike(ctx, d, attacker, row, skillBlowTerms{damageBonus: sw.flat, damagePercent: sw.percent, hits: sw.hits, attackType: sw.atk}, t)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "damage calculation failed"}).Encode()})
	}
	// The ammunition (round 838, ammo.go): spent before the blow lands; none
	// left, no blow and the repeats end.
	if r := spendAmmo(ctx, sess, d.chars, d.eq, d.inv, d.items, characterID, row); r != "" {
		pvpKeepUp.cancel(characterID)
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: r, MonsterID: int64(t.uid),
			TargetType: t.kind, HasTargetType: true}).Encode()})
	}
	o := pvpApply(ctx, d, attacker, t, hits)
	wearWeapon(ctx, d.eq, characterID, sw.hits)
	hp := 0
	if c, err := d.chars.GetByID(ctx, characterID); err == nil && c != nil {
		hp = c.HP
	}
	if err := sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: pvpResult(t, o, hp, sw.hits, row).Encode()}); err != nil {
		return err
	}
	if !o.died {
		pvpKeepUp.arm(sess, d, characterID, t.kind, int64(t.uid), 0)
	} else {
		pvpKeepUp.cancel(characterID)
	}
	return nil
}

// pvpKeepUp repeats a player's swing at a player-side target on the base
// attack's re-use delay (the engine's keep-up, keepup.go, for a monster):
// it ends at a death, a refusal, out of reach, or a new request.
var pvpKeepUp = &pvpKeep{m: map[int64]*pvpRun{}}

type pvpKeep struct {
	mu sync.Mutex
	m  map[int64]*pvpRun
}

type pvpRun struct {
	kind  byte
	id    int64
	timer *time.Timer
}

func (k *pvpKeep) cancel(characterID int64) {
	k.mu.Lock()
	if r := k.m[characterID]; r != nil && r.timer != nil {
		r.timer.Stop()
	}
	delete(k.m, characterID)
	k.mu.Unlock()
}

func (k *pvpKeep) arm(sess *gateway.Session, d combatDeps, characterID int64, kind byte, id int64, wait time.Duration) {
	if wait <= 0 {
		wait = swingDelay(context.Background(), characterID, d)
	}
	k.mu.Lock()
	if r := k.m[characterID]; r != nil && r.timer != nil {
		r.timer.Stop()
	}
	run := &pvpRun{kind: kind, id: id}
	k.m[characterID] = run
	run.timer = time.AfterFunc(wait, func() {
		k.mu.Lock()
		cur := k.m[characterID]
		k.mu.Unlock()
		if cur != run {
			return
		}
		ctx := context.Background()
		attacker, ok := d.hub.EntityBySession(sess.ID())
		if !ok || attacker.Life == world.LifeDead {
			k.cancel(characterID)
			return
		}
		t, ok := resolvePvPTarget(d.hub, attacker, kind, id)
		if !ok || pvpRefusal(ctx, d, attacker, t) != 0 || !pvpInReach(ctx, d, attacker, t, 0) {
			k.cancel(characterID)
			return
		}
		if wait := swingWait(ctx, characterID, d.eq, d.items, d.skills, time.Now()); wait > 0 {
			k.arm(sess, d, characterID, kind, id, wait)
			return
		}
		_ = pvpSwing(ctx, sess, d, characterID, attacker, t)
	})
	k.mu.Unlock()
}

// swingDelay is the base attack's re-use delay (1 s without a row).
func swingDelay(ctx context.Context, characterID int64, d combatDeps) time.Duration {
	if ref, ok := baseAttackOf(ctx, characterID, d.eq, d.items); ok && ref.ReuseDelayMs > 0 {
		return time.Duration(ref.ReuseDelayMs) * time.Millisecond
	}
	return time.Second
}

// --- Deaths and kills ----------------------------------------------------------

// deathCause is what finishKill applies to a victim (ResolveDeathCause
// s:0x4e6590): a job death (cause 1) costs the job's own penalty and never
// the normal one.
type deathCause struct {
	job         bool
	killerLevel int
	byPlayer    bool
	// war is cause 5 (round 844, lane V; s:0x4e6590): killed by a member of
	// a guild at war with the victim's.
	war bool
}

var deathCauses sync.Map // int64 -> deathCause

// setDeathCause names the cause of the death about to be settled.
func setDeathCause(victim int64, c deathCause) { deathCauses.Store(victim, c) }

// takeDeathCause is the cause set for victim, if any.
func takeDeathCause(victim int64) (deathCause, bool) {
	v, ok := deathCauses.LoadAndDelete(victim)
	if !ok {
		return deathCause{}, false
	}
	return v.(deathCause), true
}

// jobDeathPenalty is the cause-1 handler (s:0x4e6820): the job exp falls by
// 3 x Unit(victim level) (0x30E6), the character exp by 6 x the exp unit at
// min(victim, killer) level -- OURS: never below the level's 0, OpenSRO has
// no level-down -- and the normal death penalty is not taken. It returns
// the character exp lost.
func jobDeathPenalty(ctx context.Context, chars character.Store, victim *character.Character, killerLevel int) int64 {
	if levelTable == nil {
		return 0
	}
	gainJobExp(ctx, victim.ID, -jobs.DeathLoss(levelTable.GoldMin(victim.Level)))
	lvl := victim.Level
	if killerLevel > 0 && killerLevel < lvl {
		lvl = killerLevel
	}
	unit, ok := levelTable.ExpUnit(lvl)
	if !ok {
		return 0
	}
	loss := jobs.JobDeathExpLoss(unit, 0)
	exp := victim.Exp - loss
	if exp < 0 {
		loss, exp = victim.Exp, 0
	}
	if loss > 0 {
		_ = chars.SetLeveling(ctx, victim.ID, victim.Level, exp, victim.StatPoints, victim.Str, victim.Int)
	}
	return loss
}

// jobKillCredit is the kill credit's cause-1 branch (s:0x4e1f60): the killer
// (or its party, s:0x5bd7f0) gains KillExp, and a player victim also pays
// the killer 3 x the exp unit at min(killer, victim) level.
func jobKillCredit(ctx context.Context, d combatDeps, killer, victim world.Entity, pcVictim bool) {
	if levelTable == nil {
		return
	}
	awardJobKillExp(ctx, d, killer, victim.Level, victim.Pos, victim.Zone)
	if pcVictim {
		lvl := victim.Level
		if killer.Level < lvl {
			lvl = killer.Level
		}
		if unit, ok := levelTable.ExpUnit(lvl); ok {
			giveCharacterExp(ctx, d, killer, jobs.JobKillCharExp(unit))
		}
	}
}

// awardJobKillExp pays a job kill's exp: solo, KillExp to the killer; in a
// party, each eligible member (alive, in the victim's zone, within 1000.0 of
// it; a hunter killer's members hunters only) its share (s:0x5bd7f0).
func awardJobKillExp(ctx context.Context, d combatDeps, killer world.Entity, victimLevel int, at world.Position, zone string) {
	vGold := levelTable.GoldMin(victimLevel)
	one := func(e world.Entity) int64 {
		return jobs.KillExp(vGold, levelTable.GoldMin(e.Level), jobStateNow(ctx, e.CharacterID) == jobs.StateTrader)
	}
	var members []world.Entity
	if d.parties != nil {
		if p, ok := d.parties.Get(killer.CharacterID); ok && p != nil {
			hunter := jobStateNow(ctx, killer.CharacterID) == jobs.StateHunter
			for _, m := range p.Members {
				e, ok := d.hub.EntityByCharacterID(m.CharacterID)
				if !ok || e.Life == world.LifeDead || e.Zone != zone || dist2(e.Pos, at) > 1000 {
					continue
				}
				if hunter && jobStateNow(ctx, e.CharacterID) != jobs.StateHunter {
					continue
				}
				members = append(members, e)
			}
		}
	}
	if len(members) <= 1 {
		gainJobExp(ctx, killer.CharacterID, one(killer))
		return
	}
	sum := 0
	for _, m := range members {
		sum += m.Level
	}
	for _, m := range members {
		if share := jobs.PartyJobShare(one(m), m.Level, sum, len(members)); share > 0 {
			gainJobExp(ctx, m.CharacterID, share)
		}
	}
}

// giveCharacterExp pays exp to e with its level-ups (the quest payout's
// path, quest.go payExp).
func giveCharacterExp(ctx context.Context, d combatDeps, e world.Entity, exp int64) {
	if exp <= 0 || !levelTable.Loaded() {
		return
	}
	unlock := character.LockLeveling(e.CharacterID)
	char, err := d.chars.GetByID(ctx, e.CharacterID)
	if err != nil || char == nil {
		unlock()
		return
	}
	newLevel, newExp, gained := levelTable.Advance(char.Level, char.Exp, exp)
	newStatPoints := char.StatPoints + gained*leveldata.StatPointsPerLevel
	newStr := char.Str + gained*character.StatGrowthPerLevel
	newInt := char.Int + gained*character.StatGrowthPerLevel
	if err := d.chars.SetLeveling(ctx, e.CharacterID, newLevel, newExp, newStatPoints, newStr, newInt); err != nil {
		unlock()
		return
	}
	var lu *LevelUp
	if gained > 0 {
		d.hub.SetLevel(e.CharacterID, newLevel)
		_ = d.chars.ResetHP(ctx, e.CharacterID)
		bonus := character.BonusOf(e.CharacterID)
		if d.mp != nil {
			d.mp.Refill(e.CharacterID, character.MaxMPWith(newInt, newLevel, bonus))
		}
		lu = &LevelUp{NewLevel: int32(newLevel), StatPoints: int32(newStatPoints)}
	}
	unlock()
	if e.Session == nil {
		return
	}
	g := charmsg.ExpGain{Exp: exp}
	if lu != nil {
		e.Session.Send(&proto.Packet{Opcode: OpLevelUp, Data: lu.Encode()})
		g.LevelUp = true
		g.StatPoints = uint16(lu.StatPoints)
	}
	sendExpGainTo(e.Session, g)
}

// jobMobKind is a monster's job kind by its code name (MEASURED: the 1,400
// TypeID 1/2/1/2 rows are MOB_THIEF_NPC_* and MOB_EU_THIEF_NPC_*, the 1/2/1/3
// rows MOB_HUNTER_NPC_* and MOB_EU_HUNTER_NPC_*); 0 for any other.
func jobMobKind(code string) int {
	switch {
	case strings.HasPrefix(code, "MOB_THIEF_NPC"), strings.HasPrefix(code, "MOB_EU_THIEF_NPC"):
		return jobs.MobNPCThief
	case strings.HasPrefix(code, "MOB_HUNTER_NPC"), strings.HasPrefix(code, "MOB_EU_HUNTER_NPC"):
		return jobs.MobNPCHunter
	}
	return 0
}

// jobMobKillCredit is the kill credit's job-mob branch (s:0x4e1f60): an NPC
// thief killed by a trader or hunter, an NPC hunter killed by a thief, pays
// job exp (solo or the party's split).
func jobMobKillCredit(ctx context.Context, d combatDeps, killerID int64, m combat.Monster) {
	kind := jobMobKind(m.CodeName)
	if kind == 0 || levelTable == nil {
		return
	}
	killer, ok := d.hub.EntityByCharacterID(killerID)
	if !ok {
		return
	}
	job := jobStateNow(ctx, killerID)
	if (kind == jobs.MobNPCThief && (job == jobs.StateTrader || job == jobs.StateHunter)) ||
		(kind == jobs.MobNPCHunter && job == jobs.StateThief) {
		awardJobKillExp(ctx, d, killer, m.Level, world.Position{X: m.X, Y: m.Y, Z: m.Z}, m.Zone)
	}
}

// performSkillAttackPvP is a damaging cast's blow on a player or a COS: the
// caster answered with the action block, the zone told (OpSkillCast and
// OpPlayerStruck), a death settled.
func performSkillAttackPvP(ctx context.Context, d combatDeps, sess *gateway.Session, characterID int64, row *refdata.Skill,
	req *UseSkillRequest, terms skillBlowTerms, t pvpTarget) error {
	attacker, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: notInWorldRefusal}).Encode()})
	}
	hits, err := pvpStrike(ctx, d, attacker, row, terms, t)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "damage calculation failed"}).Encode()})
	}
	// The ammunition (round 838, ammo.go), as performSkillAttack spends it.
	if r := spendAmmo(ctx, sess, d.chars, d.eq, d.inv, d.items, characterID, row); r != "" {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: r}).Encode()})
	}
	o := pvpApply(ctx, d, attacker, t, hits)
	hp := 0
	if c, err := d.chars.GetByID(ctx, characterID); err == nil && c != nil {
		hp = c.HP
	}
	res := pvpResult(t, o, hp, terms.hits, row)
	if err := sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, res).Encode()}); err != nil {
		return err
	}
	announceCastWith(d.hub, characterID, req, row, res.Action)
	return nil
}

// jobMobMayTarget is jobs.MobMayTarget for a monster's code name and a
// character's job state now (true for any monster that is not a job's).
func jobMobMayTarget(code string, characterID int64) bool {
	kind := jobMobKind(code)
	if kind == 0 {
		return true
	}
	// A COS is judged by its owner (s:0x4d2880 / 0x4d28b0; round 804).
	if isCOSUID(characterID) {
		o := cosWorld.get(uint32(characterID))
		if o == nil {
			return false
		}
		cosWorld.mu.Lock()
		characterID = o.owner
		cosWorld.mu.Unlock()
	}
	return jobs.MobMayTarget(kind, jobStateNow(context.Background(), characterID))
}
