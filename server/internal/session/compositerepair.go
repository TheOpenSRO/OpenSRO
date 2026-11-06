package session

import (
	"context"
	"log/slog"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
)

// Round 864 follow-up (OURS, a repair): before v0.1.634 a premium's UIL1
// fill grants (the free instant return, reverse return and resurrection
// scrolls) lived the UIL1 entry's 86,400 s and were then DELETED from
// _TIMEDJOB, though the premium itself runs 28 days. A character who used a
// premium before then still has the premium's other type-5 rows (its BFI1
// stall decoration and UQL1 quest grant, Key = the composite's item id, End
// = the composite's end: both are created from the same use with the
// composite's Param1, compositeextra.go) but no UIL1 row, so no premium icon
// can show. In retail the UIL1 job lasts the composite's Param1 too (READ,
// s:0x49f61b..0x49fa9e), so its fills would still be running.
//
// At the character's first world entry this process sees, for each
// composite that still has a running BFI1 or UQL1 row, every UIL1 entry of
// the composite's own CompositeDesc whose fill has no running grant is
// re-created: it ends when those rows end (the latest of them), its period
// is the entry's seconds with the boundaries anchored at the use (the rows'
// Start), and it starts full (the maximum), as the period's refill
// (FUN_00653a40) would leave it. Kept in the store like any grant, so it is
// done once. Not repaired: a composite with no BFI1 / UQL1 entry (no row is
// left to say it ran), and a TypeID3 1 fill (the Energy of life's fill
// really ends at its last use, vslot_007).

// SetItems names the item table the repair reads composites from (round
// 864 follow-up).
func (k *CompositeKeeper) SetItems(items ItemLookup) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.items = items
}

// runningComposite is what a character's surviving rows say about one
// composite: when its job started and ends.
type runningComposite struct {
	start, end time.Time
}

// runningComposites groups a character's live BFI1 / UQL1 rows by their
// composite (Key).
func runningComposites(jobs []timedjob.Job, now time.Time) map[int64]runningComposite {
	out := map[int64]runningComposite{}
	for _, j := range jobs {
		if j.Type != timedjob.TypeComposite || (j.Sub != "BFI1" && j.Sub != "UQL1") || j.Key <= 0 || !now.Before(j.End) {
			continue
		}
		rc, seen := out[j.Key]
		if !seen || j.End.After(rc.end) {
			rc.end = j.End
		}
		if !seen || (!j.Start.IsZero() && j.Start.Before(rc.start)) || rc.start.IsZero() {
			rc.start = j.Start
		}
		out[j.Key] = rc
	}
	return out
}

// restoredPeriodEnd is the first period boundary after now, the boundaries
// start + n x period (n >= 1).
func restoredPeriodEnd(start, now time.Time, period time.Duration) time.Time {
	if period <= 0 {
		return time.Time{}
	}
	if start.IsZero() || start.After(now) {
		return now.Add(period)
	}
	n := now.Sub(start)/period + 1
	return start.Add(n * period)
}

// restoreDroppedFills is the repair (header). It returns how many grants it
// re-created.
func (k *CompositeKeeper) restoreDroppedFills(ctx context.Context, characterID int64, jobs []timedjob.Job, now time.Time) int {
	k.mu.Lock()
	items := k.items
	k.mu.Unlock()
	byCode, ok := items.(itemByCode)
	if items == nil || !ok {
		return 0
	}
	restored := 0
	for compositeID, rc := range runningComposites(jobs, now) {
		scroll, err := items.GetItem(ctx, compositeID)
		if err != nil || scroll == nil || !isCompositeScroll(scroll) {
			continue
		}
		entries, err := parseCompositeDesc(scroll.CompositeDesc)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.fourCC != "UIL1" || e.count <= 0 {
				continue
			}
			fill, err := byCode.GetItemByCode(ctx, e.code)
			if err != nil || fill == nil {
				continue
			}
			if fill.TypeID1 == equipment.TypeItem && fill.TypeID2 == equipment.TypeExpendable && fill.TypeID3 == recoveryFamily {
				continue
			}
			if _, running := k.get(characterID, fill.ID, now); running {
				continue
			}
			period := time.Duration(e.seconds) * time.Second
			g := compositeGrant{fillID: fill.ID, scrollID: compositeID, remaining: e.count, max: e.count,
				until: rc.end, period: period, periodEnd: restoredPeriodEnd(rc.start, now, period)}
			k.put(characterID, g, rc.end.Sub(now))
			restored++
			slog.Info("composite: fill grant restored (OURS, dropped before v0.1.634)", "character_id", characterID,
				"composite", compositeID, "item", fill.ID, "uses", e.count, "ends", rc.end, "next_refill", g.periodEnd)
		}
	}
	return restored
}
