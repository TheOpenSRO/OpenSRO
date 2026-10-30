package session

import (
	"context"
	"encoding/binary"
	"fmt"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 844 lane G (part 2): the "Give authority" pane's bit 0x04 is what
// lane U's union chat asks for (unionChat: the master or PermUnionChat, else
// 0x200e), and the pane's 13th holder is refused 0x4c4b (s:0x5c4b42).
func TestGuild844PermissionGivesUnionChat(t *testing.T) {
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
	say := func() *ChatResult {
		f.send(t, f.connB, OpChatSend, (&ChatSendRequest{Type: ChatUnion, Index: 1, Message: "-Alpha): hi"}).Encode())
		r, _ := DecodeChatResult(nextOp(t, f.connB, f.rB, OpChatResult).Data)
		return r
	}
	if r := say(); r.OK || r.Code != ChatErrGuildUnionLimit {
		t.Fatalf("without the bit: %+v", r)
	}
	// The master ticks Bram's Union box and confirms: 0x7104.
	req := []byte{1}
	req = binary.LittleEndian.AppendUint32(req, uint32(f.bram))
	req = binary.LittleEndian.AppendUint32(req, uint32(guild.PermUnionChat))
	f.send(t, f.connA, guild.OpPermission, req)
	if r := nextOp(t, f.connA, f.rA, guild.OpPermissionResult).Data; len(r) != 1 || r[0] != 1 {
		t.Fatalf("0x7104 % x", r)
	}
	if r := say(); !r.OK {
		t.Fatalf("with the bit: %+v", r)
	}
	// Twelve more holders: the 13th is refused.
	for i := 0; i < 12; i++ {
		if _, err := guilds.Join(ctx, a.ID, int64(9000+i), fmt.Sprintf("M%d", i)); err != nil {
			// The level-1 cap is 15 members.
			t.Fatalf("join %d: %v", i, err)
		}
	}
	req = []byte{12}
	for i := 0; i < 12; i++ {
		req = binary.LittleEndian.AppendUint32(req, uint32(9000+i))
		req = binary.LittleEndian.AppendUint32(req, uint32(guild.PermUnionChat))
	}
	f.send(t, f.connA, guild.OpPermission, req)
	if r := nextOp(t, f.connA, f.rA, guild.OpPermissionResult).Data; r[0] != 2 || binary.LittleEndian.Uint16(r[1:]) != guild.CodeUnionChatFull {
		t.Fatalf("13 holders % x", r)
	}
}
