package session

// The character lobby -- list, create, delete, the name check, restore and
// Start -- is retail's 0x7007/0xB007 and 0x7001/0xB001 since round 682
// (lobby.go, lobbyhandler.go; docs/protocol/charselect.md). Our own
// 0x0010-0x0015 (OpCharacterList/Create/Delete and their results) were
// removed with their last caller, the client's CharacterSelect/CharacterCreate
// screens and QaSignIn, which speak the retail lobby now.

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
