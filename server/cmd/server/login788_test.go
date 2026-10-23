package main

import (
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// The login flags (round 788): the defaults pass and become the rules; a
// value out of range is an error, not a quiet fallback.
func TestLoginRulesFrom(t *testing.T) {
	r, err := loginRulesFrom(session.DefaultLoginFailureTolerance, session.DefaultLoginFailureBlockMinutes, 0,
		session.DefaultLoginPunishmentGuide)
	if err != nil {
		t.Fatal(err)
	}
	if r != (session.LoginRules{FailureTolerance: 3, BlockMinutes: 10, PunishmentGuide: session.DefaultLoginPunishmentGuide}) {
		t.Fatalf("defaults: %+v", r)
	}
	if r, err := loginRulesFrom(5, 0, 2, "x"); err != nil || r.BlockMinutes != 0 || r.MaxPerIP != 2 {
		t.Fatalf("block 0 and 2 per IP: %+v, %v", r, err)
	}
	for _, bad := range []struct {
		tol, min, ip int
		guide        string
	}{
		{0, 10, 0, "x"}, {101, 10, 0, "x"}, {3, -1, 0, "x"}, {3, 525601, 0, "x"},
		{3, 10, -1, "x"}, {3, 10, 0, "  "}, {3, 10, 0, strings.Repeat("y", 512)},
	} {
		if _, err := loginRulesFrom(bad.tol, bad.min, bad.ip, bad.guide); err == nil {
			t.Errorf("%+v accepted", bad)
		}
	}
}
