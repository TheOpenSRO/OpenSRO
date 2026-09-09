package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func TestQuestListResultRoundTrip(t *testing.T) {
	want := &QuestListResult{
		Entries: []QuestCatalogEntry{
			{QuestID: 1, Name: "Mangyang Cull", MonsterName: "Mangyang", TargetKills: 3, GoldReward: 200, Kills: 1, Accepted: true},
		},
	}
	got, err := DecodeQuestListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeQuestListResult: %v", err)
	}
	if len(got.Entries) != 1 || got.Entries[0] != want.Entries[0] {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestQuestListResultErrorRoundTrip(t *testing.T) {
	want := &QuestListResult{Error: "failed to load quest progress"}
	got, err := DecodeQuestListResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeQuestListResult: %v", err)
	}
	if got.Error != want.Error || len(got.Entries) != 0 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestQuestAcceptRequestRoundTrip(t *testing.T) {
	want := &QuestAcceptRequest{CharacterName: "Aria", QuestID: 1}
	got, err := DecodeQuestAcceptRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeQuestAcceptRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestQuestCompletedRoundTrip(t *testing.T) {
	want := &QuestCompleted{QuestID: 1, GoldReward: 200}
	got, err := DecodeQuestCompleted(want.Encode())
	if err != nil {
		t.Fatalf("DecodeQuestCompleted: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestQuestFullFlow logs in, enters the world, accepts "Mangyang Cull" (kill 3
// Mangyangs), kills three one-hit-kill monsters via OpAttack, and
// confirms an OpQuestCompleted arrives with the right gold reward exactly
// on the third kill (not before) -- all through the real server stack,
// exercising the hook from combat's monster-death path into quest.Store.
func TestQuestFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	inv.TruncateForTest(ctx)
	inv.AddItem(ctx, c.ID, 100, 1)

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	eq.TruncateForTest(ctx)
	eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0)

	quests, err := quest.OpenSQLStore(inventoryTestDSN())
	if err != nil {
		t.Fatalf("quest.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer quests.Close()
	quests.TruncateForTest(ctx)

	hub := world.NewHub()
	monsters := combat.NewHub()

	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, items, hub, monsters, quests, inv),
		QuestHandler(chars, quests),
	)
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)

	send := func(opcode uint16, data []byte) *proto.Packet {
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

	resp := send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	resp = send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("enter world failed: err=%v result=%+v", err, ewr)
	}

	resp = send(OpQuestAccept, (&QuestAcceptRequest{CharacterName: "Aria", QuestID: 1}).Encode())
	if ar, err := DecodeQuestAcceptResult(resp.Data); err != nil || !ar.OK {
		t.Fatalf("accepting quest failed: err=%v result=%+v", err, ar)
	}

	// Accepting twice should fail cleanly.
	resp = send(OpQuestAccept, (&QuestAcceptRequest{CharacterName: "Aria", QuestID: 1}).Encode())
	if ar, err := DecodeQuestAcceptResult(resp.Data); err != nil || ar.OK || ar.Reason != "already accepted" {
		t.Fatalf("re-accepting quest: err=%v result=%+v", err, ar)
	}

	// One-hit-kill monsters (1 HP, 0 defense, 0 attack so there's no
	// counterattack noise): 30 weapon damage always kills in one hit.
	for i := 0; i < 3; i++ {
		monster := monsters.Spawn("jangan", "Mangyang", 0, 0, 0, 1, 0, 0, 10)
		resp = send(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: monster.ID}).Encode())
		ar, err := DecodeAttackResult(resp.Data)
		if err != nil || ar.Error != "" || !ar.MonsterDied {
			t.Fatalf("kill %d: err=%v result=%+v", i+1, err, ar)
		}

		if i < 2 {
			continue
		}

		// Third kill should trigger an OpQuestCompleted.
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		completedPkt, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("reading OpQuestCompleted: %v", err)
		}
		if completedPkt.Opcode != OpQuestCompleted {
			t.Fatalf("got opcode 0x%04x, want OpQuestCompleted", completedPkt.Opcode)
		}
		qc, err := DecodeQuestCompleted(completedPkt.Data)
		if err != nil || qc.QuestID != 1 || qc.GoldReward != 200 {
			t.Fatalf("unexpected QuestCompleted: %+v (err=%v)", qc, err)
		}
	}

	resp = send(OpQuestList, (&CharacterNameRequest{Name: "Aria"}).Encode())
	lr, err := DecodeQuestListResult(resp.Data)
	if err != nil || lr.Error != "" {
		t.Fatalf("listing quests failed: err=%v result=%+v", err, lr)
	}
	var found bool
	for _, e := range lr.Entries {
		if e.QuestID == 1 {
			found = true
			if !e.Accepted || !e.Completed || e.Kills != 3 {
				t.Fatalf("unexpected quest 1 entry: %+v", e)
			}
		}
	}
	if !found {
		t.Fatal("expected quest 1 in the catalog listing")
	}

	list, err := chars.ListByAccount(ctx, 1)
	if err != nil {
		t.Fatalf("ListByAccount: %v", err)
	}
	// StartingGold + 3x10 (monster kills) + 200 (quest reward).
	wantGold := int64(character.StartingGold) + 30 + 200
	if list[0].Gold != wantGold {
		t.Fatalf("got Gold %d, want %d", list[0].Gold, wantGold)
	}
}
