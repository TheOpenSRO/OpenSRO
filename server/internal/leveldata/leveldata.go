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

// AN OPEN LEAD IN THE RAW TABLE, recorded 2026-09-16 and deliberately NOT
// promoted. `LevelData.txt` has nine columns and this project maps five of them
// (level, exp-to-next, mastery cost, two provable zeros, kill-exp unit). Columns
// 6, 7 and 8 hold a triple of large, mutually IDENTICAL values that grow fast --
// 70,875 three times at level 1, 2,388,750 three times at level 2.
//
// Three identical values is suggestive of the three jobs (trader, thief, hunter),
// which would make them job experience. **That is a curve and a coincidence of
// arity, which is exactly what this project has been wrong about before**
// (characterdata col 79, twice). Nothing is claimed until a use-site reads one of
// them.
//
// LOOKED FOR THE USE-SITE 2026-09-16, AND THERE IS NONE in the obvious place.
// Every consumer of the level record goes through `RefLevel_GetEntry`
// (`0x00411130`) -- ten callers -- and between them they read exactly three
// offsets: `+0x8/+0xc` (the 64-bit exp to the next level), `+0x10` (the mastery
// cost, summed) and `+0x1c` (the kill-exp unit). **Nothing reads past `+0x1c`.**
//
// That does not prove the columns are dead: the table is an array off the
// reference-data singleton and code could index it without the accessor. It does
// mean the straightforward search has been done and come back empty, so the next
// attempt should start somewhere else -- the job system's own reader, if there is
// one.
//
// StatPointsPerLevel is how many points a character gets to spend (into Str or
// Int) each level.
//
// It was recovered as a rule rather than a table value: a real level-9 character
// window showed 24 stat points, and (9-1)*3 = 24. **The number is now grounded
// in the engine instead** (2026-09-16), and the mechanism explains why it is 3
// and not the 5 the engine actually grants.
//
// GObjPC_SetLevel (`0x004e4d90`) does two things on a level increase, and the
// disassembly is unambiguous about both:
//
//	lea edx,[esi+edi*1]     ; esi = levels gained, edi = points already held
//	lea ecx,[edx+esi*4]     ; ecx = edi + esi*5
//	mov [eax+0x84],cx       ; the pool becomes held + levels*5
//	push esi ; mov eax,esi  ; then SpendStatPoints(str = levels, int = levels)
//	call 0x511470
//
// So the engine grants **five** points per level and immediately spends **two**
// of them -- one into Str and one into Int -- leaving **three** for the player.
// GObjPC_SpendStatPoints (`0x00511470`) is a genuine spend: it refuses unless
// str+int <= the pool, then adds to charData +0x74 (Str) and +0x76 (Int).
//
// The old evidence and the new agree on 3, so nothing changes here. What changes
// is that the reason is the engine's rather than one character window's.
//
// NOT MODELLED YET: the automatic +1 Str and +1 Int per level. srrevamp keeps a
// character's Str and Int at their starting values and accumulates the three
// spendable points without spending them, so a high-level character here has far
// lower stats -- and therefore far lower MaxHP -- than the real game's. That is a
// schema and balance change rather than a constant, so it is recorded in
// docs/GROUNDING_AUDIT.md as the open item instead of being slipped in here.
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
	// expToNext[L] is what leveldata.txt column 1 holds for level L, and it
	// is int64 because THE ENGINE'S FIELD IS 64-BIT.
	//
	// Grounded twice, from different directions. docs/LEVELING.md matched
	// column 1 against a real level-9 character's "Next Exp" of 17,978. And
	// the server reads it as a 64-bit pair: GObjPC_SetLevel stores the level
	// row on the character at +0x1cb0, and GObjPC_GainExpAndLevel reads
	// `row+8` / `row+0xc` together -- including an __alldiv by that pair --
	// while walking rows to carry several levels at once (round 294).
	//
	// The same row's +0x1c is column 5, the exp unit, which is the anchor
	// cmd/export-leveldata already cites; +8/+0xc sits with it in the same
	// record.
	expToNext map[int]int64
	// masterySP[L] is the skill-point cost to raise a mastery from level L to
	// L+1 -- leveldata's column 2. REAL: the server sums exactly this field
	// over the levels being raised. See MasteryUpCost.
	masterySP map[int]int
	// expUnit[L] is the standard EXP a kill is worth at level L -- leveldata's
	// column 5. REAL: see ExpUnit.
	//
	// CONFIRMED INDEPENDENTLY 2026-09-16 from a use-site read fresh:
	// Mastery_LevelUp (`0x0059c4e0`) walks the levels between the mastery's
	// current level and its target, summing `RefLevel_GetEntry(level) + 0x10`,
	// and refuses with 0x3802 when the character's skill points (charData
	// `+0x80`) are less than that sum. So `+0x10` is the per-level mastery cost
	// and the sum is what a multi-level mastery raise actually costs -- which is
	// what this field was already claimed to be.
	expUnit  map[int]int64
	maxLevel int
}

// ExpUnit returns the level table's standard EXP unit for a level, and whether
// the table knows it.
//
// **Recovered, and the rule around it matters as much as the number.**
//
// A CAVEAT on the name, established 2026-09-15 and worth stating before the
// formula: `Formula_MonsterExpReward` is this project's name, and its only two
// callers (GObjPC_OnDeath and FUN_004e6d60) are both reached from the PC
// death-kind dispatch at CGObjPC::vslot_311 -- so every use-site in the binary
// is a PLAYER dying, not a monster. Nothing in the formula is PvP-specific: it
// takes the two levels and the level table and nothing else. But applying it to
// a monster kill is an EXTRAPOLATION, and this file previously called it
// "proven by its use-site" -- which was true of the function's identity and not
// of the application.
//
// It is, however, the ONLY option rather than a choice among several. Both
// character experience fields -- ExpOffset (charData+0x68) and SExpOffset
// (+0x70) -- have exactly one writer in the binary, GObjPC_GainExpAndLevel, and
// all 42 of its call sites are enumerated in docs/RE_COMPLETION.md. None is a
// monster kill: CGObjMob's own death handler (slot 311) and its slot 322/398
// overrides grant no experience at all. So there is no PvE reward formula in
// this binary to have preferred, which is what makes extrapolating from the one
// reward formula it does contain the grounded choice and not a shortcut.
//
// SR_GameServer.exe's Formula_MonsterExpReward (004105d0) computes a kill's
// worth as
//
//	lvl    = min(Char_GetLevel(killer), Char_GetLevel(victim))
//	reward = scaleByWindow * levelTable[lvl]+0x1c * killer[0x1cd8] * scaleByDiff
//
// The `[0x1cd8]` term was long carried here as an unexamined field. It is now
// CHARACTERISED, though not fully named (2026-09-15). On a CGObjPC it is a
// float, written only by GObjPC::FUN_004e30d0, which computes a symmetric pair:
//
//	ref = FUN_0059e870(pc + 0xa30)          // a byte, from a list walk
//	if (ref > 0x78) { pc[0x1cd8] = pc[0x1cdc] = 1.0f; return; }
//	pc[0x1cd8] = clamp(1 - (charLevel - ref) * 0.1, 0.1, 1.9)
//	pc[0x1cdc] =       1 - (ref - charLevel) * 0.1
//
// so the term is a LEVEL-DIFFERENCE modifier bounded to [0.1, 1.9], recomputed
// on exactly three events: PC load (CGObjPC::vslot_212), GObjPC_SetLevel, and
// Mastery_LevelUp. It is 1.0 whenever the reference exceeds 0x78 = 120.
//
// What the reference byte IS has NOT been settled and is deliberately not
// guessed here. Recomputation on mastery level-up, and 120 being exactly the
// 0x78 in Mastery_LevelUp (then read as a single-mastery cap; round 484 found
// it bounds only the cost loop -- see session.MasteryCostLevelCeiling), both
// fit the reference
// being the character's highest mastery level -- which would make this the
// familiar "mastery lagging your level costs you experience" rule. That is a
// hypothesis with two coincidences behind it and no use-site, which is the
// shape of the reasoning that has been wrong twice on this project, so it stays
// a hypothesis. srrevamp does not model the term at all.
//
// Beware the offset: +0x1cd8 means three different things by receiver class --
// a float here on CGObjPC, the rank BYTE on CGObjMob (see
// CGObjMob_ApplyRankSpeedScale), and an integer timer on the siege/COS objects.
//
// floored at 1, and its result goes to GObjPC_GiveExp (vtable slot 421, read
// out of the vtable at 0x00af6090). A second, independent use-site settles what
// the +0x1c field IS: FUN_00631050 hands `entry[0x1c] * multiplier` straight to
// GObjPC_GainExpAndLevel with no formula in between. It goes in as the SKILL
// experience -- the fourth argument -- rather than the experience, which
// corrects an earlier reading here. The same per-level unit feeds a kill's exp,
// a death's penalty AND a skill-point award, which is what makes it the table's
// unit of account rather than one system's constant.
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

// SkillExpPerPoint is how much SKILL EXPERIENCE buys one skill point: 400.
//
// **RECOVERED, and it is a mechanism rather than a number.** srrevamp used to
// hand out whole skill points per kill. The game does not: it grants skill
// experience, accumulates it on the character, and converts whole points out of
// the running total, carrying the remainder.
//
// GObjPC_GainExpAndLevel (004e5250) takes the skill-exp amount as its FOURTH
// and fifth arguments -- a 64-bit pair distinct from the experience in its
// second and third -- and does:
//
//	acc = charData[0x70] + amount        <- _CHAR.SExpOffset, the carried total
//	if acc >= 400 {
//	    sp  = __alldiv(acc, 400)         <- whole points
//	    acc = acc - sp*400               <- remainder stays on the character
//	    this->AddSkillPoints(sp, 0)      <- vtable slot 93
//	}
//	charData[0x70] = acc                 <- persisted, dirty bit 4 set
//
// `charData + 0x70` is `SExpOffset` in the recovered _CHAR schema, and the name
// says what it is: skill experience, offset-encoded like ExpOffset beside it.
//
// The same block is an independent confirmation of last entry's guild naming:
// it only touches its guild-contribution accumulator when `pc[0x72f]` is
// non-null, and `[0x72f]` was named GUILD from CGObjPC::GetGuildName.
const SkillExpPerPoint = 400

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

// MasteryExpPenaltyPerLevel and the MasteryExpScale bounds are the game's
// "keep your mastery up with your level" rule: **0.1 lost per level your best
// mastery lags behind your character level, clamped to [0.1, 1.9]**. RECOVERED,
// including what the reference actually is -- which took two ticks and a
// refused guess to settle.
//
// GObjPC_RecalcLevelDiffExpScale (0x004e30d0) is the only writer of the float
// at pc+0x1cd8 that Formula_MonsterExpReward multiplies a kill's reward by:
//
//	ref = Mastery_MaxLevel(pc + 0xa30)
//	if (ref > 0x78) { pc[0x1cd8] = pc[0x1cdc] = 1.0f; return; }   // 0x78 = 120
//	pc[0x1cd8] = clamp(1 - (charLevel - ref) * 0.1, 0.1, 1.9)
//	pc[0x1cdc] =        1 - (ref - charLevel) * 0.1               // the mirror
//
// K is `fmul QWORD ds:0xb45ec0` = 0.1, a double; the clamp bounds are the float
// at 0xb45eb8 (0.1) and 0xb45f18 (1.9). It is recomputed on exactly three
// events: PC load, GObjPC_SetLevel and Mastery_LevelUp -- and that last one is
// the tell that the reference tracks masteries.
//
// HOW THE REFERENCE WAS SETTLED, because the previous tick recorded it as an
// explicitly refused guess. Two coincidences pointed at "highest mastery level"
// -- recomputation on mastery level-up, and 0x78 being exactly the 0x78 in
// Mastery_LevelUp (then read as a single-mastery cap; round 484 found it bounds
// only the cost loop) -- and that is the shape of reasoning that got
// characterdata column 79 wrong twice, so it was not promoted. What settled it
// is a USE-SITE: FUN_0059e7c0 walks the identical list under pc+0xa30 with the
// identical skip rule and value path but SUMS instead of taking the maximum,
// and Mastery_LevelUp compares `that sum + the levels requested` against its
// total-mastery cap. A function whose result is the thing a mastery cap is
// checked against is summing mastery levels; its twin over the same list is
// therefore the highest mastery level.
//
// SCOPE: a character with NO mastery is not special-cased by the engine. The
// only escape is ref > 120, which only a character above level 120 can reach (a
// mastery is capped at the character's level, 0x3804 in Mastery_LevelUp, and
// at nothing lower -- round 484), so a level-10 character who has never raised
// a mastery really does fall to the 0.1 floor.
// That is the mechanic, not an oversight -- but it means the penalty is severe
// for a character that ignores masteries entirely.
const (
	MasteryExpPenaltyPerLevel = 0.1
	MasteryExpScaleMin        = 0.1
	MasteryExpScaleMax        = 1.9

	// MasteryExpRefCap is the reference value above which the engine gives up
	// and returns a flat 1.0 -- 0x78, the same 120 that bounds Mastery_LevelUp's
	// cost loop (session.MasteryCostLevelCeiling). It does not cap a mastery.
	MasteryExpRefCap = 120
)

// MasteryExpScale returns the multiplier a kill's experience takes from the gap
// between a character's level and its highest mastery level. 1.0 means no
// adjustment; below 1.0 the mastery is lagging, above it the mastery is ahead.
func MasteryExpScale(charLevel, maxMasteryLevel int) float64 {
	if maxMasteryLevel > MasteryExpRefCap {
		return 1.0
	}
	scale := 1.0 - float64(charLevel-maxMasteryLevel)*MasteryExpPenaltyPerLevel
	if scale < MasteryExpScaleMin {
		return MasteryExpScaleMin
	}
	if scale > MasteryExpScaleMax {
		return MasteryExpScaleMax
	}
	return scale
}

// PartyExpBonusPerMember is the extra share of a kill's experience each
// ADDITIONAL party member is worth: **0.03, i.e. 3% per member beyond the
// first.** RECOVERED, not chosen.
//
// CGObjCOS_GoldPet::vslot_399 builds the multiplier just before handing each
// contributor its award, and the disassembly spells it out:
//
//	4d6bb9  FLD1                          <- the multiplier starts at 1.0
//	4d6bcd  CMP  DWORD [EDI + 0x1cb8],0   <- pc[0x72e], the party field
//	4d6bd4  JE   ...                      <- no party: stays 1.0
//	4d6bd9  CALL 0x4ea230                 <- the party's member count
//	4d6bde  SUB  EAX,1                    <- members - 1
//	4d6be9  FMUL QWORD ds:0xb45dc8        <- * 0.03
//	4d6bef  FADD QWORD ds:0xb45ac0        <- + 1.0
//
// Both constants are read as QWORD, so they are DOUBLES: 0.03 and 1.0. Read as
// float32 the first is -3.7e19, which is the usual reminder that operand size
// decides a float constant in this binary.
//
// WHAT THE COUNT IS, settled 2026-09-16 rather than assumed. The call at 4d6bd9
// is GObjPC::FUN_004ea230, and it is four instructions long:
//
//	if (pc[0x1cb8] == 0) Assert;   // there must be a party
//	return *(party + 0x1c);        // the member count
//
// `party + 0x1c` is the **same field the join-time cap compares against 8 or 4**
// (see party.MaxSize). So it is the TOTAL party size, not a subset filtered by
// range or eligibility, and srrevamp passing len(pt.Members) is the right input.
//
// TWO GATES, AND ONE THAT IS ABSENT. The chain applies the bonus only when
//
//	4d6bc1  mov  eax,[edx+0x1c]   <- vtable slot 7 = IGObj::IsPC
//	4d6bc8  cmp  eax,0x1          <- players only
//	4d6bcd  cmp  DWORD [edi+0x1cb8],0 / je   <- and only with a party
//
// and it does **not** test the party's exp-sharing flag. That absence is worth
// recording now that the flag is known to exist: bit 0 of the party's +0x10
// selects the member cap (8 shared, 4 not), so a reader could reasonably expect
// the exp bonus to depend on it too. It does not. srrevamp applying the bonus
// unconditionally is therefore correct, and now checked rather than unexamined.
//
// SCOPE, because this is only part of what the engine does with a party. The
// real server also scales each contributor's award by its share of the victim's
// maximum HP -- Formula_ExpShareByDamage clamps damage/MaxHP to [1e-6, 1.0] --
// and then distributes to party members through GObjPC_DistributePartyExp.
// srrevamp does neither: it awards the whole unit to the killer. For the killer
// that is exactly right, because a solo contributor's share clamps to 1.0, and
// the bonus below then matches the engine for that character. What srrevamp
// still does NOT do is give the other party members anything, which is a
// separate missing feature rather than a wrong number.
const PartyExpBonusPerMember = 0.03

// PartyExpBonus returns the multiplier applied to a kill's experience for a
// party of the given size. A solo character (or any size below 2) gets 1.0.
func PartyExpBonus(members int) float64 {
	if members < 2 {
		return 1.0
	}
	return 1.0 + float64(members-1)*PartyExpBonusPerMember
}

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
// THE PARTY GAP BONUS (round 480; this paragraph said "NOT MODELLED" until
// then). Before the arithmetic above, the function builds a bonus that the
// `FADD [ESP + 0x8]` then adds on top of the 1.0, and it builds it only behind
// three gates, all on ESI:
//
//	41000d  MOV EDX,[EAX + 0x1c] ; CALL EDX        <- vtable slot 7 = IGObj::IsPC
//	410016  JE  none
//	410018  MOV EAX,[ESI + 0x1cb8] ; TEST ; JE     <- pc[0x72e], the party
//	410022  MOV CL,0x1
//	410024  TEST BYTE [EAX + 0x10],CL ; JE none    <- bit 0 of the party's flags
//	410029  MOV EDX,[ESI + 0x34] ; MOV EDX,[EDX + 0x18]
//	410033  CMP BYTE [EDX + 0x88],CL ; JNE china   <- the ref object's Country == 1?
//	410062  china:  CMP EAX,9 ; JL -> CMP EAX,7 ; JL -> CMP EAX,5 ; JL none
//	41003b  europe: the same three compares, 0x41003b-0x410058
//	41008b  FLD [ESP + 0x8] ; FADD qword [0x00b45ac0]  <- bonus + 1.0
//
// with EAX = victim - killer at the compares. `CMP ; JL` makes each threshold
// inclusive: a gap of exactly 5, 7 or 9 is the first to earn its step.
//
// Bit 0 of the party's +0x10 is the EXP-SHARING flag. CParty::CheckCanJoin
// (0x514560) caps a party at 8 when it is set and 4 when it is clear, and the
// client names the two refusals `0x2c13 UIIT_MSG_PARTYERR_MEMBER_FULL_EXP_
// SHARED_PARTY` and `0x2c14 ..._NONEEXP_SHARED_PARTY` (docs/protocol/party.md,
// "Size: two caps, selected by a flag"). `[0x72e]` is the party pointer, named
// by the binary's own assert through CGObjPC::GetPartyInfo (vtable slot 76).
//
// ESI is the character RECEIVING the experience: the call sites load ESI from
// the register whose +0x1cd8/+0x1cdc -- the receiver's own mastery-lag scale,
// see MasteryExpScale -- they have just read (0x410233 -> 0x41023b, 0x410660 ->
// 0x410668, 0x41076f -> 0x410777), and the byte at its ref object's
// +0x88 is Country (the common table's column 14: 0 China, 1 Europe, 3 either),
// the same byte the equip check compares for `0x182f STRGERR_COUNTRY_MISMATCH`.
//
// srrevamp's parties are all exp-sharing -- party.MaxSize is the exp-shared cap
// and no non-sharing party exists -- so the gate reduces to being in a party at
// all. That includes a party of ONE: the engine tests the pointer, not the
// member count, unlike PartyExpBonus, whose (members-1) term is zero for one.
//
// The cap is still unreachable: with the bonus the scale peaks at 1.84 for
// China (1.39 + 0.45) and 2.29 for Europe (1.39 + 0.9), against 4.0.
const (
	ExpDiffScalePerStep  = 0.03
	ExpDiffScaleMaxSteps = 13
	ExpDiffScaleCap      = 4.0
)

// The six party gap bonuses, each an `FLD DWORD` of a float32 in .rdata --
// 32-bit floats, carried here as their decimals like ExpWindowNearBelow. China
// is the branch taken when the receiver's Country byte is not 1 (0x410062),
// Europe the branch when it is (0x41003b). 0x00b45b8c serves both as China's
// seven-level step and Europe's five-level one.
const (
	ExpDiffPartyGap5 = 0.15 // FLD DWORD [0x00b45dd0], 0x410081
	ExpDiffPartyGap7 = 0.30 // FLD DWORD [0x00b45b8c], 0x410074
	ExpDiffPartyGap9 = 0.45 // FLD DWORD [0x00b45dd4], 0x410067

	ExpDiffPartyEuropeGap5 = 0.30 // FLD DWORD [0x00b45b8c], 0x41005a
	ExpDiffPartyEuropeGap7 = 0.60 // FLD DWORD [0x00b45dd8], 0x41004d
	ExpDiffPartyEuropeGap9 = 0.90 // FLD DWORD [0x00b45ddc], 0x410040
)

// ExpDiffPartyBonus is the extra a receiver in an exp-sharing party earns for
// a target five or more levels above it: the `CMP EAX,9/7/5 ; JL` ladder at
// 0x41003b-0x410081. europe selects the ref object's Country == 1 branch. It
// does not apply the party gate itself -- ExpDiffScale does.
func ExpDiffPartyBonus(killerLevel, victimLevel int, europe bool) float64 {
	gap := victimLevel - killerLevel
	gap5, gap7, gap9 := ExpDiffPartyGap5, ExpDiffPartyGap7, ExpDiffPartyGap9
	if europe {
		gap5, gap7, gap9 = ExpDiffPartyEuropeGap5, ExpDiffPartyEuropeGap7, ExpDiffPartyEuropeGap9
	}
	switch {
	case gap >= 9:
		return gap9
	case gap >= 7:
		return gap7
	case gap >= 5:
		return gap5
	}
	return 0
}

// ExpDiffScale returns the level-gap multiplier on a kill's experience.
// expSharingParty is the engine's gate -- the receiver is a player in a party
// whose flag bit 0 is set -- and europe its Country selector; see the constants
// above for both.
func ExpDiffScale(killerLevel, victimLevel int, expSharingParty, europe bool) float64 {
	// Out-levelling the target by three or more is worth no bonus at all --
	// the engine returns a bare 1.0 without reaching the arithmetic below.
	// (It builds the party bonus first and discards it here, but that bonus
	// needs a gap of +5, so nothing is lost.)
	if victimLevel+3 <= killerLevel {
		return 1
	}
	steps := victimLevel - killerLevel + 3
	if steps > ExpDiffScaleMaxSteps {
		steps = ExpDiffScaleMaxSteps
	}
	scale := 1 + float64(steps)*ExpDiffScalePerStep
	if expSharingParty {
		scale += ExpDiffPartyBonus(killerLevel, victimLevel, europe)
	}
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
// here -- see ExpDiffScale and ExpWindowScale. expSharingParty is ExpDiffScale's
// party gate (the killer is in an exp-sharing party, which every srrevamp party
// is). Its Country selector is passed as China, always: every srrevamp
// character is one (character.ValidGender admits only the two China genders,
// and equipment.Refusal refuses a Europe item on exactly that ground), so the
// Europe arm of the bonus is recovered but never selected.
//
// What remains unmodelled is the killer's own exp-rate multiplier, a float at
// killer+0x1cd8 written only by CTJ_PremiumKeeper's neighbours; it is a
// premium/event rate and a character without one evaluates it at its default,
// so what ships is the game's formula at the base rate.
func (t *Table) KillExp(killerLevel, victimLevel int, expSharingParty bool) (int64, bool) {
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
		// europe = false: every srrevamp character is China (see above).
		ExpDiffScale(killerLevel, victimLevel, expSharingParty, false)))
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
// _CHAR.PKPenaltyPoint, from the recovered schema; the test is `< 1`).
//
// THE STATE ENUM IS RECOVERED (2026-09-16) and these names are no longer an
// inference. The byte at victim+0x1cb4 that GObjPC_OnDeath compares against 5
// is the death CAUSE -- see DeathCause, which carries the derivation. 5 is
// "the killer is a player" and 3 is "the killer is not", settled by a use-site:
// the value comes from `FUN_004eb390`, which tests both parties through vtable
// slot 7, and slot 7 is IsPC by the engine's own `## Illegal ##` stub. So
// KilledByMonster and KilledByPlayer are the engine's distinction, read off the
// engine, rather than a reading of the multipliers.
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
// Exactly one function in the binary writes param 257, and that function is
// `CTJ_PremiumKeeper::vslot_012` -- a class that names itself. It sets 256, 257
// and 258 together out of one premium-benefit record (offsets +0x300, +0x2c0
// and +0x320). So the reduction is a PREMIUM ACCOUNT benefit, and a character
// without one has no writer for it.
//
// An unwritten param does not simply read as zero, though -- it reads as its
// DEFAULT. Reading goes through ParamKeeper_ReadParam, which calls
// ParamKeeper_EnsureParam first to create the param from a descriptor record,
// and ParamKeeper_EvaluateParam falls back to that record's default whenever
// slot 0 holds no entries. So the value of this constant is whatever param 257
// defaults to.
//
// That default has now been read out of the binary. The descriptor records are
// a static table at VA 0x00c64110 -- 120 params, 20 bytes each -- and **param
// 257's default is 0** (min 0, max 1000). See docs/protocol/param_registry.md
// for the whole table and how it was recovered. So a character with no premium
// benefit really does take the full penalty, and this zero is RECOVERED rather
// than assumed or chosen.
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
