package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 838: a stall decoration (3/3/3/4) is stored as the character's
// decoration and spent; a second replaces the first; a BFI1 grant shows over
// it while it lasts and leaves it untouched.
func TestStallDecorationUseAndGrant(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	acc, _ := accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, acc.ID, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	const (
		mangyang = 3847
		ghost    = 3848
	)
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: mangyang, CodeName: "ITEM_MALL_BOOTH_MOB_MANGYANG", MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 4, CanUse: true},
		{ID: ghost, CodeName: "ITEM_MALL_BOOTH_MOB_BIGEYEGHOST", MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 4, CanUse: true},
	}); err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(items)
	if err := inv.AddItem(ctx, c.ID, mangyang, 1); err != nil {
		t.Fatal(err)
	}
	if err := inv.AddItem(ctx, c.ID, ghost, 1); err != nil {
		t.Fatal(err)
	}
	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), nil, nil, nil, nil, nil, nil, nil))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	send := func(op uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatal(err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	use := func(id int64) *UseItemResult {
		t.Helper()
		slots, _ := inv.List(ctx, c.ID)
		for _, s := range slots {
			if s.ItemID == id {
				res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(s.Index)}).Encode()).Data)
				if err != nil {
					t.Fatal(err)
				}
				return res
			}
		}
		t.Fatalf("item %d not in the bag", id)
		return nil
	}
	if got := StallDecorationOf(ctx, chars, c.ID); got != 0 {
		t.Fatalf("a new character's decoration %d, want 0", got)
	}
	if res := use(mangyang); res.Error != "" || res.Remaining != 0 || res.ItemID != mangyang {
		t.Fatalf("the Mangyang decoration: %+v", res)
	}
	if got := StallDecorationOf(ctx, chars, c.ID); got != mangyang {
		t.Fatalf("decoration %d, want %d", got, mangyang)
	}
	if res := use(ghost); res.Error != "" {
		t.Fatalf("the Big-eye Ghost decoration: %+v", res)
	}
	if got := StallDecorationOf(ctx, chars, c.ID); got != ghost {
		t.Fatalf("decoration %d, want %d (the second replaces the first)", got, ghost)
	}
	slots, _ := inv.List(ctx, c.ID)
	if len(slots) != 0 {
		t.Errorf("both decorations should be spent: %+v", slots)
	}

	// The BFI1 grant: shown while it lasts, the stored decoration untouched.
	now := time.Now()
	stallClock = func() time.Time { return now }
	t.Cleanup(func() { stallClock = time.Now; GrantStallDecoration(c.ID, 0, time.Time{}) })
	GrantStallDecoration(c.ID, mangyang, now.Add(2419200*time.Second))
	if got := StallDecorationOf(ctx, chars, c.ID); got != mangyang {
		t.Fatalf("with the BFI1 grant: %d, want %d", got, mangyang)
	}
	now = now.Add(2419201 * time.Second)
	if got := StallDecorationOf(ctx, chars, c.ID); got != ghost {
		t.Fatalf("after the grant ran out: %d, want the stored %d", got, ghost)
	}
}
