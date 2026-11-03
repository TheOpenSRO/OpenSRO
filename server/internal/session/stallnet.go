package session

// The stall network (round 840, lane N): the window that searches the items
// other players' stalls hold and buys one remotely. docs/protocol/
// stall_network.md has the reading; c: is sro_client.exe, s: SR_GameServer.exe.
//
//	C->S 0x7461 {u8 mode, u8 page, u32 group, u8 degree}   search (c:0x821ae0)
//	S->C 0xB461 {1, u8 n, u8 pages, n x record} | {2, u16}  (c:0x88dca0)
//	C->S 0x7462 {}                                         leave (c:0x821bd0)
//	S->C 0xB462 {1}                                        (c:0x88df60 reads a byte)
//	C->S 0x7463 {u32 owner, u8 slot, u64 price, u16 count, u8 level, u64 serial}  (c:0x821c70)
//	S->C 0xB463 {1} | {2, u16}                             (c:0x88dec0; s:0x4738e9)
//	S->C 0x30B7 {4, u8 slot, str buyer, list}              a network sale (s:0x473a40..)
//
// A record (c:0x6c98e0): the item record (mode 1), u32 owner, str seller,
// u8 slot, u16 count, u8 level, u64 price, u64 serial.
//
// The client is READ; this server's rules are not -- SR_GameServer.exe has no
// handler for 0x7461..0x7463 (stall_network.md §0) -- so everything below is
// INFERRED from the client and the sale's tail that is left, or OURS:
//
//   - The town is _RefRegion's (IsBattleField 0, session.SetSafeRegions)
//     where the client reads regioninfo.txt's #TOWN; with no region table
//     loaded every place counts as a town (OURS), so a server without
//     -regions-csv still has a network.
//   - The record's serial is the listing's number (stall.Listing.Seq), not
//     the stack's 64-bit id: it tells a listing from a later one in the same
//     slot, which is what the buy's echo is for (OURS).
//   - Newest listing first; the searcher's own stall left out; a new search
//     sooner than 10 s after the last refused 0x3c46 (the client's own
//     interval, UIIT_MSG_WARENETWORK_SCAN_TOOLTIP); a page re-read from the
//     live stalls, a listing gone since left out of it.
//   - The sale is round 839's one transaction (sellFor) with the commission
//     taken from the owner's proceeds; a failed transaction closes the stall
//     0x3c48 (s:0x43ffd2's reason for the network job) and nobody is
//     disconnected.
//   - The event item goes into the first free bag slot after the sale's
//     transaction, nothing when the bag is full.

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"math/rand"
	"sort"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/stall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	OpStallNetSearch       uint16 = 0x7461
	OpStallNetSearchResult uint16 = 0xB461
	OpStallNetLeave        uint16 = 0x7462
	OpStallNetLeaveResult  uint16 = 0xB462
	OpStallNetBuy          uint16 = 0x7463
	OpStallNetBuyResult    uint16 = 0xB463
)

// StallEventNetSold is 0x30B7 kind 4, a sale through the network (s:0x473a48).
const StallEventNetSold byte = 4

// The codes (c:0x7b8b40 case 10; stall_network.md §2).
const (
	StallNetErrScanFail uint16 = 0x3c46 // UIIT_MSG_WARENETWORK_SCAN_FAIL
	StallNetErrUseCity  uint16 = 0x3c49 // UIIT_MSG_WARENETWORK_USE_CITY (box; closes the window)
	StallNetErrNotTown  uint16 = 0x3c4a // UIIT_MSG_WARENETWORK_USE_CITY: 0xB0BA type 5's network answer
	StallNetErrJobDB    uint16 = 0x3c48 // the network sale's DB job (close reason, s:0x43ffd2)
	StallNetErrGone     uint16 = 0x3c4f // UIIT_MSG_WARENETWORK_BUY_ERROR: the stall gone / not open / off the network
	StallNetErrChanged  uint16 = 0x3c50 // UIIT_MSG_WARENETWORK_BUY_ERROR: the slot's item or count changed
	StallNetErrPrice    uint16 = 0x3c51 // UIIT_MSG_WARENETWORK_BUY_ERROR: the price changed
	StallNetErrGold     uint16 = 0x3c52 // UIIT_MSG_FLEAMARKET_ERR_NOT_ENOUGH_GOLD
	StallNetErrBagFull  uint16 = 0x3c53 // UIIT_MSG_FLEAMARKET_ERR_INVENTORY_FULL
)

// 0x70BA's u16 net (c:0x6b99a0, 0x6b4bb6, 0x6b5ed1, 0x6b9940, 0x6b9a20) and
// the values 0xB0BA's answer accepts (c:0x878230).
const (
	StallNetRegister uint16 = 1 // type 5 {open 1}: the type-1001 Yes
	StallNetAdd      uint16 = 2
	StallNetModify   uint16 = 3 // type 5 {open 0} while registered
	StallNetPrice    uint16 = 4
	StallNetRemove   uint16 = 5
)

// The search's modes (c:0x6c9f29, 0x6c9f1a, 0x6c71ca).
const (
	StallNetModeEnter byte = 1
	StallNetModeNew   byte = 2
	StallNetModePage  byte = 3
)

const (
	// StallNetPageSize is the window's fifteen rows (CNIFStallNetworkSlot
	// 120..234).
	StallNetPageSize = 15
	// StallNetMaxPages is 0xB461's u8 page count.
	StallNetMaxPages = 255
	// stallNetSearchGap is the Search button's timer (c:0x6c9e14: 10000 ms).
	stallNetSearchGap = 10 * time.Second
	// The event (READ s:0x473988..0x4739e4): a buyer's gold change of
	// -100,000 or less, each side `rand() % 1000 == 1`.
	StallNetEventItem  = "ITEM_ETC_WARENETWORK_EVENT"
	StallNetEventPrice = 100000
	stallNetEventOdds  = 1000
	// The commission's bounds (c:0x87a4c9..0x87a4ec).
	stallNetFeeMax int64 = 100000
)

// Test seams.
var (
	stallNetNow  = time.Now
	stallNetRand = rand.Intn
	// stallNetTown answers whether e stands in a town (stallNetInTown's
	// test); nil uses the region table.
	stallNetTown func(e world.Entity) bool
)

// stallNetFeeRate is the client's float 0.01 at 0xe1b820, read as a double
// (fmul QWORD, c:0x87a4c3): 0.009999999776482582.
var stallNetFeeRate = float64(float32(0.01))

// StallNetCommission is the owner's commission on a network sale of price:
// ftol(price x 0.01f), at least 1 and at most 100,000; 0 for price 0 (the
// client prints no line then). READ c:0x87a4bf..0x87a4ec; that the server
// takes the same is INFERRED (UIIT_MSG_WARENETWORK_REGIST_03).
func StallNetCommission(price int64) int64 {
	if price <= 0 {
		return 0
	}
	fee := int64(float64(price) * stallNetFeeRate) // ftol truncates toward zero
	if fee <= 0 {
		return 1
	}
	if fee >= stallNetFeeMax {
		return stallNetFeeMax
	}
	return fee
}

// stallNetInTown is the network's town test (c:0x6b9a7d's client side, the
// server's own here): a region whose IsBattleField is 0; any place when no
// region table is loaded (OURS).
func stallNetInTown(e world.Entity) bool {
	if f := stallNetTown; f != nil {
		return f(e)
	}
	if safeRegions.Load() == nil {
		return true
	}
	_, ok := safeRegionAt(e.Zone, e.Pos.X, e.Pos.Z)
	return ok
}

// stallNetU16 reads the u16 at b[at:], 0 when absent.
func stallNetU16(b []byte, at int) uint16 {
	if len(b) < at+2 {
		return 0
	}
	return binary.LittleEndian.Uint16(b[at:])
}

// stallNetAnswer is 0xB0BA's network u16 for an accepted update, under the
// hub's lock (stall_network.md §5): type 5 registers / keeps / drops the
// stall, types 1/2/3 echo their value while it is registered.
func stallNetAnswer(s *stall.Stall, kind, open byte, net uint16, town bool) uint16 {
	switch kind {
	case StallUpdateOpen:
		if open == 1 {
			if net != StallNetRegister {
				s.Network = false
				return 0
			}
			if !town {
				s.Network = false
				return StallNetErrNotTown
			}
			s.Network = true
			return StallNetRegister
		}
		if net != StallNetModify {
			s.Network = false
			return 0
		}
		if s.Network {
			return StallNetModify
		}
		return 0
	case StallUpdatePrice, StallUpdateAdd, StallUpdateRemove:
		want := map[byte]uint16{StallUpdatePrice: StallNetPrice, StallUpdateAdd: StallNetAdd, StallUpdateRemove: StallNetRemove}[kind]
		if s.Network && net == want {
			return net
		}
	}
	return 0
}

// --- the wire -----------------------------------------------------------------

// StallNetSearch is 0x7461.
type StallNetSearch struct {
	Mode   byte
	Page   byte
	Group  uint32
	Degree byte
}

// Encode is the client's layout (c:0x821ae0).
func (r StallNetSearch) Encode() []byte {
	out := []byte{r.Mode, r.Page}
	out = binary.LittleEndian.AppendUint32(out, r.Group)
	return append(out, r.Degree)
}

// DecodeStallNetSearch reads 0x7461.
func DecodeStallNetSearch(b []byte) (StallNetSearch, bool) {
	if len(b) < 7 {
		return StallNetSearch{}, false
	}
	return StallNetSearch{Mode: b[0], Page: b[1], Group: binary.LittleEndian.Uint32(b[2:]), Degree: b[6]}, true
}

// StallNetBuy is 0x7463: a record's fields echoed (c:0x6c80ef..0x6c8126).
type StallNetBuy struct {
	Owner  uint32
	Slot   byte
	Price  uint64
	Count  uint16
	Level  byte
	Serial uint64
}

// Encode is the client's layout (c:0x821c70).
func (r StallNetBuy) Encode() []byte {
	out := binary.LittleEndian.AppendUint32(nil, r.Owner)
	out = append(out, r.Slot)
	out = binary.LittleEndian.AppendUint64(out, r.Price)
	out = binary.LittleEndian.AppendUint16(out, r.Count)
	out = append(out, r.Level)
	return binary.LittleEndian.AppendUint64(out, r.Serial)
}

// DecodeStallNetBuy reads 0x7463.
func DecodeStallNetBuy(b []byte) (StallNetBuy, bool) {
	if len(b) < 24 {
		return StallNetBuy{}, false
	}
	return StallNetBuy{Owner: binary.LittleEndian.Uint32(b), Slot: b[4], Price: binary.LittleEndian.Uint64(b[5:]),
		Count: binary.LittleEndian.Uint16(b[13:]), Level: b[15], Serial: binary.LittleEndian.Uint64(b[16:])}, true
}

// StallNetRecord is one 0xB461 record (c:0x6c98e0).
type StallNetRecord struct {
	Item   ItemInfo
	Owner  uint32
	Seller string
	Slot   byte
	Count  uint16
	Level  byte
	Price  uint64
	Serial uint64
}

// Buy is the 0x7463 a click on this record sends.
func (r StallNetRecord) Buy() StallNetBuy {
	return StallNetBuy{Owner: r.Owner, Slot: r.Slot, Price: r.Price, Count: r.Count, Level: r.Level, Serial: r.Serial}
}

// appendStallNetTail is a record after its item.
func appendStallNetTail(out []byte, r StallNetRecord) []byte {
	out = binary.LittleEndian.AppendUint32(out, r.Owner)
	out = stallAppendString(out, r.Seller)
	out = append(out, r.Slot)
	out = binary.LittleEndian.AppendUint16(out, r.Count)
	out = append(out, r.Level)
	out = binary.LittleEndian.AppendUint64(out, r.Price)
	return binary.LittleEndian.AppendUint64(out, r.Serial)
}

// EncodeStallNetResult is 0xB461's success: the records already encoded
// (item record + tail each), their count and the page count.
func EncodeStallNetResult(pages int, records [][]byte) []byte {
	out := []byte{stallReplyOK, byte(len(records)), byte(pages)}
	for _, r := range records {
		out = append(out, r...)
	}
	return out
}

// StallNetResult is a decoded 0xB461.
type StallNetResult struct {
	OK      bool
	Code    uint16
	Pages   int
	Records []StallNetRecord
}

// DecodeStallNetResult reads 0xB461. An item record's layout depends on its
// row (ReadItemRecord, with the item table's hook when it is installed);
// without the table a record is tried both as equipment and as an
// expendable's u16 count, and the reading that leaves the rest of the
// answer well formed is taken (a tool's reading, for the partybot).
func DecodeStallNetResult(b []byte) (StallNetResult, error) {
	var out StallNetResult
	if len(b) < 1 {
		return out, errors.New("0xB461: empty")
	}
	if b[0] != stallReplyOK {
		if len(b) < 3 {
			return out, errors.New("0xB461: truncated refusal")
		}
		out.Code = binary.LittleEndian.Uint16(b[1:])
		return out, nil
	}
	if len(b) < 3 {
		return out, errors.New("0xB461: truncated")
	}
	out.OK, out.Pages = true, int(b[2])
	recs, ok := decodeStallNetRecords(b[3:], int(b[1]))
	if !ok {
		return out, errors.New("0xB461: records do not parse")
	}
	out.Records = recs
	return out, nil
}

func decodeStallNetRecords(b []byte, n int) ([]StallNetRecord, bool) {
	if n == 0 {
		return nil, len(b) == 0
	}
	for _, read := range []func([]byte) (ItemInfo, []byte, error){ReadItemRecord, readExpendableRecord} {
		ii, rest, err := read(b)
		if err != nil {
			continue
		}
		r, rest, ok := readStallNetTail(rest)
		if !ok {
			continue
		}
		r.Item = ii
		more, ok := decodeStallNetRecords(rest, n-1)
		if ok {
			return append([]StallNetRecord{r}, more...), true
		}
	}
	return nil, false
}

// readExpendableRecord is an item record whose tail is a u16 count (no rent).
func readExpendableRecord(b []byte) (ItemInfo, []byte, error) {
	if len(b) < 10 || binary.LittleEndian.Uint32(b) != 0 {
		return ItemInfo{}, nil, errors.New("not an expendable record")
	}
	return ItemInfo{RefItemID: binary.LittleEndian.Uint32(b[4:]), Tail: append([]byte(nil), b[8:10]...)}, b[10:], nil
}

func readStallNetTail(b []byte) (StallNetRecord, []byte, bool) {
	var r StallNetRecord
	if len(b) < 6 {
		return r, nil, false
	}
	r.Owner = binary.LittleEndian.Uint32(b)
	name, rest, ok := stallReadString(b[4:])
	if !ok || len(name) > stall.MaxText || len(rest) < 20 {
		return r, nil, false
	}
	r.Seller = name
	r.Slot = rest[0]
	r.Count = binary.LittleEndian.Uint16(rest[1:])
	r.Level = rest[3]
	r.Price = binary.LittleEndian.Uint64(rest[4:])
	r.Serial = binary.LittleEndian.Uint64(rest[12:])
	return r, rest[20:], r.Slot < stall.MaxSlots
}

// EncodeStallNetSold is 0x30B7 kind 4 (s:0x473a40..0x473ab6): kind 3's
// layout with kind 4.
func EncodeStallNetSold(ctx context.Context, items ItemLookup, slot int, buyer string, slots [stall.MaxSlots]stall.Listing) []byte {
	out := stallAppendString([]byte{StallEventNetSold, byte(slot)}, buyer)
	return appendStallList(ctx, items, out, slots)
}

// --- the viewers ----------------------------------------------------------------

// stallNetKey is one match of a search: the listing as it was found.
type stallNetKey struct {
	owner int64
	slot  int
	seq   uint64
}

// stallNetViewer is one session's network state: entered by mode 1, left by
// 0x7462 or the disconnect.
type stallNetViewer struct {
	entered    bool
	lastSearch time.Time
	group      uint32
	degree     byte
	keys       []stallNetKey
	pages      int
}

var stallNetViewers = struct {
	mu sync.Mutex
	m  map[uint64]*stallNetViewer
}{m: map[uint64]*stallNetViewer{}}

// StallNetDisconnectHandler forgets a leaving session's network state.
func StallNetDisconnectHandler() func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		stallNetViewers.mu.Lock()
		delete(stallNetViewers.m, sess.ID())
		stallNetViewers.mu.Unlock()
	}
}

// --- the handler ----------------------------------------------------------------

// StallNetHandler serves 0x7461..0x7463. It runs on the stalls StallHandler
// installed (stallRT) and answers nothing before.
func StallNetHandler() gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpStallNetSearch, OpStallNetLeave, OpStallNetBuy:
		default:
			return nil
		}
		d := stallRT.Load()
		if d == nil {
			return nil
		}
		switch p.Opcode {
		case OpStallNetSearch:
			d.netSearch(ctx, sess, p.Data)
		case OpStallNetLeave:
			stallNetViewers.mu.Lock()
			delete(stallNetViewers.m, sess.ID())
			stallNetViewers.mu.Unlock()
			sendStall(sess, OpStallNetLeaveResult, []byte{stallReplyOK})
		case OpStallNetBuy:
			d.netBuy(ctx, sess, p.Data)
		}
		return nil
	}
}

// netSearch is 0x7461.
func (d *StallDeps) netSearch(ctx context.Context, sess *gateway.Session, data []byte) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	fail := func(code uint16) { sendStall(sess, OpStallNetSearchResult, stallResult(code)) }
	req, ok := DecodeStallNetSearch(data)
	if !ok || req.Mode < StallNetModeEnter || req.Mode > StallNetModePage {
		fail(StallErrOperation)
		return
	}
	if !stallNetInTown(me) {
		fail(StallNetErrUseCity)
		return
	}
	now := stallNetNow()
	stallNetViewers.mu.Lock()
	v := stallNetViewers.m[sess.ID()]
	if v == nil {
		v = &stallNetViewer{}
		stallNetViewers.m[sess.ID()] = v
	}
	if req.Mode != StallNetModePage {
		if !v.lastSearch.IsZero() && now.Sub(v.lastSearch) < stallNetSearchGap {
			stallNetViewers.mu.Unlock()
			fail(StallNetErrScanFail)
			return
		}
		v.lastSearch = now
		if req.Mode == StallNetModeEnter {
			v.entered = true
		}
	}
	stallNetViewers.mu.Unlock()
	if req.Mode != StallNetModePage {
		keys := d.netMatches(ctx, me.CharacterID, req.Group, req.Degree)
		pages := (len(keys) + StallNetPageSize - 1) / StallNetPageSize
		stallNetViewers.mu.Lock()
		v.group, v.degree, v.keys, v.pages = req.Group, req.Degree, keys, pages
		stallNetViewers.mu.Unlock()
	}
	stallNetViewers.mu.Lock()
	keys, pages := v.keys, v.pages
	stallNetViewers.mu.Unlock()
	start := int(req.Page) * StallNetPageSize
	if start >= len(keys) {
		sendStall(sess, OpStallNetSearchResult, EncodeStallNetResult(pages, nil))
		return
	}
	end := start + StallNetPageSize
	if end > len(keys) {
		end = len(keys)
	}
	var recs [][]byte
	for _, k := range keys[start:end] {
		if r, ok := d.netRecord(ctx, k); ok {
			recs = append(recs, r)
		}
	}
	sendStall(sess, OpStallNetSearchResult, EncodeStallNetResult(pages, recs))
}

// netMatches is the search: every open, registered stall but the searcher's
// own, its listings of group (and degree, unless 0), newest first, at most
// StallNetMaxPages pages.
func (d *StallDeps) netMatches(ctx context.Context, searcher int64, group uint32, degree byte) []stallNetKey {
	var keys []stallNetKey
	for _, s := range d.Stalls.Network() {
		if s.Owner.CharacterID == searcher {
			continue
		}
		for i, l := range s.Slots {
			if !l.Used || l.Group != group {
				continue
			}
			if degree != 0 {
				ref, _ := d.itemRef(ctx, l.ItemID)
				if ref == nil || itemDegree(ref) != int(degree) {
					continue
				}
			}
			keys = append(keys, stallNetKey{owner: s.Owner.CharacterID, slot: i, seq: l.Seq})
		}
	}
	sort.Slice(keys, func(a, b int) bool { return keys[a].seq > keys[b].seq })
	if max := StallNetMaxPages * StallNetPageSize; len(keys) > max {
		keys = keys[:max]
	}
	return keys
}

// netRecord is k's record as the stall holds it now, or false when the
// listing is gone, the stall closed or left the network.
func (d *StallDeps) netRecord(ctx context.Context, k stallNetKey) ([]byte, bool) {
	s, ok := d.Stalls.Get(k.owner)
	if !ok || !s.Open || !s.Network || k.slot >= stall.MaxSlots {
		return nil, false
	}
	l := s.Slots[k.slot]
	if !l.Used || l.Seq != k.seq {
		return nil, false
	}
	level := 0
	if ref, _ := d.itemRef(ctx, l.ItemID); ref != nil {
		level = ref.ReqLevel1
	}
	if level < 0 {
		level = 0
	} else if level > 255 {
		level = 255
	}
	out := exchangeRecord(ctx, d.Items, trade.Item{Slot: l.BagSlot, ItemID: l.ItemID, Quantity: l.Quantity, Inst: l.Inst})
	return appendStallNetTail(out, StallNetRecord{Owner: uint32(k.owner), Seller: s.Owner.Name, Slot: byte(k.slot),
		Count: uint16(l.Quantity), Level: byte(level), Price: uint64(l.Price), Serial: l.Seq}), true
}

// netBuy is 0x7463 (stall_network.md §5's order).
func (d *StallDeps) netBuy(ctx context.Context, sess *gateway.Session, data []byte) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	fail := func(code uint16) { sendStall(sess, OpStallNetBuyResult, stallResult(code)) }
	req, ok := DecodeStallNetBuy(data)
	if !ok {
		fail(StallErrOperation)
		return
	}
	switch {
	case !stallNetInTown(me):
		fail(StallNetErrUseCity)
		return
	case d.worldBusy(me):
		fail(StallErrBusy)
		return
	case int64(req.Owner) == me.CharacterID:
		fail(StallErrOperation)
		return
	}
	owner, slot := int64(req.Owner), int(req.Slot)
	code := uint16(1)
	var l stall.Listing
	found := d.Stalls.Do(owner, func(s *stall.Stall) {
		switch {
		case !s.Open || !s.Network:
			code = StallNetErrGone
		case s.Selling:
			code = StallErrGeneric
		case slot >= stall.MaxSlots || !s.Slots[slot].Used || s.Slots[slot].Seq != req.Serial ||
			s.Slots[slot].Quantity != int(req.Count):
			code = StallNetErrChanged
		case s.Slots[slot].Price != int64(req.Price):
			code = StallNetErrPrice
		default:
			l = s.Slots[slot]
			s.Selling = true
		}
	})
	if !found {
		fail(StallNetErrGone)
		return
	}
	if code != 1 {
		fail(code)
		return
	}
	fee := StallNetCommission(l.Price)
	code, toSlot := d.sellFor(ctx, owner, me.CharacterID, slot, l, fee, true)
	var members []stall.Member
	var after [stall.MaxSlots]stall.Listing
	d.Stalls.Do(owner, func(s *stall.Stall) {
		s.Selling = false
		if code == 1 || code == StallErrSlot {
			// Sold, or the listing no longer matches the bag (round 839's rule).
			if s.Slots[slot].Seq == l.Seq {
				s.Slots[slot] = stall.Listing{}
			}
		}
		members = s.Members()
		after = s.Slots
	})
	switch code {
	case 1:
	case StallErrDB:
		fail(StallNetErrJobDB)
		d.closeStall(owner, StallNetErrJobDB)
		return
	case StallErrSlot:
		fail(StallNetErrChanged)
		return
	case StallErrGold:
		fail(StallNetErrGold)
		return
	case StallErrBagFull:
		fail(StallNetErrBagFull)
		return
	default:
		fail(code)
		return
	}
	tellGold(ctx, d.Chars, d.Hub, me.CharacterID, false)
	tellGold(ctx, d.Chars, d.Hub, owner, false)
	sendStall(sess, OpStallNetBuyResult, []byte{stallReplyOK})
	if members == nil {
		// The stall closed meanwhile: its owner still hears of the sale.
		if e, ok := d.Hub.EntityByCharacterID(owner); ok {
			members = []stall.Member{{CharacterID: owner, Session: e.Session}}
		}
	}
	toMembers(members, OpStallEvent, EncodeStallNetSold(ctx, d.Items, slot, d.buyerName(ctx, me), after))
	slog.Info("stall network: sold", "owner", owner, "buyer", me.CharacterID, "slot", slot, "item", l.ItemID,
		"count", l.Quantity, "price", l.Price, "commission", fee, "to", toSlot)
	if l.Price >= StallNetEventPrice {
		for _, id := range []int64{me.CharacterID, owner} {
			if stallNetRand(stallNetEventOdds) == 1 {
				d.netEventItem(ctx, id)
			}
		}
	}
}

// netEventItem gives characterID one ITEM_ETC_WARENETWORK_EVENT (s:0x4739a1,
// 0x4739d4) into its first free bag slot and sends it its bag.
func (d *StallDeps) netEventItem(ctx context.Context, characterID int64) {
	ref, err := gachaItemByCode(ctx, d.Items, StallNetEventItem)
	if err != nil || ref == nil {
		slog.Info("stall network: the event item is not in the item table", "character_id", characterID, "err", err)
		return
	}
	if len(stallEmptySlots(ctx, d.Inv, characterID)) == 0 {
		slog.Info("stall network: the event item not given, the bag is full", "character_id", characterID)
		return
	}
	if err := d.Inv.AddItem(ctx, characterID, ref.ID, 1); err != nil {
		slog.Info("stall network: the event item not given", "character_id", characterID, "err", err)
		return
	}
	slog.Info("stall network: the event item given", "character_id", characterID)
	if e, ok := d.Hub.EntityByCharacterID(characterID); ok && e.Session != nil {
		if slots, err := d.Inv.List(ctx, characterID); err == nil {
			sendStall(e.Session, OpInventoryListResult, bagListResult(ctx, d.Inv, characterID, slots, d.Items).Encode())
		}
	}
}
