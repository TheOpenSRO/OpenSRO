package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

func jobReq(npc uint32, tail ...byte) []byte {
	return append(binary.LittleEndian.AppendUint32(nil, npc), tail...)
}

func jobAliasReq(npc uint32, op byte, alias string) []byte {
	b := jobReq(npc, op)
	b = binary.LittleEndian.AppendUint16(b, uint16(len(alias)))
	return append(b, alias...)
}

// The job guild over a real socket (round 799): the join's refusals in the
// handler's order, the fee, the alias check and set, the reward, the
// rankings, the old-job query, the withdrawal and its 7 days.
func TestRound799JobGuild(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	accounts.Add("Tara", "pw")
	c0, err := chars.Create(ctx, 1, "Tara")
	if err != nil {
		t.Fatal(err)
	}
	cid := c0.ID
	hub := world.NewHub()
	st := jobs.NewMemStore()
	SetJobDeps(JobDeps{Store: st, Chars: chars, Hub: hub})
	t.Cleanup(func() { jobRT.Store(nil) })

	trader := npcAt(5, 100, 0, npcspawn.FromNest)
	trader.Code = "NPC_CH_DOCTOR"
	trader.Flags, trader.Interact = npcspawn.FlagInteractions, []byte{1, 2, 0x14}
	hunter := npcAt(6, 120, 0, npcspawn.FromNest)
	hunter.Code = "NPC_CH_GENARAL_SW"
	hunter.Flags, hunter.Interact = npcspawn.FlagInteractions, []byte{2, 0x16}
	installNPCsForTest(t, trader, hunter)
	t.Cleanup(func() { ForgetNPCInteraction(1) })

	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), NPCTalkHandler(hub, trade.NewHub()),
		JobGuildHandler(hub))
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	conn := dialTestServer(t, srv.Addr)
	t.Cleanup(func() { conn.Close() })
	c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	c.send(OpLogin, (&LoginRequest{Username: "Tara", Password: "pw"}).Encode())
	if lr, err := DecodeLoginResult(c.next(OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Tara"}).Encode())
	if er, err := DecodeEnterWorldResult(c.next(OpEnterWorldResult).Data); err != nil || !er.OK {
		t.Fatalf("enter: %v %+v", err, er)
	}
	e, ok := hub.FindByName("Tara")
	if !ok {
		t.Fatal("Tara not in the world")
	}
	if e.Zone != "jangan" {
		t.Skipf("the test NPCs stand in the jangan frame; the world put Tara in %q", e.Zone)
	}
	hub.Relocate(e.Session, world.Position{X: 110, Z: 0}, world.MoveRelocate, 0)
	expect := func(op uint16, want []byte, what string) {
		t.Helper()
		if got := c.next(op).Data; !bytes.Equal(got, want) {
			t.Fatalf("%s: % x, want % x", what, got, want)
		}
	}
	tu, hu := trader.UID, hunter.UID

	// Nothing selected: 3.
	c.send(jobs.OpJoin, jobReq(tu, 1))
	expect(jobs.OpJoinResult, jobs.Fail(jobs.ErrNPC), "join with no NPC")
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(tu))
	c.next(npctalk.OpSelectResult)
	c.send(jobs.OpJoin, jobReq(tu, 4))
	expect(jobs.OpJoinResult, jobs.Fail(jobs.ErrUnknownJobKind), "kind 4")
	c.send(jobs.OpJoin, jobReq(tu, 3))
	expect(jobs.OpJoinResult, jobs.Fail(jobs.ErrJobGuildNotFound), "the hunters' join at the traders")
	c.send(jobs.OpJoin, jobReq(tu, 1))
	expect(jobs.OpJoinResult, jobs.Fail(jobs.ErrJobGuildLevel), "level 1")
	if err := chars.SetLeveling(ctx, cid, 30, 0, 0, 20, 20); err != nil {
		t.Fatal(err)
	}
	start, _ := chars.GetByID(ctx, cid)
	if start.Gold >= 50000 {
		t.Fatalf("a new character's gold %d", start.Gold)
	}
	c.send(jobs.OpJoin, jobReq(tu, 1))
	expect(jobs.OpJoinResult, jobs.Fail(jobs.ErrNotEnoughGold), "50000 gold short")
	_ = chars.AddGold(ctx, cid, 60000)
	c.send(jobs.OpJoin, jobReq(tu, 1))
	expect(jobs.OpJoinResult, jobs.JoinOK(jobs.KindTrader, 1, 0), "the join")
	if ch, _ := chars.GetByID(ctx, cid); ch.Gold != start.Gold+10000 {
		t.Fatalf("gold after the 50000 fee: %d", ch.Gold)
	}
	c.send(jobs.OpJoin, jobReq(tu, 1))
	expect(jobs.OpJoinResult, jobs.Fail(jobs.ErrJobOverlap), "a second join")

	// The alias: a bad name, a check, the set (free), then a change (the fee).
	c.send(jobs.OpAlias, jobAliasReq(tu, 0, "a b"))
	expect(jobs.OpAliasResult, jobs.AliasFail(jobs.ErrAliasRule, 0, "a b"), "a space")
	_ = st.SetAlias(ctx, 99, "Taken")
	t.Cleanup(func() { jobRecs.Range(func(k, _ any) bool { jobRecs.Delete(k); return true }) })
	c.send(jobs.OpAlias, jobAliasReq(tu, 0, "taken"))
	expect(jobs.OpAliasResult, jobs.AliasFail(jobs.ErrAliasTaken1, 0, "taken"), "a taken alias")
	c.send(jobs.OpAlias, jobAliasReq(tu, 0, "Merch"))
	expect(jobs.OpAliasResult, jobs.AliasOK(0, "Merch"), "the check")
	c.send(jobs.OpAlias, jobAliasReq(tu, 1, "M"))
	expect(jobs.OpAliasResult, jobs.AliasFail(jobs.ErrAliasRule, 1, "M"), "one byte")
	c.send(jobs.OpAlias, jobAliasReq(tu, 1, "Merch"))
	expect(jobs.OpAliasResult, jobs.AliasOK(1, "Merch"), "the set")
	c.send(jobs.OpAlias, jobAliasReq(tu, 1, "Merch2"))
	expect(jobs.OpAliasResult, jobs.AliasFail(jobs.ErrNotEnoughGold, 1, "Merch2"), "a change for 1,500,000")
	_ = chars.AddGold(ctx, cid, 1500000)
	c.send(jobs.OpAlias, jobAliasReq(tu, 1, "Merch2"))
	expect(jobs.OpAliasResult, jobs.AliasOK(1, "Merch2"), "the change")
	if r, _ := st.Get(ctx, cid); r.Alias != "Merch2" {
		t.Fatalf("alias %q", r.Alias)
	}

	// A trader has no reward; the rankings answer at any guild NPC; no old job.
	c.send(jobs.OpReward, jobReq(tu, 0))
	expect(jobs.OpRewardResult, jobs.RewardFail(jobs.ErrUnknownJobKind, 0), "a trader's reward")
	_ = st.SetRankings(ctx, jobs.KindHunter, jobs.RankActivity, []jobs.RankRow{{Rank: 1, Alias: "h", Level: 3, Exp: 9}})
	c.send(jobs.OpRanking, jobReq(tu, 3, 0))
	expect(jobs.OpRankingResult, jobs.RankingOK(jobs.KindHunter, jobs.RankActivity,
		[]jobs.RankRow{{Rank: 1, Alias: "h", Level: 3, Exp: 9}}), "the hunters' activity table at the traders")
	c.send(jobs.OpPrevJob, jobReq(tu))
	expect(jobs.OpPrevJobResult, jobs.Fail(jobs.ErrNoOldJobInfo), "no old job")
	old := jobs.OldJob{Level: [3]int{1, 2, 4}, Exp: [3]int64{0, 50, 77}}
	st.PutOldJob(cid, old)
	c.send(jobs.OpPrevJob, jobReq(tu))
	expect(jobs.OpPrevJobResult, jobs.PrevJobOK(old), "the old job's information")

	// The withdrawal at the wrong guild, then at its own.
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(hu))
	c.next(npctalk.OpSelectResult)
	c.send(jobs.OpWithdraw, jobReq(hu))
	expect(jobs.OpWithdrawAck, jobs.Fail(jobs.ErrJobGuildNotFound), "withdraw at the hunters")
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(tu))
	c.next(npctalk.OpSelectResult)
	c.send(jobs.OpWithdraw, jobReq(tu))
	expect(jobs.OpWithdrawAck, jobs.WithdrawOK(), "withdraw")
	r, _ := st.Get(ctx, cid)
	if r.HasJob() || r.Alias != "" || !r.Penalized(time.Now()) || r.PenaltyUntil.Sub(time.Now()) < 6*24*time.Hour {
		t.Fatalf("after the withdrawal: %+v", r)
	}
	// The gold test comes before the penalty's (s:0x5121d3 before 0x512203).
	_ = chars.AddGold(ctx, cid, 100000)
	c.send(jobs.OpJoin, jobReq(tu, 1))
	expect(jobs.OpJoinResult, jobs.Fail(jobs.ErrJoinPenalty), "a join within 7 days")

	// A hunter collects: the query, the pay, then nothing left.
	r.PenaltyUntil = time.Time{}
	_ = st.Save(ctx, r)
	forgetJobRecord(cid)
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(hu))
	c.next(npctalk.OpSelectResult)
	// The join restores the kind's old level and exp (_QueryOldTrijobInfo),
	// then deletes the old information (_DeleteOldTrijobData).
	c.send(jobs.OpJoin, jobReq(hu, 3))
	expect(jobs.OpJoinResult, jobs.JoinOK(jobs.KindHunter, 4, 77), "a hunter's join, the old hunter level back")
	if _, err := st.OldJob(ctx, cid); err != jobs.ErrNoOldJob {
		t.Fatalf("the old job after a join: %v", err)
	}
	r, _ = st.Get(ctx, cid)
	r.Reward = 777
	_ = st.Save(ctx, r)
	forgetJobRecord(cid)
	c.send(jobs.OpReward, jobReq(hu, 0))
	expect(jobs.OpRewardResult, jobs.RewardOK(0, 777), "the reward's query")
	before, _ := chars.GetByID(ctx, cid)
	c.send(jobs.OpReward, jobReq(hu, 1))
	expect(jobs.OpRewardResult, jobs.RewardOK(1, 777), "the reward's pay")
	if after, _ := chars.GetByID(ctx, cid); after.Gold != before.Gold+777 {
		t.Fatalf("gold %d -> %d", before.Gold, after.Gold)
	}
	c.send(jobs.OpReward, jobReq(hu, 1))
	expect(jobs.OpRewardResult, jobs.RewardFail(jobs.ErrNoReward, 1), "nothing to collect")
}
