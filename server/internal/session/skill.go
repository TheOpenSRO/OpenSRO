package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math/rand"
	"sort"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/berserk"
	"github.com/OpenSRO/OpenSRO/server/internal/buff"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Skill opcodes, our own protocol. All three require a prior OpLogin;
// OpUseSkill additionally requires a prior successful OpEnterWorld (same
// as OpAttack).
const (
	OpLearnSkill       uint16 = 0x0070 // client -> server
	OpLearnSkillResult uint16 = 0x0071 // server -> client
	OpUseSkill         uint16 = 0x0072 // client -> server
	// OpUseSkill's response reuses OpAttackResult -- using a skill is just
	// an attack with a damage bonus, and the client needs the exact same
	// information either way.
	OpSkillList       uint16 = 0x0073 // client -> server
	OpSkillListResult uint16 = 0x0074 // server -> client
	// The skill economy: a character's skill points (earned from mob kills)
	// and its per-mastery trained levels, and raising a mastery a level by
	// spending points. What the skill window's totals and lit/greyed skills
	// are driven by.
	OpSkillState         uint16 = 0x0075 // client -> server
	OpSkillStateResult   uint16 = 0x0076 // server -> client
	OpRaiseMastery       uint16 = 0x0077 // client -> server
	OpRaiseMasteryResult uint16 = 0x0078 // server -> client
)

// The mastery TOTAL cap -- the most the SUM of a character's mastery levels may
// reach -- is chosen by the character's Country, and for China it is a FLAT 330
// with no reference to the character's level.
//
// RECOVERED from Mastery_LevelUp (0x0059c4e0). Before anything else it switches
// on a byte of the character's ref object, `(charData+0x18)+0x88` (on-disk
// build: `movzx eax,BYTE PTR [eax+0x88]` at 0x59c53c, then `sub eax,0 / je`,
// `sub eax,1 / je`, `sub eax,1 / je`), and applies one of three rules:
//
//	0:     refused (0x3805) unless `sum + requested < 0x14b` -- a flat 330
//	       (on-disk build: `cmp eax,0x14a ; jg` at 0x59c5e6)
//	1:     refused (0x3805) unless `sum + requested <= 240.0` (the .rdata double
//	       at 0xb46130, compared with FCOMP QWORD) AND `<= level + level`
//	2:     no total cap at all
//	other: refused with 0x3801
//
// THE SELECTOR IS COUNTRY, identified by a use-site rather than by its shape.
// CGItemEquip::CanBeEquipedAt (0x00497070) walks the SAME path on both the item
// and the character -- `*(*(obj+0x34)+0x18)+0x88` -- compares the two bytes and
// refuses with 0x182f UIIT_MSG_STRGERR_COUNTRY_MISMATCH unless the item's is 3.
// RefObjCommon_ExtractData stores common-table column 14 at +0x88, and
// ITEM_FORMAT.md pins column 14 as Country (0 China, 1 Europe, 3 either; "CH"
// and "EU" code names agree on every row). A character's ref object is filled
// by the same ExtractData -- RefObjChar_ExtractData (0x006a58f0) passes its own
// `this` to it at 0x6a5908 -- so the character's +0x88 is its Country too
// (docs/protocol/item_capability_flags.md; docs/RE_COMPLETION.md, "And the
// column numbers are still not the read numbers"). A China character wears
// Country-0 gear through that very check, so China is 0 and takes the flat 330;
// Europe (1) takes min(240, 2 x level).
//
// This REVERSES the 2026-09-15/16 decision to keep a "3 x character level" rule.
// That rule was an extrapolation from an account of the retail 80-cap total of
// 240, not a reading of any binary; none of the three branches is 3 x level, and
// the selector that decision said was unidentified is identified above.
//
// A single mastery is separately capped at the character's own level (0x3804),
// and at nothing else: the 0x78 = 120 in the same function bounds the COST loop,
// not the level -- see MasteryCostLevelCeiling.
const (
	MasteryTotalCapChina  = 330 // Mastery_LevelUp selector 0: `sum + requested < 0x14b`
	MasteryTotalCapEurope = 240 // Mastery_LevelUp selector 1: the double 240.0 at 0xb46130
)

// masteryCountryUncapped is the Country byte for which Mastery_LevelUp applies
// no total cap at all (selector 2 of 0x0059c4e0). WHICH country that is is not
// identified -- ITEM_FORMAT.md's Country vocabulary is 0, 1 and 3, and 2 is not
// among them -- so it is named for what the engine does with it, not a race.
const masteryCountryUncapped = 2

// Mastery_LevelUp's refusal codes for the total cap (0x0059c4e0; the full list
// is in docs/RE_COMPLETION.md, "The mastery cap is three rules, not one").
const (
	masteryErrInvalid  uint16 = 0x3801 // unknown mastery, or a Country with no rule
	masteryErrTotalCap uint16 = 0x3805 // the mastery total would pass its cap
)

// masteryTotalRefusal is Mastery_LevelUp's total-cap branch (0x0059c4e0): the
// error code the engine answers when a character of the given Country, whose
// masteries sum to total, asks for requested more levels at charLevel -- or 0
// when the total cap allows it. The per-mastery checks that follow it in the
// engine (0x3804 the character's level, 0x3802 the skill points) are the
// caller's.
//
// The engine's sum (FUN_0059e7c0, called at each total compare) skips a mastery
// entry whose status byte, `*(entry+0x10)+0xc`, is 3 -- the same state
// FUN_0059d6f0, Mastery_LevelUp's first check, treats as "no such mastery"
// (0x3801). OpenSRO stores no such state, so the caller's total counts every
// stored mastery; nothing it holds would be excluded.
func masteryTotalRefusal(country, total, requested, charLevel int) uint16 {
	sum := total + requested
	switch country {
	case equipment.CountryChina:
		if sum > MasteryTotalCapChina {
			return masteryErrTotalCap
		}
	case equipment.CountryEurope:
		if sum > MasteryTotalCapEurope || sum > 2*charLevel {
			return masteryErrTotalCap
		}
	case masteryCountryUncapped:
		// Selector 2 jumps straight past the cap (0x59c554 -> 0x59c5ed).
	default:
		return masteryErrInvalid
	}
	return 0
}

// characterCountry is the Country byte (ref object +0x88, common column 14) of
// a character: its body's race (character.RaceOf its Gender, which round 682
// derives from RefObjID). Until round 682 every OpenSRO character was China
// and this returned China outright; Europe is creatable now (the user's
// decision, 2026-10-02), so the mastery total cap and the potion reuse delay
// read the real race here.
func characterCountry(c *character.Character) int {
	if c != nil && character.RaceOf(c.Gender) == character.RaceEurope {
		return equipment.CountryEurope
	}
	return equipment.CountryChina
}

// MasteryCostLevelCeiling is the highest mastery level whose raise costs skill
// points: 120. It is NOT a cap on the mastery's level.
//
// RECOVERED from Mastery_LevelUp (0x0059c4e0). The cost loop's bound jumps to
// the skill-point check, not to a refusal (on-disk build; the Ghidra dump reads
// `if (0x78 < (int)uVar4) break;` inside the same loop):
//
//	59c63c  movzx esi,cl                ; esi = the mastery's current level
//	59c64e  cmp esi,0x78 ; jg 0x59c687  ; past 120: stop summing ...
//	59c669  call 0x411130               ; RefLevel_GetEntry(esi) = rows[esi-1]
//	59c66e  mov ecx,[eax+0x10]          ; leveldata column 2
//	59c67c  add [esp+0x14],ecx          ; cost += it
//	59c687  ...                         ; ... and fall into the SP check
//	59c694  cmp eax,[ecx+0x80] ; jbe    ; cost <= skill points, else 0x3802
//	59c6b3  add cl,0x1                  ; the raise: level + 1, written at 0x59c6cb
//
// So a raise from a level above 120 sums nothing, costs 0, and still happens.
// The only per-mastery refusal is 0x3804 at 0x59c611, `current + requested >
// GetLevel()` (vtable +0x124, IGObj::GetLevel): a mastery may reach the
// character's level and nothing lower binds. This replaces a MasteryLevelCap =
// 120 that refused the raise at 120 -- a reading of the loop bound as a refusal
// that the instructions do not bear out (round 484).
const MasteryCostLevelCeiling = 120

// masteryUpCost is the skill-point cost to raise a mastery from currentLevel to
// currentLevel+1.
//
// **This is REAL when a level table is loaded.** The pserver's own mastery
// level-up handler (FUN_0059c4e0) walks the levels being raised, accumulates
// the level table's entry+0x10 for each, and refuses the raise when the
// character's skill points (charData+0x80) fall short. A level entry holds the
// int64 EXP requirement at +8, so +0x10 is the field straight after it, which
// is leveldata's column 2 -- 1, 1, 1, 2, 2, 4, 5, 6, 7, 9, 12 ... 53 at level
// 20 and 172 at level 32 (levels 1-11, 20 and 32 re-read from the player's
// leveldata.txt in round 518). leveldata.Table.MasteryUpCost serves it.
//
// Two levels cost nothing, whatever the table says, because the engine never
// reads the table for them:
//
//   - Level 0, the FIRST point in a mastery. Mastery_LevelUp tests the level
//     before the loop -- `test cl,cl ; jne 0x59c638` at 0x59c628 -- and on zero
//     calls the level setter FUN_005a8bf0 with cl = 1 (0x59c62c-0x59c62e: it
//     writes cl to the record's +0x20) and jumps to 0x59c6d8, past both the cost
//     loop and the 0x3802 check. The cost at [esp+0x14] stays at the 0 stored at
//     0x59c51d, and the spend at 0x59c793 (`test esi,esi ; jle`) is skipped.
//     RefLevel_GetEntry indexes rows[level-1], so level 0 has no row to read.
//   - Above MasteryCostLevelCeiling (120): the loop breaks before summing.
//
// Falls back to a DISCLOSED own-design currentLevel+1 when no level table is
// loaded (or it predates the column), which is the same shape as the rest of
// the leveling code: real when the operator brings the data, honestly labelled
// when they do not.
func masteryUpCost(currentLevel int) int {
	if currentLevel == 0 || currentLevel > MasteryCostLevelCeiling {
		return 0
	}
	if cost, ok := levelTable.MasteryUpCost(currentLevel); ok && cost > 0 {
		return cost
	}
	return currentLevel + 1
}

// LearnSkillRequest is the OpLearnSkill payload.
type LearnSkillRequest struct {
	CharacterName string
	SkillID       int64
}

func (r *LearnSkillRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.SkillID)...)
}

func DecodeLearnSkillRequest(data []byte) (*LearnSkillRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LearnSkillRequest: %w", err)
	}
	skillID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LearnSkillRequest: skill id: %w", err)
	}
	return &LearnSkillRequest{CharacterName: fields[0], SkillID: skillID}, nil
}

// LearnSkillResult is the OpLearnSkillResult payload.
type LearnSkillResult struct {
	OK     bool
	Reason string
}

func (r *LearnSkillResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeLearnSkillResult(data []byte) (*LearnSkillResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LearnSkillResult: %w", err)
	}
	return &LearnSkillResult{OK: ok, Reason: reason}, nil
}

// UseSkillRequest is the OpUseSkill payload.
//
// TargetType and the ground point are a strict suffix (round 616,
// docs/protocol/skill_buffs.md): u8 targetType -- TargetNone (0, none or
// self), TargetEntity (1) or TargetGround (2) -- and, for TargetGround only,
// the point as three f32 in the frame OpMove uses. HasTargetType says the
// suffix is there; a request without it, from any client before round 617,
// is an entity target with the target in TargetMonsterID, exactly what it
// meant before. Read the effective value through Target.
type UseSkillRequest struct {
	CharacterName   string
	SkillID         int64
	TargetMonsterID int64
	TargetType      uint8
	HasTargetType   bool
	X, Y, Z         float32
}

// Target is the request's targetType: TargetEntity without the suffix.
func (r *UseSkillRequest) Target() uint8 {
	if r.HasTargetType {
		return r.TargetType
	}
	return TargetEntity
}

func (r *UseSkillRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	out = append(out, encodeInt64(r.SkillID)...)
	out = append(out, encodeInt64(r.TargetMonsterID)...)
	if !r.HasTargetType {
		return out
	}
	out = append(out, r.TargetType)
	if r.TargetType == TargetGround {
		out = append(out, encodeFloat32(r.X)...)
		out = append(out, encodeFloat32(r.Y)...)
		out = append(out, encodeFloat32(r.Z)...)
	}
	return out
}

func DecodeUseSkillRequest(data []byte) (*UseSkillRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseSkillRequest: %w", err)
	}
	skillID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseSkillRequest: skill id: %w", err)
	}
	targetID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseSkillRequest: target id: %w", err)
	}
	req := &UseSkillRequest{CharacterName: fields[0], SkillID: skillID, TargetMonsterID: targetID}
	if len(rest) == 0 {
		return req, nil // an older client: an entity target
	}
	req.TargetType, req.HasTargetType = rest[0], true
	rest = rest[1:]
	switch req.TargetType {
	case TargetNone, TargetEntity, TargetCharacter:
	case TargetGround:
		for _, dst := range []*float32{&req.X, &req.Y, &req.Z} {
			if *dst, rest, err = decodeFloat32(rest); err != nil {
				return nil, fmt.Errorf("session: decoding UseSkillRequest: ground point: %w", err)
			}
		}
	default:
		return nil, fmt.Errorf("session: decoding UseSkillRequest: unknown target type %d", req.TargetType)
	}
	return req, nil
}

// SkillRefStore looks up a real skill's learn requirements -- the mastery it
// belongs to, the mastery level it needs, and its SP cost -- what
// LearnSkillHandler gates on. Both refdata stores satisfy it.
type SkillRefStore interface {
	GetSkill(ctx context.Context, id int64) (*refdata.Skill, error)
}

// LearnSkillHandler implements OpLearnSkill against the real skill catalogue: a
// skill is learnable once the character's level in its mastery reaches the
// skill's required mastery level, and it costs the skill's ReqLearnSP (grounded
// _RefSkill data). On success the points are spent and the skill recorded known.
func LearnSkillHandler(chars character.Store, skills skill.Store, skillRef SkillRefStore) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpLearnSkill {
			return nil
		}
		fail := func(reason string) error {
			return sess.Send(&proto.Packet{Opcode: OpLearnSkillResult, Data: (&LearnSkillResult{Reason: reason}).Encode()})
		}
		req, err := DecodeLearnSkillRequest(p.Data)
		if err != nil {
			return fail("malformed request")
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return fail(errStr)
		}
		ref, err := skillRef.GetSkill(ctx, req.SkillID)
		if err != nil || ref == nil {
			// Not a real skill -- fall back to the own-design combat catalog
			// (Power Strike etc.), which has no mastery/SP gate. Keeps the
			// learn->use combat flow working alongside real-skill learning.
			if _, ok := skill.Catalog[req.SkillID]; !ok {
				return fail("no such skill")
			}
			if known, _ := skills.Knows(ctx, characterID, req.SkillID); known {
				return fail("already known")
			}
			if err := skills.Learn(ctx, characterID, req.SkillID); err != nil {
				if errors.Is(err, skill.ErrAlreadyKnown) {
					return fail("already known")
				}
				return fail("learn failed")
			}
			return sess.Send(&proto.Packet{Opcode: OpLearnSkillResult, Data: (&LearnSkillResult{OK: true}).Encode()})
		}
		// FUN_0059e450's outermost test (READ, the round 691 review): its whole
		// body sits inside `if (... && *(int *)(skill + 0xc0) != 0)` and falls
		// through to `return 0x3409` otherwise -- a row whose ReqLearn_SP
		// (+0xc0, skilldata column 46) is 0 is never learnable. That is every
		// monster, pet, guard and trap row (26,646 MSKILL_/CSKILL_/PSKILL_/
		// TSKILL_/HSKILL_/GSKILL_ rows with Mastery1 0 and no learn cost,
		// MEASURED on round 691's re-export), every base attack, and 205 chain-link rows on the class
		// boards (SKILL_CH_SWORD_KNOCKDOWN_E2_01 ...). Until this check those
		// passed every other gate here for free -- id 31825 with its 99,999
		// damage among them. A character's default skills (round 692's
		// giveDefaults) are stored directly, not learned through here.
		if ref.ReqLearnSP <= 0 {
			return fail("this skill cannot be learned")
		}
		known, err := skills.Knows(ctx, characterID, req.SkillID)
		if err != nil {
			return fail("lookup failed")
		}
		if known {
			return fail("already known")
		}
		// The learn check's race filter, in FUN_0059e450's own order (READ,
		// called from Skill_HandleLearn 0x0059bfe0): the skill's mastery must be
		// one the character HOLDS (0x3401 -- a Europe character holds only
		// 513-518, a China one only 257-276; skill.HoldsMastery), and its
		// ReqLearn_Race must be 3 or the character's Country (0x3405). Round
		// 691: until then a Europe character could learn China skills and the
		// reverse.
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		country := characterCountry(owned)
		if ref.Mastery1 > 0 && !skill.HoldsMastery(country, ref.Mastery1) {
			return fail("not your race's mastery")
		}
		// Gated by the mastery level the skill requires.
		if ref.Mastery1 > 0 && ref.MasteryLevel1 > 0 {
			levels, err := skills.MasteryLevels(ctx, characterID)
			if err != nil {
				return fail("lookup failed")
			}
			if levels[ref.Mastery1] < ref.MasteryLevel1 {
				return fail("mastery level too low")
			}
		}
		// FUN_0059e450 tests the race byte after the masteries (and the Str/Int
		// requirements, which OpenSRO does not model) and before the chain.
		if !skill.LearnRaceAllows(ref.ReqLearnRace, country) {
			return fail("not your race's skill")
		}
		// Gated by what the character already knows: the previous level of the
		// same skill, and the skilldata prerequisites (ReqLearn_Skill1..3 at
		// ReqLearn_SkillLevel1..3 -- group ids and levels, columns 40..45).
		knownIDs, err := skills.KnownSkills(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		if reason := learnPrerequisiteFailure(ctx, skillRef, ref, knownIDs); reason != "" {
			return fail(reason)
		}
		// Paid for with skill points.
		points, err := skills.SkillPoints(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		if points < ref.ReqLearnSP {
			return fail("not enough skill points")
		}
		if _, err := skills.AddSkillPoints(ctx, characterID, -ref.ReqLearnSP); err != nil {
			return fail("spending skill points failed")
		}
		if err := skills.Learn(ctx, characterID, req.SkillID); err != nil {
			// Refund on a late failure (e.g. a race that already learned it).
			skills.AddSkillPoints(ctx, characterID, ref.ReqLearnSP)
			if errors.Is(err, skill.ErrAlreadyKnown) {
				return fail("already known")
			}
			return fail("learn failed")
		}
		return sess.Send(&proto.Packet{Opcode: OpLearnSkillResult, Data: (&LearnSkillResult{OK: true}).Encode()})
	}
}

// knownGroupLevels folds a character's known real skills into the highest
// level known per skill GROUP (skilldata GroupID) -- the shape the engine keeps
// a learned skill in: one entry per group, at a level.
func knownGroupLevels(ctx context.Context, skillRef SkillRefStore, known []int64) map[int64]int {
	levels := map[int64]int{}
	for _, id := range known {
		r, err := skillRef.GetSkill(ctx, id)
		if err != nil || r == nil {
			continue // an own-design catalog skill, not a real row
		}
		if r.GroupID == 0 {
			continue // no group, no chain (a test double; every real row has one)
		}
		if r.BasicLevel > levels[r.GroupID] {
			levels[r.GroupID] = r.BasicLevel
		}
	}
	return levels
}

// learnPrerequisiteFailure is the part of the learn gate that depends on what
// the character already knows. Empty means the prerequisites are met.
//
// Two rules. First, a skill group holds ONE learned level and the next level
// is the only one learnable: level N needs level N-1 known (level 1 needs
// nothing) -- the client's window offers only that "+" and the server now
// refuses the rest (structural; the engine's own check is unread). Second,
// the row's ReqLearn_Skill1..3 / ReqLearn_SkillLevel1..3 (skilldata columns
// 40..45, 3,305 of the real rows carry one): each names a skill GROUP that
// must be known at at least the given level -- Power Strike's B series needs
// the A series (group 174) at level 9. Verified on the real chain 2026-09-19.
func learnPrerequisiteFailure(ctx context.Context, skillRef SkillRefStore, ref *refdata.Skill, known []int64) string {
	levels := knownGroupLevels(ctx, skillRef, known)
	if ref.GroupID != 0 {
		if ref.BasicLevel > 1 && levels[ref.GroupID] < ref.BasicLevel-1 {
			return fmt.Sprintf("learn level %d first", ref.BasicLevel-1)
		}
		if ref.BasicLevel > 0 && levels[ref.GroupID] >= ref.BasicLevel {
			return "already known"
		}
	}
	for _, req := range [][2]int64{
		{ref.ReqLearnSkill1, ref.ReqLearnSkillLevel1},
		{ref.ReqLearnSkill2, ref.ReqLearnSkillLevel2},
		{ref.ReqLearnSkill3, ref.ReqLearnSkillLevel3},
	} {
		if req[0] == 0 {
			continue
		}
		if int64(levels[req[0]]) < req[1] {
			return fmt.Sprintf("requires skill group %d at level %d", req[0], req[1])
		}
	}
	return ""
}

// DisclosedSkillDamagePerLevel is this project's OWN-DESIGN skill-damage rate,
// used ONLY as a fallback now. Real skill damage is recovered -- see
// skillDamageBonus -- but a skill whose row carries no 'att' parameter (and an
// import predating the damage columns) still needs some number, and this stays
// the clearly-labeled stand-in for that case.
const DisclosedSkillDamagePerLevel = 4

// skillDamageBonus is the extra damage a skill adds on top of a plain weapon
// swing. **This is real now**, recovered rather than invented.
//
// A skill's damage lives in its own 'att' parameter in skilldata. Parameters
// are (code, values...) runs in the row's Param block, where the code is a C
// multi-character literal stored as a big-endian integer; the server's own
// parameter parser reads 'att' (0x00617474) as a fixed six-word run, which is
// how the layout is known. The values are (type, percent, min, max, percent),
// and reading a skill across its levels makes the meaning plain: for
// SKILL_CH_SWORD_SMASH_A levels 1-5 the percent holds at 143 while min/max
// climb 15-18, 18-22, 21-26, 25-30, 29-35. A plain swing
// (SKILL_CH_SWORD_BASE_01) is 60 percent with no flat damage -- exactly what a
// basic attack should be.
//
// So a cast deals `percent` of the weapon's damage plus a flat roll in
// [min, max]. Since the caller already applies the plain weapon damage, what is
// returned here is the DIFFERENCE the skill makes: the percentage's surplus (or
// deficit, for a sub-100% skill like a basic swing) plus the flat roll.
//
// Falls back to the disclosed per-level bonus when the skill has no 'att'
// (most skills are buffs, heals or passives) or when the reference data
// predates the damage columns.
// skillDamageBonus splits a skill's damage into the two halves the engine
// keeps on OPPOSITE SIDES of mitigation: a flat term that joins the weapon roll
// before it, and a percentage that scales the blow after it.
//
// The attack descriptor the engine carries at +0x230 has exactly these three
// fields -- percentage at +4, flat minimum at +8, flat maximum at +0xc -- and
// they are the same three this project reads out of skilldata's 'att'
// parameter. FUN_0040db50 adds +0x8/+0xc to the rolled damage bound;
// Formula_MitigatePhysicalDamage multiplies by +0x4 only after dividing by the
// defender's reduction, subtracting its flat absorb and clamping at zero. See
// combat.ApplySkillPercent.
//
// A skill with no real row falls back to the disclosed per-level bonus, which
// is flat and therefore has no percentage half.
func skillDamageBonus(ref *refdata.Skill) (flat, percent int) {
	// A skill the engine resolves no blow for has no damage to split. This is
	// NOT the disclosed fallback: refdata.Skill.NoCombatParam is a real answer
	// out of Combat_ResolveDamage's own 33-parameter test, so there is nothing
	// left to stand in for. See UseSkillHandler, which does not reach the
	// attack path at all for one of these.
	if ref.NoCombatParam || ref.ZeroDamage {
		return 0, 0
	}
	// A computed blow that is identically zero: the engine's floor makes it
	// exactly 1, whatever the weapon. No flat term either -- the flat min/max
	// join the roll BEFORE the multiply that zeroes it. See
	// refdata.Skill.FloorBlow and combat.SkillPercentZero.
	if ref.FloorBlow {
		return 0, combat.SkillPercentZero
	}
	if ref.AttackPercent <= 0 {
		return disclosedSkillDamageBonus(ref), 0
	}
	flat = ref.DamageMin
	if ref.DamageMax > ref.DamageMin {
		flat += rand.Intn(ref.DamageMax - ref.DamageMin + 1)
	}
	return flat, ref.AttackPercent
}

// disclosedSkillDamageBonus is the own-design fallback: a bonus scaled by the
// skill's level so higher skills hit harder. Disclosed, not recovered -- see
// DisclosedSkillDamagePerLevel.
func disclosedSkillDamageBonus(ref *refdata.Skill) int {
	lvl := ref.BasicLevel
	if lvl < 1 {
		lvl = 1
	}
	return lvl * DisclosedSkillDamagePerLevel
}

// UseSkillHandler returns a gateway.Handler implementing OpUseSkill:
// checks the character knows the skill and it's off cooldown, then
// delegates to performAttack with the skill's damage bonus. Responds with
// OpAttackResult (see OpUseSkill's doc comment) on all paths, including
// failures, so a client only needs one decoder for both attack types.
func UseSkillHandler(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	skills skill.Store,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skillRef SkillRefStore,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
	parties *party.Hub,
) gateway.Handler {
	return UseSkillHandlerWithGround(chars, eq, items, skills, hub, monsters, quests, inv, skillRef, zerk, mp, parties, nil)
}

// UseSkillHandlerWithGround is UseSkillHandler with a ground-item hub, so a
// skill kill drops its loot on the ground like a plain-attack kill does.
func UseSkillHandlerWithGround(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	skills skill.Store,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skillRef SkillRefStore,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
	parties *party.Hub,
	ground *grounditem.Hub,
) gateway.Handler {
	return useSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, skillRef, zerk, mp, parties, ground, nil, nil)
}

// UseSkillHandlerWithDrops is UseSkillHandlerWithGround plus the real drop
// tables. A skill kill drops exactly what a plain swing does, which is only
// true if both paths carry the same source -- see dropsForKill.
func UseSkillHandlerWithDrops(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	skills skill.Store,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skillRef SkillRefStore,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
	parties *party.Hub,
	ground *grounditem.Hub,
	dropSrc DropSource,
	// potions is the potion queue a death empties under -player-dead-state
	// (round 549, markDead); nil leaves nothing to empty. Carried by the full
	// constructor, as CombatHandlerWithDrops carries it.
	potions *PotionQueue,
) gateway.Handler {
	return useSkillHandler(chars, eq, items, skills, hub, monsters, quests, inv, skillRef, zerk, mp, parties, ground, dropSrc, potions)
}

func useSkillHandler(
	chars character.Store,
	eq equipment.Store,
	items combat.ItemLookup,
	skills skill.Store,
	hub *world.Hub,
	monsters *combat.Hub,
	quests quest.Store,
	inv inventory.Store,
	skillRef SkillRefStore,
	zerk *berserk.Tracker,
	mp *mana.Tracker,
	parties *party.Hub,
	ground *grounditem.Hub,
	dropSrc DropSource,
	potions *PotionQueue,
) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpUseSkill {
			return nil
		}

		req, err := DecodeUseSkillRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: (&AttackResult{Error: "malformed request"}).Encode()})
		}

		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: errStr}).Encode()})
		}
		// The character the cast charges is the one it acts on (round 616's
		// review): the named character must be the one this session has in
		// the world, or the costs would land on one character and the buff or
		// the move on another.
		if e, inWorld := hub.EntityBySession(sess.ID()); !inWorld || e.CharacterID != characterID {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: notInWorldRefusal}).Encode()})
		}
		// A dead character casts nothing (round 549, deadstate.go): the
		// engine's skill tick runs on a living PC, and even the self-heal
		// below lands only on a living caster (0x5942c0, GetLifeState == 1).
		// Before the cooldown and the costs, so a dead cast pays nothing.
		if deadBySession(hub, sess) {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: deadRefusal}).Encode()})
		}

		// Resolve the skill's cooldown and damage bonus. A real learned skill
		// (refdata) uses its real ReuseDelay cooldown; its extra damage is a
		// DISCLOSED own-design bonus (disclosedSkillDamageBonus), because the
		// real formula is NOT recoverable: skill damage is server-authoritative
		// (the retail client only receives it in the action packet -- proven by
		// decompiling NetProcessInNavAndSkill.cpp), so it lives only in the
		// packed retail AgentServer, and _RefSkill's Param block is not decoded.
		// So this is a stand-in scaled by the skill's level, clearly labeled --
		// the same accepted pattern as SPFor/ExpFor/Catalog.DamageBonus, never a
		// value dressed as recovered. See the skilldata-columns note.
		// mpCost, unlike the damage bonus, IS real: refdata.Skill.ConsumeMP is
		// the client's own skilldata Consume_MP column. The placeholder
		// catalog skills have no real row and so cost nothing.
		var cooldown time.Duration
		var damageBonus int
		var damagePercent int
		var hits = 1
		var mpCost int
		// The skill's real health cost (skilldata Consume_HP, column 52). Only 8
		// rows in the whole table carry one (recounted on the 33,632 real rows,
		// round 507; round 503 measured the same 8), all
		// SKILL_EU_BARD_RECOVERA_ABNORMALTIME_A_01..06 / B_01..02 (495 up to
		// 4756), which trade health for their effect instead of mana.
		var hpCost int
		// masteryPercent is stage 1 of the engine's damage pipeline: the weapon
		// roll is scaled by `1 + masteryPercent/100` before mitigation. It is
		// the CASTER's trained level in the skill's required mastery, not the
		// skill's requirement -- see combat.MasteryDamagePercent. A catalog
		// skill has no mastery slot and leaves this 0, which is what the engine
		// returns for an attack with no skill record.
		var masteryPercent int
		// The skill's damage-type mask. A catalog skill has no real row and
		// so leaves 0, which combat.AttackType reads as physical -- the
		// behaviour those invented skills already had.
		var attackType combat.AttackType
		// The skill's two required-weapon codes. A catalog skill has no real
		// row and leaves 0, which combat.SkillAllowsWeapon reads as "unknown"
		// and permits -- 0 is invalid in the real table, so it can only mean an
		// export predating the columns.
		var reqWeapon1, reqWeapon2 int
		// How many entries the skill puts in the list at CRefSkill+0x3a0. The
		// weapon gate applies ONLY when this is zero -- see below.
		// The skill's own Action_Range. Zero means "use the weapon's", which is
		// exactly what combat.EffectiveRange does with it.
		var skillRange int
		var reqCastList int
		var reqCastReqs []combat.CastRequirement
		var reqCastAll bool
		// noCombat: the engine resolves no blow at all for this skill, and
		// zeroDmg: it resolves one whose damage is zero. The first is a strict
		// subset of the second and OpenSRO treats them the same way today; see
		// refdata.Skill.NoCombatParam and refdata.Skill.ZeroDamage.
		var noCombat, zeroDmg bool
		// The row itself, kept for the keep-up hand-off below (its
		// AutoAttackType and timings); nil for a catalog skill.
		var castRow *refdata.Skill
		// REAL SKILLS WIN. This used to check skill.Catalog first, which
		// silently shadowed two real skills: the own-design catalog occupies
		// ids 1 and 2, and those are SKILL_PUNCH_01 and SKILL_CH_SWORD_BASE_01
		// in the client's own skilldata -- the unarmed attack and the basic
		// sword swing, two of the most-used skills in the game. A player who
		// learned the real skill 2 then used an invented "Whirlwind" with a
		// flat +10 instead of the real 60%-of-weapon swing.
		//
		// The learn path (above) already preferred refdata and fell back to the
		// catalog; only this path had the order reversed, so the two disagreed
		// about what skill 2 even was. Both now agree, and the ordering matches
		// the rule the rest of the project follows -- shop.Price says it
		// outright: "The real number is what a player pays, so it wins."
		if ref, err := skillRef.GetSkill(ctx, req.SkillID); err == nil && ref != nil {
			// The skill-use gate's motion-state refusals (round 607,
			// motion.go): only a skill carrying 'ao'/'pw' or a kind-1 'msch'
			// is refused to a seated caster -- 59 of the 33,660 rows,
			// measured. Every other skill is cast from the seat, as the
			// engine's gate lets it be.
			// THE TOGGLE (round 640, walls.go toggleOffOnCast): an 'onff'
			// skill whose record the caster runs is switched off -- before
			// the gate (the motion-state refusal below included), the costs
			// and the cooldown: the 0x7074 handler skips its gate for an
			// 'onff' row (0x4acec0) and Tick_UseSkill's phase 0 ends the
			// record before it runs its own (0x4ae622..0x4ae64d), both READ. The
			// handler resolves the learned row first (0x59d600), so the
			// skill must be known.
			if known, kerr := skills.Knows(ctx, characterID, req.SkillID); kerr == nil && known && toggleOffOnCast(hub, characterID, ref) {
				hp := int32(0)
				if c, err := chars.GetByID(ctx, characterID); err == nil && c != nil {
					hp = int32(c.HP)
				}
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: toggledOffResult(req, hp).Encode()})
			}
			// READ (round 640's review): Skill_CheckUseConditions refuses a row
			// carrying 'tele', 'tel2' or 'tel3' while the caster's book holds a
			// wall (book+0x1dc), 0x3009 (0x58e033..0x58e061) -- before the
			// cooldown test (0x58e08c) and the motion-state gate (0x58e0a0).
			// So Ghost Walk cannot carry a walled caster away. This is retail's
			// rule, not the OURS root (walls.go wallRoots). All three fields
			// are tested (refdata.Skill.HasTeleport; 'tel2'/'tel3' from CSV
			// 87/88 -- MEASURED on 7 and 21 EU rows, which a walled Chinese
			// caster cannot know, so in practice it is Ghost Walk's 'tele').
			if ref.HasTeleport() && buffBooks.HoldsWall(characterID) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: wallTeleRefusal}).Encode()})
			}
			if seatedCastRefused(ref.SitGate, characterID, time.Now()) {
				refusal := seatedRefusal
				if motions.state(characterID, time.Now()) == MotionProtectionWall {
					refusal = wallStateRefusal
				}
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: refusal}).Encode()})
			}
			castRow = ref
			skillRange = ref.Range
			cooldown = time.Duration(ref.ReuseDelayMs) * time.Millisecond
			mpCost = ref.ConsumeMP
			hpCost = ref.ConsumeHP
			damageBonus, damagePercent = skillDamageBonus(ref)
			hits = ref.HitsFor()
			attackType = combat.AttackType(ref.AttackType)
			reqWeapon1, reqWeapon2 = ref.ReqCastWeapon1, ref.ReqCastWeapon2
			reqCastList = ref.ReqCastListCount
			reqCastReqs = combat.ParseCastRequirements(ref.ReqCastList)
			reqCastAll = ref.ReqCastAll
			noCombat = ref.NoCombatParam
			zeroDmg = ref.ZeroDamage
			// The engine takes the higher of the skill's TWO mastery slots;
			// refdata carries only the first (see refdata.Skill.Mastery1), so
			// the second is reported as unoccupied and contributes the engine's
			// default of 1. That is a faithful reading of a table this project
			// has half of, not a simplification of the formula.
			if ref.Mastery1 != 0 {
				trained := 0
				if levels, err := skills.MasteryLevels(ctx, characterID); err == nil {
					trained = levels[ref.Mastery1]
				}
				pct := combat.MasteryDamagePercent(true, true, false, trained, 0)
				// OpenSRO has one attack record, so the engine's two-record
				// clamp collapses to a cap at 90. See ClampMasteryPercent.
				masteryPercent = combat.ClampMasteryPercent(pct, pct)
			}
		} else if sk, inCatalog := skill.Catalog[req.SkillID]; inCatalog {
			cooldown = time.Duration(sk.CooldownSeconds) * time.Second
			damageBonus = int(sk.DamageBonus)
		} else {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "no such skill"}).Encode()})
		}

		knows, err := skills.Knows(ctx, characterID, req.SkillID)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "lookup failed"}).Encode()})
		}
		if !knows {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "skill not known"}).Encode()})
		}
		// A known skill must also be one a player of this race may hold (the
		// round 691 review, playerskill.go): a monster's row or another race's,
		// learned before the learn gate refused it, is refused and dropped.
		if castRow != nil {
			owned, err := chars.GetByID(ctx, characterID)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "lookup failed"}).Encode()})
			}
			if reason := playerHoldRefusal(castRow, characterCountry(owned)); reason != "" {
				forgetUnholdable(ctx, skills, characterID, req.SkillID, reason)
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "you cannot use this skill"}).Encode()})
			}
		}

		// THE WEAPON GATE, recovered from FUN_0058d480: a skill names up to two
		// weapon type codes and the engine refuses the cast with error 0x300d
		// when the equipped weapon matches neither.
		//
		// CONFIRMED FROM THE OTHER BINARY 2026-09-16: the client names 0x300d
		// `UIIT_SKILL_USE_FAIL_WRONGWEAPON` (docs/protocol/error_codes.md).
		// This was named "the weapon gate" from the server alone; the client
		// agrees without having been consulted. See combat.SkillAllowsWeapon
		// for the codes and how they were confirmed.
		//
		// A lookup failure permits the cast rather than refusing it. Reference
		// data is brought by the operator, so on a deployment that has imported
		// none of it -- which is every fresh one -- refusing here would mean
		// nobody could use a skill at all, the same reasoning attackerDamage
		// already applies to an unknown weapon.
		// CORRECTED 2026-09-16. The gate shipped two versions ago applied the
		// ReqCastWeapon bytes to every skill that carries them. The engine does
		// not: FUN_0058d480 opens with
		//
		//	if (skill[0x3a0] == 0) { ...the weapon check... }
		//	else                   { ...a different check entirely... }
		//
		// and `+0x3a0` is a five-slot list filled by the skill's 'reqi'
		// parameter. So a skill with a list never has its weapon bytes
		// consulted. 1,094 real skills carry 'reqi' and **517 of them also
		// carry a weapon requirement the engine ignores** -- OpenSRO was
		// refusing casts the game allows.
		//
		// What the other branch checks is not recovered, so this does not model
		// it. Declining to apply a check the engine would not apply is the
		// faithful half of the answer; the other half is still open.
		if reqCastList == 0 {
			// The ordinary branch: the skill's two weapon bytes.
			if reqWeapon1 != 0 || reqWeapon2 != 0 {
				t3, t4, known := equippedWeaponType(ctx, characterID, eq, items)
				if known && !combat.SkillAllowsWeapon(reqWeapon1, reqWeapon2, t3, t4) {
					return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "wrong weapon for this skill"}).Encode()})
				}
				// SERVICEABILITY, the other half of the cast requirement
				// (2026-09-21). A cast requirement wants the item present AND
				// NOT BROKEN: Skill_CheckCastRequirement (0x0058d480) returns
				// 0x300f when vtable slot 372, 399 or 400 answers 0, and the
				// client names 0x300f UIIT_SKILL_USE_FAIL_BROKEN_WEAPON -- see
				// docs/protocol/igobj_vtable.md, which reads those three as
				// serviceability predicates.
				//
				// OpenSRO already dropped a broken item's STATS (the combat
				// sums skip it, matching the engine dropping its ParamKeeper
				// entry) but still let the cast through, so a broken weapon
				// cost you its damage and nothing else. It now refuses.
				//
				// CORRECTED round 486: it is ONE flag, not three predicates.
				// CGObjPC's slots 372 (0x004ec5a0), 399 (0x004ec5d0) and 400
				// (0x004ec600) each fetch one storage slot -- the weapon (6),
				// the shield (7), an armour part through DAT_00c63f44 -- and
				// answer `item == 0 || item+0x190 == 0` (4ec5bb / 4ec5eb /
				// 4ec631 `cmp [eax+0x190],ecx ; sete`). +0x190 is the flag
				// GItemEquip::SetBrokenFlag (0x00495980) sets at durability < 1,
				// so durability.IsBroken is the whole test, not a collapse.
				// Only this branch can FAIL at slot 372 for a shipped skill. The
				// reqi branch below reaches it too (58d527, after a weapon
				// match), but its TID getters already read a broken item as an
				// empty slot, so its calls (0x5d0, 0x63c, 0x640) can only fail
				// on a weapon or shield entry whose TypeID4 is 0 -- which no
				// shipped record has (combat.CastRequirement's measurement:
				// weapon values 2-15, shield 1-2).
				//
				// ORDER, disclosed: the engine runs slot 372 after the type
				// match whatever its result (58d6fe sets 0x300d, 58d719 then
				// calls +0x5d0 and returns 0x300f), and a broken weapon's TID
				// reads 0 -- bare hand. So a broken weapon of the WRONG kind is
				// 0x300f there and "wrong weapon" here. Both refuse the cast.
				// A lookup failure permits the cast, the same choice every
				// other gate here makes.
				if broken, ok := weaponIsBroken(ctx, characterID, eq); ok && broken {
					return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "your weapon is broken"}).Encode()})
				}
			}
		} else if len(reqCastReqs) > 0 {
			// The OTHER branch, recovered 2026-09-16. When the skill carries a
			// 'reqi' list the engine ignores the weapon bytes entirely and walks
			// the list instead, matching each record's (TypeID3, TypeID4) against
			// what the character is wearing. See combat.SkillAllowsEquipment.
			//
			// The previous tick made this case cast-anything, which was the
			// faithful half of an unfinished answer; this is the rest of it.
			//
			// A broken item satisfies nothing here and the refusal is 0x300d,
			// not 0x300f: the engine's getters read it as an empty slot (see
			// equippedTypes), so it never reaches the serviceability calls.
			worn, known := equippedTypes(ctx, characterID, eq, items)
			if known && !combat.SkillAllowsEquipment(reqCastReqs, reqCastAll, worn) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "wrong equipment for this skill"}).Encode()})
			}
		}

		lastUsed, everUsed, err := skills.LastUsed(ctx, characterID, req.SkillID)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "lookup failed"}).Encode()})
		}
		now := time.Now()
		if everUsed && cooldown > 0 {
			readyAt := lastUsed.Add(cooldown)
			if now.Before(readyAt) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "skill on cooldown"}).Encode()})
			}
		}
		// THE SHARED TIMER (round 504). A row with a cooldown group waits on
		// the group, not only on itself: SkillCooldowns::IsReady (0x64c1a0)
		// answers from the group map for a non-zero CRefSkill+0x8f, so casting
		// Smash A (group 2) puts Smash D (group 2) on cooldown too. The per-id
		// check above is kept; for a grouped row it never refuses where this
		// one would not, since every cast in the group re-arms the group. It
		// runs before the HP/MP costs, as the per-id check does, so a refused
		// cast costs nothing. See skillCooldownGroup for the rows it covers.
		if g := skillCooldownGroup(castRow); g != 0 && !skillGroupCooldowns.Ready(characterID, g, now) {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "skill on cooldown"}).Encode()})
		}

		// NOT MODELLED, disclosed: AMMUNITION. A skill carrying the `cnsm`
		// parameter spends ammunition, and the engine refuses the cast with
		// UIIT_SKILL_USE_FAIL_RUNOUT_AMMO when the player has none (the check at
		// 0058e348, guarded by IsPC). 448 real skills carry it -- every
		// SKILL_CH_BOW and SKILL_EU_ROG -- and the record is
		// (TypeID3, TypeID4, count): one arrow for bows, one or three bolts for
		// rogues. See docs/protocol/skill_params.md.
		//
		// OpenSRO neither stocks nor spends ammunition, so there is nothing to
		// check. Written down so that adding quivers later comes with the
		// requirement already stated.

		// THE REACH, BEFORE ANYTHING IS SPENT (round 534). The engine never
		// pays for a cast its target is out of reach of: Tick_UseSkill
		// (0x4ae590) phase 1 tests Action_IsTargetWithinReach (call at
		// 0x4aea39) and, out of reach, walks (MoveTowardObject, 0x4aeaca) and
		// stays in phase 1; only in reach does it enter phase 2 (0x4aea4b),
		// which posts the 0x7070 command (0x4aebc6). Nothing is spent before
		// that post: neither the tick nor the 0x7074 handler (0x4acc40) calls
		// EngageSkill (0x593540) or the reuse-timer arm FUN_0064c700 (their
		// direct calls, listed from srv.asm). Those are called by the
		// per-kind cast handlers -- Skill_BuildUseContext_B (0x586700), for
		// one, copies Consume_HP/Consume_MP (+0xca/+0xcc) into the context,
		// arms the timer at 0x586c22 and calls EngageSkill at 0x586c44,
		// whose first step takes both costs through vtable slot 0x308
		// (docs/protocol/skill_params.md, "EngageSkill, step by step"). The
		// function that consumes 0x7070 and dispatches them was not traced.
		// OpenSRO cannot walk the player, so it refuses instead -- and until
		// round 534 it refused only AFTER paying the HP and MP and recording
		// the use, so a cast refused as too far away cost its MP and its
		// cooldown, and the client's retry after the walk was refused on
		// cooldown or paid twice.
		//
		// What the engine DOES test before the reach, OpenSRO tests first
		// too: the cooldown (above) and whether the caster can pay. Both
		// gates the tick runs before the reach test -- mask 0x17 in phase 0
		// (0x4ae6af) and 0x91 in phase 1 (0x4aea11, called at 0x4aea18) --
		// carry bit 0x1, the cooldown row (0x58e077 `test al,0x1`, refusal
		// 0x3005 at 0x58e095), and bit 0x10, the HP/MP rows
		// (0x58e1ac `test [ebp+0x10],0x10`, refusals 0x3013 at 0x58e292 and
		// 0x3004 at 0x58e2b1). So a cast short of mana is refused for its mana
		// wherever it stands, as it was here before. The costs themselves are
		// still taken below, after the reach.
		//
		// A non-damaging cast (noCombat || zeroDmg) is accepted at any
		// distance, as before round 534: its return below comes before any
		// reach test. A refusal as too far away still ends a running keep-up,
		// as it did when the refusal came after keepUp.Cancel: the engine's
		// 0x7074 handler tests the gate (mask 0x37) but not the reach before
		// Push, so an out-of-reach cast is queued and the keep-up ends itself
		// when it sees a second action (docs/protocol/auto_command.md, "How an
		// action arrives" and "The attack tick" phase 3).
		// THE BUFF AND THE GROUND CAST (round 616, buffs.go and
		// docs/protocol/skill_buffs.md), decided here, before anything is
		// spent, because both of their refusals are the engine's gate or
		// context builder, which run before EngageSkill takes the costs:
		//
		//   - A caster buff (startsCasterBuff: action kind 3, Target_Required
		//     0 or a friendly target group) is refused 0x300c OVERLAP when a
		//     higher level of the same skill group is already active
		//     (Skill_CheckUseConditions row 16, 0x58e2fd -> FUN_0059d870).
		//   - A row carrying 'tele' moves its caster to a point on the ground
		//     (FUN_005862e0, from the context builders 0x5857b0/0x586700). It
		//     needs the point -- with none the builder aborts -- and the
		//     point is the request's ground target; anything else asking for
		//     a ground cast has no ground move here and is refused.
		isBuff := startsCasterBuff(castRow)
		isGround := req.Target() == TargetGround || castRow.HasTele()
		var groundDest world.Position
		if isGround {
			if req.Target() != TargetGround || !castRow.HasTele() || !castRow.TargetLand {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: groundRefusal}).Encode()})
			}
			e, inWorld := hub.EntityBySession(sess.ID())
			if !inWorld {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: notInWorldRefusal}).Encode()})
			}
			// A NaN or an infinity is no place (round 616's review), refused
			// before anything is spent.
			if !finitePosition(req.X, req.Y, req.Z) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: groundRefusal}).Encode()})
			}
			// A move in the sit/stand transition is refused, as handleMove
			// refuses it (the move itself, moveBySkill, stands a seated one).
			if motions.state(characterID, now) == MotionChangeMotion {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: seatedRefusal}).Encode()})
			}
			groundDest = ghostWalkDestination(e.Pos,
				world.Position{X: float64(req.X), Y: float64(req.Y), Z: float64(req.Z)}, float64(castRow.Tele1))
		}
		// A TARGETTYPE 0 CAST (round 616) applies to its caster, and the
		// monster field is ignored. Retail's skill tick clears the action
		// context's target vector for a Target_Required 0 row (0x4ae6f0,
		// auto_command.md) and the targets then come from the row's 'efr'
		// collector around the caster -- which OpenSRO does not build
		// (skillparam.EfrKind*; OPEN): the 23 class rows of that shape that
		// carry 'att' (SKILL_EU_BARD_BATTLAA_EXPLOSION_A/B, 'efr' kind 1,
		// radius 80, five targets -- MEASURED) resolve no blow here. A
		// Target_Required 1 row with no friendly group needs its target and
		// is refused before anything is spent (OURS text); a friendly one
		// was, until round 622, put on the caster; it is now refused below
		// (friendlyTargetRefusal), as the retail client refuses it.
		//
		// FRIENDLY TARGETS (round 622, friendlycast.go). A Target_Required 1
		// row with a friendly group (Heal, the party buffs) names a
		// CHARACTER (targetType 3). With nothing selected it is refused with
		// the retail client's own 0x3011 text; at a monster with the server's
		// 0x3006 (FUN_0058d7a0 steps 4 and 7) -- both before anything is
		// spent, as the retail skill tick refuses in phase 0 (PrepareAction
		// case 4 -> FUN_0058cc70) before its approach walk. A character
		// target passes the rest of FUN_0058d7a0 (Self for oneself, the same
		// party for a Party-only row) or is refused 0x3006. A hostile row
		// named at a character would be player-versus-player, which OpenSRO
		// does not model: refused with the same text (OURS).
		friendly := friendlyTargeted(castRow)
		var friendTarget world.Entity
		if req.Target() == TargetCharacter && !friendly {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: invalidTargetRefusal}).Encode()})
		}
		if friendly {
			caster, inWorld := sessionEntity(hub, sess)
			if !inWorld {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: notInWorldRefusal}).Encode()})
			}
			t, refusal := friendlyTargetRefusal(hub, parties, castRow, caster, req.Target(), req.TargetMonsterID)
			if refusal != "" {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: refusal}).Encode()})
			}
			friendTarget = t
		}
		selfTarget := req.Target() == TargetNone && !isBuff && !isGround
		if selfTarget && castRow != nil && castRow.TargetRequired &&
			!castRow.TargetSelf && !castRow.TargetAlly && !castRow.TargetParty {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: targetRefusal}).Encode()})
		}
		// The caster's book is held from the recast check to the start, so a
		// cast that passes the check starts (round 616's review): nothing
		// else can add a record in between, and the costs below are never
		// taken for a buff that is then refused.
		// A friendly buff's book is its target's (round 622).
		buffOwner := characterID
		if friendly {
			buffOwner = friendTarget.CharacterID
		}
		if isBuff {
			l := buffLock(buffOwner)
			l.Lock()
			defer l.Unlock()
		}
		if refusal := skillCostRefusal(ctx, chars, mp, characterID, hpCost, mpCost); refusal != "" {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: refusal}).Encode()})
		}
		// The recast rule after the costs' test, as the gate orders them
		// (round 636, READ): 0x58e292 NOTENOUGHHP and 0x58e2b1 NOTENOUGHMP
		// come before row 16's 0x300c at 0x58e2fd.
		if isBuff {
			if r := buffBooks.CheckOverlap(buffOwner, buffSpec(castRow, characterID)); r != buff.NotRefused {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: refusalText(r)}).Encode()})
			}
		}
		// A character target is measured as a monster one is (round 622,
		// characterInReach), before the costs.
		if friendly {
			caster, _ := sessionEntity(hub, sess)
			if !characterInReach(ctx, eq, items, caster, friendTarget, skillRange) {
				keepUp.Cancel(characterID)
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "too far away"}).Encode()})
			}
		}
		// A cast that resolves no blow but carries states for a monster (a
		// zero-damage stun or debuff) is measured as a damaging one is, and
		// refused at a monster not in the caster's zone or not alive (round
		// 659's review, H2: it landed from any distance and in any zone).
		// INFERRED that retail measures it the same: the gate's reach test is
		// not read to exempt a zero-damage row.
		if statusCastAtMonster(castRow, isBuff, isGround, selfTarget, friendly) && (noCombat || zeroDmg) {
			if refusal := statusCastRefusal(ctx, sess, eq, items, hub, monsters, characterID, req.TargetMonsterID, skillRange); refusal != "" {
				keepUp.Cancel(characterID)
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{MonsterID: req.TargetMonsterID, Error: refusal}).Encode()})
			}
		}
		if !isBuff && !isGround && !selfTarget && !friendly && !noCombat && !zeroDmg && !skillInReach(ctx, sess, eq, items, hub, monsters, characterID, req.TargetMonsterID, skillRange) {
			keepUp.Cancel(characterID)
			res := echoed(req, &AttackResult{MonsterID: req.TargetMonsterID, Error: "too far away"})
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: res.Encode()})
		}
		// THE CATEGORY END (round 636, corrected by its review; buffs.go
		// endCategoryOnSkillUse): once every refusal above has passed. READ:
		// the gate runs at request time (0x4acc40, 0x4aced4); the skill
		// tick's case 2 then posts 0x7070 -> vslot 383 FUN_004b21b0 ->
		// FUN_0059b7c0 -> FUN_0059b480, whose category end (0x59b745) runs
		// just before SkillActionHandler. A refused cast ends nothing.
		if isBuff && buffOwner == characterID {
			endCategoryOnSkillUseLocked(hub, characterID, castRow) // the caster's buff lock is held
		} else {
			endCategoryOnSkillUse(hub, characterID, castRow)
		}
		// SkillAction_Buff's sub-state 0 bit test (round 636's review,
		// buff.Books.CheckEngage): on the caster's book, before the costs; a
		// hit ends the cast silently and charges nothing.
		if isBuff {
			if r := buffBooks.CheckEngage(characterID, buffOwner, buffSpec(castRow, characterID)); r == buff.RefusedSilent {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: silentRefusal}).Encode()})
			} else if r != buff.NotRefused {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: refusalText(r)}).Encode()})
			}
		}

		// Pay the skill's real HEALTH cost first. The engine checks health
		// before mana -- 0058e292 returns UIIT_SKILL_USE_FAIL_NOTENOUGHHP and
		// 0058e2b1 returns ..._NOTENOUGHMP, in that order -- and doing the same
		// here means a cast short on health never spends mana on the way to
		// being refused. refdata.Skill.ConsumeHP was exported and stored but
		// never read until 2026-09-16; these 8 skills were free to cast.
		//
		// The gate passes on EQUAL (`cmp eax,[esp+0x10]` at 0x58e28c, `jge`
		// at 0x58e290, SR_GameServer.exe -- combat.CanPaySkillHealth), so a
		// cast whose cost is the caster's whole pool is allowed and lands her
		// at exactly 0, ALIVE: life state 1 (the dead gate above still passes),
		// no penalty, no respawn -- the payment's died flag (the store's
		// transition to 0) is not a death and is not read. What the engine
		// does with a pool its own cost emptied was not recovered
		// (EngageSkill's slot 0x308 spends it; no OnDeath call was traced
		// from there -- disclosed). What OpenSRO guarantees instead: she
		// stays killable -- the next monster or duel blow whose damage lands
		// on her is her death (killLock, monsterstrike.go, round 551).
		if hpCost > 0 {
			hp, _, err := chars.ApplyDamage(ctx, characterID, 0)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "lookup failed"}).Encode()})
			}
			if !combat.CanPaySkillHealth(hp, hpCost) {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "not enough health"}).Encode()})
			}
			if _, _, err := chars.ApplyDamage(ctx, characterID, hpCost); err != nil {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "spending health failed"}).Encode()})
			}
		}

		// Pay the skill's real mana cost. Checked after the cooldown gate so a
		// skill that is not ready does not drain anything, and before the use
		// is recorded so a refused cast costs neither mana nor the cooldown.
		if mp != nil && mpCost > 0 {
			owned, err := chars.GetByID(ctx, characterID)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "lookup failed"}).Encode()})
			}
			maxMP := owned.MaxMP()
			if _, ok := mp.Spend(characterID, maxMP, mpCost); !ok {
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "not enough mana"}).Encode()})
			}
		}

		if err := skills.RecordUse(ctx, characterID, req.SkillID, now); err != nil {
			return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: "recording use failed"}).Encode()})
		}
		// Arm the group with this row's ReuseDelay, as FUN_0064c700 files the
		// new timer under the +0x8f byte. The engine's delay is ReuseDelay
		// (+0x7c) for a row that is not active with a duration; for one that
		// is (+0x65 == 2, +0x78 != 0) it is p140/100 * t + max(0, ReuseDelay -
		// t), t = +0x74 + +0x78 -- PreparingTime + CastingTime (added at
		// load) + ActionDuration. p140 defaults to 100
		// (docs/protocol/param_registry.md) and the divisor is the double
		// 100.0 at .rdata 0xb45af0, so the delay is max(ReuseDelay, t), and on
		// the real rows that is ReuseDelay for all 2,371 grouped rows with a
		// ReuseDelay.
		if g := skillCooldownGroup(castRow); g != 0 {
			skillGroupCooldowns.Arm(characterID, g, time.Duration(castRow.ReuseDelayMs)*time.Millisecond, now)
		}
		// A cast is a new action: whatever the character was auto-attacking
		// stops here (the actor's queue rule -- a second action ends the
		// keep-up), and the plain swings resume only through the hand-off at
		// the end.
		//
		// SELF-CASTS TOO (round 616, a question asked of this line): retail
		// sends every skill cast -- a buff, Ghost Walk -- as a 0x7074 kind-4
		// action, and its handler (0x4acc40) Pushes it (0x4ad630) behind a
		// keep-up in phase 3, which ends itself when it sees the queue at
		// depth 2 (auto_command.md, READ). No self-buff resumes the swings:
		// the kind-3 Target_Required-0 class rows carry AutoAttackType 0
		// (987) or 2 (72), never the 1 the hand-off tests (MEASURED on the
		// retail skilldata). Whether the retail CLIENT re-sends an attack
		// after such a cast is its own business (round 617).
		keepUp.Cancel(characterID)

		// NO DAMAGE, and this is the engine's own answer rather than a choice.
		// Combat_ResolveDamage (0x0058e5f0) reaches it two ways, and OpenSRO
		// treats them alike because it models neither of the differences yet:
		//
		//   - It RETURNS before resolving anything when the skill carries none
		//     of the 33 in skillparam.CombatParameters and no 'efr' whose
		//     second value is 6. 1,813 real rows, 1,797 after the 'efr' ones.
		//   - Otherwise `local_d0` is 1 whenever the skill carries neither
		//     'att' nor 'ck', and the ordinary damage kind then writes ZERO to
		//     both the physical and magical halves, whose sum is the total.
		//     2,482 real rows, containing the first group.
		//
		// Until these columns existed every one of them dealt
		// DisclosedSkillDamagePerLevel * level, because skillDamageBonus fell
		// back to the disclosed bonus whenever AttackPercent was zero. So using
		// a buff on a monster hurt it. It no longer does, and that constant no
		// longer touches real skill data at all -- only the own-design
		// skill.Catalog, which has no real row.
		//
		// The cast still SUCCEEDS: costs were paid and the use recorded above,
		// which is the order the engine checks them in (EngageSkill 0x593540:
		// the costs first, the heal later, in Skill_ApplyEffectsAndNotify).
		// What the skill does INSTEAD of a blow is modelled for one case only:
		// a flat SELF-HEAL (round 503). A row whose refdata SelfHealHP /
		// SelfHealMP is non-zero -- the exporter writes them only for the shape
		// skillparam.SelfHealAmounts proves exact: action kind 0,
		// Target_Required 0, a flat 'heal' with no 'efr'/'nmh'/'mwhh'/'mwmh'/
		// 'HLRU' -- restores that much to the caster, as the engine's empty-
		// target branch does (0x5942ad-0x5942f3 -> Skill_ApplyHealToObject
		// 0x5a0850 on the caster). The scale 1 + p170/100 is exactly 1 here:
		// p170/p171 have one writer, the 'rhru' buff, and there is no buff
		// system. HP lands capped at the maximum, as the engine's setter clamps
		// it (GObjChar::FUN_004a66f0: `cmp edi,GetMaxHP` via vtbl +0x110; the
		// MP setter 0x4a6790 the same against +0x114), and only on a LIVING
		// caster (0x5942c0 vtbl+0xf8 GetLifeState == 1; the pool adjust
		// 0x4a87d0 tests it again). Two disclosed gaps: ApplyHPMPDelta
		// (0x4a86a0) first scales the amounts by (1 - p143/100) and
		// (1 - p144/100), the panic/combustion states OpenSRO does not model;
		// and buffs, status effects and heals on others remain unbuilt.
		//
		// WHO IS HEALED, stated exactly (round 507). This heals the caster
		// whatever req.TargetMonsterID names. The engine heals the caster only
		// when the use context's target vector is EMPTY (0x594293-0x5942ab);
		// with a non-empty one it heals each living target instead
		// (0x59459f-0x59463c), not the caster. On the path a player's cast
		// takes, those agree: Tick_UseSkill phase 0 (0x4ae6f0-0x4ae717) clears
		// the action context's target vector for every Target_Required 0 row
		// of Basic_Activity 2 -- the clear sits behind `cmp byte [edi+0x65],2
		// ; jne` (0x4ae6e6) -- before phase 2 posts the 0x7070 command.
		// SelfHealAmounts passes only Target_Required 0 rows, and all 57 it
		// selects (the 49 SKILL_CH_WATER_SELFHEAL and 8
		// SKILL_EU_BARD_RECOVERA_ABNORMALTIME rows) are Activity 2 (round 511,
		// re-measured). Not read: whether the 0x7070 consumer can put a target
		// back into the vector for such a row. If it can, a targeted self-heal
		// is a divergence.
		//
		// The MP half reaches the pool (mana.Tracker) but not the client at
		// once: AttackResult has no MP field, so the HUD's MP bar moves on the
		// next OpCharacterStatsResult (a stats request, or the push regen.go
		// sends when a regen tick restores HP or MP).
		//
		// PlayerHP carries the caster's real HP on every such cast. It is what
		// the client paints the health bar from, and it was left at its zero
		// value here, so every buff or other non-damaging cast emptied the bar
		// -- the same defect performAttack's seed fixed for swings. A lookup
		// failure leaves it 0, as performAttack does.
		//
		// The gauge rides along unchanged so the HUD orbs do not blink to zero
		// on a cast that simply is not an attack.
		//
		// This return also skips the keep-up hand-off at the end of the
		// handler. The engine's hand-off test does not look at damage, so
		// skipping it here is a DISCLOSED DEPARTURE (keepup.go's package
		// comment). On the real rows it affects the five type-1, no-chain,
		// ZeroDamage rows SKILL_EU_WARRIOR_DUALA_STUN_A_01..05 (ids
		// 9245-9249): retail hands off after them, and OpenSRO does not.
		//
		// A CASTER BUFF and a GROUND CAST (round 616) end here too, whatever
		// their damage columns say: SkillAction_Buff resolves no blow when it
		// engages (an imbue's 'att' acts on the caster's later blows, which is
		// not modelled -- OPEN), and Ghost Walk is a move.
		//
		// A FRIENDLY cast (round 622) ends here too: its target is a
		// character, never a monster to strike. Its buff starts on the target
		// (startBuffOnLocked) and its heal lands on the target
		// (healCharacter, the TargetHealHP/MP columns).
		if isBuff || isGround || selfTarget || friendly || noCombat || zeroDmg {
			res := echoed(req, &AttackResult{MonsterID: req.TargetMonsterID})
			if selfTarget || friendly {
				res.MonsterID = 0 // no monster: the field is ignored for a targetType 0 cast and names a character for type 3
			} else if m, ok := monsters.Get(req.TargetMonsterID); ok {
				// No blow landed, so the monster's health is what it was: sent
				// as it is (round 655's review), not the zero value, which a
				// client applying the result's health would paint as a dead bar
				// (a zero-damage stun, SKILL_EU_WARRIOR_DUALA_STUN_A_01..05).
				res.MonsterRemainingHP = int32(m.HP)
			}
			if owned, err := chars.GetByID(ctx, characterID); err == nil && owned != nil {
				res.PlayerHP = int32(owned.HP)
				if castRow != nil && owned.HP > 0 {
					if castRow.SelfHealHP > 0 {
						if hp, err := chars.Heal(ctx, characterID, castRow.SelfHealHP, owned.MaxHP()); err == nil {
							res.PlayerHP = int32(hp)
						}
					}
					if castRow.SelfHealMP > 0 && mp != nil {
						mp.Restore(characterID, owned.MaxMP(), castRow.SelfHealMP)
					}
				}
			}
			if zerk != nil {
				res.BerserkGauge = int32(zerk.Gauge(characterID))
				res.BerserkActive = zerk.Active(characterID)
			}
			// The buff or the move happens before the answer, so a failure
			// -- the session left the world between the checks and here --
			// can hand back what the cast took (round 616's review; the
			// re-use timer is not re-armed, disclosed) and answer a refusal.
			done := true
			if isBuff && friendly {
				done = startBuffOnLocked(hub, castRow, characterID, friendTarget.CharacterID, now) != startFailed
			} else if isBuff {
				e, _ := hub.EntityBySession(sess.ID())
				done = startCasterBuffLocked(hub.EntitiesInZone(e.Zone), castRow, characterID, now) != startFailed
			}
			if isGround && done {
				done = moveBySkill(sess, hub, chars, req.SkillID, groundDest, now)
			}
			if !done {
				refundSkillCosts(ctx, chars, mp, characterID, hpCost, mpCost)
				return sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: echoed(req, &AttackResult{Error: castFailedRefusal}).Encode()})
			}
			if friendly && (castRow.TargetHealHP > 0 || castRow.TargetHealMP > 0) {
				if hp := healCharacter(ctx, hub, chars, eq, items, skills, mp, friendTarget, castRow.TargetHealHP, castRow.TargetHealMP); hp >= 0 && friendTarget.CharacterID == characterID {
					res.PlayerHP = int32(hp)
				}
			}
			if err := sess.Send(&proto.Packet{Opcode: OpAttackResult, Data: res.Encode()}); err != nil {
				return err
			}
			// The zone sees the cast (round 622, OpSkillCast).
			announceCast(hub, characterID, req, castRow)
			// A cast at a monster that resolves no blow -- a zero-damage stun,
			// a debuff -- still lands its states (round 659, status.go).
			if statusCastAtMonster(castRow, isBuff, isGround, selfTarget, friendly) {
				statusFX.applyToMonster(combatDeps{chars: chars, eq: eq, items: items, hub: hub, monsters: monsters, quests: quests, inv: inv, skills: skills, zerk: zerk, mp: mp, parties: parties, ground: ground, dropSrc: dropSrc, potions: potions}, characterID, castRow, req.TargetMonsterID, now)
			}
			return nil
		}

		// THE SKILL'S OWN REACH was tested above, before the costs (round
		// 534). A cast was resolved at any distance at all -- "when i use a
		// skill on a monster even from far away, it still uses the skill. no
		// distance checking" (playtest 2026-09-20).
		//
		// It is the SAME recovered test a plain swing uses, given the skill's
		// range instead of the weapon's: combat.ApproachBand's reach is
		// casterBC + targetBC + range with the +2 slack, and
		// combat.EffectiveRange already takes a skill range as its first
		// argument and falls back to the weapon's when the skill declares none
		// (Action_Range, refdata.Skill.Range). Nothing there is new
		// arithmetic; the skill path simply never called it.

		var blow blowReport
		if err := performAttack(ctx, sess, chars, eq, items, hub, monsters, quests, inv, skills, zerk, mp, parties, ground, dropSrc, potions, characterID, req.TargetMonsterID, damageBonus, damagePercent, masteryPercent, hits, attackType, &blow); err != nil {
			return err
		}
		// The zone sees the cast (round 622, OpSkillCast) -- only when its
		// blow landed (round 622's review): a cast performAttack refused
		// after the costs ("target not found") is the requester's refusal
		// alone, as retail's 0xB070 result 2 is.
		if blow.Landed {
			announceCast(hub, characterID, req, castRow)
		}
		// The blow's states (round 659, status.go): on the monster it landed
		// on, if it lives -- and not when the monster blocked it (round 659's
		// review, M3: 0x5906c0 tests the hit record's blocked flag; OURS: one
		// application for the cast, when any of its hits got through).
		if blow.Landed && !blow.Blocked {
			statusFX.applyToMonster(combatDeps{chars: chars, eq: eq, items: items, hub: hub, monsters: monsters, quests: quests, inv: inv, skills: skills, zerk: zerk, mp: mp, parties: parties, ground: ground, dropSrc: dropSrc, potions: potions}, characterID, castRow, req.TargetMonsterID, now)
		}
		// The skill tick's hand-off (round 256, keepup.go): a row with
		// AutoAttackType 1 and no Basic_ChainCode leaves a plain attack
		// running against the same target once its PreparingTime +
		// CastingTime + ActionDuration has played (round 502). A zero-damage
		// row never gets here (the early return above).
		// TestSkillCastHandsOffToPlainSwings drives it through this handler.
		if skillHandsOff(castRow) {
			if m, ok := monsters.Get(req.TargetMonsterID); ok && m.HP > 0 {
				deps := combatDeps{chars: chars, eq: eq, items: items, hub: hub, monsters: monsters, quests: quests, inv: inv, skills: skills, zerk: zerk, mp: mp, parties: parties, ground: ground, dropSrc: dropSrc, potions: potions}
				armKeepUp(sess, deps, characterID, req.TargetMonsterID, handOffDelay(castRow))
			}
		}
		return nil
	}
}

// refundSkillCosts gives back the HP and MP a cast took when what it was to
// do could not be done after the costs were paid (round 616's review).
func refundSkillCosts(ctx context.Context, chars character.Store, mp *mana.Tracker, characterID int64, hpCost, mpCost int) {
	owned, err := chars.GetByID(ctx, characterID)
	if err != nil || owned == nil {
		return
	}
	if hpCost > 0 {
		chars.Heal(ctx, characterID, hpCost, owned.MaxHP())
	}
	if mpCost > 0 && mp != nil {
		mp.Restore(characterID, owned.MaxMP(), mpCost)
	}
}

// echoed marks res as answering req: it carries req's targetType (round 616;
// AttackResult.TargetType).
func echoed(req *UseSkillRequest, res *AttackResult) *AttackResult {
	if req != nil && req.Target() != TargetEntity {
		res.TargetType, res.HasTargetType = req.Target(), true
	}
	return res
}

// skillCooldownGroup is the cooldown group whose shared timer a cast of ref
// waits on and arms, or 0 for none: refdata.Skill.CooldownGroup, the high
// byte of Action_Overlap (CRefSkill+0x8f) that SkillCooldowns::IsReady
// (0x64c1a0) keys the group map at block+0x2c on. It is 0 when:
//
//   - ref is nil (an own-design catalog skill has no real row) or ungrouped;
//   - ReuseDelay is not positive. IsReady tests `+0x7c != 0` first and
//     answers ready without looking at any map, so such a row never waits.
//     Not arming the group for it matches the engine on every real row
//     (round 507). The arm's callers are the per-action-kind handlers in the
//     table at .data 0xc63c7c (kind 0 Skill_BuildUseContext_B 0x586700,
//     kind 1 Skill_BuildUseContext_A 0x5857b0, kind 3 SkillAction_Buff
//     0x5830b0, kind 4 0x587260); FUN_0064c700 has four call sites, in the
//     kind 0, 1 and 3 handlers and a siege path (0x623981). Kind 0 arms
//     only when ReuseDelay != 0 (0x586c03 `cmp [edi+0x7c],0 ; je`), and the
//     kind-4 handler holds no call site. That handler is SkillAction_Stance
//     (0x587260, named in round 268; the dump does not define it), which
//     CALLS EngageSkill 0x593540 (phase 3, 0x58727f) and
//     SkillAction_Stance_Register 0x587210 (phase 6, 0x58729d) -- it is
//     neither of them. The 195 real grouped rows with no ReuseDelay
//     are 192 kind-0 chain links and 3 kind-4 rows
//     (SKILL_CH_SWORD/SPEAR/BOW_BALANCE_A_01), so none is armed. Kinds 1 and
//     3 call the arm unguarded: there a row active with a duration would
//     file PreparingTime + CastingTime + ActionDuration (+0x74 holds the
//     first two), and one whose delay comes to 0 with no 'cbuf' (0x64c84e-
//     0x64c85c) files a delay-0 entry OVER the group's pointer (0x64cc15-
//     0x64cc25), which releases the whole group. No real grouped row takes
//     either path; neither is modelled;
//   - ReuseDelay is 300 000 ms or more. FUN_0064c700 sends such a delay down
//     the persisted CTJ_CoolTimeKeeper branch (0x64c8bb `cmp [esp+0x1c],
//     0x493e0`, i.e. 300 000), which OpenSRO does not model, so these rows
//     keep only their per-id timer -- a DISCLOSED departure. That branch
//     still files the entry in the group map (0x64cae4-0x64cafb) when it
//     finds a keeper slot free; with none free (0x64cb82-0x64cbd5) it
//     returns without filing. So in the engine these rows share their
//     group when a keeper slot is free, and here they do not: casting
//     Water Harmony A leaves B, C and D (all group 73, 300 000 ms) castable,
//     and the Rogue's transform mask A leaves B (group 29, 600 000 ms). On
//     the class skills that is 34 rows.
func skillCooldownGroup(ref *refdata.Skill) uint32 {
	if ref == nil || ref.CooldownGroup == 0 {
		return 0
	}
	if ref.ReuseDelayMs <= 0 || ref.ReuseDelayMs >= 300000 {
		return 0
	}
	return uint32(ref.CooldownGroup)
}

// SkillListRequest is the OpSkillList payload.
type SkillListRequest struct {
	CharacterName string
}

func (r *SkillListRequest) Encode() []byte { return encodeStrings(r.CharacterName) }

func DecodeSkillListRequest(data []byte) (*SkillListRequest, error) {
	fields, _, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillListRequest: %w", err)
	}
	return &SkillListRequest{CharacterName: fields[0]}, nil
}

// SkillSnapshot is one catalog skill, as sent over the wire, with the
// requesting character's own real relationship to it (known or not, and how
// many seconds until it's off cooldown -- 0 if it's ready now or was never
// used).
type SkillSnapshot struct {
	ID              int64
	Name            string
	DamageBonus     int32
	CooldownSeconds int32
	Known           bool
	ReadySeconds    int32
}

func (s *SkillSnapshot) Encode() []byte {
	out := append(encodeInt64(s.ID), encodeStrings(s.Name)...)
	buf := make([]byte, 13)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(s.DamageBonus))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(s.CooldownSeconds))
	if s.Known {
		buf[8] = 1
	}
	binary.LittleEndian.PutUint32(buf[9:13], uint32(s.ReadySeconds))
	return append(out, buf...)
}

func decodeSkillSnapshot(data []byte) (*SkillSnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("skill id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("name: %w", err)
	}
	if len(rest) < 13 {
		return nil, nil, errors.New("truncated fields")
	}
	return &SkillSnapshot{
		ID: id, Name: names[0],
		DamageBonus:     int32(binary.LittleEndian.Uint32(rest[0:4])),
		CooldownSeconds: int32(binary.LittleEndian.Uint32(rest[4:8])),
		Known:           rest[8] != 0,
		ReadySeconds:    int32(binary.LittleEndian.Uint32(rest[9:13])),
	}, rest[13:], nil
}

// SkillListResult is the OpSkillListResult payload.
type SkillListResult struct {
	Error  string
	Skills []SkillSnapshot
}

func (r *SkillListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Skills)))
	out = append(out, countBuf...)
	for _, s := range r.Skills {
		out = append(out, s.Encode()...)
	}
	return out
}

func DecodeSkillListResult(data []byte) (*SkillListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillListResult: %w", err)
	}
	r := &SkillListResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	if len(rest) < 2 {
		return nil, errors.New("session: decoding SkillListResult: truncated skill count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *SkillSnapshot
		snap, rest, err = decodeSkillSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding SkillListResult: skill %d: %w", i, err)
		}
		r.Skills = append(r.Skills, *snap)
	}
	return r, nil
}

// SkillListHandler returns a gateway.Handler implementing OpSkillList:
// responds with every skill in skill.Catalog (sorted by ID for a
// deterministic order -- Go map iteration isn't stable), each annotated
// with whether characterName's account knows it and, if it's on cooldown,
// how many seconds remain.
func SkillListHandler(chars character.Store, store skill.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpSkillList {
			return nil
		}

		req, err := DecodeSkillListRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: "malformed request"}).Encode()})
		}

		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: errStr}).Encode()})
		}

		ids := make([]int64, 0, len(skill.Catalog))
		for id := range skill.Catalog {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })

		now := time.Now()
		snapshots := make([]SkillSnapshot, 0, len(ids))
		for _, id := range ids {
			sk := skill.Catalog[id]
			known, err := store.Knows(ctx, characterID, id)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: "lookup failed"}).Encode()})
			}
			var readySeconds int32
			if known {
				lastUsed, everUsed, err := store.LastUsed(ctx, characterID, id)
				if err != nil {
					return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Error: "lookup failed"}).Encode()})
				}
				if everUsed {
					readyAt := lastUsed.Add(time.Duration(sk.CooldownSeconds) * time.Second)
					if remaining := readyAt.Sub(now); remaining > 0 {
						readySeconds = int32(remaining.Seconds()) + 1
					}
				}
			}
			snapshots = append(snapshots, SkillSnapshot{
				ID: sk.ID, Name: sk.Name, DamageBonus: int32(sk.DamageBonus), CooldownSeconds: int32(sk.CooldownSeconds),
				Known: known, ReadySeconds: readySeconds,
			})
		}
		return sess.Send(&proto.Packet{Opcode: OpSkillListResult, Data: (&SkillListResult{Skills: snapshots}).Encode()})
	}
}

// SkillStateRequest is the OpSkillState payload.
type SkillStateRequest struct {
	CharacterName string
}

func (r *SkillStateRequest) Encode() []byte { return encodeStrings(r.CharacterName) }

func DecodeSkillStateRequest(data []byte) (*SkillStateRequest, error) {
	fields, _, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillStateRequest: %w", err)
	}
	return &SkillStateRequest{CharacterName: fields[0]}, nil
}

// MasterySnapshot is one mastery's trained level, as sent over the wire.
type MasterySnapshot struct {
	MasteryID int64
	Level     int32
}

// SkillStateResult is the OpSkillStateResult payload: the character's level (so
// the client can show the 3x-level mastery cap), its unspent skill points, and
// every mastery it has raised.
type SkillStateResult struct {
	Error       string
	Level       int32
	SkillPoints int32
	Masteries   []MasterySnapshot
	// KnownSkills is the unique per-level skill ids the character has learned,
	// so the window can badge learned skills apart from merely-available ones.
	KnownSkills []int64
}

func (r *SkillStateResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	buf := make([]byte, 10)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Level))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.SkillPoints))
	binary.LittleEndian.PutUint16(buf[8:10], uint16(len(r.Masteries)))
	out = append(out, buf...)
	for _, m := range r.Masteries {
		out = append(out, encodeInt64(m.MasteryID)...)
		lb := make([]byte, 4)
		binary.LittleEndian.PutUint32(lb, uint32(m.Level))
		out = append(out, lb...)
	}
	kb := make([]byte, 2)
	binary.LittleEndian.PutUint16(kb, uint16(len(r.KnownSkills)))
	out = append(out, kb...)
	for _, id := range r.KnownSkills {
		out = append(out, encodeInt64(id)...)
	}
	return out
}

func DecodeSkillStateResult(data []byte) (*SkillStateResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding SkillStateResult: %w", err)
	}
	r := &SkillStateResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}
	if len(rest) < 10 {
		return nil, errors.New("session: decoding SkillStateResult: truncated")
	}
	r.Level = int32(binary.LittleEndian.Uint32(rest[0:4]))
	r.SkillPoints = int32(binary.LittleEndian.Uint32(rest[4:8]))
	count := int(binary.LittleEndian.Uint16(rest[8:10]))
	rest = rest[10:]
	for i := 0; i < count; i++ {
		id, r2, err := decodeInt64(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding SkillStateResult: mastery %d id: %w", i, err)
		}
		if len(r2) < 4 {
			return nil, errors.New("session: decoding SkillStateResult: truncated mastery level")
		}
		r.Masteries = append(r.Masteries, MasterySnapshot{MasteryID: id, Level: int32(binary.LittleEndian.Uint32(r2[0:4]))})
		rest = r2[4:]
	}
	if len(rest) >= 2 {
		kcount := int(binary.LittleEndian.Uint16(rest[0:2]))
		rest = rest[2:]
		for i := 0; i < kcount; i++ {
			id, r2, err := decodeInt64(rest)
			if err != nil {
				return nil, fmt.Errorf("session: decoding SkillStateResult: known skill %d: %w", i, err)
			}
			r.KnownSkills = append(r.KnownSkills, id)
			rest = r2
		}
	}
	return r, nil
}

// SkillStateHandlerWithRefs answers OpSkillState with the character's level,
// unspent skill points and the level of every mastery its race holds (0 for one
// never raised) -- what the skill window's tabs, totals and lit/greyed skills
// are drawn from. It first drops every learned skill the character may not hold (playerHoldRefusal, the round 691 review):
// the client asks for the state on entering the world, so a monster's or
// another race's skill learned before the learn gate refused it goes at the
// next login, logged. A nil skillRef judges nothing.
func SkillStateHandlerWithRefs(chars character.Store, store skill.Store, skillRef SkillRefStore) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpSkillState {
			return nil
		}
		send := func(r *SkillStateResult) error {
			return sess.Send(&proto.Packet{Opcode: OpSkillStateResult, Data: r.Encode()})
		}
		req, err := DecodeSkillStateRequest(p.Data)
		if err != nil {
			return send(&SkillStateResult{Error: "malformed request"})
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return send(&SkillStateResult{Error: errStr})
		}
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return send(&SkillStateResult{Error: "lookup failed"})
		}
		points, err := store.SkillPoints(ctx, characterID)
		if err != nil {
			return send(&SkillStateResult{Error: "lookup failed"})
		}
		levels, err := store.MasteryLevels(ctx, characterID)
		if err != nil {
			return send(&SkillStateResult{Error: "lookup failed"})
		}
		result := &SkillStateResult{Level: int32(owned.Level), SkillPoints: int32(points)}
		// Every mastery the character HOLDS, a level-0 one included -- retail's
		// character data carries the whole _CharSkillMastery list (seeded at
		// level 0 by _AddNewChar), and the client's skill window lays out
		// exactly that list (FUN_006aa3e0 walks the server's mastery map into
		// one tab manager per TabID, READ). Round 691: the client picks the
		// race's masteries from this; another race's stored row is not sent.
		for _, id := range skill.DefaultMasteries(characterCountry(owned)) {
			result.Masteries = append(result.Masteries, MasterySnapshot{MasteryID: id, Level: int32(levels[id])})
		}
		sort.Slice(result.Masteries, func(i, j int) bool { return result.Masteries[i].MasteryID < result.Masteries[j].MasteryID })
		if learned, err := store.KnownSkills(ctx, characterID); err == nil {
			result.KnownSkills = purgeUnholdable(ctx, store, skillRef, characterID, characterCountry(owned), learned)
		}
		return send(result)
	}
}

// RaiseMasteryRequest is the OpRaiseMastery payload.
type RaiseMasteryRequest struct {
	CharacterName string
	MasteryID     int64
}

func (r *RaiseMasteryRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.MasteryID)...)
}

func DecodeRaiseMasteryRequest(data []byte) (*RaiseMasteryRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RaiseMasteryRequest: %w", err)
	}
	id, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RaiseMasteryRequest: mastery id: %w", err)
	}
	return &RaiseMasteryRequest{CharacterName: fields[0], MasteryID: id}, nil
}

// RaiseMasteryResult is the OpRaiseMasteryResult payload.
type RaiseMasteryResult struct {
	Error       string
	MasteryID   int64
	NewLevel    int32
	SkillPoints int32
}

func (r *RaiseMasteryResult) Encode() []byte {
	out := append(encodeStrings(r.Error), encodeInt64(r.MasteryID)...)
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.NewLevel))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.SkillPoints))
	return append(out, buf...)
}

func DecodeRaiseMasteryResult(data []byte) (*RaiseMasteryResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RaiseMasteryResult: %w", err)
	}
	id, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RaiseMasteryResult: mastery id: %w", err)
	}
	if len(rest) < 8 {
		return nil, errors.New("session: decoding RaiseMasteryResult: truncated")
	}
	return &RaiseMasteryResult{
		Error:       fields[0],
		MasteryID:   id,
		NewLevel:    int32(binary.LittleEndian.Uint32(rest[0:4])),
		SkillPoints: int32(binary.LittleEndian.Uint32(rest[4:8])),
	}, nil
}

// RaiseMasteryHandler raises a mastery one level, spending masteryUpCost's skill
// points (none for a mastery's first point or past MasteryCostLevelCeiling),
// when the mastery is one the character's race holds (0x3801), the character's
// mastery total stays within its Country's cap (China a flat 330, Europe
// min(240, 2 x level) -- see masteryTotalRefusal) and the mastery is below the
// character's level (no single mastery can exceed it). The checks run in
// Mastery_LevelUp's own order: held (0x3801), total cap (0x3805), then
// the character's level (0x3804), then skill points (0x3802) -- a check the
// engine skips for level 0 and that a cost of 0 passes here. Answers
// OpRaiseMasteryResult.
func RaiseMasteryHandler(chars character.Store, store skill.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpRaiseMastery {
			return nil
		}
		fail := func(reason string) error {
			return sess.Send(&proto.Packet{Opcode: OpRaiseMasteryResult, Data: (&RaiseMasteryResult{Error: reason}).Encode()})
		}
		req, err := DecodeRaiseMasteryRequest(p.Data)
		if err != nil {
			return fail("malformed request")
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return fail(errStr)
		}
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		levels, err := store.MasteryLevels(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		// Mastery_LevelUp's first check (FUN_0059d6f0, READ): the mastery must be
		// one the character holds, else 0x3801. A character holds its race's
		// masteries (skill.HoldsMastery, from _AddNewChar), so a Europe
		// character cannot raise Bicheon and a China one cannot raise Warrior.
		country := characterCountry(owned)
		if !skill.HoldsMastery(country, req.MasteryID) {
			return fail("not your race's mastery")
		}
		// The total counts the character's own masteries. A row of another
		// race's mastery (raised before round 691 made that impossible) is not
		// in the engine's map at all, so it is not summed (FUN_0059e7c0 walks
		// the held map only).
		total := 0
		for id, lvl := range levels {
			if skill.HoldsMastery(country, id) {
				total += lvl
			}
		}
		switch code := masteryTotalRefusal(country, total, 1, owned.Level); {
		case code == masteryErrTotalCap:
			return fail("mastery total at cap")
		case code != 0:
			return fail("invalid mastery")
		}
		// The mastery may not pass the character's level, and nothing else
		// caps it: Mastery_LevelUp refuses with error 0x3804 when
		// `characterLevel < currentMasteryLevel + levelsRequested`
		// (0x59c611), which is exactly this bound for a single-level raise.
		// Its 0x78 is the cost loop's bound, not a refusal -- see
		// MasteryCostLevelCeiling -- so a mastery past 120 still raises.
		levelCap := owned.Level
		newLevel, err := store.RaiseMastery(ctx, characterID, req.MasteryID, masteryUpCost(levels[req.MasteryID]), levelCap)
		if err != nil {
			switch {
			case errors.Is(err, skill.ErrMasteryCapped):
				return fail("mastery at level cap")
			case errors.Is(err, skill.ErrInsufficientSkillPoints):
				return fail("not enough skill points")
			default:
				return fail("raise failed")
			}
		}
		points, err := store.SkillPoints(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		return sess.Send(&proto.Packet{Opcode: OpRaiseMasteryResult, Data: (&RaiseMasteryResult{
			MasteryID: req.MasteryID, NewLevel: int32(newLevel), SkillPoints: int32(points),
		}).Encode()})
	}
}

// equippedWeaponType returns the TypeID3/TypeID4 of the weapon characterID has
// equipped, and whether the answer is trustworthy enough to refuse a cast on.
//
// An EMPTY HAND is (0, 0, true): that is a real answer, and
// combat.SkillAllowsWeapon turns it into the bare-hand code, matching the
// engine's own `if (code == 0) code = 1` branch -- SKILL_PUNCH_01, the unarmed
// attack, requires exactly that code.
//
// An UNREADABLE one is (0, 0, false), and the caller permits the cast. The
// distinction is load-bearing rather than defensive: an item row imported before
// the type_id columns existed carries TypeID3 = TypeID4 = 0, which is
// indistinguishable from an empty hand by value alone. Treating that as bare
// hand would refuse every weapon-requiring skill to a character holding a
// perfectly good sword, on a deployment whose only fault is an old import.
// weaponIsBroken reports whether the worn weapon sits at zero durability, and
// whether the answer is trustworthy. It is the serviceability half of the cast
// requirement -- see the call site for the recovery. It is CGObjPC slot 372
// (0x004ec5a0): the weapon slot's item+0x190 broken flag, nothing more.
func weaponIsBroken(ctx context.Context, characterID int64, eq equipment.Store) (broken, known bool) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return false, false
	}
	return wornBroken(equipped, equipment.SlotWeapon), true
}

func equippedWeaponType(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) (typeID3, typeID4 int, known bool) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0, 0, false
	}
	for _, e := range equipped {
		if e.Slot != equipment.SlotWeapon {
			continue
		}
		item, err := items.GetItem(ctx, e.ItemID)
		if err != nil || item == nil {
			return 0, 0, false
		}
		// A weapon whose type fields are both zero predates the type_id
		// columns. Say so rather than letting it read as an empty hand.
		if item.TypeID3 == 0 && item.TypeID4 == 0 {
			return 0, 0, false
		}
		return item.TypeID3, item.TypeID4, true
	}
	// Nothing in the weapon slot: a real empty hand.
	return 0, 0, true
}

// equippedTypes returns the TypeID3/TypeID4 of every item the character is
// wearing, and whether the answer is trustworthy enough to refuse a cast on.
//
// It is NOT trustworthy when any worn item has both type fields zero, which is
// what an item row imported before the type_id columns carries -- the same
// distinction equippedWeaponType draws, for the same reason: a stale import
// must not look like an empty equipment set and lock every skill.
func equippedTypes(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) ([]combat.EquippedType, bool) {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return nil, false
	}
	out := make([]combat.EquippedType, 0, len(equipped))
	for _, e := range equipped {
		// A BROKEN ITEM IS AN EMPTY SLOT to the reqi check (round 486). The
		// engine's list walk in Skill_CheckCastRequirement (0x0058d480) reads
		// each slot's type through a getter -- Equip_GetShieldTID 0x004ead80
		// (called at 58d4c9), Equip_GetWeaponTID 0x004ead40 (58d4d4),
		// Equip_GetArmourPartTID 0x004eadc0 (58d57e / 58d5c8) -- and
		// all three write TID 0 when the item's +0x190 is set:
		//
		//	4ead63  cmp DWORD PTR [eax+0x190],0x0 ; jne -> mov WORD [edi],0x0
		//	4eada3  cmp DWORD PTR [eax+0x190],0x0 ; jne -> mov WORD [edi],0x0
		//	4eadf5  cmp DWORD PTR [esi+0x190],0x0 ; jne -> mov WORD [edi],0x0
		//
		// +0x190 is the flag GItemEquip::SetBrokenFlag (0x00495980) stores;
		// GItemEquip::AddDurability (0x00496d90, call at 496e1b) passes
		// `new < 1` and CGItemEquip::Create (0x00495c00) `durability == 0`,
		// which on a value clamped at 0 is durability.IsBroken -- except that
		// SetBrokenFlag stores 0 instead whenever the item answers non-zero
		// to vslot 36 (+0x90, "has no durability", docs/protocol/durability.md),
		// 277 (+0x454, an avatar-item predicate, RE_COMPLETION.md's
		// CanBeEquipedAt note) or 284 (+0x470, unnamed) (495982-4959bd).
		// IsBroken does not test those. Two of them cannot arise here:
		// OpenSRO has no avatar slots (equipment.SlotFor gives TypeID3 13/14
		// none), and inventory.FreshInstance makes an item with no durability
		// range Untracked (-1), never 0. The third, vslot 284, is unread, so
		// an item answering it at durability 0 would be read as broken here
		// and not by the engine -- a disclosed gap, the same one
		// weaponIsBroken and the stat removal carry. So a broken
		// item's TID matches no entry with a TypeID4, and the walk ends in
		// 0x300d (58d695, UIIT_SKILL_USE_FAIL_WRONGWEAPON) exactly as for an
		// empty slot. Skipping it before the lookup is that: an empty slot
		// has no row to read either. Untracked (-1) is not broken and stays
		// in.
		if durability.IsBroken(e.Durability) {
			continue
		}
		item, err := items.GetItem(ctx, e.ItemID)
		if err != nil || item == nil {
			return nil, false
		}
		if item.TypeID3 == 0 && item.TypeID4 == 0 {
			return nil, false // metadata predates the type_id columns
		}
		out = append(out, combat.EquippedType{TypeID3: item.TypeID3, TypeID4: item.TypeID4})
	}
	return out, true
}

// The engine's own precondition ladder for a skill cast is recovered in
// docs/protocol/skill_use_gate.md, read off FUN_0058d8f0 -- the function that
// sits immediately before Combat_ResolveDamage and returns one of seventeen
// refusal codes.
//
// UseSkillHandler above checks the skill is known, then the cooldown, then the
// HP cost, then the MP cost, each gated on the cost being greater than zero.
// That is the engine's order and the engine's gating (and since round 534 the
// reach follows those checks and precedes the payment -- skillCostRefusal):
//
//	58d93f  0x3003  NOTLEARN              the skill does not resolve
//	58e095  0x3005  TIMEDELAY_COOL_TIME   the cooldown check fails
//	58e292  0x3013  NOTENOUGHHP           hpCost > 0 && CurHP < hpCost
//	58e2b1  0x3004  NOTENOUGHMP           mpCost > 0 && CurMP < mpCost
//
// This was NOT known to be the engine's order when the handler was written, and
// nothing changed when it was read. It is recorded because "we happen to agree"
// and "we match a read" are different claims, and only the second is worth
// anything later.
//
// The thirteen refusals OpenSRO does not implement are listed on that page
// with the shape of each test: stealth and musical range, trap placement, buff
// duplication and overlap, ammunition, line of sight, and a level requirement
// read off the TARGET's ref object rather than the skill's.

// skillCostRefusal is the gate's HP and MP rows as a CHECK, spending nothing:
// "not enough health" when hpCost > 0 and the caster's HP is below it,
// "not enough mana" when mpCost > 0 and the pool is below it, "lookup failed"
// when the caster cannot be read, else "". The engine tests these rows (mask
// bit 0x10, 0x58e1ac) in Tick_UseSkill's gates BEFORE the reach test, and
// takes the costs only in EngageSkill, after the reach (round 534; see the
// reach block in useSkillHandler). The same tests as the spending blocks that
// follow the reach -- combat.CanPaySkillHealth and mana.Tracker's
// `cur < cost` -- which still re-check when they spend.
func skillCostRefusal(ctx context.Context, chars character.Store, mp *mana.Tracker, characterID int64, hpCost, mpCost int) string {
	if hpCost > 0 {
		hp, _, err := chars.ApplyDamage(ctx, characterID, 0)
		if err != nil {
			return "lookup failed"
		}
		if !combat.CanPaySkillHealth(hp, hpCost) {
			return "not enough health"
		}
	}
	if mp != nil && mpCost > 0 {
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return "lookup failed"
		}
		if mp.Current(characterID, owned.MaxMP()) < mpCost {
			return "not enough mana"
		}
	}
	return ""
}
