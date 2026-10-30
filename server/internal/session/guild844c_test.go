package session

import (
	"context"
	"encoding/binary"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
)

// Round 844 lane G (part 2): the master-release vote, the GP history, the
// recall's ask and answer (guildvote.go, guildgphistory.go, guildrecall.go).

func u32le(v uint32) []byte { return binary.LittleEndian.AppendUint32(nil, v) }

// absentMasterGuild makes a guild whose master (7777) is offline and last
// logged out daysAgo days ago, with Aria and Bram members.
func absentMasterGuild(t *testing.T, g *guild822, daysAgo int) *guild.Guild {
	t.Helper()
	ctx := context.Background()
	gg, err := g.guilds.Create(ctx, "Absent", 7777, "Gone")
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{g.aria, g.bram} {
		name := "Aria"
		if id == g.bram {
			name = "Bram"
		}
		if _, err := g.guilds.Join(ctx, gg.ID, id, name); err != nil {
			t.Fatal(err)
		}
	}
	if err := g.guilds.SetLastLogout(ctx, 7777, time.Now().Add(-time.Duration(daysAgo)*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	return gg
}

func TestGuild844VoteRefusals(t *testing.T) {
	g := startGuild822(t)
	gg := absentMasterGuild(t, g, 10)
	npc := u32le(g.npc)
	// The master away only 10 days: 0x4c33.
	g.send(t, g.connA, OpVoteStart, npc)
	if r := nextOp(t, g.connA, g.rA, OpVoteStartResult).Data; r[0] != 2 || binary.LittleEndian.Uint16(r[1:]) != CodeVoteNotTime {
		t.Fatalf("10 days % x", r)
	}
	// An unknown vote: 0x5006.
	g.send(t, g.connA, OpVoteState, u32le(999))
	if r := nextOp(t, g.connA, g.rA, OpVoteStateResult).Data; binary.LittleEndian.Uint16(r[1:]) != CodeVoteUnknown {
		t.Fatalf("unknown % x", r)
	}
	_ = gg
}

func TestGuild844VoteWins(t *testing.T) {
	g := startGuild822(t)
	gg := absentMasterGuild(t, g, 50)
	t.Cleanup(func() { guildVoteDisbanded(gg.ID) })
	npc := u32le(g.npc)
	g.send(t, g.connB, OpVoteStart, npc)
	if r := nextOp(t, g.connB, g.rB, OpVoteStartResult).Data; len(r) != 1 || r[0] != 1 {
		t.Fatalf("start % x", r)
	}
	k1 := nextOp(t, g.connA, g.rA, OpVoteUpdate).Data
	if k1[0] != VoteKindStarted || k1[5] != 0 || binary.LittleEndian.Uint32(k1[6:]) != 600000 {
		t.Fatalf("kind 1 % x", k1)
	}
	id := binary.LittleEndian.Uint32(k1[1:])
	nextOp(t, g.connB, g.rB, OpVoteUpdate)
	// A second start: 0x4c37.
	g.send(t, g.connA, OpVoteStart, npc)
	if r := nextOp(t, g.connA, g.rA, OpVoteStartResult).Data; binary.LittleEndian.Uint16(r[1:]) != CodeVoteRunning {
		t.Fatalf("second % x", r)
	}
	// The state: two on the list, in member order (Aria, Bram).
	g.send(t, g.connA, OpVoteState, u32le(id))
	st := nextOp(t, g.connA, g.rA, OpVoteStateResult).Data
	if st[0] != 1 || st[9] != 2 || binary.LittleEndian.Uint32(st[10:]) != uint32(g.aria) || binary.LittleEndian.Uint32(st[15:]) != uint32(g.bram) {
		t.Fatalf("state % x", st)
	}
	// Bram cannot leave while listed: 0x4c38.
	g.send(t, g.connB, 0x70F2, npc)
	if r := nextOp(t, g.connB, g.rB, 0xB0F2).Data; binary.LittleEndian.Uint16(r[1:]) != CodeVoteLeave {
		t.Fatalf("leave % x", r)
	}
	ballot := func(conn int, idx byte) {
		b := append(append([]byte{}, npc...), u32le(id)...)
		b = append(b, idx)
		if conn == 0 {
			g.send(t, g.connA, OpVoteBallot, b)
		} else {
			g.send(t, g.connB, OpVoteBallot, b)
		}
	}
	// Bram for Aria (index 0): 1 of 2, 50 %: kind 4 only.
	ballot(1, 0)
	k4 := nextOp(t, g.connA, g.rA, OpVoteUpdate).Data
	if k4[0] != VoteKindBallot || k4[5] != 0xff || k4[6] != 0 || k4[7] != 1 {
		t.Fatalf("kind 4 % x", k4)
	}
	// Aria for herself: 2 of 2: kind 4, kind 3 {id, 1, Aria}, the hand-over.
	ballot(0, 0)
	nextOp(t, g.connA, g.rA, OpVoteUpdate) // kind 4
	k3 := nextOp(t, g.connA, g.rA, OpVoteUpdate).Data
	if k3[0] != VoteKindEnded || k3[5] != VoteResultWon || binary.LittleEndian.Uint32(k3[6:]) != uint32(g.aria) {
		t.Fatalf("kind 3 % x", k3)
	}
	u := nextOp(t, g.connA, g.rA, 0x38F5).Data
	if u[0] != guild.UpdateMembersField || u[2] != 0x54 {
		t.Fatalf("the hand-over % x", u)
	}
	if after, _ := g.guilds.Get(context.Background(), gg.ID); after.LeaderID != g.aria {
		t.Fatalf("the new master %d", after.LeaderID)
	}
	if voteOfGuild(gg.ID) != nil {
		t.Fatal("the vote stays")
	}
}

func TestGuild844VoteTimesOut(t *testing.T) {
	g := startGuild822(t)
	gg := absentMasterGuild(t, g, 45)
	old := voteTickEvery
	voteTickEvery = 20 * time.Millisecond
	t.Cleanup(func() { voteTickEvery = old; guildVotes.now = time.Now; guildVoteDisbanded(gg.ID) })
	start := time.Now()
	guildVotes.now = func() time.Time { return start }
	g.send(t, g.connA, OpVoteStart, u32le(g.npc))
	if r := nextOp(t, g.connA, g.rA, OpVoteStartResult).Data; r[0] != 1 {
		t.Fatalf("45 days exactly starts % x", r)
	}
	nextOp(t, g.connA, g.rA, OpVoteUpdate) // kind 1
	guildVotes.now = func() time.Time { return start.Add(guild.VoteDuration + time.Second) }
	k3 := nextOp(t, g.connA, g.rA, OpVoteUpdate).Data
	for k3[0] == VoteKindTime {
		k3 = nextOp(t, g.connA, g.rA, OpVoteUpdate).Data
	}
	if k3[0] != VoteKindEnded || k3[5] != VoteResultBroken {
		t.Fatalf("broken % x", k3)
	}
	if after, _ := g.guilds.Get(context.Background(), gg.ID); after.LeaderID != 7777 {
		t.Fatal("the master changed")
	}
}

func TestGuild844VoteRules(t *testing.T) {
	cases := []struct {
		votes, n int
		win      bool
	}{{3, 5, true}, {2, 5, false}, {6, 10, true}, {5, 10, false}, {30, 50, true}, {1, 1, true}}
	for _, c := range cases {
		if guild.VoteWins(c.votes, c.n) != c.win {
			t.Errorf("VoteWins(%d, %d)", c.votes, c.n)
		}
	}
	now := time.Date(2026, 10, 30, 1, 0, 0, 0, time.UTC)
	if d := guild.DaysSince(time.Date(2026, 9, 15, 23, 0, 0, 0, time.UTC), now); d != 45 {
		t.Errorf("DaysSince %d", d)
	}
}

func TestGuild844GPHistory(t *testing.T) {
	g := guild844(t)
	ctx := context.Background()
	gg, _ := g.guilds.GetByCharacter(ctx, g.aria)
	if err := g.guilds.AddPoints(ctx, gg.ID, g.aria, 5400); err != nil {
		t.Fatal(err)
	}
	if err := g.chars.AddGold(ctx, g.aria, 3_000_000); err != nil {
		t.Fatal(err)
	}
	g.send(t, g.connA, guild.OpLevelUp, u32le(g.npc))
	nextOp(t, g.connA, g.rA, guild.OpLevelUpResult)
	// Bram (a member, no rank needed) reads it.
	g.send(t, g.connB, OpGPHistory, u32le(g.npc))
	r := nextOp(t, g.connB, g.rB, OpGPHistoryResult).Data
	if r[0] != 1 || r[1] != 1 {
		t.Fatalf("history % x", r)
	}
	n := int(binary.LittleEndian.Uint16(r[6:]))
	name := string(r[8 : 8+n])
	gp := binary.LittleEndian.Uint32(r[8+n:])
	if name != "Aria" || gp != 5400 || r[12+n] != guild.GPUseGuildGrowth {
		t.Fatalf("entry %q %d %d", name, gp, r[12+n])
	}
	// No guild NPC: 3.
	g.send(t, g.connB, OpGPHistory, u32le(0xdead))
	if r := nextOp(t, g.connB, g.rB, OpGPHistoryResult).Data; binary.LittleEndian.Uint16(r[1:]) != 3 {
		t.Fatalf("NPC % x", r)
	}
}

func TestGuild844RecallAnswer(t *testing.T) {
	g := guild844(t)
	// An answer for no job: B031 {1} and nothing else (READ: the answer is
	// not tested; a gone job is dropped).
	b := append(u32le(4242), u32le(uint32(g.aria))...)
	g.send(t, g.connB, OpRecallAnswer, append(b, 1))
	if r := nextOp(t, g.connB, g.rB, OpRecallAnswerResult).Data; len(r) != 1 || r[0] != 1 {
		t.Fatalf("B031 % x", r)
	}
}

func TestGuild844GPHistoryStores(t *testing.T) {
	ctx := context.Background()
	for _, s := range []interface {
		guild.GPHistoryStore
		guild.Store
	}{guild.NewMemStore()} {
		now := time.Now()
		for i := 0; i < guild.GPHistoryMax+5; i++ {
			_ = s.AddGPHistory(ctx, 1, guild.GPHistoryEntry{At: now.Add(time.Duration(i) * time.Second), Name: "M", GP: int64(i), Kind: 6})
		}
		_ = s.AddGPHistory(ctx, 1, guild.GPHistoryEntry{At: now.Add(-40 * 24 * time.Hour), Name: "Old", GP: 1})
		list, _ := s.GPHistory(ctx, 1, now.Add(time.Hour))
		if len(list) != guild.GPHistoryMax-1 || list[0].GP != int64(guild.GPHistoryMax+4) {
			t.Fatalf("history %d first %+v", len(list), list[0])
		}
	}
}
