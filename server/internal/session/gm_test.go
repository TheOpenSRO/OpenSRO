package session

import (
	"bufio"
	"context"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The GMCommandResult wire shape round-trips through its own encode/decode.
func TestGMCommandResultRoundTrip(t *testing.T) {
	cases := []GMCommandResult{
		{IsGM: false, Refused: true, Text: "GM commands are not enabled for your account."},
		{IsGM: true, Text: gm.Help},
		{IsGM: true, Text: "teleporting to -300.0, -880.0", HasPos: true, X: -300, Z: -880, Refresh: 0},
		{IsGM: true, Text: "travelling to donwhang", Zone: "donwhang"},
		{IsGM: true, Text: "level 1 -> 5", NewLevel: 5, StatPoints: 15, Refresh: gmRefreshStats},
		{IsGM: true, Text: "gave 5 x item 3", Refresh: gmRefreshInventory},
	}
	for _, want := range cases {
		got, err := DecodeGMCommandResult(want.Encode())
		if err != nil {
			t.Fatalf("decode %q: %v", want.Text, err)
		}
		if *got != want {
			t.Errorf("round trip:\n got %+v\nwant %+v", *got, want)
		}
	}
}

func TestGMCommandRequestRoundTrip(t *testing.T) {
	want := GMCommandRequest{Name: "Aria", Line: "/tp -300 -880", SelectedMonster: 42}
	got, err := DecodeGMCommandRequest(want.Encode())
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if *got != want {
		t.Errorf("round trip: got %+v, want %+v", *got, want)
	}
}

// The end-to-end gate: a non-GM is refused with a chat reply and IsGM
// false, a GM is answered and IsGM true, the enter-world probe (empty line)
// tells each which they are without a spurious refusal.
func TestGMGateOverTheWire(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	if _, err := accounts.Add("opensro", "pw"); err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.Add("stranger", "pw"); err != nil {
		t.Fatal(err)
	}
	chars := character.NewMemStore()
	items := refdata.NewMemStore()
	_ = items.ImportItems(ctx, []refdata.Item{{ID: 3, MaxStack: 50}})
	inv := inventory.NewMemStore(items)
	hub := world.NewHub()
	gate := gm.ParseAccounts("opensro,opensrogm")
	deps := &gm.Deps{Chars: chars, Inv: inv, Items: items, Monsters: combat.NewHub(),
		Species: []gm.Species{{Species: combat.Species{Name: "Mangyang", CodeName: "MOB_CH_MANGYANG"}, Zone: "jangan"}},
		Zones:   []string{"jangan"}}

	handle := gateway.Chain(LoginHandler(accounts), GMCommandHandler(chars, gate, deps, hub, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	// login returns a live connection already signed in as username, plus a
	// send helper bound to it.
	login := func(username string) func(line string, sel int64) *GMCommandResult {
		conn := dialTestServer(t, addr)
		t.Cleanup(func() { conn.Close() })
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
		resp := send(OpLogin, (&LoginRequest{Username: username, Password: "pw"}).Encode())
		if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
			t.Fatalf("login %s failed: err=%v result=%+v", username, err, lr)
		}
		return func(line string, sel int64) *GMCommandResult {
			t.Helper()
			resp := send(OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: line, SelectedMonster: sel}).Encode())
			if resp.Opcode != OpGMCommandResult {
				t.Fatalf("reply opcode 0x%04x, want the GM result", resp.Opcode)
			}
			out, err := DecodeGMCommandResult(resp.Data)
			if err != nil {
				t.Fatalf("decode result: %v", err)
			}
			return out
		}
	}

	// A GM needs a character to act on.
	gmAcct, _ := accounts.Authenticate(ctx, "opensro", "pw")
	if _, err := chars.Create(ctx, gmAcct.ID, "Aria"); err != nil {
		t.Fatal(err)
	}

	gmSend := login("opensro")
	if out := gmSend("", 0); !out.IsGM || out.Refused || out.Text != gm.Help {
		t.Fatalf("GM probe: %+v", out)
	}
	if out := gmSend("/give 3 5", 0); !out.IsGM || out.Refused || out.Refresh&gmRefreshInventory == 0 {
		t.Fatalf("GM /give: %+v", out)
	}
	if out := gmSend("/frobnicate", 0); !out.IsGM || !out.Refused || !strings.Contains(out.Text, "/tp") {
		t.Fatalf("GM unknown command: %+v", out)
	}

	strangerSend := login("stranger")
	if out := strangerSend("", 0); out.IsGM || out.Refused || out.Text != "" {
		t.Fatalf("non-GM probe should be silent and IsGM false: %+v", out)
	}
	if out := strangerSend("/give 3 5", 0); out.IsGM || !out.Refused || !strings.Contains(out.Text, "not enabled") {
		t.Fatalf("non-GM command should be refused: %+v", out)
	}
	// And the refused command changed nothing.
	if bag, _ := inv.List(ctx, 1); len(bag) != 5 && len(bag) != 1 {
		// The GM's own /give 3 5 put a stack of 5 in slot 0 of character 1;
		// the stranger's refusal must not have added a second character's bag
		// or a sixth item. Character ids start at 1 (the GM's Aria).
		t.Fatalf("bag after a refused command: %+v", bag)
	}
}

// THE RED (round 542): a GM's /spawn Mangyang 3 reaches the other player in
// the zone at once, with -monster-spawn-push on: Bram, in jangan, receives
// the three new monsters as three OpMonsterSpawned, in the order they were
// made, each with the heading it hatched facing. The GM receives the same
// three right after the command's reply. Before round 542 a GM /spawn reached
// other clients only on their next monster list (docs/TODO.md, the tester
// tools' item (3)), so Bram's count was 0 and this fails.
//
// CONTROL (passes before the change too): Cyra, in donwhang, receives none.
func TestGMSpawnReachesTheZone(t *testing.T) {
	spawnPushForTest(t, true)
	gate := gm.ParseAccounts("alice")
	z := startStrikeZone(t, func(chars character.Store, hub *world.Hub, monsters *combat.Hub) gateway.Handler {
		deps := &gm.Deps{Chars: chars, Monsters: monsters,
			Species: []gm.Species{{Species: strikeMangyang, Zone: "jangan", MaxHP: 54, Defense: 7}},
			Zones:   []string{"jangan", "donwhang"}}
		return GMCommandHandler(chars, gate, deps, hub, nil)
	})
	drawn := recordingHeadingRoll(z.monsters, 3)

	z.aria.write(t, OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: "/spawn Mangyang 3"}).Encode())
	p := z.aria.read(t)
	if p.Opcode != OpGMCommandResult {
		t.Fatalf("the GM's first packet is %#04x, want the command's reply", p.Opcode)
	}
	res, err := DecodeGMCommandResult(p.Data)
	if err != nil || res.Refused || res.Refresh&gmRefreshMonsters == 0 {
		t.Fatalf("/spawn Mangyang 3: %+v, %v", res, err)
	}
	spawned := z.monsters.InZone("jangan")
	if len(spawned) != 3 {
		t.Fatalf("%d monsters in jangan after /spawn Mangyang 3, want 3", len(spawned))
	}
	headings := drawn()
	if len(headings) != 3 {
		t.Fatalf("%d headings drawn for 3 spawns", len(headings))
	}

	// Aria's barrier first: her list request is handled after the GM handler
	// has returned, so once it answers every push has been sent, Bram's too.
	for _, c := range []*strikeClient{z.aria, z.bram} {
		pushes := spawnPushes(t, c.barrier(t))
		if len(pushes) != 3 {
			t.Fatalf("%s, in jangan, received %d OpMonsterSpawned, want 3", c.name, len(pushes))
		}
		for i, got := range pushes {
			m, ok := z.monsters.Get(got.Monster.ID)
			if !ok || m.Name != "Mangyang" || m.Zone != "jangan" {
				t.Errorf("%s's push %d is for monster %d, not one the /spawn made", c.name, i, got.Monster.ID)
				continue
			}
			if i > 0 && got.Monster.ID <= pushes[i-1].Monster.ID {
				t.Errorf("%s's pushes are not in spawn order: %d after %d", c.name, got.Monster.ID, pushes[i-1].Monster.ID)
			}
			if got.Heading != float32(headings[i]) || got.Heading != float32(m.Heading) {
				t.Errorf("%s's push %d faces %g, want the hatch heading %g", c.name, i, got.Heading, headings[i])
			}
			if !strings.Contains(res.Text, strconv.FormatInt(got.Monster.ID, 10)) {
				t.Errorf("monster %d is not among the ids the reply names: %q", got.Monster.ID, res.Text)
			}
		}
	}

	// CONTROL: another zone hears nothing.
	if n := len(spawnPushes(t, z.cyra.barrier(t))); n != 0 {
		t.Errorf("Cyra, in donwhang, received %d OpMonsterSpawned, want 0", n)
	}
}
