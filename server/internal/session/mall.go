package session

// The item mall (round 837): the silk balances, the buy on 0x7034 type 0x18,
// the open request 0x7121, the silk history 0x711a and OpenSRO's item chest.
// The wire, the checks and the codes are internal/mall's, with their
// addresses; this file is the session's part -- who is asking, the one
// transaction a purchase is, and the order the messages go out in.
//
// READ (item_mall_wire.md, _verify):
//   - 0x3153 at world entry (the billing load's completion, s:0x4e781d) and
//     after a silk-priced purchase, BEFORE its 0xB034 (SendMsgToPeer
//     s:0x4e0860 sends at once, s:0x4e9ae0's send runs before s:0x4e9480's).
//   - Every buy request gets an 0xB034: the client stays "dealing" until one
//     comes (wire verify M1).
//   - StorageOperation lets op 0x18 through at INTERACTMODE 0, 1, 5 and 6 and
//     refuses 0x1834 at 2 (the established exchange), 4 and 7; a dead
//     character (vslot 0xf8 == 2) may still buy (s:0x50f67c..0x50f7e8). Of
//     those modes OpenSRO has the exchange (2); an open NPC talk is mode 5
//     or 6 (character_state.md, the 0x7046 table), which op 0x18 passes.
//
// OURS, disclosed:
//   - The balances live on the account row (account.SilkStore), not behind a
//     billing page; a store failure refuses the purchase 2 instead of
//     retail's logout (wire §7).
//   - The purchase is one transaction: the checks on fresh balances, the
//     gold, the silk, the items (or the chest entries) and the purchase log
//     commit together or not at all.
//   - A purchase whose items do not all fit the bag's empty slots goes to the
//     item chest (n = 0 in the reply, then 0x00D6 per item) where retail
//     refuses 0x1807. Retail compares the free slots with n alone and fails a
//     multi-row package inside its loop (wire verify M9); here the whole
//     purchase, every row's items, must fit, or all of it goes to the chest.
//   - A new item is OpenSRO's fresh instance (inventory.FreshInstance: the
//     variance roll and full durability) with the scrap row's plus and blue
//     options; the row's Variance replaces the roll when it is not 0, and a
//     non-stackable's Data replaces the durability (the instance's Data word)
//     when it is not 0. What the procedure makes of a Variance of 0 was not
//     read.

import (
	"context"
	"errors"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// MallDeps is what the mall reads and writes.
type MallDeps struct {
	// Catalogue is the silk shop registry (-mall-csv); nil registers no
	// shop, so every buy is refused 2 ("SilkShop was not registered").
	Catalogue *mall.Catalogue
	Store     mall.Store
	Silk      account.SilkStore
	Chars     character.Store
	Inv       inventory.Store
	Items     ItemLookup
	Hub       *world.Hub
	Trades    *trade.Hub
	Logger    *slog.Logger
	// Now is the clock; nil is time.Now.
	Now func() time.Time
}

var mallRT atomic.Pointer[MallDeps]

func (d *MallDeps) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

func (d *MallDeps) logger() *slog.Logger {
	if d.Logger != nil {
		return d.Logger
	}
	return slog.Default()
}

// MallHandler serves 0x7121, 0x711a and the chest's 0x00D0/0x00D2/0x00D4;
// the buy is the item operation's type 0x18 (itemop.go -> mallBuy).
func MallHandler(d MallDeps) gateway.Handler {
	dd := d
	mallRT.Store(&dd)
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case mall.OpOpen:
			return dd.open(sess, p.Data)
		case mall.OpHistory:
			return dd.history(ctx, sess, p.Data)
		case mall.OpChestList:
			return dd.chestList(ctx, sess)
		case mall.OpChestTake:
			return dd.chestTake(ctx, sess, p.Data)
		case mall.OpChestLog:
			return dd.chestLog(ctx, sess)
		}
		return nil
	}
}

// who is the session's character and account; ok false outside the world.
func (d *MallDeps) who(sess *gateway.Session) (world.Entity, int64, bool) {
	if d.Hub == nil {
		return world.Entity{}, 0, false
	}
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return world.Entity{}, 0, false
	}
	acct, ok := AuthenticatedAccountID(sess)
	return e, acct, ok
}

// open answers 0x7121 (mall.EncodeOpen): the window opens on result 1.
func (d *MallDeps) open(sess *gateway.Session, data []byte) error {
	var group uint16
	if len(data) >= 2 {
		group = uint16(data[0]) | uint16(data[1])<<8
	}
	return sess.Send(&proto.Packet{Opcode: mall.OpOpenResult, Data: mall.EncodeOpen(group)})
}

// --- the balances -----------------------------------------------------------

// sendSilk sends 0x3153 with the account's balances.
func (d *MallDeps) sendSilk(ctx context.Context, sess *gateway.Session, acct int64) {
	if d.Silk == nil {
		return
	}
	b, err := d.Silk.Silk(ctx, acct)
	if err != nil {
		d.logger().Warn("mall: reading silk failed", "account", acct, "err", err)
		return
	}
	sendTo(sess, mall.OpSilk, mall.EncodeBalances(balancesOf(b)))
}

func balancesOf(b account.Silk) mall.Balances {
	return mall.Balances{Own: b.Own, Gift: b.Gift, Point: b.Point}
}

// mallAfterEnter sends the arriving character its account's balances (READ:
// retail's billing load completes after the placement and sends 0x3153).
func mallAfterEnter(ctx context.Context, sess *gateway.Session) {
	d := mallRT.Load()
	if d == nil {
		return
	}
	if acct, ok := AuthenticatedAccountID(sess); ok {
		d.sendSilk(ctx, sess, acct)
	}
}

// SilkChanged tells a session its balances changed from outside a purchase
// (the GM's /silk): 0x3154 {reason, cashType, offset}, then 0x3153 with the
// balances after, as retail's outside-change path s:0x4f0750 does.
func SilkChanged(sess *gateway.Session, reason, cashType byte, offset int64, after account.Silk) {
	sendTo(sess, mall.OpSilkChange, mall.EncodeSilkChange(reason, cashType, offset))
	sendTo(sess, mall.OpSilk, mall.EncodeBalances(balancesOf(after)))
}

// --- the buy ----------------------------------------------------------------

var errMallRefused = errors.New("mall: refused")

// mallBuy is 0x7034 type 0x18. The caller (handleItemMove) has refused the
// established exchange 0x1834 already.
func mallBuy(ctx context.Context, sess *gateway.Session, data []byte) error {
	fail := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: mall.EncodeBuyFail(code)})
	}
	d := mallRT.Load()
	req, err := mall.DecodeBuy(data)
	if d == nil || err != nil {
		return fail(mall.CodeFail)
	}
	e, acct, ok := d.who(sess)
	if !ok || d.Silk == nil || d.Store == nil || d.Inv == nil || d.Chars == nil {
		return fail(mall.CodeFail)
	}
	if d.Trades.Established(e.CharacterID) {
		return fail(mall.CodeBlocked)
	}
	res, code, err := d.purchase(ctx, e.CharacterID, acct, req)
	if code != 0 {
		return fail(code)
	}
	if err != nil {
		d.logger().Warn("mall: the purchase failed", "character", e.CharacterID, "package", req.Code, "err", err)
		return fail(mall.CodeFail)
	}
	if res.plan.SilkPriced() {
		sendTo(sess, mall.OpSilk, mall.EncodeBalances(balancesOf(res.after)))
	}
	if err := sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: mall.EncodeBuyOK(req, res.slots)}); err != nil {
		return err
	}
	for _, c := range res.chest {
		sendTo(sess, mall.OpChestReceived, mall.EncodeChestReceived(c.ItemID, c.Quantity))
	}
	d.logger().Info("mall: purchase", "character", e.CharacterID, "account", acct, "package", req.Code,
		"quantity", req.Quantity, "own", res.plan.Pay.Own, "gift", res.plan.Pay.Gift, "point", res.plan.Pay.Point,
		"gold", res.plan.Pay.Gold, "slots", res.slots, "chest", len(res.chest))
	return nil
}

type purchaseResult struct {
	plan  mall.Plan
	slots []int // bag indexes, in the plan's unit order
	chest []mall.ChestEntry
	after account.Silk
}

// purchase runs the checks and the payment as one transaction.
func (d *MallDeps) purchase(ctx context.Context, cid, acct int64, req mall.BuyRequest) (purchaseResult, uint16, error) {
	var res purchaseResult
	var refusal uint16
	err := txn.For(d.Silk, d.Inv, d.Chars, d.Store).Run(ctx, func(ctx context.Context) error {
		res, refusal = purchaseResult{}, 0
		refuse := func(code uint16) error {
			refusal = code
			return errMallRefused
		}
		w, err := d.wallet(ctx, cid, acct)
		if err != nil {
			return err
		}
		plan, code := mall.Check(d.Catalogue, req, w)
		if code != 0 {
			return refuse(code)
		}
		res.plan, res.after = plan, account.Silk{Own: w.Silk.Own, Gift: w.Silk.Gift, Point: w.Silk.Point}
		if plan.Pay.Gold > 0 {
			if err := d.Chars.DeductGold(ctx, cid, plan.Pay.Gold); err != nil {
				if errors.Is(err, character.ErrInsufficientGold) {
					return refuse(mall.CodeNoGold)
				}
				return err
			}
		}
		if plan.Pay.Silk() > 0 {
			after, err := d.Silk.SpendSilk(ctx, acct, plan.Pay.Own, plan.Pay.Gift, plan.Pay.Point)
			if errors.Is(err, account.ErrInsufficientSilk) {
				return refuse(mall.CodeNoSilk)
			}
			if err != nil {
				return err
			}
			res.after = after
		}
		if code, err := d.deliver(ctx, cid, plan, &res); code != 0 || err != nil {
			if code != 0 {
				return refuse(code)
			}
			return err
		}
		return d.Store.RecordPurchase(ctx, mall.Purchase{AccountID: acct, CharacterID: cid,
			PackageID: plan.Good.Package.ID, PackageCode: plan.Good.Package.Code, Quantity: int(req.Quantity),
			Pay: plan.Pay, ToChest: len(res.chest) > 0, At: d.now()})
	})
	if errors.Is(err, errMallRefused) {
		return purchaseResult{}, refusal, nil
	}
	return res, 0, err
}

// wallet is the buyer's gold and balances, read inside the transaction.
func (d *MallDeps) wallet(ctx context.Context, cid, acct int64) (mall.Wallet, error) {
	c, err := d.Chars.GetByID(ctx, cid)
	if err != nil {
		return mall.Wallet{}, err
	}
	b, err := d.Silk.Silk(ctx, acct)
	if err != nil {
		return mall.Wallet{}, err
	}
	return mall.Wallet{Gold: c.Gold, Silk: balancesOf(b)}, nil
}

// deliver puts the plan's items into the bag's first empty slots (from bag
// index 0, s:0x618fe0's FindFirstEmptySlot(0xd)), or every one of them into
// the chest when they do not all fit (OURS).
func (d *MallDeps) deliver(ctx context.Context, cid int64, plan mall.Plan, res *purchaseResult) (uint16, error) {
	placer, ok := d.Inv.(inventory.Placer)
	if !ok {
		return mall.CodeDB, nil
	}
	free, err := bagEmptySlots(ctx, d.Inv, placer, cid)
	if err != nil {
		return 0, err
	}
	if len(free) < len(plan.Units) {
		for _, u := range plan.Units {
			e := chestEntryOf(cid, u, d.now())
			id, err := d.Store.AddToChest(ctx, e)
			if err != nil {
				return 0, err
			}
			e.ID = id
			res.chest = append(res.chest, e)
		}
		return 0, nil
	}
	for i, u := range plan.Units {
		inst, err := mallInstance(ctx, d.Items, u.Scrap.Item.ID, u.Scrap.OptLevel, u.Scrap.Variance, dataWord(u.Scrap), u.Scrap.MagParams)
		if err != nil {
			return 0, err
		}
		if err := placer.PlaceItemInstance(ctx, cid, free[i], u.Scrap.Item.ID, u.Stack, inst); err != nil {
			if errors.Is(err, inventory.ErrSlotTaken) || errors.Is(err, inventory.ErrInvalidSlot) || errors.Is(err, inventory.ErrNoRoom) {
				return mall.CodeBagFull, nil // the placement loop's own code (wire verify M9)
			}
			return 0, err
		}
		res.slots = append(res.slots, free[i])
	}
	return 0, nil
}

// dataWord is the scrap row's Data as the instance's word: a stackable's Data
// is its stack count instead (mall.Unit.Stack).
func dataWord(sc mall.Scrap) int {
	if sc.Item.Stackable() {
		return 0
	}
	return sc.Data
}

func chestEntryOf(cid int64, u mall.Unit, at time.Time) mall.ChestEntry {
	return mall.ChestEntry{Owner: cid, ItemID: u.Scrap.Item.ID, Quantity: u.Stack, OptLevel: u.Scrap.OptLevel,
		Variance: u.Scrap.Variance, Data: dataWord(u.Scrap), MagParams: u.Scrap.MagParams, From: mall.FromItemMall, At: at}
}

// bagEmptySlots is the bag's empty slots in order, within its placement size.
func bagEmptySlots(ctx context.Context, inv inventory.Store, p inventory.Placer, cid int64) ([]int, error) {
	held, err := inv.List(ctx, cid)
	if err != nil {
		return nil, err
	}
	used := make(map[int]bool, len(held))
	for _, s := range held {
		used[s.Index] = true
	}
	var out []int
	for i := 0; i < p.PlacementCapacityFor(ctx, cid); i++ {
		if !used[i] {
			out = append(out, i)
		}
	}
	return out, nil
}

// mallInstance is a new item's instance (the file comment's OURS rule).
func mallInstance(ctx context.Context, items ItemLookup, itemID int64, opt uint8, variance uint64, data int, params []uint64) (inventory.Instance, error) {
	lookup, _ := items.(inventory.DurabilityLookup)
	inst, err := inventory.FreshInstance(ctx, lookup, nil, itemID)
	if err != nil {
		return inventory.Instance{}, err
	}
	inst.OptLevel = opt
	inst.MagParams = append([]uint64(nil), params...)
	if variance != 0 {
		inst.Variance = variance
		if inst.Durability != durability.Untracked && lookup != nil {
			if lo, hi, ok, err := lookup.DurabilityRange(ctx, itemID); err == nil && ok {
				inst.Durability = durability.MaxDurability(lo, hi, variance)
			}
		}
	}
	if data > 0 {
		inst.Durability = data
	}
	return inst, nil
}

// --- the silk history ---------------------------------------------------------

// history answers 0x711a (mall/history.go): kind 1 from the purchase log
// (OURS: OpenSRO's log of the silk its purchases took), any other kind 1..3
// with no rows; a kind or period _GetSilkHistory cannot answer gets a
// non-zero result (OURS), a cancel nothing.
func (d *MallDeps) history(ctx context.Context, sess *gateway.Session, data []byte) error {
	kind, period, ok := mall.DecodeHistory(data)
	if !ok || period == mall.HistoryCancel {
		return nil
	}
	reply := func(b []byte) error { return sess.Send(&proto.Packet{Opcode: mall.OpHistoryResult, Data: b}) }
	since, okPeriod := mall.PeriodStart(period, d.now())
	_, acct, in := d.who(sess)
	if !okPeriod || kind < 1 || kind > 3 || !in || d.Store == nil {
		return reply(mall.EncodeHistoryFailed(kind, period))
	}
	if kind != mall.HistoryBuying {
		return reply(mall.EncodeHistory(kind, period, nil))
	}
	rows, err := d.Store.Purchases(ctx, acct, since)
	if err != nil {
		d.logger().Warn("mall: reading the purchase log failed", "account", acct, "err", err)
		return reply(mall.EncodeHistoryFailed(kind, period))
	}
	return reply(mall.EncodeHistory(kind, period, rows))
}

// --- the item chest (OURS) ---------------------------------------------------

func (d *MallDeps) chestList(ctx context.Context, sess *gateway.Session) error {
	e, _, ok := d.who(sess)
	if !ok || d.Store == nil {
		return sess.Send(&proto.Packet{Opcode: mall.OpChestListResult, Data: mall.EncodeChestList(nil)})
	}
	es, err := d.Store.Chest(ctx, e.CharacterID)
	if err != nil {
		d.logger().Warn("mall: reading the chest failed", "character", e.CharacterID, "err", err)
	}
	return sess.Send(&proto.Packet{Opcode: mall.OpChestListResult, Data: mall.EncodeChestList(es)})
}

func (d *MallDeps) chestLog(ctx context.Context, sess *gateway.Session) error {
	e, _, ok := d.who(sess)
	var ls []mall.TakeLogEntry
	if ok && d.Store != nil {
		var err error
		ls, err = d.Store.TakeLog(ctx, e.CharacterID, d.now().AddDate(0, 0, -mall.TakeLogDays))
		if err != nil {
			d.logger().Warn("mall: reading the take log failed", "character", e.CharacterID, "err", err)
		}
	}
	return sess.Send(&proto.Packet{Opcode: mall.OpChestLogResult, Data: mall.EncodeTakeLog(ls)})
}

// chestTake is 0x00D2: one entry, or every entry in order until the bag is
// full, each taken and placed in one transaction; then 0x00D3 and a fresh
// list.
func (d *MallDeps) chestTake(ctx context.Context, sess *gateway.Session, data []byte) error {
	reply := func(b []byte) error {
		if err := sess.Send(&proto.Packet{Opcode: mall.OpChestTakeResult, Data: b}); err != nil {
			return err
		}
		return d.chestList(ctx, sess)
	}
	id, okReq := mall.DecodeChestTake(data)
	e, _, ok := d.who(sess)
	if !okReq || !ok || d.Store == nil || d.Inv == nil {
		return reply(mall.EncodeChestTakeFail(mall.CodeFail))
	}
	if d.Trades.Established(e.CharacterID) {
		return reply(mall.EncodeChestTakeFail(mall.CodeBlocked))
	}
	taken, code, err := d.take(ctx, e.CharacterID, id)
	switch {
	case code != 0:
		return reply(mall.EncodeChestTakeFail(code))
	case err != nil:
		d.logger().Warn("mall: a chest take failed", "character", e.CharacterID, "entry", id, "err", err)
		return reply(mall.EncodeChestTakeFail(mall.CodeDB))
	}
	return reply(mall.EncodeChestTaken(taken))
}

// take moves chest entries into the bag's first empty slots.
func (d *MallDeps) take(ctx context.Context, cid int64, id uint32) (int, uint16, error) {
	placer, ok := d.Inv.(inventory.Placer)
	if !ok {
		return 0, mall.CodeDB, nil
	}
	var taken int
	var refusal uint16
	err := txn.For(d.Inv, d.Store).Run(ctx, func(ctx context.Context) error {
		taken, refusal = 0, 0
		refuse := func(code uint16) error {
			refusal = code
			return errMallRefused
		}
		es, err := d.Store.Chest(ctx, cid)
		if err != nil {
			return err
		}
		if id != mall.TakeAll {
			es = entryNamed(es, int64(id))
			if len(es) == 0 {
				return refuse(mall.CodeNoGood)
			}
		}
		free, err := bagEmptySlots(ctx, d.Inv, placer, cid)
		if err != nil {
			return err
		}
		if len(es) > 0 && len(free) == 0 {
			return refuse(mall.CodeBagFull)
		}
		for _, en := range es {
			if taken >= len(free) {
				break
			}
			got, err := d.Store.TakeFromChest(ctx, cid, en.ID, d.now())
			if errors.Is(err, mall.ErrNoSuchEntry) {
				if id != mall.TakeAll {
					return refuse(mall.CodeNoGood) // taken by a request just before
				}
				continue
			}
			if err != nil {
				return err
			}
			inst, err := mallInstance(ctx, d.Items, got.ItemID, got.OptLevel, got.Variance, got.Data, got.MagParams)
			if err != nil {
				return err
			}
			if err := placer.PlaceItemInstance(ctx, cid, free[taken], got.ItemID, got.Quantity, inst); err != nil {
				return err
			}
			taken++
		}
		return nil
	})
	if errors.Is(err, errMallRefused) {
		return 0, refusal, nil
	}
	return taken, 0, err
}

func entryNamed(es []mall.ChestEntry, id int64) []mall.ChestEntry {
	for _, e := range es {
		if e.ID == id {
			return []mall.ChestEntry{e}
		}
	}
	return nil
}
