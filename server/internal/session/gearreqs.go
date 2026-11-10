package session

// A skill's required gear after the cast (round 882): which learned passives
// count, and which running buffs end, when what a character wears changes.
// Everything READ in SR_GameServer.exe as assembly unless labelled;
// docs/protocol/skill_gear.md has the whole rule.
//
// THE LIST. A skill row's 'reqi' runs fill five [kind, value] entries at
// CRefSkill+0x3a0, and 'reqn' (+0x3b4) makes the list ALL-of. The cast gate
// (Skill_CheckCastRequirement s:0x58d480), the params' own gate
// (ApplySkillParamsToChar s:0x594ac0, its head s:0x594aed..0x594cd5) and the
// re-check (GObjPC::FUN_0059f0e0 s:0x59f0e0) walk it the same way. An entry
// by its kind (the jump table at s:0x59f3e4 with the byte map at s:0x59f3f8):
//
//   - 6, the weapon: the worn weapon's TypeID4 is the value (s:0x59f1be).
//   - 4, the shield: the same of the shield slot's item (s:0x59f1e0).
//   - 1, 2, 3, 9, 10, 11, an armour kind (garment, protector, armour, robe,
//     light armour, heavy armour). Value 0: the six body parts, read in the
//     order of the table at s:0xc63f44 (head, shoulder, chest, legs, hands,
//     feet), must EVERY ONE be of that kind (TypeID3, s:0x59f232..0x59f274:
//     the first part that is not clears the answer and leaves). A value N:
//     the part at index N has TypeID4 N (s:0x59f209..0x59f230; the kind is
//     not compared -- no shipped row has one).
//   - 14, value 1: the avatar storage's item at index 4 (buffreqs.go).
//
//     A slot is read through Equip_GetWeaponTID (s:0x4ead40), FUN_004ead80
//     (s:0x4ead80, the shield slot) and FUN_004eadc0 (s:0x4eadc0, a body
//     part), and each answers TID 0 for an empty slot and for an item whose
//     broken flag (+0x190) is set. Nothing else about the item is asked: an
//     item that fails its own level or mastery requirement and so counts for
//     no stat (round 877) still answers its type here.
//   - Without 'reqn' one entry that holds is enough. With it every entry
//     must hold -- and a list whose five entries are all filled and all hold
//     falls out of the loop with the answer cleared (s:0x59f2a9..0x59f2d3:
//     the count is compared with the index only on the way out through an
//     empty entry). No shipped row fills five.
//
// WHEN. The params' gate runs whenever a record's params are applied: for a
// passive that is its engage -- FUN_0059acd0 (s:0x59acd0) builds a record for
// every learned Basic_Activity 0 row and hands it to SkillActionHandler at a
// world entry (CGObjPC vslot 391, s:0x4df9e0) and at a revive (GObjPC::Revive
// s:0x4df290), and Skill_HandleLearn (s:0x59bfe0) does the same for the row
// just learned; the action (the handler table's entry 4, s:0x587260) is
// EngageSkill (s:0x593540) and the book's insert. The gate applies to a
// record its owner cast on itself (context +0x20 == 1) of a player: a list
// that fails leaves the record with +0x10 = 0 and NOTHING applied (s:0x594cc7)
// -- no ParamKeeper entry, no 'real' resist, no 'setv' variable (FUN_005a02e0
// is the function's last call, s:0x59692a).
//
// The re-check runs after CGItemEquip::DetachAbilityByItemOptLevel
// (s:0x50f1f0, at s:0x50f53f) changed a worn item -- an equipment move (a
// put-on, a take-off, a swap over a worn slot) or an avatar move -- and
// when CGObjPC::ChangeItemDurability (s:0x4e7100, at s:0x4e71a2) took a worn
// item (slot < 13) to 0 or back from 0. It walks the running records, the
// self-cast ones whose skill has a list:
//
//   - a passive whose list holds and whose +0x10 is 0 has its params applied
//     (ApplySkillParamsToChar) and +0x10 = 1 (s:0x59f2f8..0x59f31f); one whose
//     list fails and whose +0x10 is 1 has its 'real' entries taken out
//     (FUN_0059df20), its 'setv' variables removed (FUN_005a02a0 s:0x5a02a0),
//     its ParamKeeper contributions removed (s:0x4b3660) and +0x10 = 0
//     (s:0x59f324..0x59f37d). SkillBook::Update (s:0x59bb80) passes a passive
//     record over, so it stays in the book either way.
//   - an active one whose list fails is ended (FUN_0059eff0(0), its 0xB072
//     at the next Update) unless its Basic_Code holds "SKILL_CH_FIRE_SHIELD_"
//     (s:0x59f383..0x59f3a8).
//
// A record another character cast (+0x20 == 2) and a skill with no list are
// never looked at: a buff whose skill asks for a weapon only through its
// ReqCast_Weapon columns (the cast gate's other branch) outlives the swap.
// A level or mastery change runs neither.
//
// MEASURED (the skill table): 176 of the 783 player passive rows carry a
// list, 18 skills -- the Cleric's four (a whole light-armour or robe set AND
// a cleric rod), the Warrior's seven (a one-handed sword, a two-handed sword
// or a dual axe), the Warlock's two (a warlock rod), the Rogue's one (a
// crossbow), the Chinese shield passive (a shield) and three balance rows.
// Among the timed active rows with a list are the Warrior's guard and frenzy
// buffs (any of its three weapons; the damage frenzy a two-handed sword
// alone), the Cleric's blessings (a cleric rod), the Wizard's, Warlock's,
// Rogue's and Bard's weapon buffs, the Chinese shield and bow buffs and the
// spirits' (kind 14).
//
// OURS: OpenSRO keeps no passive records. A character's passives are a
// computed set (passives.go); it is computed over what is worn, and thrown
// away -- to be computed again -- at each moment the engine re-checks, so the
// two agree at every moment a player can observe.

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// gearState is what a list is walked over: the worn, unbroken items' slots
// and types, and kind 14's answer. known false: the worn items could not be
// read (or one has no type data), and every equipment entry holds, as before
// round 882.
type gearState struct {
	worn   []wornKind
	spirit bool
	known  bool
}

// gearOf builds a gearState from a worn list.
func gearOf(worn ...wornKind) gearState { return gearState{worn: worn, known: true} }

// armourPartSlots is the table at s:0xc63f44: the body part an armour entry
// with value N reads, and the order a value-0 entry reads them in.
var armourPartSlots = [7]equipment.Slot{
	1: equipment.SlotHelm,
	2: equipment.SlotShoulderGuard,
	3: equipment.SlotMail,
	4: equipment.SlotPants,
	5: equipment.SlotGauntlet,
	6: equipment.SlotBoots,
}

// reqListSlots is how many entries a list holds (CRefSkill+0x3a0..+0x3b0).
const reqListSlots = 5

// gearEntryHolds is one entry's test (the switch at s:0x59f1b7).
func gearEntryHolds(r combat.CastRequirement, g gearState) bool {
	at := func(slot equipment.Slot) (wornKind, bool) {
		for _, w := range g.worn {
			if w.slot == slot {
				return w, true
			}
		}
		return wornKind{}, false
	}
	if !g.known && r.Kind != combat.CastReqFlagKind {
		return true
	}
	switch r.Kind {
	case 6:
		w, ok := at(equipment.SlotWeapon)
		return ok && w.typeID4 == r.Value
	case 4:
		w, ok := at(equipment.SlotShield)
		return ok && w.typeID4 == r.Value
	case 1, 2, 3, 9, 10, 11:
		if r.Value != 0 {
			if r.Value >= len(armourPartSlots) {
				return false // FUN_004eadc0 answers 0 past part 6
			}
			w, ok := at(armourPartSlots[r.Value])
			return ok && w.typeID4 == r.Value
		}
		for _, s := range armourPartSlots[1:] {
			if w, ok := at(s); !ok || w.typeID3 != r.Kind {
				return false
			}
		}
		return true
	case combat.CastReqFlagKind:
		return r.Value == 1 && g.spirit
	}
	return false
}

// gearReqsHold is the list walk (s:0x59f190..0x59f2e6, the same loop as
// s:0x594b43..0x594cc5). An empty list holds.
func gearReqsHold(reqs []combat.CastRequirement, all bool, g gearState) bool {
	if len(reqs) == 0 {
		return true
	}
	if len(reqs) > reqListSlots {
		reqs = reqs[:reqListSlots]
	}
	for _, r := range reqs {
		ok := gearEntryHolds(r, g)
		if all && !ok {
			return false
		}
		if !all && ok {
			return true
		}
	}
	// ALL-of: every entry held -- but five filled entries leave the loop with
	// the answer cleared (the engine's own, kept).
	return all && len(reqs) < reqListSlots
}

// wornKindsOf is the worn, unbroken items' slots and types: what the three
// TID getters answer. ok false when the list cannot be read or an item has
// no type data (a row imported before the type_id columns).
func wornKindsOf(ctx context.Context, eq equipment.Store, items ItemLookup, characterID int64) ([]wornKind, bool) {
	if eq == nil || items == nil {
		return nil, false
	}
	list, err := eq.Get(ctx, characterID)
	if err != nil {
		return nil, false
	}
	out := make([]wornKind, 0, len(list))
	for _, e := range list {
		if durability.IsBroken(e.Durability) {
			continue // +0x190: an empty slot to the getters
		}
		it, err := items.GetItem(ctx, e.ItemID)
		if err != nil || it == nil || (it.TypeID3 == 0 && it.TypeID4 == 0) {
			return nil, false
		}
		out = append(out, wornKind{slot: e.Slot, typeID3: it.TypeID3, typeID4: it.TypeID4})
	}
	return out, true
}

// gearStores is where the worn items are read from outside a handler: the
// gear requirement source (gearcount.go), else the skill handlers' stores.
func gearStores() (equipment.Store, ItemLookup) {
	gearGate.Lock()
	src := gearGate.src
	gearGate.Unlock()
	if src != nil {
		return src.eq, src.items
	}
	if d, ok := skillDeps(); ok {
		return d.eq, d.items
	}
	return nil, nil
}

// wornGearOf is characterID's gearState now: its worn items and the avatar
// storage's index 4.
func wornGearOf(ctx context.Context, characterID int64) gearState {
	eq, items := gearStores()
	worn, ok := wornKindsOf(ctx, eq, items, characterID)
	g := gearState{worn: worn, known: ok}
	if reg := avatarRegistryOf(); reg != nil && reg.store != nil {
		if held, err := avatar.List(ctx, reg.store, reg.items, characterID); err == nil {
			g.spirit = spiritReqHolds(held, time.Now())
		}
	}
	return g
}

// gearChanged is the re-check (s:0x59f0e0) after characterID's worn items
// changed -- an equipment move, an item broken or mended: its passives are
// counted again over what is worn now, and its own running buffs whose list
// fails end. hub may be nil (the process's hub is used). It reports the
// buffs ended.
func gearChanged(ctx context.Context, hub *world.Hub, characterID int64) int {
	if characterID == 0 {
		return 0
	}
	invalidatePassives(characterID)
	if hub == nil {
		if d, ok := skillDeps(); ok {
			hub = d.hub
		}
	}
	return len(recheckGearBuffs(hub, characterID, wornGearOf(ctx, characterID)))
}

// gearBroke is gearChanged for a worn item that just reached durability 0,
// run on its own goroutine (wearOneSlot), with the owner's stats sent after.
func gearBroke(characterID int64) {
	gearChanged(context.Background(), nil, characterID)
	pushOwnerStats(characterID)
}
