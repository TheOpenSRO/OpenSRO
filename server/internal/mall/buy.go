package mall

import (
	"encoding/binary"
	"errors"
)

// The buy on the retail wire (item_mall_wire.md §1, §3; READ):
//
//	C->S 0x7034 {u8 0x18, u16 shopGroupId, u8 shopIndexInGroup, u8 tab, u8 slot,
//	             str packageCodeName, u16 quantity, u64 pointsToUse, u32 packageId}
//	S->C 0x3153 {u32 own, u32 gift, u32 point}          first, when the good is silk-priced
//	S->C 0xB034 {u8 1, u8 0x18, u16 group, u8 shop, u8 tab, u8 slot, u8 n,
//	             n x u8 bagSlot, u16 quantity, n x rent block}
//	S->C 0xB034 {u8 2, u16 code}                        a refusal
//
// Strings are u16 length + bytes (c:0x78f480, s:0x404b60). The bag slot is
// the bag index + 13. The rent block is the item record's first field: u32
// flags, 0 for an item with no rent object (s:0x862960 writes the zero); every
// rent table is empty in the data (item_mall_data.md §1.11, MEASURED), so
// every block here is the u32 0.
//
// OURS: n = 0 says the purchase went to OpenSRO's item chest (chest.go), the
// bag having had too few empty slots; retail refuses 0x1807 there.

// OpItemMove's type for the mall buy.
const BuyType byte = 0x18

// BagWireOffset is the 13 worn slots before the bag on the wire.
const BagWireOffset = 13

// The codes the buy answers (docs/protocol/error_codes.md; the client shows
// nothing for 2, 0x1806, 0x1809, 0x1811, 0x1842 and 0x18ab: wire verify M2).
const (
	CodeFail         uint16 = 2
	CodeNoTab        uint16 = 0x1806
	CodeBagFull      uint16 = 0x1807
	CodeNoGood       uint16 = 0x1809
	CodeNoGold       uint16 = 0x180f // NOT_ENOUGH_GOLD
	CodeDB           uint16 = 0x1811
	CodeBlocked      uint16 = 0x1834 // STORAGE_OPERATION_BLOCKED
	CodeCreate       uint16 = 0x1842
	CodeNoSilk       uint16 = 0x1880 // NOT_ENOUGH_SILK_TO_BUY_ITEM
	CodeCodeName     uint16 = 0x18ab
	CodeNoGuild      uint16 = 0x18c4
	CodeGuildPoints  uint16 = 0x18c5
	CodeHonor        uint16 = 0x18d4 // TC_LACK_HONOR_POINT
	maxUnitsPerScrap        = 5      // s:0x4de170 clamps to 1..5
)

// BuyRequest is a decoded 0x7034 type 0x18.
type BuyRequest struct {
	Group     uint16
	Shop      uint8
	Tab       uint8
	Slot      uint8
	Code      string
	Quantity  uint16
	Points    uint64
	PackageID uint32 // read and unused, as the server's buy path (wire verify §3.1)
}

// ErrShort is a truncated request.
var ErrShort = errors.New("mall: truncated buy request")

// DecodeBuy reads a 0x7034 body that starts with the type byte 0x18 (the
// order of the client's serializer c:0x792944..0x79299d and the server's
// parser s:0x4d8d52..0x4d8dc3, READ).
func DecodeBuy(b []byte) (BuyRequest, error) {
	var r BuyRequest
	if len(b) < 8 || b[0] != BuyType {
		return r, ErrShort
	}
	r.Group = binary.LittleEndian.Uint16(b[1:])
	r.Shop, r.Tab, r.Slot = b[3], b[4], b[5]
	n := int(binary.LittleEndian.Uint16(b[6:]))
	b = b[8:]
	if len(b) < n+14 {
		return r, ErrShort
	}
	r.Code = string(b[:n])
	b = b[n:]
	r.Quantity = binary.LittleEndian.Uint16(b)
	r.Points = binary.LittleEndian.Uint64(b[2:])
	r.PackageID = binary.LittleEndian.Uint32(b[10:])
	return r, nil
}

// EncodeBuy is the request, for the QA bot and the tests.
func EncodeBuy(r BuyRequest) []byte {
	out := []byte{BuyType}
	out = binary.LittleEndian.AppendUint16(out, r.Group)
	out = append(out, r.Shop, r.Tab, r.Slot)
	out = binary.LittleEndian.AppendUint16(out, uint16(len(r.Code)))
	out = append(out, r.Code...)
	out = binary.LittleEndian.AppendUint16(out, r.Quantity)
	out = binary.LittleEndian.AppendUint64(out, r.Points)
	return binary.LittleEndian.AppendUint32(out, r.PackageID)
}

// EncodeBuyOK is the success reply: bagSlots are bag indexes (the +13 is
// added here), one rent block (u32 0) per slot. No slots is OURS: the chest.
func EncodeBuyOK(r BuyRequest, bagSlots []int) []byte {
	out := []byte{1, BuyType}
	out = binary.LittleEndian.AppendUint16(out, r.Group)
	out = append(out, r.Shop, r.Tab, r.Slot, byte(len(bagSlots)))
	for _, s := range bagSlots {
		out = append(out, byte(s+BagWireOffset))
	}
	out = binary.LittleEndian.AppendUint16(out, r.Quantity)
	for range bagSlots {
		out = binary.LittleEndian.AppendUint32(out, 0)
	}
	return out
}

// EncodeBuyFail is {2, code}.
func EncodeBuyFail(code uint16) []byte {
	return binary.LittleEndian.AppendUint16([]byte{2}, code)
}

// Balances are an account's three silk balances, in 0x3153's order (READ
// s:0x4f0959..0x4f096a; own/gift/mileage named by the purchase call's
// @OwnSilkToPay/@GiftSilkToPay/@MileageToPay, data verify W6).
type Balances struct {
	Own, Gift, Point int64
}

// EncodeBalances is 0x3153: each clamped to 0 when negative (s:0x4f0940) and,
// OURS, to the u32's top.
func EncodeBalances(b Balances) []byte {
	out := make([]byte, 0, 12)
	for _, v := range []int64{b.Own, b.Gift, b.Point} {
		out = binary.LittleEndian.AppendUint32(out, clampU32(v))
	}
	return out
}

func clampU32(v int64) uint32 {
	if v < 0 {
		return 0
	}
	if v > 0xffffffff {
		return 0xffffffff
	}
	return uint32(v)
}

// The outside-change reasons of 0x3154 (c:0x882e50's strings, READ).
const (
	ReasonBuyResult  byte = 0 // UIIT_STT_SILK_BUY_RESULT
	ReasonBuyCancel  byte = 1
	ReasonReceived   byte = 2 // UIIT_STT_SILK_BUY_RECEIVE
	ReasonSendResult byte = 3
	ReasonPointBuy   byte = 4
	ReasonPointUse   byte = 5
	CashOwn          byte = 0 // s:0x4f0750's cash types
	CashGift         byte = 1
	CashPoint        byte = 2
)

// EncodeSilkChange is 0x3154 {u8 reason, u8 cashType, u32 offset}
// (s:0x4f086c..0x4f08bd). The client reads the cash type and does not use it.
func EncodeSilkChange(reason, cashType byte, offset int64) []byte {
	return binary.LittleEndian.AppendUint32([]byte{reason, cashType}, clampU32(offset))
}

// Wallet is what the buyer can pay with.
type Wallet struct {
	Gold int64
	Silk Balances
}

// Payment is what a purchase takes, by currency.
type Payment struct {
	Gold             int64
	Own, Gift, Point int64
}

// Silk is the silk part, the history's offset.
func (p Payment) Silk() int64 { return p.Own + p.Gift + p.Point }

// Unit is one item the purchase makes: a scrap row and its stack.
type Unit struct {
	Scrap Scrap
	Stack int
}

// Plan is a purchase that passed every check.
type Plan struct {
	Good *Good
	// Slots is n, the slots the purchase needs per s:0x4de170 (what the
	// retail bag test compares with); Units are the items in the order the
	// server's loop makes them (scrap row outer, count inner, s:0x618fe0),
	// which is the order the client reads the reply's slots in (c:0x87fa13).
	Slots int
	Units []Unit
	Pay   Payment
}

// SilkPriced reports a good priced in silk: its purchase sends 0x3153
// (s:0x4e9ae0 runs when the request mask has 2, 4 or 0x10; the mask is
// rebuilt from the database's cost rows, wire verify §2).
func (p Plan) SilkPriced() bool {
	return p.Good.Package.Mask&(DeviceSilk|DeviceGiftSilk|DevicePoint) != 0
}

// SlotsNeeded is s:0x4de170 / _GetNeededSlotCountByBuyPackageItem (READ): 1
// for a one-row package whose item is a non-bionic 3/3 with Data 0, else the
// quantity clamped to 1..5.
func SlotsNeeded(p *Package, qty int) int {
	if len(p.Scraps) == 1 && p.Scraps[0].Item.Expendable() && p.Scraps[0].Data == 0 {
		return 1
	}
	return min(max(qty, 1), maxUnitsPerScrap)
}

// stackOf is s:0x6190c0..0x6190dd: a stackable gets the row's Data, or the
// quantity when Data is 0; anything else 1.
func stackOf(sc Scrap, qty int) int {
	if !sc.Item.Stackable() {
		return 1
	}
	if sc.Data > 0 {
		return sc.Data
	}
	return qty
}

// Check runs the buy's checks in the server's order (wire §3.2 with the
// review's corrections) and answers the plan, or the refusal's code. The
// StorageOperation guards (INTERACTMODE) are the caller's, as is the bag's
// room: retail refuses 0x1807 when it is short, OpenSRO sends the purchase to
// the chest instead (OURS).
func Check(cat *Catalogue, r BuyRequest, w Wallet) (Plan, uint16) {
	// 2. The silk shop: the group, then the shop at its index (s:0x526610).
	shop, ok := cat.Shop(int(r.Group), int(r.Shop))
	if !ok {
		return Plan{}, CodeFail
	}
	// 3. The shop's access list (s:0x617a30): `refaccesspermissionofshop` is
	// empty in every source (MEASURED), so it has nothing to refuse.
	// 4. s:0x617a50: the tab, the quantity as a signed i16 (s:0x617ab6:
	// 0x8000..0xffff are negative), the good.
	if int(r.Tab) >= len(shop.Tabs) {
		return Plan{}, CodeNoTab
	}
	qty := int(int16(r.Quantity))
	if qty <= 0 {
		return Plan{}, CodeFail
	}
	good := shop.Tabs[r.Tab].Goods[int(r.Slot)]
	if good == nil {
		return Plan{}, CodeNoGood
	}
	pk := good.Package
	// 5. The code name must be the good's package's (s:0x617afc..0x617b16).
	if r.Code != pk.Code {
		return Plan{}, CodeCodeName
	}
	// 6. A one-row stackable with Data 0 must fit one stack (W5 b).
	if code := oneStackRule(pk, qty); code != 0 {
		return Plan{}, code
	}
	// 7. The slots (n < 6 always holds: s:0x4de170 clamps to 5).
	n := SlotsNeeded(pk, qty)
	// OURS: a package with no scrap row (the procedure's 255 slots, which
	// never fit) and a per-unit quantity above 5 (retail charges cost x qty,
	// makes 5 and the client walks past the reply's slots: wire verify M4;
	// the client's box caps such goods at 5) are refused 2.
	if len(pk.Scraps) == 0 || (n > 1 && qty > maxUnitsPerScrap) {
		return Plan{}, CodeFail
	}
	// The stock and sale-period tables (0x18cf / 0x18aa) are empty in every
	// source (MEASURED) and are not exported.
	// 8. The currencies, in CheckCurrencyRequirement's order (W6).
	pay, code := checkCurrency(pk, r, qty, w)
	if code != 0 {
		return Plan{}, code
	}
	// The ExpandTerm mask (s:0x617950, M6), then the package's sell
	// conditions (M7: `refconditiontosellpackageitem` is empty, MEASURED).
	if code := expandTerm(pk); code != 0 {
		return Plan{}, code
	}
	plan := Plan{Good: good, Slots: n, Pay: pay}
	for _, sc := range pk.Scraps {
		for i := 0; i < n; i++ {
			plan.Units = append(plan.Units, Unit{Scrap: sc, Stack: stackOf(sc, qty)})
		}
	}
	return plan, 0
}

// oneStackRule is s:0x617b27..0x617cf6 for a one-row stackable (W5). Part (a)
// runs only with the server flag CMainProcess+0x42404 (the trade limit), which
// OpenSRO does not have. Part (b), Data 0: a non-bionic 3/3 must fit MaxStack
// (s:0x728130); a TypeID2-1 item has its own test (s:0x7283a0, not read here:
// INFERRED the same MaxStack test, and no such item stacks in the data); any
// other item refuses (its quantity must be 0). Every failure is 2.
func oneStackRule(pk *Package, qty int) uint16 {
	if len(pk.Scraps) != 1 {
		return 0
	}
	sc := pk.Scraps[0]
	if !sc.Item.Stackable() || sc.Data != 0 {
		return 0
	}
	switch {
	case sc.Item.Expendable(), sc.Item.TypeID[1] == 1:
		if qty > sc.Item.MaxStack {
			return CodeFail
		}
		return 0
	default:
		return CodeFail
	}
}

// expandTerm is s:0x617950 (M6): ALL needs a price for every device the
// package has (the prices are built one per device bit, so they always
// cover it here); ONE passes when any device is priced; anything else is 2.
func expandTerm(pk *Package) uint16 {
	priced := pk.Mask
	switch pk.ExpandTerm {
	case ExpandTermAll:
		if priced != pk.Mask {
			return CodeFail
		}
	case ExpandTermOne:
		if priced == 0 {
			return CodeFail
		}
	default:
		return CodeFail
	}
	return 0
}

// price is a device's amount: (i16)qty x Cost (s:0x865d90, READ).
func price(pk *Package, dev uint32, qty int) int64 {
	return int64(qty) * pk.Cost[dev]
}

// checkCurrency is CheckCurrencyRequirement (s:0x617360) in its order: gold,
// the tokens, honour, silk, guild points last.
func checkCurrency(pk *Package, r BuyRequest, qty int, w Wallet) (Payment, uint16) {
	var pay Payment
	// Gold: INFERRED Cost x qty. The engine prices bit 1 through the shop
	// (vslot 0xc), adds the fortress tax and floors it at 1 (s:0x617000);
	// OpenSRO has no fortress tax.
	if pk.Mask&DeviceGold != 0 {
		pay.Gold = max(price(pk, DeviceGold, qty), 1)
		if w.Gold < pay.Gold {
			return Payment{}, CodeNoGold
		}
	}
	// The tokens are payable by operation 0x2b only; any other operation with
	// a token bit is refused 2 (data verify M8).
	if pk.Mask&DeviceTokens != 0 {
		return Payment{}, CodeFail
	}
	// Honour (the academy's points): OURS, OpenSRO keeps none, so any honour
	// price above 0 is short.
	if pk.Mask&DeviceHonor != 0 && price(pk, DeviceHonor, qty) > 0 {
		return Payment{}, CodeHonor
	}
	if pk.Mask&(DeviceSilk|DeviceGiftSilk) != 0 {
		own, gift, point, code := splitSilk(pk, r, qty, w.Silk)
		if code != 0 {
			return Payment{}, code
		}
		pay.Own, pay.Gift, pay.Point = own, gift, point
	}
	// Guild points: the master's guild's GatheredSP. OURS: not wired to the
	// guild store; refused as "no guild or not master" (no mall good of any
	// source uses bit 8, MEASURED).
	if pk.Mask&DeviceGuildPoint != 0 {
		return Payment{}, CodeNoGuild
	}
	return pay, 0
}

// splitSilk is the silk block of s:0x617360 and its deduction in s:0x618930
// (READ): the price is bit 2's, else bit 4's; the money available is own (bit
// 2) + gift (bit 4) + points (bit 16); the points to use must be 0..points
// and at most the price; the rest is paid by gift silk alone (bit 4 only), own
// silk alone (bit 2 only), or gift first and own the remainder (both).
func splitSilk(pk *Package, r BuyRequest, qty int, b Balances) (own, gift, point int64, code uint16) {
	has := func(d uint32) bool { return pk.Mask&d != 0 }
	var p int64
	if has(DeviceSilk) {
		p = price(pk, DeviceSilk, qty)
	} else {
		p = price(pk, DeviceGiftSilk, qty)
	}
	var avail, pointBal int64
	if has(DeviceSilk) {
		avail += max(b.Own, 0)
	}
	if has(DeviceGiftSilk) {
		avail += max(b.Gift, 0)
	}
	if has(DevicePoint) {
		pointBal = max(b.Point, 0)
		avail += pointBal
	}
	if avail < p {
		return 0, 0, 0, CodeNoSilk
	}
	pts := int64(r.Points) // the request's u64 as the engine's signed field
	if pts < 0 || pts > pointBal || pts > p {
		return 0, 0, 0, CodeFail
	}
	rest := p - pts
	switch {
	case has(DeviceGiftSilk) && !has(DeviceSilk):
		if rest > b.Gift {
			return 0, 0, 0, CodeNoSilk
		}
		gift = rest
	case has(DeviceSilk) && !has(DeviceGiftSilk):
		if rest > b.Own {
			return 0, 0, 0, CodeNoSilk
		}
		own = rest
	default:
		gift = min(max(b.Gift, 0), rest)
		own = rest - gift
		if own > b.Own {
			return 0, 0, 0, CodeFail
		}
	}
	return own, gift, pts, 0
}
