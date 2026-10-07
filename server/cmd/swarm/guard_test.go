package main

import "testing"

func TestPrefixGuardRefusesShortAndOddPrefixes(t *testing.T) {
	for _, p := range []string{"", "s", "swar", "Swarm", "swarm1", "sw_rm", "swa.m", "swarm*", "^swarm", "abcdefghi", "swärm"} {
		if err := checkPrefix(p); err == nil {
			t.Errorf("checkPrefix(%q) accepted", p)
		}
		if _, err := botPattern(p); err == nil {
			t.Errorf("botPattern(%q) accepted", p)
		}
	}
	for _, p := range []string{"swarm", "crowds", "abcdefgh"} {
		if err := checkPrefix(p); err != nil {
			t.Errorf("checkPrefix(%q): %v", p, err)
		}
	}
}

func TestBotPatternMatchesExactlyPrefixAndFourDigits(t *testing.T) {
	m, err := botMatcher("swarm")
	if err != nil {
		t.Fatal(err)
	}
	for _, u := range []string{"swarm0000", "swarm0999", "swarm9999"} {
		if !m.MatchString(u) {
			t.Errorf("%q does not match", u)
		}
	}
	for _, u := range []string{"swarm", "swarm001", "swarm00001", "swarm0001x", "xswarm0001", "Swarm0001", "swarmy0001",
		"swarm 0001", "swarm0001\n", "swarm-0001", "realplayer"} {
		if m.MatchString(u) {
			t.Errorf("%q matches", u)
		}
	}
	if got := botName("swarm", 7); got != "swarm0007" || !m.MatchString(got) {
		t.Errorf("botName = %q", got)
	}
	// prefix + four digits fits the lobby's 12-byte names.
	if n := len(botName("abcdefgh", maxBots-1)); n > 12 {
		t.Errorf("a %d-byte name", n)
	}
}
