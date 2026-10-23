package session

// The character lobby -- list, create, delete, the name check, restore and
// Start -- is retail's 0x7007/0xB007 and 0x7001/0xB001 since round 682
// (lobby.go, lobbyhandler.go; docs/protocol/charselect.md). Our own
// 0x0010-0x0015 (OpCharacterList/Create/Delete and their results) were
// removed with their last caller, the client's CharacterSelect/CharacterCreate
// screens and QaSignIn, which speak the retail lobby now; an older client is
// answered by LegacyLobbyHandler below.

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

const errNotAuthenticated = "not authenticated"

// CharacterNameRequest is the payload of every request that identifies a
// character and asks for nothing else: the inventory, equipment, quest,
// skill, party, guild and friend listings all take exactly this.
//
// It exists because those ten handlers used to decode a
// CharacterCreateRequest instead, each with a comment saying "reuse: it's
// just {Name string}". That was true when it was written. Character
// creation later gained a Gender field, so the shared decoder began
// demanding *two* length-prefixed strings, and every one of those requests
// -- which the client sends with one -- started failing as "malformed
// request". The client showed it as an undressed character, an empty
// inventory and empty panels, with the server answering every listing with
// nothing. (The create request is the lobby's LobbyRequest now, a different
// shape again.)
type CharacterNameRequest struct {
	Name string
}

func (r *CharacterNameRequest) Encode() []byte { return encodeStrings(r.Name) }

func DecodeCharacterNameRequest(data []byte) (*CharacterNameRequest, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, err
	}
	return &CharacterNameRequest{Name: fields[0]}, nil
}

// The pre-682 lobby's opcodes, kept only to answer an older client (round
// 682's review). Our own protocol until round 682 (git show 3857a5e:
// server/internal/session/character.go): 0x0010 list -> 0x0011 (a u16-length
// error string, then a u16 count of characters), 0x0012 create -> 0x0013 and
// 0x0014 delete -> 0x0015 (wire.go's OK/Reason shape). That client shows the
// list's error as "Error: <text>" and a create or delete refusal as "Create
// failed: <text>" / "Delete failed: <text>" (its CharacterSelect.gd and
// CharacterCreate.gd), so each is answered in its own format with words that
// say what to do.
const (
	legacyOpCharacterList         uint16 = 0x0010
	legacyOpCharacterListResult   uint16 = 0x0011
	legacyOpCharacterCreate       uint16 = 0x0012
	legacyOpCharacterCreateResult uint16 = 0x0013
	legacyOpCharacterDelete       uint16 = 0x0014
	legacyOpCharacterDeleteResult uint16 = 0x0015
)

// LegacyLobbyNotice is what an older client is told (OURS wording).
const LegacyLobbyNotice = "this server uses the new character lobby -- update the client"

// LegacyLobbyHandler answers the removed 0x0010 / 0x0012 / 0x0014 in their
// old reply formats with LegacyLobbyNotice, and logs each at INFO, so an
// older client says why its select screen is empty instead of saying nothing.
func LegacyLobbyHandler(logger *slog.Logger) gateway.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return func(_ context.Context, sess *gateway.Session, p *proto.Packet) error {
		var reply *proto.Packet
		switch p.Opcode {
		case legacyOpCharacterList:
			reply = &proto.Packet{Opcode: legacyOpCharacterListResult, Data: append(encodeStrings(LegacyLobbyNotice), 0, 0)}
		case legacyOpCharacterCreate:
			reply = &proto.Packet{Opcode: legacyOpCharacterCreateResult, Data: encodeOKReason(false, LegacyLobbyNotice)}
		case legacyOpCharacterDelete:
			reply = &proto.Packet{Opcode: legacyOpCharacterDeleteResult, Data: encodeOKReason(false, LegacyLobbyNotice)}
		default:
			return nil
		}
		logger.Info("an older client asked the removed lobby; told to update", "opcode", fmt.Sprintf("%#04x", p.Opcode))
		return sess.Send(reply)
	}
}
