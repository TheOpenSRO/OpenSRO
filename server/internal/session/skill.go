package session

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Skill opcodes, our own protocol. Both require a prior OpLogin;
// OpUseSkill additionally requires a prior successful OpEnterWorld (same
// as OpAttack).
const (
	OpLearnSkill       uint16 = 0x0070 // client -> server
	OpLearnSkillResult uint16 = 0x0071 // server -> client
	OpUseSkill         uint16 = 0x0072 // client -> server
	// OpUseSkill's response reuses OpAttackResult -- using a skill is just
	// an attack with a damage bonus, and the client needs the exact same
	// information either way.
)

// LearnSkillRequest is the OpLearnSkill payload.
type LearnSkillRequest struct {
	CharacterName string
	SkillID       int64
}

func (r *LearnSkillRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.SkillID)...)
}

func DecodeLearnSkillRequest(data []byte) (*LearnSkillRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LearnSkillRequest: %w", err)
	}
	skillID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LearnSkillRequest: skill id: %w", err)
	}
	return &LearnSkillRequest{CharacterName: fields[0], SkillID: skillID}, nil
}

// LearnSkillResult is the OpLearnSkillResult payload.
type LearnSkillResult struct {
	OK     bool
	Reason string
}

func (r *LearnSkillResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeLearnSkillResult(data []byte) (*LearnSkillResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LearnSkillResult: %w", err)
	}
	return &LearnSkillResult{OK: ok, Reason: reason}, nil
}

// UseSkillRequest is the OpUseSkill payload.
type UseSkillRequest struct {
	CharacterName   string
	SkillID         int64
	TargetMonsterID int64
}

func (r *UseSkillRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	out = append(out, encodeInt64(r.SkillID)...)
	out = append(out, encodeInt64(r.TargetMonsterID)...)
	return out
}

func DecodeUseSkillRequest(data []byte) (*UseSkillRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseSkillRequest: %w", err)
	}
	skillID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseSkillRequest: skill id: %w", err)
	}
	targetID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseSkillRequest: target id: %w", err)
	}
	return &UseSkillRequest{CharacterName: fields[0], SkillID: skillID, TargetMonsterID: targetID}, nil
}

// LearnSkillHandler returns a gateway.Handler implementing OpLearnSkill
// against store.
func LearnSkillHandler(chars character.Store, store skill.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpLearnSkill {
			return nil
		}

		req, err := DecodeLearnSkillRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpLearnSkillResult,
				Data:   (&LearnSkillResult{Reason: "malformed request"}).Encode(),
			})
		}

		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return sess.Send(&proto.Packet{Opcode: OpLearnSkillResult, Data: (&LearnSkillResult{Reason: errStr}).Encode()})
		}

		if _, known := skill.Catalog[req.SkillID]; !known {
			return sess.Send(&proto.Packet{
				Opcode: OpLearnSkillResult,
				Data:   (&LearnSkillResult{Reason: "no such skill"}).Encode(),
			})
		}

		result := &LearnSkillResult{OK: true}
		if err := store.Learn(ctx, characterID, req.SkillID); err != nil {
			switch {
			case errors.Is(err, skill.ErrAlreadyKnown):
				result.Reason = "already known"
			default:
				result.Reason = "learn failed"
			}
			result.OK = false
		}
		return sess.Send(&proto.Packet{Opcode: OpLearnSkillResult, Data: result.Encode()})
	}
}

// UseSkillHandler returns a gateway.Handler implementing OpUseSkill:
// checks the character knows the skill and it's off cooldown, then
// delegates to performAttack with the skill's damage bonus. Responds with
// OpAttackResult (see OpUseSkill's doc comment) on all paths, including
// failures, so a client only needs one decoder for both attack types.
func UseSkillHandler(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	skills skill.Store,
	hub *world.Hub,
	monsters *combat.Hub,
) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpUseSkill {
			return nil
		}

		req, err := DecodeUseSkillRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "malformed request"}).Encode()})
		}

		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: errStr}).Encode()})
		}

		sk, known := skill.Catalog[req.SkillID]
		if !known {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "no such skill"}).Encode()})
		}

		knows, err := skills.Knows(ctx, characterID, req.SkillID)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "lookup failed"}).Encode()})
		}
		if !knows {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "skill not known"}).Encode()})
		}

		lastUsed, everUsed, err := skills.LastUsed(ctx, characterID, req.SkillID)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "lookup failed"}).Encode()})
		}
		now := time.Now()
		if everUsed {
			readyAt := lastUsed.Add(time.Duration(sk.CooldownSeconds) * time.Second)
			if now.Before(readyAt) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "skill on cooldown"}).Encode()})
			}
		}

		if err := skills.RecordUse(ctx, characterID, req.SkillID, now); err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "recording use failed"}).Encode()})
		}

		return performAttack(ctx, sess, chars, eq, items, hub, monsters, characterID, req.TargetMonsterID, sk.DamageBonus)
	}
}
