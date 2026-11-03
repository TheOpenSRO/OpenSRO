package session

// The tools used on another item (round 838): TypeID 3/3/13/8, on
// OpenSRO's use-item request (OpUseItem 0x008a). docs/protocol/item_switchers.md
// has the whole flow, client and server.
//
// RETAIL (READ, SR_GameServer CGItemExpendable::UseByKind 0x49c2b0, case 8;
// the client's SendItem_HandleUseItem 0x796660): the gender switch tool
// (ITEM_MALL_EQUIP_TRANSGENDER_1..4 and their event copies). The request
// carries the target's wire slot -- the u8 0x704C appends after the slot and
// the type word, bag index + 13 -- which OpenSRO's request carries as its
// Option byte, as the Nasrun extension's does (avataruse.go). The server:
//
//  1. the slot must be a bag slot, `(b - 13) < 99`, else 0x1882
//     UIIT_MSG_STRGERR_CANT_MUTATE_EQUIPED_ITEM;
//  2. the item there must exist, be equipment (IGObj +0x84 CGObj::IsEquip,
//     TypeID 3/1) and armour (+0x9c CGObj::IsArmor -> FUN_00488eb0: TypeID3
//     1, 2, 3, 9, 10 or 11), else 0x1884 UIIT_MSG_STRGERR_INVALID_TRANSGENDER_
//     TARGET;
//  3. the tool's Param1 (ref +0x2a0) must not be below the item's degree
//     (FUN_004775a0: ItemClass at ref +0x1a8, (c - 1) / 3 + 1 for equipment),
//     else 0x1883 UIIT_MSG_STRGERR_CANT_MUTATE_SINCE_EQUIP_CLASS_TOO_HIGH;
//  4. the item's OrgObjCodeName (ref +0x48, refdata.Item.OrgCodeName) is the
//     row it becomes: an empty one answers 2, UseByKind's preset result;
//  5. CGObjPC::MutateItemAt (0x4efb60, IGObj slot 141) looks the name up
//     (FUN_00426760) -- none answers 0 and the use stays at 2 -- and, when its
//     id differs from the item's, sets the item's reference, runs `UPDATE
//     _ITEMS SET REFITEMID = %d WHERE ID64 = %I64d` and sends the owner 0x3040
//     {u8 slot, u8 1, u32 RefItemID} (0x4efc85..0x4efcda). The instance --
//     plus, options, durability -- is the object's and does not change. A
//     name that is the item's own answers 1 with nothing changed.
//
// Item_HandleUseItem (0x510980) spends one tool only on a result of 1, so
// every refusal keeps it; its 0xB04C answer follows UseByKind's 0x3040.
//
// THE PRIVATE SERVER'S TOOLS (OURS). The archive's mall sells other 3/3/13/8
// rows -- avatar, devil's spirit and flag gender switchers, fourteen weapon
// type switchers and the model switchers -- whose effects lived in that
// server's own filter, which OpenSRO does not have. Each is built here to its
// item's own description, on retail's request and with retail's slot rule
// (an equipped target is 0x1882, which the descriptions' "unequip it first"
// asks for too). Every counterpart is an archive row found by its code name
// and checked by its TypeIDs; a target with none is refused and the tool
// kept. The other private-server 3/3/13/8 rows (ITEM_MODELSWITCHER_*,
// *_UNLOCK, ITEM_UPGRADESTONE_*, the two shield switchers) are not sold by
// the mall and are refused as before.

import (
	"context"
	"encoding/binary"
	"fmt"
	"log/slog"
	"math"
	"regexp"
	"strconv"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// switchToolTypeID4 is the tools' TypeID4 under 3/3/13 (UseByKind's
// `*puVar8 >> 0xb` case 8).
const switchToolTypeID4 = 8

// The case's codes (READ, UseByKind case 8; names docs/protocol/error_codes.md).
const (
	SwitchErrEquipped uint16 = 0x1882 // UIIT_MSG_STRGERR_CANT_MUTATE_EQUIPED_ITEM
	SwitchErrDegree   uint16 = 0x1883 // UIIT_MSG_STRGERR_CANT_MUTATE_SINCE_EQUIP_CLASS_TOO_HIGH
	SwitchErrTarget   uint16 = 0x1884 // UIIT_MSG_STRGERR_INVALID_TRANSGENDER_TARGET
	// SwitchErrFailed is UseByKind's preset result (`*param_3 = 2`), which
	// stands when the target has no OrgObjCodeName or MutateItemAt fails.
	SwitchErrFailed uint16 = 2
)

// itemFieldRefID is 0x3040's mask 1: a u32 RefItemID follows (READ,
// MutateItemAt 0x4efc9c..0x4efcca: u8 slot, u8 1, u32 the new id).
const itemFieldRefID = 0x01

// isSwitchTool reports TypeID 3/3/13/8.
func isSwitchTool(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 13 && it.TypeID4 == switchToolTypeID4
}

// switchKind is which tool a 3/3/13/8 row is, by its code name.
type switchKind int

const (
	switchRetailGender switchKind = iota // UseByKind case 8 itself
	switchAvatarGender                   // ITEM_AVATAR_SWITCHER (OURS)
	switchSpiritGender                   // ITEM_DEVIL_SWITCHER (OURS)
	switchFlagGender                     // ITEM_GDF_SWITCHER (OURS)
	switchWeaponType                     // ITEM_<race>_<type>_SWITCHER (OURS)
	switchModel                          // ITEM_MODEL_NN (OURS)
	switchUnsupported                    // a private-server row the mall does not sell
)

// switchTool is one tool's kind and, for a type switcher, the weapon it makes
// and, for a model switcher, the degree whose shape it gives.
type switchTool struct {
	kind    switchKind
	race    string // "CH" or "EU"
	weapon  string // the code-name token: SWORD, TBLADE, DARKSTAFF ...
	typeID4 int    // the weapon's TypeID4 under 3/1/6
	degree  int    // 1..16; 11 is the Default switcher
}

// weaponTypeIDs is each switcher's weapon: its code-name token and TypeID4
// under 3/1/6 (MEASURED on the archive's D11 rows: CH sword 2, blade 3, spear
// 4, glaive 5, bow 6; EU sword 7, two-handed sword 8, axe 9, dark staff 10,
// two-handed staff 11, crossbow 12, dagger 13, harp 14, staff 15).
var weaponTypeIDs = map[string]int{
	"CH_SWORD": 2, "CH_BLADE": 3, "CH_SPEAR": 4, "CH_TBLADE": 5, "CH_BOW": 6,
	"EU_SWORD": 7, "EU_TSWORD": 8, "EU_AXE": 9, "EU_DARKSTAFF": 10, "EU_TSTAFF": 11,
	"EU_CROSSBOW": 12, "EU_DAGGER": 13, "EU_HARP": 14, "EU_STAFF": 15,
}

// The model switchers' degrees: ITEM_MODEL_01..16 (the mall's; ITEM_MODEL_11
// is "Model Switcher (Default [D11])").
const (
	modelDegreeMin     = 1
	modelDegreeMax     = 16
	modelDegreeDefault = 11
)

var (
	modelToolCode  = regexp.MustCompile(`^ITEM_MODEL_(\d\d)$`)
	weaponToolCode = regexp.MustCompile(`^ITEM_(CH|EU)_([A-Z]+)_SWITCHER$`)
	// egyACode is an "Egy A" weapon's code: a degree-11 Egyptian set A row,
	// sealed or not (MEASURED: the 32 rows whose description key is
	// SN_ITEM_EGYA_TT_DESC are exactly these over the 14 weapons and the 2
	// shields; the shields are not weapons).
	egyACode = regexp.MustCompile(`^ITEM_(CH|EU)_([A-Z]+)_11_SET_A(_RARE)?$`)
	// switchRowCode is an archive model twin's code: the base's own code and
	// _SWITCHnn.
	switchRowCode = regexp.MustCompile(`^(.+)_SWITCH(\d\d)$`)
)

// switchToolOf names a 3/3/13/8 row's tool by its code name.
func switchToolOf(code string) switchTool {
	switch code {
	case "ITEM_AVATAR_SWITCHER":
		return switchTool{kind: switchAvatarGender}
	case "ITEM_DEVIL_SWITCHER":
		return switchTool{kind: switchSpiritGender}
	case "ITEM_GDF_SWITCHER":
		return switchTool{kind: switchFlagGender}
	}
	if m := modelToolCode.FindStringSubmatch(code); m != nil {
		n, _ := strconv.Atoi(m[1])
		if n >= modelDegreeMin && n <= modelDegreeMax {
			return switchTool{kind: switchModel, degree: n}
		}
		return switchTool{kind: switchUnsupported}
	}
	if m := weaponToolCode.FindStringSubmatch(code); m != nil {
		if t4, ok := weaponTypeIDs[m[1]+"_"+m[2]]; ok {
			return switchTool{kind: switchWeaponType, race: m[1], weapon: m[2], typeID4: t4}
		}
		return switchTool{kind: switchUnsupported}
	}
	if strings.HasPrefix(code, "ITEM_MODELSWITCHER_") || strings.HasPrefix(code, "ITEM_UPGRADESTONE_") ||
		strings.HasSuffix(code, "_UNLOCK") || strings.HasSuffix(code, "_SWITCHER") {
		return switchTool{kind: switchUnsupported}
	}
	return switchTool{kind: switchRetailGender}
}

// itemDegree is FUN_004775a0 (READ): the ItemClass byte, (c - 1) / 3 + 1 for
// equipment, the byte itself for anything else, 0 for 0.
func itemDegree(it *refdata.Item) int {
	c := it.ItemClass & 0xff
	if c == 0 {
		return 0
	}
	if isEquipment(it) {
		return (c-1)/3 + 1
	}
	return c
}

// isArmourItem is CGObj::IsArmor (FUN_00488eb0, READ): equipment whose
// TypeID3 is 1, 2, 3, 9, 10 or 11 -- the six garments, China and Europe.
func isArmourItem(it *refdata.Item) bool {
	if !isEquipment(it) {
		return false
	}
	switch it.TypeID3 {
	case 1, 2, 3, 9, 10, 11:
		return true
	}
	return false
}

// sameTypeIDs reports whether two rows share TypeID1..4.
func sameTypeIDs(a, b *refdata.Item) bool {
	return a.TypeID1 == b.TypeID1 && a.TypeID2 == b.TypeID2 && a.TypeID3 == b.TypeID3 && a.TypeID4 == b.TypeID4
}

// The gender tokens a code name carries (MEASURED over the archive's avatars,
// devil's spirits and flags: ITEM_MALL_AVATAR_M_x / _W_x, ITEM_ETC_x_M / _F,
// ITEM_EVENT_x_M / _W). Every row with a twin has exactly one by these swaps,
// and the eight that also name one in OrgObjCodeName name the same.
var (
	genderInfix  = [][2]string{{"_M_", "_W_"}, {"_M_", "_F_"}, {"_W_", "_M_"}, {"_F_", "_M_"}}
	genderSuffix = [][2]string{{"_M", "_F"}, {"_M", "_W"}, {"_F", "_M"}, {"_W", "_M"}}
)

// genderTwinCodes is every code a token swap of code makes.
func genderTwinCodes(code string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(c string) {
		if c != code && !seen[c] {
			seen[c] = true
			out = append(out, c)
		}
	}
	for _, sw := range genderInfix {
		for i := strings.Index(code, sw[0]); i >= 0; {
			add(code[:i] + sw[1] + code[i+len(sw[0]):])
			j := strings.Index(code[i+1:], sw[0])
			if j < 0 {
				break
			}
			i += 1 + j
		}
	}
	for _, sw := range genderSuffix {
		if strings.HasSuffix(code, sw[0]) {
			add(strings.TrimSuffix(code, sw[0]) + sw[1])
		}
	}
	return out
}

// genderTwin is the row of the other gender that is it's twin: one of its
// code's token swaps that exists with the same TypeIDs and the other
// ReqGender (1 a man's, 0 a woman's). nil when none, or when it is for
// either gender.
func genderTwin(ctx context.Context, byCode itemByCode, it *refdata.Item) *refdata.Item {
	if it.ReqGender != 0 && it.ReqGender != 1 {
		return nil
	}
	var found *refdata.Item
	for _, c := range genderTwinCodes(it.CodeName) {
		twin, err := byCode.GetItemByCode(ctx, c)
		if err != nil || twin == nil || !sameTypeIDs(twin, it) || twin.ReqGender != 1-it.ReqGender {
			continue
		}
		if found != nil && found.ID != twin.ID {
			return nil // two candidates: none is THE twin
		}
		found = twin
	}
	return found
}

// switchPlan is what one use will do to its target.
type switchPlan struct {
	newItem int64 // the target's item id afterwards
	inst    inventory.Instance
	what    string // for the log
}

// switchRefusal is a refused use: a retail code (0 for none) and the words.
type switchRefusal struct {
	code uint16
	why  string
}

func (r *switchRefusal) Error() string { return r.why }

func refuseSwitch(code uint16, why string) (switchPlan, *switchRefusal) {
	return switchPlan{}, &switchRefusal{code: code, why: why}
}

// planSwitch decides what tool t does to the bag item tgt (whose row is
// tgtIt), or why it does nothing.
func planSwitch(ctx context.Context, items ItemLookup, byCode itemByCode, tool *refdata.Item, t switchTool, tgt inventory.Slot, tgtIt *refdata.Item) (switchPlan, *switchRefusal) {
	inst := tgt.Instance()
	switch t.kind {
	case switchRetailGender:
		if !isArmourItem(tgtIt) {
			return refuseSwitch(SwitchErrTarget, "that item cannot change gender")
		}
		if int64(tool.Param1) < int64(itemDegree(tgtIt)) {
			return refuseSwitch(SwitchErrDegree, "that item's degree is too high for this tool")
		}
		if tgtIt.OrgCodeName == "" {
			// An items import from before the column (round 838) has no
			// OrgObjCodeName; the code's gender swap stands in (OURS). Over
			// the archive's 5,916 armour rows that name one, the swap finds
			// the same row for 5,832 (MEASURED); the other 84 are _ACTIVE rare
			// rows whose name is the other gender's plain row, where the swap
			// keeps _ACTIVE.
			if twin := genderTwin(ctx, byCode, tgtIt); twin != nil {
				return switchPlan{newItem: twin.ID, inst: inst, what: "gender (code swap " + twin.CodeName + ")"}, nil
			}
			return refuseSwitch(SwitchErrFailed, "that item has no counterpart of the other gender")
		}
		twin, err := byCode.GetItemByCode(ctx, tgtIt.OrgCodeName)
		if err != nil || twin == nil {
			return refuseSwitch(SwitchErrFailed, "that item has no counterpart of the other gender")
		}
		return switchPlan{newItem: twin.ID, inst: inst, what: "gender (OrgObjCodeName " + twin.CodeName + ")"}, nil
	case switchAvatarGender, switchSpiritGender, switchFlagGender:
		if !genderToolTakes(t.kind, tgtIt) {
			return refuseSwitch(0, genderToolWrongTarget[t.kind])
		}
		twin := genderTwin(ctx, byCode, tgtIt)
		if twin == nil {
			return refuseSwitch(0, "that item has no version for the other gender")
		}
		return switchPlan{newItem: twin.ID, inst: inst, what: "gender " + twin.CodeName}, nil
	case switchWeaponType:
		return planWeaponType(ctx, items, byCode, t, tgt, tgtIt, inst)
	case switchModel:
		return planModel(ctx, items, byCode, t, tgt, tgtIt, inst)
	}
	return refuseSwitch(0, "that cannot be used")
}

// genderToolTakes is each OURS gender switcher's targets, from its
// description: the avatar switcher "avatars & their hats or accessories" --
// the dress, hat and attachment, 3/1/13/2, /1, /3; the devil's spirit
// switcher "Devil's Spirits or Angel's Spirits" -- 3/1/14/1, the 26 Nasrun
// and Amalrun rows (A, B and S grade); the flag switcher "Flags!" -- 3/1/13/4,
// the Gold Dragon and Divine Flags and the ensigns.
func genderToolTakes(k switchKind, it *refdata.Item) bool {
	if !isEquipment(it) {
		return false
	}
	switch k {
	case switchAvatarGender:
		return it.TypeID3 == 13 && (it.TypeID4 == 1 || it.TypeID4 == 2 || it.TypeID4 == 3)
	case switchSpiritGender:
		return it.TypeID3 == 14 && it.TypeID4 == 1
	case switchFlagGender:
		return it.TypeID3 == 13 && it.TypeID4 == 4
	}
	return false
}

// genderToolWrongTarget is each switcher's refusal of another kind of item,
// in its description's words ("Attempted usage on any other type of object or
// item will result in an error!").
var genderToolWrongTarget = map[switchKind]string{
	switchAvatarGender: "This item can only be used on avatars and their hats or accessories.",
	switchSpiritGender: "This item can only be used on Devil's Spirits or Angel's Spirits.",
	switchFlagGender:   "This item can only be used on flags.",
}

// planWeaponType is a type switcher on an "Egy A" weapon (its description's
// Restriction): the same row of the chosen weapon -- same race prefix rule,
// degree 11, Egyptian set A, sealed when the item is -- keeping the plus,
// the blue options, the variance and the advanced elixir, its durability
// scaled to the new maximum, and a model switcher's choice moved to the new
// weapon's twin of the same degree (cleared when it has none).
func planWeaponType(ctx context.Context, items ItemLookup, byCode itemByCode, t switchTool, tgt inventory.Slot, tgtIt *refdata.Item, inst inventory.Instance) (switchPlan, *switchRefusal) {
	m := egyACode.FindStringSubmatch(tgtIt.CodeName)
	if m == nil || !isEquipment(tgtIt) || tgtIt.TypeID3 != equipment.FamilyWeapon {
		return refuseSwitch(0, "This scroll works only on Egy A weapons.")
	}
	if m[1] == t.race && m[2] == t.weapon {
		return refuseSwitch(0, "That weapon is already of that type.")
	}
	code := "ITEM_" + t.race + "_" + t.weapon + "_11_SET_A" + m[3]
	row, err := byCode.GetItemByCode(ctx, code)
	if err != nil || row == nil || !isEquipment(row) || row.TypeID3 != equipment.FamilyWeapon ||
		row.TypeID4 != t.typeID4 || row.ItemClass != tgtIt.ItemClass {
		return refuseSwitch(0, "There is no weapon of that type for that item.")
	}
	inst.Durability = scaledDurability(inst.Variance, inst.Durability, tgtIt, row)
	if inst.Model != 0 {
		inst.Model = remappedModel(ctx, items, byCode, inst.Model, row.CodeName)
	}
	return switchPlan{newItem: row.ID, inst: inst, what: "type " + row.CodeName}, nil
}

// scaledDurability keeps the durability's share of its maximum on the new
// row (both maxima from the same variance, durability.MaxDurability),
// rounded; untracked and broken stay what they are.
func scaledDurability(variance uint64, dur int, from, to *refdata.Item) int {
	if dur <= 0 {
		return dur
	}
	oldMax := durability.MaxDurability(from.DurabilityMin, from.DurabilityMax, variance)
	newMax := durability.MaxDurability(to.DurabilityMin, to.DurabilityMax, variance)
	if oldMax <= 0 || newMax <= 0 {
		return dur
	}
	n := int(math.Round(float64(dur) * float64(newMax) / float64(oldMax)))
	return max(0, min(n, newMax))
}

// remappedModel is model (a _SWITCHnn row) for the new base code: that
// code's own _SWITCHnn, or 0 when it has none.
func remappedModel(ctx context.Context, items ItemLookup, byCode itemByCode, model int64, newBase string) int64 {
	row, err := items.GetItem(ctx, model)
	if err != nil || row == nil {
		return 0
	}
	m := switchRowCode.FindStringSubmatch(row.CodeName)
	if m == nil {
		return 0
	}
	twin, err := byCode.GetItemByCode(ctx, newBase+"_SWITCH"+m[2])
	if err != nil || twin == nil {
		return 0
	}
	return twin.ID
}

// planModel is a model switcher: the item keeps its own row and every stat
// ("VISUAL modifications ONLY!") and is drawn with the model of the archive's
// twin row <its code>_SWITCHnn (inventory.Instance.Model). The Default
// switcher (degree 11) gives the item its own model back. Its description's
// IMPORTANT line: degree 11 only. The archive's twins exist for the degree-11
// A-grade weapons and shields -- plain, sealed and the Egyptian sets A and B
// sealed -- and an unlocked _ACTIVE row draws with its locked row's twins
// (OURS: the two rows differ in their requirement, not their model -- the
// census in docs/protocol/equip_glow_seal.md).
func planModel(ctx context.Context, items ItemLookup, byCode itemByCode, t switchTool, tgt inventory.Slot, tgtIt *refdata.Item, inst inventory.Instance) (switchPlan, *switchRefusal) {
	if !isEquipment(tgtIt) || (tgtIt.TypeID3 != equipment.FamilyWeapon && tgtIt.TypeID3 != equipment.FamilyShield) {
		return refuseSwitch(0, "Model Switchers can only be used on weapons and shields.")
	}
	if itemDegree(tgtIt) != modelDegreeDefault {
		return refuseSwitch(0, "Model Switchers can only be used on Degree 11 items.")
	}
	if t.degree == modelDegreeDefault {
		if inst.Model == 0 {
			return refuseSwitch(0, "That item already has its original model.")
		}
		inst.Model = 0
		return switchPlan{newItem: tgt.ItemID, inst: inst, what: "model default"}, nil
	}
	suffix := fmt.Sprintf("_SWITCH%02d", t.degree)
	row, err := byCode.GetItemByCode(ctx, tgtIt.CodeName+suffix)
	if (err != nil || row == nil) && strings.HasSuffix(tgtIt.CodeName, "_ACTIVE") {
		row, err = byCode.GetItemByCode(ctx, strings.TrimSuffix(tgtIt.CodeName, "_ACTIVE")+suffix)
	}
	if err != nil || row == nil || !sameTypeIDs(row, tgtIt) {
		return refuseSwitch(0, fmt.Sprintf("That item has no model of degree %d.", t.degree))
	}
	if inst.Model == row.ID {
		return refuseSwitch(0, "That item already has that model.")
	}
	inst.Model = row.ID
	return switchPlan{newItem: tgt.ItemID, inst: inst, what: "model " + row.CodeName}, nil
}

// ItemRefField is 0x3040 {u8 slot + 13, u8 1, u32 RefItemID}: the bag item
// at slot is now another item (READ, MutateItemAt 0x4efc85).
func ItemRefField(slot int, ref uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{byte(slot + AlchemyFirstBagSlot), itemFieldRefID}, ref)
}

// useSwitchTool is a 3/3/13/8 tool's use on the bag item at the wire slot
// target. One tool is spent only when the target changed.
func useSwitchTool(ctx context.Context, sess *gateway.Session, inv inventory.Store, items ItemLookup, characterID int64, held inventory.Slot, have int, tool *refdata.Item, target byte) error {
	refuse := func(code uint16, why string) error {
		return sendUseResult(sess, &UseItemResult{Error: why, Code: code, Remaining: int32(have)})
	}
	t := switchToolOf(tool.CodeName)
	if t.kind == switchUnsupported {
		return refuse(0, "that cannot be used")
	}
	// UseByKind case 8: `(byte)(b - 0xd) < 99`, else 0x1882.
	if target < AlchemyFirstBagSlot || target > AlchemyLastBagSlot {
		return refuse(SwitchErrEquipped, "it cannot be used on an equipped item")
	}
	byCode, ok := items.(itemByCode)
	mut, okMut := inv.(inventory.Mutator)
	if !ok || !okMut {
		return refuse(0, "that cannot be used")
	}
	idx := int(target) - AlchemyFirstBagSlot
	var plan switchPlan
	var before int64
	var refused *switchRefusal
	err := txn.For(inv).Run(ctx, func(ctx context.Context) error {
		plan, refused = switchPlan{}, nil
		bag, err := inv.List(ctx, characterID)
		if err != nil {
			return err
		}
		var tgt *inventory.Slot
		toolHere := false
		for i := range bag {
			if bag[i].Index == idx {
				tgt = &bag[i]
			}
			if bag[i].Index == held.Index && bag[i].ItemID == held.ItemID && bag[i].Quantity >= 1 {
				toolHere = true
			}
		}
		if !toolHere {
			refused = &switchRefusal{why: "nothing there"}
			return nil
		}
		if tgt == nil {
			refused = &switchRefusal{code: SwitchErrTarget, why: "there is no item there"}
			return nil
		}
		tgtIt, err := items.GetItem(ctx, tgt.ItemID)
		if err != nil || tgtIt == nil {
			refused = &switchRefusal{code: SwitchErrTarget, why: "nothing known about that item"}
			return nil
		}
		plan, refused = planSwitch(ctx, items, byCode, tool, t, *tgt, tgtIt)
		if refused != nil {
			return nil
		}
		before = tgt.ItemID
		if plan.newItem != tgt.ItemID {
			err = mut.MutateItem(ctx, characterID, idx, tgt.ItemID, plan.newItem, plan.inst)
		} else {
			err = inv.SetInstance(ctx, characterID, idx, plan.inst)
		}
		if err != nil {
			return err
		}
		return inv.RemoveItem(ctx, characterID, held.Index, 1)
	})
	if err != nil {
		slog.Warn("switch: the use failed", "character_id", characterID, "tool", tool.CodeName, "err", err)
		return refuse(0, "using failed")
	}
	if refused != nil {
		return refuse(refused.code, refused.why)
	}
	slog.Info("switch: item changed", "character_id", characterID, "tool", tool.CodeName, "slot", idx,
		"from", before, "to", plan.newItem, "model", plan.inst.Model, "what", plan.what)
	if plan.newItem != before {
		_ = sess.Send(&proto.Packet{Opcode: cos.OpItemState, Data: ItemRefField(idx, uint32(plan.newItem))})
	}
	return sendUseResult(sess, &UseItemResult{Remaining: int32(have - 1), ItemID: uint32(tool.ID)})
}
