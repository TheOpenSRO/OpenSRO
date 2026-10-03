package session

import (
	"context"
	"encoding/binary"

	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
)

// DurabilitySnapshot is one slot's durability, as sent in the trailing block
// of an inventory or equipment list. It rides AFTER the counted item records
// so a client built before durability existed stops at the count and never
// sees it, while a newer client reads the block and matches it to slots by
// index. Slots whose item has no durability are simply absent.
type DurabilitySnapshot struct {
	Slot          int
	Durability    int
	MaxDurability int
}

// encodeDurabilityBlock appends the trailing block: a u16 count then, per
// entry, u32 slot, s32 current, s32 max. Appending to a byte slice that
// already holds the counted records is what keeps it additive.
func encodeDurabilityBlock(out []byte, ds []DurabilitySnapshot) []byte {
	count := make([]byte, 2)
	binary.LittleEndian.PutUint16(count, uint16(len(ds)))
	out = append(out, count...)
	buf := make([]byte, 12)
	for _, d := range ds {
		binary.LittleEndian.PutUint32(buf[0:4], uint32(d.Slot))
		binary.LittleEndian.PutUint32(buf[4:8], uint32(int32(d.Durability)))
		binary.LittleEndian.PutUint32(buf[8:12], uint32(int32(d.MaxDurability)))
		out = append(out, buf...)
	}
	return out
}

// decodeDurabilityBlock reads what encodeDurabilityBlock wrote from the tail
// left after the counted records. An empty tail (an older server) yields no
// entries, not an error.
func decodeDurabilityBlock(rest []byte) []DurabilitySnapshot {
	if len(rest) < 2 {
		return nil
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	var out []DurabilitySnapshot
	for i := 0; i < count && len(rest) >= 12; i++ {
		out = append(out, DurabilitySnapshot{
			Slot:          int(binary.LittleEndian.Uint32(rest[0:4])),
			Durability:    int(int32(binary.LittleEndian.Uint32(rest[4:8]))),
			MaxDurability: int(int32(binary.LittleEndian.Uint32(rest[8:12]))),
		})
		rest = rest[12:]
	}
	return out
}

// inventoryDurabilities builds the block for a bag: one entry per tracked
// slot, its current durability and the max its variance and reference range
// give (durability.MaxDurability). An item without a range is skipped.
func inventoryDurabilities(ctx context.Context, slots []inventory.Slot, items ItemLookup) []DurabilitySnapshot {
	if items == nil {
		return nil
	}
	var out []DurabilitySnapshot
	for _, sl := range slots {
		if sl.Durability == durability.Untracked {
			continue
		}
		item, err := items.GetItem(ctx, sl.ItemID)
		if err != nil || item == nil || item.DurabilityMax <= 0 {
			continue
		}
		out = append(out, DurabilitySnapshot{
			Slot:          sl.Index,
			Durability:    sl.Durability,
			MaxDurability: durability.MaxDurability(item.DurabilityMin, item.DurabilityMax, sl.Variance),
		})
	}
	return out
}

// equipmentDurabilities is inventoryDurabilities for the worn slots.
func equipmentDurabilities(ctx context.Context, worn []equipment.Equipped, items ItemLookup) []DurabilitySnapshot {
	if items == nil {
		return nil
	}
	var out []DurabilitySnapshot
	for _, e := range worn {
		if e.Durability == durability.Untracked {
			continue
		}
		item, err := items.GetItem(ctx, e.ItemID)
		if err != nil || item == nil || item.DurabilityMax <= 0 {
			continue
		}
		out = append(out, DurabilitySnapshot{
			Slot:          int(e.Slot),
			Durability:    e.Durability,
			MaxDurability: durability.MaxDurability(item.DurabilityMin, item.DurabilityMax, e.Variance),
		})
	}
	return out
}
