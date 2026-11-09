package session

import (
	"bufio"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// Round 665's review follow-up. Wire-level and round-549 helpers only, so the
// file also runs against ddfe5b9 (the negative).

// startReviveStoreFixture is startDeadWorldFixture whose revive handler works
// through wrap(chars) -- a store that can be made to fail.
func startReviveStoreFixture(t *testing.T, wrap func(*character.MemStore) character.Store) *deadWorldFixture {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandlerWithHook(chars, nil, hub, nil, nil), ReviveHandler(wrap(chars), hub, RegenDeps{}))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	f := &deadWorldFixture{chars: chars, hub: hub, aria: aria.ID, bram: bram.ID}
	f.connA = dialTestServer(t, addr)
	t.Cleanup(func() { f.connA.Close() })
	f.rA = bufio.NewReader(f.connA)
	f.connB = dialTestServer(t, addr)
	t.Cleanup(func() { f.connB.Close() })
	f.rB = bufio.NewReader(f.connB)
	f.login(t, f.connA, f.rA, "alice", "hunter2", "Aria")
	f.login(t, f.connB, f.rB, "bob", "hunter3", "Bram")
	// Round 737: Bram's arrival reaches Aria as retail's 0x3015, and Aria
	// reaches Bram as a group spawn after his result (playerview.go).
	expectPlayerSpawn(t, f.connA, f.rA, f.bram)
	expectPlayerSpawn(t, f.connB, f.rB, f.aria)
	return f
}

// H1: option 1 whose revive fails on the store answers a refusal and leaves
// her dead at the return point -- it must not reach the success path with no
// character (ddfe5b9 shadowed the error and dereferenced nil, which took the
// whole server down: the gateway does not recover a handler's panic). The
// next request, the store healthy again, revives her.
func TestReviveOptionOneWithAFailingStoreIsRefused(t *testing.T) {
	var store *failingPoolStore
	f := startReviveStoreFixture(t, func(m *character.MemStore) character.Store {
		store = &failingPoolStore{Store: m}
		return store
	})
	f.setLevel(t, f.aria, 30)
	f.goDonwhang(t)
	f.kill(t, f.aria, aiT0)
	store.fails.Store(1)
	f.send(t, f.connA, OpRevive, []byte{1})
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpChangeZoneResult {
		t.Fatalf("option 1's first answer is %#04x, want the zone change home", p.Opcode)
	}
	f.expectSpawnIfInView(t)
	p := f.read(t, f.connA, f.rA)
	rr, err := DecodeReviveResult(p.Data)
	if p.Opcode != OpReviveResult || err != nil || rr.Error == "" {
		t.Fatalf("option 1 with a failing store answered %#04x %+v (err %v), want a refusal", p.Opcode, rr, err)
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeDead {
		t.Errorf("after the failed revive: life %d, want still dead (the state put back)", e.Life)
	}
	f.send(t, f.connA, OpRevive, []byte{1})
	for {
		p := f.read(t, f.connA, f.rA)
		if p.Opcode != OpReviveResult {
			continue
		}
		if rr, err := DecodeReviveResult(p.Data); err != nil || rr.Error != "" {
			t.Fatalf("the second option 1 answered %+v (err %v), want a success", rr, err)
		}
		break
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeAlive {
		t.Errorf("after the second option 1: life %d, want alive", e.Life)
	}
}

// barrierA waits until Aria's session has handled everything sent before it:
// a living character's OpRevive is answered "not dead", after every packet
// ahead of it on the one reader.
func (f *deadWorldFixture) barrierA(t *testing.T) {
	t.Helper()
	f.send(t, f.connA, OpRevive, []byte{1})
	for {
		p := f.read(t, f.connA, f.rA)
		if p.Opcode == OpReviveResult {
			return
		}
	}
}

// M1: with -player-dead-state off a kill respawns her and the server moves her
// home from the kill's goroutine, while her client -- never told she died --
// may still be walking. A step it sent from where she fell, handled after the
// move, must not put her back there; the client's landing near the return
// point is taken, and so is the walk after it.
func TestAStaleMoveDoesNotUndoTheReturn(t *testing.T) {
	deadStateForTest(t, false)
	f := startDeadWorldFixture(t)
	fell := world.Position{X: 700, Z: 700}
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(fell.X), Z: float32(fell.Z)}).Encode())
	f.barrierA(t)
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Pos != fell {
		t.Fatalf("setup: Aria at %+v, want %+v", e.Pos, fell)
	}
	returnAfterKill(context.Background(), f.chars, nil, f.hub, f.aria)
	_, home, _, _ := arrival(spawnZone)
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(fell.X + 5), Z: float32(fell.Z)}).Encode())
	f.barrierA(t)
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Pos != home {
		t.Fatalf("after a step sent from where she fell: Aria at %+v, want still at the return point %+v", e.Pos, home)
	}
	sx, sz, ok := worldmap.LandingSpotFor(spawnZone, home.X, home.Z)
	if !ok {
		sx, sz = home.X, home.Z
	}
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(sx), Z: float32(sz), Relocated: true}).Encode())
	f.barrierA(t)
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Pos.X != float64(float32(sx)) || e.Pos.Z != float64(float32(sz)) {
		t.Errorf("the client's landing at (%v, %v) was not taken: Aria at %+v", sx, sz, e.Pos)
	}
	f.send(t, f.connA, OpMove, (&MoveRequest{X: float32(sx + 600), Z: float32(sz)}).Encode())
	f.barrierA(t)
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Pos.X != float64(float32(sx+600)) {
		t.Errorf("a walk after the landing was dropped: Aria at %+v", e.Pos)
	}
}

// M2: nothing revives a dead player unasked. Killed with the flag on, she is
// still dead at HP 0 after a wait past any short timer, and is sent nothing.
// (A mutant arming time.AfterFunc(1.5 s, revivePlayer) in markDead passed
// every test before this one.)
func TestADeadPlayerStaysDeadUnasked(t *testing.T) {
	deadStateForTest(t, true)
	f := startDeadWorldFixture(t)
	ctx := context.Background()
	if _, _, err := f.chars.ApplyDamage(ctx, f.aria, 1<<30); err != nil {
		t.Fatal(err)
	}
	out, err := finishKill(ctx, strikeDeps{chars: f.chars, hub: f.hub}, f.aria, monsterStrikeOutcome{damage: 1 << 30})
	if err != nil || !out.died {
		t.Fatalf("setup: the kill %+v (err %v)", out, err)
	}
	time.Sleep(3 * time.Second)
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeDead {
		t.Errorf("3 s after the kill: life %d, want still dead -- retail revives no one unasked outside a fortress war", e.Life)
	}
	if c, _ := f.chars.GetByID(ctx, f.aria); c.HP != 0 {
		t.Errorf("3 s after the kill: HP %d, want 0", c.HP)
	}
	if !f.nothing(t, f.connA, f.rA) {
		t.Error("the dead player was sent something unasked")
	}
}

// L3: an empty request -- a client before round 665 -- is option 2 up to
// level 10 and option 1 from 11: the boundary, both sides.
func TestEmptyReviveAtTheLevelTenBoundary(t *testing.T) {
	for _, tc := range []struct {
		level  int
		inTown bool
	}{{10, false}, {11, true}} {
		f := startDeadWorldFixture(t)
		f.setLevel(t, f.aria, tc.level)
		f.goDonwhang(t)
		f.kill(t, f.aria, aiT0)
		f.send(t, f.connA, OpRevive, nil)
		first := f.read(t, f.connA, f.rA).Opcode
		if tc.inTown && first != OpChangeZoneResult {
			t.Errorf("level %d, empty request: first answer %#04x, want the zone change home (option 1)", tc.level, first)
		}
		if !tc.inTown && first != OpReviveResult {
			t.Errorf("level %d, empty request: first answer %#04x, want the revive in place (option 2)", tc.level, first)
		}
	}
}

// L3: a damage-over-time kill with the flag off respawns her at the return
// point too (status.go's returnAfterKill), not where she bled out.
func TestATickKillWithTheFlagOffReturnsHome(t *testing.T) {
	fx := statusFXForTest(t)
	deadStateForTest(t, false)
	ctx := context.Background()
	z := startStrikeZone(t)
	fell := world.Position{X: 700, Z: 700}
	z.aria.write(t, OpMove, (&MoveRequest{X: float32(fell.X), Z: float32(fell.Z)}).Encode())
	z.aria.barrier(t)
	if e, _ := z.hub.EntityByCharacterID(z.ariaChar); e.Pos != fell {
		t.Fatalf("setup: Aria at %+v, want %+v", e.Pos, fell)
	}
	k := z.monsters.SpawnSpecies("jangan", strikeMangyang, fell.X, 0, fell.Z, 100000, 0, 1, 0)
	deps := strikeDeps{chars: z.chars, eq: z.eq, items: z.items, hub: z.hub}
	t0 := time.Now()
	fx.applyToCharacter(ctx, deps, *k, combat.MonsterSkill{ID: 9200, Status: "bl:30000,100,1,100000,0"}, z.ariaChar)
	fx.step(ctx, t0.Add(2100*time.Millisecond))
	_, home, _, _ := arrival(spawnZone)
	e, _ := z.hub.EntityByCharacterID(z.ariaChar)
	c, _ := z.chars.GetByID(ctx, z.ariaChar)
	if c.HP <= 0 || e.Life != world.LifeAlive || e.Pos != home {
		t.Errorf("after a bleed killed her with the flag off: HP %d, life %d at %+v; want respawned alive at the return point %+v, not where she bled out (%+v)", c.HP, e.Life, e.Pos, home, fell)
	}
}

// L5: the flag on, one death and option 1 cost one EXP penalty: the kill's,
// none from the return.
func TestOptionOneChargesNoSecondPenalty(t *testing.T) {
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n10,23500,9,235\n11,34898,12,259\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	loss, _ := tbl.DeathPenaltyExp(11, leveldata.DeathPenaltyKilledByMonster, false)
	deadStateForTest(t, true)
	prev := levelTable
	SetLevelTable(tbl)
	t.Cleanup(func() { SetLevelTable(prev) })
	ctx := context.Background()
	f := startDeadWorldFixture(t)
	const startExp = 30000
	c, _ := f.chars.GetByID(ctx, f.aria)
	if err := f.chars.SetLeveling(ctx, f.aria, 11, startExp, c.StatPoints, c.Str, c.Int); err != nil {
		t.Fatal(err)
	}
	f.hub.SetLevel(f.aria, 11)
	f.goDonwhang(t)
	if _, _, err := f.chars.ApplyDamage(ctx, f.aria, 1<<30); err != nil {
		t.Fatal(err)
	}
	if out, err := finishKill(ctx, strikeDeps{chars: f.chars, hub: f.hub}, f.aria, monsterStrikeOutcome{damage: 1 << 30}); err != nil || out.deathExpLost != loss {
		t.Fatalf("setup: the kill %+v (err %v), want a penalty of %d", out, err, loss)
	}
	f.send(t, f.connA, OpRevive, []byte{1})
	for {
		p := f.read(t, f.connA, f.rA)
		if p.Opcode == OpReviveResult {
			if rr, err := DecodeReviveResult(p.Data); err != nil || rr.Error != "" {
				t.Fatalf("option 1 answered %+v (err %v)", rr, err)
			}
			break
		}
	}
	after, _ := f.chars.GetByID(ctx, f.aria)
	e, _ := f.hub.EntityByCharacterID(f.aria)
	if after.Exp != startExp-loss || e.Life != world.LifeAlive || e.Zone == "donwhang" {
		t.Errorf("after the kill and option 1: exp %d, life %d in %q; want %d (one penalty), alive at the return point", after.Exp, e.Life, e.Zone, startExp-loss)
	}
}
