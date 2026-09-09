package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Character opcodes, our own protocol. All require a prior successful
// OpLogin on the same connection (see authstate.go) — attempts without one
// get a not-authenticated error rather than being silently ignored.
const (
	OpCharacterList         uint16 = 0x0010 // client -> server
	OpCharacterListResult   uint16 = 0x0011 // server -> client
	OpCharacterCreate       uint16 = 0x0012 // client -> server
	OpCharacterCreateResult uint16 = 0x0013 // server -> client
	OpCharacterDelete       uint16 = 0x0014 // client -> server
	OpCharacterDeleteResult uint16 = 0x0015 // server -> client
)

const errNotAuthenticated = "not authenticated"

// CharacterListResult is the OpCharacterListResult payload.
type CharacterListResult struct {
	Error string // non-empty on failure; Names is empty in that case
	Names []string
}

func (r *CharacterListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Names)))
	out = append(out, countBuf...)
	out = append(out, encodeStrings(r.Names...)...)
	return out
}

func DecodeCharacterListResult(data []byte) (*CharacterListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CharacterListResult: %w", err)
	}
	if len(rest) < 2 {
		return nil, errors.New("session: decoding CharacterListResult: truncated name count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	names, err := decodeStrings(rest[2:], count)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CharacterListResult: %w", err)
	}
	return &CharacterListResult{Error: fields[0], Names: names}, nil
}

// CharacterCreateRequest is the OpCharacterCreate payload. Gender is one of
// character.GenderChinaMan/GenderChinaWoman -- the real, RE-confirmed
// options (see character.go's doc comment) -- or empty, which falls back
// to character.DefaultGender. An unrecognized non-empty value also falls
// back to the default rather than erroring the whole create, since it's
// purely cosmetic and shouldn't block character creation.
type CharacterCreateRequest struct {
	Name   string
	Gender string
}

func (r *CharacterCreateRequest) Encode() []byte {
	out := encodeStrings(r.Name)
	out = append(out, encodeStrings(r.Gender)...)
	return out
}

func DecodeCharacterCreateRequest(data []byte) (*CharacterCreateRequest, error) {
	fields, err := decodeStrings(data, 2)
	if err != nil {
		return nil, err
	}
	return &CharacterCreateRequest{Name: fields[0], Gender: fields[1]}, nil
}

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
// nothing.
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

// CharacterDeleteRequest is the OpCharacterDelete payload.
type CharacterDeleteRequest struct {
	Name string
}

func (r *CharacterDeleteRequest) Encode() []byte { return encodeStrings(r.Name) }

func DecodeCharacterDeleteRequest(data []byte) (*CharacterDeleteRequest, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, err
	}
	return &CharacterDeleteRequest{Name: fields[0]}, nil
}

// CharacterCreateResult is the OpCharacterCreateResult payload — the common
// OK/Reason shape (see wire.go), given its own name here rather than reused
// from an unrelated opcode.
type CharacterCreateResult struct {
	OK     bool
	Reason string
}

func (r *CharacterCreateResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeCharacterCreateResult(data []byte) (*CharacterCreateResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CharacterCreateResult: %w", err)
	}
	return &CharacterCreateResult{OK: ok, Reason: reason}, nil
}

// CharacterDeleteResult is the OpCharacterDeleteResult payload.
type CharacterDeleteResult struct {
	OK     bool
	Reason string
}

func (r *CharacterDeleteResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeCharacterDeleteResult(data []byte) (*CharacterDeleteResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CharacterDeleteResult: %w", err)
	}
	return &CharacterDeleteResult{OK: ok, Reason: reason}, nil
}

// OnCharacterCreated is called after a character is successfully created,
// for whatever a new character needs beyond its row -- currently its
// starting equipment. Optional: a nil hook means "just create the
// character", which is what the tests and any caller that has not wired
// inventory/equipment yet want.
//
// Errors are logged by the caller and do not fail the creation: a character
// that could not be given its kit is still a usable character.
type OnCharacterCreated func(ctx context.Context, characterID int64) error

// CharacterHandler returns a gateway.Handler implementing character
// list/create/delete against store, scoped to whichever account
// authenticated on the connection (see AuthenticatedAccountID).
func CharacterHandler(store character.Store) gateway.Handler {
	return CharacterHandlerWithHook(store, nil)
}

// CharacterHandlerWithHook is CharacterHandler plus a hook run after a
// successful create.
func CharacterHandlerWithHook(store character.Store, created OnCharacterCreated) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpCharacterList:
			return handleList(ctx, sess, store)
		case OpCharacterCreate:
			return handleCreate(ctx, sess, p, store, created)
		case OpCharacterDelete:
			return handleDelete(ctx, sess, p, store)
		default:
			return nil
		}
	}
}

func handleList(ctx context.Context, sess *gateway.Session, store character.Store) error {
	accountID, ok := AuthenticatedAccountID(sess)
	if !ok {
		return sess.Send(&proto.Packet{
			Opcode: OpCharacterListResult,
			Data:   (&CharacterListResult{Error: errNotAuthenticated}).Encode(),
		})
	}

	chars, err := store.ListByAccount(ctx, accountID)
	if err != nil {
		return sess.Send(&proto.Packet{
			Opcode: OpCharacterListResult,
			Data:   (&CharacterListResult{Error: "list failed"}).Encode(),
		})
	}

	names := make([]string, len(chars))
	for i, c := range chars {
		names[i] = c.Name
	}
	return sess.Send(&proto.Packet{Opcode: OpCharacterListResult, Data: (&CharacterListResult{Names: names}).Encode()})
}

func handleCreate(ctx context.Context, sess *gateway.Session, p *proto.Packet, store character.Store, onCreated OnCharacterCreated) error {
	accountID, ok := AuthenticatedAccountID(sess)
	if !ok {
		return sess.Send(&proto.Packet{
			Opcode: OpCharacterCreateResult,
			Data:   (&CharacterCreateResult{OK: false, Reason: errNotAuthenticated}).Encode(),
		})
	}

	req, err := DecodeCharacterCreateRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{
			Opcode: OpCharacterCreateResult,
			Data:   (&CharacterCreateResult{OK: false, Reason: "malformed request"}).Encode(),
		})
	}

	result := &CharacterCreateResult{OK: true}
	created, err := store.Create(ctx, accountID, req.Name)
	if err != nil {
		result.OK = false
		switch {
		case errors.Is(err, character.ErrNameTaken):
			result.Reason = "name already taken"
		case errors.Is(err, character.ErrAccountFull):
			result.Reason = "account already has the maximum number of characters"
		default:
			result.Reason = "create failed"
		}
		return sess.Send(&proto.Packet{Opcode: OpCharacterCreateResult, Data: result.Encode()})
	}

	// Gender is purely cosmetic (see CharacterCreateRequest's doc comment),
	// so an invalid/unrecognized choice just keeps the real default
	// store.Create already applied rather than failing character creation
	// over it.
	if character.ValidGender(req.Gender) && req.Gender != created.Gender {
		if err := store.SetGender(ctx, created.ID, req.Gender); err != nil {
			result.OK = false
			result.Reason = "create failed"
		}
	}

	// Starting equipment and anything else a new character needs. Failing
	// this does not fail the creation -- a character without its kit is
	// still a usable character, and reporting "create failed" for one would
	// be worse than being underdressed.
	if onCreated != nil {
		if err := onCreated(ctx, created.ID); err != nil {
			slog.Warn("character created without its starting kit", "character_id", created.ID, "err", err)
		}
	}
	return sess.Send(&proto.Packet{Opcode: OpCharacterCreateResult, Data: result.Encode()})
}

func handleDelete(ctx context.Context, sess *gateway.Session, p *proto.Packet, store character.Store) error {
	accountID, ok := AuthenticatedAccountID(sess)
	if !ok {
		return sess.Send(&proto.Packet{
			Opcode: OpCharacterDeleteResult,
			Data:   (&CharacterDeleteResult{OK: false, Reason: errNotAuthenticated}).Encode(),
		})
	}

	req, err := DecodeCharacterDeleteRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{
			Opcode: OpCharacterDeleteResult,
			Data:   (&CharacterDeleteResult{OK: false, Reason: "malformed request"}).Encode(),
		})
	}

	// Our own protocol identifies characters by name over the wire (simpler
	// for a hand-rolled client to work with); look the ID up server-side.
	chars, err := store.ListByAccount(ctx, accountID)
	var id int64 = -1
	if err == nil {
		for _, c := range chars {
			if c.Name == req.Name {
				id = c.ID
				break
			}
		}
	}

	result := &CharacterDeleteResult{OK: true}
	if id == -1 {
		result.OK = false
		result.Reason = "no such character"
	} else if err := store.Delete(ctx, accountID, id); err != nil {
		result.OK = false
		result.Reason = "delete failed"
	}
	return sess.Send(&proto.Packet{Opcode: OpCharacterDeleteResult, Data: result.Encode()})
}
