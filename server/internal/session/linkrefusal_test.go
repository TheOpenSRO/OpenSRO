package session

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/buff"
)

// The review of round 636: FUN_0059dc80's three answers reach the client as
// their retail texts (textuisystem.txt's English column, MEASURED).
func TestRefusalText(t *testing.T) {
	for r, want := range map[buff.Refusal]string{
		buff.RefusedOverlap:      "The selected item cannot be used together or the skill is already in use.",
		buff.RefusedOverlapCount: "The available number of people for this skill is maxed.",
		buff.RefusedTrapExists:   "Cannot set a trap because a set trap already exists.",
	} {
		if got := refusalText(r); got != want {
			t.Errorf("refusal %d: %q, want %q", r, got, want)
		}
	}
}
