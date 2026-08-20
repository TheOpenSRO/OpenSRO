package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"math/rand"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Combat opcodes, our own protocol. OpAttack requires a prior successful
// OpEnterWorld (the attacker's zone comes from world.Hub).
const (
	OpAttack         uint16 = 0x0060 // client -> server
	OpAttackResult   uint16 = 0x0061 // server -> client, direct ack to the attacker
	OpMonsterDamaged uint16 = 0x0062 // server -> client, broadcast to the zone
	OpMonsterDied    uint16 = 0x0063 // server -> client, broadcast to the zone
	OpLootDropped    uint16 = 0x0064 // server -> client, direct to the killer (only sent if there's loot)
)

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
}

func (r *AttackResult) Encode() []byte {
	out := encodeStrings(r.Error)
	buf := make([]byte, 18)
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
	return &AttackResult{
		Error:              fields[0],
		MonsterDamage:      int32(binary.LittleEndian.Uint32(rest[0:4])),
		MonsterRemainingHP: int32(binary.LittleEndian.Uint32(rest[4:8])),
		MonsterDied:        rest[8] != 0,
		PlayerDamageTaken:  int32(binary.LittleEndian.Uint32(rest[9:13])),
		PlayerHP:           int32(binary.LittleEndian.Uint32(rest[13:17])),
		PlayerDied:         rest[17] != 0,
	}, nil
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
) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpAttack {
			return nil
		}

		req, err := DecodeAttackRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "malformed request"}).Encode()})
		}

		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: errStr}).Encode()})
		}

		return performAttack(ctx, sess, chars, eq, items, hub, monsters, quests, inv, characterID, req.TargetMonsterID, 0)
	}
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
	characterID, targetMonsterID int64,
	damageBonus int,
) error {
	monster, ok := monsters.Get(targetMonsterID)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found"}).Encode()})
	}

	base, err := attackerDamage(ctx, characterID, eq, items)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "damage calculation failed"}).Encode()})
	}

	net := base + damageBonus - monster.Defense
	if net < 1 {
		net = 1
	}

	updated, monsterDied, ok := monsters.ApplyDamage(targetMonsterID, net)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found"}).Encode()})
	}

	result := &AttackResult{MonsterDamage: int32(net), MonsterRemainingHP: int32(updated.HP), MonsterDied: monsterDied}

	// A dead monster can't counterattack. A surviving one always hits
	// back -- there's no dodge/evade system yet, see docs' open items.
	if monsterDied {
		// No damage taken, but the client still wants to know current HP.
		hp, _, err := chars.ApplyDamage(ctx, characterID, 0)
		if err != nil {
			return fmt.Errorf("combat: reading player hp: %w", err)
		}
		result.PlayerHP = int32(hp)
	} else {
		hp, playerDied, err := chars.ApplyDamage(ctx, characterID, monster.Attack)
		if err != nil {
			return fmt.Errorf("combat: applying counterattack: %w", err)
		}
		result.PlayerDamageTaken = int32(monster.Attack)
		result.PlayerDied = playerDied
		if playerDied {
			if err := chars.ResetHP(ctx, characterID); err != nil {
				return fmt.Errorf("combat: respawning player: %w", err)
			}
			result.PlayerHP = int32(character.MaxHP)
		} else {
			result.PlayerHP = int32(hp)
		}
	}

	if err := sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: result.Encode()}); err != nil {
		return err
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
		if err := chars.AddGold(ctx, characterID, monster.GoldReward); err != nil {
			return fmt.Errorf("combat: granting gold reward: %w", err)
		}
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
		if err != nil {
			return 0, fmt.Errorf("looking up weapon stats: %w", err)
		}
		return int(item.PhysAttackMax), nil
	}
	return unarmedDamage, nil
}
