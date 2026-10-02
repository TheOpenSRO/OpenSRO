package session

// The character lobby on retail's wire (round 682): 0x7007/0xB007 (create,
// list, delete, name check, restore) and 0x7001/0xB001 (Start), with the
// payloads byte for byte the layouts docs/protocol/charselect.md section 5
// READ out of sro_client.exe and SR_ShardManager.exe. They ride our framing
// (proto.Packet) on retail's own opcode numbers -- the user's decision 1
// (2026-10-02) -- so they move unchanged into the retail codec when the
// framing does. The Godot twin is client/scripts/net/lobby.gd; the two are
// held to the same bytes by testdata/lobby_golden.json (TestLobbyGolden here,
// lobby_test.gd there).
//
// Names are a u16 length and narrow bytes (READ: the client writes narrow
// strings here). The relay's leading u32 that both ShardManager handlers read
// first is the AgentServer's (INFERRED) and never sent by the client, so it is
// not on this wire.

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// The lobby opcodes (READ: ShardManager registers 0x7001 -> 0x40e2c0 and
// 0x7007 -> 0x40f010, and builds 0xB007 and 0xB001).
const (
	OpLobby       uint16 = 0x7007 // client -> server
	OpLobbyResult uint16 = 0xB007 // server -> client
	OpStart       uint16 = 0x7001 // client -> server
	OpStartResult uint16 = 0xB001 // server -> client
)

// The 0x7007 actions (READ, the server's jump table 0x40f0f8; any other is
// ignored).
const (
	LobbyCreate    uint8 = 1
	LobbyList      uint8 = 2
	LobbyDelete    uint8 = 3
	LobbyNameCheck uint8 = 4
	LobbyRestore   uint8 = 5
)

// The result byte after the action (READ, client 0x84df10 / the select
// screen's vslot_006, server FUN_0040ef80): 1 OK, 2 an error code follows.
const (
	lobbyResultOK   uint8 = 1
	lobbyResultFail uint8 = 2
)

// The lobby's error codes (READ codes, charselect.md section 5's table; what
// this server raises each for is that table's "srrevamp" column). The client
// shows the text the table names.
const (
	LobbyOK                uint16 = 0x401
	LobbyErrRefused        uint16 = 0x402 // start on a pending character, a quote in a start name, delete refused for a guild member
	LobbyErrBadChargen     uint16 = 0x403 // a body or an item outside the rules
	LobbyErrNoWeapon       uint16 = 0x404
	LobbyErrAccountFull    uint16 = 0x405
	LobbyErrCreateFailed   uint16 = 0x406 // the store could not add the row; the armour pieces of different classes (INFERRED)
	LobbyErrNoUser         uint16 = 0x407 // not logged in
	LobbyErrDeleteName     uint16 = 0x408 // delete: an empty name or one with a quote
	LobbyErrNoGameServer   uint16 = 0x409
	LobbyErr40A            uint16 = 0x40a
	LobbyErrNotOnAccount   uint16 = 0x40b
	LobbyErrNameLength     uint16 = 0x40c
	LobbyErrNameInvalid    uint16 = 0x40d
	LobbyErrBusy           uint16 = 0x40e
	LobbyErrNoParent       uint16 = 0x40f
	LobbyErrNameExists     uint16 = 0x410
	LobbyErrNothingRestore uint16 = 0x419
)

// LobbyRequest is a 0x7007 payload. Only the fields its Action carries are
// encoded: create carries everything, list nothing, the others the name.
type LobbyRequest struct {
	Action uint8
	Name   string
	// Create only: the body, the scale byte, then the four items. The order
	// is u32 model, u8 scale, then u32 chest, legs, feet, weapon (READ in both
	// the client's writer 0x84e2e0 and the server's parser 0x41a470 --
	// correcting RE_COMPLETION's "five dwords then a byte").
	RefObjID                  uint32
	Scale                     uint8
	Chest, Legs, Feet, Weapon uint32
}

// Encode writes the request as the client does.
func (r *LobbyRequest) Encode() []byte {
	out := []byte{r.Action}
	switch r.Action {
	case LobbyList:
	case LobbyCreate:
		out = appendLobbyName(out, r.Name)
		out = binary.LittleEndian.AppendUint32(out, r.RefObjID)
		out = append(out, r.Scale)
		for _, v := range []uint32{r.Chest, r.Legs, r.Feet, r.Weapon} {
			out = binary.LittleEndian.AppendUint32(out, v)
		}
	default:
		out = appendLobbyName(out, r.Name)
	}
	return out
}

// DecodeLobbyRequest reads a 0x7007 payload. An unknown action decodes with
// no fields (the server ignores it, READ).
func DecodeLobbyRequest(data []byte) (*LobbyRequest, error) {
	rd := lobbyReader{b: data}
	r := &LobbyRequest{Action: rd.u8()}
	switch r.Action {
	case LobbyList:
	case LobbyCreate:
		r.Name = rd.str()
		r.RefObjID = rd.u32()
		r.Scale = rd.u8()
		r.Chest, r.Legs, r.Feet, r.Weapon = rd.u32(), rd.u32(), rd.u32(), rd.u32()
	case LobbyDelete, LobbyNameCheck, LobbyRestore:
		r.Name = rd.str()
	}
	if rd.err != nil {
		return nil, fmt.Errorf("session: decoding lobby request: %w", rd.err)
	}
	return r, nil
}

// LobbyItem is one item on a listed character: an equipped item with its plus
// (u32 RefItemID, u8 plus), or an avatar item (u32 RefItemID, u8 the client
// discards).
type LobbyItem struct {
	RefItemID uint32
	Plus      uint8
}

// LobbyCharacter is one record of the list (READ: the server's builder and
// the client's SCharacterInfo reader 0x85e620; column names INFERRED from
// _CHAR's bind order).
type LobbyCharacter struct {
	RefObjID   uint32
	Name       string
	Scale      uint8
	Level      uint8
	Exp        uint64 // ExpOffset
	Str        uint16
	Int        uint16
	StatPoints uint16
	HP         uint32
	MP         uint32
	Deleting   bool
	// MinutesLeft is sent only while Deleting.
	MinutesLeft uint32
	// GuildClass: 0 none, 1 member, 2 master; AcademyClass: 0 none, 1
	// student, 2 guardian (READ: the delete button's refusal picks
	// ..._CONFIRM_MEMBER / _MASTER from +0x1f0 == 1 / 2 and _STUDENT /
	// _GUARDIAN from +0x1f1 == 1 / 2, client 0x858b66-0x858bd4).
	GuildClass uint8
	// GuildRename and GuildName are the unity-server rename case (out of
	// scope); the name is sent only when the flag is set.
	GuildRename  bool
	GuildName    string
	AcademyClass uint8
	Items        []LobbyItem // at most 9
	Avatars      []LobbyItem // at most 5
}

// The record's caps (READ).
const (
	LobbyMaxItems   = 9
	LobbyMaxAvatars = 5
)

func (c *LobbyCharacter) encode(out []byte) []byte {
	out = binary.LittleEndian.AppendUint32(out, c.RefObjID)
	out = appendLobbyName(out, c.Name)
	out = append(out, c.Scale, c.Level)
	out = binary.LittleEndian.AppendUint64(out, c.Exp)
	out = binary.LittleEndian.AppendUint16(out, c.Str)
	out = binary.LittleEndian.AppendUint16(out, c.Int)
	out = binary.LittleEndian.AppendUint16(out, c.StatPoints)
	out = binary.LittleEndian.AppendUint32(out, c.HP)
	out = binary.LittleEndian.AppendUint32(out, c.MP)
	if c.Deleting {
		out = append(out, 1)
		out = binary.LittleEndian.AppendUint32(out, c.MinutesLeft)
	} else {
		out = append(out, 0)
	}
	out = append(out, c.GuildClass)
	if c.GuildRename {
		out = append(out, 1)
		out = appendLobbyName(out, c.GuildName)
	} else {
		out = append(out, 0)
	}
	out = append(out, c.AcademyClass)
	items := c.Items
	if len(items) > LobbyMaxItems {
		items = items[:LobbyMaxItems]
	}
	out = append(out, uint8(len(items)))
	for _, it := range items {
		out = binary.LittleEndian.AppendUint32(out, it.RefItemID)
		out = append(out, it.Plus)
	}
	avatars := c.Avatars
	if len(avatars) > LobbyMaxAvatars {
		avatars = avatars[:LobbyMaxAvatars]
	}
	out = append(out, uint8(len(avatars)))
	for _, it := range avatars {
		out = binary.LittleEndian.AppendUint32(out, it.RefItemID)
		out = append(out, it.Plus)
	}
	return out
}

func decodeLobbyCharacter(rd *lobbyReader) LobbyCharacter {
	var c LobbyCharacter
	c.RefObjID = rd.u32()
	c.Name = rd.str()
	c.Scale = rd.u8()
	c.Level = rd.u8()
	c.Exp = rd.u64()
	c.Str, c.Int, c.StatPoints = rd.u16(), rd.u16(), rd.u16()
	c.HP, c.MP = rd.u32(), rd.u32()
	if rd.u8() != 0 {
		c.Deleting = true
		c.MinutesLeft = rd.u32()
	}
	c.GuildClass = rd.u8()
	if rd.u8() != 0 {
		c.GuildRename = true
		c.GuildName = rd.str()
	}
	c.AcademyClass = rd.u8()
	n := int(rd.u8())
	if n > LobbyMaxItems && rd.err == nil {
		rd.err = fmt.Errorf("%d items, at most %d", n, LobbyMaxItems)
	}
	for i := 0; i < n && rd.err == nil; i++ {
		c.Items = append(c.Items, LobbyItem{RefItemID: rd.u32(), Plus: rd.u8()})
	}
	n = int(rd.u8())
	if n > LobbyMaxAvatars && rd.err == nil {
		rd.err = fmt.Errorf("%d avatars, at most %d", n, LobbyMaxAvatars)
	}
	for i := 0; i < n && rd.err == nil; i++ {
		c.Avatars = append(c.Avatars, LobbyItem{RefItemID: rd.u32(), Plus: rd.u8()})
	}
	return c
}

// LobbyResult is a 0xB007 payload: the action echoed, then OK with the
// action's payload (only list has one) or an error code.
type LobbyResult struct {
	Action     uint8
	OK         bool
	Code       uint16 // when !OK
	Characters []LobbyCharacter
}

// Encode writes the result. The restore path's asynchronous error is a u8 in
// the server and a u16 in the client (READ both; charselect.md); the client's
// u16 is sent (OURS).
func (r *LobbyResult) Encode() []byte {
	if !r.OK {
		out := []byte{r.Action, lobbyResultFail}
		return binary.LittleEndian.AppendUint16(out, r.Code)
	}
	out := []byte{r.Action, lobbyResultOK}
	if r.Action == LobbyList {
		out = append(out, uint8(len(r.Characters)))
		for i := range r.Characters {
			out = r.Characters[i].encode(out)
		}
	}
	return out
}

// DecodeLobbyResult reads a 0xB007 payload.
func DecodeLobbyResult(data []byte) (*LobbyResult, error) {
	rd := lobbyReader{b: data}
	r := &LobbyResult{Action: rd.u8()}
	switch res := rd.u8(); res {
	case lobbyResultOK:
		r.OK = true
		if r.Action == LobbyList {
			n := int(rd.u8())
			for i := 0; i < n && rd.err == nil; i++ {
				r.Characters = append(r.Characters, decodeLobbyCharacter(&rd))
			}
		}
	case lobbyResultFail:
		r.Code = rd.u16()
	default:
		if rd.err == nil {
			rd.err = fmt.Errorf("result byte %d", res)
		}
	}
	if rd.err != nil {
		return nil, fmt.Errorf("session: decoding lobby result: %w", rd.err)
	}
	return r, nil
}

// StartRequest is a 0x7001 payload: the name alone, no action byte (READ,
// 0x858770).
type StartRequest struct {
	Name string
}

func (r *StartRequest) Encode() []byte { return appendLobbyName(nil, r.Name) }

func DecodeStartRequest(data []byte) (*StartRequest, error) {
	rd := lobbyReader{b: data}
	r := &StartRequest{Name: rd.str()}
	if rd.err != nil {
		return nil, fmt.Errorf("session: decoding start request: %w", rd.err)
	}
	return r, nil
}

// StartResult is a 0xB001 payload: u8 1, or u8 2 and a u16 code (READ).
type StartResult struct {
	OK   bool
	Code uint16
}

func (r *StartResult) Encode() []byte {
	if r.OK {
		return []byte{lobbyResultOK}
	}
	return binary.LittleEndian.AppendUint16([]byte{lobbyResultFail}, r.Code)
}

func DecodeStartResult(data []byte) (*StartResult, error) {
	rd := lobbyReader{b: data}
	r := &StartResult{}
	switch res := rd.u8(); res {
	case lobbyResultOK:
		r.OK = true
	case lobbyResultFail:
		r.Code = rd.u16()
	default:
		if rd.err == nil {
			rd.err = fmt.Errorf("result byte %d", res)
		}
	}
	if rd.err != nil {
		return nil, fmt.Errorf("session: decoding start result: %w", rd.err)
	}
	return r, nil
}

func appendLobbyName(out []byte, name string) []byte {
	out = binary.LittleEndian.AppendUint16(out, uint16(len(name)))
	return append(out, name...)
}

// lobbyReader reads little-endian fields, remembering the first shortfall.
type lobbyReader struct {
	b   []byte
	err error
}

var errLobbyShort = errors.New("truncated")

func (r *lobbyReader) take(n int) []byte {
	if r.err != nil {
		return nil
	}
	if len(r.b) < n {
		r.err = errLobbyShort
		return nil
	}
	v := r.b[:n]
	r.b = r.b[n:]
	return v
}

func (r *lobbyReader) u8() uint8 {
	if v := r.take(1); v != nil {
		return v[0]
	}
	return 0
}

func (r *lobbyReader) u16() uint16 {
	if v := r.take(2); v != nil {
		return binary.LittleEndian.Uint16(v)
	}
	return 0
}

func (r *lobbyReader) u32() uint32 {
	if v := r.take(4); v != nil {
		return binary.LittleEndian.Uint32(v)
	}
	return 0
}

func (r *lobbyReader) u64() uint64 {
	if v := r.take(8); v != nil {
		return binary.LittleEndian.Uint64(v)
	}
	return 0
}

func (r *lobbyReader) str() string {
	n := int(r.u16())
	if v := r.take(n); v != nil {
		return string(v)
	}
	return ""
}
