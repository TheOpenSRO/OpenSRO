// Command export-refdata turns a client's own itemdata text tables (the
// Media.pk2 `server_dep\silkroad\textdata\itemdata*.txt` files, which are
// the game's _RefObjItem table dumped tab-separated) into the headerless
// CSV that import-refdata loads. No game data ships with this tool or the
// repo -- the operator points it at their own extracted tables, exactly as
// the client is pointed at their own pk2.
//
//	export-refdata -out items.csv itemdata_1000.txt itemdata_5000.txt ...
//	import-refdata -items-csv items.csv -postgres-dsn ...
//
// Column mapping. The itemdata fields are 0-indexed here (field 0 is the
// leading "service" column, field 1 the id). Each mapping below is either
// measured against real rows and, where a ground truth existed, verified,
// or left at an honest default when this project has not established the
// column yet -- never a guess dressed as data. The verification: a real
// Copper Sword (+5) tooltip a player sent reads exactly the physical
// attack (field 96/98, base 15/16), magical attack (101/103, 25/28),
// durability (64/65, 62/76), attack rate (114) and critical (117) these
// columns hold; the attack columns are the same for the bow and spear.
// See docs/protocol/ITEM_FORMAT.md and WORLD_ISSUES.md.
//
// MaxStack is real, from column 57: 1 for every one of the 8,616 equipment
// rows (TypeID2=1) and a real per-item cap for the stackables (an alchemy
// stone 500, a potion 5,000, arrows 2,500), which is exactly how a MaxStack
// column behaves. An earlier note here defaulted it to 1 "because it is 1 for
// every row" -- that was reading the wrong thing; the real column makes
// potions and materials stack instead of filling a slot each. Physical/magical
// DEFENCE is 0: armour
// stores its defence in different columns than a weapon's attack, and this
// project has no ground-truth armour tooltip to label them, so rather than
// guess they are left empty -- combat does not read defence, and the only
// effect is that the shop prices armour at its base price. ItemClass and
// TwoHanded are 0/false, no worse than the "unknown item" the server sees
// today. When an armour tooltip or the _RefObjItem schema pins the rest,
// fill these in here.
package main

import (
	"bufio"
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"unicode/utf16"

	"github.com/OpenSRO/srrevamp/server/internal/skillparam"
)

// Field indices into a tab-split itemdata row (0-indexed; field 0 is the
// leading service column).
const (
	fID      = 1
	fTypeID1 = 9 // TypeID1..4 run 9..12
	fCountry = 14
	// MaxStack: 1 for all equipment, a real cap for stackables (col 57).
	//
	// CONTESTED 2026-09-16 AND RESOLVED THE SAME DAY. The conflict was real
	// but it was between two FORMATS, not two readings.
	//
	// The server does not parse these text files. It parses a BINARY record
	// (4-byte fields, 2-byte length-prefixed strings) whose last common field,
	// `_RefObjCommon+0x184`, every ExtractData override asserts non-zero and
	// passes to a lookup logging "Can't find associated item data
	// [RefObjCommon ID: %d, RefItem ID: %d]". That lookup
	// (CGameServer::FUN_006ba850) scans a list of row-streams and compares the
	// key against each candidate's FIRST 4-byte field, so it is a per-row
	// foreign key -- the binary common record ends with a link to the
	// type-specific record.
	//
	// The client's text table is the DENORMALISED JOIN of the two, and it does
	// not carry that link: no itemdata column is per-row unique, and
	// characterdata's only unique columns are 1 and 2 (ID and code name). So
	// binary field 57 and text column 57 are simply different fields at the
	// same index, and reading text column 57 as MaxStack -- 18 distinct values
	// shaped 1 / 250 / 500 / 50 -- is correct.
	//
	// See docs/protocol/refobj_binary_format.md.
	fMaxStack = 57
	// Real NPC vendor prices: _RefObjCommon Price (buy) and SellPrice
	// (buy-back). Confirmed against real rows -- SellPrice < Price on every
	// item checked, potions carry a Price with 0 CostRepair, weapons carry
	// both -- and pinned by fReqLevelType1=32 lining up (ItemTableReader reads
	// the same column). See docs/protocol/refdata_schema.md.
	fPrice     = 26
	fSellPrice = 31
	// fRepairCost is the item's FULL-REPAIR cost in gold -- see
	// refdata.Item.RepairCost for the engine arithmetic that identifies it.
	fRepairCost = 28
	// The Param block stores a value beside its own label: 118 "HP...",
	// 120 "HP...(%)", 122 "MP...", 124 "MP...(%)". Potion restore amounts.
	fRestoreHP    = 118
	fRestoreHPPct = 120
	fRestoreMP    = 122
	fRestoreMPPct = 124
	// The four requirement slots. _RefObjCommon holds them as four
	// (int32 type, uint8 value) pairs at +0xb4 and +0xb8, stride 8, and
	// RefObjCommon_ExtractData fills them from columns 32..39 in a
	// four-iteration loop (0x6a36ab..0x6a3700, trip count from
	// `mov eax,0x4`). CGItemEquip::CheckEquipRequirements (0x004919e0)
	// walks all four and asserts on a slot index above 3, which is where
	// the count of four comes from rather than from the column layout.
	//
	// Only slot 1 was exported before, which is right for 11,636 of 23,327
	// real rows (the ones whose only requirement is a character level) but
	// silently drops every requirement in the other slots.
	fReqLevelType1 = 32
	fReqLevel1     = 33
	fReqLevelType2 = 34
	fReqLevel2     = 35
	fReqLevelType3 = 36
	fReqLevel3     = 37
	fReqLevelType4 = 38
	fReqLevel4     = 39
	fReqGender     = 58
	fReqStr        = 59
	fReqInt        = 60
	fDurabilityMin = 63 // and 64 for max
	fPhysAttackMin = 95 // and 97 for max (96/98 one-indexed)
	fPhysAttackMax = 97
	fMagAttackMin  = 100
	fMagAttackMax  = 102
	// A weapon's REINFORCE percentages, in tenths of a percent (306 = 30.6%),
	// laid out with the same (n, n+2) spacing as the attack pair above: n and
	// n+2 are the min's and max's low end, n+1 and n+3 their per-instance
	// variance high end, and 99/104 the per-plus increments the engine reads
	// as the `inc` of each (lo, hi, inc) triple (FUN_00495d60 computes an
	// item's actual stat as lo + t*(hi-lo) + inc*plus, and asserts lo < hi).
	//
	// Pinned by the engine, not by position: GObjPC_InitStats writes each
	// param's innate default from .rdata -- 30.6 (param 34), 34.2 (36), 49.0
	// (35), 54.8 (37) -- and 306/342/490/548 are exactly the minima of columns
	// 105/107/109/111 across all 1,568 weapon rows. Four constants, four
	// column floors.
	//
	// srrevamp models no per-instance variance and no plus level, so it takes
	// the low end, which is also the end the innate defaults correspond to.
	fReinforcePhysMin = 105 // and 107 for max
	fReinforcePhysMax = 107
	fReinforceMagMin  = 109 // and 111 for max
	fReinforceMagMax  = 111
	fHitRate          = 113
	fCritical         = 116
	// Armour defence and the shield's block ratio, all verified against real
	// +5 tooltips in docs/protocol/ITEM_FORMAT.md: a Cotton garment reads
	// 2~2.5 physical and 4.3~5.2 magical, a starter shield 10~20 block. Each
	// is a TRIPLE (min, max, a per-tier third value), so max is +1.
	//
	// These were exported as literal "0" until 2026-09-15, marked "armour,
	// not verified" -- a note that stopped being true when ITEM_FORMAT.md
	// grounded the columns three ways and was never revisited. Every
	// deployment importing through this tool therefore gave armour no
	// defence at all.
	// Whether the weapon needs both hands -- a clean 0/1 that is CONSTANT
	// within every weapon kind (TypeID4) and 0 on all 511 shield rows.
	//
	// Identified by diffing a known one-hander against a known two-hander and
	// then cross-checked against a source that knows nothing about this
	// table: the CLIENT's own weapon-to-animation-group switch, recovered in
	// docs/WORLD_ISSUES.md's hundred-and-thirty-third round, names five kinds
	// explicitly -- 7 `onehand_sword`, 10 and 15 `onehand_staff`, 8
	// `twohand_sword`, 11 `twohand_staff`. This column reads 0 for all three
	// "onehand" kinds and 1 for both "twohand" kinds. Five for five, from a
	// different binary recovered by a different route.
	// ItemClass, the item's own class/degree byte. Column 61.
	//
	// Derived from the ORDER of the server's own deserialiser rather than by
	// pattern-matching the data: RefObjItem::ExtractData reads its fields
	// consecutively off the row -- +0x198 (4 bytes), +0x19c (1), +0x1a0 (4),
	// +0x1a4 (4), +0x1a8 (1) -- and +0x19c is confirmed as ReqGender by
	// CGPCInventoryOP::CheckEquipsetIntegrity, which compares it against the
	// character's GetGender(). This exporter already maps 57/58/59/60 to
	// MaxStack/ReqGender/ReqStr/ReqInt, exactly those four in exactly that
	// order, so the next field is column 61 -- and it is a 1-byte read, which
	// matches m_btItemClass.
	//
	// Checked against the binary's own assertion rather than against a curve:
	// ExtractData asserts "ItemClass must be not zero" / "m_btItemClass > 0",
	// and column 61 is non-zero on all 21,552 equipment rows. Its values are
	// small (1..14+), and one family's tiers walk it 1, 4, 7, 10, 13.
	fItemClass = 61
	// SetID, the item set this piece belongs to. Column 62, and the field
	// RefObjItem::vslot_001 writes at +0x1ac immediately after ItemClass's
	// +0x1a8 -- the same consecutive march that pinned 57..61.
	//
	// The use-site names it: CSetMagicOptionOP::PutoutTheBindingItem reads
	// `*(item[0xd] + 0x18) + 0x1ac` and logs it as
	// `"## %s %d ## Invalid data is used! [SetID:%d]"`. Cross-checked against
	// the data by joining to `refsetitemgroup.txt`: the race and gender in an
	// item's code name match its set's code name on 360 of 360 rows that spell
	// both, where the other columns holding only legal set ids score ~25%.
	fSetID = 62
	// The capability flags. Columns 16, 17 and 19 of _RefObjCommon, recovered by
	// counting RefObjCommon_ExtractData's field reads in the disassembly -- see
	// docs/protocol/item_capability_flags.md. fCanDrop is a BITMASK column
	// (255/128/223/192 in real data); the engine takes its bit 0, so the
	// exporter emits that bit rather than the raw byte.
	fCanTrade       = 16
	fCanSell        = 17
	fCanDrop        = 19
	fTwoHanded      = 93
	fPhysDefenseMin = 65
	fBlockRatio     = 74 // shields only; body armour carries the parry pair at 68
	fMagDefenseMin  = 76
	// The highest field any mapping reads: a row shorter than this is not a
	// real item row and is skipped.
	fMax = 117
)

// Skill (_RefSkill / skilldata_*.txt) raw column indices, 0-based. The
// learn-gating columns AND the cast timing / range / resource cost are named
// and mapped -- all verified against a real SMASH_A row (the column order is
// the schema's group order, anchored by 6 known indices; see the
// skilldata-columns note and docs/protocol/refdata_schema.md). Only a few flag
// columns (FlyingSpeed, Interruptable, Overlap, AutoAttackType) stay unmapped.
const (
	skID         = 1 // unique per-level skill id
	skGroupID    = 2 // shared by every level of the skill
	skBasicCode  = 3 // SKILL_CH_..._NN
	skBasicLevel = 7
	// Cast timing / range / cost, all in ms except Range. Verified against a
	// real SMASH_A row (see the skilldata-columns note): the column order is the
	// schema's group order, anchored by 6 known indices. All clean int values.
	skPreparingTime  = 11
	skCastingTime    = 12
	skActionDuration = 13
	skReuseDelay     = 14 // the cooldown
	skCoolTime       = 15
	skRange          = 21 // 0 = melee
	skConsumeHP      = 52
	skConsumeMP      = 53
	skMastery1       = 34 // ReqCommon_Mastery1
	skMasteryLevel1  = 36 // ReqCommon_MasteryLevel1 (required mastery level)
	// The two required-weapon bytes. The engine names them itself: the
	// skilldata row loader SkillGlobal::FUN_005893e0 refuses a row whose
	// CRefSkill+199/+200 are zero with "ReqWeapon Error [RefSkill ID: %d]",
	// and FUN_0058d480 checks them against the equipped weapon's TID >> 11.
	// 0xff (255) marks an unused slot; both 0xff means no requirement.
	skReqCastWeapon1 = 50
	skReqCastWeapon2 = 51
	skReqLearnSP     = 46 // ReqLearn_SP (learn cost, verified 2/5/7 across SMASH_A 1-3)
	skReqLearnRace   = 47 // ReqLearn_Race
	skName           = 62 // SN_SKILL_ name code
	// The highest field skillRecord reads; a shorter row isn't a real skill.
	skMax = 62
)

func main() {
	out := flag.String("out", "-", "output CSV path, or - for stdout")
	mode := flag.String("mode", "items", "which reference table the input files are: items or skills")
	flag.Parse()
	if flag.NArg() == 0 || (*mode != "items" && *mode != "skills") {
		fmt.Fprintln(os.Stderr, "usage: export-refdata [-mode items|skills] -out out.csv <data_*.txt> ...")
		os.Exit(2)
	}
	record, noun := itemRecord, "item"
	if *mode == "skills" {
		record, noun = skillRecord, "skill"
	}

	var sink *os.File
	if *out == "-" {
		sink = os.Stdout
	} else {
		f, err := os.Create(*out)
		if err != nil {
			fmt.Fprintf(os.Stderr, "creating %s: %v\n", *out, err)
			os.Exit(1)
		}
		defer f.Close()
		sink = f
	}
	w := csv.NewWriter(sink)
	defer w.Flush()

	// The client's itemdata shards OVERLAP. Measured 2026-09-16 over a real
	// client's tables: 6,224 of 15,338 item ids appear in more than one shard,
	// and 608 of those carry genuinely different values -- itemdata_1000.txt
	// and itemdata_5000.txt disagree on shield defence (1.3 against 1.25),
	// which is an older copy of the table sitting beside a newer one.
	//
	// Streaming every row straight out would put both copies in the CSV and
	// leave which one reaches the database up to the importer's upsert order,
	// i.e. up to the order the operator's shell happened to glob the files in.
	// So rows are collected keyed by id, LAST occurrence wins (the same rule
	// the upsert follows, now made explicit rather than accidental), and the
	// operator is told what collided.
	written, skipped, dupes, conflicts := 0, 0, 0, 0
	order := []string{}
	byID := map[string][]string{}
	for _, path := range flag.Args() {
		rows, err := readTable(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "reading %s: %v\n", path, err)
			os.Exit(1)
		}
		for _, cols := range rows {
			rec, ok := record(cols)
			if !ok {
				skipped++
				continue
			}
			id := rec[0]
			if prev, seen := byID[id]; seen {
				dupes++
				if !sameRecord(prev, rec) {
					conflicts++
				}
			} else {
				order = append(order, id)
			}
			byID[id] = rec
		}
	}
	for _, id := range order {
		if err := w.Write(byID[id]); err != nil {
			fmt.Fprintf(os.Stderr, "writing: %v\n", err)
			os.Exit(1)
		}
		written++
	}
	w.Flush()
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d %s rows, skipped %d non-%s rows\n", written, noun, skipped, noun)
	if dupes > 0 {
		fmt.Fprintf(os.Stderr, "export-refdata: %d duplicate ids across the input files, %d of them with CONFLICTING values; kept the last occurrence of each\n", dupes, conflicts)
	}
}

// sameRecord reports whether two CSV records are equal field for field, with
// numbers compared as numbers. The shards disagree on formatting far more often
// than on substance -- the same value appears as "0" in one table and "0.0" in
// another -- and reporting those as conflicts would bury the 608 that matter in
// thousands that do not.
func sameRecord(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] == b[i] {
			continue
		}
		x, errX := strconv.ParseFloat(a[i], 64)
		y, errY := strconv.ParseFloat(b[i], 64)
		if errX != nil || errY != nil || x != y {
			return false
		}
	}
	return true
}

// itemRecord maps one tab-split itemdata row to the 28-column CSV
// import-refdata expects, or (nil, false) if the row is not a real item.
func itemRecord(cols []string) ([]string, bool) {
	if len(cols) <= fMax {
		return nil, false
	}
	if _, err := strconv.Atoi(strings.TrimSpace(cols[fID])); err != nil {
		return nil, false
	}
	// Bounds-checked: the columns read here run out to the Param block near
	// col 124, and a short or older itemdata row must yield "0" rather than
	// panic the exporter.
	get := func(i int) string {
		if i >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i])
		if s == "" {
			return "0"
		}
		return s
	}
	// A float field: itemdata writes some as "2.4"; keep as-is, default 0.
	num := func(i int) string {
		if i >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i])
		if _, err := strconv.ParseFloat(s, 64); err != nil {
			return "0"
		}
		return s
	}
	// dropBit takes bit 0 of a mask column and emits it as 0/1. The engine reads
	// CanDrop as `mask & 1`, and the column really is a mask -- 255, 128, 223
	// and 192 all occur -- so emitting the raw byte would make every consumer
	// repeat the masking or, worse, treat 255 as a boolean.
	dropBit := func(s string) string {
		n, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil {
			return "0"
		}
		if n&1 != 0 {
			return "1"
		}
		return "0"
	}
	return []string{
		get(fID),                 // 0  ID
		get(fMaxStack),           // 1  MaxStack (col 57: 1 for equipment, real cap for stackables)
		get(fReqStr),             // 2  ReqStr
		get(fReqInt),             // 3  ReqInt
		get(fItemClass),          // 4  ItemClass
		get(fTwoHanded),          // 5  TwoHanded
		num(fDurabilityMin),      // 6  DurabilityMin
		num(fDurabilityMin + 1),  // 7  DurabilityMax
		num(fPhysDefenseMin),     // 8  PhysDefenseMin
		num(fPhysDefenseMin + 1), // 9  PhysDefenseMax
		num(fMagDefenseMin),      // 10 MagDefenseMin
		num(fMagDefenseMin + 1),  // 11 MagDefenseMax
		num(fPhysAttackMin),      // 12 PhysAttackMin
		num(fPhysAttackMax),      // 13 PhysAttackMax
		num(fMagAttackMin),       // 14 MagAttackMin
		num(fMagAttackMax),       // 15 MagAttackMax
		num(fHitRate),            // 16 HitRateMin -- col 113, the verified tooltip value
		// 17 HitRateMax and 19 CriticalMax are REAL after all, restored
		// 2026-09-15. They had been withdrawn and emitted as literal "0" on the
		// argument that a real max would display as a range the way physical
		// attack does ("27 ~ 28"), while the verified Copper Sword tooltip shows
		// "Attack rate 24" and "Critical 3" -- single values.
		//
		// That argument's premise was wrong. Physical attack displays as a range
		// because its min and max are two DIFFERENT stats, at cols 95 and 97, each
		// with its own (lo, hi) variance pair beside it. Attack rate and critical
		// are ONE stat each, and the pair beside them is that stat's per-instance
		// variance -- so an instance has a single value and shows a single number.
		// The tooltip is consistent with both readings; it never discriminated.
		//
		// What settles it is the engine. FUN_00495d60 computes every item stat as
		// `lo + t*(hi-lo) + inc*plus` from a (lo, hi, inc) triple at consecutive
		// ref-object dwords, and two of those triples are (0x288, 0x28c, 0x290) ->
		// item +0x1d8 and (0x294, 0x298, 0x29c) -> item +0x1dc -- the exact fields
		// Char_PublishCombatStats publishes as ParamKeeper params 11 ('hra',
		// attack rate) and 12 ('cri', critical). So each of them IS a lo/hi pair,
		// and the tooltip value is the lo.
		//
		// The data agrees with the engine's own precondition: it asserts that
		// lo > hi is impossible, and across all 1,568 rows carrying the block,
		// col 113 <= col 114 and col 116 <= col 117 with ZERO inversions (448 rows
		// have col 116 == col 117, which the assert permits). Two unrelated stats
		// would invert somewhere.
		num(fHitRate + 1),      // 17 HitRateMax  -- col 114, the variance ceiling
		num(fCritical),         // 18 CriticalMin -- col 116, the verified tooltip value
		num(fCritical + 1),     // 19 CriticalMax -- col 117, the variance ceiling
		get(fTypeID1),          // 20 TypeID1
		get(fTypeID1 + 1),      // 21 TypeID2
		get(fTypeID1 + 2),      // 22 TypeID3
		get(fTypeID1 + 3),      // 23 TypeID4
		get(fCountry),          // 24 Country
		get(fReqGender),        // 25 ReqGender
		get(fReqLevelType1),    // 26 ReqLevelType1
		get(fReqLevel1),        // 27 ReqLevel1
		get(fPrice),            // 28 Price (real NPC buy price)
		get(fSellPrice),        // 29 SellPrice (real NPC buy-back price)
		get(fRestoreHP),        // 30 RestoreHP    (Param block, labelled "HP...")
		get(fRestoreHPPct),     // 31 RestoreHPPct
		get(fRestoreMP),        // 32 RestoreMP    (Param block, labelled "MP...")
		get(fRestoreMPPct),     // 33 RestoreMPPct
		num(fBlockRatio),       // 34 BlockRatioMin (shields only)
		num(fBlockRatio + 1),   // 35 BlockRatioMax
		num(fReinforcePhysMin), // 36 ReinforcePhysMin (weapons only)
		num(fReinforcePhysMax), // 37 ReinforcePhysMax
		num(fReinforceMagMin),  // 38 ReinforceMagMin
		num(fReinforceMagMax),  // 39 ReinforceMagMax
		get(fSetID),            // 40 SetID
		get(fCanTrade),         // 41 CanTrade
		get(fCanSell),          // 42 CanSell
		dropBit(get(fCanDrop)), // 43 CanDrop -- bit 0 of a mask column
		get(fReqLevelType2),    // 44 ReqLevelType2 -- requirement slots 2..4
		get(fReqLevel2),        // 45 ReqLevel2
		get(fReqLevelType3),    // 46 ReqLevelType3
		get(fReqLevel3),        // 47 ReqLevel3
		get(fReqLevelType4),    // 48 ReqLevelType4
		get(fReqLevel4),        // 49 ReqLevel4
		num(fRepairCost),       // 50 RepairCost
	}, true
}

// skillRecord maps one tab-split skilldata row to the 24-column skill CSV
// (refdata.skillCSVColumns order) import-refdata expects, or (nil, false) if
// the row is not a real skill. The learn-gating fields and the cast timing /
// range / resource cost are mapped from verified real columns (see the
// skilldata-columns note); only a few flags (FlyingSpeed, Interruptable,
// Overlap, AutoAttackType) and unused name/chain fields stay "0" placeholders.
func skillRecord(cols []string) ([]string, bool) {
	if len(cols) <= skMax {
		return nil, false
	}
	if _, err := strconv.Atoi(strings.TrimSpace(cols[skID])); err != nil {
		return nil, false
	}
	get := func(i int) string {
		if i >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i])
		if s == "" {
			return "0"
		}
		return s
	}
	atkType, pct, dmgMin, dmgMax := attackParam(cols)
	hits := hitCountParam(cols)
	return []string{
		get(skID),             // 0  ID
		get(skGroupID),        // 1  GroupID
		get(skBasicCode),      // 2  Basic_Code
		"0",                   // 3  Basic_Name (not verified)
		get(skBasicLevel),     // 4  Basic_Level
		"0",                   // 5  Basic_ChainCode (not verified)
		"0",                   // 6  Basic_RecycleCost (not verified)
		get(skPreparingTime),  // 7  PreparingTime  (verified raw col 11)
		get(skCastingTime),    // 8  CastingTime    (verified raw col 12)
		get(skActionDuration), // 9  ActionDuration (verified raw col 13)
		get(skReuseDelay),     // 10 ReuseDelay/cooldown (verified raw col 14)
		get(skCoolTime),       // 11 CoolTime       (verified raw col 15)
		"0",                   // 12 FlyingSpeed (flag, not mapped)
		"0",                   // 13 Interruptable (flag, not mapped)
		"0",                   // 14 Overlap (bitfield, not mapped)
		"0",                   // 15 AutoAttackType (not mapped)
		get(skRange),          // 16 Range          (verified raw col 21)
		get(skConsumeHP),      // 17 Consume_HP     (verified raw col 52)
		get(skConsumeMP),      // 18 Consume_MP     (verified raw col 53)
		get(skReqLearnSP),     // 19 ReqLearn_SP    (verified raw col 46)
		get(skReqLearnRace),   // 20 ReqLearn_Race  (raw col 47)
		get(skName),           // 21 UI_SkillName    (SN_SKILL_ name code, raw col 62)
		get(skMastery1),       // 22 ReqCommon_Mastery1      (verified raw col 34)
		get(skMasteryLevel1),  // 23 ReqCommon_MasteryLevel1 (verified raw col 36)
		pct,                   // 24 AttackPercent -- real, from the 'att' param
		dmgMin,                // 25 DamageMin
		dmgMax,                // 26 DamageMax
		hits,                  // 27 HitCount -- real, from the 'mc' param
		atkType,               // 28 AttackType -- real, 'att' value[0]
		get(skReqCastWeapon1), // 29 ReqCast_Weapon1
		get(skReqCastWeapon2), // 30 ReqCast_Weapon2
		reqItemCount(cols),    // 31 ReqCastListCount -- 'reqi' runs; non-zero disables the weapon gate
		reqItemList(cols),     // 32 ReqCastList -- the 'reqi' records as kind:value;...
		reqAll(cols),          // 33 ReqCastAll -- 'reqn': the list is ALL-of, not ANY-of
		noCombatParam(cols),   // 34 NoCombatParam -- the engine resolves no blow for this skill
		zeroDamage(cols),      // 35 ZeroDamage -- a resolved blow whose damage is zero
		floorBlow(cols),       // 36 FloorBlow -- a computed blow that is identically zero, so always the floor of 1
	}, true
}

// attackCode is the skill parameter tagged 'att', the one that carries a
// skill's damage. Skill parameters live in the row's Param block as
// (code, values...) runs, where a code is a C multi-character literal stored
// as a big-endian integer -- 'att' is 0x00617474 = 6386804. The server's own
// parameter parser reads 'att' as a fixed run of six words (the code plus five
// values), which is how the layout below is known rather than guessed.
const attackCode = "6386804"

// reqItemCode is the skill parameter tagged 'reqi'. Its handler appends into a
// FIVE-SLOT LIST at CRefSkill+0x3a0 (`mov [esi+edx*4+0x3a0],eax` at 00588f79,
// with the slot chosen by scanning for the first zero and capped at 5), and
// that list is what the weapon gate branches on:
//
//	if (skill[0x3a0] == 0) { ...check ReqCastWeapon... }
//	else                   { ...a different check entirely... }
//
// So a skill carrying 'reqi' does NOT have its ReqCastWeapon bytes applied.
// 1,094 real skills carry it, 517 of them alongside a weapon requirement that
// the engine therefore ignores. Let Python compute the constant -- hand-typing
// these has been wrong twice in this project.
const reqItemCode = "1919250793" // 0x72657169

// reqAllCode is the skill parameter tagged 'reqn' (0x7265716e, one `sub edi,5`
// past 'reqi' in the parser's dispatch chain). Its presence sets CRefSkill+0x3b4,
// and FUN_0058d480 reads that field to turn the requirement list from ANY-of
// into ALL-of. 128 real skills carry it against 966 that do not.
const reqAllCode = "1919250798" // 0x7265716e

// hitCountCode is the skill's 'mc' parameter -- 0x6d63, the pair (2, N) where N
// is how many times one cast strikes. See refdata.Skill.HitCount for the
// use-site that settles it as a count rather than a multiplier.
const hitCountCode = "28003"

// paramRuns walks a skilldata row's Param block the way the server's own parser
// does, using the recovered run lengths in internal/skillparam.
//
// WHY THIS EXISTS ALONGSIDE THE SCANS BELOW. Each of those finds a parameter by
// searching the whole row for its code literal, which is a heuristic: nothing
// stops the same integer occurring as some other column's value. The walk has
// no such failure mode -- it starts where the block starts and steps run by run
// -- so it is the primary, and a scan is used only where the walk cannot
// finish.
//
// The two agree today. Walking all 33,632 rows of the seven skilldata shards in
// a real Media.pk2, 32,367 (96.2%) walk end to end and the scans' answers for
// 'att', 'mc' and 'reqi' match the walk's on every one of them -- zero
// disagreements. So this change is not a fix; it replaces an argument that the
// scan is safe with a method that does not need the argument.
//
// The other 1,265 rows stop at a variable-length parameter, whose run length
// the parser genuinely does not state, so the walk cannot pass it. Those fall
// back to the scan, which is what they used before.
func paramRuns(cols []string) (runs []skillparam.Entry, complete bool) {
	if len(cols) <= skillparam.ParamBlockColumn {
		return nil, false
	}
	words := make([]int32, 0, len(cols)-skillparam.ParamBlockColumn)
	for _, v := range cols[skillparam.ParamBlockColumn:] {
		s := strings.TrimSpace(v)
		if s == "" {
			continue
		}
		n, err := strconv.ParseInt(s, 10, 32)
		if err != nil {
			return nil, false
		}
		words = append(words, int32(n))
	}
	runs, _, complete = skillparam.Walk(words)
	return runs, complete
}

// paramWords is a row's Param block as the 32-bit words the parser walks.
func paramWords(cols []string) ([]int32, bool) {
	if len(cols) <= skillparam.ParamBlockColumn {
		return nil, false
	}
	words := make([]int32, 0, len(cols)-skillparam.ParamBlockColumn)
	for _, v := range cols[skillparam.ParamBlockColumn:] {
		s := strings.TrimSpace(v)
		if s == "" {
			continue
		}
		n, err := strconv.ParseInt(s, 10, 32)
		if err != nil {
			return nil, false
		}
		words = append(words, int32(n))
	}
	return words, true
}

// paramFind returns the ROW COLUMN of the first run carrying code.
//
// decided says whether the answer can be trusted on its own. A completed walk
// decides both ways: it either found the run or proved the row has not got one.
// An incomplete walk decides nothing, because the code may sit past where the
// walk stopped, and the caller must fall back rather than read "not found" as
// "the skill has not got it".
func paramFind(cols []string, code skillparam.Code) (col int, found, decided bool) {
	runs, complete := paramRuns(cols)
	for _, r := range runs {
		if r.Code == code {
			return skillparam.ParamBlockColumn + r.Index, true, true
		}
	}
	return 0, false, complete
}

// paramFindAll returns the row columns of every run carrying code, for the
// parameters the engine keeps a list of. Same decided contract as paramFind.
func paramFindAll(cols []string, code skillparam.Code) (out []int, decided bool) {
	runs, complete := paramRuns(cols)
	if !complete {
		return nil, false
	}
	for _, r := range runs {
		if r.Code == code {
			out = append(out, skillparam.ParamBlockColumn+r.Index)
		}
	}
	return out, true
}

// attackParam pulls a skill's damage out of its Param block: the percentage of
// weapon damage it deals, and the flat damage range added on top.
//
// The five values after the code are (type, percent, min, max, percent again).
// Read across a skill's levels the meaning is plain: for SKILL_CH_SWORD_SMASH_A
// levels 1-5 the percent stays 143 while min/max climb 15-18, 18-22, 21-26,
// 25-30, 29-35. A plain swing (SKILL_CH_SWORD_BASE_01) is 60 percent and no
// flat damage at all, which is exactly what a basic attack should be.
//
// Returns "0","0","0" for a skill with no 'att' -- most skills are buffs,
// heals or passives and have no attack parameter.
//
// SCANNING THE WHOLE ROW rather than walking the Param block is safe, and that
// is now measured rather than hoped. The risk is obvious -- 6386804 could occur
// as some other parameter's VALUE and be read as a code -- so it was tested
// against the parser's own schema (docs/protocol/skill_params.md, the 102 codes
// recovered from SkillGlobal::RefSkill_ParseParams):
//
//   - The Param block starts at column 69. Across every real skill row, the
//     lowest column the literal ever appears at is 69, so nothing precedes the
//     block: 0 rows carry it earlier.
//   - No row carries it twice, so "first match" cannot pick the wrong one.
//
// RE-VALIDATED 2026-09-16 on the COMPLETE table. The figures above were
// measured over 31,605 rows, which turned out to be a partial extraction --
// only some skilldata shards were on disk at the time. Pulling all seven from
// Media.pk2 gives **33,632 rows**, of which 30,064 carry 'att', and both claims
// still hold exactly: 0 rows carry it before column 69, 0 rows carry it twice,
// and the lowest column it ever appears at is 69. The first-match scan is safe
// on the whole table, not just the part that happened to be extracted.
//   - On the rows whose Param block walks cleanly end to end under the
//     recovered run lengths, the walk's 'att' position and this scan's first
//     match agree and never differ.
//
// RE-VALIDATED AGAIN 2026-09-16, against a COMPLETE vocabulary. The check above
// ran against a 104-code table under which 15,625 rows stopped at a code nobody
// had recovered -- so "they agree on the rows that walk" was quietly conditioned
// on the rows that happened to walk. The vocabulary is now 148 codes and **no
// row in the table hits an unrecognised code** (docs/protocol/skill_params.md).
// Re-run on that footing:
//
//   - 19,990 rows walk end to end; the walk's 'att' position and this scan's
//     first match agree on 18,727 of them and differ on 0.
//   - The 'att' literal 6386804 appears as some other code's VALUE exactly
//     **0 times** across every walked run. That is the scan's actual failure
//     mode, and it is now measured directly rather than argued from the
//     schema.
//
// The scan is also the more version-robust of the two: a client whose skilldata
// shifts the block would break a hard-coded column 69, and this would not.
// attackType is value[0], the damage-TYPE mask -- exported since 2026-09-16
// because the engine gates each half of a blow on it. Bit 4 enables the
// physical half, bit 8 the magical one; bits 1 and 2 are a second axis
// selecting which flat-absorption param applies. See combat.AttackType and
// docs/protocol/skill_params.md.
func attackParam(cols []string) (attackType, percent, dmgMin, dmgMax string) {
	at := func(i, off int) string {
		if i+off >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i+off])
		if s == "" {
			return "0"
		}
		return s
	}
	i, found := attackRun(cols)
	if !found {
		return "0", "0", "0", "0"
	}
	// i+1 is the type; the damage is in the three that follow.
	return at(i, 1), at(i, 2), at(i, 3), at(i, 4)
}

// attackRun returns the row column of the skill's 'att' code word. The walk is
// authoritative when it finishes (see paramRuns); otherwise the whole-row scan
// the comment above measures.
func attackRun(cols []string) (col int, found bool) {
	if i, found, decided := paramFind(cols, "att"); decided {
		return i, found
	}
	for i, v := range cols {
		if strings.TrimSpace(v) == attackCode {
			return i, true
		}
	}
	return 0, false
}

// literalAbsent reports that NONE of the codes' stored words appears anywhere in
// the row. It is the one inference about a Param block that needs no walk: a
// parameter whose code word is nowhere in the row cannot be in the block. Only
// absence is proof -- presence is not, since the same integer could be some
// other column's value -- so this is used to decide rows the walk cannot
// finish, and only ever in the direction that is sound.
func literalAbsent(cols []string, codes []skillparam.Code) bool {
	present := make(map[string]bool, len(cols))
	for _, v := range cols {
		present[strings.TrimSpace(v)] = true
	}
	for _, c := range codes {
		if present[strconv.Itoa(int(skillparam.WordOf(c)))] {
			return false
		}
	}
	return true
}

// reqItemCount counts the skill's 'reqi' runs, i.e. how many entries it puts in
// the list at CRefSkill+0x3a0. The engine caps the list at 5.
//
// Only whether it is ZERO matters to the weapon gate, but the count is exported
// rather than a boolean because what the list HOLDS is not recovered yet, and a
// count is the more useful thing to already have when it is.
func reqItemCount(cols []string) string {
	n := 0
	if at, decided := paramFindAll(cols, "reqi"); decided {
		n = len(at)
	} else {
		for _, v := range cols {
			if strings.TrimSpace(v) == reqItemCode {
				n++
			}
		}
	}
	if n > 5 {
		n = 5 // the engine's own cap: `cmp edx,0x5 / je` ends the slot scan
	}
	return strconv.Itoa(n)
}

// reqItemList packs the skill's 'reqi' records as `kind:value;kind:value`.
// The run is three words -- the code plus (kind, value) -- and the engine stores
// a pointer to the pair, reading *p as the kind and p[1] as the value.
func reqItemList(cols []string) string {
	var out []string
	add := func(i int) bool {
		if i+2 >= len(cols) {
			return false
		}
		kind := strings.TrimSpace(cols[i+1])
		val := strings.TrimSpace(cols[i+2])
		if kind == "" || val == "" {
			return false
		}
		out = append(out, kind+":"+val)
		return len(out) == 5 // the engine's own cap on the list
	}
	if at, decided := paramFindAll(cols, "reqi"); decided {
		for _, i := range at {
			if add(i) {
				break
			}
		}
		return strings.Join(out, ";")
	}
	for i, v := range cols {
		if strings.TrimSpace(v) != reqItemCode {
			continue
		}
		if add(i) {
			break
		}
	}
	return strings.Join(out, ";")
}

// floorBlow reports, as "1" or "0", that every blow this skill lands is exactly
// the engine's floor of 1: `local_d0` is 0, so the blow IS computed, but the
// computation is identically zero and Combat_ResolveDamage floors it. See
// skillparam.BlowIsFloor for the three ways that happens and their citations.
//
// 446 real rows: 440 carrying 'att' with a percent of 0 (420 of them the mall
// pets' elemental skills), 5 carrying a percent but neither damage bit, and the
// single row in the table that carries 'ck' alone. Before this column every one
// of them dealt a full weapon blow plus DisclosedSkillDamagePerLevel * level.
//
// A row that is zero-damage is not a floor blow, and a row where neither
// parameter was found but absence could not be proved answers "0".
func floorBlow(cols []string) string {
	if zeroDamage(cols) == "1" {
		return "0"
	}
	num := func(i int) int32 {
		if i >= len(cols) {
			return 0
		}
		n, err := strconv.ParseInt(strings.TrimSpace(cols[i]), 10, 32)
		if err != nil {
			return 0
		}
		return int32(n)
	}
	i, hasAtt := attackRun(cols)
	var attType, attPercent int32
	if hasAtt {
		attType, attPercent = num(i+1), num(i+2)
	}
	_, carriesCk, _ := paramFind(cols, "ck")
	if !hasAtt && !carriesCk {
		return "0"
	}
	if skillparam.BlowIsFloor(hasAtt, attType, attPercent, carriesCk) {
		return "1"
	}
	return "0"
}

// zeroDamage reports, as "1" or "0", that Combat_ResolveDamage's `local_d0`
// would be 1 for this skill -- it carries neither 'att' nor 'ck', so the
// ordinary damage kind writes zero to both halves of the blow and their sum is
// the total. See skillparam.DamageParameters.
//
// This is WIDER than noCombatParam and contains it: 2,482 real rows carry
// neither, of which 1,813 also carry none of the 33 and return earlier still.
// Both columns are exported because the distinction is real -- no blow at all
// versus a blow of zero -- even though srrevamp models both as no damage today.
//
// Positive sense is safe here for the same reason the other column's negative
// sense is: an export predating this one loads false, which means "this skill's
// damage is computed", the behaviour every older export already had.
func zeroDamage(cols []string) string {
	words, ok := paramWords(cols)
	if !ok {
		return "0"
	}
	zero, decided := skillparam.DealsZeroDamage(words)
	if decided {
		if zero {
			return "1"
		}
		return "0"
	}
	// The walk stopped at a variable-length code and proved nothing -- but if
	// neither 'att' nor 'ck' appears ANYWHERE in the row, the block cannot
	// carry them. That is proof, not a heuristic, and it decides 1,085 of the
	// 1,265 real rows the walk cannot finish. (The other 180 all carry the
	// 'att' literal, so with this the three classes -- 'att', 'ck' alone,
	// neither -- partition all 33,632 rows with nothing left over.)
	if literalAbsent(cols, skillparam.DamageParameters) {
		return "1"
	}
	return "0"
}

// noCombatParam reports, as "1" or "0", that Combat_ResolveDamage would return
// WITHOUT RESOLVING A BLOW for this skill: it carries none of the 33 parameters
// that function tests, and no 'efr' whose second value is 6. See
// skillparam.CombatParameters for the list and the citation.
//
// THE COLUMN IS NEGATIVE ON PURPOSE. Skill CSV columns are a strict suffix: an
// export made before a column existed loads with the Go zero value. False here
// means "this skill does resolve a blow", which is what every older export
// already assumed, so an old export keeps its current behaviour instead of
// silently muting a third of the table.
//
// UNDECIDABLE ROWS ANSWER "0". A row whose Param block stops at a
// variable-length code hides whatever follows, so nothing can be concluded
// about it -- 1,265 of 33,632 real rows are like this. They answer "0", the
// conservative direction: the skill keeps the damage it has today rather than
// being silenced on evidence that does not exist.
func noCombatParam(cols []string) string {
	words, ok := paramWords(cols)
	if !ok {
		return "0"
	}
	carries, decided := skillparam.CarriesCombatParameter(words)
	if decided {
		if !carries {
			return "1"
		}
		return "0"
	}
	// Same sound inference as zeroDamage: a row in which none of the 33 code
	// words appears anywhere cannot carry any of them. 872 of the 1,265 rows
	// the walk cannot finish are decided this way. 'efr' is in the list, so a
	// row passing this has no 'efr' to qualify either.
	if literalAbsent(cols, skillparam.CombatParameters) {
		return "1"
	}
	return "0"
}

// reqAll reports whether the skill carries 'reqn', as "1" or "0".
func reqAll(cols []string) string {
	for _, v := range cols {
		if strings.TrimSpace(v) == reqAllCode {
			return "1"
		}
	}
	return "0"
}

// hitCountParam pulls a skill's hit count out of its Param block. The run is
// (code, 2, N); the leading 2 is a selector the server tests before taking N,
// so a run that does not carry it is not a hit count and is ignored.
//
// Returns "0" when the skill has no 'mc', which refdata.Skill.HitsFor reads as
// a single strike -- the engine's own default.
func hitCountParam(cols []string) string {
	take := func(i int) (string, bool) {
		if i+2 >= len(cols) || strings.TrimSpace(cols[i+1]) != "2" {
			return "", false
		}
		n := strings.TrimSpace(cols[i+2])
		if n == "" {
			return "0", true
		}
		return n, true
	}
	if i, found, decided := paramFind(cols, "mc"); decided {
		if !found {
			return "0"
		}
		if n, ok := take(i); ok {
			return n
		}
		return "0"
	}
	for i, v := range cols {
		if strings.TrimSpace(v) != hitCountCode {
			continue
		}
		if n, ok := take(i); ok {
			return n
		}
	}
	return "0"
}

// readTable reads a tab-separated itemdata file, decoding UTF-16LE (with or
// without a BOM) or UTF-8, and returns each non-empty, non-comment line
// split on tabs.
func readTable(path string) ([][]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	text := decode(raw)
	var out [][]string
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" || strings.HasPrefix(line, "//") {
			continue
		}
		out = append(out, strings.Split(line, "\t"))
	}
	return out, sc.Err()
}

// decode turns raw bytes into a string, honouring a UTF-16LE BOM (the form
// the Media text tables use) and falling back to UTF-8.
func decode(raw []byte) string {
	if len(raw) >= 2 && raw[0] == 0xFF && raw[1] == 0xFE {
		u16 := make([]uint16, 0, (len(raw)-2)/2)
		for i := 2; i+1 < len(raw); i += 2 {
			u16 = append(u16, uint16(raw[i])|uint16(raw[i+1])<<8)
		}
		return string(utf16.Decode(u16))
	}
	return string(raw)
}
