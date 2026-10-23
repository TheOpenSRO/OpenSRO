package session

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 665: retail's resurrect choices (deadstate.go, "THE CHOICES"). These
// tests speak the wire and the package's round-549 helpers only, so the same
// file runs against the tree before the round (the negative).

// setLevel puts characterID at level on the row and on the hub entity, as a
// level-up does (Entity.Level is what the revive's level test reads).
func (f *deadWorldFixture) setLevel(t *testing.T, characterID int64, level int) {
	t.Helper()
	ctx := context.Background()
	c, err := f.chars.GetByID(ctx, characterID)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.chars.SetLeveling(ctx, characterID, level, c.Exp, c.StatPoints, c.Str, c.Int); err != nil {
		t.Fatal(err)
	}
	f.hub.SetLevel(characterID, level)
}

// goDonwhang moves Aria (alive) to donwhang and drains the packets that
// makes: her OpChangeZoneResult and Bram's OpEntityLeft.
func (f *deadWorldFixture) goDonwhang(t *testing.T) {
	t.Helper()
	f.send(t, f.connA, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	if czr, err := DecodeChangeZoneResult(f.read(t, f.connA, f.rA).Data); err != nil || !czr.OK {
		t.Fatalf("setup: Aria's zone change answered %+v (err %v)", czr, err)
	}
	expectPlayerDespawn(t, f.connB, f.rB, f.aria)
}

// Option 1, "Resurrect at the specified point.": a level-30 player killed in
// donwhang is taken to the return point -- jangan's arrival, where every
// character enters (returnPoint, OURS) -- and revived there, NOT where she
// fell: the zone change comes first (while she is still dead, so no monster
// can take her between the two), then the revive at the load path's
// trunc(0.4 x MaxHP), then the stats push. Bram, in jangan, sees her arrive.
func TestReviveOptionOneReturnsToTheReturnPoint(t *testing.T) {
	f := startDeadWorldFixture(t)
	ctx := context.Background()
	f.setLevel(t, f.aria, 30)
	f.goDonwhang(t)
	f.kill(t, f.aria, aiT0)

	f.send(t, f.connA, OpRevive, []byte{1})
	p := f.read(t, f.connA, f.rA)
	if p.Opcode != OpChangeZoneResult {
		t.Fatalf("option 1's first answer is %#04x, want OpChangeZoneResult to the return point (a revive in place answers OpReviveResult first)", p.Opcode)
	}
	czr, err := DecodeChangeZoneResult(p.Data)
	wantBucket, wantPos, _, _ := arrival(spawnZone)
	if err != nil || !czr.OK || czr.Zone != spawnZone {
		t.Fatalf("option 1's zone change %+v (err %v), want OK to %q", czr, err, spawnZone)
	}
	f.expectSpawnIfInView(t) // Bram, at the return point (round 737)
	p = f.read(t, f.connA, f.rA)
	if p.Opcode != OpReviveResult {
		t.Fatalf("after the zone change Aria received %#04x, want OpReviveResult", p.Opcode)
	}
	rr, err := DecodeReviveResult(p.Data)
	if err != nil || rr.Error != "" {
		t.Fatalf("option 1's result %+v (err %v), want a success", rr, err)
	}
	c, _ := f.chars.GetByID(ctx, f.aria)
	if want := int(float64(c.MaxHP()) * character.RespawnFraction); c.HP != want || int(rr.HP) != want {
		t.Errorf("option 1 revived at HP %d (result %d), want the load path's %d = trunc(0.4 x %d)", c.HP, rr.HP, want, c.MaxHP())
	}
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpCharacterStatsResult {
		t.Errorf("after the result Aria received %#04x, want the stats push", p.Opcode)
	}
	e, _ := f.hub.EntityByCharacterID(f.aria)
	if e.Life != world.LifeAlive || e.Zone != wantBucket || e.Pos != wantPos {
		t.Errorf("after option 1: life %d in %q at %+v; want alive in %q at %+v (the return point, not donwhang)", e.Life, e.Zone, e.Pos, wantBucket, wantPos)
	}
	expectPlayerSpawn(t, f.connB, f.rB, f.aria)
}

// Option 2, "Resurrect at the present point.", is honoured at max level 10 or
// under only (the handler's `bVar3 < 0xb` at 0x51017f): level 10 revives in
// place at 1 + trunc(0.4 x MaxHP); level 11 is refused and stays dead where
// she lies, and option 1 then still takes her home.
func TestReviveOptionTwoOnlyUpToLevelTen(t *testing.T) {
	ctx := context.Background()
	t.Run("level 10 in place", func(t *testing.T) {
		f := startDeadWorldFixture(t)
		f.setLevel(t, f.aria, 10)
		f.goDonwhang(t)
		f.kill(t, f.aria, aiT0)
		f.send(t, f.connA, OpRevive, []byte{2})
		rr, err := DecodeReviveResult(f.read(t, f.connA, f.rA).Data)
		if err != nil || rr.Error != "" {
			t.Fatalf("level 10's option 2 answered %+v (err %v), want a success", rr, err)
		}
		c, _ := f.chars.GetByID(ctx, f.aria)
		if want := reviveHPDelta(c.MaxHP()); c.HP != want {
			t.Errorf("HP %d after option 2, want %d", c.HP, want)
		}
		if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeAlive || e.Zone != "donwhang" {
			t.Errorf("after option 2: life %d in %q, want alive where she fell (donwhang)", e.Life, e.Zone)
		}
	})
	t.Run("level 11 refused", func(t *testing.T) {
		f := startDeadWorldFixture(t)
		f.setLevel(t, f.aria, 11)
		f.goDonwhang(t)
		f.kill(t, f.aria, aiT0)
		f.send(t, f.connA, OpRevive, []byte{2})
		rr, err := DecodeReviveResult(f.read(t, f.connA, f.rA).Data)
		if err != nil || rr.Error == "" {
			t.Fatalf("level 11's option 2 answered %+v (err %v), want a refusal", rr, err)
		}
		if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeDead || e.Zone != "donwhang" {
			t.Errorf("after a refused option 2: life %d in %q, want still dead in donwhang", e.Life, e.Zone)
		}
		if c, _ := f.chars.GetByID(ctx, f.aria); c.HP != 0 {
			t.Errorf("HP %d after a refused option 2, want 0", c.HP)
		}
		f.send(t, f.connA, OpRevive, []byte{1})
		if p := f.read(t, f.connA, f.rA); p.Opcode != OpChangeZoneResult {
			t.Errorf("option 1 after the refusal answered %#04x first, want the zone change home", p.Opcode)
		}
	})
}

// An empty OpRevive -- the one Revive button of a client before round 665 --
// is the one choice retail offers at that level: above 10 the return point,
// so an old client no longer revives among its killers.
func TestEmptyReviveAboveLevelTenReturnsToTheReturnPoint(t *testing.T) {
	f := startDeadWorldFixture(t)
	f.setLevel(t, f.aria, 30)
	f.goDonwhang(t)
	f.kill(t, f.aria, aiT0)
	f.send(t, f.connA, OpRevive, nil)
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpChangeZoneResult {
		t.Fatalf("an empty request at level 30 answered %#04x first, want the zone change to the return point", p.Opcode)
	}
	f.expectSpawnIfInView(t)
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpReviveResult {
		t.Fatalf("then %#04x, want OpReviveResult", p.Opcode)
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeAlive || e.Zone == "donwhang" {
		t.Errorf("after the empty request: life %d in %q, want alive at the return point", e.Life, e.Zone)
	}
}

// A living player's revive request is refused, whatever the option, and
// moves nobody: the handler's `cmp al,0x2` (0x510077) does nothing for it.
func TestReviveRequestFromTheLivingIsRefused(t *testing.T) {
	f := startDeadWorldFixture(t)
	f.setLevel(t, f.aria, 30)
	for _, payload := range [][]byte{{1}, {2}, nil} {
		f.send(t, f.connA, OpRevive, payload)
		p := f.read(t, f.connA, f.rA)
		rr, err := DecodeReviveResult(p.Data)
		if p.Opcode != OpReviveResult || err != nil || rr.Error != "not dead" {
			t.Errorf("a living character's OpRevive %v answered %#04x %+v (err %v), want \"not dead\"", payload, p.Opcode, rr, err)
		}
	}
	if !f.nothing(t, f.connB, f.rB) {
		t.Error("Bram heard of a living character's revive request")
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Zone != "jangan" || e.Life != world.LifeAlive {
		t.Errorf("after the refusals: life %d in %q, want alive in jangan", e.Life, e.Zone)
	}
}

// A dead GM's /tp stays refused (round 549's rule, gm.Actor.Dead); the way out
// is the resurrect choice.
func TestTeleportWhileDeadStaysRefused(t *testing.T) {
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return GMCommandHandler(chars, gm.ParseAccounts("alice"), &gm.Deps{Chars: chars, Monsters: combat.NewHub(), Zones: []string{"jangan", "donwhang"}}, hub, nil)
	})
	f.kill(t, f.aria, aiT0)
	f.send(t, f.connA, OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: "/tp -300 -880"}).Encode())
	p := f.read(t, f.connA, f.rA)
	if p.Opcode != OpGMCommandResult {
		t.Fatalf("/tp while dead answered %#04x, want the GM result", p.Opcode)
	}
	res, err := DecodeGMCommandResult(p.Data)
	if err != nil || !res.Refused || !strings.HasPrefix(res.Text, deadRefusal) {
		t.Errorf("/tp while dead: %+v (err %v), want the refusal %q", res, err, deadRefusal)
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeDead || e.Pos != (world.Position{}) {
		t.Errorf("after the refused /tp: life %d at %+v, want still dead where she fell", e.Life, e.Pos)
	}
}

// One death costs one EXP penalty, flag on or off, and the revive -- the
// return point's or the flag-off respawn's -- costs nothing more. Flag off, a
// monster's kill respawns her at once AT THE RETURN POINT (returnAfterKill),
// not beside the monster that killed her: the final release review's loop.
func TestADeathAtTheReturnPointCostsOnePenalty(t *testing.T) {
	tbl, err := leveldata.ParseCSV(strings.NewReader("level,exp,mastery_sp,exp_unit\n10,23500,9,235\n11,34898,12,259\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	loss, ok := tbl.DeathPenaltyExp(11, leveldata.DeathPenaltyKilledByMonster)
	if !ok || loss <= 0 {
		t.Fatalf("setup: no death penalty at level 11 (%d, %v)", loss, ok)
	}
	const startExp = 30000
	far := world.Position{X: 700, Z: 700}
	for _, flag := range []bool{true, false} {
		t.Run(map[bool]string{true: "dead state on", false: "dead state off"}[flag], func(t *testing.T) {
			battleForTest(t, true)
			deadStateForTest(t, flag)
			prev := levelTable
			SetLevelTable(tbl)
			t.Cleanup(func() { SetLevelTable(prev) })
			ctx := context.Background()
			f := startBattleFixture(t, 665, far.X, far.Z)
			c, _ := f.chars.GetByID(ctx, f.aria)
			if err := f.chars.SetLeveling(ctx, f.aria, 11, startExp, c.StatPoints, c.Str, c.Int); err != nil {
				t.Fatal(err)
			}
			f.hub.SetLevel(f.aria, 11)
			m := f.monsters.SpawnSpecies("jangan", chaseMangyang, far.X+8, 0, far.Z, 100000, 0, 100000, 0)
			f.a.runStrike(m.ID, strikeJob{m: *m, target: f.aria})
			after, _ := f.chars.GetByID(ctx, f.aria)
			if after.Exp != startExp-loss {
				t.Fatalf("exp after the kill = %d, want %d (one penalty of %d)", after.Exp, startExp-loss, loss)
			}
			_, home, _, _ := arrival(spawnZone)
			e, _ := f.hub.EntityByCharacterID(f.aria)
			if flag {
				if e.Life != world.LifeDead || e.Pos != far {
					t.Fatalf("flag on: life %d at %+v, want dead where she fell", e.Life, e.Pos)
				}
				// Option 1 over the wire, and its penalty count, is
				// TestOptionOneChargesNoSecondPenalty (this fixture's
				// sessions cannot send); here the in-place revive charges
				// nothing either.
				if _, _, err := revivePlayer(ctx, f.chars, nil, f.hub, f.aria); err != nil {
					t.Fatal(err)
				}
			} else if e.Life != world.LifeAlive || e.Pos != home {
				t.Errorf("flag off: life %d at %+v, want respawned alive at the return point %+v, not where she fell (%+v)", e.Life, e.Pos, home, far)
			}
			again, _ := f.chars.GetByID(ctx, f.aria)
			if again.Exp != startExp-loss || again.Level != 11 {
				t.Errorf("after the revive: exp %d level %d, want %d at 11 (the revive charges nothing)", again.Exp, again.Level, startExp-loss)
			}
		})
	}
}

// A character that leaves the world dead is saved at its return point
// (FUN_004df050's state-2 branch, `call 0x4e08a0` at 0x4df188), not where it
// fell, so it re-enters in town. Needs -persist-position.
func TestLeavingDeadSavesTheReturnPoint(t *testing.T) {
	SetPersistPosition(true)
	t.Cleanup(func() { SetPersistPosition(false) })
	f := startDeadWorldFixture(t)
	f.goDonwhang(t)
	f.kill(t, f.aria, aiT0)
	// The gateway's OnDisconnect, run for Aria's session (the fixture's
	// server installs none).
	e, _ := f.hub.EntityByCharacterID(f.aria)
	WorldDisconnectHandler(f.hub, f.chars)(e.Session)
	zone := spawnZone
	_, pos, _, _ := arrival(spawnZone)
	ok := waitFor(t, 2*time.Second, func() bool {
		c, err := f.chars.GetByID(context.Background(), f.aria)
		return err == nil && c.Zone == zone && c.PosX == pos.X && c.PosZ == pos.Z
	})
	if !ok {
		c, _ := f.chars.GetByID(context.Background(), f.aria)
		t.Errorf("Aria left dead in donwhang and was saved in %q at (%v, %v), want the return point %q at (%v, %v)", c.Zone, c.PosX, c.PosZ, zone, pos.X, pos.Z)
	}
}
