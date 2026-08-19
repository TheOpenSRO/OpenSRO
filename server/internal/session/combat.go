package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Combat opcodes, our own protocol. OpAttack requires a prior successful
// OpEnterWorld (the attacker's zone comes from world.Hub).
const (
	OpAttack         uint16 = 0x0060 // client -> server
	OpAttackResult   uint16 = 0x0061 // server -> client, direct ack to the attacker
	OpMonsterDamaged uint16 = 0x0062 // server -> client, broadcast to the zone
	OpMonsterDied    uint16 = 0x0063 // server -> client, broadcast to the zone
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
// attacker). On failure, only Error is meaningful.
type AttackResult struct {
	Error       string
	Damage      int32
	RemainingHP int32
	Died        bool
}

func (r *AttackResult) Encode() []byte {
	out := encodeStrings(r.Error)
	buf := make([]byte, 9)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Damage))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.RemainingHP))
	if r.Died {
		buf[8] = 1
	}
	return append(out, buf...)
}

func DecodeAttackResult(data []byte) (*AttackResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding AttackResult: %w", err)
	}
	if len(rest) < 9 {
		return nil, errors.New("session: decoding AttackResult: truncated")
	}
	return &AttackResult{
		Error:       fields[0],
		Damage:      int32(binary.LittleEndian.Uint32(rest[0:4])),
		RemainingHP: int32(binary.LittleEndian.Uint32(rest[4:8])),
		Died:        rest[8] != 0,
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

		monster, ok := monsters.Get(req.TargetMonsterID)
		if !ok {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found"}).Encode()})
		}

		damage, err := attackerDamage(ctx, characterID, eq, items)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "damage calculation failed"}).Encode()})
		}

		net := damage - monster.Defense
		if net < 1 {
			net = 1
		}

		updated, died, ok := monsters.ApplyDamage(req.TargetMonsterID, net)
		if !ok {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "target not found"}).Encode()})
		}

		if err := sess.Send(&proto.Packet{
			Opcode: OpAttackResult,
			Data:   (&AttackResult{Damage: int32(net), RemainingHP: int32(updated.HP), Died: died}).Encode(),
		}); err != nil {
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

		if died {
			if err := chars.AddGold(ctx, characterID, monster.GoldReward); err != nil {
				return fmt.Errorf("combat: granting gold reward: %w", err)
			}
			msg := &MonsterDied{MonsterID: req.TargetMonsterID}
			for _, e := range others {
				e.Session.Send(&proto.Packet{Opcode: OpMonsterDied, Data: msg.Encode()})
			}
			return nil
		}

		msg := &MonsterDamaged{MonsterID: req.TargetMonsterID, Damage: int32(net), RemainingHP: int32(updated.HP)}
		for _, e := range others {
			e.Session.Send(&proto.Packet{Opcode: OpMonsterDamaged, Data: msg.Encode()})
		}
		return nil
	}
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
