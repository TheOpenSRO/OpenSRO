package mall

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// The mall's own records (OURS: retail keeps the silk history in the account
// database behind its billing side, SK_SILKBUYLIST, and has no item chest at
// all: item_mall_wire.md §4).
//
//   - The purchase log: one row per purchase, the silk it took by currency,
//     what was bought, when. 0x711a's Buying list reads it.
//   - The item chest: per CHARACTER (OURS, the decision: a purchase that did
//     not fit the buyer's bag waits for that buyer, who takes it into the bag
//     the purchase was meant for). One entry per item the purchase made.
//   - The take log: what was taken out of the chest, kept TakeLogDays days.

// TakeLogDays is how long the take log keeps a row (OURS; the screenshot
// server's chest says "*Only logs from the last 7 days will appear.", its
// VPLUS_UI_ITEM_STORAGE_BOX_* text, item_mall.md "The Chest window").
const TakeLogDays = 7

// FromItemMall is the chest's "from" text for a mall purchase (OURS).
const FromItemMall = "Item Mall"

// ErrNoSuchEntry is a chest entry that is not (or no longer) there.
var ErrNoSuchEntry = errors.New("mall: no such chest entry")

// Purchase is one purchase for the log.
type Purchase struct {
	AccountID   int64
	CharacterID int64
	PackageID   int64
	PackageCode string
	Quantity    int
	Pay         Payment
	ToChest     bool
	At          time.Time
}

// ChestEntry is one item waiting in a chest: the item to make and where it
// came from.
type ChestEntry struct {
	ID        int64
	Owner     int64 // the character
	ItemID    int64
	Quantity  int // the stack
	OptLevel  uint8
	Variance  uint64
	Data      int
	MagParams []uint64
	From      string
	At        time.Time
}

// TakeLogEntry is one item taken out of a chest.
type TakeLogEntry struct {
	ItemID   int64
	Quantity int
	From     string
	At       time.Time // when it entered the chest
	TakenAt  time.Time
}

// Store keeps the purchase log, the chests and the take log. Every write
// joins the context's transaction (txn), so a purchase's log row and chest
// entries stand or fall with its silk and its items.
type Store interface {
	RecordPurchase(ctx context.Context, p Purchase) error
	// Purchases are accountID's purchases since since, oldest first, as the
	// silk they took.
	Purchases(ctx context.Context, accountID int64, since time.Time) ([]HistoryRow, error)
	AddToChest(ctx context.Context, e ChestEntry) (int64, error)
	// Chest is owner's chest, oldest first.
	Chest(ctx context.Context, owner int64) ([]ChestEntry, error)
	// TakeFromChest removes one entry and logs it as taken at at.
	TakeFromChest(ctx context.Context, owner, id int64, at time.Time) (ChestEntry, error)
	// TakeLog is owner's take log since since, newest first.
	TakeLog(ctx context.Context, owner int64, since time.Time) ([]TakeLogEntry, error)
	// PruneTakeLog deletes take-log rows taken before before.
	PruneTakeLog(ctx context.Context, before time.Time) (int64, error)
}

// MemStore is the in-memory Store (the -no-postgres server and the tests).
type MemStore struct {
	mu        sync.Mutex
	purchases []memPurchase
	chest     []ChestEntry
	log       map[int64][]memLog
	nextID    int64
	seq       int64
}

// memPurchase and memLog carry a sequence number, so an undo removes its own
// row whatever was added after it.
type memPurchase struct {
	Purchase
	seq int64
}

type memLog struct {
	TakeLogEntry
	seq int64
}

// NewMemStore is an empty MemStore.
func NewMemStore() *MemStore { return &MemStore{log: map[int64][]memLog{}} }

// RecordPurchase implements Store.
func (m *MemStore) RecordPurchase(ctx context.Context, p Purchase) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.seq++
	seq := m.seq
	m.purchases = append(m.purchases, memPurchase{Purchase: p, seq: seq})
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		for i, q := range m.purchases {
			if q.seq == seq {
				m.purchases = append(m.purchases[:i], m.purchases[i+1:]...)
				return
			}
		}
	})
	return nil
}

// Purchases implements Store.
func (m *MemStore) Purchases(_ context.Context, accountID int64, since time.Time) ([]HistoryRow, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []HistoryRow
	for _, p := range m.purchases {
		if p.AccountID == accountID && !p.At.Before(since) {
			out = append(out, HistoryRow{Offset: p.Pay.Silk(), At: p.At})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	return out, nil
}

// AddToChest implements Store.
func (m *MemStore) AddToChest(ctx context.Context, e ChestEntry) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.nextID++
	e.ID = m.nextID
	e.MagParams = append([]uint64(nil), e.MagParams...)
	m.chest = append(m.chest, e)
	txn.OnRollback(ctx, func() { m.remove(e.ID) })
	return e.ID, nil
}

func (m *MemStore) remove(id int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, c := range m.chest {
		if c.ID == id {
			m.chest = append(m.chest[:i], m.chest[i+1:]...)
			return
		}
	}
}

// Chest implements Store.
func (m *MemStore) Chest(_ context.Context, owner int64) ([]ChestEntry, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []ChestEntry
	for _, c := range m.chest {
		if c.Owner == owner {
			out = append(out, c)
		}
	}
	return out, nil
}

// TakeFromChest implements Store.
func (m *MemStore) TakeFromChest(ctx context.Context, owner, id int64, at time.Time) (ChestEntry, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, c := range m.chest {
		if c.ID != id || c.Owner != owner {
			continue
		}
		m.chest = append(m.chest[:i], m.chest[i+1:]...)
		m.seq++
		seq := m.seq
		m.log[owner] = append(m.log[owner], memLog{TakeLogEntry{ItemID: c.ItemID, Quantity: c.Quantity, From: c.From, At: c.At, TakenAt: at}, seq})
		txn.OnRollback(ctx, func() {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.chest = append(m.chest, c)
			sort.SliceStable(m.chest, func(a, b int) bool { return m.chest[a].ID < m.chest[b].ID })
			l := m.log[owner]
			for k, e := range l {
				if e.seq == seq {
					m.log[owner] = append(l[:k], l[k+1:]...)
					return
				}
			}
		})
		return c, nil
	}
	return ChestEntry{}, ErrNoSuchEntry
}

// TakeLog implements Store.
func (m *MemStore) TakeLog(_ context.Context, owner int64, since time.Time) ([]TakeLogEntry, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []TakeLogEntry
	for _, l := range m.log[owner] {
		if !l.TakenAt.Before(since) {
			out = append(out, l.TakeLogEntry)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].TakenAt.After(out[j].TakenAt) })
	return out, nil
}

// PruneTakeLog implements Store.
func (m *MemStore) PruneTakeLog(_ context.Context, before time.Time) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var n int64
	for owner, l := range m.log {
		kept := l[:0]
		for _, e := range l {
			if e.TakenAt.Before(before) {
				n++
				continue
			}
			kept = append(kept, e)
		}
		m.log[owner] = kept
	}
	return n, nil
}
