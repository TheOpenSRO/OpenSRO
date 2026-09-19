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
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// TestNewCharacterIsDressedAndHasVitals walks the exact sequence a client
// performs on a fresh install -- register, log in, create a character,
// enter the world, ask what it is wearing -- against the same handler
// chain and the same stores cmd/server wires with -in-memory.
//
// It exists because the first end-to-end render showed a character in
// nothing but shorts, and the server said why in its log: the starting kit
// had failed with "querying max stack for item 4734: not found", because a
// deployment with no imported reference data could not hold an item it had
// no row for. Every piece of the chain was individually tested and the
// whole of it was not.
func TestNewCharacterIsDressedAndHasVitals(t *testing.T) {
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	// Deliberately empty: a fresh deployment has imported nothing, and the
	// starting kit still has to work.
	refItems := refdata.NewMemStore()
	inv := inventory.NewMemStore(refItems)
	eq := equipment.NewMemStore(inv)
	hub := world.NewHub()

	handle := gateway.Chain(
		LoginHandler(accounts),
		RegisterHandler(accounts),
		CharacterHandlerWithHook(chars, func(ctx context.Context, characterID int64) error {
			return equipment.GiveStartingKit(ctx, inv, eq, characterID, character.DefaultGender)
		}),
		WorldHandler(chars, eq, hub),
		EquipmentHandler(chars, eq),
		InventoryHandler(chars, inv, refItems),
		CharacterStatsHandler(chars, eq, refItems, nil, nil),
	)
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

	resp := send(OpRegister, (&RegisterRequest{Username: "qa", Password: "qa-password"}).Encode())
	if rr, err := DecodeRegisterResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("register: err=%v result=%+v", err, rr)
	}
	resp = send(OpLogin, (&LoginRequest{Username: "qa", Password: "qa-password"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login: err=%v result=%+v", err, lr)
	}

	resp = send(OpCharacterCreate, (&CharacterCreateRequest{Name: "QaTester"}).Encode())
	if cr, err := DecodeCharacterCreateResult(resp.Data); err != nil || !cr.OK {
		t.Fatalf("character create: err=%v result=%+v", err, cr)
	}

	resp = send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "QaTester"}).Encode())
	entered, err := DecodeEnterWorldResult(resp.Data)
	if err != nil || !entered.OK {
		t.Fatalf("enter world: err=%v result=%+v", err, entered)
	}

	// The client draws its health bar from these two, and a zero maximum
	// leaves it blank.
	if entered.MaxHP <= 0 {
		t.Errorf("EnterWorldResult reports MaxHP %d, so the client cannot draw a health bar", entered.MaxHP)
	}
	if entered.HP <= 0 || entered.HP > entered.MaxHP {
		t.Errorf("EnterWorldResult reports HP %d of %d", entered.HP, entered.MaxHP)
	}

	// What the client asks next, and what decides whether the character
	// renders dressed.
	resp = send(OpEquipmentList, (&CharacterNameRequest{Name: "QaTester"}).Encode())
	worn, err := DecodeEquipmentResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeEquipmentResult: %v", err)
	}
	if worn.Error != "" {
		t.Fatalf("equipment list: %s", worn.Error)
	}
	kit := equipment.StartingKitFor(character.DefaultGender)
	if len(worn.Items) != len(kit) {
		t.Fatalf("a new character is wearing %d item(s), want %d -- the client renders bare without them",
			len(worn.Items), len(kit))
	}
	for slot, want := range kit {
		found := false
		for _, it := range worn.Items {
			if it.Slot == int(slot) {
				found = true
				if it.ItemID != want {
					t.Errorf("slot %v holds item %d, want %d", slot, it.ItemID, want)
				}
			}
		}
		if !found {
			t.Errorf("slot %v is empty on a new character", slot)
		}
	}

	// The kit is worn, not carried: an inventory holding a second copy
	// would be a duplication bug, and one holding the only copy would mean
	// the equip half silently failed.
	resp = send(OpInventoryList, (&CharacterNameRequest{Name: "QaTester"}).Encode())
	bag, err := DecodeInventoryListResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeInventoryListResult: %v", err)
	}
	if len(bag.Slots) != 0 {
		t.Errorf("a new character is carrying %d loose item(s), want them all worn", len(bag.Slots))
	}

	// And what the character panel and the inventory's gold readout show.
	// With no reference data the worn armour contributes nothing, which is
	// the point: it must answer rather than fail.
	resp = send(OpCharacterStats, (&CharacterNameRequest{Name: "QaTester"}).Encode())
	stats, err := DecodeCharacterStatsResult(resp.Data)
	if err != nil {
		t.Fatalf("DecodeCharacterStatsResult: %v", err)
	}
	if stats.Error != "" {
		t.Fatalf("character stats: %s", stats.Error)
	}
	if stats.Gold != character.StartingGold {
		t.Errorf("gold = %d, want the starting %d", stats.Gold, character.StartingGold)
	}
	if stats.MaxHP != int32(character.StartingMaxHP) || stats.HP != stats.MaxHP {
		t.Errorf("stats report %d/%d hp", stats.HP, stats.MaxHP)
	}
	if stats.PhysAttack <= 0 {
		t.Errorf("physical attack is %d; an unarmed character still hits", stats.PhysAttack)
	}
	if stats.PhysDefense != 0 {
		t.Errorf("physical defence is %d, want 0 from armour with no reference data", stats.PhysDefense)
	}
}

// TestCombatWorksWithoutReferenceData is the other half of the same
// problem. `attackerDamage` and `defenderArmor` looked every equipped item
// up in refdata and returned an error when it was missing -- so on a
// deployment that has imported none of it, a character wearing the starting
// kit could not be attacked at all: all five armour pieces failed the
// lookup. An item nobody has stats for now contributes nothing, and a
// weapon nobody has stats for hits as a bare fist.
func TestCombatWorksWithoutReferenceData(t *testing.T) {
	ctx := context.Background()
	refItems := refdata.NewMemStore()
	inv := inventory.NewMemStore(refItems)
	eq := equipment.NewMemStore(inv)

	if err := equipment.GiveStartingKit(ctx, inv, eq, 1, character.DefaultGender); err != nil {
		t.Fatalf("GiveStartingKit: %v", err)
	}

	armor, err := defenderArmor(ctx, 1, eq, refItems)
	if err != nil {
		t.Fatalf("defenderArmor with no reference data: %v", err)
	}
	if armor != 0 {
		t.Errorf("armour with no stats contributed %d", armor)
	}

	damage, err := attackerDamage(ctx, 1, 0, eq, refItems)
	if err != nil {
		t.Fatalf("attackerDamage with no reference data: %v", err)
	}
	if damage != unarmedDamage {
		t.Errorf("unarmed damage = %d, want %d", damage, unarmedDamage)
	}

	// A weapon with no row is the case that used to fail outright.
	if err := inv.AddItem(ctx, 1, 12345, 1); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	slots, _ := inv.List(ctx, 1)
	if err := eq.Equip(ctx, 1, equipment.SlotWeapon, slots[0].Index); err != nil {
		t.Fatalf("Equip: %v", err)
	}
	damage, err = attackerDamage(ctx, 1, 0, eq, refItems)
	if err != nil {
		t.Fatalf("attackerDamage with an unknown weapon: %v", err)
	}
	if damage != unarmedDamage {
		t.Errorf("an unknown weapon deals %d, want the unarmed %d", damage, unarmedDamage)
	}
}
