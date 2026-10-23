package session

import (
	"bufio"
	"context"
	"io"
	"math"
	"math/rand"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/cos"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/jobs"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/species"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// donkeyTable is a COS table with COS_T_DONKEY (1906, rarity 1, bag 1).
func donkeyTable(t *testing.T) *species.Table {
	t.Helper()
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
	tab, err := species.Read(strings.NewReader(strings.Join(species.CSVColumns, ",") + "\n" + strings.Join(cols, ",") + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	return tab
}

// A caravan's wave (round 804): a trader's transport with goods, registered,
// fires past its threshold -- NPC thieves of the wave's levels under the
// 2001+ tactics, on the 150 ring round the transport; with the goods gone
// the caravan is dropped and its idle monsters removed.
func TestRound804CaravanWave(t *testing.T) {
	ctx := context.Background()
	resetCOSWorld()
	t.Cleanup(func() {
		resetCOSWorld()
		cosWorld.deps.Store(nil)
		caravanRT.Store(nil)
		monsterAIRuntime.Store(nil)
	})
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{{ID: fxGood, CodeName: "ITEM_ETC_TRADE_CH_01", MaxStack: 5000,
		TypeID1: 3, TypeID2: 3, TypeID3: 8, TypeID4: 1, Price: 4000, SellPrice: 4000, CanSell: true, CanPick: true}}); err != nil {
		t.Fatal(err)
	}
	lt, err := leveldata.ParseCSV(strings.NewReader("level,exp\n30,100,1,1,15000000,15000000,15000000,1000\n"))
	if err != nil {
		t.Fatal(err)
	}
	old := levelTable
	SetLevelTable(lt)
	t.Cleanup(func() { SetLevelTable(old) })
	chars := character.NewMemStore()
	accounts := account.NewMemStore()
	accounts.Add("tess", "pw")
	c0, _ := chars.Create(ctx, 1, "Tess")
	cid := c0.ID
	_ = chars.SetLeveling(ctx, cid, 30, 0, 0, 20, 20)
	hub := world.NewHub()
	srv := &gateway.Server{Addr: freeAddr(t), Handle: gateway.Chain(LoginHandler(accounts),
		WorldHandler(chars, equipment.NewMemStore(inventory.NewMemStore(nil)), hub))}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	conn := dialTestServer(t, srv.Addr)
	t.Cleanup(func() { conn.Close() })
	cl := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	cl.send(OpLogin, (&LoginRequest{Username: "tess", Password: "pw"}).Encode())
	cl.next(OpLoginResult)
	cl.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Tess"}).Encode())
	cl.next(OpEnterWorldResult)
	go func() { _, _ = io.Copy(io.Discard, conn) }()
	e, _ := hub.EntityByCharacterID(cid)
	sess := e.Session
	hub.Relocate(sess, world.Position{X: 100, Z: 100}, world.MoveRelocate, 0)
	e, _ = hub.EntityByCharacterID(cid)

	store := cos.NewMemStore()
	bags := inventory.NewMemStore(items)
	bags.SetCapacityFunc(func(ctx context.Context, id int64) int { return 5 })
	SetCOSDeps(store, bags, donkeyTable(t), nil, inventory.NewMemStore(items), items, chars, hub, nil, nil)
	js := jobs.NewMemStore()
	SetJobDeps(JobDeps{Store: js, Chars: chars, Hub: hub})
	t.Cleanup(func() { jobRT.Store(nil); jobStates.Delete(cid); jobRecs.Delete(cid); forgetTradeScale(cid) })
	// A safe-trading trader (Status 1, round 811): the safe trade does not
	// stop a wave. READ: its Status (TrijobMgr record +0x20, getter
	// s:0x60e4d0) is read only by the 0x34D5 sender (s:0x51a9f3..0x51ab3f),
	// the player-thief caravan rule (s:0x52b7a1 / 0x52b7fa) and the grant
	// (s:0x60e933) -- not by the caravan tick, the wave, its count or the
	// monsters' target filters.
	_ = js.Save(ctx, jobs.Record{CharID: cid, Kind: jobs.KindTrader, Level: 1, Safe: jobs.SafeTrade{Status: true, Count: 1}})
	jobStates.Store(cid, jobs.StateTrader)
	SetSpecialtyDeps(SpecialtyDeps{Items: items, Chars: chars})
	t.Cleanup(func() { specialtyRT.Store(nil) })

	monsters := combat.NewHub()
	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{}, rand.New(rand.NewSource(3)), (&pushRecorder{}).push)
	monsterAIRuntime.Store(a)
	var thieves, hunters jobs.MobLevels
	specs := map[int64]*combat.MinionSpec{}
	for lv := 20; lv <= 40; lv++ {
		id := int64(9000 + lv)
		thieves.Add(0, lv, id)
		specs[id] = &combat.MinionSpec{Species: combat.Species{Name: "Thief", CodeName: "MOB_THIEF_NPC_TEST", RefObjID: id, Level: lv,
			BCRadius: 4}, MaxHP: 500, Defense: 10, Attack: 10}
		hunters.Add(0, lv, id+1000)
	}
	tactics := map[int64]*combat.Tactics{}
	for _, id := range []int64{2001, 2002, 2003, 2004, 2011, 2012, 2013, 2014} {
		tactics[id] = &combat.Tactics{ID: id, SightRange: 250, Flags: 542, RoamRadius: MonsterRoamRadius}
	}
	SetCaravanDeps(CaravanDeps{Thieves: &thieves, Hunters: &hunters, Specs: specs, Tactics: tactics, Hub: hub,
		Monsters: monsters, Rand: rand.New(rand.NewSource(7))})

	// No transport: nothing registers.
	caravanOnEnd(ctx, sess, hub, 0, 6)
	registerCaravanIfGoods := func() { registerCaravan(ctx, cid, "test") }
	row, _ := cosRowByCode("COS_T_DONKEY")
	rec := cos.Record{OwnerCharID: cid, RefCharID: row.ID, HP: row.MaxHP, Level: row.Level, State: cos.StateAlive | cos.StateSummoned}
	recID, _ := store.Create(ctx, rec)
	rec.ID = recID
	o := spawnCOS(e, rec, row, 0, -1, cosSpawnTypeSummoned, time.Now())
	if err := bags.PlaceItemInstance(ctx, recID, 0, fxGood, 100, inventory.Instance{Durability: -1, Creator: "Merchy"}); err != nil {
		t.Fatal(err)
	}
	registerCaravanIfGoods()
	rt := caravanRT.Load()
	rt.mu.Lock()
	c := rt.list[cid]
	rt.mu.Unlock()
	if c == nil || c.threshold < 60000 || c.threshold > 120000 {
		t.Fatalf("the caravan %+v, want a threshold in 60..120 s", c)
	}
	// A second registration leaves it alone.
	c.acc = 5
	registerCaravanIfGoods()
	if rt.list[cid] != c || c.acc != 5 {
		t.Fatal("a registered caravan was registered again")
	}

	if v := tradeAmountOf(ctx, cid, 30); specialtyNow().d.Thresholds.Scale(v) != 1 || !jobRecord(ctx, cid).Safe.Status {
		t.Fatalf("want a 1-star caravan under a safe trade: amount %d, safe %+v", v, jobRecord(ctx, cid).Safe)
	}
	rt.tick(ctx, 120000)
	all := monsters.InZone("jangan")
	if len(all) == 0 {
		t.Fatal("no wave round a safe-trading 1-star caravan (the original sends one: 0 counts 1, s:0x60c468)")
	}
	cosWorld.mu.Lock()
	tp := o.at(time.Now())
	cosWorld.mu.Unlock()
	for _, m := range all {
		if !strings.HasPrefix(m.CodeName, "MOB_THIEF") {
			t.Fatalf("a trader's wave is NPC thieves: %s", m.CodeName)
		}
		// Level 30, scale 1 (100 goods: 27 <= 510): max(26, 16) - 1 + p + k, p 1 or 2, k 0..4.
		if m.Level < 26 || m.Level > 26-1+2+4 {
			t.Fatalf("wave level %d", m.Level)
		}
		if d := math.Hypot(m.X-tp.X, m.Z-tp.Z); d > 150.0001 {
			t.Fatalf("wave monster %.1f from the transport", d)
		}
		if m.Tactics == nil || m.Tactics.ID < 2001 || m.Tactics.ID > 2004 {
			t.Fatalf("tactics %+v", m.Tactics)
		}
	}
	rt.mu.Lock()
	n := len(rt.waves)
	rt.mu.Unlock()
	if n != len(all) {
		t.Fatalf("%d wave monsters filed, %d spawned", n, len(all))
	}

	// The goods gone: the next threshold drops the caravan and its idle
	// monsters go.
	if err := bags.RemoveItem(ctx, recID, 0, 100); err != nil {
		t.Fatal(err)
	}
	rt.tick(ctx, 120000)
	rt.mu.Lock()
	_, still := rt.list[cid]
	rt.mu.Unlock()
	if still {
		t.Fatal("the caravan outlived its goods")
	}
	if left := len(monsters.InZone("jangan")); left != 0 {
		t.Fatalf("%d wave monsters left after the caravan was dropped", left)
	}
}

// A wave's NPC thief and a transport (round 804, mobcos.go): under tactics
// 542 (bit 0x4: the players and the COS of the traders' side) a thief with
// no player in sight takes the trader's transport, chases and swings at it;
// the blow comes off the transport's HP and the zone hears it with the COS
// uid as the target. An NPC hunter's 666 (bit 0x80) passes a trader's
// transport by.
func TestRound804MonsterHitsATransport(t *testing.T) {
	battleForTest(t, true)
	aggroForTest(t, true)
	resetCOSWorld()
	t.Cleanup(func() {
		resetCOSWorld()
		cosWorld.deps.Store(nil)
	})
	f := startBattleFixture(t, 804, 3000, 3000)
	jobStates.Store(f.aria, jobs.StateTrader)
	t.Cleanup(func() { jobStates.Delete(f.aria) })
	// No hub in the COS deps: nothing is sent to the (connection-less) owner.
	SetCOSDeps(cos.NewMemStore(), nil, donkeyTable(t), nil, nil, nil, nil, nil, nil, nil)
	row, _ := cosRowByCode("COS_T_DONKEY")
	o := &cosObj{owner: f.aria, rec: cos.Record{OwnerCharID: f.aria, RefCharID: row.ID, HP: row.MaxHP, Level: row.Level},
		row: row, kind: cos.KindTransport, zone: "jangan", pos: world.Position{X: 100, Z: 0}, lastTick: time.Now()}
	cosWorld.add(o)

	thief := chaseMangyang
	thief.Name, thief.CodeName, thief.Level, thief.AttackMin, thief.AttackMax = "Thief", "MOB_THIEF_NPC_0050", 5, 40, 60
	m := f.monsters.SpawnHatched("jangan", thief, 120, 0, 0, 500, 1, 1, 0,
		combat.Hatch{HomeX: 120, HomeZ: 0, Tactics: &combat.Tactics{ID: 2001, SightRange: 250, Flags: 542, RoamRadius: MonsterRoamRadius}})
	hunter := thief
	hunter.CodeName = "MOB_HUNTER_NPC_0050"
	h := f.monsters.SpawnHatched("jangan", hunter, 80, 0, 0, 500, 1, 1, 0,
		combat.Hatch{HomeX: 80, HomeZ: 0, Tactics: &combat.Tactics{ID: 2011, SightRange: 250, Flags: 666, RoamRadius: MonsterRoamRadius}})

	now := aiT0
	hit := func() bool {
		for _, s := range f.rec.strikesOf(m.ID) {
			if s.TargetCharacterID == int64(o.uid) {
				return true
			}
		}
		return false
	}
	for i := 0; i < 400 && !hit(); i++ {
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		time.Sleep(time.Millisecond)
	}
	if !waitFor(t, 2*time.Second, hit) {
		t.Fatal("the NPC thief never swung at the transport")
	}
	var s MonsterAttacked
	for _, x := range f.rec.strikesOf(m.ID) {
		if x.TargetCharacterID == int64(o.uid) {
			s = x
		}
	}
	cosWorld.mu.Lock()
	hp := o.rec.HP
	cosWorld.mu.Unlock()
	if !s.Blocked && (s.Damage < 1 || hp >= row.MaxHP || int(s.TargetHP) != hp) {
		t.Fatalf("the blow %+v, the transport's HP %d of %d", s, hp, row.MaxHP)
	}
	for _, x := range f.rec.strikesOf(h.ID) {
		if x.TargetCharacterID == int64(o.uid) {
			t.Fatal("an NPC hunter (666) struck a trader's transport")
		}
	}
}
