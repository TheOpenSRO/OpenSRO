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
)

// The character-stats exchange: the client asks what its own character is
// worth, and gets back the numbers the server itself fights with.
const (
	OpCharacterStats       uint16 = 0x00EE // client -> server
	OpCharacterStatsResult uint16 = 0x00EF // server -> client
)

// CharacterStatsResult is what the character panel and the inventory's
// gold readout are filled from.
//
// **Only what the server really has.** The panel that shows these
// (`resinfo\ifplayerinfo.txt`) has rows for strength, intelligence, magical
// attack and defence, balance, hit rate, parry and three job grades, and
// nothing on this server computes any of them -- so they are not in here
// and the client leaves them as the layout drew them, rather than filling
// them with numbers that look live.
//
// PhysAttack and PhysDefense are not new arithmetic either: they are the
// same values combat already resolves from equipment when this character
// swings at something and when something swings back.
type CharacterStatsResult struct {
	Error string

	Gold  int64
	HP    int32
	MaxHP int32

	// PhysAttack is the equipped weapon's PhysAttackMax, or the unarmed
	// damage when nothing is equipped. PhysDefense sums PhysDefenseMax
	// across the worn armour.
	PhysAttack  int32
	PhysDefense int32
}

func (r *CharacterStatsResult) Encode() []byte {
	out := encodeStrings(r.Error)
	buf := make([]byte, 24)
	binary.LittleEndian.PutUint64(buf[0:8], uint64(r.Gold))
	binary.LittleEndian.PutUint32(buf[8:12], uint32(r.HP))
	binary.LittleEndian.PutUint32(buf[12:16], uint32(r.MaxHP))
	binary.LittleEndian.PutUint32(buf[16:20], uint32(r.PhysAttack))
	binary.LittleEndian.PutUint32(buf[20:24], uint32(r.PhysDefense))
	return append(out, buf...)
}

func DecodeCharacterStatsResult(data []byte) (*CharacterStatsResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CharacterStatsResult: %w", err)
	}
	if len(rest) < 24 {
		return nil, errors.New("session: decoding CharacterStatsResult: truncated")
	}
	return &CharacterStatsResult{
		Error:       fields[0],
		Gold:        int64(binary.LittleEndian.Uint64(rest[0:8])),
		HP:          int32(binary.LittleEndian.Uint32(rest[8:12])),
		MaxHP:       int32(binary.LittleEndian.Uint32(rest[12:16])),
		PhysAttack:  int32(binary.LittleEndian.Uint32(rest[16:20])),
		PhysDefense: int32(binary.LittleEndian.Uint32(rest[20:24])),
	}, nil
}

// CharacterStatsHandler answers OpCharacterStats.
func CharacterStatsHandler(chars character.Store, eq equipment.Store, items combat.ItemLookup) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpCharacterStats {
			return nil
		}
		req, err := DecodeCharacterNameRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpCharacterStatsResult,
				Data:   (&CharacterStatsResult{Error: "malformed request"}).Encode(),
			})
		}
		characterID, reason := resolveCharacterID(ctx, sess, chars, req.Name)
		if characterID < 0 {
			return sess.Send(&proto.Packet{
				Opcode: OpCharacterStatsResult,
				Data:   (&CharacterStatsResult{Error: reason}).Encode(),
			})
		}
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpCharacterStatsResult,
				Data:   (&CharacterStatsResult{Error: "lookup failed"}).Encode(),
			})
		}

		result := &CharacterStatsResult{
			Gold:  owned.Gold,
			HP:    int32(owned.HP),
			MaxHP: int32(character.MaxHP),
		}
		if eq != nil && items != nil {
			attack, err := attackerDamage(ctx, characterID, eq, items)
			if err != nil {
				return sess.Send(&proto.Packet{
					Opcode: OpCharacterStatsResult,
					Data:   (&CharacterStatsResult{Error: "reading equipment"}).Encode(),
				})
			}
			armor, err := defenderArmor(ctx, characterID, eq, items)
			if err != nil {
				return sess.Send(&proto.Packet{
					Opcode: OpCharacterStatsResult,
					Data:   (&CharacterStatsResult{Error: "reading equipment"}).Encode(),
				})
			}
			result.PhysAttack = int32(attack)
			result.PhysDefense = int32(armor)
		}
		return sess.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
	}
}
