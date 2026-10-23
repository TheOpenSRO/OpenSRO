package session

// The Test Items NPC's equipment comes perfect (round 786, OURS: the user's
// request, "all +12 full blue at 100% stats"): every piece it gives away is
// +12, every white-stat variance group at its top (31 of 31, the 100% the
// item tooltip shows), and "full blue" -- every standard blue option the
// item kind can carry, at the item's degree and its highest value
// (magicopt.FullBlue). Its durability is the max those make. Bought from any
// other NPC the same item is an ordinary one.

import (
	"context"
	"encoding/binary"
	"errors"
	"slices"

	"github.com/TheOpenSRO/OpenSRO/server/internal/alchemy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
)

// TestShopPlus is the plus the Test Items NPC's equipment carries.
const TestShopPlus = 12

// fullVariance is every variance group at its top (durability.GroupMax).
var fullVariance = func() uint64 {
	var v uint64
	for k := 0; k < durability.Groups; k++ {
		v |= uint64(durability.GroupMax) << (5 * uint(k))
	}
	return v
}()

// testShopInstance is the Test Items NPC's instance of itemID; ok false for
// an item that is not equipment, or with no item table, which the bag rolls
// as any buy.
func testShopInstance(ctx context.Context, itemID int64) (inventory.Instance, bool) {
	dropOptions.RLock()
	items, assign := dropOptions.items, dropOptions.assign
	dropOptions.RUnlock()
	if items == nil {
		return inventory.Instance{}, false
	}
	it, err := items.GetItem(ctx, itemID)
	if err != nil || it == nil || !isEquipment(it) {
		return inventory.Instance{}, false
	}
	// Round 789 (OURS): an avatar or a devil's spirit is sold as the item mall
	// sells it -- +0, no blue options (the blacksmith's grant adds them), a
	// devil's spirit not yet awakened -- so the grant and the awakening have
	// something to do. Retail avatars take no plus (the alchemy window
	// refuses them, AVATAR_ALCHEMY_RESEARCH.md section 2).
	if avatar.IsAvatarItem(it) {
		return inventory.Instance{}, false
	}
	inst := inventory.Instance{Variance: fullVariance, OptLevel: TestShopPlus, Durability: durability.Untracked}
	table := magicOptions.Load()
	var opts []alchemy.Option
	for _, o := range magicopt.FullBlue(table, assign, magicopt.DropItem{
		Equip: true, Rarity: it.Rarity, Race: it.Country, TypeID3: it.TypeID3, TypeID4: it.TypeID4,
		Code: it.CodeName, MaxOptions: it.MaxMagicOptions,
	}, (it.ItemClass-1)/3+1) {
		inst.MagParams = append(inst.MagParams, inventory.MagParam(o.ID, o.Value))
		if r := table.ByID(o.ID); r != nil {
			opts = append(opts, alchemy.Option{ID: o.ID, Tag: r.Tag, Value: o.Value})
		}
	}
	if lookup, ok := items.(inventory.DurabilityLookup); ok {
		lo, hi, tracked, err := lookup.DurabilityRange(ctx, itemID)
		if err == nil && tracked && durability.Tracked(lo, hi) {
			inst.Durability = alchemy.MaxDurability(durability.MaxDurability(lo, hi, fullVariance), opts, table)
		}
	}
	return inst, true
}

// TestShopGoodsPayloads is OpNpcShopGoods for the NPC with unique id uid
// selling ids (round 786, OURS; testnpc.OpNpcShopGoods): each equipment
// good's testShopInstance as the retail item record, keyed by its item id,
// split across as many messages as one frame each needs. The listing is the
// buy's own instance, so the store shows the item exactly as it is bought.
// nil when no good is equipment, or with no item table (the buy then has no
// instance either). Called once at boot, after SetMagicOptions and
// SetDropOptions (cmd/server).
func TestShopGoodsPayloads(ctx context.Context, uid uint32, ids []int64) [][]byte {
	dropOptions.RLock()
	items := dropOptions.items
	dropOptions.RUnlock()
	sorted := slices.Clone(ids)
	slices.Sort(sorted)
	var infos []ItemInfo
	for _, id := range slices.Compact(sorted) {
		inst, ok := testShopInstance(ctx, id)
		if !ok {
			continue
		}
		if ii, ok := itemInfoFor(ctx, items, int(id), id, inst); ok {
			infos = append(infos, ii)
		}
	}
	var out [][]byte
	for len(infos) > 0 {
		head := binary.LittleEndian.AppendUint32(nil, uid)
		fit := fitItemInfos(len(head), infos)
		if len(fit) == 0 {
			break // a record over a frame: cannot be (12 options at most)
		}
		out = append(out, encodeItemInfoBlock(head, fit))
		infos = infos[len(fit):]
	}
	return out
}

// DecodeShopGoods reads an OpNpcShopGoods payload: the NPC's uid and each
// good's item id -> its record (tests; the client's mirror is
// NpcShopDefNet.decode_goods).
func DecodeShopGoods(b []byte) (uint32, map[int64]ItemInfo, error) {
	if len(b) < 6 {
		return 0, nil, errors.New("shop goods: truncated")
	}
	infos, err := decodeItemInfoBlock(b[4:])
	out := make(map[int64]ItemInfo, len(infos))
	for _, ii := range infos {
		out[int64(ii.Slot)] = ii
	}
	return binary.LittleEndian.Uint32(b), out, err
}
