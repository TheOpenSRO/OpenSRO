package session

import (
	"context"
	"errors"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

type mapSkillRef map[int64]*refdata.Skill

func (s mapSkillRef) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	if r, ok := s[id]; ok {
		return r, nil
	}
	return nil, errors.New("no such skill")
}

// TestLearnPrerequisites pins the two learn rules on the real Power Strike
// chain: SMASH_A levels 1..3 (group 174, ids 3/291/292) chain level by level,
// and SMASH_B_01 (id 4, group 175) needs group 174 at level 9 (skilldata
// columns 40/43 on that row).
func TestLearnPrerequisites(t *testing.T) {
	ctx := context.Background()
	ref := mapSkillRef{
		3:   {ID: 3, GroupID: 174, BasicLevel: 1},
		291: {ID: 291, GroupID: 174, BasicLevel: 2},
		292: {ID: 292, GroupID: 174, BasicLevel: 3},
		4:   {ID: 4, GroupID: 175, BasicLevel: 1, ReqLearnSkill1: 174, ReqLearnSkillLevel1: 9},
		900: {ID: 900, GroupID: 174, BasicLevel: 9},
	}
	if r := learnPrerequisiteFailure(ctx, ref, ref[3], nil); r != "" {
		t.Errorf("level 1 with nothing known: %q, want allowed", r)
	}
	if r := learnPrerequisiteFailure(ctx, ref, ref[292], []int64{3}); r != "learn level 2 first" {
		t.Errorf("level 3 with only level 1 known: %q", r)
	}
	if r := learnPrerequisiteFailure(ctx, ref, ref[291], []int64{3}); r != "" {
		t.Errorf("level 2 with level 1 known: %q, want allowed", r)
	}
	if r := learnPrerequisiteFailure(ctx, ref, ref[3], []int64{291}); r != "already known" {
		t.Errorf("level 1 when level 2 is known: %q", r)
	}
	if r := learnPrerequisiteFailure(ctx, ref, ref[4], []int64{292}); r != "requires skill group 174 at level 9" {
		t.Errorf("SMASH_B with group 174 at level 3: %q", r)
	}
	if r := learnPrerequisiteFailure(ctx, ref, ref[4], []int64{900}); r != "" {
		t.Errorf("SMASH_B with group 174 at level 9: %q, want allowed", r)
	}
	// An own-design catalog id among the known skills is ignored, not fatal.
	if r := learnPrerequisiteFailure(ctx, ref, ref[291], []int64{3, 424242}); r != "" {
		t.Errorf("unknown known id must be skipped: %q", r)
	}
}
