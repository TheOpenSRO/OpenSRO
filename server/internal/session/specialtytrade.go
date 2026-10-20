package session

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"math"
	"math/rand"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/cos"
	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/jobs"
	"github.com/OpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/shop"
	"github.com/OpenSRO/OpenSRO/server/internal/specialty"
	"github.com/OpenSRO/OpenSRO/server/internal/species"
	"github.com/OpenSRO/OpenSRO/server/internal/txn"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Specialty trade (round 801): a trader buys goods into the transport at a
// specialty store, carries them, and sells them at another town's specialty
// NPC at that NPC's quotation; a thief sells goods taken from a fallen
// transport at the thief den's buyer. READ in SR_GameServer.exe unless a
// line says otherwise; docs/protocol/jobs.md, "Specialty trade", has the
// addresses.
//
//	0x7034 type 0x13  buy into the transport   u8 0x13, u32 cos, u8 tab, u8 slot, u16 count, u32 npc
//	0x7034 type 0x14  sell from the transport  u8 0x14, u32 cos, u8 slot, u16 count, u32 npc
//	0xB034 type 0x13  1, 0x13, u32 cos, u8 tab, u8 slot, u8 n, n x u8 dest, u16 count
//	0xB034 type 0x14  1, 0x14, u32 cos, u8 slot, u16 count, u32 npc, u8 book
//	0xB034 type 0x11  1, 0x11, u32 cos, u8 dest, item record  (a good picked into the transport)
//	0x30E0            u8 n, n x {u32 ref item, u32 unit price}   the NPC's quotations
//	0x30E8            u8 scale                                   the owner's trade scale
//	0x30E7            u8 1                                       too far from the transport
//
// The engine ignores the request's cos uid and takes the player's own
// transport (FUN_005266a0 s:0x52675a, FUN_005267f0 alike), as here.
const (
	ItemMoveCOSPick     byte = 0x11
	ItemMoveBuyToCOS    byte = 0x13
	ItemMoveSellFromCOS byte = 0x14

	OpTradePrices uint16 = 0x30E0
	OpTradeScale  uint16 = 0x30E8
	OpTradeLeash  uint16 = 0x30E7
)

// The refusals (READ, docs/protocol/jobs.md "The buy" / "The sale").
const (
	tradeErrCantStore     uint16 = 0x180b // CANT_BE_STORED: not a good, into the transport
	tradeErrPastStack     uint16 = 0x1815
	tradeErrBadTab        uint16 = 0x1806
	tradeErrOnlyTrader    uint16 = 0x1860 // ONLY_TRADER_CAN_BUY_SPECIALTY
	tradeErrLevel         uint16 = 0x184e // SPECIALTY_ERR_NOTTRADE
	tradeErrQuest         uint16 = 0x18b0 // QUEST_NOTCOMPLETE
	tradeErrNotSelling    uint16 = 0x18af // SPECIALTY_ERR_NOTSELL
	tradeErrTooFar        uint16 = 0x1865 // TOO_FAR_FROM_CART
	tradeErrDealerNoTreat uint16 = 0x1845 // DEALER_DONT_TREAT_THIS_ITEM
	tradeErrStolen        uint16 = 0x1868 // DEALER_DONT_TREAT_STOLEN_ITEM
	tradeErrNotBuyer      uint16 = 0x1863 // YOU_ARENT_BUYER_OF_THIS_SPECIALTY
	tradeErrRobberOwn     uint16 = 0x186f // ROBBER_CANT_PICK_HIS_ITEM
	tradeErrNoJobPick     uint16 = 0x1864
	tradeErrNoCartToPick  uint16 = 0x1861 // DONT_HAVE_ANY_TRADECART_TO_PICK_SPECIALTY
	tradeErrNoTransport   uint16 = 5
	tradeErrNoInteraction uint16 = 3
	tradeErrDead          uint16 = 2
)

// tradeLevelFloor is the buy's level test (GetLevel < 20 -> 0x184e).
const tradeLevelFloor = 20

// SpecialtyDeps are the trade's tables (cmd/server).
type SpecialtyDeps struct {
	// Board is every specialty NPC's quotation map (-quotation-csv); nil:
	// no quotations, every good sells at its SellPrice.
	Board *specialty.Board
	// Shops is the specialty stores' goods (-specialty-shops-csv); nil: no
	// good can be bought.
	Shops specialty.Shops
	// Thresholds are the trade scale's bounds.
	Thresholds specialty.Thresholds
	// SpecialGoods is the engine's CMainProcess+0x42405: the special goods
	// (TypeID4 2) are on sale. The schedule that sets it (CGameSJ_
	// SpecialGoodsSelling) is OPEN; a flag stands in (OURS).
	SpecialGoods bool
	// SafeOption and SafeNum are TRADE_SAFETY_OPTION and TRADE_SAFETY_NUM
	// (round 802, safetrade.go); SafeSet says they were configured (else the
	// shard's 0 and 8).
	SafeOption, SafeNum int
	SafeSet             bool
	Items               ItemLookup
	Chars               character.Store
	Logger              *slog.Logger
}

type specialtyRuntime struct {
	d SpecialtyDeps
	// scales is the trade scale each owner was last told (0x30E8 goes out
	// on a change, FUN_005237b0).
	mu     sync.Mutex
	scales map[int64]byte
}

var specialtyRT atomic.Pointer[specialtyRuntime]

// SetSpecialtyDeps installs the trade's tables.
func SetSpecialtyDeps(d SpecialtyDeps) {
	if d.Logger == nil {
		d.Logger = slog.Default()
	}
	if d.Thresholds == (specialty.Thresholds{}) {
		d.Thresholds = specialty.ShardThresholds
	}
	specialtyRT.Store(&specialtyRuntime{d: d, scales: map[int64]byte{}})
}

func specialtyNow() *specialtyRuntime {
	if rt := specialtyRT.Load(); rt != nil {
		return rt
	}
	return &specialtyRuntime{d: SpecialtyDeps{Logger: slog.Default(), Thresholds: specialty.ShardThresholds},
		scales: map[int64]byte{}}
}

// isSpecialtyItem is CGObj::IsSpecialty (s:0x482de0): TypeID 3/3/8, any
// TypeID4, not bionic (no item is: MEASURED).
func isSpecialtyItem(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == 3 && it.TypeID2 == 3 && it.TypeID3 == 8
}

// ownTransport is characterID's transport in the world (GObjPC::
// FUN_004fd7f0 on the COS manager), nil when it has none.
func ownTransport(characterID int64) *cosObj {
	for _, o := range cosWorld.owned(characterID) {
		cosWorld.mu.Lock()
		ok := o.kind == cos.KindTransport && !o.dead
		cosWorld.mu.Unlock()
		if ok {
			return o
		}
	}
	return nil
}

// transportBag is the transport's bag: its record id, usable size and
// slots.
func transportBag(ctx context.Context, o *cosObj) (int64, int, []inventory.Slot) {
	cosWorld.mu.Lock()
	id, size := o.rec.ID, o.rec.InvSize
	cosWorld.mu.Unlock()
	bags := cosWorld.depsNow().bags
	if bags == nil {
		return id, size, nil
	}
	slots, _ := bags.List(ctx, id)
	return id, size, slots
}

// transportGoods is FUN_004d2d20: the units of goods the transport holds
// (the stack counts of every specialty item).
func transportGoods(ctx context.Context, o *cosObj) int {
	_, _, slots := transportBag(ctx, o)
	items := cosWorld.depsNow().items
	units := 0
	for _, sl := range slots {
		if it, err := items.GetItem(ctx, sl.ItemID); err == nil && isSpecialtyItem(it) {
			units += sl.Quantity
		}
	}
	return units
}

// haveTradeItem is IHaveTradeItem (CGObjPC +0x2e8 -> CGObjCOS s:0x4d27c0):
// the player's transport holds a good.
func haveTradeItem(ctx context.Context, characterID int64) bool {
	o := ownTransport(characterID)
	return o != nil && transportGoods(ctx, o) > 0
}

// tradeScaleOf is FUN_0060c330 over FUN_0060c1f0 for characterID at level:
// 0 without a transport or goods.
func tradeScaleOf(ctx context.Context, characterID int64, level int) byte {
	return specialtyNow().d.Thresholds.Scale(tradeAmountOf(ctx, characterID, level))
}

// tradeAmountOf is FUN_0060c1f0 (s:0x60c1f0): the trade value of
// characterID's transport at level, 0 without a transport or goods.
func tradeAmountOf(ctx context.Context, characterID int64, level int) uint32 {
	o := ownTransport(characterID)
	if o == nil {
		return 0
	}
	units := transportGoods(ctx, o)
	if units == 0 || levelTable == nil {
		return 0
	}
	cosWorld.mu.Lock()
	rarity := o.row.Rarity
	cosWorld.mu.Unlock()
	// GetMaxLevel (vslot +0x128): OpenSRO keeps no separate high-water
	// mark, and a level never falls, so the level stands in (OURS).
	return specialty.Amount(units, levelTable.GoldMin(specialty.ClampTradeLevel(level)), rarity)
}

// lastTradeScale is the scale characterID was last told (the spawn record's
// TradeRank).
func lastTradeScale(characterID int64) byte {
	rt := specialtyNow()
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return rt.scales[characterID]
}

// refreshTradeScale is FUN_005237b0: the scale worked out again and, when
// it changed, 0x30E8 to its owner (s:0x523810). A scale that leaves 1 also
// clears the trader record's safe-trade byte (FUN_0060e520(0), round 802).
func refreshTradeScale(ctx context.Context, characterID int64) {
	e, ok := cosOwnerEntity(characterID)
	if !ok {
		return
	}
	now := tradeScaleOf(ctx, characterID, e.Level)
	rt := specialtyNow()
	rt.mu.Lock()
	old := rt.scales[characterID]
	rt.scales[characterID] = now
	rt.mu.Unlock()
	if old == now {
		return
	}
	if e.Session != nil {
		_ = e.Session.Send(&proto.Packet{Opcode: OpTradeScale, Data: []byte{now}})
	}
	// A scale that leaves 1 ends a safe trade (round 802, s:0x5237b0).
	if now != 1 {
		safeTradeLose(ctx, characterID)
	}
	bumpPlayerState(characterID)
}

// forgetTradeScale drops a leaving character's scale.
func forgetTradeScale(characterID int64) {
	rt := specialtyNow()
	rt.mu.Lock()
	delete(rt.scales, characterID)
	rt.mu.Unlock()
}

// EncodeTradePrices is 0x30E0 (GObjNPCNPC::FUN_004c8a60 s:0x4c8a60).
func EncodeTradePrices(list []specialty.UnitPrice) []byte {
	out := []byte{byte(len(list))}
	for _, p := range list {
		out = binary.LittleEndian.AppendUint32(out, uint32(p.Item))
		out = binary.LittleEndian.AppendUint32(out, uint32(p.Price))
	}
	return out
}

// sendTradePrices sends list to characterID when it holds goods (FUN_004c8a60
// sends only to a player whose IHaveTradeItem answers, s:0x4c8a6c).
func sendTradePrices(ctx context.Context, sess *gateway.Session, characterID int64, list []specialty.UnitPrice) {
	if sess == nil || len(list) == 0 || !haveTradeItem(ctx, characterID) {
		return
	}
	_ = sess.Send(&proto.Packet{Opcode: OpTradePrices, Data: EncodeTradePrices(list)})
}

// specialtyOpen is the 0x7046 open of id 0xc (s:0x5105ca): an NPC keeping a
// quotation map sends its list (FUN_004c8a60) and the interaction becomes
// INTERACTMODE 6; one without returns with no mode. It reports the mode.
func specialtyOpen(ctx context.Context, sess *gateway.Session, e world.Entity, npcRef uint32) byte {
	rt := specialtyNow()
	if !rt.d.Board.Has(int64(npcRef)) {
		return 0
	}
	sendTradePrices(ctx, sess, e.CharacterID, rt.d.Board.Prices(int64(npcRef)))
	return 6
}

// specialGoodsSelling is the byte 0xB046 carries for id 0xc
// (CMainProcess+0x42405).
func specialGoodsSelling() byte {
	if specialtyNow().d.SpecialGoods {
		return 1
	}
	return 0
}

// npcViewers are the sessions whose NPC window holds the NPC entity uid:
// the engine sends a price change to the NPC's +0x1c0 list (FUN_004c89d0),
// INFERRED to be the objects that see it.
func npcViewers(uid uint32) []world.Entity {
	w := npcWorldRuntime.Load()
	if w == nil {
		return nil
	}
	hub := cosWorld.depsNow().hub
	if hub == nil {
		return nil
	}
	w.mu.Lock()
	home := map[combat.Cell]bool{}
	for c, list := range w.byCell {
		for _, n := range list {
			if n.UID == uid {
				home[c] = true
			}
		}
	}
	seeing := map[uint64]bool{}
	for sid, c := range w.sent {
		for _, cc := range window(c) {
			if home[cc] {
				seeing[sid] = true
				break
			}
		}
	}
	w.mu.Unlock()
	var out []world.Entity
	for _, e := range hub.AllEntities() {
		if e.Session != nil && seeing[e.Session.ID()] {
			out = append(out, e)
		}
	}
	return out
}

// broadcastPrices sends one NPC's list (or one entry) to its viewers.
func broadcastPrices(ctx context.Context, npcRef int64, list []specialty.UnitPrice) {
	for _, n := range npcsByRef(uint32(npcRef)) {
		for _, e := range npcViewers(n) {
			sendTradePrices(ctx, e.Session, e.CharacterID, list)
		}
	}
}

// npcsByRef is every placed NPC uid of a ref id.
func npcsByRef(ref uint32) []uint32 {
	w := npcWorldRuntime.Load()
	if w == nil {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	seen := map[uint32]bool{}
	var out []uint32
	for uid, pls := range w.byUID {
		for _, pl := range pls {
			if pl.npc.RefID == ref && !seen[uid] {
				seen[uid] = true
				out = append(out, uid)
			}
		}
	}
	return out
}

// RunQuotationTick is the ten-minute recovery (FUN_004c8b90 from
// CMainProcess::FUN_00413fb0, timer 0x927C0 ms): every NPC's stock falls
// back and its whole list goes to its viewers.
func RunQuotationTick(ctx context.Context) {
	t := time.NewTicker(specialty.RecoverEveryMs * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			b := specialtyNow().d.Board
			for npc, list := range b.RecoverAll() {
				broadcastPrices(ctx, npc, list)
			}
		}
	}
}

// --- The buy (0x7034 type 0x13) ----------------------------------------------

// tradeQuestGate is GObjPC::FUN_004c9110 (s:0x4c9110): the quest an NPC's
// goods need done (READ: equality tests on the code name).
func tradeQuestGate(npcCode string) string {
	switch strings.ToUpper(npcCode) {
	case "NPC_CH_SPECIAL2":
		return "QNO_TRADE_CH_SPECIAL2_1"
	case "NPC_WC_SPECIAL2":
		return "QNO_TRADE_WC_SPECIAL2_1"
	case "NPC_TK_SPECIAL":
		return "QNO_TRADE_TK_SPECIAL_1"
	case "NPC_RM_SPECIAL":
		return "QNO_TRADE_RM_SPECIAL_1"
	case "NPC_AM_SPECIAL":
		return "QNO_TRADE_AM_SPECIAL_1"
	}
	return ""
}

// tradeQuestDone is GetQuestAchievementCountByName(name) != 0. Without the
// quest runtime the gate is not applied (OURS: nothing could pass it).
func tradeQuestDone(ctx context.Context, characterID int64, name string) bool {
	rt := questRT.Load()
	if rt == nil || name == "" {
		return true
	}
	q := rt.cat.ByCode[name]
	if q == nil {
		return false
	}
	ql, err := rt.logOf(ctx, characterID)
	if err != nil || ql == nil {
		return false
	}
	ql.mu.Lock()
	defer ql.mu.Unlock()
	return ql.log.Done(q.ID)
}

// npcHas reports whether an NPC's interaction set holds id.
func npcHas(ids []byte, id byte) bool {
	for _, b := range ids {
		if b == id {
			return true
		}
	}
	return false
}

// tradeNPC resolves the request's NPC for e (FUN_004e72a0): the placement,
// or the target's refusal.
func tradeNPC(e world.Entity, uid uint32) (npcPlacement, uint16) {
	pl, code := npcTarget(e, uid)
	if code != 0 {
		return pl, code
	}
	return pl, 0
}

// cartDistance is the PC-to-transport distance (FUN_00430d40 +
// FUN_00405270, 3-D) at now.
func cartDistance(e world.Entity, o *cosObj, now time.Time) float64 {
	cosWorld.mu.Lock()
	p := o.at(now)
	zone := o.zone
	cosWorld.mu.Unlock()
	if zone != e.Zone {
		return specialty.LeashRange * 2
	}
	pos := e.Pos
	if e.Move != nil {
		if q, _ := e.Move.At(now); q != (world.Position{}) {
			pos = q
		}
	}
	return dist3(pos, p)
}

// handleBuyToCOS is FUN_005266a0 -> FUN_00618fe0 for type 0x13.
func handleBuyToCOS(ctx context.Context, sess *gateway.Session, data []byte, d ItemOpDeps) error {
	fail := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeItemFail(code)})
	}
	if len(data) < 13 {
		return fail(ItemErrDB)
	}
	tab, slot := int(data[5]), int(data[6])
	count := int(binary.LittleEndian.Uint16(data[7:]))
	npcUID := binary.LittleEndian.Uint32(data[9:])
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return fail(ItemErrDB)
	}
	if e.Life == world.LifeDead {
		return fail(tradeErrDead)
	}
	if count < 1 {
		return fail(ItemErrCountBelowOne)
	}
	pl, code := tradeNPC(e, npcUID)
	if code != 0 {
		return fail(code)
	}
	if !npcHas(pl.npc.Interact, 1) {
		return fail(tradeErrNoInteraction)
	}
	o := ownTransport(e.CharacterID)
	if o == nil {
		return fail(tradeErrNoTransport)
	}
	rt := specialtyNow()
	if rt.d.Shops == nil || rt.d.Shops.Tabs(pl.npc.Code) == 0 {
		return fail(tradeErrNoTransport)
	}
	if tab >= rt.d.Shops.Tabs(pl.npc.Code) {
		return fail(tradeErrBadTab)
	}
	good, ok := rt.d.Shops.At(pl.npc.Code, tab, slot)
	if !ok {
		return fail(ItemErrEmptySource)
	}
	items := d.Items
	if items == nil {
		items = rt.d.Items
	}
	if items == nil {
		return fail(ItemErrDB)
	}
	it, err := items.GetItem(ctx, good.Item)
	if err != nil || it == nil {
		return fail(ItemErrDB)
	}
	// SellItemAtSpecialtyShop (s:0x6182a0), in order.
	if !isSpecialtyItem(it) {
		return fail(tradeErrCantStore)
	}
	if jobStateNow(ctx, e.CharacterID) != byte(jobs.KindTrader) {
		return fail(tradeErrOnlyTrader)
	}
	if e.Level < tradeLevelFloor {
		return fail(tradeErrLevel)
	}
	if q := tradeQuestGate(pl.npc.Code); q != "" && !tradeQuestDone(ctx, e.CharacterID, q) {
		return fail(tradeErrQuest)
	}
	if it.TypeID4 == 2 && !rt.d.SpecialGoods {
		return fail(tradeErrNotSelling)
	}
	if cartDistance(e, o, time.Now()) > specialty.LeashRange {
		return fail(tradeErrTooFar)
	}
	if !it.CanSell {
		return fail(ItemErrCannotSell)
	}
	if it.MaxStack > 0 && count > it.MaxStack {
		return fail(tradeErrPastStack)
	}
	// One package takes one slot holding count units (FUN_004de170): the
	// first free slot of the transport's bag (FUN_00617a50: none 0x1807).
	recID, size, slots := transportBag(ctx, o)
	used := map[int]bool{}
	for _, s := range slots {
		used[s.Index] = true
	}
	dest := -1
	for i := 0; i < size; i++ {
		if !used[i] {
			dest = i
			break
		}
	}
	if dest < 0 {
		return fail(ItemErrBagFull)
	}
	// The price: the store's price for count (FUN_00867480 by payment type,
	// INFERRED the gold policy's cost; OpenSRO's store prices every good by
	// its itemdata Price, which equals refpricepolicyofitem's cost on every
	// good of the shipped data, MEASURED 4000 / 4000) and no fortress tax
	// (OURS: no fortress war).
	cost := shop.Price(it) * int64(count)
	bags := cosWorld.depsNow().bags
	placer, ok := bags.(inventory.Placer)
	if !ok || d.Chars == nil {
		return fail(ItemErrDB)
	}
	// A good has no durability and no white stats (MEASURED: no 3/3/8 row
	// carries a durability range).
	inst := inventory.Instance{Durability: durability.Untracked}
	// The buyer's name (_STRG_ADD_SPECIALTY_NoTX): GetNickName, the alias.
	inst.Creator = jobRecord(ctx, e.CharacterID).Alias
	err = txn.For(d.Chars, bags).Run(ctx, func(ctx context.Context) error {
		if cost > 0 {
			if err := d.Chars.DeductGold(ctx, e.CharacterID, cost); err != nil {
				return err
			}
		}
		return placer.PlaceItemInstance(ctx, recID, dest, it.ID, count, inst)
	})
	if err != nil {
		if errors.Is(err, character.ErrInsufficientGold) {
			return fail(ItemErrNotEnoughGold)
		}
		return fail(ItemErrDB)
	}
	// OffsetGold(-price, reason, 1, 0): 0x304E unshown, before the result.
	tellGold(ctx, d.Chars, d.Hub, e.CharacterID, false)
	out := []byte{itemOpOK, ItemMoveBuyToCOS}
	out = binary.LittleEndian.AppendUint32(out, o.uid)
	out = append(out, byte(tab), byte(slot), 1, byte(dest))
	out = binary.LittleEndian.AppendUint16(out, uint16(count))
	if err := sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: out}); err != nil {
		return err
	}
	refreshTradeScale(ctx, e.CharacterID)
	return nil
}

// --- The sale (0x7034 type 0x14) ---------------------------------------------

// salePrice is GObjNPCNPC::FUN_004c8d10 for a good: the gold and the
// profit of count of it sold to the NPC of ref npcRef with ids, for a
// seller who owns it or not.
func salePrice(it *refdata.Item, npcRef int64, ids []byte, sellsIt, owned bool, count int) (gold, profit int64, changed bool) {
	switch {
	case npcHas(ids, 0x0d):
		// The thief den's buyer: profit = Price x count, gold 75 % of it
		// (FUN_004c81d0, the double 0.75 at s:0xb462d8).
		profit = it.Price * int64(count)
		gold = int64(float64(profit) * 0.75)
	case sellsIt:
		// The NPC sells this item itself (FUN_004c81f0): SellPrice, no profit.
		gold = it.SellPrice * int64(count)
	case !owned:
		// "Trying to sell stolen Item to special merchant!": 0 (unreachable
		// after 0x1868).
	default:
		g, p, ch, ok := specialtyNow().d.Board.Sell(npcRef, it.ID, count)
		if !ok {
			// "CANNOT FIND QUOT DATA": SellPrice.
			gold = it.SellPrice * int64(count)
		} else {
			gold, profit, changed = g, p, ch
		}
	}
	if profit < 0 {
		profit = 0
	}
	return gold, profit, changed
}

// handleSellFromCOS is FUN_005267f0 -> FUN_006194e0 for type 0x14.
func handleSellFromCOS(ctx context.Context, sess *gateway.Session, data []byte, d ItemOpDeps) error {
	fail := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeItemFail(code)})
	}
	if len(data) < 12 {
		return fail(ItemErrDB)
	}
	slot := int(data[5])
	count := int(binary.LittleEndian.Uint16(data[6:]))
	npcUID := binary.LittleEndian.Uint32(data[8:])
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return fail(ItemErrDB)
	}
	if count < 1 {
		return fail(ItemErrCountBelowOne)
	}
	o := ownTransport(e.CharacterID)
	if o == nil {
		return fail(tradeErrNoTransport)
	}
	recID, size, slots := transportBag(ctx, o)
	if slot >= size {
		return fail(tradeErrBadTab)
	}
	pl, code := tradeNPC(e, npcUID)
	if code != 0 {
		return fail(code)
	}
	if !npcHas(pl.npc.Interact, 1) {
		return fail(tradeErrNoInteraction)
	}
	if !pl.npc.Shop {
		return fail(tradeErrNoTransport)
	}
	var held inventory.Slot
	found := false
	for _, s := range slots {
		if s.Index == slot {
			held, found = s, true
		}
	}
	if !found {
		return fail(ItemErrEmptySource)
	}
	rt := specialtyNow()
	items := d.Items
	if items == nil {
		items = rt.d.Items
	}
	it, err := items.GetItem(ctx, held.ItemID)
	if err != nil || it == nil {
		return fail(ItemErrDB)
	}
	state := jobStateNow(ctx, e.CharacterID)
	rec := jobRecord(ctx, e.CharacterID)
	owned := held.Creator != "" && held.Creator == rec.Alias
	// GObjPC::FUN_00617f70 (s:0x617f70), in order.
	if isSpecialtyItem(it) {
		if state == byte(jobs.KindHunter) || state == 4 || state == 0 {
			return fail(tradeErrNoTransport)
		}
		if !npcHas(pl.npc.Interact, npctalk.IDSpecial) {
			return fail(tradeErrDealerNoTreat)
		}
		if q := tradeQuestGate(pl.npc.Code); q != "" && !tradeQuestDone(ctx, e.CharacterID, q) {
			return fail(tradeErrQuest)
		}
		if !owned && !npcHas(pl.npc.Interact, 0x0d) {
			return fail(tradeErrStolen)
		}
		if cartDistance(e, o, time.Now()) > specialty.LeashRange {
			return fail(tradeErrTooFar)
		}
	} else if npcHas(pl.npc.Interact, npctalk.IDSpecial) {
		return fail(tradeErrDealerNoTreat)
	}
	if !it.CanSell {
		return fail(ItemErrCannotSell)
	}
	if count > held.Quantity {
		return fail(ItemErrPastStack)
	}
	// The scale before the sale (FUN_00410520 runs before the removal,
	// s:0x61969d against s:0x6197a4).
	scale := tradeScaleOf(ctx, e.CharacterID, e.Level)
	sellsIt := false
	if rt.d.Shops != nil {
		for _, g := range rt.d.Shops[strings.ToUpper(pl.npc.Code)] {
			sellsIt = sellsIt || g.Item == it.ID
		}
	}
	gold, profit, changed := salePrice(it, int64(pl.npc.RefID), pl.npc.Interact, sellsIt, owned, count)
	// Selling his own goods at a specialty NPC ends a trader's safe trade
	// (round 802, s:0x4c8e20: the owned branch of the quotation's price).
	if isSpecialtyItem(it) && owned && !npcHas(pl.npc.Interact, 0x0d) && !sellsIt {
		safeTradeLose(ctx, e.CharacterID)
	}
	bags := cosWorld.depsNow().bags
	if d.Chars == nil || bags == nil {
		return fail(ItemErrDB)
	}
	err = txn.For(d.Chars, bags).Run(ctx, func(ctx context.Context) error {
		if _, err := inventory.Take(ctx, bags, recID, slot, count, held.ItemID, held.Instance()); err != nil {
			return err
		}
		if gold > 0 {
			return d.Chars.AddGold(ctx, e.CharacterID, gold)
		}
		return nil
	})
	if err != nil {
		return fail(ItemErrDB)
	}
	// OffsetGold(gold, 0x14 or 0x24, 1, 0): 0x304E unshown. A party's share
	// (FUN_005bd180 / FUN_005bd510) is OPEN; the seller keeps it all (OURS).
	tellGold(ctx, d.Chars, d.Hub, e.CharacterID, false)
	if changed {
		if q, ok := rt.d.Board.Quote(int64(pl.npc.RefID), it.ID); ok {
			broadcastPrices(ctx, int64(pl.npc.RefID), []specialty.UnitPrice{{Item: it.ID, Price: q.Price}})
		}
	}
	if isSpecialtyItem(it) && profit > 0 {
		saleRewards(ctx, e.CharacterID, state, scale, gold, profit)
	}
	out := []byte{itemOpOK, ItemMoveSellFromCOS}
	out = binary.LittleEndian.AppendUint32(out, o.uid)
	out = append(out, byte(slot))
	out = binary.LittleEndian.AppendUint16(out, uint16(count))
	out = binary.LittleEndian.AppendUint32(out, npcUID)
	// Goods never enter the buy-back book (gs:0x61b820's 3/3/8 test, round
	// 728): the book byte 0xFF.
	out = append(out, shop.NotBooked)
	if err := sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: out}); err != nil {
		return err
	}
	refreshTradeScale(ctx, e.CharacterID)
	return nil
}

// saleRewards are FUN_006194e0's rewards for a good sold at a profit
// (s:0x619690..0x6197f2): the job exp (FUN_00410520 -> FUN_004e2830), a
// trader's contribution (trunc(gold x 0.1), TrijobMgr::FUN_0060e0a0) and
// the weekly pool (_AddTrijobReward 3 for a trader, 2 for a robber).
func saleRewards(ctx context.Context, characterID int64, state, scale byte, gold, profit int64) {
	if exp := jobs.SaleExp(profit, state, scale); exp > 0 {
		gainJobExp(ctx, characterID, exp)
	}
	d := jobDepsNow()
	if d.store == nil {
		return
	}
	share := jobs.SaleShare(gold)
	if state == byte(jobs.KindTrader) {
		lk := jobLock(characterID)
		lk.Lock()
		rec := jobRecord(ctx, characterID)
		before := rec.Contribution
		jobs.AddTraderContribution(&rec, share)
		if rec.Contribution != before {
			if err := saveJobRecord(ctx, d, rec); err != nil {
				d.logger.Warn("jobs: saving a contribution failed", "character", characterID, "err", err)
			}
		}
		lk.Unlock()
	}
	if pool, ok := jobs.RewardPool(jobs.Kind(state)); ok && share > 0 {
		if err := d.store.AddPool(ctx, pool, share); err != nil {
			d.logger.Warn("jobs: adding to a reward pool failed", "pool", pool, "err", err)
		}
	}
}

// transportLeashed is FUN_004fd1d0 (s:0x4fd1d0, from CGObjPC vslot_392 on
// every movement step, s:0x4ef300): the owner's step is refused when the
// owner is already more than 1000 from its transport and the step takes it
// farther -- both distances 2-D (y ignored) and region-aware; a step back
// toward the cart always passes. OpenSRO tests the owner's leg once a COS
// tick (100 ms) against where the leg puts it one tick later (OURS: the
// engine tests each mover step).
func transportLeashed(owner world.Position, mv *world.Mover, cart world.Position, now time.Time) bool {
	d1 := dist2(owner, cart)
	if d1 <= specialty.LeashRange {
		return false
	}
	next, _ := mv.At(now.Add(cosTick))
	return dist2(next, cart) > d1
}

func dist2(a, b world.Position) float64 {
	dx, dz := a.X-b.X, a.Z-b.Z
	return math.Sqrt(dx*dx + dz*dz)
}

// transportBagSize is FUN_004d1a50 for a transport row and its owner's
// level.
func transportBagSize(row species.Row, level int) int {
	var goldMin int64
	if levelTable != nil {
		goldMin = levelTable.GoldMin(level)
	}
	return specialty.BagSize(row.InventorySize, goldMin, row.Rarity, row.CashItem)
}

// --- Goods on the ground -----------------------------------------------------

// dropTransportGoods is FUN_004c3f60 (s:0x4c3f60), from the transport's
// death (COS slot 398 s:0x4d1fd0, only for a cart) and from its dismissal
// (0x70C6, s:0x511e00, killer 0): every slot of its bag is taken out and laid
// on the ground at the transport, whole stacks. A good gets no owner (the
// owner reservation FUN_004901b0 is skipped for an item whose IsSpecialty
// answers); anything else is the killer's. A code name holding "_QT_" is not
// dropped. Where each stack lands round the transport is OURS: the kill
// drop's scatter ring (grounditem.Scatter); the engine's placement (slot
// +0x4dc) was not read.
func dropTransportGoods(ctx context.Context, o *cosObj, killer int64) {
	cd, _ := skillDeps()
	d := cosWorld.depsNow()
	if cd.ground == nil || d.bags == nil {
		return
	}
	cosWorld.mu.Lock()
	recID, zone, at := o.rec.ID, o.zone, o.at(time.Now())
	kind := o.kind
	cosWorld.mu.Unlock()
	if kind != cos.KindTransport {
		return
	}
	slots, err := d.bags.List(ctx, recID)
	if err != nil {
		return
	}
	var dropped []grounditem.Item
	for _, sl := range slots {
		it, err := d.items.GetItem(ctx, sl.ItemID)
		if err != nil || it == nil {
			continue
		}
		inst, err := inventory.Take(ctx, d.bags, recID, sl.Index, sl.Quantity, sl.ItemID, sl.Instance())
		if err != nil {
			continue
		}
		if strings.Contains(it.CodeName, "_QT_") {
			continue
		}
		owner := killer
		if isSpecialtyItem(it) {
			owner = 0
		}
		x, z := grounditem.Scatter(at.X, at.Z, grounditem.ScatterDraw(rand.Intn), grounditem.ScatterDraw(rand.Intn))
		g := cd.ground.DropInstance(zone, sl.ItemID, int32(sl.Quantity), float32(x), float32(at.Y), float32(z), owner, inst)
		dropped = append(dropped, g)
	}
	if d.hub != nil && len(dropped) > 0 {
		now := time.Now()
		for _, g := range dropped {
			snap := snapshotOf(g, now)
			pkt := &proto.Packet{Opcode: OpGroundItemSpawned, Data: snap.Encode()}
			for _, e := range d.hub.EntitiesInZone(zone) {
				e.Session.Send(pkt)
			}
		}
	}
	refreshTradeScale(ctx, o.owner)
}

// pickGood is FUN_00525dc0's route for a good (s:0x525dc0): who may take
// it, and into the transport (move type 0x11) rather than the bag. A
// trader takes only goods bought under his own alias (0x1863), a thief only
// someone else's (0x186f), a hunter none (0x1863), a player out of a job
// none (0x1864); no transport 0x1861. Its distance test measures a zero
// vector and never refuses (s:0x525e52, READ), so the pick's own 10-unit
// reach is the only one. it is reserved (PickCheck); every refusal releases
// it.
func pickGood(ctx context.Context, sess *gateway.Session, e world.Entity, it grounditem.Item, ground *grounditem.Hub,
	hub *world.Hub, reply func(*PickUpResult) error) error {
	refuse := func(code uint16) error {
		ground.Release(it.ID)
		return reply(&PickUpResult{Code: int32(code), GroundItemID: it.ID})
	}
	var inst inventory.Instance
	if it.Instance != nil {
		inst = *it.Instance
	} else {
		inst = inventory.Instance{Durability: durability.Untracked}
	}
	alias := jobRecord(ctx, e.CharacterID).Alias
	own := inst.Creator != "" && inst.Creator == alias
	if code := goodPickCode(jobStateNow(ctx, e.CharacterID), own); code != 0 {
		return refuse(code)
	}
	o := ownTransport(e.CharacterID)
	if o == nil {
		return refuse(tradeErrNoCartToPick)
	}
	// A bargain good picked up ends a safe trade (round 802, s:0x5261ef).
	if ref, err := cosWorld.depsNow().items.GetItem(ctx, it.ItemID); err == nil && ref != nil && ref.TypeID4 == 2 {
		safeTradeLose(ctx, e.CharacterID)
	}
	d := cosWorld.depsNow()
	if d.bags == nil {
		return refuse(grounditem.ErrCannotPick)
	}
	recID, _, before := transportBag(ctx, o)
	key := pickupLedgerKey(it)
	err := txn.For(d.bags).Run(ctx, func(ctx context.Context) error {
		if err := txn.Claim(ctx, key); err != nil {
			return err
		}
		return d.bags.AddItemInstance(ctx, recID, it.ItemID, int(it.Quantity), inst)
	})
	switch {
	case err == nil:
	case errors.Is(err, txn.ErrAlreadyApplied):
		if gone, ok := ground.Remove(it.ID); ok {
			broadcastGroundRemoval(hub, gone, 0)
		}
		return reply(&PickUpResult{Code: grounditem.ErrNotThere, GroundItemID: it.ID})
	case errors.Is(err, inventory.ErrNoRoom):
		return refuse(ItemErrBagFull)
	default:
		return refuse(grounditem.ErrCannotPick)
	}
	// The slot it went into: a stack it topped up, or the new one.
	_, _, after := transportBag(ctx, o)
	dest := -1
	was := map[int]int{}
	for _, s := range before {
		was[s.Index] = s.Quantity
	}
	for _, s := range after {
		if s.ItemID == it.ItemID && s.Quantity != was[s.Index] {
			dest = s.Index
			break
		}
	}
	ground.Remove(it.ID)
	if dest >= 0 {
		rec := ItemInfo{RefItemID: uint32(it.ItemID)}
		if ref, err := d.items.GetItem(ctx, it.ItemID); err == nil && ref != nil {
			sl := inventory.Slot{Index: dest, ItemID: it.ItemID, Quantity: int(it.Quantity)}
			sl.SetInstance(inst)
			rec.Tail = retailItemTail(ctx, ref, sl, time.Now())
		}
		out := []byte{itemOpOK, ItemMoveCOSPick}
		out = binary.LittleEndian.AppendUint32(out, o.uid)
		out = append(out, byte(dest))
		out = AppendItemRecord(out, rec)
		_ = sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: out})
	}
	if err := reply(&PickUpResult{GroundItemID: it.ID, ItemID: it.ItemID, Quantity: it.Quantity}); err != nil {
		return err
	}
	broadcastPickUpMotion(hub, e.Zone, e.CharacterID, e.Pos.X, e.Pos.Z, it)
	broadcastGroundRemoval(hub, it, e.CharacterID)
	// A good picked into the cart registers the caravan (s:0x4e9676, round
	// 804, caravan.go) and may move the scale (s:0x5265e3).
	refreshTradeScale(ctx, e.CharacterID)
	registerCaravan(ctx, e.CharacterID, "a good picked into the transport")
	return nil
}

// NoticeRobberCartTown is 0x300C's word UIIT_MSG_JSERR_ROBBER_CANT_ENTER_
// TOWN_WITH_CART (READ s:0x4eb220; the client's 0x300C handler sends a word
// it has no case for to the error dispatcher, c:0x874ea0's default). It goes
// on OpUniqueNotice, which carries retail 0x300C's payload.
const NoticeRobberCartTown uint16 = 0x0c01

// thiefEntersTown is CGObjPC::vslot_220's test (s:0x4eb220): a player in
// job state 2 with a cart whose move takes it from a battlefield region
// (IsBattleField != 0) into a town (0). OpenSRO's town is the safe-region
// table (safezone); without the table nothing is vetoed. Tested once a COS
// tick against where the leg puts it one tick later (OURS, as the leash).
func thiefEntersTown(ctx context.Context, owner world.Entity, now world.Position, at time.Time) bool {
	if safeRegions.Load() == nil || jobStateNow(ctx, owner.CharacterID) != byte(jobs.KindThief) {
		return false
	}
	if _, inTown := safeRegionAt(owner.Zone, now.X, now.Z); inTown {
		return false
	}
	next, _ := owner.Move.At(at.Add(cosTick))
	_, nextTown := safeRegionAt(owner.Zone, next.X, next.Z)
	return nextTown
}

// The trade-info window ("Trade Export Details", CIFTradeInfoWnd): 0x74D4
// {u32 NPC ref id} -> 0xB4D4 {u16 n, n x {u32 ref item, u16 percent}}
// (READ FUN_0051a8c0 s:0x51a8c0: no check of any kind -- no NPC, distance,
// job or rate test -- and the reply from AQ_ItemQuotation case 0x1b,
// s:0x4e8c50; specialty.Board.Percents). An NPC with no rows gets {0}.
const (
	OpTradeInfo       uint16 = 0x74D4
	OpTradeInfoResult uint16 = 0xB4D4
)

// EncodeTradeInfo is 0xB4D4.
func EncodeTradeInfo(rows []specialty.ItemPercent) []byte {
	out := binary.LittleEndian.AppendUint16(nil, uint16(len(rows)))
	for _, r := range rows {
		out = binary.LittleEndian.AppendUint32(out, uint32(r.Item))
		out = binary.LittleEndian.AppendUint16(out, r.Percent)
	}
	return out
}

// TradeInfoHandler answers 0x74D4.
func TradeInfoHandler() gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpTradeInfo {
			return nil
		}
		if len(p.Data) < 4 {
			return nil
		}
		npc := int64(binary.LittleEndian.Uint32(p.Data))
		return sess.Send(&proto.Packet{Opcode: OpTradeInfoResult,
			Data: EncodeTradeInfo(specialtyNow().d.Board.Percents(npc))})
	}
}

// clearTransportBag empties a deleted transport's bag: one released with
// its record when its owner dies riding it (PC_ReleaseCOS mode 1, no drop
// call, READ s:0x529b10; what becomes of the goods is OPEN -- they go with
// the deleted transport here, OURS) leaves no rows behind.
func clearTransportBag(ctx context.Context, o *cosObj) {
	d := cosWorld.depsNow()
	if d.bags == nil {
		return
	}
	recID, _, slots := transportBag(ctx, o)
	for _, sl := range slots {
		_ = d.bags.RemoveItem(ctx, recID, sl.Index, sl.Quantity)
	}
}

// goodPickCode is FUN_00525dc0's job test for a good: 0 when a player in job
// state may take it, own telling whether its buyer's name is the player's
// alias.
func goodPickCode(state byte, own bool) uint16 {
	switch jobs.Kind(state) {
	case jobs.KindTrader:
		if !own {
			return tradeErrNotBuyer
		}
	case jobs.KindThief:
		if own {
			return tradeErrRobberOwn
		}
	case jobs.KindHunter:
		return tradeErrNotBuyer
	default:
		return tradeErrNoJobPick
	}
	return 0
}
