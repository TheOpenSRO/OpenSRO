package session

import (
	"context"
	"encoding/binary"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Chat (round 634). The opcodes and their framing are OpenSRO's own; what
// they carry is the retail client's, READ from sro_client.exe and written up
// in docs/protocol/chat.md:
//
//   - the chat TYPES are the byte the client's input handler 0x7ad400 puts in
//     its 0x7025 request (+0x424) and the byte 0x3026's handler
//     (Chat_OnChatUpdate, 0x877810) switches on;
//   - the result is 0xB025's (0x877340): a success echoes the type and the
//     request's index, and a failure carries one of the error codes below;
//   - a global is not a chat request at all: it is an item use (0x704c from
//     0x7901c0) of the global chatting item, TypeID 3/3/3/5.
//
// All require the sender to be in the world: identity and zone come from
// world.Hub.
const (
	OpChatSend   uint16 = 0x00A5 // client -> server: the 0x7025 fields
	OpChatUpdate uint16 = 0x00A6 // server -> client: the 0x3026 fields
	OpChatResult uint16 = 0x00A7 // server -> client: the 0xB025 fields
	OpChatGlobal uint16 = 0x00A8 // client -> server: the global chatting item's use (0x704c)
)

// The chat types (READ: 0x7ad400's prefix switch, 0x877810's reader, 0x876810's
// colour and caption switches).
const (
	ChatAll     byte = 0x01 // no prefix; 0x3026 reads a unique id then the text
	ChatWhisper byte = 0x02 // "$name text"
	ChatAllGM   byte = 0x03 // a GM's line with no prefix (0x7ad400 asks FUN_009d4c40)
	ChatParty   byte = 0x04 // "#"
	ChatGuild   byte = 0x05 // "@"
	ChatGlobal  byte = 0x06 // the global chatting item
	ChatNotice  byte = 0x07 // the text only; 0x876810 also raises GDR_NOTICE
	ChatUnion   byte = 0x0b // "%"
	ChatAcademy byte = 0x10 // "&"
)

// The failure codes 0xB025's handler (0x877340) names, with the string it
// shows for each.
const (
	ChatErrCantFindTarget  uint16 = 0x0003 // UIIT_CHATERR_CANT_FIND_TARGET, "Cannot find [%s]."
	ChatErrSquelched       uint16 = 0x2006 // UIIT_CHATERR_YOU_ARE_SQUELCHED
	ChatErrInvalidCommand  uint16 = 0x2008 // UIIT_CHATERR_INVALID_COMMAND
	ChatErrNotPartyMember  uint16 = 0x200a // UIIT_CHATERR_NOT_A_PARTY_MEMBER
	ChatErrAllianceDenied  uint16 = 0x200b // UIIT_CHATERR_ALLIANCE_PERMISSION_DENIED (0x200c too)
	ChatErrCantChat        uint16 = 0x200d // UIIT_STT_CANT_CHATTING
	ChatErrGuildUnionLimit uint16 = 0x200e // UIIT_MSG_GUILD_UNION_CHAT_LIMIT
	// OURS: the retail client refuses these two itself before it sends
	// (0x7ad400 asks 0x9870e0 / 0x987140 and shows UIIT_MSG_GUILD_NON_EXISTING
	// / UIIT_MSG_TC_ERROR_NOT_POSITION); OpenSRO's client does not hold the
	// guild or academy state, so the server answers and the client shows the
	// same two strings. The values are outside every code 0x877340 reads.
	ChatErrNoGuild   uint16 = 0xf001
	ChatErrNoAcademy uint16 = 0xf002
	// OURS: a global with no global chatting item in the named slot. Retail
	// answers that through 0x704c's own item-use result, not 0xB025.
	ChatErrNoGlobalItem uint16 = 0xf003
	// OURS: an empty line. The retail client never sends one (0x7ad400 ends
	// the input on an empty box, 0x7ef550 refuses an empty global).
	ChatErrEmpty uint16 = 0xf004
)

// The global chatting item's TypeID (READ: 0x7901c0 sends 0x704c only when the
// slot's type word has (w & 0x1c) == 0xc, (w & 0x60) == 0x60, (w & 0x780) ==
// 0x180 and (w & 0xf800) == 0x2800 -- TypeID1..4 = 3, 3, 3, 5 -- and
// IFSlotWithHelp 0x676570's case 5 opens CIFWholeChat for it).
const (
	globalItemTID1 = 3
	globalItemTID2 = 3
	globalItemTID3 = 3
	globalItemTID4 = 5
)

// ChatSendRequest is OpChatSend: 0x7025's type, index and (for a whisper) the
// receiver, then the text.
type ChatSendRequest struct {
	Type    byte
	Index   byte
	Target  string
	Message string
}

func (r *ChatSendRequest) Encode() []byte {
	return append([]byte{r.Type, r.Index}, encodeStrings(r.Target, r.Message)...)
}

func DecodeChatSendRequest(data []byte) (*ChatSendRequest, error) {
	if len(data) < 2 {
		return nil, fmt.Errorf("session: decoding ChatSendRequest: short header")
	}
	fields, err := decodeStrings(data[2:], 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChatSendRequest: %w", err)
	}
	return &ChatSendRequest{Type: data[0], Index: data[1], Target: fields[0], Message: fields[1]}, nil
}

// ChatUpdate is OpChatUpdate: one line for the receiver's chat. Sender is ""
// for a notice. Retail's 0x3026 carries a unique id instead of a name for
// types 1, 3 and 0xd (0x877810 resolves it); OpenSRO sends the name (OURS).
type ChatUpdate struct {
	Type    byte
	Sender  string
	Message string
}

func (r *ChatUpdate) Encode() []byte {
	return append([]byte{r.Type}, encodeStrings(r.Sender, r.Message)...)
}

func DecodeChatUpdate(data []byte) (*ChatUpdate, error) {
	if len(data) < 1 {
		return nil, fmt.Errorf("session: decoding ChatUpdate: empty")
	}
	fields, err := decodeStrings(data[1:], 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChatUpdate: %w", err)
	}
	return &ChatUpdate{Type: data[0], Sender: fields[0], Message: fields[1]}, nil
}

// ChatResult is OpChatResult: 0xB025's answer to the sender. On OK the client
// shows its own line from the request it kept under Index (0x877340 looks it
// up through 0x787db0); on a failure Code says why and Target is the name the
// "[%s]" strings format.
type ChatResult struct {
	OK     bool
	Type   byte
	Index  byte
	Code   uint16
	Target string
}

func (r *ChatResult) Encode() []byte {
	out := []byte{boolByte(r.OK), r.Type, r.Index, 0, 0}
	binary.LittleEndian.PutUint16(out[3:5], r.Code)
	return append(out, encodeStrings(r.Target)...)
}

func DecodeChatResult(data []byte) (*ChatResult, error) {
	if len(data) < 5 {
		return nil, fmt.Errorf("session: decoding ChatResult: short header")
	}
	fields, err := decodeStrings(data[5:], 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChatResult: %w", err)
	}
	return &ChatResult{OK: data[0] != 0, Type: data[1], Index: data[2],
		Code: binary.LittleEndian.Uint16(data[3:5]), Target: fields[0]}, nil
}

// ChatGlobalRequest is OpChatGlobal: 0x704c's slot and text (the type word it
// also carries is the server's to check here, from the slot's own item).
type ChatGlobalRequest struct {
	InventorySlot int32
	Message       string
}

func (r *ChatGlobalRequest) Encode() []byte {
	return append(encodeInt64(int64(r.InventorySlot)), encodeStrings(r.Message)...)
}

func DecodeChatGlobalRequest(data []byte) (*ChatGlobalRequest, error) {
	slot, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChatGlobalRequest: slot: %w", err)
	}
	fields, err := decodeStrings(rest, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChatGlobalRequest: %w", err)
	}
	return &ChatGlobalRequest{InventorySlot: int32(slot), Message: fields[0]}, nil
}

// ChatDeps are what the chat channels reach. Any may be nil: a channel whose
// group store is missing answers as if the sender were in no such group.
type ChatDeps struct {
	Hub     *world.Hub
	Parties *party.Hub
	Guilds  guild.Store
	// Inv and Items back the global chatting item.
	Inv   inventory.Store
	Items combat.ItemLookup
	// Gate decides whether a type-3 (GM) line is honoured.
	Gate *gm.Gate
}

// ChatHandler returns the gateway.Handler for OpChatSend and OpChatGlobal.
func ChatHandler(d ChatDeps) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpChatSend:
			return handleChatSend(ctx, sess, p, d)
		case OpChatGlobal:
			return handleChatGlobal(ctx, sess, p, d)
		default:
			return nil
		}
	}
}

func sendChatResult(sess *gateway.Session, r *ChatResult) error {
	return sess.Send(&proto.Packet{Opcode: OpChatResult, Data: r.Encode()})
}

func sendChatUpdate(sess *gateway.Session, u *ChatUpdate) error {
	return sess.Send(&proto.Packet{Opcode: OpChatUpdate, Data: u.Encode()})
}

func handleChatSend(ctx context.Context, sess *gateway.Session, p *proto.Packet, d ChatDeps) error {
	req, err := DecodeChatSendRequest(p.Data)
	if err != nil {
		// Nothing meaningful to tell a client that sent garbage.
		return nil
	}
	if d.Hub == nil {
		return nil
	}
	sender, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	fail := func(code uint16, target string) error {
		return sendChatResult(sess, &ChatResult{Type: req.Type, Index: req.Index, Code: code, Target: target})
	}
	okResult := func() error {
		return sendChatResult(sess, &ChatResult{OK: true, Type: req.Type, Index: req.Index, Target: req.Target})
	}
	if req.Message == "" {
		return fail(ChatErrEmpty, "")
	}
	line := &ChatUpdate{Type: req.Type, Sender: sender.Name, Message: req.Message}

	switch req.Type {
	case ChatAll, ChatAllGM:
		// A type-3 line is the GM's (the client picks it, 0x7ad400 asking
		// FUN_009d4c40); from anyone else it is ordinary chat (OURS: the
		// server-side check was not read).
		if req.Type == ChatAllGM {
			username, _ := AuthenticatedUsername(sess)
			if d.Gate == nil || !d.Gate.Allows(username) {
				line.Type = ChatAll
			}
		}
		// The audience is the sender's zone bucket (OURS: retail's range for
		// ordinary chat was not read).
		for _, e := range d.Hub.EntitiesInZone(sender.Zone) {
			if e.Session.ID() == sess.ID() {
				continue
			}
			sendChatUpdate(e.Session, line)
		}
		return okResult()

	case ChatWhisper:
		target, ok := d.Hub.FindByName(req.Target)
		if !ok {
			return fail(ChatErrCantFindTarget, req.Target)
		}
		// A whisper to oneself is answered with the sender's "(TO)" echo
		// only, not a "(FROM)" line as well (OURS: retail's server was not
		// read for it; its client will not even reply to itself, 0x7ab470).
		if target.Session.ID() == sess.ID() {
			return okResult()
		}
		if err := sendChatUpdate(target.Session, line); err != nil {
			return fail(ChatErrCantFindTarget, req.Target)
		}
		return okResult()

	case ChatParty:
		if d.Parties == nil {
			return fail(ChatErrNotPartyMember, "")
		}
		pt, ok := d.Parties.Get(sender.CharacterID)
		if !ok {
			return fail(ChatErrNotPartyMember, "")
		}
		// Every member hears it, the sender included, and nobody outside the
		// party (READ, round 709: GS CMainProcess::FUN_005bef50 sends the 0x3026
		// type 4 with CParty::BroadcastToLocalMember(msg, 0), an exclusion of 0
		// that excludes no one). The sender's client drops the copy carrying its
		// own name (c:Chat_OnChatUpdate 0x877810, case 4) and shows its line from
		// the result instead (round 710).
		for _, m := range pt.Members {
			if m.Session == nil {
				continue
			}
			sendChatUpdate(m.Session, line)
		}
		return okResult()

	case ChatGuild:
		if d.Guilds == nil {
			return fail(ChatErrNoGuild, "")
		}
		g, err := d.Guilds.GetByCharacter(ctx, sender.CharacterID)
		if err != nil || g == nil {
			return fail(ChatErrNoGuild, "")
		}
		for _, m := range g.Members {
			if m.CharacterID == sender.CharacterID {
				continue
			}
			if e, ok := d.Hub.EntityByCharacterID(m.CharacterID); ok {
				sendChatUpdate(e.Session, line)
			}
		}
		return okResult()

	case ChatUnion:
		// OpenSRO forms no alliances (internal/guild/alliance.go), so no
		// sender is in one: 0x200b, the client's "Cannot use the Ally Chat"
		// line.
		return fail(ChatErrAllianceDenied, "")

	case ChatAcademy:
		// OpenSRO has no academy (internal/academy's package comment).
		return fail(ChatErrNoAcademy, "")

	default:
		// A global or a notice is never a chat request (0x7ad400 sends
		// neither), and the other types are not the player's to send.
		return fail(ChatErrInvalidCommand, "")
	}
}

func handleChatGlobal(ctx context.Context, sess *gateway.Session, p *proto.Packet, d ChatDeps) error {
	req, err := DecodeChatGlobalRequest(p.Data)
	if err != nil || d.Hub == nil {
		return nil
	}
	sender, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	fail := func(code uint16) error {
		return sendChatResult(sess, &ChatResult{Type: ChatGlobal, Code: code})
	}
	if req.Message == "" {
		return fail(ChatErrEmpty)
	}
	if d.Inv == nil || d.Items == nil {
		return fail(ChatErrNoGlobalItem)
	}
	slots, err := d.Inv.List(ctx, sender.CharacterID)
	if err != nil {
		return fail(ChatErrNoGlobalItem)
	}
	var held *inventory.Slot
	for i := range slots {
		if slots[i].Index == int(req.InventorySlot) {
			held = &slots[i]
			break
		}
	}
	if held == nil || held.Quantity < 1 {
		return fail(ChatErrNoGlobalItem)
	}
	it, err := d.Items.GetItem(ctx, held.ItemID)
	if err != nil || it == nil || it.TypeID1 != globalItemTID1 || it.TypeID2 != globalItemTID2 ||
		it.TypeID3 != globalItemTID3 || it.TypeID4 != globalItemTID4 {
		return fail(ChatErrNoGlobalItem)
	}
	// One use per line (OURS: the server's own accounting of 0x704c for this
	// kind was not read; the window's "Remaining turns" is the stack count,
	// 0x7ef400 reading it off the slot).
	if err := d.Inv.RemoveItem(ctx, sender.CharacterID, held.Index, 1); err != nil {
		return fail(ChatErrNoGlobalItem)
	}
	BroadcastChatAll(d.Hub, &ChatUpdate{Type: ChatGlobal, Sender: sender.Name, Message: req.Message})
	return sendChatResult(sess, &ChatResult{OK: true, Type: ChatGlobal})
}

// BroadcastChatAll sends one line to every character in the world, the
// sender included: a global (type 6) and a notice (type 7) are heard
// everywhere.
func BroadcastChatAll(hub *world.Hub, u *ChatUpdate) int {
	if hub == nil {
		return 0
	}
	n := 0
	for _, e := range hub.AllEntities() {
		if e.Session == nil {
			continue
		}
		if sendChatUpdate(e.Session, u) == nil {
			n++
		}
	}
	return n
}

// BroadcastNotice is a GM notice: type 7, no sender.
func BroadcastNotice(hub *world.Hub, text string) int {
	return BroadcastChatAll(hub, &ChatUpdate{Type: ChatNotice, Message: text})
}
