package leveldata

// The death-cause enum, recovered 2026-09-16. It was the last open piece of the
// death penalty: `GObjPC_OnDeath` picks its multiplier partly from a byte at
// victim `+0x1CB4` (`pc[0x72d]`) compared against 5, and what that byte meant
// was unknown, so the penalty constants were named by inference.
//
// EXACTLY ONE FUNCTION WRITES IT. `GObjPC::FUN_004e6ec0` (server `0x004e6ec0`,
// 81 bytes) computes the value and dispatches on it in the same breath:
//
//	uVar1 = FUN_004e6590();               // resolve the cause
//	*(byte *)(this + 0x1cb4) = uVar1;     // store it
//	switch (uVar1) {
//	case 1:               FUN_004e6820(); return;   // job-suit death
//	case 3: case 4: case 5: GObjPC_OnDeath(); return;
//	case 6:               FUN_004e6d60(); return;
//	}
//
// so three of the values mean "this death carries the penalty" and the others
// route elsewhere or nowhere.
//
// WHAT SEPARATES 3 FROM 5 is a use-site, not a guess. `FUN_004e6590` ends:
//
//	iVar2 = FUN_004eb390(in_EAX);
//	return (-(uint)(iVar2 != 1) & 0xfffffffe) + 5;   // 5 when it returns 1, else 3
//
// and `FUN_004eb390` gates on `(**(code **)(*obj + 0x1c))()` for both parties.
// Vtable byte offset 0x1c is slot 7, and slot 7 is **`IsPC`** -- named by the
// engine's own `"## Illegal ##  IGObj::IsPC Entered! TypeID: %u"` stub, with
// `IsNPC` at slot 8 and `IsMonster` at slot 10 for corroboration. So 5 means
// the killer is a player and 3 means it is not.
//
// That agrees with the multipliers already read out of `GObjPC_OnDeath`, which
// is the check rather than the finding: the branch taken when the byte is NOT 5
// is the 100x/300x pair, and a monster kill costing more than a player kill is
// what the table says.
type DeathCause int

const (
	// DeathCauseNone is returned when either party is missing or the victim
	// fails the liveness test. Nothing is dispatched.
	DeathCauseNone DeathCause = 0
	// DeathCauseJobSuit is a death while wearing the job suit. FUN_004e6590
	// reaches it through `(**(code **)(*obj + 0x578))(8)` -- equipment slot 8,
	// which equipment.SlotJobSuit already names -- and it dispatches to
	// FUN_004e6820 instead of the ordinary death handler, so the job system
	// has its own penalty.
	DeathCauseJobSuit DeathCause = 1
	// DeathCauseNoPenalty is the value the zone and faction predicates
	// produce (FUN_004eb320, and two singleton checks behind a 10-second
	// GetTickCount gate). It is NOT in the dispatch switch at all, so such a
	// death costs nothing.
	DeathCauseNoPenalty DeathCause = 2
	// DeathCauseMonster is a death whose killer is not a player.
	DeathCauseMonster DeathCause = 3
	// DeathCauseOther is the third value the dispatch switch sends to
	// GObjPC_OnDeath. FUN_004e6590 never returns it, so whatever sets it is
	// elsewhere -- recorded because the switch names it, not because its
	// meaning is known.
	DeathCauseOther DeathCause = 4
	// DeathCausePlayer is a death whose killer is a player.
	DeathCausePlayer DeathCause = 5
	// DeathCauseZone is the value behind FUN_0062eb50 + FUN_005f88f0, which
	// dispatches to FUN_004e6d60 rather than to the death handler.
	DeathCauseZone DeathCause = 6
)

// CarriesExpPenalty reports whether a death with this cause reaches
// GObjPC_OnDeath at all. Straight off the dispatch switch: 3, 4 and 5 do,
// everything else does not.
func (c DeathCause) CarriesExpPenalty() bool {
	return c == DeathCauseMonster || c == DeathCauseOther || c == DeathCausePlayer
}

// DeathPenaltyFactorFor gives the EXP multiplier and the skill-point cost for a
// death, in the engine's own terms. pkFlagged is the victim carrying PK penalty
// points (charData+0xb4 = _CHAR.PKPenaltyPoint; the engine's test is `< 1`).
//
// ok is false for a cause that never reaches the penalty block, so a caller
// cannot silently charge a death the engine would have let go.
//
// SRREVAMP ONLY EVER REACHES DeathCauseMonster: there is no PK system, no job
// suit and no siege zone, so the other causes are implemented and tested but
// unreachable. That is a disclosure, not a claim that they are dead code in the
// real game.
func DeathPenaltyFactorFor(cause DeathCause, pkFlagged bool) (expFactor, skillPoints int, ok bool) {
	if !cause.CarriesExpPenalty() {
		return 0, 0, false
	}
	if cause == DeathCausePlayer {
		if pkFlagged {
			return DeathPenaltyKilledByPlayerFlagged, DeathPenaltySkillPointsPlayerFlagged, true
		}
		return DeathPenaltyKilledByPlayer, 0, true
	}
	// DeathCauseMonster and DeathCauseOther both take the not-a-player branch,
	// because the engine's test is `byte != 5` rather than `byte == 3`.
	if pkFlagged {
		return DeathPenaltyKilledByMonsterFlagged, DeathPenaltySkillPointsMonsterFlagged, true
	}
	return DeathPenaltyKilledByMonster, 0, true
}
