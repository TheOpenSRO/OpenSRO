package nest

import (
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/OpenSRO/srrevamp/server/internal/skillparam"
)

// The uniques' minions (round 661): which of a unique's skills summon, what
// they summon, and the executor's arithmetic. The RULES are READ from
// SR_GameServer.exe (each cited where it is written; docs/protocol/
// monster_ai.md, "The unique rotation and the minions"). The ROWS -- which
// tactics a unique runs under, its _RefAISkill triggers and its summon
// skills' Param blocks -- come from the shard DB's CSVs (EXTERNAL, the
// Eternity backup, round 658; never committed). The summon blocks are the
// same words the client's own skilldata carries (READ data): round 661
// measured 286 of the 292 client skills with an 'ssou' block identical in the
// DB, and every one of the seven field uniques' among them.

// The two optional files -nest-db-dir may also hold (round 661). Without
// them the uniques still rotate, but summon nothing and have no triggers.
const (
	AISkillFile = "Tab_RefAISkill.csv"
	SkillFile   = "_RefSkill.csv"
)

// AISkillRow is one _RefAISkill row (EXTERNAL values; the five columns READ
// off RefAISkill_ExtractData 0x6ab4b0, monster_ai.md): the tactics it
// belongs to, the skill by its Basic_Code, and the trigger.
type AISkillRow struct {
	TacticsID int64
	SkillCode string
	// Type is the trigger kind: 0 fires once when the owner's HP percent is
	// at or below Data, 1 every Data milliseconds (round 260).
	Type uint8
	Data int
	// Option bit 0, type 1 only: fire at the first evaluation.
	Option int
}

// SummonTuple is one {refObjID, class, min, max} entry of an 'ssou' block,
// as the minion executor (0x596e50) reads it: 16 bytes, `piVar13 =
// base + i * 0x10`, the object id at +0, the class byte at +4 (its low
// nibble), the count's two ends at +8 and +0xc. READ (round 661). A zero id
// is skipped (`if (*piVar13 != 0)`).
type SummonTuple struct {
	RefObjID int64
	Class    uint8
	Min, Max int
}

// SummonTuplesMax is the executor's loop bound: `while (iStack_210 < 9)`.
const SummonTuplesMax = 9

// SkillRow is what this package keeps of a _RefSkill row: its id and code,
// and for a summon skill ('ssou' in its Param block) the tuples after the
// code word.
type SkillRow struct {
	ID     int64
	Code   string
	Summon bool
	Tuples []SummonTuple
}

// ParseSummon reads the tuples of a Param block: the words after its 'ssou'
// run, found by the engine's own walk (skillparam.Find -- the parser stores
// the cursor past the code word at +0x354 and returns, 0x5890cb..0x5890e5).
// ok is false for a block with no 'ssou'. Up to SummonTuplesMax tuples, the
// zero-id ones included (the executor skips them); a tuple past the block's
// end reads as zero.
func ParseSummon(words []int32) (tuples []SummonTuple, ok bool) {
	i, found, _ := skillparam.Find(words, "ssou")
	if !found {
		return nil, false
	}
	at := func(k int) int32 {
		if k < len(words) {
			return words[k]
		}
		return 0
	}
	for t := 0; t < SummonTuplesMax; t++ {
		b := i + 1 + t*4
		tuples = append(tuples, SummonTuple{RefObjID: int64(uint32(at(b))), Class: uint8(at(b+1)) & 0x0f,
			Min: int(uint32(at(b + 2))), Max: int(uint32(at(b + 3)))})
	}
	return tuples, true
}

// AISkillColumns is every Tab_RefAISkill column this package reads.
var AISkillColumns = []string{"TacticsID", "SkillCodeName", "ExcuteConditionType", "ExcuteConditionData", "Option"}

// ReadAISkills parses a Tab_RefAISkill CSV into rows by tactics id.
func ReadAISkills(r io.Reader) (map[int64][]AISkillRow, error) {
	t, err := readTable(r, AISkillColumns)
	if err != nil {
		return nil, err
	}
	out := map[int64][]AISkillRow{}
	for i, rec := range t.rows {
		c := &cell{t: t, rec: rec, row: i + 2}
		row := AISkillRow{TacticsID: c.int("TacticsID"), SkillCode: c.str("SkillCodeName"),
			Type: uint8(c.int("ExcuteConditionType")), Data: int(c.int("ExcuteConditionData")), Option: int(c.int("Option"))}
		if c.err != nil {
			return nil, c.err
		}
		out[row.TacticsID] = append(out[row.TacticsID], row)
	}
	return out, nil
}

// ReadSkills streams a _RefSkill CSV (36,000 rows of 118 columns): every
// row's id and code, and the tuples of the rows whose Param1..Param50 carry
// an 'ssou' block.
func ReadSkills(r io.Reader) (map[int64]*SkillRow, error) {
	cr := csv.NewReader(r)
	cr.FieldsPerRecord = -1
	cr.LazyQuotes = true
	cr.ReuseRecord = true
	header, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("reading header: %w", err)
	}
	col := map[string]int{}
	for i, h := range header {
		col[strings.TrimPrefix(strings.TrimSpace(h), "\ufeff")] = i
	}
	idCol, ok1 := col["ID"]
	codeCol, ok2 := col["Basic_Code"]
	p1, ok3 := col["Param1"]
	if !ok1 || !ok2 || !ok3 {
		return nil, fmt.Errorf("no ID, Basic_Code or Param1 column in header")
	}
	out := map[int64]*SkillRow{}
	words := make([]int32, skillparam.ParamBlockMaxWords)
	for line := 2; ; line++ {
		rec, err := cr.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		if idCol >= len(rec) || codeCol >= len(rec) {
			return nil, fmt.Errorf("row %d: short", line)
		}
		id, err := strconv.ParseInt(strings.TrimSpace(rec[idCol]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("row %d: ID %q: %w", line, rec[idCol], err)
		}
		row := &SkillRow{ID: id, Code: strings.TrimSpace(rec[codeCol])}
		for k := range words {
			words[k] = 0
			if p1+k < len(rec) {
				if v, err := strconv.ParseInt(strings.TrimSpace(rec[p1+k]), 10, 64); err == nil {
					words[k] = int32(v)
				}
			}
		}
		row.Tuples, row.Summon = ParseSummon(words)
		out[id] = row
	}
	return out, nil
}

// loadOptional reads the round-661 files from dir into db; a file that is
// absent is left out (reported by db.AISkills / db.Skills being nil), one
// that is there but does not parse is an error.
func loadOptional(db *DB, dir string) error {
	f, err := os.Open(filepath.Join(dir, AISkillFile))
	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		return err
	default:
		ai, err := ReadAISkills(f)
		f.Close()
		if err != nil {
			return fmt.Errorf("%s: %w", AISkillFile, err)
		}
		db.AISkills = ai
	}
	f, err = os.Open(filepath.Join(dir, SkillFile))
	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		return err
	default:
		sk, err := ReadSkills(f)
		f.Close()
		if err != nil {
			return fmt.Errorf("%s: %w", SkillFile, err)
		}
		db.SetSkills(sk)
	}
	return nil
}

// SetSkills installs the skill rows.
func (db *DB) SetSkills(rows map[int64]*SkillRow) {
	db.Skills = rows
}

// SummonKind is the unique AI-skill selector a tactics row gets.
type SummonKind uint8

const (
	// SummonNone is the plain selector, AI::CAISkill_Basic.
	SummonNone SummonKind = iota
	// SummonA is AI::CAISkill_Unique_Summon_A (vtable 0xaf9d5c, built by
	// 0x561f20): four summon slots by AI_AttackChance, one per HP bucket.
	SummonA
	// SummonB is AI::CAISkill_Unique_Summon_B (vtable 0xaf9d94, built by
	// 0x562330): every summon skill in a list, two sets drawn 50/50.
	SummonB
	// SummonC is AI::CAISkill_Unique_Summon_C (0x5626d0). No field unique
	// runs it; not modelled.
	SummonC
)

func (k SummonKind) String() string {
	switch k {
	case SummonA:
		return "Summon_A"
	case SummonB:
		return "Summon_B"
	case SummonC:
		return "Summon_C"
	}
	return "Basic"
}

// SummonKindFor is AI::CTactics::BindSkillsAndRanges' choice of the AI-skill
// selector by TacticsID (srv.asm 0x53f7bd..0x53f8cf, round 661 -- the ids are
// immediates in the code, READ):
//
//	0x71 0x9a 0xb9                                     -> Summon_B (0x53f7eb)
//	0x21 0x3f 0xe5 0x67e8 0x8084 0x80e8 0x814c 0x81b0
//	0x8214 0x82dc                                      -> Summon_A (0x53f837)
//	0x970e 0x9722                                      -> Summon_C (0x53f894)
//	anything else keeps the Basic selector
//
// The shard's seven field uniques run under exactly seven of these (EXTERNAL:
// 33 TIGERWOMAN, 63 URUCHI, 229 KERBEROS, 26600 IVY -> A; 113 ISYUTARU, 154
// BONELORD, 185 TAHOMET -> B).
func SummonKindFor(tacticsID int64) SummonKind {
	switch tacticsID {
	case 0x71, 0x9a, 0xb9:
		return SummonB
	case 0x21, 0x3f, 0xe5, 0x67e8, 0x8084, 0x80e8, 0x814c, 0x81b0, 0x8214, 0x82dc:
		return SummonA
	case 0x970e, 0x9722:
		return SummonC
	}
	return SummonNone
}

// SummonASlot is where AI::CAISkill_Unique_Summon_A::RegisterSkill (0x562060)
// files a summon skill: its AI_AttackChance (CRefSkill+0x164, skilldata col
// 66) over 100.0 as a float, against the doubles 0.2/0.4/0.6/0.8 (0xb45be8,
// 0xb45be0, 0xb45bd8, 0xb45bd0; srv.asm 0x5620e8..0x56214f):
//
//	< 0.4 -> 3 ; < 0.6 -> 2 ; < 0.8 -> 1 ; else 0
//
// (below 0.2 is 3 too). A slot already taken keeps its first skill, and the
// later one is dropped -- not put on the attack list either (`jne 0x56219c`).
// READ, round 661.
func SummonASlot(chance int) int {
	f := float64(float32(float64(chance) / 100.0))
	switch {
	case f < 0.2, f < 0.4:
		return 3
	case f < 0.6:
		return 2
	case f < 0.8:
		return 1
	}
	return 0
}

// SummonCountStandIn is the count both ends of a tuple whose row gives
// 0..0 take: Kerberos's Ladon's 2..3, the only field unique's tuple with a
// count (its R1_80 summon; its R1_40 one gives Ladon 1..2). OURS, the user's
// decision D10 (docs/WORLD_ISSUES.md round 661): with the rows as they are,
// the executor spawns nothing for a 0..0 tuple (`if (n < 1) skip`), so no
// field unique but Cerberus would ever summon.
const (
	SummonCountStandInMin = 2
	SummonCountStandInMax = 3
)

// SummonCountCap is the executor's cap: a count of 51 or more logs "Oooops!!!!
// Spawn Monster Count is over 50!!!!" and spawns 50 (0x597745..0x597763).
// READ.
const SummonCountCap = 50

// MinionCount is the executor's count for one tuple (0x596e50): `n = min +
// abs(rand()) % (max - min + 1)`, capped at SummonCountCap; below 1 nothing
// is spawned. The die is thrown whatever the ends. READ, round 661. (max <
// min asserts in the engine and still computes; here it is treated as
// max = min.)
func MinionCount(dice Dice, min, max int) int {
	span := max - min
	if span < 0 {
		span = 0
	}
	n := min + dice()%(span+1)
	if n > SummonCountCap {
		n = SummonCountCap
	}
	if n < 1 {
		return 0
	}
	return n
}

// SummonRadius is the executor's per-tuple "radius" argument to the spawn
// routine: `rand() / 32767.0 * float(2 pi) + 0.0` (0xb45af8, 0xb45c18,
// 0xb45ab0), thrown once per tuple BEFORE its count die. The spawn routine
// hands it to FUN_00531240 as the ring's radius, where it is at most 2 pi --
// far inside the minimum -- so every minion lands exactly at the minimum,
// each at its own random angle. READ (round 661).
func SummonRadius(dice Dice) float64 {
	return float64(float32(float64(dice())/CRandMax*float64(float32(6.283185307179586)) + 0.0))
}

// SummonDistance is the executor's minimum for FUN_00531240: the unique's
// IGObj slot 344 (0x560, its collision radius -- the word at the common
// record's +0xee) plus 30 plus the minion species' own +0xee, as an int, then
// a float. READ (round 661): `(float)(slot344() + 0x1e + *(ushort*)(ref+0xee))`.
func SummonDistance(uniqueBC, minionBC int) float64 {
	return float64(float32(uniqueBC + 30 + minionBC))
}
