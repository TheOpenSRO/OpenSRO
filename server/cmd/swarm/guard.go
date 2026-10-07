package main

// The prefix guard: what makes `swarm down` unable to touch an account that
// is not a bot's. Every account the tool creates, seeds, logs in or deletes is
// named exactly prefix + four digits, and the prefix itself is 5..8 lowercase
// letters -- no digit, so "swarm" can never match "swarm1" + four digits, and
// no character a regular expression or LIKE pattern would read specially.

import (
	"fmt"
	"regexp"
)

const (
	minPrefix = 5
	// maxPrefix keeps prefix + four digits within the lobby's 12-byte name
	// limit (session.LobbyNameCode), since a bot's character is named as its
	// account.
	maxPrefix = 8
	// maxBots is what four digits can number.
	maxBots = 10000
)

var prefixRE = regexp.MustCompile(`^[a-z]+$`)

// checkPrefix refuses a prefix shorter than 5 or longer than 8 characters, or
// one with anything but lowercase ASCII letters.
func checkPrefix(prefix string) error {
	if len(prefix) < minPrefix {
		return fmt.Errorf("prefix %q is shorter than %d characters: refused (it could match real accounts)", prefix, minPrefix)
	}
	if len(prefix) > maxPrefix {
		return fmt.Errorf("prefix %q is longer than %d characters (a bot's name must fit the lobby's 12 bytes)", prefix, maxPrefix)
	}
	if !prefixRE.MatchString(prefix) {
		return fmt.Errorf("prefix %q must be lowercase letters a-z only", prefix)
	}
	return nil
}

// botPattern is the one pattern a bot's account and character are named by:
// ^prefix[0-9]{4}$. The prefix is checked first, so it holds no regexp
// metacharacter and the same string is valid for Go and for Postgres's `~`.
func botPattern(prefix string) (string, error) {
	if err := checkPrefix(prefix); err != nil {
		return "", err
	}
	return "^" + prefix + "[0-9]{4}$", nil
}

// botMatcher compiles botPattern.
func botMatcher(prefix string) (*regexp.Regexp, error) {
	p, err := botPattern(prefix)
	if err != nil {
		return nil, err
	}
	return regexp.MustCompile(p), nil
}

// botName is bot i's account and character name.
func botName(prefix string, i int) string { return fmt.Sprintf("%s%04d", prefix, i) }
