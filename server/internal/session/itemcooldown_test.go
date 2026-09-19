package session

import (
	"testing"
	"time"
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
