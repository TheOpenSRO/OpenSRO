// Package leveldata holds the EXP-per-level curve recovered from the client's
// own server_dep\silkroad\textdata\leveldata.txt (see docs/LEVELING.md), and
// the level-up math built on it. The curve is game data, so it is never
// committed: an operator generates a CSV from their own client with
// cmd/export-leveldata and points the server at it (SRREVAMP_LEVELDATA_CSV).
// Without it the server has no curve and characters do not level.
package leveldata

import (
	"bufio"
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
)

// StatPointsPerLevel is how many points a character gets to spend (into Str or
// Int) each level. Recovered as a rule, not a table value: a real level-9
// character window showed 24 stat points, and (9-1)*3 = 24. See docs/LEVELING.md.
const StatPointsPerLevel = 3

// MaxCharacterLevel is the hard level cap this client enforces, recovered from
// the client's own EXP handler: sro_client.exe FUN_008a97c0 runs its level-up
// carry loop `while (level != 'n')` -- 'n' is 0x6E = 110 -- and force-stops at
// that level. It is independent of the leveldata.txt row count (that table has
// 139 rows; a character still stops at 110). This is this specific client's
// base-game cap; a later expansion's client would raise it. See
// docs/GROUNDING_AUDIT.md.
const MaxCharacterLevel = 110

// Table is the level -> EXP-to-advance curve. expToNext[L] is the experience a
// character must accumulate at level L to reach level L+1.
type Table struct {
	expToNext map[int]int64
	// masterySP[L] is the skill-point cost to raise a mastery from level L to
	// L+1 -- leveldata's column 2. REAL: the server sums exactly this field
	// over the levels being raised. See MasteryUpCost.
	masterySP map[int]int
	// expUnit[L] is the standard EXP a kill is worth at level L -- leveldata's
	// column 5. REAL: see ExpUnit.
	expUnit  map[int]int64
	maxLevel int
}

// ExpUnit returns the level table's standard EXP unit for a level, and whether
// the table knows it.
//
// **Recovered, and the rule around it matters as much as the number.**
// SR_GameServer.exe's Formula_MonsterExpReward (004105d0) computes a kill's
// worth as
//
//	lvl    = min(Char_GetLevel(killer), Char_GetLevel(victim))
//	reward = scaleByWindow * levelTable[lvl]+0x1c * killer[0x1cd8] * scaleByDiff
//
// floored at 1, and its result goes to GObjPC_GiveExp (vtable slot 421, read
// out of the vtable at 0x00af6090). A second, independent use-site settles what
// the +0x1c field IS: FUN_00631050 hands `entry[0x1c] * multiplier` straight to
// GObjPC_GainExpAndLevel as an exp amount, with no formula in between.
//
// That +0x1c is column 5 is settled by elimination, not by curve-matching.
// Column 2 sits at +0x10 (the mastery cost, already grounded and confirmed
// value-for-value against the real file), columns 3 and 4 are plain zero
// integers, so the next 4-byte field is column 5. Every other packing puts a
// provably impossible value at +0x1c: skipping the zero columns would land on
// column 7, making a level-1 kill worth 15,000,000 exp, and an extra internal
// field would land on a column that is zero at every level. Verified identical
// in the ORIGINAL client's leveldata.txt and the pserver's, so it is not a
// private-server edit. See docs/RE_COMPLETION.md.
func (t *Table) ExpUnit(level int) (int64, bool) {
	if t == nil {
		return 0, false
	}
	v, ok := t.expUnit[level]
	return v, ok
}

// ExpWindowScale is the OTHER of the two scalers on a kill's experience, and it
// only ever reduces: killing far below your level, or far above it, pays less.
//
// RECOVERED from Formula_ExpScaleByLevelWindow (0040fed0) and the classifier it
// calls, FUN_0040fe60 (0040fe60), which is three comparisons on the level gap:
//
//	gap = victimLevel - killerLevel
//	gap <  -3  -> mode 2
//	gap <  11  -> mode 0
//	otherwise  -> mode 1
//
// and mode 0 takes a branch that leaves the result at the 1.0 it was
// initialised to (`40ff03 SUB EAX,0 ; JE 0x40ff8c`, jumping straight past every
// arithmetic path). So **inside a -3..+10 band the scale is exactly 1.0**,
// which is most kills.
//
// The two outer modes, disassembled because the decompiler renders the register
// levels as an unreadable mix of `uVar5` halves:
//
//	mode 1, 40ff5d:  SUB EDX,EBX ; SUB EDX,0xA
//	                 FMUL qword [0x00b45ec8]        <- * 0.02
//	                 FLD1 ; FSUBRP                  <- 1.0 - that
//	mode 2, 40ff1f:  SUB ECX,EBX ; CMP ECX,-7 ; JG  <- near band?
//	         40ff55:   FLD dword [0x00b45ddc]       <- 0.9 flat
//	         40ff38:   SUB EBX,EDX ; SUB EBX,3
//	                   FMUL qword [0x00b45ed0]      <- * 0.15
//	                   FLD1 ; FSUBRP                <- 1.0 - that
//	clamp,  40ff94:  FCOM qword [0x00b45ec0] -> below 0.1 returns 0.1
//	        40ffb6:  FLD1 ; FCOM            -> at or above 1.0 returns 1.0
//
// EBX is the killer's level and EDX the victim's: Formula_MonsterExpReward
// calls this with `MOV ECX,EDI` where EDI is the killer, and ESI still holds
// the victim from the function's entry.
//
// Operand sizes again decide the constants, and here they matter more than
// usual because both 0x00b45ec8 and 0x00b45ed0 read as 2 when taken as a float:
// `FMUL qword` makes them doubles, **0.02** and **0.15**. 0x00b45ddc is `FLD
// dword`, a float, **0.9**, and the clamp pair 0x00b45ec0 / 0x00b45eb8 are both
// **0.1**.
func ExpWindowScale(killerLevel, victimLevel int) float64 {
	gap := victimLevel - killerLevel
	scale := 1.0
	switch {
	case gap >= 11:
		// The target is far above: leeching a kill on something out of reach
		// decays by 2% a level past the tenth.
		scale = 1 - float64(gap-10)*ExpWindowFarAbovePerLevel
	case gap <= -4:
		// The target is far below. Four to six levels down is a flat 0.9;
		// past that it falls away fast, 15% a level.
		if gap > -7 {
			scale = ExpWindowNearBelow
		} else {
			scale = 1 - float64(-gap-3)*ExpWindowFarBelowPerLevel
		}
	}
	if scale < ExpWindowScaleFloor {
		scale = ExpWindowScaleFloor
	}
	if scale > 1 {
		scale = 1
	}
	return scale
}

// The constants ExpWindowScale reads, all from .rdata -- see its doc comment
// for the instruction that fixes each one's operand size.
const (
	ExpWindowFarAbovePerLevel = 0.02
	ExpWindowFarBelowPerLevel = 0.15
	ExpWindowNearBelow        = 0.9
	ExpWindowScaleFloor       = 0.1
)

// ExpDiffScalePerStep, ExpDiffScaleMaxSteps and ExpDiffScaleCap are the real
// level-gap bonus on a kill's experience: punching UP pays more, and
// out-levelling a target by three or more pays nothing extra.
//
// RECOVERED from Formula_ExpScaleByLevelDiff (0040ffe0), one of the two scalers
// Formula_MonsterExpReward multiplies its base by. Disassembled rather than read
// off the decompiler, because which level is subtracted from which is exactly
// what the C loses:
//
//	40108f  LEA EAX,[EDI + 0x3] ; CMP EAX,EBX ; JG    <- victim+3 > killer?
//	4100a0  FLD1 ; RET                                <- else exactly 1.0
//	4100a8  SUB EDI,EBX ; ADD EDI,0x3                 <- victim - killer + 3
//	4100ad  CMP EDI,0xD ; ... MOV [ESP+0xC],0xD       <- capped at 13
//	4100c2  FMUL qword [0x00b45dc8]                   <- * 0.03
//	4100c8  FADD [ESP + 0x8]                          <- + bonus + 1.0
//	4100f1  FLD  dword [0x00b45dc0]                   <- clamped to 4.0 above
//
// EDI is the victim's level and EBX the killer's: the caller loads EAX with the
// dead party and ESI with the killer (`MOV EAX,ESI ; MOV ESI,EDI` at 0x410666),
// and GObjPC_OnDeath puts the stack argument -- the dead -- in EBP and `this`
// -- the killer -- in EDI.
//
// The operand sizes settle the constants: `FMUL qword` makes 0x00b45dc8 a
// double, 0.03 (the same constant the level-advantage damage term uses), and
// `FLD dword` makes 0x00b45dc0 a float, 4.0.
//
// NOT MODELLED, and deliberately: the function can add a further 0.15/0.3/0.45
// (or 0.3/0.6/0.9 on a flag at the killer's ref object +0x88) for gaps above
// 4, 6 and 8 levels. It is a PARTY bonus -- the gate is `killer[0x72e]`
// non-null with bit 0 of its +0x10 set, and `[0x72e]` is the party pointer,
// named by the binary's own assert through CGObjPC::GetPartyInfo (vtable slot
// 76), which reads exactly that field. What bit 0 of the party's +0x10 selects
// is still unread, so a solo kill provably misses this bonus but a partied one
// cannot be decided; srrevamp's parties are own design and carry no such flag.
// Shipping it would apply it to every kill, which is worse than omitting it.
// The cap is therefore unreachable here: without the bonus the scale spans
// 1.03 to 1.39.
const (
	ExpDiffScalePerStep  = 0.03
	ExpDiffScaleMaxSteps = 13
	ExpDiffScaleCap      = 4.0
)

// ExpDiffScale returns the level-gap multiplier on a kill's experience.
func ExpDiffScale(killerLevel, victimLevel int) float64 {
	// Out-levelling the target by three or more is worth no bonus at all --
	// the engine returns a bare 1.0 without reaching the arithmetic below.
	if victimLevel+3 <= killerLevel {
		return 1
	}
	steps := victimLevel - killerLevel + 3
	if steps > ExpDiffScaleMaxSteps {
		steps = ExpDiffScaleMaxSteps
	}
	scale := 1 + float64(steps)*ExpDiffScalePerStep
	if scale < 1 {
		scale = 1
	}
	if scale > ExpDiffScaleCap {
		scale = ExpDiffScaleCap
	}
	return scale
}

// KillExp is the experience a kill is worth, applying the game's own
// **minimum-level rule**: the reward is taken at the LOWER of the two levels,
// so out-levelling a monster -- or being power-levelled by someone who has --
// pays at the weaker party's rate. The rule is symmetric, so it does not matter
// which argument is which.
//
// BOTH level-gap scalers the real formula applies are now recovered and applied
// here -- see ExpDiffScale and ExpWindowScale. What remains unmodelled is the
// killer's own exp-rate multiplier, a float at killer+0x1cd8 written only by
// CTJ_PremiumKeeper's neighbours; it is a premium/event rate and a character
// without one evaluates it at its default, so what ships is the game's formula
// at the base rate.
func (t *Table) KillExp(killerLevel, victimLevel int) (int64, bool) {
	lvl := killerLevel
	if victimLevel < lvl {
		lvl = victimLevel
	}
	v, ok := t.ExpUnit(lvl)
	if !ok {
		return 0, false
	}
	v = int64(math.Round(float64(v) *
		ExpWindowScale(killerLevel, victimLevel) *
		ExpDiffScale(killerLevel, victimLevel)))
	if v < 1 {
		// The real formula floors its result at 1.
		v = 1
	}
	return v, true
}

// MasteryUpCost returns the skill-point cost to raise a mastery from level to
// level+1, and whether the table knows it.
//
// **Recovered, not invented.** The pserver's own mastery level-up handler
// (FUN_0059c4e0) walks the levels being raised and accumulates the level
// table's entry+0x10 for each, then refuses the raise when the character's
// skill points (charData+0x80) are below the total. The level entry holds the
// int64 EXP requirement at +8, so +0x10 is the field after it -- leveldata's
// column 2. The values escalate 1, 1, 2, 2, 4, 5, 6, 7, 9, 12 ... 53 at level
// 20, 172 at level 32.
func (t *Table) MasteryUpCost(level int) (int, bool) {
	if t == nil {
		return 0, false
	}
	v, ok := t.masterySP[level]
	return v, ok
}

// ExpToNext returns the EXP needed to advance from level, and whether level is
// in the table (the max level has no "next", so it returns false there).
func (t *Table) ExpToNext(level int) (int64, bool) {
	if t == nil {
		return 0, false
	}
	v, ok := t.expToNext[level]
	return v, ok
}

// MaxLevel is the highest level the curve defines. A character at MaxLevel does
// not advance further.
func (t *Table) MaxLevel() int {
	if t == nil {
		return 0
	}
	return t.maxLevel
}

// Loaded reports whether a real curve is present (an operator imported one).
func (t *Table) Loaded() bool { return t != nil && len(t.expToNext) > 0 }

// Advance applies gained EXP to a character at (level, exp), where exp is the
// progress already accumulated at level. It returns the new level, the new
// progress, and how many levels were gained. A nil/empty table gains no levels
// and accumulates exp unbounded, so a server with no curve still tracks raw
// progress.
//
// The carry model is RECOVERED from the client, not assumed: sro_client.exe's
// EXP handler FUN_008a97c0 does exactly this -- on each level it subtracts that
// level's requirement from the running EXP and increments the level in a loop
// (excess EXP rolls into the next level), stopping when the EXP is below the
// next level's requirement OR the level reaches the cap 'n' (110,
// MaxCharacterLevel). At the cap it does NOT zero the bar: it holds EXP at that
// level's requirement minus one (a full-but-not-overflowing bar). See
// docs/GROUNDING_AUDIT.md.
func (t *Table) Advance(level int, exp int64, gained int64) (newLevel int, newExp int64, levelsGained int) {
	newLevel = level
	newExp = exp + gained
	if !t.Loaded() {
		return newLevel, newExp, 0
	}
	// The effective cap is the client's hard cap or the last level the table
	// actually defines, whichever comes first (a shorter table can't advance
	// past its last row).
	levelCap := t.maxLevel
	if MaxCharacterLevel < levelCap {
		levelCap = MaxCharacterLevel
	}
	for {
		need, ok := t.expToNext[newLevel]
		if !ok || newLevel >= levelCap {
			// At the cap, hold EXP just below this level's requirement, the
			// way the client does (FUN_008a97c0) -- not zeroed.
			if newLevel >= levelCap && ok && newExp >= need {
				newExp = need - 1
			}
			break
		}
		if newExp < need {
			break
		}
		newExp -= need
		newLevel++
		levelsGained++
	}
	return newLevel, newExp, levelsGained
}

// ParseCSV reads "level,expToNext" rows (a header line and blank lines are
// skipped) into a Table.
func ParseCSV(r io.Reader) (*Table, error) {
	t := &Table{expToNext: map[int]int64{}, masterySP: map[int]int{}, expUnit: map[int]int64{}}
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	line := 0
	for scanner.Scan() {
		line++
		text := strings.TrimSpace(scanner.Text())
		if text == "" {
			continue
		}
		fields := strings.Split(text, ",")
		if len(fields) < 2 {
			return nil, fmt.Errorf("leveldata: line %d: want 'level,exp', got %q", line, text)
		}
		level, err := strconv.Atoi(strings.TrimSpace(fields[0]))
		if err != nil {
			// The first line may be a header ("level,exp") -- skip a
			// non-numeric level rather than fail.
			if line == 1 {
				continue
			}
			return nil, fmt.Errorf("leveldata: line %d: level %q: %w", line, fields[0], err)
		}
		exp, err := strconv.ParseInt(strings.TrimSpace(fields[1]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("leveldata: line %d: exp %q: %w", line, fields[1], err)
		}
		t.expToNext[level] = exp
		// Column 2 is the mastery-up cost; optional so an older two-column
		// export still loads.
		if len(fields) > 2 {
			if sp, err := strconv.Atoi(strings.TrimSpace(fields[2])); err == nil {
				t.masterySP[level] = sp
			}
		}
		// Column 4 is the kill EXP unit; optional, so an older three-column
		// export still loads.
		if len(fields) > 3 {
			if eu, err := strconv.ParseInt(strings.TrimSpace(fields[3]), 10, 64); err == nil {
				t.expUnit[level] = eu
			}
		}
		if level > t.maxLevel {
			t.maxLevel = level
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("leveldata: reading CSV: %w", err)
	}
	// The max level is the top of the curve, which itself has no "next" -- so
	// treat the highest level present as the cap (a character there does not
	// advance). Guard against gaps by taking the real max.
	if len(t.expToNext) > 0 {
		levels := make([]int, 0, len(t.expToNext))
		for l := range t.expToNext {
			levels = append(levels, l)
		}
		sort.Ints(levels)
		t.maxLevel = levels[len(levels)-1]
	}
	return t, nil
}

// DeathPenaltyMinLevel is the level a character must EXCEED before dying costs
// anything. Real: GObjPC_OnDeath (004e6980) wraps the whole penalty block in
// `if (10 < Char_GetLevel(victim))`, so levels 1-10 die free.
const DeathPenaltyMinLevel = 10

// The four death-penalty multipliers, in units of the level's EXP unit (the
// same `levelTable[lvl]+0x1c` field a kill is paid from -- see ExpUnit). Real,
// read straight out of GObjPC_OnDeath's four branches.
//
// The branch is chosen by two things: whether the killer was another PLAYER,
// and whether the victim is carrying PK penalty points (charData+0xb4 =
// _CHAR.PKPenaltyPoint, from the recovered schema; the test is `< 1`). A
// second byte at victim+0x1cb4 is compared against 5 and gates the harsher
// branch together with the PK points; what that state enum means is still
// unrecovered, so the harsher branches are labelled by the condition this code
// CAN name.
const (
	DeathPenaltyKilledByMonster        = 100
	DeathPenaltyKilledByMonsterFlagged = 300
	DeathPenaltyKilledByPlayer         = 20
	DeathPenaltyKilledByPlayerFlagged  = 100
)

// The skill points a death costs, on top of the experience. Zero unless the
// victim is carrying PK penalty points -- an ordinary death costs no SP at
// all. Capped at what the character actually has (charData+0x80 =
// RemainSkillPoint).
const (
	DeathPenaltySkillPointsMonsterFlagged = 60
	DeathPenaltySkillPointsPlayerFlagged  = 20
)

// DeathPenaltyExp is the experience a death costs a character of this level,
// and whether the table knows the level.
//
// RECOVERED 2026-09-15 from GObjPC_OnDeath (004e6980), which the binary itself
// places at D:\WORK2005\Source\SilkroadOnline\Server\SR_GameServer\GObjPC.cpp
// (the CLAMP assert in the middle of this very block names the file and line
// 6168). The shape is
//
//	if 10 < GetLevel(victim) {
//	    loss = levelTable[level]+0x1c * {100 | 300 | 20 | 100}
//	    loss = CLAMP(loss, 1, ...)      // the assert's min is 1.0
//	    loss -= <a reduction stat>
//	    if loss > 0 { GainExpAndLevel(-loss) }   // slot 0x170 = 92, NEGATIVE
//	}
//
// so the loss is applied through the same function that grants experience,
// with a negative 64-bit amount.
//
// That +0x1c is the EXP UNIT is not assumed here: Formula_MonsterExpReward
// reads the identical field, and its disassembly also shows the minimum-level
// rule (`CMP EBX,EAX / JLE / MOV EBX,EAX` over two Char_GetLevel calls) that
// KillExp already implements -- so one function confirms both the field and a
// rule this project had recovered separately.
//
// What this costs is steeply regressive, and that is the real curve, checked
// against the ORIGINAL client's own leveldata.txt (identical to the pserver's
// at every level sampled, so it is not a private-server edit): 74% of a level
// at 11, 17% at 20, 1.9% at 50, and effectively nothing by 110. Dying is
// brutal just after the level-10 grace period and shrugged off at cap.
//
// The reduction the engine applies before the loss lands IS modelled, and it is
// a proven zero rather than an omission -- see DeathPenaltyReductionPercent.
func (t *Table) DeathPenaltyExp(level, multiplier int) (int64, bool) {
	if level <= DeathPenaltyMinLevel {
		return 0, true
	}
	unit, ok := t.ExpUnit(level)
	if !ok {
		return 0, false
	}
	loss := unit * int64(multiplier)
	if loss < 1 {
		// The real formula clamps at 1 -- its own assert spells the minimum
		// out as 1.0.
		loss = 1
	}
	return ApplyDeathPenaltyReduction(loss, DeathPenaltyReductionPercent), true
}

// DeathPenaltyReductionPercent is the percentage a character's own stat takes
// off an exp death penalty. **Zero, and RECOVERED as zero rather than assumed.**
//
// GObjPC_OnDeath reads it off the DEAD character's own keeper and subtracts a
// percentage of the loss. The id travels in a register, which is why the
// decompiled C shows a bare call; the disassembly spells it out:
//
//	4e6b78  LEA  EDI,[EBP + 0x1ec]        <- the victim's GParamKeeper
//	4e6b7e  MOV  EAX,0x101                <- param 257
//	4e6b83  CALL 0x4b3740                 <- EvaluateParam
//	4e6b88  FDIV qword [0x00b45af0]       <- / 100
//	4e6b8e  FIMUL dword [ESP + 0x14]      <- * the loss
//	4e6b9b  SUB  ESI,EAX                  <- loss -= that
//
// so it is a PERCENTAGE of the loss, not a flat subtraction.
//
// It is zero for an ordinary character because exactly one function in the
// binary writes param 257, and that function is `CTJ_PremiumKeeper::vslot_012`
// -- a class that names itself. It sets 256, 257 and 258 together out of one
// premium-benefit record (offsets +0x300, +0x2c0 and +0x320). So the reduction
// is a PREMIUM ACCOUNT benefit; a character without one has no writer for the
// param and evaluates it at zero. srrevamp has no premium system, so the term
// is structurally zero here rather than unmodelled.
//
// Kept as a named constant, and applied through a function rather than folded
// away, so the engine's shape stays visible and a premium system later has one
// place to change.
const DeathPenaltyReductionPercent = 0

// ApplyDeathPenaltyReduction takes reductionPercent off an exp death penalty,
// the way GObjPC_OnDeath does: a percentage of the loss, subtracted only when
// it comes out positive, and never taking the loss below zero.
func ApplyDeathPenaltyReduction(loss int64, reductionPercent int) int64 {
	if reductionPercent <= 0 || loss <= 0 {
		return loss
	}
	off := int64(math.Round(float64(loss) * float64(reductionPercent) / 100))
	if off <= 0 {
		// The engine only subtracts when the term is positive.
		return loss
	}
	if off >= loss {
		return 0
	}
	return loss - off
}
