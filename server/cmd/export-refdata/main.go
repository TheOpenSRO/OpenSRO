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
	fHitRate       = 113
	fCritical      = 116
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
	fTwoHanded      = 93
	fPhysDefenseMin = 65
	fBlockRatio     = 74 // shields only; body armour carries the parry pair at 68
	fMagDefenseMin  = 76
	// The highest field any mapping reads: a row shorter than this is not a
	// real item row and is skipped.
	fMax = 116
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

	written, skipped := 0, 0
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
			if err := w.Write(rec); err != nil {
				fmt.Fprintf(os.Stderr, "writing: %v\n", err)
				os.Exit(1)
			}
			written++
		}
	}
	w.Flush()
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d %s rows, skipped %d non-%s rows\n", written, noun, skipped, noun)
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
		"0",                      // 4  ItemClass (not mapped)
		"0",                      // 5  TwoHanded (not mapped)
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
		num(fHitRate),            // 16 HitRateMin
		num(fHitRate + 1),        // 17 HitRateMax
		num(fCritical),           // 18 CriticalMin
		num(fCritical + 1),       // 19 CriticalMax
		get(fTypeID1),            // 20 TypeID1
		get(fTypeID1 + 1),        // 21 TypeID2
		get(fTypeID1 + 2),        // 22 TypeID3
		get(fTypeID1 + 3),        // 23 TypeID4
		get(fCountry),            // 24 Country
		get(fReqGender),          // 25 ReqGender
		get(fReqLevelType1),      // 26 ReqLevelType1
		get(fReqLevel1),          // 27 ReqLevel1
		get(fPrice),              // 28 Price (real NPC buy price)
		get(fSellPrice),          // 29 SellPrice (real NPC buy-back price)
		get(fRestoreHP),          // 30 RestoreHP    (Param block, labelled "HP...")
		get(fRestoreHPPct),       // 31 RestoreHPPct
		get(fRestoreMP),          // 32 RestoreMP    (Param block, labelled "MP...")
		get(fRestoreMPPct),       // 33 RestoreMPPct
		num(fBlockRatio),         // 34 BlockRatioMin (shields only)
		num(fBlockRatio + 1),     // 35 BlockRatioMax
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
	pct, dmgMin, dmgMax := attackParam(cols)
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
	}, true
}

// attackCode is the skill parameter tagged 'att', the one that carries a
// skill's damage. Skill parameters live in the row's Param block as
// (code, values...) runs, where a code is a C multi-character literal stored
// as a big-endian integer -- 'att' is 0x00617474 = 6386804. The server's own
// parameter parser reads 'att' as a fixed run of six words (the code plus five
// values), which is how the layout below is known rather than guessed.
const attackCode = "6386804"

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
func attackParam(cols []string) (percent, dmgMin, dmgMax string) {
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
		return at(2), at(3), at(4)
	}
	return "0", "0", "0"
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
