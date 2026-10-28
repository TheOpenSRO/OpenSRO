package session

import (
	"bufio"
	"context"
	"strings"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

func TestChatPayloadsRoundTrip(t *testing.T) {
	send := &ChatSendRequest{Type: ChatWhisper, Index: 7, Target: "Bram", Message: "psst"}
	if got, err := DecodeChatSendRequest(send.Encode()); err != nil || *got != *send {
		t.Fatalf("ChatSendRequest: got %+v err %v, want %+v", got, err, send)
	}
	up := &ChatUpdate{Type: ChatGlobal, Sender: "Aria", Message: "wts blade"}
	if got, err := DecodeChatUpdate(up.Encode()); err != nil || *got != *up {
		t.Fatalf("ChatUpdate: got %+v err %v, want %+v", got, err, up)
	}
	res := &ChatResult{OK: false, Type: ChatWhisper, Index: 9, Code: ChatErrCantFindTarget, Target: "Ghost"}
	if got, err := DecodeChatResult(res.Encode()); err != nil || *got != *res {
		t.Fatalf("ChatResult: got %+v err %v, want %+v", got, err, res)
	}
	glob := &ChatGlobalRequest{InventorySlot: 21, Message: "hi all"}
	if got, err := DecodeChatGlobalRequest(glob.Encode()); err != nil || *got != *glob {
		t.Fatalf("ChatGlobalRequest: got %+v err %v, want %+v", got, err, glob)
	}
}

// The types are the retail client's bytes (0x7ad400's prefix switch,
// 0x877810's reader); a renumbering would still round-trip, so pin them.
func TestChatTypesAreTheClientBytes(t *testing.T) {
	for name, pair := range map[string][2]byte{
		"all": {ChatAll, 1}, "whisper": {ChatWhisper, 2}, "gm": {ChatAllGM, 3}, "party": {ChatParty, 4},
		"guild": {ChatGuild, 5}, "global": {ChatGlobal, 6}, "notice": {ChatNotice, 7},
		"union": {ChatUnion, 0x0b}, "academy": {ChatAcademy, 0x10},
	} {
		if pair[0] != pair[1] {
			t.Errorf("%s = %d, want %d", name, pair[0], pair[1])
		}
	}
}

type chatClient struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
}

func (c *chatClient) send(opcode uint16, data []byte) {
	c.t.Helper()
	if err := proto.Write(c.conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
		c.t.Fatalf("Write: %v", err)
	}
}

// next reads packets until one with the opcode arrives (other broadcasts,
// such as an entity entering, are skipped).
func (c *chatClient) next(opcode uint16) *proto.Packet {
	c.t.Helper()
	for {
		c.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			c.t.Fatalf("waiting for 0x%04x: %v", opcode, err)
		}
		if p.Opcode == opcode {
			return p
		}
	}
}

// none asserts nothing with the opcode arrives within a short window.
func (c *chatClient) none(opcode uint16) {
	c.t.Helper()
	for {
		c.conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			return
		}
		if p.Opcode == opcode {
			c.t.Fatalf("unexpected 0x%04x: % x", opcode, p.Data)
		}
	}
}

func (c *chatClient) update() *ChatUpdate {
	c.t.Helper()
	u, err := DecodeChatUpdate(c.next(OpChatUpdate).Data)
	if err != nil {
		c.t.Fatalf("DecodeChatUpdate: %v", err)
	}
	return u
}

func (c *chatClient) result() *ChatResult {
	c.t.Helper()
	r, err := DecodeChatResult(c.next(OpChatResult).Data)
	if err != nil {
		c.t.Fatalf("DecodeChatResult: %v", err)
	}
	return r
}

func (c *chatClient) say(typ, index byte, target, msg string) {
	c.send(OpChatSend, (&ChatSendRequest{Type: typ, Index: index, Target: target, Message: msg}).Encode())
}

type chatWorld struct {
	hub     *world.Hub
	parties *party.Hub
	guilds  *guild.MemStore
	inv     *inventory.MemStore
	a, b, c *chatClient
}

// globalItemID is a synthetic global chatting item (TypeID 3/3/3/5); 99 is a
// potion-shaped item that is not one.
const (
	globalItemID  = 900001
	greenGlobalID = 57832 // ITEM_MALL_GLOBAL_CHATTING_GREEN (round 838)
	notGlobalID   = 99
)

// newChatWorld logs three accounts in (alice is a GM), each into the same
// zone, with the channels' stores behind the handler.
func newChatWorld(t *testing.T) *chatWorld {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "pw1")
	accounts.Add("bob", "pw2")
	accounts.Add("carol", "pw3")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")
	chars.Create(ctx, 3, "Cato")

	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: globalItemID, CodeName: "ITEM_MALL_GLOBAL_CHATTING", TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 5, MaxStack: 50},
		{ID: notGlobalID, CodeName: "ITEM_ETC_HP_POTION_01", TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1, MaxStack: 50},
		{ID: greenGlobalID, CodeName: "ITEM_MALL_GLOBAL_CHATTING_GREEN", TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 5, MaxStack: 50},
	}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}
	w := &chatWorld{hub: world.NewHub(), parties: party.NewHub(), guilds: guild.NewMemStore(), inv: inventory.NewMemStore(nil)}
	gate := gm.ParseAccounts("alice")
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, w.hub),
		ChatHandler(ChatDeps{Hub: w.hub, Parties: w.parties, Guilds: w.guilds, Inv: w.inv, Items: items, Gate: gate}))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)

	login := func(user, pw, name string) *chatClient {
		conn := dialTestServer(t, addr)
		t.Cleanup(func() { conn.Close() })
		c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
		c.send(OpLogin, (&LoginRequest{Username: user, Password: pw}).Encode())
		if lr, err := DecodeLoginResult(c.next(OpLoginResult).Data); err != nil || !lr.OK {
			t.Fatalf("%s login: %v %+v", user, err, lr)
		}
		c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
		if er, err := DecodeEnterWorldResult(c.next(OpEnterWorldResult).Data); err != nil || !er.OK {
			t.Fatalf("%s enter world: %v %+v", name, err, er)
		}
		return c
	}
	w.a = login("alice", "pw1", "Aria")
	w.b = login("bob", "pw2", "Bram")
	w.c = login("carol", "pw3", "Cato")
	return w
}

// TestChatAllAndWhisper: ordinary chat reaches the zone but not the sender,
// who gets 0xB025's OK carrying its index; a whisper reaches only its target;
// a whisper to nobody answers code 3 with the name.
func TestChatAllAndWhisper(t *testing.T) {
	w := newChatWorld(t)

	w.b.say(ChatAll, 1, "", "hello, jangan")
	if r := w.b.result(); !r.OK || r.Type != ChatAll || r.Index != 1 {
		t.Fatalf("sender's result = %+v, want OK type 1 index 1", r)
	}
	for _, c := range []*chatClient{w.a, w.c} {
		if u := c.update(); *u != (ChatUpdate{Type: ChatAll, Sender: "Bram", Message: "hello, jangan"}) {
			t.Fatalf("heard %+v", u)
		}
	}
	w.b.none(OpChatUpdate)

	w.b.say(ChatWhisper, 2, "Aria", "psst")
	if r := w.b.result(); !r.OK || r.Type != ChatWhisper || r.Index != 2 || r.Target != "Aria" {
		t.Fatalf("whisper result = %+v", r)
	}
	if u := w.a.update(); *u != (ChatUpdate{Type: ChatWhisper, Sender: "Bram", Message: "psst"}) {
		t.Fatalf("whisper heard %+v", u)
	}
	w.c.none(OpChatUpdate)

	// A whisper to oneself: the "(TO)" echo only, no "(FROM)" line too.
	w.c.say(ChatWhisper, 4, "Cato", "note to self")
	w.c.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	first, err := proto.Read(w.c.r, nil, nil)
	if err != nil || first.Opcode != OpChatResult {
		t.Fatalf("a self-whisper's first answer is 0x%04x, want only the result (no FROM line)", first.Opcode)
	}
	if r, _ := DecodeChatResult(first.Data); !r.OK || r.Target != "Cato" {
		t.Fatalf("self-whisper result = %+v", r)
	}
	w.c.none(OpChatUpdate)

	w.b.say(ChatWhisper, 3, "Ghost", "hello?")
	if r := w.b.result(); r.OK || r.Code != ChatErrCantFindTarget || r.Target != "Ghost" || r.Index != 3 {
		t.Fatalf("whisper to nobody = %+v, want code 3 naming Ghost", r)
	}
}

// TestChatGMLineOnlyFromGM: a type-3 line from a GM account goes out as 3; the
// same byte from a player goes out as ordinary chat.
func TestChatGMLineOnlyFromGM(t *testing.T) {
	w := newChatWorld(t)
	w.a.say(ChatAllGM, 1, "", "server restart soon")
	w.a.result()
	if u := w.b.update(); u.Type != ChatAllGM || u.Sender != "Aria" {
		t.Fatalf("GM line heard as %+v, want type 3", u)
	}
	w.c.update()
	w.b.say(ChatAllGM, 1, "", "i am a gm")
	w.b.result()
	if u := w.a.update(); u.Type != ChatAll {
		t.Fatalf("a player's type-3 line heard as %+v, want type 1", u)
	}
}

// TestChatPartyAndGuild: the party and guild lines reach only the group; with
// no group they are refused with the codes the client shows.
func TestChatPartyAndGuild(t *testing.T) {
	w := newChatWorld(t)
	ctx := context.Background()

	w.a.say(ChatParty, 4, "", "anyone?")
	if r := w.a.result(); r.OK || r.Code != ChatErrNotPartyMember {
		t.Fatalf("party with no party = %+v, want 0x200a", r)
	}
	w.a.say(ChatGuild, 5, "", "anyone?")
	if r := w.a.result(); r.OK || r.Code != ChatErrNoGuild {
		t.Fatalf("guild with no guild = %+v, want the no-guild code", r)
	}

	ea, _ := w.hub.FindByName("Aria")
	eb, _ := w.hub.FindByName("Bram")
	if _, err := w.parties.Form(party.Member{Session: ea.Session, CharacterID: ea.CharacterID, Name: "Aria", Level: 10},
		party.Member{Session: eb.Session, CharacterID: eb.CharacterID, Name: "Bram"}, party.FlagExpShare); err != nil {
		t.Fatalf("party form: %v", err)
	}
	w.a.say(ChatParty, 6, "", "pull the boss")
	// The sender hears its own line too (round 710; GS 0x5bef50 excludes no
	// one), before its result.
	if u := w.a.update(); *u != (ChatUpdate{Type: ChatParty, Sender: "Aria", Message: "pull the boss"}) {
		t.Fatalf("party echo %+v", u)
	}
	if r := w.a.result(); !r.OK || r.Type != ChatParty {
		t.Fatalf("party result %+v", r)
	}
	if u := w.b.update(); *u != (ChatUpdate{Type: ChatParty, Sender: "Aria", Message: "pull the boss"}) {
		t.Fatalf("party heard %+v", u)
	}
	w.c.none(OpChatUpdate)

	g, err := w.guilds.Create(ctx, "Lions", ec(w, "Cato"), "Cato")
	if err != nil {
		t.Fatalf("guild create: %v", err)
	}
	if _, err := w.guilds.Join(ctx, g.ID, ec(w, "Bram"), "Bram"); err != nil {
		t.Fatalf("guild join: %v", err)
	}
	w.c.say(ChatGuild, 7, "", "guild war at 8")
	if r := w.c.result(); !r.OK {
		t.Fatalf("guild result %+v", r)
	}
	if u := w.b.update(); *u != (ChatUpdate{Type: ChatGuild, Sender: "Cato", Message: "guild war at 8"}) {
		t.Fatalf("guild heard %+v", u)
	}
	w.a.none(OpChatUpdate)

	// OpenSRO has no alliances and no academy.
	w.c.say(ChatUnion, 8, "", "x")
	if r := w.c.result(); r.OK || r.Code != ChatErrAllianceDenied {
		t.Fatalf("union = %+v, want 0x200b", r)
	}
	w.c.say(ChatAcademy, 9, "", "x")
	if r := w.c.result(); r.OK || r.Code != ChatErrNoAcademy {
		t.Fatalf("academy = %+v, want the no-academy code", r)
	}
	// A notice is not the player's to send.
	w.c.say(ChatNotice, 10, "", "fake notice")
	if r := w.c.result(); r.OK || r.Code != ChatErrInvalidCommand {
		t.Fatalf("player notice = %+v, want refused", r)
	}
	w.a.none(OpChatUpdate)
}

func ec(w *chatWorld, name string) int64 {
	e, _ := w.hub.FindByName(name)
	return e.CharacterID
}

// TestChatGlobalSpendsTheItemAndReachesEveryone: a global needs the global
// chatting item in the named slot, spends one, and reaches every character,
// the sender too.
func TestChatGlobalSpendsTheItemAndReachesEveryone(t *testing.T) {
	w := newChatWorld(t)
	ctx := context.Background()
	id := ec(w, "Aria")

	// No item: refused, nobody hears it.
	w.a.send(OpChatGlobal, (&ChatGlobalRequest{InventorySlot: 13, Message: "wts"}).Encode())
	if r := w.a.result(); r.OK || r.Code != ChatErrNoGlobalItem {
		t.Fatalf("global with nothing = %+v", r)
	}
	if err := w.inv.AddItem(ctx, id, notGlobalID, 1); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	if err := w.inv.AddItem(ctx, id, globalItemID, 2); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	slots, _ := w.inv.List(ctx, id)
	var potionSlot, globalSlot int = -1, -1
	for _, s := range slots {
		switch s.ItemID {
		case notGlobalID:
			potionSlot = s.Index
		case globalItemID:
			globalSlot = s.Index
		}
	}
	w.a.send(OpChatGlobal, (&ChatGlobalRequest{InventorySlot: int32(potionSlot), Message: "wts"}).Encode())
	if r := w.a.result(); r.OK || r.Code != ChatErrNoGlobalItem {
		t.Fatalf("global from a potion = %+v", r)
	}
	w.b.none(OpChatUpdate)

	w.a.send(OpChatGlobal, (&ChatGlobalRequest{InventorySlot: int32(globalSlot), Message: "WTS blade +7"}).Encode())
	want := ChatUpdate{Type: ChatGlobal, Sender: "Aria", Message: "WTS blade +7"}
	for _, c := range []*chatClient{w.a, w.b, w.c} {
		if u := c.update(); *u != want {
			t.Fatalf("global heard %+v, want %+v", u, want)
		}
	}
	if r := w.a.result(); !r.OK || r.Type != ChatGlobal {
		t.Fatalf("global result %+v", r)
	}
	slots, _ = w.inv.List(ctx, id)
	for _, s := range slots {
		if s.ItemID == globalItemID && s.Quantity != 1 {
			t.Fatalf("global chatting items left = %d, want 1", s.Quantity)
		}
	}
}

// Round 838: a green global chatting item's line carries its colour (OURS,
// GlobalChatColor) to everyone, and a line past 128 characters is cut with
// "..." (READ, case 5); the plain item's line carries none.
func TestChatGlobalGreenAndTheCut(t *testing.T) {
	w := newChatWorld(t)
	ctx := context.Background()
	id := ec(w, "Aria")
	if err := w.inv.AddItem(ctx, id, greenGlobalID, 1); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	slots, _ := w.inv.List(ctx, id)
	long := strings.Repeat("x", 130)
	w.a.send(OpChatGlobal, (&ChatGlobalRequest{InventorySlot: int32(slots[0].Index), Message: long}).Encode())
	want := ChatUpdate{Type: ChatGlobal, Sender: "Aria", Message: strings.Repeat("x", 128) + "...", Color: 0xff71fe99}
	for _, c := range []*chatClient{w.a, w.b, w.c} {
		if u := c.update(); *u != want {
			t.Fatalf("green global heard %+v, want %+v", u, want)
		}
	}
	if r := w.a.result(); !r.OK {
		t.Fatalf("green global result %+v", r)
	}
	// The colour rides as a strict suffix; a plain line has none.
	plain := (&ChatUpdate{Type: ChatGlobal, Sender: "A", Message: "m"}).Encode()
	green := (&ChatUpdate{Type: ChatGlobal, Sender: "A", Message: "m", Color: 0xff71fe99}).Encode()
	if len(green) != len(plain)+4 {
		t.Fatalf("green %d bytes, plain %d: want 4 more", len(green), len(plain))
	}
	if GlobalChatColor("ITEM_MALL_GLOBAL_CHATTING") != 0 || GlobalChatColor("ITEM_EVENT_GLOBAL_CHATTING") != 0 {
		t.Error("the plain items must keep the yellow")
	}
}

// TestNoticeReachesEveryone: BroadcastNotice is chat type 7 with no sender,
// to every character; the GM command hands its text through untouched.
func TestNoticeReachesEveryone(t *testing.T) {
	w := newChatWorld(t)
	if n := BroadcastNotice(w.hub, "Server maintenance in  10 minutes."); n != 3 {
		t.Fatalf("notice reached %d, want 3", n)
	}
	for _, c := range []*chatClient{w.a, w.b, w.c} {
		if u := c.update(); *u != (ChatUpdate{Type: ChatNotice, Message: "Server maintenance in  10 minutes."}) {
			t.Fatalf("notice heard %+v", u)
		}
	}
	d := &gm.Deps{}
	res := d.Run(context.Background(), gm.Actor{Name: "Aria"}, "/notice Server maintenance in  10 minutes.")
	if res.Refused || res.Notice != "Server maintenance in  10 minutes." {
		t.Fatalf("/notice = %+v", res)
	}
	if res := d.Run(context.Background(), gm.Actor{Name: "Aria"}, "/ notice hi there"); res.Refused || res.Notice != "hi there" {
		t.Fatalf("'/ notice hi there' = %+v, want the notice 'hi there'", res)
	}
	if res := d.Run(context.Background(), gm.Actor{Name: "Aria"}, "/notice   "); !res.Refused || res.Notice != "" {
		t.Fatalf("/notice with no text = %+v, want refused", res)
	}
}
