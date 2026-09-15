package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/duel"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Duel opcodes, our own protocol. All require a prior successful
// OpEnterWorld (target resolution reuses world.Hub.FindByName, the same as
// chat's whisper). PvP damage is mitigated by the defender's real equipped
// armor (equipment.ArmorSlots), the same as PvE -- see defenderArmor in
// combat.go.
const (
	OpDuelChallenge       uint16 = 0x00C0 // client -> server
	OpDuelChallengeResult uint16 = 0x00C1 // server -> client, ack to the challenger
	OpDuelInvite          uint16 = 0x00C2 // server -> client, direct to the target
	OpDuelRespond         uint16 = 0x00C3 // client -> server
	OpDuelRespondResult   uint16 = 0x00C4 // server -> client, ack to the responder
	OpDuelStarted         uint16 = 0x00C5 // server -> client, direct to both sides
	OpDuelDeclined        uint16 = 0x00C6 // server -> client, direct to the challenger
	OpDuelAttack          uint16 = 0x00C7 // client -> server
	OpDuelAttackResult    uint16 = 0x00C8 // server -> client, direct to the attacker
	OpDuelOpponentDamaged uint16 = 0x00C9 // server -> client, direct to the defender
	OpDuelEnded           uint16 = 0x00CA // server -> client, direct to both sides
)

// DuelChallengeRequest is the OpDuelChallenge payload.
type DuelChallengeRequest struct {
	CharacterName string
	TargetName    string
}

func (r *DuelChallengeRequest) Encode() []byte {
	return encodeStrings(r.CharacterName, r.TargetName)
}

func DecodeDuelChallengeRequest(data []byte) (*DuelChallengeRequest, error) {
	fields, err := decodeStrings(data, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelChallengeRequest: %w", err)
	}
	return &DuelChallengeRequest{CharacterName: fields[0], TargetName: fields[1]}, nil
}

// DuelChallengeResult is the OpDuelChallengeResult payload.
type DuelChallengeResult struct {
	OK     bool
	Reason string
}

func (r *DuelChallengeResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeDuelChallengeResult(data []byte) (*DuelChallengeResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelChallengeResult: %w", err)
	}
	return &DuelChallengeResult{OK: ok, Reason: reason}, nil
}

// DuelInvite is the OpDuelInvite payload.
type DuelInvite struct {
	ChallengerName string
}

func (r *DuelInvite) Encode() []byte { return encodeStrings(r.ChallengerName) }

func DecodeDuelInvite(data []byte) (*DuelInvite, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelInvite: %w", err)
	}
	return &DuelInvite{ChallengerName: fields[0]}, nil
}

// DuelRespondRequest is the OpDuelRespond payload.
type DuelRespondRequest struct {
	CharacterName  string
	ChallengerName string
	Accept         bool
}

func (r *DuelRespondRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName, r.ChallengerName)
	if r.Accept {
		return append(out, 1)
	}
	return append(out, 0)
}

func DecodeDuelRespondRequest(data []byte) (*DuelRespondRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelRespondRequest: %w", err)
	}
	if len(rest) < 1 {
		return nil, errors.New("session: decoding DuelRespondRequest: truncated accept flag")
	}
	return &DuelRespondRequest{CharacterName: fields[0], ChallengerName: fields[1], Accept: rest[0] != 0}, nil
}

// DuelRespondResult is the OpDuelRespondResult payload.
type DuelRespondResult struct {
	OK     bool
	Reason string
}

func (r *DuelRespondResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeDuelRespondResult(data []byte) (*DuelRespondResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelRespondResult: %w", err)
	}
	return &DuelRespondResult{OK: ok, Reason: reason}, nil
}

// DuelStarted is the OpDuelStarted payload.
type DuelStarted struct {
	OpponentName string
}

func (r *DuelStarted) Encode() []byte { return encodeStrings(r.OpponentName) }

func DecodeDuelStarted(data []byte) (*DuelStarted, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelStarted: %w", err)
	}
	return &DuelStarted{OpponentName: fields[0]}, nil
}

// DuelDeclined is the OpDuelDeclined payload.
type DuelDeclined struct {
	TargetName string
}

func (r *DuelDeclined) Encode() []byte { return encodeStrings(r.TargetName) }

func DecodeDuelDeclined(data []byte) (*DuelDeclined, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelDeclined: %w", err)
	}
	return &DuelDeclined{TargetName: fields[0]}, nil
}

// DuelAttackRequest is the OpDuelAttack payload: just the attacker's own
// character name (the opponent is whoever duel.Hub says they're dueling).
type DuelAttackRequest struct {
	CharacterName string
}

func (r *DuelAttackRequest) Encode() []byte { return encodeStrings(r.CharacterName) }

func DecodeDuelAttackRequest(data []byte) (*DuelAttackRequest, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelAttackRequest: %w", err)
	}
	return &DuelAttackRequest{CharacterName: fields[0]}, nil
}

// DuelAttackResult is the OpDuelAttackResult payload (direct reply to the
// attacker). On failure, only Error is meaningful.
type DuelAttackResult struct {
	Error string

	Damage       int32
	OpponentHP   int32
	OpponentDied bool

	// Critical and Blocked are the same two outcomes a PvE blow reports, and
	// they reach a duel by the same route now -- both sides are players, so a
	// weapon's Critical column and a shield's block ratio both apply.
	// Appended, so an older client still decodes the rest.
	Critical bool
	Blocked  bool
}

func (r *DuelAttackResult) Encode() []byte {
	out := encodeStrings(r.Error)
	buf := make([]byte, 11)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Damage))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.OpponentHP))
	if r.OpponentDied {
		buf[8] = 1
	}
	if r.Critical {
		buf[9] = 1
	}
	if r.Blocked {
		buf[10] = 1
	}
	return append(out, buf...)
}

func DecodeDuelAttackResult(data []byte) (*DuelAttackResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelAttackResult: %w", err)
	}
	if len(rest) < 9 {
		return nil, errors.New("session: decoding DuelAttackResult: truncated")
	}
	out := &DuelAttackResult{
		Error:        fields[0],
		Damage:       int32(binary.LittleEndian.Uint32(rest[0:4])),
		OpponentHP:   int32(binary.LittleEndian.Uint32(rest[4:8])),
		OpponentDied: rest[8] != 0,
	}
	// Appended, so a 9-byte result from an older server still decodes.
	if len(rest) >= 11 {
		out.Critical = rest[9] != 0
		out.Blocked = rest[10] != 0
	}
	return out, nil
}

// DuelOpponentDamaged is the OpDuelOpponentDamaged payload (direct to the
// defender).
type DuelOpponentDamaged struct {
	Damage      int32
	RemainingHP int32
}

func (r *DuelOpponentDamaged) Encode() []byte {
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Damage))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.RemainingHP))
	return buf
}

func DecodeDuelOpponentDamaged(data []byte) (*DuelOpponentDamaged, error) {
	if len(data) < 8 {
		return nil, errors.New("session: decoding DuelOpponentDamaged: truncated")
	}
	return &DuelOpponentDamaged{
		Damage:      int32(binary.LittleEndian.Uint32(data[0:4])),
		RemainingHP: int32(binary.LittleEndian.Uint32(data[4:8])),
	}, nil
}

// DuelEnded is the OpDuelEnded payload (direct to both sides).
type DuelEnded struct {
	WinnerName string
}

func (r *DuelEnded) Encode() []byte { return encodeStrings(r.WinnerName) }

func DecodeDuelEnded(data []byte) (*DuelEnded, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding DuelEnded: %w", err)
	}
	return &DuelEnded{WinnerName: fields[0]}, nil
}

// DuelHandler returns a gateway.Handler implementing
// OpDuelChallenge/OpDuelRespond/OpDuelAttack.
func DuelHandler(chars character.Store, eq equipment.Store, items combat.ItemLookup, hub *world.Hub, duels *duel.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpDuelChallenge:
			return handleDuelChallenge(ctx, sess, p, chars, hub, duels)
		case OpDuelRespond:
			return handleDuelRespond(ctx, sess, p, chars, hub, duels)
		case OpDuelAttack:
			return handleDuelAttack(ctx, sess, p, chars, eq, items, duels)
		default:
			return nil
		}
	}
}

func handleDuelChallenge(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, hub *world.Hub, duels *duel.Hub) error {
	req, err := DecodeDuelChallengeRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpDuelChallengeResult, Data: (&DuelChallengeResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpDuelChallengeResult, Data: (&DuelChallengeResult{Reason: errStr}).Encode()})
	}
	targetEntity, ok := hub.FindByName(req.TargetName)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpDuelChallengeResult, Data: (&DuelChallengeResult{Reason: "player not found"}).Encode()})
	}

	challenger := duel.Member{Session: sess, CharacterID: characterID, Name: req.CharacterName}
	target := duel.Member{Session: targetEntity.Session, CharacterID: targetEntity.CharacterID, Name: targetEntity.Name}
	if err := duels.Challenge(challenger, target); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpDuelChallengeResult, Data: (&DuelChallengeResult{Reason: duelErrorMessage(err)}).Encode()})
	}

	if err := sess.Send(&proto.Packet{Opcode: OpDuelChallengeResult, Data: (&DuelChallengeResult{OK: true}).Encode()}); err != nil {
		return err
	}
	invite := &DuelInvite{ChallengerName: req.CharacterName}
	return target.Session.Send(&proto.Packet{Opcode: OpDuelInvite, Data: invite.Encode()})
}

func handleDuelRespond(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, hub *world.Hub, duels *duel.Hub) error {
	req, err := DecodeDuelRespondRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpDuelRespondResult, Data: (&DuelRespondResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpDuelRespondResult, Data: (&DuelRespondResult{Reason: errStr}).Encode()})
	}

	responder := duel.Member{Session: sess, CharacterID: characterID, Name: req.CharacterName}
	challenger, err := duels.Respond(responder, req.Accept)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpDuelRespondResult, Data: (&DuelRespondResult{Reason: duelErrorMessage(err)}).Encode()})
	}

	if err := sess.Send(&proto.Packet{Opcode: OpDuelRespondResult, Data: (&DuelRespondResult{OK: true}).Encode()}); err != nil {
		return err
	}

	if !req.Accept {
		declined := &DuelDeclined{TargetName: req.CharacterName}
		return challenger.Session.Send(&proto.Packet{Opcode: OpDuelDeclined, Data: declined.Encode()})
	}

	if err := sess.Send(&proto.Packet{Opcode: OpDuelStarted, Data: (&DuelStarted{OpponentName: challenger.Name}).Encode()}); err != nil {
		return err
	}
	return challenger.Session.Send(&proto.Packet{Opcode: OpDuelStarted, Data: (&DuelStarted{OpponentName: req.CharacterName}).Encode()})
}

func handleDuelAttack(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, eq equipment.Store, items combat.ItemLookup, duels *duel.Hub) error {
	req, err := DecodeDuelAttackRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpDuelAttackResult, Data: (&DuelAttackResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpDuelAttackResult, Data: (&DuelAttackResult{Error: errStr}).Encode()})
	}

	opponent, ok := duels.OpponentOf(characterID)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpDuelAttackResult, Data: (&DuelAttackResult{Error: "not in a duel"}).Encode()})
	}

	// The attacker's Strength contributes to both ends of its damage range;
	// a store that cannot answer drops the term rather than the attack.
	attackerStr := 0
	if c, err := chars.GetByID(ctx, characterID); err == nil && c != nil {
		attackerStr = c.Str
	}
	base, err := attackerDamage(ctx, characterID, attackerStr, eq, items)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpDuelAttackResult, Data: (&DuelAttackResult{Error: "damage calculation failed"}).Encode()})
	}
	armor, err := defenderArmor(ctx, opponent.CharacterID, eq, items)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpDuelAttackResult, Data: (&DuelAttackResult{Error: "damage calculation failed"}).Encode()})
	}
	// PvP goes through the SAME pipeline as PvE, which it had not been doing:
	// this was `base - armor` while the monster path collected the mitigation
	// shape, criticals, blocking and the level term. Both sides are players,
	// so both a weapon's Critical column and a shield's block ratio apply, and
	// both have a real level.
	//
	// The player's own mitigation percentage is zero and that is recovered
	// rather than assumed -- see session.playerMitigationPercent.
	atkLevel, defLevel := 0, 0
	if c, err := chars.GetByID(ctx, characterID); err == nil && c != nil {
		atkLevel = c.Level
	}
	if c, err := chars.GetByID(ctx, opponent.CharacterID); err == nil && c != nil {
		defLevel = c.Level
	}
	blow := resolveBlow(
		base, playerMitigationPercent, armor,
		attackerCritical(ctx, characterID, eq, items),
		defenderBlock(ctx, opponent.CharacterID, eq, items),
		atkLevel, defLevel)
	damage := blow.Damage

	hp, opponentDied, err := chars.ApplyDamage(ctx, opponent.CharacterID, damage)
	if err != nil {
		return fmt.Errorf("duel: applying damage: %w", err)
	}

	result := &DuelAttackResult{Damage: int32(damage), OpponentHP: int32(hp), OpponentDied: opponentDied,
		Critical: blow.Critical, Blocked: blow.Blocked}
	if err := sess.Send(&proto.Packet{Opcode: OpDuelAttackResult, Data: result.Encode()}); err != nil {
		return err
	}

	if !opponentDied {
		damaged := &DuelOpponentDamaged{Damage: int32(damage), RemainingHP: int32(hp)}
		return opponent.Session.Send(&proto.Packet{Opcode: OpDuelOpponentDamaged, Data: damaged.Encode()})
	}

	// Duel over: reset the loser's HP (no harsh death penalty, same as PvE)
	// and clear both sides from the active duel set.
	if err := chars.ResetHP(ctx, opponent.CharacterID); err != nil {
		return fmt.Errorf("duel: resetting loser's hp: %w", err)
	}
	duels.End(characterID)

	if err := sess.Send(&proto.Packet{Opcode: OpDuelEnded, Data: (&DuelEnded{WinnerName: req.CharacterName}).Encode()}); err != nil {
		return err
	}
	return opponent.Session.Send(&proto.Packet{Opcode: OpDuelEnded, Data: (&DuelEnded{WinnerName: req.CharacterName}).Encode()})
}

// DuelDisconnectHandler returns a func suitable for gateway.Server's
// OnDisconnect hook: withdraws any pending challenge the disconnecting
// session was part of and, if they were mid-duel, ends it and notifies
// their opponent.
func DuelDisconnectHandler(hub *world.Hub, duels *duel.Hub) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		entity, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return
		}
		characterID := entity.CharacterID

		if challenger, notifiable := duels.CancelPendingFor(characterID); notifiable {
			declined := &DuelDeclined{TargetName: entity.Name}
			challenger.Session.Send(&proto.Packet{Opcode: OpDuelDeclined, Data: declined.Encode()})
		}

		if opponent, ok := duels.End(characterID); ok {
			ended := &DuelEnded{WinnerName: opponent.Name}
			opponent.Session.Send(&proto.Packet{Opcode: OpDuelEnded, Data: ended.Encode()})
		}
	}
}

func duelErrorMessage(err error) string {
	switch {
	case errors.Is(err, duel.ErrCannotChallengeSelf):
		return "cannot challenge yourself"
	case errors.Is(err, duel.ErrAlreadyDueling):
		return "already in a duel"
	case errors.Is(err, duel.ErrTargetBusy):
		return "target is busy"
	case errors.Is(err, duel.ErrNoPendingChallenge):
		return "no pending challenge"
	default:
		return "operation failed"
	}
}
