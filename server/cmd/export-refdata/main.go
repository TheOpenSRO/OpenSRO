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
)

// Field indices into a tab-split itemdata row (0-indexed; field 0 is the
// leading service column).
const (
	fID      = 1
	fTypeID1 = 9 // TypeID1..4 run 9..12
	fCountry = 14
	// MaxStack: 1 for all equipment, a real cap for stackables (col 57).
	fMaxStack = 57
	// Real NPC vendor prices: _RefObjCommon Price (buy) and SellPrice
	// (buy-back). Confirmed against real rows -- SellPrice < Price on every
	// item checked, potions carry a Price with 0 CostRepair, weapons carry
	// both -- and pinned by fReqLevelType1=32 lining up (ItemTableReader reads
	// the same column). See docs/protocol/refdata_schema.md.
	fPrice     = 26
	fSellPrice = 31
	// The Param block stores a value beside its own label: 118 "HP...",
	// 120 "HP...(%)", 122 "MP...", 124 "MP...(%)". Potion restore amounts.
	fRestoreHP     = 118
	fRestoreHPPct  = 120
	fRestoreMP     = 122
	fRestoreMPPct  = 124
	fReqLevelType1 = 32
	fReqLevel1     = 33
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
	fItemClass      = 61
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
	}, true
}

// attackCode is the skill parameter tagged 'att', the one that carries a
// skill's damage. Skill parameters live in the row's Param block as
// (code, values...) runs, where a code is a C multi-character literal stored
// as a big-endian integer -- 'att' is 0x00617474 = 6386804. The server's own
// parameter parser reads 'att' as a fixed run of six words (the code plus five
// values), which is how the layout below is known rather than guessed.
const attackCode = "6386804"

// hitCountCode is the skill's 'mc' parameter -- 0x6d63, the pair (2, N) where N
// is how many times one cast strikes. See refdata.Skill.HitCount for the
// use-site that settles it as a count rather than a multiplier.
const hitCountCode = "28003"

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
//   - On the 19,839 rows whose Param block walks cleanly end to end under the
//     recovered run lengths, the walk's 'att' position and this scan's first
//     match agree 19,839 times and differ 0 times.
//
// The scan is also the more version-robust of the two: a client whose skilldata
// shifts the block would break a hard-coded column 69, and this would not.
// attackType is value[0], the damage-TYPE mask -- exported since 2026-09-16
// because the engine gates each half of a blow on it. Bit 4 enables the
// physical half, bit 8 the magical one; bits 1 and 2 are a second axis
// selecting which flat-absorption param applies. See combat.AttackType and
// docs/protocol/skill_params.md.
func attackParam(cols []string) (attackType, percent, dmgMin, dmgMax string) {
	for i, v := range cols {
		if strings.TrimSpace(v) != attackCode {
			continue
		}
		at := func(off int) string {
			if i+off >= len(cols) {
				return "0"
			}
			s := strings.TrimSpace(cols[i+off])
			if s == "" {
				return "0"
			}
			return s
		}
		// i+1 is the type; the damage is in the three that follow.
		return at(1), at(2), at(3), at(4)
	}
	return "0", "0", "0", "0"
}

// hitCountParam pulls a skill's hit count out of its Param block. The run is
// (code, 2, N); the leading 2 is a selector the server tests before taking N,
// so a run that does not carry it is not a hit count and is ignored.
//
// Returns "0" when the skill has no 'mc', which refdata.Skill.HitsFor reads as
// a single strike -- the engine's own default.
func hitCountParam(cols []string) string {
	for i, v := range cols {
		if strings.TrimSpace(v) != hitCountCode || i+2 >= len(cols) {
			continue
		}
		if strings.TrimSpace(cols[i+1]) != "2" {
			continue
		}
		n := strings.TrimSpace(cols[i+2])
		if n == "" {
			return "0"
		}
		return n
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
