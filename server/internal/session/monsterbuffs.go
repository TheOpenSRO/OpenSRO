package session

// Debuffs on monsters (round 785). A Target_Required 1, action-kind-3 row
// whose target groups are hostile -- the Warlock's damage-over-time links,
// the Bard's and Cleric's curses, Water Cancel's weakenings -- starts its
// record on the TARGET's book (SkillAction_Buff, 0x5830b0: the record is
// registered on each target, READ), and ApplySkillParamsToChar (0x594ac0)
// writes its stats into the monster's ParamKeeper (GObjMob has one at
// +0x1ec; READ). The monster's books are their own buff.Books: monster and
// character ids overlap. OpBuffStart / OpBuffEnd carry ownerKind 1 (round
// 616's field) to the players whose window holds the monster.

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// monsterBooks is every monster's book. Its owners live in a key space of
// their own (monsterKey), apart from the character ids its casters and
// links use (round 785 review: character 7 casting on monster 7 read as a
// self-cast, and the caster's link entries shared a key with monster 7).
var monsterBooks = monsterBookSet{buff.NewBooks(0)}

// monsterKey is monster id's owner key in monsterBooks: ^id, never a
// character id (those are >= 0).
func monsterKey(id int64) int64 { return ^id }

// monsterBookSet is buff.Books keyed by monster id.
type monsterBookSet struct{ b *buff.Books }

func (s monsterBookSet) Start(id int64, spec buff.Spec, now time.Time) (buff.Record, []buff.Record, buff.Refusal, buff.Speed) {
	return s.b.Start(monsterKey(id), spec, now)
}

func (s monsterBookSet) Active(id int64) []buff.Record { return s.b.Active(monsterKey(id)) }

func (s monsterBookSet) ExpireOwner(id int64, now time.Time) ([]buff.Record, buff.Speed) {
	return s.b.ExpireOwner(monsterKey(id), now)
}

func (s monsterBookSet) EndAll(id int64) ([]buff.Record, buff.Speed) {
	return s.b.EndAll(monsterKey(id))
}

func (s monsterBookSet) EndToken(id int64, token uint32) ([]buff.Record, buff.Speed) {
	return s.b.EndToken(monsterKey(id), token)
}

func (s monsterBookSet) ParamTotals(id int64) map[int]buff.Totals {
	return s.b.ParamTotals(monsterKey(id))
}

// startsMonsterDebuff reports whether a cast of ref is a debuff on a
// monster: action kind 3, Target_Required 1, no friendly group -- and,
// from the round 785 review, a row whose Param block says so: the block
// is there (a database imported before round 785 has none, and its rows
// strike as they always did), and the row deals no damage at the cast
// (no 'att', or an 'att' its 'lnks' link deals pulse by pulse). A hostile
// kind-3 row with an 'att' and no 'lnks' strikes (performSkillAttack).
func startsMonsterDebuff(ref *refdata.Skill) bool {
	if ref == nil || ref.ActionKind != 3 || !ref.TargetRequired ||
		ref.TargetSelf || ref.TargetAlly || ref.TargetParty || ref.TargetLand {
		return false
	}
	if !ref.HasParams() {
		return false
	}
	r := ref.Runs()
	return !r.Has("att") || r.Has("lnks")
}

// startMonsterDebuff starts ref, cast by casterID, on monster m's book and
// tells the players who see m. It reports whether the record started.
func startMonsterDebuff(d combatDeps, ref *refdata.Skill, casterID int64, m combat.Monster, now time.Time) bool {
	rec, ended, refused, _ := monsterBooks.Start(m.ID, buffSpec(ref, casterID), now)
	if refused != buff.NotRefused {
		return false
	}
	noteSkillDeps(d)
	rememberRow(true, m.ID, ref)
	if len(ended) > 0 {
		pushMonsterBuffEnd(d, m, ended)
	}
	msg := &BuffStart{OwnerID: m.ID, SkillID: rec.SkillID, Token: rec.Token, DurationMs: -1, RemainingMs: -1, OwnerKind: OwnerMonster}
	if rec.Timed() {
		msg.DurationMs = rec.Dura.Milliseconds()
		msg.RemainingMs = rec.Remaining(now).Milliseconds()
		token, id := rec.Token, m.ID
		time.AfterFunc(rec.Dura, func() { expireMonsterRecord(id, token) })
	}
	p := &proto.Packet{Opcode: OpBuffStart, Data: msg.Encode()}
	for _, e := range monsterWatchers(d.hub, d.monsters, m) {
		if e.Session != nil {
			sendMonsterPush(e.Session, p)
		}
	}
	startPeriodic(true, m.ID, casterID, ref, rec, now)
	return true
}

// expireMonsterRecord ends a timed monster record that ran its time (the
// buff ticker's rule, SkillAction_Buff's `elapsed > dura`).
func expireMonsterRecord(id int64, token uint32) {
	ended, _ := monsterBooks.ExpireOwner(id, time.Now().Add(time.Millisecond))
	d, ok := skillDeps()
	if !ok || len(ended) == 0 {
		return
	}
	if m, alive := d.monsters.Get(id); alive {
		pushMonsterBuffEnd(d, m, ended)
	}
}

// pushMonsterBuffEnd tells m's watchers that records ended.
func pushMonsterBuffEnd(d combatDeps, m combat.Monster, ended []buff.Record) {
	msg := &BuffEnd{OwnerID: m.ID, OwnerKind: OwnerMonster}
	for _, r := range ended {
		msg.Tokens = append(msg.Tokens, r.Token)
	}
	p := &proto.Packet{Opcode: OpBuffEnd, Data: msg.Encode()}
	for _, e := range monsterWatchers(d.hub, d.monsters, m) {
		if e.Session != nil {
			sendMonsterPush(e.Session, p)
		}
	}
}

// forgetMonsterBuffs drops a dead monster's records, rows and threat (its
// object is gone; nothing is sent, as forgetMonster sends nothing).
func forgetMonsterBuffs(id int64) {
	monsterBooks.EndAll(id)
	forgetRows(true, id)
	forgetThreat(id)
}

// castMonsterDebuff answers a debuff cast at a monster (the costs paid, the
// target tested): the record starts on the target and on every monster the
// row's 'efr' collector adds (SkillAction_Buff registers it on each target,
// READ), a row without a linked blow lands its states at once (round 659's
// zero-damage rule), and the zone hears the cast.
func castMonsterDebuff(ctx context.Context, sess *gateway.Session, d combatDeps, characterID int64, req *UseSkillRequest, castRow *refdata.Skill, now time.Time) error {
	res := echoed(req, &AttackResult{MonsterID: req.TargetMonsterID})
	m, ok := d.monsters.Get(req.TargetMonsterID)
	caster, in := d.hub.EntityByCharacterID(characterID)
	if !ok || !in {
		res.Error = "target not found"
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: res.Encode()})
	}
	linked := castRow.HasParams() && castRow.Runs().Has("lnks") && castRow.Runs().Has("att")
	action := &ActionBlock{Target: uint32(m.ID), TargetKind: ActionTargetMonster, HitCount: 1}
	for _, t := range collectSkillTargets(castRow, caster, m, d.monsters, equippedWeaponRange(ctx, characterID, d.eq, d.items)) {
		mm, alive := d.monsters.Get(t.ID)
		if !alive || mm.HP <= 0 {
			continue
		}
		if !startMonsterDebuff(d, castRow, characterID, mm, now) {
			continue
		}
		var bits uint32
		if !linked {
			bits = statusFX.applyToMonster(d, characterID, castRow, mm.ID, now)
		}
		noteStruck(d.monsters, mm.ID, characterID)
		action.Targets = append(action.Targets, ActionTarget{UID: uint32(mm.ID), Kind: ActionTargetMonster,
			Hits: []ActionHit{debuffEntryHit(castRow, linked, bits)}})
	}
	res.MonsterRemainingHP = int32(m.HP)
	if c, err := d.chars.GetByID(ctx, characterID); err == nil && c != nil {
		res.PlayerHP = int32(c.HP)
	}
	if d.zerk != nil {
		res.BerserkGauge = int32(d.zerk.Gauge(characterID))
		res.BerserkActive = d.zerk.Active(characterID)
	}
	res.Action = action
	if err := sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: res.Encode()}); err != nil {
		return err
	}
	announceCastWith(d.hub, characterID, req, castRow, action)
	return nil
}

// debuffEntryHit is a debuff cast's hit-block entry for one target: kind 0,
// no damage.
//
// The effect-only flag 0x10 is retail's (SR_GameServer Combat_ResolveDamage
// 0x58fd9f: a blow of no damage whose row passes FUN_00589f10, a test of the
// row's state fields, READ; that those fields are the row's state runs is
// INFERRED). Round 786: the client draws the "Resist" word for 0x10 with
// statusBits 0 (sro_client.exe FUN_00a47720, READ), so it is set only when
// the cast itself rolls states -- a row with state runs (StatusParams) that is
// not linked. A linked debuff lands its states with its pulses' blows (OURS),
// and a row with no state runs has nothing to resist: their entries carry the
// plain flag 1 (OURS), which the client draws as nothing (a plain 0).
func debuffEntryHit(castRow *refdata.Skill, linked bool, bits uint32) ActionHit {
	if !linked && castRow != nil && castRow.StatusParams != "" {
		return ActionHit{Kind: HitKindDamage, Flags: 0x10, Status: bits}
	}
	return ActionHit{Kind: HitKindDamage, Flags: HitFlagNormal, Status: bits}
}
