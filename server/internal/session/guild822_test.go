package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 822: the original's guild membership (guildops.go; READ addresses
// there): create 0x70F0, invite 0x70F3 and its 0x3080 answer, leave 0x70F2,
// expel 0x70F4, disband 0x70F1, the 0x38F5 updates and the 72 h penalty.

// nextOp reads conn until a packet with op arrives (the block messages and
// spawns in between are stepped over).
func nextOp(t *testing.T, conn net.Conn, r *bufio.Reader, op uint16) *proto.Packet {
	t.Helper()
	for {
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("waiting for %#04x: %v", op, err)
		}
		if p.Opcode == op {
			return p
		}
	}
}

// noOp reports that no packet with op arrives within 300 ms.
func noOp(t *testing.T, conn net.Conn, r *bufio.Reader, op uint16) {
	t.Helper()
	deadline := time.Now().Add(300 * time.Millisecond)
	for {
		conn.SetReadDeadline(deadline)
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			return
		}
		if p.Opcode == op {
			t.Fatalf("unexpected %#04x % x", op, p.Data)
		}
	}
}

type guild822 struct {
	*deadWorldFixture
	guilds *guild.MemStore
	npc    uint32
}

func startGuild822(t *testing.T) *guild822 {
	t.Helper()
	guilds := guild.NewMemStore()
	keeper := npcAt(9, 100, 0, npcspawn.FromNest)
	keeper.Code = "NPC_T_GUILD"
	keeper.Flags, keeper.Interact = npcspawn.FlagInteractions, []byte{guildNPCInteraction}
	installNPCsForTest(t, keeper)
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return gateway.Chain(testGuildHandler(t, chars, guilds, hub),
			PartyHandler(PartyDeps{Chars: chars, Hub: hub, Parties: party.NewHub()}))
	})
	ea, _ := f.hub.FindByName("Aria")
	if ea.Zone != "jangan" {
		t.Skipf("the test NPC stands in the jangan frame; the world put Aria in %q", ea.Zone)
	}
	eb, _ := f.hub.FindByName("Bram")
	f.hub.Relocate(ea.Session, world.Position{X: 50, Z: 0}, world.MoveRelocate, 0)
	f.hub.Relocate(eb.Session, world.Position{X: 55, Z: 0}, world.MoveRelocate, 0)
	return &guild822{deadWorldFixture: f, guilds: guilds, npc: keeper.UID}
}

func (g *guild822) create(t *testing.T, conn net.Conn, r *bufio.Reader, id int64, name string) []byte {
	t.Helper()
	c, _ := g.chars.GetByID(context.Background(), id)
	qualifyFounder(t, g.chars, c)
	b := binary.LittleEndian.AppendUint32(nil, g.npc)
	b = binary.LittleEndian.AppendUint16(b, uint16(len(name)))
	g.send(t, conn, guild.OpCreate, append(b, name...))
	return nextOp(t, conn, r, guild.OpCreateResult).Data
}

func uidBytes(id int64) []byte { return binary.LittleEndian.AppendUint32(nil, uint32(id)) }

func TestGuild822InviteAcceptLeaveExpelDisband(t *testing.T) {
	g := startGuild822(t)
	ctx := context.Background()
	res := g.create(t, g.connA, g.rA, g.aria, "Verizon")
	if res[0] != 1 || binary.LittleEndian.Uint32(res[1:]) == 0 {
		t.Fatalf("create % x", res)
	}

	// Aria invites Bram: he gets the question, she gets nothing.
	g.send(t, g.connA, guild.OpInvite, uidBytes(g.bram))
	q := nextOp(t, g.connB, g.rB, guild.OpRequest).Data
	if q[0] != guild.RequestGuildInvite || binary.LittleEndian.Uint32(q[1:]) != uint32(g.aria) || len(q) != 5 {
		t.Fatalf("invitation % x", q)
	}
	noOp(t, g.connA, g.rA, guild.OpInviteResult)
	// Yes: Bram gets the block, Aria his record and "joined".
	g.send(t, g.connB, guild.OpRequest, []byte{1, 1})
	nextOp(t, g.connB, g.rB, guild.OpBlockEnd)
	add := nextOp(t, g.connA, g.rA, guild.OpUpdate).Data
	if add[0] != guild.UpdateMemberAdd || binary.LittleEndian.Uint32(add[1:]) != uint32(g.bram) {
		t.Fatalf("member add % x", add)
	}
	on := nextOp(t, g.connA, g.rA, guild.OpUpdate).Data
	if on[0] != guild.UpdateMember || on[5] != guild.MemberFieldOffline || on[6] != 0 {
		t.Fatalf("joined (online) % x", on)
	}
	if gg, _ := g.guilds.GetByCharacter(ctx, g.bram); gg == nil || len(gg.Members) != 2 {
		t.Fatalf("Bram's guild %+v", gg)
	}

	// The master's leave: no reply at all (s:0x515070).
	g.send(t, g.connA, guild.OpLeave, uidBytes(int64(g.npc)))
	noOp(t, g.connA, g.rA, guild.OpLeaveResult)

	// Bram leaves: {1}, type 3 reason 1 to both, his penalty.
	g.send(t, g.connB, guild.OpLeave, uidBytes(int64(g.npc)))
	if r := nextOp(t, g.connB, g.rB, guild.OpLeaveResult).Data; r[0] != 1 {
		t.Fatalf("leave % x", r)
	}
	for _, c := range []struct {
		conn net.Conn
		r    *bufio.Reader
	}{{g.connA, g.rA}, {g.connB, g.rB}} {
		u := nextOp(t, c.conn, c.r, guild.OpUpdate).Data
		if u[0] != guild.UpdateMemberOut || binary.LittleEndian.Uint32(u[1:]) != uint32(g.bram) || u[5] != guild.RemovedLeft {
			t.Fatalf("left % x", u)
		}
	}
	if until, _ := g.guilds.PenaltyUntil(ctx, g.bram); time.Until(until) < guild.PenaltyDuration-time.Minute {
		t.Fatalf("Bram's penalty %v", until)
	}
	// Invited again: the penalty refuses (0x4c3d).
	g.send(t, g.connA, guild.OpInvite, uidBytes(g.bram))
	if r := nextOp(t, g.connA, g.rA, guild.OpInviteResult).Data; r[0] != 2 || binary.LittleEndian.Uint16(r[1:]) != guild.CodeJoinPenalty {
		t.Fatalf("invite a penalised character % x", r)
	}
	// And a founding by him: {2, 0x4c3c, u32 seconds left}.
	pen := g.create(t, g.connB, g.rB, g.bram, "Other")
	if pen[0] != 2 || binary.LittleEndian.Uint16(pen[1:]) != guild.CodeCreatePenalty || binary.LittleEndian.Uint32(pen[3:]) < 259000 {
		t.Fatalf("a penalised founding % x", pen)
	}

	// Lift the penalty; join again; Aria expels him by name.
	_ = g.guilds.SetPenalty(ctx, g.bram, time.Time{})
	g.send(t, g.connA, guild.OpInvite, uidBytes(g.bram))
	nextOp(t, g.connB, g.rB, guild.OpRequest)
	g.send(t, g.connB, guild.OpRequest, []byte{1, 1})
	nextOp(t, g.connB, g.rB, guild.OpBlockEnd)
	g.send(t, g.connA, guild.OpExpel, append([]byte{4, 0}, "bram"...))
	if r := nextOp(t, g.connA, g.rA, guild.OpExpelResult).Data; r[0] != 1 {
		t.Fatalf("expel % x", r)
	}
	if u := nextOp(t, g.connB, g.rB, guild.OpUpdate).Data; u[0] != guild.UpdateMemberOut || u[5] != guild.RemovedExpelled {
		t.Fatalf("expelled % x", u)
	}
	// Expelling oneself: 0x4c36.
	g.send(t, g.connA, guild.OpExpel, append([]byte{4, 0}, "Aria"...))
	if r := nextOp(t, g.connA, g.rA, guild.OpExpelResult).Data; binary.LittleEndian.Uint16(r[1:]) != guild.CodeExpelSelf {
		t.Fatalf("expel self % x", r)
	}

	// Disband: {1}, type 1, the guild gone, the master's penalty.
	g.send(t, g.connA, guild.OpDisband, uidBytes(int64(g.npc)))
	if r := nextOp(t, g.connA, g.rA, guild.OpDisbandResult).Data; r[0] != 1 {
		t.Fatalf("disband % x", r)
	}
	if u := nextOp(t, g.connA, g.rA, guild.OpUpdate).Data; len(u) != 1 || u[0] != guild.UpdateDisbanded {
		t.Fatalf("disbanded % x", u)
	}
	if _, err := g.guilds.GetByCharacter(ctx, g.aria); err == nil {
		t.Fatal("Aria still in a guild")
	}
	if until, _ := g.guilds.PenaltyUntil(ctx, g.aria); until.IsZero() {
		t.Fatal("no penalty for the master")
	}
}

func TestGuild822InviteRefusedAndTimedOut(t *testing.T) {
	g := startGuild822(t)
	g.create(t, g.connA, g.rA, g.aria, "Verizon")
	// No: 0x4c16 to both.
	g.send(t, g.connA, guild.OpInvite, uidBytes(g.bram))
	nextOp(t, g.connB, g.rB, guild.OpRequest)
	g.send(t, g.connB, guild.OpRequest, []byte{2, 0x16, 0x4c})
	if r := nextOp(t, g.connA, g.rA, guild.OpInviteResult).Data; binary.LittleEndian.Uint16(r[1:]) != guild.CodeJoinRefused {
		t.Fatalf("inviter % x", r)
	}
	if r := nextOp(t, g.connB, g.rB, guild.OpJoinResult).Data; binary.LittleEndian.Uint16(r[1:]) != guild.CodeJoinRefused {
		t.Fatalf("invitee % x", r)
	}
	// No answer: 0x4c10 to both.
	old := guildInviteTimeout
	guildInviteTimeout = 100 * time.Millisecond
	t.Cleanup(func() { guildInviteTimeout = old })
	g.send(t, g.connA, guild.OpInvite, uidBytes(g.bram))
	nextOp(t, g.connB, g.rB, guild.OpRequest)
	if r := nextOp(t, g.connA, g.rA, guild.OpInviteResult).Data; binary.LittleEndian.Uint16(r[1:]) != guild.CodeInviteTimeout {
		t.Fatalf("timeout inviter % x", r)
	}
	if r := nextOp(t, g.connB, g.rB, guild.OpJoinResult).Data; binary.LittleEndian.Uint16(r[1:]) != guild.CodeInviteTimeout {
		t.Fatalf("timeout invitee % x", r)
	}
	// Bram, no permission bit, cannot invite (he is not in a guild: nothing).
	g.send(t, g.connB, guild.OpInvite, uidBytes(g.aria))
	noOp(t, g.connB, g.rB, guild.OpInviteResult)
}
