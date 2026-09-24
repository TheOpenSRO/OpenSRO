package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"math/rand"
	"sync"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/durability"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/grounditem"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/rates"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
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

func handleBerserk(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, zerk *berserk.Tracker) error {
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
	if c, err := chars.GetByID(ctx, characterID); err == nil {
		zerk.EnsureSeeded(characterID, c.HwanCount)
	}
	activated := zerk.Activate(characterID)
	if activated {
		// Activation spends orbs; the count lives on the character row.
		if err := chars.SetHwanCount(ctx, characterID, zerk.Charges(characterID)); err != nil {
			return fmt.Errorf("combat: persisting berserk spend: %w", err)
		}
	}
	return sess.Send(&proto.Packet{Opcode: OpBerserkResult, Data: (&BerserkResult{
		Activated: activated, Gauge: int32(zerk.Gauge(characterID)), Active: zerk.Active(characterID),
	}).Encode()})
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

// playerMitigationPercent is the percentage term of a player's damage
// mitigation: zero, and RECOVERED as zero rather than assumed.
//
// The engine's mitigation is `raw / (1 + pct/100) - flat` for both sides, with
// the percentage read as ParamKeeper param 7. A monster's is populated on every
// characterdata row (col 73 = its level, via GObjMob_PublishStats). A player's
// has three writers and none of them can set it:
//
//   - Char_PublishCombatStats (00497830) publishes it from a float field whose
//     source is the _RefObjItem defence block -- and a census of all 21,560
//     item rows finds no percentage-reduction column populated anywhere.
//   - The skill-effect applier (00594ac0) reaches it only through the skill
//     param code 'ar' (SkillGlobal::RefSkill_ParseParams, 00587630, writing
//     skill+0x268 as a 3-word run). 'ar' appears on ZERO of the 33,632 real
//     skill rows; the single numeric match is a skill's own id column.
//   - GObjMob_PublishStats is mobs only.
//
// The two defensive skill codes that ARE live go somewhere else entirely:
// 'defp' (273 skills) writes params 5/6 at slot 0 -- the FLAT absorb -- and
// 'defr' (4 skills) writes them at slot 1, a percentage boost to that flat
// term. Neither touches param 7.
//
// So a player never has a percentage reduction, and the asymmetry with monsters
// is the game's, not a gap here. If buffs ever land, 'defp'/'defr' belong on the
// flat term.
const playerMitigationPercent = 0

// AttackRequest is the OpAttack payload.
type AttackRequest struct {
	CharacterName   string
	TargetMonsterID int64
}

func (r *AttackRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.TargetMonsterID)...)
}

func DecodeAttackRequest(data []byte) (*AttackRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding AttackRequest: %w", err)
	}
	targetID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding AttackRequest: target id: %w", err)
	}
	return &AttackRequest{CharacterName: fields[0], TargetMonsterID: targetID}, nil
}

// AttackResult is the OpAttackResult payload (direct reply to the
// attacker): what happened to the monster, and what happened to the
// attacker in the monster's counterattack (skipped if the monster died).
// On failure, only Error is meaningful.
type AttackResult struct {
	Error string

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
}

func (m *MonsterSnapshot) Encode() []byte {
	out := append(encodeInt64(m.ID), encodeStrings(m.Name, m.CodeName)...)
	out = append(out, encodeFloat32(m.X)...)
	out = append(out, encodeFloat32(m.Y)...)
	out = append(out, encodeFloat32(m.Z)...)
	buf := make([]byte, 16)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(m.MaxHP))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(m.HP))
	binary.LittleEndian.PutUint32(buf[8:12], uint32(m.Level))
	binary.LittleEndian.PutUint32(buf[12:16], uint32(m.Rarity))
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
	return &MonsterSnapshot{
		ID: id, Name: names[0], CodeName: names[1], X: x, Y: y, Z: z,
		MaxHP:  int32(binary.LittleEndian.Uint32(rest[0:4])),
		HP:     int32(binary.LittleEndian.Uint32(rest[4:8])),
		Level:  int32(binary.LittleEndian.Uint32(rest[8:12])),
		Rarity: int32(binary.LittleEndian.Uint32(rest[12:16])),
	}, rest[16:], nil
}

// MonsterListResult is the OpMonsterListResult payload.
type MonsterListResult struct {
	Error    string
	Monsters []MonsterSnapshot
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
	return r, nil
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
) gateway.Handler {
	return combatHandler(chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, parties, ground, dropSrc)
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
	return combatHandler(chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, parties, ground, nil)
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
) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpBerserk:
			return handleBerserk(ctx, sess, p, chars, zerk)
		case OpAttack:
			req, err := DecodeAttackRequest(p.Data)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "malformed request"}).Encode()})
			}

			characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
			if errStr != "" {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: errStr}).Encode()})
			}

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
			if !firstSwingInReach(ctx, sess, eq, items, hub, monsters, characterID, req.TargetMonsterID) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "too far away"}).Encode()})
			}
			// A plain swing is the weapon's base attack skill, on that skill's
			// own re-use delay (round 255). A click inside the delay is the
			// engine's "action already running": nothing happens, no reply.
			if !swingReady(ctx, characterID, eq, items, skills, time.Now()) {
				return nil
			}
			// The swing IS the weapon's base attack skill (PrepareAction
			// 0x4ad030 writes DefaultAttackSkillID into the action context),
			// so its damage is that row's `att` share, hit count and mask --
			// see plainSwingOf. masteryPercent stays 0: see performAttack.
			sw := plainSwingOf(ctx, characterID, eq, items)
			if err := performAttack(ctx, sess, chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, parties, ground, dropSrc, characterID, req.TargetMonsterID, sw.flat, sw.percent, 0, sw.hits, sw.atk); err != nil {
				return err
			}
			// One click is the whole fight: the server repeats the swing on
			// the base attack's ReuseDelay until the target is dead (round
			// 256, keepup.go). A target the swing could not find arms
			// nothing; the first repeat would only find the same.
			if m, ok := monsters.Get(req.TargetMonsterID); ok && m.HP > 0 {
				deps := combatDeps{chars: chars, eq: eq, items: items, hub: hub, monsters: monsters, quests: quests, inv: inv, skills: skills, zerk: zerk, mp: mp, parties: parties, ground: ground, dropSrc: dropSrc}
				armKeepUp(sess, deps, characterID, req.TargetMonsterID, 0)
			}
			return nil
		case OpMonsterList:
			return handleMonsterList(sess, hub, monsters)
		default:
			return nil
		}
	}
}

// handleMonsterList responds with every live monster in the requesting
// session's current zone (via world.Hub -- same "who am I / where am I"
// resolution chat/duel/trade already use). Without this, a client has no
// way to discover a monster's ID to attack it at all.
//
// With the monster AI on (-monster-ai, round 537) ONE OpMonsterMotionList
// follows the result, carrying the listed monsters' legs (n may be 0), and
// both are built and written under the session's wire lock -- the lock the AI
// tick takes to push to this session -- so a push for a newer leg can never
// arrive ahead of a list built before it (monsterAI.wireLock). With it off the
// reply is exactly what it always was.
func handleMonsterList(sess *gateway.Session, hub *world.Hub, monsters *combat.Hub) error {
	entity, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpMonsterListResult, Data: (&MonsterListResult{Error: "not in the world"}).Encode()})
	}
	rt := monsterAIRuntime.Load()
	if rt != nil {
		wire := rt.wireLock(sess)
		wire.Lock()
		defer wire.Unlock()
	}

	inZone := monsters.InZone(entity.Zone)
	snapshots := make([]MonsterSnapshot, len(inZone))
	for i, m := range inZone {
		snapshots[i] = MonsterSnapshot{
			ID: m.ID, Name: m.Name, CodeName: m.CodeName,
			X: float32(m.X), Y: float32(m.Y), Z: float32(m.Z),
			MaxHP: int32(m.MaxHP), HP: int32(m.HP), Level: int32(m.Level), Rarity: int32(m.Rarity),
		}
	}
	if err := sess.Send(&proto.Packet{Opcode: OpMonsterListResult, Data: (&MonsterListResult{Monsters: snapshots}).Encode()}); err != nil || rt == nil {
		return err
	}
	return sess.Send(&proto.Packet{Opcode: OpMonsterMotionList, Data: motionListOf(inZone).Encode()})
}

// performAttack computes damage (the attacker's base weapon/unarmed damage
// plus damageBonus -- a skill's flat damage, which for a plain OpAttack is the
// weapon's base attack skill's and 0 on every real base row -- see
// plainSwingOf), applies it to the target monster, resolves the monster's
// counterattack, sends OpAttackResult to sess, grants gold on a kill, and
// broadcasts to everyone else in the zone. Shared by CombatHandler and
// skill.UseHandler so both attack paths behave identically.
// inParty reports whether a character is in a party, the condition the engine
// uses to choose between ExpRatio and ExpRatioParty (`pc[0x72e] != 0`).
func inParty(parties *party.Hub, characterID int64) bool {
	if parties == nil {
		return false
	}
	pt, in := parties.Get(characterID)
	return in && pt != nil && len(pt.Members) > 0
}

// killExpFor is what a kill is worth to characterID before the mastery, party
// and rate multipliers, and whether the level table knows it. Being in a party
// is Formula_ExpScaleByLevelDiff's gate for its gap bonus (0x410018-0x410027:
// `pc[0x72e]` non-null and bit 0 -- exp-sharing -- of the party's flags), and
// every srrevamp party shares experience (party.MaxSize). See
// leveldata.ExpDiffScale.
//
// The gate here asks for a SECOND member, which the engine's does not: it
// tests the party pointer. But the engine never creates a party of one. A
// party is born when an invite is accepted, with two member records at once
// (trs_wait_response::FUN_005be4f0, docs/protocol/party.md round 271), while
// srrevamp's own create path makes a party of just the leader -- so a pointer
// test here would pay the bonus to a lone player for clicking "create party",
// a state the engine has no way into (round 485). What the engine does when a
// party of two drops to one is UNREAD (the party lives in another server
// process), so that case follows the same two-member reading, disclosed.
func killExpFor(tbl *leveldata.Table, parties *party.Hub, characterID int64, killerLevel, victimLevel int) (int64, bool) {
	return tbl.KillExp(killerLevel, victimLevel, inPartyWithOthers(parties, characterID))
}

// inPartyWithOthers reports whether characterID is in a party that has at
// least one other member -- the only kind the engine creates. See killExpFor.
func inPartyWithOthers(parties *party.Hub, characterID int64) bool {
	if parties == nil {
		return false
	}
	pt, in := parties.Get(characterID)
	return in && pt != nil && len(pt.Members) >= 2
}

// applyMasteryExpScale scales a kill's experience by the gap between the
// character's level and its highest mastery level -- the engine's
// "keep your mastery up" rule, recovered in
// leveldata.MasteryExpScale (0.1 lost per level of lag, clamped to [0.1, 1.9]).
//
// Returns exp unchanged when there is no skill store, when the lookup fails, or
// when the scale works out to 1.0. A lookup FAILURE deliberately does not
// penalise the player: the engine always has the number to hand, so a missing
// one here is srrevamp's problem and should not cost someone 90% of a kill.
func applyMasteryExpScale(ctx context.Context, skills skill.Store, characterID int64, charLevel int, exp int64) int64 {
	if skills == nil || exp == 0 {
		return exp
	}
	levels, err := skills.MasteryLevels(ctx, characterID)
	if err != nil {
		return exp
	}
	best := 0
	for _, lvl := range levels {
		if lvl > best {
			best = lvl
		}
	}
	scale := leveldata.MasteryExpScale(charLevel, best)
	if scale == 1.0 {
		return exp
	}
	out := int64(math.Round(float64(exp) * scale))
	if out < 1 {
		out = 1
	}
	return out
}

// applyPartyExpBonus scales a kill's experience by the engine's party
// multiplier -- 1.0 plus 3% for every member past the first, recovered from the
// FMUL 0.03 / FADD 1.0 pair in CGObjCOS_GoldPet::vslot_399. See
// leveldata.PartyExpBonusPerMember, which also records what srrevamp still does
// NOT do: distribute a share to the other members.
//
// Returns exp unchanged when there is no party hub (the handler is constructed
// without one in several tests), when the character is in no party, or when the
// party has a single member -- all three are the engine's FLD1 default.
func applyPartyExpBonus(parties *party.Hub, characterID int64, exp int64) int64 {
	if parties == nil || exp == 0 {
		return exp
	}
	pt, in := parties.Get(characterID)
	if !in || pt == nil || len(pt.Members) < 2 {
		return exp
	}
	return int64(math.Round(float64(exp) * leveldata.PartyExpBonus(len(pt.Members))))
}

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
	characterID, targetMonsterID int64,
	damageBonus int,
	damagePercent int,
	// masteryPercent is stage 1 of the engine's damage pipeline: the weapon
	// roll is scaled by `1 + masteryPercent/100` BEFORE mitigation. See
	// combat.MasteryDamageScale.
	//
	// A plain swing passes 0, and that is srrevamp's limit, NOT the engine's
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

	// Both sides' levels, for the level-advantage term below and for the
	// monster's counterattack, and the attacker's Strength, which contributes
	// to both ends of its damage range. A store that cannot answer leaves
	// playerLevel at zero and the term is simply skipped -- it only ever
	// scales damage up, so missing it costs nobody anything -- and leaves
	// playerStr at zero, which drops the Strength term the same way.
	playerLevel, playerStr, playerInt := 0, 0, 0
	playerHPNow := 0
	if c, err := chars.GetByID(ctx, characterID); err == nil && c != nil {
		playerLevel, playerStr, playerInt = c.Level, c.Str, c.Int
		playerHPNow = c.HP
	}

	// The defender's parry rate: a monster's 'era' is characterdata col 75,
	// which holds 2*level + 25 on every monster row (combat.MonsterRate).
	base, err := attackerDamageOf(ctx, characterID, playerStr, playerInt, eq, items, attackType,
		playerLevel, monster.Level, combat.MonsterRate(monster.Level))
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "damage calculation failed", MonsterID: targetMonsterID}).Encode()})
	}

	// Stage 1: the roll is scaled by the caster's mastery before anything else
	// touches it. Recovered 2026-09-17 -- docs/protocol/damage_pipeline.md had
	// this stage's argument recorded as "damage" when it is a mastery percent.
	base = combat.ApplyMasteryScale(base, masteryPercent)

	// A skill's own flat damage is scaled DOWN when the monster out-levels the
	// attacker -- 2.5% per level, floored at 10%. This is the opposite term to
	// the level ADVANTAGE resolveBlow applies below, it has a different rate,
	// and the engine applies it to the skill's damage bucket alone rather than
	// to the weapon blow. See combat.SkillLevelPenalty for the disassembly and
	// for how the attacker was told from the target.
	damageBonus = combat.SkillLevelPenalty(damageBonus, playerLevel, monster.Level)

	// A skill's FLAT damage joins the roll here, before mitigation -- the
	// engine adds it to the rolled bound itself (FUN_0040db50 reads the attack
	// descriptor's +0x8 for the minimum and +0xc for the maximum). Its
	// PERCENTAGE does not; that lands after mitigation, below.
	raw := base + damageBonus
	// The game's own mitigation shape: a percentage reduction plus a flat
	// term, not the flat subtraction this used to do. The percentage is REAL
	// (characterdata cols 73/74 = the monster's level); the flat Defense is
	// still the disclosed curve. See combat.MitigateDamage.
	// One pipeline for every blow in the game -- see combat.ResolveBlow. The
	// monster's own block chance is characterdata col 76, which reads 0 for
	// every species on the Jangan ladder (938 monsters elsewhere carry 20), so
	// it is a real zero rather than an unmodelled one.
	blow := resolveBlow(raw, monster.DefensePercent, monster.Defense,
		combat.EvadedChance(attackerCritical(ctx, characterID, eq, items), monsterEvasion),
		combat.EvadedChance(monster.Block, playerEvasion),
		playerLevel, monster.Level, characterID, monster.ID)
	// A skill's percentage applies HERE, after mitigation and the clamp, not
	// to the raw roll -- see combat.ApplySkillPercent for the disassembly. A
	// plain attack passes its base attack skill's share (60 for a CH sword's
	// SKILL_CH_SWORD_BASE_01, 150 bare-handed), or 0 -- unchanged -- with no
	// base row (plainSwingOf).
	net := combat.ApplySkillPercent(blow.Damage, damagePercent)
	playerCrit := blow.Critical

	// A multi-hit skill strikes again, and each strike is INDEPENDENT: the
	// engine runs its whole damage resolution inside
	// `do { ... } while (i < record[5])`, with the damage-kind switch and the
	// mitigation calls inside the loop body, so every hit rolls its own
	// damage, critical and block. Multiplying one blow would be a different
	// distribution -- see refdata.Skill.HitCount.
	//
	// The first strike is the blow already resolved above; this adds the rest.
	for i := 1; i < hits; i++ {
		extra := resolveBlow(raw, monster.DefensePercent, monster.Defense,
			combat.EvadedChance(attackerCritical(ctx, characterID, eq, items), monsterEvasion),
			combat.EvadedChance(monster.Block, playerEvasion),
			playerLevel, monster.Level, characterID, monster.ID)
		net += combat.ApplySkillPercent(extra.Damage, damagePercent)
		playerCrit = playerCrit || extra.Critical
	}
	// Berserk multiplies the blow AFTER mitigation, which is the order
	// Formula_MitigatePhysicalDamage uses: it divides by the percentage term,
	// subtracts the flat term, clamps at zero, and only then multiplies by
	// GetParam(189) + 2.0. This code boosted the raw roll instead until
	// 2026-09-15, with a comment claiming that was "the order the real
	// formula implies" -- it is not, and the two differ whenever the flat
	// term is non-zero: 2*(d/(1+p) - f) against (2d)/(1+p) - f, the second
	// of which quietly scales the defence away and over-pays berserk.
	// ...except a floor blow. Berserk's multiplier is a term INSIDE the
	// mitigation formula, so when a zero percentage has already made that
	// formula's result zero, berserk multiplies zero, and the floor of 1 is
	// applied after it. Boosting the floored 1 here would double a blow the
	// engine leaves at exactly 1. See combat.SkillPercentZero.
	if zerk != nil && damagePercent != combat.SkillPercentZero {
		net = zerk.Boost(characterID, net)
	}

	// THE DAMAGE KIND. Everything above is the engine's ORDINARY kind, and
	// Combat_ResolveDamage switches away from it in four cases -- see
	// combat.SelectDamageKind for the selector and how each condition was
	// grounded. Two of the four replace the blow with a constant and are
	// applied here: a fortress weapon deals exactly 1 to anything that is not a
	// structure, and the hard-coded event monster takes its listed damage
	// whatever hits it. Both assign the total directly inside the engine's
	// per-hit loop, past every formula, so nothing computed above survives --
	// not the skill percentage, not berserk -- and a multi-hit skill lands the
	// constant once per hit.
	//
	// Neither is reachable with the content this server spawns today; they are
	// here because the rule is fully read and cheap, and so that a fortress
	// weapon or the winter event cannot arrive ahead of it. The other two kinds
	// (the monster transform, fortress structures) are identified but NOT
	// modelled -- the first needs a transform system and the second's formula
	// is unread -- and an srrevamp monster carries no TypeID, so a target is
	// never taken for a structure.
	kindIn := combat.KindInput{AttackerIsPC: true, TargetCodeName: monster.CodeName}
	if _, t4, known := equippedWeaponType(ctx, characterID, eq, items); known {
		kindIn.WeaponTypeID4 = t4
	}
	if perHit, fixed := combat.FixedDamagePerHit(combat.SelectDamageKind(kindIn), monster.CodeName); fixed {
		n := hits
		if n < 1 {
			n = 1
		}
		net = perHit * n
	}

	updated, monsterDied, ok := monsters.ApplyDamage(targetMonsterID, net)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found", MonsterID: targetMonsterID}).Encode()})
	}
	// The monster AI's struck event (round 537, monsterai.go): a surviving
	// monster is attacked (CAIState::OnAttacked 0x558ea0) and stopped at the
	// blow. A no-op while -monster-ai is off; nothing is sent from here.
	if !monsterDied {
		noteStruck(monsters, targetMonsterID, characterID)
	}
	// A landed blow wears the weapon: one roll at rate = hits (2% a hit).
	wearWeapon(ctx, eq, characterID, hits)

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
		MonsterDied: monsterDied, PlayerCritical: playerCrit, PlayerHP: int32(playerHPNow)}
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

	// A dead monster can't counterattack. A surviving one always hits
	// back -- there's no dodge/evade system yet, see docs' open items.
	if monsterDied {
		// The monster's object is gone, so its blocking streak goes with it.
		// The engine's accumulator lives on the object; nothing survives it.
		chanceMemory.Forget(targetMonsterID)
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
			if gained := zerk.EarnOnKill(characterID, berserk.Kill{
				KillerLevel: killerLevel, VictimLevel: monster.Level,
				VictimIsMonster: true, VictimRarity: monster.Rarity,
			}); gained > 0 {
				// The engine's count is a character-row column, so a gain has
				// to reach the row -- see character.Character.HwanCount.
				if err := chars.SetHwanCount(ctx, characterID, zerk.Charges(characterID)); err != nil {
					return fmt.Errorf("combat: persisting berserk orbs: %w", err)
				}
			}
			result.BerserkGauge = int32(zerk.Gauge(characterID))
		}
		// No damage taken, but the client still wants to know current HP.
		hp, _, err := chars.ApplyDamage(ctx, characterID, 0)
		if err != nil {
			return fmt.Errorf("combat: reading player hp: %w", err)
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
				return fmt.Errorf("combat: granting gold reward: %w", err)
			}
		}

		// Skill points from the kill are granted BELOW, out of the kill's own
		// experience, because the game grants skill EXPERIENCE and converts it
		// at leveldata.SkillExpPerPoint. Without a level table there is no
		// experience to convert, so that path falls back to the disclosed
		// per-kill default -- see the else branch.

		// Experience, and a level-up if it crosses the curve -- only when the
		// server has a leveldata curve loaded (SetLevelTable). Without one, no
		// exp is tracked, the same way an empty item table means flat damage.
		// A level-up refills HP and is announced with OpLevelUp after the
		// attack result below.
		if levelTable.Loaded() {
			char, err := chars.GetByID(ctx, characterID)
			if err != nil {
				return fmt.Errorf("combat: reading character for exp: %w", err)
			}
			// What the kill is worth. The level table's own EXP unit when it
			// has one, taken at the MINIMUM of the two levels -- the game's
			// anti-powerlevelling rule, recovered from
			// Formula_MonsterExpReward. Falls back to the disclosed
			// toughness-derived ExpReward only for a table with no exp_unit
			// column (an export that predates it). A killer in a party also
			// earns the diff scaler's gap bonus -- see killExpFor.
			gainedExp := monster.ExpReward
			if unit, ok := killExpFor(levelTable, parties, characterID, char.Level, monster.Level); ok {
				gainedExp = unit
			}
			gainedExp = applyMasteryExpScale(ctx, skills, characterID, char.Level, gainedExp)
			gainedExp = applyPartyExpBonus(parties, characterID, gainedExp)
			// The server's ExpRatio / ExpRatioParty knob. The engine picks
			// ONE of the two by party membership rather than multiplying
			// both -- see rates.Rates.ExpFor.
			if m := rates.Current().ExpFor(inParty(parties, characterID)); m != 1 {
				gainedExp = int64(math.Round(float64(gainedExp) * m))
			}
			// The skill economy's income. The game grants skill EXPERIENCE,
			// carries it on the character and converts whole points out of the
			// running total at 400:1 -- see leveldata.SkillExpPerPoint, which
			// is the recovered part.
			//
			// How much skill experience a KILL is worth is NOT recovered, and
			// the search for it is now exhaustive rather than partial. Every
			// route into the skill-point currency has been enumerated:
			//
			//   - _CHAR.SExpOffset (charData+0x70), the carried total, has
			//     exactly ONE writer in the binary -- the 400:1 conversion
			//     inside GObjPC_GainExpAndLevel. The only other function that
			//     touches it, FUN_0049efc0, reads it into a packet.
			//   - Of the 42 call sites of GainExpAndLevel, only four pass a
			//     non-zero skill-exp argument (it is the FOURTH argument, and
			//     every ordinary exp grant passes zero there). None is a kill:
			//     they are a quest reward, its party distribution, and two
			//     others off the same quest path.
			//   - Every positive caller of AddSkillPoints is either that
			//     conversion or a skill/mastery WITHDRAWAL refund.
			//
			// So no kill path in this binary feeds the currency at all, and
			// there is no M to read for a kill. srrevamp takes M = 1 -- a kill
			// is worth its own experience in skill experience -- which is a
			// DISCLOSED choice and the single knob to turn if a kill-side
			// source is ever found.
			//
			// Guild points inherit that M = 1 (round 525): cmd/server hands
			// this path NewGuildPointSkills' wrapper, which credits a member's
			// guild 1:1 with the points this call converts, so the disclosed
			// M also sets how fast GatheredSP grows from kills.
			if skills != nil && gainedExp > 0 {
				if _, _, err := skills.AddSkillExp(ctx, characterID, gainedExp); err != nil {
					return fmt.Errorf("combat: granting skill experience: %w", err)
				}
			}
			newLevel, newExp, gained := levelTable.Advance(char.Level, char.Exp, gainedExp)
			newStatPoints := char.StatPoints + gained*leveldata.StatPointsPerLevel
			// Str and Int rise by one each per level, automatically and without
			// the player choosing -- on top of the three spendable points.
			// GObjPC_SetLevel grants five points and immediately calls
			// SpendStatPoints(levels, levels), which is `Str += levels` and
			// `Int += levels`; the asm is `movzx ecx,[eax+0x74]; add cx,si;
			// call SetStr`, and it publishes ParamKeeper param 1 (Str)
			// afterwards. See leveldata.StatPointsPerLevel for the full
			// arithmetic and docs/GROUNDING_AUDIT.md for why this took a tick
			// of its own: it moves every derived HP and MP number.
			newStr := char.Str + gained*character.StatGrowthPerLevel
			newInt := char.Int + gained*character.StatGrowthPerLevel
			if err := chars.SetLeveling(ctx, characterID, newLevel, newExp, newStatPoints, newStr, newInt); err != nil {
				return fmt.Errorf("combat: applying experience: %w", err)
			}
			if gained > 0 {
				if err := chars.ResetHP(ctx, characterID); err != nil {
					return fmt.Errorf("combat: refilling hp on level up: %w", err)
				}
				// Healed to the NEW level's higher maximum -- and mana with
				// it. Both derive from the character's own Str/Int, so read
				// the level off the advance rather than the stale record.
				// The new Str/Int, not the stale record's: the level-up
				// raised them, and the engine's refill goes to the maximum
				// those give (GObjPC_SetLevel heals by GetMaxHP - GetCurHP).
				result.PlayerHP = int32(character.MaxHPFor(newStr, newLevel))
				if mp != nil {
					mp.Refill(characterID, character.MaxMPFor(newInt, newLevel))
				}
				levelUp = &LevelUp{NewLevel: int32(newLevel), StatPoints: int32(newStatPoints)}
			}
		} else if skills != nil && monster.SPReward > 0 {
			// No level table, so no experience to convert: fall back to the
			// disclosed whole-point default (combat.SPFor). This is the only
			// path that still hands out points directly, and it exists so a
			// deployment that has imported no leveldata still has a skill
			// economy at all.
			if _, err := skills.AddSkillPoints(ctx, characterID, int(monster.SPReward)); err != nil {
				return fmt.Errorf("combat: granting skill points: %w", err)
			}
		}
	} else if !monsters.CounterattackReady(monster.ID, time.Now()) {
		// Inside its attack skill's re-use delay: the real monster is still
		// in that skill's action and cannot strike again yet (combat.Hub.
		// CounterattackReady). The player's blow landed; there is no reply.
	} else {
		armor, err := defenderArmor(ctx, characterID, eq, items)
		if err != nil {
			return fmt.Errorf("combat: reading armor: %w", err)
		}
		// A monster attacks with its SKILL's damage range (characterdata col 83
		// -> that skill's 'att' param), rolled the same way a weapon is. The
		// flat disclosed Attack remains only for a monster with no range.
		raw := monster.Attack
		if monster.AttackMax > 0 {
			// WHERE in that range the blow lands is the same centre-biased
			// roll the player's attack takes, with the sides swapped: the
			// monster's attack rate (2*level + 25) against the player's parry.
			//
			// Guarded the same way, and for the same reason: a player with no
			// armour parry at all means an item table imported before itemdata
			// col 68 existed, and treating that as a real zero would put every
			// monster blow at the 90 % ceiling on exactly the deployments that
			// have imported least.
			parry, perr := defenderParryRate(ctx, characterID, eq, items)
			if perr != nil {
				parry = 0
			}
			raw = monsterBlow(monster, playerLevel, parry)
		}
		// The player's side of the SAME mitigation the monster gets, through
		// the same function -- percentage term first, then the flat absorb.
		// The player's percentage is ZERO, and that is recovered rather than
		// a simplification: a player's ParamKeeper param 7 has exactly three
		// writers, and none of them can make it non-zero here.
		//
		//   GObjMob_PublishStats     mobs only (characterdata col 73)
		//   Char_PublishCombatStats  from a field no item column populates --
		//                            a census of all 21,560 item rows finds
		//                            no percentage-reduction column at all
		//   the skill-effect applier only through the skill param code 'ar',
		//                            which appears on ZERO of 29,342 skill
		//                            rows (the one numeric hit is a skill id)
		//
		// So the asymmetry this code already had -- monsters carry a
		// percentage, players do not -- is the game's own. Written as an
		// explicit 0 through combat.MitigateDamage rather than as a bare
		// subtraction, so the zero carries its citation instead of being a
		// coincidence that happens to compute the same number.
		// A blocked blow deals NOTHING, and the whole damage pipeline is
		// skipped rather than reduced to zero -- which is exactly what the
		// real resolve function does: a successful block jumps past every
		// Formula_Mitigate* call and leaves the damage record at its
		// zero-initialised value. So the roll comes first, and mitigation,
		// the critical and the level term are the things it skips.
		// The counterattack is the same pipeline with the roles swapped: the
		// monster is the attacker, so its Critical applies and the player's
		// shield is what blocks. combat.ResolveBlow does not care which side
		// is a player, which is the point of it being one function.
		counter := resolveBlow(raw, playerMitigationPercent, armor,
			combat.EvadedChance(monster.Critical, playerEvasion),
			combat.EvadedChance(defenderBlock(ctx, characterID, eq, items), monsterEvasion),
			monster.Level, playerLevel, monster.ID, characterID)
		incoming := counter.Damage
		result.MonsterCritical = counter.Critical
		result.PlayerBlocked = counter.Blocked
		// The counterattack wears the defender's gear: a blocked hit the
		// shield, any other hit one armour piece.
		if counter.Blocked {
			wearShield(ctx, eq, characterID)
		} else if counter.Damage > 0 {
			wearArmour(ctx, eq, characterID)
		}
		hp, playerDied, err := chars.ApplyDamage(ctx, characterID, incoming)
		if err != nil {
			return fmt.Errorf("combat: applying counterattack: %w", err)
		}
		result.PlayerDamageTaken = int32(incoming)
		result.PlayerDied = playerDied
		if playerDied {
			// Dying costs experience, above level 10. Real: GObjPC_OnDeath
			// multiplies the level's EXP unit -- the same field a kill is
			// paid from -- by 100 when a monster did the killing and the
			// victim carries no PK penalty points, which is the only branch
			// this project can reach until there is a PK system. See
			// leveldata.DeathPenaltyExp for the other three and for why the
			// reduction stat is left out.
			if levelTable != nil {
				if c, e := chars.GetByID(ctx, characterID); e == nil && c != nil {
					loss, ok := levelTable.DeathPenaltyExp(c.Level, leveldata.DeathPenaltyKilledByMonster)
					if ok && loss > 0 {
						exp := c.Exp - loss
						if exp < 0 {
							// The real formula clamps the LOSS so it cannot
							// exceed what is there; clamping the result to
							// zero is the same thing from this side. A death
							// never costs a level -- nothing in
							// GObjPC_OnDeath touches CurLevel.
							exp = 0
						}
						// A death penalty takes experience only: level, stat
						// points, Str and Int are carried through unchanged.
						if err := chars.SetLeveling(ctx, characterID, c.Level, exp, c.StatPoints, c.Str, c.Int); err != nil {
							return fmt.Errorf("combat: applying death penalty: %w", err)
						}
						result.DeathExpLost = loss
					}
				}
			}
			if err := chars.RespawnHP(ctx, characterID); err != nil {
				return fmt.Errorf("combat: respawning player: %w", err)
			}
			// Death ends the action queue with everything else: no repeat
			// fires for a character who has just been put back on their feet.
			keepUp.Cancel(characterID)
			// Back at character.RespawnFraction of the maximum, not all of
			// it: the game restores a character whose stored pool is zero --
			// which is what death leaves -- to 40%, for HP and MP alike. See
			// character.RespawnFraction for the recovery. A level-up still
			// heals to full, which is why that path calls ResetHP instead.
			//
			// Falls back to the starting maximum only if the re-read fails,
			// which would mean the character vanished mid-respawn.
			result.PlayerHP = int32(character.StartingMaxHP)
			if reborn, e := chars.GetByID(ctx, characterID); e == nil {
				result.PlayerHP = int32(reborn.HP)
				if mp != nil {
					mp.Refill(characterID, character.RespawnMP(reborn.MaxMP()))
				}
			}
		} else {
			result.PlayerHP = int32(hp)
		}
	}

	if err := sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: result.Encode()}); err != nil {
		return err
	}

	// The level-up (if any) rides just behind the attack result, direct to the
	// attacker, so the client can play the effect and refresh the character
	// window.
	if levelUp != nil {
		if err := sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: levelUp.Encode()}); err != nil {
			return err
		}
	}

	// The attacker already got the richer OpAttackResult above; only
	// broadcast to everyone *else* in the zone, not back to them too.
	var others []world.Entity
	for _, e := range hub.EntitiesInZone(monster.Zone) {
		if e.Session.ID() != sess.ID() {
			others = append(others, e)
		}
	}

	if monsterDied {
		// The kill reward itself was already granted above, before the
		// result packet went out -- see the comment there.
		msg := &MonsterDied{MonsterID: targetMonsterID}
		for _, e := range others {
			e.Session.Send(&proto.Packet{Opcode: OpMonsterDied, Data: msg.Encode()})
		}

		completedQuests, err := quests.RecordKill(ctx, characterID, monster.Name)
		if err != nil {
			return fmt.Errorf("combat: recording quest kill: %w", err)
		}
		for _, q := range completedQuests {
			if err := chars.AddGold(ctx, characterID, q.GoldReward); err != nil {
				return fmt.Errorf("combat: granting quest reward: %w", err)
			}
			completedMsg := &QuestCompleted{QuestID: q.ID, GoldReward: q.GoldReward}
			if err := sess.Send(&proto.Packet{Opcode: OpQuestCompleted, Data: completedMsg.Encode()}); err != nil {
				return err
			}
		}

		if ground != nil {
			// The kill's gold and loot lie on the ground near the corpse,
			// owned by the killer for the 30 s window, announced to the zone.
			dropKillLoot(ground, hub, monster, characterID, killGold, dropsForKill(ctx, dropSrc, monster))
			return nil
		}
		if drops := rollLoot(ctx, inv, characterID, monster, dropSrc); len(drops) > 0 {
			lootMsg := &LootDropped{MonsterID: targetMonsterID, Drops: drops}
			if err := sess.Send(&proto.Packet{Opcode: OpLootDropped, Data: lootMsg.Encode()}); err != nil {
				return err
			}
		}
		return nil
	}

	msg := &MonsterDamaged{MonsterID: targetMonsterID, Damage: int32(net), RemainingHP: int32(updated.HP)}
	for _, e := range others {
		e.Session.Send(&proto.Packet{Opcode: OpMonsterDamaged, Data: msg.Encode()})
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

// swingReady is the plain attack's cadence gate: the equipped weapon type's
// base attack skill (combat.BaseAttackSkillFor -- SKILL_CH_SWORD_BASE_01 for
// a sword, SKILL_PUNCH_01 bare-handed) has a ReuseDelay in the imported skill
// table, and a swing inside it is dropped, exactly as the engine's action
// machine ignores a second use while the first runs. When it passes, the
// swing is recorded against that skill id. Without reference data for the
// skill (or a store that cannot look skills up) there is no gate, as before.
func swingReady(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup, skills skill.Store, now time.Time) bool {
	if skills == nil {
		return true
	}
	ref, ok := baseAttackOf(ctx, characterID, eq, items)
	if !ok || ref.ReuseDelayMs <= 0 {
		return true
	}
	last, ever, err := skills.LastUsed(ctx, characterID, ref.ID)
	if err == nil && ever && now.Sub(last) < time.Duration(ref.ReuseDelayMs)*time.Millisecond {
		return false
	}
	_ = skills.RecordUse(ctx, characterID, ref.ID, now)
	return true
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
			hra := combat.CharacterRate(attackerLevel, item.HitRateMin)
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
func weaponInstance(e equipment.Equipped) combat.Instance {
	return combat.Instance{Variance: e.Variance, Tracked: e.Durability != durability.Untracked}
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
// srrevamp left the shield out of the sum). A weapon's block carries no
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
	if m.AttackMax <= 0 {
		return m.Attack // no range at all: the flat disclosed Attack
	}
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
// The LO end is taken, not an instance-interpolated value. defenderDefence
// interpolates its pairs through a recovered variance group; no such group is
// recovered for parry, and inventing one would be worse than the documented
// rule for this field -- srrevamp models neither per-instance variance nor plus
// level, so lo is what applies.
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
		total += it.ParryRatioMin
	}
	return total, nil
}

func defenderArmor(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) (int, error) {
	return defenderDefence(ctx, characterID, eq, items, func(it *refdata.Item) (float64, float64) {
		return it.PhysDefenseMin, it.PhysDefenseMax
	}, durability.ArmourPhysDefenseGroup, durability.ShieldPhysDefenseGroup)
}

// defenderDefence is the shared walk behind defenderArmor and its magical
// twin: the worn armour and shield, each piece's range through its instance's
// variance group (armourGroup for the six armour slots, shieldGroup for the
// shield), summed and rounded once at the end (the engine keeps floats and
// srrevamp's wire field is an int32).
func defenderDefence(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup, rangeOf func(*refdata.Item) (float64, float64), armourGroup, shieldGroup int) (int, error) {
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
		lo, hi := rangeOf(item)
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
		item, err := items.GetItem(ctx, e.ItemID)
		if err != nil || item == nil {
			return 0
		}
		return int(item.CriticalMin)
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
// independent streak protection in the real game; srrevamp models neither.
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
		if e.Durability == durability.Untracked {
			return int(item.BlockRatioMin)
		}
		return int(math.Round(durability.WhiteStat(item.BlockRatioMin, item.BlockRatioMax, e.Variance, durability.ShieldBlockGroup)))
	}
	return 0
}

// The two evasion terms that oppose the critical and block rolls. Both are
// zero, and combat.EvadedChance explains why they are zero for DIFFERENT
// reasons -- which is the whole point of naming them apart rather than writing
// a literal 0 six times.
const (
	// monsterEvasion is a monster's 'evcr' or 'evbl'. GROUNDED: the engine's
	// own GObjMob_PublishStats publishes params 0, 3-12, 23, 24, 27-33 and 140,
	// and neither 56 nor 57 is among them, so a monster has no evasion term to
	// publish. This is a measured value, not a simplification.
	monsterEvasion = 0.0

	// playerEvasion is a player's 'evcr' or 'evbl'. DISCLOSED: both arrive only
	// as magic options ("blue" stats), and srrevamp aggregates none, so no
	// player can carry either. combat.TestNoPlayerEvasionSourceExists fails the
	// day that stops being true, and the fix is to compute the real term here.
	playerEvasion = 0.0
)

// resolveBlow is combat.ResolveBlow under the SAME lock as every other roll in
// this package -- it takes two chance rolls, and rand.Rand is not safe for
// concurrent use.
func resolveBlow(base, mitigationPercent, flat, critChance, blockChance, attackerLevel, defenderLevel int, attackerID, defenderID int64) combat.Blow {
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
