package session

// Round 622: friendly-target casts (a heal or a party buff aimed at a
// character) and the cast broadcast that lets everyone in the zone see
// another player's cast. docs/protocol/skill_buffs.md, "Friendly targets"
// and "The cast broadcast", has the evidence; the READ addresses are
// repeated beside the code that follows them.

import (
	"context"
	"encoding/binary"
	"errors"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// TargetCharacter is OpUseSkill's fourth targetType (round 622): the
// targetMonsterId field names a CHARACTER. srrevamp's monster ids (combat.Hub)
// and character ids (the database) overlap, so the kind has to travel with
// the id, as OpBuffStart's ownerKind does. A server before round 622 answers
// such a request "malformed request": it names a target that server cannot
// resolve, and nothing is spent.
const TargetCharacter uint8 = 3

// OpSkillCast tells a zone that someone cast a skill (round 622): the
// retail cast messages 0xB070 (result 1: the cast starts on the caster --
// NetProcessInNavAndSkill::FUN_008a5fd0 reads u16 kind 0x3000/0x3002, u32
// skill id, u32 caster id, u32 and builds the caster's IDecoSkill through
// FUN_00a54f00) and 0xB071 (the skill acts -- FUN_008a4960 -> FUN_00a56680:
// u8 kind, u32 cast id, kind 1 forces the cast's SHOT through FUN_00a53090).
// srrevamp's own layout, sent to every session in the caster's zone except
// the caster's own (whose client drew the cast when it sent it):
//
//	{i64 casterId, u8 casterKind (0 character, 1 monster), i64 skillId,
//	 u32 castId, u8 phase (0 start, 1 act), u8 targetType (0 none, 1 monster,
//	 2 ground, 3 character), i64 targetId, f32 x, f32 y, f32 z}
//
// 43 bytes. castId pairs a start with its act (a server-wide counter that
// never yields 0, OURS, as the buff token is). The point is the ground
// target for targetType 2 and zero otherwise. 0x00FA was free (the same grep
// as rounds 616/617: the highest session opcode in use was OpSelfID 0x00F9).
// A client before round 622 drops an unknown opcode.
const OpSkillCast uint16 = 0x00FA

// The OpSkillCast phases.
const (
	CastPhaseStart uint8 = 0
	CastPhaseAct   uint8 = 1
)

// SkillCast is the OpSkillCast payload.
type SkillCast struct {
	CasterID   int64
	CasterKind uint8
	SkillID    int64
	CastID     uint32
	Phase      uint8
	TargetType uint8
	TargetID   int64
	X, Y, Z    float32
}

const skillCastSize = 43

func (r *SkillCast) Encode() []byte {
	b := make([]byte, skillCastSize)
	le := binary.LittleEndian
	le.PutUint64(b[0:], uint64(r.CasterID))
	b[8] = r.CasterKind
	le.PutUint64(b[9:], uint64(r.SkillID))
	le.PutUint32(b[17:], r.CastID)
	b[21] = r.Phase
	b[22] = r.TargetType
	le.PutUint64(b[23:], uint64(r.TargetID))
	le.PutUint32(b[31:], math.Float32bits(r.X))
	le.PutUint32(b[35:], math.Float32bits(r.Y))
	le.PutUint32(b[39:], math.Float32bits(r.Z))
	return b
}

func DecodeSkillCast(data []byte) (*SkillCast, error) {
	if len(data) < skillCastSize {
		return nil, errors.New("session: decoding SkillCast: short payload")
	}
	le := binary.LittleEndian
	return &SkillCast{
		CasterID:   int64(le.Uint64(data[0:])),
		CasterKind: data[8],
		SkillID:    int64(le.Uint64(data[9:])),
		CastID:     le.Uint32(data[17:]),
		Phase:      data[21],
		TargetType: data[22],
		TargetID:   int64(le.Uint64(data[23:])),
		X:          math.Float32frombits(le.Uint32(data[31:])),
		Y:          math.Float32frombits(le.Uint32(data[35:])),
		Z:          math.Float32frombits(le.Uint32(data[39:])),
	}, nil
}

var castIDs atomic.Uint32

func nextCastID() uint32 {
	for {
		if id := castIDs.Add(1); id != 0 {
			return id
		}
	}
}

// castActMax bounds how long after its start a cast's act is announced. OURS:
// the act waits the row's PreparingTime + CastingTime (castActDelay), and no
// real row needs more; a bound keeps a bad row from parking a timer for long.
const castActMax = 5 * time.Second

// castActDelay is when, after its start, the zone hears a cast act: the
// row's Action_PreparingTime + Action_CastingTime (skilldata cols 11 and 12).
// The retail server posts the cast (0xB070) when its skill tick enters phase
// 2 and the action (0xB071) when the context builder engages it, which waits
// CastingTime -- the server's +0x74 already holds PreparingTime + CastingTime
// (SkillGlobal::PostLoadSkillTable, auto_command.md). srrevamp resolves the
// cast itself at once (its blow, heal or buff land when the request is
// accepted), so only the announcement waits: an observer sees the cast's
// READY and WAIT run for the row's own time before its SHOT and ACT, as the
// retail client draws them. A catalog skill (no row) acts at once.
func castActDelay(ref *refdata.Skill) time.Duration {
	if ref == nil {
		return 0
	}
	d := time.Duration(ref.PreparingTimeMs+ref.CastingTimeMs) * time.Millisecond
	if d < 0 {
		return 0
	}
	if d > castActMax {
		return castActMax
	}
	return d
}

// othersInZone is characterID's zone without characterID, or nil when it is
// not in the world.
func othersInZone(hub *world.Hub, characterID int64) []world.Entity {
	var out []world.Entity
	for _, e := range zoneOf(hub, characterID) {
		if e.CharacterID != characterID {
			out = append(out, e)
		}
	}
	return out
}

// castAfterHook runs f after d: a time.AfterFunc, replaceable by a test
// under castAfterMu, since the handlers read it on their own
// goroutines.
var (
	castAfterMu   sync.Mutex
	castAfterHook = func(d time.Duration, f func()) { time.AfterFunc(d, f) }
)

func castAfter(d time.Duration, f func()) {
	castAfterMu.Lock()
	h := castAfterHook
	castAfterMu.Unlock()
	h(d, f)
}

// announceCast tells the caster's zone, the caster excepted, that a cast of
// ref started, and then that it acted after castActDelay. Called once the
// cast is accepted and paid for (a refused cast is never announced: retail
// sends 0xB070 result 1 only from a posted action). The act's audience is
// the zone at that moment.
func announceCast(hub *world.Hub, casterID int64, req *UseSkillRequest, ref *refdata.Skill) {
	if hub == nil {
		return
	}
	msg := SkillCast{CasterID: casterID, CasterKind: OwnerCharacter, SkillID: req.SkillID,
		CastID: nextCastID(), Phase: CastPhaseStart, TargetType: req.Target()}
	switch msg.TargetType {
	case TargetEntity, TargetCharacter:
		msg.TargetID = req.TargetMonsterID
	case TargetGround:
		msg.X, msg.Y, msg.Z = req.X, req.Y, req.Z
	}
	started, inWorld := hub.EntityByCharacterID(casterID)
	if !inWorld {
		return
	}
	sendToAll(othersInZone(hub, casterID), OpSkillCast, msg.Encode())
	act := msg
	act.Phase = CastPhaseAct
	send := func() {
		// Round 622's review: the act is dropped when the caster died, left
		// or arrived anew (a zone change or a teleport, world.Entity.Arrival)
		// since the start -- its cast did not run to its action there. The
		// start's own audience keeps the READY effects until their guard
		// (SkillEffects.READY_LOOP_MAX); OURS.
		now, ok := hub.EntityByCharacterID(casterID)
		if !ok || now.Life != world.LifeAlive || now.Arrival != started.Arrival || now.Zone != started.Zone {
			return
		}
		sendToAll(othersInZone(hub, casterID), OpSkillCast, act.Encode())
	}
	if d := castActDelay(ref); d > 0 {
		castAfter(d, send)
		return
	}
	send()
}

// The two refusals a friendly target draws, in the retail client's own words
// (MEASURED, textuisystem.txt's English column):
//   - noTargetRefusal is UIIT_SKILL_USE_FAIL_NONESELECTETARGET (0x3011),
//     which the retail client shows itself when a Target_Required 1 row with
//     TargetType_Animal, no Land and no Building is used with nothing
//     selected (FUN_0081ba10, 0x81be5e..0x81be99: the selected id at
//     0x110f80c+0x628 is 0, so `push 0x3011; call 0x778190`);
//   - invalidTargetRefusal is UIIT_SKILL_USE_FAIL_WRONGTARGET (0x3006), the
//     server's answer to a target its target test rejects (FUN_0058cc70 ->
//     FUN_0058d7a0, sent from PrepareAction case 4 in the skill tick's phase
//     0, before the approach walk and before anything is spent).
const (
	noTargetRefusal      = "The target is not selected."
	invalidTargetRefusal = "Invalid target"
)

// friendlyTargeted reports whether ref is a Target_Required 1 row aimed at
// a friend: TargetGroup_Self, _Ally or _Party set and no land target. Heal
// (id 149) is one; so are the party buffs.
//
// MEASURED over the retail skilldata's Service 1 rows with Target_Required 1
// and a friendly group (412 rows): every one carries TargetType_Animal 1,
// Land 0 and Building 0, and none that carries Self without Ally or Party
// carries TargetGroup_Enemy_M. So for every such row the retail client's
// 0x3011 test applies with nothing selected, and the server's target test
// rejects a monster (below).
func friendlyTargeted(ref *refdata.Skill) bool {
	return ref != nil && ref.TargetRequired && !ref.TargetLand &&
		(ref.TargetSelf || ref.TargetAlly || ref.TargetParty)
}

// friendlyTargetRefusal is the server's target test (FUN_0058d7a0, READ;
// registers ESI the skill, EBX the caster, EDI the target at 0x58cf3f) for a
// friendly row, over the two kinds of target srrevamp has, in the engine's
// order:
//
//  1. TargetGroup_DontCare (+0x9e) passes anything -- no friendly row
//     carries it (the census above), so it is not exported;
//  2. the caster must be a PC (vtable +0x1c) -- it always is here;
//  3. a target that is an NPC-NPC (+0x24) fails -- srrevamp cannot name one;
//  4. **Ally or Party (+0x99/+0x9a) with a target that is not a PC fails** --
//     a monster;
//  5. **no Self (+0x98) and the target is the caster fails**;
//  6. SelectDeadBody (+0x9f) with a living target fails (the resurrections;
//     not modelled: a dead target is refused below, as 0x58cc70 refuses a
//     dead one for a row without SelectDeadBody);
//  7. no Enemy_M (+0x9b) and the target is a monster fails (+0x28) -- the
//     two Self-only rows, which carry no Enemy_M; Enemy_M without Enemy_P
//     (+0x9c) and a PC target fails, and Enemy_P without Enemy_M and a
//     target that is not a PC fails (no friendly row carries Enemy_M
//     without Enemy_P -- MEASURED -- so a character target passes);
//  8. **Party alone (no Ally, no Self): both must be in a party and it must
//     be the same one** (GObjPC::PartyID on each);
//  9. a target in motion state 8 fails unless +0x240 -- not modelled (the
//     motion state 8 test is not reproducible, igobj_vtable.md).
//
// Before it, FUN_0058cc70 (the loop over the context's targets) refuses a
// target that does not resolve or stands where the caster's region test
// (FUN_00430ce0) fails -- srrevamp: not in the world or not in the caster's
// zone -- and, without SelectDeadBody, a dead one (life state 2 or 3).
// Every failure is 0x3006.
func friendlyTargetRefusal(hub *world.Hub, parties *party.Hub, ref *refdata.Skill, caster world.Entity, targetType uint8, targetID int64) (world.Entity, string) {
	switch targetType {
	case TargetNone:
		return world.Entity{}, noTargetRefusal
	case TargetEntity:
		// Steps 4 and 7: a monster is never a friendly row's target.
		return world.Entity{}, invalidTargetRefusal
	case TargetCharacter:
	default:
		return world.Entity{}, invalidTargetRefusal
	}
	var target world.Entity
	if targetID == caster.CharacterID {
		target = caster
	} else {
		t, ok := hub.EntityByCharacterID(targetID)
		if !ok || t.Zone != caster.Zone {
			return world.Entity{}, invalidTargetRefusal
		}
		target = t
	}
	if target.Life != world.LifeAlive {
		return world.Entity{}, invalidTargetRefusal
	}
	if !ref.TargetSelf && target.CharacterID == caster.CharacterID {
		return world.Entity{}, invalidTargetRefusal
	}
	if ref.TargetParty && !ref.TargetAlly && !ref.TargetSelf {
		if parties == nil {
			return world.Entity{}, invalidTargetRefusal
		}
		pc, inC := parties.Get(caster.CharacterID)
		pt, inT := parties.Get(target.CharacterID)
		if !inC || !inT || pc.ID != pt.ID {
			return world.Entity{}, invalidTargetRefusal
		}
	}
	return target, ""
}

// characterInReach is the skill tick's reach test (Action_IsTargetWithinReach,
// `int(dist) <= reach + 2`) for a character target: the same band a monster
// target gets (skillInReach), with the target's BCRadius the player body's
// (combat.PlayerBCRadius -- all 52 playable rows read 4). Retail walks the
// caster into reach instead (phase 1, MoveTowardObject); srrevamp's server
// cannot walk a player, so the client walks first and the server refuses
// "too far away" before anything is spent, as it does for a monster (round
// 534).
func characterInReach(ctx context.Context, eq equipment.Store, items combat.ItemLookup, caster, target world.Entity, skillRange int) bool {
	if caster.CharacterID == target.CharacterID {
		return true
	}
	dist := math.Hypot(caster.Pos.X-target.Pos.X, caster.Pos.Z-target.Pos.Z)
	_, reach := combat.ApproachBand(combat.PlayerBCRadius, combat.PlayerBCRadius,
		combat.EffectiveRange(skillRange, equippedWeaponRange(ctx, caster.CharacterID, eq, items)))
	return combat.InReach(dist, reach)
}

// healCharacter restores a Target_Required 1 heal's amounts to the target
// (Skill_ApplyHealToObject on each living target, 0x59461b..0x59463c; the
// pool adjust 0x4a87d0 runs only while the target's life state is 1), under
// the target's kill lock so a lethal blow and the heal are not interleaved,
// and pushes the target its stats so its bars move. It returns the target's
// HP after the heal (-1 when nothing was healed).
func healCharacter(ctx context.Context, hub *world.Hub, chars character.Store, eq equipment.Store, items combat.ItemLookup, skills skill.Store, mp *mana.Tracker, target world.Entity, hp, mpAmount int) int {
	l := killLock(target.CharacterID)
	l.Lock()
	if cur, ok := hub.EntityByCharacterID(target.CharacterID); !ok || cur.Life != world.LifeAlive {
		l.Unlock()
		return -1
	}
	c, err := chars.GetByID(ctx, target.CharacterID)
	if err != nil || c == nil || c.HP <= 0 {
		l.Unlock()
		return -1
	}
	newHP := c.HP
	if hp > 0 {
		if h, err := chars.Heal(ctx, c.ID, hp, c.MaxHP()); err == nil {
			newHP = h
		}
	}
	if mpAmount > 0 && mp != nil {
		mp.Restore(c.ID, c.MaxMP(), mpAmount)
	}
	l.Unlock()
	// The push, a TCP write, goes out after the lock, as regen's does.
	if target.Session != nil {
		if now, err := chars.GetByID(ctx, c.ID); err == nil {
			if result, err := buildCharacterStats(ctx, now, now.ID, eq, items, skills, mp); err == nil {
				_ = target.Session.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
			}
		}
	}
	return newHP
}

// startBuffOnLocked starts ref's buff on ownerID, cast by casterID, and tells
// the owner's zone -- the Target_Required 1 friendly buff (SkillAction_Buff,
// 0x5830b0, writes ctx+0x20 = 2 on a record it builds for a target that is
// not the caster: srrevamp's Record.SelfCast is CasterID == OwnerID). A
// Target_Required 1 row gets no overlap check at the gate (row 16 tests only
// Target_Required 0 rows without 'lnks'; skill_buffs.md, "The recast rule"),
// so buff.Books.Start is asked for none. The caller holds ownerID's buff lock.
func startBuffOnLocked(hub *world.Hub, ref *refdata.Skill, casterID, ownerID int64, now time.Time) startOutcome {
	// The target is looked at again under its buff lock (round 622's
	// review): one that died or left since the target test gets no record.
	if e, ok := hub.EntityByCharacterID(ownerID); !ok || e.Life != world.LifeAlive {
		return startFailed
	}
	zone := zoneOf(hub, ownerID)
	if zone == nil {
		return startFailed
	}
	return startCasterBuffOn(zone, ref, casterID, ownerID, now)
}

// sessionEntity is the session's entity (its character in the world).
func sessionEntity(hub *world.Hub, sess *gateway.Session) (world.Entity, bool) {
	if hub == nil || sess == nil {
		return world.Entity{}, false
	}
	return hub.EntityBySession(sess.ID())
}
