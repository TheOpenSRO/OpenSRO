package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
)

// Quest opcodes, our own protocol. All require a prior OpLogin.
const (
	OpQuestList         uint16 = 0x00B0 // client -> server
	OpQuestListResult   uint16 = 0x00B1 // server -> client
	OpQuestAccept       uint16 = 0x00B2 // client -> server
	OpQuestAcceptResult uint16 = 0x00B3 // server -> client
	OpQuestCompleted    uint16 = 0x00B4 // server -> client, direct to the character who just completed one
)

// QuestCatalogEntry is one Catalog entry, as sent over the wire.
type QuestCatalogEntry struct {
	QuestID     int64
	Name        string
	MonsterName string
	TargetKills int32
	GoldReward  int64
	Kills       int32 // this character's current progress; 0 if not accepted
	Accepted    bool
	Completed   bool
}

func (e *QuestCatalogEntry) Encode() []byte {
	out := encodeInt64(e.QuestID)
	out = append(out, encodeStrings(e.Name, e.MonsterName)...)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(e.TargetKills))
	out = append(out, buf...)
	out = append(out, encodeInt64(e.GoldReward)...)
	binary.LittleEndian.PutUint32(buf, uint32(e.Kills))
	out = append(out, buf...)
	flags := byte(0)
	if e.Accepted {
		flags |= 1
	}
	if e.Completed {
		flags |= 2
	}
	return append(out, flags)
}

func decodeQuestCatalogEntry(data []byte) (*QuestCatalogEntry, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("quest id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 2)
	if err != nil {
		return nil, nil, fmt.Errorf("names: %w", err)
	}
	if len(rest) < 4 {
		return nil, nil, errors.New("truncated target kills")
	}
	target := int32(binary.LittleEndian.Uint32(rest))
	rest = rest[4:]

	goldReward, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("gold reward: %w", err)
	}

	if len(rest) < 4 {
		return nil, nil, errors.New("truncated kills")
	}
	kills := int32(binary.LittleEndian.Uint32(rest))
	rest = rest[4:]

	if len(rest) < 1 {
		return nil, nil, errors.New("truncated flags")
	}
	flags := rest[0]

	return &QuestCatalogEntry{
		QuestID: id, Name: names[0], MonsterName: names[1],
		TargetKills: target, GoldReward: goldReward, Kills: kills,
		Accepted: flags&1 != 0, Completed: flags&2 != 0,
	}, rest[1:], nil
}

// QuestListResult is the OpQuestListResult payload.
type QuestListResult struct {
	Error   string
	Entries []QuestCatalogEntry
}

func (r *QuestListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Entries)))
	out = append(out, countBuf...)
	for _, e := range r.Entries {
		out = append(out, e.Encode()...)
	}
	return out
}

func DecodeQuestListResult(data []byte) (*QuestListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding QuestListResult: %w", err)
	}
	r := &QuestListResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	if len(rest) < 2 {
		return nil, errors.New("session: decoding QuestListResult: truncated entry count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var entry *QuestCatalogEntry
		entry, rest, err = decodeQuestCatalogEntry(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding QuestListResult: entry %d: %w", i, err)
		}
		r.Entries = append(r.Entries, *entry)
	}
	return r, nil
}

// QuestAcceptRequest is the OpQuestAccept payload.
type QuestAcceptRequest struct {
	CharacterName string
	QuestID       int64
}

func (r *QuestAcceptRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.QuestID)...)
}

func DecodeQuestAcceptRequest(data []byte) (*QuestAcceptRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding QuestAcceptRequest: %w", err)
	}
	questID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding QuestAcceptRequest: quest id: %w", err)
	}
	return &QuestAcceptRequest{CharacterName: fields[0], QuestID: questID}, nil
}

// QuestAcceptResult is the OpQuestAcceptResult payload.
type QuestAcceptResult struct {
	OK     bool
	Reason string
}

func (r *QuestAcceptResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeQuestAcceptResult(data []byte) (*QuestAcceptResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding QuestAcceptResult: %w", err)
	}
	return &QuestAcceptResult{OK: ok, Reason: reason}, nil
}

// QuestCompleted is the OpQuestCompleted payload.
type QuestCompleted struct {
	QuestID    int64
	GoldReward int64
}

func (r *QuestCompleted) Encode() []byte {
	return append(encodeInt64(r.QuestID), encodeInt64(r.GoldReward)...)
}

func DecodeQuestCompleted(data []byte) (*QuestCompleted, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding QuestCompleted: %w", err)
	}
	gold, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding QuestCompleted: gold reward: %w", err)
	}
	return &QuestCompleted{QuestID: id, GoldReward: gold}, nil
}

// QuestHandler returns a gateway.Handler implementing OpQuestList and
// OpQuestAccept against quests.
func QuestHandler(chars character.Store, quests quest.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpQuestList:
			return handleQuestList(ctx, sess, p, chars, quests)
		case OpQuestAccept:
			return handleQuestAccept(ctx, sess, p, chars, quests)
		default:
			return nil
		}
	}
}

func handleQuestList(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, quests quest.Store) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpQuestListResult, Data: (&QuestListResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpQuestListResult, Data: (&QuestListResult{Error: errStr}).Encode()})
	}

	progress, err := quests.ListProgress(ctx, characterID)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpQuestListResult, Data: (&QuestListResult{Error: "failed to load quest progress"}).Encode()})
	}
	byQuestID := make(map[int64]quest.Progress, len(progress))
	for _, pr := range progress {
		byQuestID[pr.QuestID] = pr
	}

	entries := make([]QuestCatalogEntry, 0, len(quest.Catalog))
	for _, q := range quest.Catalog {
		entry := QuestCatalogEntry{
			QuestID: q.ID, Name: q.Name, MonsterName: q.MonsterName,
			TargetKills: int32(q.TargetKills), GoldReward: q.GoldReward,
		}
		if pr, ok := byQuestID[q.ID]; ok {
			entry.Accepted = true
			entry.Kills = int32(pr.Kills)
			entry.Completed = pr.Completed
		}
		entries = append(entries, entry)
	}

	return sess.Send(&proto.Packet{Opcode: OpQuestListResult, Data: (&QuestListResult{Entries: entries}).Encode()})
}

func handleQuestAccept(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, quests quest.Store) error {
	req, err := DecodeQuestAcceptRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpQuestAcceptResult, Data: (&QuestAcceptResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpQuestAcceptResult, Data: (&QuestAcceptResult{Reason: errStr}).Encode()})
	}

	if err := quests.Accept(ctx, characterID, req.QuestID); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpQuestAcceptResult, Data: (&QuestAcceptResult{Reason: questErrorMessage(err)}).Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpQuestAcceptResult, Data: (&QuestAcceptResult{OK: true}).Encode()})
}

func questErrorMessage(err error) string {
	switch {
	case errors.Is(err, quest.ErrUnknownQuest):
		return "no such quest"
	case errors.Is(err, quest.ErrAlreadyAccepted):
		return "already accepted"
	default:
		return "operation failed"
	}
}
