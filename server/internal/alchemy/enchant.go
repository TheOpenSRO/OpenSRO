package alchemy

// The three enchant operations the alchemy window runs (round 768): the
// elixir reinforce (CEnchant_Reinforce), the magic stone
// (CEnchant_EnchantMagicStone) and the attribute stone
// (CEnchant_EnchantAttrStone), as SR_GameServer.exe executes them. Every rule
// below is READ from that binary (addresses given; docs/protocol/alchemy.md,
// "Round 768"), except where a comment says OURS or INFERRED.
//
// The engine works on a Target -- the plus, the white stats and the blue
// options of one bag item, with the reference facts the rules ask about --
// and changes it in place. The caller turns it back into an
// inventory.Instance and persists it.

import (
	"math"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/magicopt"
)

// Rand is the engine's rand(): Intn(n) uniform in [0, n).
type Rand = magicopt.Rand

// The bless-stone tags (magic_options.md's vocabulary, packed big-endian).
// Their option VALUE is a count of charges: each protective use spends one
// (FUN_00505e50).
var (
	TagSolid  = combat.PackTag("soli") // MATTR_SOLID: Steady
	TagAstral = combat.PackTag("astr") // MATTR_ASTRAL
	TagApe    = combat.PackTag("ape")  // assimilation protection
	TagRepair = combat.PackTag("rep")  // honour items' repair
	TagDecDur = combat.PackTag("dura") // MATTR_DEC_MAXDUR: the durability flaw
	TagNoRep  = combat.PackTag("nrep")
)

// Option is one blue option: the magicoption.txt id the item stores, the tag
// that id resolves to, and the value (the high dword of the packed u64).
type Option struct {
	ID    uint16
	Tag   uint32
	Value uint32
}

// Class is an equipment item's alchemy class: the four kinds the attribute
// stones and the white-stat counts distinguish. ClassNone is anything else.
type Class int

const (
	ClassNone Class = iota
	ClassWeapon
	ClassShield
	ClassArmour
	ClassAccessory
)

// ClassOf names an equipment item's class from its TypeID3 (equipment is
// TypeID1 3 / TypeID2 1). READ, the client's predicates (re_client notes
// 0x56fa30/0x56fa80/0x56fb40, and the server's TID3 test for the shield):
// armour 1, 2, 3, 9, 10, 11; shield 4; accessory 5, 12; weapon 6.
func ClassOf(typeID3 int) Class {
	switch typeID3 {
	case 6:
		return ClassWeapon
	case 4:
		return ClassShield
	case 1, 2, 3, 9, 10, 11:
		return ClassArmour
	case 5, 12:
		return ClassAccessory
	}
	return ClassNone
}

// WhiteCount is how many white-stat groups an item of the class carries, the
// N the assimilation step draws over (slot 8, FUN_00501d30, READ): weapon 7,
// armour and shield 6, accessory 2.
func (c Class) WhiteCount() int {
	switch c {
	case ClassWeapon:
		return 7
	case ClassShield, ClassArmour:
		return 6
	case ClassAccessory:
		return 2
	}
	return 0
}

// attrNames is each class's white-stat list in variance-group order
// (FUN_00502c80, READ): an attribute stone's NATTR_ name sets the group at
// its position here. The order is durability.go's group order (round 243).
var attrNames = map[Class][]string{
	ClassWeapon:    {"DUR", "PASTR", "MAINT", "HR", "PA", "MA", "CRITICAL"},
	ClassArmour:    {"DUR", "PDSTR", "MDINT", "PD", "MD", "ER"},
	ClassShield:    {"DUR", "PDSTR", "MDINT", "BR", "PD", "MD"},
	ClassAccessory: {"PAR", "MAR"},
}

// classWord is the word an attribute stone's Desc128_4 lists for a class
// (MEASURED: "weapon", "armor,shield", "shield", "armor", "accessory").
var classWord = map[Class]string{
	ClassWeapon: "weapon", ClassShield: "shield", ClassArmour: "armor", ClassAccessory: "accessory",
}

// Target is the item being worked on.
type Target struct {
	TypeID3, TypeID4 int
	// CodeName is the item's code name, which a few options name outright.
	CodeName string
	// ItemClass is the reference ItemClass (itemdata column 61, ref +0x1a8).
	ItemClass int
	// Cash is the TypeID word's bit 0 (IsCashItem, gs 0x483890): a cash item
	// is never destroyed by a failed reinforce.
	Cash bool
	// MaxOptions is itemdata column 158 (ref +0x53c), the base option cap.
	MaxOptions int

	OptLevel   int
	Variance   uint64
	Durability int
	Options    []Option
}

// Degree is the equipment degree, (ItemClass-1)/3 + 1 (FUN_004775a0, READ).
func (t *Target) Degree() int { return (t.ItemClass-1)/3 + 1 }

// Class is the target's alchemy class.
func (t *Target) Class() Class { return ClassOf(t.TypeID3) }

// Find returns the index of the option carrying tag, or -1.
func (t *Target) Find(tag uint32) int {
	for i, o := range t.Options {
		if o.Tag == tag {
			return i
		}
	}
	return -1
}

// Has reports whether the target carries tag.
func (t *Target) Has(tag uint32) bool { return t.Find(tag) >= 0 }

// Spend uses one charge of a bless option (FUN_00505e50, READ): a value
// below 2 removes the option (the rest shift down), any other loses one. It
// reports whether the target had the option at all.
func (t *Target) Spend(tag uint32) bool {
	i := t.Find(tag)
	if i < 0 {
		return false
	}
	if t.Options[i].Value < 2 {
		t.Options = append(t.Options[:i], t.Options[i+1:]...)
	} else {
		t.Options[i].Value--
	}
	return true
}

// MaxOptionCount is the option cap FUN_00491780 computes (READ): column 158
// plus one for every 'dura' and 'nrep' option already present, capped at 12.
func (t *Target) MaxOptionCount() int {
	n := t.MaxOptions
	for _, o := range t.Options {
		if o.Tag == TagDecDur || o.Tag == TagNoRep {
			n++
		}
	}
	if n > 12 {
		n = 12
	}
	return n
}

// ---------------------------------------------------------------------------
// Reinforce
// ---------------------------------------------------------------------------

// MaxPlus is the highest plus: the loader refuses an item past 249 and the
// setter clamps at 250 (0x505bd0, 0x506ae0; READ).
const MaxPlus = 250

// The server's own failure flags (FUN_00506ce0, READ). They never go on the
// wire: the reply carries success and destroyed, and the client derives its
// UI_REINFORCERR byte by comparing the old and new item.
const (
	failLosePlus = 0x08
	failDestroy  = 0x10
	failFlaw     = 0x02
)

// ReinforceRate is the full rate of an attempt, the clamp included
// (slots 6, 7 and 1 of CEnchant_Reinforce; READ, with round 768's
// correction): the elixir's packed rate for the plus; with a lucky powder
// loaded, unless that already exceeds 99, the POWDER's own packed rate is
// added (the second LookupPackedRate runs on the powder, asm
// 0x506046-0x506055 -- not the elixir's rate twice); then, below 100, Lucky
// adds 5 and spends a charge; then param 173. It changes t (the luck
// charge), so call it once per attempt.
func ReinforceRate(t *Target, elixir [3]uint32, powder *[3]uint32, paramBonus int) int {
	rate := BaseRate(t.OptLevel, elixir)
	early := false
	if powder != nil {
		if rate > CeilingTest {
			early = true
		} else {
			rate += BaseRate(t.OptLevel, *powder)
		}
	}
	if !early && rate < MaxRate && t.Has(combat.PackTag("luck")) {
		rate += LuckyBonus
		t.Spend(combat.PackTag("luck"))
	}
	return ClampRate(rate + paramBonus)
}

// ReinforceResult is what an attempt did.
type ReinforceResult struct {
	Rate      int
	Success   bool
	Destroyed bool
}

// Reinforce runs one elixir attempt on t (MakeAttempt 0x506090, READ).
// Success raises the plus by one and changes nothing else (0x506b20). A
// failure (FUN_00506ce0), n the plus before:
//   - from +5 up, half the time the item is destroyed (never a cash item),
//     the other half its durability is flawed;
//   - an Immortal ('atha') charge cancels the destruction, a Steady ('soli')
//     charge the flaw;
//   - the plus falls to 0, or to 4 when n >= 4 and an Astral charge is spent.
//
// The flaw adds a MATTR_DEC_MAXDUR value from the table's LEVEL-3 record
// (asm 0x4906db), added to any existing one and clamped to 1..99.
func Reinforce(t *Target, elixir [3]uint32, powder *[3]uint32, paramBonus int, opts *magicopt.Table, r Rand) ReinforceResult {
	n := t.OptLevel
	res := ReinforceResult{Rate: ReinforceRate(t, elixir, powder, paramBonus)}
	if Succeeds(res.Rate, r.Intn(RollModulus)) {
		t.OptLevel = min(n+1, MaxPlus)
		res.Success = true
		return res
	}
	flags := failLosePlus
	if n >= 5 {
		if r.Intn(100) < 50 {
			if !t.Cash {
				flags |= failDestroy
			}
		} else {
			flags |= failFlaw
		}
	}
	if flags&failDestroy != 0 && t.Spend(combat.PackTag("atha")) {
		flags &^= failDestroy
	}
	if flags&failFlaw != 0 && t.Spend(TagSolid) {
		flags &^= failFlaw
	}
	if flags&failDestroy != 0 {
		res.Destroyed = true
		return res
	}
	if flags&failFlaw != 0 {
		flaw(t, opts, r)
	}
	if n >= 4 && t.Spend(TagAstral) {
		t.OptLevel = 4
	} else {
		t.OptLevel = 0
	}
	return res
}

// flawLevel is the record FUN_00506b60 always reads for the flaw: level 3
// (`mov edi,3`, asm 0x4906db; READ).
const flawLevel = 3

// flaw is FUN_00506b60: a fresh MATTR_DEC_MAXDUR value from the level-3
// record, added to any 'dura' the item has, clamped to 1..99, written in
// place or appended -- only if the option is allowed on the item.
func flaw(t *Target, opts *magicopt.Table, r Rand) {
	if opts == nil {
		return
	}
	rec := opts.Record("MATTR_DEC_MAXDUR", flawLevel)
	if rec == nil || !rec.AllowedOn(t.TypeID3, t.TypeID4, t.CodeName) {
		return
	}
	v := int(rec.Generate(r))
	i := t.Find(TagDecDur)
	if i >= 0 {
		v += int(t.Options[i].Value)
	}
	v = max(1, min(v, 99))
	if i >= 0 {
		// The existing option keeps its own id: FUN_00490550 hands back the
		// found entry's id, and the overwrite writes that (asm 0x506c27 /
		// 0x506c6a; round 768's review F1).
		t.Options[i].Value = uint32(v)
		return
	}
	if len(t.Options) < t.MaxOptionCount() {
		t.Options = append(t.Options, Option{ID: rec.ID, Tag: TagDecDur, Value: uint32(v)})
	}
}

// ---------------------------------------------------------------------------
// Stones
// ---------------------------------------------------------------------------

// Stone is a magic or attribute stone as the engine reads it.
type Stone struct {
	// Param1 is the stone's degree (itemdata column 118).
	Param1 int
	// Rate is its success rate, Param4 (column 124, ref +0x300).
	Rate int
	// Desc1 names what it writes: an MATTR_ code on a magic stone, an NATTR_
	// name on an attribute stone (Desc128_1, column 119).
	Desc1 string
	// Desc4 lists the classes an attribute stone suits (column 125).
	Desc4 string
	// Assimilation is the stone instance's OptLevel byte: the percentage
	// chance (`rand()%101 <`) that a success also disturbs another stat.
	Assimilation int
}

// StoneMinRate is the stones' floor: `<5 -> 5` (0x503680; READ).
const StoneMinRate = 5

// StoneRate is a stone's clamped rate: Param4 + round(param 172), floor 5,
// above 99 -> 100.
func StoneRate(s Stone, paramBonus int) int {
	rate := s.Rate + paramBonus
	if rate < StoneMinRate {
		return StoneMinRate
	} else if rate > CeilingTest {
		return MaxRate
	}
	return rate
}

// StoneSucceeds is the stones' roll, which differs from the reinforce roll:
// the attempt FAILS iff `rate < rand()%100` (0x503680, 0x5032a0), so a roll
// equal to the rate succeeds.
func StoneSucceeds(rate, roll int) bool { return !(rate < roll) }

// StoneResult is what a stone attempt did. Code is Success (1), a 0x54xx
// error, or NothingWritten. Only ErrEnchantFailed -- the lost roll -- spends
// the stone; every other refusal leaves it in the bag.
type StoneResult struct {
	Rate int
	Code int
	// Assimilated says which stat the assimilation step disturbed: -1 none,
	// 0..6 a white group, WhiteCount()+i blue option i, Protected an 'ape'
	// charge spent instead.
	Assimilated int
	// Before and After are the written option's value before (0 when new)
	// and after, for the client's "%d -> %d" lines.
	Before, After uint32
}

// NothingWritten is BlessItem's return of 2: the roll succeeded but the
// table has no such option, or the item has no room for a new one. Like
// every refusal after a successful roll it goes out as an error reply with
// that code, and the stone is NOT spent (READ: only the failed roll releases
// the loaded items inside MakeAttempt; the error path clears the slots).
const NothingWritten = 2

// Protected marks an assimilation an 'ape' charge absorbed.
const Protected = -2

// MagicStone runs one magic or bless stone attempt (MakeAttempt 0x503680 and
// BlessItem 0x503810; READ). The degree and kind checks come only after a
// successful roll, as in the binary; the client refuses a mismatched stone
// before it is sent.
func MagicStone(t *Target, s Stone, paramBonus int, opts *magicopt.Table, r Rand) StoneResult {
	res := StoneResult{Rate: StoneRate(s, paramBonus), Assimilated: -1}
	if !StoneSucceeds(res.Rate, r.Intn(RollModulus)) {
		res.Code = ErrEnchantFailed
		return res
	}
	res.Code = blessItem(t, s, opts, r, &res)
	return res
}

// The bless tags: values are charge counts, raised by one per stone.
var blessTags = map[uint32]bool{
	combat.PackTag("atha"): true, combat.PackTag("luck"): true, TagSolid: true,
	TagAstral: true, TagApe: true,
}

// The value cap a stone's generated value is clamped to (BlessItem; READ).
const (
	stoneValueMax  = 1700
	blessChargeMax = 5
	repChargeMax   = 6
)

func blessItem(t *Target, s Stone, opts *magicopt.Table, r Rand, res *StoneResult) int {
	maxCount := t.MaxOptionCount()
	if len(t.Options) > maxCount {
		return NothingWritten
	}
	// No group by the stone's name: "Can't find Magic [%s] option from Ref
	// Table!" and 2.
	if len(opts.Group(s.Desc1)) == 0 {
		return NothingWritten
	}
	if s.Param1 != t.Degree() {
		return ErrTargetCannotBeReinforced
	}
	// The kind check looks the level's record up first: none, or not
	// allowed on this item, is 0x5409.
	rec := opts.Record(s.Desc1, s.Param1)
	if rec == nil || !rec.AllowedOn(t.TypeID3, t.TypeID4, t.CodeName) {
		return ErrRecipeMismatch
	}
	tag := rec.Tag
	i := t.Find(tag)
	var have uint32
	if i >= 0 {
		have = t.Options[i].Value
	}
	if tag == TagRepair && i < 0 {
		return ErrHonorItem
	}
	if tag == TagAstral {
		a := t.Find(combat.PackTag("atha"))
		if a < 0 || t.Options[a].Value <= have {
			return ErrAstralAlt
		}
	}
	var v uint32
	switch {
	case blessTags[tag]:
		v = have + 1
		if v > blessChargeMax {
			return ErrMagicStone2Max
		}
	case tag == TagRepair:
		v = have + 1
		if v > repChargeMax {
			return ErrMagicStone2Max
		}
	default:
		v = max(1, min(rec.Generate(r), stoneValueMax))
	}
	hadOptions := len(t.Options)
	if i >= 0 {
		// The existing option keeps its id (FUN_00490550's EDI; asm
		// 0x5039f2..0x503b53, review F1): only the value changes.
		t.Options[i].Value = v
	} else {
		if len(t.Options) >= maxCount {
			// OURS (review F8): the binary still runs the assimilation step
			// before it returns 2 (asm 0x503b44 -> 0x503be2), on an item its
			// error path then does not save; this returns before it.
			return NothingWritten
		}
		t.Options = append(t.Options, Option{ID: rec.ID, Tag: tag, Value: v})
	}
	res.Before, res.After = have, v
	res.Assimilated = assimilate(t, s.Assimilation, -1, true, hadOptions == 0, opts, r)
	return Success
}

// AttrStone runs one attribute stone attempt (0x5032a0 and 0x503430; READ):
// the degree and the stone's class list are checked first (slot 4, 0x502a40:
// 0x5421 on either), then the same roll as a magic stone, then the white
// group the stone names is SET to a fresh value.
//
// OURS (review F9): three edge cases are refused here with 0x5421 before the
// roll where the binary differs -- an empty class list returns 2, a list
// naming no known class passes, and a NATTR_ name the class list lacks returns
// 2 only after the roll (so a lost roll would spend the stone). No retail
// attribute stone has any of the three; the client refuses them before
// sending.
func AttrStone(t *Target, s Stone, paramBonus int, opts *magicopt.Table, r Rand) StoneResult {
	res := StoneResult{Rate: StoneRate(s, paramBonus), Assimilated: -1}
	group := AttrGroup(t.Class(), s.Desc1)
	if s.Param1 != t.Degree() || !AttrStoneSuits(s.Desc4, t.Class()) || group < 0 {
		res.Code = ErrEnchantEquipClassMismatch
		return res
	}
	if !StoneSucceeds(res.Rate, r.Intn(RollModulus)) {
		res.Code = ErrEnchantFailed
		return res
	}
	res.Before = uint32(durability.Group(t.Variance, group))
	v := whiteValue(t.MaxOptionCount(), r)
	t.Variance = setGroup(t.Variance, group, v)
	res.After = uint32(v)
	res.Assimilated = assimilate(t, s.Assimilation, group, false, false, opts, r)
	res.Code = Success
	return res
}

// AttrStoneSuits reports whether an attribute stone's Desc128_4 class list
// ("armor,shield", "weapon", ...) names the target's class.
func AttrStoneSuits(desc4 string, c Class) bool {
	word, ok := classWord[c]
	if !ok {
		return false
	}
	for _, w := range strings.Split(desc4, ",") {
		if strings.EqualFold(strings.TrimSpace(w), word) {
			return true
		}
	}
	return false
}

// AttrGroup is the variance group an attribute stone's NATTR_ name sets on
// the class, or -1.
func AttrGroup(c Class, desc1 string) int {
	name := strings.TrimPrefix(strings.ToUpper(strings.TrimSpace(desc1)), "NATTR_")
	for i, n := range attrNames[c] {
		if n == name {
			return i
		}
	}
	return -1
}

// whitePct is FUN_00501ea0's percentage table (READ); the value written is
// pct*31/100: 0, 7, 13, 19, 25, 31.
var whitePct = [6]int{0, 23, 43, 63, 83, 100}

// whiteValue is FUN_00501ea0 (READ): k is the minimum of maxCount and four
// draws of rand()%6, the table's entry scaled to 31. (The binary draws five
// for an equip whose ref+0x89 is 2 -- INFERRED Rarity, a Seal item; OpenSRO
// does not export that byte, so every item takes four: OURS.)
func whiteValue(maxCount int, r Rand) int {
	k := maxCount
	for i := 0; i < 4; i++ {
		k = min(k, r.Intn(6))
	}
	k = max(0, min(k, 5))
	return whitePct[k] * durability.GroupMax / 100
}

func setGroup(v uint64, group, value int) uint64 {
	shift := uint(5 * group)
	return v&^(uint64(0x1f)<<shift) | uint64(value&0x1f)<<shift
}

// assimilate is the step after a successful stone (slots 10/11; READ): with
// probability pct/101 another stat is disturbed. An 'ape' charge absorbs it.
// Otherwise k is drawn over the white groups and the blue options:
//   - a white index re-rolls that group the way an attribute stone rolls
//     (SetEnchantAttrToAttrAssim, FUN_00501ea0), except the group an
//     attribute stone just set (justSet);
//   - a blue index re-rolls an option from its own record
//     (SetEnchantMagicToAttrAssim), never a charge, flaw or repair option.
//     After a MAGIC stone that option is always index 0, and only while the
//     item has room below its cap; after an attribute stone it is the one
//     drawn.
//
// magic marks the magic stone's variant, and fresh its "the item had no
// options before", which sends every draw to the white step -- index
// WhiteCount() included, which writes a group past the class's list, as the
// binary does (harmless: no stat reads it).
func assimilate(t *Target, pct, justSet int, magic, fresh bool, opts *magicopt.Table, r Rand) int {
	if pct <= 0 || r.Intn(101) >= pct {
		return -1
	}
	if t.Spend(TagApe) {
		return Protected
	}
	white := t.Class().WhiteCount()
	n := white + len(t.Options)
	if n <= 0 {
		return -1
	}
	k := r.Intn(n)
	if k < white || (magic && fresh) {
		if k == justSet || k >= durability.Groups {
			return -1
		}
		t.Variance = setGroup(t.Variance, k, whiteValue(t.MaxOptionCount(), r))
		return k
	}
	i := k - white
	if magic {
		i = 0
	}
	// Both stones re-roll a blue option through 0x502040, which refuses an
	// item at its cap ("MagOptCount is Max!"; review F2).
	if len(t.Options) >= t.MaxOptionCount() {
		return -1
	}
	if i >= len(t.Options) || opts == nil {
		return -1
	}
	o := t.Options[i]
	if blessTags[o.Tag] || o.Tag == TagDecDur || o.Tag == TagRepair {
		return -1
	}
	rec := opts.ByID(o.ID)
	if rec == nil {
		return -1
	}
	t.Options[i].Value = max(1, min(rec.Generate(r), stoneValueMax))
	return white + i
}

// TagDur is MATTR_DUR ('duru'), which raises max durability by a percentage.
var TagDur = combat.PackTag("duru")

// MaxDurability is an item's max durability with its durability options
// (GItemEquip::ApplyDurabilityAndRateOptions 0x496a70; READ,
// docs/protocol/durability.md): pct is the 'duru' values, less the 'dura'
// values, plus each 'nrep' option's record column 9; a non-zero pct adds
// round(base * pct / 100), and a result of 0 becomes 1.
func MaxDurability(base int, opts []Option, table *magicopt.Table) int {
	pct := 0
	for _, o := range opts {
		switch o.Tag {
		case TagDur:
			pct += int(o.Value)
		case TagDecDur:
			pct -= int(o.Value)
		case TagNoRep:
			if r := table.ByID(o.ID); r != nil {
				pct += int(r.Params[1])
			}
		}
	}
	if pct == 0 {
		return base
	}
	m := base + int(math.Round(float64(base)*float64(pct)/100))
	if m == 0 {
		m = 1
	}
	return m
}
