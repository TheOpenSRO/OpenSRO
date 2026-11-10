package session

// A character's own resistance to the abnormal states (round 881): what its
// buffs, its passives and its worn items put between a monster's skill and
// the state it carries. The rule is statuseffect's resist.go; this file
// gathers the entries. Everything READ in SR_GameServer.exe unless labelled.
//
// Sources:
//
//   - a running buff's 'real' [mask, probability, level] (buff.StateResist),
//     and its 'bgra' / 'reat' (params 27..32 / 145..150, buff.StatContributions);
//   - a learned passive's the same, but only while the passive's own 'reqi'
//     list holds: GObjPC::FUN_0059f0e0 (s:0x59f0e0) takes a passive's 'real'
//     entries out (FUN_0059df20) and its params off while the list fails and
//     puts them back when it holds again. The Cleric's two resist passives
//     ask for a cleric rod AND a whole robe set (10 0 / 6 15 with 'reqn') or a
//     whole light-armour set, the Warrior's for a dual axe (MEASURED, the
//     skill table), so a character fighting with another weapon has none of
//     them. OURS: OpenSRO's other passive params are not gated this way yet
//     (passives.go), only the resists added in this round;
//   - a worn item's blue options (Stat_ApplyTaggedModifier s:0x498690): 'fz'
//     params 27 and 28, 'es' 29, 'bu' 30, 'ps' 31, 'zb' 32; 'rsli', 'rfei',
//     'rsti', 'rdii', 'rcsi' the percent list of sleep, fear, stun, disease,
//     combustion; 'rals' all six params and the lists of combustion, disease,
//     sleep and fear;
//   - the disease on the character itself (param 169, statusRuntime).

import (
	"context"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/statuseffect"
)

// The item option tags this file reads.
var (
	tagFz   = combat.PackTag("fz")
	tagEs   = combat.PackTag("es")
	tagBu   = combat.PackTag("bu")
	tagPs   = combat.PackTag("ps")
	tagZb   = combat.PackTag("zb")
	tagRals = combat.PackTag("rals")
	tagRsli = combat.PackTag("rsli")
	tagRfei = combat.PackTag("rfei")
	tagRsti = combat.PackTag("rsti")
	tagRdii = combat.PackTag("rdii")
	tagRcsi = combat.PackTag("rcsi")
)

// optionElemental is the elemental resist params an option tag writes, as
// client bits (param 27 + bit).
var optionElemental = map[uint32][]int{
	tagFz:   {0, 1},
	tagEs:   {2},
	tagBu:   {3},
	tagPs:   {4},
	tagZb:   {5},
	tagRals: {0, 1, 2, 3, 4, 5},
}

// optionCategory is the resist records whose percent list an option tag
// files its value in ('rals' in the order the engine does, s:0x498fef..
// 0x499018: combustion, disease, sleep, fear).
var optionCategory = map[uint32][]int{
	tagRsli: {statuseffect.ResistCatSleep},
	tagRfei: {statuseffect.ResistCatFear},
	tagRsti: {statuseffect.ResistCatStun},
	tagRdii: {statuseffect.ResistCatDisease},
	tagRcsi: {statuseffect.ResistCatCombustion},
	tagRals: {statuseffect.ResistCatCombustion, statuseffect.ResistCatDisease, statuseffect.ResistCatSleep, statuseffect.ResistCatFear},
}

// passiveResist is one learned passive's resists and the list that gates
// them.
type passiveResist struct {
	reqs    []combat.CastRequirement
	all     bool
	resists []buff.StateResist
	percent [buff.ElementalStates]int
	flat    [buff.ElementalStates]int
}

// splitPassiveResists takes a passive row's elemental resist writes out of
// its stat contributions and returns them, with its 'real' runs, as the
// gated part (nil when the row has none).
func splitPassiveResists(row *refdata.Skill, cs []buff.Contribution, resists []buff.StateResist) ([]buff.Contribution, *passiveResist) {
	pr := &passiveResist{resists: resists}
	rest := cs[:0:0]
	any := len(resists) > 0
	for _, c := range cs {
		switch {
		case c.Param >= buff.ParamResistPercent && c.Param < buff.ParamResistPercent+buff.ElementalStates:
			pr.percent[c.Param-buff.ParamResistPercent] += int(c.Value)
			any = true
		case c.Param >= buff.ParamResistFlat && c.Param < buff.ParamResistFlat+buff.ElementalStates:
			pr.flat[c.Param-buff.ParamResistFlat] += int(c.Value)
			any = true
		default:
			rest = append(rest, c)
		}
	}
	if !any {
		return cs, nil
	}
	pr.reqs = combat.ParseCastRequirements(row.ReqCastList)
	pr.all = row.ReqCastAll
	return rest, pr
}

// wornKind is one worn, unbroken item's slot and type.
type wornKind struct {
	slot             equipment.Slot
	typeID3, typeID4 int
}

// passiveReqsHold is FUN_0059f0e0's list walk over what is worn (s:0x59f0e0,
// READ): kind 6 the weapon's TypeID4, kind 4 the shield's, an armour kind
// (1, 2, 3, 9, 10, 11) with value 0 every one of the six body parts being of
// that TypeID3, with a value the part of that TypeID4; 'reqn' asks for every
// entry, otherwise one is enough. A broken item is an empty slot. Kind 14
// (the spirit) is not asked of a passive (no passive row carries it,
// MEASURED) and fails here.
func passiveReqsHold(reqs []combat.CastRequirement, all bool, worn []wornKind) bool {
	if len(reqs) == 0 {
		return true
	}
	at := func(slot equipment.Slot) (wornKind, bool) {
		for _, w := range worn {
			if w.slot == slot {
				return w, true
			}
		}
		return wornKind{}, false
	}
	holds := func(r combat.CastRequirement) bool {
		switch r.Kind {
		case 6:
			w, ok := at(equipment.SlotWeapon)
			return ok && w.typeID4 == r.Value
		case 4:
			w, ok := at(equipment.SlotShield)
			return ok && w.typeID4 == r.Value
		case 1, 2, 3, 9, 10, 11:
			if r.Value != 0 {
				for _, s := range equipment.ArmorSlots {
					if w, ok := at(s); ok && w.typeID4 == r.Value {
						return true
					}
				}
				return false
			}
			for _, s := range equipment.ArmorSlots {
				if w, ok := at(s); !ok || w.typeID3 != r.Kind {
					return false
				}
			}
			return true
		}
		return false
	}
	for _, r := range reqs {
		ok := holds(r)
		if all && !ok {
			return false
		}
		if !all && ok {
			return true
		}
	}
	return all
}

// statusTargetOf is what a state's roll needs of characterID: its level,
// its elemental resist params, its per-state resist records and its disease.
func statusTargetOf(ctx context.Context, characterID int64, level int, eq equipment.Store, items combat.ItemLookup) statuseffect.Target {
	t := statuseffect.Target{Level: level}
	file := func(rs []buff.StateResist) {
		for _, r := range rs {
			for _, cat := range statuseffect.ResistCategoriesOfMask(r.Mask) {
				t.Resist[cat].File(r.Level, r.Prob)
			}
		}
	}
	// The running buffs (and the worn avatars' params).
	file(buffBooks.StateResistsOf(characterID))
	totals := mergeTotals(buffBooks.ParamTotals(characterID), avatarTotals(characterID))
	for bit := 0; bit < buff.ElementalStates; bit++ {
		t.ResistPercent[bit] = int(totals[buff.ParamResistPercent+bit].Flat)
		t.ResistFlat[bit] = int(totals[buff.ParamResistFlat+bit].Flat)
	}
	// The worn items: their types for the passives' lists, their options.
	var worn []wornKind
	if eq != nil {
		if list, err := countedWorn(ctx, eq, characterID); err == nil {
			for _, e := range list {
				if durability.IsBroken(e.Durability) {
					continue
				}
				if items != nil {
					if it, err := items.GetItem(ctx, e.ItemID); err == nil && it != nil {
						worn = append(worn, wornKind{slot: e.Slot, typeID3: it.TypeID3, typeID4: it.TypeID4})
					}
				}
				for _, o := range optionsOf(e.MagParams) {
					for _, bit := range optionElemental[o.tag] {
						t.ResistPercent[bit] += o.value
					}
					for _, cat := range optionCategory[o.tag] {
						t.Resist[cat].Cut += o.value
					}
				}
			}
		}
	}
	// The passives whose own list holds.
	for _, pr := range passiveOf(characterID).resists {
		if !passiveReqsHold(pr.reqs, pr.all, worn) {
			continue
		}
		file(pr.resists)
		for bit := 0; bit < buff.ElementalStates; bit++ {
			t.ResistPercent[bit] += pr.percent[bit]
			t.ResistFlat[bit] += pr.flat[bit]
		}
	}
	for bit := range t.ResistPercent {
		t.ResistPercent[bit] = max(0, min(t.ResistPercent[bit], statuseffect.MaxResistPercent))
		t.ResistFlat[bit] = max(0, t.ResistFlat[bit])
	}
	t.Disease = statusFX.diseaseOf(characterID)
	return t
}
