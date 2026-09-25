package session

import (
	"bufio"
	"context"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/guild"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// guildTotals reads a guild's GatheredSP and one member's GPDonation.
func guildTotals(t *testing.T, guilds guild.Store, guildID, characterID int64) (gathered, donation int64) {
	t.Helper()
	g, err := guilds.Get(context.Background(), guildID)
	if err != nil {
		t.Fatalf("Get(%d): %v", guildID, err)
	}
	for _, m := range g.Members {
		if m.CharacterID == characterID {
			donation = m.GPDonation
		}
	}
	return g.GatheredSP, donation
}

// pointEarners is a character store holding Aria (id 1) and Bram (id 2), both
// alive: the decorator's life stand-in (HP > 0) reads the earner from it.
func pointEarners(t *testing.T) *character.MemStore {
	t.Helper()
	chars := character.NewMemStore()
	for i, name := range []string{"Aria", "Bram"} {
		c, err := chars.Create(context.Background(), 1, name)
		if err != nil {
			t.Fatalf("Create(%s): %v", name, err)
		}
		if c.ID != int64(i+1) || c.HP <= 0 {
			t.Fatalf("fixture assumes %s is id %d and alive, got id %d HP %d", name, i+1, c.ID, c.HP)
		}
	}
	return chars
}

// TestGuildPointsBatchFromSkillExp pins NewGuildPointSkills to
// GObjPC_GainExpAndLevel's (0x4e5250) rule: the skill points converted out of
// skill experience (400:1) are booked on the member's accumulator, and once it
// passes 9 the whole batch goes to the guild's GatheredSP and the member's
// GP_Donation (CGuild::AddPoints, 0x5c4110).
func TestGuildPointsBatchFromSkillExp(t *testing.T) {
	ctx := context.Background()
	guilds := guild.NewMemStore()
	g, err := guilds.Create(ctx, "Ironclad", 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	inner := skill.NewMemStore()
	ref := skill.NewMemStore() // the same calls without the wrapper
	skills := NewGuildPointSkills(inner, guilds, pointEarners(t))

	if leveldata.SkillExpPerPoint != 400 {
		t.Fatalf("fixture assumes 400 skill exp a point, have %d", leveldata.SkillExpPerPoint)
	}

	// 1600 skill exp is 4 points. 4, 8: below the batch. 12: out it goes.
	for i, wantTotal := range []int64{0, 0, 12} {
		gained, total, err := skills.AddSkillExp(ctx, 1, 1600)
		rg, rt, rerr := ref.AddSkillExp(ctx, 1, 1600)
		if err != nil || rerr != nil {
			t.Fatalf("call %d: AddSkillExp: %v / %v", i+1, err, rerr)
		}
		if gained != rg || total != rt {
			t.Fatalf("call %d: the wrapper returned (%d, %d), the plain store (%d, %d)", i+1, gained, total, rg, rt)
		}
		if gained != 4 {
			t.Fatalf("call %d: gained %d points, want 4", i+1, gained)
		}
		if got, _ := guildTotals(t, guilds, g.ID, 1); got != wantTotal {
			t.Fatalf("call %d: GatheredSP = %d, want %d", i+1, got, wantTotal)
		}
	}
	if gathered, donation := guildTotals(t, guilds, g.ID, 1); gathered != 12 || donation != 12 {
		t.Fatalf("after 12 points: GatheredSP %d, donation %d, want 12 and 12", gathered, donation)
	}

	// NEGATIVE: a guildless character earning 12 points credits nothing, and
	// books nothing either (pc[0x72f] != 0 is tested before the add): once it
	// joins, 4 more points are 4 pending, not 16.
	if _, _, err := skills.AddSkillExp(ctx, 2, 4800); err != nil {
		t.Fatalf("AddSkillExp(guildless): %v", err)
	}
	if gathered, _ := guildTotals(t, guilds, g.ID, 1); gathered != 12 {
		t.Fatalf("a guildless character's points moved the guild: GatheredSP %d, want 12", gathered)
	}
	if _, err := guilds.Join(ctx, g.ID, 2, "Bram"); err != nil {
		t.Fatalf("Join: %v", err)
	}
	if _, _, err := skills.AddSkillExp(ctx, 2, 1600); err != nil {
		t.Fatalf("AddSkillExp(Bram): %v", err)
	}
	if gathered, donation := guildTotals(t, guilds, g.ID, 2); gathered != 12 || donation != 0 {
		t.Fatalf("points earned before joining were booked: GatheredSP %d, Bram's donation %d, want 12 and 0",
			gathered, donation)
	}

	// NEGATIVE: points granted directly (GM /sp, refunds, the no-level-table
	// fallback) are not a conversion and credit nothing.
	if _, err := skills.AddSkillPoints(ctx, 1, 50); err != nil {
		t.Fatalf("AddSkillPoints: %v", err)
	}
	if gathered, donation := guildTotals(t, guilds, g.ID, 1); gathered != 12 || donation != 12 {
		t.Fatalf("AddSkillPoints credited the guild: GatheredSP %d, donation %d, want 12 and 12", gathered, donation)
	}

	// Carry-over: 6 then 6 is one batch of 12.
	if _, _, err := skills.AddSkillExp(ctx, 1, 2400); err != nil {
		t.Fatalf("AddSkillExp: %v", err)
	}
	if gathered, _ := guildTotals(t, guilds, g.ID, 1); gathered != 12 {
		t.Fatalf("6 points went out alone: GatheredSP %d, want 12", gathered)
	}
	if _, _, err := skills.AddSkillExp(ctx, 1, 2400); err != nil {
		t.Fatalf("AddSkillExp: %v", err)
	}
	if gathered, donation := guildTotals(t, guilds, g.ID, 1); gathered != 24 || donation != 24 {
		t.Fatalf("after 6 + 6: GatheredSP %d, Aria's donation %d, want 24 and 24", gathered, donation)
	}
}

// failingPoints is a guild store whose AddPoints always fails. Test-only.
type failingPoints struct{ guild.Store }

func (failingPoints) AddPoints(context.Context, int64, int64, int) error {
	return errors.New("database unavailable")
}

// A failed credit is logged and dropped: the kill path must not fail over a
// guild total, so AddSkillExp still answers with the inner store's values.
func TestGuildPointsCreditFailureIsNotReturned(t *testing.T) {
	ctx := context.Background()
	guilds := guild.NewMemStore()
	if _, err := guilds.Create(ctx, "Ironclad", 1, "Aria"); err != nil {
		t.Fatalf("Create: %v", err)
	}
	skills := NewGuildPointSkills(skill.NewMemStore(), failingPoints{guilds}, pointEarners(t))
	gained, total, err := skills.AddSkillExp(ctx, 1, 4000)
	if err != nil || gained != 10 || total != 10 {
		t.Fatalf("AddSkillExp with a failing guild store = (%d, %d, %v), want (10, 10, nil)", gained, total, err)
	}
}

// TestKillCreditsGuildPoints is the wiring end to end: a guild member's kill
// through CombatHandler, with the handler's skill store wrapped the way
// cmd/server wraps it, reaches the guild, and OpGuildPoints reports it.
func TestKillCreditsGuildPoints(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	// One level, worth 5000 exp a kill: at the 400:1 conversion that is well
	// past the batch of ten even after the mastery-lag scale.
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n1,1000000,1,5000\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	prevTable := levelTable
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prevTable) })

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}}
	inv := inventory.NewMemStore(items)
	if err := inv.AddItem(ctx, c.ID, 100, 1); err != nil {
		t.Fatalf("seeding inventory: %v", err)
	}
	eq := equipment.NewMemStore(inv)
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping weapon: %v", err)
	}

	guilds := guild.NewMemStore()
	g, err := guilds.Create(ctx, "Silk Legion", c.ID, "Aria")
	if err != nil {
		t.Fatalf("guild Create: %v", err)
	}
	inner := skill.NewMemStore()

	hub := world.NewHub()
	monsters := combat.NewHub()
	target := monsters.SpawnSpecies("jangan", combat.Species{Name: "Mangyang", Level: 1}, 0, 0, 0, 1, 0, 0, 0)

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quest.NewMemStore(), inv, NewGuildPointSkills(inner, guilds, chars), nil, nil, nil),
		GuildHandler(chars, guilds, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	// sendFor writes one request and reads until the reply with the wanted
	// opcode, skipping the zone broadcasts a kill also sends this session.
	sendFor := func(cn net.Conn, opcode uint16, data []byte, want uint16) *proto.Packet {
		t.Helper()
		if err := proto.Write(cn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		for {
			cn.SetReadDeadline(time.Now().Add(2 * time.Second))
			resp, err := proto.Read(r, nil, nil)
			if err != nil {
				t.Fatalf("Read waiting for 0x%04x: %v", want, err)
			}
			if resp.Opcode == want {
				return resp
			}
		}
	}

	if lr, err := DecodeLoginResult(sendFor(conn, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode(), OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(sendFor(conn, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode(), OpEnterWorldResult).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	ar, err := DecodeAttackResult(sendFor(conn, OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: target.ID}).Encode(), OpAttackResult).Data)
	if err != nil || ar.Error != "" || !ar.MonsterDied {
		t.Fatalf("kill: err=%v result=%+v", err, ar)
	}
	sp, err := inner.SkillPoints(ctx, c.ID)
	if err != nil {
		t.Fatalf("SkillPoints: %v", err)
	}
	if sp < guild.PointBatchThreshold {
		t.Fatalf("the kill converted %d skill points; the fixture needs at least %d", sp, guild.PointBatchThreshold)
	}

	pr, err := DecodeGuildPointsResult(sendFor(conn, OpGuildPoints, (&CharacterNameRequest{Name: "Aria"}).Encode(), OpGuildPointsResult).Data)
	if err != nil || pr.Error != "" {
		t.Fatalf("OpGuildPoints: err=%v result=%+v", err, pr)
	}
	if pr.GuildID != g.ID || pr.GatheredSP <= 0 {
		t.Fatalf("OpGuildPoints = %+v, want guild %d with GatheredSP > 0", pr, g.ID)
	}
	if pr.GatheredSP != int64(sp) {
		t.Fatalf("GatheredSP = %d, want the %d skill points the kill converted, 1:1", pr.GatheredSP, sp)
	}
	if len(pr.Members) != 1 || pr.Members[0].Name != "Aria" || pr.Members[0].GPDonation != pr.GatheredSP {
		t.Fatalf("members = %+v, want Aria alone, donating all %d", pr.Members, pr.GatheredSP)
	}
}

// pendingOf reads a character's pending count, and whether it has an entry at
// all, straight off the decorator's map.
func pendingOf(gp *GuildPointSkills, characterID int64) (int, bool) {
	gp.mu.Lock()
	defer gp.mu.Unlock()
	a, ok := gp.acc[characterID]
	if !ok {
		return 0, false
	}
	return a.Pending(), true
}

// TestGuildPointsFlushPending pins FlushPending to FUN_004def90
// (0x4def96-0x4defc2): whatever a member has pending, below the batch of ten,
// goes to the guild when they leave the world, and the count is gone after.
func TestGuildPointsFlushPending(t *testing.T) {
	ctx := context.Background()
	guilds := guild.NewMemStore()
	g, err := guilds.Create(ctx, "Ironclad", 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := guilds.Join(ctx, g.ID, 2, "Bram"); err != nil {
		t.Fatalf("Join: %v", err)
	}
	chars := pointEarners(t)
	gp := NewGuildPointSkills(skill.NewMemStore(), guilds, chars)

	// 4 points: below the batch, so nothing yet.
	if _, _, err := gp.AddSkillExp(ctx, 1, 1600); err != nil {
		t.Fatalf("AddSkillExp: %v", err)
	}
	if gathered, _ := guildTotals(t, guilds, g.ID, 1); gathered != 0 {
		t.Fatalf("4 points went out before the flush: GatheredSP %d", gathered)
	}
	gp.FlushPending(ctx, 1)
	if gathered, donation := guildTotals(t, guilds, g.ID, 1); gathered != 4 || donation != 4 {
		t.Fatalf("after the flush: GatheredSP %d, Aria's donation %d, want 4 and 4 (no threshold on the flush)",
			gathered, donation)
	}
	if _, ok := pendingOf(gp, 1); ok {
		t.Fatalf("the flushed character's accumulator is still in the map")
	}
	// A second flush has nothing to send.
	gp.FlushPending(ctx, 1)
	if gathered, _ := guildTotals(t, guilds, g.ID, 1); gathered != 4 {
		t.Fatalf("a second flush credited again: GatheredSP %d, want 4", gathered)
	}

	// NEGATIVE: earned in the guild, then left it -- the engine skips the
	// request (0x4def9f), and the count goes with the PC.
	if _, _, err := gp.AddSkillExp(ctx, 2, 2400); err != nil {
		t.Fatalf("AddSkillExp(Bram): %v", err)
	}
	if _, _, err := guilds.Leave(ctx, 2); err != nil {
		t.Fatalf("Leave: %v", err)
	}
	gp.FlushPending(ctx, 2)
	if gathered, _ := guildTotals(t, guilds, g.ID, 1); gathered != 4 {
		t.Fatalf("a former member's pending points reached the guild: GatheredSP %d, want 4", gathered)
	}
	if _, ok := pendingOf(gp, 2); ok {
		t.Fatalf("the former member's accumulator is still in the map")
	}

	// NEGATIVE: dead at logout -- the request's life test (0x4c07) drops the
	// count, and it is not kept for later.
	if _, _, err := gp.AddSkillExp(ctx, 1, 2000); err != nil {
		t.Fatalf("AddSkillExp: %v", err)
	}
	if _, died, err := chars.ApplyDamage(ctx, 1, 1_000_000); err != nil || !died {
		t.Fatalf("ApplyDamage: died=%v err=%v", died, err)
	}
	gp.FlushPending(ctx, 1)
	if gathered, _ := guildTotals(t, guilds, g.ID, 1); gathered != 4 {
		t.Fatalf("a dead character's flush was credited: GatheredSP %d, want 4", gathered)
	}
	if _, ok := pendingOf(gp, 1); ok {
		t.Fatalf("the dead character's accumulator is still in the map")
	}
}

// NEGATIVE, on the batch path: a dead earner's batch is dropped (the request's
// 0x4c07) and the count is zeroed all the same (0x4e5647), so 4 more points
// after respawning are 4 pending, not 16.
func TestGuildPointsDeadEarnerBatchIsDropped(t *testing.T) {
	ctx := context.Background()
	guilds := guild.NewMemStore()
	g, err := guilds.Create(ctx, "Ironclad", 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	chars := pointEarners(t)
	gp := NewGuildPointSkills(skill.NewMemStore(), guilds, chars)
	if _, died, err := chars.ApplyDamage(ctx, 1, 1_000_000); err != nil || !died {
		t.Fatalf("ApplyDamage: died=%v err=%v", died, err)
	}
	if _, _, err := gp.AddSkillExp(ctx, 1, 4800); err != nil {
		t.Fatalf("AddSkillExp: %v", err)
	}
	if gathered, donation := guildTotals(t, guilds, g.ID, 1); gathered != 0 || donation != 0 {
		t.Fatalf("a dead earner's batch was credited: GatheredSP %d, donation %d", gathered, donation)
	}
	if err := chars.RespawnHP(ctx, 1); err != nil {
		t.Fatalf("RespawnHP: %v", err)
	}
	if _, _, err := gp.AddSkillExp(ctx, 1, 1600); err != nil {
		t.Fatalf("AddSkillExp: %v", err)
	}
	if pending, _ := pendingOf(gp, 1); pending != 4 {
		t.Fatalf("pending after the dropped batch and 4 more = %d, want 4", pending)
	}
}

// FlushAllPending sends every pending count, for a stopping server.
func TestGuildPointsFlushAllPending(t *testing.T) {
	ctx := context.Background()
	guilds := guild.NewMemStore()
	g, err := guilds.Create(ctx, "Ironclad", 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := guilds.Join(ctx, g.ID, 2, "Bram"); err != nil {
		t.Fatalf("Join: %v", err)
	}
	gp := NewGuildPointSkills(skill.NewMemStore(), guilds, pointEarners(t))
	if _, _, err := gp.AddSkillExp(ctx, 1, 1600); err != nil {
		t.Fatalf("AddSkillExp(Aria): %v", err)
	}
	if _, _, err := gp.AddSkillExp(ctx, 2, 2400); err != nil {
		t.Fatalf("AddSkillExp(Bram): %v", err)
	}
	gp.FlushAllPending(ctx)
	gathered, aria := guildTotals(t, guilds, g.ID, 1)
	_, bram := guildTotals(t, guilds, g.ID, 2)
	if gathered != 10 || aria != 4 || bram != 6 {
		t.Fatalf("after FlushAllPending: GatheredSP %d, Aria %d, Bram %d, want 10, 4, 6", gathered, aria, bram)
	}
	gp.mu.Lock()
	left := len(gp.acc)
	gp.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d accumulators left after FlushAllPending, want 0", left)
	}
}

// TestGuildPointsDisconnectFlush is the logout flush end to end: a member
// earns 4 points, below the batch, and disconnects; the gateway's OnDisconnect
// chain, wired the way cmd/server wires it (the guild flush before the world
// hub forgets the session), credits the guild +4.
func TestGuildPointsDisconnectFlush(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	eq := equipment.NewMemStore(inventory.NewMemStore(stubCombatItems{}))
	guilds := guild.NewMemStore()
	g, err := guilds.Create(ctx, "Silk Legion", c.ID, "Aria")
	if err != nil {
		t.Fatalf("guild Create: %v", err)
	}
	gp := NewGuildPointSkills(skill.NewMemStore(), guilds, chars)

	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub))
	flush := GuildPointsDisconnectHandler(hub, gp)
	leave := WorldDisconnectHandler(hub, nil)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: func(sess *gateway.Session) {
		flush(sess)
		leave(sess)
	}}
	srvCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.ListenAndServe(srvCtx)

	conn := dialTestServer(t, addr)
	r := bufio.NewReader(conn)
	sendRecv := func(opcode uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(sendRecv(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	if ewr, err := DecodeEnterWorldResult(sendRecv(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	if gained, _, err := gp.AddSkillExp(ctx, c.ID, 1600); err != nil || gained != 4 {
		t.Fatalf("AddSkillExp = %d, %v; want 4 points", gained, err)
	}
	if gathered, _ := guildTotals(t, guilds, g.ID, c.ID); gathered != 0 {
		t.Fatalf("4 points went out while still online: GatheredSP %d", gathered)
	}

	conn.Close()
	// Wait for the whole OnDisconnect chain: the hub forgetting the session
	// is its last step, so the flush has run by then.
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, inWorld := hub.EntityByCharacterID(c.ID); !inWorld {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the world hub still holds the disconnected character")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if gathered, donation := guildTotals(t, guilds, g.ID, c.ID); gathered != 4 || donation != 4 {
		t.Fatalf("after disconnecting: GatheredSP %d, Aria's donation %d, want 4 and 4", gathered, donation)
	}
}
