package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// The engine's own rule for spending stat points, GObjPC_SpendStatPoints
// (0x00511470): a spend of s+i is refused unless s+i <= the unspent pool, and
// it only ever ADDS -- Str += s, Int += i, pool -= s+i. A new character has
// no pool, a level-up grants five and auto-spends two (GObjPC_SetLevel), so
// here the pool is set directly and the rule is exercised on it.
func TestSpendStatPointsFollowsTheEngineRule(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	acct, err := accounts.Add("alice", "hunter2")
	if err != nil {
		t.Fatalf("accounts.Add: %v", err)
	}
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, acct.ID, "Aria")
	if err != nil {
		t.Fatalf("chars.Create: %v", err)
	}
	// Level 2 with the three unspent points the public server measured.
	if err := chars.SetLeveling(ctx, c.ID, 2, 3, 3, 21, 21); err != nil {
		t.Fatalf("SetLeveling: %v", err)
	}

	handle := gateway.Chain(LoginHandler(accounts), SpendStatPointsHandler(chars, nil, nil, nil, nil))
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
	spend := func(s, i uint8) *CharacterStatsResult {
		t.Helper()
		resp := send(OpSpendStatPoints, (&SpendStatPointsRequest{Name: "Aria", Str: s, Int: i}).Encode())
		if resp.Opcode != OpCharacterStatsResult {
			t.Fatalf("reply opcode 0x%04x, want the stats result", resp.Opcode)
		}
		out, err := DecodeCharacterStatsResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeCharacterStatsResult: %v", err)
		}
		return out
	}

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}

	// Over the pool: refused, nothing moves.
	if out := spend(3, 1); out.Error != "not enough stat points" {
		t.Fatalf("spending 4 of 3: got %+v, want refused", out)
	}
	if got, _ := chars.GetByID(ctx, c.ID); got.Str != 21 || got.Int != 21 || got.StatPoints != 3 {
		t.Fatalf("a refused spend changed the character: %+v", got)
	}
	// Nothing at all: refused.
	if out := spend(0, 0); out.Error != "nothing to spend" {
		t.Fatalf("spending 0: got %+v, want refused", out)
	}
	// Within the pool: plain increments, pool down by the sum, and the reply
	// carries the new numbers (with MaxHP following Str: 23*10*1.02 = 234).
	out := spend(2, 1)
	if out.Error != "" {
		t.Fatalf("spending 3 of 3: refused %q", out.Error)
	}
	if out.Str != 23 || out.Int != 22 || out.StatPoints != 0 {
		t.Fatalf("after the spend: Str=%d Int=%d pool=%d, want 23/22/0", out.Str, out.Int, out.StatPoints)
	}
	if want := int32(character.MaxHPFor(23, 2)); out.MaxHP != want {
		t.Fatalf("MaxHP after the spend %d, want %d (MaxHPFor(23, 2))", out.MaxHP, want)
	}
	if out := spend(1, 0); out.Error != "not enough stat points" {
		t.Fatalf("spending from an empty pool: got %+v, want refused", out)
	}
}
