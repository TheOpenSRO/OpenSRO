package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/shop"
	"github.com/TheOpenSRO/OpenSRO/server/internal/storage"
)

// TestNPCServicesRefusedWhileTrading walks one trade through every phase, with
// the NPC services sharing the trade hub, and checks each service against the
// engine's INTERACTMODE gates (tradebusy.go):
//
//   - pending (mode 1 on both, OpenTradeSession 0x0047f620): buy, sell,
//     warehouse list/deposit/gold and repair refused (GObjPC_HandleShopMsg_046's
//     0x1c0b); the shop list and equipping still work (the equip gates test 2
//     and 7, not 1: StorageOperation's guard and Attach/DetachEquipItem);
//   - accepted (mode 2, EstablishTradeSession 0x0047f970): equip and unequip
//     refused, buy still refused;
//   - cancelled: everything works again;
//   - a cancel with only a REQUEST pending withdraws it.
func TestNPCServicesRefusedWhileTrading(t *testing.T) {
	ctx := context.Background()
	var eq *equipment.MemStore
	f := setupTradeTestWith(t, nil, func(d tradeFixtureDeps) []gateway.Handler {
		shopItems := stubShopItems{100: {ID: 100}, 200: {ID: 200}} // 100 costs shop.basePrice (100 gold)
		eq = equipment.NewMemStore(d.inv)
		warehouse := inventory.NewMemStore(shopItems)
		warehouse.SetCapacity(storage.DefaultCapacity)
		return []gateway.Handler{
			ShopHandler(d.chars, &shop.Service{Gold: d.chars, Inv: d.inv, Items: shopItems}, d.trades),
			StorageHandler(d.chars, &storage.Service{Bag: d.inv, Warehouse: warehouse, Gold: d.chars, Accounts: d.accounts}, d.trades),
			RepairHandlerWithBag(d.chars, eq, nil, nil, d.trades),
			EquipmentHandlerWithRules(d.chars, eq, d.inv, nil, d.trades),
		}
	})

	gold := func(id int64) int64 {
		t.Helper()
		c, err := f.chars.GetByID(ctx, id)
		if err != nil {
			t.Fatalf("GetByID(%d): %v", id, err)
		}
		return c.Gold
	}
	bagCount := func(id int64) int {
		t.Helper()
		slots, err := f.inv.List(ctx, id)
		if err != nil {
			t.Fatalf("inv.List(%d): %v", id, err)
		}
		n := 0
		for _, s := range slots {
			n += s.Quantity
		}
		return n
	}
	buy := func() *ShopBuyResult {
		t.Helper()
		resp := doSend(t, f.connA, f.rA, OpShopBuy, (&ShopBuyRequest{CharacterName: "Aria", ItemID: 100, Quantity: 1}).Encode())
		res, err := DecodeShopBuyResult(resp.Data)
		if err != nil {
			t.Fatalf("DecodeShopBuyResult: %v", err)
		}
		return res
	}
	equipResult := func(r *proto.Packet) *EquipmentResult {
		t.Helper()
		if r.Opcode != OpEquipmentResult {
			t.Fatalf("got opcode 0x%x, want OpEquipmentResult", r.Opcode)
		}
		res, err := DecodeEquipmentResult(r.Data)
		if err != nil {
			t.Fatalf("DecodeEquipmentResult: %v", err)
		}
		return res
	}
	ariaEquip := func() *EquipmentResult {
		t.Helper()
		return equipResult(doSend(t, f.connA, f.rA, OpEquip, (&EquipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon, InventorySlot: 0}).Encode()))
	}
	ariaUnequip := func() *EquipmentResult {
		t.Helper()
		return equipResult(doSend(t, f.connA, f.rA, OpUnequip, (&UnequipRequest{CharacterName: "Aria", Slot: equipment.SlotWeapon}).Encode()))
	}
	bramEquip := func() *EquipmentResult {
		t.Helper()
		return equipResult(doSend(t, f.connB, f.rB, OpEquip, (&EquipRequest{CharacterName: "Bram", Slot: equipment.SlotWeapon, InventorySlot: 0}).Encode()))
	}
	readCancelled := func(who string, conn net.Conn, r *bufio.Reader) {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		pkt, err := proto.Read(r, nil, nil)
		if err != nil || pkt.Opcode != OpTradeCancelled {
			t.Fatalf("%s: want OpTradeCancelled, got packet=%v err=%v", who, pkt, err)
		}
	}

	// ---- 1. PENDING: Aria has asked, Bram has not answered. ----
	requestTrade(t, f)

	// NEGATIVE: before round 499 this bought the sword for 100 gold.
	if res := buy(); res.OK || res.Reason != tradeBusyReason {
		t.Fatalf("pending: Aria's buy = %+v, want refused %q", res, tradeBusyReason)
	}
	if got := gold(f.ariaID); got != character.StartingGold {
		t.Fatalf("pending: Aria's gold %d, want %d untouched", got, character.StartingGold)
	}

	// The target is held too: OpenTradeSession writes 1 to BOTH parties.
	resp := doSend(t, f.connB, f.rB, OpShopSell, (&ShopSellRequest{CharacterName: "Bram", Slot: 0, Quantity: 1}).Encode())
	if res, err := DecodeShopSellResult(resp.Data); err != nil || res.OK || res.Reason != tradeBusyReason {
		t.Fatalf("pending: Bram's sell = %+v (err %v), want refused %q", res, err, tradeBusyReason)
	}
	if got := bagCount(f.bramID); got != 5 {
		t.Fatalf("pending: Bram's bag holds %d, want 5 (nothing sold)", got)
	}

	resp = doSend(t, f.connB, f.rB, OpStorageDeposit, (&StorageMoveRequest{CharacterName: "Bram", Slot: 0, Quantity: 1}).Encode())
	if res, err := DecodeStorageMoveResult(resp.Data); err != nil || res.OK || res.Reason != tradeBusyReason {
		t.Fatalf("pending: Bram's deposit = %+v (err %v), want refused %q", res, err, tradeBusyReason)
	}
	if got := bagCount(f.bramID); got != 5 {
		t.Fatalf("pending: Bram's bag holds %d, want 5 (nothing deposited)", got)
	}

	// The warehouse list and gold requests are refused the same way. The gold
	// refusal still carries both balances, the branch storage.go keeps because
	// the client redraws its gold lines from them.
	resp = doSend(t, f.connB, f.rB, OpStorageList, (&CharacterNameRequest{Name: "Bram"}).Encode())
	if res, err := DecodeStorageListResult(resp.Data); err != nil || res.Error != tradeBusyReason {
		t.Fatalf("pending: Bram's warehouse list = %+v (err %v), want refused %q", res, err, tradeBusyReason)
	}
	resp = doSend(t, f.connA, f.rA, OpStorageGold, (&StorageGoldRequest{CharacterName: "Aria", Op: StorageGoldDeposit, Amount: 50}).Encode())
	if res, err := DecodeStorageGoldResult(resp.Data); err != nil || res.OK || res.Reason != tradeBusyReason ||
		res.Carried != character.StartingGold || res.Stored != 0 {
		t.Fatalf("pending: Aria's gold deposit = %+v (err %v), want refused %q carrying %d carried / 0 stored",
			res, err, tradeBusyReason, character.StartingGold)
	}
	if got := gold(f.ariaID); got != character.StartingGold {
		t.Fatalf("pending: Aria's gold %d after a refused deposit, want %d", got, character.StartingGold)
	}

	resp = doSend(t, f.connA, f.rA, OpRepair, (&RepairRequest{CharacterName: "Aria", Slot: RepairAllSlots}).Encode())
	if res, err := DecodeRepairResult(resp.Data); err != nil || res.Code != interactionBusyCode {
		t.Fatalf("pending: Aria's repair = %+v (err %v), want code 0x%x", res, err, interactionBusyCode)
	}

	// The list changes nothing and is not refused.
	resp = doSend(t, f.connA, f.rA, OpShopList, (&ShopListRequest{ItemIDs: []int64{100}}).Encode())
	if res, err := DecodeShopListResult(resp.Data); err != nil || res.Error != "" || len(res.Entries) != 1 {
		t.Fatalf("pending: shop list = %+v (err %v), want one entry", res, err)
	}

	// Mode 1 does not lock equipment: the engine's equip gate is `== 2 || == 7`.
	if res := ariaEquip(); res.Error != "" || len(res.Items) != 1 {
		t.Fatalf("pending: Aria's equip = %+v, want the weapon on", res)
	}

	// ---- 2. ACCEPTED: the trade window is open. ----
	acceptTrade(t, f)

	if res := ariaUnequip(); res.Error != tradeEquipLockedReason {
		t.Fatalf("accepted: Aria's unequip = %+v, want %q", res, tradeEquipLockedReason)
	}
	if worn, _ := eq.Get(ctx, f.ariaID); len(worn) != 1 {
		t.Fatalf("accepted: Aria wears %+v, want the weapon still on", worn)
	}
	if res := bramEquip(); res.Error != tradeEquipLockedReason {
		t.Fatalf("accepted: Bram's equip = %+v, want %q", res, tradeEquipLockedReason)
	}
	if got := bagCount(f.bramID); got != 5 {
		t.Fatalf("accepted: Bram's bag holds %d, want 5 (nothing equipped)", got)
	}
	if res := buy(); res.OK || res.Reason != tradeBusyReason {
		t.Fatalf("accepted: Aria's buy = %+v, want refused %q", res, tradeBusyReason)
	}

	// ---- 3. CANCELLED: everything is free again. ----
	resp = doSend(t, f.connA, f.rA, OpTradeCancel, (&TradeCancelRequest{CharacterName: "Aria"}).Encode())
	if resp.Opcode != OpTradeCancelled {
		t.Fatalf("cancel: Aria got opcode 0x%x, want OpTradeCancelled", resp.Opcode)
	}
	readCancelled("Bram", f.connB, f.rB)

	if res := buy(); !res.OK {
		t.Fatalf("after cancel: Aria's buy = %+v, want OK", res)
	}
	if got, want := gold(f.ariaID), int64(character.StartingGold-100); got != want {
		t.Fatalf("after cancel: Aria's gold %d, want %d", got, want)
	}
	if res := ariaUnequip(); res.Error != "" || len(res.Items) != 0 {
		t.Fatalf("after cancel: Aria's unequip = %+v, want the weapon off", res)
	}
	if res := bramEquip(); res.Error != "" || len(res.Items) != 1 {
		t.Fatalf("after cancel: Bram's equip = %+v, want it on", res)
	}
	resp = doSend(t, f.connB, f.rB, OpStorageList, (&CharacterNameRequest{Name: "Bram"}).Encode())
	if res, err := DecodeStorageListResult(resp.Data); err != nil || res.Error != "" {
		t.Fatalf("after cancel: Bram's warehouse list = %+v (err %v), want it served", res, err)
	}
	resp = doSend(t, f.connA, f.rA, OpStorageGold, (&StorageGoldRequest{CharacterName: "Aria", Op: StorageGoldQuery}).Encode())
	if res, err := DecodeStorageGoldResult(resp.Data); err != nil || !res.OK || res.Carried != character.StartingGold-100 {
		t.Fatalf("after cancel: Aria's gold query = %+v (err %v), want OK carrying %d", res, err, character.StartingGold-100)
	}

	// ---- 4. A CANCEL WITH ONLY A REQUEST PENDING WITHDRAWS IT. ----
	// NEGATIVE: before round 499 handleTradeCancel only ended an OPEN trade,
	// so this cancel answered nothing and left both parties busy.
	requestTrade(t, f)
	resp = doSend(t, f.connA, f.rA, OpTradeCancel, (&TradeCancelRequest{CharacterName: "Aria"}).Encode())
	if resp.Opcode != OpTradeCancelled {
		t.Fatalf("withdraw: Aria got opcode 0x%x, want OpTradeCancelled", resp.Opcode)
	}
	if c, err := DecodeTradeCancelled(resp.Data); err != nil || c.CancelledByName != "Aria" {
		t.Fatalf("withdraw: Aria's OpTradeCancelled = %+v (err %v), want by Aria", c, err)
	}
	readCancelled("Bram", f.connB, f.rB)
	if f.trades.Busy(f.ariaID) || f.trades.Busy(f.bramID) {
		t.Fatal("withdraw: a party is still busy")
	}
	if res := buy(); !res.OK {
		t.Fatalf("after withdraw: Aria's buy = %+v, want OK", res)
	}
	resp = doSend(t, f.connB, f.rB, OpTradeRespond, (&TradeRespondRequest{CharacterName: "Bram", RequesterName: "Aria", Accept: true}).Encode())
	if rr, err := DecodeTradeRespondResult(resp.Data); err != nil || rr.OK {
		t.Fatalf("after withdraw: Bram accepted a withdrawn request: %+v (err %v)", rr, err)
	}
}
