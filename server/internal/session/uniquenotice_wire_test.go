package session

import (
	"bufio"
	"bytes"
	"context"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/gm"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// TestUniqueSpawnReachesTheWorld is round 657's negative: it uses nothing the
// base lacks -- a GM's plain /spawn of a rank-3 species, and the opcode and
// payload as literal bytes -- so against the base it runs and times out
// waiting for 0x0110 on the other character's connection.
func TestUniqueSpawnReachesTheWorld(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "pw1")
	accounts.Add("bob", "pw2")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")
	hub := world.NewHub()
	deps := &gm.Deps{Chars: chars, Monsters: combat.NewHub(), Species: []gm.Species{
		{Species: combat.Species{Name: "Test Unique", CodeName: "MOB_TEST_UNIQUE", RefObjID: 1954, Level: 20, Rarity: 3}, MaxHP: 5000, Defense: 1},
	}}
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub),
		GMCommandHandler(chars, gm.ParseAccounts("alice"), deps, hub, nil))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	login := func(user, pw, name string) *chatClient {
		conn := dialTestServer(t, addr)
		t.Cleanup(func() { conn.Close() })
		c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
		c.send(OpLogin, (&LoginRequest{Username: user, Password: pw}).Encode())
		c.next(OpLoginResult)
		c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
		c.next(OpEnterWorldResult)
		return c
	}
	a := login("alice", "pw1", "Aria")
	b := login("bob", "pw2", "Bram")
	a.send(OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: "/spawn test unique"}).Encode())
	a.next(OpGMCommandResult)
	// 0x0110, word 0x0C05, RefObjID 1954.
	if got, want := b.next(0x0110).Data, []byte{0x05, 0x0c, 0xa2, 0x07, 0, 0}; !bytes.Equal(got, want) {
		t.Fatalf("Bram heard % x, want % x", got, want)
	}
}
