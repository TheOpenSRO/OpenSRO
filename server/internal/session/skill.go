package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Skill opcodes, our own protocol. All three require a prior OpLogin;
// OpUseSkill additionally requires a prior successful OpEnterWorld (same
// as OpAttack).
const (
	OpLearnSkill       uint16 = 0x0070 // client -> server
	OpLearnSkillResult uint16 = 0x0071 // server -> client
	OpUseSkill         uint16 = 0x0072 // client -> server
	// OpUseSkill's response reuses OpAttackResult -- using a skill is just
	// an attack with a damage bonus, and the client needs the exact same
	// information either way.
	OpSkillList       uint16 = 0x0073 // client -> server
	OpSkillListResult uint16 = 0x0074 // server -> client
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
	quests quest.Store,
	inv inventory.Store,
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

		return performAttack(ctx, sess, chars, eq, items, hub, monsters, quests, inv, characterID, req.TargetMonsterID, sk.DamageBonus)
	}
}

// SkillListRequest is the OpSkillList payload.
type SkillListRequest struct {
	CharacterName string
}

func (r *SkillListRequest) Encode() []byte { return encodeStrings(r.CharacterName) }

func DecodeSkillListRequest(data []byte) (*SkillListRequest, error) {
	fields, _, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillListRequest: %w", err)
	}
	return &SkillListRequest{CharacterName: fields[0]}, nil
}

// SkillSnapshot is one catalog skill, as sent over the wire, with the
// requesting character's own real relationship to it (known or not, and how
// many seconds until it's off cooldown -- 0 if it's ready now or was never
// used).
type SkillSnapshot struct {
	ID              int64
	Name            string
	DamageBonus     int32
	CooldownSeconds int32
	Known           bool
	ReadySeconds    int32
}

func (s *SkillSnapshot) Encode() []byte {
	out := append(encodeInt64(s.ID), encodeStrings(s.Name)...)
	buf := make([]byte, 13)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(s.DamageBonus))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(s.CooldownSeconds))
	if s.Known {
		buf[8] = 1
	}
	binary.LittleEndian.PutUint32(buf[9:13], uint32(s.ReadySeconds))
	return append(out, buf...)
}

func decodeSkillSnapshot(data []byte) (*SkillSnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("skill id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("name: %w", err)
	}
	if len(rest) < 13 {
		return nil, nil, errors.New("truncated fields")
	}
	return &SkillSnapshot{
		ID: id, Name: names[0],
		DamageBonus:     int32(binary.LittleEndian.Uint32(rest[0:4])),
		CooldownSeconds: int32(binary.LittleEndian.Uint32(rest[4:8])),
		Known:           rest[8] != 0,
		ReadySeconds:    int32(binary.LittleEndian.Uint32(rest[9:13])),
	}, rest[13:], nil
}

// SkillListResult is the OpSkillListResult payload.
type SkillListResult struct {
	Error  string
	Skills []SkillSnapshot
}

func (r *SkillListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Skills)))
	out = append(out, countBuf...)
	for _, s := range r.Skills {
		out = append(out, s.Encode()...)
	}
	return out
}

func DecodeSkillListResult(data []byte) (*SkillListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillListResult: %w", err)
	}
	r := &SkillListResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	if len(rest) < 2 {
		return nil, errors.New("session: decoding SkillListResult: truncated skill count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *SkillSnapshot
		snap, rest, err = decodeSkillSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding SkillListResult: skill %d: %w", i, err)
		}
		r.Skills = append(r.Skills, *snap)
	}
	return r, nil
}

// SkillListHandler returns a gateway.Handler implementing OpSkillList:
// responds with every skill in skill.Catalog (sorted by ID for a
// deterministic order -- Go map iteration isn't stable), each annotated
// with whether characterName's account knows it and, if it's on cooldown,
// how many seconds remain.
func SkillListHandler(chars character.Store, store skill.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpSkillList {
			return nil
		}

		req, err := DecodeSkillListRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: "malformed request"}).Encode()})
		}

		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: errStr}).Encode()})
		}

		ids := make([]int64, 0, len(skill.Catalog))
		for id := range skill.Catalog {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })

		now := time.Now()
		snapshots := make([]SkillSnapshot, 0, len(ids))
		for _, id := range ids {
			sk := skill.Catalog[id]
			known, err := store.Knows(ctx, characterID, id)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: "lookup failed"}).Encode()})
			}
			var readySeconds int32
			if known {
				lastUsed, everUsed, err := store.LastUsed(ctx, characterID, id)
				if err != nil {
					return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: "lookup failed"}).Encode()})
				}
				if everUsed {
					readyAt := lastUsed.Add(time.Duration(sk.CooldownSeconds) * time.Second)
					if remaining := readyAt.Sub(now); remaining > 0 {
						readySeconds = int32(remaining.Seconds()) + 1
					}
				}
			}
			snapshots = append(snapshots, SkillSnapshot{
				ID: sk.ID, Name: sk.Name, DamageBonus: int32(sk.DamageBonus), CooldownSeconds: int32(sk.CooldownSeconds),
				Known: known, ReadySeconds: readySeconds,
			})
		}
		return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Skills: snapshots}).Encode()})
	}
}
