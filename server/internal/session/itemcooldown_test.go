package session

import (
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// A timer belongs to the cooltime GROUP: two items in group 0xC8 share it, an
// item in another group does not, and it runs out exactly at the delay.
func TestItemCooldownIsPerGroup(t *testing.T) {
	tr := newItemCooldownTracker()
	t0 := time.Date(2026, 9, 19, 18, 40, 0, 0, time.UTC)
	if !tr.Ready(1, 0xC8, t0) {
		t.Fatal("an unarmed group is ready")
	}
	tr.Arm(1, 0xC8, 20*time.Second, t0)
	if tr.Ready(1, 0xC8, t0.Add(19999*time.Millisecond)) {
		t.Error("inside the 20 s the group is not ready")
	}
	if !tr.Ready(1, 0xC8, t0.Add(20*time.Second)) {
		t.Error("at 20 s it is ready again")
	}
	if !tr.Ready(1, 0xF0, t0.Add(time.Second)) {
		t.Error("another group has its own timer")
	}
	if !tr.Ready(2, 0xC8, t0.Add(time.Second)) {
		t.Error("another character has its own timers")
	}
}

// Round 504: which rows take part in a shared skill cooldown group, and the
// group timer itself. skillCooldownGroup answers the group only for a grouped
// row with a ReuseDelay under the persisted 300 000 ms branch; the timer runs
// per (character, group).
func TestSkillCooldownGroupGate(t *testing.T) {
	for _, tc := range []struct {
		name string
		ref  *refdata.Skill
		want uint32
	}{
		{"grouped, 3 s", &refdata.Skill{ReqLearnSP: 1, CooldownGroup: 2, ReuseDelayMs: 3000}, 2},
		{"ungrouped", &refdata.Skill{ReqLearnSP: 1, CooldownGroup: 0, ReuseDelayMs: 3000}, 0},
		{"no ReuseDelay (IsReady's +0x7c guard)", &refdata.Skill{ReqLearnSP: 1, CooldownGroup: 2, ReuseDelayMs: 0}, 0},
		{"persisted branch, Water Harmony", &refdata.Skill{ReqLearnSP: 1, CooldownGroup: 73, ReuseDelayMs: 300000}, 0},
		{"just under the persisted branch", &refdata.Skill{ReqLearnSP: 1, CooldownGroup: 73, ReuseDelayMs: 299999}, 73},
		{"catalog skill", nil, 0},
	} {
		if got := skillCooldownGroup(tc.ref); got != tc.want {
			t.Errorf("%s: skillCooldownGroup = %d, want %d", tc.name, got, tc.want)
		}
	}

	tr := newItemCooldownTracker()
	t0 := time.Date(2026, 9, 23, 9, 0, 0, 0, time.UTC)
	tr.Arm(1, 2, 3*time.Second, t0)
	if tr.Ready(1, 2, t0.Add(time.Second)) {
		t.Error("inside the 3 s the group is not ready")
	}
	if !tr.Ready(1, 2, t0.Add(3*time.Second)) {
		t.Error("at 3 s the group is ready again")
	}
	if !tr.Ready(1, 3, t0.Add(time.Second)) {
		t.Error("another group has its own timer")
	}
	if !tr.Ready(2, 2, t0.Add(time.Second)) {
		t.Error("another character has its own timers")
	}
}

// The skill group map and the item cooltime-group map are ONE map in the
// engine (block+0x2c, read by both SkillCooldowns::IsReady and
// ItemCooldowns::IsReady), so the two trackers must be one tracker: an item
// armed in group 0x71 holds a skill in group 0x71 too.
func TestSkillAndItemGroupsShareOneMap(t *testing.T) {
	if skillGroupCooldowns != itemCooldowns {
		t.Fatal("skillGroupCooldowns is a separate tracker; the engine has one group map")
	}
	const char = 424242 // no other test uses this character id
	now := time.Now()
	itemCooldowns.Arm(char, 0x71, time.Minute, now)
	if skillGroupCooldowns.Ready(char, 0x71, now.Add(time.Second)) {
		t.Error("an item armed in group 0x71 did not hold the skill group 0x71")
	}
}
