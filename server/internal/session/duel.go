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
			return handleDuelAttack(ctx, sess, p, chars, eq, items, hub, duels)
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

func handleDuelAttack(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, eq equipment.Store, items combat.ItemLookup, hub *world.Hub, duels *duel.Hub) error {
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
	// Neither side of a duel blow may be dead (round 549, deadstate.go). OWN
	// DESIGN, disclosed: the retail duel messages were not read for a
	// life-state test. The opponent's side matters as much as the attacker's:
	// a blow on a character a monster has already killed would find HP 0,
	// report a second death and, below, ResetHP a character whose life state
	// is still 2. A duel's own death path is unchanged (ResetHP, alive): the
	// flag covers a monster's kill only, as the plan scoped it.
	if deadBySession(hub, sess) {
		return sess.Send(&proto.Packet{Opcode: OpDuelAttackResult, Data: (&DuelAttackResult{Error: deadRefusal}).Encode()})
	}
	if deadCharacter(hub, opponent.CharacterID) {
		return sess.Send(&proto.Packet{Opcode: OpDuelAttackResult, Data: (&DuelAttackResult{Error: "your opponent is dead"}).Encode()})
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
	// BOTH parties are players here, so neither divisor is covered by the
	// monster measurement the PvE path cites -- see combat.EvadedChance.
	blow := resolveBlow(
		base, playerMitigationPercent, armor,
		combat.EvadedChance(attackerCritical(ctx, characterID, eq, items), playerEvasion),
		combat.EvadedChance(defenderBlock(ctx, opponent.CharacterID, eq, items), playerEvasion),
		atkLevel, defLevel, characterID, opponent.CharacterID)
	damage := blow.Damage

	// The store's died flag is not read (round 551): the duel's kill is
	// decided as a monster's is, under the opponent's kill lock (killLock,
	// monsterstrike.go), because the flag cannot tell an opponent alive at 0
	// -- an HP-cost cast lands its caster there, the engine's own gate passing
	// on equal (combat.CanPaySkillHealth) -- from one a monster is killing
	// this instant. Round 550 read the flag, and a duel against an opponent
	// alive at 0 could never end.
	hp, _, err := chars.ApplyDamage(ctx, opponent.CharacterID, damage)
	if err != nil {
		return fmt.Errorf("duel: applying damage: %w", err)
	}
	// A blow that lands stands a sitting opponent up (round 607, motion.go).
	standOnHit(hub, opponent.CharacterID, damage)
	opponentDied := false
	if hp == 0 && damage > 0 {
		// The blow's damage left the opponent at 0. Under her kill lock: alive
		// and still at 0, this blow is the duel's kill, and the loser's HP is
		// reset there (a monster's blow racing this one then finds her above
		// 0 and lands as usual); in the dead state, a monster's kill got
		// there first and the blow is answered as the dead gate above would
		// have answered it; above 0 again, a monster's kill and respawn got
		// there first and the blow landed nothing -- reported at the HP she
		// has. A blocked or zero blow kills nobody, at any pool.
		l := killLock(opponent.CharacterID)
		l.Lock()
		c, ferr := fallen(ctx, chars, hub, opponent.CharacterID)
		if ferr != nil {
			l.Unlock()
			return fmt.Errorf("duel: reading the fallen opponent: %w", ferr)
		}
		switch {
		case c != nil:
			opponentDied = true
			if err := chars.ResetHP(ctx, opponent.CharacterID); err != nil {
				l.Unlock()
				return fmt.Errorf("duel: resetting loser's hp: %w", err)
			}
		case deadCharacter(hub, opponent.CharacterID):
			l.Unlock()
			return sess.Send(&proto.Packet{Opcode: OpDuelAttackResult, Data: (&DuelAttackResult{Error: "your opponent is dead"}).Encode()})
		default:
			if cur, e := chars.GetByID(ctx, opponent.CharacterID); e == nil && cur != nil {
				hp = cur.HP
			}
		}
		l.Unlock()
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

	// Duel over: the loser's HP was reset under her kill lock above; clear
	// both sides from the active duel set.
	//
	// Losing a duel costs NO experience here. That is own design, and it is a
	// deliberate divergence rather than a match: the engine does charge for a
	// player kill -- GObjPC_OnDeath picks its multiplier on the killer's
	// vtable-0x1c predicate, the same one that gates the exp grant, so a
	// PC killer takes the 20x branch (leveldata.DeathPenaltyKilledByPlayer)
	// against a monster's 100x.
	//
	// SHARPENED 2026-09-21. That sentence is too simple, and the correction
	// makes the case for charging here WEAKER, not stronger.
	// GObjPC::IsKilledByPlayer (0x004eb390) does not merely test that both
	// parties are PCs: its body also requires the victim's +0x1cbc AND the
	// killer's [0x72f] to be non-null before a second slot-7 test, and
	// [0x72e]/[0x72f] are PARTY and GUILD. So cause 5 -- the 20x branch -- is
	// a GUILD-CONTEXT kill, and two unguilded duellists would not reach it at
	// all. Which leaves a duel landing on cause 3 (the 100x/300x monster-grade
	// pair) or on one of the kinds that go elsewhere, and nothing read so far
	// distinguishes those two. Charging anything here remains a guess. What is NOT established is whether a duel
	// death reaches that code at all: GObjPC_OnDeath is dispatched only for
	// death kinds 3, 4 and 5 (the byte at pc+0x1cb4, written by FUN_004e6ec0),
	// and kinds 1, 2 and 6 go elsewhere entirely. Until which kind a duel is
	// has been read, charging 20x here would be a guess dressed as recovery.
	//
	// The comment this replaces claimed "same as PvE", which stopped being
	// true when PvE started applying the real 100x penalty.
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
