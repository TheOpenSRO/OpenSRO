package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
)

// TestMasteryTotalRefusal pins Mastery_LevelUp's (0x0059c4e0) total-cap branch
// for every selector: China (0) refuses once `sum + requested` passes 330 with no
// level term; Europe (1) once it passes 240.0 or `level + level`; selector 2 has
// no cap; anything else is 0x3801.
func TestMasteryTotalRefusal(t *testing.T) {
	if MasteryTotalCapChina != 330 {
		t.Fatalf("MasteryTotalCapChina = %d, want 330 (sum+requested < 0x14b)", MasteryTotalCapChina)
	}
	if MasteryTotalCapEurope != 240 {
		t.Fatalf("MasteryTotalCapEurope = %d, want 240 (the double at 0xb46130)", MasteryTotalCapEurope)
	}
	cases := []struct {
		name                          string
		country, total, req, charLevl int
		want                          uint16
	}{
		{"china 329+1 at level 1: no level term", equipment.CountryChina, 329, 1, 1, 0},
		{"china 330+1 at level 120", equipment.CountryChina, 330, 1, 120, 0x3805},
		{"china 0+1 at level 1", equipment.CountryChina, 0, 1, 1, 0},
		{"europe 239+1 at level 120", equipment.CountryEurope, 239, 1, 120, 0},
		{"europe 240+1 at level 120: the 240.0 ceiling", equipment.CountryEurope, 240, 1, 120, 0x3805},
		{"europe 99+1 at level 50: exactly 2 x level", equipment.CountryEurope, 99, 1, 50, 0},
		{"europe 100+1 at level 50: past 2 x level", equipment.CountryEurope, 100, 1, 50, 0x3805},
		{"selector 2 has no cap", masteryCountryUncapped, 100000, 1, 1, 0},
		{"country 3 has no rule", 3, 0, 1, 1, 0x3801},
		{"country 255 has no rule", 255, 0, 1, 1, 0x3801},
	}
	for _, c := range cases {
		if got := masteryTotalRefusal(c.country, c.total, c.req, c.charLevl); got != c.want {
			t.Errorf("%s: masteryTotalRefusal(%d, %d, %d, %d) = %#x, want %#x",
				c.name, c.country, c.total, c.req, c.charLevl, got, c.want)
		}
	}
}

// TestRaiseMasteryTotalCapIsFlatForChina drives RaiseMasteryHandler for China
// characters (every srrevamp character is one): the total cap is a flat 330,
// whatever the character's level, and the per-mastery character-level cap still
// binds on its own.
func TestRaiseMasteryTotalCapIsFlatForChina(t *testing.T) {
	ctx := context.Background()
	prevTable := levelTable
	SetLevelTable(nil) // masteryUpCost's fallback; the points below cover either
	t.Cleanup(func() { SetLevelTable(prevTable) })
	accounts := account.NewMemStore()
	acct, err := accounts.Add("alice", "hunter2")
	if err != nil {
		t.Fatalf("accounts.Add: %v", err)
	}
	chars := character.NewMemStore()
	skills := skill.NewMemStore()
	newChar := func(name string, level int) int64 {
		t.Helper()
		c, err := chars.Create(ctx, acct.ID, name)
		if err != nil {
			t.Fatalf("chars.Create(%s): %v", name, err)
		}
		if err := chars.SetLeveling(ctx, c.ID, level, 0, 0, character.StartingStr, character.StartingInt); err != nil {
			t.Fatalf("SetLeveling: %v", err)
		}
		if _, err := skills.AddSkillPoints(ctx, c.ID, 1000000); err != nil {
			t.Fatalf("AddSkillPoints: %v", err)
		}
		return c.ID
	}
	// Seeds a mastery straight into the store, bypassing the handler's caps.
	seed := func(id, mastery int64, to int) {
		t.Helper()
		for {
			lv, _ := skills.MasteryLevels(ctx, id)
			if lv[mastery] >= to {
				return
			}
			if _, err := skills.RaiseMastery(ctx, id, mastery, 0, MasteryLevelCap); err != nil {
				t.Fatalf("RaiseMastery: %v", err)
			}
		}
	}
	low := newChar("Aria", 5)
	high := newChar("Bria", 120)

	handle := gateway.Chain(LoginHandler(accounts), RaiseMasteryHandler(chars, skills))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(opcode uint16, data []byte) *proto.Packet {
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
	raise := func(name string, mastery int64) *RaiseMasteryResult {
		t.Helper()
		resp := send(OpRaiseMastery, (&RaiseMasteryRequest{CharacterName: name, MasteryID: mastery}).Encode())
		rr, err := DecodeRaiseMasteryResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeRaiseMasteryResult: %v", err)
		}
		return rr
	}

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	// (d) Level 5 with Bicheon 5: raising Bicheon is refused by the per-mastery
	// character-level cap (0x3804), not by the total.
	seed(low, 257, 5)
	if rr := raise("Aria", 257); rr.Error != "mastery at level cap" {
		t.Fatalf("level 5, Bicheon 5, raise Bicheon: got %+v, want 'mastery at level cap'", rr)
	}

	// (a) Level 5 with three masteries at 5 (total 15): a fourth still raises,
	// because China's cap has no level term. Under 3 x level it was refused.
	seed(low, 258, 5)
	seed(low, 259, 5)
	if rr := raise("Aria", 273); rr.Error != "" || rr.NewLevel != 1 {
		t.Fatalf("level 5, total 15, raise 273: got %+v, want NewLevel 1", rr)
	}

	// (c) The boundary at level 120: total 329 raises to 330 ...
	seed(high, 257, 120)
	seed(high, 258, 120)
	seed(high, 259, 89)
	if rr := raise("Bria", 259); rr.Error != "" || rr.NewLevel != 90 {
		t.Fatalf("level 120, total 329, raise 259: got %+v, want NewLevel 90", rr)
	}
	// (b) ... and at 120/120/90 (total 330) nothing more raises, although
	// 3 x 120 = 360 would have allowed it.
	if rr := raise("Bria", 273); rr.Error != "mastery total at cap" {
		t.Fatalf("level 120, total 330, raise 273: got %+v, want 'mastery total at cap'", rr)
	}
}
