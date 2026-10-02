package skill

// The masteries a character HOLDS, by its Country (round 691).
//
// READ, from the retail shard's character creation: the stored procedure
// _AddNewChar seeds a new character's _CharSkillMastery rows with
//
//	INSERT INTO _CharSkillMastery (CharID, MasteryID, Level)
//	SELECT @NewCharID, MasteryID, 0 FROM _RefCharDefault_SkillMastery
//	WHERE Race = @country or Race = 3
//
// where @country is _GetObjCountry of the body's ref object, and
// _RefCharDefault_SkillMastery holds 13 rows (the retail DB export on the
// render box, /opt/sro-files/db/csv/charsel/): Race 0 -> 257, 258, 259, 273,
// 274, 275, 276; Race 1 -> 513, 514, 515, 516, 517, 518; no Race-3 row. So a
// China character holds the seven China masteries at level 0 from birth and a
// Europe character the six Europe ones, and NEITHER ever holds the other's.
//
// The game server enforces that through the held list, not a race test:
// FUN_0059d6f0 looks the mastery id up in the character's mastery map
// (+0x234) and returns nothing for an id it does not hold, and both callers
// refuse on that -- Mastery_LevelUp (0x0059c4e0) with 0x3801 and the learn
// check FUN_0059e450 (called from Skill_HandleLearn 0x0059bfe0) with 0x3401.
// srrevamp's held list is derived from the Country here. Since round 692 a new
// character is also seeded with its race's masteries as level-0 rows
// (SeedMasteries, from the same table) -- characters made before 692 hold only
// the rows they raised -- and the two agree: every seeded row is one
// HoldsMastery answers true for, and a stored row of another race (raisable
// before round 691) is ignored by every check that uses this list.
//
// The mastery ids are the skillmasterydata.txt ids (column 0) the client's
// window titles them with: 513 Warrior, 514 Wizard, 515 Rogue, 516 Warlock,
// 517 Bard, 518 Cleric (READ, the table's own name codes UIIT_STT_WARRIOR /
// _WIZARD / _ROG / _WARLOCK / _BARD / _CLERIC).
var raceMasteries = map[int][]int64{
	0: {257, 258, 259, 273, 274, 275, 276},
	1: {513, 514, 515, 516, 517, 518},
}

// The Europe mastery ids (skillmasterydata.txt column 0, READ).
const (
	MasteryWarrior int64 = 513
	MasteryWizard  int64 = 514
	MasteryRogue   int64 = 515
	MasteryWarlock int64 = 516
	MasteryBard    int64 = 517
	MasteryCleric  int64 = 518
)

// DefaultMasteries returns the masteries a character of the given Country
// holds (a copy; nil for a Country _RefCharDefault_SkillMastery has no row
// for -- which then holds nothing and can raise nothing).
func DefaultMasteries(country int) []int64 {
	src := raceMasteries[country]
	if src == nil {
		return nil
	}
	return append([]int64(nil), src...)
}

// HoldsMastery reports whether a character of the given Country holds
// masteryID -- FUN_0059d6f0's answer for a character _AddNewChar created.
func HoldsMastery(country int, masteryID int64) bool {
	for _, id := range raceMasteries[country] {
		if id == masteryID {
			return true
		}
	}
	return false
}

// LearnRaceAllows is the learn check's race clause (FUN_0059e450, READ):
// the skill's ReqLearn_Race byte (CRefSkill+0xc4, skilldata column 47) must be
// 3 or equal the character's Country (`*(ref+0x18)+0x88`), else 0x3405.
// MEASURED on the retail table: every row of a China mastery (257-276) carries
// 0 except the three CH base attacks (3), and every row of a Europe mastery
// (513-518) carries 1 -- 2,942 and 3,242 rows.
func LearnRaceAllows(reqLearnRace, country int) bool {
	return reqLearnRace == 3 || reqLearnRace == country
}
