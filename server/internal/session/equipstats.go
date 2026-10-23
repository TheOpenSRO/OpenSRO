package session

// Round 769: a worn item's plus and blue options count. Every rule is READ
// from SR_GameServer.exe (docs/protocol/item_magic_options.md, "Round 769"):
//
//   - The effective plus (FUN_00459c70) is OptLevel + the advanced elixir's
//     binding value + a 'rein' option's column 9. Char_BuildAggregateStats
//     (0x495d60) adds Inc * plus to each stat's white value (refdata.Item's
//     PlusInc* columns): the attack ranges, the defences, the absorbs, the
//     parry and the attack rate.
//   - ApplyDurabilityAndRateOptions (0x496a70) then scales the weapon's
//     attack rate by its 'hr' option and a body piece's parry by its 'er'
//     option, (1 + v/100) each.
//   - Stat_ApplyTaggedModifier (0x498690) adds 'str', 'int', 'hp' and 'mp'
//     flat to params 1-4 (character.Bonus), replaces the weapon's critical
//     and the shield's block with round(white) + 'cri' / 'bri', and adds
//     'evbl' / 'evcr' into params 56 / 57, which divide the opponent's block
//     and critical (combat.EvadedChance).
//
// A broken item contributes nothing: CGObjPC::ChangeItemDurability
// (0x4e7100) removes a breaking item's param entries and does not publish
// them again, and PublishEquipItemParams (0x4e3760) runs the option
// operations only when the item's own publication succeeds (READ, round 769's
// review). PublishEquipItemParams also gates the whole item on
// CheckEquipRequirements (0x4919e0); OpenSRO checks requirements only at
// equip time (OPEN: an item worn below its requirement, after a de-level,
// still counts here). The set items' opt-level bonus
// (CGPCInventoryOP::ApplySetItemOptLevel2ThisGroup 0x4bb680) is not built.
// The magic option table names each option's tag; without it no option
// counts (the plus still does).

import (
	"context"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
)

var magicOptions atomic.Pointer[magicopt.Table]

// SetMagicOptions installs the magic option table the worn items' options
// are read through (cmd/server's -magic-options-csv). nil: no option counts.
func SetMagicOptions(t *magicopt.Table) { magicOptions.Store(t) }

// The tags this file reads.
var (
	tagStr  = combat.PackTag("str")
	tagInt  = combat.PackTag("int")
	tagHP   = combat.PackTag("hp")
	tagMP   = combat.PackTag("mp")
	tagHR   = combat.PackTag("hr")
	tagER   = combat.PackTag("er")
	tagCri  = combat.PackTag("cri")
	tagBri  = combat.PackTag("bri")
	tagEvbl = combat.PackTag("evbl")
	tagEvcr = combat.PackTag("evcr")
	tagRein = combat.PackTag("rein")
)

// wornOption is one of a worn item's blue options, its tag resolved.
type wornOption struct {
	tag   uint32
	value int
	row   *magicopt.Row
}

// optionsOf resolves an item's packed options through the table; an id the
// table lacks is left out.
func optionsOf(params []uint64) []wornOption {
	t := magicOptions.Load()
	if t == nil {
		return nil
	}
	out := make([]wornOption, 0, len(params))
	for _, p := range params {
		r := t.ByID(inventory.MagParamOption(p))
		if r == nil {
			continue
		}
		out = append(out, wornOption{tag: r.Tag, value: int(inventory.MagParamValue(p)), row: r})
	}
	return out
}

// optionSum is the sum of an item's options with tag.
func optionSum(opts []wornOption, tag uint32) int {
	n := 0
	for _, o := range opts {
		if o.tag == tag {
			n += o.value
		}
	}
	return n
}

// wornPlus is FUN_00459c70: the plus, the advanced elixir's value and a
// 'rein' option's column 9 (MEASURED: level 1 gives 1, level 2 gives 2), as
// a byte. (equipment.Equipped.EffectivePlus is the same without 'rein',
// which needs the magic option table.)
func wornPlus(e equipment.Equipped) int {
	p := int(e.OptLevel) + int(e.AdvElixir)
	for _, o := range optionsOf(e.MagParams) {
		if o.tag == tagRein && o.row != nil {
			p += int(o.row.Params[1])
		}
	}
	return p & 0xff
}

// equipBonus is the character.Bonus the worn items give: their 'str',
// 'int', 'hp', 'mp', 'evbl' and 'evcr' options summed (the last two clamped
// at 100, the params' max), broken items left out. ok false when the worn
// items could not be read, so the registry does not cache a zero.
func equipBonus(ctx context.Context, characterID int64, eq equipment.Store) (character.Bonus, bool) {
	var b character.Bonus
	if eq == nil || magicOptions.Load() == nil {
		return b, true
	}
	worn, err := eq.Get(ctx, characterID)
	if err != nil {
		return b, false
	}
	for _, e := range worn {
		if durability.IsBroken(e.Durability) {
			continue
		}
		opts := optionsOf(e.MagParams)
		b.Str += optionSum(opts, tagStr)
		b.Int += optionSum(opts, tagInt)
		b.HP += optionSum(opts, tagHP)
		b.MP += optionSum(opts, tagMP)
		b.EvadeBlock += optionSum(opts, tagEvbl)
		b.EvadeCrit += optionSum(opts, tagEvcr)
	}
	b.EvadeBlock, b.EvadeCrit = min(b.EvadeBlock, 100), min(b.EvadeCrit, 100)
	return b, true
}

// SetEquipBonusSource makes the worn items' options count toward a
// character's Str, Int, max HP/MP and evasion (character.BonusOf), read from
// eq.
func SetEquipBonusSource(eq equipment.Store) {
	if eq == nil {
		character.SetBonusSource(nil)
		return
	}
	character.SetBonusSource(func(id int64) (character.Bonus, bool) {
		return equipBonus(context.Background(), id, eq)
	})
}

// wornOptionSum is one option summed over every worn, unbroken item except
// the one in `except` (-1 for none): the other items' entries of a param a
// 'cri' / 'bri' option writes (each item's own entry is round(its white
// value) + v, and a non-weapon's critical / a non-shield's block white value
// is 0; INFERRED for the white values of other kinds, review F7).
func wornOptionSum(ctx context.Context, characterID int64, eq equipment.Store, tag uint32, except equipment.Slot) int {
	if eq == nil || magicOptions.Load() == nil {
		return 0
	}
	worn, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0
	}
	n := 0
	for _, e := range worn {
		if e.Slot != except && !durability.IsBroken(e.Durability) {
			n += optionSum(optionsOf(e.MagParams), tag)
		}
	}
	return n
}

// clampHP lowers a character's stored HP to its max when a worn item taken
// off, swapped or broken lowered the max below it (OURS, round 769's review
// F2: whether retail clamps here is OPEN; without it the HP stayed banked
// above the max, because regeneration only ever raises it).
func clampHP(ctx context.Context, chars character.Store, characterID int64) {
	if chars == nil {
		return
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return
	}
	if m := c.MaxHP(); c.HP > m {
		_, _ = chars.Heal(ctx, characterID, 0, m)
	}
}
