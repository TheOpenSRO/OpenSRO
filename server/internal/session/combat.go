package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"math/rand"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/rates"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Combat opcodes, our own protocol. OpAttack requires a prior successful
// OpEnterWorld (the attacker's zone comes from world.Hub).
const (
	OpAttack            uint16 = 0x0060 // client -> server
	OpAttackResult      uint16 = 0x0061 // server -> client, direct ack to the attacker
	OpMonsterDamaged    uint16 = 0x0062 // server -> client, broadcast to the zone
	OpMonsterDied       uint16 = 0x0063 // server -> client, broadcast to the zone
	OpLootDropped       uint16 = 0x0064 // server -> client, direct to the killer (only sent if there's loot)
	OpMonsterList       uint16 = 0x0065 // client -> server
	OpMonsterListResult uint16 = 0x0066 // server -> client
	OpLevelUp           uint16 = 0x0067 // server -> client, direct to the character that levelled
	OpBerserk           uint16 = 0x0068 // client -> server, request to go berserk
	OpBerserkResult     uint16 = 0x0069 // server -> client, the gauge/active after the request
)

// damageRoll is the randomness behind a blow's damage range. Its own source
// rather than the global one, so a test can seed it and get a fixed blow, and
// so nothing else in the server perturbs the sequence. Guarded because
// rand.Rand is not safe for concurrent use and attacks arrive per session.
var (
	damageRollMu sync.Mutex
	damageRollNG = rand.New(rand.NewSource(time.Now().UnixNano()))
)

// rollDamage is combat.RollDamage under the lock.
func rollDamage(min, max int) int {
	damageRollMu.Lock()
	defer damageRollMu.Unlock()
	return combat.RollDamage(min, max, damageRollNG)
}

// rollCentred is combat.RollCentred under the same lock: the engine's
// centre-biased roll, which is what the ORDINARY attack takes (Combat_
// ResolveDamage's damage-kind case 0, params 13/14). RollDamage's uniform roll
// is a different damage kind.
func rollCentred(min, max int, centrePercent float64) int {
	damageRollMu.Lock()
	defer damageRollMu.Unlock()
	return combat.RollCentred(min, max, centrePercent, damageRollNG)
}

// rollGold is combat.RollGold under the SAME lock -- one generator, one mutex.
// An earlier version of this guarded it with a second mutex, which protects
// nothing: two locks around one rand.Rand is a data race, not synchronisation.
func rollGold(min, max, flat int64) int64 {
	damageRollMu.Lock()
	defer damageRollMu.Unlock()
	return combat.RollGold(min, max, flat, damageRollNG)
}

// BerserkResult reports the gauge (0..berserk.Max) and whether berserk is now
// active, after an OpBerserk request. Activated is true only when this request
// actually started a berserk (the gauge was full).
type BerserkResult struct {
	Activated bool
	Gauge     int32
	Active    bool
}

func (r *BerserkResult) Encode() []byte {
	buf := make([]byte, 6)
	if r.Activated {
		buf[0] = 1
	}
	binary.LittleEndian.PutUint32(buf[1:5], uint32(r.Gauge))
	if r.Active {
		buf[5] = 1
	}
	return buf
}

func DecodeBerserkResult(data []byte) (*BerserkResult, error) {
	if len(data) < 6 {
		return nil, errors.New("session: decoding BerserkResult: truncated")
	}
	return &BerserkResult{
		Activated: data[0] != 0,
		Gauge:     int32(binary.LittleEndian.Uint32(data[1:5])),
		Active:    data[5] != 0,
	}, nil
}

func handleBerserk(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, hub *world.Hub, zerk *berserk.Tracker) error {
	if zerk == nil {
		return sess.Send(&proto.Packet{Opcode: OpBerserkResult, Data: (&BerserkResult{}).Encode()})
	}
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpBerserkResult, Data: (&BerserkResult{}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpBerserkResult, Data: (&BerserkResult{}).Encode()})
	}
	// The berserk turn (round 632 review): the activation and its persisted
	// spend run as one against a potion or fill of the same character.
	release := zerk.Turn(characterID)
	defer release()
	if c, err := chars.GetByID(ctx, characterID); err == nil {
		zerk.EnsureSeeded(characterID, c.HwanCount)
	}
	// Round 786: not in the arrival's body mode 2 -- GObjPC_HandleBerserkMsg
	// refuses with its error 4 then (0x515b69, READ); the gauge is kept.
	if protectedNow(characterID, time.Now()) {
		return sess.Send(&proto.Packet{Opcode: OpBerserkResult, Data: (&BerserkResult{
			Gauge: int32(zerk.Gauge(characterID)), Active: zerk.Active(characterID),
		}).Encode()})
	}
	activated := zerk.Activate(characterID)
	if activated {
		// Activation spends orbs; the count lives on the character row.
		if err := chars.SetHwanCount(ctx, characterID, zerk.Charges(characterID)); err != nil {
			return fmt.Errorf("combat: persisting berserk spend: %w", err)
		}
		// The body-mode change, as the engine's SetBodyMode broadcasts it:
		// on now, and off when the berserk runs out (round 629's review).
		broadcastBodyMode(hub, characterID, 1)
		scheduleBerserkEnd(hub, zerk, characterID)
	}
	return sess.Send(&proto.Packet{Opcode: OpBerserkResult, Data: (&BerserkResult{
		Activated: activated, Gauge: int32(zerk.Gauge(characterID)), Active: zerk.Active(characterID),
	}).Encode()})
}

// broadcastBodyMode sends 0x30bf {id, kind 4, value[, 0]} to the character's
// zone, the character included -- GObjPC::BroadcastStateChange as
// CGObjChar::SetBodyMode calls it. The client's handler (0x8a80a0) runs
// FUN_00778ae0(0, 1) for its own player on value 1, which starts the orbs'
// berserk display; value 0 ends the body mode and leaves the display to its
// own timer. A character not in the hub (tests, a disconnect) hears nothing.
func broadcastBodyMode(hub *world.Hub, characterID int64, value byte) {
	if hub == nil {
		return
	}
	// Round 737: to the players in view that hold it (playerview.go); one
	// arriving later reads the body mode from its spawn record.
	msg := (&StateChange{ObjectID: uint32(characterID), Kind: StateKindBodyMode, Value: value}).Encode()
	bumpPlayerState(characterID)
	sendAboutPlayerPacket(hub, characterID, true, OpStateChange, msg)
}

// berserkEndDelay is how long after activation the end is pushed: until the
// tracker's ActiveUntil. A variable so a test can shorten it.
var berserkEndDelay = func(until time.Time) time.Duration { return time.Until(until) }

// scheduleBerserkEnd pushes the body-mode end when this activation runs out.
// The tracker expires lazily (Active compares the clock), so nothing else
// would say it; the engine's SetBodyMode timer does. A later activation, or
// an End (revive, zone change), moves ActiveUntil, and the older timer then
// stands down. The test and the push are one step under the character's
// berserk turn, so an activation cannot land between them and be followed by
// this older activation's "off".
func scheduleBerserkEnd(hub *world.Hub, zerk *berserk.Tracker, characterID int64) {
	until := zerk.ActiveUntil(characterID)
	time.AfterFunc(berserkEndDelay(until), func() {
		release := zerk.Turn(characterID)
		defer release()
		if !zerk.ActiveUntil(characterID).Equal(until) {
			return
		}
		broadcastBodyMode(hub, characterID, 0)
	})
}

// endBerserk ends the character's running berserk now, as the engine does
// when another body mode replaces mode 1, and tells the zone the body mode is
// 0. Its two callers:
//
//   - revive: READ. GObjPC::Revive (0x4df290) ends with SetBodyMode(2, 0,
//     6.0 s (0xb45b78) or 11.0 s (0xb45bb8), 0) -- body mode 2,
//     BODYMODE_INVINCIBLE, for that long -- which replaces mode 1, and
//     SetBodyMode broadcasts the change (kind 4, value 2).
//   - zone change: world entry is READ -- CGame::EnterWorld (0x417240, the
//     0x3012 SR_READY_TO_PLAY handler's) calls CGObjPC::vslot_391 (0x4df9e0)
//     once CGObj::EnterWorld succeeds, and vslot_391 sets body mode 2 (a
//     timer the world gives) or 4 -- but that a teleport is such a re-entry
//     is INFERRED: 0x34b5 (SR_RESET_CLIENT, sent from
//     CMainProcess::CharDataSavingCompleted 0x437de0) and its ack 0x34b6
//     (FUN_00402e60 -> FUN_00437e80, which hands the lobby entry off with
//     0x7005 and destroys it) were read; the path from the teleport handler
//     to them was not traced. The client resets its display on a zone
//     change (FUN_00787860, READ), and ending the server's berserk there
//     keeps the two consistent.
//
// OURS: the broadcast value is 0 here; the engine's 2 follows from the
// arrival's release or the revive (round 786, arrival.go startProtection),
// which broadcasts body mode 2 and its end on its own; the client's 0x30BF kind-4 handler
// starts the display only on value 1 and does nothing else to the orbs on
// either value (0x8a80a0, READ). A character with no running berserk hears
// nothing. The turn orders it against an activation of the same character.
func endBerserk(hub *world.Hub, zerk *berserk.Tracker, characterID int64) {
	if zerk == nil {
		return
	}
	release := zerk.Turn(characterID)
	defer release()
	if zerk.End(characterID) {
		broadcastBodyMode(hub, characterID, 0)
	}
}

// levelTable is the EXP curve the server was started with, or nil if the
// operator provided none (then characters accumulate raw exp but never level).
// It is server-wide static config, loaded once at startup by SetLevelTable and
// read-only after -- not per-request state.
var levelTable *leveldata.Table

// SetLevelTable installs the EXP curve the combat code levels characters
// against. Called once from cmd/server at startup.
func SetLevelTable(t *leveldata.Table) { levelTable = t }

// LevelUp is the OpLevelUp payload: the character's new level and how many
// unspent stat points it now has, so the client can announce the level-up and
// refresh the character window.
type LevelUp struct {
	NewLevel   int32
	StatPoints int32
}

func (r *LevelUp) Encode() []byte {
	out := make([]byte, 8)
	binary.LittleEndian.PutUint32(out[0:], uint32(r.NewLevel))
	binary.LittleEndian.PutUint32(out[4:], uint32(r.StatPoints))
	return out
}

func DecodeLevelUp(data []byte) (*LevelUp, error) {
	if len(data) < 8 {
		return nil, fmt.Errorf("session: decoding LevelUp: want 8 bytes, got %d", len(data))
	}
	return &LevelUp{
		NewLevel:   int32(binary.LittleEndian.Uint32(data[0:])),
		StatPoints: int32(binary.LittleEndian.Uint32(data[4:])),
	}, nil
}

// unarmedDamage is the base damage roll with no weapon equipped. Own design,
// disclosed: the number is invented, and it is the ROLL, not the blow.
//
// CORRECTED in round 505. This comment said an unarmed player would need a
// base attack skill with no weapon type and that the skill table has none.
// The empty hand's base attack exists: SKILL_PUNCH_01, id 1, which
// SkillGlobal::PostLoadSkillTable (0x5893e0) files for TypeID4 1 (and
// SkillBook::DefaultAttackSkillIDForWeaponTID 0x59e650 reads a TypeID4 of 0
// as 1). It requires weapon code 1, the bare hand (combat.WeaponBareHand),
// and its `att` is 5/150/0/0 -- physical, 150% of the roll, no flat damage.
// It is not one of the twelve `_BASE_01` rows, which ARE all weapon-typed:
//
//	CH  SWORD(2)  SPEAR(40)  BOW(70)
//	EU  SWORD(8419) TSWORD(8420) AXE(8421) CROSSBOW(9354) DAGGER(9355)
//	    STAFF(9944) WAND_WARLOCK(10625) HARP(11162) WAND_CLERIC(11526)
//
// What is still missing is the ROLL that 150% scales. A character's damage
// reaches the engine as ParamKeeper params 190/191, which
// Char_PublishCombatStats publishes from the equipment aggregate, and what an
// empty hand puts there is not read. So 5 stands in for that roll, and since
// round 505 the punch's 150% multiplies it after mitigation, as it does any
// weapon's roll (session.plainSwingOf).
//
// Guard against a plausible misreading while here: characterdata cols 84-86 on
// a PLAYER row are base-attack SKILL IDS, not a damage range. A Chinese row
// reads 2 / 40 / 70, which resolve to exactly the three CH base skills above;
// a European row reads 8419 / 8420 / 8421. Read as numbers, `[85]=40 [86]=70`
// looks like a tidy 40~70 damage range, and it is not one.
const unarmedDamage = 5

// AttackRequest is the OpAttack payload.
type AttackRequest struct {
	CharacterName   string
	TargetMonsterID int64
	// TargetKind (round 802, an optional trailing byte, OURS) names a
	// character (PvPTargetCharacter) or a COS (PvPTargetCOS); absent or any
	// other value, the id is a monster's.
	TargetKind byte
}

func (r *AttackRequest) Encode() []byte {
	out := append(encodeStrings(r.CharacterName), encodeInt64(r.TargetMonsterID)...)
	if r.TargetKind != 0 {
		out = append(out, r.TargetKind)
	}
	return out
}

func DecodeAttackRequest(data []byte) (*AttackRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding AttackRequest: %w", err)
	}
	targetID, tail, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding AttackRequest: target id: %w", err)
	}
	r := &AttackRequest{CharacterName: fields[0], TargetMonsterID: targetID}
	if len(tail) > 0 {
		r.TargetKind = tail[0]
	}
	return r, nil
}

// AttackResult is the OpAttackResult payload (direct reply to the
// attacker): what happened to the monster, and what happened to the
// attacker in the monster's counterattack (skipped if the monster died).
// On failure, only Error is meaningful.
type AttackResult struct {
	Error string

	// expGain is the killer's retail 0x3056 (round 716), not encoded here:
	// the attack path sends it after this result and the OpLevelUp, the
	// original's order (0x3056 is the last thing GainExpAndLevel sends).
	expGain *charmsg.ExpGain

	MonsterDamage      int32
	MonsterRemainingHP int32
	MonsterDied        bool

	PlayerDamageTaken int32
	PlayerHP          int32
	PlayerDied        bool // true if the counterattack killed the player (they've been respawned with full HP already)

	// BerserkGauge (0..berserk.Max) and BerserkActive drive the five HUD orbs
	// and the berserk aura; they ride along on every attack so the gauge fills
	// visibly as you fight.
	BerserkGauge  int32
	BerserkActive bool

	// MonsterCritical is true when the monster's counterattack landed a
	// critical -- real chance, real doubling. See combat.RollChance.
	MonsterCritical bool

	// PlayerCritical is true when the player's own blow was a critical. The
	// chance is the equipped weapon's Critical column (itemdata 116); see
	// attackerCritical.
	PlayerCritical bool

	// PlayerBlocked is true when the player's shield blocked the monster's
	// counterattack outright. A blocked hit deals nothing; see defenderBlock.
	PlayerBlocked bool

	// DeathExpLost is the experience the death penalty took, 0 when the
	// player did not die or is still inside the level-10 grace period. Real;
	// see leveldata.DeathPenaltyExp. Appended, so an older client that stops
	// reading at the berserk tail still decodes the rest.
	DeathExpLost int64

	// MonsterID names the monster this result is about -- the one that took
	// MonsterDamage and, if it survived, counterattacked. Without it the
	// client could only guess from "whatever I am targeting now", and a
	// retarget between the swing and its landing made the wrong monster
	// animate ("one Mangyang killed another"). Appended after the flag bytes,
	// so a client that stops at 34 bytes still decodes; 0 means unknown (an
	// old server, or a refusal before the target was resolved).
	MonsterID int64

	// TargetType echoes the OpUseSkill request's targetType (round 616,
	// docs/protocol/skill_buffs.md), a trailing u8 after MonsterID, so the
	// client can tell which request a result answers: a keep-up repeat, a
	// plain swing and a monster-initiated result carry TargetEntity (1).
	// Only a skill reply echoing TargetNone (0) or TargetGround (2) sets
	// HasTargetType; the zero value encodes 1, and a decoded 1 leaves both
	// fields zero. Read it through EchoedTargetType.
	TargetType    uint8
	HasTargetType bool

	// ExpGained and SkillExpGained are what a kill earned the attacker (round
	// 639): the experience added to the character and the skill experience
	// the 400:1 conversion was fed (leveldata.SkillExpPerPoint), 0 for a blow
	// that killed nothing or a server with no level table. Two trailing s64s
	// after the targetType byte, so a client that stops there still decodes.
	// The client writes them to its system-message window as retail's
	// Client_ApplyExpAndLevelUp (0x8a97c0) does with UIIT_MSG_STATE_GAIN_EXP
	// and UIIT_MSG_STATE_GET_SKILL_EXP. Retail carries them in its own EXP
	// packet; carrying them here is OURS (docs/protocol/system_message.md).
	ExpGained      int64
	SkillExpGained int64
	// Wall is the monster's counter meeting the player's protection wall
	// (round 640, walls.go WallInfo), or the toggle-off marker; a strict
	// suffix after round 639's EXP tail (ExpGained, SkillExpGained), sent
	// only when non-zero.
	Wall WallInfo
	// Action is the cast's retail action block (round 785, actionblock.go,
	// docs/protocol/skill_hit_block.md): every target, every hit, the
	// caster's move. When set, the wall suffix is always written (13 bytes,
	// zero for no wall) and the block follows it at offset 72.
	Action *ActionBlock
	// SkillID is the skill the result answers, 0 for a plain swing (the base
	// attack). It is written as a u32 right after the action block's
	// leading-target kind byte, and only when the block is (round 785
	// review, OURS): a keep-up swing's result arriving while a cast is
	// pending was otherwise drawn as the cast's answer. A client that stops
	// reading at the kind byte is unaffected.
	SkillID int64
}

// expAdded is the experience a character gained going from (level, exp) to
// (newLevel, newExp): the requirements of the levels passed plus the change in
// progress; never below 0.
func expAdded(t *leveldata.Table, level int, exp int64, newLevel int, newExp int64) int64 {
	added := newExp - exp
	for l := level; l < newLevel; l++ {
		if need, ok := t.ExpToNext(l); ok {
			added += need
		}
	}
	if added < 0 {
		return 0
	}
	return added
}

// EchoedTargetType is the targetType the result carries on the wire.
func (r *AttackResult) EchoedTargetType() uint8 {
	if r.HasTargetType {
		return r.TargetType
	}
	return TargetEntity
}

func (r *AttackResult) Encode() []byte {
	out := encodeStrings(r.Error)
	buf := make([]byte, 34)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.MonsterDamage))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.MonsterRemainingHP))
	if r.MonsterDied {
		buf[8] = 1
	}
	binary.LittleEndian.PutUint32(buf[9:13], uint32(r.PlayerDamageTaken))
	binary.LittleEndian.PutUint32(buf[13:17], uint32(r.PlayerHP))
	if r.PlayerDied {
		buf[17] = 1
	}
	binary.LittleEndian.PutUint32(buf[18:22], uint32(r.BerserkGauge))
	if r.BerserkActive {
		buf[22] = 1
	}
	binary.LittleEndian.PutUint64(buf[23:31], uint64(r.DeathExpLost))
	if r.MonsterCritical {
		buf[31] = 1
	}
	if r.PlayerCritical {
		buf[32] = 1
	}
	if r.PlayerBlocked {
		buf[33] = 1
	}
	// Trailing, additive: see MonsterID's doc comment.
	buf = append(buf, encodeInt64(r.MonsterID)...)
	// Trailing again (round 616): the echoed targetType.
	buf = append(buf, r.EchoedTargetType())
	// And again (round 639): the kill's experience and skill experience.
	buf = append(buf, encodeInt64(r.ExpGained)...)
	buf = append(buf, encodeInt64(r.SkillExpGained)...)
	// Trailing again (round 640): the wall suffix, only when there is one,
	// so every result without a wall is byte for byte what it was.
	if r.Wall != (WallInfo{}) || r.Action != nil {
		buf = append(buf, r.Wall.encode()...)
	}
	// Trailing again (round 785): the action block, after a wall suffix
	// that is then always present.
	if r.Action != nil {
		buf = r.Action.encode(buf)
		// And the skill id after it (round 785 review): 0 = a plain swing.
		buf = binary.LittleEndian.AppendUint32(buf, uint32(r.SkillID))
	}
	return append(out, buf...)
}

func DecodeAttackResult(data []byte) (*AttackResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding AttackResult: %w", err)
	}
	if len(rest) < 18 {
		return nil, errors.New("session: decoding AttackResult: truncated")
	}
	r := &AttackResult{
		Error:              fields[0],
		MonsterDamage:      int32(binary.LittleEndian.Uint32(rest[0:4])),
		MonsterRemainingHP: int32(binary.LittleEndian.Uint32(rest[4:8])),
		MonsterDied:        rest[8] != 0,
		PlayerDamageTaken:  int32(binary.LittleEndian.Uint32(rest[9:13])),
		PlayerHP:           int32(binary.LittleEndian.Uint32(rest[13:17])),
		PlayerDied:         rest[17] != 0,
	}
	// The berserk tail is appended, so an older 18-byte result still decodes.
	if len(rest) >= 23 {
		r.BerserkGauge = int32(binary.LittleEndian.Uint32(rest[18:22]))
		r.BerserkActive = rest[22] != 0
	}
	if len(rest) >= 31 {
		r.DeathExpLost = int64(binary.LittleEndian.Uint64(rest[23:31]))
	}
	if len(rest) >= 32 {
		r.MonsterCritical = rest[31] != 0
	}
	if len(rest) >= 33 {
		r.PlayerCritical = rest[32] != 0
	}
	if len(rest) >= 34 {
		r.PlayerBlocked = rest[33] != 0
	}
	if len(rest) >= 42 {
		r.MonsterID = int64(binary.LittleEndian.Uint64(rest[34:42]))
	}
	if len(rest) >= 43 && rest[42] != TargetEntity {
		r.TargetType, r.HasTargetType = rest[42], true
	}
	if len(rest) >= 59 {
		r.ExpGained = int64(binary.LittleEndian.Uint64(rest[43:51]))
		r.SkillExpGained = int64(binary.LittleEndian.Uint64(rest[51:59]))
	}
	if w, ok := decodeWallInfo(rest[min(len(rest), 59):]); ok {
		r.Wall = w
	}
	if len(rest) > 72 && rest[72] == actionBlockMarker {
		if b, after, err := DecodeActionBlock(rest[72:]); err == nil {
			r.Action = b
			if len(after) >= 4 {
				r.SkillID = int64(binary.LittleEndian.Uint32(after))
			}
		}
	}
	return r, nil
}

// MonsterDamaged is the OpMonsterDamaged broadcast payload.
type MonsterDamaged struct {
	MonsterID   int64
	Damage      int32
	RemainingHP int32
}

func (r *MonsterDamaged) Encode() []byte {
	out := encodeInt64(r.MonsterID)
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Damage))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.RemainingHP))
	return append(out, buf...)
}

func DecodeMonsterDamaged(data []byte) (*MonsterDamaged, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding MonsterDamaged: %w", err)
	}
	if len(rest) < 8 {
		return nil, errors.New("session: decoding MonsterDamaged: truncated")
	}
	return &MonsterDamaged{
		MonsterID:   id,
		Damage:      int32(binary.LittleEndian.Uint32(rest[0:4])),
		RemainingHP: int32(binary.LittleEndian.Uint32(rest[4:8])),
	}, nil
}

// MonsterDied is the OpMonsterDied broadcast payload.
type MonsterDied struct {
	MonsterID int64
}

func (r *MonsterDied) Encode() []byte { return encodeInt64(r.MonsterID) }

func DecodeMonsterDied(data []byte) (*MonsterDied, error) {
	id, _, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding MonsterDied: %w", err)
	}
	return &MonsterDied{MonsterID: id}, nil
}

// LootDrop is one item dropped from a monster kill.
type LootDrop struct {
	ItemID   int64
	Quantity int32
}

func (d *LootDrop) Encode() []byte {
	out := encodeInt64(d.ItemID)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(d.Quantity))
	return append(out, buf...)
}

func decodeLootDrop(data []byte) (*LootDrop, []byte, error) {
	itemID, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("item id: %w", err)
	}
	if len(rest) < 4 {
		return nil, nil, errors.New("truncated quantity")
	}
	return &LootDrop{ItemID: itemID, Quantity: int32(binary.LittleEndian.Uint32(rest))}, rest[4:], nil
}

// LootDropped is the OpLootDropped payload: everything a kill dropped for
// the killer, in one message (only sent if there's at least one drop).
type LootDropped struct {
	MonsterID int64
	Drops     []LootDrop
}

func (r *LootDropped) Encode() []byte {
	out := encodeInt64(r.MonsterID)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Drops)))
	out = append(out, countBuf...)
	for _, d := range r.Drops {
		out = append(out, d.Encode()...)
	}
	return out
}

func DecodeLootDropped(data []byte) (*LootDropped, error) {
	monsterID, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LootDropped: monster id: %w", err)
	}
	if len(rest) < 2 {
		return nil, errors.New("session: decoding LootDropped: truncated drop count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	r := &LootDropped{MonsterID: monsterID}
	for i := 0; i < count; i++ {
		var d *LootDrop
		d, rest, err = decodeLootDrop(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding LootDropped: drop %d: %w", i, err)
		}
		r.Drops = append(r.Drops, *d)
	}
	return r, nil
}

// MonsterSnapshot is one live monster, as sent over the wire.
type MonsterSnapshot struct {
	ID   int64
	Name string
	// CodeName is the species' characterdata key (MOB_CH_MANGNYANG); the
	// client resolves the model by it and only falls back to Name.
	CodeName string
	X, Y, Z  float32 // own design placeholder position -- see combat.Hub.Spawn
	MaxHP    int32
	HP       int32
	// Level is the monster's real level (characterdata _RefObjChar col 57), so
	// the target window can show it. 0 when unknown.
	Level int32
	// Rarity is the monster's rank (characterdata _RefObjChar col 15): 0 normal,
	// 1 champion, 3/8 unique, 4 giant, 5 titan, 6 elite -- the target window
	// picks its rank gem from it (mapping recovered from the retail client).
	Rarity int32
	// Party is the party-monster flag (round 660, combat.Monster.Party). It
	// travels in bit 8 of the rarity word (MonsterRarityPartyBit), and only to
	// a session that asked for it (MonsterListFlagParty): an older client
	// reads the word whole as the rank, and a party monster's 0x101 would
	// show it no rank at all (hud_target's table has no such rarity).
	Party bool
	// Body is the monster's body byte (round 805, combat.Monster.Body), sent
	// only to a session that asked (MonsterListFlagBody) -- HasBody says it
	// rides in this record.
	Body    byte
	HasBody bool
}

// MonsterRarityBodyBit marks a rarity word that carries the body byte in its
// third byte (bits 16..23, round 805). OURS framing of the original's one
// extra byte after the class byte (CGObjMob::vslot_294 s:0x4c19d6 sends it for
// an NPC thief or hunter only; OpenSRO sends it for every monster to a client
// that asked, and the client reads it for those two kinds).
const MonsterRarityBodyBit = 0x200

// MonsterRarityPartyBit is where the rarity word carries the party flag
// (round 660): bit 8, above every rank (0..8). OURS, an additive placeholder
// like every OpenSRO field (docs/protocol/PROTOCOL_DECISION.md). Retail
// sends one byte, `class | party << 4` (CICMonster::vslot_025 0x9d3850: `and
// cl,0xf` to +0x7ac at 0x9d38e1, `shr al,4` to +0x7ad at 0x9d38e7); OpenSRO's
// rarity word is a u32 already, so the flag rides in its second byte.
const MonsterRarityPartyBit = 0x100

func (m *MonsterSnapshot) Encode() []byte {
	out := append(encodeInt64(m.ID), encodeStrings(m.Name, m.CodeName)...)
	out = append(out, encodeFloat32(m.X)...)
	out = append(out, encodeFloat32(m.Y)...)
	out = append(out, encodeFloat32(m.Z)...)
	buf := make([]byte, 16)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(m.MaxHP))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(m.HP))
	binary.LittleEndian.PutUint32(buf[8:12], uint32(m.Level))
	rarity := uint32(m.Rarity)
	if m.Party {
		rarity |= MonsterRarityPartyBit
	}
	if m.HasBody {
		rarity |= MonsterRarityBodyBit | uint32(m.Body)<<16
	}
	binary.LittleEndian.PutUint32(buf[12:16], rarity)
	return append(out, buf...)
}

func decodeMonsterSnapshot(data []byte) (*MonsterSnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("monster id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 2)
	if err != nil {
		return nil, nil, fmt.Errorf("name: %w", err)
	}
	x, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("x: %w", err)
	}
	y, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("y: %w", err)
	}
	z, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("z: %w", err)
	}
	if len(rest) < 16 {
		return nil, nil, errors.New("truncated hp/level/rarity fields")
	}
	rarity := binary.LittleEndian.Uint32(rest[12:16])
	return &MonsterSnapshot{
		ID: id, Name: names[0], CodeName: names[1], X: x, Y: y, Z: z,
		MaxHP:   int32(binary.LittleEndian.Uint32(rest[0:4])),
		HP:      int32(binary.LittleEndian.Uint32(rest[4:8])),
		Level:   int32(binary.LittleEndian.Uint32(rest[8:12])),
		Rarity:  int32(rarity & 0xff),
		Party:   rarity&MonsterRarityPartyBit != 0,
		HasBody: rarity&MonsterRarityBodyBit != 0,
		Body:    byte(rarity >> 16),
	}, rest[16:], nil
}

// MonsterListResult is the OpMonsterListResult payload.
//
// Page and Pages are the paging trailer (round 656, monsterlist.go): a list
// too big for one frame goes as Pages frames, page 0 first, each one this
// payload with its share of the records and, after them, u16 Page and u16
// Pages. A list that fits one frame carries no trailer -- Pages 0 on both
// sides, the payload byte for byte what it always was -- and a client that
// predates the trailer reads a one-page list exactly as before (both decoders
// stop after the counted records).
type MonsterListResult struct {
	Error    string
	Monsters []MonsterSnapshot
	Page     uint16
	Pages    uint16
}

func (r *MonsterListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Monsters)))
	out = append(out, countBuf...)
	for _, m := range r.Monsters {
		out = append(out, m.Encode()...)
	}
	if r.Pages > 1 {
		out = append(out, byte(r.Page), byte(r.Page>>8), byte(r.Pages), byte(r.Pages>>8))
	}
	return out
}

func DecodeMonsterListResult(data []byte) (*MonsterListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding MonsterListResult: %w", err)
	}
	r := &MonsterListResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	if len(rest) < 2 {
		return nil, errors.New("session: decoding MonsterListResult: truncated monster count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *MonsterSnapshot
		snap, rest, err = decodeMonsterSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding MonsterListResult: monster %d: %w", i, err)
		}
		r.Monsters = append(r.Monsters, *snap)
	}
	// The paging trailer, when the page carries one (round 656).
	if len(rest) >= 4 {
		r.Page = binary.LittleEndian.Uint16(rest[0:2])
		r.Pages = binary.LittleEndian.Uint16(rest[2:4])
	}
	return r, nil
}

// monsterSnapshotOf is a live monster as one OpMonsterListResult record, the
// record OpMonsterSpawned carries too.
// The party flag is left off: monsterSnapshotFor adds it for a session that
// asked.
func monsterSnapshotOf(m combat.Monster) MonsterSnapshot {
	return MonsterSnapshot{
		ID: m.ID, Name: m.Name, CodeName: m.CodeName,
		X: float32(m.X), Y: float32(m.Y), Z: float32(m.Z),
		MaxHP: int32(m.MaxHP), HP: int32(m.HP), Level: int32(m.Level), Rarity: int32(m.Rarity),
	}
}

// monsterSnapshotFor is m's record as sess is sent it: with the party flag
// when sess asked for it (monsterPartyAsked, round 660).
func monsterSnapshotFor(sess *gateway.Session, m combat.Monster) MonsterSnapshot {
	s := monsterSnapshotOf(m)
	s.Party = m.Party && monsterPartyAsked(sess)
	if monsterBodyAsked(sess) {
		s.Body, s.HasBody = m.Body, true
	}
	return s
}

// monsterBodyKey is the session value that records MonsterListFlagBody.
const monsterBodyKey = "session.monsterBody"

// monsterBodyAsked reports whether sess reads the body byte (round 805).
func monsterBodyAsked(sess *gateway.Session) bool {
	if sess == nil {
		return false
	}
	v, ok := sess.Get(monsterBodyKey)
	b, _ := v.(bool)
	return ok && b
}

// monsterPartyKey is the session value that records a client's
// MonsterListFlagParty.
const monsterPartyKey = "session.monsterParty"

// monsterPartyAsked reports whether sess's monster list requests carry
// MonsterListFlagParty: it reads the party flag in the rarity word.
func monsterPartyAsked(sess *gateway.Session) bool {
	if sess == nil {
		return false
	}
	v, ok := sess.Get(monsterPartyKey)
	b, _ := v.(bool)
	return ok && b
}

// The spawn push (round 542): the server half of round 540's client
// (docs/protocol/monster_ai.md, "The strike and spawn pushes";
// client/scripts/net/combat.gd decode_monster_spawned). Until this round a
// respawn or a GM /spawn reached a client only on its next monster list.
// OpMonsterSpawned sends the new monster to everyone in its zone the moment it
// appears, with the heading it hatched facing (combat.Monster.Heading,
// Nest_Hatch's rand() / 32767.0 * 2pi: ai.SpawnHeading; monster_ai.md, "The
// _RefNest row", row 8). The pattern is the ground-item spawn push
// (OpGroundItemSpawned 0x006c, docs/protocol/ground_items.md): one packet to
// every session in the zone, a failed write left to that session's reader.
//
// Behind cmd/server's -monster-spawn-push (OPENSRO_MONSTER_SPAWN_PUSH), OFF by
// default: off, nothing is sent and the wire is what it was. It is flipped only
// once a client release that draws the push is out; an older client ignores
// 0x007E with an "unhandled opcode" warning.
//
// An additive placeholder like every opcode here
// (docs/protocol/PROTOCOL_DECISION.md). 0x007E was free: before round 540 no
// non-test file under server/ or client/scripts/net used it, and before this
// round none under server/ did (grep, 2026-09-24).
const OpMonsterSpawned uint16 = 0x007e // server -> every session in the zone: a monster that has just appeared

// MonsterSpawned is the OpMonsterSpawned payload: one record in
// OpMonsterListResult's own encoding, then an f32 heading in radians from +x
// toward +z (OpenSRO's world frame, never an engine angle). A new message
// rather than a longer list record: the list's records carry no per-record
// length, so no record can grow without breaking every client.
type MonsterSpawned struct {
	Monster MonsterSnapshot
	Heading float32
}

func (m *MonsterSpawned) Encode() []byte {
	return append(m.Monster.Encode(), encodeFloat32(m.Heading)...)
}

// DecodeMonsterSpawned refuses a payload whose record or heading is cut short,
// as the client does (CombatNet.decode_monster_spawned). Only tests call it --
// the message goes server to client.
func DecodeMonsterSpawned(data []byte) (*MonsterSpawned, error) {
	snap, rest, err := decodeMonsterSnapshot(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding MonsterSpawned: %w", err)
	}
	heading, _, err := decodeFloat32(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding MonsterSpawned: heading: %w", err)
	}
	return &MonsterSpawned{Monster: *snap, Heading: heading}, nil
}

// monsterSpawnPush is cmd/server's -monster-spawn-push, OFF by default. An
// atomic because cmd/server sets it on the boot goroutine while the roster's
// maintainMonster goroutines and the GM handler read it.
var monsterSpawnPush atomic.Bool

// SetMonsterSpawnPush turns the spawn push on or off. cmd/server calls it once
// at boot, before the first spawn, with -monster-spawn-push.
func SetMonsterSpawnPush(on bool) { monsterSpawnPush.Store(on) }

// BroadcastMonsterSpawned sends monster id to every session in its zone as an
// OpMonsterSpawned, when -monster-spawn-push is on; off, or for a monster that
// is already gone, it sends nothing. cmd/server's maintainMonster calls it after
// the first spawn and every respawn, and the GM console after each /spawn
// (session/gm.go), the GM included.
//
// The record is read through Get at the send, not off the live record
// SpawnSpecies returned (combat.Hub.SpawnSpecies: position and HP change under
// the hub's lock). It takes no monster AI wire lock (monsterAI.wireLock),
// which orders a list before the legs newer than it: a respawn is sent from
// the goroutine that spawned it, while its brain's first leg waits out at least
// one IDLE dwell (ai.DwellMs, 2001 ms or more), and a spawn push that did
// arrive after a leg would find the body walking, which the client leaves
// where it is drawn (unless it is past MonsterMotion.RESYNC_DISTANCE) and does
// not turn (World3D._on_monster_spawned).
func BroadcastMonsterSpawned(hub *world.Hub, monsters *combat.Hub, id int64) {
	if !monsterSpawnPush.Load() || hub == nil || monsters == nil {
		return
	}
	m, ok := monsters.Get(id)
	if !ok {
		return
	}
	// One packet per form a session reads (the party flag, round 660; the
	// body byte, round 805), made once each.
	forms := map[[2]bool]*proto.Packet{}
	packetFor := func(sess *gateway.Session) *proto.Packet {
		key := [2]bool{m.Party && monsterPartyAsked(sess), monsterBodyAsked(sess)}
		if p := forms[key]; p != nil {
			return p
		}
		msg := &MonsterSpawned{Monster: monsterSnapshotOf(m), Heading: float32(m.Heading)}
		msg.Monster.Party = key[0]
		if key[1] {
			msg.Monster.Body, msg.Monster.HasBody = m.Body, true
		}
		p := &proto.Packet{Opcode: OpMonsterSpawned, Data: msg.Encode()}
		forms[key] = p
		return p
	}
	// Round 656: to the players whose area of interest holds the new
	// monster's cell (aoi.go). Under the area-of-interest runtime it goes as
	// the checked enter (deliverViewEvents: sent only if the monster is alive
	// and in the player's window at the send, round 656's review), so a spawn
	// cannot reach a view that moved away from its cell meanwhile; without
	// it, each under the monster wire lock.
	v := aoiFor(monsters)
	for _, e := range monsterWatchers(hub, monsters, m) {
		if e.Session == nil {
			continue
		}
		if v != nil {
			v.deliverViewEvents(viewEvents{sess: e.Session, enters: []int64{id}})
			continue
		}
		sendMonsterPush(e.Session, packetFor(e.Session))
	}
}

// rollLoot rolls a kill's drops (real tables when the operator has supplied
// them, own-design otherwise -- see dropsForKill) and adds what it won to
// characterID's inventory, returning what actually landed. AddItem failures
// (unknown ref item, full inventory) are skipped rather than failing the whole
// kill -- loot is enrichment on top of a successful attack, not a precondition
// for one.
func rollLoot(ctx context.Context, inv inventory.Store, characterID int64, monster combat.Monster, src DropSource) []LootDrop {
	var landed []LootDrop
	for _, d := range dropsForKill(ctx, src, monster) {
		if err := inv.AddItem(ctx, characterID, d.ItemID, int(d.Quantity)); err != nil {
			continue
		}
		landed = append(landed, d)
	}
	return landed
}

// CombatHandler returns a gateway.Handler implementing OpAttack: resolves
// the attacker's equipped weapon (via eq/items) for damage, applies it to
// the target monster (via monsters), grants gold to the killer on death
// (via chars), and broadcasts to everyone in the attacker's zone (via hub).
func CombatHandler(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skills skill.Store,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
	parties *party.Hub,
) gateway.Handler {
	return CombatHandlerWithGround(chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, parties, nil)
}

// CombatHandlerWithDrops is CombatHandlerWithGround plus the real drop tables.
// A nil dropSrc, or a monster with no rows in them, falls back to the
// own-design combat.LootTables -- so an operator who has not imported
// _RefMonster_AssignedItemRndDrop sees exactly the behaviour they saw before.
func CombatHandlerWithDrops(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skills skill.Store,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
	parties *party.Hub,
	ground *grounditem.Hub,
	dropSrc DropSource,
	// potions is the potion queue a death empties under -player-dead-state
	// (round 549, markDead); nil leaves nothing to empty. The full
	// constructor carries it because cmd/server is its one caller and the
	// only deployment with a queue to empty.
	potions *PotionQueue,
) gateway.Handler {
	return combatHandler(chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, parties, ground, dropSrc, potions)
}

// CombatHandlerWithGround is CombatHandler with a ground-item hub: a kill's
// gold and loot then lie on the ground near the corpse (internal/grounditem)
// instead of landing in the killer's bag. A nil hub keeps the direct grant.
func CombatHandlerWithGround(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skills skill.Store,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
	parties *party.Hub,
	ground *grounditem.Hub,
) gateway.Handler {
	return combatHandler(chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, parties, ground, nil, nil)
}

// combatHandler is the one implementation both exported constructors delegate
// to, so a new dependency is added in one place rather than duplicated.
func combatHandler(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skills skill.Store,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
	parties *party.Hub,
	ground *grounditem.Hub,
	dropSrc DropSource,
	potions *PotionQueue,
) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpBerserk:
			return handleBerserk(ctx, sess, p, chars, hub, zerk)
		case OpAttack:
			req, err := DecodeAttackRequest(p.Data)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "malformed request"}).Encode()})
			}

			characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
			if errStr != "" {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: errStr}).Encode()})
			}
			// A dead character does not swing (round 549, deadstate.go): the
			// engine's action tick runs on a living PC only, and the client
			// half already refuses the click; this is the server's own gate,
			// before the reach test so a dead click is not told "too far".
			if deadBySession(hub, sess) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: deadRefusal}).Encode()})
			}
			// Round 860 (scrollhold.go): held by the scroll state -- retail's
			// 0x7074 refused {3, 0x4004}, silent; here the silent end.
			if scrollHolds(sess) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: silentRefusal, MonsterID: req.TargetMonsterID}).Encode()})
			}
			// Round 832: the attack is pushed, and Push drops a running trace
			// for it, silently (trace.go).
			dropTraceFor(characterID)
			// Round 786 (arrival.go): an untouchable attacker -- held, or in
			// the arrival's body mode 2 -- is refused 0x3020 (GObjPC::
			// FUN_005291d0, attacker mode 2 at 0x529240, READ). Nothing
			// ends the protection early.
			if attackerUntouchable(hub, characterID) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: untouchableRefusal, MonsterID: req.TargetMonsterID}).Encode()})
			}
			// Round 802 (jobpvp.go): a player or a COS target.
			if req.TargetKind == PvPTargetCharacter || req.TargetKind == PvPTargetCOS {
				keepUp.Cancel(characterID)
				deps := combatDeps{chars: chars, eq: eq, items: items, hub: hub, monsters: monsters, quests: quests, inv: inv, skills: skills, zerk: zerk, mp: mp, parties: parties, ground: ground, dropSrc: dropSrc, potions: potions}
				return handlePvPAttack(ctx, sess, deps, characterID, req.TargetKind, req.TargetMonsterID)
			}
			pvpKeepUp.cancel(characterID)
			// A job's monsters (vslot_394's monster branch, round 802): a
			// trader or hunter does not hit an NPC hunter, a thief an NPC
			// thief, a player out of a job neither.
			if m, ok := monsters.Get(req.TargetMonsterID); ok {
				if code := jobs.MonsterAttackCode(jobStateNow(ctx, characterID), jobMobKind(m.CodeName)); code != 0 {
					return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: pvpRefusalText(code), MonsterID: req.TargetMonsterID}).Encode()})
				}
			}
			// A seated character's swing is NOT refused (round 607,
			// motion.go): the retail plain attack is the basic-attack skill
			// (SKILL_CH_SWORD_BASE_01 and the like), and none of the 1,273
			// *_BASE_* / PUNCH rows carries 'ao', 'pw' or 'msch' (measured),
			// so the skill-use gate lets it through and nothing stands the
			// attacker up. Read, not a choice.

			// Reach first, THEN the cooldown -- the order is the engine's.
			// Its phase 1 measures the approach band and only gates on the
			// cooldown (mask 0x81) once the target is within reach; out of
			// reach it walks instead (round 256, docs/protocol/
			// auto_command.md).
			//
			// The order matters here for a reason of our own: swingReady
			// RECORDS the use, so testing it first would let a refused,
			// out-of-reach click burn the re-use delay and silently swallow
			// the player's next good one.
			//
			// The repeats have always tested reach (keepup.go); the FIRST
			// swing did not, so a click landed a hit from any distance at
			// all (playtest 2026-09-20, item 2). This server cannot walk the
			// player into range the way the engine does, so it refuses and
			// says why -- the same stated departure the keep-up carries.
			// The ammunition (round 838, ammo.go): a bow's or a crossbow's
			// base attack carries `cnsm`, and Tick_Attack's phase 0 tests it
			// (mask 0x64) before the reach.
			if base, ok := baseAttackOf(ctx, characterID, eq, items); ok {
				if refusal := ammoRefusal(ctx, chars, eq, items, characterID, base); refusal != "" {
					keepUp.Cancel(characterID)
					return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: refusal, MonsterID: req.TargetMonsterID}).Encode()})
				}
			}
			if !firstSwingInReach(ctx, sess, eq, items, hub, monsters, characterID, req.TargetMonsterID) {
				// Round 785: the refusal names its monster, and the requester
				// is told where the server has that monster (resyncMonster),
				// so its walk into reach aims at the server's position.
				resyncMonster(sess, monsters, req.TargetMonsterID)
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: refusedTooFar, MonsterID: req.TargetMonsterID}).Encode()})
			}
			// A new attack ends a chain still posting links (round 785
			// review, skillchain.go cancelChain; OURS: retail queues it
			// behind the chain, OpenSRO resolves at once, as a new cast does).
			cancelChain(characterID)
			// A plain swing is the weapon's base attack skill, on that skill's
			// own re-use delay (round 255). A click inside the delay is not
			// dropped (round 785): the engine queues the action and its phase
			// 1 waits on the cooldown gate (mask 0x81) before it swings
			// (auto_command.md), so the swing is armed for the moment the
			// delay ends -- the keep-up's own first swing. A click on the
			// target the keep-up already swings at changes nothing (the
			// 0x7074 handler refuses a duplicate of the running attack,
			// 0x4004).
			if wait := swingWait(ctx, characterID, eq, items, skills, time.Now()); wait > 0 {
				if cur, running := keepUp.Target(characterID); !running || cur != req.TargetMonsterID {
					deps := combatDeps{chars: chars, eq: eq, items: items, hub: hub, monsters: monsters, quests: quests, inv: inv, skills: skills, zerk: zerk, mp: mp, parties: parties, ground: ground, dropSrc: dropSrc, potions: potions}
					armKeepUp(sess, deps, characterID, req.TargetMonsterID, wait)
				}
				return nil
			}
			// The swing IS the weapon's base attack skill (PrepareAction
			// 0x4ad030 writes DefaultAttackSkillID into the action context),
			// so its damage is that row's `att` share, hit count and mask --
			// see plainSwingOf. masteryPercent stays 0: see performAttack.
			sw := plainSwingOf(ctx, characterID, eq, items)
			if err := performAttack(ctx, sess, chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, parties, ground, dropSrc, potions, characterID, req.TargetMonsterID, sw.flat, sw.percent, 0, sw.hits, sw.atk, nil); err != nil {
				return err
			}
			// One click is the whole fight: the server repeats the swing on
			// the base attack's ReuseDelay until the target is dead (round
			// 256, keepup.go). A target the swing could not find arms
			// nothing; the first repeat would only find the same.
			if m, ok := monsters.Get(req.TargetMonsterID); ok && m.HP > 0 {
				deps := combatDeps{chars: chars, eq: eq, items: items, hub: hub, monsters: monsters, quests: quests, inv: inv, skills: skills, zerk: zerk, mp: mp, parties: parties, ground: ground, dropSrc: dropSrc, potions: potions}
				armKeepUp(sess, deps, characterID, req.TargetMonsterID, 0)
			}
			return nil
		case OpMonsterList:
			noteMonsterListCaps(sess, p.Data)
			return handleMonsterList(sess, hub, monsters, monsterListPagedAsked(p.Data))
		default:
			return nil
		}
	}
}

// performAttack computes damage (the attacker's base weapon/unarmed damage
// plus damageBonus -- a skill's flat damage, which for a plain OpAttack is the
// weapon's base attack skill's and 0 on every real base row -- see
// plainSwingOf), applies it to the target monster, resolves the monster's
// counterattack, sends OpAttackResult to sess, grants gold on a kill, and
// broadcasts to everyone else in the zone. Shared by CombatHandler and
// skill.UseHandler so both attack paths behave identically.
func performAttack(
	ctx context.Context,
	sess *gateway.Session,
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skills skill.Store,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
	parties *party.Hub,
	ground *grounditem.Hub,
	dropSrc DropSource,
	// potions is the potion queue a death empties under -player-dead-state
	// (round 549); nil leaves nothing to empty.
	potions *PotionQueue,
	characterID, targetMonsterID int64,
	damageBonus int,
	damagePercent int,
	// masteryPercent is stage 1 of the engine's damage pipeline: the weapon
	// roll is scaled by `1 + masteryPercent/100` BEFORE mitigation. See
	// combat.MasteryDamageScale.
	//
	// A plain swing passes 0, and that is OpenSRO's limit, NOT the engine's
	// answer for every weapon. The swing is the weapon's base attack skill
	// (PrepareAction 0x4ad030, see plainSwingOf), and
	// Skill_GetRequiredMasteryLevel (0x59e770) returns a mastery level for
	// any row whose CRefSkill+0x574 is non-zero -- 0 only when there is no
	// row or +0x574 is 0. The one writer of +0x574 is the row's own
	// `getv MAAT` parameter (SkillGlobal::RefSkill_ParseParams 0x587630).
	// On the retail rows the CH sword/spear/bow base attacks and the EU
	// staff and both wand base attacks carry it; SKILL_PUNCH_01 and the
	// other EU base attacks do not. refdata does not export MAAT, so the two
	// cannot be told apart here and every plain swing takes 0 (disclosed;
	// docs/TODO.md).
	masteryPercent int,
	hits int,
	// attackType is the skill's `att` value[0]: which half of the blow
	// exists. A plain OpAttack passes its base attack skill's mask, or
	// combat.AttackPhysical with no base row (plainSwingOf). See
	// combat.AttackType.
	attackType combat.AttackType,
	// landed, when not nil, is set once the blow is applied to the monster
	// (round 622's review): a cast refused here after its costs ("target not
	// found", a damage failure) is not announced to the zone. Its Blocked
	// says every hit was blocked (round 659's review): a blocked hit applies
	// no state (Combat_ApplyStatusEffects' `cmp [edi+5],2` on the hit
	// record's blocked flag, 0x5906c0).
	landed *blowReport,
) error {
	monster, ok := monsters.Get(targetMonsterID)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found", MonsterID: targetMonsterID}).Encode()})
	}

	// A monster is only reachable from its own zone -- MonsterListResult
	// already only ever shows same-zone monsters (see handleMonsterList), so
	// treat a cross-zone target ID (e.g. looked up before a real zone
	// change, see world.Hub.ChangeZone) the same as an unknown one, rather
	// than leaking that a target with that ID exists somewhere else.
	attacker, ok := hub.EntityBySession(sess.ID())
	if !ok || attacker.Zone != monster.Zone {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found", MonsterID: targetMonsterID}).Encode()})
	}

	// The attacker's level, for the monster's counterattack, and its HP now
	// (the result's seed). The blow's own terms (its level, the TOTAL Str
	// and Int, round 769) are newCastContext's, read the same way.
	playerLevel := 0
	playerHPNow := 0
	if c, err := chars.GetByID(ctx, characterID); err == nil && c != nil {
		playerLevel = c.Level
		playerHPNow = c.HP
	}

	// THE HITS (round 785 review): a plain swing is its weapon's base attack
	// skill (PrepareAction 0x4ad030), and Combat_ResolveDamage resolves it
	// as it resolves any cast (skill_attack.md "One hit"), so its hits run
	// through the cast's own per-hit resolution (castContext.strike, with the
	// base attack row): the monster's debuffs (monsterDefence, its block and
	// parry through monsterStat, applyMonsterTaken), the attacker's buffs and
	// passives (applyBuffDamage, applyGetvDamage on the row's getv keys),
	// berserk on each hit, the fixed damage kinds, and the running imbue's
	// add, its states (castContext.apply) and its extra targets (role 1,
	// 'efr' collected again, 0x586b33). Every term the swing had before is
	// one of strike's: the level penalty on the skill's flat damage, the
	// mastery scale (0 for a swing, see masteryPercent), the share
	// percentage after mitigation, the multi-hit loop with each hit rolled on
	// its own. One difference is the engine's and now OpenSRO's: a magical
	// swing (a staff's) no longer crits (magic never crits, READ).
	//
	// The guarantees of the combat lane hold: the blow is applied once
	// (castContext.apply), the attacker hears it once (the OpAttackResult
	// below, the block carrying every target), and the other watchers once
	// each (the primary's OpMonsterDamaged or kill below, the extra targets'
	// through announceOutcomes, the attacker excluded).
	deps := combatDeps{chars: chars, eq: eq, items: items, hub: hub, monsters: monsters, quests: quests, inv: inv, skills: skills, zerk: zerk, mp: mp, parties: parties, ground: ground, dropSrc: dropSrc, potions: potions}
	baseRow, _ := baseAttackOf(ctx, characterID, eq, items)
	cc := newCastContext(ctx, deps, characterID, attacker, baseRow, skillBlowTerms{damageBonus: damageBonus, damagePercent: damagePercent,
		masteryPercent: masteryPercent, hits: hits, attackType: attackType})
	targets := []skillTarget{{ID: monster.ID, Share: 100}}
	if cc.imbue != nil {
		for _, t := range collectSkillTargets(cc.imbue.row, attacker, monster, monsters, 0)[1:] {
			if t.ID != monster.ID {
				t.Role = 1
				targets = append(targets, t)
			}
		}
	}
	var outcomes []targetOutcome
	for _, tg := range targets {
		o, err := cc.strike(tg)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "damage calculation failed", MonsterID: targetMonsterID}).Encode()})
		}
		if o.ok {
			outcomes = append(outcomes, o)
		}
	}
	if len(outcomes) == 0 || outcomes[0].before.ID != monster.ID {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found", MonsterID: targetMonsterID}).Encode()})
	}
	// The ammunition (round 838, ammo.go): the swing is its base attack
	// skill's cast, which spends after its blows resolve and before they land.
	if r := spendAmmo(ctx, sess, chars, eq, inv, items, characterID, baseRow); r != "" {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: r, MonsterID: targetMonsterID}).Encode()})
	}
	swingAction := &ActionBlock{Target: uint32(monster.ID), TargetKind: ActionTargetMonster, HitCount: uint8(cc.terms.hits)}
	// The blow, with the players watching the monster before it and after it
	// (damageMonsterWatched, round 656's review), booked to the attacker on
	// the monster's damage list, which the killing blow hands back: the unique
	// kill notice names its killer from it (round 657, AnnounceUniqueKill).
	// apply also tells the nests of a kill (round 660), the AI of a struck
	// survivor (round 537), and lands the imbue's states.
	cc.apply(outcomes, swingAction)
	primary := outcomes[0]
	if !primary.ok {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found", MonsterID: targetMonsterID}).Encode()})
	}
	net, updated, monsterDied, watchers, killHits := primary.total, primary.updated, primary.died, primary.watchers, primary.killHits
	playerCrit := false
	for _, h := range primary.hits {
		playerCrit = playerCrit || h.Flags&HitFlagCritical != 0
	}
	if landed != nil {
		landed.Landed, landed.Blocked = true, primary.blocked
	}
	addSkillHate(cc, outcomes)
	// A landed blow wears the weapon: one roll at rate = hits (2% a hit).
	wearWeapon(ctx, eq, characterID, hits)
	extras := outcomes[1:]

	// PlayerHP is SEEDED with the truth before any branch runs.
	//
	// It is what the client paints the player's health bar from, and an int32
	// left at its zero value is indistinguishable from "you are dead". The
	// counterattack branch below is skipped entirely when the monster is still
	// inside its attack skill's re-use delay -- there is no reply to compute --
	// and it used to leave this at 0, so the bar emptied on every swing that
	// drew no counterattack. Mangyang's delay is 3000 ms and a player swings
	// faster than that, so it emptied almost at once: "when i click on a
	// mangyang its health bar appears but then my health shoots all the way
	// down to 0" (playtest 2026-09-20).
	//
	// Every branch that changes the player's HP overwrites this afterwards.
	result := &AttackResult{MonsterID: targetMonsterID, MonsterDamage: int32(net), MonsterRemainingHP: int32(updated.HP),
		MonsterDied: monsterDied, PlayerCritical: playerCrit, PlayerHP: int32(playerHPNow), Action: swingAction}
	// The berserk orbs ride along on every attack result so the HUD tracks
	// them -- but a blow that does not kill earns nothing: the engine adds
	// hwan only on the killing blow (see berserk.EarnOnKill), which is
	// applied below once the kill is known.
	if zerk != nil {
		result.BerserkGauge = int32(zerk.Gauge(characterID))
		result.BerserkActive = zerk.Active(characterID)
	}
	var levelUp *LevelUp // set on a kill that crosses the exp curve, sent below
	var killGold int64   // the kill's gold, dropped on the ground below when a ground hub exists
	// The monster's counter as the zone push, set only when the monster struck
	// back; sent last, below, and only with -monster-strike-push on.
	var strike *MonsterAttacked

	// A dead monster can't counterattack. A surviving one always hits
	// back -- there's no dodge/evade system yet, see docs' open items.
	if monsterDied {
		// The kill reward (round 659: one function, grantKill, that the
		// damage-over-time kill in status.go pays through too).
		lu, kg, kerr := grantKill(ctx, deps, characterID, monster, result, killHits)
		if kerr != nil {
			return kerr
		}
		levelUp, killGold = lu, kg
	} else if monsterBattle.Load() {
		// -monster-battle (round 546): the monster's blow is its own, from the
		// AI tick's BATTLE -- it chases to its attack band and swings on its
		// skill's ReuseDelay (monsterai.go battleTick), and the zone learns of
		// each blow by an OpMonsterAttacked. Nothing is resolved here, so the
		// result carries no counter and PlayerHP stays the seeded truth. Off,
		// the synchronous counter below is what it was (mob-counter-retire
		// deletes it).
	} else if !monsters.CounterattackReady(monster.ID, time.Now()) || !monsterMayAct(monster.ID) {
		// ...or its states stop it: stunned, frozen or asleep (round 659,
		// status.go).
		// Inside its attack skill's re-use delay: the real monster is still
		// in that skill's action and cannot strike again yet (combat.Hub.
		// CounterattackReady). The player's blow landed; there is no reply.
	} else {
		// The monster strikes back: monsterStrike (monsterstrike.go) is this
		// branch, moved there unchanged in round 541, and its outcome is copied
		// into the result field for field, so the wire is what it was. The same
		// outcome is the zone push below. No skill is named: the counter rolls
		// the monster's primary range, the col-83 skill's (round 554's draw is
		// BATTLE's, under -monster-battle, which this branch is not).
		out, err := monsterStrike(ctx, strikeDeps{chars: chars, eq: eq, items: items, mp: mp, hub: hub, potions: potions}, monster, combat.MonsterSkill{}, characterID, playerLevel)
		if err != nil {
			return err
		}
		// A counter that lost the kill to another monster's blow inside this
		// handler's window (round 550; killLock since round 551) landed
		// nothing: the result carries no counter and no push is made
		// (`strike` stays nil). PlayerHP is re-read (round 551): the value
		// seeded above was read BEFORE the racing kill, so it could carry a
		// stale positive HP while she lies at 0 and the killer's own
		// OpMonsterAttacked carries 0.
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
			strike = out.message(monster.ID, characterID)
			// Round 785: the counter rolls the primary range, so it names
			// the primary attack skill (strikeSkillID).
			strike.SkillID = strikeSkillID(monster, combat.MonsterSkill{})
		}
	}

	// The imbue's extra targets' kills pay as a cast's do (payKills), their
	// EXP summed into the result.
	extraLevelUps, extraKills, err := payKills(ctx, deps, characterID, extras, result)
	if err != nil {
		return err
	}

	if err := sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: result.Encode()}); err != nil {
		return err
	}

	// The level-up (if any) rides just behind the attack result, direct to the
	// attacker, so the client can play the effect and refresh the character
	// window.
	if levelUp != nil {
		announceLevelUp(hub, characterID)
		if err := sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: levelUp.Encode()}); err != nil {
			return err
		}
	}
	for _, lu := range extraLevelUps {
		announceLevelUp(hub, characterID)
		if err := sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: lu.Encode()}); err != nil {
			return err
		}
	}
	// Then the killer's 0x3056, last (round 716; see distributeKill).
	if result.expGain != nil {
		sendExpGainTo(sess, *result.expGain)
	}
	for _, k := range extraKills {
		if k.exp != nil {
			sendExpGainTo(sess, *k.exp)
		}
	}
	// The extra targets to their watchers (the attacker excluded: the block
	// told it).
	if len(extras) > 0 {
		if err := announceOutcomes(ctx, deps, sess, characterID, extras, extraKills, true); err != nil {
			return err
		}
	}

	// The attacker already got the richer OpAttackResult above; only
	// broadcast to everyone *else* in the zone, not back to them too -- and
	// since round 656 only to those whose area of interest holds the monster
	// (aoi.go monsterWatchers), at the position the swing found it.
	var others []world.Entity
	for _, e := range watchers {
		if e.Session.ID() != sess.ID() {
			others = append(others, e)
		}
	}

	if monsterDied {
		return announceKill(ctx, deps, sess, others, characterID, monster, killGold, updated, killHits)
	}

	msg := &MonsterDamaged{MonsterID: targetMonsterID, Damage: int32(net), RemainingHP: int32(updated.HP)}
	for _, e := range others {
		sendMonsterPush(e.Session, &proto.Packet{Opcode: OpMonsterDamaged, Data: msg.Encode()})
	}
	// The monster's blow, to the attacker and to the same `others` this
	// swing's OpMonsterDamaged just went to -- the one zone snapshot above,
	// round 544 -- after both (round 541, OpMonsterAttacked; nothing is sent
	// while -monster-strike-push is off). See pushMonsterStrike.
	if strike != nil {
		pushMonsterStrike(sess, others, strike)
		// Round 640: a counter that broke the player's wall ends it now,
		// after the messages that report the blow (walls.go endBrokenWall).
		if strike.Wall.Broke {
			endBrokenWall(hub, characterID)
		}
		// With -player-dead-state off a counter that killed has respawned
		// her; she goes to her return point now, after the messages that
		// report the blow (round 665, returnAfterKill).
		if strike.TargetDied {
			returnAfterKill(ctx, chars, eq, hub, characterID)
		}
	}
	return nil
}

// attackerDamage resolves characterID's raw physical attack power from
// their equipped weapon (falling back to unarmedDamage if none), before
// the target's defense is subtracted.
// str is the attacker's Strength, which contributes a real term to both ends
// of the range (see below); passing 0 is safe and simply omits it.
func attackerDamage(ctx context.Context, characterID int64, str int, eq equipment.Store, items combat.ItemLookup) (int, error) {
	// A caller with no skill in hand is swinging a weapon, which is physical.
	// No defender, so no centre: the uniform roll, as before round 378.
	return attackerDamageOf(ctx, characterID, str, 0, eq, items, combat.AttackPhysical, 0, 0, 0)
}

// swingWait is the plain attack's cadence gate: the equipped weapon type's
// base attack skill (combat.BaseAttackSkillFor -- SKILL_CH_SWORD_BASE_01 for
// a sword, SKILL_PUNCH_01 bare-handed) has a ReuseDelay in the imported skill
// table, and a swing inside it must wait out the rest of it. It returns that
// rest, or 0 when the swing may go now -- and then records the swing against
// that skill id. Without reference data for the skill (or a store that cannot
// look skills up) there is no gate, as before. Round 785: the wait used to be
// a refusal (swingReady) that dropped the click with no reply, and the player
// stood still; the caller now arms the swing for when the delay ends, as the
// engine's phase 1 waits on its cooldown gate.
func swingWait(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup, skills skill.Store, now time.Time) time.Duration {
	if skills == nil {
		return 0
	}
	ref, ok := baseAttackOf(ctx, characterID, eq, items)
	if !ok || ref.ReuseDelayMs <= 0 {
		return 0
	}
	last, ever, err := skills.LastUsed(ctx, characterID, ref.ID)
	if err == nil && ever {
		if left := time.Duration(ref.ReuseDelayMs)*time.Millisecond - now.Sub(last); left > 0 {
			return left
		}
	}
	_ = skills.RecordUse(ctx, characterID, ref.ID, now)
	return 0
}

// attackerDamageOf is attackerDamage for a blow whose damage-type mask is
// known -- `att` value[0] off the skill being used. See combat.AttackType.
func attackerDamageOf(ctx context.Context, characterID int64, str, intel int, eq equipment.Store, items combat.ItemLookup, atk combat.AttackType, attackerLevel, defenderLevel int, defenderParry float64) (int, error) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0, fmt.Errorf("reading equipment: %w", err)
	}

	for _, e := range equipped {
		if e.Slot != equipment.SlotWeapon {
			continue
		}
		if durability.IsBroken(e.Durability) {
			// A broken weapon carries none of its attack; you swing bare-fisted.
			return unarmedDamage, nil
		}
		item, err := items.GetItem(ctx, e.ItemID)
		if errors.Is(err, refdata.ErrItemNotFound) {
			// A weapon nobody has stats for hits as a bare fist rather
			// than making the attack fail. Reference data is brought by
			// the operator, so on a deployment that has imported none of
			// it -- which is every fresh one -- refusing here would mean
			// nobody could fight at all.
			return unarmedDamage, nil
		}
		if err != nil {
			return 0, fmt.Errorf("looking up weapon stats: %w", err)
		}
		// One selection, in one place: combat.WeaponRange. The rule -- which
		// stat scales which half, and when the magical columns are used -- is
		// recovered there from the engine's own parameter graph, together with
		// what is deliberately not done and why.
		min, max := combat.WeaponRange(item, weaponInstance(e), str, intel, atk)
		// Round 785: the buffs' weapon-bound entries ('apau', 'apru', 'tpad').
		min, max = buffedWeaponRange(characterID, atk, min, max)
		// WHERE in that range the blow lands is the engine's centre-biased
		// roll: the attacker's attack rate against the defender's parry rate,
		// plus the level term, clamped to [10 %, 90 %] and then given a
		// min-of-three excursion (combat.RollCentred).
		//
		// A caller that cannot supply the defender's parry passes 0 and gets
		// the uniform roll instead -- the behaviour this had before round 378.
		// That is a real fallback rather than a default: with no defender there
		// is no ratio, and inventing one would put every blow at the ceiling.
		//
		// AND the weapon must carry a real attack rate. itemdata col 113 is a
		// recent addition to this project's export, so an item table imported
		// before it reads 0 -- and 0 is missing data, not a weapon that cannot
		// hit. Treating it as real would put every blow near the floor on
		// exactly the deployments that have imported least, which is the same
		// reasoning the unarmed fallback above already uses.
		if defenderParry > 0 && item.HitRateMin > 0 {
			// The instance's own attack rate (combat.WeaponAttackRate: its
			// variance group 3, as the engine publishes param 11).
			// Round 785: the buffs' param-11 entries ('hr', 'thrd').
			hra := combat.CharacterRate(attackerLevel, buffStat(characterID, buff.ParamHitRate, combat.WeaponAttackRate(item, weaponInstance(e))))
			centre := combat.DamageCentrePercent(hra, defenderParry, attackerLevel, defenderLevel)
			return rollCentred(min, max, centre), nil
		}
		return rollDamage(min, max), nil
	}
	return unarmedDamage, nil
}

// weaponInstance is the worn weapon's per-instance part for combat.WeaponRange:
// its variance, and whether it has one at all (an Untracked row never rolled
// one and reads its lo ends, as every weapon did before round 244).
//
// Round 769: with its effective plus and its 'hr' option (equipstats.go).
func weaponInstance(e equipment.Equipped) combat.Instance {
	return combat.Instance{Variance: e.Variance, Tracked: e.Durability != durability.Untracked,
		Plus: wornPlus(e), HitRatePct: float64(optionSum(optionsOf(e.MagParams), tagHR))}
}

// defenderArmor sums each worn piece's physical defence -- the six armour
// slots (equipment.ArmorSlots) AND the shield -- for mitigating a monster's
// counterattack. A piece's defence is what the engine's Char_BuildAggregateStats
// (0x00495d60) computes for it: the ref row's PD_L..PD_U interpolated by the
// INSTANCE's variance, group 3 for armour (durability.ArmourPhysDefenseGroup;
// the block at 0x495f26 stores it to item+0x198) and group 4 for a shield
// (the shield branch at 0x49682a, same field). Every equipped item's block is
// then published into the character's params keyed by the item:
// CGPCInventoryOP::RefreshEquipParamEntryForPC (0x004bb3e0) walks all 13
// equipment slots and, for each item that answers "equipment" (vslot 33) and
// passes CGItemEquip::CheckEquipRequirements, calls Char_PublishCombatStats
// (0x00497830) with the ITEM -- +0x198 -> param 5, +0x1a8 -> param 6 -- so a
// shield's defence counts exactly as armour's does (round 246; until then
// OpenSRO left the shield out of the sum). A weapon's block carries no
// defence (its branch never stores +0x198), so weapons add nothing here.
//
// Until 2026-09-19 this summed PhysDefenseMax, a disclosed stand-in from
// before instances carried a variance. A worn row that never got one
// (Untracked -- no reference data to roll from) still counts at the top of
// its range, as it always did; a broken piece counts nothing (the publisher
// zeroes params 5/6 while the item's broken flag, item+0x190, is set).
// monsterBlow rolls a monster's counterattack: WHERE in its skill's damage
// range the blow lands, by the same centre-biased roll the player's attack
// takes with the sides swapped -- the monster's attack rate (2*level + 25)
// against the player's parry rate.
//
// A parry of 0 takes the uniform roll instead. That is a fallback, not a
// defender who cannot parry: every character has the innate 10, so a zero here
// means the item table was imported before itemdata col 68 existed, and
// treating it as real would put every monster blow at the 90 % ceiling on
// exactly the deployments that have imported least. The player's attack guards
// its own half the same way (round 378).
func monsterBlow(m combat.Monster, playerLevel int, parry float64) int {
	// A party monster's attack value is x1.2 and an elite's x1.5 before
	// defence (round 712, combat.MonsterAttackFactor, READ FUN_0040da20). The
	// engine scales the attacker's own stat; applying it to a drawn skill's
	// range is INFERRED, and the truncation is OURS (ScaleMonsterAttack).
	f := combat.MonsterAttackFactor(m.Party, m.Rarity)
	if m.AttackMax <= 0 {
		return combat.ScaleMonsterAttack(m.Attack, f) // no range at all: the flat disclosed Attack
	}
	m.AttackMin, m.AttackMax = combat.ScaleMonsterAttack(m.AttackMin, f), combat.ScaleMonsterAttack(m.AttackMax, f)
	if parry > 0 {
		centre := combat.DamageCentrePercent(
			combat.MonsterRate(m.Level),
			combat.CharacterRate(playerLevel, parry),
			m.Level, playerLevel)
		return rollCentred(m.AttackMin, m.AttackMax, centre)
	}
	return rollDamage(m.AttackMin, m.AttackMax)
}

// defenderParryRate is the character's `era`, the parry rate the engine divides
// an attacker's attack rate by to place a blow in its range.
//
// BODY ARMOUR ONLY, which is the data's own division rather than a choice: a
// census of all 21,560 retail item rows found 9,663 carrying a non-zero parry
// (itemdata col 68) and none of them a shield, against 500 carrying a non-zero
// block ratio and every one of them a shield, with no row carrying both
// (round 377). Shields block; body armour parries.
//
// Each piece's parry is its INSTANCE's, as the engine publishes param 9
// (round 629's integration review, which replaced the LO end taken until
// then): READ, Char_BuildAggregateStats' armour branch interpolates the ref's
// ER triple +0x1c8/+0x1cc (itemdata columns 68/69, ParryRatioMin/Max) by
// variance group 5 (durability.ArmourParryGroup, `mov esi,5` at 0x496062) into
// item+0x19c (0x496088), and Char_PublishCombatStats publishes +0x19c as
// param 9 (0x497920..0x49792f). The instance rule is defenderDefence's: a
// piece that never rolled a variance (Untracked) counts at the top of its
// range; a row without its hi end reads the lo end. Round 769: plus the
// per-plus increment (column 70) and the piece's 'er' option (armourParry).
//
// A broken piece parries for nothing, the same rule defenderDefence uses.
func defenderParryRate(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) (float64, error) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0, fmt.Errorf("reading equipment: %w", err)
	}
	isArmorSlot := make(map[equipment.Slot]bool, len(equipment.ArmorSlots))
	for _, s := range equipment.ArmorSlots {
		isArmorSlot[s] = true
	}
	total := 0.0
	for _, e := range equipped {
		if !isArmorSlot[e.Slot] || durability.IsBroken(e.Durability) {
			continue
		}
		it, err := items.GetItem(ctx, e.ItemID)
		if err != nil || it == nil {
			continue // no reference row: contributes nothing, as elsewhere here
		}
		total += armourParry(e, it)
	}
	// Round 785: the buffs' param-9 entries ('er', 'terd'; buffstats.go).
	return buffStat(characterID, buff.ParamParry, total), nil
}

// armourParry is one worn armour piece's parry, param 9's item term (see
// defenderParryRate). Round 769: plus the per-plus increment (column 70,
// 0 on every retail row) times the plus, then scaled by the piece's own 'er'
// option, (1 + v/100) (ApplyDurabilityAndRateOptions 0x496a70; READ).
func armourParry(e equipment.Equipped, it *refdata.Item) float64 {
	lo, hi := it.ParryRatioMin, it.ParryRatioMax
	v := lo
	switch {
	case hi <= lo:
	case e.Durability == durability.Untracked:
		v = hi
	default:
		v = durability.WhiteStat(lo, hi, e.Variance, durability.ArmourParryGroup)
	}
	v += it.PlusIncParry * float64(wornPlus(e))
	return v * (1 + float64(optionSum(optionsOf(e.MagParams), tagER))/100)
}

func defenderArmor(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) (int, error) {
	v, err := defenderDefence(ctx, characterID, eq, items, func(it *refdata.Item) (float64, float64, float64) {
		return it.PhysDefenseMin, it.PhysDefenseMax, it.PlusIncPhysDef
	}, durability.ArmourPhysDefenseGroup, durability.ShieldPhysDefenseGroup)
	// Round 785: the buffs' param-5 entries ('defp', 'defr', ...; buffstats.go).
	return buffStatInt(characterID, buff.ParamPhysDefFlat, v), err
}

// defenderDefence is the shared walk behind defenderArmor and its magical
// twin: the worn armour and shield, each piece's range through its instance's
// variance group (armourGroup for the six armour slots, shieldGroup for the
// shield), summed and rounded once at the end (the engine keeps floats and
// OpenSRO's wire field is an int32).
//
// Round 769: each piece also adds its per-plus increment (rangeOf's third
// value: column 67 physical, 78 magical) times its plus (READ,
// Char_BuildAggregateStats).
func defenderDefence(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup, rangeOf func(*refdata.Item) (float64, float64, float64), armourGroup, shieldGroup int) (int, error) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0, fmt.Errorf("reading equipment: %w", err)
	}

	isArmorSlot := make(map[equipment.Slot]bool, len(equipment.ArmorSlots))
	for _, s := range equipment.ArmorSlots {
		isArmorSlot[s] = true
	}

	total := 0.0
	for _, e := range equipped {
		group := armourGroup
		switch {
		case isArmorSlot[e.Slot]:
		case e.Slot == equipment.SlotShield:
			group = shieldGroup
		default:
			continue
		}
		if durability.IsBroken(e.Durability) {
			continue // a broken piece defends for nothing
		}
		item, err := items.GetItem(ctx, e.ItemID)
		if errors.Is(err, refdata.ErrItemNotFound) {
			// Armour nobody has stats for protects nothing. Without this,
			// a character wearing the starting kit could not be attacked
			// at all on a deployment with no reference data: every one of
			// the five pieces failed the lookup.
			continue
		}
		if err != nil {
			return 0, fmt.Errorf("looking up armor stats: %w", err)
		}
		lo, hi, inc := rangeOf(item)
		total += inc * float64(wornPlus(e))
		if e.Durability == durability.Untracked {
			total += hi
			continue
		}
		total += durability.WhiteStat(lo, hi, e.Variance, group)
	}
	return int(math.Round(total)), nil
}

// attackerCritical is the player's critical-hit chance: the equipped weapon's
// own Critical value, itemdata column 116.
//
// That column is REAL and was verified against a real +5 tooltip before this
// used it -- a Copper Sword reads 3, and the tooltip showed 3 (see
// docs/protocol/ITEM_FORMAT.md's weapon stat table). This project already
// loaded it as refdata.Item.CriticalMin/Max and had nowhere to spend it.
//
// TWO CORRECTIONS, both to things written here on 2026-09-15.
//
// The first pass concluded "the player never crits", on the grounds that
// Char_PublishCombatStats does not publish param 12. The conclusion was wrong,
// and the grounds were wrong too -- but it took a second pass to see the
// second part.
//
// It publishes param 12 from the stat source's +0x1dc, and the reason the
// earlier pass missed it is mundane: the disassembly was cut at 220
// instructions and that write is at 0x00497ef0, three hundred instructions
// past the end of what was read. The full publication is eighteen fields, and
// the critical is the last of them -- immediately after 'hra' attack rate at
// +0x1d8, exactly where a reader would expect the pair to sit.
//
// So a player's critical arrives by the SAME route as every other combat stat
// rather than by the item-modifier path (Stat_ApplyTaggedModifier's 'cri'
// tag), which is what the correction of 2026-09-15 offered instead. That path
// exists and also reaches param 12; it is simply not the interesting one here.
// The value this code uses -- the weapon's own Critical column, itemdata 116 --
// is unchanged and was right throughout; only the citation improves.
//
// The divisor this chance faces is NOT this function's business -- the caller
// applies it, because it depends on who the defender is. Against a monster it
// is a grounded zero (GObjMob_PublishStats publishes params 0, 3-12, 23, 24,
// 27-33 and 140, and 57 is not among them); in a duel the defender is a player
// and the zero is merely disclosed. Round 406 found this comment claiming the
// grounded reason for both. See combat.EvadedChance.
//
// No weapon, or a weapon with no reference data, means no critical rather than
// a disclosed default: an unarmed attack has no weapon column to read.
func attackerCritical(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) int {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0
	}
	for _, e := range equipped {
		if e.Slot != equipment.SlotWeapon {
			continue
		}
		if durability.IsBroken(e.Durability) {
			return 0 // the publisher zeroes a broken item's params
		}
		item, err := items.GetItem(ctx, e.ItemID)
		if err != nil || item == nil {
			return 0
		}
		// Round 769: the weapon's critical is its instance's white stat,
		// variance group 6 (durability.WeaponCriticalGroup, `mov esi,6` at
		// 0x4965ce, into item+0x1dc), and a 'cri' option REPLACES the item's
		// param-12 entry with round(that) + v (Stat_ApplyTaggedModifier
		// 0x498690; READ). No per-plus term (its increment is a synthesized
		// 0). An Untracked row reads the low end, as before.
		crit := item.CriticalMin
		if e.Durability != durability.Untracked && item.CriticalMax > item.CriticalMin {
			crit = durability.WhiteStat(item.CriticalMin, item.CriticalMax, e.Variance, durability.WeaponCriticalGroup)
		}
		// The other worn items' 'cri' options are entries of the same param
		// (review F7).
		// Round 785: the buffs' param-12 entries (a passive's 'cr').
		return buffStatInt(characterID, buff.ParamCritical, int(math.Round(crit))+optionSum(optionsOf(e.MagParams), tagCri)+
			wornOptionSum(ctx, characterID, eq, tagCri, equipment.SlotWeapon))
	}
	return 0
}

// defenderBlock is the player's chance to block a blow outright: the equipped
// SHIELD's own block ratio, itemdata columns 74-75.
//
// REAL, and present on exactly the 500 shield rows in the real item table
// (a starter shield reads 10~20); body armour carries the parry-family pair at
// 68-69 instead, and the split is what the _RefObjItem order PD, ER, PAR, BR,
// MD predicts. The lower end is used, matching how this project reads the
// weapon's Critical column.
//
// A BLOCKED HIT DEALS NOTHING. That is not a design choice here -- it is the
// control flow of Combat_ResolveDamage: on a successful block the roll falls
// through to `JZ 0x005905fb`, which lands past ALL FOUR Formula_Mitigate* call
// pairs (0x58f15d, 0x58f2fb, 0x58f7ea, 0x58f9b2), so no damage is ever
// computed and the damage record's zero-initialised +0x28 (physical), +0x24
// (magical) and +0x20 (total) stand. A FAILED block jumps to 0x58f739, before
// the third pair, and resolves normally.
//
// The chance is rolled by the same function as the critical, and the
// disassembly shows how the engine tells them apart -- a key byte in the high
// bits of ECX, 'B' (0x42) for blocks against 'C' (0x43) for criticals, which is
// also the key the bad-luck accumulator is filed under. So the two have
// independent streak protection in the real game; OpenSRO models neither.
//
// As with attackerCritical, the divisor belongs to the caller: this block is
// opposed by the ATTACKER's 'evbl', which is a grounded zero when a monster is
// swinging (param 56 is absent from GObjMob_PublishStats' list) and a disclosed
// zero in a duel. Round 406 found this comment claiming the former for both.
// See combat.EvadedChance.
func defenderBlock(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) int {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0
	}
	for _, e := range equipped {
		if e.Slot != equipment.SlotShield {
			continue
		}
		if durability.IsBroken(e.Durability) {
			return 0 // a broken shield blocks nothing
		}
		item, err := items.GetItem(ctx, e.ItemID)
		if err != nil || item == nil {
			return 0
		}
		// The shield's block rate is its instance's white stat, like every
		// other equipment stat: the shield branch of Char_BuildAggregateStats
		// (0x4967b0, `mov esi,3`) stores BR_L + q*(BR_U-BR_L) from the ref
		// row's +0x1e0/+0x1e4 into item+0x1a4, the field Char_PublishCombatStats
		// publishes as param 10 ('bri', the blocking rate the block roll
		// reads). Until 2026-09-19 (round 245) this returned BlockRatioMin, the
		// low end, "so a shield is never overstated" -- a choice made before
		// instances carried a variance. An Untracked row still reads the low
		// end. Rounded because RollChance takes whole percent.
		// Round 769: a 'bri' option replaces the shield's param-10 entry with
		// round(white) + v (Stat_ApplyTaggedModifier 0x498690; READ).
		// The other worn items' 'bri' options are entries of the same param
		// (review F7).
		bri := optionSum(optionsOf(e.MagParams), tagBri) + wornOptionSum(ctx, characterID, eq, tagBri, equipment.SlotShield)
		// Round 785: the buffs' param-10 entries and the physical 'br' bonus
		// (p136; the block test adds p136..139 by the blow's type, READ --
		// a monster's blow is physical).
		if e.Durability == durability.Untracked {
			return buffedBlock(characterID, int(math.Round(item.BlockRatioMin))+bri)
		}
		return buffedBlock(characterID, int(math.Round(durability.WhiteStat(item.BlockRatioMin, item.BlockRatioMax, e.Variance, durability.ShieldBlockGroup)))+bri)
	}
	return 0
}

// monsterEvasion is a monster's 'evcr' or 'evbl'. GROUNDED: the engine's own
// GObjMob_PublishStats publishes params 0, 3-12, 23, 24, 27-33 and 140, and
// neither 56 nor 57 is among them, so a monster has no evasion term to
// publish. This is a measured value, not a simplification.
//
// A player's is no longer a constant (round 769): playerEvadeBlock and
// playerEvadeCrit are the worn items' 'evbl' and 'evcr' options, cached in
// character.Bonus (equipstats.go).
const monsterEvasion = 0.0

// playerEvadeBlock is the player's param 56, which divides the block chance
// of whatever it strikes.
func playerEvadeBlock(_ context.Context, characterID int64, _ equipment.Store) float64 {
	return float64(character.BonusOf(characterID).EvadeBlock)
}

// playerEvadeCrit is the player's param 57, which divides the critical
// chance of whatever strikes it.
func playerEvadeCrit(_ context.Context, characterID int64, _ equipment.Store) float64 {
	return float64(character.BonusOf(characterID).EvadeCrit)
}

// resolveBlow is combat.ResolveBlow under the SAME lock as every other roll in
// this package -- it takes two chance rolls, and rand.Rand is not safe for
// concurrent use.
func resolveBlow(base int, mitigationPercent float64, flat, critChance, blockChance, attackerLevel, defenderLevel int, attackerID, defenderID int64) combat.Blow {
	damageRollMu.Lock()
	defer damageRollMu.Unlock()
	return combat.ResolveBlow(base, mitigationPercent, flat, critChance, blockChance,
		attackerLevel, defenderLevel, damageRollNG,
		&combat.ChanceMemory{Tracker: chanceMemory, AttackerID: attackerID, DefenderID: defenderID})
}

// chanceMemory holds the engine's per-actor bad-luck accumulators for every
// blow this package resolves -- see combat.ChanceTracker. It is package-level
// for the same reason damageRollNG is: the streak belongs to the actor across
// fights, not to one request.
//
// Monster ids and character ids share this key space, and CAN collide -- a
// character id comes from the characters table while a monster id comes from
// combat.Hub's own counter, so nothing stops both from being 7. The collision is
// harmless rather than prevented: a shared key would merge two actors' streaks
// of the same kind, which costs a little fidelity and cannot produce a wrong
// damage number, and separating the spaces would mean threading an actor-kind
// through every call site for no gameplay difference. Written down because the
// next reader will notice it and should not have to re-derive that it is safe.
//
// A monster's streak is dropped when it dies (the engine's accumulator lives on
// the object, so it cannot outlive one); a character's persists across fights,
// which is what the engine does.
var chanceMemory = combat.NewChanceTracker()

// blowReport is what performAttack tells a cast about its blow.
type blowReport struct {
	Landed  bool // the blow reached the monster
	Blocked bool // and the monster blocked every hit of it
}

// grantKill pays characterID for killing monster: the berserk orb roll, the
// gold, the experience with its level-up, and the skill experience, writing
// what the attacker's OpAttackResult reports into result. It is performAttack's
// kill branch moved here unchanged in round 659, so that a kill by a state's
// damage tick (status.go) pays exactly what a kill by a blow does.
func grantKill(ctx context.Context, d combatDeps, characterID int64, monster combat.Monster, result *AttackResult, hits []combat.Hit) (levelUp *LevelUp, killGold int64, err error) {
	chars, zerk, ground, skills := d.chars, d.zerk, d.ground, d.skills

	// The monster's object is gone, so its blocking streak goes with it.
	// The engine's accumulator lives on the object; nothing survives it.
	chanceMemory.Forget(monster.ID)
	// And its states end with it (round 659, status.go).
	statusFX.forgetMonster(monster.ID)
	// Hwan (berserk orbs) are earned on the KILLING blow, by chance:
	// 8% base, decaying for a victim more than three levels below the
	// killer, x5 for a giant, x2 for an elite, all five orbs for a
	// unique -- the rule read off FUN_00410880 (see internal/berserk).
	// The killer's level is the character's; a store that cannot say
	// leaves the base chance, disclosed here rather than guessed.
	if zerk != nil {
		killerLevel := 0
		if kc, err := chars.GetByID(ctx, characterID); err == nil {
			killerLevel = kc.Level
			// The stored orbs are the starting point for this character;
			// seed-once, so orbs earned this session are not undone.
			zerk.EnsureSeeded(characterID, kc.HwanCount)
		}
		releaseTurn := zerk.Turn(characterID)
		if gained := zerk.EarnOnKill(characterID, berserk.Kill{
			KillerLevel: killerLevel, VictimLevel: monster.Level,
			VictimIsMonster: true, VictimRarity: monster.Rarity, Source: uint32(monster.ID),
		}); gained > 0 {
			// The engine's count is a character-row column, so a gain has
			// to reach the row -- see character.Character.HwanCount.
			if err := chars.SetHwanCount(ctx, characterID, zerk.Charges(characterID)); err != nil {
				releaseTurn()
				return nil, 0, fmt.Errorf("combat: persisting berserk orbs: %w", err)
			}
		}
		releaseTurn()
		result.BerserkGauge = int32(zerk.Gauge(characterID))
	}
	// No damage taken, but the client still wants to know current HP.
	hp, _, err := chars.ApplyDamage(ctx, characterID, 0)
	if err != nil {
		return nil, 0, fmt.Errorf("combat: reading player hp: %w", err)
	}
	result.PlayerHP = int32(hp)

	// Granted before the result packet goes out, not after. The kill
	// reward is part of the state the attack result announces, so a
	// client that reads the character back as soon as it sees
	// OpAttackResult must already find the gold there. Awarding it
	// afterwards left a real window where the attacker had been told
	// the monster died but the reward had not landed yet -- an
	// intermittent CI failure (gold 1000 where 1500 was expected, i.e.
	// the starting balance with the reward missing) that reproduced
	// only under load, since locally the write always won the race.
	// Gold is rolled in the real per-level range (levelgold) when the
	// monster has one, falling back to the disclosed flat reward.
	gold := rollGold(monster.GoldMin, monster.GoldMax, monster.GoldReward)
	// The server's own DropGoldAmountCoef knob, default 1x and capped at
	// 2.5 -- see internal/rates.
	if g := rates.Current().Gold; g != 1 {
		gold = int64(math.Round(float64(gold) * g))
	}
	killGold = gold
	// With a ground-item hub the gold lands on the ground as the pile the
	// engine spawns (ITEM_ETC_GOLD_03) and is picked up, so nothing is
	// credited here -- see the drop block below. Without one (tests, an
	// older wiring) it is credited directly as before.
	if ground == nil {
		if err := chars.AddGold(ctx, characterID, gold); err != nil {
			return nil, 0, fmt.Errorf("combat: granting gold reward: %w", err)
		}
	}

	// Skill experience is granted BELOW with the experience (the kill's own
	// formula, FUN_004106b0) and converted at leveldata.SkillExpPerPoint.
	// Without a level table neither can be computed, so that path falls back
	// to the disclosed per-kill default -- see the else branch.

	// Experience, and a level-up if it crosses the curve -- only when the
	// server has a leveldata curve loaded (SetLevelTable). Without one, no
	// exp is tracked, the same way an empty item table means flat damage.
	// A level-up refills HP and is announced with OpLevelUp after the
	// attack result below.
	// Round 802: a job's monster pays job exp (jobpvp.go).
	jobMobKillCredit(ctx, d, characterID, monster)
	if levelTable.Loaded() {
		// Round 712 (party lane S2): the kill pays everyone its damage list
		// earns a share, as the monster's death distributor does --
		// CGObjMob::vslot_399, killshare.go -- not the killing blow alone.
		// The killer's own payout is what its OpAttackResult reports; the
		// skill experience every kill pays is the engine's FUN_004106b0
		// (round 709 corrected the census that said kills pay none).
		paid, err := distributeKill(ctx, d, characterID, monster, hits)
		if err != nil {
			return nil, 0, err
		}
		result.ExpGained = paid.expAdded
		result.SkillExpGained = paid.sp
		g := expGainFor(monster, paid)
		result.expGain = &g
		if paid.levelUp != nil {
			result.PlayerHP = int32(paid.hp)
			levelUp = paid.levelUp
		}
	} else if skills != nil && monster.SPReward > 0 {
		// No level table, so no experience to convert: fall back to the
		// disclosed whole-point default (combat.SPFor). This is the only
		// path that still hands out points directly, and it exists so a
		// deployment that has imported no leveldata still has a skill
		// economy at all.
		if _, err := skills.AddSkillPoints(ctx, characterID, int(monster.SPReward)); err != nil {
			return nil, 0, fmt.Errorf("combat: granting skill points: %w", err)
		}
	}
	return levelUp, killGold, nil
}

// announceKill tells the zone a monster died and settles the rest of the
// kill: the unique notice, the quest credit and the drops. others is who is sent OpMonsterDied
// -- the zone less the attacker, whose OpAttackResult already said so, or the
// whole zone for a kill with no attack result (status.go). sess is the
// killer's, and may be nil for a killer no longer in the world: then nothing
// is sent to them. performAttack's announcement moved here unchanged in round
// 659.
func announceKill(ctx context.Context, d combatDeps, sess *gateway.Session, others []world.Entity, characterID int64, monster combat.Monster, killGold int64, updated combat.Monster, killHits []combat.Hit) error {
	hub, ground, inv, dropSrc, parties := d.hub, d.ground, d.inv, d.dropSrc, d.parties
	// The kill reward itself was already granted above, before the
	// result packet went out -- see the comment there.
	msg := &MonsterDied{MonsterID: monster.ID}
	for _, e := range others {
		sendMonsterPush(e.Session, &proto.Packet{Opcode: OpMonsterDied, Data: msg.Encode()})
	}
	// A unique's death is announced to the whole world (round 657): the
	// top-damage member of the top-damage group is named. Nothing for
	// any other rank. updated and killHits are the killing blow's
	// (damageMonsterWatched).
	AnnounceUniqueKill(hub, parties, updated, killHits)

	// The killer's quests (round 785, quest.go): kill counts and gather drops.
	questOnKill(ctx, sess, characterID, monster)

	if ground != nil {
		// The kill's gold and loot lie on the ground near the corpse,
		// owned by the killer for the 30 s window, announced to the zone.
		dropKillLoot(ground, hub, monster, characterID, killGold, dropsForKill(ctx, dropSrc, monster))
		return nil
	}
	if drops := rollLoot(ctx, inv, characterID, monster, dropSrc); len(drops) > 0 {
		lootMsg := &LootDropped{MonsterID: monster.ID, Drops: drops}
		if err := sess.Send(&proto.Packet{Opcode: OpLootDropped, Data: lootMsg.Encode()}); err != nil {
			return err
		}
	}
	return nil
}
