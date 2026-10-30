package session

import (
	"bytes"
	"context"
	"encoding/binary"
	"math"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

type union844 struct {
	*deadWorldFixture
	guilds      *guild.MemStore
	alpha, beta *guild.Guild
}

// startUnion844: Aria masters Alpha and Bram Beta, side by side, with the
// guild, union, party (the 0x3080 answer) and chat handlers.
func startUnion844(t *testing.T) *union844 {
	t.Helper()
	guilds := guild.NewMemStore()
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return gateway.Chain(testGuildHandler(t, chars, guilds, hub), UnionHandler(),
			PartyHandler(PartyDeps{Chars: chars, Hub: hub, Parties: party.NewHub()}),
			ChatHandler(ChatDeps{Hub: hub, Guilds: guilds}))
	})
	ea, _ := f.hub.FindByName("Aria")
	eb, _ := f.hub.FindByName("Bram")
	f.hub.Relocate(ea.Session, world.Position{X: 50, Z: 0}, world.MoveRelocate, 0)
	f.hub.Relocate(eb.Session, world.Position{X: 55, Z: 0}, world.MoveRelocate, 0)
	ctx := context.Background()
	a, err := guilds.Create(ctx, "Alpha", f.aria, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	b, err := guilds.Create(ctx, "Beta", f.bram, "Bram")
	if err != nil {
		t.Fatal(err)
	}
	return &union844{deadWorldFixture: f, guilds: guilds, alpha: a, beta: b}
}

// level raises characterID's guild to n, as /guildlevel does.
func (u *union844) level(t *testing.T, characterID int64, n int) {
	t.Helper()
	ctx := context.Background()
	g, err := u.guilds.GetByCharacter(ctx, characterID)
	if err != nil {
		t.Fatal(err)
	}
	for g.Level < n {
		_, gp, _ := guild.LevelUpCost(g.Level)
		if err := u.guilds.AddPoints(ctx, g.ID, characterID, gp); err != nil {
			t.Fatal(err)
		}
		if g, err = u.guilds.LevelUp(ctx, characterID, true, math.MaxInt64, nil); err != nil {
			t.Fatal(err)
		}
	}
}

func u32(v int64) []byte { return binary.LittleEndian.AppendUint32(nil, uint32(v)) }

func failBytes(code uint16) []byte { return guild.EncodeFail(code) }

// Round 844: the request (0x70FB), its box (0x3080 kind 6), a "no" (0x4c2e),
// a "yes" forming the union (0x3102 to both, the requester's guild first),
// the 30 s wait (0x4c10), and the refusals of s:0x5c6550.
func TestRound844UnionRequest(t *testing.T) {
	u := startUnion844(t)
	ctx := context.Background()
	// Both guilds level 1: the requester's level first.
	u.send(t, u.connA, guild.OpUnionRequest, u32(u.bram))
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionRequestResult); !bytes.Equal(p.Data, failBytes(0x4c2a)) {
		t.Fatalf("own level 1: % x", p.Data)
	}
	u.level(t, u.aria, 2)
	u.send(t, u.connA, guild.OpUnionRequest, u32(u.bram))
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionRequestResult); !bytes.Equal(p.Data, failBytes(0x4c2b)) {
		t.Fatalf("target level 1: % x", p.Data)
	}
	u.level(t, u.bram, 2)
	// Hostile guilds (the war lane's test): 0x4c42.
	hostile := func(_ context.Context, a, b int64) bool { return true }
	unionHostile.Store(&hostile)
	u.send(t, u.connA, guild.OpUnionRequest, u32(u.bram))
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionRequestResult); !bytes.Equal(p.Data, failBytes(guild.CodeHostile)) {
		t.Fatalf("hostile: % x", p.Data)
	}
	unionHostile.Store(nil)
	// Not reachable: an id nobody has.
	u.send(t, u.connA, guild.OpUnionRequest, u32(999999))
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionRequestResult); !bytes.Equal(p.Data, failBytes(3)) {
		t.Fatalf("no target: % x", p.Data)
	}
	// The request: Bram's box, nothing to Aria; a second is busy (3).
	u.send(t, u.connA, guild.OpUnionRequest, u32(u.bram))
	box := nextOp(t, u.connB, u.rB, guild.OpRequest)
	if !bytes.Equal(box.Data, guild.EncodeUnionRequestBox(uint32(u.aria))) {
		t.Fatalf("the box: % x", box.Data)
	}
	u.send(t, u.connA, guild.OpUnionRequest, u32(u.bram))
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionRequestResult); !bytes.Equal(p.Data, failBytes(3)) {
		t.Fatalf("a second request: % x", p.Data)
	}
	// A "no" (the client's {2, u16 0}): 0x4c2e to Aria, no union.
	u.send(t, u.connB, party.OpInvitation, []byte{2, 0, 0})
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionRequestResult); !bytes.Equal(p.Data, failBytes(guild.CodeUnionRefused)) {
		t.Fatalf("refused: % x", p.Data)
	}
	if un, _ := u.guilds.UnionOf(ctx, u.alpha.ID); un != nil {
		t.Fatalf("a refused request formed %+v", un)
	}
	// The wait runs out: 0x4c10 to Aria.
	old := unionRequestTimeout
	unionRequestTimeout = 150 * time.Millisecond
	u.send(t, u.connA, guild.OpUnionRequest, u32(u.bram))
	nextOp(t, u.connB, u.rB, guild.OpRequest)
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionRequestResult); !bytes.Equal(p.Data, failBytes(guild.CodeInviteTimeout)) {
		t.Fatalf("timed out: % x", p.Data)
	}
	unionRequestTimeout = old
	// A "yes": the union, Alpha first; 0x3102 to both.
	u.send(t, u.connA, guild.OpUnionRequest, u32(u.bram))
	nextOp(t, u.connB, u.rB, guild.OpRequest)
	u.send(t, u.connB, party.OpInvitation, []byte{1, 1})
	info := nextOp(t, u.connA, u.rA, guild.OpUnionInfo)
	un, _ := u.guilds.UnionOf(ctx, u.beta.ID)
	if un == nil || un.LeaderGuildID() != u.alpha.ID || un.Slots[1] != u.beta.ID {
		t.Fatalf("formed: %+v", un)
	}
	if leader := binary.LittleEndian.Uint32(info.Data[8:]); int64(leader) != u.alpha.ID {
		t.Fatalf("0x3102's leader %d", leader)
	}
	nextOp(t, u.connB, u.rB, guild.OpUnionInfo)
	// Now Bram's Beta is in a union: Bram (not the union's first) asking
	// Aria gets 0x4c1e; Aria asking Bram, 0x4c28.
	u.send(t, u.connB, guild.OpUnionRequest, u32(u.aria))
	if p := nextOp(t, u.connB, u.rB, guild.OpUnionRequestResult); !bytes.Equal(p.Data, failBytes(0x4c1e)) {
		t.Fatalf("a member guild's master: % x", p.Data)
	}
	u.send(t, u.connA, guild.OpUnionRequest, u32(u.bram))
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionRequestResult); !bytes.Equal(p.Data, failBytes(0x4c28)) {
		t.Fatalf("a target already in a union: % x", p.Data)
	}
}

// Round 844: leave, expel and the union broken (sm:0x4369f0), and union chat.
func TestRound844UnionLeaveExpelChat(t *testing.T) {
	u := startUnion844(t)
	ctx := context.Background()
	gamma, err := u.guilds.Create(ctx, "Gamma", 7777, "Gil")
	if err != nil {
		t.Fatal(err)
	}
	form := func() {
		t.Helper()
		if _, err := u.guilds.JoinUnion(ctx, u.beta.ID, u.alpha.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := u.guilds.JoinUnion(ctx, gamma.ID, u.alpha.ID); err != nil {
			t.Fatal(err)
		}
	}
	// No union: leave 0x4c2f, chat 0x200c; no guild would be 0x200b.
	u.send(t, u.connA, guild.OpUnionLeave, nil)
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionLeaveResult); !bytes.Equal(p.Data, failBytes(guild.CodeNoUnion)) {
		t.Fatalf("no union: % x", p.Data)
	}
	u.send(t, u.connA, OpChatSend, (&ChatSendRequest{Type: ChatUnion, Index: 1, Message: "-Alpha): hi"}).Encode())
	if r, _ := DecodeChatResult(nextOp(t, u.connA, u.rA, OpChatResult).Data); r.OK || r.Code != 0x200c {
		t.Fatalf("chat with no union: %+v", r)
	}
	form()
	// Union chat both ways: each other's line, never one's own.
	u.send(t, u.connA, OpChatSend, (&ChatSendRequest{Type: ChatUnion, Index: 2, Message: "-Alpha): hi"}).Encode())
	if r, _ := DecodeChatResult(nextOp(t, u.connA, u.rA, OpChatResult).Data); !r.OK {
		t.Fatalf("chat: %+v", r)
	}
	if c, _ := DecodeChatUpdate(nextOp(t, u.connB, u.rB, OpChatUpdate).Data); c.Type != ChatUnion || c.Sender != "Aria" || c.Message != "-Alpha): hi" {
		t.Fatalf("Bram heard %+v", c)
	}
	noOp(t, u.connA, u.rA, OpChatUpdate)
	u.send(t, u.connB, OpChatSend, (&ChatSendRequest{Type: ChatUnion, Index: 3, Message: "-Beta): yo"}).Encode())
	if c, _ := DecodeChatUpdate(nextOp(t, u.connA, u.rA, OpChatUpdate).Data); c.Sender != "Bram" || c.Message != "-Beta): yo" {
		t.Fatalf("Aria heard %+v", c)
	}
	// Bram (Beta, not the first guild) expels: 0x4c1e; Aria a stranger: 0x4c30.
	u.send(t, u.connB, guild.OpUnionExpel, u32(gamma.ID))
	if p := nextOp(t, u.connB, u.rB, guild.OpUnionExpelResult); !bytes.Equal(p.Data, failBytes(0x4c1e)) {
		t.Fatalf("not the first guild: % x", p.Data)
	}
	u.send(t, u.connA, guild.OpUnionExpel, u32(424242))
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionExpelResult); !bytes.Equal(p.Data, failBytes(guild.CodeNotInUnion)) {
		t.Fatalf("not in the union: % x", p.Data)
	}
	// Aria expels Gamma: {0x12, 2, Gamma} to both, 0xB0FD {1}; two are left.
	u.send(t, u.connA, guild.OpUnionExpel, u32(gamma.ID))
	out := guild.EncodeUnionOut(guild.UnionOutExpelled, gamma.ID)
	if p := nextOp(t, u.connA, u.rA, guild.OpUpdate); !bytes.Equal(p.Data, out) {
		t.Fatalf("Aria told % x", p.Data)
	}
	if p := nextOp(t, u.connA, u.rA, guild.OpUnionExpelResult); !bytes.Equal(p.Data, guild.EncodeOK()) {
		t.Fatalf("expel reply % x", p.Data)
	}
	if p := nextOp(t, u.connB, u.rB, guild.OpUpdate); !bytes.Equal(p.Data, out) {
		t.Fatalf("Bram told % x", p.Data)
	}
	if un, _ := u.guilds.UnionOf(ctx, u.alpha.ID); un == nil || un.Count() != 2 {
		t.Fatalf("after the expel: %+v", un)
	}
	// Bram leaves the two-guild union: {1, Beta} to both, 0xB0FC {1} to him,
	// and the union broken: {3} to Aria.
	u.send(t, u.connB, guild.OpUnionLeave, nil)
	left := guild.EncodeUnionOut(guild.UnionOutLeft, u.beta.ID)
	if p := nextOp(t, u.connB, u.rB, guild.OpUpdate); !bytes.Equal(p.Data, left) {
		t.Fatalf("Bram told % x", p.Data)
	}
	if p := nextOp(t, u.connB, u.rB, guild.OpUnionLeaveResult); !bytes.Equal(p.Data, guild.EncodeOK()) {
		t.Fatalf("leave reply % x", p.Data)
	}
	if p := nextOp(t, u.connA, u.rA, guild.OpUpdate); !bytes.Equal(p.Data, left) {
		t.Fatalf("Aria told % x", p.Data)
	}
	broken := guild.EncodeUnionOut(guild.UnionOutBroken, 0)
	if p := nextOp(t, u.connA, u.rA, guild.OpUpdate); !bytes.Equal(p.Data, broken) {
		t.Fatalf("Aria not told it broke: % x", p.Data)
	}
	if un, _ := u.guilds.UnionOf(ctx, u.alpha.ID); un != nil {
		t.Fatalf("a one-guild union stands: %+v", un)
	}
	// Three again; the leader's guild leaves: broken, though two are left.
	form()
	u.send(t, u.connA, guild.OpUnionLeave, nil)
	lead := guild.EncodeUnionOut(guild.UnionOutLeft, u.alpha.ID)
	if p := nextOp(t, u.connB, u.rB, guild.OpUpdate); !bytes.Equal(p.Data, lead) {
		t.Fatalf("Bram told % x", p.Data)
	}
	if p := nextOp(t, u.connB, u.rB, guild.OpUpdate); !bytes.Equal(p.Data, broken) {
		t.Fatalf("Bram not told it broke: % x", p.Data)
	}
	for _, id := range []int64{u.alpha.ID, u.beta.ID, gamma.ID} {
		if un, _ := u.guilds.UnionOf(ctx, id); un != nil {
			t.Fatalf("guild %d still in %+v", id, un)
		}
	}
}

// Round 844: union chat's permission (0x04): Bram, a plain member of
// Aria's Alpha (in a union with Gamma), is refused 0x200e; Aria, the master,
// is heard by him.
func TestRound844UnionChatPermission(t *testing.T) {
	guilds := guild.NewMemStore()
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return gateway.Chain(testGuildHandler(t, chars, guilds, hub), ChatHandler(ChatDeps{Hub: hub, Guilds: guilds}))
	})
	ctx := context.Background()
	a, _ := guilds.Create(ctx, "Alpha", f.aria, "Aria")
	if _, err := guilds.Join(ctx, a.ID, f.bram, "Bram"); err != nil {
		t.Fatal(err)
	}
	gamma, _ := guilds.Create(ctx, "Gamma", 7777, "Gil")
	if _, err := guilds.JoinUnion(ctx, gamma.ID, a.ID); err != nil {
		t.Fatal(err)
	}
	f.send(t, f.connB, OpChatSend, (&ChatSendRequest{Type: ChatUnion, Index: 1, Message: "-Alpha): hi"}).Encode())
	if r, _ := DecodeChatResult(nextOp(t, f.connB, f.rB, OpChatResult).Data); r.OK || r.Code != ChatErrGuildUnionLimit {
		t.Fatalf("a member without the bit: %+v", r)
	}
	f.send(t, f.connA, OpChatSend, (&ChatSendRequest{Type: ChatUnion, Index: 2, Message: "-Alpha): all"}).Encode())
	if c, _ := DecodeChatUpdate(nextOp(t, f.connB, f.rB, OpChatUpdate).Data); c.Type != ChatUnion || c.Sender != "Aria" {
		t.Fatalf("Bram heard %+v", c)
	}
	if !memberPerm(&guild.Guild{Members: []guild.Member{{CharacterID: 5, Permission: guild.PermUnionChat}}}, 5).Has(guild.PermUnionChat) {
		t.Fatal("the bit is not union chat")
	}
}
