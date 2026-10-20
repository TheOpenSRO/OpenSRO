// Package specialty is the trade of specialty goods (round 801): the
// specialty NPCs' quotation board, the trade scale, the transport's bag size
// and the specialty stores' goods. The session runs the messages; this
// package holds the rules, each READ from SR_GameServer.exe unless a comment
// says otherwise (docs/protocol/jobs.md, "Specialty trade").
package specialty

import (
	"encoding/csv"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// QuoteRow is one _ItemQuotation row (READ: DB_Bind__ITEMQUOTATION
// s:0x8434e0; the columns are the table's own, MEASURED on the shard DB):
// ID, Service, AssocNPC (the NPC's ref id), RefItemID, BaseQuot, Quot_LB,
// Quot_UB, BaseStockAmount, FluctuateAmount, CurStockAmount.
type QuoteRow struct {
	ID               int64
	Service          bool
	NPC, Item        int64
	BaseQuot, LB, UB float32
	BaseStock, Fluct int
	CurStock         int
}

// QuoteColumns is the CSV's column order (the table's).
var QuoteColumns = []string{"ID", "Service", "AssocNPC", "RefItemID", "BaseQuot", "Quot_LB", "Quot_UB",
	"BaseStockAmount", "FluctuateAmount", "CurStockAmount"}

// ReadQuotes parses an _ItemQuotation CSV, with or without the header row.
func ReadQuotes(r io.Reader) ([]QuoteRow, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	recs, err := cr.ReadAll()
	if err != nil {
		return nil, err
	}
	var out []QuoteRow
	for i, rec := range recs {
		if len(rec) == 0 || (len(rec) == 1 && strings.TrimSpace(rec[0]) == "") {
			continue
		}
		if i == 0 && strings.EqualFold(strings.TrimSpace(rec[0]), "ID") {
			continue
		}
		if len(rec) < len(QuoteColumns) {
			return nil, fmt.Errorf("quotation row %d: %d columns, want %d", i+1, len(rec), len(QuoteColumns))
		}
		var q QuoteRow
		var firstErr error
		in := func(k int) int64 {
			v, err := strconv.ParseInt(strings.TrimSpace(rec[k]), 10, 64)
			if err != nil && firstErr == nil {
				firstErr = fmt.Errorf("quotation row %d column %s: %w", i+1, QuoteColumns[k], err)
			}
			return v
		}
		fl := func(k int) float32 {
			v, err := strconv.ParseFloat(strings.TrimSpace(rec[k]), 32)
			if err != nil && firstErr == nil {
				firstErr = fmt.Errorf("quotation row %d column %s: %w", i+1, QuoteColumns[k], err)
			}
			return float32(v)
		}
		q.ID = in(0)
		q.Service = in(1) != 0
		q.NPC, q.Item = in(2), in(3)
		q.BaseQuot, q.LB, q.UB = fl(4), fl(5), fl(6)
		q.BaseStock, q.Fluct, q.CurStock = int(in(7)), int(in(8)), int(in(9))
		if firstErr != nil {
			return nil, firstErr
		}
		out = append(out, q)
	}
	return out, nil
}

// LoadQuotes reads an _ItemQuotation CSV file.
func LoadQuotes(path string) ([]QuoteRow, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ReadQuotes(f)
}

// Quote is one entry of an NPC's quotation map as GObjNPCNPC::FUN_004c8220
// (s:0x4c8220) builds it: the row, the base price (the item's ref Price,
// +0x9c; 0 becomes 1), the stock bounds and the current unit price.
type Quote struct {
	Row                QuoteRow
	Base               int64
	Price              int64
	MinStock, MaxStock int
}

// stockBound is the x87 fistp of FUN_004c8220 (round to nearest, ties to
// even) over the float32 fields.
func stockBound(v float64) int { return int(math.RoundToEven(v)) }

// NewQuote builds an entry for a row whose item's ref Price is refPrice.
//
//	MaxStock = round(Fluct x (BaseQuot - LB) / 0.01 + BaseStock)
//	MinStock = round(BaseStock - (UB - BaseQuot) x Fluct / 0.01)
func NewQuote(r QuoteRow, refPrice int64) *Quote {
	q := &Quote{Row: r, Base: refPrice}
	if q.Base == 0 {
		q.Base = 1
	}
	fl := float64(float32(r.Fluct))
	q.MaxStock = stockBound(fl*float64(r.BaseQuot-r.LB)/0.01 + float64(r.BaseStock))
	q.MinStock = stockBound(float64(r.BaseStock) - float64(r.UB-r.BaseQuot)*fl/0.01)
	q.Recompute()
	return q
}

// Quotient is FUN_004c8810's quotation (s:0x4c8810..0x4c8915), in its float
// widths:
//
//	t = float32((Cur - BaseStock) / Fluct x 0.01)
//	q = clamp(float32(BaseQuot - t), LB, UB)
//	q = float32(trunc(q x 100) / 100)
func (q *Quote) Quotient() float32 {
	r := q.Row
	t := float32(float64(r.CurStock-r.BaseStock) / float64(r.Fluct) * 0.01)
	v := r.BaseQuot - t
	if !(r.LB <= v) {
		v = r.LB
	} else if !(r.UB > v) {
		v = r.UB
	}
	return float32(float64(int64(float64(v)*100.0)) / 100.0)
}

// Recompute sets Price from the stock and reports whether it changed:
// base + trunc(float32(base) x q - float32(base)) (s:0x4c891d..0x4c8945).
func (q *Quote) Recompute() bool {
	if q.Row.Fluct == 0 {
		// The row would divide by zero; the loader keeps only rows with a
		// base stock, and Fluct 0 never occurs in the data (MEASURED: 150,
		// 200, 250). OURS: such a row keeps its base price.
		old := q.Price
		q.Price = q.Base
		return old != q.Price
	}
	b := float64(float32(q.Base))
	p := q.Base + int64(b*float64(q.Quotient())-b)
	old := q.Price
	q.Price = p
	return old != p
}

// Sell is the specialty branch of FUN_004c8d10 (s:0x4c8d10): the stock grows
// by count (held at MaxStock), the gold is the unit price BEFORE the sale's
// recompute times count, the profit (price - base) x count; then the price
// is recomputed. changed reports a new price (the engine then sends the
// single entry, FUN_004c89d0).
func (q *Quote) Sell(count int) (gold, profit int64, changed bool) {
	q.Row.CurStock += count
	if q.Row.CurStock > q.MaxStock {
		q.Row.CurStock = q.MaxStock
	}
	gold = q.Price * int64(count)
	profit = (q.Price - q.Base) * int64(count)
	changed = q.Recompute()
	return gold, profit, changed
}

// Recover is one entry's step of the ten-minute tick (FUN_004c8b90, timer
// 0x927C0 ms at s:0x413189): the stock falls by Fluct (to 0 at most), held
// within [MinStock, MaxStock], and the price is recomputed.
func (q *Quote) Recover() bool {
	if q.Row.CurStock > q.Row.Fluct {
		q.Row.CurStock -= q.Row.Fluct
	} else {
		q.Row.CurStock = 0
	}
	if q.Row.CurStock < q.MinStock {
		q.Row.CurStock = q.MinStock
	}
	if q.Row.CurStock > q.MaxStock {
		q.Row.CurStock = q.MaxStock
	}
	return q.Recompute()
}

// RecoverEvery is the tick's interval (0x927C0 ms, READ s:0x413189).
const RecoverEveryMs = 600000

// UnitPrice is one 0x30E0 entry: the item and its unit price.
type UnitPrice struct {
	Item  int64
	Price int64
}

// Board is every NPC's quotation map. Safe for concurrent use.
type Board struct {
	mu   sync.Mutex
	npcs map[int64]map[int64]*Quote
	// rows are every row with Service != 0 by NPC, in ID order: what the
	// trade-info query reads (`WHERE AssocNPC=%d and Service <> 0`).
	rows  map[int64][]QuoteRow
	price func(item int64) int64
}

// NewBoard builds the board from the rows, as FUN_004c8220 does per NPC: a
// row with Service 0 or BaseStock 0 is dropped (s:0x4c8370). refPrice is the
// item's ref Price (+0x9c).
func NewBoard(rows []QuoteRow, refPrice func(item int64) int64) *Board {
	b := &Board{npcs: map[int64]map[int64]*Quote{}, rows: map[int64][]QuoteRow{}, price: refPrice}
	for _, r := range rows {
		if r.Service {
			b.rows[r.NPC] = append(b.rows[r.NPC], r)
		}
		if !r.Service || r.BaseStock == 0 {
			continue
		}
		m := b.npcs[r.NPC]
		if m == nil {
			m = map[int64]*Quote{}
			b.npcs[r.NPC] = m
		}
		var p int64
		if refPrice != nil {
			p = refPrice(r.Item)
		}
		m[r.Item] = NewQuote(r, p)
	}
	return b
}

// Has reports whether npc (a ref id) keeps a quotation map: the engine's
// npc+0x1cf0, which the 0x7046 open of id 0xc tests (s:0x5105ca).
func (b *Board) Has(npc int64) bool {
	if b == nil {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.npcs[npc]) > 0
}

// NPCs is every NPC with a map, ascending.
func (b *Board) NPCs() []int64 {
	if b == nil {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]int64, 0, len(b.npcs))
	for n := range b.npcs {
		out = append(out, n)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// Prices is npc's whole list, ascending by item id (the map's own order is a
// std::map keyed by the ref id, INFERRED from FUN_004c5d60's lookup).
func (b *Board) Prices(npc int64) []UnitPrice {
	if b == nil {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return pricesLocked(b.npcs[npc])
}

func pricesLocked(m map[int64]*Quote) []UnitPrice {
	out := make([]UnitPrice, 0, len(m))
	for item, q := range m {
		out = append(out, UnitPrice{Item: item, Price: q.Price})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Item < out[j].Item })
	return out
}

// Quote is a copy of npc's entry for item.
func (b *Board) Quote(npc, item int64) (Quote, bool) {
	if b == nil {
		return Quote{}, false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	q, ok := b.npcs[npc][item]
	if !ok {
		return Quote{}, false
	}
	return *q, true
}

// Sell sells count of item to npc (Quote.Sell); ok is false when npc keeps
// no entry for it.
func (b *Board) Sell(npc, item int64, count int) (gold, profit int64, changed, ok bool) {
	if b == nil {
		return 0, 0, false, false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	q, found := b.npcs[npc][item]
	if !found {
		return 0, 0, false, false
	}
	gold, profit, changed = q.Sell(count)
	return gold, profit, changed, true
}

// RecoverAll runs the ten-minute tick over every NPC and returns each NPC's
// full list afterwards (the engine sends the whole list, 0x30E0, to its PC
// list after the tick whether or not a price moved, READ FUN_004c8b90).
func (b *Board) RecoverAll() map[int64][]UnitPrice {
	if b == nil {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make(map[int64][]UnitPrice, len(b.npcs))
	for npc, m := range b.npcs {
		for _, q := range m {
			q.Recover()
		}
		out[npc] = pricesLocked(m)
	}
	return out
}

// ItemPercent is one 0xB4D4 row: a good and its sale price as a percent of
// its ref Price.
type ItemPercent struct {
	Item    int64
	Percent uint16
}

// Percents is the trade-info reply for npc (AsyncQuerySucceeded case 0x1b,
// s:0x4e8c50..0x4e8e74, READ): every Service row of the NPC, each
//
//	q  = clamp(BaseQuot - (Cur - BaseStock) / Fluct x 0.01, LB, UB)
//	q2 = trunc(q x 100) / 100
//	P  = trunc(Price x q2); percent = P x 100 / Price
//
// The engine reads the rows from the DB, whose CurStockAmount lags the
// NPC's live stock until it is written back (when is OPEN); OpenSRO has no
// write-back and reads the live stock where the NPC keeps the entry (OURS).
// Rows come in ID order (INFERRED: the unordered SELECT's clustered key).
func (b *Board) Percents(npc int64) []ItemPercent {
	if b == nil {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	rows := append([]QuoteRow(nil), b.rows[npc]...)
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].ID < rows[j].ID })
	out := make([]ItemPercent, 0, len(rows))
	for _, r := range rows {
		if q, ok := b.npcs[npc][r.Item]; ok {
			r.CurStock = q.Row.CurStock
		}
		var price int64
		if b.price != nil {
			price = b.price(r.Item)
		}
		qq := (&Quote{Row: r}).Quotient()
		if r.Fluct == 0 {
			qq = r.BaseQuot
		}
		p := int64(float64(price) * float64(qq))
		var pct uint16
		if price > 0 {
			pct = uint16(uint32(p*100) / uint32(price))
		}
		out = append(out, ItemPercent{Item: r.Item, Percent: pct})
	}
	return out
}
