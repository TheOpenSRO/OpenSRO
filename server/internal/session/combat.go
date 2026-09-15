package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math/rand"
	"sync"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
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
	activated := zerk.Activate(characterID)
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

// unarmedDamage is the base damage dealt with no weapon equipped. Own
// design choice.
const unarmedDamage = 5

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

	// DeathExpLost is the experience the death penalty took, 0 when the
	// player did not die or is still inside the level-10 grace period. Real;
	// see leveldata.DeathPenaltyExp. Appended, so an older client that stops
	// reading at the berserk tail still decodes the rest.
	DeathExpLost int64
}

func (r *AttackResult) Encode() []byte {
	out := encodeStrings(r.Error)
	buf := make([]byte, 31)
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

// rollLoot rolls combat.LootTables[monsterName] and adds anything won to
// characterID's inventory, returning what actually landed. AddItem
// failures (unknown ref item, full inventory) are skipped rather than
// failing the whole kill -- loot is enrichment on top of a successful
// attack, not a precondition for one.
func rollLoot(ctx context.Context, inv inventory.Store, characterID int64, monsterName string) []LootDrop {
	entries, ok := combat.LootTables[monsterName]
	if !ok {
		return nil
	}
	var drops []LootDrop
	for _, e := range entries {
		if rand.Float64() > e.Chance {
			continue
		}
		qty := e.MinQuantity
		if e.MaxQuantity > e.MinQuantity {
			qty += rand.Intn(e.MaxQuantity - e.MinQuantity + 1)
		}
		if err := inv.AddItem(ctx, characterID, e.ItemID, qty); err != nil {
			continue
		}
		drops = append(drops, LootDrop{ItemID: e.ItemID, Quantity: int32(qty)})
	}
	return drops
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

			return performAttack(ctx, sess, chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, characterID, req.TargetMonsterID, 0)
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
func handleMonsterList(sess *gateway.Session, hub *world.Hub, monsters *combat.Hub) error {
	entity, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpMonsterListResult, Data: (&MonsterListResult{Error: "not in the world"}).Encode()})
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
	return sess.Send(&proto.Packet{Opcode: OpMonsterListResult, Data: (&MonsterListResult{Monsters: snapshots}).Encode()})
}

// performAttack computes damage (the attacker's base weapon/unarmed damage
// plus damageBonus -- 0 for a plain OpAttack, a skill's DamageBonus for
// OpUseSkill), applies it to the target monster, resolves the monster's
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
	characterID, targetMonsterID int64,
	damageBonus int,
) error {
	monster, ok := monsters.Get(targetMonsterID)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found"}).Encode()})
	}

	// A monster is only reachable from its own zone -- MonsterListResult
	// already only ever shows same-zone monsters (see handleMonsterList), so
	// treat a cross-zone target ID (e.g. looked up before a real zone
	// change, see world.Hub.ChangeZone) the same as an unknown one, rather
	// than leaking that a target with that ID exists somewhere else.
	attacker, ok := hub.EntityBySession(sess.ID())
	if !ok || attacker.Zone != monster.Zone {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found"}).Encode()})
	}

	base, err := attackerDamage(ctx, characterID, eq, items)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "damage calculation failed"}).Encode()})
	}

	// Both sides' levels, for the level-advantage term below and for the
	// monster's counterattack. A store that cannot answer leaves playerLevel
	// at zero and the term is simply skipped -- it only ever scales damage
	// up, so missing it costs nobody anything.
	playerLevel := 0
	if c, err := chars.GetByID(ctx, characterID); err == nil && c != nil {
		playerLevel = c.Level
	}

	raw := base + damageBonus
	// The game's own mitigation shape: a percentage reduction plus a flat
	// term, not the flat subtraction this used to do. The percentage is REAL
	// (characterdata cols 73/74 = the monster's level); the flat Defense is
	// still the disclosed curve. See combat.MitigateDamage.
	net := combat.MitigateDamage(raw, monster.DefensePercent, monster.Defense)
	// Berserk multiplies the blow AFTER mitigation, which is the order
	// Formula_MitigatePhysicalDamage uses: it divides by the percentage term,
	// subtracts the flat term, clamps at zero, and only then multiplies by
	// GetParam(189) + 2.0. This code boosted the raw roll instead until
	// 2026-09-15, with a comment claiming that was "the order the real
	// formula implies" -- it is not, and the two differ whenever the flat
	// term is non-zero: 2*(d/(1+p) - f) against (2d)/(1+p) - f, the second
	// of which quietly scales the defence away and over-pays berserk.
	if zerk != nil {
		net = zerk.Boost(characterID, net)
	}
	// Out-levelling the target hits harder: +3% a level, capped at +30%. Real,
	// and applied here because the game applies it last -- after mitigation and
	// after the berserk multiplier. See combat.LevelAdvantage.
	//
	// Both levels must be known. A zero is "not set", not "level zero", and
	// treating it as a level would hand a level-1 attacker a 3% bonus against
	// anything whose level simply was not filled in.
	if playerLevel > 0 && monster.Level > 0 {
		net = combat.ApplyLevelAdvantage(net, playerLevel, monster.Level)
	}

	updated, monsterDied, ok := monsters.ApplyDamage(targetMonsterID, net)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found"}).Encode()})
	}

	result := &AttackResult{MonsterDamage: int32(net), MonsterRemainingHP: int32(updated.HP), MonsterDied: monsterDied}
	// Fighting fills the berserk gauge; report it (and whether berserk is on)
	// so the HUD orbs and aura track it as the fight goes.
	if zerk != nil {
		result.BerserkGauge = int32(zerk.Fill(characterID))
		result.BerserkActive = zerk.Active(characterID)
	}
	var levelUp *LevelUp // set on a kill that crosses the exp curve, sent below

	// A dead monster can't counterattack. A surviving one always hits
	// back -- there's no dodge/evade system yet, see docs' open items.
	if monsterDied {
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
		if err := chars.AddGold(ctx, characterID, gold); err != nil {
			return fmt.Errorf("combat: granting gold reward: %w", err)
		}

		// Skill points from the kill -- the skill economy's income, spent
		// raising masteries (which unlocks skills in the skill window). Granted
		// on every kill like gold; the amount is a disclosed default
		// (combat.SPFor), see Monster.SPReward. A store without skill tracking
		// (nil) simply grants none.
		if skills != nil && monster.SPReward > 0 {
			if _, err := skills.AddSkillPoints(ctx, characterID, int(monster.SPReward)); err != nil {
				return fmt.Errorf("combat: granting skill points: %w", err)
			}
		}

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
			// column (an export that predates it).
			gainedExp := monster.ExpReward
			if unit, ok := levelTable.KillExp(char.Level, monster.Level); ok {
				gainedExp = unit
			}
			newLevel, newExp, gained := levelTable.Advance(char.Level, char.Exp, gainedExp)
			newStatPoints := char.StatPoints + gained*leveldata.StatPointsPerLevel
			if err := chars.SetLeveling(ctx, characterID, newLevel, newExp, newStatPoints); err != nil {
				return fmt.Errorf("combat: applying experience: %w", err)
			}
			if gained > 0 {
				if err := chars.ResetHP(ctx, characterID); err != nil {
					return fmt.Errorf("combat: refilling hp on level up: %w", err)
				}
				// Healed to the NEW level's higher maximum -- and mana with
				// it. Both derive from the character's own Str/Int, so read
				// the level off the advance rather than the stale record.
				result.PlayerHP = int32(character.MaxHPFor(char.Str, newLevel))
				if mp != nil {
					mp.Refill(characterID, character.MaxMPFor(char.Int, newLevel))
				}
				levelUp = &LevelUp{NewLevel: int32(newLevel), StatPoints: int32(newStatPoints)}
			}
		}
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
			raw = rollDamage(monster.AttackMin, monster.AttackMax)
		}
		incoming := raw - armor
		if incoming < 1 {
			incoming = 1
		}
		// The same level-advantage term, with the roles swapped: the monster
		// is the attacker in its own counterattack, so a monster that
		// out-levels the player hits harder for it. The formula is one
		// function and does not care which side is a player.
		if playerLevel > 0 && monster.Level > 0 {
			incoming = combat.ApplyLevelAdvantage(incoming, monster.Level, playerLevel)
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
						if err := chars.SetLeveling(ctx, characterID, c.Level, exp, c.StatPoints); err != nil {
							return fmt.Errorf("combat: applying death penalty: %w", err)
						}
						result.DeathExpLost = loss
					}
				}
			}
			if err := chars.ResetHP(ctx, characterID); err != nil {
				return fmt.Errorf("combat: respawning player: %w", err)
			}
			// Respawned at the character's own maximum, from its Str and
			// level. Falls back to the starting maximum only if the re-read
			// fails, which would mean the character vanished mid-respawn.
			result.PlayerHP = int32(character.StartingMaxHP)
			if reborn, e := chars.GetByID(ctx, characterID); e == nil {
				result.PlayerHP = int32(reborn.MaxHP())
				if mp != nil {
					mp.Refill(characterID, reborn.MaxMP())
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

		if drops := rollLoot(ctx, inv, characterID, monster.Name); len(drops) > 0 {
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
func attackerDamage(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) (int, error) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0, fmt.Errorf("reading equipment: %w", err)
	}

	for _, e := range equipped {
		if e.Slot != equipment.SlotWeapon {
			continue
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
		// The game rolls the blow in [min, max] rather than always swinging
		// for maximum -- see combat.RollDamage, recovered from
		// Formula_RollWeaponDamage. Both ends come from the client's own
		// itemdata.
		return rollDamage(int(item.PhysAttackMin), int(item.PhysAttackMax)), nil
	}
	return unarmedDamage, nil
}

// defenderArmor sums PhysDefenseMax across every real armor piece
// (equipment.ArmorSlots -- HELM/MAIL/SHOULDERGUARD/PANTS/BOOTS) characterID
// currently has equipped, for mitigating a monster's counterattack.
func defenderArmor(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) (int, error) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0, fmt.Errorf("reading equipment: %w", err)
	}

	isArmorSlot := make(map[equipment.Slot]bool, len(equipment.ArmorSlots))
	for _, s := range equipment.ArmorSlots {
		isArmorSlot[s] = true
	}

	total := 0
	for _, e := range equipped {
		if !isArmorSlot[e.Slot] {
			continue
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
		total += int(item.PhysDefenseMax)
	}
	return total, nil
}
