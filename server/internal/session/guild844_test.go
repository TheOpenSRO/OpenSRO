package session

import (
	"context"
	"encoding/binary"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
)

// Round 844 (lane G): the notice 0x70F9, the permissions 0x7104, the master's
// hand-over 0x7103, the SP donation 0x7258 and the level-up 0x70FA, two
// clients in one world (guildmanage.go has the READ addresses).

func str844(s string) []byte {
	return append(binary.LittleEndian.AppendUint16(nil, uint16(len(s))), s...)
}

// guild844 founds Verizon with Aria and brings Bram in.
func guild844(t *testing.T) *guild822 {
	t.Helper()
	g := startGuild822(t)
	if res := g.create(t, g.connA, g.rA, g.aria, "Verizon"); res[0] != 1 {
		t.Fatalf("create % x", res)
	}
	g.send(t, g.connA, guild.OpInvite, uidBytes(g.bram))
	nextOp(t, g.connB, g.rB, guild.OpRequest)
	g.send(t, g.connB, guild.OpRequest, []byte{1, 1})
	nextOp(t, g.connB, g.rB, guild.OpBlockEnd)
	nextOp(t, g.connA, g.rA, guild.OpUpdate) // type 2
	nextOp(t, g.connA, g.rA, guild.OpUpdate) // type 6 online
	return g
}

func TestGuild844Notice(t *testing.T) {
	g := guild844(t)
	ctx := context.Background()
	// Bram has no notice bit: 0x4c1e.
	g.send(t, g.connB, guild.OpNotice, append(str844("Hi"), str844("Body")...))
	if r := nextOp(t, g.connB, g.rB, guild.OpNoticeResult).Data; r[0] != 2 || binary.LittleEndian.Uint16(r[1:]) != 0x4c1e {
		t.Fatalf("no bit % x", r)
	}
	// A quote: dropped, no reply.
	g.send(t, g.connA, guild.OpNotice, append(str844("it's"), str844("Body")...))
	noOp(t, g.connA, g.rA, guild.OpNoticeResult)
	// Too long a title (129 bytes): 0x4c22.
	long := make([]byte, 129)
	for i := range long {
		long[i] = 'a'
	}
	g.send(t, g.connA, guild.OpNotice, append(str844(string(long)), str844("Body")...))
	if r := nextOp(t, g.connA, g.rA, guild.OpNoticeResult).Data; r[0] != 2 || binary.LittleEndian.Uint16(r[1:]) != 0x4c22 {
		t.Fatalf("long title % x", r)
	}
	g.send(t, g.connA, guild.OpNotice, append(str844("Raid"), str844("")...))
	if r := nextOp(t, g.connA, g.rA, guild.OpNoticeResult).Data; r[0] != 2 || binary.LittleEndian.Uint16(r[1:]) != 0x4c23 {
		t.Fatalf("empty body % x", r)
	}
	// The master writes it: {1}, both get type 5 mask 0x10.
	g.send(t, g.connA, guild.OpNotice, append(str844("Raid"), str844("Tonight at nine")...))
	if r := nextOp(t, g.connA, g.rA, guild.OpNoticeResult).Data; len(r) != 1 || r[0] != 1 {
		t.Fatalf("notice % x", r)
	}
	want := guild.EncodeGuildFields(guild.GuildFieldNotice, &guild.Guild{NoticeTitle: "Raid", NoticeBody: "Tonight at nine"})
	if u := nextOp(t, g.connB, g.rB, guild.OpUpdate).Data; string(u) != string(want) {
		t.Fatalf("Bram's update % x, want % x", u, want)
	}
	if gg, _ := g.guilds.GetByCharacter(ctx, g.aria); gg.NoticeTitle != "Raid" || gg.NoticeBody != "Tonight at nine" {
		t.Fatalf("stored %+v", gg)
	}
}

func TestGuild844Permissions(t *testing.T) {
	g := guild844(t)
	ctx := context.Background()
	req := func(id int64, mask uint32) []byte {
		b := []byte{1}
		b = binary.LittleEndian.AppendUint32(b, uint32(id))
		return binary.LittleEndian.AppendUint32(b, mask)
	}
	// Bram is not the master.
	g.send(t, g.connB, guild.OpPermission, req(g.aria, 0))
	if r := nextOp(t, g.connB, g.rB, guild.OpPermissionResult).Data; r[0] != 2 || binary.LittleEndian.Uint16(r[1:]) != 0x4c1e {
		t.Fatalf("not master % x", r)
	}
	// Aria gives Bram invite + notice.
	g.send(t, g.connA, guild.OpPermission, req(g.bram, uint32(guild.PermInvite|guild.PermNotice)))
	if r := nextOp(t, g.connA, g.rA, guild.OpPermissionResult).Data; len(r) != 1 || r[0] != 1 {
		t.Fatalf("permissions % x", r)
	}
	// The master: type 0x16 mask 0x10.
	u := nextOp(t, g.connA, g.rA, guild.OpUpdate).Data
	if u[0] != guild.UpdateMembersField || u[1] != 1 || u[2] != guild.MemberFieldPerm ||
		binary.LittleEndian.Uint32(u[3:]) != uint32(g.bram) || binary.LittleEndian.Uint32(u[7:]) != 0x11 {
		t.Fatalf("master's 0x16 % x", u)
	}
	// Bram: type 6 mask 0x10, then type 0x14.
	u = nextOp(t, g.connB, g.rB, guild.OpUpdate).Data
	if u[0] != guild.UpdateMember || u[5] != guild.MemberFieldPerm || binary.LittleEndian.Uint32(u[6:]) != 0x11 {
		t.Fatalf("Bram's type 6 % x", u)
	}
	u = nextOp(t, g.connB, g.rB, guild.OpUpdate).Data
	if u[0] != guild.UpdatePermissions || u[1] != 1 || binary.LittleEndian.Uint32(u[6:]) != 0x11 {
		t.Fatalf("type 0x14 % x", u)
	}
	if gg, _ := g.guilds.GetByCharacter(ctx, g.bram); memberPerm(gg, g.bram) != 0x11 {
		t.Fatalf("stored %+v", gg)
	}
	// Bram may now write the notice.
	g.send(t, g.connB, guild.OpNotice, append(str844("Bram"), str844("was here")...))
	if r := nextOp(t, g.connB, g.rB, guild.OpNoticeResult).Data; r[0] != 1 {
		t.Fatalf("Bram's notice % x", r)
	}
}

func TestGuild844UnionChatCap(t *testing.T) {
	g := &guild.Guild{LeaderID: 1}
	var changes []guild.PermissionChange
	for i := int64(2); i <= 14; i++ {
		g.Members = append(g.Members, guild.Member{CharacterID: i})
		changes = append(changes, guild.PermissionChange{CharacterID: i, Permission: guild.PermUnionChat})
	}
	if n := unionChatHolders(g, changes); n != 13 {
		t.Fatalf("13 holders, got %d", n)
	}
	if n := unionChatHolders(g, changes[:12]); n != 12 {
		t.Fatalf("12 holders, got %d", n)
	}
}

func TestGuild844HandOver(t *testing.T) {
	g := guild844(t)
	ctx := context.Background()
	req := func(to int64) []byte {
		return binary.LittleEndian.AppendUint32(binary.LittleEndian.AppendUint32(nil, g.npc), uint32(to))
	}
	// To himself: 3. Bram (not master): 0x4c1e. A stranger: 0x4c1d.
	g.send(t, g.connA, guild.OpHandOver, req(g.aria))
	if r := nextOp(t, g.connA, g.rA, guild.OpHandOverResult).Data; binary.LittleEndian.Uint16(r[1:]) != 3 {
		t.Fatalf("self % x", r)
	}
	g.send(t, g.connB, guild.OpHandOver, req(g.aria))
	if r := nextOp(t, g.connB, g.rB, guild.OpHandOverResult).Data; binary.LittleEndian.Uint16(r[1:]) != 0x4c1e {
		t.Fatalf("not master % x", r)
	}
	g.send(t, g.connA, guild.OpHandOver, req(987654))
	if r := nextOp(t, g.connA, g.rA, guild.OpHandOverResult).Data; binary.LittleEndian.Uint16(r[1:]) != 0x4c1d {
		t.Fatalf("stranger % x", r)
	}
	g.send(t, g.connA, guild.OpHandOver, req(g.bram))
	if r := nextOp(t, g.connA, g.rA, guild.OpHandOverResult).Data; len(r) != 1 || r[0] != 1 {
		t.Fatalf("hand-over % x", r)
	}
	// Both: type 0x16 mask 0x54 {new: class 0, perm all, siege 1} {old: 10, 0, 0}.
	want := []byte{guild.UpdateMembersField, 2, 0x54}
	want = binary.LittleEndian.AppendUint32(want, uint32(g.bram))
	want = append(want, 0, 0xff, 0xff, 0xff, 0xff, 1)
	want = binary.LittleEndian.AppendUint32(want, uint32(g.aria))
	want = append(want, 10, 0, 0, 0, 0, 0)
	if u := nextOp(t, g.connA, g.rA, guild.OpUpdate).Data; string(u) != string(want) {
		t.Fatalf("Aria's 0x16 % x want % x", u, want)
	}
	if u := nextOp(t, g.connB, g.rB, guild.OpUpdate).Data; string(u) != string(want) {
		t.Fatalf("Bram's 0x16 % x", u)
	}
	// Bram (new master) gets the others' permissions.
	if u := nextOp(t, g.connB, g.rB, guild.OpUpdate).Data; u[0] != guild.UpdateMembersField || u[2] != guild.MemberFieldPerm ||
		binary.LittleEndian.Uint32(u[3:]) != uint32(g.aria) {
		t.Fatalf("the list % x", u)
	}
	gg, _ := g.guilds.GetByCharacter(ctx, g.aria)
	if gg.LeaderID != g.bram {
		t.Fatalf("leader %+v", gg)
	}
	// Aria can now leave (no longer the master): {1}.
	g.send(t, g.connA, guild.OpLeave, uidBytes(int64(g.npc)))
	if r := nextOp(t, g.connA, g.rA, guild.OpLeaveResult).Data; r[0] != 1 {
		t.Fatalf("old master's leave % x", r)
	}
}

func TestGuild844Donate(t *testing.T) {
	g := guild844(t)
	ctx := context.Background()
	sp := skill.NewMemStore()
	SetGuildDonateSkills(sp)
	t.Cleanup(func() { SetGuildDonateSkills(nil) })
	if _, err := sp.AddSkillPoints(ctx, g.bram, 100); err != nil {
		t.Fatal(err)
	}
	amt := func(n uint32) []byte { return binary.LittleEndian.AppendUint32(nil, n) }
	g.send(t, g.connB, guild.OpDonate, amt(0))
	if r := nextOp(t, g.connB, g.rB, guild.OpDonateResult).Data; binary.LittleEndian.Uint16(r[1:]) != 2 {
		t.Fatalf("zero % x", r)
	}
	g.send(t, g.connB, guild.OpDonate, amt(101))
	if r := nextOp(t, g.connB, g.rB, guild.OpDonateResult).Data; binary.LittleEndian.Uint16(r[1:]) != 0x4c32 {
		t.Fatalf("short % x", r)
	}
	g.send(t, g.connB, guild.OpDonate, amt(40))
	if r := nextOp(t, g.connB, g.rB, guild.OpDonateResult).Data; r[0] != 1 || binary.LittleEndian.Uint32(r[1:]) != 40 {
		t.Fatalf("donate % x", r)
	}
	if left, _ := sp.SkillPoints(ctx, g.bram); left != 60 {
		t.Fatalf("SP left %d", left)
	}
	gg, _ := g.guilds.GetByCharacter(ctx, g.bram)
	m, _ := memberOf(gg, g.bram)
	if gg.GatheredSP != 40 || m.GPDonation != 40 {
		t.Fatalf("GP %d / %d", gg.GatheredSP, m.GPDonation)
	}
	u := nextOp(t, g.connA, g.rA, guild.OpUpdate).Data
	if u[0] != guild.UpdateGuild || u[1] != guild.GuildFieldGP || binary.LittleEndian.Uint32(u[2:]) != 40 {
		t.Fatalf("type 5 % x", u)
	}
}

func TestGuild844LevelUpNPC(t *testing.T) {
	g := guild844(t)
	ctx := context.Background()
	npc := binary.LittleEndian.AppendUint32(nil, g.npc)
	// Not enough GP yet: 0x4c32 after the gold check passes.
	if err := g.chars.AddGold(ctx, g.aria, 3_000_000); err != nil {
		t.Fatal(err)
	}
	g.send(t, g.connA, guild.OpLevelUp, npc)
	if r := nextOp(t, g.connA, g.rA, guild.OpLevelUpResult).Data; binary.LittleEndian.Uint16(r[1:]) != 0x4c32 {
		t.Fatalf("GP short % x", r)
	}
	gg, _ := g.guilds.GetByCharacter(ctx, g.aria)
	if err := g.guilds.AddPoints(ctx, gg.ID, g.aria, 5400); err != nil {
		t.Fatal(err)
	}
	// Bram is not the master.
	g.send(t, g.connB, guild.OpLevelUp, npc)
	if r := nextOp(t, g.connB, g.rB, guild.OpLevelUpResult).Data; binary.LittleEndian.Uint16(r[1:]) != 0x4c1e {
		t.Fatalf("not master % x", r)
	}
	// A wrong NPC: 3.
	g.send(t, g.connA, guild.OpLevelUp, binary.LittleEndian.AppendUint32(nil, 0xdead))
	if r := nextOp(t, g.connA, g.rA, guild.OpLevelUpResult).Data; binary.LittleEndian.Uint16(r[1:]) != 3 {
		t.Fatalf("NPC % x", r)
	}
	g.send(t, g.connA, guild.OpLevelUp, npc)
	if r := nextOp(t, g.connA, g.rA, guild.OpLevelUpResult).Data; len(r) != 1 || r[0] != 1 {
		t.Fatalf("level-up % x", r)
	}
	u := nextOp(t, g.connB, g.rB, guild.OpUpdate).Data
	if u[0] != guild.UpdateGuild || u[1] != guild.GuildFieldLevel|guild.GuildFieldGP || u[2] != 2 {
		t.Fatalf("type 5 % x", u)
	}
}
