package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/specialty"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const fxGood = 2147 // ITEM_ETC_TRADE_CH_01

// The specialty trade over a real socket (round 801): a trader's buy into
// the transport and its refusals, the quotation list on the 0xc open, the
// sale at another town's NPC with its gold, job exp, contribution and pool,
// the trade scale's 0x30E8, the trade-info reply and the stolen-goods
// refusal.
func TestRound801SpecialtyTrade(t *testing.T) {
	ctx := context.Background()
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: fxGood, CodeName: "ITEM_ETC_TRADE_CH_01", MaxStack: 5000, TypeID1: 3, TypeID2: 3, TypeID3: 8, TypeID4: 1,
			Price: 4000, SellPrice: 4000, CanSell: true, CanPick: true},
	}); err != nil {
		t.Fatal(err)
	}
	cols := make([]string, len(species.CSVColumns))
	for i, c := range species.CSVColumns {
		switch c {
		case "ID":
			cols[i] = "1906"
		case "CodeName":
			cols[i] = "COS_T_DONKEY"
		case "TypeID4":
			cols[i] = "2"
		case "Rarity", "InventorySize":
			cols[i] = "1"
		case "Level":
			cols[i] = "20"
		case "MaxHP":
			cols[i] = "3933"
		case "WalkSpeed":
			cols[i] = "19"
		case "RunSpeed":
			cols[i] = "36"
		case "Model", "OrgCodeName", "NameKey", "Name", "DescStrID":
			cols[i] = ""
		default:
			cols[i] = "0"
		}
	}
	table, err := species.Read(strings.NewReader(strings.Join(species.CSVColumns, ",") + "\n" + strings.Join(cols, ",") + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	// Level 30's levelgold minimum 1000: Unit 1250.
	lt, err := leveldata.ParseCSV(strings.NewReader("level,exp\n30,100,1,1,15000000,15000000,15000000,1000\n"))
	if err != nil {
		t.Fatal(err)
	}
	old := levelTable
	SetLevelTable(lt)
	t.Cleanup(func() { SetLevelTable(old) })

	chars := character.NewMemStore()
	accounts := account.NewMemStore()
	if _, err := accounts.Register(ctx, "trader", "pw"); err != nil {
		t.Fatal(err)
	}
	acct, _ := accounts.Authenticate(ctx, "trader", "pw")
	c0, err := chars.Create(ctx, acct.ID, "Tess")
	if err != nil {
		t.Fatal(err)
	}
	cid := c0.ID
	if err := chars.SetLeveling(ctx, cid, 30, 0, 0, 20, 20); err != nil {
		t.Fatal(err)
	}
	_ = chars.AddGold(ctx, cid, 1000000)
	start, _ := chars.GetByID(ctx, cid)

	hub := world.NewHub()
	store := cos.NewMemStore()
	bags := inventory.NewMemStore(items)
	bags.SetCapacityFunc(func(ctx context.Context, id int64) int {
		r, err := store.Get(ctx, id)
		if err != nil {
			return 0
		}
		return r.InvSize
	})
	inv := inventory.NewMemStore(items)
	SetCOSDeps(store, bags, table, nil, inv, items, chars, hub, nil, nil)
	t.Cleanup(func() { SetCOSDeps(nil, nil, nil, nil, nil, nil, nil, nil, nil, nil) })
	js := jobs.NewMemStore()
	SetJobDeps(JobDeps{Store: js, Chars: chars, Hub: hub})
	t.Cleanup(func() { jobRT.Store(nil) })
	_ = js.Save(ctx, jobs.Record{CharID: cid, Kind: jobs.KindTrader, Level: 1})
	if err := js.SetAlias(ctx, cid, "Merchy"); err != nil {
		t.Fatal(err)
	}
	jobStates.Store(cid, byte(4))
	t.Cleanup(func() { jobStates.Delete(cid); jobRecs.Delete(cid); forgetTradeScale(cid) })

	buyer := npcAt(7, 100, 0, npcspawn.FromNest)
	buyer.Code, buyer.RefID, buyer.Shop = "NPC_CH_SPECIAL", 2010, true
	buyer.Flags, buyer.Interact = npcspawn.FlagInteractions, []byte{1, 0x0c}
	seller := npcAt(8, 120, 0, npcspawn.FromNest)
	seller.Code, seller.RefID, seller.Shop = "NPC_WC_SPECIAL", 2059, true
	seller.Flags, seller.Interact = npcspawn.FlagInteractions, []byte{1, 0x0c}
	installNPCsForTest(t, buyer, seller)

	rows, _ := specialty.ReadQuotes(strings.NewReader("1,1,2059,2147,1.1,1.1,1.1,50000,250,50000\n"))
	SetSpecialtyDeps(SpecialtyDeps{
		Board: specialty.NewBoard(rows, func(int64) int64 { return 4000 }),
		Shops: specialty.Shops{"NPC_CH_SPECIAL": {{NPC: "NPC_CH_SPECIAL", Item: fxGood, Specialty: true}},
			"NPC_WC_SPECIAL": {{NPC: "NPC_WC_SPECIAL", Slot: 0, Item: 2151, Specialty: true}}},
		Items: items, Chars: chars,
	})
	t.Cleanup(func() { specialtyRT.Store(nil) })

	eq := equipment.NewMemStore(inventory.NewMemStore(nil))
	trades := trade.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub), NPCTalkHandler(hub, trades),
		ItemOpHandler(ItemOpDeps{Hub: hub, Inv: inv, Items: items, Chars: chars, Trades: trades}), TradeInfoHandler())
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	conn := dialTestServer(t, srv.Addr)
	t.Cleanup(func() { conn.Close() })
	c := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	c.send(OpLogin, (&LoginRequest{Username: "trader", Password: "pw"}).Encode())
	if lr, err := DecodeLoginResult(c.next(OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	c.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Tess"}).Encode())
	if er, err := DecodeEnterWorldResult(c.next(OpEnterWorldResult).Data); err != nil || !er.OK {
		t.Fatalf("enter: %v %+v", err, er)
	}
	e, ok := hub.FindByName("Tess")
	if !ok {
		t.Fatal("not in the world")
	}
	if e.Zone != "jangan" {
		t.Skipf("the test NPCs stand in the jangan frame; the world put Tess in %q", e.Zone)
	}
	hub.Relocate(e.Session, world.Position{X: 110, Z: 0}, world.MoveRelocate, 0)
	e, _ = hub.FindByName("Tess")

	buy := func(tab, slot byte, count uint16) {
		b := []byte{ItemMoveBuyToCOS, 0, 0, 0, 0, tab, slot}
		b = binary.LittleEndian.AppendUint16(b, count)
		b = binary.LittleEndian.AppendUint32(b, buyer.UID)
		c.send(OpItemMove, b)
	}
	sell := func(npc uint32, slot byte, count uint16) {
		b := []byte{ItemMoveSellFromCOS, 0, 0, 0, 0, slot}
		b = binary.LittleEndian.AppendUint16(b, count)
		b = binary.LittleEndian.AppendUint32(b, npc)
		c.send(OpItemMove, b)
	}
	expectFail := func(code uint16, what string) {
		t.Helper()
		if got := c.next(OpItemMoveResult).Data; !bytes.Equal(got, EncodeItemFail(code)) {
			t.Fatalf("%s: % x, want the refusal 0x%x", what, got, code)
		}
	}

	// No transport: 5.
	buy(0, 0, 100)
	expectFail(tradeErrNoTransport, "no transport")

	row, _ := cosRowByCode("COS_T_DONKEY")
	rec := cos.Record{OwnerCharID: cid, RefCharID: row.ID, HP: row.MaxHP, Level: row.Level,
		State: cos.StateAlive | cos.StateSummoned}
	id, err := store.Create(ctx, rec)
	if err != nil {
		t.Fatal(err)
	}
	rec.ID = id
	o := spawnCOS(e, rec, row, 0, -1, cosSpawnTypeSummoned, time.Now())
	if o.rec.InvSize != 1 {
		t.Fatalf("the donkey's bag: %d, want min(InventorySize 1, cap 259)", o.rec.InvSize)
	}
	data := c.next(cos.OpCOSData).Data
	if data[16] != 1 {
		t.Fatalf("0x30C8's bag size byte: % x", data)
	}

	// Out of the trader's suit: 0x1860.
	buy(0, 0, 100)
	expectFail(tradeErrOnlyTrader, "no trader suit")
	jobStates.Store(cid, byte(jobs.KindTrader))
	buy(1, 0, 100)
	expectFail(tradeErrBadTab, "tab 1")
	buy(0, 3, 100)
	expectFail(ItemErrEmptySource, "an empty slot")
	buy(0, 0, 5001)
	expectFail(tradeErrPastStack, "past MaxStack")

	// The buy: 100 x 4000, the gold first (0x304E unshown), then the result,
	// then the scale: 100 x 348 / 1250 = 27.84 -> 27 <= 510: one star.
	buy(0, 0, 100)
	g := c.next(charmsg.OpCharInfo).Data
	if !bytes.Equal(g, charmsg.EncodeGold(start.Gold-400000, false)) {
		t.Fatalf("gold after the buy: % x", g)
	}
	want := []byte{1, ItemMoveBuyToCOS}
	want = binary.LittleEndian.AppendUint32(want, o.uid)
	want = append(want, 0, 0, 1, 0, 100, 0)
	if got := c.next(OpItemMoveResult).Data; !bytes.Equal(got, want) {
		t.Fatalf("the buy: % x, want % x", got, want)
	}
	if got := c.next(OpTradeScale).Data; !bytes.Equal(got, []byte{1}) {
		t.Fatalf("0x30E8: % x", got)
	}
	slots, _ := bags.List(ctx, id)
	if len(slots) != 1 || slots[0].Quantity != 100 || slots[0].Creator != "Merchy" {
		t.Fatalf("the transport's bag: %+v", slots)
	}
	// One slot, taken: 0x1807.
	buy(0, 0, 1)
	expectFail(ItemErrBagFull, "the full bag")

	// The open of 0xc at the other town: 0xB046 {1, 0xc, 0}, then its list.
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(seller.UID))
	c.next(npctalk.OpSelectResult)
	c.send(npctalk.OpOpen, append(npctalk.EncodeEntity(seller.UID), 0x0c))
	if got := c.next(npctalk.OpOpenResult).Data; !bytes.Equal(got, []byte{1, 0x0c, 0}) {
		t.Fatalf("0xB046: % x", got)
	}
	wantPrices := []byte{1}
	wantPrices = binary.LittleEndian.AppendUint32(wantPrices, fxGood)
	wantPrices = binary.LittleEndian.AppendUint32(wantPrices, 4400)
	if got := c.next(OpTradePrices).Data; !bytes.Equal(got, wantPrices) {
		t.Fatalf("0x30E0: % x", got)
	}

	// Round 802, the safe trade: the dialog closed (EndInteraction in mode
	// 6 at an NPC with 0xc) by a trader carrying normal goods at one star
	// grants it, the first of TRADE_SAFETY_NUM 8 today: {1, 0x50, 1, 8}.
	c.send(npctalk.OpEnd, npctalk.EncodeEntity(seller.UID))
	c.next(npctalk.OpEndResult)
	if got := c.next(OpSafeTrade).Data; !bytes.Equal(got, []byte{1, 0x50, 1, 8}) {
		t.Fatalf("0x34D5 at the close: % x", got)
	}
	if r := jobRecord(ctx, cid); !r.Safe.Status || r.Safe.Count != 1 {
		t.Fatalf("the safe trade record: %+v", r.Safe)
	}
	c.send(npctalk.OpSelect, npctalk.EncodeEntity(seller.UID))
	c.next(npctalk.OpSelectResult)
	c.send(npctalk.OpOpen, append(npctalk.EncodeEntity(seller.UID), 0x0c))
	c.next(npctalk.OpOpenResult)
	c.next(OpTradePrices)

	// The sale of 100 at 4400: gold 440000, profit 40000; job exp 40000 x
	// 0.8 (one star) = 32000; contribution and the hunters' pool 44000.
	sell(seller.UID, 0, 100)
	// Selling his own goods ends the safe trade (s:0x4c8e20): {0, 0x40}.
	if got := c.next(OpSafeTrade).Data; !bytes.Equal(got, []byte{0, 0x40}) {
		t.Fatalf("0x34D5 at the sale: % x", got)
	}
	g = c.next(charmsg.OpCharInfo).Data
	if !bytes.Equal(g, charmsg.EncodeGold(start.Gold-400000+440000, false)) {
		t.Fatalf("gold after the sale: % x", g)
	}
	x := c.next(jobs.OpJobExp).Data
	if x[0] != byte(jobs.KindTrader) || binary.LittleEndian.Uint32(x[2:]) != 32000 {
		t.Fatalf("0x30E6: % x", x)
	}
	want = []byte{1, ItemMoveSellFromCOS}
	want = binary.LittleEndian.AppendUint32(want, o.uid)
	want = append(want, 0, 100, 0)
	want = binary.LittleEndian.AppendUint32(want, seller.UID)
	want = append(want, 0xFF)
	if got := c.next(OpItemMoveResult).Data; !bytes.Equal(got, want) {
		t.Fatalf("the sale: % x, want % x", got, want)
	}
	if got := c.next(OpTradeScale).Data; !bytes.Equal(got, []byte{0}) {
		t.Fatalf("0x30E8 after the sale: % x", got)
	}
	if r := jobRecord(ctx, cid); r.Contribution != 44000 {
		t.Fatalf("contribution %d", r.Contribution)
	}
	if p, _ := js.TakePool(ctx, jobs.KindHunter); p != 44000 {
		t.Fatalf("the hunters' pool %d", p)
	}

	// The trade-info window: 110 %.
	c.send(OpTradeInfo, binary.LittleEndian.AppendUint32(nil, 2059))
	wantInfo := binary.LittleEndian.AppendUint16(nil, 1)
	wantInfo = binary.LittleEndian.AppendUint32(wantInfo, fxGood)
	wantInfo = binary.LittleEndian.AppendUint16(wantInfo, 110)
	if got := c.next(OpTradeInfoResult).Data; !bytes.Equal(got, wantInfo) {
		t.Fatalf("0xB4D4: % x", got)
	}

	// Someone else's goods at a specialty NPC: 0x1868.
	if err := bags.PlaceItemInstance(ctx, id, 0, fxGood, 10, inventory.Instance{Durability: -1, Creator: "Other"}); err != nil {
		t.Fatal(err)
	}
	sell(seller.UID, 0, 10)
	expectFail(tradeErrStolen, "stolen goods at a specialty NPC")
}

// Who may pick a good off the ground (FUN_00525dc0's routing).
func TestRound801GoodPickRules(t *testing.T) {
	for _, c := range []struct {
		state byte
		own   bool
		want  uint16
	}{
		{1, true, 0}, {1, false, tradeErrNotBuyer},
		{2, false, 0}, {2, true, tradeErrRobberOwn},
		{3, false, tradeErrNotBuyer}, {4, false, tradeErrNoJobPick},
	} {
		if got := goodPickCode(c.state, c.own); got != c.want {
			t.Fatalf("state %d own %v: 0x%x, want 0x%x", c.state, c.own, got, c.want)
		}
	}
}

// The leash: refused only beyond 1000 and stepping farther.
func TestRound801Leash(t *testing.T) {
	cart := world.Position{}
	far := world.Position{X: 1001}
	if dist2(far, cart) <= specialty.LeashRange {
		t.Fatal("1001 is past the leash")
	}
	if dist2(world.Position{X: 999}, cart) > specialty.LeashRange {
		t.Fatal("999 is inside the leash")
	}
}
