package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Job PvP over a real socket (round 802): a plain swing refused between
// players out of a job (no PK), a thief's blow on a trader, the trader's
// job death (no normal penalty; 3 x Unit job exp, 6 x the exp unit
// character exp) and the thief's credit (KillExp, 3 x the exp unit).
func TestRound802JobPvP(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("thief", "pw")
	accounts.Add("trader", "pw")
	chars := character.NewMemStore()
	a, _ := chars.Create(ctx, 1, "Robin")
	b, _ := chars.Create(ctx, 2, "Mercer")
	for _, id := range []int64{a.ID, b.ID} {
		if err := chars.SetLeveling(ctx, id, 50, 5000, 0, 60, 60); err != nil {
			t.Fatal(err)
		}
	}
	// Level 50: gold min 1000 (Unit 1250), exp unit 400.
	lt, err := leveldata.ParseCSV(strings.NewReader("level,exp\n49,100000,1,390,1,1,1,990\n50,100000,1,400,1000000,1000000,1000000,1000\n51,100000,1,410,1,1,1,1010\n"))
	if err != nil {
		t.Fatal(err)
	}
	old := levelTable
	SetLevelTable(lt)
	t.Cleanup(func() { SetLevelTable(old) })
	hub := world.NewHub()
	js := jobs.NewMemStore()
	SetJobDeps(JobDeps{Store: js, Chars: chars, Hub: hub})
	t.Cleanup(func() { jobRT.Store(nil) })
	_ = js.Save(ctx, jobs.Record{CharID: a.ID, Kind: jobs.KindThief, Level: 1})
	_ = js.Save(ctx, jobs.Record{CharID: b.ID, Kind: jobs.KindTrader, Level: 1, Exp: 10000})
	t.Cleanup(func() {
		for _, id := range []int64{a.ID, b.ID} {
			jobStates.Delete(id)
			jobRecs.Delete(id)
			pvpKeepUp.cancel(id)
		}
	})
	jobStates.Store(a.ID, jobs.StateNone)
	jobStates.Store(b.ID, jobs.StateNone)

	items := stubCombatItems{}
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, combat.NewHub(), nil, inv, nil, nil, nil, nil))
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	login := func(user, name string) *chatClient {
		conn := dialTestServer(t, srv.Addr)
		t.Cleanup(func() { conn.Close() })
		c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
		c.send(OpLogin, (&LoginRequest{Username: user, Password: "pw"}).Encode())
		c.next(OpLoginResult)
		c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
		c.next(OpEnterWorldResult)
		return c
	}
	ca := login("thief", "Robin")
	cb := login("trader", "Mercer")
	ea, _ := hub.FindByName("Robin")
	eb, _ := hub.FindByName("Mercer")
	hub.Relocate(ea.Session, world.Position{X: 100, Z: 100}, world.MoveRelocate, 0)
	hub.Relocate(eb.Session, world.Position{X: 102, Z: 100}, world.MoveRelocate, 0)

	attack := func() *AttackResult {
		t.Helper()
		ca.send(OpAttack, (&AttackRequest{CharacterName: "Robin", TargetMonsterID: b.ID, TargetKind: PvPTargetCharacter}).Encode())
		r, err := DecodeAttackResult(ca.next(OpAttackResult).Data)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	// Out of a job: no PK system, refused 0x3025's key.
	if r := attack(); r.Error != "UIIT_MSG_SKILL_USE_FAIL_PK_PROHIBITED_IN_THIS_SERVER" {
		t.Fatalf("no job: %q", r.Error)
	}
	// Thief against trader: the blow lands.
	jobStates.Store(a.ID, jobs.StateThief)
	jobStates.Store(b.ID, jobs.StateTrader)
	before, _ := chars.GetByID(ctx, b.ID)
	// Left at 1 HP, so the blow kills.
	if _, _, err := chars.ApplyDamage(ctx, b.ID, before.HP-1); err != nil {
		t.Fatal(err)
	}
	r := attack()
	if r.Error != "" || !r.MonsterDied || r.MonsterDamage < 1 || r.MonsterID != b.ID {
		t.Fatalf("the blow: %+v", r)
	}
	st := cb.next(OpPlayerStruck).Data
	if binary.LittleEndian.Uint32(st) != uint32(a.ID) || st[4] != 0 || binary.LittleEndian.Uint32(st[5:]) != uint32(b.ID) || st[13]&4 == 0 ||
		len(st) != 30 || binary.LittleEndian.Uint64(st[22:]) != 2400 {
		t.Fatalf("OpPlayerStruck % x", st)
	}
	// The trader's job death: 3 x Unit(1000) = 3750 job exp, 6 x 400 = 2400
	// character exp, no normal penalty.
	after, _ := chars.GetByID(ctx, b.ID)
	if after.Exp != 5000-2400 {
		t.Fatalf("victim exp %d, want %d", after.Exp, 5000-2400)
	}
	if rec := jobRecord(ctx, b.ID); rec.Exp != 10000-3750 {
		t.Fatalf("victim job exp %d", rec.Exp)
	}
	// The thief's credit: KillExp(1000, 1000) = 1250, and 3 x 400 = 1200.
	if rec := jobRecord(ctx, a.ID); rec.Exp != 1250 {
		t.Fatalf("killer job exp %d", rec.Exp)
	}
	if k, _ := chars.GetByID(ctx, a.ID); k.Exp != 5000+1200 {
		t.Fatalf("killer exp %d", k.Exp)
	}
	// Same side: a trader and a hunter, 0x3006.
	jobStates.Store(a.ID, jobs.StateHunter)
	_ = chars.ResetHP(ctx, b.ID)
	if r := attack(); r.Error != "UIIT_SKILL_USE_FAIL_WRONGTARGET" {
		t.Fatalf("same side: %q", r.Error)
	}
}

// A COS target (round 802): a thief's swing at a trader's pet is judged by
// the owner's job and lands on the pet; the owner hears OpPlayerStruck kind
// 2; the owner's own swing at it is refused 0x3006.
func TestRound802COSTarget(t *testing.T) {
	ctx := context.Background()
	resetCOSWorld()
	t.Cleanup(func() {
		resetCOSWorld()
		cosWorld.deps.Store(nil)
	})
	accounts := account.NewMemStore()
	accounts.Add("thief", "pw")
	accounts.Add("trader", "pw")
	chars := character.NewMemStore()
	a, _ := chars.Create(ctx, 1, "Robin")
	b, _ := chars.Create(ctx, 2, "Mercer")
	for _, id := range []int64{a.ID, b.ID} {
		if err := chars.SetLeveling(ctx, id, 50, 5000, 0, 60, 60); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	js := jobs.NewMemStore()
	SetJobDeps(JobDeps{Store: js, Chars: chars, Hub: hub})
	t.Cleanup(func() { jobRT.Store(nil) })
	_ = js.Save(ctx, jobs.Record{CharID: a.ID, Kind: jobs.KindThief, Level: 1})
	_ = js.Save(ctx, jobs.Record{CharID: b.ID, Kind: jobs.KindTrader, Level: 1})
	t.Cleanup(func() {
		for _, id := range []int64{a.ID, b.ID} {
			jobStates.Delete(id)
			jobRecs.Delete(id)
			pvpKeepUp.cancel(id)
		}
	})
	jobStates.Store(a.ID, jobs.StateThief)
	jobStates.Store(b.ID, jobs.StateTrader)

	items := stubCombatItems{}
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	store := cos.NewMemStore()
	SetCOSDeps(store, nil, cosFixtureTable(t), nil, inv, nil, chars, hub, nil, nil)
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, combat.NewHub(), nil, inv, nil, nil, nil, nil))
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	login := func(user, name string) *chatClient {
		conn := dialTestServer(t, srv.Addr)
		t.Cleanup(func() { conn.Close() })
		c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
		c.send(OpLogin, (&LoginRequest{Username: user, Password: "pw"}).Encode())
		c.next(OpLoginResult)
		c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
		c.next(OpEnterWorldResult)
		return c
	}
	ca := login("thief", "Robin")
	cb := login("trader", "Mercer")
	ea, _ := hub.FindByName("Robin")
	eb, _ := hub.FindByName("Mercer")
	hub.Relocate(ea.Session, world.Position{X: 100, Z: 100}, world.MoveRelocate, 0)
	hub.Relocate(eb.Session, world.Position{X: 102, Z: 100}, world.MoveRelocate, 0)
	eb, _ = hub.FindByName("Mercer")

	row, ok := cosRowByCode("COS_P_WOLF_001")
	if !ok {
		t.Fatal("no wolf row")
	}
	rec := cos.Record{OwnerCharID: b.ID, RefCharID: row.ID, HP: row.MaxHP, Level: row.Level,
		State: cos.StateAlive | cos.StateSummoned}
	id, err := store.Create(ctx, rec)
	if err != nil {
		t.Fatal(err)
	}
	rec.ID = id
	o := spawnCOS(eb, rec, row, 0, -1, cosSpawnTypeSummoned, time.Now())
	// A pet spawns at a random point round its owner (cosSpawnPoint): put
	// beside the thief, inside an unarmed swing's reach.
	cosWorld.mu.Lock()
	o.pos = world.Position{X: 101, Z: 100}
	cosWorld.mu.Unlock()
	if !isCOSUID(int64(o.uid)) {
		t.Fatalf("the pet's uid %#x is outside the COS range", o.uid)
	}

	attack := func(c *chatClient, who string) *AttackResult {
		t.Helper()
		c.send(OpAttack, (&AttackRequest{CharacterName: who, TargetMonsterID: int64(o.uid), TargetKind: PvPTargetCOS}).Encode())
		r, err := DecodeAttackResult(c.next(OpAttackResult).Data)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	r := attack(ca, "Robin")
	if r.Error != "" || r.MonsterDamage < 1 || r.MonsterID != int64(o.uid) || r.TargetType != PvPTargetCOS {
		t.Fatalf("the swing at the pet: %+v", r)
	}
	pvpKeepUp.cancel(a.ID)
	st := cb.next(OpPlayerStruck).Data
	if st[4] != 2 || binary.LittleEndian.Uint32(st[5:]) != o.uid || int32(binary.LittleEndian.Uint32(st[9:])) != r.MonsterDamage {
		t.Fatalf("OpPlayerStruck % x", st)
	}
	cosWorld.mu.Lock()
	hp := o.rec.HP
	cosWorld.mu.Unlock()
	if want := row.MaxHP - int(r.MonsterDamage); hp != want && !(want < 0 && hp == 0) {
		t.Fatalf("the pet's HP %d, want %d", hp, want)
	}
	// The owner at his own pet: 0x3006.
	if r := attack(cb, "Mercer"); r.Error != "UIIT_SKILL_USE_FAIL_WRONGTARGET" {
		t.Fatalf("the owner's own pet: %q", r.Error)
	}
}
